import 'dart:async';

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

/// Alpha (the entry, two servers answering fresh pings) and Beta (the exit, three servers).
FakeCoreHost _host() {
  final host = FakeCoreHost();
  final a = [_node('a1', 'Alpha one'), _node('a2', 'Alpha two')];
  host.catalog.sourcesData['s1'] = Source(
    id: 's1',
    name: 'Alpha',
    url: 'https://alpha.example.com/sub',
    nodes: a,
  );
  host.catalog.sourcesData['s2'] = Source(
    id: 's2',
    name: 'Beta',
    url: 'https://beta.example.com/sub',
    nodes: [
      _node('b1', 'Beta one'),
      _node('b2', 'Beta two'),
      _node('b3', 'Beta three'),
    ],
  );
  host.catalog.sourceOrder = ['s1', 's2'];
  host.catalog.syncCatalog();
  host.catalog.pings.set(a[0], 40);
  host.catalog.pings.set(a[1], 90);
  host.pairMs.addAll({'b1': 30, 'b2': 60, 'b3': 80});
  return host;
}

/// The chain editor of the Nodes tab, scrolled to the route check.
Future<void> _openChainEditor(WidgetTester tester, FakeCoreHost host) async {
  await pumpApp(tester, host);
  await tester.tap(find.byIcon(AppTab.nodes.icon));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chain'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Check route'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'route check: the exits go through each entry, working pairs are listed',
    (tester) async {
      final host = _host();
      // 320 dp at 120 % text: any overflow is thrown by the checks below
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _openChainEditor(tester, host);

      expect(
        find.text(
          'Tries every exit node through the entry nodes, fastest entries first.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Check route'));
      await tester.pumpAndSettle();

      // fresh entry pings are used as they are; the fastest entry goes first
      expect(host.calls, isNot(contains('pingNodes 2')));
      expect(host.calls.where((c) => c.startsWith('pingPairs')), [
        'pingPairs a1 3',
        'pingPairs a2 3',
      ]);
      expect(find.text('6 working pairs · best 30ms'), findsOneWidget);
      // every measured pair is kept in the pair book: what the chain's exits live by
      final cat = host.catalog;
      final a1 = cat.sourcesData['s1']!.nodes[0], a2 = cat.sourcesData['s1']!.nodes[1];
      final b = cat.sourcesData['s2']!.nodes;
      expect([cat.pairs.ping(a1, b[0]), cat.pairs.ping(a1, b[2]), cat.pairs.ping(a2, b[1])], [30, 80, 60]);
      expect(find.text('Check again'), findsOneWidget);
      // the top four of six, the rest behind "Show all"
      expect(find.text('Show all 6'), findsOneWidget);
      expect(find.text('30ms'), findsNWidgets(2));
      await tester.ensureVisible(find.text('Show all 6'));
      await tester.tap(find.text('Show all 6'));
      await tester.pumpAndSettle();
      expect(find.text('80ms'), findsNWidgets(2));
      expect(find.textContaining('Show top'), findsOneWidget);

      // grouped by entry: one row per entry with its count, unfolding to the exits
      await tester.tap(find.text('By entry'));
      await tester.pumpAndSettle();
      expect(find.text('MIN'), findsNWidgets(2));
      await tester.tap(find.text('3 nodes').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Beta three', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('route check: a weak pair is marked and ranks after every strong one', (tester) async {
    final host = _host()..pairWeak.add('b1');
    await _openChainEditor(tester, host);

    await tester.tap(find.text('Check route'));
    await tester.pumpAndSettle();
    // b1 answers fastest (30 ms) but only by a backup check: the best is the strong 60 ms
    expect(find.text('6 working pairs · best 60ms'), findsOneWidget);
    await tester.ensureVisible(find.text('Show all 6'));
    await tester.tap(find.text('Show all 6'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Answered only a backup check'), findsNWidgets(2));
    // the weak 30 ms rows come after the strong 80 ms ones
    final ys = [
      for (final t in ['60ms', '80ms', '30ms']) tester.getTopLeft(find.text(t).last).dy,
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: '$ys');
    expect(tester.takeException(), isNull);
  });

  testWidgets('route check: no pair answers', (tester) async {
    final host = _host();
    host.pairMs.addAll({'b1': -1, 'b2': -1, 'b3': -1});
    await _openChainEditor(tester, host);

    await tester.tap(find.text('Check route'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No exit node answers through any entry node — this chain will not connect.',
      ),
      findsOneWidget,
    );
    expect(find.text('By entry'), findsNothing);
    // "answered with a miss" is a verdict: every pair is in the book as dead
    final cat = host.catalog;
    final a1 = cat.sourcesData['s1']!.nodes[0];
    expect(cat.pairs.ping(a1, cat.sourcesData['s2']!.nodes[0]), -1);
  });

  testWidgets('route check: a call that failed as a whole writes nothing to the pair book', (tester) async {
    final host = _host()..pairCallFails = true;
    await _openChainEditor(tester, host);

    await tester.tap(find.text('Check route'));
    await tester.pumpAndSettle();
    expect(host.calls.where((c) => c.startsWith('pingPairs')), ['pingPairs a1 3', 'pingPairs a2 3']);
    final cat = host.catalog;
    for (final e in cat.sourcesData['s1']!.nodes) {
      for (final x in cat.sourcesData['s2']!.nodes) {
        expect(cat.pairs.entry(e, x), isNull, reason: 'no verdict on ${e.id} -> ${x.id}');
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('route check: Stop ends the run, a late answer changes nothing', (
    tester,
  ) async {
    final host = _host()..pairGate = Completer<void>();
    await _openChainEditor(tester, host);

    await tester.tap(find.text('Check route'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('Entry 1 of 2:'), findsOneWidget);
    expect(find.text('Check route'), findsNothing);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Stopped — no working pair found yet.'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);

    host.pairGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stopped — no working pair found yet.'), findsOneWidget);
    expect(host.calls.where((c) => c.startsWith('pingPairs')), [
      'pingPairs a1 3',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route check: stale entry pings are measured first', (
    tester,
  ) async {
    final host = _host();
    // an entry never measured: the check pings the entries before the pairs
    host.catalog.pings.remove(host.catalog.sourcesData['s1']!.nodes[1]);
    await _openChainEditor(tester, host);

    await tester.tap(find.text('Check route'));
    await tester.pumpAndSettle();
    expect(host.calls, contains('pingNodes 2'));
    // the fake host's ping does not answer, so only the entry it knew is alive
    expect(host.calls.where((c) => c.startsWith('pingPairs')), [
      'pingPairs a1 3',
    ]);
  });
}
