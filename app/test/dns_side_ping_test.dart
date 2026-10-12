import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/settings_dns.dart';

import 'fake_core_host.dart';

void main() {
  testWidgets('DNS rows: a ping under each side chip, fits 320 px at 120 %', (t) async {
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(640, 2400);
    addTearDown(t.view.reset);
    final host = FakeCoreHost();
    await t.pumpWidget(
      AppSettingsScope(
        settings: AppSettings(textScale: 1.2, locale: const Locale('en')),
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
            home: const Scaffold(body: DnsSheet()),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    final cat = host.catalog;
    expect(host.calls.where((c) => c.startsWith('pingDns ')), isNotEmpty);
    final both = cat.dnsActive.firstWhere((s) => s.activeSides.length == 2);
    // FakeCoreHost answers 24 ms on every active side
    for (final side in ['direct', 'vpn']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('dns-ping-${both.id}-$side')),
          matching: find.text('24 ms'),
        ),
        findsOneWidget,
        reason: side,
      );
    }
    // the ping sits under its chip, the chips on the right of the name
    final chip = t.getBottomLeft(find.byKey(ValueKey('dns-${both.id}-vpn'))).dy;
    expect(t.getTopLeft(find.byKey(ValueKey('dns-ping-${both.id}-vpn'))).dy, greaterThanOrEqualTo(chip));
    expect(
      t.getTopLeft(find.byKey(ValueKey('dns-${both.id}-direct'))).dx,
      greaterThanOrEqualTo(t.getTopRight(find.text(both.name).first).dx),
    );
  });
}
