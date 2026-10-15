// The background ping after a connect (the route's subscriptions, its top first) and the guard
// against pinging the same servers twice at once — docs/connect-model.md → Ping.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot, testBoxes;

/// A core whose ping is held until [gate] opens and which remembers the servers it was asked about.
class _RecPingCore extends CoreService {
  _RecPingCore({required super.dataDir, required super.runner})
    : super(singBox: '', boxFactory: testBoxes, sysProxy: NoSystemProxy(), isElevated: () => true, resolveAddresses: false);

  final asked = <List<String>>[];
  Completer<void>? gate;

  @override
  Stream<Map<String, dynamic>> ping(Map<String, dynamic> body) async* {
    final keys = [for (final n in (body['nodes'] as List? ?? const [])) (n as Map)['key'] as String];
    asked.add(keys);
    if (gate != null) await gate!.future;
    for (final k in keys) {
      yield {'kind': 'n', 'key': k, 'ms': 40};
    }
    // pairs: the 2nd exit answers through a backup check only
    final pairKeys = [for (final p in (body['pairs'] as List? ?? const [])) (p as Map)['key'] as String];
    for (var i = 0; i < pairKeys.length; i++) {
      yield {'kind': 'p', 'key': pairKeys[i], 'ms': 70 + i, if (i == 1) 'byChecker': true};
    }
    yield {'done': true, 'network': 'up'};
  }
}

void main() {
  late Directory dir;
  late _RecPingCore core;
  late LiveCoreHost host;

  Future<void> start() async {
    dir = Directory.systemTemp.createTempSync('jorm_routeping_');
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(snapshot()));
    core = _RecPingCore(dataDir: dir.path, runner: FakeRunner());
    host = LiveCoreHost(
      api: core,
      isAndroid: false,
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 40),
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

  Future<void> settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

  test('after a connect the route\'s subscription is pinged in the background, its best known server first', () async {
    await start();
    final a = host.catalog.sourcesData['a']!.nodes;
    host.catalog.pings.set(a[0], 200);
    host.catalog.pings.set(a[1], 30);
    host.setGlobal(true); // no rule lists to fetch through the fake runner's dead port

    await host.connect();
    await settle();

    expect(core.asked, [
      ['a2', 'a1'], // the route's subscription only (b is another one), the answered-fastest first
    ]);
    expect(host.catalog.pings.ping(a[0]), 40);
    expect(host.catalog.pings.anyTesting, isFalse);
  });

  test('a chain-exit pair answered only by a backup check is stored weak and ranks after a strong pair', () async {
    await start();
    final catalog = host.catalog;
    final chain = Chain(id: 'c1', name: 'C', inId: 'b', outId: 'a');
    catalog.chainsData['c1'] = chain;
    catalog.catalogOrder['simple']!.add('c1');
    final b1 = catalog.sourcesData['b']!.nodes.single;
    final a = catalog.sourcesData['a']!.nodes;
    catalog.pings.set(b1, 20);

    await host.pingChain(chain, entries: false);

    expect(core.asked.where((k) => k.isEmpty), isNotEmpty, reason: 'the pair request carries no direct nodes');
    expect(catalog.pairs.entry(b1, a[0])!.byChecker, isFalse);
    expect(catalog.pairs.entry(b1, a[1])!.byChecker, isTrue);
    expect(catalog.chainExitRank(chain, a[1]), greaterThan(catalog.chainExitRank(chain, a[0])));
    expect(catalog.chainExitRank(chain, a[1]), weakRankBase + 71);
  });

  test('servers already being pinged are not pinged a second time at once; the caller waits for the run in flight', () async {
    await start();
    final a = host.catalog.sourcesData['a']!.nodes;
    core.gate = Completer<void>();

    final first = host.pingNodes(a);
    await settle(20);
    expect(host.catalog.pings.entry(a[0])!.testing, isTrue);
    var secondDone = false;
    final second = host.pingNodes([a[1]]).then((_) => secondDone = true);
    await settle(20);

    expect(core.asked, hasLength(1)); // not asked again
    expect(secondDone, isFalse); // waits for the run that has its answer
    core.gate!.complete();
    await Future.wait([first, second]);
    expect(host.catalog.pings.ping(a[1]), 40);

    // a mixed call: only the servers not being pinged go out
    core.gate = Completer<void>();
    final run = host.pingNodes([a[0]]);
    await settle(20);
    final b1 = host.catalog.sourcesData['b']!.nodes.single;
    final mixed = host.pingNodes([a[0], b1]);
    await settle(20);
    expect(core.asked.last, ['b1']);
    core.gate!.complete();
    await Future.wait([run, mixed]);
  });
}
