// Kill switch and the invisible restart of sing-box (docs/core.md → "Падение sing-box",
// "Kill switch"): the daemon over a fake sing-box process, a fake system proxy and fake
// timers, so nothing is waited for and neither the registry nor a real sing-box is touched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The system proxy as the daemon sees it, without the registry: records the calls.
class _FakeSys extends SystemProxy {
  _FakeSys({bool on = false})
      : _on = on,
        super(File('never-written'));
  final calls = <String>[];
  final ports = <int>[]; // what enable was asked to point at
  bool _on;

  @override
  bool get isSet => _on;

  @override
  Future<String?> enable(int port) async {
    calls.add('enable');
    ports.add(port);
    _on = true;
    return null;
  }

  @override
  Future<void> restore() async {
    if (_on) calls.add('restore');
    _on = false;
  }
}

/// sing-box that is not: starts when told to, fails while [failStarts] > 0, "crashes" on [crash].
class _FakeBox extends SingBoxProcess {
  _FakeBox() : super('none', 'none');
  bool up = false;
  int starts = 0, failStarts = 0;
  Map<String, dynamic>? config; // the last one asked for

  @override
  bool get running => up;

  @override
  int? get pid => up ? 1 : null;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    starts++;
    this.config = config;
    if (failStarts > 0) {
      failStarts--;
      throw SingBoxError('boom');
    }
    up = true;
  }

  @override
  Future<void> stop() async => up = false;

  void crash([int code = 9]) {
    up = false;
    onExit?.call(code);
  }
}

class _Timer implements Timer {
  _Timer(this.owner, this.due, this.wait, this.fire);
  final _Timers owner;
  final DateTime due;
  final Duration wait;
  final void Function() fire;

  @override
  void cancel() => owner.pending.remove(this);

  @override
  bool get isActive => owner.pending.contains(this);

  @override
  int get tick => 0;
}

/// The daemon's clock and its waits: time moves only when the test lets a wait pass.
class _Timers {
  DateTime now = DateTime(2026, 9, 29, 12);
  final pending = <_Timer>[];

  Timer make(Duration d, void Function() cb) {
    final t = _Timer(this, now.add(d), d, cb);
    pending.add(t);
    return t;
  }

  /// The wait the daemon is in (it takes a moment to get there).
  Future<Duration> waiting() async {
    await until(() => pending.isNotEmpty, 'the daemon to wait');
    pending.sort((a, b) => a.due.compareTo(b.due));
    return pending.first.wait;
  }

  /// Lets the next wait pass; its length.
  Future<Duration> tick() async {
    final d = await waiting();
    final t = pending.removeAt(0);
    if (t.due.isAfter(now)) now = t.due;
    t.fire();
    return d;
  }
}

Future<void> until(bool Function() ok, [String what = 'the condition']) async {
  for (var i = 0; i < 1000; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for $what');
}

class _Rig {
  _Rig._(this.tmp, this.sys, this.box, this.timers, this.daemon, this.api);

  final Directory tmp;
  final _FakeSys sys;
  final _FakeBox box;
  final _Timers timers;
  final Daemon daemon;
  final HttpServer api;

  static Future<_Rig> start({Directory? dir, _FakeSys? sys, _FakeBox? box, _Timers? timers}) async {
    final tmp = dir ?? await Directory.systemTemp.createTemp('jorm-kill');
    final s = sys ?? _FakeSys(), b = box ?? _FakeBox(), t = timers ?? _Timers();
    final d = Daemon(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      uiFile: 'none',
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sysProxy: s,
      process: b,
      timer: t.make,
      now: () => t.now,
    );
    await d.init();
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen(d.handle);
    return _Rig._(tmp, s, b, t, d, api);
  }

  Future<(int, Map<String, dynamic>)> raw(String method, String path, [String body = '']) async {
    final c = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:${api.port}$path'));
      req.headers.set('X-Jorm', '1');
      if (body.isNotEmpty) req.write(body);
      final res = await req.close();
      return (res.statusCode, (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>());
    } finally {
      c.close(force: true);
    }
  }

  Future<Map<String, dynamic>> call(String path, [Map<String, dynamic>? body]) async =>
      (await raw(body == null ? 'GET' : 'POST', path, body == null ? '' : jsonEncode(body))).$2;

  Future<Map<String, dynamic>> status() => call('/api/status');

  Future<Map<String, dynamic>> untilStatus(bool Function(Map<String, dynamic>) ok, [String what = 'the status']) async {
    Map<String, dynamic> s = {};
    for (var i = 0; i < 1000; i++) {
      s = await status();
      if (ok(s)) return s;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting for $what, last: $s');
  }

  Future<Map<String, dynamic>> connect({
    bool killSwitch = false,
    bool killOnDisconnect = false,
    bool killWhileClosed = false,
    String downProxy = 'remove',
    bool sysProxy = true,
    Map<String, String>? auth, // plan.mixedAuth: the user port has a password
  }) =>
      call('/api/connect', {
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
          'mixedAuth': ?auth,
          'global': true,
          'urlTest': {'url': 'http://127.0.0.1:1/'},
        },
        'systemProxy': sysProxy,
        'killSwitch': killSwitch,
        'killOnDisconnect': killOnDisconnect,
        'killWhileClosed': killWhileClosed,
        'downProxy': downProxy,
      });

  /// Crashes sing-box (every restart fails) and lets the waits pass up to "down":
  /// 1, 4, 15 s (tries), then 10 s to the 30th second since the crash.
  Future<void> crashUntilDown() async {
    box.failStarts = 1 << 20;
    box.crash();
    await untilStatus((s) => s['recovering'] != null, 'recovering');
    expect([await timers.tick(), await timers.tick(), await timers.tick(), await timers.tick()],
        [1, 4, 15, 10].map((s) => Duration(seconds: s)).toList());
    await untilStatus((s) => s['down'] != null, 'down');
  }

  Future<List<Map<String, dynamic>>> events({bool journal = true}) async => [
        for (final e in (await call('/api/events'))['events'] as List)
          if ((e as Map)['type'] != 'deprecated') e.cast<String, dynamic>(),
      ];

  Future<List<String>> types() async => [for (final e in await events()) '${e['cat']}/${e['type']}'];

  Future<void> close() async {
    await daemon.shutdown();
    await api.close(force: true);
    await tmp.delete(recursive: true);
  }
}

void main() {
  test('crash: the proxy is never released, connected stays true, waits 1/4/15/30, down after 30 s, recovery', () async {
    final r = await _Rig.start();
    try {
      var s = await r.connect(killSwitch: true);
      expect([s['connected'], s['systemProxy'], s['down'], s['blocking']], [true, true, null, null]);
      r.box.failStarts = 1 << 20;
      r.box.crash(9);
      s = await r.untilStatus((s) => s['recovering'] != null, 'recovering');
      expect([s['connected'], s['systemProxy'], s['down']], [true, true, null], reason: 'invisible: connected, proxy set');
      expect(s['recovering'], {'attempt': 1, 'code': 9, 'next': r.timers.now.add(const Duration(seconds: 1)).millisecondsSinceEpoch});

      // the tries: 1 s, 4 s, 15 s; each fails; the proxy stays
      final waits = <Duration>[];
      for (var i = 1; i <= 3; i++) {
        waits.add(await r.timers.tick());
        await until(() => r.box.starts == 1 + i, 'try $i');
        s = await r.untilStatus((s) => (s['recovering'] as Map?)?['attempt'] == i + 1, 'attempt ${i + 1}');
        expect([s['connected'], s['systemProxy'], s['down']], [true, true, null]);
      }
      expect(waits, [1, 4, 15].map((s) => Duration(seconds: s)));
      // 20 s in: the fourth wait is cut at the 30th second since the crash
      expect(await r.timers.tick(), const Duration(seconds: 10));
      s = await r.untilStatus((s) => s['down'] != null, 'down');
      expect(s['down'], {'since': r.timers.now.millisecondsSinceEpoch, 'attempt': 4, 'proxy': 'kept'});
      expect([s['connected'], s['systemProxy']], [true, true]);
      // ... then the rest of the 30 s, and every 30 s after
      expect(await r.timers.tick(), const Duration(seconds: 20));
      await until(() => r.box.starts == 5, 'try 4');
      expect(await r.timers.tick(), const Duration(seconds: 30));
      await until(() => r.box.starts == 6, 'try 5');
      expect(await r.timers.waiting(), const Duration(seconds: 30));
      expect(r.sys.calls, ['enable'], reason: 'never released');

      // back
      r.box.failStarts = 0;
      final crashAt = r.timers.now.subtract(const Duration(seconds: 80)); // 1 + 4 + 15 + 10 + 20 + 30
      expect(await r.timers.tick(), const Duration(seconds: 30));
      s = await r.untilStatus((s) => s['recovering'] == null && s['restarts'] == 1, 'recovered');
      expect([s['connected'], s['down'], s['systemProxy'], s['error']], [true, null, true, null]);
      expect(r.sys.calls, ['enable']);
      expect(r.timers.pending, isEmpty);

      final ev = await r.events();
      expect([for (final e in ev) '${e['cat']}/${e['type']}'], [
        'core/sysProxy',
        'conn/connected',
        'core/crashed',
        'core/restartFailed',
        'core/restartFailed',
        'core/restartFailed',
        'core/down',
        'core/restarted',
      ]);
      expect([ev[6]['level'], ev[6]['own'], ev[6]['data']], ['error', false, {'proxy': 'kept'}]);
      expect(ev[7]['data'], {'attempt': 6, 'downMs': r.timers.now.difference(crashAt).inMilliseconds});
      expect(ev.sublist(2).every((e) => e['own'] == false && e['log'] is int), isTrue);
    } finally {
      await r.close();
    }
  });

  group('down: what happens to the system proxy', () {
    // killSwitch, downProxy, what down.proxy says, the calls until then, the calls after recovery
    for (final c in [
      (true, 'remove', 'kept', ['enable'], ['enable']),
      (true, 'keep', 'kept', ['enable'], ['enable']),
      (false, 'keep', 'kept', ['enable'], ['enable']),
      (false, 'remove', 'removed', ['enable', 'restore'], ['enable', 'restore', 'enable']),
    ]) {
      test('killSwitch ${c.$1}, downProxy ${c.$2} → ${c.$3}', () async {
        final r = await _Rig.start();
        try {
          await r.connect(killSwitch: c.$1, downProxy: c.$2);
          r.box.failStarts = 1 << 20;
          r.box.crash();
          await r.untilStatus((s) => s['recovering'] != null);
          for (final w in [1, 4, 15]) {
            expect(await r.timers.tick(), Duration(seconds: w));
            await until(() => r.box.starts == 2 + [1, 4, 15].indexOf(w), 'try');
          }
          await r.timers.waiting();
          expect(r.sys.calls, ['enable'], reason: 'before the 30th second the proxy stays, whatever the setting');
          expect(await r.timers.tick(), const Duration(seconds: 10));
          var s = await r.untilStatus((s) => s['down'] != null, 'down');
          expect((s['down'] as Map)['proxy'], c.$3);
          expect(s['systemProxy'], c.$3 == 'kept');
          expect(s['connected'], isTrue);
          expect(r.sys.calls, c.$4);
          final down = (await r.events()).lastWhere((e) => e['type'] == 'down');
          expect(down['data'], {'proxy': c.$3});
          if (c.$3 == 'removed') {
            final off = (await r.events()).lastWhere((e) => e['type'] == 'sysProxy');
            expect([off['data'], off['level']], [{'on': false}, 'info']);
          }

          // recovery: the proxy is set again if it was off
          r.box.failStarts = 0;
          expect(await r.timers.tick(), const Duration(seconds: 20));
          s = await r.untilStatus((s) => s['recovering'] == null && s['restarts'] == 1, 'recovered');
          expect([s['down'], s['systemProxy'], s['connected']], [null, true, true]);
          expect(r.sys.calls, c.$5);
          expect((await r.events()).lastWhere((e) => e['type'] == 'restarted')['data'], {'attempt': 4, 'downMs': 50000});
        } finally {
          await r.close();
        }
      });
    }
  });

  test('POST /api/sysproxy/release while down: proxy off, down.proxy released, retries go on, recovery sets it again', () async {
    final r = await _Rig.start();
    try {
      await r.connect(killSwitch: true);
      await r.crashUntilDown();
      var s = await r.call('/api/sysproxy/release', {});
      expect([s['systemProxy'], s['connected']], [false, true]);
      expect((s['down'] as Map)['proxy'], 'released');
      expect(r.sys.calls, ['enable', 'restore']);
      final off = (await r.events()).lastWhere((e) => e['type'] == 'sysProxy');
      expect([off['data'], off['own'], off['level']], [{'on': false, 'by': 'user'}, true, 'info']);

      // still retrying
      final starts = r.box.starts;
      expect(await r.timers.tick(), const Duration(seconds: 20));
      await until(() => r.box.starts == starts + 1, 'a try after the release');
      r.box.failStarts = 0;
      expect(await r.timers.tick(), const Duration(seconds: 30));
      s = await r.untilStatus((s) => s['recovering'] == null && s['restarts'] == 1, 'recovered');
      expect([s['down'], s['systemProxy']], [null, true], reason: 'the connection is back: the proxy is set again');
      expect(r.sys.calls, ['enable', 'restore', 'enable']);
    } finally {
      await r.close();
    }
  });

  test('release before "down" (still invisible): the proxy goes, down reports released', () async {
    final r = await _Rig.start();
    try {
      await r.connect(killSwitch: true);
      r.box.failStarts = 1 << 20;
      r.box.crash();
      await r.untilStatus((s) => s['recovering'] != null);
      var s = await r.call('/api/sysproxy/release', {});
      expect([s['systemProxy'], s['down']], [false, null]);
      for (var i = 0; i < 4; i++) {
        await r.timers.tick();
      }
      s = await r.untilStatus((s) => s['down'] != null, 'down');
      expect((s['down'] as Map)['proxy'], 'released');
    } finally {
      await r.close();
    }
  });

  test('POST /api/retry: a restart now, the wait starts over; nothing to do when not restarting', () async {
    final r = await _Rig.start();
    try {
      // not restarting: no effect, an empty body is fine
      var (code, s) = await r.raw('POST', '/api/retry');
      expect([code, s['connected']], [200, false]);
      await r.connect(killSwitch: true);
      (code, s) = await r.raw('POST', '/api/retry');
      expect([code, s['connected'], r.box.starts], [200, true, 1]);

      r.box.failStarts = 1 << 20;
      r.box.crash();
      await r.untilStatus((s) => s['recovering'] != null);
      expect(await r.timers.tick(), const Duration(seconds: 1));
      await until(() => r.box.starts == 2);
      expect(await r.timers.waiting(), const Duration(seconds: 4));

      await r.call('/api/retry', {}); // no waiting for the 4 s
      await until(() => r.box.starts == 3, 'the retry');
      expect(await r.timers.waiting(), const Duration(seconds: 15), reason: 'the next wait is the regular one');
      expect(r.timers.pending, hasLength(1), reason: 'the cut wait is gone');

      r.box.failStarts = 0;
      await r.call('/api/retry', {});
      s = await r.untilStatus((s) => s['recovering'] == null && s['restarts'] == 1, 'recovered by the retry');
      expect([s['connected'], s['down'], s['systemProxy']], [true, null, true]);
      expect(r.timers.pending, isEmpty);
    } finally {
      await r.close();
    }
  });

  test('retry while down: tries at once, and the down state stays until it works', () async {
    final r = await _Rig.start();
    try {
      await r.connect(killSwitch: true);
      await r.crashUntilDown();
      final starts = r.box.starts;
      await r.call('/api/retry', {});
      await until(() => r.box.starts == starts + 1);
      var s = await r.untilStatus((s) => (s['recovering'] as Map?)?['attempt'] == 5, 'the next attempt');
      expect((s['down'] as Map)['proxy'], 'kept');
      expect(await r.timers.waiting(), const Duration(seconds: 30));
    } finally {
      await r.close();
    }
  });

  group('user disconnect', () {
    test('killSwitch + killOnDisconnect: the proxy stays, blocking; Remove releases; connect clears', () async {
      final r = await _Rig.start();
      try {
        await r.connect(killSwitch: true, killOnDisconnect: true);
        final s = await r.call('/api/disconnect', {});
        expect([s['connected'], s['systemProxy']], [false, true]);
        final b = s['blocking'] as Map;
        expect([b['reason'], b['proxy'], b['since']], ['disconnect', 'kept', r.timers.now.millisecondsSinceEpoch]);
        expect(r.sys.calls, ['enable']);
        expect((await r.events()).where((e) => e['type'] == 'sysProxy').length, 1, reason: 'no "proxy off" event');
        expect((await r.call('/api/disconnect', {}))['blocking'], b, reason: 'a second disconnect changes nothing');

        // Remove
        final rel = await r.call('/api/sysproxy/release', {});
        expect(rel['systemProxy'], isFalse);
        expect(rel['blocking'], {...b, 'proxy': 'released'});
        expect(r.sys.calls, ['enable', 'restore']);
        final off = (await r.events()).last;
        expect([off['type'], off['data'], off['own']], ['sysProxy', {'on': false, 'by': 'user'}, true]);

        // a connect ends it
        final on = await r.connect(killSwitch: true, killOnDisconnect: true);
        expect([on['connected'], on['blocking'], on['systemProxy']], [true, null, true]);
      } finally {
        await r.close();
      }
    });

    test('a connect that fails while blocked keeps the block', () async {
      final r = await _Rig.start();
      try {
        await r.connect(killSwitch: true, killOnDisconnect: true);
        await r.call('/api/disconnect', {});
        r.box.failStarts = 1;
        final (code, _) = await r.raw('POST', '/api/connect', jsonEncode({
          'plan': {
            'routes': [
              {'id': 'A', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::a', 'nodes': [{'key': 's::a', 'outbound': {'type': 'direct'}}]}},
            ],
            'global': true,
          },
          'systemProxy': true,
        }));
        expect(code, 500);
        final s = await r.status();
        expect([s['connected'], s['systemProxy'], (s['blocking'] as Map)['proxy']], [false, true, 'kept']);
      } finally {
        await r.close();
      }
    });

    for (final c in [(true, false), (false, true), (false, false)]) {
      test('killSwitch ${c.$1}, killOnDisconnect ${c.$2}: the proxy goes back as always', () async {
        final r = await _Rig.start();
        try {
          await r.connect(killSwitch: c.$1, killOnDisconnect: c.$2);
          final s = await r.call('/api/disconnect', {});
          expect([s['connected'], s['systemProxy'], s['blocking']], [false, false, null]);
          expect(r.sys.calls, ['enable', 'restore']);
        } finally {
          await r.close();
        }
      });
    }

    test('while down / recovering: retries stop, the proxy follows the rules', () async {
      final r = await _Rig.start();
      try {
        await r.connect(killSwitch: true); // no killOnDisconnect: it goes back
        await r.crashUntilDown();
        final starts = r.box.starts;
        final s = await r.call('/api/disconnect', {});
        expect([s['connected'], s['down'], s['recovering'], s['systemProxy'], s['blocking']], [false, null, null, false, null]);
        expect(r.sys.calls, ['enable', 'restore']);
        await until(() => r.timers.pending.isEmpty, 'the wait to be dropped');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect([r.timers.pending, r.box.starts], [isEmpty, starts], reason: 'no more tries');
        expect((await r.status())['recovering'], isNull);
      } finally {
        await r.close();
      }
    });

    test('while recovering with killOnDisconnect: retries stop, blocking', () async {
      final r = await _Rig.start();
      try {
        await r.connect(killSwitch: true, killOnDisconnect: true);
        r.box.failStarts = 1 << 20;
        r.box.crash();
        await r.untilStatus((s) => s['recovering'] != null);
        final s = await r.call('/api/disconnect', {});
        expect([s['connected'], s['recovering'], s['systemProxy']], [false, null, true]);
        expect((s['blocking'] as Map)['reason'], 'disconnect');
        await until(() => r.timers.pending.isEmpty, 'the wait to be dropped');
      } finally {
        await r.close();
      }
    });
  });

  group('POST /api/killswitch: changed while connected', () {
    Future<Map<String, dynamic>> set(_Rig r, Map<String, dynamic> body) => r.call('/api/killswitch', body);

    test('while down: the proxy is set / taken off at once, down.proxy follows; a release stays', () async {
      final r = await _Rig.start();
      try {
        await r.connect(); // no kill switch, downProxy remove
        await r.crashUntilDown();
        var s = await r.status();
        expect([(s['down'] as Map)['proxy'], s['systemProxy']], ['removed', false]);

        s = await set(r, {'killSwitch': true});
        expect([(s['down'] as Map)['proxy'], s['systemProxy']], ['kept', true]);
        expect(r.sys.calls, ['enable', 'restore', 'enable']);
        expect((await r.events()).last['own'], isTrue);

        s = await set(r, {'killSwitch': false, 'downProxy': 'remove'});
        expect([(s['down'] as Map)['proxy'], s['systemProxy']], ['removed', false]);
        s = await set(r, {'downProxy': 'keep'}); // the other fields stay as they were
        expect([(s['down'] as Map)['proxy'], s['systemProxy']], ['kept', true]);
        expect(r.sys.calls, ['enable', 'restore', 'enable', 'restore', 'enable']);

        s = await r.call('/api/sysproxy/release', {});
        expect((s['down'] as Map)['proxy'], 'released');
        s = await set(r, {'killSwitch': true});
        expect([(s['down'] as Map)['proxy'], s['systemProxy']], ['released', false], reason: 'the user took it off: it stays off');
      } finally {
        await r.close();
      }
    });

    test('before down: it counts for the coming down', () async {
      final r = await _Rig.start();
      try {
        await r.connect();
        final s = await set(r, {'killSwitch': true});
        expect([s['connected'], s['systemProxy'], r.box.starts], [true, true, 1], reason: 'no restart of sing-box');
        await r.crashUntilDown();
        expect((await r.status())['down']['proxy'], 'kept');
        expect(r.sys.calls, ['enable']);
      } finally {
        await r.close();
      }
    });

    test('killOnDisconnect / killWhileClosed set live count at the next disconnect / shutdown', () async {
      final r = await _Rig.start();
      await r.connect(killSwitch: true);
      await set(r, {'killOnDisconnect': true});
      expect((await r.call('/api/disconnect', {}))['blocking']['reason'], 'disconnect');
      await r.connect(killSwitch: true, killOnDisconnect: false);
      await set(r, {'killWhileClosed': true});
      await r.daemon.shutdown();
      expect(r.sys.isSet, isTrue);
      await r.api.close(force: true);
      await r.tmp.delete(recursive: true);
    });

    test('a block whose setting is turned off is lifted: the proxy goes back', () async {
      final r = await _Rig.start();
      try {
        await r.connect(killSwitch: true, killOnDisconnect: true);
        await r.call('/api/disconnect', {});
        var s = await set(r, {'killWhileClosed': true}); // not what holds this block
        expect([s['systemProxy'], (s['blocking'] as Map)['proxy']], [true, 'kept']);
        s = await set(r, {'killOnDisconnect': false});
        expect([s['systemProxy'], s['blocking'], s['connected']], [false, null, false]);
        expect(r.sys.calls, ['enable', 'restore']);
      } finally {
        await r.close();
      }
    });

    test('a block of a closed app is lifted by turning the kill switch off', () async {
      final tmp = await Directory.systemTemp.createTemp('jorm-kill');
      final sys = _FakeSys();
      final r = await _Rig.start(dir: tmp, sys: sys);
      await r.connect(killSwitch: true, killWhileClosed: true);
      await r.daemon.shutdown();
      await r.api.close(force: true);
      final r2 = await _Rig.start(dir: tmp, sys: sys, timers: r.timers);
      try {
        expect((await r2.status())['blocking']['reason'], 'closed');
        final s = await r2.call('/api/killswitch', {'killSwitch': false});
        expect([s['systemProxy'], s['blocking']], [false, null]);
      } finally {
        await r2.close();
      }
    });
  });

  group('shutdown', () {
    test('killSwitch + killWhileClosed: the proxy stays; the next start reports blocking closed; Remove ends it', () async {
      final tmp = await Directory.systemTemp.createTemp('jorm-kill');
      final sys = _FakeSys();
      final r = await _Rig.start(dir: tmp, sys: sys);
      await r.connect(killSwitch: true, killWhileClosed: true);
      await r.daemon.shutdown();
      await r.api.close(force: true);
      expect(sys.isSet, isTrue);
      expect(sys.calls, ['enable']);

      final r2 = await _Rig.start(dir: tmp, sys: sys, timers: r.timers);
      try {
        final s = await r2.status();
        expect([s['connected'], s['systemProxy']], [false, true]);
        final b = s['blocking'] as Map;
        expect([b['reason'], b['proxy'], b['since']], ['closed', 'kept', r.timers.now.millisecondsSinceEpoch]);
        expect(sys.calls, ['enable'], reason: 'not touched at start');
        final rel = await r2.call('/api/sysproxy/release', {});
        expect([rel['systemProxy'], (rel['blocking'] as Map)['proxy']], [false, 'released']);
      } finally {
        await r2.close();
      }
    });

    test('without killWhileClosed the proxy is restored, and the journal says so', () async {
      final r = await _Rig.start();
      await r.connect(killSwitch: true);
      await r.daemon.shutdown();
      expect(r.sys.isSet, isFalse);
      expect(r.sys.calls, ['enable', 'restore']);
      final last = r.daemon.events.since(null)['events'] as List;
      expect([(last.last as Map)['type'], (last.last as Map)['data'], (last.last as Map)['own']], ['sysProxy', {'on': false}, false]);
      await r.api.close(force: true);
      await r.tmp.delete(recursive: true);
    });

    test('killWhileClosed without killSwitch: restored', () async {
      final r = await _Rig.start();
      await r.connect(killWhileClosed: true);
      await r.daemon.shutdown();
      expect(r.sys.isSet, isFalse);
      await r.api.close(force: true);
      await r.tmp.delete(recursive: true);
    });

    test('a proxy left by a crash (no marker) is restored at start, as before', () async {
      final sys = _FakeSys(on: true);
      final r = await _Rig.start(sys: sys);
      try {
        final s = await r.status();
        expect([s['systemProxy'], s['blocking']], [false, null]);
        expect(sys.calls, ['restore']);
      } finally {
        await r.close();
      }
    });
  });

  // A password on the user port (plan.mixedAuth): the system proxy cannot send it, so it points at
  // sys-in, an open loopback inbound on a port picked once and kept (docs/core.md → Inbounds).
  group('password on the user port', () {
    const auth = {'user': 'jorm', 'pass': 's3cret'};
    List<Map> inbounds(_Rig r) => ((r.box.config!['inbounds']) as List).cast<Map>();
    Map? sysIn(_Rig r) => inbounds(r).where((i) => i['tag'] == 'sys-in').firstOrNull;
    Map mixedIn(_Rig r) => inbounds(r).firstWhere((i) => i['tag'] == 'mixed-in');

    test('off: one inbound, the system proxy points at the user port', () async {
      final r = await _Rig.start();
      try {
        final s = await r.connect();
        expect(mixedIn(r).containsKey('users'), isFalse);
        expect(sysIn(r), isNull);
        expect(r.sys.ports, [2080]);
        expect(s['sysPort'], isNull);
      } finally {
        await r.close();
      }
    });

    test('on: users on mixed-in, an open sys-in, the system proxy and status point at it', () async {
      final r = await _Rig.start();
      try {
        final s = await r.connect(auth: auth);
        expect(mixedIn(r)['users'], [
          {'username': 'jorm', 'password': 's3cret'},
        ]);
        final sys = sysIn(r)!;
        expect(sys.containsKey('users'), isFalse);
        expect(sys['listen'], '127.0.0.1');
        final port = sys['listen_port'] as int;
        expect(port, isNot(2080));
        expect(r.sys.ports, [port]);
        expect(s['sysPort'], port);
        expect(jsonDecode(File(p.join(r.tmp.path, 'data', 'sys-in.json')).readAsStringSync()), {'port': port});
        // the daemon's own requests go through tunnel-in, never the user port
        expect(inbounds(r).any((i) => i['tag'] == 'tunnel-in' && !i.containsKey('users')), isTrue);
      } finally {
        await r.close();
      }
    });

    test('on, system proxy off: no sys-in', () async {
      final r = await _Rig.start();
      try {
        final s = await r.connect(auth: auth, sysProxy: false);
        expect(sysIn(r), isNull);
        expect(mixedIn(r).containsKey('users'), isTrue);
        expect(r.sys.ports, isEmpty);
        expect(s['sysPort'], isNull);
      } finally {
        await r.close();
      }
    });

    test('the same port after a crash restart, a reconnect and a new jormd; a busy one is replaced', () async {
      final tmp = await Directory.systemTemp.createTemp('jorm-kill');
      final r = await _Rig.start(dir: tmp);
      int? port;
      try {
        await r.connect(auth: auth, killSwitch: true, killWhileClosed: true);
        port = sysIn(r)!['listen_port'] as int;
        r.box.crash(9);
        await r.untilStatus((s) => s['recovering'] != null, 'recovering');
        await r.timers.tick();
        await r.untilStatus((s) => s['recovering'] == null && s['restarts'] == 1, 'restarted');
        expect(sysIn(r)!['listen_port'], port, reason: 'a proxy the kill switch holds must still hit it');
        await r.connect(auth: auth);
        expect(sysIn(r)!['listen_port'], port, reason: 'a reconnect keeps it too (our own sing-box holds it)');
        expect(r.sys.ports.every((x) => x == port), isTrue, reason: '${r.sys.ports}');
        await r.daemon.shutdown();
        await r.api.close(force: true);

        final r2 = await _Rig.start(dir: tmp, timers: r.timers);
        try {
          await r2.connect(auth: auth);
          expect(sysIn(r2)!['listen_port'], port, reason: 'kept on disk across runs');
          await r2.daemon.shutdown(); // sing-box is "down"
          // someone else holds it now
          final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
          try {
            await r2.connect(auth: auth);
            final next = sysIn(r2)!['listen_port'] as int;
            expect(next, isNot(port));
            expect(r2.sys.ports.last, next);
            expect(jsonDecode(File(p.join(tmp.path, 'data', 'sys-in.json')).readAsStringSync()), {'port': next});
          } finally {
            await squatter.close();
          }
        } finally {
          await r2.close();
        }
      } finally {
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      }
    });

    test('an empty password is an error, not an open port', () {
      expect(() => buildConfig({'mixedAuth': {'user': 'a', 'pass': ''}}), throwsArgumentError);
      expect(() => mixedAuthUser({'mixedAuth': {'user': 'a:b', 'pass': 'x'}}), throwsArgumentError);
      expect(mixedAuthUser({}), isNull);
    });
  });
}
