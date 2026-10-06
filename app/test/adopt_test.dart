// A new core (the app's engine was made again while the tunnel kept running) takes the running
// tunnel over: no stop, no start, state "connected"; another plan than the catalog builds now goes
// the ordinary reconnect way; nothing running = "disconnected". CoreService + LiveCoreHost over a
// fake AdoptableRunner (the platform's record store is a plain field).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

/// What the VpnService holds across engines: whether the tunnel runs and the record kept for it.
class HeldTunnel {
  bool running = false;
  Map<String, dynamic>? record;
  int starts = 0, stops = 0;
}

/// A runner on the shared [HeldTunnel]: start / stop act on it, [adopt] attaches to what runs.
class AdoptRunner implements AdoptableRunner {
  AdoptRunner(this.platform);
  final HeldTunnel platform;
  bool up = false;
  bool adopted = false;
  Object? adoptFails;
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
    platform
      ..running = true
      ..record = null
      ..starts += 1;
    up = true;
  }

  @override
  Future<void> stop() async {
    up = false;
    if (platform.running) platform.stops++;
    platform
      ..running = false
      ..record = null;
  }

  @override
  Future<void> keep(Map<String, dynamic> record) async {
    if (up) platform.record = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>?> adopt() async {
    if (!platform.running) return null;
    if (adoptFails != null) throw adoptFails!;
    final r = platform.record;
    if (r == null) throw SingBoxError('no record');
    up = true;
    adopted = true;
    return r;
  }
}

Map<String, dynamic> _node(String id) => {
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

Map<String, dynamic> _source(String id, List<String> nodes) => {
  'id': id,
  'kind': 'sub',
  'name': 'Source $id',
  'enabled': true,
  'inAuto': true,
  'offNodes': <String>[],
  'disabledNodes': <String>[],
  'gone': <dynamic>[],
  'nodes': [for (final n in nodes) _node(n)],
  'url': 'http://127.0.0.1:1/$id',
};

Map<String, dynamic> _snapshot({List<String> a = const ['a1', 'a2']}) => {
  'sourcesData': {
    'a': _source('a', a),
    'b': _source('b', ['b1']),
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
  // global: no rule lists to fetch (a reconnect would fetch them through the fake tunnel's dead port)
  'segState': {'mode': 'proxy', 'route': 'global', 'sys': 'off'},
};

void main() {
  late Directory dir;
  final platform = HeldTunnel();
  final hosts = <LiveCoreHost>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('jorm_adopt_');
    platform
      ..running = false
      ..record = null
      ..starts = 0
      ..stops = 0;
  });

  tearDown(() async {
    for (final h in hosts) {
      await h.shutdown();
      h.dispose();
    }
    hosts.clear();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// One "engine": a core + a host on [runner]. [snap] is written to the shared data dir first.
  Future<LiveCoreHost> engine(AdoptRunner runner, {Map<String, dynamic>? snap}) async {
    if (snap != null) {
      File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(snap));
    }
    final core = CoreService(
      singBox: '',
      dataDir: dir.path,
      runner: runner,
      boxFactory: (_) => AdoptRunner(HeldTunnel()),
      sysProxy: NoSystemProxy(),
      isElevated: () => true,
      exitCheck: (port) async => {'ip': '203.0.113.7', 'country': 'DE'},
    );
    final host = LiveCoreHost(
      api: core,
      isAndroid: true,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    hosts.add(host);
    await host.init();
    return host;
  }

  Future<void> settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

  /// The first engine connects (and keeps its record on the platform), then "dies": its host and
  /// core are dropped WITHOUT a stop, the tunnel stays on the platform.
  Future<void> connectAndLoseEngine(Map<String, dynamic> snap) async {
    final first = await engine(AdoptRunner(platform), snap: snap);
    expect((await first.connect()).started, isTrue);
    expect(platform.starts, 1);
    expect(platform.record, isNotNull);
    first.dispose(); // no shutdown: the engine is gone, nobody stops the tunnel
    hosts.remove(first);
    await settle();
  }

  test('a running tunnel is taken over: connected, nothing stopped or started', () async {
    await connectAndLoseEngine(_snapshot());

    final runner = AdoptRunner(platform);
    final host = await engine(runner);
    expect(runner.adopted, isTrue);
    expect(host.phase, ConnectionPhase.connected);
    expect(host.isOn, isTrue);
    await settle();
    expect(platform.starts, 1, reason: 'no start');
    expect(platform.stops, 0, reason: 'no stop');
    expect(host.phase, ConnectionPhase.connected, reason: 'the same plan: no reconnect either');

    // it keeps controlling the adopted tunnel
    await host.disconnect();
    expect(host.phase, ConnectionPhase.disconnected);
    expect(platform.running, isFalse);
    expect(platform.stops, 1);
  });

  test('a plan that differs from what the catalog builds now takes the usual reconnect, not a silent restart', () async {
    await connectAndLoseEngine(_snapshot());

    // the catalog changed meanwhile (a server was added): another plan
    final runner = AdoptRunner(platform);
    final host = await engine(runner, snap: _snapshot(a: ['a1', 'a2', 'a3']));
    expect(runner.adopted, isTrue);
    expect(host.phase, ConnectionPhase.connected);
    expect(platform.starts, 1, reason: 'taken over first');
    await settle(1000);
    expect(platform.starts, 2, reason: 'then the ordinary reconnect with the new plan');
    expect(host.phase, ConnectionPhase.connected);
  });

  test('no tunnel: nothing to take over, disconnected', () async {
    final runner = AdoptRunner(platform);
    final host = await engine(runner, snap: _snapshot());
    expect(runner.adopted, isFalse);
    expect(host.phase, ConnectionPhase.disconnected);
    expect(platform.starts, 0);
    expect(platform.stops, 0);
  });

  test('a tunnel that cannot be taken over is stopped: the state is true, not "disconnected" over a live tunnel', () async {
    await connectAndLoseEngine(_snapshot());

    final runner = AdoptRunner(platform)..adoptFails = SingBoxError('the API does not answer');
    final host = await engine(runner);
    expect(runner.adopted, isFalse);
    expect(host.phase, ConnectionPhase.disconnected);
    expect(platform.running, isFalse);
    expect(platform.stops, 1);
  });

  test('the record of a tunnel that stopped is gone: a later engine finds nothing', () async {
    final first = AdoptRunner(platform);
    final host = await engine(first, snap: _snapshot());
    await host.connect();
    await host.disconnect();
    expect(platform.record, isNull);

    final second = AdoptRunner(platform);
    final h2 = await engine(second);
    expect(second.adopted, isFalse);
    expect(h2.phase, ConnectionPhase.disconnected);
  });
}
