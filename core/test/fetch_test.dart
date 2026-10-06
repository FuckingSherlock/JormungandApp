// Subscription fetching against a fake provider on loopback: UA discovery and strategy,
// ETag / 304, headers, HWID, filter, channels. Nothing leaves the machine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

/// A provider: [on] answers each request; [seen] keeps every request's headers in order.
class Provider {
  Provider._(this._server, this.on);
  final HttpServer _server;
  FutureOr<void> Function(HttpRequest req) on;
  final seen = <HttpHeaders>[];

  static Future<Provider> start(FutureOr<void> Function(HttpRequest req) on) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pr = Provider._(s, on);
    s.listen((req) async {
      pr.seen.add(req.headers);
      try {
        await pr.on(req);
      } catch (e) {
        stderr.writeln('provider: $e');
        req.response.statusCode = 500;
      }
      await req.response.close();
    });
    return pr;
  }

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port/sub';
  List<String> get uas => [for (final h in seen) h.value('user-agent')!];
  List<String?> get etags => [for (final h in seen) h.value('if-none-match')];
  Future<void> close() => _server.close(force: true);
}

String _b64(String s) => base64.encode(utf8.encode(s));

/// sing-box UA → sing-box JSON (the Frankfurt server); mihomo / ClashMeta → Clash YAML
/// (Frankfurt again + three more). ETag per format; [notModified] answers a matching
/// If-None-Match with 304.
Future<void> byUa(HttpRequest req, {bool notModified = true, Map<String, String> headers = const {}}) async {
  final ua = req.headers.value('user-agent') ?? '';
  final sb = ua.startsWith('sing-box');
  final etag = sb ? '"sb1"' : '"cl1"';
  headers.forEach(req.response.headers.set);
  if (notModified && req.headers.value('if-none-match') == etag) {
    req.response.statusCode = 304;
    return;
  }
  req.response.headers.set('etag', etag);
  req.response.write(sb ? singboxJson : clashYaml);
}

void main() {
  late Provider pr;
  tearDown(() => pr.close());

  group('UA strategy', () {
    test('discovery asks every UA, keeps those that brought new servers', () async {
      pr = await Provider.start(byUa);
      final r = await fetchSubscription(pr.url);
      expect(pr.uas.toSet(), discoveryAgents.toSet());
      expect([for (final e in r.strategy) e['ua']], ['sing-box/1.14.2', 'mihomo/1.19.28']);
      expect([for (final e in r.strategy) e['unique']], [1, 3]);
      expect([for (final e in r.strategy) e['etag']], ['"sb1"', '"cl1"']);
      expect(r.nodes, hasLength(4));
      expect(r.total, 4);
      expect(r.format, 'sing-box');
      expect(r.discoveredAt, closeTo(DateTime.now().millisecondsSinceEpoch, 5000));
    });

    test('an update asks only the strategy UAs, with ETags; all 304 = not modified', () async {
      pr = await Provider.start((req) => byUa(req, headers: {'subscription-userinfo': 'upload=1e9; download=2e9; total=1e10; expire=0'}));
      final first = await fetchSubscription(pr.url);
      pr.seen.clear();
      final r = await fetchSubscription(pr.url, strategy: first.strategy, discoveredAt: first.discoveredAt, prevCount: 4);
      expect(pr.uas, ['sing-box/1.14.2', 'mihomo/1.19.28']);
      expect(pr.etags, ['"sb1"', '"cl1"']);
      expect(r.notModified, isTrue);
      expect(r.strategy, first.strategy);
      // usage and expiry are read from the 304 too
      expect([r.hasUserInfo, r.usedGb, r.totalGb, r.expire], [true, 3.0, 10.0, null]);
    });

    test('mixed 304: a UA that said 304 is asked again in full', () async {
      // mihomo's answer changed (no 304), sing-box's did not
      pr = await Provider.start((req) => byUa(req, notModified: req.headers.value('user-agent')!.startsWith('sing-box')));
      final first = await fetchSubscription(pr.url);
      pr.seen.clear();
      final r = await fetchSubscription(pr.url, strategy: first.strategy, discoveredAt: first.discoveredAt);
      expect(r.notModified, isFalse);
      expect(r.nodes, hasLength(4));
      expect(pr.uas.where((u) => u.startsWith('sing-box')), hasLength(2));
      expect(pr.etags.last, isNull);
    });

    test('rediscover asks every UA again, unconditionally', () async {
      pr = await Provider.start(byUa);
      final first = await fetchSubscription(pr.url);
      pr.seen.clear();
      final r = await fetchSubscription(pr.url, strategy: first.strategy, discoveredAt: first.discoveredAt, rediscover: true);
      expect(pr.uas.toSet(), discoveryAgents.toSet());
      expect(pr.etags.every((e) => e == null), isTrue);
      expect(r.notModified, isFalse);
    });

    test('a list that shrank by more than 20% triggers discovery', () async {
      pr = await Provider.start(byUa);
      final first = await fetchSubscription(pr.url);
      pr.on = (req) => req.response.write(singboxJson); // every UA now gets one server
      pr.seen.clear();
      await fetchSubscription(pr.url, strategy: first.strategy, discoveredAt: first.discoveredAt, prevCount: 4);
      expect(pr.uas.toSet(), discoveryAgents.toSet());
    });

    test('an explicit UA is the only one asked; the v2ray chip sends v2rayN', () async {
      pr = await Provider.start(byUa);
      final r = await fetchSubscription(pr.url, userAgent: 'mihomo');
      expect(pr.uas, ['mihomo/1.19.28']);
      expect(r.format, 'clash');
      expect(r.nodes, hasLength(4));
      pr.seen.clear();
      pr.on = (req) => req.response.write(_b64(allLinks.join('\n')));
      final v = await fetchSubscription(pr.url, userAgent: 'v2ray');
      expect(pr.uas, ['v2rayN/7.0']);
      expect(v.format, 'base64');
    });
  });

  group('headers', () {
    test('subscription-userinfo: decimal and e-notation', () {
      final i = userInfo('upload=1.5e9; download=500000000.0; total=1.0E11; expire=1798761600')!;
      expect([i.used, i.total, i.expire], [2.0, 100.0, '2027-01-01']);
      expect(userInfo('expire=1798761600000')!.expire, '2027-01-01'); // milliseconds
      expect(userInfo(null), isNull);
      expect(userInfo('garbage'), isNull);
    });

    test('title: profile-title (base64 or raw UTF-8), else the content-disposition file name', () async {
      var title = 'base64:${_b64('Мой VPN')}';
      String? disposition;
      pr = await Provider.start((req) {
        req.response.headers.set('profile-title', title);
        if (disposition != null) req.response.headers.set('content-disposition', disposition);
        req.response.write(singboxJson);
      });
      expect((await fetchSubscription(pr.url, userAgent: 'sing-box')).title, 'Мой VPN');
      // raw UTF-8 bytes on the wire (dart:io reads them as Latin-1; its server will not send them)
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(raw.close);
      raw.listen((sock) {
        sock.listen((_) {
          final body = utf8.encode(singboxJson);
          sock.add([
            ...ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\nprofile-title: '),
            ...utf8.encode('Мой VPN'),
            ...ascii.encode('\r\n\r\n'),
            ...body,
          ]);
          sock.close();
        });
      });
      expect((await fetchSubscription('http://127.0.0.1:${raw.port}/sub', userAgent: 'sing-box')).title, 'Мой VPN');
      title = '';
      disposition = "attachment; filename*=UTF-8''%D0%9C%D0%BE%D0%B9%20VPN.yaml";
      expect((await fetchSubscription(pr.url, userAgent: 'sing-box')).title, 'Мой VPN');
      disposition = 'attachment; filename="Work.json"';
      expect((await fetchSubscription(pr.url, userAgent: 'sing-box')).title, 'Work');
    });

    test('interval, support / web page links, announce', () async {
      pr = await Provider.start((req) {
        req.response.headers
          ..set('profile-update-interval', '6')
          ..set('support-url', 'https://t.me/support_bot')
          ..set('profile-web-page-url', 'javascript:alert(1)')
          ..set('announce', 'base64:${_b64('Maintenance tonight')}')
          ..set('content-type', 'application/json; charset=utf-8');
        req.response.write(singboxJson);
      });
      final r = await fetchSubscription(pr.url, userAgent: 'sing-box');
      expect([r.updateHours, r.supportUrl, r.webPage, r.announce], [6.0, 'https://t.me/support_bot', null, 'Maintenance tonight']);
    });

    test('HWID: device headers only when the source has it on; the id is stable', () async {
      final dir = await Directory.systemTemp.createTemp('jorm-hwid');
      addTearDown(() => dir.delete(recursive: true));
      final hw = await deviceHeaders(dir.path);
      expect(hw.keys, ['x-hwid', 'x-device-os', 'x-ver-os', 'x-device-model']);
      expect(hw['x-hwid'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect((await deviceHeaders(dir.path))['x-hwid'], hw['x-hwid']);
      expect(File(p.join(dir.path, 'device.json')).existsSync(), isTrue);

      pr = await Provider.start((req) => req.response.write(singboxJson));
      final s = {'url': pr.url, 'userAgent': 'sing-box', 'hwid': true};
      await updateSubscription(s, hwid: hw);
      expect(pr.seen.last.value('x-hwid'), hw['x-hwid']);
      expect(pr.seen.last.value('x-device-os'), hw['x-device-os']);
      await updateSubscription({...s, 'hwid': false}, hwid: hw);
      expect(pr.seen.last.value('x-hwid'), isNull);
    });
  });

  group('filter', () {
    test('keeps matching names (flag included); a changed filter reads in full', () async {
      pr = await Provider.start(byUa);
      final r = await fetchSubscription(pr.url, filter: '🇩🇪|obfs');
      expect(r.nodes.map((n) => n.name).toSet(), {'Frankfurt 01', 'obfs'});
      expect(r.total, 4);
      expect(r.strategy.every((e) => e['filter'] == '🇩🇪|obfs'), isTrue);
      pr.seen.clear();
      // same filter: conditional; another filter: no ETag sent, the list is read again
      expect((await fetchSubscription(pr.url, filter: '🇩🇪|obfs', strategy: r.strategy, discoveredAt: r.discoveredAt)).notModified, isTrue);
      pr.seen.clear();
      final other = await fetchSubscription(pr.url, filter: 'Frankfurt', strategy: r.strategy, discoveredAt: r.discoveredAt);
      expect(pr.etags.every((e) => e == null), isTrue);
      expect(other.nodes.map((n) => n.name), ['Frankfurt 01']);
    });

    test('a bad expression or nothing matching is an error, not an empty source', () async {
      pr = await Provider.start(byUa);
      expect(fetchSubscription(pr.url, filter: '('), throwsA(isA<FormatException>()));
      expect(fetchSubscription(pr.url, filter: 'Nowhere'), throwsA(isA<FormatException>()));
    });
  });

  group('robustness and channels', () {
    test('a body over the cap and a stalled body fail', () async {
      pr = await Provider.start((req) async {
        if (req.uri.path == '/stall') {
          req.response.write('proxies:\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(seconds: 3));
          return;
        }
        req.response.write('x' * 5000);
      });
      expect(fetchSubscription(pr.url, userAgent: 'sing-box', maxBytes: 1000), throwsA(isA<HttpException>()));
      expect(fetchSubscription('http://127.0.0.1:${pr.port}/stall', userAgent: 'sing-box', timeout: const Duration(milliseconds: 500)),
          throwsA(isA<TimeoutException>()));
    });

    test('Direct first falls back to the tunnel; with no tunnel everything goes direct', () async {
      // the provider is unreachable directly (closed port); the "tunnel" is an HTTP proxy
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadUrl = 'http://127.0.0.1:${closed.port}/sub';
      await closed.close();
      pr = await Provider.start((req) {
        expect(req.uri.toString(), deadUrl); // the proxy got the absolute URL
        req.response.write(_b64(ssSip002));
      });
      final r = await fetchSubscription(deadUrl, userAgent: 'sing-box', channel: Channel.directFirst, proxyPort: pr.port);
      expect([r.via, r.nodes.length], ['proxy', 1]);
      final viaProxy = await fetchSubscription(deadUrl, userAgent: 'sing-box', channel: Channel.proxy, proxyPort: pr.port);
      expect(viaProxy.via, 'proxy');
      expect(fetchSubscription(deadUrl, userAgent: 'sing-box', channel: Channel.direct, proxyPort: pr.port), throwsA(isA<SocketException>()));
      expect(fetchSubscription(deadUrl, userAgent: 'sing-box', channel: Channel.proxy), throwsA(isA<SocketException>()));
      expect(Channel.of('Proxy first'), Channel.proxyFirst);
      expect(Channel.of(null), Channel.directFirst);
    });
  });

  group('updateSubscription', () {
    test('a full answer patches the server fields; a 304 only the time and usage', () async {
      pr = await Provider.start((req) => byUa(req, headers: {
            'subscription-userinfo': 'upload=0; download=1e9; total=0; expire=1798761600',
            'announce': 'Hello',
          }));
      final s = <String, dynamic>{'url': pr.url, 'userAgent': 'Auto', 'nodes': [], 'gone': []};
      final t0 = DateTime(2026, 9, 1);
      final a = await updateSubscription(s, now: t0);
      final patch = a['patch'] as Map<String, dynamic>;
      expect(patch.keys.toSet().difference(sourceServerFields.toSet()), isEmpty);
      expect([patch['count'], patch['format'], patch['announce'], patch['expire'], patch['updatedAt']],
          [4, 'sing-box', 'Hello', '2027-01-01', t0.millisecondsSinceEpoch]);
      expect(patch['usage'], {'used': 1.0, 'total': 0.0});
      s.addAll(patch);
      final b = await updateSubscription(s, now: t0.add(const Duration(hours: 1)));
      expect(b['notModified'], isTrue);
      expect((b['patch'] as Map).keys.toSet(), {'updatedAt', 'usage', 'expire', 'announce'});
    });

    group('filter and gone', () {
      String line(String host, String name) => 'ss://${_b64('aes-256-gcm:password')}@$host:8388#${Uri.encodeComponent(name)}';
      List<String> sent = [];
      Future<Map<String, dynamic>> run(Map<String, dynamic> s) async {
        final patch = (await updateSubscription(s, now: DateTime(2026, 9, 1)))['patch'] as Map<String, dynamic>;
        return patch;
      }

      test('servers the filter leaves out are not "removed by the provider"', () async {
        sent = [line('a.example', 'A-DE'), line('b.example', 'B-NL')];
        pr = await Provider.start((req) => req.response.write(_b64(sent.join('\n'))));
        final s = <String, dynamic>{'url': pr.url, 'userAgent': 'sing-box', 'nodes': [], 'gone': []};
        s.addAll(await run(s));
        expect(s['nodes'], hasLength(2));
        s['filter'] = 'DE';
        final p = await run(s);
        expect([for (final n in p['nodes'] as List) n['name']], ['A-DE']);
        expect(p['gone'], isEmpty);
      });

      test('a server the provider dropped is gone when the filter would keep it', () async {
        sent = [line('a.example', 'A-DE'), line('b.example', 'B-NL'), line('c.example', 'C-DE')];
        pr = await Provider.start((req) => req.response.write(_b64(sent.join('\n'))));
        final s = <String, dynamic>{'url': pr.url, 'userAgent': 'sing-box', 'nodes': [], 'gone': [], 'filter': ''};
        s.addAll(await run(s));
        s['filter'] = 'DE';
        sent = [line('b.example', 'B-NL'), line('c.example', 'C-DE')];
        final p = await run(s);
        expect([for (final n in p['nodes'] as List) n['name']], ['C-DE']);
        expect([for (final g in p['gone'] as List) g['name']], ['A-DE']);
      });
    });
  });
}
