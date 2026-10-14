// planCheckers (config.dart): the backup check URLs a plan asks for.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('tunCheckRule in buildConfig', () {
    Map<String, dynamic> plan(String mode) => {
          'kind': 'unit',
          'mode': mode,
          'main': {
            'pick': 'priority',
            'chosen': 'k::0',
            'nodes': [
              {'key': 'k::0', 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'}},
            ],
          },
        };
    List<Map> rules(Map<String, dynamic> cfg) => ((cfg['route'] as Map)['rules'] as List).cast<Map>();

    test('TUN with a port: the rule stands right after the tunnel-in rule, before the self rules, with exact fields', () {
      final r = rules(buildConfig(plan('tun'), tunnelPort: 7001, tunCheckPort: 45678, selfPackages: ['dev.jormungand.app']));
      final i = r.indexWhere((x) => x['override_port'] == 45678);
      expect(i, greaterThan(0));
      expect(r[i], {
        'inbound': ['tun-in'],
        'ip_cidr': ['192.0.2.251/32'],
        'port': [44251],
        'network': ['tcp'],
        'action': 'route',
        'outbound': 'direct',
        'override_address': '127.0.0.1',
        'override_port': 45678,
      });
      expect(r[i - 1]['inbound'], ['tunnel-in'], reason: 'right after tunnelRule');
      final self = r.indexWhere((x) => x['package_name'] != null);
      expect(self, greaterThan(i), reason: 'ahead of the self rules');
    });

    test('TUN without a port: no rule', () {
      final r = rules(buildConfig(plan('tun'), tunnelPort: 7001));
      expect(r.where((x) => x['override_port'] != null), isEmpty);
    });

    test('not TUN: no rule even with a port', () {
      final r = rules(buildConfig(plan('proxy'), tunnelPort: 7001, tunCheckPort: 45678));
      expect(r.where((x) => x['override_port'] != null), isEmpty);
    });
  });

  group('node server names: domain_resolver of the system chain (docs/rules.md §6)', () {
    Map<String, dynamic> node(String key, String server, {Map<String, dynamic>? extra}) => {
          'key': key,
          'outbound': {'type': 'vless', 'server': server, 'server_port': 443, 'uuid': 'u', ...?extra},
        };
    Map<String, dynamic> prov(String id, bool on, List<Map<String, String>> transports, {List<String> sides = const ['direct']}) =>
        {'id': id, 'on': on, 'sides': sides, 'use': ['doh', 'udp', 'system'], 'transports': transports};
    // the user's own DNS is first in the list, then the built-in ones; Local is on
    final dns = {
      'servers': [
        prov('mine', true, [{'kind': 'doh', 'addr': 'https://dns.mine.test/dns-query'}]),
        prov('google', true, [{'kind': 'doh', 'addr': 'https://8.8.8.8/dns-query'}, {'kind': 'udp', 'addr': '8.8.8.8'}]),
        prov('cloudflare', true, [{'kind': 'udp', 'addr': '1.1.1.1'}]),
        prov('local', true, [{'kind': 'system', 'addr': 'system'}]),
      ],
    };
    Map<String, dynamic> plan() => {
          'kind': 'chain',
          'entry': {'pick': 'fastest', 'nodes': [node('e', 'entry.example')]},
          'main': {
            'pick': 'priority',
            'chosen': 'k::0',
            'nodes': [node('k::0', 'exit.example')],
          },
          'routing': {'dns': dns},
        };
    Map<String, dynamic> cfg({Map<String, String> pins = const {}, bool Function(DnsCandidate)? usable}) =>
        buildConfig(plan(), pins: pins, nodeResolverUsable: usable);
    Map? out(Map<String, dynamic> c, String tag) => (c['outbounds'] as List).cast<Map>().where((o) => o['tag'] == tag).firstOrNull;
    final builtin = {'google', 'cloudflare', 'local'};

    test('an unpinned node name gets the first enabled built-in server (encrypted first), never the user\'s own DNS', () {
      final c = cfg(usable: (x) => builtin.contains(x.provider));
      expect(out(c, 'route0-entry/e')!['domain_resolver'], 'dns-google-doh1');
      expect(out(c, 'route0-entry/e')!['server'], 'entry.example');
      // the exit dials through its entry: nothing to resolve there
      expect(out(c, 'route0/k::0')!.containsKey('domain_resolver'), isFalse);
      // selectors and direct are not servers
      expect((c['outbounds'] as List).cast<Map>().where((o) => const {'selector', 'urltest', 'direct'}.contains(o['type'])).any((o) => o.containsKey('domain_resolver')), isFalse);
      // the route's default is the user's chain, untouched
      expect((c['route'] as Map)['default_domain_resolver'], 'dns-mine-doh1');
    });

    test('a pinned name (an IP in the config) has no resolver; a dead verdict moves to the next; all dead: Local', () {
      final c = cfg(pins: {'entry.example': '203.0.113.1'}, usable: (x) => builtin.contains(x.provider));
      expect(out(c, 'route0-entry/e')!['server'], '203.0.113.1');
      expect(out(c, 'route0-entry/e')!.containsKey('domain_resolver'), isFalse);

      final dead = {'dns-google-doh1', 'dns-google-udp1'};
      expect(out(cfg(usable: (x) => builtin.contains(x.provider) && !dead.contains(x.tag)), 'route0-entry/e')!['domain_resolver'], 'dns-cloudflare-udp1');
      expect(out(cfg(usable: (x) => false), 'route0-entry/e')!['domain_resolver'], 'dns-local', reason: 'the OS resolver only when nothing else is left');
    });

    test('the chosen node resolver is reported in RoutingInfo (for blaming a dead name resolution), not the route default', () {
      final info = RoutingInfo();
      buildConfig(plan(), info: info, nodeResolverUsable: (x) => builtin.contains(x.provider));
      expect(info.nodeResolver, 'dns-google-doh1');
      expect(info.domainResolver, 'dns-mine-doh1');
      final none = RoutingInfo();
      buildConfig(plan(), info: none);
      expect(none.nodeResolver, isNull);
    });

    test('a detoured exit gets no domain_resolver: the entry resolves its name on the far side (measured: with one sing-box would look it up here)', () {
      final c = cfg(usable: (x) => builtin.contains(x.provider));
      final exit = out(c, 'route0/k::0')!;
      expect(exit['detour'], 'route0-entry');
      expect(exit['server'], 'exit.example');
      expect(exit.containsKey('domain_resolver'), isFalse);
      // no outbound with a detour carries one, whatever the plan
      expect((c['outbounds'] as List).cast<Map>().where((o) => o['detour'] != null).any((o) => o.containsKey('domain_resolver')), isFalse);
    });

    test('RoutingInfo.nameRoutes: the entry named by a host counts, the exit and a pinned entry do not', () {
      Set<String> names({Map<String, String> pins = const {}, Map<String, dynamic>? pl}) {
        final info = RoutingInfo();
        buildConfig(pl ?? plan(), info: info, pins: pins, nodeResolverUsable: (x) => builtin.contains(x.provider));
        return info.nameRoutes;
      }

      expect(names(), {'route0'}, reason: 'the entry is looked up by sing-box');
      expect(names(pins: {'entry.example': '203.0.113.1'}), isEmpty, reason: 'pinned: nothing left to resolve; the exit is the entry\'s');
      final onlyExit = plan();
      ((onlyExit['entry'] as Map)['nodes'] as List)[0] = node('e', '203.0.113.9');
      expect(names(pl: onlyExit), isEmpty, reason: 'an address entry, a host exit: not resolved here');
      // a single route: its nodes are dialed directly
      final single = {
        'kind': 'unit',
        'main': {'pick': 'priority', 'chosen': 'k::0', 'nodes': [node('k::0', 'one.example')]},
        'routing': {'dns': dns},
      };
      expect(names(pl: single), {'route0'});
      expect(names(pins: {'one.example': '203.0.113.2'}, pl: single), isEmpty);
    });

    test('loopback sing-box check accepts the chain config (entry + detoured exit, both named by a host)', () async {
      final bin = File(p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box'));
      if (!bin.existsSync()) return markTestSkipped('no sing-box in tool/bin');
      final dir = Directory(p.join('.data-dev', 'node-resolver-check'))..createSync(recursive: true);
      try {
        final info = RoutingInfo();
        final config = buildConfig(plan(), info: info, dnsFlagDir: p.join(dir.path, 'flags'), nodeResolverUsable: (x) => builtin.contains(x.provider));
        writeDnsFlags(info.dnsCandidates);
        final f = File(p.join(dir.path, 'chain.json'))..writeAsStringSync(jsonEncode(config));
        final r = await Process.run(bin.path, ['check', '-c', f.path, '--disable-color']);
        expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('without the seam the config is as before: no domain_resolver on any node', () {
      final c = cfg();
      expect((c['outbounds'] as List).cast<Map>().any((o) => o.containsKey('domain_resolver')), isFalse);
    });
  });

  group('planCheckers', () {
    test('missing everywhere: defaultCheckers', () {
      expect(planCheckers({}), defaultCheckers);
    });

    test('auto.checkers []: none, even if urlTest.checkers has some', () {
      expect(planCheckers({
        'auto': {'checkers': []},
        'urlTest': {
          'checkers': ['https://a.example/'],
        },
      }), isEmpty);
    });

    test('auto.checkers wins over urlTest.checkers when both are set', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/'],
            },
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://a.example/']);
    });

    test('no auto.checkers: falls back to urlTest.checkers', () {
      expect(
          planCheckers({
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://b.example/']);
    });

    test('urlTest.checkers []: none', () {
      expect(
          planCheckers({
            'urlTest': {'checkers': []},
          }),
          isEmpty);
    });

    test('non-string and empty entries are dropped, from either key', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/', 42, '', null, 'https://b.example/'],
            },
          }),
          ['https://a.example/', 'https://b.example/']);
    });

    test('auto.checkers present but not a list: defaultCheckers (?? does not fall through to urlTest)', () {
      expect(
          planCheckers({
            'auto': {'checkers': 'oops'},
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          defaultCheckers);
    });
  });

  test('AutoSettings.fromPlan reads checkers via planCheckers', () {
    final a = AutoSettings.fromPlan({
      'auto': {
        'checkers': ['https://a.example/'],
      },
    });
    expect(a.checkers, ['https://a.example/']);

    final b = AutoSettings.fromPlan({});
    expect(b.checkers, defaultCheckers);
  });
}
