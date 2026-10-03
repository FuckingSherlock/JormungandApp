import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// A host whose catalog holds two subscriptions with two servers each.
FakeCoreHost _host() {
  final host = FakeCoreHost();
  host.catalog.sourcesData['s1'] = Source(
    id: 's1',
    name: 'Alpha',
    url: 'https://alpha.example.com/sub',
    nodes: [_node('a1', 'Alpha one'), _node('a2', 'Alpha two')],
  );
  host.catalog.sourcesData['s2'] = Source(
    id: 's2',
    name: 'Beta',
    url: 'https://beta.example.com/sub',
    nodes: [_node('b1', 'Beta one'), _node('b2', 'Beta two')],
  );
  host.catalog.sourceOrder = ['s1', 's2'];
  host.catalog.syncCatalog();
  return host;
}

Future<void> _openNodes(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.nodes.icon));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Profile editor: Create stays off until something is ticked', (
    tester,
  ) async {
    final host = _host();
    await pumpApp(tester, host);
    await _openNodes(tester);
    await tester.tap(find.text('Profiles'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Create profile'), findsWidgets);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.tap(find.text('Create profile').last);
    await tester.pumpAndSettle();
    expect(host.calls, isNot(contains('saveProfile')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Subscription form: an empty URL is refused inline', (
    tester,
  ) async {
    final host = _host();
    await pumpApp(tester, host);
    await _openNodes(tester);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subscription'));
    await tester.pumpAndSettle();

    expect(find.text('Add subscription'), findsWidgets);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Paste a subscription URL first'), findsOneWidget);
    expect(host.calls, isNot(contains(startsWith('addSubscription'))));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chain editor opens with an entry and an exit', (tester) async {
    await pumpApp(tester, _host());
    await _openNodes(tester);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chain'));
    await tester.pumpAndSettle();

    expect(find.text('Create chain'), findsWidgets);
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Nodes: the catalog lists its sources, a card unfolds its servers',
    (tester) async {
      await pumpApp(tester, _host());
      await _openNodes(tester);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(
        find.textContaining('Alpha one', findRichText: true),
        findsNothing,
      );

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Alpha one', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Alpha two', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Nodes: edit mode swaps the pencil for a check', (tester) async {
    await pumpApp(tester, _host());
    await _openNodes(tester);

    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byType(ReorderableListView), findsWidgets);
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('Nodes: + on Simple offers subscription, manual server, chain', (
    tester,
  ) async {
    await pumpApp(tester, _host());
    await _openNodes(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Subscription'), findsOneWidget);
    expect(find.text('Manual server'), findsOneWidget);
    expect(find.text('Chain'), findsOneWidget);

    await tester.tap(find.text('Manual server'));
    await tester.pumpAndSettle();
    expect(find.text('Add server'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Nodes: the Profiles tab is empty until one is created', (
    tester,
  ) async {
    await pumpApp(tester, _host());
    await _openNodes(tester);

    await tester.tap(find.text('Profiles'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Chain'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
