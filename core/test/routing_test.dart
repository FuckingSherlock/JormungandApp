// Rules / apps / quick rules / DNS (plan.routing) → sing-box: the builder's output, a
// sing-box check of a config using every feature, and a loopback run with two fake DNS
// servers (which rule sends where, which server resolves). Nothing leaves the machine.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

Map<String, dynamic> _grp(List<Map> outbounds, {String pick = 'fastest', String prefix = 's'}) => {
      'pick': pick,
      'chosen': pick == 'priority' ? '$prefix::0' : null,
      'nodes': [for (var i = 0; i < outbounds.length; i++) {'key': '$prefix::$i', 'outbound': outbounds[i]}],
    };

final _node = parseLink(ssSip002)!.outbound;
final _node2 = parseLink(trojanGrpc)!.outbound;

Map<String, dynamic> _plan(Map<String, dynamic> routing, {bool global = false}) => {
      'kind': 'unit',
      'main': _grp([_node]),
      'global': global,
      'routing': routing,
    };

Map<String, dynamic> _rule(Map<String, dynamic> groups, {String action = 'proxy', String target = '', String fallback = 'default', String dns = 'auto', String id = 'r1'}) => {
      'id': id,
      'name': '',
      'action': action,
      'target': target,
      'fallback': fallback,
      'block': 'drop',
      'dns': dns,
      'groups': groups,
    };

Map<String, dynamic> _g(Map<String, List<String>> v, {bool not = false, bool flag = false}) => {'not': not, 'v': v, if (flag) 'flag': true};

// after sniff and the local-networks rule (first always)
List<Map> _rules(Map<String, dynamic> config) => ((config['route'] as Map)['rules'] as List).cast<Map>().skip(2).toList();
const _lan = {'ip_is_private': true, 'domain_suffix': lanSuffixes, 'action': 'route', 'outbound': 'direct'};
Map _lanRule(Map<String, dynamic> config) => ((config['route'] as Map)['rules'] as List).cast<Map>()[1];
Map? _out(Map<String, dynamic> config, String tag) => (config['outbounds'] as List).cast<Map>().where((o) => o['tag'] == tag).firstOrNull;

const _defaultDns = {
  'servers': [
    {'id': 'remote', 'addr': 'https://1.1.1.1/dns-query', 'via': 'vpn', 'on': true},
    {'id': 'local', 'addr': 'system', 'via': 'direct', 'on': true},
    {'id': 'google', 'addr': 'tls://dns.google', 'via': 'vpn', 'on': false},
  ],
};

void main() {
  group('rules', () {
    test('no routing in the plan: local networks direct, the rest through the main flow', () {
      final c = buildConfig({'kind': 'unit', 'main': _grp([_node])});
      expect(_lanRule(c), _lan);
      expect(_rules(c), isEmpty);
      expect(c['route']['final'], 'proxy');
      expect(c['experimental']['cache_file']['enabled'], true);
    });

    test('Global: rules, apps and quick rules are ignored, local networks still direct', () {
      final c = buildConfig(_plan({
        'rules': [_rule({'domain': _g({'domain_suffix': ['a.com']})}, action: 'block')],
        'apps': [{'id': 'org.telegram.messenger', 'act': 'block'}],
        'quick': {'lan': true, 'ads': true, 'final': 'direct'},
      }, global: true));
      expect(_lanRule(c), _lan, reason: 'local networks go direct in Global too');
      expect(_rules(c), isEmpty);
      expect(c['route']['final'], 'proxy');
    });

    test('one group: a flat rule; domain AND port stay flat (sing-box ANDs them)', () {
      final c = buildConfig(_plan({
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['.corp.local', 'intra.example.com'], 'domain': ['*.wild.example', 'exact.example']})}, action: 'direct'),
          _rule({'domain': _g({'domain_keyword': ['tracker']}), 'port': _g({'port': ['443', '8000-9000']})}, action: 'block', id: 'r2'),
        ],
      }));
      final names = {
        'domain': ['exact.example'],
        'domain_suffix': ['corp.local', 'intra.example.com', 'wild.example'],
      };
      expect(_rules(c)[0], {...names, 'action': 'resolve'}, reason: 'a direct rule with names resolves them by the DNS rules first');
      expect(_rules(c)[1], {...names, 'action': 'route', 'outbound': 'direct'});
      expect(_rules(c)[2], {'domain_keyword': ['tracker'], 'port': [443], 'port_range': ['8000:9000'], 'action': 'reject', 'method': 'drop'});
    });

    test('domain AND IP: logical and (a flat rule would OR them); except → invert', () {
      final c = buildConfig(_plan({
        'rules': [
          _rule({
            'domain': _g({'domain_suffix': ['a.com']}),
            'ip': _g({'ip_cidr': ['10.0.0.0/8', '1.1.1.1-1.1.1.9']}, not: true),
          }, action: 'direct'),
        ],
      }));
      final rules = _rules(c);
      expect(rules.first, {'action': 'resolve'}, reason: 'IP conditions need the IP of a domain');
      final match = {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'domain_suffix': ['a.com']},
          {'ip_cidr': ['10.0.0.0/8', '1.1.1.1/32', '1.1.1.2/31', '1.1.1.4/30', '1.1.1.8/31'], 'invert': true},
        ],
      };
      expect(rules[1], {...match, 'action': 'resolve'}, reason: 'then the direct names are resolved by the DNS rules');
      expect(rules[2], {...match, 'action': 'route', 'outbound': 'direct'});
    });

    test('process: names, paths and * paths are OR; source IP AND source port', () {
      final c = buildConfig(_plan({
        'rules': [
          _rule({
            'process': _g({'process': ['chrome.exe', r'C:\Tools\app.exe', r'C:\Games\*\game.exe']}),
            'source': _g({'source_ip_cidr': ['192.168.1.0/24'], 'source_port': ['5000-6000']}),
          }, action: 'direct'),
        ],
      }));
      expect(_rules(c).first, {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'source_ip_cidr': ['192.168.1.0/24'], 'source_port_range': ['5000:6000']},
          {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'process_name': ['chrome.exe']},
              {'process_path': [r'C:\Tools\app.exe']},
              {'process_path_regex': [r'(?i)^C:\\Games\\.*\\game\.exe$']},
            ],
          },
        ],
        'action': 'route',
        'outbound': 'direct',
      });
    });

    test('targets: one group per target, shared by rules and apps; a chain dials through its entry', () {
      final targets = {
        'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
        'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
      };
      final c = buildConfig(_plan({
        'targets': targets,
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a'),
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', id: 'r2'),
          _rule({'network': _g({'network': ['udp']})}, target: 'chain:c', id: 'r3'),
        ],
        'apps': [
          {'id': 'com.discord', 'kind': 'package', 'act': 'proxy', 'target': 'src:a', 'split': true, 'udp': {'act': 'proxy', 'target': 'chain:c'}},
        ],
      }));
      final outs = (c['outbounds'] as List).cast<Map>();
      expect(outs.where((o) => o['tag'] == 'src:a'), hasLength(1));
      expect(_out(c, 'src:a')!['type'], 'urltest');
      expect(_out(c, 'src:a')!['outbounds'], ['src:a/a::0', 'src:a/a::1']);
      expect(_out(c, 'chain:c')!['type'], 'selector');
      expect(_out(c, 'chain:c/out::0')!['detour'], 'chain:c>entry');
      // rules and apps lead to a selector [target, fallback] per target (Main flow by default): live "If unavailable"
      expect(_rules(c).take(2), [
        {'package_name': ['com.discord'], 'network': ['tcp'], 'action': 'route', 'outbound': 'src:a~proxy'},
        {'package_name': ['com.discord'], 'network': ['udp'], 'action': 'route', 'outbound': 'chain:c~proxy'},
      ]);
      expect(_rules(c).map((r) => r['outbound']).skip(2).take(3), ['src:a~proxy', 'src:a~proxy', 'chain:c~proxy']);
      expect(_out(c, 'src:a~proxy'), {
        'type': 'selector',
        'tag': 'src:a~proxy',
        'outbounds': ['src:a', 'proxy'],
        'default': 'src:a',
        'interrupt_exist_connections': false,
      });
    });

    test('If unavailable live: a selector per (target, fallback); Block is an outbound only a selector holds; the info names the rules', () {
      final targets = {
        'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
        'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
      };
      final info = RoutingInfo();
      final c = buildConfig(_plan({
        'fallback': 'main',
        'targets': targets,
        'rules': [
          {..._rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'block'), 'name': 'Streaming'},
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', fallback: 'block', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, target: 'src:a', fallback: 'direct', id: 'r3'),
          _rule({'domain': _g({'domain_suffix': ['d.com']})}, target: 'chain:c', id: 'r4'),
        ],
        'apps': [
          {'id': 'com.x', 'kind': 'package', 'act': 'proxy', 'target': 'src:a'},
        ],
      }), info: info);
      expect(_out(c, 'block'), {'type': 'block', 'tag': 'block'});
      expect(_out(c, 'src:a~block')!['outbounds'], ['src:a', 'block']);
      expect(_out(c, 'src:a~direct')!['outbounds'], ['src:a', 'direct']);
      expect(_out(c, 'src:a~proxy')!['outbounds'], ['src:a', 'proxy'], reason: 'the app has the global fallback: Main flow');
      expect(_out(c, 'chain:c~proxy')!['default'], 'chain:c');
      expect(info.fallbacks.map((f) => '${f.tag} ${f.target} ${f.to} ${f.rules.join('/')}|${f.apps.join('/')}'), [
        'src:a~proxy src:a main |com.x',
        'src:a~block src:a block Streaming/rule r2|',
        'src:a~direct src:a direct rule r3|',
        'chain:c~proxy chain:c main rule r4|',
      ]);
      expect(_rules(c).map((r) => r['outbound']).skip(1), ['src:a~block', 'src:a~block', 'src:a~direct', 'chain:c~proxy']);
      // the main flow is no target: no selector, no fallback to watch
      final main = RoutingInfo();
      buildConfig(_plan({'rules': [_rule({'domain': _g({'domain_suffix': ['a.com']})}, target: '')]}), info: main);
      expect(main.fallbacks, isEmpty);
    });

    test('apps: a proxy half has "If unavailable" like a rule (selectors shared), split per network, Default half = no rule', () {
      final targets = {
        'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
        'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
      };
      final info = RoutingInfo();
      final c = buildConfig(_plan({
        'fallback': 'main',
        'targets': targets,
        'rules': [_rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'block', id: 'r1')],
        'apps': [
          // TCP through a target that goes Block when down, UDP through another that goes Direct
          {'id': 'com.tg', 'kind': 'package', 'name': 'Telegram', 'act': 'proxy', 'target': 'src:a', 'fallback': 'block', 'split': true,
            'udp': {'act': 'proxy', 'target': 'chain:c', 'fallback': 'direct'}},
          // TCP Default, UDP Block: only a udp reject rule (QUIC dies, the app falls back to TCP)
          {'id': 'chrome.exe', 'kind': 'process', 'name': 'Chrome', 'act': 'default', 'split': true, 'udp': {'act': 'block'}},
          // TCP Direct, UDP Default
          {'id': 'a.exe', 'kind': 'process', 'act': 'direct', 'split': true, 'udp': {'act': 'default'}},
          // one action for everything, "Default" fallback = the global one
          {'id': 'com.d', 'kind': 'package', 'name': 'Dd', 'act': 'proxy', 'target': 'src:a'},
          // both halves Default: no rule at all
          {'id': 'com.none', 'kind': 'package', 'act': 'default', 'split': true, 'udp': {'act': 'default'}},
        ],
      }), info: info);
      expect(_rules(c).take(5), [
        {'package_name': ['com.tg'], 'network': ['tcp'], 'action': 'route', 'outbound': 'src:a~block'},
        {'package_name': ['com.tg'], 'network': ['udp'], 'action': 'route', 'outbound': 'chain:c~direct'},
        {'process_name': ['chrome.exe'], 'network': ['udp'], 'action': 'reject'},
        {'process_name': ['a.exe'], 'network': ['tcp'], 'action': 'route', 'outbound': 'direct'},
        {'package_name': ['com.d'], 'action': 'route', 'outbound': 'src:a~proxy'},
      ]);
      expect(_rules(c).where((r) => '${r['package_name']}'.contains('com.none')), isEmpty);
      expect(_out(c, 'chain:c~direct')!['outbounds'], ['chain:c', 'direct']);
      // the rule and the app share src:a~block; the journal names both
      expect([for (final f in info.fallbacks) '${f.tag} r=${f.rules.join('/')} a=${f.apps.join('/')}'], [
        'src:a~block r=rule r1 a=Telegram',
        'chain:c~direct r= a=Telegram',
        'src:a~proxy r= a=Dd',
      ]);
      // a target that is unavailable now: the half's own fallback, the global one for Default
      final gone = buildConfig(_plan({
        'fallback': 'direct',
        'targets': {'src:off': null},
        'apps': [
          {'id': 'com.q', 'kind': 'package', 'act': 'proxy', 'target': 'src:off', 'fallback': 'block', 'split': true, 'udp': {'act': 'proxy', 'target': 'src:off'}},
        ],
      }));
      expect(_rules(gone).take(2), [
        {'package_name': ['com.q'], 'network': ['tcp'], 'action': 'reject'},
        {'package_name': ['com.q'], 'network': ['udp'], 'action': 'route', 'outbound': 'direct'},
      ]);
    });

    test('an unavailable target takes the rule\'s If unavailable; Default = the global setting; apps use the global one', () {
      final c = buildConfig(_plan({
        'fallback': 'direct',
        'targets': {'profile:gone': null},
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'profile:gone', fallback: 'block'),
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'chain:deleted', fallback: 'main', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, target: 'src:off', id: 'r3'),
        ],
        'apps': [{'id': 'org.telegram.messenger', 'act': 'proxy', 'target': 'src:off'}],
      }));
      final rules = _rules(c);
      expect(rules[0], {'package_name': ['org.telegram.messenger'], 'action': 'route', 'outbound': 'direct'});
      expect(rules[1], {'domain_suffix': ['a.com'], 'action': 'reject'});
      expect(rules[2]['outbound'], 'proxy');
      expect(rules[3], {'domain_suffix': ['c.com'], 'action': 'resolve'}, reason: 'the global fallback is Direct: its names are resolved by the DNS rules');
      expect(rules[4]['outbound'], 'direct');
    });

    test('no `targets` key at all: the main flow keeps its "If unavailable", a catalog target is simply unavailable (no crash)', () {
      final c = buildConfig(_plan({
        'fallback': 'direct',
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'block'),
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', fallback: 'chain:c', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, fallback: 'block', id: 'r3'),
        ],
        'apps': [
          {'id': 'a.exe', 'kind': 'process', 'act': 'default', 'fallback': 'block'},
          {'id': 'b.exe', 'kind': 'process', 'act': 'proxy', 'target': 'src:a', 'fallback': 'direct'},
        ],
      }));
      final rules = _rules(c);
      expect(rules[0], {'process_name': ['a.exe'], 'action': 'route', 'outbound': 'proxy~block'});
      expect(rules[1], {'process_name': ['b.exe'], 'action': 'route', 'outbound': 'direct'}, reason: 'unavailable target → its If unavailable');
      expect(rules[2], {'domain_suffix': ['a.com'], 'action': 'reject'});
      expect(rules[3], {'domain_suffix': ['b.com'], 'action': 'resolve'});
      expect(rules[4], {'domain_suffix': ['b.com'], 'action': 'route', 'outbound': 'direct'}, reason: 'the fallback target is unavailable too → the global default');
      expect(rules[5], {'domain_suffix': ['c.com'], 'action': 'route', 'outbound': 'proxy~block'});
      expect(_out(c, 'proxy~block'), isNotNull);
    });

    test('If unavailable → another target: selector [target, fallback target, main flow], both targets\' groups exist, a chain works as the fallback', () {
      final targets = {
        'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
        'src:b': {'kind': 'unit', 'main': _grp([_node2], prefix: 'b')},
        'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
      };
      final info = RoutingInfo();
      final w = <String>[];
      final c = buildConfig(_plan({
        'fallback': 'block',
        'targets': targets,
        'rules': [
          {..._rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'src:b'), 'name': 'Video'},
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', fallback: 'chain:c', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, target: 'src:a', fallback: 'src:b', id: 'r3'),
        ],
        'apps': [
          {'id': 'com.x', 'kind': 'package', 'act': 'proxy', 'target': 'src:b', 'fallback': 'chain:c', 'split': true,
            'udp': {'act': 'proxy', 'target': 'src:a', 'fallback': 'src:b'}},
        ],
      }), info: info, warnings: w);
      expect(_out(c, 'src:a~src:b')!['outbounds'], ['src:a', 'src:b', 'proxy']);
      expect(_out(c, 'src:a~src:b')!['default'], 'src:a');
      expect(_out(c, 'src:a~chain:c')!['outbounds'], ['src:a', 'chain:c', 'proxy']);
      expect(_out(c, 'src:b~chain:c')!['outbounds'], ['src:b', 'chain:c', 'proxy']);
      for (final tag in ['src:a', 'src:b', 'chain:c', 'chain:c>entry']) {
        expect(_out(c, tag), isNotNull, reason: 'the group $tag is in the config');
      }
      expect(_out(c, 'chain:c/out::0')!['detour'], 'chain:c>entry');
      expect(_out(c, 'block'), isNull, reason: 'no Block fallback in use: no block outbound');
      expect([for (final f in info.fallbacks) '${f.tag} ${f.target}>${f.fallbackTarget} to=${f.to} ${f.rules.join('/')}|${f.apps.join('/')}'], [
        'src:b~chain:c src:b>chain:c to=chain:c |com.x',
        'src:a~src:b src:a>src:b to=src:b Video/rule r3|com.x',
        'src:a~chain:c src:a>chain:c to=chain:c rule r2|',
      ]);
      expect(info.fallbacks[1].fallbackSpec, same(targets['src:b']));
      expect(w, isEmpty);
    });

    test('a fallback target equal to the target is the main flow; an empty one too; a global one that is a target is main', () {
      final targets = {'src:a': {'kind': 'unit', 'main': _grp([_node], prefix: 'a')}};
      final info = RoutingInfo();
      final c = buildConfig(_plan({
        'fallback': 'src:a',
        'targets': targets,
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'src:a'),
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', fallback: '', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, target: 'src:a', id: 'r3'),
        ],
      }), info: info);
      expect(_out(c, 'src:a~proxy')!['outbounds'], ['src:a', 'proxy']);
      expect(info.fallbacks.map((f) => f.tag), ['src:a~proxy'], reason: 'one selector, shared');
      expect(info.fallbacks.single.fallbackTarget, isNull);
    });

    test('a fallback target that is gone / off: the default applies and a warning says so, with the target out now the fallback target is used straight', () {
      final targets = {
        'src:a': {'kind': 'unit', 'main': _grp([_node], prefix: 'a')},
        'src:b': {'kind': 'unit', 'main': _grp([_node2], prefix: 'b')},
        'src:off': null,
      };
      final info = RoutingInfo();
      final w = <String>[];
      final c = buildConfig(_plan({
        'fallback': 'direct',
        'targets': targets,
        'rules': [
          {..._rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:a', fallback: 'chain:deleted'), 'name': 'One'},
          _rule({'domain': _g({'domain_suffix': ['b.com']})}, target: 'src:a', fallback: 'src:off', id: 'r2'),
          // the target is out now, the fallback target answers: straight to it, with the main flow behind it
          _rule({'domain': _g({'domain_suffix': ['c.com']})}, target: 'src:off', fallback: 'src:b', id: 'r3'),
          // both out now: the default
          _rule({'domain': _g({'domain_suffix': ['d.com']})}, target: 'src:off', fallback: 'chain:deleted', id: 'r4'),
        ],
      }), info: info, warnings: w);
      expect(_rules(c).map((r) => r['outbound']), ['src:a~direct', 'src:a~direct', 'src:b~proxy', null, 'direct'], reason: 'null: the resolve step of the direct one');
      expect(_out(c, 'src:a~direct')!['outbounds'], ['src:a', 'direct']);
      expect(info.fallbacks.every((f) => f.fallbackTarget == null), isTrue);
      expect(w, [
        'One: "If unavailable" target chain:deleted is not available, the default applies',
        'rule r2: "If unavailable" target src:off is not available, the default applies',
        'rule r4: "If unavailable" target chain:deleted is not available, the default applies',
      ]);
    });

    test('the main flow has "If unavailable" when an app asks for it explicitly: Default / Proxy with the main flow + block / direct / a target', () {
      final targets = {
        'src:b': {'kind': 'unit', 'main': _grp([_node2], prefix: 'b')},
        'src:off': null,
      };
      final info = RoutingInfo();
      final w = <String>[];
      final plan = _plan({
        'fallback': 'block', // the global one never reaches the main flow
        'targets': targets,
        'apps': [
          {'id': 'a.exe', 'kind': 'process', 'name': 'A', 'act': 'default', 'fallback': 'block'},
          {'id': 'b.exe', 'kind': 'process', 'act': 'default', 'fallback': 'direct'},
          {'id': 'c.exe', 'kind': 'process', 'act': 'default', 'fallback': 'src:b'},
          {'id': 'd.exe', 'kind': 'process', 'act': 'proxy', 'target': '', 'fallback': 'block'},
          // asks for none: no rule (Default) / the main flow (Proxy)
          {'id': 'e.exe', 'kind': 'process', 'act': 'default', 'fallback': 'default'},
          {'id': 'f.exe', 'kind': 'process', 'act': 'default', 'fallback': 'main'},
          {'id': 'g.exe', 'kind': 'process', 'act': 'proxy', 'target': '', 'fallback': 'default'},
          // the fallback target is not available: no fallback, a warning; Default has no rule then
          {'id': 'h.exe', 'kind': 'process', 'act': 'default', 'fallback': 'src:off'},
          {'id': 'i.exe', 'kind': 'process', 'act': 'proxy', 'target': '', 'fallback': 'chain:gone'},
          // TCP Default + a fallback, UDP Direct
          {'id': 'j.exe', 'kind': 'process', 'act': 'default', 'fallback': 'block', 'split': true, 'udp': {'act': 'direct'}},
        ],
      });
      final c = buildConfig(plan, info: info, warnings: w);
      expect(_rules(c).map((r) => '${r['process_name']}${r['network'] ?? ''} ${r['outbound']}'), [
        '[a.exe] proxy~block',
        '[b.exe] proxy~direct',
        '[c.exe] proxy~src:b',
        '[d.exe] proxy~block',
        '[g.exe] proxy',
        '[i.exe] proxy',
        '[j.exe][tcp] proxy~block',
        '[j.exe][udp] direct',
      ]);
      expect(_out(c, 'proxy~block'), containsPair('outbounds', ['proxy', 'block']));
      expect(_out(c, 'proxy~block'), containsPair('default', 'proxy'));
      expect(_out(c, 'proxy~direct')!['outbounds'], ['proxy', 'direct']);
      expect(_out(c, 'proxy~src:b')!['outbounds'], ['proxy', 'src:b'], reason: 'the main flow is the target: no third member');
      expect(_out(c, 'src:b'), isNotNull);
      expect([for (final f in info.fallbacks) '${f.tag} ${f.target}>${f.fallbackTarget} ${f.to} ${f.apps.join('/')}'], [
        'proxy~block proxy>null block A/d.exe/j.exe',
        'proxy~direct proxy>null direct b.exe',
        'proxy~src:b proxy>src:b src:b c.exe',
      ]);
      expect(w, [
        'h.exe: "If unavailable" target src:off is not available, the main flow has none',
        'i.exe: "If unavailable" target chain:gone is not available, the main flow has none',
      ]);
      // the probe also tests 'direct' (to tell a dead main flow from a dead network), always
      final probe = Probe(1081, 'x');
      final users = (buildConfig(plan, probe: probe)['inbounds'] as List).cast<Map>().firstWhere((i) => i['tag'] == probeInboundTag)['users'] as List;
      expect([for (final u in users) u['username']], contains('direct'));
      final plain = buildConfig(_plan({'rules': [_rule({'domain': _g({'domain_suffix': ['a.com']})}, target: 'src:b')], 'targets': targets}), probe: probe);
      expect(((plain['inbounds'] as List).cast<Map>().firstWhere((i) => i['tag'] == probeInboundTag)['users'] as List).map((u) => u['username']), contains('direct'),
          reason: 'the probe pool\'s network check: always (pool.dart)');
    });

    test('quick rules and everything else, in order after the own rules', () {
      final c = buildConfig(_plan({
        'rules': [_rule({'domain': _g({'domain_suffix': ['mine.com']})}, action: 'direct')],
        'quick': {'ads': true, 'region': 'RU', 'services': {'telegram': 'vpn', 'youtube': 'direct', 'discord': 'default'}, 'final': 'block'},
        'dns': _defaultDns,
      }), ruleSetFiles: {'geosite-category-ru': '/l/ru.srs', 'geoip-ru': '/l/geoip-ru.srs', 'geosite-telegram': '/l/tg.srs'});
      final rules = _rules(c);
      expect(rules[0], {'domain_suffix': ['mine.com'], 'action': 'resolve'});
      expect(rules[1]['domain_suffix'], ['mine.com']);
      expect(rules[1]['outbound'], 'direct');
      expect(rules[2], {'domain_suffix': adsDomains, 'action': 'reject'}, reason: 'no ad list on disk: the built-in domains');
      expect(rules[3], {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'domain_suffix': services['telegram']!.domains},
          {'rule_set': ['geosite-telegram']},
        ],
        'action': 'route',
        'outbound': 'proxy',
      });
      expect(rules[4], {'domain_suffix': services['youtube']!.domains, 'action': 'resolve'});
      expect(rules[5]['outbound'], 'direct');
      expect(rules[6], {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'domain_suffix': ['ru', 'xn--p1ai', 'su']},
          {'rule_set': ['geosite-category-ru']},
        ],
        'action': 'resolve',
      }, reason: 'the region\'s names only, not its IPs');
      expect(rules[7]['rules'], [
        {'domain_suffix': ['ru', 'xn--p1ai', 'su']},
        {'rule_set': ['geosite-category-ru']},
        {'rule_set': ['geoip-ru']},
      ]);
      expect(rules[8], {'action': 'reject'}, reason: 'Everything else: Block');
      expect((c['route']['rule_set'] as List).map((s) => s['tag']).where((t) => !'$t'.startsWith('flag-')), unorderedEquals(['geosite-category-ru', 'geoip-ru', 'geosite-telegram']));
      expect(c['route']['rule_set'][0]['type'], 'local');
    });

    test('a missing list: narrows a rule, or skips it where a missing list would flip it', () {
      final w = <String>[];
      final c = buildConfig(_plan({
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com'], 'geosite': ['youtube']})}, action: 'direct'),
          _rule({'domain': _g({'geosite': ['youtube']}, not: true)}, action: 'direct', id: 'r2'),
          _rule({'domain': _g({'geosite': ['netflix']})}, action: 'direct', id: 'r3'),
        ],
        'quick': {'final': 'proxy'},
      }), ruleSetFiles: {'geosite-netflix': '/l/nf.srs'}, warnings: w);
      final rules = _rules(c);
      expect(rules.where((r) => r['action'] != 'resolve'), hasLength(2));
      expect(rules[0], {'domain_suffix': ['a.com'], 'action': 'resolve'});
      expect(rules[1], {'domain_suffix': ['a.com'], 'action': 'route', 'outbound': 'direct'});
      expect(rules[2], {'rule_set': ['geosite-netflix'], 'action': 'resolve'});
      expect(rules[3], {'rule_set': ['geosite-netflix'], 'action': 'route', 'outbound': 'direct'});
      expect(w, hasLength(2));
    });

    test('a composite (JSON) rule passes through with its lists swapped for local files', () {
      final c = buildConfig(_plan({
        'ruleSets': [{'name': 'blocked', 'url': 'https://example.org/b.srs', 'format': 'srs', 'via': 'vpn', 'every': 86400}],
        'rules': [
          {
            ..._rule({}, action: 'block'),
            'composite': {
              'type': 'logical',
              'mode': 'or',
              'rules': [
                {'geosite': ['category-porn']},
                {'rule_set': ['blocked'], 'port': [443]},
              ],
              'action': 'reject',
              'method': 'drop',
            },
          },
        ],
      }), ruleSetFiles: {'geosite-category-porn': '/l/p.srs', 'set-blocked': '/l/b.srs'});
      expect(_rules(c).first, {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'rule_set': ['geosite-category-porn']},
          {'port': [443], 'rule_set': ['set-blocked']},
        ],
        'action': 'reject',
        'method': 'drop',
      });
    });

    test('ruleSetsNeeded: runetfreedom first, SagerNet next; user lists by name', () {
      final need = ruleSetsNeeded(_plan({
        'ruleSets': [{'name': 'blocked', 'url': 'https://example.org/b.json', 'format': 'json', 'via': 'direct', 'every': 3600}],
        'geo': {
          'geosite': {'via': 'vpn', 'every': 86400},
          'geoip': {'via': 'direct', 'every': 86400},
        },
        'rules': [
          _rule({'domain': _g({'geosite': ['youtube'], 'rule_set': ['blocked']}), 'ip': _g({'geoip': ['NL']})}),
        ],
        'quick': {'ads': true, 'region': 'RU', 'services': {'telegram': 'vpn'}},
      }));
      final byTag = {for (final s in need) s.tag: s};
      expect(byTag.keys, containsAll(['geosite-youtube', 'set-blocked', 'geoip-nl', 'geosite-category-ads-all', 'geosite-category-ru', 'geoip-ru', 'geosite-telegram', 'geoip-telegram']));
      expect(byTag['geosite-youtube']!.urls.first, contains('runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-youtube.srs'));
      expect(byTag['geosite-youtube']!.urls.last, contains('SagerNet/sing-geosite/rule-set/'));
      expect(byTag['geoip-nl']!.viaVpn, false);
      expect(byTag['geosite-youtube']!.every, const Duration(days: 1));
      expect(byTag['set-blocked']!.binary, false);
      expect(byTag['set-blocked']!.every, const Duration(hours: 1));
      expect(ruleSetsNeeded(_plan({'quick': {'ads': true}}, global: true)), isEmpty);
    });
  });

  group('dns', () {
    test('the plan shape before the rework ({id, addr, via, on}) builds: one transport on the one side it names', () {
      final info = RoutingInfo();
      final c = buildConfig(_plan({'dns': _defaultDns}), info: info);
      final dns = c['dns'] as Map;
      expect(dns['servers'], [
        {'type': 'local', 'tag': 'dns-local'},
        {'type': 'https', 'tag': 'dns-remote-doh1-v', 'server': '1.1.1.1', 'detour': 'proxy'},
      ]);
      expect(dns['final'], 'dns-remote-doh1-v', reason: 'the catch-all is the VPN side');
      expect(dns.containsKey('rules'), isFalse, reason: 'one candidate per side: nothing to try in turn');
      expect(c['route']['default_domain_resolver'], 'dns-local');
      expect(info.dnsServers.map((s) => '${s.id}=${s.tag}'), ['local=dns-local', 'remote-doh1-v=dns-remote-doh1-v']);
      expect(info.dnsVpn, {'remote-doh1-v'});
    });

    test('the older shape: a server that is off is no candidate, a bare address is plain UDP, no VPN candidate = the direct side answers the rest', () {
      final c = buildConfig(_plan({
        'dns': {
          'servers': [
            {'id': 'a', 'addr': '9.9.9.9:5353', 'via': 'direct', 'on': true},
            {'id': 'b', 'addr': 'tls://dns.google', 'on': false},
          ],
        },
      }));
      expect((c['dns'] as Map)['servers'], [
        {'type': 'local', 'tag': 'local'},
        {'type': 'udp', 'tag': 'dns-a-udp1', 'server': '9.9.9.9', 'server_port': 5353},
      ], reason: 'no Local server in the list: the OS resolver is there for the hostnames');
      expect((c['dns'] as Map)['final'], 'dns-a-udp1', reason: 'no VPN candidate: the direct side answers the rest');
    });

    group('providers and flags', () {
      Map<String, dynamic> prov(String id, Map<String, List<String>> addrs,
              {List<String> sides = const ['direct', 'vpn'], List<String> use = const ['doh', 'dot'], bool on = true}) =>
          {
            'id': id,
            'on': on,
            'sides': sides,
            'use': use,
            'transports': [
              for (final e in addrs.entries)
                for (final a in e.value) {'kind': e.key, 'addr': a},
            ],
          };
      final cf = prov('cf', {
        'doh': ['https://1.1.1.1/dns-query', 'https://1.0.0.1/dns-query'],
        'dot': ['tls://1.1.1.1'],
        'udp': ['1.1.1.1'],
      });
      final gg = prov('gg', {'doh': ['https://8.8.8.8/dns-query'], 'dot': ['tls://dns.google']});
      const local = {
        'id': 'local',
        'on': true,
        'sides': ['direct'],
        'use': <String>[],
        'transports': [{'kind': 'system', 'addr': 'system'}],
      };
      Map<String, dynamic> dnsOf(List<Map> servers, {String? policy}) => {'servers': servers, 'directPolicy': ?policy};
      List<String> ids(Iterable<DnsCandidate> l) => [for (final c in l) c.id];

      test('a candidate per enabled transport and side: tags, detour on the VPN side, the order of each side', () {
        final info = RoutingInfo();
        final c = buildConfig(_plan({'dns': dnsOf([cf, gg, local])}), info: info, dnsFlagDir: 'F');
        // udp is not in `use`: no candidate
        expect(ids(info.dnsSides['direct']!), ['local', 'cf-doh1', 'cf-doh2', 'cf-dot1', 'gg-doh1', 'gg-dot1'], reason: 'Local first on the direct side');
        expect(ids(info.dnsSides['vpn']!), ['cf-doh1-v', 'cf-doh2-v', 'cf-dot1-v', 'gg-doh1-v', 'gg-dot1-v'], reason: 'Local is never on the VPN side');
        final servers = ((c['dns'] as Map)['servers'] as List).cast<Map>();
        expect(servers.length, 11);
        expect(servers.where((s) => s['detour'] == 'proxy').map((s) => s['tag']), everyElement(endsWith('-v')));
        expect(servers.where((s) => s['detour'] == 'proxy'), hasLength(5));
        expect(servers.firstWhere((s) => s['tag'] == 'dns-gg-dot1'), {'type': 'tls', 'tag': 'dns-gg-dot1', 'server': 'dns.google', 'domain_resolver': 'dns-local'},
            reason: 'a hostname is found by the OS resolver, itself the first direct candidate');
        expect((c['dns'] as Map)['final'], 'dns-cf-doh1-v');
        expect(c['route']['default_domain_resolver'], 'dns-local');
        expect(info.dnsCandidates, hasLength(11));
        final sets = ((c['route'] as Map)['rule_set'] as List).cast<Map>();
        expect(sets, hasLength(11), reason: 'a flag per candidate');
        expect(sets.firstWhere((s) => s['tag'] == 'flag-dns-local'), {'type': 'local', 'tag': 'flag-dns-local', 'format': 'source', 'path': p.join('F', 'dns-local.json')});
        expect(info.dnsCandidates.firstWhere((c) => c.provider == 'local').flagPath, p.join('F', 'dns-local.json'));

        // `priority`: the direct side follows the list too, Local where the list has it
        final byList = RoutingInfo();
        final c2 = buildConfig(_plan({'dns': dnsOf([cf, gg, local], policy: 'priority')}), info: byList);
        expect(ids(byList.dnsSides['direct']!), ['cf-doh1', 'cf-doh2', 'cf-dot1', 'gg-doh1', 'gg-dot1', 'local']);
        expect(c2['route']['default_domain_resolver'], 'dns-cf-doh1');
      });

      test('Local never goes through the VPN; a provider with no sides is VPN only; a provider that is off is no candidate', () {
        final info = RoutingInfo();
        buildConfig(_plan({
          'dns': dnsOf([
            {...local, 'sides': ['direct', 'vpn']},
            {...gg, 'sides': null}, // a server the user added: VPN only
            {...cf, 'on': false},
          ]),
        }), info: info);
        expect(ids(info.dnsSides['direct']!), ['local']);
        expect(ids(info.dnsSides['vpn']!), ['gg-doh1-v', 'gg-dot1-v']);
        expect(info.dnsCandidates.where((c) => c.provider == 'cf'), isEmpty);
      });

      test('the DNS rules of a side: AND(names, flag) per candidate in priority order, then the top candidate; the catch-all the same', () {
        final c = buildConfig(_plan({
          'dns': dnsOf([cf, gg, local]),
          'rules': [
            _rule({'domain': _g({'domain_suffix': ['bank.ru']})}, action: 'direct'),
            _rule({'domain': _g({'domain_suffix': ['gov.ru']})}, action: 'direct', id: 'r2'),
            _rule({'domain': _g({'domain_suffix': ['x.com']})}, id: 'r3'),
          ],
        }));
        final rules = (((c['dns'] as Map)['rules']) as List).cast<Map>();
        // bank.ru + gov.ru: one group (adjacent, the same chain), 6 candidates + the plain rule; then 5 catch-all flags
        final names = {'type': 'logical', 'mode': 'or', 'rules': [{'domain_suffix': ['bank.ru']}, {'domain_suffix': ['gov.ru']}]};
        expect(rules, hasLength(6 + 1 + 5));
        expect(rules[0], {
          'type': 'logical',
          'mode': 'and',
          'rules': [names, {'rule_set': ['flag-dns-local']}],
          'action': 'route',
          'server': 'dns-local',
        });
        expect([for (final r in rules.take(6)) r['server']], ['dns-local', 'dns-cf-doh1', 'dns-cf-doh2', 'dns-cf-dot1', 'dns-gg-doh1', 'dns-gg-dot1']);
        expect(rules[6], {...names, 'action': 'route', 'server': 'dns-local'}, reason: 'every flag off: the top candidate of the side answers');
        expect(rules[7], {'rule_set': ['flag-dns-cf-doh1-v'], 'action': 'route', 'server': 'dns-cf-doh1-v'});
        expect([for (final r in rules.skip(7)) r['server']], ['dns-cf-doh1-v', 'dns-cf-doh2-v', 'dns-cf-dot1-v', 'dns-gg-doh1-v', 'dns-gg-dot1-v']);
        expect((c['dns'] as Map)['final'], 'dns-cf-doh1-v', reason: 'and with every VPN flag off, the top VPN candidate');
      });

      test('Everything else Direct: the direct side is the catch-all, everything left is resolved by the DNS rules', () {
        final info = RoutingInfo();
        final c = buildConfig(_plan({'dns': dnsOf([cf, local]), 'quick': {'final': 'direct'}}), info: info);
        final dns = c['dns'] as Map;
        expect(dns['final'], 'dns-local');
        expect([for (final r in (dns['rules'] as List).cast<Map>()) r['server']], ['dns-local', 'dns-cf-doh1', 'dns-cf-doh2', 'dns-cf-dot1']);
        expect((c['route'] as Map)['final'], 'direct');
        expect(_rules(c).last, {'action': 'resolve'});
      });

      test('a rule\'s DNS: Auto = the side of its traffic; a named provider on that side (or its other); a provider that is off still serves the rule', () {
        final info = RoutingInfo();
        final c = buildConfig(_plan({
          'dns': dnsOf([cf, local, prov('ya', {'doh': ['https://77.88.8.8/dns-query']}, sides: ['direct'], on: false)]),
          'rules': [
            _rule({'domain': _g({'domain_suffix': ['gov.ru']})}, action: 'direct', dns: 'ya'),
            _rule({'domain': _g({'domain_suffix': ['a.com']})}, dns: 'ya', id: 'r2'),
            _rule({'domain': _g({'domain_suffix': ['b.com']})}, dns: 'cf', id: 'r3'),
          ],
        }), info: info);
        final rules = (((c['dns'] as Map)['rules']) as List).cast<Map>();
        // a.com goes via VPN but ya has only the direct side: it serves there (the same chain: one rule); one candidate: no flag
        expect(rules.first, {
          'type': 'logical',
          'mode': 'or',
          'rules': [{'domain_suffix': ['gov.ru']}, {'domain_suffix': ['a.com']}],
          'action': 'route',
          'server': 'dns-ya-doh1',
        });
        expect(info.dnsExtra.map((e) => e.tag), contains('dns-ya-doh1'));
        expect(info.dnsExtra.map((e) => e.tag), isNot(contains('dns-cf-doh1-v')));
        expect(ids(info.dnsSides['direct']!), ['local', 'cf-doh1', 'cf-doh2', 'cf-dot1'], reason: 'ya is off: not in the side');
        // b.com via VPN, cf named: cf's VPN candidates are the Auto chain already (the catch-all): no rule
        expect(rules.where((r) => '${r['domain_suffix']}' == '[b.com]'), isEmpty);
        expect(info.ruleDns, {'r1': 'dns-ya-doh1', 'r2': 'dns-ya-doh1', 'r3': 'dns-cf-doh1-v'});
      });

      test('a direct rule resolves its names by the DNS rules first: a resolve step, no outbound of its own', () {
        final c = buildConfig(_plan({
          'dns': dnsOf([cf, local]),
          'rules': [_rule({'domain': _g({'domain_suffix': ['gov.ru']})}, action: 'direct', dns: 'cf')],
        }));
        final rules = _rules(c);
        expect(rules[0], {'domain_suffix': ['gov.ru'], 'action': 'resolve'});
        expect(rules[1], {'domain_suffix': ['gov.ru'], 'action': 'route', 'outbound': 'direct'});
        expect((c['outbounds'] as List).cast<Map>().where((o) => '${o['tag']}'.startsWith('direct@')), isEmpty);
        expect(((c['dns'] as Map)['rules'] as List).cast<Map>().first['server'], 'dns-cf-doh1');
      });
    });

    test('address forms', () {
      expect(dnsServerJson('t', '8.8.8.8:5353'), {'type': 'udp', 'tag': 't', 'server': '8.8.8.8', 'server_port': 5353});
      expect(dnsServerJson('t', 'tls://dns.google'), {'type': 'tls', 'tag': 't', 'server': 'dns.google'});
      expect(dnsServerJson('t', 'https://dns.example:8443/q'), {'type': 'https', 'tag': 't', 'server': 'dns.example', 'server_port': 8443, 'path': '/q'});
      expect(dnsServerJson('t', 'quic://[2606:4700::1111]'), {'type': 'quic', 'tag': 't', 'server': '2606:4700::1111'});
      expect(dnsServerJson('t', 'ftp://x'), isNull);
    });

    test('the older shape: a rule names a server that is off: it serves that rule, a hostname is found by the OS resolver', () {
      final c = buildConfig(_plan({
        'dns': {
          'servers': [
            ..._defaultDns['servers']!,
            {'id': 'ya', 'addr': 'https://common.dot.dns.yandex.net/dns-query', 'via': 'direct', 'on': false},
          ],
        },
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['bank.ru']})}, action: 'direct'),
          _rule({'domain': _g({'domain_suffix': ['gov.ru']})}, action: 'direct', dns: 'ya', id: 'r2'),
          _rule({'domain': _g({'domain_suffix': ['x.com']})}, id: 'r3'),
        ],
      }));
      final dns = c['dns'] as Map;
      expect(dns['rules'], [
        {'domain_suffix': ['bank.ru'], 'action': 'route', 'server': 'dns-local'},
        {'domain_suffix': ['gov.ru'], 'action': 'route', 'server': 'dns-ya-doh1'},
      ], reason: 'x.com goes via VPN: the final server already; one candidate per chain: no flags');
      expect((dns['servers'] as List).last, {
        'type': 'https',
        'tag': 'dns-ya-doh1',
        'server': 'common.dot.dns.yandex.net',
        'domain_resolver': 'dns-local',
      });
    });

    group('resolve before IP rules', () {
      final ipRule = _rule({'ip': _g({'ip_cidr': ['10.0.0.0/8']})}, action: 'direct');
      Map<String, dynamic> ipRuleFlagged(String id, {bool tunOnly = false}) => {
            ..._rule({'ip': _g({'ip_cidr': ['10.0.0.0/8']})}, action: 'direct', id: id),
            if (tunOnly) 'ipTunOnly': true,
          };
      final domainRule = _rule({'domain': _g({'domain_suffix': ['a.com']})}, id: 'rd');
      List<Map> run(Map<String, dynamic> dns, List<Map<String, dynamic>> rules, [List<String>? w]) =>
          _rules(buildConfig(_plan({'dns': dns, 'rules': rules}), warnings: w));
      Map<String, dynamic> withResolve(Object? resolve, [List<Map>? servers]) => {'servers': servers ?? _defaultDns['servers'], 'resolve': ?resolve};

      test('default (auto): the first ticked server via VPN, named explicitly, before the first IP rule only', () {
        for (final dns in [_defaultDns, withResolve('auto')]) {
          final rules = run(dns, [domainRule, ipRule, ipRuleFlagged('r3')]);
          expect(rules.map((r) => r['action']), ['route', 'resolve', 'route', 'route']);
          expect(rules[1], {'action': 'resolve', 'server': 'dns-remote-doh1-v'});
        }
      });

      test('off: no resolve step, the IP rule stays', () {
        final rules = run(withResolve('off'), [ipRule]);
        expect(rules.map((r) => r['action']), ['route']);
        expect(rules.single['ip_cidr'], ['10.0.0.0/8']);
      });

      test('a named server (even a direct one); deleted or unticked = auto again', () {
        expect(run(withResolve('local'), [ipRule]).first, {'action': 'resolve', 'server': 'dns-local'});
        expect(run(withResolve('google'), [ipRule]).first, {'action': 'resolve', 'server': 'dns-remote-doh1-v'}, reason: 'google is unticked');
        expect(run(withResolve('gone'), [ipRule]).first, {'action': 'resolve', 'server': 'dns-remote-doh1-v'});
      });

      test('auto with no server via VPN: plain resolve and a warning', () {
        final w = <String>[];
        final rules = run(withResolve('auto', [{'id': 'local', 'addr': 'system', 'via': 'direct', 'on': true}]), [ipRule], w);
        expect(rules.first, {'action': 'resolve'});
        expect(w.single, contains('no DNS server via VPN'));
      });

      test('TUN-only rules do not force resolve: it goes before the first IP rule that is not', () {
        final rules = run(_defaultDns, [ipRuleFlagged('a', tunOnly: true), domainRule, ipRuleFlagged('b'), ipRuleFlagged('c')]);
        expect(rules.map((r) => r['action']), ['route', 'route', 'resolve', 'route', 'route']);
        expect(rules[0].containsKey('ip_cidr'), isTrue);
        expect(run(_defaultDns, [ipRuleFlagged('a', tunOnly: true), ipRuleFlagged('b', tunOnly: true)]).map((r) => r['action']), ['route', 'route'],
            reason: 'nothing needs a resolve');
      });

      test('geoip rule sets and JSON (composite) rules count as IP conditions; quick rules never resolve', () {
        final composite = {
          ..._rule({}, id: 'rc'),
          'composite': {'type': 'logical', 'mode': 'or', 'rules': [{'ip_cidr': ['1.1.1.1/32']}, {'domain_keyword': ['x']}]},
        };
        expect(run(_defaultDns, [composite]).first, {'action': 'resolve', 'server': 'dns-remote-doh1-v'});
        expect(run(_defaultDns, [{...composite, 'ipTunOnly': true}]).map((r) => r['action']), ['route']);
        final geo = buildConfig(_plan({'dns': _defaultDns, 'rules': [_rule({'ip': _g({'geoip': ['ru']})}, action: 'direct')]}), ruleSetFiles: {'geoip-ru': '/l/ru.srs'});
        expect(_rules(geo).first, {'action': 'resolve', 'server': 'dns-remote-doh1-v'});
        final q = buildConfig(_plan({'dns': _defaultDns, 'quick': {'region': 'RU', 'final': 'proxy'}}), ruleSetFiles: {'geoip-ru': '/l/ru.srs', 'geosite-category-ru': '/l/s.srs', 'geosite-ru-available-only-inside': '/l/s.srs'});
        expect(_rules(q).where((r) => r['action'] == 'resolve' && r.containsKey('server')), isEmpty, reason: 'no step for IP rules');
        expect(_rules(q).where((r) => r['action'] == 'resolve'), hasLength(1), reason: 'only the direct region\'s names are resolved, by the DNS rules');
      });
    });
  });

  group('sing-box', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-routing'));
    tearDown(() async => tmp.delete(recursive: true));

    test('a config with every rule feature passes sing-box check', () async {
      final json = File(p.join(tmp.path, 'set.json'))
        ..writeAsStringSync(jsonEncode({
          'version': 3,
          'rules': [
            {'domain_suffix': ['example.com']},
          ],
        }));
      final srs = p.join(tmp.path, 'set.srs');
      final compiled = await Process.run(_bin, ['rule-set', 'compile', '--output', srs, json.path]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      final ipJson = File(p.join(tmp.path, 'ip.json'))
        ..writeAsStringSync(jsonEncode({
          'version': 3,
          'rules': [
            {'ip_cidr': ['203.0.113.0/24']},
          ],
        }));
      final files = {
        'geosite-youtube': srs,
        'geosite-category-ads-all': srs,
        'geosite-category-ru': srs,
        'geoip-ru': ipJson.path,
        'geosite-telegram': srs,
        'geoip-telegram': ipJson.path,
        'set-blocked': json.path,
      };
      final plan = _plan({
        'fallback': 'main',
        'ruleSets': [{'name': 'blocked', 'url': 'https://example.org/b.json', 'format': 'json', 'via': 'vpn', 'every': 86400}],
        'targets': {
          'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
          'node:a::1': {'kind': 'unit', 'main': _grp([_node2], pick: 'priority', prefix: 'a')},
          'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
        },
        'apps': [
          {'id': 'com.discord', 'kind': 'package', 'act': 'proxy', 'target': 'src:a', 'split': true, 'udp': {'act': 'proxy', 'target': 'chain:c'}},
          {'id': 'chrome.exe', 'kind': 'process', 'act': 'direct'},
          {'id': r'C:\x\y.exe', 'kind': 'path', 'act': 'block'},
          // a target as the fallback; the main flow with a fallback (block / direct / a target)
          {'id': 'fb1.exe', 'kind': 'process', 'act': 'proxy', 'target': 'src:a', 'fallback': 'chain:c'},
          {'id': 'fb2.exe', 'kind': 'process', 'act': 'default', 'fallback': 'block'},
          {'id': 'fb3.exe', 'kind': 'process', 'act': 'default', 'fallback': 'direct'},
          {'id': 'fb4.exe', 'kind': 'process', 'act': 'default', 'fallback': 'node:a::1'},
        ],
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com'], 'geosite': ['youtube'], 'rule_set': ['blocked']}), 'ip': _g({'ip_cidr': ['10.0.0.0/8'], 'geoip': ['ru']}, not: true, flag: true)},
              target: 'src:a', dns: 'google'),
          _rule({'port': _g({'port': ['443', '1000-2000']}), 'network': _g({'network': ['udp'], 'protocol': ['quic']})}, action: 'block', id: 'r2'),
          _rule({'process': _g({'process': ['a.exe', r'C:\b\*.exe']})}, target: 'node:a::1', fallback: 'block', id: 'r3'),
          _rule({'source': _g({'source_ip_cidr': ['192.168.0.0/16'], 'source_port': ['80']})}, action: 'direct', dns: 'google', id: 'r4'),
          _rule({'domain': _g({'domain_regex': [r'^.+\.ru$']})}, target: 'chain:gone', fallback: 'direct', id: 'r5'),
          {
            ..._rule({}, action: 'proxy', target: 'chain:c', id: 'r6'),
            'composite': {
              'type': 'logical',
              'mode': 'or',
              'rules': [
                {'domain_keyword': ['tracker']},
                {'port': [6969]},
              ],
            },
          },
        ],
        'quick': {'lan': true, 'ads': true, 'region': 'RU', 'services': {'telegram': 'vpn', 'youtube': 'direct'}, 'final': 'direct'},
        'dns': _defaultDns,
      });
      final info = RoutingInfo();
      final config = buildConfig(plan, ruleSetFiles: files, tunnelPort: await freePort(), dnsFlagDir: p.join(tmp.path, 'flags'), info: info);
      writeDnsFlags(info.dnsCandidates);
      final f = File(p.join(tmp.path, 'c.json'))..writeAsStringSync(jsonEncode(config));
      final r = await Process.run(_bin, ['check', '-c', f.path, '--disable-color']);
      expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}\n${const JsonEncoder.withIndent(' ').convert(config)}');
      expect('${r.stderr}${r.stdout}', isNot(contains('deprecated')));
    }, skip: _skip);

    test('loopback: a rule\'s DNS server, block, an IP rule after resolve, the main flow', () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // answers after a moment: the connection is still open when the test looks at it
      target.listen((r) => Future<void>.delayed(const Duration(milliseconds: 500), () => r.response
        ..write('ok')
        ..close()));
      final log = <String>[];
      final dnsA = await _fakeDns('A', log), dnsB = await _fakeDns('B', log);
      final mixed = await freePort(), tunnel = await freePort();
      final sb = SingBoxProcess(_bin, p.join(tmp.path, 'run'));
      // the "servers" are direct outbounds: every group is real, nothing needs a proxy
      final plan = {
        'kind': 'unit',
        'main': _grp([{'type': 'direct'}], prefix: 'main'),
        'mixedPort': mixed,
        'routing': {
          'dns': {
            'servers': [
              {'id': 'a', 'addr': 'udp://127.0.0.1:${dnsA.port}', 'via': 'direct', 'on': true},
              {'id': 'b', 'addr': '127.0.0.1:${dnsB.port}', 'via': 'direct', 'on': false},
            ],
          },
          'targets': {
            'src:x': {'kind': 'unit', 'main': _grp([{'type': 'direct'}], prefix: 'x')},
          },
          'rules': [
            _rule({'domain': _g({'domain_suffix': ['viab.test']})}, action: 'direct', dns: 'b'),
            _rule({'domain': _g({'domain_suffix': ['blocked.test']})}, action: 'block', id: 'r2'),
            _rule({'domain': _g({'domain_keyword': ['viaip']}), 'ip': _g({'ip_cidr': ['127.0.0.0/8']})}, target: 'src:x', id: 'r3'),
          ],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      try {
        final info = RoutingInfo();
        final config = buildConfig(plan, tunnelPort: tunnel, dnsFlagDir: p.join(tmp.path, 'flags'), info: info);
        writeDnsFlags(info.dnsCandidates);
        await sb.start(config);
        Future<(String?, List<String>)> get(String host, [int? port]) async {
          final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${port ?? mixed}';
          try {
            final pending = http.getUrl(Uri.parse('http://$host:${target.port}/')).then((q) => q.close());
            pending.ignore();
            // while the target holds the answer: which outbounds the connection went through
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final mine = sb.api!.connections.where((c) => c.hostPort.$1 == host).firstOrNull;
            final res = await pending;
            final body = await res.transform(utf8.decoder).join();
            return (res.statusCode == 200 ? body : null, [...?mine?.chain]);
          } catch (_) {
            return (null, <String>[]);
          } finally {
            http.close(force: true);
          }
        }

        final viaB = await get('x.viab.test');
        expect(viaB.$1, 'ok');
        expect(viaB.$2, ['direct']);
        expect(log, contains('B x.viab.test'));

        expect((await get('x.blocked.test')).$1, isNull);

        final viaIp = await get('viaip.test');
        expect(viaIp.$1, 'ok');
        expect(viaIp.$2.first, 'src:x/x::0');
        expect(log, contains('A viaip.test'), reason: 'resolved before the IP rule, by the DNS list');

        final other = await get('other.test');
        expect(other.$1, 'ok');
        expect(other.$2.last, 'proxy');
        expect(log.where((l) => l.startsWith('B')).every((l) => l.contains('viab.test')), isTrue);

        // tunnel-in (exit check, lists via VPN): the main flow whatever the rules say
        final tunneled = await get('y.viab.test', tunnel);
        expect(tunneled.$1, 'ok');
        expect(tunneled.$2.last, 'proxy');
      } finally {
        await sb.stop();
        dnsA.close();
        dnsB.close();
        await target.close(force: true);
      }
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// A DNS server on loopback that answers every A query with 127.0.0.1 (AAAA: no answer)
/// and logs `name domain`.
Future<RawDatagramSocket> _fakeDns(String name, List<String> log) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((e) {
    final d = e == RawSocketEvent.read ? s.receive() : null;
    if (d == null) return;
    final q = d.data;
    var i = 12;
    final labels = <String>[];
    while (q[i] != 0) {
      labels.add(String.fromCharCodes(q.sublist(i + 1, i + 1 + q[i])));
      i += q[i] + 1;
    }
    final qtype = (q[i + 1] << 8) | q[i + 2];
    if (qtype == 1) log.add('$name ${labels.join('.')}');
    final b = BytesBuilder()
      ..add(q.sublist(0, 2))
      ..add([0x81, 0x80, 0, 1, 0, qtype == 1 ? 1 : 0, 0, 0, 0, 0])
      ..add(q.sublist(12, i + 5));
    if (qtype == 1) b.add([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1]);
    s.send(b.toBytes(), d.address, d.port);
  });
  return s;
}
