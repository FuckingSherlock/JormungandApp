import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'redact.dart';
import 'report_crypto.dart';
import 'stall_guard.dart';

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

/// Connecting to the receiver (TCP and the TLS handshake).
const reportConnectTimeout = Duration(seconds: 10);

// The seconds of each stage of a send; [reportSendDeadline] is built from them.
const _probeSeconds = 3;
const _attemptSeconds = 10;
const _marginSeconds = 5;

/// The bulk probe of a way to the receiver (POST [reportProbePath] with [reportProbeBytes] of random
/// data, which the Worker echoes back), all of it: TCP, TLS, a body up and a body down. Both ways are
/// probed at the same time, directly and through the tunnel; each has this long. Short: it only
/// decides which way is worth the upload.
const reportProbeTimeout = Duration(seconds: _probeSeconds);

/// When both ways can pass, the tunnel is preferred: once the direct probe has passed, the tunnel's is
/// waited for this much longer (and not past [reportProbeTimeout]).
const reportTunnelGrace = Duration(milliseconds: 300);

/// The Worker's health path (workers/reports → `POST /v1/ping`), answered before the rate limit.
const reportProbePath = '/v1/ping';

/// The probe's body, and what a healthy path must bring back. A DPI that freezes a connection to the
/// CDN after ~16–20 KB lets a tiny request through, but not this one.
const reportProbeBytes = 32 * 1024;

/// An upload's way is dead when, while the body is going out, the connection accepts no bytes for
/// this long (the DPI freeze: the send buffer fills and stays full).
const reportStallTimeout = Duration(seconds: 3);

/// An upload's way is dead when no response has started this long after the whole body went out
/// (the freeze that came after the buffer took everything).
const reportResponseTimeout = Duration(seconds: 5);

/// The absolute cap of one upload attempt (connect, send, the answer): the safety under the stall
/// detection.
const reportAttemptTimeout = Duration(seconds: _attemptSeconds);

/// What building, masking and encrypting the report may add on top of the probes and the attempts.
const reportBuildMargin = Duration(seconds: _marginSeconds);

/// Everything "Send report" does (build, mask, encrypt, probes, an upload on the first way and, when
/// that fails, on the other) must end within this, success or not (CoreService.sendReport): the user
/// is never left on "Sending…". The app counts it down.
const reportSendDeadline = Duration(seconds: _probeSeconds + 2 * _attemptSeconds + _marginSeconds);

/// What a finished upload gives back.
class ReportReceipt {
  const ReportReceipt({required this.id, this.at, this.via = 'direct', this.firstError});

  /// The report's id on the receiving side: what the user quotes in a message.
  final String id;

  /// When the receiver accepted it (its clock), if it says.
  final DateTime? at;

  /// The way it went: `vpn` (through the running tunnel) or `direct` (outside the tunnel).
  final String via;

  /// Why the first way failed (`via VPN: …` or `direct: …`), when this one is the second: the probe
  /// of the first way did not pass, or its upload stalled / failed.
  final String? firstError;
}

/// Stops an upload that is under way (the user's Cancel, the overall deadline): [cancel] makes
/// [whenCancelled] complete and an uploader that honours it closes its connection.
class ReportCancel {
  final _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;

  /// Completes when [cancel] is called; never otherwise.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// An upload that did not go through. [code] is machine-readable and shown by the app in the
/// user's language: `not-configured` (no uploader plugged in), `network` (no connection to the
/// receiver), `rejected` (the receiver refused it: size, rate limit, bad format), `server` (the
/// receiver failed), `no-route` (the direct probe and upload both failed and the VPN is not up to carry it),
/// `cancelled` (the user stopped it), `timeout` (the whole send did not end in
/// [reportSendDeadline]), `failed` (anything else); [message] is for the log and for the developer.
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
/// `commit`, `platform`, `bytes` (the report as JSON), `gzipBytes`, `noteLength`, and `note` (the
/// user's note after the strict redactor; absent when empty).
///
/// [proxyPort]: the running tunnel's local proxy (tunnel-in), null while not connected — the first
/// way to the receiver when it is up, the direct one is the fallback. [cancel] aborts the upload
/// (`cancelled`).
abstract interface class ReportUploader {
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta, int? proxyPort, ReportCancel? cancel});
}

/// The default: no receiver is configured, so nothing leaves the device.
class NotConfiguredUploader implements ReportUploader {
  const NotConfiguredUploader();

  @override
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta, int? proxyPort, ReportCancel? cancel}) =>
      Future.error(const ReportUploadException('not-configured'));
}

/// The real uploader: encrypts the gzipped report to [publicKey] on the device ([encryptReport],
/// envelope `JRP1`) and POSTs the envelope to [endpoint] (the Worker, docs/logs.md → Отправка →
/// Контракт). `X-Jorm-*` headers carry the plain part of `meta` (format, version, build, platform,
/// envelope size); there is no auth header, the Worker takes anonymous uploads and limits them.
///
/// The order of the ways is picked by probes ([_probe]: POST of [reportProbeBytes] to
/// [reportProbePath], which the Worker echoes; only an echo of the full size proves a way carries a
/// real upload). With the tunnel up (`proxyPort != null`) both ways are probed at once — directly
/// (outside the tunnel, by the self rule, outside_tunnel.dart → `report-upload`) and through the
/// tunnel's local proxy; the tunnel goes first when its probe passes (the direct path to the receiver
/// is the one a DPI chokes), the direct one when only its probe passed; when neither passed, the
/// tunnel first anyway. A failed probe never stops the send: it is "not confirmed", not "no way". With
/// the tunnel down only the direct way exists; its upload failing after a failed probe is `no-route`.
/// The envelope goes out on the first way (`via` = `vpn` | `direct`); an answer of the receiver, of any
/// status, is final. A network failure of the upload (a connection error, no bytes accepted for
/// [stallTimeout], no response in [responseTimeout] after the body, [attemptTimeout] overall) sends it
/// once more on the other way (VPN up), its probe passed or not.
class HttpReportUploader implements ReportUploader {
  HttpReportUploader({
    this.endpoint = reportEndpoint,
    this.publicKey = reportPublicKey,
    this.connectTimeout = reportConnectTimeout,
    this.attemptTimeout = reportAttemptTimeout,
    this.stallTimeout = reportStallTimeout,
    this.responseTimeout = reportResponseTimeout,
    this.probeTimeout = reportProbeTimeout,
    this.tunnelGrace = reportTunnelGrace,
    this.maxBytes = reportMaxBytes,
  });

  final String endpoint;

  /// Base64 of the recipient's X25519 public key.
  final String publicKey;

  /// Connecting (TCP and TLS) of the upload.
  final Duration connectTimeout;

  /// The absolute cap of one upload attempt (connecting, sending, the answer).
  final Duration attemptTimeout;

  /// No upload bytes accepted for this long = the way is dead.
  final Duration stallTimeout;

  /// No response started this long after the body went out = the way is dead.
  final Duration responseTimeout;

  /// The whole bulk probe, of each way.
  final Duration probeTimeout;

  /// How long the tunnel's probe is waited for after the direct one passed.
  final Duration tunnelGrace;

  /// The envelope is not sent when it is bigger ([reportMaxBytes], the Worker's own limit).
  final int maxBytes;

  @override
  Future<ReportReceipt> upload(List<int> gzipped,
      {required Map<String, dynamic> meta, int? proxyPort, ReportCancel? cancel}) async {
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
    final Uri uri;
    try {
      uri = Uri.parse(endpoint);
    } on FormatException catch (e) {
      throw ReportUploadException('failed', 'bad report endpoint: ${e.message}');
    }
    if (cancel != null && cancel.isCancelled) throw const ReportUploadException('cancelled');

    final vpnOn = proxyPort != null;
    void checkCancel() {
      if (cancel != null && cancel.isCancelled) throw const ReportUploadException('cancelled');
    }

    // 1. probe the ways at once: directly, and through the tunnel when it is up
    // (what each probe said, as far as it has finished: a probe still running says nothing)
    String? directErr, tunnelErr;
    var directDone = false, tunnelDone = false;
    final directProbe = _probe(uri, null, cancel).then((e) {
      directDone = true;
      directErr = e;
      return e;
    });
    final tunnelProbe = vpnOn
        ? _probe(uri, proxyPort, cancel).then((e) {
            tunnelDone = true;
            tunnelErr = e;
            return e;
          })
        : null;

    // 2. the first way: the probes only choose the order, a failed one means "not confirmed", not "no
    // way". A passed tunnel probe: the tunnel (the direct probe's pass gives it only a short grace);
    // only the direct one passed: direct; neither: the tunnel first, direct second (VPN down: direct).
    final bool firstVpn;
    String? probeError; // why the tunnel was passed over, when it was
    if (tunnelProbe == null) {
      await directProbe;
      checkCancel();
      firstVpn = false;
    } else {
      final t = await Future.any<({String? err})?>([
        tunnelProbe.then((e) => (err: e)),
        directProbe.then<({String? err})?>((e) async {
          if (e != null) return Completer<({String? err})?>().future; // no direct pass: wait for the tunnel's probe
          await Future<void>.delayed(tunnelGrace);
          return null; // the grace is over, the tunnel's probe has not passed in time
        }),
      ]);
      checkCancel();
      if (t != null && t.err == null) {
        firstVpn = true;
      } else if (t == null) {
        firstVpn = false; // the direct probe passed, the tunnel's is late: not waited for
      } else {
        final d = await directProbe;
        checkCancel();
        firstVpn = d != null; // neither passed: the tunnel first
        if (!firstVpn) probeError = 'via VPN: probe: ${t.err}';
      }
    }

    // 3. the upload on the first way; a receiver's answer, of any status, is final
    String label(bool vpn) => vpn ? 'via VPN' : 'direct';
    // why a way failed: the reason of its probe (when that failed) with the upload's
    String why(bool vpn, String upload) {
      final probe = vpn ? (tunnelDone ? tunnelErr : null) : (directDone ? directErr : null);
      return '${label(vpn)}: ${probe == null ? '' : 'probe: $probe, upload: '}$upload';
    }

    ReportReceipt receipt(ReportReceipt r, bool vpn, String? first) =>
        ReportReceipt(id: r.id, at: r.at, via: vpn ? 'vpn' : 'direct', firstError: first);
    Future<ReportReceipt> go(bool vpn) =>
        _attempt(uri, envelope, meta, proxyPort: vpn ? proxyPort : null, vpnOn: vpnOn, cancel: cancel);
    try {
      return receipt(await go(firstVpn), firstVpn, probeError);
    } on ReportUploadException catch (e1) {
      if (e1.code != 'network') rethrow;
      checkCancel();
      if (!vpnOn) {
        final p = directErr;
        if (p != null) {
          throw ReportUploadException(
              'no-route', 'no direct path to the receiver (probe: $p, upload: ${e1.message}) and the VPN is not connected');
        }
        rethrow;
      }
      // 4. a network failure: once on the other way, whether its probe passed or not (a probe still
      // running is not waited for)
      final secondVpn = !firstVpn;
      final firstWhy = why(firstVpn, e1.message);
      try {
        return receipt(await go(secondVpn), secondVpn, firstWhy);
      } on ReportUploadException catch (e2) {
        if (e2.code != 'network') rethrow;
        throw ReportUploadException('network', '$firstWhy; ${why(secondVpn, e2.message)}');
      }
    }
  }

  /// The bulk probe of one way ([proxyPort] null = directly): POST [reportProbeBytes] of random bytes
  /// to [reportProbePath] of the receiver's origin. null = it answered 200 with a body of exactly that
  /// size (the Worker echoes it); anything else — refusal, TLS, a stall after the first KB, another
  /// status or length — is why not. Ends within [probeTimeout] or at [cancel] (then null: the caller
  /// checks the token).
  Future<String?> _probe(Uri uri, int? proxyPort, ReportCancel? cancel) async {
    final client = HttpClient()
      ..connectionTimeout = probeTimeout
      ..findProxy = ((_) => proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort')
      ..userAgent = null;
    try {
      final url = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: reportProbePath);
      final rnd = Random.secure();
      final body = Uint8List.fromList([for (var i = 0; i < reportProbeBytes; i++) rnd.nextInt(256)]);
      final done = () async {
        final req = await client.postUrl(url);
        req.followRedirects = false;
        req.headers.contentType = ContentType.binary;
        req.contentLength = body.length;
        req.add(body);
        final res = await req.close();
        var n = 0;
        await for (final chunk in res) {
          n += chunk.length;
          if (n > reportProbeBytes) break;
        }
        if (res.statusCode != 200) return 'the ping answered HTTP ${res.statusCode}';
        if (n != reportProbeBytes) return 'the ping echoed $n bytes of $reportProbeBytes';
        return null;
      }()
          .timeout(probeTimeout, onTimeout: () => throw TimeoutException('no echo in ${_dur(probeTimeout)}'));
      if (cancel == null) return await done;
      return await Future.any<String?>([done, cancel.whenCancelled.then<String?>((_) => null)]);
    } on TimeoutException catch (e) {
      return e.message ?? 'timeout';
    } catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// One try: a new client, so nothing of a stalled connection is reused; [proxyPort] null = direct;
  /// [vpnOn]: the tunnel is connected (told to the receiver). Ends within [attemptTimeout] (and sooner
  /// when the way stalls, [_post]) or at [cancel], and leaves no connection open.
  Future<ReportReceipt> _attempt(Uri uri, Uint8List envelope, Map<String, dynamic> meta,
      {required int? proxyPort, required bool vpnOn, ReportCancel? cancel}) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort')
      ..userAgent = null;
    final way = proxyPort == null ? 'direct' : 'via VPN';
    try {
      final done = _post(client, uri, envelope, meta, via: proxyPort == null ? 'direct' : 'vpn', way: way, vpnOn: vpnOn).timeout(
        attemptTimeout,
        onTimeout: () => throw TimeoutException('the receiver did not answer in ${_dur(attemptTimeout)} ($way)'),
      );
      if (cancel == null) return await done;
      return await Future.any([
        done,
        cancel.whenCancelled.then<ReportReceipt>((_) => throw const ReportUploadException('cancelled')),
      ]);
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

  Future<ReportReceipt> _post(HttpClient client, Uri uri, Uint8List envelope, Map<String, dynamic> meta,
      {required String via, required String way, required bool vpnOn}) async {
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
    h('X-Jorm-Via', via);
    h('X-Jorm-Vpn', vpnOn ? 'on' : 'off');
    // The user's note, already masked by the strict redactor (packReport), in the open so the
    // developer reads it without the key; base64url keeps it printable ASCII. It is also in the report.
    final note = meta['note'];
    if (note is String && note.isNotEmpty) {
      req.headers.set('X-Jorm-Note', base64Url.encode(utf8.encode(note)).replaceAll('=', ''));
    }
    // The body in pieces, each flushed: a piece the connection does not take for [stallTimeout] means
    // the way is frozen (the DPI cuts a connection to the CDN after ~16–20 KB), no need to wait for the
    // overall cap.
    for (var i = 0; i < envelope.length; i += _chunk) {
      req.add(Uint8List.sublistView(envelope, i, min(i + _chunk, envelope.length)));
      await stallWatch(req.flush(), stallTimeout, 'the upload stalled: no bytes accepted for ${_dur(stallTimeout)} ($way)');
    }
    // Everything went out; now the response must start (and be read) in time.
    final answer = () async {
      final res = await req.close();
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        if (b.length < _answerMax) b.add(chunk);
      }
      return _receipt(res.statusCode, utf8.decode(b.takeBytes(), allowMalformed: true), res.headers.date);
    }();
    return answer.timeout(responseTimeout,
        onTimeout: () => throw TimeoutException('no response within ${_dur(responseTimeout)} after the upload ($way)'));
  }

  /// A span for a message: whole seconds as «3 s», else milliseconds.
  static String _dur(Duration d) => spanText(d);

  /// The size of one piece of the body ([_post]).
  static const _chunk = 16 * 1024;

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
      if (n.isNotEmpty) 'note': out['note'],
    },
  );
}
