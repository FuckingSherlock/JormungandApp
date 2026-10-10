// Ignored sites: a dead site that some program keeps opening can be silenced. «Ignore site» on its
// events and toast adds the host (with «<host> ignored · Undo»), the filter sheets (Events and Raw) list /
// edit / clear the list, the Raw view hides the failed-connection lines of ignored sites behind a chip, no
// notification is made for them, and the core is told (no reconnect).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

const _dead = 'dial tcp: lookup api.dead.example.com: no such host';

void main() {
  testWidgets('the controller: ignoring hides the failed lines of the host and its subdomains until the chip is on; Undo brings them back', (
    tester,
  ) async {
    final host = FakeCoreHost();
    final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    try {
      c.start();
      await tester.pump();
      c.setTab('raw');
      c.setOnScreen(true);
      host.addLogLine('[1 2s] outbound/vless[x]: outbound connection to dead.example.com:443: $_dead', lvl: 'warn');
      host.addLogLine('[2 1s] connection: open outbound connection: dial tcp 1.2.3.4:443: i/o timeout', lvl: 'error');
      host.addLogLine('[3 1s] outbound/vless[x]: outbound connection to notdead.example.com:443: refused', lvl: 'warn');
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.shownLines.length, 3);
      expect(c.ignoredLineCount, 0);

      final changes = host.changes;
      expect(c.ignoreSite('Dead.Example.com'), 'dead.example.com');
      expect(c.ignoreSite('dead.example.com'), isNull, reason: 'already there');
      expect(c.ignoreSite('not a host!'), isNull);
      expect(host.notif.ignoredSites, ['dead.example.com'], reason: 'kept in the state (backup), cleaned');
      expect(host.changes, changes + 1, reason: 'the host is told: it hands the list to the core');
      expect(c.ignoredLineCount, 1);
      expect(c.shownLines.map((l) => l.n), [1, 2], reason: 'only the line that names the site is hidden');
      expect(c.raw.visibleCount, 2);

      host.addLogLine('router: api.dead.example.com timed out', lvl: 'warn'); // a later one is sorted too
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.ignoredLineCount, 2);

      c.setShowIgnored(true);
      expect(c.shownLines.length, 4);
      expect(c.cfg.toJson()['showIgnored'], true);
      c.setShowIgnored(false);

      c.unignoreSite('dead.example.com'); // Undo
      expect(c.ignoredLineCount, 0);
      expect(c.shownLines.length, 4);
    } finally {
      c.dispose();
    }
  });

  testWidgets('the controller: no notification for an event of an ignored site', (tester) async {
    final host = FakeCoreHost();
    final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    final got = <String>[];
    final sub = c.notifications.listen((e) => got.add('${e.data['host']}'));
    try {
      c.start();
      await tester.pump();
      c.setOnScreen(true);
      await tester.pump(const Duration(seconds: 4)); // the first look is history
      c.ignoreSite('dead.example.com');
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'api.dead.example.com', 'tried': const []});
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'alive.example.org', 'tried': const []});
      await tester.pump(const Duration(milliseconds: 400));
      expect(got, ['alive.example.org']);
    } finally {
      unawaited(sub.cancel());
      c.dispose();
    }
  });

  testWidgets('Ignore site on an event: «host ignored · Undo»; Undo takes it off', (tester) async {
    final host = FakeCoreHost();
    host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'dead.example.com', 'entry': 'x', 'tried': const []});
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ignore site'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(host.notif.ignoredSites, ['dead.example.com']);
    expect(find.text('dead.example.com ignored'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(host.notif.ignoredSites, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('the «host ignored · Undo» toast goes by itself (an action does not make it stay)', (tester) async {
    final host = FakeCoreHost();
    host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'dead.example.com', 'entry': 'x', 'tried': const []});
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore site'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('dead.example.com ignored'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('dead.example.com ignored'), findsNothing);
    expect(host.notif.ignoredSites, ['dead.example.com'], reason: 'no Undo: it stays ignored');
  });

  testWidgets('Raw filter sheet → Ignored sites: add (checked), remove, clear; the Raw chip counts the hidden lines', (
    tester,
  ) async {
    final host = FakeCoreHost();
    host.notif.ignoredSites = ['dead.example.com'];
    host.addLogLine(_dead, lvl: 'warn');
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();

    // Raw: the failed line of the ignored site is behind a switch of the filter sheet
    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
    expect(find.text(_dead), findsNothing);
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    expect(find.text('1 from ignored sites'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rawIgnored')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // closes the sheet
    await tester.pumpAndSettle();
    expect(find.textContaining('no such host'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawIgnored')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text(_dead), findsNothing);

    // the list is reached from the filter sheet (Raw tab), not from ⋮
    await tester.tap(find.byKey(const ValueKey('logsMenu')));
    await tester.pumpAndSettle();
    expect(find.text('Ignored sites'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ignoredSitesRow')), findsOneWidget);
    expect(find.text('dead.example.com'), findsOneWidget, reason: 'the row shows what is ignored');
    await tester.tap(find.byKey(const ValueKey('ignoredSitesRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ignored:dead.example.com')), findsOneWidget);

    final input = find.byKey(const ValueKey('ignoredSiteInput'));
    await tester.enterText(input, 'bad host!');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Enter a site, like example.com'), findsOneWidget);
    await tester.enterText(input, 'DEAD.example.com');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('dead.example.com is already in the list'), findsOneWidget);
    await tester.enterText(input, 'https://Other.org/path');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(host.notif.ignoredSites, ['dead.example.com', 'other.org']);
    expect(find.byKey(const ValueKey('ignored:other.org')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('ignored:dead.example.com')), matching: find.byIcon(Icons.close)));
    await tester.pump();
    expect(host.notif.ignoredSites, ['other.org']);

    await tester.tap(find.text('Clear all'));
    await tester.pump();
    expect(host.notif.ignoredSites, isEmpty);
    expect(find.text('No ignored sites'), findsOneWidget);
  });

  testWidgets('Events filter sheet → Ignored sites row opens the same list', (tester) async {
    final host = FakeCoreHost();
    host.notif.ignoredSites = ['dead.example.com'];
    host.addEvent('conn', 'lost', level: 'warn');
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('ignoredSitesRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ignoredSitesRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ignored:dead.example.com')), findsOneWidget);
  });

  testWidgets('a «does not open» toast has both buttons; Ignore site adds the host', (tester) async {
    final host = FakeCoreHost();
    await tester.pumpWidget(JormungandApp(coreHost: host));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    host.addEvent('site', 'blocked', level: 'warn', data: {'host': 'dead.example.com', 'via': 'nope'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.descendant(of: find.byType(SnackBar), matching: find.text('Create rule')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Ignore site')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(host.notif.ignoredSites, ['dead.example.com']);
    expect(find.text('dead.example.com ignored'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
