// LiveCoreHost: the Priority order goes to the running core live (applyOrder), one plan per editing series
// (holdPlan / releasePlan), «Check again» (recheckSite). Spec: docs/connect-model.md 466-480.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot, testBoxes;

/// A real core that records what the host sends it and answers `applyOrder` / `recheckSite` as told.
class _OrderCore extends CoreService {
  _OrderCore({required super.dataDir, required super.runner})
    : super(singBox: '', boxFactory: testBoxes, sysProxy: NoSystemProxy(), isElevated: () => true, resolveAddresses: false);

  final connects = <Map<String, dynamic>>[];
  final orders = <Map<String, dynamic>>[];
  final disconnects = <Map<String, dynamic>?>[];
  final rechecks = <int>[];

  Map<String, dynamic> orderAnswer = {'applied': false}; // like the real core for anything but a Priority reorder
  Object? orderThrows;
  Object? recheckAnswer = {'ok': true, 'result': 'opens'};

  @override
  Future<Map<String, dynamic>> connect(Map<String, dynamic> body) {
    connects.add(body);
    return super.connect(body);
  }

  @override
  Future<Map<String, dynamic>> disconnect({Map<String, dynamic>? error, Map<String, dynamic>? op}) {
    disconnects.add(error);
    return super.disconnect(error: error, op: op);
  }

  @override
  Future<Map<String, dynamic>> applyOrder(Map<String, dynamic> plan) async {
    orders.add(plan);
    if (orderThrows != null) throw orderThrows!;
    return orderAnswer;
  }

  @override
  Future<Map<String, dynamic>> recheckSite(int eventId) async {
    rechecks.add(eventId);
    final a = recheckAnswer;
    if (a is Map<String, dynamic>) return a;
    throw a!;
  }
}

void main() {
  late Directory dir;
  late _OrderCore core;
  late LiveCoreHost host;

  Future<void> start({Duration reconnectDelay = const Duration(milliseconds: 20)}) async {
    dir = Directory.systemTemp.createTempSync('jorm_order_');
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(snapshot()));
    core = _OrderCore(dataDir: dir.path, runner: FakeRunner());
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: reconnectDelay,
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
    host.catalog.setRouteRowMode('a', 'priority'); // a Priority row with two servers on entry a
    host.setGlobal(true); // no rule lists to fetch through the fake runner's dead port
    await host.connect();
    core.connects.clear();
    core.orders.clear();
  }

  tearDown(() async {
    try {
      await host.shutdown();
      host.dispose();
    } catch (_) {}
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle([int ms = 200]) => Future<void>.delayed(Duration(milliseconds: ms));

  void reorder(List<String> keys) {
    host.reorderPick('a', keys);
  }

  var seq = 0;
  void addRule(String domain) {
    final r = UserRule(
      id: 'tmp',
      enabled: true,
      action: 'direct',
      groups: {
        'domain': {
          'v': {
            'domain_suffix': [domain],
          },
        },
      },
    );
    expect(host.catalog.saveRule(r), isNull);
    host.changed();
  }

  String freshDomain() => 'site${seq++}.example.com';

  group('Priority order live', () {
    test('a reorder only: applyOrder gets the plan; applied:true -> no connect, no restart; the plan is taken', () async {
      await start();
      core.orderAnswer = {'applied': true};
      reorder(['a::a2', 'a::a1']);
      await settle();
      expect(core.orders, hasLength(1));
      expect(core.orders.single, isNotEmpty);
      expect(core.connects, isEmpty);
      expect(host.phase, ConnectionPhase.connected);

      // planSig taken: nothing is resent for the same state
      host.changed();
      await settle();
      expect(core.orders, hasLength(1));
      expect(core.connects, isEmpty);
    });

    test('applied:false -> the full plan goes with connect as before', () async {
      await start();
      core.orderAnswer = {'applied': false};
      reorder(['a::a2', 'a::a1']);
      await settle();
      expect(core.orders, hasLength(1));
      expect(core.connects, hasLength(1));
      expect(core.connects.single['plan'] ?? core.connects.single, isNotEmpty);
    });

    test('applyOrder throws -> falls back to connect', () async {
      await start();
      core.orderThrows = StateError('boom');
      reorder(['a::a2', 'a::a1']);
      await settle();
      expect(core.orders, hasLength(1));
      expect(core.connects, hasLength(1));
      expect(host.phase, ConnectionPhase.connected);
    });

    test('the plan given to applyOrder is the one connect would send', () async {
      await start();
      core.orderAnswer = {'applied': false};
      reorder(['a::a2', 'a::a1']);
      await settle();
      final sent = core.connects.single;
      final plan = sent['plan'] is Map ? sent['plan'] : sent;
      expect(jsonEncode(core.orders.single), jsonEncode(plan));
    });
  });

  group('one plan per editing series', () {
    test('control: a rule edit without a hold reaches the core as a connect', () async {
      await start();
      addRule(freshDomain());
      await settle();
      expect(core.connects, hasLength(1));
    });

    test('while held, rule edits send nothing; releasePlan sends exactly one connect at once (no reconnect-delay wait)', () async {
      await start(reconnectDelay: const Duration(seconds: 30));
      host.holdPlan();
      addRule(freshDomain());
      addRule(freshDomain());
      addRule(freshDomain());
      await settle();
      expect(core.orders, isEmpty);
      expect(core.connects, isEmpty);

      host.releasePlan();
      await settle();
      expect(core.connects, hasLength(1));
      host.holdPlan();
      host.releasePlan();
      await settle();
      expect(core.connects, hasLength(1));
    });

    test('edits reverted while held: nothing is sent on release', () async {
      await start(reconnectDelay: const Duration(seconds: 30));
      final before = host.catalog.ruleOrder.length;
      host.holdPlan();
      addRule(freshDomain());
      final id = host.catalog.ruleOrder.last;
      host.catalog.deleteRule(id);
      host.changed();
      expect(host.catalog.ruleOrder.length, before);
      host.releasePlan();
      await settle();
      expect(core.connects, isEmpty);
      expect(core.orders, isEmpty);
    });

    test('nested holds: sends only after the last release', () async {
      await start(reconnectDelay: const Duration(seconds: 30));
      host.holdPlan();
      host.holdPlan();
      addRule(freshDomain());
      host.releasePlan();
      await settle();
      expect(core.connects, isEmpty);
      host.releasePlan();
      await settle();
      expect(core.connects, hasLength(1));
    });

    test('a reorder while held waits too, and goes out (live) on release', () async {
      await start(reconnectDelay: const Duration(seconds: 30));
      core.orderAnswer = {'applied': true};
      host.holdPlan();
      reorder(['a::a2', 'a::a1']);
      await settle();
      expect(core.orders, isEmpty);
      expect(core.connects, isEmpty);
      host.releasePlan();
      await settle();
      expect(core.orders, hasLength(1));
      expect(core.connects, isEmpty);
    });

    test('pin loss while held ends the connection (the hold does not delay it)', () async {
      await start(); // the normal reconnect delay applies to the pin check; only the hold must not add to it
      host.pinRouteNode('a', 'a::a1');
      expect((await host.connect()).started, isTrue); // the pin is part of the running plan
      host.holdPlan();
      core.connects.clear();
      core.disconnects.clear();
      host.catalog.pinnedNode = 'a::gone';
      host.changed();
      await settle();
      expect(host.phase, ConnectionPhase.disconnected);
      expect(host.error, contains('Manual pick'));
      expect(core.disconnects, isNotEmpty);
      expect(core.connects, isEmpty);
      host.releasePlan();
    });

    test('a release without a change sends nothing', () async {
      await start(reconnectDelay: const Duration(seconds: 30));
      host.holdPlan();
      host.releasePlan();
      await settle();
      expect(core.connects, isEmpty);
      expect(core.orders, isEmpty);
    });
  });

  group('recheckSite', () {
    test('forwards the event id; true only on ok:true', () async {
      await start();
      expect(await host.recheckSite(7), isTrue);
      expect(core.rechecks, [7]);
      core.recheckAnswer = {'ok': true, 'result': 'blocked'};
      expect(await host.recheckSite(8), isTrue);
      core.recheckAnswer = {'ok': false, 'reason': 'notFound'};
      expect(await host.recheckSite(9), isFalse);
      expect(core.rechecks, [7, 8, 9]);
    });

    test('an error in the core: false, never throws', () async {
      await start();
      core.recheckAnswer = StateError('boom');
      expect(await host.recheckSite(1), isFalse);
    });
  });
}
