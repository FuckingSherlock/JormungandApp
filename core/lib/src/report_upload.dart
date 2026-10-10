import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'redact.dart';
import 'report_crypto.dart';

/// Sending the support report to the developers (docs/logs.md → Отправка). The core builds the
/// report, adds the user's note, masks it in the strict mode and gzips it; what happens to the bytes
/// next — the encryption on the device and the upload to the receiving Worker — is a
/// [ReportUploader], plugged in by the host: [HttpReportUploader] in the real hosts,
/// [NotConfiguredUploader] by default (tests, hosts that plug nothing).

/// The longest note the user can attach (characters; longer is cut).
const reportNoteMax = 500;

/// The receiving Worker's upload endpoint (workers/reports; docs/logs.md → Отправка → Контракт).
const reportEndpoint = 'https://jormungand-reports.slackerwarlock.workers.dev/v1/report';

/// The developers' X25519 public key, base64 (32 bytes): reports are encrypted to it on the device.
/// The private half is only in the developer's `%USERPROFILE%\.jormungand\report_private.key`
/// (tool/report_keys.dart; docs/logs.md → «Ключи»). Generated 2026-10-10.
const reportPublicKey = 'NGLJJuB4SbWoxILEKJL0l1nAO8nrEgxiCkWQC6dtQ3I=';

/// The Worker takes no more than this (the envelope); the client does not even try.
const reportMaxBytes = 4 * 1024 * 1024;

/// Connecting to the receiver, and the whole upload (connect, send, the answer).
const reportConnectTimeout = Duration(seconds: 10);
const reportUploadTimeout = Duration(seconds: 60);

/// What a finished upload gives back.
class ReportReceipt {
  const ReportReceipt({required this.id, this.at});

  /// The report's id on the receiving side: what the user quotes in a message.
  final String id;

  /// When the receiver accepted it (its clock), if it says.
  final DateTime? at;
}

/// An upload that did not go through. [code] is machine-readable and shown by the app in the
/// user's language: `not-configured` (no uploader plugged in), `network` (no connection to the
/// receiver), `rejected` (the receiver refused it: size, rate limit, bad format), `server` (the
/// receiver failed), `failed` (anything else); [message] is for the log and for the developer.
class ReportUploadException implements Exception {
  const ReportUploadException(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? 'ReportUploadException($code)' : 'ReportUploadException($code): $message';
}

/// Delivers a gzipped report to the receiver. The implementation encrypts it on the device (the
/// receiver's public key is built into the app) and uploads the envelope; it opens a connection,
/// so it is registered in `outside_tunnel.dart` ([HttpReportUploader]). Throws a
/// [ReportUploadException] on failure.
///
/// [meta] is what may be read without decrypting: `format`, `createdAt`, `version`, `versionCode`,
/// `commit`, `platform`, `bytes` (the report as JSON), `gzipBytes`, `noteLength`.
abstract interface class ReportUploader {
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta});
}

/// The default: no receiver is configured, so nothing leaves the device.
class NotConfiguredUploader implements ReportUploader {
  const NotConfiguredUploader();

  @override
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta}) =>
      Future.error(const ReportUploadException('not-configured'));
}

/// The real uploader: encrypts the gzipped report to [publicKey] on the device ([encryptReport],
/// envelope `JRP1`) and POSTs the envelope to [endpoint] (the Worker, docs/logs.md → Отправка →
/// Контракт). `X-Jorm-*` headers carry the plain part of `meta` (format, version, build, platform,
/// envelope size); there is no auth header, the Worker takes anonymous uploads and limits them.
///
/// The connection is the app's own: it goes direct, outside the tunnel, by the self rule
/// (outside_tunnel.dart → `report-upload`), so the report goes out exactly when the proxy is broken.
class HttpReportUploader implements ReportUploader {
  HttpReportUploader({
    this.endpoint = reportEndpoint,
    this.publicKey = reportPublicKey,
    this.connectTimeout = reportConnectTimeout,
    this.timeout = reportUploadTimeout,
    this.maxBytes = reportMaxBytes,
  });

  final String endpoint;

  /// Base64 of the recipient's X25519 public key.
  final String publicKey;
  final Duration connectTimeout;

  /// The whole upload: connecting, sending, the answer.
  final Duration timeout;

  /// The envelope is not sent when it is bigger ([reportMaxBytes], the Worker's own limit).
  final int maxBytes;

  @override
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta}) async {
    final Uint8List envelope;
    try {
      envelope = await encryptReport(gzipped, recipientPublicKey: base64.decode(publicKey));
    } on FormatException {
      throw const ReportUploadException('failed', 'the receiver key built into the app is not base64');
    } on ReportCryptoException catch (e) {
      throw ReportUploadException('failed', e.message);
    }
    if (envelope.length > maxBytes) {
      throw ReportUploadException('rejected',
          'the report is too big to send: ${envelope.length} bytes encrypted, the limit is $maxBytes (use Download log instead)');
    }
    final HttpClient client;
    final Uri uri;
    try {
      uri = Uri.parse(endpoint);
      client = HttpClient()
        ..connectionTimeout = connectTimeout
        ..userAgent = null;
    } on FormatException catch (e) {
      throw ReportUploadException('failed', 'bad report endpoint: ${e.message}');
    }
    try {
      return await _post(client, uri, envelope, meta).timeout(
        timeout,
        onTimeout: () => throw TimeoutException('the receiver did not answer in ${timeout.inSeconds} s'),
      );
    } on ReportUploadException {
      rethrow;
    } on TimeoutException catch (e) {
      throw ReportUploadException('network', e.message ?? 'timeout');
    } on IOException catch (e) {
      throw ReportUploadException('network', '$e');
    } catch (e) {
      throw ReportUploadException('failed', '$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<ReportReceipt> _post(HttpClient client, Uri uri, Uint8List envelope, Map<String, dynamic> meta) async {
    final req = await client.postUrl(uri);
    req.followRedirects = false;
    req.headers.contentType = ContentType.binary;
    req.contentLength = envelope.length;
    void h(String name, Object? v) {
      final s = _headerValue(v);
      if (s != null) req.headers.set(name, s);
    }

    h('X-Jorm-Format', meta['format']);
    h('X-Jorm-Version', meta['version']);
    h('X-Jorm-Build', meta['versionCode']);
    h('X-Jorm-Platform', meta['platform']);
    h('X-Jorm-Size', envelope.length);
    req.add(envelope);
    final res = await req.close();
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      if (b.length < _answerMax) b.add(chunk);
    }
    return _receipt(res.statusCode, utf8.decode(b.takeBytes(), allowMalformed: true), res.headers.date);
  }

  /// The Worker's answer is a few bytes of JSON; more than this is not read.
  static const _answerMax = 64 * 1024;

  /// A header value: printable ASCII only, cut, so a stray field of `meta` cannot break the request.
  static String? _headerValue(Object? v) {
    if (v == null) return null;
    final s = '$v'.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    if (s.isEmpty) return null;
    return s.length > 64 ? s.substring(0, 64) : s;
  }

  /// What the receiver wrote as the reason (`{"error": …}`, else the start of the body).
  static String _reason(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return (j['error'] as String).trim();
    } on FormatException {
      // not JSON: the text itself
    }
    final t = body.trim();
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }

  static ReportReceipt _receipt(int status, String body, DateTime? date) {
    String why(String lead) {
      final r = _reason(body);
      return r.isEmpty ? '$lead (HTTP $status)' : '$lead (HTTP $status): $r';
    }

    if (status == 200) {
      Object? j;
      try {
        j = jsonDecode(body);
      } on FormatException {
        // reported below
      }
      final id = j is Map ? j['id'] : null;
      if (j is Map && j['ok'] == true && id is String && id.isNotEmpty && id.length <= 64) {
        return ReportReceipt(id: id, at: date);
      }
      throw ReportUploadException('failed', 'the receiver answered 200 without a report id: ${_reason(body)}');
    }
    if (status == 429) throw ReportUploadException('rejected', why('rate limit: too many reports from this network, try later'));
    if (status == 400 || status == 413 || status == 415) throw ReportUploadException('rejected', why('the receiver refused the report'));
    if (status >= 500) throw ReportUploadException('server', why('the receiver failed'));
    throw ReportUploadException('failed', why('unexpected answer'));
  }
}

/// A report ready to leave: the gzip of its JSON and what may be read without decrypting.
class PackedReport {
  const PackedReport({required this.report, required this.gzipped, required this.meta});

  /// The report with the note in it (what [gzipped] decodes to).
  final Map<String, dynamic> report;
  final List<int> gzipped;
  final Map<String, dynamic> meta;
}

/// [report] with the user's [note] (cut to [reportNoteMax], masked by [redactor] like the rest of
/// the report, `note` field; empty = none) as gzipped JSON. `redactions` is brought up to date
/// with what the note cost. The caller built [report] with the same [redactor].
PackedReport packReport(Map<String, dynamic> report, {String note = '', Redactor? redactor}) {
  final out = <String, dynamic>{...report};
  var n = note.trim();
  if (n.length > reportNoteMax) n = n.substring(0, reportNoteMax);
  if (n.isNotEmpty) {
    final r = redactor;
    out['note'] = r == null ? n : r.text(n);
    if (r != null) out['redactions'] = {'total': r.total, 'byKind': {...r.counts}};
  }
  final json = utf8.encode(jsonEncode(out));
  final gz = gzip.encode(json);
  final app = (out['app'] as Map?) ?? const {};
  return PackedReport(
    report: out,
    gzipped: gz,
    meta: {
      'format': out['format'],
      'createdAt': out['createdAt'],
      for (final k in const ['version', 'versionCode', 'commit', 'platform'])
        if (app[k] != null) k: app[k],
      'bytes': json.length,
      'gzipBytes': gz.length,
      'noteLength': n.length,
    },
  );
}
