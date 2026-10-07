import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// A file the user chose to restore from.
class PickedFile {
  const PickedFile(this.name, this.text);

  final String name;
  final String text;
}

/// The backup's two file dialogs (Settings -> Data): Android has the system picker
/// (FilesChannel, Kotlin: android_overlay/kotlin/FilesChannel.kt.tmpl), Windows a PowerShell
/// SaveFileDialog / OpenFileDialog. Tests put a fake into [current].
abstract class BackupIo {
  static BackupIo current = _PlatformBackupIo();

  /// Asks where to save and writes [text]; the saved file's name, null when the user closed the
  /// dialog. Throws when the file could not be written.
  Future<String?> save(String name, String text);

  /// Asks for a file and reads it (UTF-8); null when the user closed the dialog.
  Future<PickedFile?> pick();
}

class _PlatformBackupIo implements BackupIo {
  static const MethodChannel _channel = MethodChannel('jormungand/files');

  @override
  Future<String?> save(String name, String text) async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod<String>('save', {
          'name': name,
          'text': text,
        });
      } on PlatformException catch (e) {
        throw FileSystemException(e.message ?? e.code);
      }
    }
    if (Platform.isWindows) {
      final path = await _dialog('''
\$d = New-Object System.Windows.Forms.SaveFileDialog
\$d.Filter = 'JSON (*.json)|*.json'
\$d.FileName = '${_ps(name)}'
\$d.OverwritePrompt = \$true
if (\$d.ShowDialog() -eq 'OK') { [Console]::Out.Write(\$d.FileName) }
''');
      if (path == null) return null;
      await File(path).writeAsString(text, encoding: utf8);
      return path.split(RegExp(r'[\\/]')).last;
    }
    throw UnsupportedError('no file dialog on this platform');
  }

  @override
  Future<PickedFile?> pick() async {
    if (Platform.isAndroid) {
      try {
        final m = await _channel.invokeMapMethod<String, String>('pick');
        if (m == null) return null;
        return PickedFile(m['name'] ?? 'backup', m['text'] ?? '');
      } on PlatformException catch (e) {
        throw FileSystemException(e.message ?? e.code);
      }
    }
    if (Platform.isWindows) {
      final path = await _dialog('''
\$d = New-Object System.Windows.Forms.OpenFileDialog
\$d.Filter = 'JSON (*.json)|*.json|All files (*.*)|*.*'
if (\$d.ShowDialog() -eq 'OK') { [Console]::Out.Write(\$d.FileName) }
''');
      if (path == null) return null;
      final file = File(path);
      return PickedFile(
        path.split(RegExp(r'[\\/]')).last,
        await file.readAsString(encoding: utf8),
      );
    }
    throw UnsupportedError('no file dialog on this platform');
  }

  /// Runs a WinForms dialog script; the chosen path or null.
  Future<String?> _dialog(String body) async {
    final script =
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8\n'
        'Add-Type -AssemblyName System.Windows.Forms\n$body';
    final r = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      stdoutEncoding: utf8,
    );
    final out = (r.stdout as String).trim();
    if (r.exitCode != 0) {
      throw FileSystemException('${r.stderr}'.trim());
    }
    return out.isEmpty ? null : out;
  }

  static String _ps(String s) => s.replaceAll("'", "''");
}

/// Android: the APK the running app was installed from (`applicationInfo.sourceDir`); the core
/// hashes it to pick a delta update and applies the patch to it. Null elsewhere / when the
/// platform does not say.
Future<String?> installedApkPath() async {
  if (!Platform.isAndroid) return null;
  try {
    return await const MethodChannel(
      'jormungand/files',
    ).invokeMethod<String>('installedPackage');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Android: hands the downloaded, verified APK to the system installer (Kotlin
/// UpdateInstaller). Resolves to true when the installer took it; false when it did not (the
/// "Install unknown apps" screen was opened, the file did not pass the check, the user declined).
Future<bool> installApk(String path) async {
  if (!Platform.isAndroid) return false;
  try {
    final why = await const MethodChannel(
      'jormungand/files',
    ).invokeMethod<String>('install', {'path': path});
    return why == null;
  } on PlatformException {
    return false;
  }
}
