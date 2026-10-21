// HttpReportUploader (report_upload.dart, docs/logs.md → Отправка → Контракт) against a local
// HttpServer on loopback: what goes out (headers, the envelope that opens with the private key, the
// size), the error mapping, the timeouts and the size cap. No connection past loopback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
    Duration? attemptTimeout,
    Duration? stallTimeout,
    Duration? responseTimeout,
    Duration? probeTimeout,
    Duration? tunnelGrace,
    String? publicKey,
    String? endpoint,
  }) =>
      HttpReportUploader(
        endpoint: endpoint ?? 'http://127.0.0.1:${server.port}/v1/report',
        publicKey: publicKey ?? keys.publicBase64,
        connectTimeout: const Duration(seconds: 2),
        attemptTimeout: attemptTimeout ?? const Duration(seconds: 8),
        stallTimeout: stallTimeout ?? const Duration(seconds: 2),
        responseTimeout: responseTimeout ?? const Duration(seconds: 4),
        probeTimeout: probeTimeout ?? const Duration(seconds: 2),
        tunnelGrace: tunnelGrace ?? const Duration(milliseconds: 300),
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
      expect(d.attemptTimeout, const Duration(seconds: 10));
      expect(d.stallTimeout, const Duration(seconds: 3));
      expect(d.responseTimeout, const Duration(seconds: 5));
      expect(d.probeTimeout, const Duration(seconds: 3));
      expect(d.tunnelGrace, const Duration(milliseconds: 300));
      expect(reportProbeBytes, 32 * 1024);
      expect(d.stallTimeout + d.responseTimeout, lessThanOrEqualTo(d.attemptTimeout), reason: 'the cap is only a safety net');
      expect(reportSendDeadline, d.probeTimeout + d.attemptTimeout * 2 + reportBuildMargin,
          reason: 'the overall deadline covers the probes + an attempt on each way + margin');
      expect(reportSendDeadline, const Duration(seconds: 28));
    });
  });

  // The way: with the tunnel up both ways are probed at once (POST of 32 KiB that must come back whole),
  // the upload goes on the first way that passed, the tunnel preferred; a network failure of the upload
  // (a stall, no response after the body) sends it once on the other way, if its probe passed; an answer
  // of the receiver is final. With the tunnel down only the direct probe runs, and its failure is
  // `no-route`. Here the direct receiver is the HttpServer above; the "tunnel" is a plain HTTP server
  // acting as the proxy (for an http:// target a proxy gets the absolute URI, which is what Dart sends)
  // with its own knobs; an unreachable receiver is a socket that accepts and never speaks.
  group('probes in parallel, then the upload on the first way that passed', () {
    late ServerSocket stalled;
    final held = <Socket>[];
    late HttpServer proxy;
    // what the proxy got of the report (not of the probes): target, X-Jorm-Via, X-Jorm-Vpn
    final viaProxy = <({Uri uri, String? via, String? vpn})>[];
    var proxyProbes = 0;
    // how the proxy answers the probe (status null = never; echo bytes null = the body back) and how late
    int? proxyPing = 200;
    int? proxyPingBytes;
    var proxyPingDelay = Duration.zero;
    // how it answers the report (status null = never answers; noRead = does not read the body)
    int? proxyStatus = 200;
    var proxyNoRead = false;

    setUp(() async {
      held.clear();
      viaProxy.clear();
      proxyProbes = 0;
      proxyPing = 200;
      proxyPingBytes = null;
      proxyPingDelay = Duration.zero;
      proxyStatus = 200;
      proxyNoRead = false;
      stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      stalled.listen(held.add);
      proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
        if (req.uri.path == reportProbePath) {
          proxyProbes++;
          final body = (await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))).takeBytes();
          if (proxyPingDelay > Duration.zero) await Future<void>.delayed(proxyPingDelay);
          final s = proxyPing;
          if (s == null) return;
          req.response.statusCode = s;
          final n = proxyPingBytes ?? body.length;
          req.response.add(n <= body.length ? body.sublist(0, n) : Uint8List(n));
          await req.response.close();
          return;
        }
        viaProxy.add((uri: req.requestedUri, via: req.headers.value('X-Jorm-Via'), vpn: req.headers.value('X-Jorm-Vpn')));
        if (proxyNoRead) return;
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
    HttpReportUploader stalledUp({int? port}) => up(
          endpoint: 'http://127.0.0.1:${port ?? stalled.port}/v1/report',
          probeTimeout: const Duration(milliseconds: 400),
          responseTimeout: const Duration(milliseconds: 300),
        );

    // the direct receiver answers the report with nothing (a dead upload way)
    void directUploadDead() => answer = (status: 200, body: null, headers: const {});

    // a port where nothing listens (connection refused)
    Future<int> deadPort() async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      return port;
    }

    group('which way is picked', () {
      test('both probes pass: the tunnel; the direct way is not used for the upload', () async {
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.id, '20261010-vpn123');
        expect(r.via, 'vpn');
        expect(r.firstError, isNull);
        expect(proxyProbes, 1);
        expect(viaProxy.single.uri.port, server.port, reason: 'the proxy was asked for the receiver');
        expect(viaProxy.single.via, 'vpn');
        expect(viaProxy.single.vpn, 'on');
        expect(got, isEmpty);
      });

      test('only the direct probe passes: direct, and the receipt says why the tunnel was passed over', () async {
        proxyPing = 503;
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.id, '20261010-k3x9qa');
        expect(r.firstError, allOf(startsWith('via VPN: probe:'), contains('HTTP 503')));
        expect(viaProxy, isEmpty);
        final h = got.single.headers;
        expect(h.value('X-Jorm-Via'), 'direct');
        expect(h.value('X-Jorm-Vpn'), 'on', reason: 'the tunnel is connected, it just did not carry this');
      });

      test('only the tunnel probe passes: the tunnel, no reason to report', () async {
        pingStatus = 503;
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(r.firstError, isNull);
        expect(got, isEmpty);
      });

      test('the tunnel probe a little behind the direct one (within the grace) still wins', () async {
        proxyPingDelay = const Duration(milliseconds: 150);
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(got, isEmpty);
      });

      test('the tunnel probe later than the grace: direct goes, and nothing is claimed about the tunnel', () async {
        proxyPingDelay = const Duration(milliseconds: 900);
        final sw = Stopwatch()..start();
        final r = await up(tunnelGrace: const Duration(milliseconds: 100)).upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.firstError, isNull, reason: 'its probe has not failed, it is just late');
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 800)), reason: 'the late probe is not waited for');
        expect(viaProxy, isEmpty);
      });

      test('neither probe passes but the tunnel upload does: the tunnel goes first, via vpn', () async {
        proxyPing = 503;
        pingStatus = 404;
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(r.id, '20261010-vpn123');
        expect(r.firstError, isNull, reason: 'nothing failed on the way that carried it');
        expect(viaProxy, hasLength(1));
        expect(got, isEmpty);
      });

      test('neither probe passes, the tunnel upload fails, the direct one goes: firstError has both reasons', () async {
        proxyPing = 503;
        pingStatus = 404;
        proxyStatus = null;
        final r = await up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.id, '20261010-k3x9qa');
        expect(r.firstError, allOf(startsWith('via VPN: probe:'), contains('HTTP 503'), contains('upload: no response within')));
        expect(viaProxy, hasLength(1));
        expect(got, hasLength(1));
      });

      test('neither probe passes and both uploads fail: network with probe and upload reasons of both ways', () async {
        proxyPing = 503;
        pingStatus = 404;
        proxyStatus = null;
        directUploadDead();
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port));
        expect(e.code, 'network');
        expect(
            e.message,
            allOf(contains('via VPN: probe:'), contains('HTTP 503'), contains('direct: probe:'), contains('HTTP 404'),
                contains('upload: no response within')));
      });

      test('tunnel down, the probe fails, the direct upload goes', () async {
        pingStatus = 404;
        final r = await up().upload(_gz(), meta: _meta);
        expect(r.via, 'direct');
        expect(got, hasLength(1));
      });

      test('tunnel down, the probe fails and the direct upload too: no-route with both reasons', () async {
        pingStatus = 404;
        directUploadDead();
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, allOf(contains('no direct path to the receiver'), contains('probe:'), contains('HTTP 404'), contains('VPN is not connected')));
      });

      test('tunnel down, the probe passes and the direct upload fails: network, not no-route', () async {
        directUploadDead();
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta));
        expect(e.code, 'network');
      });

      test('the tunnel refuses the connection (dead port), direct passes: direct', () async {
        final r = await up().upload(_gz(), meta: _meta, proxyPort: await deadPort());
        expect(r.via, 'direct');
        // a refused connection can take its time (Windows retries): the reason is there only if the refusal
        // came within the grace
        expect(r.firstError, anyOf(isNull, startsWith('via VPN: no path')));
      });

      test('tunnel down: only the direct probe runs, the way is direct, no reason', () async {
        final r = await up().upload(_gz(), meta: _meta);
        expect(r.via, 'direct');
        expect(r.firstError, isNull);
        expect(proxyProbes, 0);
        expect(got.single.headers.value('X-Jorm-Vpn'), 'off');
      });
    });

    group('the bulk probe', () {
      test('POST /v1/ping with 32 KiB of random bytes; passes on 200 with the full echo', () async {
        await up().upload(_gz(), meta: _meta);
        expect(probes, hasLength(1));
        final p = probes.single;
        expect(p.method, 'POST');
        expect(p.path, '/v1/ping');
        expect(p.headers.contentType?.mimeType, 'application/octet-stream');
        expect(p.body, hasLength(reportProbeBytes));
        expect(p.body.toSet().length, greaterThan(200), reason: 'random, not zeros');
      });

      test('the probe body differs from try to try', () async {
        await up().upload(_gz(), meta: _meta);
        await up().upload(_gz(), meta: _meta);
        expect(probes[0].body, isNot(probes[1].body));
      });

      test('the tunnel\'s probe is the same POST, through the proxy', () async {
        await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(proxyProbes, 1);
      });

      test('a shorter echo is not a confirmed path: no-route (tunnel down, upload dead too) with the lengths', () async {
        pingBytes = 1000;
        directUploadDead();
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, allOf(contains('echoed 1000 bytes'), contains('$reportProbeBytes')));
        expect(got, hasLength(1), reason: 'the upload was tried');
      });

      test('a longer echo is not a path either; a short one of the tunnel passes the tunnel over', () async {
        pingBytes = reportProbeBytes + 5;
        directUploadDead();
        expect((await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta))).code, 'no-route');
        answer = (status: 200, body: '{"ok":true,"id":"20261010-k3x9qa"}', headers: const {});
        pingBytes = null;
        proxyPingBytes = 10;
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.firstError, contains('echoed 10 bytes'));
      });

      test('any other status is not a confirmed path (a 404 of an older Worker; a 200 is needed)', () async {
        pingStatus = 404;
        directUploadDead();
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, contains('HTTP 404'));
      });

      test('silence: after the probe timeout the upload is tried; both dead: no-route', () async {
        final sw = Stopwatch()..start();
        final e = await failure(stalledUp().upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
        expect(e.message, allOf(contains('no direct path'), contains('VPN')));
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
        expect(viaProxy, isEmpty);
      });

      test('refused (nothing listens) and no tunnel: no-route', () async {
        final e = await failure(stalledUp(port: await deadPort()).upload(_gz(), meta: _meta));
        expect(e.code, 'no-route');
      });

      test('both probes run at once: a silent direct one does not delay the tunnel beyond its own pass', () async {
        final sw = Stopwatch()..start();
        final r = await stalledUp().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 300)), reason: 'the tunnel probe passed at once, the direct one is not waited for');
        expect(viaProxy.single.uri.port, stalled.port);
      });
    });

    group('the upload fails: once on the other way', () {
      test('tunnel: no response after the body → direct; the receipt says why', () async {
        proxyStatus = null;
        final sw = Stopwatch()..start();
        final r = await up(responseTimeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.id, '20261010-k3x9qa');
        expect(r.firstError, allOf(startsWith('via VPN:'), contains('no response within'), contains('after the upload')));
        expect(viaProxy, hasLength(1));
        expect(got.single.headers.value('X-Jorm-Via'), 'direct');
        expect(got.single.headers.value('X-Jorm-Vpn'), 'on');
        expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      });

      test('tunnel: the connection dies mid-way (the proxy goes away after its probe) → direct', () async {
        // a proxy that answers the probe and then refuses the report: closes its socket
        await proxy.close(force: true);
        proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        proxy.listen((req) async {
          if (req.uri.path == reportProbePath) {
            final body = (await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))).takeBytes();
            req.response.add(body);
            await req.response.close();
            return;
          }
          (await req.response.detachSocket()).destroy();
        });
        final r = await up().upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.firstError, startsWith('via VPN:'));
      });

      test('direct first (the tunnel probe is late), no response → the tunnel, once its probe has passed', () async {
        proxyPingDelay = const Duration(milliseconds: 700);
        answer = (status: 200, body: null, headers: const {});
        final r = await up(tunnelGrace: const Duration(milliseconds: 50), responseTimeout: const Duration(milliseconds: 300))
            .upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(r.firstError, allOf(startsWith('direct:'), contains('no response within')));
        expect(got, hasLength(1), reason: 'the direct upload was made once');
        expect(viaProxy.single.via, 'vpn');
      });

      test('direct first, no response, the tunnel probe failed: the tunnel is still tried once', () async {
        proxyPing = 503;
        answer = (status: 200, body: null, headers: const {});
        final r = await up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'vpn');
        expect(r.firstError, allOf(startsWith('direct:'), contains('no response within')));
        expect(viaProxy, hasLength(1));
        expect(got, hasLength(1));
      });

      test('direct first, no response, the tunnel probe failed and its upload too: network with both reasons', () async {
        proxyPing = 503;
        proxyStatus = null;
        answer = (status: 200, body: null, headers: const {});
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port));
        expect(e.code, 'network');
        expect(e.message, allOf(contains('direct: no response within'), contains('via VPN: probe:'), contains('HTTP 503'), contains('upload: no response')));
        expect(viaProxy, hasLength(1));
        expect(got, hasLength(1));
      });

      test('both uploads fail: network with both reasons', () async {
        proxyStatus = null;
        answer = (status: 200, body: null, headers: const {});
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port));
        expect(e.code, 'network');
        expect(e.message, allOf(contains('via VPN: no response within'), contains('direct: no response within')));
        expect(viaProxy, hasLength(1));
        expect(got, hasLength(1));
      });

      test('a stall while the body goes out (nobody reads it) is a dead way within the stall time, then the other way', () async {
        // an envelope too big for the socket buffers; the proxy never reads it
        final rnd = Random(7);
        final big = Uint8List.fromList([for (var i = 0; i < 3 * 1024 * 1024; i++) rnd.nextInt(256)]);
        proxyNoRead = true;
        final sw = Stopwatch()..start();
        final r = await up(stallTimeout: const Duration(milliseconds: 500), responseTimeout: const Duration(seconds: 1))
            .upload(big, meta: _meta, proxyPort: proxy.port);
        expect(r.via, 'direct');
        expect(r.firstError, allOf(startsWith('via VPN:'), contains('the upload stalled: no bytes accepted for 500ms')));
        expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
      });

      test('an answer of the receiver (any status) on the first way is final: no upload on the other', () async {
        proxyStatus = 429;
        final e = await failure(up().upload(_gz(), meta: _meta, proxyPort: proxy.port));
        expect(e.code, 'rejected');
        expect(got, isEmpty);
      });

      test('an answer of the receiver on the second way is final too', () async {
        proxyStatus = null;
        answer = (status: 429, body: '{"ok":false,"error":"slow"}', headers: const {});
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 300)).upload(_gz(), meta: _meta, proxyPort: proxy.port));
        expect(e.code, 'rejected');
      });

      test('tunnel down, direct upload: no response → network after the response time, nothing else to try', () async {
        answer = (status: 200, body: null, headers: const {});
        final e = await failure(up(responseTimeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta));
        expect(e.code, 'network');
        expect(e.message, allOf(contains('no response within'), contains('(direct)')));
        expect(probes, hasLength(1));
        expect(got, hasLength(1));
        expect(viaProxy, isEmpty);
      });

      test('the absolute cap of an attempt backs the stall detection', () async {
        // stall and response times are long; the cap is short
        answer = (status: 200, body: null, headers: const {});
        final e = await failure(up(
          attemptTimeout: const Duration(milliseconds: 400),
          stallTimeout: const Duration(seconds: 5),
          responseTimeout: const Duration(seconds: 5),
        ).upload(_gz(), meta: _meta));
        expect(e.code, 'network');
        expect(e.message, contains('did not answer in'));
      });
    });

    // For an https receiver Dart asks the proxy for CONNECT; a refusal of that (sing-box's mixed inbound
    // cannot reach the receiver: 502/503) is an exception of the HttpClient, i.e. a failed probe of the
    // tunnel, not "an answer of the receiver". Both ends are raw sockets: the proxy answers the CONNECT
    // with the status, the "receiver" only counts that the direct probe came (its TLS cannot succeed).
    for (final status in [502, 503]) {
      test('the proxy refuses CONNECT with $status: the tunnel way fails (network), the direct probe is tried', () async {
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
        expect(connects.first, startsWith('CONNECT 127.0.0.1:${receiver.port}'));
        expect(direct, greaterThan(0), reason: 'the direct probe was made');
        expect(e.code, 'network', reason: 'not rejected / server: the proxy is not the receiver');
        expect(e.message, allOf(contains('via VPN: probe:'), contains('$status'), contains('direct: probe:')));
      });
    }

    group('Cancel', () {
      test('aborts the probes under way at once', () async {
        final c = ReportCancel();
        final f = failure(up(endpoint: 'http://127.0.0.1:${stalled.port}/v1/report', probeTimeout: const Duration(seconds: 2))
            .upload(_gz(), meta: _meta, cancel: c));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        c.cancel();
        final e = await f.timeout(const Duration(seconds: 1));
        expect(e.code, 'cancelled');
      });

      test('aborts an upload under way at once, and no other way is tried', () async {
        proxyStatus = null;
        final c = ReportCancel();
        final f = failure(up().upload(_gz(), meta: _meta, proxyPort: proxy.port, cancel: c));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        c.cancel();
        final e = await f.timeout(const Duration(seconds: 1));
        expect(e.code, 'cancelled');
        expect(got, isEmpty);
      });

      test('aborts a stalled direct upload at once', () async {
        answer = (status: 200, body: null, headers: const {});
        final c = ReportCancel();
        final f = failure(up().upload(_gz(), meta: _meta, cancel: c));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        c.cancel();
        final e = await f.timeout(const Duration(seconds: 1));
        expect(e.code, 'cancelled');
      });

      test('already cancelled: nothing is sent, nothing is probed', () async {
        final c = ReportCancel()..cancel();
        final e = await failure(up().upload(_gz(), meta: _meta, cancel: c));
        expect(e.code, 'cancelled');
        expect(got, isEmpty);
        expect(probes, isEmpty);
      });
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
      final e = await failure(up(responseTimeout: const Duration(milliseconds: 400)).upload(_gz(), meta: _meta));
      expect(e.code, 'network');
      expect(e.message, contains('no response within'));
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
