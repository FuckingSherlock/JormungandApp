import 'dart:convert';
import 'dart:io' show gzip;

import 'redact.dart';

/// Sending the support report to the developers (docs/logs.md → Отправка). The core builds the
/// report, adds the user's note, masks it in the strict mode and gzips it; what happens to the bytes
/// next — the encryption on the device and the upload to the receiving Worker — is a
/// [ReportUploader], plugged in by the host. None is written yet: [NotConfiguredUploader].

/// The longest note the user can attach (characters; longer is cut).
const reportNoteMax = 500;

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
/// so it must be registered in `outside_tunnel.dart` when it is written. Throws a
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
