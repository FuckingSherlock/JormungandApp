import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('links', () {
    test('vless reality', () {
      final n = parseLink(vlessReality)!;
      expect(n.flag, '🇩🇪');
      expect(n.name, 'Frankfurt 01');
      expect(n.protocol, 'vless');
      expect(n.outbound['flow'], 'xtls-rprx-vision');
      expect(n.outbound['tls']['reality']['public_key'], startsWith('Z84J'));
      expect(n.outbound['tls']['utls']['fingerprint'], 'chrome');
      expect(n.unsupported, isNull);
    });

    test('ws early data moves from the path to max_early_data', () {
      final t = parseLink(vlessWs)!.outbound['transport'] as Map;
      expect(t['path'], '/ws');
      expect(t['max_early_data'], 2048);
      expect(t['headers'], {'Host': 'cdn.example'});
    });

    test('xhttp is listed but marked unsupported', () {
      expect(parseLink(vlessXhttp)!.unsupported, 'xhttp');
    });

    test('shadowsocks: SIP002, 2022 plain userinfo, legacy', () {
      expect(parseLink(ssSip002)!.outbound, containsPair('method', 'aes-256-gcm'));
      expect(parseLink(ss2022)!.outbound['password'], 'AAAAAAAAAAAAAAAAAAAAAA==');
      final l = parseLink(ssLegacy)!;
      expect([l.address, l.port, l.outbound['password']], ['192.0.2.12', 8388, 'pass']);
    });

    test('hy2 with obfs and port hopping', () {
      final o = parseLink(hy2)!.outbound;
      expect(o['obfs'], {'type': 'salamander', 'password': 'ob'});
      expect(o['server_ports'], ['20000:30000']);
      expect(o['tls']['insecure'], true);
    });

    test('vmess v2rayN json', () {
      final n = parseLink(vmessJson)!;
      expect(n.name, 'WS'); // the protocol word goes: it has its own badge
      expect(n.outbound['transport'], {'type': 'ws', 'path': '/vm', 'headers': {'Host': 'tr1.example'}});
      expect(n.outbound['tls']['server_name'], 'tr1.example');
    });

    test('every sample parses, unknown schemes do not', () {
      expect(allLinks.map(parseLink).whereType<Node>(), hasLength(allLinks.length));
      expect(parseLink('foo://x@y:1'), isNull);
      expect(parseLink('https://t.me/provider'), isNull);
      expect(parseLink('not a link'), isNull);
    });

    test('vmess URI form: transport, TLS and cipher from the query', () {
      final n = parseLink(vmessUri)!;
      expect([n.protocol, n.address, n.port], ['vmess', 'tr2.example', 443]);
      expect(n.outbound['security'], 'aes-128-gcm');
      expect(n.outbound['transport'], {'type': 'grpc', 'service_name': 'vm'});
      expect(n.outbound['tls']['server_name'], 'tr2.example');
    });

    test('socks: v2rayN base64 userinfo and plain socks5', () {
      final a = parseLink(socksB64)!, b = parseLink(socks5Plain)!;
      expect(a.outbound, containsPair('username', 'user'));
      expect(a.outbound, containsPair('password', 'pass'));
      expect([b.protocol, b.outbound['username'], b.outbound['version']], ['socks', 'u2', '5']);
    });

    test('hysteria v1: auth, obfs, bandwidth, peer as SNI', () {
      final n = parseLink(hysteria1)!;
      expect(n.protocol, 'hy');
      expect(n.outbound, containsPair('auth_str', 'hy1-pass'));
      expect(n.outbound, containsPair('obfs', 'hide'));
      expect([n.outbound['up_mbps'], n.outbound['down_mbps']], [20, 100]);
      expect(n.outbound['tls']['server_name'], 'hk1.example');
      expect(n.unsupported, isNull);
    });

    test('quic transport goes to sing-box; without TLS it cannot', () {
      expect(parseLink(vlessQuic)!.outbound['transport'], {'type': 'quic'});
      expect(parseLink(vlessQuic)!.unsupported, isNull);
      expect(parseLink(vlessQuic.replaceFirst('security=tls', 'security=none'))!.unsupported, 'quic without tls');
    });

    test('wireguard, ssr and VLESS encryption are listed as unsupported', () {
      final ns = unsupportedLinks.map(parseLink).toList();
      expect(ns.map((n) => n!.unsupported), ['wireguard', 'ssr', 'vless encryption']);
      expect([ns[0]!.name, ns[0]!.address, ns[0]!.port], ['WG Home', '203.0.113.5', 51820]);
      expect([ns[1]!.name, ns[1]!.address, ns[1]!.port], ['Old', '203.0.113.6', 8388]);
    });
  });

  group('subscriptions', () {
    test('base64 list', () {
      final (f, nodes) = parseSubscription(base64.encode(utf8.encode(allLinks.join('\n'))));
      expect(f, SubFormat.base64);
      expect(nodes, hasLength(allLinks.length));
      expect(parseSubscription(allLinks.join('\n')).$1, SubFormat.uriList);
    });

    test('clash yaml: unknown types listed as unsupported', () {
      final (f, nodes) = parseSubscription(clashYaml);
      expect(f, SubFormat.clash);
      expect(nodes.map((n) => n.protocol), ['vless', 'hy2', 'ss', 'snell']);
      expect(nodes[1].outbound['server_ports'], ['20000:21000']);
      expect(nodes[2].outbound['plugin_opts'], 'obfs=http;obfs-host=bing.com');
      expect(nodes[3].unsupported, 'snell');
    });

    test('clash: vmess / trojan / tuic / anytls, ws / grpc / h2 / httpupgrade, socks / http / ssh / hysteria', () {
      final ns = {for (final n in parseClash(clashMore)) n.name: n};
      expect(ns.keys, ['VM WS', 'TJ gRPC', 'VL H2', 'VL Upgrade', 'TUIC', 'AnyTLS', 'Hy1', 'Socks', 'HTTP TLS', 'SSH', 'WG', 'VL PQ']);
      Map t(String k) => ns[k]!.outbound['transport'] as Map;
      expect(t('VM WS'), {
        'type': 'ws',
        'max_early_data': 2048,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
        'path': '/vmws',
        'headers': {'Host': 'cdn.vm1.example'},
      });
      expect(ns['VM WS']!.outbound['tls']['server_name'], 'vm1.example');
      expect(t('TJ gRPC'), {'type': 'grpc', 'service_name': 'tjsvc'});
      expect(t('VL H2'), {'type': 'http', 'host': ['vl1.example'], 'path': '/h2'});
      expect(t('VL Upgrade'), {'type': 'httpupgrade', 'host': 'vl2.example', 'path': '/up'});
      expect(ns['TUIC']!.outbound, containsPair('congestion_control', 'cubic'));
      expect(ns['TUIC']!.outbound, containsPair('udp_relay_mode', 'native'));
      expect(ns['AnyTLS']!.outbound['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      expect([ns['Hy1']!.outbound['up_mbps'], ns['Hy1']!.outbound['down_mbps'], ns['Hy1']!.outbound['obfs']], [30, 200, 'hide']);
      expect(ns['Socks']!.outbound, containsPair('type', 'socks'));
      expect(ns['HTTP TLS']!.outbound['tls']['server_name'], 'hp1.example');
      expect(ns['SSH']!.outbound, containsPair('user', 'root'));
      expect([ns['WG']!.unsupported, ns['VL PQ']!.unsupported], ['wireguard', 'vless encryption']);
      expect(ns.values.where((n) => n.unsupported == null), hasLength(10));
    });

    test('format by Content-Type and inside base64', () {
      String b64(String s) => base64.encode(utf8.encode(s));
      expect(parseSubscription(b64(clashYaml)).$1, SubFormat.clash);
      expect(parseSubscription(b64(singboxJson)).$1, SubFormat.singbox);
      expect(parseSubscription(b64(singboxJson)).$2.map((n) => n.name), ['Frankfurt 01']);
      // YAML whose proxies: key is not at a line start, told by its Content-Type
      expect(parseSubscription('{proxies: [{name: A, type: ss, server: 192.0.2.1, port: 1, cipher: aes-128-gcm, password: p}]}',
              contentType: 'text/yaml; charset=utf-8')
          .$1, SubFormat.clash);
      expect(SubFormat.base64.label, 'base64');
      expect(SubFormat.singbox.label, 'sing-box');
    });

    test('sing-box json: servers only, no groups or detoured outbounds', () {
      final (f, nodes) = parseSubscription(singboxJson);
      expect(f, SubFormat.singbox);
      expect(nodes.map((n) => n.name), ['Frankfurt 01']);
    });

    test('one server in three formats has one id', () {
      final ids = {
        parseLink(vlessReality)!.id,
        parseSubscription(clashYaml).$2.first.id,
        parseSubscription(singboxJson).$2.first.id,
      };
      expect(ids, hasLength(1));
    });
  });

  test('update keeps dropped servers in gone, brings returning ones back', () {
    final a = parseLink(ssSip002)!, b = parseLink(hy2)!, c = parseLink(tuic)!;
    final t0 = DateTime(2026, 1, 1);
    final first = mergeUpdate([a.toJson(), b.toJson()], [], [a, c], now: t0);
    expect(first.nodes.map((n) => n['id']), [a.id, c.id]);
    expect(first.gone.map((n) => n['id']), [b.id]);

    final back = mergeUpdate(first.nodes, first.gone, [a, b, c], now: t0.add(const Duration(days: 1)));
    expect(back.gone, isEmpty);

    final expired = mergeUpdate(first.nodes, first.gone, [a, c], now: t0.add(const Duration(days: 16)));
    expect(expired.gone, isEmpty);
  });

  group('variants of one server', () {
    const base = 'hysteria2://pw@hy.example:443?';
    Node hy(String q, [String name = 'VK']) => parseLink('$base$q#$name')!;

    test('SNI / fingerprint / ALPN variants are separate nodes of one server', () {
      final ns = [hy('sni=a.example'), hy('sni=b.example'), hy('sni=a.example&alpn=h3'), hy('sni=a.example')];
      expect(ns.map((n) => n.key).toSet(), hasLength(3));
      expect(ns.map((n) => n.base).toSet(), hasLength(1));
    });

    test('sni=off sends no SNI', () {
      final tls = hy('sni=off').outbound['tls'] as Map;
      expect(tls['disable_sni'], true);
      expect(tls.containsKey('server_name'), isFalse);
    });

    test('a changed variant keeps its id when unambiguous; same names get sticky numbers', () {
      final a = hy('sni=a.example'), b = hy('sni=b.example'), c = hy('sni=c.example', 'Other');
      final first = mergeUpdate([], [], [a, b, c]);
      expect(first.nodes.map((n) => n['name']), ['VK-1', 'VK-2', 'Other']);
      final ids = first.nodes.map((n) => n['id']).toList();

      // b dropped: a keeps VK-1 and is the only VK left (no number)
      final second = mergeUpdate(first.nodes, [], [a, c]);
      expect(second.nodes.map((n) => n['name']), ['VK', 'Other']);
      // b back in front of a: numbers stay with their servers
      final third = mergeUpdate(first.nodes, [], [b, a, c]);
      expect(third.nodes.map((n) => n['name']), ['VK-2', 'VK-1', 'Other']);
      // c's SNI changed: same server, one candidate each side -> same id, nothing gone
      final c2 = hy('sni=c2.example', 'Other');
      final fourth = mergeUpdate(first.nodes, [], [a, b, c2]);
      expect(fourth.nodes.map((n) => n['id']), ids);
      expect(fourth.gone, isEmpty);
    });

    test('a node returning from gone keeps its id and number', () {
      final a = hy('sni=a.example'), b = hy('sni=b.example'), c = hy('sni=c.example', 'Other');
      final first = mergeUpdate([], [], [a, b, c]);
      expect(first.nodes.map((n) => n['name']), ['VK-1', 'VK-2', 'Other']);
      final bId = first.nodes[1]['id'];

      // b drops out: gone, a is the only VK left so it loses its number.
      final dropped = mergeUpdate(first.nodes, [], [a, c]);
      expect(dropped.nodes.map((n) => n['name']), ['VK', 'Other']);
      expect(dropped.gone.single['id'], bId);

      // b comes back: same id, same number, nothing left in gone.
      final back = mergeUpdate(dropped.nodes, dropped.gone, [a, b, c]);
      expect(back.gone, isEmpty);
      expect(back.nodes.map((n) => n['id']), [first.nodes[0]['id'], bId, first.nodes[2]['id']]);
      expect(back.nodes.map((n) => n['name']), ['VK-1', 'VK-2', 'Other']);
    });

    test('two variants of one server changing at once is ambiguous: new ids, old ones gone', () {
      final a1 = hy('sni=q1.example'), a2 = hy('sni=q2.example');
      final first = mergeUpdate([], [], [a1, a2]);
      final oldIds = first.nodes.map((n) => n['id']).toSet();

      final a3 = hy('sni=q3.example'), a4 = hy('sni=q4.example');
      final second = mergeUpdate(first.nodes, [], [a3, a4]);

      expect(second.nodes.map((n) => n['id']), [a3.key, a4.key]);
      expect(second.nodes.any((n) => oldIds.contains(n['id'])), isFalse);
      expect(second.gone.map((n) => n['id']).toSet(), oldIds);
    });

    test('legacy prev nodes (id only, no key/base) do not crash; a single variant keeps its old id', () {
      final f = hy('sni=legacy.example');
      // Before key/base existed, id was the base (protocol|address|port|identity) hash.
      final legacy = {'id': f.base, 'name': 'VK', 'flag': f.flag, 'protocol': f.protocol, 'address': f.address, 'outbound': f.outbound};
      final merged = mergeUpdate([legacy], [], [f]);
      expect(merged.nodes.single['id'], f.base);
      expect(merged.gone, isEmpty);
    });
  });

  test('protocol words leave server names, Reality gets its own badge', () {
    expect(stripProtocol('VLESS RU-SPB ➡️ Нидерланды'), 'RU-SPB ➡️ Нидерланды');
    expect(stripProtocol('HY2 RU-SPB'), 'RU-SPB');
    expect(stripProtocol('NL | Hysteria2 | Reality'), 'NL');
    expect(stripProtocol('Frankfurt (VMess) 01'), 'Frankfurt 01');
    expect(stripProtocol('[Trojan] Tokyo'), 'Tokyo');
    expect(stripProtocol('Vlessland'), 'Vlessland'); // not a whole word
    expect(stripProtocol('VLESS'), 'VLESS'); // nothing would be left
    expect(protoLabel('vless', {'tls': {'enabled': true, 'reality': {'enabled': true}}}), 'reality');
    expect(protoLabel('vless', {'tls': {'enabled': true}}), 'vless');
  });
}
