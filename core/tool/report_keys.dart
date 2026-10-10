// Generates the X25519 key pair of the support reports (docs/logs.md -> Отправка).
//
//   dart run tool/report_keys.dart
//
// The private key goes to %USERPROFILE%\.jormungand\report_private.key (HOME on other systems;
// base64 of the 32 bytes), NEVER into this repository: an existing file is never overwritten, and
// nothing about the private key is printed. Keep the file and a copy somewhere only the developer
// can reach; whoever has it reads every report. The PUBLIC key is printed: paste it into
// `reportPublicKey` in core/lib/src/report_upload.dart (a new key = a new build; reports made with
// the old key stay readable only with the old private key, so keep the old file too).
import 'dart:io';

import 'package:jormungand_core/src/report_crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/report_keys.dart   (takes no arguments)');
    exit(64);
  }
  final path = defaultReportKeyPath();
  final f = File(path);
  if (f.existsSync()) {
    stderr.writeln('Refusing to overwrite $path (move it away first if a new key is really meant).');
    exit(1);
  }
  final keys = await generateReportKeys();
  Directory(p.dirname(path)).createSync(recursive: true);
  try {
    f.createSync(exclusive: true);
  } on FileSystemException {
    stderr.writeln('Refusing to overwrite $path');
    exit(1);
  }
  f.writeAsStringSync('${keys.privateBase64}\n', flush: true);
  stdout.writeln('Private key written to ${f.absolute.path} (keep it secret, keep a backup).');
  stdout.writeln('Public key (paste into reportPublicKey in core/lib/src/report_upload.dart):');
  stdout.writeln('');
  stdout.writeln("const reportPublicKey = '${keys.publicBase64}';");
}
