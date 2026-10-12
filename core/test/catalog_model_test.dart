// The Dart catalog on small hand-made states: snapshot round trip (unknown keys), pings, who Auto
// picks, the plan signature, validation, delete impact, rules / apps. The big comparison with the
// mockup's JS is catalog_golden_test.dart; this file covers what a snapshot cannot hold (a ping in
// flight) and the contracts the golden files do not (strict round trip, error codes).
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const t0 = 1760000000000;
int clock = t0;

Map<String, dynamic> node(String id, {String? name, Map<String, dynamic>? extra, bool outbound = true}) => {
      'id': id,
      'name': name ?? 'Server $id',
      'flag': '🇩🇪',
      'protocol': 'vless',
      'address': '$id.example',
      'port': 443,
      if (outbound) 'outbound': {'o': id},
      ...?extra,
    };

Map<String, dynamic> source(String id, List<String> ids, {Map<String, dynamic>? extra}) => {
      'id': id,
      'kind': 'sub',
      'name': 'Source $id',
      'enabled': true,
      'inAuto': true,
      'offNodes': <String>[],
      'disabledNodes': <String>[],
      'gone': <dynamic>[],
      'nodes': [for (final n in ids) node('$id$n')],
      ...?extra,
    };

/// Two sources (a: a1 a2 a3, b: b1 b2), a profile over both, a chain b -> a.
Map<String, dynamic> snap({Map<String, dynamic>? over}) => {
      'sourcesData': {'a': source('a', ['1', '2', '3']), 'b': source('b', ['1', '2'])},
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
      'rulesData': <String, dynamic>{},
      'ruleOrder': <String>[],
      'ruleSeq': 1,
      'quickCfg': <String, dynamic>{},
      'appRules': <String, dynamic>{},
      'pings': <dynamic>[],
      ...?over,
    };

Catalog make([Map<String, dynamic>? s]) => Catalog.fromJson(jsonDecode(jsonEncode(s ?? snap())) as Map<String, dynamic>, now: () => clock);

CatalogNode nodeOf(Catalog c, String key) => c.nodeOfKey(key)!;
void ping(Catalog c, String key, num ms, {int? fails, int age = 1000}) =>
    c.pings.put(nodeOf(c, key), PingEntry(ms: ms, at: clock - age, fails: fails ?? (ms < 0 ? 1 : 0)));

/// Every key / value of [want] is in [got] (deep): what a round trip must not lose.
void expectContains(Object? want, Object? got, [String path = '']) {
  if (want is Map) {
    expect(got, isA<Map>(), reason: path);
    for (final e in want.entries) {
      expect((got as Map).containsKey(e.key), isTrue, reason: 'lost $path/${e.key}');
      expectContains(e.value, got[e.key], '$path/${e.key}');
    }
  } else if (want is List) {
    expect(got, isA<List>(), reason: path);
    expect((got as List).length, want.length, reason: path);
    for (var i = 0; i < want.length; i++) {
      expectContains(want[i], got[i], '$path[$i]');
    }
  } else {
    expect(got, want, reason: path);
  }
}

void main() {
  setUp(() => clock = t0);

  group('snapshot round trip', () {
    test('unknown keys survive at every level, known ones keep their values', () {
      final s = snap(over: {
        'futureKey': {'x': [1, 2, 3]},
        'genCfg': {'lang': 'ru', 'nodeSort': 'name'},
        'notifCfg': {'status': true},
        'logCfg': {'showOwn': false},
        'sourcesData': {
          'a': source('a', ['1', '2'], extra: {'userAgent': 'mihomo', 'usage': {'used': 1.5, 'total': 0}, 'expire': null, 'hwid': false, 'pickMode': 'priority', 'pickOrder': ['a:a2']}),
          'b': source('b', ['1'], extra: {'gone': [node('b9', extra: {'goneAt': t0 - 86400000, 'reality': true})]}),
        },
        'profilesData': {
          'p': {'id': 'p', 'name': 'All', 'sources': ['a'], 'nodes': ['b::b1'], 'inAuto': false, 'color': 'red', 'pickMode': 'priority', 'pickOrder': ['b::b1']},
        },
        'chainsData': {
          'c1': {'id': 'c1', 'name': 'x', 'inId': 'b', 'outId': 'a', 'inAuto': false, 'exitMode': 'priority', 'exitOrder': ['a::a1'], 'inOff': ['b::b1'], 'outOff': <String>[], 'note': 'n'},
        },
        'modeState': {
          'profiles': {'order': ['p'], 'active': 'p', 'auto': false, 'pin': 'b::b1', 'extra': 1},
        },
        'connCfg': {'port': 7000, 'proxyAuth': true, 'proxyUser': 'u', 'proxyPass': 'p', 'newSetting': 'z', 'checkers': ['https://c.example'], 'ipv6': true},
        'autoCfg': {'failAfter': 3, 'retryPause': 0.25, 'newTune': true},
        'quickCfg': {'region': 'BY', 'services': {'telegram': 'vpn', 'custom': 'direct'}, 'more': [1]},
        'rulesData': {
          'r1': {'id': 'r1', 'name': 'R', 'enabled': true, 'action': 'proxy', 'target': 'src:a', 'groups': {'domain': {'not': false, 'v': {'domain': ['a.com']}}}, 'future': 7},
        },
        'ruleOrder': ['r1'],
        'appRules': {
          'org.x': {'act': 'proxy', 'target': '', 'fallback': 'default', 'fallbackTarget': '', 'split': false, 'udp': {'act': 'default', 'target': '', 'fallback': 'default', 'fallbackTarget': '', 'half': 1}, 'appExtra': 2},
        },
        'ruleSets': [
          {'id': 'geosite', 'name': 'geosite', 'builtin': true, 'url': 'built-in', 'format': 'srs', 'via': 'vpn', 'every': 604800, 'updated': '2 d ago'},
        ],
        'dnsServers': {
          'cloudflare': {
            'id': 'cloudflare',
            'name': 'Cloudflare',
            'on': true,
            'sides': ['direct', 'vpn'],
            'use': ['doh', 'dot'],
            'tag': 't',
          },
          'own': {
            'id': 'own',
            'name': 'Own',
            'on': false,
            'sides': ['vpn'],
            'use': ['doh', 'dot'],
            'transports': [
              {'kind': 'doh', 'addr': 'https://9.9.9.9/dns-query', 'tt': 1},
              {'kind': 'dot', 'addr': 'tls://9.9.9.9'},
            ],
            'tag': 'o',
          },
        },
        'dnsOrder': ['cloudflare', 'own'],
        'dnsCfg': {'resolve': 'cloudflare', 'hijack': false, 'directPolicy': 'priority', 'listVersion': 2, 'extra': 1},
        'pings': [
          ['vless://a1.example:443#a1', {'ms': 41, 'at': t0 - 5, 'fails': 0}],
        ],
      });
      final c = make(s);
      final out = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
      expectContains(s, out);
      // and again: nothing grows or changes on a second pass
      expect(jsonEncode(make(out).toJson()), jsonEncode(c.toJson()));
    });

    test('a first run (null) has the defaults of a fresh install', () {
      final c = Catalog.fromJson(null, now: () => clock);
      expect(c.sourcesData, isEmpty);
      expect(c.connectMode, 'simple');
      expect(c.autoConnect, isTrue);
      expect(c.ruleSets.map((r) => r.id), ['geosite', 'geoip']);
      expect(c.ruleSets.every((r) => r.builtin && r.every == 604800), isTrue);
      expect(c.dnsOrder, ['cloudflare', 'google', 'adguard', 'local']);
      expect(c.dnsServers.values.every((s) => s.on), isTrue);
      expect(c.dnsServers['local']!.system, isTrue);
      expect(c.dnsServers['local']!.activeSides, {'direct'});
      expect(c.dnsServers['cloudflare']!.activeSides, {'direct', 'vpn'});
      expect(c.dnsServers['cloudflare']!.use, {'doh', 'dot'});
      expect(c.dnsServers['adguard']!.transports.map((t) => t.kind).toSet(), {'doh', 'dot', 'doq', 'udp'});
      expect(c.dnsCfg.directPolicy, 'localFirst');
      expect(c.dnsCfg.listVersion, 2);
      expect(c.dnsCfg.hijack, isTrue);
      expect(c.quickCfg.services.keys, containsAll(['telegram', 'x']));
      expect(c.quickCfg.services.values.toSet(), {'default'});
      final out = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
      expect(jsonEncode(make(out).toJson()), jsonEncode(c.toJson()));
    });

    test('JS truthiness: absent enabled / inAuto read as off, autoConnect only false turns Auto off', () {
      final s = snap();
      (s['sourcesData'] as Map)['a'] = {'id': 'a', 'name': 'A', 'nodes': [node('a1')]};
      s['autoConnect'] = 0; // not `false`: Auto stays on
      final c = make(s);
      expect(c.sourcesData['a']!.enabled, isFalse);
      expect(c.sourcesData['a']!.inAuto, isFalse);
      expect(c.autoConnect, isTrue);
      expect(c.entryVisible('a'), isFalse); // a switched-off source's own entry is hidden
    });

    test('the spinner of a page closed mid-update is not loaded', () {
      final s = snap();
      ((s['sourcesData'] as Map)['a'] as Map)['updating'] = true;
      expect((make(s).toJson()['sourcesData'] as Map)['a'], isNot(contains('updating')));
    });
  });

  group('dns list', () {
    Map<String, dynamic> oldList() => snap(over: {
          'dnsServers': {
            'remote': {'id': 'remote', 'name': 'Cloudflare', 'addr': 'https://1.1.1.1/dns-query', 'via': 'vpn', 'on': true},
            'local': {'id': 'local', 'name': 'Local', 'addr': 'system', 'via': 'direct', 'on': true},
            'google': {'id': 'google', 'name': 'Google', 'addr': 'tls://dns.google', 'via': 'vpn', 'on': false},
            'ya': {'id': 'ya', 'name': 'Yandex', 'addr': 'https://common.dot.dns.yandex.net/dns-query', 'via': 'direct', 'on': true, 'tag': 't'},
            'mine': {'id': 'mine', 'name': 'Mine', 'addr': '9.9.9.9', 'via': 'vpn', 'on': false},
          },
          'dnsOrder': ['ya', 'remote', 'local', 'google', 'mine'],
          'dnsCfg': {'resolve': 'remote', 'hijack': true},
          'rulesData': {
            'r1': {'id': 'r1', 'name': 'R', 'enabled': true, 'action': 'direct', 'dns': 'remote', 'groups': {'domain': {'not': false, 'v': {'domain': ['a.com']}}}},
            'r2': {'id': 'r2', 'name': 'R2', 'enabled': true, 'action': 'direct', 'dns': 'ya', 'groups': {'domain': {'not': false, 'v': {'domain': ['b.com']}}}},
          },
          'ruleOrder': ['r1', 'r2'],
        });

    test('the old list is migrated once: the built-ins are replaced by the new defaults, the user\'s own servers follow, converted', () {
      final c = make(oldList());
      expect(c.dnsOrder, ['cloudflare', 'google', 'adguard', 'local', 'ya', 'mine']);
      expect(c.dnsServers['google']!.on, isTrue, reason: 'the defaults replace the old google (which was off)');
      final ya = c.dnsServers['ya']!;
      expect(ya.name, 'Yandex');
      expect([for (final t in ya.transports) '${t.kind} ${t.addr}'], ['doh https://common.dot.dns.yandex.net/dns-query']);
      expect(ya.use, {'doh'});
      expect(ya.activeSides, {'direct'});
      expect(ya.unknown['tag'], 't', reason: 'unknown fields travel');
      final mine = c.dnsServers['mine']!;
      expect(mine.on, isFalse);
      expect([for (final t in mine.transports) t.kind], ['udp']);
      expect(mine.activeSides, {'vpn'});
      // what referred to the old ids follows
      expect(c.dnsCfg.resolve, 'cloudflare');
      expect(c.rulesData['r1']!.dns, 'cloudflare');
      expect(c.rulesData['r2']!.dns, 'ya');
      expect(c.dnsCfg.listVersion, 2);
    });

    test('a later load leaves the list as it is: the user\'s edits stay, nothing is added back', () {
      final first = make(oldList());
      final out = jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>;
      expect(jsonEncode(make(out).toJson()), jsonEncode(first.toJson()), reason: 'a second load changes nothing');
      // the user removes AdGuard, switches Cloudflare off, reorders
      (out['dnsServers'] as Map).remove('adguard');
      ((out['dnsServers'] as Map)['cloudflare'] as Map)['on'] = false;
      out['dnsOrder'] = ['local', 'cloudflare', 'ya', 'google', 'mine'];
      final again = make(out);
      expect(again.dnsOrder, ['local', 'cloudflare', 'ya', 'google', 'mine']);
      expect(again.dnsServers.containsKey('adguard'), isFalse);
      expect(again.dnsServers['cloudflare']!.on, isFalse);
      expect(jsonEncode(make(jsonDecode(jsonEncode(again.toJson())) as Map<String, dynamic>).toJson()), jsonEncode(again.toJson()));
    });

    test('Local is direct only whatever is stored; a server the user adds is VPN only; the OS resolver needs no sides', () {
      final c = make(snap(over: {
        'dnsServers': {
          'local': {'id': 'local', 'on': true, 'sides': ['direct', 'vpn'], 'use': <String>[], 'transports': [{'kind': 'system', 'addr': 'system'}]},
          'new': {'id': 'new', 'on': true, 'transports': [{'kind': 'doh', 'addr': 'https://9.9.9.9/dns-query'}]},
        },
        'dnsOrder': ['local', 'new'],
        'dnsCfg': {'listVersion': 2},
      }));
      expect(c.dnsServers['local']!.activeSides, {'direct'});
      expect(c.dnsServers['local']!.via, 'direct');
      final plan = (c.routingPlan()['dns'] as Map)['servers'] as List;
      expect((plan[0] as Map)['sides'], ['direct']);
      expect(c.dnsServers['new']!.activeSides, {'vpn'}, reason: 'a provider with no sides: VPN only');
      expect((plan[1] as Map)['sides'], ['vpn']);
      expect((plan[1] as Map)['use'], ['doh', 'dot']);
      // a server added by hand through the old single-address constructor: VPN only too
      expect(DnsServerCfg(id: 'x', addr: 'tls://dns.example').activeSides, {'vpn'});
      expect(DnsServerCfg(id: 'x', addr: 'system').activeSides, {'direct'}, reason: 'unless it is the OS resolver');
    });

    test('builtin is derived from the id of the defaults, never stored', () {
      final c = make();
      expect([for (final s in c.dnsServers.values) '${s.id}:${s.builtin}'], ['cloudflare:true', 'google:true', 'adguard:true', 'local:true']);
      expect(DnsServerCfg(id: 'dns1', addr: 'tls://1.1.1.1').builtin, isFalse);
      expect(c.dnsServers['google']!.toJson().containsKey('builtin'), isFalse);
    });

    group('built-in addresses come from the code', () {
      Map<String, dynamic> stored() => snap(over: {
            'dnsServers': {
              'cloudflare': {
                'id': 'cloudflare',
                'name': 'CF mine',
                'on': false,
                'sides': ['vpn'],
                'use': ['dot', 'udp'],
                'transports': [
                  {'kind': 'doh', 'addr': 'https://stale.example/dns-query'},
                  {'kind': 'dot', 'addr': 'tls://stale.example'},
                ],
                'tag': 't',
              },
              'google': {
                'id': 'google',
                'on': true,
                'sides': ['direct', 'vpn'],
                'use': ['doh', 'doq'], // doq: a kind the code has not (for Google)
                'transports': [
                  {'kind': 'doq', 'addr': 'quic://old.example'},
                ],
              },
              'local': {'id': 'local', 'on': true, 'sides': ['direct'], 'use': <String>[], 'transports': [{'kind': 'system', 'addr': 'elsewhere'}]},
              'own': {'id': 'own', 'on': true, 'sides': ['vpn'], 'use': ['dot'], 'transports': [{'kind': 'dot', 'addr': 'tls://9.9.9.9', 'tt': 1}]},
            },
            'dnsOrder': ['own', 'local', 'cloudflare', 'google'],
            'dnsCfg': {'listVersion': 2},
          });

      List<String> addrs(DnsServerCfg s) => [for (final t in s.transports) '${t.kind} ${t.addr}'];

      test('a stored built-in loads with the transports of the code; the user\'s settings stay', () {
        final c = make(stored());
        final defaults = {for (final s in defaultDnsServers()) s.id: s};
        for (final id in ['cloudflare', 'google', 'local']) {
          expect(addrs(c.dnsServers[id]!), addrs(defaults[id]!), reason: id);
        }
        final cf = c.dnsServers['cloudflare']!;
        expect([cf.name, cf.on, cf.sides, cf.use], ['CF mine', false, {'vpn'}, {'dot', 'udp'}]);
        expect(cf.unknown['tag'], 't');
        expect(c.dnsOrder, ['own', 'local', 'cloudflare', 'google']);
        expect(addrs(c.dnsServers['own']!), ['dot tls://9.9.9.9'], reason: 'an own server keeps its stored addresses');
        // the plan (and so the sing-box config) gets the full transports
        final plan = ((c.routingPlan()['dns'] as Map)['servers'] as List).cast<Map>();
        final cfPlan = plan.firstWhere((s) => s['id'] == 'cloudflare');
        expect([for (final t in cfPlan['transports'] as List) '${(t as Map)['kind']} ${t['addr']}'], addrs(defaults['cloudflare']!));
        expect(cfPlan['use'], ['dot', 'udp']);
      });

      test('a kind the code dropped is ignored; a kind the code added is off for a stored built-in', () {
        final c = make(stored());
        final g = c.dnsServers['google']!;
        expect(g.use, {'doh', 'doq'}, reason: 'stored use stays');
        expect(g.usedTransports.map((t) => t.kind).toSet(), {'doh'}, reason: 'doq has no address now');
        // the code gives Cloudflare a kind this store never had: not in use
        final cf = c.dnsServers['cloudflare']!;
        expect(cf.transports.map((t) => t.kind), contains('doh'));
        expect(cf.use.contains('doh'), isFalse);
        expect(cf.usedTransports.map((t) => t.kind).toSet(), {'dot', 'udp'});
      });

      test('the write omits the transports of a built-in, keeps those of an own server; settings survive a round trip', () {
        final c = make(stored());
        final out = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
        final ds = out['dnsServers'] as Map;
        for (final id in ['cloudflare', 'google', 'local']) {
          expect((ds[id] as Map).containsKey('transports'), isFalse, reason: id);
        }
        expect((ds['own'] as Map)['transports'], [
          {'kind': 'dot', 'addr': 'tls://9.9.9.9', 'tt': 1},
        ]);
        expect(ds['cloudflare'], containsPair('name', 'CF mine'));
        expect(ds['cloudflare'], containsPair('on', false));
        expect(ds['cloudflare'], containsPair('sides', ['vpn']));
        expect(ds['cloudflare'], containsPair('use', ['dot', 'udp']));
        expect(ds['cloudflare'], containsPair('tag', 't'));
        expect(out['dnsOrder'], ['own', 'local', 'cloudflare', 'google']);
        final again = make(out);
        expect(jsonEncode(again.toJson()), jsonEncode(c.toJson()));
        expect(addrs(again.dnsServers['cloudflare']!), addrs(c.dnsServers['cloudflare']!));
      });

      test('a list migrated from the old version gets the code\'s addresses too, and writes none for the built-ins', () {
        final c = make(oldList());
        final out = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
        final ds = out['dnsServers'] as Map;
        expect((ds['cloudflare'] as Map).containsKey('transports'), isFalse);
        expect((ds['ya'] as Map).containsKey('transports'), isTrue);
        expect(c.dnsServers['cloudflare']!.transports.length, defaultDnsServers().first.transports.length);
      });
    });

    test('directPolicy: localFirst by default, priority when stored; an unknown value is the default', () {
      expect(make().dnsCfg.directPolicy, 'localFirst');
      expect(make(snap(over: {'dnsCfg': {'directPolicy': 'priority', 'listVersion': 2}})).dnsCfg.directPolicy, 'priority');
      expect(make(snap(over: {'dnsCfg': {'directPolicy': 'bogus', 'listVersion': 2}})).dnsCfg.directPolicy, 'localFirst');
      expect((make(snap(over: {'dnsCfg': {'directPolicy': 'priority', 'listVersion': 2}})).routingPlan()['dns'] as Map)['directPolicy'], 'priority');
    });
  });

  group('pings', () {
    test('a timeout counts one more fail, an answer resets them', () {
      final c = make();
      final n = nodeOf(c, 'a::a1');
      c.pings.set(n, -1);
      c.pings.set(n, -1);
      expect(c.pings.entry(n)!.fails, 2);
      c.pings.set(n, 50);
      expect(c.pings.entry(n)!.fails, 0);
      expect(c.pings.isAlive(n), isTrue);
    });

    test('unmarkTesting: a ping that did not run gives back the old value; a never-pinged node ends without one', () {
      final c = make();
      final a = nodeOf(c, 'a::a1'), dead = nodeOf(c, 'a::a2'), fresh = nodeOf(c, 'b::b1');
      ping(c, 'a::a1', 80);
      ping(c, 'a::a2', -1, fails: 2);
      c.pings.markTesting([a, dead, fresh]);
      c.pings.markTesting([a]); // a second ping on the same node: the first old value stays
      expect(c.pings.ping(a), isNull);
      c.pings.unmarkTesting([a, dead, fresh]);
      expect(c.pings.ping(a), 80);
      expect(c.pings.entry(a)!.testing, isFalse);
      expect(c.pings.ping(dead), -1);
      expect(c.pings.entry(dead)!.fails, 2);
      expect(c.pings.entry(fresh), isNull);
      expect(c.pings.anyTesting, isFalse);
    });

    test('rank: alive by ms, never measured, dead last', () {
      final c = make();
      ping(c, 'a::a1', 80);
      ping(c, 'a::a2', 20);
      ping(c, 'a::a3', -1);
      final r = [for (final k in ['a::a1', 'a::a2', 'a::a3', 'b::b1']) c.pings.rank(nodeOf(c, k))];
      expect(r, [80, 20, 2e9, 1e9]);
    });

    test('a ping in flight keeps counting as dead (and is not saved)', () {
      final c = make();
      final n = nodeOf(c, 'a::a1');
      ping(c, 'a::a1', -1, fails: 2);
      expect(c.knownDead(n), isTrue);
      c.pings.markTesting([n]);
      expect(c.knownDead(n), isTrue);
      expect(c.pings.anyTesting, isTrue);
      expect(c.pings.toJson(), isEmpty);
      c.pings.set(n, 40);
      expect(c.knownDead(n), isFalse);
    });

    test('dead only while fresh and after failAfter misses', () {
      final c = make();
      final n = nodeOf(c, 'a::a1');
      ping(c, 'a::a1', -1, fails: 1);
      expect(c.knownDead(n), isFalse); // one lost ping
      ping(c, 'a::a1', -1, fails: 2);
      expect(c.knownDead(n), isTrue);
      ping(c, 'a::a1', -1, fails: 5, age: pingFreshMs + 1);
      expect(c.knownDead(n), isFalse); // measured long ago
      c.autoCfg.failAfter = 6;
      ping(c, 'a::a1', -1, fails: 5);
      expect(c.knownDead(n), isFalse);
    });

    test('stored pings: per variant, an old key goes only to a server with one variant', () {
      final s = snap();
      (s['sourcesData'] as Map)['b'] = source('b', ['1', '2']);
      // b2 gets a second variant of the same server
      final b = (s['sourcesData'] as Map)['b'] as Map;
      (b['nodes'] as List).add(node('b2x', extra: {'address': 'b2.example'}));
      s['pings'] = [
        ['vless://a1.example:443', {'ms': 30, 'at': t0}], // old key, one variant: goes to a1
        ['vless://b2.example:443', {'ms': -1}], // old key, two variants: nobody
        ['vless://a2.example:443#a2', {'ms': -1, 'at': t0, 'fails': 4}],
        ['vless://ghost.example:443#zz', {'ms': 10, 'at': t0}], // a server not in the catalog: kept as it was
      ];
      final c = make(s);
      expect(c.pings.ping(nodeOf(c, 'a::a1')), 30);
      expect(c.pings.ping(nodeOf(c, 'b::b2')), isNull);
      expect(c.pings.entry(nodeOf(c, 'a::a2'))!.fails, 4);
      expect(c.pings.keys, contains('vless://ghost.example:443#zz'));
    });

    test('the core checks land newer-only, an in-flight ping wins', () {
      final c = make();
      final a1 = nodeOf(c, 'a::a1'), a2 = nodeOf(c, 'a::a2');
      c.pings.put(a1, PingEntry(ms: 90, at: 5000));
      c.pings.markTesting([a2]);
      final changed = c.pings.mergeCore([
        {'key': 'a::a1', 'ms': 20, 'at': 4000}, // older: ignored
        {'key': 'a::a2', 'ms': 20, 'at': 9000}, // in flight: ignored
        {'key': 'b::b1', 'ms': 33, 'at': 9000, 'fails': 0},
        {'key': 'zz::q', 'ms': 1, 'at': 1},
      ], c.nodeOfKey);
      expect(changed, isTrue);
      expect(c.pings.ping(a1), 90);
      expect(c.pings.ping(a2), isNull);
      expect(c.pings.ping(nodeOf(c, 'b::b1')), 33);
    });
  });

  // A chain's exit may be unreachable on its own and fine through the entry: it lives by its pair.
  group('chain pairs', () {
    void pair(Catalog c, String entry, String exit, num ms, {int? fails, int age = 1000}) =>
        c.pairs.put(nodeOf(c, entry), nodeOf(c, exit), PingEntry(ms: ms, at: clock - age, fails: fails ?? (ms < 0 ? 1 : 0)));

    test('an exit dead directly but alive through the entry works: exit node, usable, mayWork, latency', () {
      final c = make();
      final ch = c.chainsData['c1']!;
      ping(c, 'b::b1', 20);
      ping(c, 'b::b2', 50);
      for (final k in ['a::a1', 'a::a2', 'a::a3']) {
        ping(c, k, -1, fails: 5); // not reachable directly
      }
      expect(c.chainExitNode(ch), isNull);
      expect(c.isUsable('c1'), isFalse);
      expect(c.mayWork('c1'), isTrue); // every exit misses directly, but a direct miss says nothing about the pair
      pair(c, 'b::b1', 'a::a2', 70);
      expect(c.chainExitNode(ch)!.id, 'a2');
      expect(c.isUsable('c1'), isTrue);
      expect(c.mayWork('c1'), isTrue);
      expect(c.chainLatency(ch), 70); // the pair itself, not 20 + (a2 direct)
      expect(c.chainExitPing(ch, nodeOf(c, 'a::a2')), 70);
      expect(c.chainExitPing(ch, nodeOf(c, 'a::a1')), isNull); // no pair, direct miss: unknown
    });

    test('a direct miss does not kill an exit for Auto: mayWork holds until its pair is known dead', () {
      final c = make();
      final ch = c.chainsData['c1']!;
      ping(c, 'b::b1', 20);
      for (final k in ['a::a1', 'a::a2', 'a::a3']) {
        ping(c, k, -1, fails: 5);
        pair(c, 'b::b1', k, -1, fails: 2);
      }
      expect(c.mayWork('c1'), isFalse);
      pair(c, 'b::b1', 'a::a3', -1, fails: 1); // one lost ping
      expect(c.mayWork('c1'), isTrue);
      pair(c, 'b::b1', 'a::a3', -1, fails: 2, age: pingFreshMs + 1); // long ago
      expect(c.mayWork('c1'), isTrue);
      expect(c.chainExitKnownDead(ch, nodeOf(c, 'a::a1')), isTrue);
      // a chain whose exits are all dead through the entry is skipped, whatever their direct pings
      pair(c, 'b::b1', 'a::a3', -1, fails: 2);
      for (final k in ['a::a1', 'a::a2', 'a::a3']) {
        ping(c, k, 30);
      }
      expect(c.mayWork('c1'), isFalse);
    });

    test('the pair is read through the entry in use: the core\'s, else the best alive one; another entry\'s fresh pair fills in', () {
      final c = make();
      final ch = c.chainsData['c1']!;
      ping(c, 'b::b1', 20);
      ping(c, 'b::b2', 40);
      pair(c, 'b::b1', 'a::a1', -1, fails: 3);
      pair(c, 'b::b2', 'a::a1', 90);
      // b1 is the entry in use and says dead
      expect(c.chainExitAlive(ch, nodeOf(c, 'a::a1')), isFalse);
      expect(c.chainExitKnownDead(ch, nodeOf(c, 'a::a1')), isTrue);
      c.coreRoute = const CoreRoute(id: 'c1', server: 'a::a1', entryServer: 'b::b2');
      expect(c.chainPair(ch, nodeOf(c, 'a::a1'))!.ms, 90);
      c.coreRoute = null;
      // an exit b1 never measured: the fresh pair through b2 is used
      pair(c, 'b::b2', 'a::a2', 55);
      expect(c.chainPair(ch, nodeOf(c, 'a::a2'))!.ms, 55);
      pair(c, 'b::b2', 'a::a2', 55, age: pingFreshMs + 1);
      expect(c.chainPair(ch, nodeOf(c, 'a::a2')), isNull); // stale: not borrowed
    });

    test('Fastest / Priority exits order and choose by the pair; direct answers are a hint only while no pair exists', () {
      final c = make();
      ping(c, 'b::b1', 20);
      final ch = c.chainsData['c1']!;
      ping(c, 'a::a1', 10); // direct only: a hint
      pair(c, 'b::b1', 'a::a2', 60);
      pair(c, 'b::b1', 'a::a3', 40);
      expect(c.chainExitNode(ch)!.id, 'a1'); // the hint is the fastest number
      pair(c, 'b::b1', 'a::a1', -1, fails: 1); // measured through the entry: dead
      expect(c.chainExitNode(ch)!.id, 'a3');
      List keys(Plan p) => [for (final n in (((p['routes'] as List)[2]['main']) as Map)['nodes']) n['key']];
      expect(keys(c.livePlan()), ['a::a3', 'a::a2', 'a::a1']);
      ch.exitMode = 'priority';
      c.sourcesData['a']!.pickOrder = ['a::a1', 'a::a2', 'a::a3'];
      expect(c.chainExitNode(ch)!.id, 'a2'); // the first alive by the pair in the chain's order
      // the plan starts on the first not known dead: one miss is not dead yet (a1), a never-measured one is a candidate
      expect(((c.livePlan()['routes'] as List)[2]['main'] as Map)['chosen'], 'a::a1');
      pair(c, 'b::b1', 'a::a1', -1, fails: 9);
      expect(((c.livePlan()['routes'] as List)[2]['main'] as Map)['chosen'], 'a::a2');
      expect(c.byChainPing<NodeRef>(ch, c.chainExitRefs(ch), (r) => r.node).map((r) => r.node.id), ['a3', 'a2', 'a1']);
    });

    test('without pairs the chain reads the direct answers as before (the hop sum for the latency)', () {
      final c = make();
      final ch = c.chainsData['c1']!;
      ping(c, 'b::b1', 20);
      ping(c, 'a::a1', 30);
      expect(c.chainExitNode(ch)!.id, 'a1');
      expect(c.chainLatency(ch), 50);
      ping(c, 'a::a1', -1, fails: 3);
      expect(c.chainExitNode(ch), isNull);
      expect(c.chainLatency(ch), isNull);
    });

    test('pairs are saved in the snapshot and a ping in flight is not', () {
      final c = make();
      final b1 = nodeOf(c, 'b::b1'), a1 = nodeOf(c, 'a::a1'), a2 = nodeOf(c, 'a::a2');
      c.pairs.set(b1, a1, 70, clock);
      c.pairs.set(b1, a2, -1, clock);
      c.pairs.set(b1, a2, -1, clock);
      c.pairs.markTesting(b1, [nodeOf(c, 'a::a3')]);
      final j = c.toJson();
      expect((j['pairs'] as List).length, 2);
      final back = make(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.pairs.ping(nodeOf(back, 'b::b1'), nodeOf(back, 'a::a1')), 70);
      expect(back.pairs.entry(nodeOf(back, 'b::b1'), nodeOf(back, 'a::a2'))!.fails, 2);
      expect(back.pairs.anyTesting, isFalse);
      c.pairs.unmarkTesting(b1, [nodeOf(c, 'a::a3')]);
      expect(c.pairs.entry(b1, nodeOf(c, 'a::a3')), isNull);
    });

    test('the core\'s pair checks land newer-only, an in-flight pair wins; unknown servers are skipped', () {
      final c = make();
      final b1 = nodeOf(c, 'b::b1'), a1 = nodeOf(c, 'a::a1'), a2 = nodeOf(c, 'a::a2');
      c.pairs.put(b1, a1, PingEntry(ms: 90, at: 5000));
      c.pairs.markTesting(b1, [a2]);
      final changed = c.pairs.mergeCore([
        {'entry': 'b::b1', 'key': 'a::a1', 'ms': 20, 'at': 4000}, // older
        {'entry': 'b::b1', 'key': 'a::a2', 'ms': 20, 'at': 9000}, // in flight
        {'entry': 'b::b2', 'key': 'a::a1', 'ms': 33, 'at': 9000, 'fails': 0},
        {'entry': 'zz::q', 'key': 'a::a1', 'ms': 1, 'at': 1},
      ], c.nodeOfKey);
      expect(changed, isTrue);
      expect(c.pairs.ping(b1, a1), 90);
      expect(c.pairs.ping(b1, a2), isNull);
      expect(c.pairs.ping(nodeOf(c, 'b::b2'), a1), 33);
      expect(c.pairs.keys.length, 3);
    });
  });

  group('what is connected', () {
    test('Auto: the first entry in Auto that may work; every one silent -> still the first', () {
      final c = make();
      expect(c.effectiveConnectId(), 'a');
      for (final k in ['a::a1', 'a::a2', 'a::a3']) {
        ping(c, k, -1, fails: 2);
      }
      expect(c.effectiveConnectId(), 'b');
      for (final k in ['b::b1', 'b::b2']) {
        ping(c, k, -1, fails: 2);
      }
      // the chain's entry (b) and exit (a) are dead too
      expect(c.effectiveConnectId(), 'a');
    });

    test('the core\'s own position wins over the guess, but not for the plan', () {
      final c = make();
      c.coreRoute = const CoreRoute(id: 'b', server: 'b::b2');
      expect(c.effectiveConnectId(), 'b');
      expect(c.effectiveConnectId(true), 'a');
      expect(c.unitNode('b')!.id, 'b2');
      expect(c.livePlan()['current'], 0); // the plan is built on the catalog's pick
      c.coreRoute = const CoreRoute(id: 'b', server: 'b::gone'); // a server that is not there: ignored
      ping(c, 'b::b1', 30);
      expect(c.unitNode('b')!.id, 'b1');
    });

    test('Manual pin: that entry and that server, answering or not; a stale pin falls back', () {
      final c = make();
      c.pinRouteNode('a', 'a::a3');
      expect(c.autoConnect, isFalse);
      expect(c.effectiveConnectId(), 'a');
      ping(c, 'a::a3', -1, fails: 9);
      expect(c.unitNode('a')!.id, 'a3');
      final plan = c.livePlan();
      final main = (plan['routes'] as List).firstWhere((r) => r['id'] == 'a')['main'] as Map;
      expect(main['pinned'], isTrue);
      expect(main['pick'], 'priority');
      expect(main['chosen'], 'a::a3');
      c.sourcesData['a']!.disabledNodes = ['a3']; // the pinned server went off in Nodes
      expect(c.pinnedRef('a'), isNull);
      c.pinRouteNode('a', 'a::a1');
      c.pinRouteNode('a', 'a::a1'); // again: back to the entry's own pick
      expect(c.pinnedNode, isNull);
      expect(c.autoConnect, isFalse);
    });

    test('nothing in Auto, and the alert / empty states', () {
      final c = make();
      for (final id in ['a', 'b', 'c1']) {
        c.connectEntry(id)!.inAuto = false;
      }
      expect(c.nothingInAuto(), isTrue);
      expect(c.effectiveConnectId(), isNull);
      expect(c.checkBeforeConnect()!.code, 'nothingInAuto');
      expect(() => c.livePlan(), throwsA(isA<CatalogException>().having((e) => e.code, 'code', 'nothingInAuto')));
      final empty = Catalog.fromJson(null, now: () => clock);
      expect(empty.catalogEmpty(), isTrue);
      expect(empty.checkBeforeConnect()!.code, 'catalogEmpty');
      expect(empty.checkBeforeConnect()!.message, 'Add a subscription or a server first');
      expect(() => empty.livePlan(), throwsA(isA<CatalogException>().having((e) => e.code, 'code', 'nothingToConnect')));
      expect(make().checkBeforeConnect(), isNull);
    });

    test('a server switched off in Nodes breaks what stood only on it; the text says what to switch on', () {
      final c = make();
      c.sourcesData['b']!.disabledNodes = ['b1', 'b2'];
      expect(c.isBroken('b'), isTrue);
      expect(c.brokenBy('b'), [const OffReason('b', 'b1'), const OffReason('b', 'b2')]);
      expect(c.reasonsText(c.brokenBy('b')), '🇩🇪 Server b1, 🇩🇪 Server b2 are off in Nodes');
      expect(c.brokenBy('c1'), c.brokenBy('b')); // the chain's entry is b
      expect(c.visibleOrder(), ['a']);
      expect(c.brokenOrder(), ['b', 'c1']);
      c.sourcesData['b']!.enabled = false;
      expect(c.entryVisible('b'), isFalse);
      expect(c.brokenBy('b'), [const OffReason('b')]);
      expect(c.reasonsText(c.brokenBy('b')), 'Source b is off in Nodes');
    });
  });

  group('plan', () {
    test('a Fastest group lists the known fastest first, dead ones last; Priority keeps its order', () {
      final c = make();
      ping(c, 'a::a1', 90);
      ping(c, 'a::a2', 30);
      ping(c, 'a::a3', -1, fails: 9);
      List keys(Plan p, int route) => [for (final n in ((p['routes'] as List)[route]['main'] as Map)['nodes']) n['key']];
      expect(keys(c.livePlan(), 0), ['a::a2', 'a::a1', 'a::a3']);
      c.sourcesData['a']!.pickMode = 'priority';
      c.sourcesData['a']!.pickOrder = ['a::a3', 'a::a1'];
      final p = c.livePlan();
      expect(keys(p, 0), ['a::a3', 'a::a1', 'a::a2']);
      expect(((p['routes'] as List)[0]['main'] as Map)['chosen'], 'a::a1'); // the first not known dead in the order
    });

    test('Priority starts on the first server not known dead: one never measured is a candidate, a known-dead one is skipped', () {
      final c = make();
      c.sourcesData['a']!.pickMode = 'priority';
      c.sourcesData['a']!.pickOrder = ['a::a3', 'a::a1', 'a::a2'];
      ping(c, 'a::a1', 90);
      ping(c, 'a::a2', 30);
      // a3 was never measured: it is not dead, it goes first
      expect(c.unitNode('a')!.id, 'a3');
      expect(((c.livePlan()['routes'] as List)[0]['main'] as Map)['chosen'], 'a::a3');
      ping(c, 'a::a3', -1, fails: 9); // known dead now
      expect(c.unitNode('a')!.id, 'a1');
    });

    test('a new plan starts every route group where the core had it (standby routes too); that is no plan change', () {
      final c = make();
      c.sourcesData['a']!.pickMode = 'priority';
      c.sourcesData['a']!.pickOrder = ['a::a1', 'a::a2', 'a::a3'];
      c.chainsData['c1']!.exitMode = 'priority';
      c.chainsData['c1']!.exitOrder = ['a::a1', 'a::a2', 'a::a3'];
      Object? chosen(Plan p, int route) => ((p['routes'] as List)[route]['main'] as Map)['chosen'];
      final before = c.planSig();
      var p = c.livePlan();
      expect([chosen(p, 0), chosen(p, 2)], ['a::a1', 'a::a1']); // the catalog's own guess
      // Auto had moved the standby routes: a to a2, the chain to the exit a3 through the entry b2
      c.coreRoute = const CoreRoute(id: 'b', server: 'b::b2');
      c.coreGroups = {
        'a': const CoreRoute(id: 'a', server: 'a::a2'),
        'b': const CoreRoute(id: 'b', server: 'b::b2'),
        'c1': const CoreRoute(id: 'c1', server: 'a::a3', entryServer: 'b::b2'),
      };
      p = c.livePlan();
      expect([chosen(p, 0), chosen(p, 2)], ['a::a2', 'a::a3']);
      expect(p['current'], 0, reason: 'the anchor stays the catalog\'s pick');
      expect(c.planSig(), before, reason: 'where a group stands is the core\'s business, not a new plan');
      // the UI shows the core's server for a route it is not on, too
      expect(c.unitNode('a')!.id, 'a2');
      // a server that is no longer there is ignored
      c.coreGroups = {'a': const CoreRoute(id: 'a', server: 'a::gone')};
      expect(chosen(c.livePlan(), 0), 'a::a1');
    });

    test('servers the core cannot use are left out; none left is an error with the reason', () {
      final c = make();
      c.sourcesData['a']!.nodes[0] = CatalogNode.fromJson({...node('a1'), 'unsupported': 'XHTTP'});
      final main = ((c.livePlan()['routes'] as List)[0]['main'] as Map)['nodes'] as List;
      expect(main.map((n) => n['key']), ['a::a2', 'a::a3']);
      for (final n in c.sourcesData['b']!.nodes) {
        c.sourcesData['b']!.nodes[c.sourcesData['b']!.nodes.indexOf(n)] = CatalogNode.fromJson({...n.toJson(), 'unsupported': 'XHTTP'});
      }
      final routes = c.livePlan()['routes'] as List;
      expect(routes.map((r) => r['id']), ['a']); // b and the chain have nothing usable: not routes
      c.pinRouteNode('b', 'b::b1');
      expect(
          () => c.livePlan(),
          throwsA(isA<CatalogException>()
              .having((e) => e.code, 'code', 'noUsableServer')
              .having((e) => e.message, 'message', 'No server here the core can use (XHTTP is not in sing-box)')));
    });

    test('Auto lists every Auto entry as a route, Manual too (`manual`, current = the anchor); the mockup\'s plan only the pinned one', () {
      final c = make();
      var p = c.livePlan();
      expect((p['routes'] as List).map((r) => r['id']), ['a', 'b', 'c1']);
      expect(p['current'], 0);
      expect(p.containsKey('manual'), isFalse);
      expect((p['routes'] as List)[2]['kind'], 'chain');
      final auto = c.planSig();
      c.selectConnect('b');
      p = c.livePlan();
      expect((p['routes'] as List).map((r) => r['id']), ['a', 'b', 'c1']);
      expect(p['current'], 1);
      expect(p['manual'], isTrue);
      expect(c.planSig(), auto, reason: 'Auto <-> Manual is no new plan: the core switches it live');
      c.mockupPlan = true; // the mockup's plan
      p = c.livePlan();
      expect((p['routes'] as List).map((r) => r['id']), ['b']);
      expect(p.containsKey('manual'), isFalse);
      c.mockupPlan = false;
      c.selectConnect('b'); // back to Auto
      expect(c.planSig(), auto);
      c.connectEntry('a')!.inAuto = false;
      p = c.livePlan();
      expect((p['routes'] as List).map((r) => r['id']), ['b', 'c1']);
    });

    test('plan header: mode, ports, auth, urlTest, Auto settings', () {
      final c = make();
      c.connCfg
        ..proxyAuth = true
        ..proxyUser = 'u'
        ..proxyPass = 'p'
        ..testUrl = 'https://t.example/'
        ..port = 0;
      c.segState
        ..mode = 'tun'
        ..route = 'global';
      final p = c.livePlan();
      expect(p['mode'], 'tun');
      expect(p['global'], isTrue);
      expect(p['mixedPort'], 2080);
      expect(p['mixedAuth'], {'user': 'u', 'pass': 'p'});
      expect(p['urlTest'], {'interval': 60, 'tolerance': 50, 'url': 'https://t.example/'});
      expect((p['auto'] as Map)['checkers'], c.connCfg.checkers);
      expect((p['auto'] as Map).keys, containsAll(['failAfter', 'threshold', 'returnTo', 'siteRetry']));
      // the external checker switch: on by default and then not written (the mockup's snapshots stay the same); off is
      expect((p['auto'] as Map).containsKey('siteCheck'), isFalse);
      expect(c.autoCfg.toJson().containsKey('siteCheck'), isFalse);
      c.autoCfg.siteCheck = false;
      expect((c.livePlan()['auto'] as Map)['siteCheck'], isFalse);
      expect(AutoCfg.fromJson(c.autoCfg.toJson()).siteCheck, isFalse);
      c.autoCfg.siteCheck = true;
      c.connCfg
        ..proxyAuth = false
        ..testUrl = '';
      final q = c.livePlan();
      expect(q.containsKey('mixedAuth'), isFalse);
      expect((q['urlTest'] as Map).containsKey('url'), isFalse);
    });

    test('IPv6: off for a snapshot without it (migration), saved when on, in the plan and the signature in both modes', () {
      final c = make();
      expect(c.connCfg.ipv6, isFalse);
      expect(c.toJson()['connCfg']['ipv6'], isFalse);
      expect(c.livePlan()['ipv6'], isFalse);
      final sig = c.planSig();
      c.connCfg.ipv6 = true; // the DNS strategy counts in proxy mode, the TUN address in TUN
      expect(c.livePlan()['ipv6'], isTrue);
      expect(c.planSig(), isNot(sig));
      expect(make(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>).connCfg.ipv6, isTrue);
      c.segState.mode = 'tun';
      final tun = c.planSig();
      c.connCfg.ipv6 = false;
      expect(c.planSig(), isNot(tun));
    });

    test('planSig: ping order and the core\'s moves do not change it; a real change does', () {
      final c = make();
      ping(c, 'a::a1', 50);
      ping(c, 'a::a2', 90);
      final sig = c.planSig()!;
      ping(c, 'a::a1', 120); // Fastest reorders
      ping(c, 'a::a3', 10);
      expect(c.planSig(), sig);
      c.pings.markTesting([nodeOf(c, 'a::a2')]); // a ping in flight
      expect(c.planSig(), sig);
      c.coreRoute = const CoreRoute(id: 'b', server: 'b::b2'); // the core on its way: not a new plan
      expect(c.planSig(), sig);
      c.autoCfg.checkEvery = 5; // the plan's own urlTest interval (plan.auto itself is not in the signature)
      expect(c.planSig(), isNot(sig));
      c.autoCfg.checkEvery = 60;
      expect(c.planSig(), sig);
      c.sourcesData['a']!.disabledNodes = ['a2']; // a server off: a new plan
      expect(c.planSig(), isNot(sig));
      c.sourcesData['a']!.disabledNodes = [];
      expect(c.planSig(), sig);
      c.segState.sys = 'on'; // the system proxy goes with the reconnect
      expect(c.planSig(), isNot(sig));
      c.segState.sys = 'off';
      c.connCfg.tunStack = 'gvisor'; // only counts in TUN
      expect(c.planSig(), sig);
      c.segState.mode = 'tun';
      final tun = c.planSig();
      c.connCfg.tunStack = 'system';
      expect(c.planSig(), isNot(tun));
    });

    test('planSig: a Priority group counts by its first server when nothing is measured, a pin counts', () {
      final c = make();
      c.sourcesData['a']!.pickMode = 'priority';
      final sig = c.planSig();
      ping(c, 'a::a1', 40); // now a1 is chosen: it is the first anyway
      expect(c.planSig(), sig);
      c.pinRouteNode('a', 'a::a2');
      final pinned = c.planSig();
      expect(pinned, isNot(sig));
      c.pinRouteNode('a', 'a::a3');
      expect(c.planSig(), isNot(pinned));
    });

    test('liveSigAnchor keeps the anchor the plan was built on while it is still in Auto', () {
      final c = make();
      c.liveAnchor = 'b';
      expect(c.liveSigAnchor(), 'b');
      c.connectEntry('b')!.inAuto = false;
      expect(c.liveSigAnchor(), 'a');
      c.liveAnchor = 'a';
      c.selectConnect('b'); // Manual: the catalog's pick
      expect(c.liveSigAnchor(), 'b');
    });
  });

  group('rules in the plan', () {
    Catalog withRules() {
      final s = snap(over: {
        'rulesData': {
          'r1': {'id': 'r1', 'name': 'Via A', 'enabled': true, 'action': 'proxy', 'target': 'src:a', 'fallback': 'main', 'fallbackTarget': 'profile:p', 'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['a.com']}}}},
          'r2': {'id': 'r2', 'enabled': false, 'action': 'direct', 'groups': {}},
          'r3': {'id': 'r3', 'name': 'Raw', 'enabled': true, 'action': 'block', 'composite': {'type': 'logical', 'mode': 'or', 'rules': [], 'action': 'reject', 'method': 'drop', 'outbound': 'x'}, 'extra': {'a': 1}, 'ipTunOnly': true},
        },
        'ruleOrder': ['r1', 'r2', 'r3'],
        'quickCfg': {'ads': true, 'regionOn': false, 'final': 'direct', 'services': {'telegram': 'vpn', 'youtube': 'default', 'x': 'direct'}},
        'appRules': {
          'org.telegram.messenger': {'act': 'proxy', 'target': 'chain:c1', 'fallback': 'main', 'fallbackTarget': 'src:b', 'split': true, 'udp': {'act': 'direct'}},
          'old.app': {'act': 'proxy', 'split': true, 'udpTarget': 'src:a'},
        },
      });
      return make(s);
    }

    test('rules, apps, quick, fallback and the targets they name', () {
      final c = withRules();
      c.appInfo = (pkg) => pkg == 'org.telegram.messenger' ? (name: 'Telegram', kind: 'package') : null;
      final r = c.routingPlan();
      final rules = r['rules'] as List;
      expect(rules.map((x) => x['id']), ['r1', 'r3']); // disabled ones are left out
      expect(rules[0], {
        'id': 'r1',
        'name': 'Via A',
        'action': 'proxy',
        'target': 'src:a',
        'fallback': 'profile:p', // Proxy via X goes as the target id
        'dns': 'auto',
        'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['a.com']}}},
      });
      expect(rules[1]['composite'], {'type': 'logical', 'mode': 'or', 'rules': []}); // action / outbound / method are the core's
      expect(rules[1]['extra'], {'a': 1});
      expect(rules[1]['ipTunOnly'], isTrue);
      expect(rules[1]['fallback'], 'default'); // not a Proxy rule
      expect(r['quick'], {'ads': true, 'region': null, 'final': 'direct', 'services': {'telegram': 'vpn', 'x': 'direct'}});
      final apps = r['apps'] as List;
      expect(apps[0], {
        'id': 'org.telegram.messenger',
        'kind': 'package',
        'name': 'Telegram',
        'act': 'proxy',
        'target': 'chain:c1',
        'fallback': 'src:b',
        'split': true,
        'udp': {'act': 'direct', 'target': '', 'fallback': 'default'},
      });
      expect(apps[1]['name'], 'old.app'); // not in the installed list: its id
      // the installed list is not read yet (cold start): the name kept with the rule, not the package
      c.appInfo = null;
      c.appRules['org.telegram.messenger']!.unknown['name'] = 'Telegram';
      expect((c.routingPlan()['apps'] as List)[0]['name'], 'Telegram');
      expect(apps[1]['udp'], {'act': 'proxy', 'target': 'src:a', 'fallback': 'default'}); // the old udpTarget
      final t = r['targets'] as Map;
      expect(t.keys, unorderedEquals(['src:a', 'profile:p', 'chain:c1', 'src:b']));
      expect((t['chain:c1'] as Map)['kind'], 'chain');
      expect(((t['src:a'] as Map)['main'] as Map)['pick'], 'fastest');
      expect((r['geo'] as Map)['geosite'], {'via': 'vpn', 'every': 604800});
      expect(((r['dns'] as Map)['servers'] as List).map((s) => s['id']), ['cloudflare', 'google', 'adguard', 'local']);
      expect((r['dns'] as Map)['directPolicy'], 'localFirst');
      final cf = ((r['dns'] as Map)['servers'] as List).first as Map;
      expect(cf['sides'], ['direct', 'vpn']);
      expect(cf['use'], ['doh', 'dot']);
      expect((cf['transports'] as List).first, {'kind': 'doh', 'addr': 'https://1.1.1.1/dns-query'});
    });

    test('a target that is off, gone or has no usable server is null', () {
      final c = withRules();
      c.sourcesData['a']!.enabled = false;
      expect(c.targetInfo('src:a').ok, isFalse);
      expect(c.routingTarget('src:a'), isNull);
      expect(c.routingTarget('chain:c1'), isNull); // its exit is a
      expect(c.routingTarget('profile:p'), isNotNull); // b still serves it
      expect(c.targetInfo('src:zz').gone, isTrue);
      expect(c.targetInfo('node:a::a1').ok, isFalse);
      expect(c.targetInfo('node:b::b1').ok, isTrue);
      expect(c.targetInfo('b').kind, 'subscription'); // a bare entry id is that entry
      expect(c.targetInfo('').kind, 'main');
      expect(c.routingPlan()['targets'], containsPair('src:a', isNull));
    });

    test('app normalisation: the old udpTarget, halves, round trip of the normal form', () {
      final c = withRules();
      final old = c.appRules['old.app']!;
      expect(old.split, isTrue);
      expect(old.udp.act, 'proxy');
      expect(old.udp.target, 'src:a');
      expect(old.halves.map((h) => h.$1), ['TCP', 'UDP']);
      expect(c.appRules['org.telegram.messenger']!.halves.length, 2);
      final out = c.toJson()['appRules'] as Map;
      expect(out['old.app'], isNot(contains('udpTarget')));
      expect(((out['old.app'] as Map)['udp'] as Map)['target'], 'src:a');
    });
  });

  group('delete impact', () {
    test('a source: its chains go, entries left empty will not connect, a profile loses servers, rules lose targets', () {
      final c = make(snap(over: {
        'rulesData': {
          'r1': {'id': 'r1', 'name': 'To B', 'enabled': true, 'action': 'proxy', 'target': 'src:b', 'fallback': 'block'},
        },
        'ruleOrder': ['r1'],
        'appRules': {
          'org.x': {'act': 'proxy', 'target': 'chain:c1', 'fallback': 'default', 'split': false},
        },
      }));
      c.appInfo = (pkg) => (name: 'X app', kind: 'package');
      final lines = c.deleteSourceImpact('b');
      expect(lines.map((l) => l.toString()), [
        '[B via A | chain | is deleted with it | bad]',
        '[All | profile | loses 2 servers of 5 | warn]',
        '[To B | rule #1 | loses its target — traffic goes nowhere (blocked) | warn]',
        '[X app | app | loses its target — traffic goes through the main flow | warn]',
      ]);
      expect(c.simExclude, isNull); // the preview is switched off again
      // the connection goes through a1 (the fastest): deleting it says so
      ping(c, 'a::a1', 10);
      ping(c, 'a::a2', 99);
      final one = c.deleteNodeImpact('a', 'a1');
      expect(one.first.toString(), '[Current connection |  | goes through it — will reconnect through the next working server | warn]');
    });

    test('a profile: its chains move to the first other profile, the last one takes them with it', () {
      final s = snap(over: {
        'profilesData': {
          'p': {'id': 'p', 'name': 'P', 'sources': ['a'], 'nodes': <String>[], 'inAuto': true},
          'q': {'id': 'q', 'name': 'Q', 'sources': ['b'], 'nodes': <String>[], 'inAuto': true},
        },
        'chainsData': {
          'pc': {'id': 'pc', 'name': 'P to Q', 'inId': 'p', 'outId': 'q', 'inAuto': true},
        },
        'catalogOrder': {'simple': ['a', 'b'], 'profiles': ['p', 'q', 'pc']},
      });
      final c = make(s);
      expect(c.deleteEntryImpact('p').map((l) => l.toString()), ['[P to Q | chain | is deleted with it | bad]']); // both ends would be Q
      // with a third profile the chain keeps going: its end moves to the first other profile (p)
      final three = make(snap(over: {
        'profilesData': {
          ...s['profilesData'] as Map<String, dynamic>,
          'r': {'id': 'r', 'name': 'R', 'sources': ['a'], 'nodes': <String>[], 'inAuto': true},
        },
        'chainsData': {
          'qr': {'id': 'qr', 'name': 'Q to R', 'inId': 'q', 'outId': 'r', 'inAuto': true},
        },
        'catalogOrder': {'simple': ['a', 'b'], 'profiles': ['p', 'q', 'r', 'qr']},
      }));
      expect(three.deleteEntryImpact('q').map((l) => l.toString()), ['[Q to R | chain | its entry moves to P | warn]']);
      three.deleteProfile('q');
      expect(three.chainsData['qr']!.inId, 'p');
      expect(three.chainsData['qr']!.outId, 'r');
      three.deleteProfile('r'); // p -> p is pointless: the chain goes
      expect(three.chainsData, isEmpty);
    });
  });

  group('validation', () {
    test('a profile draft needs a server; the text says what is off', () {
      final c = make();
      expect(c.profileProblem(['a'], []), isNull);
      expect(c.profileProblem([], []), 'Select at least 1 server — a profile with none can’t connect');
      c.sourcesData['b']!.enabled = false;
      expect(c.profileProblem(['b'], []), 'Source b is off in Nodes — switch it on there or select another server');
      expect(c.profileProblem(['b'], ['a::a1']), isNull);
    });

    test('chain exit order: servers the chain never ordered follow the exit unit\'s pickOrder', () {
      final s = snap();
      ((s['sourcesData'] as Map)['a'] as Map)['pickOrder'] = ['a::a2', 'a::a1'];
      final c = make(s);
      final d = Chain(id: 'x', inId: 'b', outId: 'a');
      expect(c.chainExitOrder(d).map((r) => r.node.id), ['a2', 'a1', 'a3']);
      d.exitOrder = ['a::a3'];
      expect(c.chainExitOrder(d).map((r) => r.node.id), ['a3', 'a2', 'a1']);
    });

    test('a chain needs a server at both ends and two different ends', () {
      final c = make();
      final d = Chain(id: 'x', inId: 'b', outId: 'a');
      expect(c.chainProblems(d), isEmpty);
      expect(c.chainSaveProblem(Chain(id: 'x', inId: 'a', outId: 'a')), 'Entry and exit must be different');
      d.outOff = ['a::a1', 'a::a2', 'a::a3'];
      expect(c.chainProblems(d), ['Select at least 1 server of the exit']);
      c.sourcesData['b']!.enabled = false;
      expect(c.chainProblems(d), [
        'The entry: Source b is off in Nodes — switch it on there or select another server',
        'Select at least 1 server of the exit',
      ]);
      expect(c.chainSaveProblem(d), startsWith('The entry: '));
    });
  });

  group('ops', () {
    test('syncCatalog follows Nodes until the route has an order of its own', () {
      final c = make();
      c.catalogOrder['simple'] = ['b', 'a', 'c1'];
      c.syncCatalog();
      expect(c.connectOrder, ['b', 'a', 'c1']);
      c.reorderRoute(['c1', 'b', 'a']);
      expect(c.routeCustom['simple'], isTrue);
      c.catalogOrder['simple'] = ['a', 'b', 'c1', 'n'];
      c.sourceOrder = ['a', 'b'];
      c.syncCatalog();
      expect(c.connectOrder, ['c1', 'b', 'a']); // its own order; 'n' does not exist
      c.resetRouteOrder();
      expect(c.connectOrder, ['a', 'b', 'c1']);
    });

    test('reordering the shown part leaves hidden entries in their slots', () {
      final s = snap(over: {
        'chainsData': <String, dynamic>{},
        'connectOrder': ['a', 'b', 'z'],
        'catalogOrder': {'simple': ['a', 'b', 'z'], 'profiles': ['p']},
        'sourceOrder': ['a', 'b', 'z'],
      });
      (s['sourcesData'] as Map)['z'] = source('z', ['1']);
      final c = make(s);
      c.sourcesData['b']!.enabled = false; // hidden
      expect(c.visibleOrder(), ['a', 'z']);
      c.reorderRoute(['z', 'a']);
      expect(c.connectOrder, ['z', 'b', 'a']);
    });

    test('Auto / Manual switch and the Simple / Profiles state', () {
      final c = make();
      c.pings.put(nodeOf(c, 'a::a1'), PingEntry(ms: -1, at: clock, fails: 5));
      for (final k in ['a::a2', 'a::a3']) {
        c.pings.put(nodeOf(c, k), PingEntry(ms: -1, at: clock, fails: 5));
      }
      c.setAutoConnect(false); // Manual on what Auto would pick: b
      expect(c.activeConnectId, 'b');
      c.setConnectMode('profiles');
      expect(c.connectMode, 'profiles');
      expect(c.activeConnectId, 'p');
      expect(c.autoConnect, isTrue);
      c.setConnectMode('simple');
      expect(c.activeConnectId, 'b');
      expect(c.autoConnect, isFalse);
      expect(c.toggleEntryAuto('a'), isFalse);
      expect(c.toggleEntryAuto('b'), isFalse);
      c.setAutoConnect(true);
      expect(c.toggleEntryAuto('c1'), isTrue); // nothing left in Auto
    });

    test('modeEmpty tells either mode without switching to it', () {
      final c = make();
      expect(c.modeEmpty('simple'), isFalse);
      expect(c.modeEmpty('profiles'), isFalse);
      for (final id in [...c.getProfileIds()]) {
        c.deleteProfile(id);
      }
      for (final id in [...c.catalogOrder['profiles']!]) {
        if (c.chainsData.containsKey(id)) c.deleteChain(id);
      }
      c.syncCatalog(); // what the host does after every edit
      expect(c.connectMode, 'simple');
      expect(c.modeEmpty('profiles'), isTrue);
      expect(c.modeEmpty('simple'), isFalse);
      expect(c.catalogEmpty(), isFalse);
      c.setConnectMode('profiles'); // stuck in an empty mode: catalogEmpty is about the active one
      expect(c.catalogEmpty(), isTrue);
      expect(c.modeEmpty('profiles'), isTrue);
      expect(c.modeEmpty('simple'), isFalse);
      expect(Catalog.fromJson(null, now: () => clock).modeEmpty('simple'), isTrue);
    });

    test('deleting a source removes it from profiles and chains and drops the chains that end on it', () {
      final c = make();
      c.profilesData['p']!.nodes = ['a::a1', 'b::b1'];
      c.profilesData['p']!.pickOrder = ['a::a1', 'b::b1'];
      c.deleteSource('a');
      expect(c.sourcesData.keys, ['b']);
      expect(c.profilesData['p']!.sources, ['b']);
      expect(c.profilesData['p']!.nodes, ['b::b1']);
      expect(c.profilesData['p']!.pickOrder, ['b::b1']);
      expect(c.chainsData, isEmpty);
      expect(c.connectOrder, ['b']);
      expect(c.activeConnectId, 'b');
    });

    test('forgetting dropped servers: only the given ones, settings with them; goneAt missing = never expires', () {
      final s = snap();
      final a = (s['sourcesData'] as Map)['a'] as Map;
      a['gone'] = [
        node('g1', extra: {'goneAt': t0 - 20 * 86400000}),
        node('g2', extra: {'goneAt': t0 - 86400000}),
        node('g3'),
      ];
      (s['profilesData'] as Map)['p']['nodes'] = ['a::g1', 'a::g2'];
      final c = make(s);
      expect(c.goneLeftDays(c.sourcesData['a']!.gone[0]), -5);
      expect(c.goneLeftDays(c.sourcesData['a']!.gone[1]), 14);
      expect(c.goneLeftDays(c.sourcesData['a']!.gone[2]), isNull);
      expect(c.purgeExpiredGone(), 1);
      expect(c.sourcesData['a']!.gone.map((n) => n.id), ['g2', 'g3']);
      expect(c.profilesData['p']!.nodes, ['a::g2']);
      expect(c.forgetGone('a', ['g3']), 1);
      expect(c.forgetGone('a'), 1);
      expect(c.sourcesData['a']!.gone, isEmpty);
      expect(c.profilesData['p']!.nodes, isEmpty);
    });

    test('a new source joins the end of Simple, in Auto when it did not say', () {
      final c = make();
      c.addSource(Source.fromJson({'id': 'z', 'name': 'Z', 'enabled': true, 'nodes': [node('z1')]}));
      expect(c.sourcesData['z']!.inAuto, isTrue);
      expect(c.catalogOrder['simple']!.last, 'z');
      expect(c.connectOrder.last, 'z');
      expect(c.sourceOrder.last, 'z');
    });
  });
}
