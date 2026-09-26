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
      expect(n.name, 'VMess WS');
      expect(n.outbound['transport'], {'type': 'ws', 'path': '/vm', 'headers': {'Host': 'tr1.example'}});
      expect(n.outbound['tls']['server_name'], 'tr1.example');
    });

    test('every sample parses, unknown schemes do not', () {
      expect(allLinks.map(parseLink).whereType<Node>(), hasLength(allLinks.length));
      expect(parseLink('socks://x@y:1'), isNull);
      expect(parseLink('not a link'), isNull);
    });
  });

  group('subscriptions', () {
    test('base64 list', () {
      final (f, nodes) = parseSubscription(base64.encode(utf8.encode(allLinks.join('\n'))));
      expect(f, SubFormat.uriList);
      expect(nodes, hasLength(allLinks.length));
    });

    test('clash yaml: known types only', () {
      final (f, nodes) = parseSubscription(clashYaml);
      expect(f, SubFormat.clash);
      expect(nodes.map((n) => n.protocol), ['vless', 'hy2', 'ss']);
      expect(nodes[1].outbound['server_ports'], ['20000:21000']);
      expect(nodes[2].outbound['plugin_opts'], 'obfs=http;obfs-host=bing.com');
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
}
