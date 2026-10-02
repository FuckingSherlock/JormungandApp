import 'dart:io';

/// Writes [text] to [f] so that a power cut leaves the old file or the new one, never a
/// file full of NUL bytes: the text goes to `<f>.tmp` and is flushed to the disk (fsync)
/// before the rename. (Renaming a file whose data is still in the cache is what left
/// `ui-state.json` empty after a power loss.) The rename replaces an existing file; on
/// Windows Dart does it with `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`.
Future<void> writeFileDurable(File f, String text) async {
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(f.path);
}

/// [writeFileDurable], synchronous.
void writeFileDurableSync(File f, String text) {
  final tmp = File('${f.path}.tmp');
  tmp.writeAsStringSync(text, flush: true);
  tmp.renameSync(f.path);
}
