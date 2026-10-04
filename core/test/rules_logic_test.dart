// The Rules screen's logic (rules_logic.dart): validators, the draft ⇄ sing-box JSON, saving a rule,
// the address test, the final order, Clash lines, per-app helpers, rule sets.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show clock, make, t0;

UserRule _rule(
  Map<String, dynamic> groups, {
  String action = 'proxy',
  String target = '',
}) => newRule(groups: groups)
  ..action = action
  ..target = target;

Map<String, dynamic> _card(
  Map<String, List<String>> v, {
  bool not = false,
  bool? flag,
}) => {'not': not, 'v': v, 'flag': ?flag};

void main() {
  setUp(() => clock = t0);

  group('validators', () {
    test('domains, suffixes, names, text', () {
      expect(validRuleValue('domain', 'example.com'), isTrue);
      expect(validRuleValue('domain', '*.example.com'), isTrue);
      expect(validRuleValue('domain', 'example'), isFalse);
      expect(validRuleValue('suffix', '.google.com'), isTrue);
      expect(validRuleValue('suffix', 'a b'), isFalse);
      expect(validRuleValue('name', 'category-ads'), isTrue);
      expect(validRuleValue('name', 'a b'), isFalse);
      expect(validRuleValue('text', 'no-spaces'), isTrue);
      expect(validRuleValue('text', 'two words'), isFalse);
      expect(validRuleValue('regex', r'^.+\.ru$'), isTrue);
      expect(validRuleValue('regex', '(unclosed'), isFalse);
    });

    test('IPs, CIDRs, ranges, ports', () {
      for (final ok in [
        '10.0.0.0/8',
        '1.1.1.1',
        '1.1.1.1-1.1.1.9',
        '2001:db8::/32',
      ]) {
        expect(validRuleValue('ip', ok), isTrue, reason: ok);
      }
      for (final bad in [
        '300.1.1.1',
        '10.0.0.0/33',
        '1.1.1.9-1.1.1.1',
        'abc',
        '10.0.0.0/8/8',
      ]) {
        expect(validRuleValue('ip', bad), isFalse, reason: bad);
      }
      expect(validRuleValue('port', '443'), isTrue);
      expect(validRuleValue('port', '8000-9000'), isTrue);
      expect(validRuleValue('port', '9000-8000'), isFalse);
      expect(validRuleValue('port', '0'), isFalse);
      expect(validRuleValue('port', '70000'), isFalse);
    });

    test('a rule_set value must be one of the rule sets', () {
      expect(
        validRuleValue('ruleset', 'ru-blocked', ruleSetNames: ['ru-blocked']),
        isTrue,
      );
      expect(
        validRuleValue('ruleset', 'x', ruleSetNames: ['ru-blocked']),
        isFalse,
      );
    });

    test('typed values split on commas, semicolons and new lines', () {
      expect(splitRuleValues('a.com, b.com;c.com\n d.com ,,'), [
        'a.com',
        'b.com',
        'c.com',
        'd.com',
      ]);
    });
  });

  group('the draft groups', () {
    test(
      '+ Condition puts a field on its card, the x takes the card with its last field',
      () {
        final r = newRuleDraft();
        expect(r.groups!.keys, ['domain']);
        addRuleField(r, 'ip', 'ip_is_private');
        addRuleField(r, 'port', 'port');
        expect(r.groups!['ip'], {
          'not': false,
          'v': <String, dynamic>{},
          'flag': true,
        });
        expect(
          groupHasField(
            r.groups!['ip'] as Map<String, dynamic>,
            ruleGroup('ip'),
            'ip_is_private',
          ),
          isTrue,
        );
        removeRuleField(r, 'ip', 'ip_is_private');
        expect(r.groups!.containsKey('ip'), isFalse);
        addRuleValues(r, 'port', 'port', '443, 8000-9000, 443');
        expect(ruleFieldValues(r, 'port', 'port'), ['443', '8000-9000']);
        replaceRuleValue(r, 'port', 'port', 0, '80, 8080');
        expect(ruleFieldValues(r, 'port', 'port'), ['80', '8080', '8000-9000']);
      },
    );

    test(
      'a rule with ip_cidr, local networks or GeoIP has an IP condition; so does a JSON one',
      () {
        expect(
          ruleHasIpCondition(
            _rule({
              'ip': _card({
                'ip_cidr': ['1.1.1.1'],
              }),
            }),
          ),
          isTrue,
        );
        expect(
          ruleHasIpCondition(
            _rule({
              'ip': _card({'ip_cidr': []}, flag: true),
            }),
          ),
          isTrue,
        );
        expect(
          ruleHasIpCondition(
            _rule({
              'ip': _card({'ip_cidr': []}),
            }),
          ),
          isFalse,
        );
        expect(
          ruleHasIpCondition(
            _rule({
              'domain': _card({
                'domain': ['a.com'],
              }),
            }),
          ),
          isFalse,
        );
        expect(
          ruleHasIpCondition(
            newRule()
              ..composite = {
                'type': 'logical',
                'rules': [
                  {
                    'rule_set': ['geoip-ru'],
                  },
                ],
              },
          ),
          isTrue,
        );
      },
    );
  });

  group('rule ⇄ JSON', () {
    test(
      'a flat rule: one key per field, ports and ranges apart, IP ranges as CIDRs, process name / path',
      () {
        final c = make();
        final r = _rule({
          'domain': _card({
            'domain_suffix': ['a.com', 'b.com'],
          }),
          'port': _card({
            'port': ['443', '8000-9000'],
          }),
        }, action: 'direct');
        expect(ruleJson(c, r), {
          'domain_suffix': ['a.com', 'b.com'],
          'port': [443],
          'port_range': ['8000:9000'],
          'action': 'route',
          'outbound': 'direct',
        });
        final ip = _rule({
          'ip': _card({
            'ip_cidr': ['1.1.1.1-1.1.1.9', '10.0.0.0/8'],
          }, flag: true),
        });
        expect(ruleJson(c, ip)['ip_cidr'], [
          '1.1.1.1/32',
          '1.1.1.2/31',
          '1.1.1.4/30',
          '1.1.1.8/31',
          '10.0.0.0/8',
        ]);
        expect(ruleJson(c, ip)['ip_is_private'], true);
        final proc = _rule({
          'process': _card({
            'process': ['chrome.exe', r'C:\x\y.exe', '/usr/bin/*'],
          }),
        });
        expect(ruleJson(c, proc)['process_name'], ['chrome.exe']);
        expect(ruleJson(c, proc)['process_path'], [
          r'C:\x\y.exe',
          '/usr/bin/*',
        ]);
      },
    );

    test('Block: reject with drop / default; an empty card is no JSON', () {
      final c = make();
      final r = _rule({
        'domain': _card({
          'domain': ['a.com'],
        }),
        'port': _card({'port': []}),
      }, action: 'block')..block = 'reject';
      expect(ruleJson(c, r), {
        'domain': ['a.com'],
        'action': 'reject',
        'method': 'default',
      });
      r.block = 'drop';
      expect(ruleJson(c, r)['method'], 'drop');
    });

    test(
      'an except card, or Domains with IP, is a logical AND; it reads back into the same cards',
      () {
        final c = make();
        final r = _rule({
          'domain': _card({
            'domain_suffix': ['a.com'],
          }),
          'ip': _card({
            'ip_cidr': ['10.0.0.0/8'],
          }, not: true),
        });
        final j = ruleJson(c, r);
        expect(j['type'], 'logical');
        expect(j['mode'], 'and');
        expect((j['rules'] as List)[1], {
          'ip_cidr': ['10.0.0.0/8'],
          'invert': true,
        });
        final back = ruleFromJson(c, j);
        expect(back.composite, isNull);
        expect(back.groups, {
          'domain': _card({
            'domain_suffix': ['a.com'],
          }),
          'ip': _card({
            'ip_cidr': ['10.0.0.0/8'],
          }, not: true),
        });
        final both = _rule({
          'domain': _card({
            'domain': ['a.com'],
          }),
          'ip': _card({
            'ip_cidr': ['1.1.1.1'],
          }),
        });
        expect(ruleJson(c, both)['type'], 'logical');
      },
    );

    test(
      'Via: a target is the outbound `kind:name`, read back to the same target; a deleted one reads as deleted',
      () {
        final c = make();
        final r = _rule({
          'domain': _card({
            'domain': ['a.com'],
          }),
        }, target: 'chain:c1');
        expect(ruleJson(c, r)['outbound'], 'chain:B via A');
        expect(ruleFromJson(c, ruleJson(c, r)).target, 'chain:c1');
        expect(
          ruleJson(
            c,
            _rule({
              'domain': _card({
                'domain': ['a.com'],
              }),
            }),
          )['outbound'],
          'proxy',
        );
        expect(
          ruleJson(
            c,
            _rule({
              'domain': _card({
                'domain': ['a.com'],
              }),
            }, target: 'chain:zz'),
          )['outbound'],
          'chain:deleted chain',
        );
        expect(
          ruleFromJson(c, {
            'domain': ['a.com'],
            'outbound': 'direct',
          }).action,
          'direct',
        );
        final s = ruleFromJson(c, {
          'domain': ['a.com'],
          'outbound': 'subscription:Source a',
        });
        expect(s.target, 'src:a');
        expect(allTargets(c), [
          '',
          'src:a',
          'node:a::a1',
          'node:a::a2',
          'node:a::a3',
          'src:b',
          'node:b::b1',
          'node:b::b2',
          'profile:p',
          'chain:c1',
        ]);
      },
    );

    test(
      'unknown keys are extra and come back; any other logical rule is composite; a reject keeps its method',
      () {
        final c = make();
        final x = ruleFromJson(c, {
          'domain': ['a.com'],
          'ip_version': 4,
          'action': 'route',
          'outbound': 'direct',
        });
        expect(x.extra, {'ip_version': 4});
        expect(ruleJson(c, x)['ip_version'], 4);
        final comp = ruleFromJson(c, {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {
              'domain_keyword': ['tracker'],
            },
            {
              'port': [6969],
            },
          ],
          'action': 'reject',
          'method': 'drop',
        });
        expect(comp.composite, isNotNull);
        expect(comp.action, 'block');
        expect(comp.block, 'drop');
        expect(ruleJson(c, comp)['mode'], 'or');
        expect(ruleJson(c, comp)['method'], 'drop');
        expect(ruleFromJson(c, {'action': 'reject'}).block, 'reject');
        final inv = ruleFromJson(c, {
          'domain': ['a.com'],
          'invert': true,
        });
        expect(
          inv.groups!['domain'],
          _card({
            'domain': ['a.com'],
          }, not: true),
        );
        expect(inv.extra, isNull);
      },
    );

    test('port ranges and process names read into the cards', () {
      final c = make();
      final r = ruleFromJson(c, {
        'port': [443],
        'port_range': ['8000:9000'],
        'process_name': ['a.exe'],
        'ip_is_private': true,
      });
      expect(ruleFieldValues(r, 'port', 'port'), ['443', '8000-9000']);
      expect(ruleFieldValues(r, 'process', 'process'), ['a.exe']);
      expect((r.groups!['ip'] as Map)['flag'], true);
    });

    test(
      'a text that is not a rule: a syntax error with its line, or notObject',
      () {
        final c = make();
        expect(
          () => ruleFromJsonText(c, '{\n  "domain": [\n'),
          throwsA(
            isA<RuleJsonError>()
                .having((e) => e.code, 'code', 'syntax')
                .having((e) => e.line, 'line', isNotNull),
          ),
        );
        expect(
          () => ruleFromJsonText(c, '[1]'),
          throwsA(
            isA<RuleJsonError>().having((e) => e.code, 'code', 'notObject'),
          ),
        );
        expect(
          parseJsonRules(c, '[{"domain":["a.com"]},{"domain":["b.com"]}]'),
          hasLength(2),
        );
        expect(parseJsonRules(c, '{"domain":["a.com"]}'), hasLength(1));
      },
    );

    test(
      'the JSON tab applied to a draft keeps the name, Fallback, DNS and the cards not filled in yet',
      () {
        final c = make();
        final old =
            _rule({
                'domain': _card({
                  'domain_suffix': ['a.com'],
                  'domain': [],
                }),
                'port': _card({'port': []}),
              })
              ..name = 'mine'
              ..fallback = 'main'
              ..dns = 'remote'
              ..ipTunOnly = true;
        final parsed = ruleFromJson(c, {
          'domain_suffix': ['a.com', 'b.com'],
          'action': 'route',
          'outbound': 'direct',
        });
        final d = applyJsonToDraft(parsed, old);
        expect(d.name, 'mine');
        expect(d.fallback, 'main');
        expect(d.dns, 'remote');
        expect(d.ipTunOnly, isTrue);
        expect(d.action, 'direct');
        expect(ruleFieldValues(d, 'domain', 'domain_suffix'), [
          'a.com',
          'b.com',
        ]);
        expect(
          (d.groups!['domain'] as Map)['v'],
          containsPair('domain', <String>[]),
        );
        expect(d.groups!.containsKey('port'), isTrue);
      },
    );
  });

  group('saving a rule', () {
    test(
      'red values and an empty rule stop it; empty fields and cards are dropped',
      () {
        final c = make();
        expect(
          c.saveRule(
            _rule({
              'domain': _card({
                'domain': ['not a domain'],
              }),
            }),
          ),
          RuleProblem.invalidValues,
        );
        expect(c.rulesData, isEmpty);
        expect(
          c.saveRule(
            _rule({
              'domain': _card({'domain_suffix': []}),
            }),
          ),
          RuleProblem.noConditions,
        );
        final r = _rule({
          'domain': _card({
            'domain_suffix': ['a.com'],
            'domain': [],
          }),
          'port': _card({'port': []}),
          'ip': _card({'ip_cidr': []}),
        }, action: 'direct')..fallback = 'block';
        expect(c.saveRule(r), isNull);
        expect(c.ruleOrder, ['r1']);
        final saved = c.rulesData['r1']!;
        expect(saved.groups, {
          'domain': _card({
            'domain_suffix': ['a.com'],
          }),
        });
        expect(saved.fallback, 'default', reason: 'Fallback is Proxy only');
        expect(saved.id, 'r1');
        expect(c.ruleSeq, 2);
      },
    );

    test(
      'Local networks alone is a condition; a rule set value is checked against Rules → Rule sets',
      () {
        final c = make();
        expect(c.saveRule(_rule({'ip': _card({}, flag: true)})), isNull);
        expect(
          c.saveRule(
            _rule({
              'domain': _card({
                'rule_set': ['ru-blocked'],
              }),
            }),
          ),
          RuleProblem.invalidValues,
        );
        c.saveRuleSet(
          RuleSetCfg(
            id: '',
            name: 'ru-blocked',
            url: 'https://example.org/a.srs',
            format: 'srs',
            via: 'vpn',
            every: 86400,
          ),
        );
        expect(
          c.saveRule(
            _rule({
              'domain': _card({
                'rule_set': ['ru-blocked'],
              }),
            }),
          ),
          isNull,
        );
        expect(c.ruleSetUsers('ru-blocked'), [2]);
      },
    );

    test(
      'editing keeps the place and the id; the fallback target goes unless Fallback is Proxy-via, and never equals the Via',
      () {
        final c = make();
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['a.com'],
            }),
          }),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['b.com'],
            }),
          }),
        );
        final d = cloneRule(c.rulesData['r1']!)
          ..fallback = 'main'
          ..fallbackTarget = 'chain:c1'
          ..target = 'chain:c1';
        expect(c.saveRule(d, editing: 'r1'), isNull);
        expect(c.ruleOrder, ['r1', 'r2']);
        expect(c.rulesData['r1']!.fallbackTarget, '');
        final e = cloneRule(c.rulesData['r2']!)
          ..fallback = 'main'
          ..fallbackTarget = 'src:a'
          ..target = 'chain:c1';
        c.saveRule(e, editing: 'r2');
        expect(c.rulesData['r2']!.fallbackTarget, 'src:a');
        c.saveRule(
          cloneRule(c.rulesData['r2']!)..action = 'block',
          editing: 'r2',
        );
        expect(c.rulesData['r2']!.fallbackTarget, '');
      },
    );

    test('IP-only-in-TUN is kept only for a rule with an IP condition', () {
      final c = make();
      c.saveRule(
        _rule({
          'domain': _card({
            'domain': ['a.com'],
          }),
        })..ipTunOnly = true,
      );
      c.saveRule(
        _rule({
          'ip': _card({
            'ip_cidr': ['1.1.1.1'],
          }),
        })..ipTunOnly = true,
      );
      expect(c.rulesData['r1']!.ipTunOnly, isFalse);
      expect(c.rulesData['r2']!.ipTunOnly, isTrue);
    });

    test('delete and import: the rules go to the end with new ids', () {
      final c = make();
      c.saveRule(
        _rule({
          'domain': _card({
            'domain': ['a.com'],
          }),
        }),
      );
      c.addRules([
        _rule({
          'domain': _card({
            'domain': ['b.com'],
          }),
        }),
        _rule({
          'domain': _card({
            'domain': ['c.com'],
          }),
        }),
      ]);
      expect(c.ruleOrder, ['r1', 'r2', 'r3']);
      c.deleteRule('r2');
      expect(c.ruleOrder, ['r1', 'r3']);
      expect(c.rulesData.keys, ['r1', 'r3']);
    });
  });

  group('the address test', () {
    Catalog withRules() {
      final c = make();
      c.saveRule(
        _rule({
          'domain': _card({
            'domain_suffix': ['corp.example'],
          }),
        }, action: 'direct')..name = 'Work',
      );
      c.saveRule(
        _rule({
          'domain': _card({
            'domain_suffix': ['discord.gg'],
          }),
          'network': _card({
            'network': ['tcp'],
          }),
        }, target: 'chain:c1'),
      );
      c.saveRule(
        _rule({
          'port': _card({
            'port': ['6881-6889'],
          }),
        }, action: 'block'),
      );
      c.saveRule(
        _rule({
          'domain': _card({
            'domain_keyword': ['off'],
          }),
        }, action: 'block')..enabled = false,
      );
      return c;
    }

    test(
      'local networks first, then own rules in order, then quick rules, services, region, everything else',
      () {
        final c = withRules();
        c.quickCfg
          ..ads = true
          ..regionOn = true
          ..region = 'RU'
          ..services['youtube'] = 'vpn';
        expect(testAddress(c, '192.168.1.5')!.kind, 'local');
        expect(testAddress(c, 'printer.local')!.kind, 'local');
        final w = testAddress(c, 'https://app.corp.example/path')!;
        expect((w.kind, w.index, w.act), ('rule', 1, 'direct'));
        final d = testAddress(c, 'discord.gg:443')!;
        expect(
          (d.kind, d.index, d.act, d.target),
          ('rule', 2, 'proxy', 'chain:c1'),
        );
        expect(testAddress(c, '1.2.3.4:6885')!.index, 3);
        expect(
          testAddress(c, 'offline.example')!.kind,
          isNot('rule'),
          reason: 'a disabled rule never catches',
        );
        expect(testAddress(c, 'doubleclick.net')!.kind, 'ads');
        final y = testAddress(c, 'www.youtube.com')!;
        expect((y.kind, y.key, y.act), ('service', 'youtube', 'proxy'));
        expect(testAddress(c, 'yandex.ru')!.kind, 'region');
        final f = testAddress(c, 'example.org')!;
        expect((f.kind, f.act), ('final', 'proxy'));
        expect(testAddress(c, '  '), isNull);
      },
    );

    test(
      'a rule it cannot judge (rule set, GeoIP, source, process, composite) is skipped, never invented',
      () {
        final c = make();
        c.saveRuleSet(
          RuleSetCfg(
            id: '',
            name: 'set1',
            url: 'https://example.org/a.srs',
            format: 'srs',
            via: 'vpn',
            every: 86400,
          ),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'rule_set': ['set1'],
            }),
          }, action: 'block'),
        );
        c.saveRule(
          _rule({
            'ip': _card({
              'geoip': ['ru'],
            }),
          }, action: 'block'),
        );
        c.saveRule(
          _rule({
            'process': _card({
              'process': ['a.exe'],
            }),
          }, action: 'block'),
        );
        c.rulesData['r3']!.groups = {
          'process': _card({
            'process': ['a.exe'],
          }, not: true),
        };
        expect(testAddress(c, 'a.example')!.kind, 'final');
        expect(testAddress(c, '8.8.8.8')!.kind, 'final');
      },
    );

    test('an app by name or package: its rule, or none', () {
      final c = make();
      c.appRules['org.telegram.messenger'] = AppRule(
        tcp: AppHalf(act: 'proxy'),
      );
      final apps = [
        (pkg: 'org.telegram.messenger', name: 'Telegram'),
        (pkg: 'com.x', name: 'X app'),
      ];
      final t = testAddress(c, 'telegram', apps: apps)!;
      expect((t.kind, t.appName), ('app', 'Telegram'));
      expect(t.app!.tcp.act, 'proxy');
      expect(testAddress(c, 'com.x', apps: apps)!.app, isNull);
    });

    test('Except and the IP / port cards are judged', () {
      final c = make();
      c.saveRule(
        _rule({
          'ip': _card({
            'ip_cidr': ['8.8.8.0/24'],
          }, not: true),
          'port': _card({
            'port': ['443'],
          }),
        }, action: 'direct'),
      );
      expect(testAddress(c, '9.9.9.9:443')!.kind, 'rule');
      expect(testAddress(c, '8.8.8.8:443')!.kind, 'final');
      expect(testAddress(c, '9.9.9.9:80')!.kind, 'final');
    });
  });

  group('the final order', () {
    test(
      'local networks, apps, own rules (enabled), ads, services, region, everything else',
      () {
        final c = make();
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['a.com'],
            }),
          }, action: 'direct'),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['b.com'],
            }),
          })..enabled = false,
        );
        c.appRules['com.x'] = AppRule(tcp: AppHalf(act: 'block'));
        c.quickCfg
          ..ads = true
          ..regionOn = true
          ..region = 'BY'
          ..finalAction = 'direct'
          ..services['spotify'] = 'direct'
          ..services['telegram'] = 'vpn';
        final rows = effectiveRules(c);
        expect(
          [for (final r in rows) '${r.kind}:${r.act}'],
          [
            'lan:direct',
            'apps:mixed',
            'rule:direct',
            'ads:block',
            'service:proxy',
            'service:direct',
            'region:direct',
            'final:direct',
          ],
        );
        expect(rows[1].count, 1);
        expect(
          [rows[4].key, rows[5].key, rows[6].key],
          ['telegram', 'spotify', 'BY'],
        );
      },
    );

    test('nothing set: local networks and everything else', () {
      final c = make();
      c.quickCfg.regionOn = false;
      expect([for (final r in effectiveRules(c)) r.kind], ['lan', 'final']);
    });
  });

  group('Clash rules', () {
    test(
      'export: one line per value, the policy from the action; what Clash cannot hold is a comment',
      () {
        final c = make();
        c.saveRule(
          _rule({
            'domain': _card({
              'domain_suffix': ['a.com', 'b.com'],
            }),
          }, action: 'direct'),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'domain_keyword': ['ads'],
            }),
          }, action: 'block'),
        );
        c.saveRule(
          _rule({
            'port': _card({
              'port': ['443'],
            }),
          }, target: 'chain:c1'),
        );
        c.saveRule(
          _rule({
            'port': _card({
              'port': ['80'],
            }, not: true),
          }),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['a.com'],
            }),
            'port': _card({
              'port': ['1'],
            }),
          }),
        );
        c.saveRule(
          _rule({
            'domain': _card({
              'domain': ['z.com'],
            }),
          }),
        );
        c.rulesData['r6']!.name = 'Plain';
        final out = exportClashRules(c);
        expect(
          out,
          contains(
            'DOMAIN-SUFFIX,a.com,DIRECT\nDOMAIN-SUFFIX,b.com,DIRECT\nDOMAIN-KEYWORD,ads,REJECT',
          ),
        );
        expect(out, contains('DST-PORT,443,'));
        expect(out.split('\n').where((l) => l.startsWith('#')), hasLength(2));
        expect(out.split('\n').last, 'DOMAIN,z.com,PROXY');
      },
    );

    test(
      'import: types, policies, comments; MATCH is Everything else; a bad line names its number',
      () {
        final c = make();
        final r = parseClashRules(
          c,
          '# note\nDOMAIN-SUFFIX,example.com,DIRECT\n\nIP-CIDR6,2001:db8::/32,REJECT\nDST-PORT, 443 , Proxy-1\nMATCH,DIRECT',
        );
        expect(r.finalAction, 'direct');
        expect(r.rules, hasLength(3));
        expect(r.rules[0].action, 'direct');
        expect(ruleFieldValues(r.rules[0], 'domain', 'domain_suffix'), [
          'example.com',
        ]);
        expect(r.rules[1].action, 'block');
        expect(ruleFieldValues(r.rules[1], 'ip', 'ip_cidr'), ['2001:db8::/32']);
        expect(r.rules[2].action, 'proxy');
        expect(ruleFieldValues(r.rules[2], 'port', 'port'), ['443']);
        expect(parseClashRules(c, 'MATCH,REJECT').finalAction, 'block');
        expect(parseClashRules(c, 'DOMAIN,a.com,PROXY').finalAction, isNull);
        expect(
          () => parseClashRules(c, 'DOMAIN,a.com,DIRECT\nNOPE,x,DIRECT'),
          throwsA(isA<ClashLineError>().having((e) => e.line, 'line', 2)),
        );
        expect(
          () => parseClashRules(c, 'DOMAIN,a.com'),
          throwsA(isA<ClashLineError>()),
        );
      },
    );

    test('JSON export is the rules in order, as the JSON tab shows them', () {
      final c = make();
      c.saveRule(
        _rule({
          'domain': _card({
            'domain': ['a.com'],
          }),
        }, action: 'direct'),
      );
      expect(exportRulesJson(c), contains('"outbound": "direct"'));
      expect(parseJsonRules(c, exportRulesJson(c)).single.action, 'direct');
    });
  });

  group('per-app routing', () {
    test(
      'an app on Default with no Fallback is not stored; the UDP half only lives while split',
      () {
        final c = make();
        final d = cloneApp(null)..tcp.act = 'proxy';
        d.udp.act = 'block';
        c.saveApp('com.x', d, label: 'X');
        expect(
          c.appRules['com.x']!.udp.act,
          'default',
          reason: 'not split: no UDP half',
        );
        expect(c.appRules['com.x']!.unknown['name'], 'X');
        final s = cloneApp(c.appRules['com.x'])
          ..split = true
          ..udp.act = 'block';
        c.saveApp('com.x', s, label: 'X');
        expect(c.appRules['com.x']!.udp.act, 'block');
        c.saveApp('com.x', cloneApp(null));
        expect(c.appRules, isEmpty);
        final fb = cloneApp(null)..tcp.fallback = 'block';
        expect(
          appIsDefault(fb),
          isFalse,
          reason: 'Default + a Fallback is an own rule',
        );
      },
    );

    test(
      'the name of an app: the installed list, else the one kept with the rule, else the package',
      () {
        final c = make();
        expect(c.appLabel('com.x'), 'com.x');
        c.saveApp('com.x', cloneApp(null)..tcp.act = 'direct', label: 'Kept');
        expect(c.appLabel('com.x'), 'Kept');
        c.appInfo = (pkg) => (name: 'Live', kind: 'package');
        expect(c.appLabel('com.x'), 'Live');
      },
    );

    test(
      'the state class of a row is the first action that is not Default; a service links to its app',
      () {
        final a = AppRule(
          split: true,
          tcp: AppHalf(),
          udp: AppHalf(act: 'block'),
        );
        expect(appStateAct(a), 'block');
        expect(appStateAct(AppRule(tcp: AppHalf(act: 'direct'))), 'direct');
        final c = make();
        expect(c.appOfService('telegram'), isNull);
        c.appRules['org.telegram.messenger'] = AppRule(
          tcp: AppHalf(act: 'proxy'),
        );
        expect(c.appOfService('telegram'), 'org.telegram.messenger');
        expect(serviceOfApp('org.telegram.messenger'), 'telegram');
        expect(serviceOfApp('com.unknown'), isNull);
      },
    );
  });

  group('rule sets', () {
    test('name, duplicate and URL are checked; built-in ones are not', () {
      final c = make();
      RuleSetCfg d({
        String name = 'mine',
        String url = 'https://example.org/a.srs',
      }) => RuleSetCfg(
        id: '',
        name: name,
        url: url,
        format: 'srs',
        via: 'vpn',
        every: 86400,
      );
      expect(c.ruleSetProblem(d(name: 'bad name')), 'name');
      expect(c.ruleSetProblem(d(name: '')), 'name');
      expect(c.ruleSetProblem(d(url: 'ftp://x')), 'url');
      expect(c.ruleSetProblem(d()), isNull);
      c.saveRuleSet(d());
      expect(c.ruleSets.last.id, 'rs${c.rsSeq - 1}');
      expect(c.ruleSetProblem(d()), 'nameTaken');
      expect(c.ruleSetProblem(d(), editing: c.ruleSets.last.id), isNull);
      expect(
        c.ruleSetProblem(
          RuleSetCfg(id: 'geosite', name: 'geosite', builtin: true),
        ),
        isNull,
      );
      c.saveRuleSet(d(name: 'renamed'), editing: c.ruleSets.last.id);
      expect(c.ruleSets.last.name, 'renamed');
      c.deleteRuleSet(c.ruleSets.last.id);
      expect(c.ruleSets.any((s) => s.name == 'renamed'), isFalse);
    });
  });
}
