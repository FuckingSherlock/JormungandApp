// «VPN не работает» as CoreService writes it (docs/logs.md → «VPN не работает», docs/failures.md → «Сеть»,
// «Падение ядра»): ONE `conn/vpnDown` per failure while the user is connected (causes core / network, changed in
// place), `conn/vpnUp` closes it, the crash events pour into it (`joins`), and everything warn / error written
// meanwhile without a cause becomes its consequence. A fake sing-box runner, time by hand (FakeTime).
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
    tmp = await Directory.systemTemp.createTemp('jorm-vpndown');
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
    if (!started) return; // tests that never called start() (the EventBook group) own no service
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

  Future<void> untilEvent(String cat, String type, {Duration step = const Duration(seconds: 1)}) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(step);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type, got: ${types()}');
  }

  /// sing-box dies and every restart fails until [runner.failStarts] is cleared; runs up to the vpnDown.
  Future<Map> crashUntilVpnDown() async {
    runner.failStarts = 1 << 20;
    runner.up = false;
    runner.onExit!(9);
    await untilEvent('conn', 'vpnDown');
    return events('conn', 'vpnDown').single;
  }

  Future<void> recoverCore() async {
    runner.failStarts = 0;
    await untilEvent('core', 'restarted');
    await time.advanceSeconds(1);
  }

  Future<Map> networkGone() async {
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(11);
    return events('conn', 'vpnDown').single;
  }

  Future<void> networkBack() async {
    svc.setNetwork({'connected': true, 'validated': true});
    await time.advanceSeconds(2);
  }

  test('a crash that does not recover in 30 s: one vpnDown (core) joining the crash event, core/down not written, restarted then vpnUp', () async {
    await start();
    final down = await crashUntilVpnDown();
    final crashed = events('core', 'crashed').single;
    expect([down['level'], down['verdict']], ['error', 'confirmed']);
    expect((down['why'] as Map)['code'], 'core.down');
    expect(trailCodes(down), contains('ctx.core'));
    expect(down['data'], containsPair('causes', ['core']));
    expect((down['data'] as Map).containsKey('proxy'), isTrue);
    expect(down['joins'], [crashed['id']]);
    expect(events('core', 'down'), isEmpty);
    expect(events('conn', 'offline'), isEmpty);
    expect(svc.sentinel.roots.byKind(rootCoreDown)!.eventId, down['id'], reason: 'the root is attached to the same event');
    // a few more failed tries inside do not make a second vpnDown, and the crash events stay out of the hook
    await time.advanceSeconds(70);
    expect(events('conn', 'vpnDown'), hasLength(1));
    for (final e in [...events('core', 'crashed'), ...events('core', 'restartFailed')]) {
      expect(e['cause'], isNot(down['id']), reason: 'they join through `joins`, not as consequences of vpnDown: ${e['type']}');
    }
    expect(events('conn', 'vpnUp'), isEmpty);

    await recoverCore();
    final up = events('conn', 'vpnUp').single;
    expect([up['level'], up['opens']], ['info', down['id']]);
    expect(up['data'], containsPair('causes', ['core']));
    expect(up['data'], containsPair('downMs', greaterThan(30000)));
    expect((up['data'] as Map).containsKey('by'), isFalse);
    expect(types().indexOf('core/restarted'), lessThan(types().indexOf('conn/vpnUp')));
    expect(events('conn', 'vpnDown').single['id'], down['id']);
    expect(svc.sentinel.roots.byKind(rootCoreDown), isNull);
    // the restart that closed the crash does not close the failure by itself: only vpnUp does
    expect(events('core', 'restarted').single.containsKey('verdict'), isFalse);
  });

  test('a crash restarted inside 30 s: no vpnDown, no vpnUp (the crash events are the journal only)', () async {
    await start();
    runner.failStarts = 1;
    runner.up = false;
    runner.onExit!(9);
    await untilEvent('core', 'restarted');
    await time.advanceSeconds(60);
    expect(types().where((t) => t == 'conn/vpnDown' || t == 'conn/vpnUp' || t == 'core/down'), isEmpty);
    expect(events('core', 'crashed'), hasLength(1));
  });

  test('the network gone longer than the blip window while connected: vpnDown (network), no standing conn/offline; back: vpnUp, no conn/online', () async {
    await start();
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(3);
    expect(events('conn', 'vpnDown'), isEmpty, reason: 'not before the blip window');
    await time.advanceSeconds(8);
    final down = events('conn', 'vpnDown').single;
    expect([down['level'], down['verdict']], ['warn', 'confirmed'], reason: 'network only: warn (error once core is added)');
    expect((down['why'] as Map)['code'], 'net.offline');
    expect(trailCodes(down), contains('ctx.net'));
    expect(down['data'], containsPair('causes', ['network']));
    expect(down.containsKey('joins'), isFalse, reason: 'nothing to join: no crash');
    expect(events('conn', 'offline').where((e) => e['level'] != 'info'), isEmpty);
    expect(svc.sentinel.roots.byKind('net.offline')!.eventId, down['id']);

    await networkBack();
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], down['id']);
    expect(up['data'], containsPair('causes', ['network']));
    expect(events('conn', 'online'), isEmpty);
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('a network blip shorter than the window while connected stays an info blip: no vpnDown', () async {
    await start();
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(3);
    svc.setNetwork({'connected': true, 'validated': true});
    await time.advanceSeconds(2);
    final e = events('conn', 'offline').single;
    expect([e['level'], e['verdict']], ['info', 'blip']);
    expect(events('conn', 'vpnDown'), isEmpty);
    expect(events('conn', 'vpnUp'), isEmpty);
  });

  test('the second cause is added in place (rev, no new event), one leaves while the other stands, vpnUp lists every cause of the failure', () async {
    await start();
    final first = await crashUntilVpnDown();
    final id = first['id'] as int;
    final rev0 = rev(first);
    final crashId = events('core', 'crashed').single['id'];
    await networkGone();
    var down = events('conn', 'vpnDown').single;
    expect(down['id'], id, reason: 'the same event');
    expect(rev(down), greaterThan(rev0));
    expect((down['data'] as Map)['causes'], ['core', 'network']);
    expect(down['joins'], [crashId]);
    expect(svc.sentinel.roots.byKind('net.offline')!.eventId, id, reason: 'the late root goes to the same event');
    expect(svc.sentinel.roots.byKind(rootCoreDown)!.eventId, id);
    final rev1 = rev(down);

    await networkBack(); // the network leaves, the core stands
    down = events('conn', 'vpnDown').single;
    expect((down['data'] as Map)['causes'], ['core']);
    expect(rev(down), greaterThan(rev1));
    expect(events('conn', 'vpnUp'), isEmpty, reason: 'one cause still stands');

    await recoverCore();
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], id);
    expect((up['data'] as Map)['causes'], unorderedEquals(['core', 'network']), reason: 'all causes during the failure');
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('network first, the core goes down meanwhile: the crash event is added to joins of the open vpnDown; the core leaving keeps it open', () async {
    await start();
    final first = await networkGone();
    final id = first['id'];
    expect(first.containsKey('joins'), isFalse);
    runner.failStarts = 1 << 20;
    runner.up = false;
    runner.onExit!(9);
    for (var i = 0; i < 40; i++) {
      await time.advanceSeconds(1);
    }
    final down = events('conn', 'vpnDown').single;
    expect(down['id'], id);
    expect((down['data'] as Map)['causes'], ['network', 'core']);
    expect(down['joins'], [events('core', 'crashed').single['id']]);
    expect(svc.sentinel.roots.byKind(rootCoreDown)!.eventId, id);

    await recoverCore();
    expect((events('conn', 'vpnDown').single['data'] as Map)['causes'], ['network']);
    expect(events('conn', 'vpnUp'), isEmpty);
    await networkBack();
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], id);
    expect((up['data'] as Map)['causes'], unorderedEquals(['core', 'network']));
  });

  for (final cause in ['core', 'network']) {
    test('the user disconnects during a $cause failure: vpnUp with by: user, nothing reopens it', () async {
      await start();
      final down = cause == 'core' ? await crashUntilVpnDown() : await networkGone();
      await svc.disconnect();
      await time.advanceSeconds(1);
      final up = events('conn', 'vpnUp').single;
      expect(up['opens'], down['id']);
      expect(up['data'], containsPair('by', 'user'));
      expect(up['data'], containsPair('causes', [cause]));
      expect(svc.sentinel.roots.byKind(rootCoreDown), isNull);
      await time.advanceSeconds(120);
      expect(events('conn', 'vpnDown'), hasLength(1));
      expect(events('conn', 'vpnUp'), hasLength(1));
    });
  }

  test('not connected: the network pair is conn/offline / conn/online (info), never vpnDown', () async {
    await start(connected: false);
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(11);
    final off = events('conn', 'offline').single;
    expect(off['level'], 'info', reason: 'the standing offline was warn; without a connection it is info');
    expect(events('conn', 'vpnDown'), isEmpty);
    svc.setNetwork({'connected': true, 'validated': true});
    await time.advanceSeconds(2);
    final on = events('conn', 'online').single;
    expect([on['level'], on['opens']], ['info', off['id']]);
    expect(events('conn', 'vpnDown'), isEmpty);
    expect(events('conn', 'vpnUp'), isEmpty);
  });

  test('connecting while the network is gone closes the offline pair without online and opens vpnDown (network) at once', () async {
    await start(connected: false);
    svc.pool.silent(true);
    await time.advanceSeconds(11);
    final off = events('conn', 'offline').single;
    expect(off['level'], 'info');
    expect(events('conn', 'vpnDown'), isEmpty);
    await svc.connect(_body());
    await time.advanceSeconds(12);
    final down = events('conn', 'vpnDown').single;
    expect(down['data'], containsPair('causes', ['network']));
    expect(down['joins'], contains(off['id']), reason: 'the open offline row folds into the failure');
    expect(events('conn', 'online'), isEmpty, reason: 'the pair is closed without online');
    expect(svc.sentinel.roots.byKind('net.offline')!.eventId, down['id']);
  });

  group('consequences while vpnDown is open (one hook for every writer)', () {
    int add(String cat, String type, String level, {bool own = false, int? cause, String? verdict, Map<String, dynamic> data = const {}}) =>
        svc.eventBook.add(cat, type, level, own: own, cause: cause, verdict: verdict, data: data);
    Map get(int id) => (svc.events()['events'] as List).cast<Map>().firstWhere((e) => e['id'] == id);

    test('a warn / error without a cause written by anyone becomes a consequence of vpnDown; info stays as it is', () async {
      await start();
      final down = await crashUntilVpnDown();
      for (final (cat, type, level) in [('sub', 'failed', 'warn'), ('site', 'unreachable', 'error'), ('dns', 'failed', 'warn'), ('rules', 'ruleSetFailed', 'warn')]) {
        final e = get(add(cat, type, level));
        expect([e['cause'], e['verdict']], [down['id'], 'consequence'], reason: '$cat/$type');
      }
      final info = get(add('sub', 'updated', 'info'));
      expect(info.containsKey('cause'), isFalse);
      expect(info['verdict'], isNull);
    });

    test('exceptions: own, an event that already has a cause, vpnDown / vpnUp themselves, the crash events, stateLost / stateRestored / deprecated', () async {
      await start();
      final down = await crashUntilVpnDown();
      final other = add('site', 'blocked', 'warn', data: {'host': 'x.example'});
      final own = get(add('user', 'connect', 'warn', own: true));
      expect(own.containsKey('cause'), isFalse);
      expect(get(add('sub', 'failed', 'warn', own: true)).containsKey('cause'), isFalse);
      expect(get(add('sub', 'failed', 'warn', cause: other, verdict: 'consequence'))['cause'], other, reason: 'an explicit cause is kept');
      for (final t in ['stateLost', 'stateRestored', 'deprecated']) {
        expect(get(add('core', t, 'warn')).containsKey('cause'), isFalse, reason: 'core/$t does not depend on the VPN');
      }
      for (final t in ['crashed', 'restartFailed']) {
        expect(get(add('core', t, 'error')).containsKey('cause'), isFalse, reason: 'core/$t joins through `joins`');
      }
      expect(events('conn', 'vpnDown').single['id'], down['id']);
      expect(get(down['id'] as int).containsKey('cause'), isFalse, reason: 'vpnDown is the root');
      await svc.disconnect();
      await time.advanceSeconds(1);
      expect(events('conn', 'vpnUp').single.containsKey('cause'), isFalse);
    });

    test('before the failure and after vpnUp a warn has no cause', () async {
      await start();
      final before = get(add('sub', 'failed', 'warn'));
      expect(before.containsKey('cause'), isFalse);
      await crashUntilVpnDown();
      await recoverCore();
      expect(events('conn', 'vpnUp'), hasLength(1));
      final after = get(add('sub', 'failed', 'warn'));
      expect(after.containsKey('cause'), isFalse);
      expect(after['verdict'], isNull);
    });

    test('a failure through the roots (conn/failing under a network failure) lands on the vpnDown id through attachEvent', () async {
      await start();
      final down = await networkGone();
      svc.routesLost(AutoNet(kind: 'lost', at: time.t.millisecondsSinceEpoch), 2);
      await time.advanceSeconds(1);
      final lost = events('conn', 'lost').single;
      expect([lost['verdict'], lost['cause']], ['consequence', down['id']]);
    });
  });

  group('EventBook: joins is a top-level field like opens', () {
    late Directory dir;
    late File file;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('jorm-joins');
      file = File(p.join(dir.path, 'events.jsonl'));
    });
    tearDown(() => dir.delete(recursive: true));

    test('add and update write it next to cause / opens, absent = not written, it survives a reload', () async {
      final b = EventBook(file, clock: () => DateTime(2026, 10, 17, 12));
      final crash = b.add('core', 'crashed', 'error');
      final plain = b.add('conn', 'vpnDown', 'error', data: {'causes': ['network']});
      final withJ = b.add('conn', 'vpnDown', 'error', joins: [crash], data: {'causes': ['core']});
      expect(b.byId(plain)!.containsKey('joins'), isFalse);
      expect(b.byId(withJ)!['joins'], [crash]);
      expect((b.byId(withJ)!['data'] as Map).containsKey('joins'), isFalse);
      expect(b.update(plain, joins: [crash], data: {'causes': ['network', 'core']}), isTrue);
      expect(b.byId(plain)!['joins'], [crash]);
      expect((b.byId(plain)!['data'] as Map)['causes'], ['network', 'core']);
      expect(b.byId(plain)!['rev'], 1);
      expect(b.update(plain, data: {'causes': ['core']}), isTrue);
      expect(b.byId(plain)!['joins'], [crash], reason: 'an update without joins keeps them');
      await b.flush();
      final again = EventBook(file, clock: () => DateTime(2026, 10, 17, 12));
      expect(again.byId(plain)!['joins'], [crash]);
      expect(EventRecord.fromJson(again.byId(plain)!).joins, [crash]);
      expect(EventRecord.fromJson(again.byId(crash)!).joins, isNull);
      await again.flush();
    });
  });
}
