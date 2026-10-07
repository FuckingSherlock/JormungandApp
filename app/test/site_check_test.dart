// The external checker (check-host) on site events: «Check with checker» runs the check and the same
// event is changed in place; a result that says the site opens elsewhere is the one that notifies; the
// Auto settings switch is kept in autoCfg and goes into the plan only when off.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand/widgets/settings_auto.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

const _gone = {'host': 'dead.example.com', 'entry': 'x', 'tried': <Object>[]};
const _nodes = [
  {'cc': 'DE', 'country': 'Germany', 'city': 'Frankfurt', 'ok': true, 'code': 200, 'ms': 200},
  {'cc': 'FR', 'country': 'France', 'ok': false, 'error': 'Connection timed out'},
];

void main() {
  testWidgets('«Check with checker»: pending (button dimmed), then the same event shows the verdict and the nodes; no new event', (tester) async {
    final host = FakeCoreHost()
      ..checkGate = Completer<void>()
      ..checkAnswer = {'state': 'down', 'ok': 0, 'total': 2, 'via': 'tunnel', 'nodes': _nodes};
    final e = host.addEvent('site', 'unreachable', level: 'warn', data: _gone);
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evCheck')), findsNothing);

    await tester.tap(find.text('Check with checker'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(host.checkedSites, [e['id']]);
    expect(find.text('Checking…'), findsOneWidget, reason: 'the button waits for the answer');
    expect(find.text('Asking check-host…'), findsOneWidget);

    host.checkGate!.complete();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 4)); // the slow poll too
    expect(find.text('Down everywhere (check-host)'), findsOneWidget);
    expect(find.text('Check with checker'), findsOneWidget, reason: 'it can be asked again');
    expect(host.journal.length, 1, reason: 'the event is changed in place, not repeated');

    // an opened row lists the checker's nodes
    await tester.tap(find.text('Down everywhere (check-host)'));
    await tester.pumpAndSettle();
    expect(find.text('Germany, Frankfurt'), findsOneWidget);
    expect(find.text('OK 200 · 200 ms'), findsOneWidget);
    expect(find.text('Connection timed out'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('the controller: an event that the checker later says opens elsewhere notifies once; pending, down and manual do not', (tester) async {
    final host = FakeCoreHost();
    final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    final got = <String>[];
    final sub = c.notifications.listen((e) => got.add('${e.data['host']}'));
    try {
      c.start();
      await tester.pump();
      c.setOnScreen(true);
      await tester.pump(const Duration(seconds: 4)); // the first look is history
      Map<String, dynamic> gone(String h) => host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': h, 'check': {'state': 'pending'}});
      final a = gone('a.example'), b = gone('b.example'), m = gone('m.example');
      host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'plain.example'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(got, ['plain.example'], reason: 'no check on it: as before; the pending ones are quiet');

      host.checkAnswer = {'state': 'opens', 'ok': 2, 'total': 2};
      host.checkGate = null;
      // the core's own (automatic) results, written into the events
      for (final (ev, state) in [(a, 'opens'), (b, 'down')]) {
        ev['rev'] = 1;
        ev['data'] = {...(ev['data'] as Map<String, dynamic>), 'check': {'state': state}};
      }
      host.addEvent('user', 'poke'); // the poll runs on any event (this one notifies nobody)
      await tester.pump(const Duration(milliseconds: 400));
      expect(got, ['plain.example', 'a.example'], reason: 'only opens-elsewhere notifies, once');
      await tester.pump(const Duration(seconds: 4));
      expect(got.length, 2, reason: 'the same revision is not told again');

      await host.checkSite(m['id'] as int); // a manual check: the user is looking
      await tester.pump(const Duration(milliseconds: 400));
      expect(got.length, 2);
      expect(c.feed.list.firstWhere((x) => x.id == m['id']).data['check']['state'], 'opens');
    } finally {
      unawaited(sub.cancel());
      c.dispose();
    }
  });

  testWidgets('Settings → Auto mode: «Check with an external checker» is on by default, off is kept in autoCfg and the plan', (tester) async {
    final host = FakeCoreHost();
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(640, 4000);
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
            home: const Scaffold(body: SingleChildScrollView(child: AutoModeBody())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.catalog.autoCfg.siteCheck, isTrue);
    final toggle = find.descendant(
      of: find.ancestor(of: find.text('Check with an external checker'), matching: find.byType(SetRow)).first,
      matching: find.byType(MiniToggle),
    );
    await tester.ensureVisible(toggle);
    expect(tester.widget<MiniToggle>(toggle).on, isTrue);
    final saves = host.changes;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(host.changes, saves + 1, reason: 'saved, and the live plan syncs the running core without a reconnect');
    expect(host.catalog.autoCfg.siteCheck, isFalse);
    expect(tester.widget<MiniToggle>(toggle).on, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(host.catalog.autoCfg.siteCheck, isTrue);
  });
}
