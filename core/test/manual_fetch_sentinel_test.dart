// The manual subscription update through the Sentinel (docs/logs.md → «Один автор sub/*», «Ручное обновление»):
// CoreService.fetchSource waits for the network (up to 5 s) and for the end of our own restart, answers only after the
// load (no `waiting`, no intermediate notModified), tells the wait in status().subWaits, and writes exactly one sub/*
// event per update. A fake subscription server on loopback; the Sentinel context driven by hand.
//
// The waits may run on the Sentinel's clock (FakeTime) or on a real timer: [until] moves the fake clock in small steps
// and gives the real loopback I/O (and real timers) time, so the tests hold either way.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

const _link = 'ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.20:8388#one';

class _Outcome {
  Map<String, dynamic>? result;
  Object? error;
  bool done = false;
}

void main() {
  late Directory tmp;
  late HttpServer server;
  late CoreService svc;
  late FakeTime time;
  late ContextTracker ctx;
  late List<String> hits;
  late List<Map<String, dynamic>> statuses;
  StreamSubscription<Map<String, dynamic>>? statusSub;
  var serve = true; // false: the server cuts the connection (a failed load)

  setUp(() async {
    serve = true;
    hits = [];
    statuses = [];
    tmp = await Directory.systemTemp.createTemp('jorm-manual-fetch');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((rq) {
      hits.add(rq.uri.path);
      if (!serve) {
        rq.response.detachSocket().then((s) => s.destroy());
        return;
      }
      rq.response
        ..write(_link)
        ..close();
    });
    time = FakeTime();
    svc = CoreService(
      directProbe: (_, _) async => 5,
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
    ctx = svc.sentinel.context
      ..noSignalGrace = Duration.zero
      ..switchCap = Duration.zero;
    statusSub = svc.statusChanges.listen(statuses.add);
  });

  tearDown(() async {
    await statusSub?.cancel();
    await svc.dispose();
    await server.close(force: true);
    for (var i = 0; i < 10 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Map<String, dynamic> src([String path = 'sub']) => {'url': 'http://127.0.0.1:${server.port}/$path', 'name': 'T'};

  _Outcome manual(String sid, [Map<String, dynamic>? source]) {
    final o = _Outcome();
    svc.fetchSource({'sid': sid, 'source': source ?? src(sid)}).then((r) {
      o.result = r;
      o.done = true;
    }, onError: (Object e) {
      o.error = e;
      o.done = true;
    });
    return o;
  }

  /// Steps the fake clock (and the real one, for sockets / real timers) until [done], at most ~10 real seconds.
  Future<void> until(bool Function() done) async {
    final sw = Stopwatch()..start();
    while (!done() && sw.elapsed < const Duration(seconds: 10)) {
      await time.advance(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// A few small steps of both clocks, for "still waiting" checks ([fakeMs] of fake time in all).
  Future<void> idle(int fakeMs) async {
    for (var i = 0; i < fakeMs ~/ 250; i++) {
      await time.advance(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  List<Map> subEvents() => [for (final e in (svc.eventBook.since(null)['events'] as List).cast<Map>()) if (e['cat'] == 'sub') e];

  Future<List?> waits() async => (await svc.status())['subWaits'] as List?;

  void offline() => ctx.platform(connected: false);
  void online() => ctx.platform(connected: true, validated: true, type: 'wifi', id: '1');

  test('the network is up: the load is at once, the answer is the load itself, one sub/updated own, no wait is ever told', () async {
    final o = manual('a');
    await until(() => o.done);
    expect(o.error, isNull);
    expect((o.result!['patch'] as Map)['nodes'], isNotEmpty);
    expect(o.result!.containsKey('waiting'), isFalse);
    expect(o.result!['notModified'], isNot(true));
    expect(subEvents(), isEmpty, reason: 'a manual update writes no success sub/updated');
    expect(statuses.where((s) => s.containsKey('subWaits')), isEmpty);
    expect((await svc.status()).containsKey('subWaits'), isFalse);
  });

  test('offline: it waits (no load, subWaits for network); the network back within 5 s: it loads, one sub/updated own, the wait is cleared and pushed', () async {
    offline();
    final o = manual('a');
    await idle(1000);
    expect(o.done, isFalse, reason: 'waits for the network');
    expect(hits, isEmpty, reason: 'nothing is asked while there is no network');
    expect(await waits(), [
      {'source': 'a', 'name': 'T', 'for': 'network'}
    ]);
    expect(statuses.any((s) => s['subWaits'] != null), isTrue, reason: 'pushed through statusChanges at the start');
    expect(subEvents(), isEmpty, reason: 'the wait is not written on the card or in the journal');

    online();
    await until(() => o.done);
    expect(o.error, isNull);
    expect(hits, isNotEmpty);
    expect(o.result!.containsKey('waiting'), isFalse);
    expect(subEvents(), isEmpty, reason: 'no success event');
    expect(await waits(), isNull);
    expect((await svc.status()).containsKey('subWaits'), isFalse, reason: 'absent when empty');
    final last = statuses.lastWhere((s) => s.containsKey('subWaits') || s.isNotEmpty);
    expect(last['subWaits'] == null || (last['subWaits'] as List).isEmpty, isTrue, reason: 'the end of the wait is pushed too');
  });

  test('a portal counts as no network for this: it waits as well, and loads when the portal is gone', () async {
    ctx.platform(connected: true, validated: false, captive: true, type: 'wifi', id: '1');
    final o = manual('a');
    await idle(1000);
    expect(o.done, isFalse);
    expect(hits, isEmpty);
    expect(((await waits())!.single as Map)['for'], 'network');
    online();
    await until(() => o.done);
    expect(o.error, isNull);
    expect(subEvents(), isEmpty, reason: 'no success event');
  });

  test('offline for 5 s: one sub/failed own with code offline and "No network"; the call throws; nothing was loaded; the wait is cleared', () async {
    offline();
    final o = manual('a');
    await idle(4000);
    expect(o.done, isFalse, reason: 'the wait is up to 5 s: not given up at 4');
    await until(() => o.done);
    expect(o.done, isTrue);
    expect(o.error, isNotNull, reason: 'a failed manual fetch throws, as before');
    expect(hits, isEmpty);
    final ev = subEvents();
    expect(ev, hasLength(1), reason: 'exactly one sub/* event per manual update');
    expect([ev.single['type'], ev.single['own'], ev.single['level']], ['failed', true, 'error']);
    final d = (ev.single['data'] as Map);
    expect([d['code'], d['error'], d['source'], d['name']], ['offline', 'No network', 'a', 'T']);
    expect((ev.single['op'] as Map)['kind'], 'subUpdate');
    expect(await waits(), isNull);
  });

  test('two manual updates waiting at once: both are in subWaits, both load when the network is back, each its own sub/updated and op', () async {
    offline();
    final a = manual('a'), b = manual('b');
    await idle(500);
    final w = (await waits())!.cast<Map>();
    expect([for (final x in w) x['source']]..sort(), ['a', 'b']);
    online();
    await until(() => a.done && b.done);
    expect([a.error, b.error], [null, null]);
    expect(subEvents(), isEmpty, reason: 'no success event for either');
    expect(await waits(), isNull);
  });

  group('our own restart', () {
    test('the load cut by it: waits for the settle (subWaits for connection, no extra loads, no notModified), then loads once more; one event, no askAgain', () async {
      // the source is stored fresh: a timer's askAgain would make it due although its period is not over
      await svc.store.save({
        'sourcesData': {
          'a': <String, dynamic>{
            'id': 'a',
            'kind': 'sub',
            'name': 'T',
            'enabled': true,
            'url': src('a')['url'],
            'userAgent': 'Auto',
            'updateInterval': 12 * 3600,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': <Object>[],
            'gone': <Object>[],
          },
        },
        'sourceOrder': ['a'],
      });
      serve = false;
      ctx.starting('refreshLists');
      final o = manual('a');
      await until(() => ((statuses.isNotEmpty && statuses.any((s) => s['subWaits'] != null))) || o.done);
      expect(o.done, isFalse, reason: 'no intermediate answer: the caller is still awaiting');
      expect(await waits(), [
        {'source': 'a', 'name': 'T', 'for': 'connection'}
      ]);
      expect(subEvents(), isEmpty, reason: 'a failure of our own restart is not a failure: nothing told');
      final before = hits.length;
      await idle(3000);
      expect(o.done, isFalse);
      expect(hits.length, before, reason: 'not loaded again until the core is settled');

      serve = true;
      ctx.started();
      await idle(1000);
      expect(o.done, isFalse, reason: 'started is not settled');
      await until(() => o.done);
      expect(o.error, isNull);
      expect(hits.length, greaterThan(before), reason: 'loaded again after the settle');
      expect((o.result!['patch'] as Map)['nodes'], isNotEmpty);
      expect(o.result!.containsKey('waiting'), isFalse);
      expect(o.result!['notModified'], isNot(true));
      expect(subEvents(), isEmpty, reason: 'no success event');
      expect(await waits(), isNull);
      final after = hits.length;
      expect(await svc.updater.runDue(), isEmpty, reason: 'the timer was not asked to come again');
      expect(hits.length, after);
    });

    test('the core goes down while it waits: sub/failed own with code core.down; the call throws; the wait is cleared; one event', () async {
      serve = false;
      ctx.starting('refreshLists');
      final o = manual('a');
      await until(() => statuses.any((s) => s['subWaits'] != null) || o.done);
      expect(o.done, isFalse);
      expect(((await waits())!.single as Map)['for'], 'connection');

      ctx.down();
      await until(() => o.done);
      expect(o.done, isTrue);
      expect(o.error, isNotNull);
      final ev = subEvents();
      expect(ev, hasLength(1));
      expect([ev.single['type'], ev.single['own']], ['failed', true]);
      expect((ev.single['data'] as Map)['code'], 'core.down');
      expect((ev.single['op'] as Map)['kind'], 'subUpdate');
      expect(await waits(), isNull);
    });
  });

  test('a load that fails with the core settled and the network up: sub/failed own at once, no wait, no second event', () async {
    serve = false;
    final o = manual('a');
    await until(() => o.done);
    expect(o.error, isNotNull);
    final ev = subEvents();
    expect(ev, hasLength(1));
    expect([ev.single['type'], ev.single['own']], ['failed', true]);
    expect((ev.single['data'] as Map)['code'], isNot(anyOf('offline', 'core.down')));
    expect(statuses.where((s) => s['subWaits'] != null), isEmpty);
  });
}

class _Runner implements BoxRunner {
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => false;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) {}
  @override
  Future<void> start(Map<String, dynamic> config) async {}
  @override
  Future<void> stop() async {}
}
