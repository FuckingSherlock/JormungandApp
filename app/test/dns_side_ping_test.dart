import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/form_parts.dart' show PingSpinner;
import 'package:jormungand/widgets/settings_dns.dart';

import 'fake_core_host.dart';

void main() {
  testWidgets('side column: the chip stays in one place for a value, a spinner, a dash and no answer (320 px, 120 %)', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 800);
    addTearDown(t.view.reset);
    Widget side(String label, {int? ms, bool testing = false, String? kind, Key? key}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SideChip(key: key, label: label, on: true),
        DnsSidePingLine(ms: ms, testing: testing, kind: kind),
      ],
    );
    Widget rowOf(Key k, {int? ms, bool testing = false, String? kind}) => Row(
      children: [
        const Expanded(child: Text('Name', maxLines: 1, overflow: TextOverflow.ellipsis)),
        side('Direct', ms: ms, testing: testing, kind: kind, key: ValueKey('$k-d')),
        const SizedBox(width: 6),
        side('VPN', ms: ms, testing: testing, kind: kind, key: ValueKey('$k-v')),
      ],
    );
    await t.pumpWidget(
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
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.2)),
          child: w!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                rowOf(const ValueKey('a'), ms: 9999, kind: 'doq'),
                rowOf(const ValueKey('b'), ms: 84, kind: 'doh'),
                rowOf(const ValueKey('c'), testing: true),
                rowOf(const ValueKey('d')),
                rowOf(const ValueKey('e'), ms: -1),
                rowOf(const ValueKey('f'), ms: 7),
              ],
            ),
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
    for (final s in ['d', 'v']) {
      final xs = [for (final r in 'abcdef'.split('')) t.getTopLeft(find.byKey(ValueKey('${ValueKey(r)}-$s'))).dx];
      expect(xs.toSet().length, 1, reason: '$s: $xs');
    }
    expect(find.text('84ms'), findsNWidgets(2));
  });

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
          matching: find.text('24ms'),
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

  testWidgets('a suspect transport (no answer, still being confirmed) shows the warning sign and a spinner in the same slot', (t) async {
    await t.pumpWidget(
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
        home: const Scaffold(body: Column(children: [DnsSidePingLine(ms: -1, suspect: true)])),
      ),
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byType(PingSpinner), findsOneWidget);
    expect(find.byTooltip('No answer, re-checking'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
