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

    // A fake svc-in: one HTTP proxy that answers by the login (the path id) of Proxy-Authorization, as sing-box's
    // auth_user does. [byLogin] has the behaviour of each path; [logins] the paths asked, in order.
    final logins = <String>[];
    final dropped = <HttpRequest>{};
    FutureOr<void> Function(HttpRequest) drop() => (req) {
          dropped.add(req);
          req.response.detachSocket().then((s) => s.destroy());
        };
    Future<ServiceFetch> fakeSvc(Map<String, FutureOr<void> Function(HttpRequest req)> byLogin, {String? url}) async {
      logins.clear();
      pr = await Provider.start((_) {}); // (the group's tearDown closes it)
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final auth = req.headers.value('proxy-authorization') ?? '';
        final login = utf8.decode(base64.decode(auth.substring(6))).split(':').first;
        logins.add(login);
        final b = byLogin[login];
        if (b == null) {
          req.response.detachSocket().then((s) => s.destroy());
          return;
        }
        await b(req);
        if (!dropped.remove(req)) await req.response.close();
      });
      final ids = byLogin.keys.toList();
      final svcIn = SvcIn(server.port, 'sec', [
        for (final id in ids) SvcPath(id, id == 'direct' ? SvcKind.direct : (id == 'main' ? SvcKind.main : SvcKind.route), 'tag-$id', id),
      ]);
      return ServiceFetch(endpoint: () => svcIn, tieGrace: const Duration(milliseconds: 300), collectGrace: const Duration(milliseconds: 800));
    }

    FutureOr<void> Function(HttpRequest) body(String links, {Duration delay = Duration.zero, Map<String, String> headers = const {}}) => (req) async {
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          headers.forEach(req.response.headers.set);
          req.response.write(_b64(links));
        };
    const dead = 'http://sub.test/sub';

    test('Download via: three options, the old Direct first / Proxy first and a missing value are Auto', () {
      expect(Channel.values, [Channel.auto, Channel.proxy, Channel.direct]);
      for (final old in ['Direct first', 'Proxy first', 'Auto', null, '']) {
        expect(Channel.of(old), Channel.auto, reason: '$old');
      }
      expect(Channel.of('Proxy'), Channel.proxy);
      expect(Channel.of('Direct'), Channel.direct);
    });

    test('Proxy never uses the direct path; with no tunnel it has no way (noPath)', () async {
      final svc = await fakeSvc({'direct': body(_b64(ssSip002)), 'main': body(ssSip002), 'route0': body(ssSip002)});
      final r = await fetchSubscription(dead, userAgent: 'sing-box', channel: Channel.proxy, svc: svc);
      expect([r.via, r.nodes.length], ['proxy', 1]);
      expect(logins, isNot(contains('direct')));
      // a tunnel that fails does not fall back to direct
      final broken = await fakeSvc({'direct': body(ssSip002), 'main': drop()});
      await expectLater(
          fetchSubscription(dead, userAgent: 'sing-box', channel: Channel.proxy, svc: broken), throwsA(isA<SubscriptionFetchException>()));
      expect(logins, isNot(contains('direct')));
      // no sing-box: only the plain direct socket exists, which Proxy must not use
      final err = await fetchSubscription(dead, userAgent: 'sing-box', channel: Channel.proxy).then<Object>((_) => 'ok', onError: (Object e) => e);
      expect(err, isA<SubscriptionFetchException>().having((e) => e.failure.code, 'code', 'noPath'));
    });

    test('Direct asks the direct path only', () async {
      final svc = await fakeSvc({'direct': body(ssSip002), 'main': body(ssSip002)});
      final r = await fetchSubscription(dead, userAgent: 'sing-box', channel: Channel.direct, svc: svc);
      expect([r.via, r.nodes.length, logins.toSet()], ['direct', 1, {'direct'}]);
    });

    test('Auto: one request over both sides; a tie goes to the tunnel; direct alone works when the tunnel fails', () async {
      final svc = await fakeSvc({'direct': body(ssSip002), 'main': body(ssSip002)});
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc);
      expect(logins.toSet(), {'direct', 'main'});
      expect(r.via, 'proxy');
      final noTunnel = await fakeSvc({'direct': body(ssSip002)});
      expect((await fetchSubscription(dead, userAgent: 'sing-box', svc: noTunnel)).via, 'direct');
    });

    test('Auto: two copies with different sets of servers are journaled once with the difference; no word on freshness merges them', () async {
      final tunnelLinks = '$ssSip002\n$ss2022';
      final svc = await fakeSvc({'direct': body(ssSip002), 'main': body(tunnelLinks, delay: const Duration(milliseconds: 100))});
      final told = <Map<String, dynamic>>[];
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: told.add);
      expect(r.nodes.length, 2); // the union (here the tunnel's list holds the direct one)
      expect(told, hasLength(1));
      final d = told.single;
      expect([d['directNodes'], d['tunnelNodes'], d['onlyDirect'], d['onlyDirectCount'], d['onlyTunnelCount']], [1, 2, isEmpty, 0, 1]);
      expect(d['onlyTunnel'], hasLength(1));
      expect([d['directStatus'], d['tunnelStatus'], d['used'], d['why'], d['usedNodes'], d['directPath'], d['tunnelPath']],
          [200, 200, 'merged', 'unknown', 2, 'direct', 'main']);
      expect(d['directMs'], isA<int>());
      expect(d['tunnelMs'], greaterThanOrEqualTo(100));
      // the same body on both sides says nothing
      final same = await fakeSvc({'direct': body(ssSip002), 'main': body(ssSip002)});
      told.clear();
      await fetchSubscription(dead, userAgent: 'sing-box', svc: same, onDiverged: told.add);
      expect(told, isEmpty);
    });

    test('Auto: the same servers in another order or other bytes are the same answer, no event', () async {
      final svc = await fakeSvc({'direct': body('$ssSip002\n$ss2022'), 'main': body('$ss2022\n\n$ssSip002\n')});
      final told = <Map<String, dynamic>>[];
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: told.add);
      expect([r.nodes.length, r.via, told], [2, 'proxy', isEmpty]);
    });

    // direct: ssSip002 + trojanGrpc, tunnel: ssSip002 + ss2022 (one shared server, one of its own on each side)
    final directLinks = '$ssSip002\n$trojanGrpc', tunnelLinks = '$ssSip002\n$ss2022';
    String names(SubscriptionResult r) => r.nodes.map((n) => n.address).join(' ');

    Future<(SubscriptionResult, Map<String, dynamic>)> diverge(Map<String, String> direct, Map<String, String> tunnel) async {
      final svc = await fakeSvc({
        'direct': body(directLinks, headers: direct),
        'main': body(tunnelLinks, headers: tunnel, delay: const Duration(milliseconds: 100)),
      });
      final told = <Map<String, dynamic>>[];
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: told.add);
      expect(told, hasLength(1));
      return (r, told.single);
    }

    test('Auto: the copy with the later Last-Modified is used (either side), the freshness headers of both go to the event', () async {
      final (r, d) = await diverge({
        'last-modified': 'Thu, 15 Oct 2026 10:00:05 GMT',
        'etag': '"d1"',
        'cache-control': 'max-age=300',
        'date': 'Thu, 15 Oct 2026 10:01:00 GMT',
      }, {
        'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT',
        'etag': '"t1"',
      });
      expect(names(r), '192.0.2.10 se1.example');
      expect([d['used'], d['why'], d['usedNodes'], r.via], ['direct', 'newer: lastModified', 2, 'direct']);
      expect(d['directFresh'], containsPair('Last-Modified', 'Thu, 15 Oct 2026 10:00:05 GMT'));
      expect(d['directFresh'], containsPair('ETag', '"d1"'));
      expect(d['directFresh'], containsPair('Cache-Control', 'max-age=300'));
      expect(d['directFresh'], containsPair('Date', 'Thu, 15 Oct 2026 10:01:00 GMT'));
      expect(d['tunnelFresh'], containsPair('Last-Modified', 'Thu, 15 Oct 2026 10:00:00 GMT'));
      expect(d['tunnelFresh'], isNot(contains('Cache-Control')));
      // the other way round: a one-second difference is enough (the header counts whole seconds)
      final (r2, d2) = await diverge({'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT'}, {'last-modified': 'Thu, 15 Oct 2026 10:00:01 GMT'});
      expect(names(r2), '192.0.2.10 192.0.2.11');
      expect([d2['used'], d2['why']], ['tunnel', 'newer: lastModified']);
    });

    test('Auto: with no Last-Modified on both, the moment a copy left the origin (Date - Age) decides', () async {
      // direct: left the origin at 10:00:00, tunnel at 10:00:50 (Date 10:01:00, Age 10)
      final (r, d) = await diverge({'date': 'Thu, 15 Oct 2026 10:01:40 GMT', 'age': '100'}, {'date': 'Thu, 15 Oct 2026 10:01:00 GMT', 'age': '10'});
      expect(names(r), '192.0.2.10 192.0.2.11');
      expect([d['used'], d['why']], ['tunnel', 'newer: age']);
      expect(d['directFresh'], containsPair('Age', '100'));
      // no Age = 0: direct is the fresh one
      final (r2, d2) = await diverge({'date': 'Thu, 15 Oct 2026 10:01:00 GMT'}, {'date': 'Thu, 15 Oct 2026 10:01:00 GMT', 'age': '30'});
      expect(names(r2), '192.0.2.10 se1.example');
      expect([d2['used'], d2['why']], ['direct', 'newer: age']);
      // Last-Modified on one side only does not count: Date - Age is used
      final (_, d3) = await diverge({'last-modified': 'Thu, 15 Oct 2026 12:00:00 GMT', 'date': 'Thu, 15 Oct 2026 10:00:00 GMT', 'age': '60'},
          {'date': 'Thu, 15 Oct 2026 10:00:00 GMT'});
      expect([d3['used'], d3['why']], ['tunnel', 'newer: age']);
    });

    test('Auto: copies that cannot be told apart by freshness are merged: the tunnel servers first, then the direct-only ones, once each', () async {
      for (final (direct, tunnel) in [
        (<String, String>{}, <String, String>{}), // no freshness headers at all
        // the same Last-Modified: the same version, the gap of the fetch times says nothing
        ({'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT', 'age': '500'}, {'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT'}),
        // under the margin of 2 s
        ({'date': 'Thu, 15 Oct 2026 10:00:01 GMT'}, {'date': 'Thu, 15 Oct 2026 10:00:00 GMT'}),
        ({'date': 'Thu, 15 Oct 2026 10:00:00 GMT', 'age': '1'}, {'date': 'Thu, 15 Oct 2026 10:00:00 GMT'}),
        // Age that is no number of seconds
        ({'date': 'Thu, 15 Oct 2026 10:00:00 GMT', 'age': 'soon'}, {'date': 'Thu, 15 Oct 2026 10:05:00 GMT'}),
      ]) {
        final (r, d) = await diverge(direct, tunnel);
        expect(names(r), '192.0.2.10 192.0.2.11 se1.example', reason: '$direct / $tunnel'); // shared server once
        expect([d['used'], d['why'], d['usedNodes'], d['directNodes'], d['tunnelNodes']], ['merged', 'unknown', 3, 2, 2], reason: '$direct / $tunnel');
        expect([d['onlyDirectCount'], d['onlyTunnelCount']], [1, 1]);
      }
    });

    test('Auto: after a divergence the validators are not kept, so the next request is a full one', () async {
      final svc = await fakeSvc({
        'direct': body(directLinks, headers: {'etag': '"d"', 'last-modified': 'Thu, 15 Oct 2026 10:00:05 GMT'}),
        'main': body(tunnelLinks, headers: {'etag': '"t"', 'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT'}, delay: const Duration(milliseconds: 100)),
      });
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: (_) {});
      expect(r.strategy.single, isNot(contains('etag')));
      expect(r.strategy.single, isNot(contains('lastModified')));
      // the same set on both sides keeps them
      final same = await fakeSvc({
        'direct': body(tunnelLinks, headers: {'etag': '"x"'}),
        'main': body('$ss2022\n$ssSip002', headers: {'etag': '"x"'}, delay: const Duration(milliseconds: 100)),
      });
      expect((await fetchSubscription(dead, userAgent: 'sing-box', svc: same)).strategy.single['etag'], '"x"');
    });

    test('Auto discovery asks every UA over both sides: one event per UA with its own ua, the applied list is what they say was used', () async {
      Future<(SubscriptionResult, List<Map<String, dynamic>>)> discover(Map<String, String> direct, Map<String, String> tunnel) async {
        final svc = await fakeSvc({
          'direct': body(directLinks, headers: direct),
          'main': body(tunnelLinks, headers: tunnel, delay: const Duration(milliseconds: 100)),
        });
        final told = <Map<String, dynamic>>[];
        final r = await fetchSubscription(dead, svc: svc, onDiverged: told.add); // Auto UA: discovery
        return (r, told);
      }

      // nothing says which is newer: each UA's copy is the merge, so is the applied list
      var (r, told) = await discover({}, {});
      expect({for (final d in told) d['ua']}, discoveryAgents.toSet());
      expect(told.every((d) => d['used'] == 'merged'), isTrue);
      expect(names(r), '192.0.2.10 192.0.2.11 se1.example');
      // the tunnel is newer for every UA: its copy is applied, the direct-only server does not come in
      (r, told) = await discover({'last-modified': 'Thu, 15 Oct 2026 10:00:00 GMT'}, {'last-modified': 'Thu, 15 Oct 2026 10:00:09 GMT'});
      expect(told, hasLength(discoveryAgents.length));
      expect(told.every((d) => d['used'] == 'tunnel'), isTrue);
      expect(names(r), '192.0.2.10 192.0.2.11');
      // the other UAs brought nothing new, so the strategy keeps one of them
      expect(r.strategy, hasLength(1));
    });

    test('copyFreshness: Last-Modified first, then Date - Age; what is missing or garbled is unknown', () {
      Map<String, String> h(String? lm, String? date, [String? age]) =>
          {'last-modified': ?lm, 'date': ?date, 'age': ?age};
      const t0 = 'Thu, 15 Oct 2026 10:00:00 GMT', t1 = 'Thu, 15 Oct 2026 10:00:01 GMT', t2 = 'Thu, 15 Oct 2026 10:00:02 GMT';
      expect(copyFreshness(h(t0, null), h(t1, null)), (tunnelNewer: true, why: 'newer: lastModified'));
      expect(copyFreshness(h(t1, null), h(t0, null)), (tunnelNewer: false, why: 'newer: lastModified'));
      expect(copyFreshness(h(t0, null), h(t0, null)).tunnelNewer, isNull);
      // 2 s apart is the margin of Date - Age; 1 s is not enough
      expect(copyFreshness(h(null, t0), h(null, t2)), (tunnelNewer: true, why: 'newer: age'));
      expect(copyFreshness(h(null, t2), h(null, t0)), (tunnelNewer: false, why: 'newer: age'));
      expect(copyFreshness(h(null, t0), h(null, t1)).why, 'unknown');
      expect(copyFreshness(h(null, t2, '5'), h(null, t2, '3')), (tunnelNewer: true, why: 'newer: age'));
      // no Date, a Date nobody can read, a negative or a non-numeric Age
      expect(copyFreshness(h(null, null), h(null, t2)).why, 'unknown');
      expect(copyFreshness(h(null, 'yesterday'), h(null, t2)).why, 'unknown');
      expect(copyFreshness(h(null, t2, '-5'), h(null, t0)).why, 'unknown');
      expect(copyFreshness(h(null, t2, '5, 7'), h(null, t0)).why, 'unknown');
      // an unreadable Last-Modified counts as missing
      expect(copyFreshness(h('soon', t0), h(t1, t2)), (tunnelNewer: true, why: 'newer: age'));
    });

    group('a copy older than the applied one', () {
      const lm0 = 'Thu, 15 Oct 2026 10:00:00 GMT', lm1 = 'Thu, 15 Oct 2026 10:00:10 GMT';
      final big = '$ssSip002\n$ss2022\n$trojanGrpc', small = ssSip002;

      // the answer of the direct side alone (the tunnel is down or late)
      Future<SubscriptionResult> fetchWith(String links, Map<String, String> headers, SubscriptionResult? applied,
          {String filter = '', bool rediscover = false, String? url}) async {
        final svc = await fakeSvc({'direct': body(links, headers: headers)});
        return fetchSubscription(url ?? dead,
            userAgent: 'sing-box', svc: svc, filter: filter, rediscover: rediscover, strategy: applied?.strategy ?? const []);
      }

      test('is left out: nothing to apply, a notModified answer with both moments and the UA', () async {
        final first = await fetchWith(big, {'last-modified': lm1}, null);
        expect(first.nodes, hasLength(3));
        expect(first.strategy.single['fresh'], {'lastModified': DateTime.utc(2026, 10, 15, 10, 0, 10).millisecondsSinceEpoch});
        final r = await fetchWith(small, {'last-modified': lm0}, first);
        expect([r.notModified, r.nodes, r.hasUserInfo], [true, isEmpty, false]);
        expect(r.stale, {
          'ua': 'sing-box/1.14.2',
          'why': 'older: lastModified',
          'applied': {'lastModified': '2026-10-15T10:00:10.000Z'},
          'received': {'lastModified': '2026-10-15T10:00:00.000Z'},
          'nodes': 1,
        });
      });

      test('newer, equal and unknown are applied (unknown remembers nothing)', () async {
        final first = await fetchWith(big, {'last-modified': lm1}, null);
        for (final h in [
          {'last-modified': 'Thu, 15 Oct 2026 10:00:20 GMT'}, // newer
          {'last-modified': lm1}, // the same version
          <String, String>{}, // no way to tell (the test server adds a Date, but no Last-Modified to compare)
        ]) {
          final r = await fetchWith(small, h, first);
          expect([r.stale, r.nodes.length], [isNull, 1], reason: '$h');
        }
        final none = await fetchWith(small, {'date': 'Thu, 15 Oct 2026 10:00:20 GMT'}, first);
        expect(none.strategy.single['fresh'], {'origin': DateTime.utc(2026, 10, 15, 10, 0, 20).millisecondsSinceEpoch});
      });

      test('Date - Age decides when Last-Modified is not on both, with the margin of 2 s', () async {
        final first = await fetchWith(big, {'date': 'Thu, 15 Oct 2026 10:01:00 GMT', 'age': '10'}, null); // left the origin 10:00:50
        expect((await fetchWith(small, {'date': 'Thu, 15 Oct 2026 10:01:30 GMT', 'age': '100'}, first)).stale?['why'], 'older: age'); // left it at 09:59:50
        expect((await fetchWith(small, {'date': 'Thu, 15 Oct 2026 10:01:00 GMT', 'age': '11'}, first)).stale, isNull); // 1 s: not clear
      });

      test('a manual reread, another filter and a source with no strategy (new address) compare with nothing', () async {
        final first = await fetchWith(big, {'last-modified': lm1}, null);
        expect((await fetchWith(small, {'last-modified': lm0}, first, rediscover: true)).stale, isNull);
        expect((await fetchWith(small, {'last-modified': lm0}, first, filter: '.')).stale, isNull);
        expect((await fetchWith(small, {'last-modified': lm0}, null)).stale, isNull);
        expect((await fetchWith(small, {'last-modified': lm0}, first)).stale, isNotNull);
      });

      test('two merged copies remember the later known moments', () async {
        final svc = await fakeSvc({
          'direct': body(directLinks, headers: {'last-modified': lm1, 'date': 'Thu, 15 Oct 2026 10:02:00 GMT'}),
          'main': body(tunnelLinks, headers: {'last-modified': lm1, 'date': 'Thu, 15 Oct 2026 10:03:00 GMT'}, delay: const Duration(milliseconds: 100)),
        });
        final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: (_) {});
        expect(r.strategy.single['fresh'], {
          'lastModified': DateTime.utc(2026, 10, 15, 10, 0, 10).millisecondsSinceEpoch,
          'origin': DateTime.utc(2026, 10, 15, 10, 3).millisecondsSinceEpoch,
        });
      });

      test('updateSubscription: the list and gone stay, only the time moves, the stale data goes up; the memory survives a reload of the state', () async {
        final dir = await Directory.systemTemp.createTemp('jorm-stale');
        addTearDown(() => dir.delete(recursive: true));
        var store = SnapshotStore(File(p.join(dir.path, 'ui-state.json')));
        final s = <String, dynamic>{'url': dead, 'name': 'Sub', 'userAgent': 'sing-box', 'nodes': [], 'gone': []};
        final t0 = DateTime(2026, 10, 15, 12);
        final a = await updateSubscription(s,
            svc: await fakeSvc({'direct': body(big, headers: {'last-modified': lm1})}), sid: 'src1', now: t0);
        expect(a, isNot(contains('stale')));
        s.addAll((a['patch'] as Map).cast<String, dynamic>());
        expect(s['nodes'], hasLength(3));
        // the state is written and read again (a restart): the memory is in the strategy
        await store.save({'sourcesData': {'src1': s}, 'sourceOrder': ['src1']});
        store = SnapshotStore(File(p.join(dir.path, 'ui-state.json')));
        final loaded = ((await store.read())!['sourcesData'] as Map)['src1'] as Map<String, dynamic>;
        final b = await updateSubscription(loaded,
            svc: await fakeSvc({'direct': body(small, headers: {'last-modified': lm0})}), sid: 'src1', now: t0.add(const Duration(hours: 12)));
        expect(b['notModified'], isTrue);
        expect((b['patch'] as Map).keys.toSet(), {'updatedAt'});
        expect(b['stale'], containsPair('source', 'src1'));
        expect(b['stale'], containsPair('name', 'Sub'));
        expect(b['stale'], containsPair('why', 'older: lastModified'));
      });
    });

    Future<void> oneSideFails(String side, FutureOr<void> Function(HttpRequest) bad, {required String why}) async {
      final other = side == 'main' ? 'direct' : 'main';
      final svc = await fakeSvc({side: bad, other: body('$ssSip002\n$ss2022', delay: const Duration(milliseconds: 150))});
      final told = <Map<String, dynamic>>[];
      final r = await fetchSubscription(dead, userAgent: 'sing-box', svc: svc, onDiverged: told.add);
      expect(r.nodes.length, 2, reason: '$side: $why');
      expect(r.via, other == 'main' ? 'proxy' : 'direct', reason: '$side: $why');
      expect(told, isEmpty, reason: '$side: $why');
    }

    FutureOr<void> Function(HttpRequest) status(int code) => (req) => req.response.statusCode = code;

    test('Auto: a side with an empty body is no answer, the other copy is used with no event (either side)', () async {
      for (final side in ['main', 'direct']) {
        await oneSideFails(side, (req) {}, why: 'empty');
      }
    });

    test('Auto: a side whose body has no servers is no answer, the other copy is used with no event', () async {
      for (final side in ['main', 'direct']) {
        await oneSideFails(side, body('this is not a subscription'), why: 'zero nodes');
      }
    });

    test('Auto: a side with an HTTP error is no answer, the other copy is used with no event', () async {
      for (final side in ['main', 'direct']) {
        await oneSideFails(side, status(403), why: 'HTTP 403');
      }
    });

    test('Auto: both sides empty is a failure as before', () async {
      final svc = await fakeSvc({'direct': (req) {}, 'main': (req) {}});
      await expectLater(fetchSubscription(dead, userAgent: 'sing-box', svc: svc), throwsA(isA<SubscriptionFetchException>()));
    });

    test('the retry count is per subscription', () async {
      final svc = await fakeSvc({'direct': drop()});
      for (final sid in ['a', 'a', 'b']) {
        await expectLater(fetchSubscription(dead, userAgent: 'sing-box', svc: svc, retryKey: sid, channel: Channel.direct),
            throwsA(isA<SubscriptionFetchException>()));
      }
      expect(svc.retryFor('subscription:a').failures, 2);
      expect(svc.retryFor('subscription:b').failures, 1);
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
