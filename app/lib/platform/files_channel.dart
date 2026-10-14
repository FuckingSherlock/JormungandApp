import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A file the user chose to restore from.
class PickedFile {
  const PickedFile(this.name, this.text);

  final String name;
  final String text;
}

/// A file that was written: its actual [name] (the system adds a suffix when the name was taken)
/// and the [folder] it is in (display name).
class SavedFile {
  const SavedFile(this.name, this.folder);

  final String name;
  final String folder;

  /// What the user reads in "saved" messages.
  String get label => '$folder/$name';
}

/// The remembered export folder is gone or no longer allowed (Android: the permission was
/// revoked): the caller asks the user for a folder again.
class ExportFolderGone implements Exception {
  const ExportFolderGone();

  @override
  String toString() => 'the export folder is not available';
}

/// The file dialogs of the exports (Settings -> Data, Logs -> Download log) and of the backup
/// restore: Android has the system pickers (FilesChannel, Kotlin:
/// android_overlay/kotlin/FilesChannel.kt.tmpl), Windows a PowerShell SaveFileDialog /
/// OpenFileDialog. One export folder is remembered for all exports (Android: the tree URI of
/// "Choose folder", Windows: the folder of the last "Save as"). Tests put a fake into [current].
abstract class BackupIo {
  static BackupIo current = _PlatformBackupIo();

  /// Display name of the remembered export folder; null when none was chosen yet.
  Future<String?> exportFolder();

  /// Android: the system folder picker; remembers the folder. Its display name, null when the
  /// user closed the dialog.
  Future<String?> chooseFolder();

  /// Writes [text] into the remembered folder as [name] (a taken name gets a suffix). Throws
  /// [ExportFolderGone] when there is no usable folder, another error when the write failed.
  Future<SavedFile> saveToFolder(String name, String text);

  /// Windows: the system "Save as" dialog; the folder it ends in becomes the remembered one.
  /// Null when the user closed the dialog. Throws when the file could not be written.
  Future<SavedFile?> saveAs(String name, String text);

  /// Asks for a file and reads it (UTF-8); null when the user closed the dialog.
  Future<PickedFile?> pick();
}

class _PlatformBackupIo implements BackupIo {
  static const MethodChannel _channel = MethodChannel('jormungand/files');

  Future<T?> _android<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'folder_gone') throw const ExportFolderGone();
      throw FileSystemException(e.message ?? e.code);
    }
  }

  // Windows: the remembered folder is one line in a file next to the core's folder.
  Future<File> _folderFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}${Platform.pathSeparator}export_folder.txt');
  }

  Future<String?> _winFolder() async {
    final f = await _folderFile();
    if (!await f.exists()) return null;
    final v = (await f.readAsString(encoding: utf8)).trim();
    return v.isEmpty ? null : v;
  }

  static String _base(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  @override
  Future<String?> exportFolder() async {
    if (Platform.isAndroid) return _android<String>('folder');
    if (Platform.isWindows) {
      final dir = await _winFolder();
      return dir == null ? null : _base(dir);
    }
    return null;
  }

  @override
  Future<String?> chooseFolder() async {
    if (Platform.isAndroid) return _android<String>('chooseFolder');
    throw UnsupportedError('no folder picker on this platform');
  }

  @override
  Future<SavedFile> saveToFolder(String name, String text) async {
    if (Platform.isAndroid) {
      final m = await _android<Map<Object?, Object?>>('saveToFolder', {
        'name': name,
        'text': text,
      });
      return SavedFile('${m?['name'] ?? name}', '${m?['folder'] ?? ''}');
    }
    if (Platform.isWindows) {
      final dir = await _winFolder();
      if (dir == null || !await Directory(dir).exists()) {
        throw const ExportFolderGone();
      }
      final file = await _unique(dir, name);
      await file.writeAsString(text, encoding: utf8);
      return SavedFile(_base(file.path), _base(dir));
    }
    throw UnsupportedError('no file dialog on this platform');
  }

  /// `dir\name`, or `dir\name (1).ext`, `(2)`... when the name is taken.
  static Future<File> _unique(String dir, String name) async {
    final sep = Platform.pathSeparator;
    var f = File('$dir$sep$name');
    if (!await f.exists()) return f;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; ; i++) {
      f = File('$dir$sep$stem ($i)$ext');
      if (!await f.exists()) return f;
    }
  }

  @override
  Future<SavedFile?> saveAs(String name, String text) async {
    if (Platform.isWindows) {
      final filter = name.endsWith('.txt') ? 'Text (*.txt)|*.txt' : 'JSON (*.json)|*.json';
      final path = await _dialog('''
\$d = New-Object System.Windows.Forms.SaveFileDialog
\$d.Filter = '${_ps(filter)}'
\$d.FileName = '${_ps(name)}'
\$d.OverwritePrompt = \$true
if (\$d.ShowDialog() -eq 'OK') { [Console]::Out.Write(\$d.FileName) }
''');
      if (path == null) return null;
      await File(path).writeAsString(text, encoding: utf8);
      final cut = path.lastIndexOf(RegExp(r'[\\/]'));
      final dir = cut > 0 ? path.substring(0, cut) : path;
      await (await _folderFile()).writeAsString(dir, encoding: utf8);
      return SavedFile(_base(path), _base(dir));
    }
    throw UnsupportedError('no save dialog on this platform');
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
