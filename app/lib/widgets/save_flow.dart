import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/files_channel.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'rules_parts.dart' show showAppDialog;

/// What every export does to save a file (Logs -> Download log, Settings -> Data -> export backup),
/// so the system dialog does not open each time (docs/platforms.md, "Сохранение файлов"):
///  - no folder remembered yet: Android opens the folder picker, Windows the "Save as" dialog;
///  - a folder is remembered: a short question "Save FILE to FOLDER?" with Save / Choose folder
///    (Windows: Save as…) / Cancel;
///  - the remembered folder is gone or no longer allowed: the picker (Windows: Save as) again, with
///    a one-line explanation.
/// The file name the system gives (a taken name gets a suffix) is the one reported back.
/// [android] picks "Choose folder" over "Save as…". Null: the user backed out. Throws when the
/// write failed.
Future<SavedFile?> saveExport(
  BuildContext context, {
  required bool android,
  required String name,
  required String text,
}) async {
  final io = BackupIo.current;
  final l10n = context.l10n;

  Future<SavedFile?> elsewhere({bool gone = false}) async {
    if (gone && context.mounted) {
      showToast(
        context,
        android ? l10n.theFolderYouSavedToBefore : l10n.theFolderYouSavedToBefore2,
      );
    }
    if (!android) return io.saveAs(name, text);
    final folder = await io.chooseFolder();
    if (folder == null) return null;
    return io.saveToFolder(name, text);
  }

  final folder = await io.exportFolder();
  if (folder == null) return elsewhere();
  if (!context.mounted) return null;
  final c = context.colors;
  // true = save here, false = choose another, null = cancel
  final choice = await showAppDialog<bool>(
    context,
    title: l10n.saveTo(name, folder),
    builder: (_) => const SizedBox.shrink(),
    actions: (ctx) => [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(),
        child: Text(l10n.cancel, style: TextStyle(color: c.muted)),
      ),
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(false),
        child: Text(android ? l10n.chooseFolder : l10n.saveAs),
      ),
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(true),
        child: Text(l10n.save),
      ),
    ],
  );
  if (choice == null) return null;
  if (!choice) return elsewhere();
  return _into(io, name, text, () => elsewhere(gone: true));
}

Future<SavedFile?> _into(
  BackupIo io,
  String name,
  String text,
  Future<SavedFile?> Function() onGone,
) async {
  try {
    return await io.saveToFolder(name, text);
  } on ExportFolderGone {
    return onGone();
  }
}
