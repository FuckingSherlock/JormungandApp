// LiveCoreHost over a real CoreService (a fake BoxRunner instead of sing-box, no network):
// the catalog from the snapshot, the connect flow, what a change does to a running connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/platform/network_channel.dart';
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

/// A core that remembers what the app told its updater.
class _RecCore extends CoreService {
  _RecCore({required super.dataDir, required super.runner})
    : super(singBox: '', boxFactory: (_) => FakeRunner(), sysProxy: NoSystemProxy(), isElevated: () => true);

  final updateBodies = <Map<String, dynamic>>[];

  @override
  void updateSettings(Map<String, dynamic> body) {
    updateBodies.add(body);
    super.updateSettings(body);
  }
}

class _FakeNetwork implements NetworkPort {
  bool isMetered = true;
  final changes = StreamController<bool>.broadcast();

  @override
  Future<bool> metered() async => isMetered;

  @override
  Stream<bool> get meteredChanges => changes.stream;
}

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

  test('Settings -> Notifications switches are saved and read back by a new host', () async {
    await start();
    host.notif
      ..setFlag('enabled', false)
      ..setFlag('autoSwitch', false)
      ..setFlag('coreCrash', true);
    host.changed();
    await settle();
    final saved = (await core.state())['snapshot'] as Map<String, dynamic>;
    expect(saved['notifCfg'], {'enabled': false, 'autoSwitch': false, 'coreCrash': true});

    // the same data dir, a new host (the app started again)
    await host.shutdown();
    host.dispose();
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
    expect(host.notif.enabled, isFalse);
    expect(host.notif.flag('autoSwitch'), isFalse);
    expect(host.notif.flag('coreCrash'), isTrue);
    expect(host.notif.flag('connLost'), isTrue); // never touched: the default
    expect(notifAllows(host.catalog.unknown['notifCfg'], 'coreCrash'), isFalse); // the master is off
    host.notif.setFlag('enabled', true);
    expect(notifAllows(host.catalog.unknown['notifCfg'], 'coreCrash'), isTrue);
    expect(notifAllows(host.catalog.unknown['notifCfg'], 'autoSwitch'), isFalse);
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

  test('servers switched off in Nodes survive an update: not "removed by the provider", hidden in a chain exit', () async {
    String line(String host, String name) =>
        'ss://${base64.encode(utf8.encode('aes-256-gcm:password'))}@$host:8388#${Uri.encodeComponent(name)}';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response
        ..headers.set('content-type', 'text/plain')
        ..write(
          base64.encode(
            utf8.encode(
              [
                line('one.example', 'One'),
                line('two.example', 'Two'),
                line('three.example', 'Three'),
              ].join('\n'),
            ),
          ),
        );
      req.response.close();
    });
    final snap = snapshot();
    ((snap['sourcesData'] as Map)['a'] as Map)
      ..['url'] = 'http://127.0.0.1:${server.port}/sub'
      ..['nodes'] = <dynamic>[]
      ..['userAgent'] = 'sing-box';
    await start(snap: snap);
    await host.updateSource('a');
    final catalog = host.catalog;
    final s = catalog.sourcesData['a']!;
    expect(s.nodes.map((n) => n.name), ['One', 'Two', 'Three']);

    host.toggleNodeEnabled('a', s.nodes[1].id);
    host.toggleNodeEnabled('a', s.nodes[2].id);
    final chain = Chain(id: 'c1', name: 'C', inId: 'b', outId: 'a');
    catalog.chainsData['c1'] = chain;
    catalog.catalogOrder['simple']!.add('c1');
    await host.updateSource('a'); // the provider still sends all three

    final after = catalog.sourcesData['a']!;
    expect(after.gone, isEmpty);
    expect(after.disabledNodes, hasLength(2));
    expect(catalog.unitGoneRefs('a'), isEmpty);
    expect(catalog.chainExitRefs(chain).map((r) => r.node.name), ['One']);
    expect(catalog.chainExitOrder(chain).map((r) => r.node.name), ['One']);
    // switched off in Nodes is a reason to show, not a removal
    expect(catalog.offReasons(catalog.chainExitOrder(chain, withOff: true)).map((r) => r.nid), [after.nodes[1].id, after.nodes[2].id]);
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
    'a chain ping goes to the pair book (exits through the entry), never to the exits\' own pings; one that cannot run keeps the old pair',
    () async {
      await start();
      final catalog = host.catalog;
      final chain = Chain(id: 'c1', name: 'C', inId: 'b', outId: 'a');
      catalog.chainsData['c1'] = chain;
      catalog.catalogOrder['simple']!.add('c1');
      final b1 = catalog.sourcesData['b']!.nodes.single;
      final a = catalog.sourcesData['a']!.nodes;
      catalog.pings.set(b1, 20); // the entry answers: it is the one in use
      catalog.pairs.set(b1, a[0], 55, catalog.pings.now);
      boxFails = SingBoxError('no sing-box');

      await host.pingChain(chain, entries: false);

      expect(catalog.pairs.ping(b1, a[0]), 55); // not measured: the old value stays
      expect(catalog.pairs.entry(b1, a[1]), isNull); // never measured: a dash
      expect(catalog.pairs.anyTesting, isFalse);
      expect(catalog.pings.entry(a[0]), isNull); // the exits were not pinged directly
      expect(catalog.pings.entry(a[1]), isNull);
      // what the chain lives by is the pair
      expect(catalog.chainExitNode(chain), same(a[0]));
      expect(catalog.chainLatency(chain), 55);
      boxFails = null;
    },
  );

  test('update settings (auto-download, metered network) go to the core and follow every change', () async {
    await start();
    await host.shutdown();
    host.dispose();
    final rec = _RecCore(dataDir: dir.path, runner: runner);
    final net = _FakeNetwork();
    host = LiveCoreHost(
      api: rec,
      isAndroid: false,
      network: net,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
    // the first push already knows the network and the default (Wi-Fi only)
    expect(rec.updateBodies.last, {'autoCheck': true, 'channel': 'stable', 'autoDownload': 'wifi', 'metered': true, 'ignoredSites': []});

    net.isMetered = false;
    net.changes.add(false);
    await settle(20);
    expect(rec.updateBodies.last['metered'], false);

    host.gen.updAutoDownload = 'always';
    host.changed();
    expect(rec.updateBodies.last['autoDownload'], 'always');
    final n = rec.updateBodies.length;
    host.changed(); // nothing moved: nothing sent
    expect(rec.updateBodies, hasLength(n));

    // the ignored sites go the same way: the core filters by them at once, no reconnect
    host.notif.ignoredSites = ['dead.example.com'];
    host.changed();
    expect(rec.updateBodies.last['ignoredSites'], ['dead.example.com']);
    expect(rec.ignoredSites.matches('api.dead.example.com'), isTrue);
    expect(host.phase, isNot(ConnectionPhase.connecting));
    await net.changes.close();
  });

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
