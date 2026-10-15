// CoreService without HTTP: the app's direct line to the core (docs/core.md → "CoreService").
// A fake BoxRunner (the platform seam, no sing-box binary) and the system proxy seams; the
// HTTP adapter over the same logic is covered by killswitch_test / events_test / tun_test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

// What Auto used to probe and report itself, as the tests' wording of a site failure: the probes are the
// Sentinel's checks now (the service's probe seams answer them), Auto only notices.
class AutoBlocked {
  const AutoBlocked({required this.route, required this.server, required this.dest, required this.via, required this.viaServer, required this.at, this.rule = '', this.process = '', this.pkg = ''});
  final String route, server, dest, via, viaServer, rule, process, pkg;
  final int at;
}

class AutoUnreachable {
  const AutoUnreachable({required this.route, required this.server, required this.dest, required this.tried, required this.at, this.retriesOff = false, this.rule = '', this.process = '', this.pkg = ''});
  final String route, server, dest, rule, process, pkg;
  final List<({String route, String server})> tried;
  final bool retriesOff;
  final int at;
}

final _alts = Expando<Map<String, AltReach>>();

extension SiteTestWording on CoreService {
  void _fail(String route, String server, String dest, AltReach alt, String rule, String process, String pkg) {
    (_alts[this] ??= {})[dest] = alt;
    probeSame = (o, d, c) async => false;
    // the scout (step 2) answers with what the case says; the other subscriptions (step 3) add nothing
    probeScout = (o, d, c) async => _alts[this]![d] ?? const AltReach(unsure: true);
    probeElsewhere = (o, d, s, c) async => AltReach(off: _alts[this]![d]?.off ?? false);
    siteFailed(AutoSiteFail(route: route, server: server, tag: server, dest: dest, at: 1, rule: rule, process: process, pkg: pkg));
  }

  void siteBlocked(AutoBlocked b) => _fail(b.route, b.server, b.dest, AltReach(via: b.via, viaServer: b.viaServer), b.rule, b.process, b.pkg);

  void siteUnreachable(AutoUnreachable u) =>
      _fail(u.route, u.server, u.dest, AltReach(tried: u.tried, off: u.retriesOff, unsure: u.tried.isEmpty), u.rule, u.process, u.pkg);
}

/// A runner that is not sing-box: starts when told to, has no API service.
class _Runner implements BoxRunner {
  bool up = false;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;

  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  Map<String, dynamic>? config; // the last one started
  @override
  Future<void> start(Map<String, dynamic> config) async {
    this.config = config;
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}

/// A runner that can take over a running sing-box and hands back [record] for it.
class _AdoptRunner extends _Runner implements AdoptableRunner {
  _AdoptRunner(this.record);
  final Map<String, dynamic> record;
  bool stopped = false;

  @override
  Future<void> keep(Map<String, dynamic> record) async {}

  @override
  Future<Map<String, dynamic>?> adopt() async {
    up = true; // a sing-box was running; adopting attaches to it
    return record;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    up = false;
  }
}

/// A throwaway box (latency test) that comes up and complains once.
class _NoisyRunner extends _Runner {
  @override
  Future<void> start(Map<String, dynamic> config) async {
    up = true;
    onLog?.call('WARN[0000] boom');
  }
}

Map<String, dynamic> _body({bool sys = false}) => {
      'plan': {
        'routes': [
          {
            'id': 'A',
            'kind': 'unit',
            'main': {
              'pick': 'priority',
              'chosen': 's::a',
              'nodes': [
                {
                  'key': 's::a',
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
              ],
            },
          },
        ],
        'mixedPort': 2080,
        'global': true,
      },
      'systemProxy': sys,
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;

  late FakeTime time;

  /// How the TUN test (tun_check.dart) dials: tests have no TUN. Default = refused; [dialThroughResponder] = a TUN
  /// that works (the connection ends at the responder the config's rule names).
  late Future<Socket> Function(String host, int port, Duration timeout) tunDial;
  final dialed = <String>[];

  /// How many of the first dials go through the responder whatever [tunDial] says: the TUN test at the start (tun_check
  /// is asked once a connect) passes by default, so the tests of the log detector see only their own checks.
  late int startTries;

  int responderPort() {
    final rules = ((runner.config!['route'] as Map)['rules'] as List).cast<Map>();
    return (rules.firstWhere((r) => r['override_port'] != null && r['ip_cidr'] != null && '${r['ip_cidr']}'.contains(tunCheckAddress))['override_port'] as num).toInt();
  }

  Future<Socket> dialThroughResponder(String host, int port, Duration timeout) => Socket.connect('127.0.0.1', responderPort());

  /// Lets the real loopback I/O of the TUN test run (the fake time does not move it) until [done].
  Future<void> untilReal(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await time.advance(Duration.zero);
    }
  }

  /// Connects and lets the core settle (5 s after the start).
  Future<void> up([Map<String, dynamic>? body]) async {
    await svc.connect(body ?? _body());
    await time.advanceSeconds(6);
  }

  /// A service whose Sentinel runs on [time]; [connected] brings the (fake) core up and lets it settle, as the
  /// site detectors only report while it runs.
  Future<void> start({SystemProxyBackend? sys, SiteChecker? checker, bool connected = false, FailureWindows windows = const FailureWindows()}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    runner = _Runner();
    time = FakeTime();
    dialed.clear();
    startTries = 1;
    tunDial = (h, p, t) async => throw const SocketException('no TUN in tests');
    svc = CoreService(
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      tunCheckConnect: (h, p, t) {
        dialed.add('$h:$p');
        if (startTries > 0) {
          startTries--;
          return dialThroughResponder(h, p, t);
        }
        return tunDial(h, p, t);
      },
      windows: windows,
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _NoisyRunner(),
      sysProxy: sys ?? NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      // never the real check-host.net: a checker whose every request fails
      siteChecker: checker ?? SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    if (connected) await up();
  }

  /// Lets the Sentinel finish what it is judging (windows of the site detectors are zero).
  Future<void> settle() => time.advance(Duration.zero);

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  test('version: a known sing-box version (libbox on Android) is reported without running a binary', () async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    svc = CoreService(
      singBox: 'does-not-exist',
      resolveAddresses: false, // hermetic: no real DoH
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      knownSingBoxVersion: '1.12.0',
    );
    expect((await svc.version())['singBox'], '1.12.0');
  });

  test('connect / disconnect push the status, the journal and the log on their streams', () async {
    await start();
    final statuses = <Map<String, dynamic>>[], events = <Map<String, dynamic>>[], lines = <Map<String, dynamic>>[];
    final subs = [
      svc.statusChanges.listen(statuses.add),
      svc.eventStream.listen(events.add),
      svc.logStream.listen(lines.add),
    ];
    final s = await svc.connect(_body());
    expect(s['connected'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses.any((s) => s['connected'] == true), isTrue);
    expect(events.map((e) => '${e['cat']}/${e['type']}'), contains('conn/connected'));
    expect(lines.any((l) => '${l['msg']}'.startsWith('Connected:')), isTrue);

    await svc.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses.last['connected'], isFalse);
    // an unchanged status is not sent twice in a row
    for (var i = 1; i < statuses.length; i++) {
      expect(statuses[i], isNot(statuses[i - 1]));
    }
    for (final s in subs) {
      await s.cancel();
    }
  });

  test('polling and streams agree: log / events since the last number', () async {
    await start();
    await svc.connect(_body());
    final log = svc.log(since: null), ev = svc.events(since: null);
    expect((log['lines'] as List).isNotEmpty, isTrue);
    expect((ev['events'] as List).map((e) => (e as Map)['type']), contains('connected'));
    expect((svc.log(since: log['next'] as int)['lines'] as List), isEmpty);
    final id = svc.postEvent({'cat': 'user', 'type': 'hello', 'level': 'info'})['id'] as int;
    expect((svc.events(since: id)['events'] as List).single['type'], 'hello');
    expect(() => svc.postEvent({'cat': 'nope', 'type': 'x', 'level': 'info'}), throwsFormatException);
    svc.clearEvents();
    expect(svc.events(since: null)['events'], isEmpty);
  });

  test('NoSystemProxy: systemProxy asked, nothing set, the warning says so', () async {
    await start();
    final s = await svc.connect(_body(sys: true));
    expect([s['connected'], s['systemProxy']], [true, false]);
    expect('${s['warning']}', contains('not available'));
    expect((svc.events(since: null)['events'] as List).any((e) => (e as Map)['type'] == 'sysProxy'), isFalse);
  });

  test('ping without servers answers done at once, as a stream', () async {
    await start();
    final lines = await svc.ping({'nodes': [], 'pairs': []}).toList();
    expect(lines, [
      {'done': true, 'network': 'up'}
    ]);
  });

  test('a ping that gets no answer says why in the raw log, with the throwaway box\'s own lines', () async {
    await start();
    final lines = await svc.ping({
      'nodes': [
        {
          'key': 's::a',
          'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
        },
      ],
      'url': 'http://127.0.0.1:9/', // nothing listens on the test inbound either
    }).toList();
    expect(lines.where((l) => l['kind'] == 'n').single['ms'], -1);
    final log = (svc.log()['lines'] as List).cast<Map>();
    expect(log.map((l) => l['msg']), contains(matches(r'^\[ping\] boom$')));
    expect(log.firstWhere((l) => '${l['msg']}'.startsWith('[ping]'))['lvl'], 'warn');
    final why = log.firstWhere((l) => '${l['msg']}'.startsWith('Ping:'));
    expect([why['src'], why['lvl']], ['core', 'warn']);
    expect('${why['msg']}', allOf(contains('1 of 1 did not answer'), contains('x connect to the test inbound')));
  });

  test('ignored sites: no site/* event for the host or a subdomain, others still get one; no reconnect', () async {
    await start(connected: true);
    AutoBlocked blocked(String dest) => AutoBlocked(route: 'A', server: 's', dest: dest, via: 'B', viaServer: 't', at: 1);
    AutoUnreachable gone(String dest) => AutoUnreachable(route: 'A', server: 's', dest: dest, tried: const [], at: 1);
    List<String> hosts() => [
          for (final e in (svc.events()['events'] as List).cast<Map>())
            if (e['cat'] == 'site') '${e['type']} ${(e['data'] as Map)['host']}',
        ];
    svc.updateSettings({'ignoredSites': ['Dead.Example.com.', 'https://other.org/x', '', 'dead.example.com']});
    expect(svc.ignoredSites.hosts, ['dead.example.com', 'other.org'], reason: 'cleaned, no repeats');
    svc.siteBlocked(blocked('dead.example.com:443'));
    svc.siteBlocked(blocked('api.dead.example.com:443'));
    svc.siteUnreachable(gone('cdn.other.org:80'));
    svc.siteBlocked(blocked('notdead.example.com:443')); // not a subdomain: a different host
    svc.siteUnreachable(gone('example.com:443'));
    await settle();
    expect(hosts(), ['blocked notdead.example.com', 'unreachable example.com']);
    svc.updateSettings({'ignoredSites': []});
    svc.siteBlocked(blocked('dead.example.com:443'));
    await settle();
    expect(hosts().last, 'blocked dead.example.com');
    expect(runner.running, isTrue, reason: 'changing the list does not touch the connection');
  });

  test('site events carry the Android package of the app as data.app (none = no key), next to data.process', () async {
    await start(connected: true);
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'a.example:443', via: 'B', viaServer: 't', at: 1, pkg: 'org.telegram.messenger'));
    svc.siteUnreachable(AutoUnreachable(route: 'A', server: 's', dest: 'b.example:443', tried: const [], at: 1, pkg: 'android'));
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'c.example:443', via: 'B', viaServer: 't', at: 1, process: r'C:\x\Discord.exe'));
    await settle();
    final data = {for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') (e['data'] as Map)['host']: e['data'] as Map};
    expect(data['a.example']!['app'], 'org.telegram.messenger');
    expect(data['b.example']!['app'], 'android');
    expect(data['c.example']!.containsKey('app'), isFalse);
    expect(data['c.example']!['process'], {'name': 'Discord.exe', 'path': r'C:\x\Discord.exe'});
  });

  test('screen off: a site/* event is marked bg at the moment it is found; screen on again: unmarked', () async {
    await start(connected: true);
    AutoBlocked blocked(String dest) => AutoBlocked(route: 'A', server: 's', dest: dest, via: 'B', viaServer: 't', at: 1);
    AutoUnreachable gone(String dest) => AutoUnreachable(route: 'A', server: 's', dest: dest, tried: const [], at: 1);
    Map<String, bool> flags() => {for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') '${(e['data'] as Map)['host']}': e['bg'] == true};
    expect(svc.screenOn, isTrue, reason: 'never reported = on');
    svc.siteBlocked(blocked('a.example:443'));
    svc.updateSettings({'screenOn': false});
    svc.siteBlocked(blocked('b.example:443'));
    svc.siteUnreachable(gone('c.example:443'));
    svc.updateSettings({'screenOn': true});
    svc.siteUnreachable(gone('d.example:443'));
    await settle();
    expect(flags(), {'a.example': false, 'b.example': true, 'c.example': true, 'd.example': false});
    expect(runner.running, isTrue, reason: 'the screen is no reason to touch the connection');
  });

  test('updateSettings {closeOnSwitch}: on by default, set live; other keys leave it', () async {
    await start();
    expect(svc.closeOnSwitch, isTrue);
    svc.updateSettings({'closeOnSwitch': false});
    expect(svc.closeOnSwitch, isFalse);
    svc.updateSettings({'screenOn': true});
    expect(svc.closeOnSwitch, isFalse);
    svc.updateSettings({'closeOnSwitch': true});
    expect(svc.closeOnSwitch, isTrue);
  });

  // check-host.net that says every node reaches the site ([opens]) or none does
  SiteChecker fakeChecker(List<Uri> asked, {required bool opens}) => SiteChecker(
        delay: (_) async {},
        get: (url, {proxyPort, timeout = Duration.zero}) async {
          asked.add(url);
          const nodes = {'a': ['de', 'Germany', 'Frankfurt'], 'b': ['fr', 'France', 'Paris'], 'c': ['nl', 'Netherlands', 'Amsterdam']};
          if (url.pathSegments.last == 'check-http') return (status: 200, body: jsonEncode({'ok': 1, 'request_id': 'r', 'nodes': nodes}));
          final one = opens ? [[1, 0.2, 'OK', '200', '1.1.1.1']] : [[0, 5.0, 'Connection timed out']];
          return (status: 200, body: jsonEncode({for (final k in nodes.keys) k: one}));
        },
      );

  AutoUnreachable gone(String dest, {bool off = false}) => AutoUnreachable(route: 'A', server: 's', dest: dest, tried: const [], at: 1, retriesOff: off);
  List<Map> siteEvents() => [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') e];
  bool notifies(Map e) => eventNotifies(null, EventRecord.fromJson(e));

  Map<String, dynamic> noCheckBody() => _body()..['plan'] = {...(_body()['plan'] as Map), 'auto': {'siteCheck': false}};
  List<String> trailCodes(Map e) => [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];

  test('a site down on every route: the checker says it opens elsewhere → confirmed, notifies, check and trail in the event; down for the checker too → unexplained, quiet', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    svc.siteUnreachable(gone('a.example:443'));
    await settle();
    var e = siteEvents().single;
    expect([e['verdict'], e['level']], ['confirmed', 'warn']);
    expect(e['rev'], 2, reason: 'the result of the checker is added after the verdict, then the root of the announcement closes');
    final check = (e['data'] as Map)['check'] as Map;
    expect([check['state'], check['ok'], check['total'], check['via']], ['opens', 3, 3, 'direct']);
    expect((check['nodes'] as List).first, containsPair('country', 'Germany'));
    expect(notifies(e), isTrue, reason: 'opens from the checker\'s nodes: notify');
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.scout', 'site.checker']));
    expect((e['why'] as Map)['code'], 'site.checker');
    expect(svc.sentinel.roots.open, isEmpty, reason: 'an announcement: Auto repeats it at its own pace');
    expect((svc.events()['updated'] as List).single['id'], e['id'], reason: 'a reader that already has the event learns of the change');
    expect(asked.map((u) => u.queryParameters['host']).whereType<String>(), ['https://a.example']);

    // the same on a checker that finds it down
    final down = <Uri>[];
    await svc.dispose();
    await tmp.delete(recursive: true);
    await start(checker: fakeChecker(down, opens: false), connected: true);
    svc.siteUnreachable(gone('b.example:443'));
    await settle();
    e = siteEvents().single;
    expect(((e['data'] as Map)['check'] as Map)['state'], 'down');
    expect([e['verdict'], e['level']], ['unexplained', 'warn']);
    expect(notifies(e), isFalse, reason: 'down everywhere: the journal only');
  });

  test('check trouble, a switched-off check: quiet, unexplained; the checker is asked also when retries are off; a partial failure (blocked) is a workaround and asks nobody', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    // check switched off in Settings → Auto mode (plan.auto.siteCheck)
    await up(noCheckBody());
    expect(svc.siteCheckOn, isFalse);
    svc.siteUnreachable(gone('off.example:443'));
    svc.siteUnreachable(gone('retries.example:443', off: true));
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'part.example:443', via: 'B', viaServer: 't', at: 1));
    await settle();
    final byHost = {for (final e in siteEvents()) '${(e['data'] as Map)['host']}': e};
    expect(((byHost['off.example']!['data'] as Map)['check'] as Map)['state'], 'off');
    expect(notifies(byHost['off.example']!), isFalse);
    expect(byHost['off.example']!['verdict'], 'unexplained');
    expect(((byHost['retries.example']!['data'] as Map)['check'] as Map)['state'], 'off', reason: 'the switch is off: not asked, whatever the retries');
    expect((byHost['part.example']!['data'] as Map).containsKey('check'), isFalse);
    expect(byHost['part.example']!['verdict'], 'workaround');
    expect(trailCodes(byHost['part.example']!), containsAllInOrder(['suspect', 'probe.same', 'probe.scout']));
    expect(asked, isEmpty, reason: 'nothing was sent to the checker');
  });

  test('retries off (only the current route was tried): the checker is asked all the same, and the event has the verdict and the check', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    svc.siteUnreachable(gone('retries.example:443', off: true));
    await settle();
    final e = siteEvents().single;
    expect(asked, isNotEmpty);
    expect(e['verdict'], 'confirmed');
    expect(((e['data'] as Map)['check'] as Map)['state'], 'opens');
    expect((e['data'] as Map)['retries'], 'off');
    expect(notifies(e), isTrue);
    final alt = (e['trail'] as List).cast<Map>().firstWhere((s) => s['code'] == 'probe.scout');
    expect((alt['params'] as Map)['reason'], 'off');
  });

  test('a checker that fails leaves the event quiet with the reason; an ignored host is never sent', () async {
    await start(connected: true); // the default test checker fails every request
    svc.updateSettings({'ignoredSites': ['secret.example']});
    svc.siteUnreachable(gone('api.secret.example:443'));
    svc.siteUnreachable(gone('open.example:443'));
    await settle();
    final e = siteEvents().single;
    final check = (e['data'] as Map)['check'] as Map;
    expect([check['state'], check['error']], ['failed', contains('no network in tests')]);
    expect(e['verdict'], 'unexplained');
    expect(notifies(e), isFalse);
  });

  test('automatic checks are cached per site: the same site again within 10 minutes is not asked again', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    for (final route in ['A', 'B']) {
      // another route: the hour of the first report does not hold it back
      svc.siteUnreachable(AutoUnreachable(route: route, server: 's', dest: 'again.example:443', tried: const [], at: 1));
      await settle();
    }
    expect(siteEvents().length, 2);
    expect(asked.where((u) => u.pathSegments.last == 'check-http').length, 1);
    expect(siteEvents().map((e) => ((e['data'] as Map)['check'] as Map)['state']), ['opens', 'opens']);
  });

  test('Auto\'s notice and the connection book\'s streak for the same host:port are one suspicion: one event, the evidence merged; another route opens it -> site/blocked', () async {
    await start(connected: true);
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'same.example:443', via: 'B', viaServer: 't', at: 1, rule: 'domain=same.example'));
    final report = FailureReport(
      key: FailureBook.siteKey('same.example', 443),
      subject: {'host': 'same.example', 'port': 443, 'outbound': 's', 'route': 'A', 'path': 'proxy'},
      data: {'host': 'same.example', 'port': 443, 'outbound': 's', 'route': 'A', 'kind': 'refused', 'count': 3, 'windowMs': 60000, 'source': 'closed'},
      bg: false,
      firstSeen: DateTime.now(),
      kind: ConnKind.refused,
    );
    final id = await svc.failures.report!(report);
    await settle();
    final events = [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site' || e['type'] == 'failing') e];
    expect(events.map((e) => '${e['cat']}/${e['type']} ${e['verdict']}'), ['site/blocked workaround'], reason: 'one suspicion, one event');
    expect([events.single['cat'], events.single['type'], events.single['verdict']], ['site', 'blocked', 'workaround']);
    final data = events.single['data'] as Map;
    expect([data['via'], data['viaServer'], data['entry'], data['dest']], ['B', 't', 'A', 'same.example:443']);
    expect(data['rule'], isNotNull);
    expect(id, isNull, reason: 'a workaround is no standing failure for the book');
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'same.example:443', via: 'B', viaServer: 't', at: 1));
    await settle();
    final again = [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site' || e['type'] == 'failing') e];
    expect(again.length, events.length, reason: 'the same site and route within the hour: the event changes in place, no second one');
    expect(((again.single['data'] as Map)['repeat'] as Map)['count'], 2);
  });

  test('a repeat of a site/* event folds into it (count, times, raw line), notifies nobody again; another route is its own event; after the ladder\'s timer the verdict again is the same event', () async {
    await start(checker: fakeChecker(<Uri>[], opens: true), connected: true);
    Map repeat(Map e) => (e['data'] as Map)['repeat'] as Map;
    svc.siteUnreachable(gone('rep.example:443'));
    await settle();
    final first = siteEvents().single;
    final id = first['id'] as int;
    final t0 = first['at'] as int, rev0 = first['rev'] as int; // the maps are live
    expect((first['data'] as Map).containsKey('repeat'), isFalse);
    final lines = (svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('rep.example')).length;
    await time.advanceSeconds(600);
    svc.siteUnreachable(gone('rep.example:443'));
    await settle();
    final e = siteEvents().single;
    expect(e['id'], id, reason: 'the same event, changed in place');
    expect(e['at'], t0, reason: 'its time stays the first one');
    expect([repeat(e)['count'], repeat(e)['firstAt'], (repeat(e)['at'] as List).length], [2, t0, 2]);
    expect(repeat(e)['lastAt'], greaterThan(t0));
    expect(e['rev'], greaterThan(rev0), reason: 'readers learn of the change by rev');
    expect(((e['data'] as Map)['check'] as Map)['state'], 'opens');
    expect((svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('rep.example')).length, greaterThan(lines), reason: 'the repeat is in Raw');
    expect((svc.events()['updated'] as List).single['id'], id);
    // another route is another event (the key is the pair); another kind (blocked) is another event too
    svc.siteUnreachable(AutoUnreachable(route: 'B', server: 's', dest: 'rep.example:443', tried: const [], at: 1));
    await settle();
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'rep.example:443', via: 'B', viaServer: 't', at: 1));
    await settle();
    expect(siteEvents().map((x) => '${x['type']} ${(x['data'] as Map)['entry']}'), ['unreachable A', 'unreachable B'],
        reason: 'a verdict is fresh for the site and route whatever its kind: no second, different event inside the window');
    expect(repeat(siteEvents().first)['count'], 3, reason: 'the blocked report is one more occurrence of the first event');
    // once the ladder's timer is over the whole check runs again and, the kind being the same, folds into the same event
    await time.advanceSeconds(3600);
    svc.siteUnreachable(gone('rep.example:443'));
    await settle();
    final all = siteEvents().where((x) => x['type'] == 'unreachable' && (x['data'] as Map)['entry'] == 'A').toList();
    expect(all.length, 1, reason: 'no hour window any more: the verdict again is the same event');
    expect(repeat(all.single)['count'], 4);
  });

  test('a site with a verdict under its timer fails again: only the event counts it (raw line, no notification), no probe and no checker; after the timer the check runs again', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    var same = 0, alt = 0;
    void again() => svc.siteFailed(AutoSiteFail(route: 'A', server: 's', tag: 's', dest: 'fresh.example:443', at: 1, rule: '', process: '', pkg: ''));
    svc
      ..probeSame = ((o, d, c) async { same++; return false; })
      ..probeScout = ((o, d, c) async { alt++; return const AltReach(tried: [], unsure: true); })
      ..probeElsewhere = ((o, d, s, c) async { alt++; return const AltReach(tried: [], unsure: true); });
    again();
    await settle();
    final id = siteEvents().single['id'] as int;
    final probed = [same, alt, asked.length];
    expect(probed.every((n) => n > 0), isTrue, reason: 'the first failure runs the whole ladder');
    final lines = (svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('fresh.example')).length;
    for (var i = 0; i < 3; i++) {
      await time.advanceSeconds(60); // inside the first step of the ladder (5 min)
      again();
      await settle();
    }
    final e = siteEvents().single;
    expect([same, alt, asked.length], probed, reason: 'the repeats probe nothing');
    expect(((e['data'] as Map)['repeat'] as Map)['count'], 4);
    expect((svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('fresh.example') && '${l['msg']}'.contains('again, ')).length, 3);
    expect((svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('fresh.example')).length, lines + 3);
    expect(e['id'], id);
    await time.advanceSeconds(3600);
    again();
    await settle();
    expect(siteEvents().single['id'], id, reason: 'after the timer the full check runs again; the same verdict folds into the event');
    expect(((siteEvents().single['data'] as Map)['repeat'] as Map)['count'], 5);
    expect(same, greaterThan(probed[0]));
  });

  test('another route opens the site: exactly one site/blocked, a workaround; the checker is asked beside the scout', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'alt.example:443', via: 'B', viaServer: 't', at: 1, rule: 'domain=alt.example'));
    await settle();
    final e = siteEvents().single;
    expect([e['type'], e['verdict'], e['level']], ['blocked', 'workaround', 'info']);
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.scout']));
    expect(asked, isNotEmpty, reason: 'the checker is asked in parallel with the scout (step 2), whatever the scout finds');
    expect(svc.sentinel.roots.open, isEmpty);
  });

  test('nothing opens the site and the checker says it opens elsewhere: a confirmed site/unreachable with the routes tried and the checker\'s answer', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    svc.siteUnreachable(AutoUnreachable(route: 'A', server: 's', dest: 'none.example:443', tried: const [(route: 'B', server: 't'), (route: 'C', server: 'u')], at: 1));
    await settle();
    final e = siteEvents().single;
    expect([e['type'], e['verdict']], ['unreachable', 'confirmed']);
    final data = e['data'] as Map;
    expect((data['tried'] as List).map((t) => (t as Map)['entry']), ['B', 'C']);
    expect((data['check'] as Map)['state'], 'opens');
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.scout', 'site.checker']));
    expect(notifies(e), isTrue);
  });

  test('a site/* report while the core is still settling waits for it (our own start is not the site\'s fault); before any connection it is let go without a record', () async {
    await start();
    svc.siteUnreachable(gone('early.example:443'));
    await settle();
    expect(siteEvents(), isEmpty, reason: 'the core is stopped: deferred');
    await svc.connect(_body());
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'wait.example:443', via: 'B', viaServer: 't', at: 1));
    await settle();
    expect(siteEvents(), isEmpty, reason: 'settling');
    await time.advanceSeconds(6);
    expect(siteEvents().single['verdict'], 'workaround');
  });

  test('«Check with checker»: the same event goes pending, then gets the result with manual: true (no notification); a bad id is a FormatException', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    await up(noCheckBody());
    svc.siteUnreachable(gone('hand.example:443'));
    await settle();
    final id = siteEvents().single['id'] as int;
    expect(asked, isEmpty);
    final states = <String>[];
    final sub = svc.eventStream.where((e) => e['id'] == id).listen((e) => states.add('${((e['data'] as Map)['check'] as Map)['state']}'));
    final r = await svc.siteCheck({'event': id});
    await Future<void>.delayed(Duration.zero); // the stream delivers a turn later
    await sub.cancel();
    expect(states, ['pending', 'opens']);
    expect((r['check'] as Map)['state'], 'opens');
    final e = siteEvents().single;
    expect(siteEvents().length, 1, reason: 'no new event');
    expect([e['id'], e['rev'], ((e['data'] as Map)['check'] as Map)['manual']], [id, 3, true]);
    expect(notifies(e), isFalse);
    expect(() => svc.siteCheck({'event': 9999}), throwsFormatException);
    final other = svc.postEvent({'cat': 'user', 'type': 'hello', 'level': 'info'})['id'];
    expect(() => svc.siteCheck({'event': other}), throwsFormatException);
  });

  Map<String, dynamic> tunBody() {
    final body = _body();
    body['plan'] = {...(body['plan'] as Map<String, dynamic>), 'mode': 'tun', 'tunStack': 'system'};
    return body;
  }

  List<Map> tunEvents(String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == 'core' && e['type'] == type) e,
      ];
  void orphans(int n) {
    for (var i = 0; i < n; i++) {
      runner.onLog!('INFO[0010] [${700 + i} 0ms] router: found package name: org.telegram.messenger.web');
      for (var k = 0; k < 8; k++) {
        runner.onLog!('INFO[0010] outbound/direct[direct]: other');
      }
    }
  }

  void tcpThroughTun() {
    runner.onLog!('INFO[0020] [5000 0ms] router: found package name: org.telegram.messenger.web');
    runner.onLog!('INFO[0020] [5001 0ms] inbound/tun[tun-in]: inbound connection from 172.19.0.1:50000');
    runner.onLog!('INFO[0020] [5001 0ms] inbound/tun[tun-in]: inbound connection to 1.1.1.1:443');
  }

  test('a TUN that takes no TCP: core/tunTcpDead from the raw log, once; the snapshots follow the connection', () async {
    await start();
    expect(svc.failuresSnapshot()['active'], isFalse);
    expect(svc.tunIngressSnapshot()['state'], 'off');

    await svc.connect(tunBody());
    expect(svc.failuresSnapshot()['active'], isTrue);
    final snap = svc.tunIngressSnapshot();
    expect([snap['state'], snap['stack']], ['ok', 'system']);

    orphans(10);
    await settle();
    expect(tunEvents('tunTcpDead'), isEmpty, reason: 'grace: the first seconds are not judged');
    await time.advanceSeconds(10);
    orphans(1);
    expect(tunEvents('tunTcpDead'), isEmpty, reason: 'the dead window has not passed since our own start settled');
    await time.advanceSeconds(11);
    final e = tunEvents('tunTcpDead').single;
    expect([e['level'], e['verdict']], ['error', 'confirmed']);
    final d = e['data'] as Map;
    expect([d['stack'], d['accepted']], ['system', 0]);
    expect(d['synSeen'], greaterThanOrEqualTo(TunIngressDetector.minUnpaired));
    expect(d['apps'], ['org.telegram.messenger.web']);
    expect(d['appCounts'], isNotEmpty, reason: 'the evidence: which apps, how many look-ups');
    expect(trailCodes(e), containsAllInOrder(['suspect', 'persist.window']));
    orphans(10);
    await settle();
    expect(tunEvents('tunTcpDead').length, 1);
    expect(svc.tunIngressSnapshot()['state'], 'dead');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNotNull, reason: 'a standing failure is a root');
    expect((svc.log()['lines'] as List).any((l) => '${(l as Map)['msg']}'.contains('TUN')), isTrue, reason: 'it is said in the journal too');

    // a TCP connection through the tunnel again: the root closes, tunTcpBack says so
    tcpThroughTun();
    await settle();
    expect(tunEvents('tunTcpBack').length, 1);
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);

    await svc.disconnect();
    expect(svc.failuresSnapshot()['active'], isFalse);
    expect(svc.tunIngressSnapshot()['state'], 'off');
  });

  test('a TUN that takes no TCP, but TCP is back inside the window: a blip of the same event, no tunTcpBack', () async {
    await start(windows: const FailureWindows(tunTcpDead: Duration(seconds: 30)));
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    orphans(10);
    await settle();
    expect(tunEvents('tunTcpDead'), isEmpty, reason: 'the window has not passed');
    await time.advanceSeconds(8);
    tcpThroughTun();
    await time.advanceSeconds(1);
    final e = tunEvents('tunTcpDead').single;
    expect([e['verdict'], e['level']], ['blip', 'info']);
    expect((e['why'] as Map)['code'], 'recovered');
    expect(trailCodes(e), containsAllInOrder(['suspect', 'blip.recovered']));
    expect(tunEvents('tunTcpBack'), isEmpty, reason: 'it never stood');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  /// The dead window of tunTcpDead passed with [n] look-ups and no TCP (as in the first TUN test).
  Future<void> deadWindowPassed() async {
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    orphans(10);
    await time.advanceSeconds(10);
    orphans(1);
    await time.advanceSeconds(11);
  }

  test('the active TUN test: the connection goes to the documentation address; it reaches the responder: a blip (no error, no tunTcpBack), the journal says it once per 15 min', () async {
    await start();
    tunDial = dialThroughResponder;
    await deadWindowPassed();
    await untilReal(() => tunEvents('tunTcpDead').isNotEmpty);
    expect(dialed, hasLength(2), reason: 'the start test and the Sentinel\'s');
    expect(dialed, everyElement('$tunCheckAddress:$tunCheckPort'));
    final e = tunEvents('tunTcpDead').single;
    expect([e['verdict'], e['level']], ['blip', 'info']);
    expect(trailCodes(e), contains(tunCheckCode));
    expect(tunEvents('tunTcpBack'), isEmpty);
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
    // the same app again within 15 minutes (TCP came back in between, so the detector judges anew): the raw log only
    final before = dialed.length;
    tcpThroughTun();
    await time.advanceSeconds(35);
    orphans(10);
    await time.advanceSeconds(10);
    orphans(1);
    await time.advanceSeconds(11);
    await untilReal(() => dialed.length > before);
    // the verdict of the second test is the raw-log line (not a fixed pause): by then the journal decision is made
    bool said() => ((svc.logBook.since(null)['lines'] as List).cast<Map>()).any((l) => '${l['msg']}'.contains('TCP passes the tunnel'));
    await untilReal(said);
    expect(said(), isTrue, reason: 'the second test ran and was let go to the raw log');
    expect(tunEvents('tunTcpDead').length, 1);
    expect((tunEvents('tunTcpDead').single['data'] as Map)['repeat'], isA<Map>().having((r) => r['count'], 'count', 2), reason: 'the repeat is counted on the earlier event');
    expect(((svc.logBook.since(null)['lines'] as List).cast<Map>()).any((l) => '${l['msg']}'.contains('again, 2 times')), isTrue);
  });

  test('the active TUN test fails: confirmed, the reason is in the trail', () async {
    await start(); // the default dial is refused
    await deadWindowPassed();
    await untilReal(() => tunEvents('tunTcpDead').isNotEmpty);
    final e = tunEvents('tunTcpDead').single;
    expect([e['verdict'], e['level']], ['confirmed', 'error']);
    final step = ((e['trail'] as List).cast<Map>()).firstWhere((t) => t['code'] == tunCheckCode);
    expect([step['outcome'], (step['params'] as Map)['reason']], ['fail', 'refused']);
  });

  bool logHas(String text) => ((svc.logBook.since(null)['lines'] as List).cast<Map>()).any((l) => '${l['msg']}'.contains(text));

  test('the TUN test at the start fails every try: dead without traffic, the Sentinel confirms by the same test; TCP arriving closes it', () async {
    await start();
    startTries = 0; // the default dial is refused
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    expect(dialed, hasLength(3), reason: 'three tries, 1 / 3 / 5 s after the start');
    expect(svc.tunIngressSnapshot()['state'], 'dead');
    expect(svc.tunIngressSnapshot()['byProbe'], isTrue);
    expect(tunEvents('tunTcpDead'), isEmpty, reason: 'a verdict only after a recheck: the window first');
    expect(logHas('the start test failed every try'), isTrue);
    await time.advanceSeconds(10);
    await untilReal(() => tunEvents('tunTcpDead').isNotEmpty);
    final e = tunEvents('tunTcpDead').single;
    expect([e['verdict'], e['level']], ['confirmed', 'error']);
    final d = e['data'] as Map;
    expect([d['probe'], d['probeReason'], d['synSeen'], d['apps']], [true, 'refused', 0, isEmpty]);
    expect(dialed, hasLength(4), reason: 'the Sentinel asked again');
    final step = ((e['trail'] as List).cast<Map>()).firstWhere((t) => t['code'] == tunCheckCode);
    expect(step['outcome'], 'fail');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNotNull);
    tcpThroughTun();
    await settle();
    expect(tunEvents('tunTcpBack').length, 1);
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  test('the TUN test at the start passes on a later try: nothing is said but the raw log', () async {
    await start();
    startTries = 0;
    var n = 0;
    tunDial = (h, p, t) => ++n < 3 ? throw const SocketException('not yet') : dialThroughResponder(h, p, t);
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    await untilReal(() => logHas('the start test passed'));
    expect(logHas('the start test failed (try 1 of 3)'), isTrue);
    expect(logHas('the start test passed (try 3'), isTrue);
    await time.advanceSeconds(30);
    expect(tunEvents('tunTcpDead'), isEmpty);
    expect(svc.tunIngressSnapshot()['state'], 'ok');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  test('the TUN test at the start failed, the Sentinel\'s second test passes: a blip with no journal entry, the raw log says it; the detector judges by the log again', () async {
    await start();
    startTries = 0;
    var n = 0;
    tunDial = (h, p, t) => ++n <= 3 ? throw const SocketException('not yet') : dialThroughResponder(h, p, t);
    await svc.connect(tunBody());
    await time.advanceSeconds(16);
    await untilReal(() => logHas('the tunnel was only late'));
    expect(tunEvents('tunTcpDead'), isEmpty);
    expect(tunEvents('tunTcpBack'), isEmpty);
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
    expect(svc.tunIngressSnapshot()['state'], 'ok');
  });

  test('the TUN test at the start failed, TCP arrives inside the window: a blip, no journal entry, no tunTcpBack', () async {
    await start();
    startTries = 0;
    await svc.connect(tunBody());
    await time.advanceSeconds(7);
    expect(svc.tunIngressSnapshot()['state'], 'dead');
    tcpThroughTun();
    await time.advanceSeconds(1);
    await time.advanceSeconds(10);
    expect(tunEvents('tunTcpDead'), isEmpty);
    expect(tunEvents('tunTcpBack'), isEmpty, reason: 'it never stood');
    expect(svc.tunIngressSnapshot()['state'], 'ok');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  test('a stop while the TUN test at the start is under way: no more tries, nothing judged', () async {
    await start();
    startTries = 0;
    await svc.connect(tunBody());
    await time.advanceSeconds(2);
    await svc.disconnect();
    await time.advanceSeconds(60);
    expect(dialed, hasLength(1));
    expect(tunEvents('tunTcpDead'), isEmpty);
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  test('look-ups that our own reject rule took are not a dead TUN: no event, the state stays ok, the log says it was let go', () async {
    await start();
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    for (var i = 0; i < TunIngressDetector.minUnpaired + 2; i++) {
      runner.onLog!('INFO[0010] [${900 + i} 0ms] router: found package name: org.telegram.messenger.web');
      runner.onLog!('DEBUG[0010] [${900 + i} 0ms] router: pre-match[0] inbound=tun-in ip_version=6 => reject(no_drop)');
      for (var k = 0; k < 8; k++) {
        runner.onLog!('INFO[0010] outbound/direct[direct]: other');
      }
    }
    await time.advanceSeconds(1);
    expect(tunEvents('tunTcpDead'), isEmpty);
    expect(svc.tunIngressSnapshot()['state'], 'ok');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
    expect((svc.log()['lines'] as List).any((l) => '${(l as Map)['msg']}'.contains('tun.tcpDead let go: self.reject')), isTrue);
  });

  test('a suspicion about the TUN still under way when the core is stopped is let go without a record', () async {
    await start(windows: const FailureWindows(tunTcpDead: Duration(seconds: 30)));
    await svc.connect(tunBody());
    await time.advanceSeconds(6);
    orphans(10);
    await time.advanceSeconds(2);
    await svc.disconnect();
    await time.advanceSeconds(60);
    expect(tunEvents('tunTcpDead'), isEmpty, reason: 'the session ended: nothing was confirmed');
    expect(svc.sentinel.roots.byKey('tun.tcpDead'), isNull);
  });

  test('adopt: a record without the selectorGroups marker (a core with urltest groups) is not taken over: stopped', () async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    time = FakeTime();
    final old = _AdoptRunner({'plan': _body()['plan'], 'tunnelPort': 1, 'probePort': 2, 'probeSecret': 'x'});
    svc = CoreService(
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      runner: old,
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
    expect(await svc.adopt({}), {'adopted': false, 'stopped': true});
    expect(old.stopped, isTrue);
    expect(old.running, isFalse);
    expect((svc.log(since: null)['lines'] as List).any((l) => '${(l as Map)['msg']}'.contains('older core')), isTrue);
  });

  test('a rule whose target is lost: rules/targetLost once, again only when it changes, rules/targetFound on recovery, a disconnect forgets', () async {
    await start();
    Map<String, dynamic> withTarget({required bool lost, String fallback = 'block'}) {
      final b = _body();
      final plan = b['plan'] as Map<String, dynamic>;
      final node = ((((plan['routes'] as List).first as Map)['main'] as Map)['nodes'] as List).first as Map;
      plan['global'] = false;
      plan['routing'] = {
        'fallback': 'main',
        'targets': {
          'src:x': lost
              ? null
              : {
                  'id': 'src:x',
                  'kind': 'unit',
                  'main': {
                    'pick': 'priority',
                    'chosen': 's::a',
                    'nodes': [node]
                  }
                }
        },
        'rules': [
          {
            'id': 'r1',
            'name': 'Video',
            'on': true,
            'action': 'proxy',
            'target': 'src:x',
            'fallback': fallback,
            if (lost) 'targetLost': 'deleted',
            'dns': 'auto',
            'groups': {
              'domain': {'not': false, 'v': {'domain_suffix': ['video.test']}},
            },
          }
        ],
      };
      return b;
    }

    List<Map> told() => [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'rules' && '${e['type']}'.startsWith('target')) e];
    await svc.connect(withTarget(lost: true));
    expect(told().map((e) => e['type']), ['targetLost']);
    expect(told().single['level'], 'warn');
    expect(told().single['data'], {'rule': 'Video', 'target': 'src:x', 'why': 'deleted', 'to': 'block'});
    expect(((await svc.status())['rulesLost'] as List).single, containsPair('rule', 'Video'));
    await svc.connect(withTarget(lost: true)); // a rebuild of the same state: nothing new to tell
    expect(told(), hasLength(1));
    await svc.connect(withTarget(lost: true, fallback: 'direct')); // where its traffic goes changed: told again
    expect(told().map((e) => e['type']), ['targetLost', 'targetLost']);
    expect((told().last['data'] as Map)['to'], 'direct');
    await svc.connect(withTarget(lost: false));
    expect(told().map((e) => e['type']), ['targetLost', 'targetLost', 'targetFound']);
    expect(told().last['data'], {'rule': 'Video', 'target': 'src:x'});
    expect(told().last['level'], 'info');
    expect((await svc.status())['rulesLost'], isEmpty);
    // a disconnect forgets: the next connect tells the loss anew
    await svc.connect(withTarget(lost: true));
    expect(told(), hasLength(4));
    await svc.disconnect();
    expect((await svc.status())['rulesLost'], isEmpty);
    await svc.connect(withTarget(lost: true));
    expect(told(), hasLength(5));
  });

  test('dispose stops the box and ends the streams', () async {
    await start();
    await svc.connect(_body());
    final status = svc.statusChanges.toList(), events = svc.eventStream.toList(), log = svc.logStream.toList();
    await svc.dispose();
    expect(runner.running, isFalse);
    await status;
    await events;
    await log; // all three completed: the streams are closed
  });
}
