import 'package:jormungand/platform/files_channel.dart';

/// A BackupIo for tests: a remembered [folder] (null = none), what was asked of it in [calls].
class FakeBackupIo implements BackupIo {
  FakeBackupIo({this.folder = 'Downloads'});

  String? folder;
  PickedFile? file;
  String? name, text;
  Object? fail;

  /// The next [saveToFolder] says the folder is gone (the permission was revoked).
  bool gone = false;

  /// What [chooseFolder] returns (null = the user closed the picker).
  String? picks = 'Documents';

  /// What [saveAs] returns the next time (false = the user closed the dialog).
  bool saveAsOk = true;
  final calls = <String>[];

  @override
  Future<String?> exportFolder() async => folder;

  @override
  Future<String?> chooseFolder() async {
    calls.add('chooseFolder');
    if (picks != null) {
      folder = picks;
      gone = false;
    }
    return picks;
  }

  @override
  Future<SavedFile> saveToFolder(String name, String text) async {
    calls.add('saveToFolder');
    if (gone) throw const ExportFolderGone();
    if (fail != null) throw fail!;
    this.name = name;
    this.text = text;
    return SavedFile(name, folder!);
  }

  @override
  Future<SavedFile?> saveAs(String name, String text) async {
    calls.add('saveAs');
    if (!saveAsOk) return null;
    if (fail != null) throw fail!;
    this.name = name;
    this.text = text;
    folder = picks ?? folder;
    return SavedFile(name, folder ?? 'Documents');
  }

  @override
  Future<PickedFile?> pick() async => file;
}
