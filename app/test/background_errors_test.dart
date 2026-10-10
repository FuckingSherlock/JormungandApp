// Failures found while the phone's screen is off are background ones: the core writes the `site/*`
// event with `bg: true` (core tests), the journal shows it marked «background» and a «Background» row
// of the Events filter hides it, and it makes no toast / system notification unless Settings ->
// Notifications -> «Errors while screen is off» is on. The decision goes by the event's own flag.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/form_parts.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;
import 'system_notification_test.dart' show FakeNotifyIo, FakePowerIo;

void _lifecycle(AppLifecycleState s) {
  final binding = TestWidgetsFlutterBinding.instance;
  const steps = [
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  var i = steps.indexOf(binding.lifecycleState ?? AppLifecycleState.resumed);
  final to = steps.indexOf(s);
  while (i != to) {
    i += to > i ? 1 : -1;
    binding.handleAppLifecycleStateChanged(steps[i]);
  }
}

const _gone = {'host': 'dead.example.org', 'entry': 'x', 'tried': <Object>[]};

void main() {
  testWidgets('the controller: a bg event notifies only with «Errors while screen is off»; a normal one always', (
    tester,
  ) async {
    final host = FakeCoreHost();
    final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    final got = <String>[];
    final sub = c.notifications.listen((e) => got.add('${e.data['host']}${e.bg ? ' bg' : ''}'));
    try {
      c.start();
      await tester.pump();
      c.setOnScreen(true);
      await tester.pump(const Duration(seconds: 4)); // the first look is history
      expect(host.notif.bgErrors, isFalse, reason: 'off by default');
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {..._gone, 'host': 'a.example'});
      host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'b.example'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(got, ['b.example']);

      host.notif.setFlag('bgErrors', true);
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {..._gone, 'host': 'c.example'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(got, ['b.example', 'c.example bg']);

      host.notif.setFlag('blocked', false); // the kind still decides
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {..._gone, 'host': 'd.example'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(got.length, 2);
      expect(c.feed.list.length, 4, reason: 'the journal keeps every one of them');
    } finally {
      unawaited(sub.cancel());
      c.dispose();
    }
  });

  group('toast and shade', () {
    late FakeNotifyIo io;
    late NotifyIo saved;
    late PowerIo savedPower;

    setUp(() {
      saved = NotifyIo.current;
      io = FakeNotifyIo();
      NotifyIo.current = io;
      savedPower = PowerIo.current;
      PowerIo.current = FakePowerIo();
    });

    tearDown(() {
      NotifyIo.current = saved;
      PowerIo.current = savedPower;
      _lifecycle(AppLifecycleState.resumed);
    });

    Future<FakeCoreHost> open(WidgetTester tester) async {
      final host = FakeCoreHost(android: true);
      await tester.pumpWidget(JormungandApp(coreHost: host));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4)); // the first look is history
      return host;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('the app in front: a bg event makes no toast while the switch is off, a toast when it is on', (
      tester,
    ) async {
      final host = await open(tester);
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: _gone);
      await settle(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(io.posted, isEmpty);

      host.notif.setFlag('bgErrors', true);
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {..._gone, 'host': 'two.example'});
      await settle(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('behind: no system notification for a bg event while the switch is off, one when it is on; it goes by the event, not the screen now', (
      tester,
    ) async {
      final host = await open(tester);
      _lifecycle(AppLifecycleState.paused);
      host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: _gone);
      await settle(tester);
      expect(io.posted, isEmpty);

      // switched on: the next bg event notifies (the flag is the event's, the screen is not looked at)
      host.notif.setFlag('bgErrors', true);
      final e = host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {..._gone, 'host': 'two.example'});
      await settle(tester);
      expect(io.posted.map((n) => n.id), [e['id']]);

      // and a normal one is never held back by the switch
      host.notif.setFlag('bgErrors', false);
      final n = host.addEvent('site', 'unreachable', level: 'warn', data: {..._gone, 'host': 'three.example'});
      await settle(tester);
      expect(io.posted.map((x) => x.id), [e['id'], n['id']]);
    });

    testWidgets('Settings -> Notifications has the switch (Android), off by default, saved', (tester) async {
      final host = await open(tester);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(640, 5000);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-setnotif')));
      await tester.pumpAndSettle();

      final toggle = find.descendant(
        of: find.ancestor(of: find.text('Errors while screen is off'), matching: find.byType(SetRow)).first,
        matching: find.byType(MiniToggle),
      );
      expect(toggle, findsOneWidget);
      expect(tester.widget<MiniToggle>(toggle).on, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(host.notif.bgErrors, isTrue);
    });
  });

  testWidgets('Events: a bg row is marked and the «Background» row of the filter hides / shows it', (tester) async {
    final host = FakeCoreHost();
    host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: _gone);
    host.addEvent('conn', 'lost', level: 'warn');
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evBg')), findsOneWidget, reason: 'shown by default, marked');
    expect(find.text('background'), findsOneWidget);
    expect(find.text('Connection lost'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('evFilterBg'));
    expect(row, findsOneWidget);
    await tester.tap(find.descendant(of: row, matching: find.byType(MiniToggle)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evBg')), findsNothing, reason: 'hidden');
    // the sheet's categories start folded: only the row in the list behind it
    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.textContaining('no background'), findsNothing, reason: 'no «Filtered» bar any more');

    await tester.tap(find.descendant(of: row, matching: find.byType(MiniToggle)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evBg')), findsOneWidget);
  });
}
