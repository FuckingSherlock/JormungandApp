// The third cause of «VPN не работает»: `routes` — no route answers (Sentinel root `conn.lost`, verdict confirmed),
// docs/logs.md → «„VPN не работает“», docs/failures.md (conn.lost root). It is a cause of the ONE `conn/vpnDown` /
// `vpnUp` pair; `conn/lost` / `conn/restored` are never written by the core any more. A fake sing-box runner, time
// by hand (FakeTime), the route silence is fed straight into CoreService.routesLost / routesRestored (what Auto's
// net events do).
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Runner implements BoxRunner {
  bool up = false;
  int failStarts = 0;
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

Map<String, dynamic> _body() => {
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
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;
  var started = false;

  Future<void> start({bool connected = true}) async {
    started = true;
    tmp = await Directory.systemTemp.createTemp('jorm-vpnroutes');
    runner = _Runner();
    time = FakeTime();
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false,
      directProbe: (_, _) async => 5,
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    if (connected) {
      await svc.connect(_body());
      await time.advanceSeconds(6);
    }
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await svc.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  List<String> types() => [for (final e in (svc.events()['events'] as List).cast<Map>()) '${e['cat']}/${e['type']}'];
  List<String> trailCodes(Map e) => [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];
  int rev(Map e) => (e['rev'] as int?) ?? 0;
  Map downOf() => events('conn', 'vpnDown').single;
  List causesOf(Map e) => (e['data'] as Map)['causes'] as List;
  void expectNoOldPair() {
    expect(events('conn', 'lost'), isEmpty, reason: 'conn/lost is never written any more');
    expect(events('conn', 'restored'), isEmpty, reason: 'conn/restored is never written any more');
  }

  Future<void> untilEvent(String cat, String type) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type, got: ${types()}');
  }

  void silent([int routes = 2]) => svc.routesLost(AutoNet(kind: 'lost', at: time.t.millisecondsSinceEpoch), routes);
  Future<void> answers({int downMs = 20000}) async {
    svc.routesRestored(AutoNet(kind: 'restored', at: time.t.millisecondsSinceEpoch, downMs: downMs));
    await time.advanceSeconds(1);
  }

  /// Routes silent past the connLost window: runs up to the confirmed vpnDown.
  Future<Map> routesDown([int routes = 2]) async {
    silent(routes);
    await time.advanceSeconds(5);
    expect(events('conn', 'vpnDown'), isEmpty, reason: 'a route may answer again inside the window');
    await time.advanceSeconds(10);
    return downOf();
  }

  Future<Map> crashUntilVpnDown() async {
    runner.failStarts = 1 << 20;
    runner.up = false;
    runner.onExit!(9);
    await untilEvent('conn', 'vpnDown');
    return downOf();
  }

  Future<void> recoverCore() async {
    runner.failStarts = 0;
    await untilEvent('core', 'restarted');
    await time.advanceSeconds(1);
  }

  Future<void> networkGone() async {
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(11);
  }

  Future<void> networkBack() async {
    svc.setNetwork({'connected': true, 'validated': true});
    await time.advanceSeconds(2);
  }

  test('no route answers past the window while connected: ONE vpnDown (routes, error, routes.silent) with data.routes, root attached; answers: vpnUp opens it, no conn/restored', () async {
    await start();
    final down = await routesDown(3);
    expect([down['level'], down['verdict']], ['error', 'confirmed']);
    expect((down['why'] as Map)['code'], 'routes.silent');
    expect(trailCodes(down), isNotEmpty);
    expect(down['data'], containsPair('causes', ['routes']));
    expect(down['data'], containsPair('routes', 3));
    expect(down.containsKey('joins'), isFalse);
    expectNoOldPair();
    expect(svc.sentinel.roots.byKey('conn.lost')!.eventId, down['id'], reason: 'the root gets the vpnDown event (attachEvent)');

    // a failure through the root is a consequence of vpnDown
    final v = await svc.sentinel.suspect(Suspicion(
        kind: 'conn.failing',
        key: 'conn.failing|test',
        subject: const {'host': 'example.org', 'outbound': 'route0/s::a', 'path': 'proxy'},
        window: Duration.zero,
        event: const SuspicionEvent('conn', 'failing', level: 'warn')));
    expect(v.kind, VerdictKind.consequence);
    expect(v.cause, down['id']);

    await time.advanceSeconds(60);
    expect(events('conn', 'vpnDown'), hasLength(1), reason: 'one event per failure');
    expect(events('conn', 'vpnUp'), isEmpty);

    await answers(downMs: 75000);
    final up = events('conn', 'vpnUp').single;
    expect([up['level'], up['opens']], ['info', down['id']]);
    expect(up['data'], containsPair('causes', ['routes']));
    expect(up['data'], containsPair('downMs', greaterThan(10000)));
    expect((up['data'] as Map).containsKey('by'), isFalse);
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    expectNoOldPair();
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('a blip (routes answer inside the window): nothing in the journal, no cause, no root', () async {
    await start();
    silent();
    await time.advanceSeconds(4);
    await answers(downMs: 4000);
    await time.advanceSeconds(30);
    expect(types().where((t) => t.startsWith('conn/') && t != 'conn/connected'), isEmpty, reason: 'Raw / trail only: ${types()}');
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
  });

  test('silence while the core is down is its consequence: no routes cause, no conn/lost, no root; the core leaving closes with [core]', () async {
    await start();
    final first = await crashUntilVpnDown();
    final rev0 = rev(first);
    silent();
    await time.advanceSeconds(20);
    final down = downOf();
    expect(causesOf(down), ['core']);
    expect(rev(down), rev0, reason: 'nothing changed in the event');
    expectNoOldPair();
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull, reason: 'a consequence opens no root');
    await recoverCore();
    expect(events('conn', 'vpnUp').single['data'], containsPair('causes', ['core']), reason: 'routes never became a cause');
    await time.advanceSeconds(30);
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('silence while the network is gone is its consequence: no routes cause; when the network returns routes do not appear', () async {
    await start();
    await networkGone();
    final first = downOf();
    silent();
    await time.advanceSeconds(20);
    expect(causesOf(downOf()), ['network']);
    expect(rev(downOf()), rev(first));
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    expectNoOldPair();
    await networkBack();
    final up = events('conn', 'vpnUp').single;
    expect(up['data'], containsPair('causes', ['network']), reason: 'the consequence never stood as a root');
    await time.advanceSeconds(30);
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('routes stand, the network goes: routes STAY beside network (no flip), error, same event; the network returns: routes alone; no vpnUp between', () async {
    await start();
    final first = await routesDown(2);
    final id = first['id'];
    final rev0 = rev(first);
    await networkGone();
    var down = downOf();
    expect(down['id'], id, reason: 'the same event');
    expect(causesOf(down), ['routes', 'network'], reason: 'order of appearance, routes does not leave');
    expect(down['level'], 'error', reason: 'routes is a cause: not just waiting');
    expect(rev(down), greaterThan(rev0));
    expect(down['data'], containsPair('routes', 2));
    expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull, reason: 'the root stays');
    expect(events('conn', 'vpnUp'), isEmpty);
    final rev1 = rev(down);

    await networkBack();
    down = downOf();
    expect(down['id'], id);
    expect(causesOf(down), ['routes']);
    expect(down['level'], 'error');
    expect(down['data'], containsPair('routes', 2));
    expect(rev(down), greaterThan(rev1));
    expect(events('conn', 'vpnUp'), isEmpty, reason: 'the failure never ended');
    expect(events('conn', 'vpnDown'), hasLength(1));

    await answers();
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], id);
    expect(causesOf(up), unorderedEquals(['routes', 'network']), reason: 'all causes of the failure');
    expectNoOldPair();
  });

  test('routes answer while the network is still out: routes leave, causes [network], warn (waiting); the event stays open', () async {
    await start();
    await routesDown(2);
    await networkGone();
    await answers();
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull, reason: 'recovered');
    expect(events('conn', 'vpnUp'), isEmpty, reason: 'the network still stands');
    expect(causesOf(downOf()), ['network']);
    expect(downOf()['level'], 'warn');
    expect((downOf()['data'] as Map).containsKey('routes'), isFalse, reason: 'data.routes only while routes is a cause');
    await networkBack();
    expect(causesOf(downOf()), ['network'], reason: 'routes do not come back after the answer');
    final up = events('conn', 'vpnUp').single;
    expect(causesOf(up), unorderedEquals(['routes', 'network']));
    expectNoOldPair();
  });

  test('routes and core together: both causes in order of appearance, error; one leaves, the event stays open; the last closes with both', () async {
    await start();
    final first = await routesDown(2);
    final id = first['id'];
    runner.failStarts = 1 << 20;
    runner.up = false;
    runner.onExit!(9);
    for (var i = 0; i < 40; i++) {
      await time.advanceSeconds(1);
    }
    var down = downOf();
    expect(down['id'], id);
    expect(causesOf(down), ['routes', 'core']);
    expect(down['level'], 'error');
    expect(down['joins'], [events('core', 'crashed').single['id']]);
    expect(svc.sentinel.roots.byKey('conn.lost')!.eventId, id);
    expect(svc.sentinel.roots.byKey(rootCoreDown)!.eventId, id);

    await recoverCore();
    down = downOf();
    expect(causesOf(down), ['routes']);
    expect(down['level'], 'error', reason: 'routes alone is not waiting: error');
    expect(events('conn', 'vpnUp'), isEmpty);

    await answers();
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], id);
    expect(causesOf(up), unorderedEquals(['routes', 'core']));
    expect(events('conn', 'vpnDown'), hasLength(1));
    expectNoOldPair();
  });

  test('the core restarts inside 30 s while routes stand: routes stay, the same event, no new one', () async {
    await start();
    final first = await routesDown(2);
    runner.failStarts = 1;
    runner.up = false;
    runner.onExit!(9);
    await untilEvent('core', 'restarted');
    await time.advanceSeconds(60);
    final down = downOf();
    expect(down['id'], first['id']);
    expect(causesOf(down), ['routes']);
    expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull, reason: 'the root is not session-scoped');
    expect(events('conn', 'vpnUp'), isEmpty);
    expectNoOldPair();
    await answers();
    expect(events('conn', 'vpnUp').single['opens'], first['id']);
  });

  test('the user disconnects during a routes failure: vpnUp by user, the root closed without an event; the next connection starts counting anew', () async {
    await start();
    final first = await routesDown(2);
    await svc.disconnect();
    await time.advanceSeconds(1);
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], first['id']);
    expect(up['data'], containsPair('by', 'user'));
    expect(causesOf(up), ['routes']);
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    await time.advanceSeconds(120);
    expect(events('conn', 'vpnDown'), hasLength(1));
    expect(events('conn', 'vpnUp'), hasLength(1));
    expectNoOldPair();

    await svc.connect(_body());
    await time.advanceSeconds(60);
    expect(events('conn', 'vpnDown'), hasLength(1), reason: 'the old silence is not carried over');
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    // a new silence is a new failure
    silent(1);
    await time.advanceSeconds(15);
    final second = events('conn', 'vpnDown').last;
    expect(second['id'], isNot(first['id']));
    expect(events('conn', 'vpnDown'), hasLength(2));
    expect(second['data'], containsPair('routes', 1));
  });

  test('not connected: route silence and answers write nothing and open no root', () async {
    await start(connected: false);
    silent();
    await time.advanceSeconds(40);
    expect(types().where((t) => t.startsWith('conn/')), isEmpty, reason: types().toString());
    expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    await answers();
    await time.advanceSeconds(10);
    expect(types().where((t) => t.startsWith('conn/')), isEmpty, reason: types().toString());
  });
}
