// The app's own update must not leave the VPN off (docs/updates.md, "Подключение после обновления"):
// the record is written before the installer; the first start after the update connects again
// through the remembered entry, once, and only when that is what the user had (fresh, another
// version, VPN was on, consent there - else a notification). CoreService + LiveCoreHost over a fake
// runner; the native store is a fake ResumePort.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand/core/update_resume.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/resume_channel.dart';
import 'package:jormungand/platform/tile_channel.dart';
import 'package:jormungand/platform/vpn_channel.dart';
import 'package:jormungand_core/jormungand_core.dart';

class _Runner implements AdoptableRunner {
  bool up = false;
  int starts = 0;
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
    up = true;
    starts++;
  }

  @override
  Future<void> stop() async => up = false;
  @override
  Future<void> keep(Map<String, dynamic> record) async {}
  @override
  Future<Map<String, dynamic>?> adopt() async => null;
}

/// The native store: [rec] is what the package replacement armed (null = a start with no update).
class _Port implements ResumePort {
  ResumeRecord? rec;
  final saves = <({bool connected, String entry})>[];
  final log = <String>[];
  int takes = 0, prompts = 0, dones = 0;
  @override
  bool get available => true;
  @override
  Future<void> save({required bool connected, required String entry}) async {
    saves.add((connected: connected, entry: entry));
    log.add('save');
  }

  @override
  Future<ResumeRecord?> take() async {
    takes++;
    final r = rec;
    rec = null; // consumed
    return r;
  }

  @override
  Future<void> promptConnect() async => prompts++;
  @override
  Future<void> done() async => dones++;
}

class _Vpn extends VpnChannel {
  _Vpn();
  bool consent = true;
  @override
  Future<bool> prepare() async => consent;
}

/// A core whose update is downloaded and ready (the real updater needs a feed to get there).
class _ReadyCore extends CoreService {
  _ReadyCore({required super.dataDir, required super.runner})
    : super(
        singBox: '',
        boxFactory: (_) => _Runner(),
        sysProxy: NoSystemProxy(),
        isElevated: () => true,
        exitCheck: (port) async => {'ip': '203.0.113.7', 'country': 'DE'},
      );

  @override
  Future<void> updateBeginInstall() async {}

  @override
  Map<String, dynamic> updateStatus() => {'phase': 'ready', 'current': '0.1.0', 'file': '/tmp/update.apk'};
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

Map<String, dynamic> _snapshot() => {
  'sourcesData': {
    'a': {
      'id': 'a',
      'kind': 'sub',
      'name': 'Source a',
      'enabled': true,
      'inAuto': true,
      'offNodes': <String>[],
      'disabledNodes': <String>[],
      'gone': <dynamic>[],
      'nodes': [_node('a1')],
      'url': 'http://127.0.0.1:1/a',
    },
  },
  'sourceOrder': ['a'],
  'sourceSeq': 2,
  'connectMode': 'simple',
  'connectOrder': ['a'],
  'activeConnectId': 'a',
  'autoConnect': true,
  'catalogOrder': {
    'simple': ['a'],
    'profiles': <String>[],
  },
  'segState': {'mode': 'proxy', 'route': 'global', 'sys': 'off'},
};

class _Tile implements TilePort {
  final pushed = <TileState>[];
  @override
  Stream<TileAction> get actions => const Stream.empty();
  @override
  Future<void> push(TileState state) async => pushed.add(state);
  @override
  Future<String?> takeLaunchAction() async => null;
  @override
  Future<void> moveToBack() async {}
}

void main() {
  late Directory dir;
  late _Runner runner;
  late _Port port;
  late _Vpn vpn;
  final hosts = <LiveCoreHost>[];
  final now = DateTime(2026, 10, 6, 12);
  final at = now.millisecondsSinceEpoch;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('jorm_resume_');
    runner = _Runner();
    port = _Port();
    vpn = _Vpn();
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

  Future<LiveCoreHost> host({bool ready = false, Future<bool> Function(String)? installer}) async {
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(_snapshot()));
    final CoreService core = ready
        ? _ReadyCore(dataDir: dir.path, runner: runner)
        : CoreService(
            singBox: '',
            dataDir: dir.path,
            runner: runner,
            boxFactory: (_) => _Runner(),
            sysProxy: NoSystemProxy(),
            isElevated: () => true,
            exitCheck: (port) async => {'ip': '203.0.113.7', 'country': 'DE'},
          );
    final h = LiveCoreHost(
      api: core,
      isAndroid: true,
      vpn: vpn,
      installer: installer,
      resume: port,
      now: () => now,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    hosts.add(h);
    await h.init();
    return h;
  }

  ResumeRecord record({
    bool connected = true,
    int fromCode = 10,
    int code = 11,
    int? when,
  }) => ResumeRecord(connected: connected, entry: 'a', fromCode: fromCode, code: code, at: when ?? at);

  test('the record is written before the installer gets the file, with the entry and whether the VPN is on', () async {
    final order = port.log;
    final h = await host(
      ready: true,
      installer: (file) async {
        order.add('install');
        return true;
      },
    );
    expect((await h.connect()).started, isTrue);

    expect(await h.installUpdate(), isTrue);

    expect(order, ['save', 'install']);
    expect(port.saves.single.connected, isTrue);
    expect(port.saves.single.entry, 'a');
  });

  test('a record written while the VPN is off says so', () async {
    final h = await host(ready: true, installer: (_) async => true);
    await h.installUpdate();
    expect(port.saves.single.connected, isFalse);
  });

  test('a fresh record of another version connects once through the entry and is consumed', () async {
    final h = await host();
    port.rec = record();

    expect(await h.resumeAfterUpdate(), ResumeOutcome.resumed);
    expect(h.phase, ConnectionPhase.connected);
    expect(runner.starts, 1);
    expect(port.dones, 1);

    // taking consumed it: a second start (or call) does not connect again
    await h.disconnect();
    expect(await h.resumeAfterUpdate(), ResumeOutcome.none);
    expect(h.phase, ConnectionPhase.disconnected);
    expect(runner.starts, 1);
  });

  test('a start that follows no update does nothing', () async {
    final h = await host();
    expect(await h.resumeAfterUpdate(), ResumeOutcome.none);
    expect(runner.starts, 0);
    expect(port.dones, 1);
  });

  test('an old record (the window passed) is ignored', () async {
    final h = await host();
    port.rec = record(when: at - const Duration(minutes: 11).inMilliseconds);
    expect(await h.resumeAfterUpdate(), ResumeOutcome.stale);
    expect(runner.starts, 0);
    expect(h.phase, ConnectionPhase.disconnected);
  });

  test('the same version (nothing was replaced) is ignored', () async {
    final h = await host();
    port.rec = record(fromCode: 11, code: 11);
    expect(await h.resumeAfterUpdate(), ResumeOutcome.stale);
    expect(runner.starts, 0);
  });

  test('the user had switched the VPN off: it stays off', () async {
    final h = await host();
    port.rec = record(connected: false);
    expect(await h.resumeAfterUpdate(), ResumeOutcome.notWanted);
    expect(runner.starts, 0);
    expect(port.prompts, 0);
  });

  test('already connected (taken over): nothing is restarted', () async {
    final h = await host();
    expect((await h.connect()).started, isTrue);
    port.rec = record();
    expect(await h.resumeAfterUpdate(), ResumeOutcome.alreadyOn);
    expect(runner.starts, 1);
  });

  test('no VPN consent: no connect, the "tap to connect" notification instead', () async {
    final h = await host();
    vpn.consent = false;
    port.rec = record();

    expect(await h.resumeAfterUpdate(), ResumeOutcome.needsConsent);
    expect(runner.starts, 0);
    expect(port.prompts, 1);
    expect(port.dones, 1);
    expect(h.phase, ConnectionPhase.disconnected);
  });

  test('a resumed connect tells the tile and the notification; no window needed', () async {
    final h = await host();
    port.rec = record();
    final tile = _Tile();
    final notify = _Notify();

    expect(await resumeInBackground(h, tile: tile, notify: notify), ResumeOutcome.resumed);

    expect(tile.pushed.single.phase, 'on');
    expect(tile.pushed.single.name, isNotEmpty);
    expect(notify.nodes, hasLength(1));
    expect(notify.visible, [true]); // the native side keeps it; a headless start says it too
  });
}

class _Notify implements NotifyIo {
  final nodes = <String?>[];
  @override
  Future<void> setVpnNode(String? node) async => nodes.add(node);
  final visible = <bool>[];
  @override
  Future<void> setVpnVisible(bool v) async => visible.add(v);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
