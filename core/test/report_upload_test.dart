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

  HttpReportUploader up({int? maxBytes, Duration? timeout, String? publicKey, String? endpoint}) => HttpReportUploader(
        endpoint: endpoint ?? 'http://127.0.0.1:${server.port}/v1/report',
        publicKey: publicKey ?? keys.publicBase64,
        connectTimeout: const Duration(seconds: 2),
        timeout: timeout ?? const Duration(seconds: 10),
        maxBytes: maxBytes ?? reportMaxBytes,
      );

  setUpAll(() async => keys = await generateReportKeys());

  setUp(() async {
    got.clear();
    answer = (status: 200, body: '{"ok":true,"id":"20261010-k3x9qa"}', headers: const {});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await req.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c));
      got.add(_Got(req.method, req.uri.path, req.headers, body.takeBytes()));
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

    test('the endpoint is the Workers URL by default and the key is the built-in one', () {
      expect(reportEndpoint, 'https://jormungand-reports.slackerwarlock.workers.dev/v1/report');
      final d = HttpReportUploader();
      expect(d.endpoint, reportEndpoint);
      expect(d.publicKey, reportPublicKey);
      expect(d.maxBytes, 4 * 1024 * 1024);
      expect(d.connectTimeout, const Duration(seconds: 10));
      expect(d.timeout, const Duration(seconds: 60));
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

    test('no listener on the port: network', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final e = await failure(up(endpoint: 'http://127.0.0.1:$port/v1/report').upload(_gz(), meta: _meta));
      expect(e.code, 'network');
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
        await req.drain<void>();
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
