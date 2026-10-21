// Per-app rules in the core catalog: AppRule.rules (JSON), appIsDefault, saveAppRule / deleteAppRule /
// moveAppRule / appRuleById (rules_logic.dart), and the Android-only, once-only migration of own
// process rules into the apps on load (catalog.dart; docs/rules.md §3 «Правила приложения», «Перенос»).
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

UserRule _rule(
  Map<String, dynamic> groups, {
  String action = 'proxy',
  String target = '',
}) => newRule(groups: groups)
  ..action = action
  ..target = target;

Map<String, dynamic> _card(Map<String, List<String>> v, {bool not = false}) => {'not': not, 'v': v};

// A rule as the catalog stores it (its own JSON), with a fixed id.
Map<String, dynamic> _ruleJson(
  String id,
  Map<String, dynamic> groups, {
  String action = 'direct',
  bool enabled = true,
}) => {
  ...(newRule(groups: groups)..action = action).toJson(),
  'id': id,
  'enabled': enabled,
};

// A catalog JSON with the given own rules and app rules, everything else as a fresh install has it.
Map<String, dynamic> _base({
  Map<String, dynamic> rulesData = const {},
  List<String> order = const [],
  Map<String, dynamic> appRules = const {},
}) {
  final s = Catalog.fromJson(null, now: () => 1760000000000).toJson();
  s['rulesData'] = rulesData;
  s['ruleOrder'] = order;
  s['appRules'] = appRules;
  return s;
}

Catalog _load(Map<String, dynamic> s, {bool android = false}) => Catalog.fromJson(
  jsonDecode(jsonEncode(s)) as Map<String, dynamic>,
  now: () => 1760000000000,
  android: android,
);

final _domain = _card({'domain_suffix': ['x.com']});

void main() {
  group('AppRule.rules (JSON)', () {
    test(
      'the rules of an app round-trip in order with their on/off flag; absent means none; unknown keys stay',
      () {
        expect(AppRule.fromJson({}).rules, isEmpty);
        final src = [
          _ruleJson('ar1', {'domain': _domain}, enabled: false),
          _ruleJson('ar2', {'domain': _card({'domain': ['y.com']})}, action: 'block'),
        ];
        final a = AppRule.fromJson({'rules': src, 'keep': 'me'});
        expect([for (final r in a.rules) r.id], ['ar1', 'ar2']);
        expect(a.rules.first.enabled, isFalse, reason: 'the on/off flag is the rule’s own');
        expect(a.unknown['keep'], 'me');
        final back = AppRule.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
        expect([for (final r in back.rules) r.id], ['ar1', 'ar2']);
        expect(back.rules.first.enabled, isFalse);
        expect(back.rules.last.action, 'block');
        expect(jsonEncode(back.toJson()), jsonEncode(a.toJson()));
        expect(back.toJson()['keep'], 'me');
      },
    );

    test('an app is default only when its route is default AND it has no rules', () {
      expect(appIsDefault(AppRule.fromJson({})), isTrue);
      expect(
        appIsDefault(AppRule.fromJson({'rules': [_ruleJson('ar1', {'domain': _domain})]})),
        isFalse,
        reason: 'a rule keeps a default-route app',
      );
      expect(
        appIsDefault(AppRule.fromJson({'rules': [_ruleJson('ar1', {'domain': _domain}, enabled: false)]})),
        isFalse,
        reason: 'a disabled rule is still a rule',
      );
    });
  });

  group('saving, deleting and moving app rules', () {
    test(
      'saveAppRule drops the process group, appends, creates the app on a default route; own rules are not touched',
      () {
        final c = _load(_base());
        final d = _rule({
          'process': _card({'process': ['com.x']}),
          'domain': _domain,
        }, action: 'direct');
        expect(c.saveAppRule('com.x', d), isNull);
        expect(c.appRules.containsKey('com.x'), isTrue);
        final a = c.appRules['com.x']!;
        expect(a.rules.length, 1);
        expect(a.rules.single.groups, {'domain': _domain});
        expect(a.rules.single.action, 'direct');
        expect(a.tcp.act, 'default', reason: 'the app is created on the default route');
        expect(appIsDefault(a), isFalse);
        final first = a.rules.single.id;
        expect(c.appRuleById('com.x', first)?.groups, {'domain': _domain});

        expect(c.saveAppRule('com.x', _rule({'domain': _card({'domain': ['z.com']})})), isNull);
        expect(
          [for (final r in c.appRules['com.x']!.rules) r.id].first,
          first,
          reason: 'a new rule is appended, the first stays first',
        );
        expect(c.appRules['com.x']!.rules.length, 2);
        expect(c.rulesData, isEmpty, reason: 'an app rule is not an own rule');
        expect(c.ruleOrder, isEmpty);
      },
    );

    test('saveAppRule: the same red values and empty rule as saveRule stop it; Fallback only for Proxy', () {
      final c = _load(_base());
      expect(
        c.saveAppRule('com.x', _rule({'domain': _card({'domain': ['not a domain']})})),
        RuleProblem.invalidValues,
      );
      expect(
        c.saveAppRule('com.x', _rule({'domain': _card({'domain_suffix': []})})),
        RuleProblem.noConditions,
      );
      expect(c.appRules.containsKey('com.x'), isFalse, reason: 'a refused rule creates nothing');

      final d = _rule({'domain': _domain}, action: 'direct')..fallback = 'block';
      expect(c.saveAppRule('com.x', d), isNull);
      expect(c.appRules['com.x']!.rules.single.fallback, 'default', reason: 'Fallback is Proxy only');
    });

    test('saveAppRule with editing replaces that rule in place and keeps its id', () {
      final c = _load(_base());
      c.saveAppRule('com.x', _rule({'domain': _domain}, action: 'direct'));
      c.saveAppRule('com.x', _rule({'domain': _card({'domain': ['z.com']})}, action: 'block'));
      final ids = [for (final r in c.appRules['com.x']!.rules) r.id];
      final edited = _rule({'domain': _card({'domain': ['e.com']})}, action: 'proxy');
      expect(c.saveAppRule('com.x', edited, editing: ids.first), isNull);
      final now = c.appRules['com.x']!.rules;
      expect([for (final r in now) r.id], ids);
      expect(now.first.groups, {'domain': _card({'domain': ['e.com']})});
      expect(now.first.action, 'proxy');
      expect(now.last.action, 'block', reason: 'the other rule is untouched');
    });

    test('rule ids are unique across the catalog; appRuleById looks only in its own app', () {
      final c = _load(_base());
      c.saveAppRule('com.x', _rule({'domain': _domain}));
      c.saveAppRule('com.y', _rule({'domain': _domain}));
      final x = c.appRules['com.x']!.rules.single.id;
      final y = c.appRules['com.y']!.rules.single.id;
      expect(x, startsWith('ar'));
      expect(y, startsWith('ar'));
      expect(x, isNot(y));
      expect(c.appRuleById('com.x', x), isNotNull);
      expect(c.appRuleById('com.y', x), isNull, reason: 'the id is looked up in that app only');
      expect(c.appRuleById('com.unknown', y), isNull);
    });

    test('deleteAppRule removes one rule and keeps the others in order; the last one of a default route drops the app', () {
      final c = _load(_base());
      for (final v in ['a.com', 'b.com', 'c.com']) {
        c.saveAppRule('com.x', _rule({'domain': _card({'domain': [v]})}));
      }
      final ids = [for (final r in c.appRules['com.x']!.rules) r.id];
      c.deleteAppRule('com.x', ids[1]);
      expect([for (final r in c.appRules['com.x']!.rules) r.id], [ids[0], ids[2]]);
      c.deleteAppRule('com.x', ids[0]);
      c.deleteAppRule('com.x', ids[2]);
      expect(c.appRules.containsKey('com.x'), isFalse, reason: 'a default app with no rules is not stored');
    });

    test('moveAppRule moves a rule within its app (the index is where it ends up)', () {
      final c = _load(_base());
      for (final v in ['a.com', 'b.com', 'c.com']) {
        c.saveAppRule('com.x', _rule({'domain': _card({'domain': [v]})}));
      }
      final ids = [for (final r in c.appRules['com.x']!.rules) r.id];
      c.moveAppRule('com.x', 0, 2);
      expect([for (final r in c.appRules['com.x']!.rules) r.id], [ids[1], ids[2], ids[0]]);
      c.moveAppRule('com.x', 2, 0);
      expect([for (final r in c.appRules['com.x']!.rules) r.id], [ids[0], ids[1], ids[2]]);
    });
  });

  group('migration of own process rules (Android, once)', () {
    // r1: a process rule for two packages, with a domain condition too.
    final processRule = {
      'r1': _ruleJson('r1', {
        'process': _card({'process': ['com.a', 'com.b']}),
        'domain': _domain,
      }),
    };

    test('a non-inverted process rule is copied without that group to each package; the own rule is removed', () {
      final c = _load(
        _base(
          rulesData: processRule,
          order: ['r1'],
          appRules: {
            'com.b': {
              'rules': [_ruleJson('ar1', {'domain': _card({'domain': ['y.com']})}, action: 'block')],
            },
          },
        ),
        android: true,
      );
      expect(c.rulesData.containsKey('r1'), isFalse);
      expect(c.ruleOrder, isEmpty);
      expect(c.movedToApps, ['r1']);

      final a = c.appRules['com.a']!.rules;
      expect(a.length, 1);
      expect(a.single.groups, {'domain': _domain});
      expect(a.single.action, 'direct');

      final b = c.appRules['com.b']!.rules;
      expect(b.length, 2, reason: 'appended after the rule the app already had');
      expect(b.first.id, 'ar1');
      expect(b.last.groups, {'domain': _domain});
      expect(b.last.action, 'direct');

      final ids = {a.single.id, b.first.id, b.last.id};
      expect(ids.length, 3, reason: 'ids are unique across the catalog');
      expect(c.appRuleById('com.b', b.last.id), isNotNull);
    });

    test('an inverted process group and a composite rule stay as they are', () {
      final composite = {
        ...(newRule()
              ..composite = {
                'type': 'logical',
                'mode': 'or',
                'rules': [
                  {'domain_suffix': ['x.com']},
                ],
              })
            .toJson(),
        'id': 'r3',
        'enabled': true,
      };
      final c = _load(
        _base(
          rulesData: {
            'r2': _ruleJson('r2', {
              'process': _card({'process': ['com.a']}, not: true),
              'domain': _domain,
            }),
            'r3': composite,
          },
          order: ['r2', 'r3'],
        ),
        android: true,
      );
      expect(c.rulesData.keys, containsAll(['r2', 'r3']));
      expect(c.ruleOrder, ['r2', 'r3']);
      expect(c.appRules, isEmpty);
      expect(c.movedToApps, isEmpty);
    });

    test('the moved rules keep their names for the one journal line', () {
      final named = {
        'r1': {..._ruleJson('r1', {'process': _card({'process': ['com.a']}), 'domain': _domain}), 'name': 'Work'},
      };
      final c = _load(_base(rulesData: named, order: ['r1']), android: true);
      expect(c.movedToApps, ['r1']);
      expect(c.appRulesMovedNames, {'r1': 'Work'});
    });

    test('on another platform nothing moves', () {
      final c = _load(_base(rulesData: processRule, order: ['r1']), android: false);
      expect(c.rulesData.containsKey('r1'), isTrue);
      expect(c.appRules, isEmpty);
      expect(c.movedToApps, isEmpty);
    });

    test('deleting a target warns about and retargets the rules of apps like own rules', () {
      final c = _load(
        _base(
          appRules: {
            'com.a': {
              'rules': [
                {..._ruleJson('ar1', {'domain': _domain}, action: 'proxy'), 'target': 'src:x', 'fallback': 'block'},
                {..._ruleJson('ar2', {'domain': _domain}, action: 'proxy'), 'target': 'src:y'},
              ],
            },
          },
        ),
      );
      final lines = c.targetImpact((t) => t == 'src:x');
      expect(lines.length, 1);
      expect(lines.single.aKind, 'rule');
      expect(lines.single.aId, 'ar1');
      expect(lines.single.aTo, 'block');

      c.retargetAll([
        {'kind': 'rule', 'id': 'ar1', 'name': 'x', 'to': 'block'},
      ], 'src:z');
      final rules = c.appRules['com.a']!.rules;
      expect(rules.first.target, 'src:z');
      expect(rules.last.target, 'src:y', reason: 'a rule not in the list stays');
    });

    test('it runs once: a later load changes nothing, even when a process rule is back', () {
      final first = _load(_base(rulesData: processRule, order: ['r1']), android: true);
      expect(first.movedToApps, ['r1']);
      final out = jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>;

      final again = Catalog.fromJson(
        jsonDecode(jsonEncode(out)) as Map<String, dynamic>,
        now: () => 1760000000000,
        android: true,
      );
      expect(again.movedToApps, isEmpty);
      expect(jsonEncode(again.toJson()), jsonEncode(first.toJson()));

      // a process rule put back by hand after the migration is not migrated again
      (out['rulesData'] as Map)['r9'] = _ruleJson('r9', {
        'process': _card({'process': ['com.a']}),
        'domain': _domain,
      });
      out['ruleOrder'] = [...(out['ruleOrder'] as List), 'r9'];
      final later = Catalog.fromJson(
        jsonDecode(jsonEncode(out)) as Map<String, dynamic>,
        now: () => 1760000000000,
        android: true,
      );
      expect(later.rulesData.containsKey('r9'), isTrue);
      expect(later.movedToApps, isEmpty);
      expect(jsonEncode(later.appRules), jsonEncode(first.appRules));
    });
  });
}
