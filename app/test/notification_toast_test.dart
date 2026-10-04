import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/shell/home_shell.dart';

import 'fake_core_host.dart';

void main() {
  Future<FakeCoreHost> open(WidgetTester tester) async {
    final host = FakeCoreHost();
    await tester.pumpWidget(JormungandApp(coreHost: host));
    await tester.pumpAndSettle();
    // the first look at the journal is history; only later events notify
    await tester.pump(const Duration(seconds: 4));
    return host;
  }

  // the event reaches the shell by a microtask, the snackbar animates in on the next frames
  Future<void> shown(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('a background event is a toast; a tap opens it in Logs', (
    tester,
  ) async {
    final host = await open(tester);
    host.addEvent('conn', 'lost', level: 'warn');
    await shown(tester);

    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(SnackBar), findsNothing);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, AppTab.logs.index);
  });

  testWidgets('a blocked-site toast offers Create rule, prefilled', (
    tester,
  ) async {
    final host = await open(tester);
    host.addEvent(
      'site',
      'blocked',
      level: 'warn',
      data: {'host': 'example.com', 'via': 'nope'},
    );
    await shown(tester);

    expect(find.byType(SnackBarAction), findsOneWidget);
    await tester.tap(find.byType(SnackBarAction));
    await tester.pumpAndSettle();

    // the action does not also open Logs
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, isNot(AppTab.logs.index));
    expect(find.widgetWithText(TextField, 'example.com'), findsOneWidget);
  });

  testWidgets('an own event does not toast; an untapped one flies away', (
    tester,
  ) async {
    final host = await open(tester);
    host.addEvent('conn', 'lost', own: true);
    await shown(tester);
    expect(find.byType(SnackBar), findsNothing);

    host.addEvent('conn', 'lost', level: 'warn');
    await shown(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpAndSettle();
  });
}
