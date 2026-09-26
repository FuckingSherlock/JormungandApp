// Share links (share.dart) against the link parser, servers typed in by hand
// (manual.dart), the Logs tab's log book and the jormd routes behind them — on loopback,
// with no network: the daemon is never init()-ed (that would check the exit IP).
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

// The same server back from its own link: key (dedup), outbound, name and flag.
void _roundTrip(Node n) {
  final link = shareLinkOf(n);
  expect(link, isNotNull, reason: n.outbound.toString());
  final back = parseLink(link!);
  expect(back, isNotNull, reason: link);
  expect(back!.key, n.key, reason: link);
  expect(back.outbound, n.outbound, reason: link);
  expect([back.name, back.flag, back.protocol, back.address, back.port], [n.name, n.flag, n.protocol, n.address, n.port], reason: link);
}

const _uuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('share links', () {
    test('every sample link round-trips; an unsupported one has no link', () {
      for (final raw in allLinks) {
        final n = parseLink(raw)!;
        if (n.unsupported != null) {
          expect(shareLinkOf(n), isNull, reason: raw);
        } else {
          _roundTrip(n);
        }
      }
    });

    test('harder cases: IPv6, grpc + alpn + insecure, vmess over Reality, ss plugin, hy2 hop ranges, odd names', () {
      final links = [
        'vless://$_uuid@[2001:db8::1]:443?security=tls&sni=v6.example&alpn=h2,http%2F1.1&allowInsecure=1&type=grpc&serviceName=g#v6%20%23%201',
        'vless://$_uuid@h.example:443?security=tls&type=http&host=a.example,b.example&path=%2Fh2#H2',
        'vless://$_uuid@u.example:80?type=httpupgrade&host=u.example&path=%2Fup#Upgrade',
        'vmess://$_uuid@r.example:443?encryption=aes-128-gcm&security=reality&sni=www.apple.com&pbk=PBK&sid=ab&type=ws&path=%2Fv#VM%20Reality',
        'trojan://p%40ss%3Aw%2Fo%3Frd%23@t.example:443?type=ws&path=%2Ft%3Fed%3D2048&host=cdn.example&fp=firefox#%F0%9F%87%B8%F0%9F%87%AA%20100%25%20%2B%20more',
        'trojan://plain@t2.example:8080?security=none#No%20TLS',
        'ss://${base64.encode(utf8.encode('chacha20-ietf-poly1305:pw'))}@192.0.2.40:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com#Obfs',
        'hysteria2://pw@hop.example:443,20000-21000,30000?sni=off&up=50&down=200&alpn=h3#Hop',
        'tuic://$_uuid:p%3Aw@t.example:443?congestion_control=cubic&udp_relay_mode=quic&alpn=h3,spdy%2F3.1&allowInsecure=1&fp=safari#T',
        'anytls://a%20p@a.example:8443?sni=a.example&insecure=1&fp=chrome&alpn=h2#A',
      ];
      for (final raw in links) {
        final n = parseLink(raw);
        expect(n, isNotNull, reason: raw);
        _roundTrip(n!);
      }
    });

    test('Clash and sing-box subscription servers get links that dedup with them', () {
      final nodes = [...parseSubscription(clashYaml).$2, ...parseSubscription(singboxJson).$2];
      final linked = nodes.where((n) => shareLinkOf(n) != null).toList();
      expect(linked, isNotEmpty);
      for (final n in linked) {
        expect(parseLink(shareLinkOf(n)!)!.key, n.key, reason: shareLinkOf(n));
      }
    });

    test('no link form: http; socks round-trips with and without a login', () {
      expect(shareLink({'type': 'http', 'server': 'x.example', 'server_port': 8080}), isNull);
      for (final raw in ['socks5://u%40x:p%3Aw@192.0.2.9:1080#S', 'socks5://192.0.2.9:1080#S', 'socks4://u:@192.0.2.9:1080#S']) {
        _roundTrip(parseLink(raw)!);
      }
    });
  });

  group('manual servers', () {
    test('a fresh one is the server its plain link gives', () {
      final n = manualNode(protocol: 'vless', address: 'm.example', port: 443, secret: _uuid, name: 'Mine');
      expect(n.key, parseLink('vless://$_uuid@m.example:443?security=none#Mine')!.key);
      expect(n.name, 'Mine');
      final ss = manualNode(protocol: 'ss', address: '192.0.2.50', port: 8388, secret: 'aes-256-gcm:pw');
      expect([ss.outbound['method'], ss.outbound['password'], ss.name], ['aes-256-gcm', 'pw', '192.0.2.50:8388']);
      final t = manualNode(protocol: 'tuic', address: '[2001:db8::2]', port: 443, secret: '$_uuid:pw');
      expect([t.address, t.outbound['server'], t.outbound['password']], ['2001:db8::2', '2001:db8::2', 'pw']);
      final s = manualNode(protocol: 'socks', address: '127.0.0.1', port: 1080, secret: 'u:p');
      expect(s.outbound, {'type': 'socks', 'server': '127.0.0.1', 'server_port': 1080, 'version': '5', 'username': 'u', 'password': 'p'});
    });

    test('an edit keeps TLS and transport, changes address, port and secret; an empty secret keeps the old', () {
      final old = parseLink(vlessWs)!;
      final n = manualNode(protocol: 'vless', address: 'nl2.example', port: 2053, name: 'Moved', outbound: old.outbound);
      expect(n.outbound['transport'], old.outbound['transport']);
      expect(n.outbound['tls'], old.outbound['tls']);
      expect([n.outbound['server'], n.outbound['server_port'], n.outbound['uuid']], ['nl2.example', 2053, _uuid]);
      expect(n.key, isNot(old.key));
      expect(old.outbound['server'], 'nl1.example'); // the old map is not touched
      final other = manualNode(protocol: 'vless', address: 'nl2.example', port: 2053, secret: 'x-y', outbound: old.outbound);
      expect(other.outbound['uuid'], 'x-y');
      expect(other.key, isNot(n.key));
    });

    test('says what is missing', () {
      Matcher says(String m) => throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(m)));
      expect(() => manualNode(protocol: 'vless', address: '', port: 443, secret: 'x'), says('Address'));
      expect(() => manualNode(protocol: 'vless', address: 'a', port: 0, secret: 'x'), says('Port'));
      expect(() => manualNode(protocol: 'trojan', address: 'a', port: 443), says('Password'));
      expect(() => manualNode(protocol: 'ss', address: 'a', port: 443, secret: 'nocolon'), says('method:password'));
      expect(() => manualNode(protocol: 'wireguard', address: 'a', port: 443, secret: 'x'), says('Unknown protocol'));
    });
  });

  group('log book', () {
    test('sing-box lines lose their stamp and keep their level; the runtime\'s own lines are the core\'s', () {
      final b = LogBook()
        ..singBox('+0300 2026-09-26 14:02:11 WARN [123 0ms] dns: exchange failed')
        ..singBox('FATAL[0000] start service: bind: address already in use')
        ..singBox('plain line')
        ..singBox('[jormd] sing-box exited with code 1')
        ..note('info', 'Connected');
      final l = (b.since(null)['lines'] as List).cast<Map>();
      expect(l.map((x) => [x['src'], x['lvl'], x['msg']]), [
        ['sing-box', 'warn', '[123 0ms] dns: exchange failed'],
        ['sing-box', 'error', 'start service: bind: address already in use'],
        ['sing-box', 'info', 'plain line'],
        ['core', 'warn', 'sing-box exited with code 1'],
        ['core', 'info', 'Connected'],
      ]);
    });

    test('since, cap and clear', () {
      final b = LogBook(cap: 3);
      for (var i = 0; i < 5; i++) {
        b.note('info', 'l$i');
      }
      expect((b.since(null)['lines'] as List).map((x) => x['msg']), ['l2', 'l3', 'l4']);
      expect((b.since(4)['lines'] as List).map((x) => x['msg']), ['l4']);
      expect(b.since(4)['next'], 5);
      b.clear();
      b.note('info', 'after');
      expect(b.since(0)['lines'], [containsPair('n', 5)]);
    });
  });

  group('jormd routes', () {
    late HttpServer server;
    late Daemon d;
    late Directory tmp;
    final client = HttpClient();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jormd-test');
      d = Daemon(singBox: p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box'), dataDir: tmp.path, uiFile: 'none');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(d.handle);
    });
    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      req.headers.set('X-Jorm', '1');
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    }

    test('log: since, clear', () async {
      d.log.note('info', 'one');
      d.log.note('warn', 'two');
      final (_, all) = await call('GET', '/api/log');
      expect((all['lines'] as List).map((l) => l['msg']), ['one', 'two']);
      final (_, newer) = await call('GET', '/api/log?since=${all['next'] - 1}');
      expect((newer['lines'] as List).single['msg'], 'two');
      await call('DELETE', '/api/log');
      expect((await call('GET', '/api/log')).$2['lines'], isEmpty);
    });

    test('node: built from the form; a missing secret is a 400 with the message', () async {
      final (code, j) = await call('POST', '/api/node', {'protocol': 'hy2', 'address': 'h.example', 'port': '443', 'secret': 'pw', 'name': 'H'});
      expect(code, 200);
      expect(j['node']['outbound']['type'], 'hysteria2');
      final (bad, e) = await call('POST', '/api/node', {'protocol': 'trojan', 'address': 'h.example', 'port': '443'});
      expect([bad, e['error']], [400, 'Password is required']);
    });

    test('share: the link of a node; none for http', () async {
      final n = parseLink(anytls)!;
      final (_, j) = await call('POST', '/api/share', {'outbound': n.outbound, 'name': n.name, 'flag': n.flag});
      expect(parseLink(j['link'] as String)!.key, n.key);
      expect((await call('POST', '/api/share', {'outbound': {'type': 'http', 'server': 'a', 'server_port': 1}})).$2['link'], isNull);
    });

    test('version and connections without a tunnel', () async {
      final (_, v) = await call('GET', '/api/version');
      expect([v['core'], v['dataDir']], [coreVersion, tmp.path]);
      expect((await call('DELETE', '/api/connections')).$2, {'ok': false});
      expect((await call('DELETE', '/api/connections/abc')).$2, {'ok': false});
    });
  });
}
