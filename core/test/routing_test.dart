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
      expect(_rules(c)[0], {
        'domain': ['exact.example'],
        'domain_suffix': ['corp.local', 'intra.example.com', 'wild.example'],
        'action': 'route',
        'outbound': 'direct',
      });
      expect(_rules(c)[1], {'domain_keyword': ['tracker'], 'port': [443], 'port_range': ['8000:9000'], 'action': 'reject', 'method': 'drop'});
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
      expect(rules[1], {
        'type': 'logical',
        'mode': 'and',
        'rules': [
          {'domain_suffix': ['a.com']},
          {'ip_cidr': ['10.0.0.0/8', '1.1.1.1/32', '1.1.1.2/31', '1.1.1.4/30', '1.1.1.8/31'], 'invert': true},
        ],
        'action': 'route',
        'outbound': 'direct',
      });
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
          {'id': 'com.discord', 'kind': 'package', 'act': 'proxy', 'target': 'src:a', 'split': true, 'udpTarget': 'chain:c'},
        ],
      }));
      final outs = (c['outbounds'] as List).cast<Map>();
      expect(outs.where((o) => o['tag'] == 'src:a'), hasLength(1));
      expect(_out(c, 'src:a')!['type'], 'urltest');
      expect(_out(c, 'src:a')!['outbounds'], ['src:a/a::0', 'src:a/a::1']);
      expect(_out(c, 'chain:c')!['type'], 'selector');
      expect(_out(c, 'chain:c/out::0')!['detour'], 'chain:c>entry');
      expect(_rules(c).take(2), [
        {'package_name': ['com.discord'], 'network': ['tcp'], 'action': 'route', 'outbound': 'src:a'},
        {'package_name': ['com.discord'], 'network': ['udp'], 'action': 'route', 'outbound': 'chain:c'},
      ]);
      expect(_rules(c).map((r) => r['outbound']).skip(2).take(3), ['src:a', 'src:a', 'chain:c']);
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
      expect(rules[3]['outbound'], 'direct');
    });

    test('quick rules and everything else, in order after the own rules', () {
      final c = buildConfig(_plan({
        'rules': [_rule({'domain': _g({'domain_suffix': ['mine.com']})}, action: 'direct')],
        'quick': {'ads': true, 'region': 'RU', 'services': {'telegram': 'vpn', 'youtube': 'direct', 'discord': 'default'}, 'final': 'block'},
        'dns': _defaultDns,
      }), ruleSetFiles: {'geosite-category-ru': '/l/ru.srs', 'geoip-ru': '/l/geoip-ru.srs', 'geosite-telegram': '/l/tg.srs'});
      final rules = _rules(c);
      expect(rules[0]['domain_suffix'], ['mine.com']);
      expect(rules[1], {'domain_suffix': adsDomains, 'action': 'reject'}, reason: 'no ad list on disk: the built-in domains');
      expect(rules[2], {
        'type': 'logical',
        'mode': 'or',
        'rules': [
          {'domain_suffix': services['telegram']!.domains},
          {'rule_set': ['geosite-telegram']},
        ],
        'action': 'route',
        'outbound': 'proxy',
      });
      expect(rules[3]['outbound'], 'direct');
      expect(rules[4]['rules'], [
        {'domain_suffix': ['ru', 'xn--p1ai', 'su']},
        {'rule_set': ['geosite-category-ru']},
        {'rule_set': ['geoip-ru']},
      ]);
      expect(rules[5], {'action': 'reject'}, reason: 'Everything else: Block');
      expect((c['route']['rule_set'] as List).map((s) => s['tag']), unorderedEquals(['geosite-category-ru', 'geoip-ru', 'geosite-telegram']));
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
      expect(rules, hasLength(2));
      expect(rules[0], {'domain_suffix': ['a.com'], 'action': 'route', 'outbound': 'direct'});
      expect(rules[1], {'rule_set': ['geosite-netflix'], 'action': 'route', 'outbound': 'direct'});
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
    test('typed servers from Settings → DNS: via VPN = detour, final = first ticked, direct resolver for server names', () {
      final c = buildConfig(_plan({'dns': _defaultDns}));
      final dns = c['dns'] as Map;
      expect(dns['servers'], [
        {'type': 'https', 'tag': 'dns-remote', 'server': '1.1.1.1', 'detour': 'proxy'},
        {'type': 'local', 'tag': 'dns-local'},
      ]);
      expect(dns['final'], 'dns-remote');
      expect(c['route']['default_domain_resolver'], 'dns-local');
    });

    test('address forms', () {
      expect(dnsServerJson('t', '8.8.8.8:5353'), {'type': 'udp', 'tag': 't', 'server': '8.8.8.8', 'server_port': 5353});
      expect(dnsServerJson('t', 'tls://dns.google'), {'type': 'tls', 'tag': 't', 'server': 'dns.google'});
      expect(dnsServerJson('t', 'https://dns.example:8443/q'), {'type': 'https', 'tag': 't', 'server': 'dns.example', 'server_port': 8443, 'path': '/q'});
      expect(dnsServerJson('t', 'quic://[2606:4700::1111]'), {'type': 'quic', 'tag': 't', 'server': '2606:4700::1111'});
      expect(dnsServerJson('t', 'ftp://x'), isNull);
    });

    test('a rule\'s DNS: Auto by its route, or a named server; direct traffic resolves with it', () {
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
        {'domain_suffix': ['gov.ru'], 'action': 'route', 'server': 'dns-ya'},
      ], reason: 'x.com goes via VPN: the final server already');
      expect((dns['servers'] as List).last, {
        'type': 'https',
        'tag': 'dns-ya',
        'server': 'common.dot.dns.yandex.net',
        'domain_resolver': 'dns-local',
      });
      expect(_rules(c)[0]['outbound'], 'direct');
      expect(_rules(c)[1]['outbound'], 'direct@dns-ya');
      expect(_out(c, 'direct@dns-ya'), {'type': 'direct', 'tag': 'direct@dns-ya', 'domain_resolver': 'dns-ya'});
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
          {'id': 'com.discord', 'kind': 'package', 'act': 'proxy', 'target': 'src:a', 'split': true, 'udpTarget': 'chain:c'},
          {'id': 'chrome.exe', 'kind': 'process', 'act': 'direct'},
          {'id': r'C:\x\y.exe', 'kind': 'path', 'act': 'block'},
        ],
        'rules': [
          _rule({'domain': _g({'domain_suffix': ['a.com'], 'geosite': ['youtube'], 'rule_set': ['blocked']}), 'ip': _g({'ip_cidr': ['10.0.0.0/8'], 'geoip': ['ru']}, not: true, flag: true)},
              target: 'src:a', dns: 'google'),
          _rule({'port': _g({'port': ['443', '1000-2000']}), 'network': _g({'network': ['udp'], 'protocol': ['quic']})}, action: 'block', id: 'r2'),
          _rule({'process': _g({'process': ['a.exe', r'C:\b\*.exe']})}, target: 'node:a::1', id: 'r3'),
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
      final config = buildConfig(plan, ruleSetFiles: files, tunnelPort: await freePort());
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
      final mixed = await freePort(), clash = await freePort(), tunnel = await freePort();
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
        await sb.start(buildConfig(plan, clashPort: clash, tunnelPort: tunnel), clashPort: clash);
        Future<(String?, List<String>)> get(String host, [int? port]) async {
          final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${port ?? mixed}';
          try {
            final pending = http.getUrl(Uri.parse('http://$host:${target.port}/')).then((q) => q.close());
            pending.ignore();
            // while the target holds the answer: which outbounds the connection went through
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final conns = ((await sb.clashGet('/connections'))?['connections'] as List? ?? const []).cast<Map>();
            final mine = conns.where((c) => (c['metadata'] as Map)['host'] == host).firstOrNull;
            final res = await pending;
            final body = await res.transform(utf8.decoder).join();
            return (res.statusCode == 200 ? body : null, [for (final t in (mine?['chains'] as List? ?? const [])) '$t']);
          } catch (_) {
            return (null, <String>[]);
          } finally {
            http.close(force: true);
          }
        }

        final viaB = await get('x.viab.test');
        expect(viaB.$1, 'ok');
        expect(viaB.$2, ['direct@dns-b']);
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
