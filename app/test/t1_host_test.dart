// t1, app stage, run A (docs/logs.md → «Один автор sub/*», «Уровни и атрибуция», «Смена сети»): what LiveCoreHost
// does with the core's new contract. A real CoreService (fake sing-box runner, loopback subscription server):
//  - the app writes no `sub/*` event (the core is the only author of a manual update's event),
//  - `status.subWaits` reaches `CoreHost.subWaits` and its listeners,
//  - a lost Manual pin ends the connection with `disconnect({error: {reason: 'pinLost', pick, why}})`, and the app
//    journals no `user/disconnect` for it,
//  - `detectNetProvider` goes to `updateSettings` like `closeOnSwitch`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot, testBoxes;

const _link = 'ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.20:8388#one';

/// A core that records what the app tells it, and whose status can carry a wait the test injects.
class _RecCore extends CoreService {
  _RecCore({required super.dataDir, required super.runner})
    : super(singBox: '', boxFactory: testBoxes, sysProxy: NoSystemProxy(), isElevated: () => true, resolveAddresses: false) {
    super.statusChanges.listen(_push.add); // the core's own pushes (real waits) go through too
  }

  final updateBodies = <Map<String, dynamic>>[];
  final disconnects = <Map<String, dynamic>?>[];
  final posted = <Map<String, dynamic>>[];

  /// Injected `subWaits` (null = the real ones only).
  List<Map<String, String>>? fakeWaits;
  final _push = StreamController<Map<String, dynamic>>.broadcast();

  @override
  void updateSettings(Map<String, dynamic> body) {
    updateBodies.add(Map<String, dynamic>.from(body));
    super.updateSettings(body);
  }

  @override
  Future<Map<String, dynamic>> disconnect({Map<String, dynamic>? error}) {
    disconnects.add(error == null ? null : Map<String, dynamic>.from(error));
    return super.disconnect(error: error);
  }

  @override
  Map<String, dynamic> postEvent(Map<String, dynamic> body) {
    posted.add(Map<String, dynamic>.from(body));
    return super.postEvent(body);
  }

  @override
  Future<Map<String, dynamic>> status() async {
    final st = await super.status();
    final w = fakeWaits;
    if (w == null) return st;
    return {...st, if (w.isNotEmpty) 'subWaits': w};
  }

  @override
  Stream<Map<String, dynamic>> get statusChanges => _push.stream;

  /// Sets the injected waits and pushes the status, as the core does on both ends of a wait.
  Future<void> pushWaits(List<Map<String, String>> w) async {
    fakeWaits = w;
    _push.add(await status());
  }
}

List<Map> _events(CoreService c) => (c.eventBook.since(null)['events'] as List).cast<Map>();

void main() {
  late Directory dir;
  late FakeRunner runner;
  late _RecCore core;
  late LiveCoreHost host;
  late HttpServer server;
  var serve = true; // false: the subscription server cuts the connection

  Future<void> start({Map<String, dynamic>? snap}) async {
    dir = Directory.systemTemp.createTempSync('jorm_t1_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((rq) {
      if (!serve) {
        rq.response.detachSocket().then((s) => s.destroy());
        return;
      }
      rq.response
        ..write(_link)
        ..close();
    });
    final s = snap ?? snapshot();
    ((s['sourcesData'] as Map)['a'] as Map)['url'] = 'http://127.0.0.1:${server.port}/a';
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(s));
    runner = FakeRunner();
    core = _RecCore(dataDir: dir.path, runner: runner);
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
  }

  setUp(() {
    serve = true;
  });

  tearDown(() async {
    await host.shutdown();
    host.dispose();
    await server.close(force: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

  group('one author of sub/*: the core', () {
    test('a manual update that loads: exactly one sub/updated (own, from the core), nothing posted by the app', () async {
      await start();
      await host.updateSource('a');
      await settle(40);
      final sub = _events(core).where((e) => e['cat'] == 'sub').toList();
      // the fixture's servers a1 / a2 are not in the loaded list: the core also writes `removed`, once
      final types = [for (final e in sub) e['type']];
      expect(types.where((t) => t == 'updated'), hasLength(1), reason: '$types');
      expect(types.toSet(), hasLength(types.length), reason: 'one update, one event per type: $types');
      expect(sub.every((e) => e['own'] == true), isTrue);
      expect(core.posted.where((b) => b['cat'] == 'sub'), isEmpty, reason: 'the app writes no sub/* (updated / removed / back)');
      expect(host.catalog.sourcesData['a']!.unknown.containsKey('lastError'), isFalse);
    });

    test('a manual update that fails: exactly one sub/failed (from the core), one card error, nothing posted by the app', () async {
      serve = false;
      await start();
      final notices = <HostNotice>[];
      final sub = host.notices.listen(notices.add);
      await host.updateSource('a');
      await settle(40);
      await sub.cancel();
      final ev = _events(core).where((e) => e['cat'] == 'sub').toList();
      expect([for (final e in ev) e['type']], ['failed']);
      expect(ev.single['own'], isTrue);
      expect(core.posted.where((b) => b['cat'] == 'sub'), isEmpty);
      // the card keeps the error; a notice, if the host still gives one, is not doubled
      expect(host.catalog.sourcesData['a']!.unknown['lastError'], isA<Map>());
      expect(notices.where((n) => n.code == 'subFailed').length, lessThanOrEqualTo(1));
    });

  });

  group('subWaits', () {
    test('empty by default; a wait in the core status reaches the host with a notification; the end of the wait clears it', () async {
      await start();
      expect(host.subWaits, isEmpty);
      var n = 0;
      host.addListener(() => n++);

      await core.pushWaits([
        {'source': 'a', 'name': 'Source a', 'for': 'network'},
      ]);
      await settle(20);
      expect(host.subWaits, hasLength(1));
      expect(host.subWaits.single.source, 'a');
      expect(host.subWaits.single.name, 'Source a');
      expect(host.subWaits.single.forWhat, 'network');
      expect(n, greaterThan(0), reason: 'listeners are told');

      final before = n;
      await core.pushWaits([]);
      await settle(20);
      expect(host.subWaits, isEmpty);
      expect(n, greaterThan(before), reason: 'the end of the wait is told too');
    });

    test('two waits of different kinds are kept in order; one ending leaves the other', () async {
      await start();
      await core.pushWaits([
        {'source': 'a', 'name': 'Source a', 'for': 'network'},
        {'source': 'b', 'name': 'Source b', 'for': 'connection'},
      ]);
      await settle(20);
      expect([for (final w in host.subWaits) (w.source, w.forWhat)], [('a', 'network'), ('b', 'connection')]);

      await core.pushWaits([
        {'source': 'b', 'name': 'Source b', 'for': 'connection'},
      ]);
      await settle(20);
      expect([for (final w in host.subWaits) w.source], ['b']);
    });

    test('a real offline wait: the host shows it while the core waits, and clears it when the load is done', () async {
      await start();
      core.sentinel.context.platform(connected: false);
      final done = host.updateSource('a');
      for (var i = 0; i < 40 && host.subWaits.isEmpty; i++) {
        await settle(25);
      }
      expect(host.subWaits.map((w) => (w.source, w.forWhat)), [('a', 'network')]);

      core.sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: '1');
      await done.timeout(const Duration(seconds: 10));
      await settle(40);
      expect(host.subWaits, isEmpty);
      expect(_events(core).where((e) => e['cat'] == 'sub' && e['type'] == 'updated'), hasLength(1));
    });
  });

  group('a lost Manual pin', () {
    test('a pinned server gone: disconnect carries {reason: pinLost, pick, why: deleted}; the core journals by: error, the app no user/disconnect', () async {
      await start();
      host.pinRouteNode('a', 'a::a1');
      expect((await host.connect()).started, isTrue);
      core.posted.clear();
      core.disconnects.clear();

      host.catalog.pinnedNode = 'a::gone';
      host.changed();
      await settle();

      expect(host.phase, ConnectionPhase.disconnected);
      expect(core.disconnects, hasLength(1));
      final err = core.disconnects.single!;
      expect(err['reason'], 'pinLost');
      expect(err['why'], 'deleted');
      expect(err['pick'], isA<String>());
      expect(err['pick'], isNotEmpty);

      final d = _events(core).where((e) => e['cat'] == 'conn' && e['type'] == 'disconnected').toList();
      expect(d, hasLength(1));
      expect((d.single['data'] as Map)['by'], 'error');
      expect((d.single['data'] as Map)['reason'], 'pinLost');
      expect((d.single['data'] as Map)['why'], 'deleted');
      expect(core.posted.where((b) => b['cat'] == 'user' && b['type'] == 'disconnect'), isEmpty, reason: 'the user did not disconnect');
    });

    test('an entry left with no enabled server: why is off', () async {
      await start();
      host.catalog.selectConnect('b');
      host.changed();
      expect((await host.connect()).started, isTrue);
      core.disconnects.clear();

      final b = host.catalog.sourcesData['b']!;
      b.disabledNodes = [for (final n in b.nodes) n.id];
      host.changed();
      await settle();

      expect(core.disconnects, hasLength(1));
      expect(core.disconnects.single!['reason'], 'pinLost');
      expect(core.disconnects.single!['why'], 'off');
    });

    test('an ordinary disconnect passes no error; nothing is sent when the pin is intact', () async {
      await start();
      host.pinRouteNode('a', 'a::a1');
      await host.connect();
      host.changed();
      await settle();
      expect(core.disconnects, isEmpty, reason: 'a pin that holds ends nothing');

      await host.disconnect();
      expect(core.disconnects, hasLength(1));
      expect(core.disconnects.single, isNull);
      final d = _events(core).where((e) => e['cat'] == 'conn' && e['type'] == 'disconnected').toList();
      expect(d, hasLength(1));
      expect((d.single['data'] as Map)['by'], isNot('error'));
    });
  });

  group('detectNetProvider', () {
    test('goes to updateSettings at start and on every real change, like closeOnSwitch; no reconnect', () async {
      await start();
      expect(core.updateBodies.last['detectNetProvider'], isTrue, reason: 'the default is on');
      expect(core.detectNetProvider, isTrue);

      host.catalog.connCfg.detectNetProvider = false;
      host.changed();
      expect(core.updateBodies.last['detectNetProvider'], isFalse);
      expect(core.detectNetProvider, isFalse);
      expect(host.phase, isNot(ConnectionPhase.connecting));

      final n = core.updateBodies.length;
      host.changed(); // nothing moved: nothing sent
      expect(core.updateBodies, hasLength(n));

      host.catalog.connCfg.detectNetProvider = true;
      host.changed();
      expect(core.updateBodies.last['detectNetProvider'], isTrue);
      expect(core.detectNetProvider, isTrue);
    });

    test('the saved choice survives a restart of the host: the first push carries it', () async {
      await start();
      host.catalog.connCfg.detectNetProvider = false;
      host.changed();
      await settle(100); // saved
      await host.shutdown();
      host.dispose();

      core = _RecCore(dataDir: dir.path, runner: runner);
      host = LiveCoreHost(
        api: core,
        isAndroid: false,
        saveDelay: const Duration(milliseconds: 20),
        reconnectDelay: const Duration(milliseconds: 20),
        trafficEvery: const Duration(milliseconds: 50),
      );
      await host.init();
      expect(core.updateBodies.last['detectNetProvider'], isFalse);
      expect(core.detectNetProvider, isFalse);
    });
  });
}
