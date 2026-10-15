// A rule / app whose target is lost (deleted, off, no servers, none sing-box can run): the plan says why
// (`targetLost`), the config reports it once (`RoutingInfo.lost`) and keeps routing by "If unavailable" (docs/rules.md §0
// «Потерянная цель»). The events at connect / recovery: service_test.dart.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show make, node, snap, source;

/// a, b are usable; `e` has no servers, `x` only XHTTP ones, `o` is switched off.
Catalog lab({Map<String, dynamic>? quick, List<Map<String, dynamic>> rules = const [], Map<String, dynamic> apps = const {}}) {
  final s = snap(over: {
    'sourcesData': {
      'a': source('a', ['1', '2', '3']),
      'b': source('b', ['1', '2']),
      'e': source('e', []),
      'x': source('x', ['1', '2'], extra: {
        'nodes': [for (final id in ['x1', 'x2']) {...node(id), 'unsupported': 'XHTTP'}],
      }),
      'o': source('o', ['1'], extra: {'enabled': false}),
    },
    'sourceOrder': ['a', 'b', 'e', 'x', 'o'],
    'rulesData': {
      for (final r in rules) '${r['id']}': {'enabled': true, 'action': 'proxy', 'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['${r['id']}.test']}}}, ...r},
    },
    'ruleOrder': [for (final r in rules) '${r['id']}'],
    'quickCfg': quick ?? <String, dynamic>{},
    'appRules': apps,
  });
  return make(s);
}

Map<String, dynamic> rule(String id, String target, {String fallback = 'default', String? via}) =>
    {'id': id, 'name': 'Rule $id', 'target': target, 'fallback': via == null ? fallback : 'main', 'fallbackTarget': ?via};

void main() {
  final all = [
    rule('rdel', 'src:zz', fallback: 'block'),
    rule('roff', 'src:o', fallback: 'direct'),
    rule('rno', 'src:e'),
    rule('runs', 'src:x', via: 'src:b'),
    rule('rok', 'src:b', fallback: 'block'),
  ];

  group('the plan', () {
    test('a lost target is named with its reason; a usable one has no targetLost', () {
      final c = lab(rules: all);
      final rules = {for (final r in (c.routingPlan()['rules'] as List).cast<Map>()) r['id']: r};
      expect(rules['rdel']!['targetLost'], 'deleted');
      expect(rules['roff']!['targetLost'], 'off');
      expect(rules['rno']!['targetLost'], 'noServers');
      expect(rules['runs']!['targetLost'], 'unsupported');
      expect(rules['rok']!.containsKey('targetLost'), isFalse);
      // a node of a lost source, a profile with nothing left, a chain: the same kinds of loss
      expect(c.targetLoss('node:o::o1'), 'off');
      expect(c.targetLoss('node:b::zz'), 'deleted');
      expect(c.targetLoss('profile:zz'), 'deleted');
      expect(c.targetLoss('chain:c1'), isNull);
      expect(c.targetLoss(''), isNull, reason: 'the main flow is never lost');
    });

    test('where the traffic goes: its own "If unavailable", Default = the global one, a lost fallback target = Default', () {
      var c = lab(rules: all);
      TargetLost lost(String id) => c.targetLost((c.rulesData[id]!).target, c.planRuleFallback(c.rulesData[id]!))!;
      expect([lost('rdel').to, lost('rdel').byDefault], ['block', false]);
      expect([lost('roff').to, lost('roff').byDefault], ['direct', false]);
      expect([lost('rno').to, lost('rno').byDefault], ['main', true]);
      expect([lost('runs').to, lost('runs').byDefault], ['src:b', false]);
      expect(c.targetLost('src:b', 'default'), isNull, reason: 'a usable target is not lost');
      c = lab(quick: {'fallback': 'block'}, rules: all);
      expect([lost('rno').to, lost('rno').byDefault], ['block', true]);
      // "Proxy via X" where X is lost too: the global one
      expect(c.targetLost('src:zz', 'src:o')!.byDefault, isTrue);
      // the target itself as its fallback: the main flow
      expect(c.targetLost('src:zz', 'src:zz')!.to, 'main');
    });

    test('an app half: its target is lost the same way, not for Direct / Block', () {
      final c = lab(apps: {
        'org.a': {'act': 'proxy', 'target': 'src:x', 'fallback': 'block', 'split': true, 'udp': {'act': 'proxy', 'target': 'src:zz', 'fallback': 'default'}},
        'org.b': {'act': 'direct', 'target': 'src:zz', 'fallback': 'default', 'split': false},
      });
      c.appInfo = (pkg) => (name: pkg, kind: 'package');
      final apps = {for (final a in (c.routingPlan()['apps'] as List).cast<Map>()) a['id']: a};
      expect(apps['org.a']!['targetLost'], 'unsupported');
      expect((apps['org.a']!['udp'] as Map)['targetLost'], 'deleted');
      expect(apps['org.b']!.containsKey('targetLost'), isFalse);
    });

    test('the mockup\'s plan has none (mockupPlan)', () {
      final c = lab(rules: all)..mockupPlan = true;
      expect([for (final r in (c.routingPlan()['rules'] as List).cast<Map>()) r.containsKey('targetLost')], everyElement(isFalse));
    });
  });

  group('the config', () {
    RoutingInfo build(Catalog c) {
      final info = RoutingInfo();
      buildConfig(c.livePlan(), info: info);
      return info;
    }

    test('one LostTarget per lost rule with the right where; routing is the rule\'s "If unavailable"', () {
      final c = lab(rules: all);
      final info = RoutingInfo();
      final config = buildConfig(c.livePlan(), info: info);
      final byRule = {for (final l in info.lost) l.label: l};
      expect(byRule.keys, unorderedEquals(['Rule rdel', 'Rule roff', 'Rule rno', 'Rule runs']));
      expect([byRule['Rule rdel']!.why, byRule['Rule rdel']!.to, byRule['Rule rdel']!.byDefault], ['deleted', 'block', false]);
      expect([byRule['Rule roff']!.why, byRule['Rule roff']!.to, byRule['Rule roff']!.byDefault], ['off', 'direct', false]);
      expect([byRule['Rule rno']!.why, byRule['Rule rno']!.to, byRule['Rule rno']!.byDefault], ['noServers', 'main', true]);
      expect([byRule['Rule runs']!.why, byRule['Rule runs']!.to, byRule['Rule runs']!.byDefault], ['unsupported', 'src:b', false]);
      expect(byRule['Rule rdel']!.toJson(), {'rule': 'Rule rdel', 'target': 'src:zz', 'why': 'deleted', 'to': 'block'});
      expect(byRule['Rule rno']!.toJson(), containsPair('default', true));
      expect(info.reached, contains(lostId('Rule rok', false, 'src:b')));
      // routing unchanged: Block rejects, Direct goes direct, the lost fallback of a usable target stays a selector
      final rules = ((config['route'] as Map)['rules'] as List).cast<Map>();
      Map ruleOf(String id) => rules.firstWhere((r) => '${r['domain_suffix']}'.contains('$id.test') && r['action'] != 'resolve');
      expect(ruleOf('rdel')['action'], 'reject');
      expect(ruleOf('roff')['outbound'], 'direct');
      expect(ruleOf('rok')['outbound'], isNot('direct'));
    });

    test('the same build twice gives the same losses (nothing new to tell)', () {
      final c = lab(rules: all);
      expect([for (final l in build(c).lost) '${l.id} ${l.state}'], [for (final l in build(c).lost) '${l.id} ${l.state}']);
    });

    test('an app half is a lost target of its own (TCP and UDP count apart)', () {
      final c = lab(apps: {
        'org.a': {'act': 'proxy', 'target': 'src:x', 'fallback': 'block', 'split': true, 'udp': {'act': 'proxy', 'target': 'src:zz', 'fallback': 'direct'}},
      });
      c.appInfo = (pkg) => (name: 'App A', kind: 'package');
      final info = build(c);
      expect([for (final l in info.lost) '${l.app} ${l.why} ${l.to}'], unorderedEquals(['true unsupported block', 'true deleted direct']));
    });

    test('recovery: the target usable again is reached, not lost', () {
      final c = lab(rules: [rule('r1', 'src:o', fallback: 'block')]);
      expect(build(c).lost.single.why, 'off');
      c.sourcesData['o']!.enabled = true;
      final info = build(c);
      expect(info.lost, isEmpty);
      expect(info.reached, contains(lostId('Rule r1', false, 'src:o')));
    });
  });
}
