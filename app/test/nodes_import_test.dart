import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/platform/import_io.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/nodes_menus.dart';
import 'package:jormungand/widgets/qr_box.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// Scripted camera / file dialog: no camera, no system picker in a widget test.
class _FakeImportIo implements ImportIo {
  _FakeImportIo({this.scanned, this.picked, this.failure});

  final String? scanned;
  final String? picked;
  final ImportFailure? failure;
  int scans = 0;
  int picks = 0;

  @override
  Future<String?> scan(BuildContext context) async {
    scans++;
    return scanned;
  }

  @override
  Future<String?> pickFile() async {
    picks++;
    if (failure != null) throw ImportException(failure!);
    return picked;
  }
}

Future<void> _openAddMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.nodes.icon));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();
}

void main() {
  late ImportIo saved;
  setUp(() => saved = ImportIo.current);
  tearDown(() => ImportIo.current = saved);

  test('QrBox: a text that fits gets a code, one that does not gets null', () {
    expect(QrBox.of('https://example.com/sub'), isNotNull);
    expect(QrBox.of('x' * 4000), isNull);
  });

  testWidgets('Share sheet draws the code and keeps the text under it', (
    tester,
  ) async {
    await pumpApp(tester, FakeCoreHost());
    final context = tester.element(find.byType(Scaffold).first);
    showShareSheet(
      context,
      title: 'Alpha',
      text: 'https://alpha.example.com/sub',
      what: 'Subscription URL',
      copyLabel: 'Copy URL',
    );
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('https://alpha.example.com/sub'), findsOneWidget);
    expect(find.text('Copy URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Share sheet: a text too long for a QR code only says so', (
    tester,
  ) async {
    await pumpApp(tester, FakeCoreHost());
    final context = tester.element(find.byType(Scaffold).first);
    showShareSheet(
      context,
      title: 'Alpha',
      text: 'x' * 4000,
      what: 'Link',
      copyLabel: 'Copy',
    );
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('Too long for a QR code'), findsOneWidget);
  });

  testWidgets('Add menu on the desktop: no camera row, the file row stays', (
    tester,
  ) async {
    await pumpApp(tester, FakeCoreHost());
    await _openAddMenu(tester);

    expect(find.text('Scan QR code'), findsNothing);
    expect(find.text('Import config file'), findsOneWidget);
  });

  testWidgets('Scan QR code: a scanned URL opens the subscription form', (
    tester,
  ) async {
    final io = _FakeImportIo(scanned: 'https://alpha.example.com/sub');
    ImportIo.current = io;
    await pumpApp(tester, FakeCoreHost(android: true));
    await _openAddMenu(tester);

    await tester.tap(find.text('Scan QR code'));
    await tester.pumpAndSettle();

    expect(io.scans, 1);
    expect(find.text('Add subscription'), findsWidgets);
    expect(find.text('https://alpha.example.com/sub'), findsOneWidget);
  });

  testWidgets('Scan QR code: backing out of the camera changes nothing', (
    tester,
  ) async {
    final io = _FakeImportIo();
    ImportIo.current = io;
    await pumpApp(tester, FakeCoreHost(android: true));
    await _openAddMenu(tester);

    await tester.tap(find.text('Scan QR code'));
    await tester.pumpAndSettle();

    expect(io.scans, 1);
    expect(find.text('Add subscription'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('Import config file: text with no link says so', (tester) async {
    final io = _FakeImportIo(picked: 'just some text');
    ImportIo.current = io;
    await pumpApp(tester, FakeCoreHost());
    await _openAddMenu(tester);

    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    expect(io.picks, 1);
    expect(
      find.text('No subscription URL or server link found'),
      findsOneWidget,
    );
  });

  testWidgets('Import config file: an image without a QR code says so', (
    tester,
  ) async {
    ImportIo.current = _FakeImportIo(failure: ImportFailure.noQr);
    await pumpApp(tester, FakeCoreHost());
    await _openAddMenu(tester);

    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    expect(find.text('No QR code found in the image'), findsOneWidget);
  });

  testWidgets('Nodes: the round ? opens the tips of the screen', (
    tester,
  ) async {
    await pumpApp(tester, FakeCoreHost());
    await tester.tap(find.byIcon(AppTab.nodes.icon));
    await tester.pumpAndSettle();

    await tester.tap(find.text('?'));
    await tester.pumpAndSettle();

    // the tips are one rich text per line: the term bold, then its text
    expect(
      find.textContaining('Tap a server', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'everything traffic can go through',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
