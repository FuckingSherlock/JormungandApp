import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/stat_cards.dart';

import 'fake_core_host.dart';

void main() {
  testWidgets('stat cards fit 320 dp at 120 % text: no RenderFlex overflow', (
    tester,
  ) async {
    final host = FakeCoreHost()
      ..setTraffic(
        const TrafficInfo(
          down: 48.3 * 1024 * 1024,
          up: 6.1 * 1024 * 1024,
          downTotal: 1.84 * 1024 * 1024 * 1024,
          upTotal: 312 * 1024 * 1024,
          tcp: 43,
          udp: 8,
        ),
      )
      ..setPhase(ConnectionPhase.connected);
    await tester.pumpWidget(
      MaterialApp(
        theme: appThemes[AppThemeId.original],
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: const Size(320, 640),
            textScaler: const TextScaler.linear(1.2),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: StatCards(host: host),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1.84 GB'), findsOneWidget);
    expect(find.text('312 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
