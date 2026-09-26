// checkExitIp() talks to real geo-IP services through the tunnel; here it talks to a
// fake local HTTP proxy instead, so the race/merge/timeout logic runs with no network.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

ExitProbe _find(String name) => exitProbes.firstWhere((p) => p.name == name);

void main() {
  group('probe parsers', () {
    test('ipwho.is', () {
      final r = _find('ipwho.is').read(
        '{"success":true,"ip":"203.0.113.5","country_code":"DE","city":"Frankfurt","connection":{"org":"Hetzner Online GmbH"}}',
      );
      expect(r, {'ip': '203.0.113.5', 'country': 'DE', 'city': 'Frankfurt', 'org': 'Hetzner Online GmbH'});
    });

    test('ipwho.is failure answer has no ip', () {
      expect(_find('ipwho.is').read('{"success":false,"message":"reserved range"}'), isNull);
    });

    test('ipinfo.io strips the AS-number prefix from org', () {
      final r = _find('ipinfo.io').read(
        '{"ip":"203.0.113.6","country":"NL","city":"Amsterdam","org":"AS57043 HOSTKEY B.V."}',
      );
      expect(r, {'ip': '203.0.113.6', 'country': 'NL', 'city': 'Amsterdam', 'org': 'HOSTKEY B.V.'});
    });

    test('ip-api.com falls back from empty org to isp', () {
      final r = _find('ip-api.com').read(
        '{"status":"success","countryCode":"NL","city":"Amsterdam","isp":"X","org":"","query":"1.2.3.4"}',
      );
      expect(r, {'ip': '1.2.3.4', 'country': 'NL', 'city': 'Amsterdam', 'org': 'X'});
    });

    test('ip-api.com failure answer has no ip', () {
      expect(_find('ip-api.com').read('{"status":"fail","message":"private range"}'), isNull);
    });

    test('cloudflare trace', () {
      final r = _find('cloudflare').read('fl=1x1\nip=1.2.3.4\nts=1700000000\nloc=NL\ncolo=AMS\n');
      expect(r, {'ip': '1.2.3.4', 'country': 'NL'});
    });

    test('yandex, quoted ip', () {
      expect(_find('yandex').read('"1.2.3.4"'), {'ip': '1.2.3.4'});
    });

    test('amazon, bare ip', () {
      expect(_find('amazon').read('1.2.3.4\n'), {'ip': '1.2.3.4'});
    });

    test('ipip.net, ip embedded in Chinese text', () {
      expect(_find('ipip.net').read('当前 IP：1.2.3.4  来自于：荷兰 阿姆斯特丹 XX 运营商'), {'ip': '1.2.3.4'});
    });
  });

  group('race logic (fake proxy)', () {
    late HttpServer proxy;

    tearDown(() => proxy.close(force: true));

    // Test-only wire format for the fake probes: "ip|country|city|org", any part may be
    // empty; a body of exactly 'FAIL' means "no ip in the answer".
    Map<String, dynamic>? readCsv(String body) {
      if (body == 'FAIL') return null;
      final parts = body.split('|');
      String? v(int i) => i < parts.length && parts[i].isNotEmpty ? parts[i] : null;
      return {'ip': v(0), 'country': v(1), 'city': v(2), 'org': v(3)};
    }

    ExitProbe probe(String name) => (name: name, url: 'http://probe.test/$name', read: readCsv);

    Future<HttpServer> serve(Map<String, ({Duration delay, int status, String body})> answers) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        final a = answers[req.uri.path];
        if (a != null && a.delay > Duration.zero) await Future<void>.delayed(a.delay);
        req.response.statusCode = a?.status ?? 404;
        req.response.write(a?.body ?? '');
        await req.response.close();
      });
      return s;
    }

    test('a rich answer wins right away, without waiting for a slow probe', () async {
      proxy = await serve({
        '/fast': (delay: const Duration(milliseconds: 20), status: 200, body: '203.0.113.1|DE|Berlin|'),
        '/slow': (delay: const Duration(seconds: 5), status: 200, body: '203.0.113.2|NL|Amsterdam|'),
      });
      final sw = Stopwatch()..start();
      final r = await checkExitIp(
        proxy.port,
        probes: [probe('fast'), probe('slow')],
        timeout: const Duration(seconds: 3),
        grace: const Duration(milliseconds: 300),
      );
      sw.stop();
      expect(r['ip'], '203.0.113.1');
      expect(r['country'], 'DE');
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('an ip-only answer merges with a later rich answer for the same ip', () async {
      proxy = await serve({
        '/ipOnly': (delay: const Duration(milliseconds: 10), status: 200, body: '203.0.113.3|||HosterOrg'),
        '/rich': (delay: const Duration(milliseconds: 60), status: 200, body: '203.0.113.3|DE|Berlin|'),
      });
      final r = await checkExitIp(
        proxy.port,
        probes: [probe('ipOnly'), probe('rich')],
        timeout: const Duration(seconds: 3),
        grace: const Duration(milliseconds: 300),
      );
      expect(r['ip'], '203.0.113.3');
      expect(r['country'], 'DE');
      expect(r['city'], 'Berlin');
      expect(r['org'], 'HosterOrg'); // filled in from the ip-only answer
    });

    test('an ip-only answer alone comes back after grace, without a country', () async {
      // A second, still-pending probe is needed so the wait is actually grace, not the
      // "everyone has answered, nothing more can arrive" shortcut for a single probe.
      proxy = await serve({
        '/ipOnly': (delay: const Duration(milliseconds: 10), status: 200, body: '203.0.113.4|||'),
        '/pending': (delay: const Duration(seconds: 5), status: 200, body: '203.0.113.7|DE|Berlin|'),
      });
      final sw = Stopwatch()..start();
      final r = await checkExitIp(
        proxy.port,
        probes: [probe('ipOnly'), probe('pending')],
        timeout: const Duration(seconds: 3),
        grace: const Duration(milliseconds: 150),
      );
      sw.stop();
      expect(r['ip'], '203.0.113.4');
      expect(r.containsKey('country'), isFalse);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('HTTP 500, garbage and country XX are ignored, the good answer still wins', () async {
      proxy = await serve({
        '/bad500': (delay: const Duration(milliseconds: 5), status: 500, body: 'server error'),
        '/garbage': (delay: const Duration(milliseconds: 5), status: 200, body: 'not-an-ip-body'),
        '/xxCountry': (delay: const Duration(milliseconds: 5), status: 200, body: '203.0.113.5|XX|Nowhere|'),
        '/good': (delay: const Duration(milliseconds: 40), status: 200, body: '203.0.113.5|NL|Amsterdam|'),
      });
      final r = await checkExitIp(
        proxy.port,
        probes: [probe('bad500'), probe('garbage'), probe('xxCountry'), probe('good')],
        timeout: const Duration(seconds: 3),
        grace: const Duration(milliseconds: 300),
      );
      expect(r['ip'], '203.0.113.5');
      expect(r['country'], 'NL');
      expect(r['city'], 'Amsterdam');
    });

    test('throws when every probe fails or answers with no valid ip', () async {
      proxy = await serve({
        '/bad500': (delay: const Duration(milliseconds: 5), status: 500, body: 'server error'),
        '/garbage': (delay: const Duration(milliseconds: 5), status: 200, body: 'nope'),
        '/xxCountry': (delay: const Duration(milliseconds: 5), status: 200, body: 'not-an-ip|XX|Nowhere|'),
      });
      await expectLater(
        checkExitIp(
          proxy.port,
          probes: [probe('bad500'), probe('garbage'), probe('xxCountry')],
          timeout: const Duration(milliseconds: 500),
          grace: const Duration(milliseconds: 100),
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('no answer through the tunnel'))),
      );
    });

    test('throws roughly at the timeout when nothing answers in time', () async {
      proxy = await serve({
        '/slow': (delay: const Duration(seconds: 2), status: 200, body: '203.0.113.6|DE|Berlin|'),
      });
      final sw = Stopwatch()..start();
      await expectLater(
        checkExitIp(
          proxy.port,
          probes: [probe('slow')],
          timeout: const Duration(milliseconds: 150),
          grace: const Duration(milliseconds: 50),
        ),
        throwsA(isA<Exception>()),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
      expect(sw.elapsedMilliseconds, lessThan(800));
    });
  });
}
