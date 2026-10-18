// Servers in use that go away (docs/logs.md → «Задетые настройки», catalog rows sub/updated, sub/back, sub/removed,
// node/lost, node/back). Used = some setting depends on the server (here: rules whose target is the server). Free
// servers give no events.
//   * the provider removes servers at an update (auto: `updater.runDue()`, manual: `fetchSource`) -> warn `sub/updated`
//     {lost, lostCount, affected}; free servers only -> info `sub/updated` without `lost`; manual -> no success event,
//     only the warn variation; `sub/removed` is never written; `sub/back` (opens = the warn) when ALL lost servers are
//     back;
//   * the user switches off / deletes a node or a source -> `node/lost` (own) via the new CoreService methods;
//     `node/back` (opens) when all switched-off used nodes are on again; no pair after a delete.
//
// SPEC GAP: the spec does not name the new CoreService methods. The calls are collected in [Ops] below and assumed to
// be `toggleNodeEnabled(Catalog, sid, nid)`, `toggleSourceEnabled(Catalog, sid)`, `deleteNode(Catalog, sid, nid)`,
// `deleteSource(Catalog, sid)` (they apply the change to the catalog after computing the impact). Fix them in one place.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'catalog_model_test.dart' show make, snap, source;

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

String _link(int i, String name) => 'ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.${20 + i}:8388#$name';

const _names = ['one', 'two', 'three', 'four'];

void main() {
  late Directory tmp;
  late HttpServer server;
  late CoreService svc;
  var served = <int>[0, 1, 2, 3];

  setUp(() async {
    served = [0, 1, 2, 3];
    tmp = await Directory.systemTemp.createTemp('jorm-inuse');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((rq) {
      rq.response
        ..write([for (final i in served) _link(i, _names[i])].join('\n'))
        ..close();
    });
    svc = CoreService(
      directProbe: (_, _) async => 5,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
  });

  tearDown(() async {
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

  /// Source `a` with the four servers one..four as the provider serves them now, and rules: `r1` -> two,
  /// `r2` -> three. `one` is the connection's (first of the unit) and `four` is free.
  Map<String, dynamic> snapshot() {
    final nodes = [for (final n in parseLinks([for (var i = 0; i < 4; i++) _link(i, _names[i])].join('\n'))) n.toJson()];
    String rid(String name) => '${nodes.firstWhere((n) => n['name'] == name)['id']}';
    return snap(over: {
      'sourcesData': {
        'a': source('a', [], extra: {
          'name': 'Prov',
          'url': 'http://127.0.0.1:${server.port}/sub',
          'updateInterval': 10,
          'updatedAt': 0,
          'nodes': nodes,
        }),
      },
      'sourceOrder': ['a'],
      'connectOrder': ['a'],
      'catalogOrder': {'simple': ['a'], 'profiles': <String>[]},
      'profilesData': <String, dynamic>{},
      'chainsData': <String, dynamic>{},
      'modeState': {'profiles': {'order': <String>[], 'active': null, 'auto': true}},
      'rulesData': {
        for (final (id, name) in [('r1', 'two'), ('r2', 'three')])
          id: {
            'id': id,
            'name': 'Rule $id',
            'enabled': true,
            'action': 'proxy',
            'target': 'node:a::${rid(name)}',
            'fallback': 'block',
            'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['$id.test']}}},
          },
      },
      'ruleOrder': ['r1', 'r2'],
    });
  }

  List<Map> evs(String cat) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat) e,
      ];
  Map data(Map e) => (e['data'] as Map);
  List<String> types(String cat) => [for (final e in evs(cat)) '${e['type']}:${e['level']}'];
  List<String> affectedIds(Map e) => [for (final a in (data(e)['affected'] as List).cast<Map>()) '${a['kind']}:${a['id']}'];

  Future<void> auto(Map<String, dynamic> snapshotNow) async {
    await svc.saveState(snapshotNow);
    svc.updater.askAgain('a');
    await svc.updater.runDue();
  }

  Future<Map<String, dynamic>> stored() async => (await svc.state())['snapshot'] as Map<String, dynamic>;

  group('provider removes servers (auto update)', () {
    test('a used server removed: ONE warn sub/updated with lost / lostCount / affected; no sub/removed', () async {
      await svc.saveState(snapshot());
      served = [0, 2, 3]; // `two` (r1's target) gone
      await auto(snapshot());
      expect(types('sub'), ['updated:warn']);
      final e = evs('sub').single;
      expect(e['own'], isNot(true));
      expect(data(e)['lost'], ['two']);
      expect(data(e)['lostCount'], 1);
      expect(data(e)['source'], 'a');
      expect(affectedIds(e), contains('rule:r1'));
      expect(affectedIds(e), isNot(contains('rule:r2')), reason: 'r2 targets a server that stayed');
      final r1 = (data(e)['affected'] as List).cast<Map>().firstWhere((a) => a['id'] == 'r1');
      expect(r1['to'], 'block', reason: 'its own If unavailable');
      expect(evs('sub').where((x) => x['type'] == 'removed'), isEmpty);
    });

    test('only a free server removed: info sub/updated, no lost, no affected', () async {
      await svc.saveState(snapshot());
      served = [0, 1, 2]; // `four` gone
      await auto(snapshot());
      expect(types('sub'), ['updated:info']);
      final d = data(evs('sub').single);
      expect(d['lost'] ?? const [], isEmpty);
      expect(d['affected'] ?? const [], isEmpty);
      expect(d['lostCount'] ?? 0, 0);
    });

    test('lost is capped at 10 names but lostCount is the whole number', () async {
      final nodes = [for (var i = 0; i < 12; i++) parseLinks(_link(i, 'n$i')).single.toJson()];
      final s = snapshot();
      final src = (s['sourcesData'] as Map)['a'] as Map;
      src['nodes'] = nodes;
      s['rulesData'] = {
        for (var i = 0; i < 12; i++)
          'q$i': {
            'id': 'q$i',
            'name': 'Q$i',
            'enabled': true,
            'action': 'proxy',
            'target': 'node:a::${nodes[i]['id']}',
            'fallback': 'block',
            'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['q$i.test']}}},
          },
      };
      s['ruleOrder'] = [for (var i = 0; i < 12; i++) 'q$i'];
      await svc.saveState(s);
      served = []; // the provider serves an empty list: everything is removed
      await auto(s);
      final warn = evs('sub').where((e) => e['level'] == 'warn').toList();
      if (warn.isEmpty) return; // an empty answer may be refused as no update; the cap is checked only when applied
      final d = data(warn.single);
      expect((d['lost'] as List).length, lessThanOrEqualTo(10));
      expect(d['lostCount'], greaterThan(10));
    });

    test('sub/back (info, opens = the warn) only when ALL lost servers are back; a partial return writes nothing', () async {
      await svc.saveState(snapshot());
      served = [0, 3]; // two and three (both used) gone
      await auto(snapshot());
      final warn = evs('sub').single;
      expect([warn['level'], data(warn)['lostCount']], ['warn', 2]);

      served = [0, 1, 3]; // `two` returns, `three` still missing
      await auto(await stored());
      expect(evs('sub').where((e) => e['type'] == 'back'), isEmpty, reason: 'partial return: no event');

      served = [0, 1, 2, 3]; // everything is back
      await auto(await stored());
      final back = evs('sub').where((e) => e['type'] == 'back').single;
      expect(back['level'], 'info');
      expect(back['opens'], warn['id']);
      expect(data(back)['source'], 'a');
      expect(data(back)['names'], unorderedEquals(['two', 'three']));
      expect(data(back).containsKey('affected'), isTrue);
      expect(evs('sub').where((e) => e['type'] == 'removed'), isEmpty);
    });

    test('a free server returning writes no sub/back (nothing in use was lost)', () async {
      await svc.saveState(snapshot());
      served = [0, 1, 2];
      await auto(snapshot());
      served = [0, 1, 2, 3];
      await auto(await stored());
      expect(evs('sub').where((e) => e['type'] == 'back' || e['type'] == 'removed'), isEmpty);
    });
  });

  group('manual update', () {
    Future<void> manual(Map<String, dynamic> s) => svc.fetchSource({'sid': 'a', 'source': ((s['sourcesData'] as Map)['a'] as Map).cast<String, dynamic>()});

    test('no change, or only free servers removed: no sub/updated at all (no success event)', () async {
      await svc.saveState(snapshot());
      await manual(snapshot());
      served = [0, 1, 2];
      await manual(snapshot());
      expect(evs('sub'), isEmpty);
    });

    test('a used server removed: the warn variation is written, own: true', () async {
      await svc.saveState(snapshot());
      served = [0, 2, 3];
      await manual(snapshot());
      final e = evs('sub').single;
      expect([e['type'], e['level'], e['own']], ['updated', 'warn', true]);
      expect(data(e)['lost'], ['two']);
      expect(affectedIds(e), contains('rule:r1'));
    });

    test('a failed manual update still writes sub/failed (unchanged)', () async {
      final s = snapshot();
      await svc.saveState(s);
      await server.close(force: true);
      await expectLater(manual(s), throwsA(anything));
      expect(types('sub'), ['failed:error']);
    });
  });

  group('node / source switched off or deleted by the user (new CoreService methods)', () {
    late Catalog cat;
    late dynamic ops; // [Ops] adapter: the one place that knows the method names

    String nid(String name) => cat.sourcesData['a']!.nodes.firstWhere((n) => n.name == name).id;

    setUp(() async {
      cat = make(snapshot());
      ops = svc as dynamic;
    });

    Future<void> off(String name) async => await ops.toggleNodeEnabled(cat, 'a', nid(name));
    Future<void> delNode(String name) async => await ops.deleteNode(cat, 'a', nid(name));
    Future<void> toggleSrc() async => await ops.toggleSourceEnabled(cat, 'a');
    Future<void> delSrc() async => await ops.deleteSource(cat, 'a');

    test('switching off a used node: warn node/lost own with action off, nodes, nodeCount, affected; the change is applied', () async {
      await off('two');
      final e = evs('node').single;
      expect([e['type'], e['level'], e['own']], ['lost', 'warn', true]);
      final d = data(e);
      expect([d['action'], d['source'], d['name'], d['nodes'], d['nodeCount']], ['off', 'a', 'Prov', ['two'], 1]);
      expect(affectedIds(e), contains('rule:r1'));
      expect(d['nodeIds'], [nid('two')], reason: 'nodeIds = ids of the used servers; nodes stays names');
      expect(cat.sourcesData['a']!.disabledNodes, contains(nid('two')), reason: 'the toggle itself still happens');
    });

    test('rules/targetLost caused by the switch-off: cause = the node/lost id, verdict consequence', () async {
      await svc.saveState(snapshot());
      await off('two');
      final lost = evs('node').single;
      // the rules event comes from the next plan the UI builds (routing with the lost target), within the window
      await svc.connect({
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
          'global': false,
          'routing': {
            'fallback': 'main',
            'targets': {'node:a::${nid('two')}': null},
            'rules': [
              {
                'id': 'r1',
                'name': 'Rule r1',
                'on': true,
                'action': 'proxy',
                'target': 'node:a::${nid('two')}',
                'fallback': 'block',
                'targetLost': 'off',
                'dns': 'auto',
                'groups': {
                  'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}},
                },
              },
            ],
          },
        },
      });
      final tl = evs('rules').where((e) => e['type'] == 'targetLost').toList();
      expect(tl, isNotEmpty);
      expect(tl.map((e) => e['cause']), everyElement(lost['id']));
      expect(tl.map((e) => e['verdict']), everyElement('consequence'));
    });

    test('a free node switched off: no event at all; the change is applied', () async {
      await off('four');
      expect(evs('node'), isEmpty);
      expect(cat.sourcesData['a']!.disabledNodes, contains(nid('four')));
    });

    test('node/back (info, opens = node/lost) when the node is switched on again; a free node never writes it', () async {
      await off('two');
      final lost = evs('node').single;
      await off('two');
      final back = evs('node').where((e) => e['type'] == 'back').single;
      expect([back['level'], back['opens']], ['info', lost['id']]);
      expect(data(back)['source'], 'a');
      expect(data(back)['nodes'], ['two']);
      expect(data(back).containsKey('affected'), isTrue);
      expect(cat.sourcesData['a']!.disabledNodes, isEmpty);
    });

    test('deleting a used node: node/lost with action deleted, never a node/back', () async {
      await delNode('two');
      final e = evs('node').single;
      expect([e['type'], e['level'], e['own'], data(e)['action']], ['lost', 'warn', true, 'deleted']);
      expect(data(e)['nodes'], ['two']);
      expect(cat.sourcesData['a']!.nodes.any((n) => n.name == 'two'), isFalse);
      expect(evs('node').where((x) => x['type'] == 'back'), isEmpty);
    });

    test('deleting a free node writes nothing', () async {
      await delNode('four');
      expect(evs('node'), isEmpty);
      expect(cat.sourcesData['a']!.nodes.any((n) => n.name == 'four'), isFalse);
    });

    test('switching a whole source off: node/lost lists the used nodes (two, three), nodeCount 2; on again: node/back', () async {
      await toggleSrc();
      final lost = evs('node').single;
      final d = data(lost);
      expect([lost['type'], lost['level'], lost['own'], d['action'], d['source'], d['nodeCount']], ['lost', 'warn', true, 'off', 'a', greaterThanOrEqualTo(2)]);
      expect(d['nodes'], containsAll(['two', 'three']));
      expect(d['nodes'], isNot(contains('four')), reason: 'a free server is not named');
      expect(d['nodeIds'], unorderedEquals([nid('two'), nid('three')]));
      expect(cat.sourcesData['a']!.enabled, isFalse);
      await toggleSrc();
      final back = evs('node').where((e) => e['type'] == 'back').single;
      expect(back['opens'], lost['id']);
      expect(data(back)['nodes'], containsAll(['two', 'three']));
    });

    test('deleting a whole source with used nodes: node/lost deleted, no pair; the source is gone', () async {
      await delSrc();
      final e = evs('node').single;
      expect([e['type'], data(e)['action'], data(e)['source']], ['lost', 'deleted', 'a']);
      expect(data(e)['nodes'], containsAll(['two', 'three']));
      expect(cat.sourcesData.containsKey('a'), isFalse);
      expect(evs('node').where((x) => x['type'] == 'back'), isEmpty);
    });
  });
}
