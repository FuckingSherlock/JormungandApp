// Opens a support report that came from the receiving Worker (docs/logs.md -> Отправка).
//
//   dart run tool/decrypt_report.dart <file.bin> [--out report.json] [--key <private-key-file>] [--text]
//
// <file.bin> is the stored envelope. The private key is read from --key, else from
// %USERPROFILE%\.jormungand\report_private.key (written by tool/report_keys.dart). The report is
// written as pretty JSON to --out, or printed when there is no --out; --text writes the readable
// form ("Download log": a header, then events and raw lines) instead of JSON.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/report_crypto.dart';

Never _die(String msg, [int code = 1]) {
  stderr.writeln(msg);
  exit(code);
}

Future<void> main(List<String> args) async {
  String? input, out, keyPath;
  var text = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--out':
      case '--key':
        if (i + 1 >= args.length) _die('$a needs a value', 64);
        if (a == '--out') {
          out = args[++i];
        } else {
          keyPath = args[++i];
        }
      case '--text':
        text = true;
      default:
        if (a.startsWith('-') || input != null) _die('Unknown argument: $a (see the header of tool/decrypt_report.dart)', 64);
        input = a;
    }
  }
  if (input == null) _die('Usage: dart run tool/decrypt_report.dart <file.bin> [--out report.json] [--key <file>] [--text]', 64);

  final file = File(input);
  if (!file.existsSync()) _die('No such file: $input');
  try {
    final key = readReportKeyFile(File(keyPath ?? defaultReportKeyPath()));
    final report = await openReport(file.readAsBytesSync(), privateKey: key);
    // reportToText is the local "Download log" form and has no note (only a sent report has one)
    final note = report['note'];
    final body = text
        ? '${note is String && note.isNotEmpty ? '## Note\n$note\n\n' : ''}${reportToText(report)}'
        : '${const JsonEncoder.withIndent('  ').convert(report)}\n';
    if (out == null) {
      stdout.add(utf8.encode(body)); // UTF-8 whatever the console's code page is (--out is the safer way)
    } else {
      File(out).writeAsStringSync(body, flush: true);
      stdout.writeln('Report written to ${File(out).absolute.path}');
    }
  } on ReportCryptoException catch (e) {
    _die(e.message);
  }
}
