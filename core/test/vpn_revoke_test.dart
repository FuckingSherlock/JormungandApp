// «Отзыв туннеля» as CoreService does it (docs/core.md → «Отзыв туннеля», docs/logs.md → conn/disconnected): the
// system took the VPN away (runner.onRevoked). A full stop, never a recovery: no restart, no core/crashed, no
// restartFailed, one conn/disconnected warn {by: system, reason: revoked}, the open vpnDown closed by vpnUp
// {by: system}. A fake RevocableRunner, time by hand (FakeTime).
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Runner implements RevocableRunner {
  bool up = false;
  int failStarts = 0;
  int starts = 0;
  Completer<void>? gate; // start() waits for it while set
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  void Function()? onRevoked;

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
    starts++;
    final g = gate;
    if (g != null) await g.future;
    if (failStarts > 0) {
      failStarts--;
      throw SingBoxError('boom');
    }
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}

/// The same runner without the revoke signal: the crash behaviour must stay what it was.
class _PlainRunner implements BoxRunner {
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

Map<String, dynamic> _body({bool killSwitch = false}) => {
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
      if (killSwitch) 'killSwitch': true,
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late BoxRunner runner;
  late FakeTime time;
  var started = false;

  _Runner rv() => runner as _Runner;

  Future<void> start({bool connected = true, BoxRunner? custom, Map<String, dynamic>? body}) async {
    started = true;
    tmp = await Directory.systemTemp.createTemp('jorm-revoke');
    runner = custom ?? _Runner();
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
      await svc.connect(body ?? _body());
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

  Future<void> untilEvent(String cat, String type) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type, got: ${types()}');
  }

  /// The system takes the tunnel: the process is gone and the signal comes.
  void revoke() {
    rv().up = false;
    rv().onRevoked!();
  }

  void expectOneRevoked() {
    final d = events('conn', 'disconnected');
    expect(d, hasLength(1), reason: types().toString());
    expect(d.single['level'], 'warn');
    expect(d.single['data'], containsPair('by', 'system'));
    expect(d.single['data'], containsPair('reason', 'revoked'));
  }

  void expectNoCrashTraces() {
    expect(events('core', 'crashed'), isEmpty);
    expect(events('core', 'restartFailed'), isEmpty);
    expect(events('conn', 'connectFailed'), isEmpty);
  }

  test('the core subscribes to the signal of a RevocableRunner', () async {
    await start(connected: false);
    expect(rv().onRevoked, isNotNull);
  });

  test('revoked while connected: full stop, no restart over minutes, one disconnected {system, revoked}', () async {
    await start();
    final startsBefore = rv().starts;
    final before = events('conn', 'disconnected').length;
    expect((await svc.status())['connected'], isTrue);
    revoke();
    await time.advanceSeconds(1);
    var s = await svc.status();
    expect([s['connected'], s['recovering'], s['down']], [false, null, null]);
    await time.advanceSeconds(300);
    s = await svc.status();
    expect([s['connected'], s['recovering'], s['down']], [false, null, null]);
    expect(rv().starts, startsBefore, reason: 'no restart attempt');
    expect(rv().up, isFalse);
    expect(events('conn', 'disconnected'), hasLength(before + 1));
    expectOneRevoked();
    expectNoCrashTraces();
    expect(events('conn', 'vpnDown'), isEmpty);
    expect(events('conn', 'vpnUp'), isEmpty, reason: 'nothing was open');
  });

  test('a repeated signal after the stop changes nothing (late onRevoke)', () async {
    await start();
    revoke();
    await time.advanceSeconds(1);
    final n = types().length;
    revoke();
    await time.advanceSeconds(60);
    expect(types().length, n);
    expectOneRevoked();
  });

  test('revoked during the recovery after a crash with vpnDown open: vpnUp {system} then disconnected, retries stop', () async {
    await start();
    rv().failStarts = 1 << 20;
    rv().up = false;
    rv().onExit!(9);
    await untilEvent('conn', 'vpnDown');
    final down = events('conn', 'vpnDown').single;
    final startsAt = rv().starts;
    expect(events('core', 'crashed'), hasLength(1));
    rv().onRevoked!();
    await time.advanceSeconds(1);
    final up = events('conn', 'vpnUp').single;
    expect(up['opens'], down['id']);
    expect(up['data'], containsPair('by', 'system'));
    expectOneRevoked();
    expect(types().indexOf('conn/vpnUp'), lessThan(types().indexOf('conn/disconnected')));
    final s = await svc.status();
    expect([s['connected'], s['recovering'], s['down']], [false, null, null]);
    await time.advanceSeconds(300);
    expect(rv().starts, startsAt, reason: 'the recovery loop is cancelled');
    expect(events('conn', 'vpnDown'), hasLength(1));
    expect(events('conn', 'vpnUp'), hasLength(1));
    expect(events('conn', 'disconnected'), hasLength(1));
  });

  test('revoked at the start of a recovery (before vpnDown): no further attempts, only the old crash event, one disconnected', () async {
    await start();
    rv().failStarts = 1 << 20;
    rv().up = false;
    rv().onExit!(9);
    await time.advanceSeconds(2);
    rv().onRevoked!();
    await time.advanceSeconds(1);
    final startsAt = rv().starts;
    await time.advanceSeconds(300);
    expect(rv().starts, startsAt);
    expect(events('conn', 'vpnDown'), isEmpty);
    expect(events('core', 'down'), isEmpty);
    expectOneRevoked();
    expect((await svc.status())['connected'], isFalse);
  });

  test('revoked during connect: connect ends without connecting, no connectFailed, only disconnected {system}', () async {
    await start(connected: false);
    rv().gate = Completer<void>();
    Object? err;
    final done = svc.connect(_body()).then<void>((_) {}, onError: (Object e) => err = e);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rv().starts, greaterThan(0), reason: 'connect is inside runner.start');
    rv().onRevoked!();
    rv().gate!.complete();
    await done;
    await time.advanceSeconds(10);
    final s = await svc.status();
    expect(s['connected'], isFalse);
    expect(rv().up, isFalse, reason: 'a box that came up after the revoke is stopped');
    expect(events('conn', 'connectFailed'), isEmpty, reason: 'err: $err');
    expect(events('core', 'crashed'), isEmpty);
    expectOneRevoked();
    final starts = rv().starts;
    await time.advanceSeconds(300);
    expect(rv().starts, starts, reason: 'no auto-reconnect retries');
  });

  test('revoked while disconnected: nothing', () async {
    await start(connected: false);
    final n = types().length;
    rv().onRevoked!();
    await time.advanceSeconds(30);
    expect(types().length, n);
    expect(events('conn', 'disconnected'), isEmpty);
  });

  test('revoked after our own disconnect: the late signal adds nothing, the user disconnected stays the only one', () async {
    await start();
    await svc.disconnect();
    await time.advanceSeconds(1);
    final n = types().length;
    final d = events('conn', 'disconnected');
    rv().onRevoked!();
    await time.advanceSeconds(30);
    expect(types().length, n);
    expect(events('conn', 'disconnected'), hasLength(d.length));
    for (final e in events('conn', 'disconnected')) {
      expect(e['data'], isNot(containsPair('by', 'system')));
    }
  });

  test('kill switch does not keep the proxy on a revoke', () async {
    await start(body: _body(killSwitch: true));
    revoke();
    await time.advanceSeconds(1);
    final s = await svc.status();
    expect(s['connected'], isFalse);
    expect(s['blocking'], anyOf(isNull, isFalse));
    expectOneRevoked();
  });

  test('a runner without RevocableRunner: the crash behaviour is unchanged (recovery, core/crashed)', () async {
    final plain = _PlainRunner();
    await start(custom: plain);
    plain.up = false;
    plain.onExit!(9);
    await untilEvent('core', 'restarted');
    expect(events('core', 'crashed'), hasLength(1));
    expect((await svc.status())['connected'], isTrue);
    expect(events('conn', 'disconnected').where((e) => (e['data'] as Map)['by'] == 'system'), isEmpty);
  });
}
