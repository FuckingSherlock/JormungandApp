import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/connect_dock.dart';

import 'fake_core_host.dart';

/// The dock alone: [rowTaps] counts what would open Route.
Future<void> _pumpDock(
  WidgetTester tester,
  FakeCoreHost host,
  void Function() onRowTap, {
  bool tickers = true,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 1200);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppSettingsScope(
      settings: AppSettings(locale: const Locale('en')),
      child: CoreHostScope(
        host: host,
        child: MaterialApp(
          theme: appThemes[AppThemeId.original],
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: TickerMode(
            enabled: tickers,
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ConnectDock(onPower: () {}, onRowTap: onRowTap),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a tap on the latency pings and does not open Route; a second one stops', (
    tester,
  ) async {
    final host = FakeCoreHost();
    var rowTaps = 0;
    await _pumpDock(tester, host, () => rowTaps++);
    expect(host.dockPinging, isFalse);

    await tester.tap(find.text('48'));
    await tester.pump();
    expect(host.calls, ['dockPing start']);
    expect(rowTaps, 0);
    expect(host.dockPinging, isTrue);
    // the light runs round the frame
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.tap(find.text('ms'));
    await tester.pump();
    expect(host.calls, ['dockPing start', 'dockPing stop']);
    expect(rowTaps, 0);
    expect(host.dockPinging, isFalse);
    // nothing animates any more
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the rest of the dock row still opens Route', (tester) async {
    final host = FakeCoreHost();
    var rowTaps = 0;
    await _pumpDock(tester, host, () => rowTaps++);
    await tester.tap(find.text('Remnawave'));
    await tester.pump();
    expect(rowTaps, 1);
    expect(host.calls, isEmpty);
    await tester.tap(find.text('AUTO'));
    await tester.pump();
    expect(rowTaps, 2);
    expect(host.dockPinging, isFalse);
  });

  testWidgets('the light costs nothing while the page is out of sight (TickerMode off)', (
    tester,
  ) async {
    final host = FakeCoreHost();
    await _pumpDock(tester, host, () {}, tickers: false);
    await tester.tap(find.text('48'));
    await tester.pump();
    expect(host.dockPinging, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
