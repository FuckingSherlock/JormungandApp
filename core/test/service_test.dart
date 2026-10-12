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
    probeAlt = (d, r, c) async => _alts[this]![d] ?? const AltReach(unsure: true);
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
    tunDial = (h, p, t) async => throw const SocketException('no TUN in tests');
    svc = CoreService(
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      tunCheckConnect: (h, p, t) {
        dialed.add('$h:$p');
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
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.alt', 'site.checker']));
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
    expect(trailCodes(byHost['part.example']!), containsAllInOrder(['suspect', 'probe.same', 'probe.alt']));
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
    final alt = (e['trail'] as List).cast<Map>().firstWhere((s) => s['code'] == 'probe.alt');
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
    expect(again.length, events.length, reason: 'the hour per site and route: not written again');
  });

  test('another route opens the site: exactly one site/blocked, a workaround; the checker is not asked', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true), connected: true);
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'alt.example:443', via: 'B', viaServer: 't', at: 1, rule: 'domain=alt.example'));
    await settle();
    final e = siteEvents().single;
    expect([e['type'], e['verdict'], e['level']], ['blocked', 'workaround', 'info']);
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.alt']));
    expect(asked, isEmpty);
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
    expect(trailCodes(e), containsAllInOrder(['suspect', 'probe.same', 'probe.alt', 'site.checker']));
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
    expect(dialed, [contains('$tunCheckAddress:$tunCheckPort')]);
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
