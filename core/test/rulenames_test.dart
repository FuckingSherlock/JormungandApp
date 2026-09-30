// Live connections name the rule a connection went by (rulenames.dart, traffic.dart): the
// text of each generated route rule → its origin (unit), and that text checked against what a
// real sing-box reports for connections (loopback only, skipped without the binary).
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

final _node = parseLink(ssSip002)!.outbound;
final _node2 = parseLink(trojanGrpc)!.outbound;

Map<String, dynamic> _grp(List<Map> outbounds, {String pick = 'fastest', String prefix = 's'}) => {
      'pick': pick,
      'chosen': pick == 'priority' ? '$prefix::0' : null,
      'nodes': [for (var i = 0; i < outbounds.length; i++) {'key': '$prefix::$i', 'outbound': outbounds[i]}],
    };

Map<String, dynamic> _rule(String id, String name, Map<String, dynamic> groups, {String action = 'proxy', String target = '', String fallback = 'default'}) => {
      'id': id,
      'name': name,
      'action': action,
      'target': target,
      'fallback': fallback,
      'block': 'drop',
      'dns': 'auto',
      'groups': groups,
    };

Map<String, dynamic> _g(Map<String, List<String>> v, {bool not = false}) => {'not': not, 'v': v};

RuleNames _names(Map<String, dynamic> routing, {int? tunnelPort, Probe? probe}) {
  final info = RoutingInfo();
  buildConfig({
    'kind': 'unit',
    'main': _grp([_node]),
    'routing': routing,
  }, tunnelPort: tunnelPort, probe: probe, info: info);
  return info.ruleNames;
}

void main() {
  group('ruleText', () {
    test('sing-box\'s wording: item order, one value bare, more in brackets, long lists cut', () {
      expect(ruleText({'domain_suffix': ['a.com'], 'action': 'route', 'outbound': 'x'}), 'domain_suffix=a.com');
      expect(ruleText({'port': [443], 'network': ['tcp'], 'domain_suffix': ['a.com', 'b.com']}), 'network=tcp domain_suffix=[a.com b.com] port=443');
      expect(ruleText({'domain_suffix': ['1', '2', '3', '4'], 'domain': ['x.com'], 'domain_keyword': ['a', 'b', 'c', 'd'], 'domain_regex': ['a', 'b', 'c', 'd']}),
          'domain=x.com domain_suffix=[1 2 3...] domain_keyword=[a b c...] domain_regex=[a b c]');
      expect(ruleText({'ip_cidr': ['1.0.0.0/8', '2.0.0.0/8', '3.0.0.0/8', '4.0.0.0/8'], 'ip_is_private': true}), 'ip_cidr=[1.0.0.0/8 2.0.0.0/8 3.0.0.0/8...] ip_is_private=true');
      expect(ruleText({'rule_set': ['geosite-a', 'set-b'], 'port_range': ['1:2'], 'source_port': [5]}), 'source_port=5 port_range=1:2 rule_set=[geosite-a set-b]');
      expect(ruleText({'action': 'sniff'}), '');
    });

    test('logical and inverted rules; a condition it does not know = no text', () {
      expect(
          ruleText({
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'domain_suffix': ['a.com']},
              {'rule_set': ['geoip-ru']},
            ],
            'action': 'route',
            'outbound': 'direct',
          }),
          'domain_suffix=a.com || rule_set=geoip-ru');
      expect(ruleText({'type': 'logical', 'mode': 'and', 'rules': [{'port': [1]}, {'network': ['udp']}], 'invert': true}), '!(port=1 && network=udp)');
      expect(ruleText({'port': [1], 'invert': true}), '!(port=1)');
      expect(ruleText({'domain_suffix': ['a.com'], 'ip_version': 4}), isNull);
      expect(ruleText({'type': 'logical', 'mode': 'xor', 'rules': const []}), isNull);
    });
  });

  group('RuleNames', () {
    final routing = {
      'fallback': 'main',
      'targets': {
        'src:a': {'kind': 'unit', 'main': _grp([_node, _node2], prefix: 'a')},
        'chain:c': {'kind': 'chain', 'entry': _grp([_node], prefix: 'in'), 'main': _grp([_node2], pick: 'priority', prefix: 'out')},
      },
      'apps': [
        {'id': 'com.discord', 'kind': 'package', 'name': 'Discord app', 'act': 'proxy', 'target': 'src:a', 'split': true, 'udp': {'act': 'proxy', 'target': 'chain:c', 'fallback': 'block'}},
        {'id': 'chrome.exe', 'kind': 'process', 'name': 'Chrome', 'act': 'direct'},
        {'id': r'C:\x\y.exe', 'kind': 'path', 'act': 'block'},
        {'id': 'skip.exe', 'kind': 'process', 'act': 'default'},
      ],
      'rules': [
        // a target with "If unavailable": the rule's conditions are what name it
        _rule('r1', 'Work sites', {'domain': _g({'domain_suffix': ['corp.example', 'corp.test']})}, target: 'src:a', fallback: 'direct'),
        _rule('r2', '', {'port': _g({'port': ['6881']}), 'network': _g({'network': ['udp']})}, action: 'block'),
        _rule('r3', 'Chain rule', {'domain': _g({'domain_keyword': ['tracker']})}, target: 'chain:c', fallback: 'block'),
        _rule('r4', 'Same again', {'domain': _g({'domain_keyword': ['tracker']})}, action: 'direct'),
        _rule('r5', 'Long one', {'domain': _g({'domain_suffix': ['a.com', 'b.com', 'c.com', 'd.com']})}),
        _rule('r6', 'Long two', {'domain': _g({'domain_suffix': ['a.com', 'b.com', 'c.com', 'e.com']})}),
        {
          ..._rule('r7', 'JSON rule', {}),
          'composite': {
            'type': 'logical',
            'mode': 'or',
            'rules': [
              {'domain_keyword': ['json']},
              {'port': [6969]},
            ],
          },
        },
      ],
      'quick': {'ads': true, 'region': 'RU', 'services': {'telegram': 'vpn', 'youtube': 'direct'}, 'final': 'block'},
    };

    void named(RuleNames n, String text, String kind, String name, String id) {
      final o = n.of(text);
      expect(o, isNotNull, reason: text);
      expect((o!.kind, o.name, o.id), (kind, name, id), reason: text);
    }

    test('every kind of generated rule finds its name', () {
      final n = _names(routing, tunnelPort: 1234, probe: Probe(4321));
      // the core's own
      named(n, 'domain_suffix=[local localhost lan...] ip_is_private=true', 'system', 'Private networks', 'private');
      named(n, 'inbound=tunnel-in', 'system', 'Core checks', 'tunnel');
      named(n, 'inbound=probe-in auth_user=route0/s::0', 'system', 'Latency check', 'probe');
      // apps: a whole app, the two halves of a split one (its own name, else its id)
      named(n, 'network=tcp package_name=com.discord', 'app', 'Discord app (TCP)', 'com.discord');
      named(n, 'network=udp package_name=com.discord', 'app', 'Discord app (UDP)', 'com.discord');
      named(n, 'process_name=chrome.exe', 'app', 'Chrome', 'chrome.exe');
      named(n, r'process_path=C:\x\y.exe', 'app', r'C:\x\y.exe', r'C:\x\y.exe');
      expect(n.of('process_name=skip.exe'), isNull, reason: 'a default app has no rule');
      // own rules, whatever their target and fallback
      named(n, 'domain_suffix=[corp.example corp.test]', 'user', 'Work sites', 'r1');
      named(n, 'network=udp port=6881', 'user', 'rule r2', 'r2');
      named(n, 'domain_keyword=json || port=6969', 'user', 'JSON rule', 'r7');
      // the same conditions twice: the first one is what sing-box uses
      named(n, 'domain_keyword=tracker', 'user', 'Chain rule', 'r3');
      // quick rules and services
      named(n, 'domain_suffix=[doubleclick.net googlesyndication.com googleadservices.com...]', 'quick', 'Block ads', 'ads');
      named(n, 'domain_suffix=[telegram.org t.me telegram.me...]', 'service', 'Telegram', 'telegram');
      named(n, 'domain_suffix=[youtube.com googlevideo.com ytimg.com...]', 'service', 'YouTube', 'youtube');
      named(n, 'domain_suffix=[ru xn--p1ai su]', 'quick', 'My region direct', 'region');
    });

    test('a text two different rules share (long lists cut alike) names nothing; unknown text too', () {
      final n = _names(routing);
      expect(n.of('domain_suffix=[a.com b.com c.com...]'), isNull);
      expect(n.of('domain_suffix=nothing.example'), isNull);
      expect(n.of(''), isNull);
    });

    test('Global keeps the private-networks rule only', () {
      final info = RoutingInfo();
      buildConfig({'kind': 'unit', 'main': _grp([_node]), 'global': true, 'routing': routing}, info: info);
      expect(info.ruleNames.of('domain_suffix=[local localhost lan...] ip_is_private=true')?.name, 'Private networks');
      expect(info.ruleNames.of('process_name=chrome.exe'), isNull);
    });
  });

  group('sing-box', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-rulenames'));
    tearDown(() async => tmp.delete(recursive: true));

    test('ruleText equals what sing-box reports for the connection each rule caught', () async {
      final set = File(p.join(tmp.path, 'x.json'))
        ..writeAsStringSync(jsonEncode({
          'version': 3,
          'rules': [
            {'domain_suffix': ['localhost']},
          ],
        }));
      final srs = p.join(tmp.path, 'x.srs');
      final compiled = await Process.run(_bin, ['rule-set', 'compile', '--output', srs, set.path]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');

      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((r) => Future<void>.delayed(const Duration(milliseconds: 2500), () => r.response
        ..write('ok')
        ..close()));
      final port = target.port;
      final me = p.basename(Platform.resolvedExecutable);
      // one inbound per rule: the rule names its inbound, the rest of its conditions is what is checked
      final cases = <(Map<String, dynamic>, String)>[
        ({'network': ['tcp'], 'ip_cidr': ['10.0.0.0/8', '127.0.0.0/8', '1.1.1.0/24', '2.2.2.0/24', '3.3.3.0/24'], 'ip_is_private': true, 'port': [port]}, '127.0.0.1'),
        ({'domain': ['localhost'], 'domain_suffix': ['a.test', 'b.test', 'c.test', 'd.test'], 'domain_keyword': ['loc', 'xyz'], 'domain_regex': ['^x', '^y', '^z', '^localhost\$']}, 'localhost'),
        ({'type': 'logical', 'mode': 'and', 'rules': [{'inbound': ['in2']}, {'port': [port]}, {'network': ['tcp']}]}, '127.0.0.1'),
        ({'process_name': [me, 'dart.exe', 'dartvm.exe', 'dart'], 'process_path_regex': ['.*', 'a', 'b', 'c'], 'source_port_range': ['1:65535'], 'port_range': ['$port:$port']}, '127.0.0.1'),
        ({'rule_set': ['set-x']}, 'localhost'),
        ({'source_ip_cidr': ['127.0.0.0/8'], 'source_ip_is_private': true}, '127.0.0.1'),
        ({'inbound': ['in6'], 'port': [1, 2], 'invert': true}, '127.0.0.1'), // last: it catches every other inbound too
      ];
      final ports = [for (final _ in cases) await freePort()];
      final rules = <Map<String, dynamic>>[
        {'action': 'sniff'},
        for (var i = 0; i < cases.length; i++)
          cases[i].$1['type'] == 'logical'
              ? {...cases[i].$1, 'action': 'route', 'outbound': 'direct'}
              : {'inbound': ['in$i'], ...cases[i].$1, 'action': 'route', 'outbound': 'direct'},
      ];
      final sb = SingBoxProcess(_bin, p.join(tmp.path, 'run'));
      try {
        await sb.start({
          'log': {'level': 'warn'},
          'dns': {
            'servers': [
              {'type': 'local', 'tag': 'local'},
            ],
          },
          'inbounds': [
            for (var i = 0; i < cases.length; i++) {'type': 'mixed', 'tag': 'in$i', 'listen': '127.0.0.1', 'listen_port': ports[i]},
          ],
          'outbounds': [
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {
            'rules': rules,
            'rule_set': [
              {'type': 'local', 'tag': 'set-x', 'format': 'binary', 'path': srs},
            ],
            'final': 'direct',
            'default_domain_resolver': 'local',
            'find_process': true,
          },
        });
        final clients = <HttpClient>[];
        for (var i = 0; i < cases.length; i++) {
          final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${ports[i]}';
          clients.add(http);
          http.getUrl(Uri.parse('http://${cases[i].$2}:$port/')).then((q) => q.close()).then((r) => r.drain<void>()).ignore();
        }
        final byInbound = <String, String>{};
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        while (byInbound.length < cases.length && DateTime.now().isBefore(deadline)) {
          for (final c in sb.api!.connections) {
            byInbound[c.c.inbound] = c.rule;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        for (var i = 0; i < cases.length; i++) {
          expect(byInbound['in$i'], ruleText(rules[i + 1]), reason: 'rule $i: ${cases[i].$1}');
        }
        for (final c in clients) {
          c.close(force: true);
        }
      } finally {
        await sb.stop();
        await target.close(force: true);
      }
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 40)));

    test('trafficOf names the rule of an open connection: private networks, the core\'s tunnel', () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((r) => Future<void>.delayed(const Duration(milliseconds: 2500), () => r.response
        ..write('ok')
        ..close()));
      final mixed = await freePort(), tunnel = await freePort();
      final sb = SingBoxProcess(_bin, p.join(tmp.path, 'run'));
      final info = RoutingInfo();
      final plan = {
        'kind': 'unit',
        'main': _grp([{'type': 'direct'}], prefix: 'main'),
        'mixedPort': mixed,
        'routing': {
          'rules': [
            _rule('r1', 'Loopback', {'ip': _g({'ip_cidr': ['127.0.0.0/8']})}, action: 'direct'),
          ],
          'quick': {'final': 'proxy'},
        },
      };
      try {
        await sb.start(buildConfig(plan, tunnelPort: tunnel, info: info));
        final clients = [for (final port in [mixed, tunnel]) HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port'];
        for (final http in clients) {
          http.getUrl(Uri.parse('http://127.0.0.1:${target.port}/')).then((q) => q.close()).then((r) => r.drain<void>()).ignore();
        }
        List<Map> mine() => (trafficOf(sb.api!, names: info.ruleNames)['conns'] as List).cast<Map>().where((c) => c['port'] == '${target.port}').toList();
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        while (mine().length < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final conns = mine();
        expect(conns, hasLength(2));
        final kinds = {for (final c in conns) c['ruleKind'] as String: c};
        expect(kinds.keys, unorderedEquals(['system']));
        expect(conns.map((c) => c['ruleName']), unorderedEquals(['Private networks', 'Core checks']));
        expect(conns.map((c) => c['ruleId']), unorderedEquals(['private', 'tunnel']));
        expect(conns.every((c) => (c['rule'] as String).isNotEmpty), isTrue, reason: 'the raw text stays');
        // no names known: the raw text only
        final bare = (trafficOf(sb.api!)['conns'] as List).cast<Map>().first;
        expect(bare['ruleKind'], '');
        expect(bare['ruleName'], '');
        expect(bare.containsKey('ruleId'), isFalse);
        for (final c in clients) {
          c.close(force: true);
        }
      } finally {
        await sb.stop();
        await target.close(force: true);
      }
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 40)));
  });
}
