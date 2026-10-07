import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/pages/route_page.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand/widgets/source_card.dart';
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

/// One subscription with a working server, an unmeasured one and four known-dead ones.
FakeCoreHost _host() {
  final host = FakeCoreHost(emptyFromCatalog: true);
  final c = host.catalog;
  final nodes = [
    _node('n1', 'Live one'),
    _node('n2', 'Fresh two'),
    for (var i = 1; i <= 4; i++) _node('d$i', 'Dead $i'),
  ];
  c.sourcesData['s1'] = Source(
    id: 's1',
    name: 'Alpha',
    url: 'https://alpha.example.com/sub',
    nodes: nodes,
  );
  c.sourceOrder = ['s1'];
  c.syncCatalog();
  c.pings.set(nodes[0], 40);
  for (final n in nodes.skip(2)) {
    c.pings.put(n, PingEntry(ms: -1, at: c.pings.now, fails: 5));
  }
  return host;
}

Finder _inRoute(Finder f) => find.descendant(of: find.byType(RouteSheet), matching: f);

Future<void> _openRoute(WidgetTester tester, FakeCoreHost host) async {
  tester.platformDispatcher.textScaleFactorTestValue = 1.2;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await pumpApp(tester, host);
  await tester.tap(find.text('Remnawave')); // the dock row: Route
  await tester.pumpAndSettle();
  expect(find.byType(RouteSheet), findsOneWidget);
}

void main() {
  testWidgets('Route: refresh sits on the card next to the ping, 48 dp targets, no overflow', (
    tester,
  ) async {
    final host = _host();
    await _openRoute(tester, host);

    // folded: both buttons are there, no unfolding needed
    final refresh = _inRoute(find.byTooltip('Update'));
    final ping = _inRoute(find.byTooltip('Ping its servers'));
    expect(refresh, findsOneWidget);
    expect(ping, findsOneWidget);
    for (final f in [refresh, ping]) {
      final size = tester.getSize(find.ancestor(of: f, matching: find.byType(IconBtn)).first);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);

    await tester.tap(refresh);
    await tester.pump();
    expect(host.calls, contains('updateSource s1'));
  });

  testWidgets('Route: dead servers collapse into "Unavailable · N": 2 shown, expand, collapse', (
    tester,
  ) async {
    final host = _host();
    await _openRoute(tester, host);
    await tester.tap(_inRoute(find.text('Alpha')));
    await tester.pumpAndSettle();

    // working and unmeasured stay in the main list
    expect(_inRoute(find.textContaining('Live one')), findsWidgets);
    expect(_inRoute(find.textContaining('Fresh two')), findsOneWidget);
    expect(_inRoute(find.text('Unavailable · 4')), findsOneWidget);
    expect(_inRoute(find.textContaining('Dead 1')), findsOneWidget);
    expect(_inRoute(find.textContaining('Dead 2')), findsOneWidget);
    expect(_inRoute(find.textContaining('Dead 3')), findsNothing);
    expect(_inRoute(find.text('Show all 4')), findsOneWidget);

    await tester.ensureVisible(_inRoute(find.text('Show all 4')));
    await tester.tap(_inRoute(find.text('Show all 4')));
    await tester.pumpAndSettle();
    expect(_inRoute(find.textContaining('Dead 3')), findsOneWidget);
    expect(_inRoute(find.textContaining('Dead 4')), findsOneWidget);
    expect(_inRoute(find.text('Show less')), findsOneWidget);

    await tester.tap(_inRoute(find.text('Show less')));
    await tester.pumpAndSettle();
    expect(_inRoute(find.textContaining('Dead 3')), findsNothing);
    expect(_inRoute(find.text('Show all 4')), findsOneWidget);
  });

  testWidgets('Nodes: the card buttons are 48 dp and fit 320 dp at 120 %', (tester) async {
    final host = _host();
    tester.platformDispatcher.textScaleFactorTestValue = 1.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.nodes.icon));
    await tester.pumpAndSettle();
    for (final tip in ['Update', 'Test latency', 'More']) {
      final f = find.descendant(of: find.byType(SourceCard), matching: find.byTooltip(tip)).first;
      final size = tester.getSize(find.ancestor(of: f, matching: find.byType(IconBtn)).first);
      expect(size.width, greaterThanOrEqualTo(48), reason: tip);
      expect(size.height, greaterThanOrEqualTo(48), reason: tip);
    }
    expect(tester.takeException(), isNull);
  });
}
