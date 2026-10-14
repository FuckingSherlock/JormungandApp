// Logs: the Raw tab hides the lines of successful connections by default (and keeps the choice), and
// a "does not open" event can always be copied / made a rule, and its Open leads to the Nodes tab
// the entry lives in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

CatalogNode _node(String id, String name) => CatalogNode(
  id: id,
  name: name,
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
);

FakeCoreHost _hostWithSimpleChain() {
  final host = FakeCoreHost();
  host.catalog.sourcesData['s1'] = Source(
    id: 's1',
    name: 'Alpha',
    url: 'https://alpha.example.com/sub',
    nodes: [_node('a1', 'Alpha one')],
  );
  host.catalog.sourcesData['s2'] = Source(
    id: 's2',
    name: 'Beta',
    url: 'https://beta.example.com/sub',
    nodes: [_node('b1', 'Beta one')],
  );
  host.catalog.sourceOrder = ['s1', 's2'];
  host.catalog.chainsData['c1'] = Chain(
    id: 'c1',
    name: 'Alpha via Beta',
    inId: 's1',
    outId: 's2',
  );
  host.catalog.catalogOrder['simple'] = ['s1', 's2', 'c1'];
  host.catalog.syncCatalog();
  return host;
}

void main() {
  testWidgets('Raw: connection lines are hidden by default, errors stay, the chip brings them back and is kept', (
    tester,
  ) async {
    final host = FakeCoreHost();
    final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    try {
      c.start();
      await tester.pump();
      c.setTab('raw');
      c.setOnScreen(true);
      host.addLogLine('[1 5ms] inbound/mixed[mixed-in]: inbound connection to example.com:443');
      host.addLogLine('[1 9ms] outbound/vless[proxy/Alpha]: outbound connection to example.com:443');
      host.addLogLine('[2 5.0s] connection: open outbound connection: dial tcp 1.2.3.4:443: i/o timeout', lvl: 'error');
      host.addLogLine('router: matched rule', lvl: 'info');
      host.addLogLine('[3 1ms] outbound/direct[direct]: outbound connection to 1.1.1.1:53', lvl: 'warn');
      await tester.pump(const Duration(milliseconds: 600));

      // the core leaves the successful connections out itself while the switch is off, and says how many
      expect(c.raw.lines.length, 3);
      expect(c.rawHidden, 2);
      expect(c.shownLines.map((l) => l.msg), [
        contains('open outbound connection: dial tcp'),
        'router: matched rule',
        contains('1.1.1.1:53'),
      ], reason: 'successful connections are hidden, problems and other lines are not');
      expect(c.raw.visibleCount, 3);

      c.setShowConns(true);
      expect(c.shownLines.length, 5, reason: 'asked for again from the start');
      expect(c.rawHidden, 0);
      expect((host.catalog.unknown['logCfg'] as Map)['showConns'], true);
      expect(LogCfg.fromJson(host.catalog.unknown['logCfg']).showConns, true);
      expect(LogCfg().showConns, false, reason: 'off by default');

      c.setShowConns(false);
      expect(c.shownLines.length, 3);
    } finally {
      c.dispose();
    }
  });

  Future<void> openLogs(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
  }

  testWidgets('a "does not open" event: copy and Create rule are there even without a working route', (
    tester,
  ) async {
    final host = _hostWithSimpleChain();
    host.addEvent(
      'site',
      'unreachable',
      level: 'warn',
      data: {'host': 'example.org', 'entry': 'c1', 'tried': const []},
    );
    await pumpApp(tester, host);
    await openLogs(tester);

    expect(find.text('Copy site'), findsOneWidget);
    expect(find.text('Create rule'), findsOneWidget);
    await tester.tap(find.text('Create rule'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'example.org'), findsOneWidget);
  });

  testWidgets('a blocked event with viaTarget (the scout is a node of the failing entry): Create rule targets that node, named "<host> via <node>"', (
    tester,
  ) async {
    final host = _hostWithSimpleChain();
    host.addEvent(
      'site',
      'blocked',
      level: 'info',
      data: {'host': 'example.org', 'entry': 's1', 'via': 's1', 'viaServer': 's1::a1', 'viaTarget': 'node:s1::a1'},
    );
    await pumpApp(tester, host);
    await openLogs(tester);
    await tester.tap(find.text('Create rule'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'example.org via Alpha one'), findsOneWidget);
  });

  testWidgets('Copy site shows the toast', (tester) async {
    final host = _hostWithSimpleChain();
    host.addEvent(
      'site',
      'unreachable',
      level: 'warn',
      data: {'host': 'example.org', 'entry': 'c1', 'tried': const []},
    );
    await pumpApp(tester, host);
    await openLogs(tester);
    await tester.tap(find.text('Copy site'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('Open on a Simple chain goes to the Simple tab, not Profiles', (tester) async {
    final host = _hostWithSimpleChain();
    host.addEvent(
      'site',
      'unreachable',
      level: 'warn',
      data: {'host': 'example.org', 'entry': 'c1', 'tried': const []},
    );
    await pumpApp(tester, host);
    await openLogs(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, AppTab.nodes.index);
    expect(host.catalog.modeOf('c1'), 'simple');
    expect(find.text('Alpha via Beta'), findsOneWidget, reason: 'the Simple page is the one in view');
  });
}
