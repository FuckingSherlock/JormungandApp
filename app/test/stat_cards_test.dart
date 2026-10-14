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

  testWidgets('exit card: a ring under the flag while rechecking, the answer stays', (
    tester,
  ) async {
    final host = FakeCoreHost()..setPhase(ConnectionPhase.connected);
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
              width: 160,
              child: ListenableBuilder(
                listenable: host,
                builder: (_, _) => ExitIpCard(host: host),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    const ring = ValueKey('exit-rechecking');
    expect(find.byKey(ring), findsNothing);

    host.setExit(
      const ExitState.found(
        ip: '203.0.113.7',
        country: 'DE',
        city: 'Frankfurt',
        rechecking: true,
      ),
    );
    await tester.pump();
    expect(find.byKey(ring), findsOneWidget);
    expect(find.text('203.0.113.7'), findsOneWidget);
    expect(find.text('Frankfurt, DE'), findsOneWidget);

    host.setExit(
      const ExitState.found(ip: '203.0.113.7', country: 'DE', city: 'Frankfurt'),
    );
    await tester.pump();
    expect(find.byKey(ring), findsNothing);
    expect(find.text('203.0.113.7'), findsOneWidget);

    // a switch to a node with a stored answer: that answer, the ring while the core checks it
    host.setExit(
      const ExitState.found(ip: '198.51.100.9', country: 'NL', city: 'Amsterdam', rechecking: true),
    );
    await tester.pump();
    expect(find.byKey(ring), findsOneWidget);
    expect(find.text('198.51.100.9'), findsOneWidget);
    expect(find.text('Amsterdam, NL'), findsOneWidget);

    // a failed check shows the error instead of the stored answer
    host.setExit(
      const ExitState.found(ip: '198.51.100.9', country: 'NL', city: 'Amsterdam', error: true),
    );
    await tester.pump();
    expect(find.text('198.51.100.9'), findsNothing);
    expect(find.text('Amsterdam, NL'), findsNothing);
    expect(find.byKey(ring), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
