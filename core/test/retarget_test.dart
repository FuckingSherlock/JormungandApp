// `Catalog.retargetAll(affected, target)` (catalog/ops.dart): "Choose for all" of the affected-settings events
// (docs/logs.md → «Задетые настройки»). Sets `target` for every `rule` / `app` item and the route of a `connection`
// item; `chain` / `profile` items are ignored; '' = the main flow. Other settings stay untouched.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show make, snap;

Catalog lab() => make(snap(over: {
      'rulesData': {
        for (final id in ['r1', 'r2', 'r3'])
          id: {
            'id': id,
            'name': 'Rule $id',
            'enabled': true,
            'action': 'proxy',
            'target': 'src:a',
            'fallback': 'block',
            'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['$id.test']}}},
          },
      },
      'ruleOrder': ['r1', 'r2', 'r3'],
      'appRules': {
        'org.a': {'act': 'proxy', 'target': 'src:a', 'fallback': 'direct', 'split': false},
        'org.b': {'act': 'proxy', 'target': 'src:a', 'fallback': 'direct', 'split': false},
      },
    }));

Map<String, dynamic> item(String kind, String id) => {'kind': kind, 'id': id, 'name': id, 'to': 'main'};

void main() {
  test('rules and apps named in affected get the target; ones not named stay', () {
    final c = lab();
    c.retargetAll([item('rule', 'r1'), item('rule', 'r3'), item('app', 'org.a')], 'src:b');
    expect(c.rulesData['r1']!.target, 'src:b');
    expect(c.rulesData['r3']!.target, 'src:b');
    expect(c.rulesData['r2']!.target, 'src:a', reason: 'not affected');
    expect(c.appRules['org.a']!.tcp.target, 'src:b');
    expect(c.appRules['org.b']!.tcp.target, 'src:a', reason: 'not affected');
    expect(c.rulesData['r1']!.fallback, 'block', reason: 'only the target moves');
    expect(c.rulesData['r1']!.action, 'proxy');
  });

  test('the connection item moves the route to the chosen target', () {
    final c = lab();
    expect(c.activeConnectId, 'a');
    c.retargetAll([item('connection', 'a')], 'src:b');
    expect(c.activeConnectId, 'b');
  });

  test('chain and profile items are ignored (no rule, route or entry changes)', () {
    final c = lab();
    final before = c.toJson();
    c.retargetAll([item('chain', 'c1'), item('profile', 'p')], 'src:b');
    expect(c.toJson(), before);
  });

  test('chain / profile mixed with rules: only the rules change', () {
    final c = lab();
    c.retargetAll([item('chain', 'c1'), item('rule', 'r2'), item('profile', 'p')], 'src:b');
    expect(c.rulesData['r2']!.target, 'src:b');
    expect(c.rulesData['r1']!.target, 'src:a');
    expect(c.chainsData['c1']!.inId, 'b', reason: 'the chain is untouched');
    expect(c.activeConnectId, 'a');
  });

  test("'' means the main flow: rules and apps get an empty target", () {
    final c = lab();
    c.retargetAll([item('rule', 'r1'), item('app', 'org.b')], '');
    expect(c.rulesData['r1']!.target, '');
    expect(c.appRules['org.b']!.tcp.target, '');
    expect(c.rulesData['r2']!.target, 'src:a');
  });

  test('an unknown id and an empty list change nothing and do not throw', () {
    final c = lab();
    final before = c.toJson();
    c.retargetAll(const [], 'src:b');
    c.retargetAll([item('rule', 'nope'), item('app', 'no.such')], 'src:b');
    expect(c.toJson(), before);
  });

  test('a split app: the target of a lost half moves, the other half keeps its own', () {
    final c = make(snap(over: {
      'appRules': {
        'org.s': {
          'act': 'proxy',
          'target': 'src:a',
          'fallback': 'direct',
          'split': true,
          'udp': {'act': 'proxy', 'target': 'src:zz', 'fallback': 'default'},
        },
      },
    }));
    c.retargetAll([item('app', 'org.s')], 'src:b');
    final a = c.appRules['org.s']!;
    expect([a.tcp.target, a.udp.target].contains('src:b'), isTrue, reason: 'at least the affected half moved');
  });
}
