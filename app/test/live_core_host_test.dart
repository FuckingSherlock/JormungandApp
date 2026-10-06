// LiveCoreHost over a real CoreService (a fake BoxRunner instead of sing-box, no network):
// the catalog from the snapshot, the connect flow, what a change does to a running connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

/// A runner that is not sing-box: starts when told to, counts the starts, has no API service.
class FakeRunner implements BoxRunner {
  bool up = false;
  int starts = 0;
  Map<String, dynamic>? lastConfig;

  /// A sing-box that cannot start (a ping's throwaway box: the core answers `{error}`).
  Object? failWith;
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
    if (failWith != null) throw failWith!;
    up = true;
    starts++;
    lastConfig = config;
  }

  @override
  Future<void> stop() async => up = false;
}

Map<String, dynamic> node(String id) => {
  'id': id,
  'name': 'Server $id',
  'flag': '\u{1F1E9}\u{1F1EA}',
  'protocol': 'vless',
  'address': '$id.example',
  'port': 443,
  'outbound': {
    'type': 'vless',
    'server': '$id.example',
    'server_port': 443,
    'uuid': '11111111-1111-1111-1111-111111111111',
  },
};

Map<String, dynamic> source(String id, List<String> nodes) => {
  'id': id,
  'kind': 'sub',
  'name': 'Source $id',
  'enabled': true,
  'inAuto': true,
  'offNodes': <String>[],
  'disabledNodes': <String>[],
  'gone': <dynamic>[],
  'nodes': [for (final n in nodes) node(n)],
  'url': 'http://127.0.0.1:1/$id',
};

Map<String, dynamic> snapshot() => {
  'sourcesData': {
    'a': source('a', ['a1', 'a2']),
    'b': source('b', ['b1']),
  },
  'sourceOrder': ['a', 'b'],
  'sourceSeq': 3,
  'connectMode': 'simple',
  'connectOrder': ['a', 'b'],
  'activeConnectId': 'a',
  'autoConnect': true,
  'catalogOrder': {
    'simple': ['a', 'b'],
    'profiles': <String>[],
  },
  'segState': {'mode': 'proxy', 'route': 'rules', 'sys': 'off'},
};

void main() {
  late Directory dir;
  late FakeRunner runner;
  late CoreService core;
  late LiveCoreHost host;
  Object? boxFails; // set: every throwaway sing-box (ping, Speed Test) fails to start

  Future<void> start({bool elevated = true, Map<String, dynamic>? snap}) async {
    dir = Directory.systemTemp.createTempSync('jorm_app_');
    File(
      '${dir.path}/ui-state.json',
    ).writeAsStringSync(jsonEncode(snap ?? snapshot()));
    runner = FakeRunner();
    core = CoreService(
      singBox: '',
      dataDir: dir.path,
      runner: runner,
      boxFactory: (_) => FakeRunner()..failWith = boxFails,
      sysProxy: NoSystemProxy(),
      isElevated: () => elevated,
      exitCheck: (port) async => {
        'ip': '203.0.113.7',
        'country': 'DE',
        'city': 'Frankfurt',
      },
    );
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
  }

  tearDown(() async {
    await host.shutdown();
    host.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle([int ms = 120]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test(
    'init loads the catalog; the dock shows the entry Auto would use',
    () async {
      await start();
      expect(host.ready, isTrue);
      expect(host.initError, isNull);
      expect(host.phase, ConnectionPhase.disconnected);
      expect(host.catalogEmpty, isFalse);
      expect(host.autoMode, isTrue);
      final d = host.dock;
      expect(d.kind, DockKind.sub);
      expect(d.name, 'Source a');
      expect(d.auto, isTrue);
      expect(d.node, isNull); // nothing measured yet: "no working node"
      expect(host.tun, isFalse);
      expect(host.global, isFalse);
    },
  );

  test('first run: empty catalog, nothing to connect', () async {
    await start(snap: {});
    expect(host.catalogEmpty, isTrue);
    expect(host.dock.none, DockNone.empty);
    final r = await host.toggleConnection();
    expect(r.outcome, ConnectOutcome.catalogEmpty);
    expect(runner.up, isFalse);
  });

  test('connect: plan -> core -> connected; disconnect', () async {
    await start();
    final r = await host.toggleConnection();
    expect(r.outcome, ConnectOutcome.started);
    expect(runner.up, isTrue);
    expect(runner.starts, 1);
    expect(host.phase, ConnectionPhase.connected);
    expect(host.isOn, isTrue);

    await settle();
    expect(host.exit.ip, '203.0.113.7');
    expect(host.exit.country, 'DE');

    await host.toggleConnection();
    expect(host.phase, ConnectionPhase.disconnected);
    expect(runner.up, isFalse);
  });

  test('a change that makes another plan reconnects', () async {
    await start();
    await host.connect();
    expect(runner.starts, 1);

    host.setGlobal(true);
    await settle();
    expect(runner.starts, 2);
    expect(host.phase, ConnectionPhase.connected);

    // the same value again: no new plan
    host.setGlobal(true);
    await settle();
    expect(runner.starts, 2);

    // Manual on the other entry: another entry is another plan
    host.catalog.selectConnect('b');
    host.changed();
    await settle();
    expect(runner.starts, 3);
    expect(host.autoMode, isFalse);
  });

  test('segments are saved with the catalog', () async {
    await start();
    host.setGlobal(true);
    host.setTun(true);
    await settle();
    final saved = (await core.state())['snapshot'] as Map<String, dynamic>;
    expect((saved['segState'] as Map)['route'], 'global');
    expect((saved['segState'] as Map)['mode'], 'tun');
  });

  test(
    'TUN without administrator rights: a clear failure, still off',
    () async {
      await start(elevated: false);
      host.setTun(true);
      final notices = <HostNotice>[];
      final sub = host.notices.listen(notices.add);
      final r = await host.connect();
      await settle(20);
      await sub.cancel();
      expect(r.outcome, ConnectOutcome.failed);
      expect(r.code, 'tunNeedsAdmin');
      expect(notices.single.code, 'connectFailed');
      expect(host.phase, ConnectionPhase.disconnected);
      expect(runner.up, isFalse);
    },
  );

  test('nothing in Auto: refused before the core is asked', () async {
    await start();
    host.catalog.toggleEntryAuto('a');
    host.catalog.toggleEntryAuto('b');
    host.changed();
    final r = await host.toggleConnection();
    expect(r.outcome, ConnectOutcome.nothingInAuto);
    expect(host.dock.none, DockNone.nothingInAuto);
    expect(runner.starts, 0);
  });

  test('a subscription that cannot be loaded stays with its error', () async {
    await start();
    final notices = <HostNotice>[];
    final sub = host.notices.listen(notices.add);
    final r = await host.addSubscription(
      'http://127.0.0.1:1/sub',
      name: 'Broken',
    );
    await settle(20);
    await sub.cancel();
    expect(r.outcome, AddSourceOutcome.failed);
    final s = host.catalog.sourcesData['src3']!;
    expect(s.name, 'Broken');
    expect(s.unknown['lastError'], isA<Map>());
    expect(notices.map((n) => n.code), contains('subFailed'));
    expect(host.catalog.sourceOrder, contains('src3'));

    expect(
      (await host.addSubscription('  ')).outcome,
      AddSourceOutcome.emptyUrl,
    );
  });

  test('an imported file becomes a local source; garbage adds nothing', () async {
    await start();
    final r = await host.importConfigFile(
      'my list.txt',
      'vless://11111111-1111-1111-1111-111111111111@one.example.com:443?security=tls&sni=one.example.com#One\n'
      'trojan://pw@two.example.com:443?sni=two.example.com#Two\n',
    );
    expect(r.ok, isTrue);
    expect(r.sourceId, 'src3');
    expect(r.name, 'my list');
    expect(r.count, 2);
    final s = host.catalog.sourcesData['src3']!;
    expect(s.kind, 'file');
    expect(s.url, isNull);
    expect(s.nodes.length, 2);
    expect(s.count, 2);
    expect(host.catalog.sourceOrder.last, 'src3');
    expect(host.catalog.sourceSeq, 4);

    // the dock says `file` when the entry is such a source
    host.catalog.setAutoConnect(false);
    host.catalog.activeConnectId = 'src3';
    host.changed();
    expect(host.dock.kind, DockKind.file);

    // nothing to update: a no-op, no error strip
    await host.updateSource('src3');
    expect(s.unknown['lastError'], isNull);
    expect(host.isUpdating('src3'), isFalse);

    final bad = await host.importConfigFile('junk.json', 'not a config');
    expect(bad.ok, isFalse);
    expect(bad.error, 'No servers found in the file');
    expect(host.catalog.sourceOrder, ['a', 'b', 'src3']);
    expect(host.catalog.sourceSeq, 4);
  });

  test(
    'a ping that cannot run keeps what the nodes had; only a never-pinged node stays without a value',
    () async {
      await start();
      final nodes = host.catalog.sourcesData['a']!.nodes;
      host.catalog.pings.set(nodes[0], 42);
      host.catalog.pings.set(nodes[1], -1);
      boxFails = SingBoxError('no sing-box');
      final b1 = host.catalog.sourcesData['b']!.nodes.single;

      await host.pingNodes([...nodes, b1]);

      final pings = host.catalog.pings;
      expect(pings.ping(nodes[0]), 42);
      expect(pings.ping(nodes[1]), -1);
      expect(pings.entry(nodes[1])!.fails, 1);
      expect(pings.entry(nodes[0])!.testing, isFalse);
      expect(pings.entry(b1), isNull); // never pinged: a dash
      expect(pings.anyTesting, isFalse);
      boxFails = null;
    },
  );

  test(
    'the dock follows the core: Auto members give pings and the server',
    () async {
      await start();
      await host.connect();
      // the core's Auto reports members only with sing-box's API; the catalog takes its own pings
      host.catalog.pings.set(host.catalog.sourcesData['a']!.nodes.last, 87);
      host.changed();
      final d = host.dock;
      expect(d.node?.name, 'Server a2');
      expect(d.latencyMs, 87);
      expect(d.node?.protocol, 'vless');
    },
  );
}
