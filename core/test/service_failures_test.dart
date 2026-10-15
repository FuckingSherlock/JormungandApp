// The connection and core detectors as CoreService runs them through the Sentinel (docs/failures.md →
// Перенос детекторов): `conn/failing`, `conn/offline` / `online`, `conn/lost` / `restored`, `auto/unstable`
// and the core events (`crashed`, `restartFailed`, `down`). A fake sing-box runner (no process, no API), time
// by hand (FakeTime): the Sentinel's clock, the service's clock and its waits are one.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

/// An API service that is not sing-box's: no groups, no connections (so `_startAuto` runs past its `api == null` exit).
class _Api extends SingBoxApi {
  _Api() : super(0, '');
  @override
  Map<String, String> get selected => const {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => true;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<bool> closeAllConnections() async => true;
  @override
  Stream<ClosedConnection> closedConnections() => const Stream.empty();
  @override
  void watch() {}
  @override
  Future<void> close() async {}
}

class _Runner implements BoxRunner {
  bool up = false;
  int failStarts = 0;
  /// A running core has an API service (Auto exists); off = the old harness, where `_startAuto` returns at once.
  bool withApi = false;
  final _api = _Api();
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;

  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => up && withApi ? _api : null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (failStarts > 0) {
      failStarts--;
      throw SingBoxError('boom');
    }
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}

/// [exitServer]: the route is a chain, [server] is its entry and [exitServer] its exit (dialed through the entry).
Map<String, dynamic> _body({Map<String, dynamic>? routing, String server = '127.0.0.1', bool global = true, String? exitServer}) => {
      'plan': {
        'routing': ?routing,
        'routes': [
          {
            'id': 'A',
            'kind': exitServer == null ? 'unit' : 'chain',
            if (exitServer != null)
              'entry': {
                'pick': 'priority',
                'chosen': 's::e',
                'nodes': [
                  {
                    'key': 's::e',
                    'outbound': {'type': 'shadowsocks', 'server': server, 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                  },
                ],
              },
            'main': {
              'pick': 'priority',
              'chosen': 's::a',
              'nodes': [
                {
                  'key': 's::a',
                  'outbound': {'type': 'shadowsocks', 'server': exitServer ?? server, 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
              ],
            },
          },
        ],
        'mixedPort': 2080,
        'global': global,
      },
    };

ClosedConnection _closed(
        {String dest = 'example.org:443', int down = 0, int? ms = 5000, String outbound = 'route0/s::a', String inbound = 'tun-in', String rule = '', String pkg = 'org.example.app'}) =>
    ClosedConnection(
      rule: rule,
      outbound: outbound,
      chain: [outbound, 'route0', 'proxy'],
      destination: dest,
      up: 0,
      down: down,
      pkg: pkg,
      process: '',
      network: 'tcp',
      inbound: inbound,
      durationMs: ms,
    );

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;
  var directMs = 5;

  Future<void> start(
      {FailureWindows windows = const FailureWindows(), bool connected = true, Map<String, dynamic>? routing, String server = '127.0.0.1', bool global = true, String? exitServer, bool api = false}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-sfail');
    runner = _Runner()..withApi = api;
    time = FakeTime();
    directMs = 5;
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      directProbe: (_, _) async => directMs, // hermetic: what the direct path answers (ms, -1 = silent)
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      windows: windows,
      // never the real check-host.net: a checker whose every request fails
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    if (connected) {
      await svc.connect(_body(routing: routing, server: server, global: global, exitServer: exitServer));
      await time.advanceSeconds(6); // settled: 5 s after the start
    }
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  List<String> types() => [for (final e in (svc.events()['events'] as List).cast<Map>()) '${e['cat']}/${e['type']}'];
  List<String> trailCodes(Map e) => [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];
  /// The restart goes through real file I/O: time moves by [step] while the event is awaited, the loop waits for real.
  Future<void> untilEvent(String cat, String type, {Duration step = Duration.zero}) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(step);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type, got: ${types()}');
  }

  bool quiet(Map e) => EventBook.isQuiet(e.cast<String, dynamic>());
  void fail(int n, {String dest = 'example.org:443', String pkg = 'org.example.app'}) {
    for (var i = 0; i < n; i++) {
      svc.failures.onClosed(_closed(dest: dest, pkg: pkg));
    }
  }

  void ok({String dest = 'example.org:443'}) => svc.failures.onClosed(_closed(dest: dest, down: 2000, ms: 300));

  group('conn/failing', () {
    test('a failure that goes on is confirmed after the window, with the old data and the trail of the checks', () async {
      await start();
      fail(3);
      await time.advanceSeconds(5);
      expect(events('conn', 'failing'), isEmpty, reason: 'the window (10 s) has not passed');
      await time.advanceSeconds(6);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect(e.containsKey('cause'), isFalse);
      expect((e['why'] as Map)['code'], 'conn.timeout');
      expect(e['data'], containsPair('host', 'example.org'));
      expect(e['data'], containsPair('count', 3));
      expect(e['data'], containsPair('source', 'closed'));
      expect(trailCodes(e), containsAllInOrder(['suspect', 'persist.window', 'conn.recovered', 'conn.otherRoute']));
      expect(quiet(e), isFalse);
      expect(svc.sentinel.roots.byKey('site|example.org:443'), isNotNull);
    });

    test('the probe opens the site through the same server but the app\'s connections go on failing: not a recovery, confirmed conn/failing with the probe in the trail', () async {
      await start();
      svc.probeSame = (o, d, c) async {
        fail(1); // the app's own request fails while the probe goes
        return true;
      };
      fail(3);
      await time.advanceSeconds(11);
      expect(events('site', 'unreachable'), isEmpty);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect((e['why'] as Map)['code'], 'conn.timeout');
      expect(e['data'], containsPair('count', 3));
      expect(trailCodes(e), containsAllInOrder(['suspect', 'persist.window', 'conn.recovered', 'conn.otherRoute', 'probe.same', 'probe.scout', 'site.checker']));
      final same = (e['trail'] as List).cast<Map>().firstWhere((s) => s['code'] == 'probe.same');
      expect([same['outcome'], (same['params'] as Map)['opens'], (same['params'] as Map)['appFails']], ['fail', true, true]);
      expect(quiet(e), isFalse);
    });

    test('the probe opens the site and the app\'s connections stay quiet: a recovery, a blip', () async {
      await start();
      svc.probeSame = (o, d, c) async => true;
      fail(3);
      await time.advanceSeconds(11);
      // a micro-failure is the raw log only, by design (docs/failures.md → Проверки сайтов): no journal event
      expect(events('conn', 'failing'), isEmpty);
      expect((svc.log()['lines'] as List).cast<Map>().any((l) => '${l['msg']}'.contains('micro-failure')), isTrue);
    });

    test('the network goes while probe.same runs (the failure began before): the probe is cancelled, the suspicion parked, and judged again when the network is back', () async {
      await start();
      var runs = 0;
      svc.probeSame = (o, d, c) => ++runs == 1 ? Completer<bool?>().future : Future.value(true);
      fail(3);
      await time.advanceSeconds(11);
      expect(runs, 1);
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(20);
      expect(events('conn', 'failing'), isEmpty, reason: 'parked: nothing is written while the network is gone');
      expect(runs, 1, reason: 'not started again behind the network root');
      svc.setNetwork({'connected': true, 'validated': true});
      await time.advanceSeconds(2);
      expect(runs, 2);
      expect(events('conn', 'failing'), isEmpty, reason: 'a micro-failure: the raw log only, no event');
      expect((svc.log()['lines'] as List).cast<Map>().any((l) => '${l['msg']}'.contains('micro-failure')), isTrue);
    });

    test('it worked again inside the window: a blip that says what failed and when it recovered', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      ok();
      await time.advanceSeconds(1);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect((e['why'] as Map)['code'], 'recovered');
      expect(trailCodes(e), containsAllInOrder(['suspect', 'blip.recovered']));
      final suspect = (e['trail'] as List).cast<Map>().first;
      expect(((suspect['params'] as Map)['facts'] as Map)['host'], 'example.org');
      expect(((suspect['params'] as Map)['subject'] as Map)['outbound'], 'route0/s::a');
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('it opens through another outbound already (live traffic): a workaround, quiet', () async {
      await start();
      fail(3);
      await time.advanceSeconds(1);
      // the same destination works through the other outbound
      svc.failures.onClosed(_closed(down: 2000, ms: 300, outbound: 'route1/s::b'));
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect(e['verdict'], 'workaround');
      expect(trailCodes(e), contains('conn.otherRoute'));
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('the probe inbound (Auto\'s checks of the spare routes) never makes a suspicion', () async {
      await start();
      for (var i = 0; i < 6; i++) {
        svc.failures.onClosed(_closed(inbound: 'probe-in', outbound: 'route1/s::b'));
      }
      await time.advanceSeconds(30);
      expect(events('conn', 'failing'), isEmpty);
      expect(svc.failuresSnapshot()['failed'], 0, reason: 'not even counted');
    });

    test('no network: nothing is confirmed; after the blip window the failure is a consequence of conn/offline', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(11);
      final offline = events('conn', 'offline').single;
      expect([offline['level'], offline['verdict']], ['warn', 'confirmed']);
      fail(3);
      await time.advanceSeconds(1);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['info', 'consequence']);
      expect(e['cause'], offline['id']);
      expect((e['why'] as Map)['code'], 'net.offline');
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.byKey('site|example.org:443'), isNull, reason: 'a consequence opens no root');
      expect(types().where((t) => t == 'conn/failing').length, 1);
      // the network is back: conn/online with the time
      svc.setNetwork({'connected': true, 'validated': true});
      await time.advanceSeconds(1);
      final online = events('conn', 'online').single;
      expect(online['data'], containsPair('downMs', greaterThan(10000)));
    });

    test('a move to another network while the probes say down: the root stays until the direct path answers, then conn/online once', () async {
      await start(connected: false);
      svc.pool.silent(true);
      await time.advanceSeconds(11);
      expect(events('conn', 'offline').single['verdict'], 'confirmed');
      directMs = -1;
      svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'a'});
      svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'b'}); // another network: the direct path is asked at once
      await time.advanceSeconds(1);
      expect(svc.sentinel.roots.byKind('net.offline'), isNotNull, reason: 'silent: nothing closes the root');
      expect(events('conn', 'online'), isEmpty);
      await time.advanceSeconds(10);
      expect(events('conn', 'online'), isEmpty, reason: 'asked again every noNetEvery, still silent');
      directMs = 7;
      await time.advanceSeconds(10);
      expect(svc.sentinel.roots.byKind('net.offline'), isNull);
      expect(events('conn', 'online').single['data'], containsPair('downMs', greaterThan(20000)));
    });

    test('the outage survives a reconnect: the same conn/lost event stays open, one conn/restored with the whole time', () async {
      await start();
      final t0 = time.t.millisecondsSinceEpoch;
      svc.routesLost(AutoNet(kind: 'lost', at: t0), 1);
      await time.advanceSeconds(40);
      expect(events('conn', 'lost').single['verdict'], 'confirmed');
      await svc.disconnect();
      await svc.connect(_body());
      await time.advanceSeconds(6);
      expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull, reason: 'a restart does not end it');
      expect(events('conn', 'lost').length, 1, reason: 'no new event');
      svc.routesRestored(AutoNet(kind: 'restored', at: t0 + 50000, downMs: 50000));
      await time.advanceSeconds(1);
      expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
      expect(events('conn', 'restored').single['data'], containsPair('downMs', 50000));
    });

    test('Auto starting and stopping while the network is down says nothing of it: no conn/online without a probe that answered', () async {
      await start(connected: false, api: true);
      svc.pool.silent(true);
      await time.advanceSeconds(11);
      expect(events('conn', 'offline').single['verdict'], 'confirmed');
      directMs = -1; // the direct path stays silent
      await svc.connect(_body()); // Auto starts (the API service exists)
      await time.advanceSeconds(6);
      expect(runner.api, isNotNull);
      expect(svc.sentinel.roots.byKind('net.offline'), isNotNull, reason: 'a new sing-box says nothing of the network');
      expect(events('conn', 'online'), isEmpty);
      await svc.disconnect();
      await time.advanceSeconds(30);
      expect(svc.sentinel.roots.byKind('net.offline'), isNotNull);
      expect(events('conn', 'online'), isEmpty, reason: 'the stop probed the direct path, which is silent: nothing written');
    });

    test('disconnect() while the pool is down asks the direct path: its answer closes the root (conn/online once, the real time); silence asks again every noNetEvery', () async {
      await start(connected: false, api: true);
      svc.pool.silent(true);
      await time.advanceSeconds(11);
      directMs = -1;
      await svc.connect(_body());
      await time.advanceSeconds(6);
      await svc.disconnect(); // no sing-box and no Auto from here: nobody else would ask
      await time.advanceSeconds(25);
      expect(events('conn', 'online'), isEmpty);
      expect(svc.sentinel.roots.byKind('net.offline'), isNotNull);
      directMs = 7;
      await time.advanceSeconds(10);
      expect(svc.sentinel.roots.byKind('net.offline'), isNull);
      final online = events('conn', 'online').single;
      expect(online['data'], containsPair('downMs', greaterThan(40000)));
      await time.advanceSeconds(30);
      expect(events('conn', 'online').length, 1);
    });

    test('Auto started again re-suspects an outage that never became a root (the stop came inside the window): one conn/lost, one conn/restored', () async {
      await start(connected: false, api: true);
      final t0 = time.t.millisecondsSinceEpoch;
      svc.autoMemory.lostAt = t0; // Auto's owed `lost` of the earlier session
      expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
      await svc.connect(_body());
      await time.advanceSeconds(40);
      final lost = events('conn', 'lost').single;
      expect(lost['verdict'], 'confirmed');
      expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull);
      svc.routesRestored(AutoNet(kind: 'restored', at: time.t.millisecondsSinceEpoch, downMs: 41000));
      await time.advanceSeconds(1);
      expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
      expect(events('conn', 'lost').length, 1);
      expect(events('conn', 'restored').single['data'], containsPair('downMs', 41000));
    });

    test('the network gone for a moment: conn/offline is a blip with how long, no conn/online', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(3);
      expect(events('conn', 'offline'), isEmpty, reason: 'not before the blip window');
      svc.setNetwork({'connected': true, 'validated': true});
      await time.advanceSeconds(1);
      final e = events('conn', 'offline').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect(e['data'], containsPair('downMs', greaterThanOrEqualTo(3000)));
      expect(trailCodes(e), ['ctx.net', 'blip.recovered']);
      expect(events('conn', 'online'), isEmpty);
      expect(quiet(e), isTrue);
    });

    test('a failure suspected while the core is stopped or stops meanwhile is let go: no event, no root', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      await svc.disconnect();
      await time.advanceSeconds(60);
      expect(events('conn', 'failing'), isEmpty);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('our own start: a failure seen while the core settles is judged by the window that begins at the settle', () async {
      await start(connected: false);
      await svc.connect(_body());
      fail(3); // right after the start
      await time.advanceSeconds(3);
      expect(events('conn', 'failing'), isEmpty);
      await time.advanceSeconds(20);
      final e = events('conn', 'failing').single;
      expect(e['verdict'], 'confirmed');
      expect(trailCodes(e), contains('ctx.core'));
    });

    test('after a suspicion that did not stand, the same entry is suspected again only after a pause', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      ok();
      await time.advanceSeconds(1);
      expect(events('conn', 'failing').length, 1);
      fail(3);
      await time.advanceSeconds(12);
      expect(events('conn', 'failing').length, 1, reason: 'held for ${FailureBook.recheckAfter.inSeconds} s: a flapping destination is not written every time');
      await time.advance(FailureBook.recheckAfter);
      fail(3);
      await time.advanceSeconds(12);
      expect(events('conn', 'failing').length, 2);
    });

    test('a series beyond maxEvents per 10 min is not silent: counted on the latest conn/failing (count, times), a raw line says why, no new event', () async {
      await start();
      for (var i = 0; i <= FailureBook.maxEvents; i++) {
        fail(3, dest: 'h$i.example:443', pkg: 'org.app.n$i');
      }
      await time.advanceSeconds(12);
      final all = events('conn', 'failing');
      expect(all.length, FailureBook.maxEvents, reason: 'the seventh series has no event of its own');
      final last = all.last;
      expect(((last['data'] as Map)['repeat'] as Map)['count'], 4, reason: 'its three failures are on the latest event');
      expect((((last['data'] as Map)['repeat'] as Map)['at'] as List).length, 4);
      final line = (svc.log()['lines'] as List).cast<Map>().where((l) => '${l['msg']}'.contains('beyond the limit')).toList();
      expect(line.length, 1);
      expect('${line.single['msg']}', allOf(contains('h${FailureBook.maxEvents}.example'), contains('folded onto the latest conn/failing event')));
    });
  });

  group('the DNS server a failure resolved through', () {
    final dns = {
      'dns': {
        'servers': [
          {'id': 'g', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true},
        ],
      },
    };

    test('an open dns.down root of the resolver explains the failure: a consequence with its cause, no root of its own', () async {
      await start(routing: dns);
      final root = svc.sentinel.openRoot(
        kind: 'dns.down',
        key: 'dns|g-udp1',
        subject: {'dns': 'g-udp1', 'path': 'direct'},
        scope: Scope.of({'dns': 'g-udp1'}),
        level: Level.dns,
      );
      final cause = svc.eventBook.add('dns', 'failed', 'warn', data: {'server': 'g-udp1'});
      svc.sentinel.attachEvent(root, cause);
      fail(3);
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['info', 'consequence']);
      expect(e['cause'], cause);
      expect((e['why'] as Map)['code'], 'dns.down');
      expect(svc.sentinel.roots.byKey('site|example.org:443'), isNull);
    });

    test('the host does not resolve through the same server: the failure is the resolver\'s (why dns.resolve), not the site\'s', () async {
      await start(routing: dns);
      final asked = <String>[];
      svc.dnsQuery = (tag, name, t) async {
        asked.add('$tag $name');
        return -1;
      };
      fail(3);
      await time.advanceSeconds(11);
      expect(asked, ['dns-g-udp1 example.org']);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect((e['why'] as Map)['code'], 'dns.resolve');
      expect(events('site', 'unreachable'), isEmpty);
      expect(trailCodes(e), containsAllInOrder(['conn.recovered', 'conn.otherRoute', 'dns.resolve']));
    });

    test('the host resolves: the check passes and the failure goes on as before', () async {
      await start(routing: dns);
      svc.dnsQuery = (tag, name, t) async => 12;
      fail(3);
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect((e['why'] as Map)['code'], 'conn.timeout');
      final dnsStep = (e['trail'] as List).cast<Map>().firstWhere((s) => s['code'] == 'dns.resolve');
      expect(dnsStep['outcome'], 'pass');
    });

    int openDnsRoot(String id) {
      final root = svc.sentinel.openRoot(
        kind: 'dns.down',
        key: 'dns|$id',
        subject: {'dns': id, 'path': 'direct'},
        scope: Scope.of({'dns': id}),
        level: Level.dns,
      );
      final cause = svc.eventBook.add('dns', 'failed', 'warn', data: {'server': id});
      svc.sentinel.attachEvent(root, cause);
      return cause;
    }

    test('a rule with its own DNS server: the rule kept from the closed record finds it, an open root of it explains the streak', () async {
      await start(global: false, routing: {
        'dns': {
          'servers': [
            {'id': 'g', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true},
            {'id': 'g2', 'addr': 'udp://127.0.0.1:5454', 'via': 'direct', 'on': false},
          ],
        },
        'rules': [
          {
            'id': 'r1',
            'name': 'Work',
            'action': 'proxy',
            'target': '',
            'fallback': 'default',
            'block': 'drop',
            'dns': 'g2',
            'groups': {
              'domain': {
                'not': false,
                'v': {'domain_suffix': ['example.org']},
              },
            },
          },
        ],
      });
      final cause = openDnsRoot('g2-udp1');
      for (var i = 0; i < 3; i++) {
        svc.failures.onClosed(_closed(rule: 'domain_suffix=example.org'));
      }
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict'], e['cause']], ['info', 'consequence', cause]);
      expect((e['data'] as Map)['rule'], {'kind': 'user', 'name': 'Work', 'id': 'r1'});
    });

    test('the same streak with no rule is the default resolver\'s: the rule server\'s root does not explain it', () async {
      await start(routing: dns);
      svc.dnsQuery = (tag, name, t) async => 12;
      openDnsRoot('g2-udp1');
      fail(3);
      await time.advanceSeconds(11);
      expect(events('conn', 'failing').single['verdict'], isNot('consequence'));
    });

    test('a route with a domain-named server depends on the resolver of the domain: its dead root explains auto/unstable and conn/lost', () async {
      // the user's own server is not the node resolver (the top of the system chain is the OS resolver without a built-in one)
      await start(routing: dns, server: 'node.example.com');
      final cause = openDnsRoot('system');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      final u = events('auto', 'unstable').single;
      expect([u['level'], u['verdict'], u['cause']], ['info', 'consequence', cause]);
      svc.routesLost(AutoNet(kind: 'lost', at: time.t.millisecondsSinceEpoch), 1);
      await time.advanceSeconds(1);
      final l = events('conn', 'lost').single;
      expect([l['verdict'], l['cause']], ['consequence', cause]);
    });

    test('the domain-named node is blamed on the top of the system chain (the node outbounds\' domain_resolver), not on the user\'s default resolver', () async {
      await start(server: 'node.example.com', routing: {
        'dns': {
          'servers': [
            {'id': 'g', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true},
            {'id': 'cloudflare', 'addr': '1.1.1.1', 'via': 'direct', 'on': true},
          ],
        },
      });
      openDnsRoot('g-udp1'); // the default resolver's root: the node does not go through it
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      expect(events('auto', 'unstable').last['verdict'], 'confirmed');
      final cause = openDnsRoot('cloudflare-udp1');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      final u = events('auto', 'unstable').last;
      expect([u['verdict'], u['cause']], ['consequence', cause]);
    });

    test('a route whose servers are addresses does not depend on it: the same dead root leaves auto/unstable confirmed', () async {
      await start(routing: dns);
      openDnsRoot('g-udp1');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      expect(events('auto', 'unstable').single['verdict'], 'confirmed');
    });

    test('a chain\'s exit named by a host is resolved on the entry\'s far side: the route does not depend on the node resolver', () async {
      await start(routing: dns, exitServer: 'exit.example.com'); // the entry is an address
      openDnsRoot('system');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      expect(events('auto', 'unstable').single['verdict'], 'confirmed');
    });

    test('a chain\'s entry named by a host depends on it', () async {
      await start(routing: dns, server: 'entry.example.com', exitServer: 'exit.example.com');
      final cause = openDnsRoot('system');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      final u = events('auto', 'unstable').single;
      expect([u['verdict'], u['cause']], ['consequence', cause]);
    });

    test('no direct server set: the OS resolver is the one the domain servers resolve through, under the id system', () async {
      await start(server: 'node.example.com');
      final cause = openDnsRoot('system');
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: time.t.millisecondsSinceEpoch));
      final u = events('auto', 'unstable').single;
      expect([u['verdict'], u['cause']], ['consequence', cause]);
    });
  });

  group('the core', () {
    test('crash: core/crashed is the root; the restart that fails is its consequence (cause = the crash), the one that works closes the root', () async {
      await start();
      runner.failStarts = 1;
      runner.up = false;
      runner.onExit!(9);
      await time.advance(Duration.zero);
      final crashed = events('core', 'crashed').single;
      expect([crashed['level'], crashed['verdict']], ['error', 'confirmed']);
      expect((crashed['why'] as Map)['code'], 'core.exit');
      expect(svc.sentinel.roots.byKind('core.crashed'), isNotNull);
      await time.advanceSeconds(1); // the first try fails
      await untilEvent('core', 'restartFailed');
      final failed = events('core', 'restartFailed').single;
      expect([failed['level'], failed['verdict'], failed['cause']], ['info', 'consequence', crashed['id']]);
      expect(quiet(failed), isTrue);
      await untilEvent('core', 'restarted', step: const Duration(seconds: 1)); // the second works
      expect(types(), containsAllInOrder(['core/crashed', 'core/restartFailed', 'core/restarted']));
      expect(svc.sentinel.roots.byKind('core.crashed'), isNull, reason: 'closed when sing-box is back');
      expect(events('core', 'restarted').single.containsKey('verdict'), isFalse, reason: 'a recovery, not a failure');
    });

    test('down: core/down is the event of the core.down root; a failure through the core meanwhile is its consequence', () async {
      await start();
      runner.failStarts = 99;
      runner.up = false;
      runner.onExit!(9);
      await untilEvent('core', 'down', step: const Duration(seconds: 1));
      final down = events('core', 'down').single;
      expect([down['level'], down['verdict']], ['error', 'confirmed']);
      expect(svc.sentinel.roots.byKind(rootCoreDown)!.eventId, down['id']);
      // the failure book is not fed by a dead core, but a late record still is judged against the root
      fail(3);
      await time.advanceSeconds(1);
      expect(events('conn', 'failing'), isEmpty, reason: 'the book is off while the core is down');
      final id = svc.sentinel.suspect(Suspicion(
          kind: 'conn.failing',
          key: 'conn.failing|test',
          subject: const {'host': 'example.org', 'outbound': 'route0/s::a', 'path': 'proxy'},
          window: Duration.zero,
          event: const SuspicionEvent('conn', 'failing', level: 'warn')));
      final v = await id;
      expect(v.kind, VerdictKind.consequence);
      expect(v.cause, down['id']);
      final e = events('conn', 'failing').single;
      expect([e['verdict'], e['cause']], ['consequence', down['id']]);
    });
  });

  group('conn/lost and auto/unstable', () {
    int at() => time.t.millisecondsSinceEpoch;
    AutoNet lost() => AutoNet(kind: 'lost', at: at());

    test('auto/unstable: judged and written with a verdict, and every new announcement for the route is written again', () async {
      await start();
      final u = AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: at());
      await svc.routeUnstable(u);
      var e = events('auto', 'unstable').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect((e['why'] as Map)['code'], 'route.unstable');
      expect(e['data'], containsPair('strikes', 3));
      expect(svc.sentinel.roots.open, isEmpty, reason: 'an announcement: Auto itself keeps the route on hold');
      await svc.routeUnstable(u);
      expect(events('auto', 'unstable').length, 2);
    });

    test('auto/unstable with no network is a consequence of it, not an error', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(1);
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: at()));
      final e = events('auto', 'unstable').single;
      expect([e['level'], e['verdict']], ['info', 'consequence']);
    });

    test('conn/lost that stands for the window: confirmed, a root over the proxy path; conn/restored closes it with the time', () async {
      await start();
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(5);
      expect(events('conn', 'lost'), isEmpty, reason: 'a route may answer again inside the window');
      await time.advanceSeconds(8);
      final e = events('conn', 'lost').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect(e['data'], containsPair('routes', 2));
      expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull);
      // while it stands the proxy path's failures are its consequences
      fail(3);
      await time.advanceSeconds(1);
      final f = events('conn', 'failing').single;
      expect([f['verdict'], f['cause']], ['consequence', e['id']]);
      svc.routesRestored(AutoNet(kind: 'restored', at: at(), downMs: 13000));
      final r = events('conn', 'restored').single;
      expect(r['data'], {'downMs': 13000});
      expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    });

    test('conn/lost that ends inside the window: a blip, and no conn/restored', () async {
      await start();
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(4);
      svc.routesRestored(AutoNet(kind: 'restored', at: at(), downMs: 4000));
      await time.advanceSeconds(1);
      final e = events('conn', 'lost').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect(events('conn', 'restored'), isEmpty);
    });

    test('conn/lost with the network gone is a consequence of conn/offline', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(11);
      final offline = events('conn', 'offline').single;
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(1);
      final e = events('conn', 'lost').single;
      expect([e['verdict'], e['cause']], ['consequence', offline['id']]);
      expect(quiet(e), isTrue);
    });
  });
}
