// The Dart catalog against the mockup's own JavaScript: core/test/golden/catalog.json was made by
// core/tool/catalog_golden.mjs, which runs design/main_screen.html through the scenarios (the seed
// of 10-data.js with ping / switch / mode variations) and records the snapshot plus what the JS answers
// on it. Here the same snapshot goes into Catalog.fromJson and every answer is compared: the connect
// entry and servers, broken entries, the plan and its signature, targets, delete impact, and — for the
// `op-*` scenarios — the snapshot after the Dart op against the one after the mockup's function.
//
// Comparing snapshots, null values and empty lists count as absent: the JS creates `pickOrder: []` on
// every profile when it purges, the Dart keeps a key out while the input did not have it. Both read the
// same way back. (catalog_model_test.dart checks the strict round-trip.)
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

typedef J = Map<String, dynamic>;

J asJ(Object? v) => J.from(v as Map);

String? hashOf(String? s) {
  if (s == null) return null;
  var a = 0x811c9dc5, b = 5381;
  for (final cu in s.codeUnits) {
    a = ((a ^ cu) * 16777619) & 0xFFFFFFFF;
    b = (b * 33 + cu) & 0xFFFFFFFF;
  }
  return '${s.length}:${a.toRadixString(16)}:${b.toRadixString(16)}';
}

Object? plain(Object? v) => jsonDecode(jsonEncode(v));

/// The mockup's list of DNS servers is the one it had before the DNS rework (one address and one side per server,
/// no migration marker): the snapshots are read as a list already at the current version, and the new fields are
/// folded back into `addr` / `via` when compared (until the mockup sync pass, `mockup_todo.md`).
J _mockupDns(J snapshot) => {
      ...snapshot,
      'dnsCfg': {...?(snapshot['dnsCfg'] as Map?)?.cast<String, dynamic>(), 'listVersion': dnsListVersion},
    };

Map<String, dynamic> _legacyDnsServer(Map v) {
  final ts = v['transports'] as List;
  final sides = (v['sides'] as List?) ?? const ['vpn'];
  return {
    for (final e in v.entries)
      if (!const {'transports', 'sides', 'use'}.contains(e.key)) '${e.key}': e.value,
    'addr': ts.isEmpty ? '' : (ts.first as Map)['addr'],
    'via': sides.contains('vpn') ? 'vpn' : 'direct',
  };
}

/// Null and empty list = absent; pings as a map.
Object? norm(Object? v, [String? key]) {
  if (v is Map) {
    if (v['transports'] is List && v.containsKey('id')) v = _legacyDnsServer(v);
    return {
      for (final e in v.entries)
        if (e.value != null &&
            !(e.value is List && (e.value as List).isEmpty) &&
            !(key == 'dnsCfg' && (e.key == 'directPolicy' || e.key == 'listVersion')))
          '${e.key}': norm(e.value, '${e.key}'),
    };
  }
  if (key == 'pings' && v is List) return {for (final p in v) (p as List)[0]: norm(p[1])};
  if (v is List) return [for (final x in v) norm(x)];
  return v;
}

/// JSON with the keys of every map sorted: equal data = equal strings.
String canon(Object? v) => jsonEncode(_sorted(v));
Object? _sorted(Object? v) => v is Map
    ? {for (final k in (v.keys.map((e) => '$e').toList()..sort())) k: _sorted(v[k])}
    : v is List
        ? [for (final x in v) _sorted(x)]
        : v;

/// Where [a] and [b] first differ (a path and both values), or null when equal.
String? firstDiff(Object? a, Object? b, [String path = '']) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      final d = firstDiff(a[k], b[k], '$path/$k');
      if (d != null) return d;
    }
    return null;
  }
  if (a is List && b is List && a.length == b.length) {
    for (var i = 0; i < a.length; i++) {
      final d = firstDiff(a[i], b[i], '$path[$i]');
      if (d != null) return d;
    }
    return null;
  }
  return canon(a) == canon(b) ? null : '$path: ${canon(a)} != ${canon(b)}';
}

/// The snapshot diff of the generator applied to [base]: whole keys, the entity maps per entry.
J applyDiff(J base, J diff) {
  final out = <String, dynamic>{...(plain(base) as J)};
  for (final e in diff.entries) {
    final v = e.value;
    if (v is Map && v.containsKey('__patch')) {
      final m = <String, dynamic>{...(out[e.key] as Map).cast<String, dynamic>()};
      for (final p in (v['__patch'] as Map).entries) {
        if (p.value is Map && (p.value as Map).containsKey('__del')) {
          m.remove(p.key);
        } else {
          m[p.key as String] = p.value;
        }
      }
      out[e.key] = m;
    } else {
      out[e.key] = v;
    }
  }
  return out;
}

String? keyOfNode(Catalog c, CatalogNode? n) {
  if (n == null) return null;
  for (final s in c.sourcesData.values) {
    if (s.nodes.any((x) => identical(x, n))) return '${s.id}::${n.id}';
  }
  return null;
}

Map<String, dynamic>? grp(Json? g) => g == null
    ? null
    : {
        'pick': g['pick'],
        'chosen': g['chosen'],
        'pinned': g['pinned'] == true,
        'keys': [for (final n in g['nodes'] as List) (n as Map)['key']],
      };

const targets = [
  '', 'src:src1', 'src:src2', 'src:src3', 'src:src4', 'src:ghost', 'node:src1::n0', 'node:src1::n5', 'node:src2::n8', 'node:src2::n1', //
  'node:ghost::n1', 'node:src1::ghost', 'profile:default', 'profile:work', 'profile:gaming', 'profile:ghost', 'chain:sc1', 'chain:cpgaming',
  'chain:ghost', 'src1', 'sc1', 'default', 'zzz',
];

/// What the generator's `results()` records, computed by the Dart catalog.
J compute(Catalog c, {required bool full, required bool rt}) {
  final ids = [...c.connectOrder];
  final r = <String, dynamic>{};
  r['effective'] = c.effectiveConnectId();
  r['own'] = c.effectiveConnectId(true);
  r['whenAuto'] = c.effectiveConnectIdWhenAuto();
  r['nothingInAuto'] = c.nothingInAuto();
  r['catalogEmpty'] = c.catalogEmpty();
  r['visible'] = c.visibleOrder();
  r['broken'] = c.brokenOrder();
  r['autoOrder'] = c.autoOrder();
  final brokenBy = <String, dynamic>{}, brokenText = <String, dynamic>{}, mayWork = <String, dynamic>{}, picks = <String, dynamic>{}, usable = <String, dynamic>{};
  for (final id in ids) {
    final b = c.brokenBy(id);
    brokenBy[id] = [for (final x in b) [x.sid, x.nid]];
    if (b.isNotEmpty) brokenText[id] = c.reasonsText(b);
    mayWork[id] = c.mayWork(id);
    usable[id] = c.isUsable(id);
    final ch = c.chainsData[id];
    picks[id] = ch != null
        ? {'entry': keyOfNode(c, c.chainEntryNode(ch)), 'exit': keyOfNode(c, c.chainExitNode(ch))}
        : {'node': keyOfNode(c, c.unitNode(id))};
  }
  r..['brokenBy'] = brokenBy..['brokenText'] = brokenText..['mayWork'] = mayWork..['picks'] = picks..['usable'] = usable;
  Plan? plan;
  try {
    plan = c.livePlan();
    r['planBrief'] = {
      'current': plan['current'],
      'routes': [
        for (final x in plan['routes'] as List)
          {
            'id': (x as Map)['id'],
            'kind': x['kind'],
            'main': grp(asJ(x['main'])),
            'entry': grp(x['entry'] == null ? null : asJ(x['entry'])),
          },
      ],
    };
    if (full) r['plan'] = plain(plan);
  } on CatalogException catch (e) {
    r['planBrief'] = {'error': e.message};
  }
  r['planSig'] = hashOf(c.planSig());
  final anchors = <String, dynamic>{};
  for (final id in ids) {
    try {
      final p = c.livePlan(id);
      anchors[id] = {
        'routes': [for (final x in p['routes'] as List) (x as Map)['id']],
        'current': p['current'],
        'sig': hashOf(c.planSigOf(p)),
      };
    } on CatalogException catch (e) {
      anchors[id] = {'error': e.message};
    }
  }
  r['anchors'] = anchors;
  r['findAnchor'] = [c.autoOrder(), ['sc1', 'src2'], ['zzz']].map(c.liveFindAnchor).toList();
  r['goneLeft'] = {
    for (final s in c.sourcesData.values)
      for (final n in s.gone) '${s.id}::${n.id}': c.goneLeftDays(n),
  };
  if (!full) return r;
  r['targets'] = {
    for (final t in targets)
      t: () {
        final i = c.targetInfo(t);
        return [i.kind, i.name, i.flag, i.gone, i.ok];
      }(),
  };
  if (rt) r['routingTargets'] = {for (final t in targets) t: t.isEmpty ? null : plain(c.routingTarget(t))};
  final impact = {'src': <String, dynamic>{}, 'node': <String, dynamic>{}, 'entry': <String, dynamic>{}};
  List<List<String>> lines(List<ImpactLine> l) => [for (final x in l) x.toList()];
  for (final sid in c.sourceOrder) {
    impact['src']![sid] = lines(c.deleteSourceImpact(sid));
    for (final nid in const ['n0', 'n6']) {
      if (c.sourcesData[sid]!.nodes.any((n) => n.id == nid)) impact['node']!['$sid::$nid'] = lines(c.deleteNodeImpact(sid, nid));
    }
  }
  for (final id in [...c.profilesData.keys, ...c.chainsData.keys]) {
    impact['entry']![id] = lines(c.deleteEntryImpact(id));
  }
  r['impact'] = impact;
  r['nodeDead'] = {
    for (final s in c.sourcesData.values)
      for (final n in s.nodes)
        if (c.knownDead(n)) '${s.id}::${n.id}': true,
  };
  return r;
}

final _src9 = {
  'id': 'src9',
  'kind': 'node',
  'name': 'New',
  'enabled': true,
  'nodes': [
    {'id': 'n0', 'name': 'X', 'flag': '🇩🇪', 'protocol': 'vless', 'address': 'x.example', 'port': 443, 'outbound': {'o': 'x'}},
  ],
};

/// The mockup's function of each `op-*` scenario, as the Dart op (plus what JS' `renderConnects` does:
/// `syncCatalog`).
final Map<String, void Function(Catalog)> ops = {
  'op-select-src2': (c) => c.selectConnect('src2'),
  'op-select-twice': (c) => c.selectConnect('src2'),
  'op-auto-off': (c) => c.setAutoConnect(false),
  'op-auto-on': (c) => c.setAutoConnect(true),
  'op-pin': (c) => c.pinRouteNode('src1', 'src1::n2'),
  'op-pin-again': (c) => c.pinRouteNode('src1', 'src1::n2'),
  'op-toggle-auto': (c) => c.toggleEntryAuto('src2'),
  'op-mode-profiles': (c) => c.setConnectMode('profiles'),
  'op-mode-roundtrip': (c) {
    c.setConnectMode('profiles');
    c
      ..autoConnect = false
      ..activeConnectId = 'gaming';
    c.setConnectMode('simple');
  },
  'op-delete-src1': (c) => c.deleteSource('src1'),
  'op-delete-src4': (c) => c.deleteSource('src4'),
  'op-delete-node': (c) => c.deleteNode('src1', 'n2'),
  'op-delete-profile': (c) => c.deleteProfile('default'),
  'op-delete-profile-active': (c) => c.deleteProfile('gaming'),
  'op-delete-chain': (c) => c.deleteChain('sc1'),
  'op-forget-gone': (c) => c.forgetGone('src1'),
  'op-forget-one': (c) => c.forgetGone('src1', ['n19']),
  'op-purge-gone': (c) => c.purgeExpiredGone(),
  'op-enable-source': (c) => c.enableSource('src2'),
  'op-toggle-source': (c) => c.toggleSourceEnabled('src2'),
  'op-enable-node': (c) => c.enableNode('src3', 'n0'),
  'op-toggle-node': (c) {
    c.toggleNodeEnabled('src2', 'n1');
    c.toggleNodeEnabled('src2', 'n8');
  },
  'op-drag-route': (c) => c.reorderRoute(c.visibleOrder().reversed.toList()),
  'op-drag-route-hidden': (c) => c.reorderRoute(c.visibleOrder().reversed.toList()),
  'op-reset-order': (c) => c.resetRouteOrder(),
  'op-route-custom-sync': (c) => c.addSource(Source.fromJson(asJ(plain(_src9)))),
  'op-route-node-drag': (c) => c.reorderUnitPick('src1', c.unitPickRefs('src1').map((r) => r.key).toList().reversed.toList()),
  'op-row-mode': (c) => c.setRouteRowMode('src2', 'priority'),
};

/// Scenarios where core logic moved ahead of the frozen mockup (`.claude_states/mockup_todo.md`):
/// skipped until the mockup gets the same change and the golden file is regenerated.
const _mockupBehind = <String, String>{
  'priority-source': 'chainExitOrder follows the exit unit pickOrder (mockup_todo.md)',
  'op-route-node-drag': 'chainExitOrder follows the exit unit pickOrder (mockup_todo.md)',
  'src1-dead': 'a chain exit lives by its pair through the entry, not by its direct ping (mockup_todo.md)',
  'op-auto-off': 'a chain exit lives by its pair through the entry, not by its direct ping (mockup_todo.md)',
};

/// FakeIP is removed from the core until it is redesigned, the frozen mockup still has it:
/// drop its keys from the golden file until the mockup sync pass (`mockup_todo.md`).
void _dropFakeip(dynamic v) {
  if (v is Map) {
    v.remove('fakeip');
    v.remove('fakeipExclude');
    v.values.forEach(_dropFakeip);
  } else if (v is List) {
    v.forEach(_dropFakeip);
  }
}

void main() {
  final golden = jsonDecode(File('test/golden/catalog.json').readAsStringSync()) as J;
  _dropFakeip(golden);
  final now = golden['now'] as int;
  final base = golden['base'] as J;
  final apps = (golden['apps'] as Map).cast<String, dynamic>();
  final scenarios = [for (final s in golden['scenarios'] as List) s as J];

  Catalog load(J snapshot, J meta) {
    final c = Catalog.fromJson(_mockupDns(snapshot), now: () => now);
    c.mockupPlan = true; // the mockup's plan: Manual = the anchor alone
    c.appInfo = (pkg) {
      final a = apps[pkg];
      return a == null ? null : (name: a['name'] as String, kind: (a['kind'] ?? '') as String);
    };
    final cr = meta['coreRoute'];
    if (cr is Map) c.coreRoute = CoreRoute(id: cr['id'] as String, server: cr['server'] as String?, entryServer: cr['entryServer'] as String?);
    return c;
  }

  /// Keys of [want] where [got] differs (a readable report instead of one huge matcher dump).
  List<String> mismatches(J want, J got) {
    final out = <String>[];
    for (final k in want.keys) {
      final a = canon(norm(want[k])), b = canon(norm(plain(got[k])));
      if (a != b) out.add('$k\n   JS : ${a.length > 600 ? '${a.substring(0, 600)}…' : a}\n   Dart: ${b.length > 600 ? '${b.substring(0, 600)}…' : b}');
    }
    return out;
  }

  group('golden: answers on the mockup snapshots', () {
    for (final sc in scenarios) {
      final name = sc['name'] as String;
      test(name, skip: _mockupBehind[name], () {
        final snap = applyDiff(base, sc['snapshot'] as J);
        final c = load(snap, sc['meta'] as J);
        final want = sc['results'] as J;
        final got = compute(c, full: want.containsKey('targets'), rt: want.containsKey('routingTargets'));
        expect(mismatches(want, got), isEmpty);
        // the same state read and written again
        expect(firstDiff(norm(snap), norm(plain(Catalog.fromJson(_mockupDns(snap), now: () => now).toJson()))), isNull, reason: 'snapshot round trip');
        // the planSig string itself, not only its hash, must not depend on pings: reorder and compare
        if (want['planSig'] != null) {
          final plan = c.livePlan(c.liveSigAnchor());
          expect(hashOf(c.planSigOf(plan)), want['planSig']);
        }
      });

      if (sc['op'] != null) {
        test('$name (snapshot after the op)', skip: _mockupBehind[name], () {
          final fn = ops[name];
          expect(fn, isNotNull, reason: 'no Dart op for the scenario $name');
          final snap = applyDiff(base, sc['snapshot'] as J);
          final c = load(snap, sc['meta'] as J);
          fn!(c);
          c.syncCatalog();
          final want = applyDiff(snap, sc['after'] as J);
          final a = norm(want) as Map, b = norm(plain(c.toJson())) as Map;
          final bad = <String>[];
          for (final k in {...a.keys, ...b.keys}) {
            final x = canon(a[k]), y = canon(b[k]);
            if (x != y) {
              bad.add('$k\n   JS : ${x.length > 800 ? '${x.substring(0, 800)}…' : x}\n   Dart: ${y.length > 800 ? '${y.substring(0, 800)}…' : y}');
            }
          }
          expect(bad, isEmpty);
        });
      }
    }
  });
}
