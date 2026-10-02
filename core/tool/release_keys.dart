// Generates the Ed25519 key pair that signs release manifests (docs/updates.md).
//
//   dart run tool/release_keys.dart <private-key-file>
//
// The private key goes to the file given (base64 of the 32-byte seed), NEVER into this
// repository: the tool refuses a path inside any git working tree and never overwrites a
// file. Keep the file (and a copy) somewhere only the publisher can reach; whoever has it
// can ship code to every install. The PUBLIC key is printed: paste it into
// `releasePublicKeys` in core/lib/src/appupdate.dart.
import 'dart:io';

import 'package:jormungand_core/src/appupdate_release.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || args[0].startsWith('-')) {
    stderr.writeln('Usage: dart run tool/release_keys.dart <private-key-file>');
    exit(64);
  }
  final path = args[0];
  if (insideGitTree(path)) {
    stderr.writeln('Refusing: $path is inside a git working tree. Pick a path outside any repository.');
    exit(1);
  }
  final f = File(path);
  if (f.existsSync()) {
    stderr.writeln('Refusing to overwrite $path');
    exit(1);
  }
  final keys = await generateReleaseKeys();
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${keys.seedBase64}\n', flush: true);
  stdout.writeln('Private key written to ${f.absolute.path} (keep it secret, keep a backup).');
  stdout.writeln('Public key (paste into releasePublicKeys in core/lib/src/appupdate.dart):');
  stdout.writeln('');
  stdout.writeln("const releasePublicKeys = <String>['${keys.publicBase64}'];");
}
