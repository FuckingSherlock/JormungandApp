// The decision of every export save (widgets/save_flow.dart): no folder -> the picker / Save as,
// a folder -> "Save <file> to <folder>?", a revoked folder -> the picker again with a one-line reason.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/platform/files_channel.dart';
import 'package:jormungand/widgets/save_flow.dart';

import 'fake_backup_io.dart';
import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

void main() {
  late FakeBackupIo io;
  late BuildContext ctx;

  Future<void> start(WidgetTester tester, FakeBackupIo fake) async {
    io = fake;
    BackupIo.current = io;
    await pumpApp(tester, FakeCoreHost());
    ctx = tester.element(find.byType(Scaffold).first);
  }

  Future<SavedFile?> run(WidgetTester tester, {required bool android}) {
    final f = saveExport(ctx, android: android, name: 'a.json', text: 'T');
    return f;
  }

  testWidgets('Android, no folder: the folder picker, then the file lands there', (tester) async {
    await start(tester, FakeBackupIo(folder: null));
    final f = run(tester, android: true);
    await tester.pumpAndSettle();
    expect(find.textContaining('Save a.json'), findsNothing);
    expect(io.calls, ['chooseFolder', 'saveToFolder']);
    final s = (await f)!;
    expect(s.label, 'Documents/a.json');
  });

  testWidgets('Android, a folder: asks first; Save writes there without any system dialog', (tester) async {
    await start(tester, FakeBackupIo());
    final f = run(tester, android: true);
    await tester.pumpAndSettle();
    expect(find.text('Save a.json to Downloads?'), findsOneWidget);
    expect(io.calls, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(io.calls, ['saveToFolder']);
    expect((await f)!.label, 'Downloads/a.json');
  });

  testWidgets('the question: Choose folder opens the picker, Cancel does nothing', (tester) async {
    await start(tester, FakeBackupIo());
    var f = run(tester, android: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(io.calls, ['chooseFolder', 'saveToFolder']);
    expect((await f)!.folder, 'Documents');

    io.calls.clear();
    f = run(tester, android: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await f, isNull);
    expect(io.calls, isEmpty);
  });

  testWidgets('Android, the folder was revoked: the picker opens with a one-line reason', (tester) async {
    await start(tester, FakeBackupIo()..gone = true);
    final f = run(tester, android: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(io.calls, ['saveToFolder', 'chooseFolder', 'saveToFolder']);
    expect(find.textContaining('gone or no longer allowed'), findsOneWidget);
    expect((await f)!.folder, 'Documents');
  });

  testWidgets('a closed picker saves nothing', (tester) async {
    await start(tester, FakeBackupIo(folder: null)..picks = null);
    final f = run(tester, android: true);
    await tester.pumpAndSettle();
    expect(await f, isNull);
    expect(io.calls, ['chooseFolder']);
  });

  testWidgets('Windows: no folder -> Save as; a folder -> question with Save as… as the second action', (tester) async {
    await start(tester, FakeBackupIo(folder: null));
    var f = run(tester, android: false);
    await tester.pumpAndSettle();
    expect(io.calls, ['saveAs']);
    expect(await f, isNotNull);

    io.calls.clear();
    f = run(tester, android: false);
    await tester.pumpAndSettle();
    expect(find.text('Save as…'), findsOneWidget);
    expect(find.text('Choose folder'), findsNothing);
    await tester.tap(find.text('Save as…'));
    await tester.pumpAndSettle();
    expect(io.calls, ['saveAs']);
    await f;
  });

  testWidgets('Windows, the folder is gone: Save as with the reason', (tester) async {
    await start(tester, FakeBackupIo()..gone = true);
    final f = run(tester, android: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(io.calls, ['saveToFolder', 'saveAs']);
    expect(find.textContaining('Pick where to save'), findsOneWidget);
    await f;
  });

  testWidgets('a failed write is thrown to the caller (it shows the failure)', (tester) async {
    await start(tester, FakeBackupIo()..fail = StateError('disk full'));
    final f = run(tester, android: true);
    unawaited(f.then((_) {}, onError: (_) {}));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await expectLater(f, throwsStateError);
  });
}
