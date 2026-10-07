// What keeps the UI from rebuilding per event: LiveCoreHost joins the notifications of a ping run,
// the traffic ticks go to their own notifier, a hidden tab's gate holds the host's rebuilds back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot, source;

/// A core whose ping answers at once for every server, and whose traffic changes every call.
class _ScriptCore extends CoreService {
  _ScriptCore({required super.dataDir, required super.runner})
    : super(singBox: '', boxFactory: (_) => FakeRunner(), sysProxy: NoSystemProxy(), isElevated: () => true);

  int ticks = 0;

  @override
  Stream<Map<String, dynamic>> ping(Map<String, dynamic> body) async* {
    for (final n in body['nodes'] as List) {
      yield {'kind': 'n', 'key': (n as Map)['key'], 'ms': 40};
    }
    yield {'done': true, 'network': 'up'};
  }

  @override
  Future<Map<String, dynamic>> traffic() async {
    ticks++;
    return {'down': ticks * 1000, 'up': ticks * 10, 'downTotal': ticks * 1000, 'upTotal': ticks * 10, 'tcp': 1, 'udp': 0, 'conns': const []};
  }
}

void main() {
  late Directory dir;
  late _ScriptCore core;
  late LiveCoreHost host;
  var started = false;

  Future<void> start({int servers = 2}) async {
    dir = Directory.systemTemp.createTempSync('jorm_notify_');
    final snap = snapshot();
    (snap['sourcesData'] as Map)['a'] = source('a', [for (var i = 0; i < servers; i++) 'a$i']);
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(snap));
    core = _ScriptCore(dataDir: dir.path, runner: FakeRunner());
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 40),
      notifyEvery: const Duration(milliseconds: 60),
    );
    await host.init();
    started = true;
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await host.shutdown();
    host.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a ping run of 200 servers: every answer lands, the listeners hear of it a few times', () async {
    await start(servers: 200);
    final nodes = host.catalog.sourcesData['a']!.nodes;
    var heard = 0;
    host.addListener(() => heard++);

    await host.pingNodes(nodes);

    expect(nodes.every((n) => host.catalog.pings.ping(n) == 40), isTrue);
    expect(host.catalog.pings.anyTesting, isFalse);
    // "pinging" at once, the answers joined, the end (changed) at once: not one per answer
    expect(heard, lessThanOrEqualTo(4), reason: '$heard notifications for 200 answers');
    expect(heard, greaterThanOrEqualTo(2));
  });

  test('flushNotify delivers what the window still holds', () async {
    await start(servers: 3);
    var heard = 0;
    host.addListener(() => heard++);
    host.catalog.pings.set(host.catalog.sourcesData['a']!.nodes.first, 5);
    // a held notification: the status path of a ping-only status joins the window
    unawaited(host.pingNodes(host.catalog.sourcesData['a']!.nodes));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    host.flushNotify();
    expect(heard, greaterThanOrEqualTo(1));
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('traffic ticks go to the traffic notifier, not to the host', () async {
    await start();
    await host.connect();
    await Future<void>.delayed(const Duration(milliseconds: 250)); // the exit check and status settle
    var hostHeard = 0, trafficHeard = 0;
    host.addListener(() => hostHeard++);
    host.trafficNotifier.addListener(() => trafficHeard++);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(trafficHeard, greaterThanOrEqualTo(3));
    expect(hostHeard, 0, reason: 'the host stays quiet while only the speed moves');
    expect(host.traffic.down, greaterThan(0));
  });

  test('HostGate: closed it holds the host back, opened it catches up once', () {
    final origin = ChangeNotifier();
    final gate = HostGate(origin, active: false);
    var heard = 0;
    gate.addListener(() => heard++);

    origin.notifyListeners();
    origin.notifyListeners();
    expect(heard, 0);
    gate.active = true;
    expect(heard, 1);
    origin.notifyListeners();
    expect(heard, 2);
    gate.active = false;
    gate.active = true; // nothing came meanwhile: nothing to catch up
    expect(heard, 2);
    gate.dispose();
    origin.dispose();
  });
}
