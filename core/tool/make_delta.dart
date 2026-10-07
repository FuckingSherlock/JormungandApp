// Makes a delta patch between two builds of an installer (docs/updates.md -> "Дельта-обновления").
//
//   dart run tool/make_delta.dart <old file> <new file> <patch out> [--block 4096] [--no-verify]
//
// The patch turns <old> into <new> (the app's updater applies it to the installed APK). After
// writing it the tool applies it to <old> and compares with <new> (skip: --no-verify). Prints
// key=value lines for scripts: from (sha256 of <old>), to (sha256 of <new>), size and sha256 of
// the patch, ratio (patch size / new size, in percent). Exit 0 = patch written and verified.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jormungand_core/jormungand_core.dart';

Never _die(String msg, [int code = 64]) {
  stderr.writeln(msg);
  exit(code);
}

Future<void> main(List<String> args) async {
  final files = <String>[];
  var block = 4096;
  var verify = true;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--no-verify') {
      verify = false;
    } else if (a == '--block') {
      if (++i >= args.length) _die('--block needs a value');
      block = int.tryParse(args[i]) ?? 0;
      if (block < 64 || block > 1 << 20) _die('--block is between 64 and 1048576');
    } else if (a.startsWith('--')) {
      _die('Unknown argument: $a (see the header of tool/make_delta.dart)');
    } else {
      files.add(a);
    }
  }
  if (files.length != 3) _die('Usage: dart run tool/make_delta.dart <old file> <new file> <patch out> [--block N] [--no-verify]');
  final [oldPath, newPath, outPath] = files;
  for (final f in [oldPath, newPath]) {
    if (!File(f).existsSync()) _die('File not found: $f');
  }
  final sw = Stopwatch()..start();
  final DeltaStats stats;
  try {
    stats = await makeDelta(oldPath: oldPath, newPath: newPath, outPath: outPath, blockSize: block);
  } catch (e) {
    _die('Could not make the patch: $e', 1);
  }
  final made = sw.elapsedMilliseconds;
  if (verify) {
    final check = '$outPath.verify';
    try {
      await applyDelta(oldPath: oldPath, patchPath: outPath, outPath: check, expectOldSha256: stats.oldSha256, expectNewSha256: stats.newSha256);
    } catch (e) {
      File(outPath).deleteSync();
      _die('The patch does not apply back to the new file: $e', 1);
    } finally {
      final c = File(check);
      if (c.existsSync()) c.deleteSync();
    }
  }
  final patchSha = (await sha256.bind(File(outPath).openRead()).first).toString();
  stderr.writeln('$stats; made in $made ms${verify ? ', applied back in ${sw.elapsedMilliseconds - made} ms' : ''}');
  stdout.writeln('from=${stats.oldSha256}');
  stdout.writeln('to=${stats.newSha256}');
  stdout.writeln('size=${stats.patchSize}');
  stdout.writeln('sha256=$patchSha');
  stdout.writeln('ratio=${stats.newSize == 0 ? 0 : (stats.patchSize * 100 / stats.newSize).toStringAsFixed(1)}');
}
