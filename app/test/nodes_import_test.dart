import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/platform/import_io.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/nodes_menus.dart';
import 'package:jormungand/widgets/qr_box.dart';
import 'package:jormungand/widgets/source_card.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// Scripted camera / file dialog: no camera, no system picker in a widget test.
class _FakeImportIo implements ImportIo {
  _FakeImportIo({this.scanned, this.picked, this.failure});

  final String? scanned;
  final PickedFile? picked;
  final ImportFailure? failure;
  int scans = 0;
  int picks = 0;

  @override
  Future<String?> scan(BuildContext context) async {
    scans++;
    return scanned;
  }

  @override
  Future<PickedFile?> pickFile() async {
    picks++;
    if (failure != null) throw ImportException(failure!);
    return picked;
  }
}

/// A list of two links, as a user's file `my list.txt`.
const _listFile = PickedFile(
  'my list.txt',
  'vless://11111111-1111-1111-1111-111111111111@one.example.com:443?security=tls&sni=one.example.com#One\n'
  'trojan://pw@two.example.com:443?sni=two.example.com#Two\n',
);

/// The ⋮ of the first source card.
Finder _cardMenu() => find.descendant(
  of: find.byType(SourceCard).first,
  matching: find.byIcon(Icons.more_vert),
);

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

  testWidgets('Import config file: garbage says so and adds nothing', (
    tester,
  ) async {
    final io = _FakeImportIo(picked: const PickedFile('junk.json', 'text'));
    ImportIo.current = io;
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await _openAddMenu(tester);

    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    expect(io.picks, 1);
    expect(
      find.text('Could not import junk.json: No servers found in the file'),
      findsOneWidget,
    );
    expect(host.catalog.sourceOrder, isEmpty);
    expect(find.byType(SourceCard), findsNothing);
  });

  testWidgets('Import config file: a file becomes an opened local source', (
    tester,
  ) async {
    ImportIo.current = _FakeImportIo(picked: _listFile);
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await _openAddMenu(tester);

    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    final s = host.catalog.sourcesData['src1']!;
    expect(s.kind, 'file');
    expect(s.name, 'my list');
    expect(s.url, isNull);
    expect(find.text('Imported 2 servers from my list'), findsOneWidget);
    // the card: the label instead of a format, nodes (not servers), the age of the import
    expect(find.text('my list'), findsOneWidget);
    expect(find.text('local file'), findsOneWidget);
    expect(find.text('2 nodes'), findsOneWidget);
    expect(find.text('now'), findsOneWidget);
    // opened: its servers are listed
    expect(find.textContaining('One', findRichText: true), findsOneWidget);
    expect(find.textContaining('Two', findRichText: true), findsOneWidget);
    // nothing of a subscription: no update, no usage line, no error strip
    expect(find.byTooltip('Update'), findsNothing);
    expect(find.textContaining('No expiry'), findsNothing);
    expect(find.text('Couldn’t load'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Local file card: menu has Rename, Route settings, Delete only', (
    tester,
  ) async {
    ImportIo.current = _FakeImportIo(picked: _listFile);
    await pumpApp(tester, FakeCoreHost());
    await _openAddMenu(tester);
    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    await tester.tap(_cardMenu());
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Route settings'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Edit subscription'), findsNothing);
    expect(find.text('Update with all user agents'), findsNothing);
    expect(find.text('Copy URL'), findsNothing);
    expect(find.text('Show QR code'), findsNothing);
  });

  testWidgets('Local file card: Rename edits the name only', (tester) async {
    ImportIo.current = _FakeImportIo(picked: _listFile);
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await _openAddMenu(tester);
    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    await tester.tap(_cardMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    // a form with the name alone
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Subscription URL'), findsNothing);
    expect(find.text('Updates'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Home list');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(host.catalog.sourcesData['src1']!.name, 'Home list');
    expect(find.text('Home list'), findsOneWidget);
    expect(host.calls, isNot(contains(startsWith('updateSource'))));
  });

  testWidgets('Local file card: Delete says what goes with the file', (
    tester,
  ) async {
    ImportIo.current = _FakeImportIo(picked: _listFile);
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await _openAddMenu(tester);
    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    await tester.tap(_cardMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('The imported file and its 2 servers are removed'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete imported file'));
    await tester.pumpAndSettle();
    expect(host.catalog.sourceOrder, isEmpty);
  });

  testWidgets('Import config file: an image goes the way of a QR code', (
    tester,
  ) async {
    ImportIo.current = _FakeImportIo(
      picked: const PickedFile(
        'qr.png',
        'https://alpha.example.com/sub',
        qr: true,
      ),
    );
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await _openAddMenu(tester);

    await tester.tap(find.text('Import config file'));
    await tester.pumpAndSettle();

    expect(host.calls, isNot(contains(startsWith('importConfigFile'))));
    expect(find.text('Add subscription'), findsWidgets);
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
