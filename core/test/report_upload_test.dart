// HttpReportUploader (report_upload.dart, docs/logs.md → Отправка → Контракт) against a local
// HttpServer on loopback: what goes out (headers, the envelope that opens with the private key, the
// size), the error mapping, the timeouts and the size cap. No connection past loopback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/report_crypto.dart';
import 'package:test/test.dart';

class _Got {
  _Got(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final HttpHeaders headers;
  final Uint8List body;
}

const _meta = <String, dynamic>{
  'format': 1,
  'createdAt': '2026-10-10T10:00:00.000Z',
  'version': '0.9.0-beta.8',
  'versionCode': 42,
  'commit': 'abc1234',
  'platform': 'android',
  'bytes': 1000,
  'gzipBytes': 400,
  'noteLength': 0,
};

Uint8List _gz() => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode({'format': 1, 'note': 'privet'}))));

void main() {
  late HttpServer server;
  late ReportKeys keys;
  final got = <_Got>[];
  // what the server answers next: (status, body, extra headers); a null body = never answer
  var answer = (status: 200, body: '{"ok":true,"id":"20261010-k3x9qa"}' as String?, headers: const <String, String>{});
  // the bulk probe (POST /v1/ping): what it got, and how the server answers it: the status (null =
  // never answers) and how many bytes it echoes (null = the whole body back, as the Worker does)
  final probes = <_Got>[];
  int? pingStatus = 200;
  int? pingBytes;

  HttpReportUploader up({
    int? maxBytes,
    Duration? timeout,
    Duration? tunnelTimeout,
    Duration? probeTimeout,
    String? publicKey,
    String? endpoint,
  }) =>
      HttpReportUploader(
        endpoint: endpoint ?? 'http://127.0.0.1:${server.port}/v1/report',
        publicKey: publicKey ?? keys.publicBase64,
        connectTimeout: const Duration(seconds: 2),
        timeout: timeout ?? const Duration(seconds: 10),
        tunnelTimeout: tunnelTimeout ?? const Duration(seconds: 10),
        probeTimeout: probeTimeout ?? const Duration(seconds: 2),
        maxBytes: maxBytes ?? reportMaxBytes,
      );

  setUpAll(() async => keys = await generateReportKeys());

  setUp(() async {
    got.clear();
    probes.clear();
    pingStatus = 200;
    pingBytes = null;
    answer = (status: 200, body: '{"ok":true,"id":"20261010-k3x9qa"}', headers: const {});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = (await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))).takeBytes();
      if (req.uri.path == reportProbePath) {
        probes.add(_Got(req.method, req.uri.path, req.headers, body));
        final s = pingStatus;
        if (s == null) return; // never answers
        req.response.statusCode = s;
        final n = pingBytes ?? body.length;
        req.response.add(n <= body.length ? body.sublist(0, n) : Uint8List(n));
        await req.response.close();
        return;
      }
      got.add(_Got(req.method, req.uri.path, req.headers, body));
      final a = answer;
      if (a.body == null) return; // never answers
      req.response.statusCode = a.status;
      a.headers.forEach(req.response.headers.set);
      req.response.write(a.body);
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<ReportUploadException> failure(Future<ReportReceipt> f) async {
    try {
      await f;
    } on ReportUploadException catch (e) {
      return e;
    }
    fail('the upload was expected to fail');
  }

  group('what goes out', () {
    test('POST of the envelope with the X-Jorm headers; it opens with the private key; the receipt comes back', () async {
      answer = (status: 200, body: '{"ok":true,"id":"20261010-k3x9qa"}', headers: {'Date': 'Sat, 10 Oct 2026 12:00:00 GMT'});
      final gz = _gz();
      final r = await up().upload(gz, meta: _meta);
      expect(r.id, '20261010-k3x9qa');
      expect(r.at, DateTime.utc(2026, 10, 10, 12));

      expect(got, hasLength(1));
      final g = got.single;
      expect(g.method, 'POST');
      expect(g.path, '/v1/report');
      expect(g.headers.contentType?.mimeType, 'application/octet-stream');
      expect(g.headers.value('X-Jorm-Format'), '1');
      expect(g.headers.value('X-Jorm-Version'), '0.9.0-beta.8');
      expect(g.headers.value('X-Jorm-Build'), '42');
      expect(g.headers.value('X-Jorm-Platform'), 'android');
      expect(g.headers.value('X-Jorm-Size'), '${g.body.length}');
      expect(g.headers.value('X-Jorm-Via'), 'direct');
      expect(g.headers.value('X-Jorm-Vpn'), 'off');
      expect(g.headers.value('X-Jorm-Note'), isNull, reason: 'no note, no header');
      expect(g.headers.value('authorization'), isNull);
      expect(g.body.length, gz.length + reportEnvelopeOverhead);
      expect(g.body.sublist(0, 4), utf8.encode('JRP1'));
      expect(await decryptReport(g.body, privateKey: keys.privateKey), gz);
      // the clear report is nowhere on the wire
      expect(utf8.decode(g.body, allowMalformed: true), isNot(contains('privet')));
    });

    test('meta that is missing or odd does not break the request: absent fields are not sent, values are made header-safe', () async {
      await up().upload(_gz(), meta: {'format': 1, 'version': 'v\r\nX-Evil: 1 ж', 'platform': 'p' * 200});
      final h = got.single.headers;
      expect(h.value('X-Jorm-Build'), isNull);
      expect(h.value('X-Evil'), isNull);
      expect(h.value('X-Jorm-Version'), 'vX-Evil: 1');
      expect(h.value('X-Jorm-Platform'), 'p' * 64);
      expect(h.value('X-Jorm-Format'), '1');
    });

    test('the note travels in X-Jorm-Note: base64url without padding of its UTF-8, printable ASCII; the empty one is omitted', () async {
      // bytes that make '+', '/' and padding in plain base64
      const note = 'не грузится Telegram >>> ??? ~~~ с 14:00 \u{1F600}';
      await up().upload(_gz(), meta: {..._meta, 'note': note, 'noteLength': note.length});
      final v = got.single.headers.value('X-Jorm-Note')!;
      expect(v, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(utf8.decode(base64Url.decode(base64Url.normalize(v))), note);
      got.clear();
      await up().upload(_gz(), meta: {..._meta, 'note': ''});
      expect(got.single.headers.value('X-Jorm-Note'), isNull);
    });

    test('the endpoint is the Workers URL by default and the key is the built-in one', () {
      expect(reportEndpoint, 'https://jormungand-reports.slackerwarlock.workers.dev/v1/report');
      final d = HttpReportUploader();
      expect(d.endpoint, reportEndpoint);
      expect(d.publicKey, reportPublicKey);
      expect(d.maxBytes, 4 * 1024 * 1024);
      expect(d.connectTimeout, const Duration(seconds: 10));
      expect(d.timeout, const Duration(seconds: 10));
      expect(d.tunnelTimeout, const Duration(seconds: 10));
      expect(d.probeTimeout, const Duration(seconds: 3));
      expect(reportProbeBytes, 32 * 1024);
      expect(reportSendDeadline, d.tunnelTimeout + d.probeTimeout + d.timeout + reportBuildMargin,
          reason: 'the overall deadline covers tunnel try + probe + direct upload + margin');
      expect(reportSendDeadline, const Duration(seconds: 28));
    });
  });

  // The way: with the tunnel up the upload goes through its proxy first and an answer of the receiver
  // is final; no answer → the direct path, behind a bulk probe (POST of 32 KiB that the Worker echoes);
  // with the tunnel down the probe is first and a failed one is `no-route`. Here the unreachable
  // "direct" receiver is a socket that accepts and never speaks, the "proxy" is a plain HTTP server
  // (for an http:// target a proxy gets the absolute URI, which is what Dart sends).
  group('tunnel first, then the probed direct path', () {
    late ServerSocket stalled;
    final held = <Socket>[];
    late HttpServer proxy;
    // what the proxy got: the target and the X-Jorm-Via / X-Jorm-Vpn of the request
    final viaProxy = <({Uri uri, String? via, String? vpn})>[];
    int? proxyStatus = 200; // null = never answers

    setUp(() async {
      held.clear();
      viaProxy.clear();
      proxyStatus = 200;
      stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      stalled.listen(held.add);
      proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
        viaProxy.add((uri: req.requestedUri, via: req.headers.value('X-Jorm-Via'), vpn: req.headers.value('X-Jorm-Vpn')));
        await req.drain<void>();
        final s = proxyStatus;
        if (s == null) return; // never answers
        req.response.statusCode = s;
        req.response.write(s == 200 ? '{"ok":true,"id":"20261010-vpn123"}' : '{"ok":false,"error":"slow"}');
        await req.response.close();
      });
    });

    tearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await stalled.close();
      await proxy.close(force: true);
    });

    // the "direct" receiver never speaks
    HttpReportUploader stalledUp({Duration? tunnelTimeout}) => up(
          endpoint: 'http://127.0.0.1:${stalled.port}/v1/report',
          probeTimeout: const Duration(milliseconds: 400),
          timeout: const Duration(seconds: 2),
          tunnelTimeout: tunnelTimeout,
        );

    // a port where the proxy is gone (connection refused)
    Future<int> deadProxy() async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      return port;
    }

    test('tunnel up: the upload goes through the tunnel first, nothing direct, no probe', () async {
      final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
      expect(r.id, '20261010-vpn123');
      expect(r.via, 'vpn');
      expect(r.firstError, isNull);
      expect(viaProxy.single.uri.port, server.port, reason: 'the proxy was asked for the receiver');
      expect(viaProxy.single.via, 'vpn');
      expect(viaProxy.single.vpn, 'on');
      expect(probes, isEmpty);
      expect(got, isEmpty);
    });

    test('an answer of the receiver through the tunnel (any status) is final: no probe, no direct try', () async {
      proxyStatus = 429;
      final e = await failure(up().upload(_gz(), meta: _meta, proxyPort: proxy.port));
      expect(e.code, 'rejected');
      expect(probes, isEmpty);
      expect(got, isEmpty);
    });

    test('tunnel refuses: the probe, then the direct upload; the receipt says why the tunnel failed', () async {
      final r = await up().upload(_gz(), meta: _meta, proxyPort: await deadProxy());
      expect(r.via, 'direct');
      expect(r.id, '20261010-k3x9qa');
      expect(r.firstError, startsWith('via VPN:'));
      expect(probes, hasLength(1));
      final h = got.single.headers;
      expect(h.value('X-Jorm-Via'), 'direct');
      expect(h.value('X-Jorm-Vpn'), 'on', reason: 'the tunnel is connected, it just failed to carry this');
    });

    test('tunnel silent for its timeout: direct after the probe', () async {
      proxyStatus = null;
      final sw = Stopwatch()..start();
      final r = await up(tunnelTimeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta, proxyPort: proxy.port);
      expect(r.via, 'direct');
      expect(r.firstError, allOf(contains('via VPN'), contains('did not answer')));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(viaProxy, hasLength(1));
    });

    test('tunnel fails and the probe fails: network with both reasons', () async {
      final e = await failure(stalledUp().upload(_gz(), meta: _meta, proxyPort: await deadProxy()));
      expect(e.code, 'network');
      expect(e.message, allOf(contains('via VPN:'), contains('direct: no path'), contains('no echo')));
    });

    test('tunnel fails and the direct upload fails too: network with both reasons', () async {
      answer = (status: 200, body: null, headers: const {});
      final e = await failure(up(timeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta, proxyPort: await deadProxy()));
      expect(e.code, 'network');
      expect(e.message, allOf(contains('via VPN:'), contains('direct:'), contains('did not answer')));
      expect(probes, hasLength(1));
    });

    test('an answer of the receiver on the direct path after a failed tunnel try is final too', () async {
      answer = (status: 429, body: '{"ok":false,"error":"slow"}', headers: const {});
      final e = await failure(up().upload(_gz(), meta: _meta, proxyPort: await deadProxy()));
      expect(e.code, 'rejected');
    });

    // For an https receiver Dart asks the proxy for CONNECT; a refusal of that (sing-box's mixed inbound
    // cannot reach the receiver: 502/503) is an exception of the HttpClient, i.e. `network` → the direct
    // path, and not "an answer of the receiver". Both ends are raw sockets: the proxy answers the CONNECT
    // with the status, the "receiver" only counts that the direct probe came (its TLS cannot succeed).
    for (final status in [502, 503]) {
      test('the proxy refuses CONNECT with $status: a network failure of the tunnel try, the direct path is tried', () async {
        final connects = <String>[];
        final fakeProxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(fakeProxy.close);
        fakeProxy.listen((s) {
          final buf = StringBuffer();
          s.listen((d) {
            buf.write(latin1.decode(d));
            if (buf.toString().contains('\r\n\r\n')) {
              connects.add(buf.toString().split('\r\n').first);
              s.write('HTTP/1.1 $status Bad Gateway\r\nContent-Length: 0\r\n\r\n');
              s.flush().then((_) => s.destroy());
            }
          }, onError: (_) {});
        });
        var direct = 0;
        final receiver = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(receiver.close);
        receiver.listen((s) {
          direct++;
          s.destroy();
        });
        final e = await failure(up(endpoint: 'https://127.0.0.1:${receiver.port}/v1/report')
            .upload(_gz(), meta: _meta, proxyPort: fakeProxy.port));
        expect(connects.single, startsWith('CONNECT 127.0.0.1:${receiver.port}'));
        expect(direct, greaterThan(0), reason: 'the direct path (the probe) was tried after the tunnel failed');
        expect(e.code, 'network', reason: 'not rejected / server: the proxy is not the receiver');
        expect(e.message, allOf(contains('via VPN:'), contains('$status'), contains('direct: no path')));
      });
    }

    group('the bulk probe', () {
      test('POST /v1/ping with 32 KiB of random bytes; passes on 200 with the full echo, tunnel not involved', () async {
        final r = await up().upload(_gz(), meta: _meta);
        expect(r.via, 'direct');
        expect(r.firstError, isNull);
        expect(probes, hasLength(1));
        final p = probes.single;
        expect(p.method, 'POST');
        expect(p.path, '/v1/ping');
        expect(p.headers.contentType?.mimeType, 'application/octet-stream');
        expect(p.body, hasLength(reportProbeBytes));
        expect(p.body.toSet().length, greaterThan(200), reason: 'random, not zeros');
        expect(got.single.method, 'POST');
        expect(viaProxy, isEmpty);
      });

      test('the probe body differs from try to try', () async {
        await up().upload(_gz(), meta: _meta);
        await up().upload(_gz(), meta: _meta);
        expect(probes[0].body, isNot(probes[1].body));
      });

      test('a shorter echo is no path: no-route with the lengths', () async {
        pingBytes = 1000;
        final e = await failure(up().upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, allOf(contains('echoed 1000 bytes'), contains('$reportProbeBytes')));
        expect(got, isEmpty);
      });

      test('a longer echo is no path either', () async {
        pingBytes = reportProbeBytes + 5;
        final e = await failure(up().upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
      });

      test('any other status is no path (a 404 of an older Worker, a 200 is needed)', () async {
        pingStatus = 404;
        final e = await failure(up().upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, contains('HTTP 404'));
        expect(got, isEmpty);
      });

      test('silence: no-route after the probe timeout, right away, no long attempt', () async {
        final sw = Stopwatch()..start();
        final e = await failure(stalledUp().upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, allOf(contains('no direct path'), contains('VPN')));
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
        expect(viaProxy, isEmpty);
      });

      test('refused (nothing listens) and no tunnel: no-route', () async {
        final port = await deadProxy();
        final e = await failure(up(endpoint: 'http://127.0.0.1:$port/v1/report').upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
      });

      test('with a tunnel that failed, a failed probe is network (not no-route), with both reasons', () async {
        pingStatus = 503;
        final e = await failure(up().upload(_gz(), meta: _meta, proxyPort: await deadProxy()));
        expect(e.code, 'network');
        expect(e.message, allOf(contains('via VPN:'), contains('HTTP 503')));
      });
    });

    test('probe passed but the direct upload stalls, tunnel down: network after the upload timeout, no second try', () async {
      answer = (status: 200, body: null, headers: const {});
      final e = await failure(up(timeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta));
      expect(e.code, 'network');
      expect(e.message, contains('(direct)'));
      expect(probes, hasLength(1));
      expect(got, hasLength(1));
      expect(viaProxy, isEmpty);
    });

    test('Cancel aborts a tunnel try under way at once, with no probe after it', () async {
      proxyStatus = null;
      final c = ReportCancel();
      final f = failure(up().upload(_gz(), meta: _meta, proxyPort: proxy.port, cancel: c));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.cancel();
      final e = await f.timeout(const Duration(seconds: 1));
      expect(e.code, 'cancelled');
      expect(probes, isEmpty);
    });

    test('Cancel aborts a probe under way at once', () async {
      final c = ReportCancel();
      final f = failure(up(endpoint: 'http://127.0.0.1:${stalled.port}/v1/report', probeTimeout: const Duration(seconds: 2))
          .upload(_gz(), meta: _meta, cancel: c));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.cancel();
      final e = await f.timeout(const Duration(seconds: 1));
      expect(e.code, 'cancelled');
    });

    test('Cancel aborts a stalled direct upload at once', () async {
      answer = (status: 200, body: null, headers: const {});
      final c = ReportCancel();
      final f = failure(up().upload(_gz(), meta: _meta, cancel: c));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      c.cancel();
      final e = await f.timeout(const Duration(seconds: 1));
      expect(e.code, 'cancelled');
    });

    test('already cancelled: nothing is sent', () async {
      final c = ReportCancel()..cancel();
      final e = await failure(up().upload(_gz(), meta: _meta, cancel: c));
      expect(e.code, 'cancelled');
      expect(got, isEmpty);
      expect(probes, isEmpty);
    });
  });

  group('size cap', () {
    test('an envelope over the limit is refused locally, nothing is sent', () async {
      final big = Uint8List(2000);
      final e = await failure(up(maxBytes: 1000).upload(big, meta: _meta));
      expect(e.code, 'rejected');
      expect(e.message, contains('too big'));
      expect(got, isEmpty);
    });

    test('exactly at the limit goes', () async {
      final gz = Uint8List(1000);
      final r = await up(maxBytes: 1000 + reportEnvelopeOverhead).upload(gz, meta: _meta);
      expect(r.id, isNotEmpty);
      expect(got.single.body.length, 1000 + reportEnvelopeOverhead);
    });
  });

  group('errors', () {
    final table = <int, String>{
      400: 'rejected',
      413: 'rejected',
      415: 'rejected',
      429: 'rejected',
      500: 'server',
      502: 'server',
      503: 'server',
      401: 'failed',
      403: 'failed',
      404: 'failed',
      301: 'failed',
    };
    table.forEach((status, code) {
      test('HTTP $status → $code', () async {
        answer = (status: status, body: '{"ok":false,"error":"nope"}', headers: const {});
        final e = await failure(up().upload(_gz(), meta: _meta));
        expect(e.code, code);
        expect(e.message, contains('$status'));
      });
    });

    test('the server\'s reason travels in the message; 429 says it is the rate limit', () async {
      answer = (status: 413, body: '{"ok":false,"error":"report is over 4 MiB"}', headers: const {});
      expect((await failure(up().upload(_gz(), meta: _meta))).message, contains('report is over 4 MiB'));
      answer = (status: 429, body: '{"ok":false,"error":"slow down"}', headers: const {});
      final e = await failure(up().upload(_gz(), meta: _meta));
      expect(e.message.toLowerCase(), contains('rate limit'));
      expect(e.message, contains('slow down'));
    });

    test('a 200 that is not {ok: true, id} is a failure, not a receipt', () async {
      for (final body in ['not json', '{"ok":true}', '{"ok":false,"id":"x"}', '{"ok":true,"id":""}', '[]', '']) {
        answer = (status: 200, body: body, headers: const {});
        final e = await failure(up().upload(_gz(), meta: _meta));
        expect(e.code, 'failed', reason: body);
      }
    });

    test('no listener on the port and no tunnel: no-route', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final e = await failure(up(endpoint: 'http://127.0.0.1:$port/v1/report').upload(_gz(), meta: _meta));
      expect(e.code, 'no-route');
    });

    test('an answer that never comes: network, after the timeout', () async {
      answer = (status: 200, body: null, headers: const {});
      final sw = Stopwatch()..start();
      final e = await failure(up(timeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta));
      expect(e.code, 'network');
      expect(e.message, contains('did not answer'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a connection closed in the middle of the answer: network', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c));
        if (req.uri.path == reportProbePath) {
          req.response.add(body.takeBytes()); // the probe is echoed, the upload is not answered
          await req.response.close();
          return;
        }
        final s = await req.response.detachSocket();
        s.destroy();
      });
      final e = await failure(up().upload(_gz(), meta: _meta));
      expect(e.code, 'network');
    });

    test('a bad receiver key or endpoint is a failure of ours, not a network one', () async {
      expect((await failure(up(publicKey: 'not base64!').upload(_gz(), meta: _meta))).code, 'failed');
      expect((await failure(up(publicKey: 'AAAA').upload(_gz(), meta: _meta))).code, 'failed');
      expect((await failure(up(endpoint: 'http://[bad/').upload(_gz(), meta: _meta))).code, 'failed');
      expect(got, isEmpty);
    });
  });
}
