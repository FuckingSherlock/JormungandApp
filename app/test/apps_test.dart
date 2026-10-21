import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/platform/apps_io.dart';
import 'package:jormungand/widgets/apps_sheet.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// Counts the icons the rows ask for (a phone lists hundreds of apps).
class _IconHost extends FakeCoreHost {
  final asked = <String>[];

  @override
  Future<Uint8List?> appIcon(String pkg) async {
    asked.add(pkg);
    return null;
  }
}

const _tg = InstalledApp(pkg: 'org.telegram.messenger', name: 'Telegram');
const _chrome = InstalledApp(pkg: 'com.android.chrome', name: 'Chrome');
const _gms = InstalledApp(
  pkg: 'com.google.android.gms',
  name: 'Google Play services',
  system: true,
);

Future<void> _open(WidgetTester tester) async {
  final context = tester.element(find.byType(Scaffold).first);
  showApps(context);
  await tester.pumpAndSettle();
}

void main() {
  test('ChannelAppsIo: the list and the icon come over the channel', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('jormungand/apps');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'list':
          return [
            {'pkg': 'com.a', 'name': 'A', 'system': false},
            {'pkg': 'com.b', 'system': true}, // no label: the package
            {'name': 'broken'}, // no package: dropped
          ];
        case 'icon':
          if (call.arguments['pkg'] == 'com.a') return Uint8List.fromList([1, 2]);
          throw PlatformException(code: 'gone');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const io = ChannelAppsIo();
    final list = await io.list();
    expect(list.map((a) => (a.pkg, a.name, a.system)), [
      ('com.a', 'A', false),
      ('com.b', 'com.b', true),
    ]);
    expect(await io.icon('com.a'), [1, 2]);
    expect(await io.icon('com.gone'), isNull); // a failed icon is the letter tile, not an error
  });

  test('ChannelAppsIo off Android: no apps, no icons', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const io = ChannelAppsIo();
    expect(await io.list(), isEmpty);
    expect(await io.icon('com.a'), isNull);
  });

  testWidgets(
    'the picker lists the installed apps by filter and search, and asks the platform again',
    (tester) async {
      final host = FakeCoreHost()..apps = [_tg, _chrome, _gms];
      host.catalog.appRules['gone.app'] = AppRule(
        tcp: AppHalf(act: 'block'),
      )..unknown['name'] = 'Gone';
      await pumpApp(tester, host);
      await _open(tester);

      expect(host.appRefreshes, 1);
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('Chrome'), findsOneWidget);
      expect(find.text('Google Play services'), findsNothing); // system
      expect(find.text('Gone'), findsOneWidget); // a rule of an app that is not installed still shows (to change or clear it)

      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(find.text('Google Play services'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);

      await tester.tap(find.text('Configured'));
      await tester.pumpAndSettle();
      expect(find.text('Gone'), findsOneWidget); // by its kept name
      expect(find.text('Telegram'), findsNothing);

      await tester.tap(find.text('User'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'chr');
      await tester.pumpAndSettle();
      expect(find.text('Chrome'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No apps'), findsOneWidget);
    },
  );

  testWidgets('a tap opens the app sheet; Direct + Save stores the rule', (
    tester,
  ) async {
    final host = FakeCoreHost()..apps = [_tg, _chrome];
    await pumpApp(tester, host, width: 560); // the test font (Ahem) is wide: the dialog's rows need room
    await _open(tester);

    await tester.tap(find.text('Telegram'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget); // the app's own sheet (it replaced the dialog)
    await tester.tap(find.text('Direct').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final r = host.catalog.appRules['org.telegram.messenger']!;
    expect(r.tcp.act, 'direct');
    expect(r.split, isFalse);
    expect(r.unknown['name'], 'Telegram'); // kept with the rule
    // the row now says so (the apps sheet is still open under the app's sheet)
    expect(find.text('Direct'), findsOneWidget);
    // and the plan carries it as a package app with its name
    final apps = host.catalog.routingPlan()['apps'] as List;
    expect(apps.single['id'], 'org.telegram.messenger');
    expect(apps.single['kind'], 'package');
    expect(apps.single['name'], 'Telegram');
    expect(apps.single['act'], 'direct');
  });

  testWidgets('hundreds of apps: only the rows on screen ask for an icon', (
    tester,
  ) async {
    final host = _IconHost()
      ..apps = [
        for (var i = 0; i < 400; i++)
          InstalledApp(pkg: 'com.app$i', name: 'App ${i.toString().padLeft(3, '0')}'),
      ];
    await pumpApp(tester, host);
    await _open(tester);

    expect(find.text('App 000'), findsOneWidget);
    expect(find.text('App 399'), findsNothing);
    expect(host.asked.length, greaterThan(3));
    expect(host.asked.length, lessThan(40));
  });
}
