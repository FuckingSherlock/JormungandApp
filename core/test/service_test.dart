// CoreService without HTTP: the app's direct line to the core (docs/core.md → "CoreService").
// A fake BoxRunner (the platform seam, no sing-box binary) and the system proxy seams; the
// HTTP adapter over the same logic is covered by killswitch_test / events_test / tun_test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
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

  Future<void> start({SystemProxyBackend? sys, SiteChecker? checker}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    runner = _Runner();
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _NoisyRunner(),
      sysProxy: sys ?? NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      // never the real check-host.net: a checker whose every request fails
      siteChecker: checker ?? SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  test('version: a known sing-box version (libbox on Android) is reported without running a binary', () async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    svc = CoreService(
      singBox: 'does-not-exist',
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
    await start();
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
    expect(hosts(), ['blocked notdead.example.com', 'unreachable example.com']);
    svc.updateSettings({'ignoredSites': []});
    svc.siteBlocked(blocked('dead.example.com:443'));
    expect(hosts().last, 'blocked dead.example.com');
    expect(runner.running, isFalse, reason: 'changing the list does not touch the connection');
  });

  test('site events carry the Android package of the app as data.app (none = no key), next to data.process', () async {
    await start();
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'a.example:443', via: 'B', viaServer: 't', at: 1, pkg: 'org.telegram.messenger'));
    svc.siteUnreachable(AutoUnreachable(route: 'A', server: 's', dest: 'b.example:443', tried: const [], at: 1, pkg: 'android'));
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'c.example:443', via: 'B', viaServer: 't', at: 1, process: r'C:\x\Discord.exe'));
    final data = [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') e['data'] as Map];
    expect(data[0]['app'], 'org.telegram.messenger');
    expect(data[1]['app'], 'android');
    expect(data[2].containsKey('app'), isFalse);
    expect(data[2]['process'], {'name': 'Discord.exe', 'path': r'C:\x\Discord.exe'});
  });

  test('screen off: a site/* event is marked bg at the moment it is found; screen on again: unmarked', () async {
    await start();
    AutoBlocked blocked(String dest) => AutoBlocked(route: 'A', server: 's', dest: dest, via: 'B', viaServer: 't', at: 1);
    AutoUnreachable gone(String dest) => AutoUnreachable(route: 'A', server: 's', dest: dest, tried: const [], at: 1);
    List<bool> flags() => [for (final e in (svc.events()['events'] as List).cast<Map>()) e['bg'] == true];
    expect(svc.screenOn, isTrue, reason: 'never reported = on');
    svc.siteBlocked(blocked('a.example:443'));
    svc.updateSettings({'screenOn': false});
    svc.siteBlocked(blocked('b.example:443'));
    svc.siteUnreachable(gone('c.example:443'));
    svc.updateSettings({'screenOn': true});
    svc.siteUnreachable(gone('d.example:443'));
    expect(flags(), [false, true, true, false]);
    expect(runner.running, isFalse, reason: 'the screen is no reason to touch the connection');
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

  test('a site down on every route is quiet while the checker asks, loud when it opens elsewhere, quiet when down for the checker too', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    final changed = svc.eventStream.firstWhere((e) => e['rev'] != null);
    svc.siteUnreachable(gone('a.example:443'));
    var e = siteEvents().single;
    expect((e['data'] as Map)['check']['state'], 'pending');
    expect(notifies(e), isFalse, reason: 'quiet while the check is pending');
    final id = e['id'];
    final pushed = await changed;
    expect(pushed['id'], id, reason: 'the same event, pushed again');
    e = siteEvents().single;
    expect([e['id'], e['rev']], [id, 1]);
    final check = (e['data'] as Map)['check'] as Map;
    expect([check['state'], check['ok'], check['total'], check['via']], ['opens', 3, 3, 'direct']);
    expect((check['nodes'] as List).first, containsPair('country', 'Germany'));
    expect(notifies(e), isTrue, reason: 'opens from the checker\'s nodes: notify');
    expect((svc.events()['updated'] as List).single['id'], id, reason: 'a reader that already has the event learns of the change');
    expect(asked.map((u) => u.queryParameters['host']).whereType<String>(), ['https://a.example']);

    // the same on a checker that finds it down
    final down = <Uri>[];
    await svc.dispose();
    await tmp.delete(recursive: true);
    await start(checker: fakeChecker(down, opens: false));
    final changed2 = svc.eventStream.firstWhere((e) => e['rev'] != null);
    svc.siteUnreachable(gone('b.example:443'));
    await changed2;
    e = siteEvents().single;
    expect(((e['data'] as Map)['check'] as Map)['state'], 'down');
    expect(notifies(e), isFalse, reason: 'down everywhere: the journal only');
  });

  test('check trouble, a switched-off check and retries off: only the last notifies as before; a partial failure (blocked) asks nobody', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    // check switched off in Settings → Auto mode (plan.auto.siteCheck)
    final body = _body();
    ((body['plan'] as Map)['auto'] = {'siteCheck': false});
    await svc.connect(body);
    expect(svc.siteCheckOn, isFalse);
    svc.siteUnreachable(gone('off.example:443'));
    svc.siteUnreachable(gone('retries.example:443', off: true));
    svc.siteBlocked(AutoBlocked(route: 'A', server: 's', dest: 'part.example:443', via: 'B', viaServer: 't', at: 1));
    await Future<void>.delayed(Duration.zero);
    final byHost = {for (final e in siteEvents()) '${(e['data'] as Map)['host']}': e};
    expect(((byHost['off.example']!['data'] as Map)['check'] as Map)['state'], 'off');
    expect(notifies(byHost['off.example']!), isFalse);
    expect((byHost['retries.example']!['data'] as Map).containsKey('check'), isFalse);
    expect(notifies(byHost['retries.example']!), isTrue, reason: 'only the current route was tried: as before');
    expect((byHost['part.example']!['data'] as Map).containsKey('check'), isFalse);
    expect(notifies(byHost['part.example']!), isTrue);
    expect(asked, isEmpty, reason: 'nothing was sent to the checker');
  });

  test('a checker that fails leaves the event quiet with the reason; an ignored host is never sent', () async {
    await start(); // the default test checker fails every request
    svc.updateSettings({'ignoredSites': ['secret.example']});
    final changed = svc.eventStream.firstWhere((e) => e['rev'] != null);
    svc.siteUnreachable(gone('api.secret.example:443'));
    svc.siteUnreachable(gone('open.example:443'));
    await changed;
    final e = siteEvents().single;
    final check = (e['data'] as Map)['check'] as Map;
    expect([check['state'], check['error']], ['failed', contains('no network in tests')]);
    expect(notifies(e), isFalse);
  });

  test('automatic checks are cached per site: the same site again within 10 minutes is not asked again', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    for (var i = 0; i < 2; i++) {
      final changed = svc.eventStream.firstWhere((e) => e['rev'] != null && e['rev'] == 1 && e['id'] == siteEvents().last['id']);
      svc.siteUnreachable(gone('again.example:443'));
      await changed;
    }
    expect(siteEvents().length, 2);
    expect(asked.where((u) => u.pathSegments.last == 'check-http').length, 1);
    expect(siteEvents().map((e) => ((e['data'] as Map)['check'] as Map)['state']), ['opens', 'opens']);
  });

  test('«Check with checker»: the same event goes pending, then gets the result with manual: true (no notification); a bad id is a FormatException', () async {
    final asked = <Uri>[];
    await start(checker: fakeChecker(asked, opens: true));
    await svc.connect(_body()..['plan'] = {...(_body()['plan'] as Map), 'auto': {'siteCheck': false}});
    svc.siteUnreachable(gone('hand.example:443'));
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
    expect([e['id'], e['rev'], ((e['data'] as Map)['check'] as Map)['manual']], [id, 2, true]);
    expect(notifies(e), isFalse);
    expect(() => svc.siteCheck({'event': 9999}), throwsFormatException);
    final other = svc.postEvent({'cat': 'user', 'type': 'hello', 'level': 'info'})['id'];
    expect(() => svc.siteCheck({'event': other}), throwsFormatException);
  });

  test('a TUN that takes no TCP: core/tunTcpDead from the raw log, once; the snapshots follow the connection', () async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    runner = _Runner();
    var t = DateTime.utc(2026, 10, 10, 12);
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _NoisyRunner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      isElevated: () => true,
      now: () => t,
    );
    await svc.init();
    expect(svc.failuresSnapshot()['active'], isFalse);
    expect(svc.tunIngressSnapshot()['state'], 'off');

    final body = _body();
    body['plan'] = {...(body['plan'] as Map<String, dynamic>), 'mode': 'tun', 'tunStack': 'system'};
    await svc.connect(body);
    expect(svc.failuresSnapshot()['active'], isTrue);
    final snap = svc.tunIngressSnapshot();
    expect([snap['state'], snap['stack']], ['ok', 'system']);

    List<Map> dead() => [
          for (final e in (svc.events()['events'] as List).cast<Map>())
            if (e['cat'] == 'core' && e['type'] == 'tunTcpDead') e,
        ];
    void orphans(int n) {
      for (var i = 0; i < n; i++) {
        runner.onLog!('INFO[0010] [${700 + i} 0ms] router: found package name: org.telegram.messenger.web');
        for (var k = 0; k < 8; k++) {
          runner.onLog!('INFO[0010] outbound/direct[direct]: other');
        }
      }
    }

    orphans(10);
    expect(dead(), isEmpty, reason: 'grace: the first seconds are not judged');
    t = t.add(const Duration(seconds: 10));
    orphans(1);
    final e = dead().single;
    expect(e['level'], 'error');
    final d = e['data'] as Map;
    expect([d['stack'], d['accepted']], ['system', 0]);
    expect(d['synSeen'], greaterThanOrEqualTo(TunIngressDetector.minUnpaired));
    expect(d['apps'], ['org.telegram.messenger.web']);
    orphans(10);
    expect(dead().length, 1);
    expect(svc.tunIngressSnapshot()['state'], 'dead');
    expect((svc.log()['lines'] as List).any((l) => '${(l as Map)['msg']}'.contains('TUN')), isTrue, reason: 'it is said in the journal too');

    await svc.disconnect();
    expect(svc.failuresSnapshot()['active'], isFalse);
    expect(svc.tunIngressSnapshot()['state'], 'off');
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
