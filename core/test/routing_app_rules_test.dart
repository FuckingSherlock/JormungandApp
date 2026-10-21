// App rules in the routing (docs/rules.md §3 «Правила приложения», plan Routing bullet): an app's
// enabled rules go before its own route, each rule's conditions ANDed with the app match; a disabled
// rule is not routed; an app on the default route keeps only its rules; a split app keeps each rule
// once; exclude_package only for a fully Direct app without enabled rules; Global ignores both; the
// event data of such a rule names the app. Built from a catalog snapshot (routingPlan) and checked
// through the sing-box builder. Nothing leaves the machine.
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

final _node = parseLink(ssSip002)!.outbound;
const _t0 = 1760000000000;
const _tunnelPort = 40001;

Map<String, dynamic> _src(String id) => {
      'id': id,
      'kind': 'sub',
      'name': 'Source $id',
      'enabled': true,
      'inAuto': true,
      'offNodes': <String>[],
      'disabledNodes': <String>[],
      'gone': <dynamic>[],
      'nodes': [
        for (final n in ['1', '2']) {'id': '$id$n', 'name': 'Server $id$n', 'protocol': 'vless', 'address': '$id$n.example', 'port': 443, 'outbound': _node},
      ],
    };

/// A catalog with two sources (a, b), one profile, one chain and the given own / app rules.
Catalog _catalog({Map<String, dynamic> own = const {}, List<String> ownOrder = const [], Map<String, dynamic> apps = const {}}) {
  final s = <String, dynamic>{
    'sourcesData': {'a': _src('a'), 'b': _src('b')},
    'sourceOrder': ['a', 'b'],
    'sourceSeq': 3,
    'connectMode': 'simple',
    'connectOrder': ['a', 'b', 'c1'],
    'activeConnectId': 'a',
    'autoConnect': true,
    'pinnedNode': null,
    'modeState': {
      'profiles': {'order': ['p'], 'active': 'p', 'auto': true},
    },
    'profilesData': {
      'p': {'id': 'p', 'name': 'All', 'sources': ['a', 'b'], 'nodes': <String>[], 'inAuto': true},
    },
    'profileSeq': 1,
    'chainsData': {
      'c1': {'id': 'c1', 'name': 'B via A', 'inId': 'b', 'outId': 'a', 'inAuto': true},
    },
    'chainSeq': 1,
    'catalogOrder': {'simple': ['a', 'b', 'c1'], 'profiles': ['p']},
    'routeCustom': {'simple': false, 'profiles': false},
    'segState': {'mode': 'proxy', 'route': 'rules', 'sys': 'off'},
    'connCfg': <String, dynamic>{},
    'autoCfg': <String, dynamic>{},
    'rulesData': own,
    'ruleOrder': ownOrder,
    'ruleSeq': 1,
    'quickCfg': <String, dynamic>{},
    'appRules': apps,
    'pings': <dynamic>[],
  };
  final c = Catalog.fromJson(jsonDecode(jsonEncode(s)) as Map<String, dynamic>, now: () => _t0);
  // "*.exe" are desktop processes, the rest Android packages
  c.appInfo = (pkg) => (name: pkg, kind: pkg.endsWith('.exe') ? 'process' : 'package');
  return c;
}

Map<String, dynamic> _ownRule(String id, String domain, {String action = 'direct'}) => {
      'id': id,
      'name': 'Own $id',
      'enabled': true,
      'action': action,
      'target': '',
      'fallback': 'default',
      'groups': {
        'domain': {
          'not': false,
          'v': {
            'domain_suffix': [domain],
          },
        },
      },
    };

Map<String, dynamic> _ar(String id, String domain, {String action = 'proxy', String target = '', String fallback = 'default', bool enabled = true, String name = ''}) => {
      'id': id,
      'name': name.isEmpty ? 'Rule $id' : name,
      'enabled': enabled,
      'action': action,
      'target': target,
      'fallback': fallback,
      'groups': {
        'domain': {
          'not': false,
          'v': {
            'domain_suffix': [domain],
          },
        },
      },
    };

/// An app's record in the snapshot: its route (Split: the UDP half's action) and its rules.
Map<String, dynamic> _app(String act, {bool split = false, String udp = 'default', List<Map<String, dynamic>> rules = const []}) => {
      'act': act,
      'target': '',
      'fallback': 'default',
      'split': split,
      'udp': {'act': udp},
      'rules': rules,
    };

Map<String, dynamic> _plan(Catalog c, {bool global = false, String? mode}) => {
      'kind': 'unit',
      'main': {
        'pick': 'fastest',
        'chosen': null,
        'nodes': [
          {'key': 's::0', 'outbound': _node},
        ],
      },
      'global': global,
      'mode': ?mode,
      'routing': c.routingPlan(),
    };

// the first two route rules are sniff and private networks (routing_test.dart: _rules / _lanRule)
List<Map> _rules(Map<String, dynamic> cfg) => ((cfg['route'] as Map)['rules'] as List).cast<Map>().skip(2).toList();
Map _lanRule(Map<String, dynamic> cfg) => ((cfg['route'] as Map)['rules'] as List).cast<Map>()[1];
Map? _tun(Map<String, dynamic> cfg) => (cfg['inbounds'] as List).cast<Map>().where((i) => i['type'] == 'tun').firstOrNull;

bool _says(Object? r, String s) => jsonEncode(r).contains(s);
List<Map> _about(List<Map> rules, String s) => rules.where((r) => _says(r, s)).toList();

/// The conditions of a generated rule, its logical groups flattened; every group must be an AND.
Map<String, dynamic> _conds(Map r) {
  final out = <String, dynamic>{};
  void walk(Map x) {
    if (x['type'] == 'logical') {
      expect(x['mode'], 'and', reason: 'an app rule is its conditions AND the app match');
      for (final y in x['rules'] as List) {
        walk(y as Map);
      }
    } else {
      x.forEach((k, v) {
        if (k != 'action' && k != 'outbound' && k != 'method') out['$k'] = v;
      });
    }
  }

  walk(r);
  return out;
}

void main() {
  group('app rules in the routing', () {
    test('the order: after private networks, the app rules in their list order, then the app route, then own rules', () {
      final c = _catalog(
        own: {'r1': _ownRule('r1', 'own.example')},
        ownOrder: ['r1'],
        apps: {
          'com.x': _app('proxy', rules: [_ar('ar1', 'one.example', action: 'block'), _ar('ar2', 'two.example')]),
        },
      );
      final cfg = buildConfig(_plan(c));
      final rules = _rules(cfg);
      expect(_lanRule(cfg)['ip_is_private'], true);
      expect(_lanRule(cfg)['outbound'], 'direct');
      final appRoute = rules.indexWhere((r) => _says(r, 'com.x') && !_says(r, 'example'));
      expect(appRoute, greaterThanOrEqualTo(0));
      expect(rules[appRoute], {'package_name': ['com.x'], 'action': 'route', 'outbound': 'proxy'});
      int at(String s) => rules.indexWhere((r) => _says(r, s));
      expect(at('one.example'), greaterThanOrEqualTo(0));
      expect(at('one.example'), lessThan(at('two.example')), reason: 'the list order');
      expect(at('two.example'), lessThan(appRoute), reason: 'the rules before the app route');
      expect(appRoute, lessThan(at('own.example')), reason: 'the app before own rules');
    });

    for (final (app, key) in <(String, String)>[('com.x', 'package_name'), ('chrome.exe', 'process_name')]) {
      test('the conditions AND the app match ($key for $app)', () {
        final c = _catalog(apps: {
          app: _app('proxy', rules: [_ar('ar1', 'one.example')]),
        });
        final hit = _about(_rules(buildConfig(_plan(c))), 'one.example');
        expect(hit, hasLength(1));
        expect(hit.single['outbound'], 'proxy');
        expect(_conds(hit.single), {
          key: [app],
          'domain_suffix': ['one.example'],
        });
      });
    }

    for (final (app, key) in <(String, String)>[('com.x', 'package_name'), ('chrome.exe', 'process_name')]) {
      test('the DNS part of an app rule works like an own rule\'s, the app match ANDed into it ($key)', () {
        final c = _catalog(
          own: {'r1': _ownRule('r1', 'own.example')},
          ownOrder: ['r1'],
          apps: {
            app: _app('proxy', rules: [_ar('ar1', 'one.example', action: 'direct')]),
          },
        );
        final cfg = buildConfig(_plan(c));
        final dnsRules = (((cfg['dns'] as Map)['rules']) as List? ?? const []).cast<Map>();
        final own = dnsRules.where((r) => _says(r, 'own.example')).toList();
        expect(own, isNotEmpty, reason: 'the same direct rule without an app has its DNS rule');
        final hit = dnsRules.where((r) => _says(r, 'one.example')).toList();
        expect(hit, isNotEmpty, reason: 'the app rule is not skipped');
        for (final r in hit) {
          expect(_says(r, '"$key":["$app"]'), isTrue, reason: 'only the app\'s own queries');
        }
      });
    }

    test('an "except" condition inverts the conditions only, never the app match', () {
      final rule = _ar('ar1', 'one.example');
      ((rule['groups'] as Map)['domain'] as Map)['not'] = true;
      final c = _catalog(apps: {
        'com.x': _app('proxy', rules: [rule]),
      });
      final hit = _about(_rules(buildConfig(_plan(c))), 'one.example').single;
      expect(hit['invert'], isNull, reason: 'an invert on the outer rule would also negate package_name');
      expect(jsonEncode(hit), contains('"invert":true'));
      expect(hit['type'], 'logical');
      expect(hit['mode'], 'and');
    });

    test('a disabled rule is not routed; an app on the default route with only disabled rules emits nothing', () {
      final c = _catalog(apps: {
        'com.x': _app('proxy', rules: [_ar('ar1', 'off.example', enabled: false), _ar('ar2', 'on.example')]),
        'com.y': _app('default', rules: [_ar('ar3', 'gone.example', enabled: false)]),
      });
      final rules = _rules(buildConfig(_plan(c)));
      expect(_about(rules, 'off.example'), isEmpty);
      expect(_about(rules, 'gone.example'), isEmpty);
      expect(_about(rules, 'on.example'), hasLength(1));
      expect(_about(rules, 'com.y'), isEmpty);
    });

    test('an app on the default route with rules: only the rules, no route of its own', () {
      final c = _catalog(apps: {
        'com.x': _app('default', rules: [_ar('ar1', 'one.example')]),
      });
      final mine = _about(_rules(buildConfig(_plan(c))), 'com.x');
      expect(mine, hasLength(1));
      expect(mine.single['action'], 'route');
      expect(_conds(mine.single), {
        'package_name': ['com.x'],
        'domain_suffix': ['one.example'],
      });
    });

    test('a split app keeps each rule once; a network condition is the rule\'s own, none is added', () {
      final c = _catalog(apps: {
        'com.x': _app('proxy', split: true, udp: 'default', rules: [
          _ar('ar1', 'one.example'),
          {
            ..._ar('ar2', 'two.example'),
            'groups': {
              'domain': {
                'not': false,
                'v': {
                  'domain_suffix': ['two.example'],
                },
              },
              'network': {
                'not': false,
                'v': {
                  'network': ['udp'],
                },
              },
            },
          },
        ]),
      });
      final rules = _rules(buildConfig(_plan(c)));
      final plain = _about(rules, 'one.example');
      expect(plain, hasLength(1));
      expect(_conds(plain.single).containsKey('network'), isFalse);
      final udp = _about(rules, 'two.example');
      expect(udp, hasLength(1));
      expect(_conds(udp.single)['network'], ['udp']);
    });

    test('a direct app rule resolves its names first, as an own rule does', () {
      final c = _catalog(apps: {
        'com.x': _app('default', rules: [_ar('ar1', 'dir.example', action: 'direct')]),
      });
      final mine = _about(_rules(buildConfig(_plan(c))), 'dir.example');
      expect(mine.map((r) => r['action']), ['resolve', 'route']);
      expect(mine.last['outbound'], 'direct');
    });

    test('the rule\'s target and "If unavailable" are used as on an own rule', () {
      final c = _catalog(apps: {
        'com.x': _app('default', rules: [_ar('ar1', 'one.example', target: 'src:a', fallback: 'block')]),
      });
      final mine = _about(_rules(buildConfig(_plan(c))), 'one.example');
      expect(mine, hasLength(1));
      expect(mine.single['outbound'], 'src:a~block');
    });

    test('event data of an app rule names the rule and its app', () {
      final info = RoutingInfo();
      final c = _catalog(apps: {
        'com.x': _app('proxy', rules: [_ar('ar1', 'one.example', name: 'Blocked one')]),
      });
      final hit = _about(_rules(buildConfig(_plan(c), info: info)), 'one.example').single;
      final text = ruleText(hit);
      expect(text, isNotNull, reason: 'the text the connection reports for this rule');
      expect(ruleEventData(info.ruleNames, text!), {'kind': 'appRule', 'app': 'com.x', 'id': 'ar1', 'name': 'Blocked one'});
    });
  });

  group('exclude_package', () {
    test('a fully Direct app goes out of the tunnel only without enabled rules', () {
      final c = _catalog(apps: {
        'com.bank': _app('direct'),
        'com.bank2': _app('direct', rules: [_ar('ar1', 'one.example', action: 'direct')]),
        'com.bank3': _app('direct', rules: [_ar('ar2', 'two.example', action: 'direct', enabled: false)]),
        'com.half': _app('direct', split: true, udp: 'default'),
        'com.chat': _app('proxy'),
      });
      final cfg = buildConfig(_plan(c, mode: 'tun'), tunnelPort: _tunnelPort);
      expect(_tun(cfg)!['exclude_package'], unorderedEquals(['com.bank', 'com.bank3']), reason: 'com.bank2 has an enabled rule; the disabled one is not in the plan');
    });

    test('Global: app rules and exclude_package are ignored', () {
      final c = _catalog(apps: {
        'com.x': _app('proxy', rules: [_ar('ar1', 'one.example')]),
        'com.bank': _app('direct'),
      });
      final cfg = buildConfig(_plan(c, global: true, mode: 'tun'), tunnelPort: _tunnelPort);
      expect(_about(_rules(cfg), 'one.example'), isEmpty);
      expect(_about(_rules(cfg), 'com.x'), isEmpty);
      expect(_tun(cfg)!.containsKey('exclude_package'), isFalse);
    });
  });
}
