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

/// A chain Alpha -> Beta: the entry answers, the exits do not answer on their own.
FakeCoreHost _host() {
  final host = FakeCoreHost();
  final a = [_node('a1', 'Alpha one'), _node('a2', 'Alpha two')];
  final b = [_node('b1', 'Beta one'), _node('b2', 'Beta two')];
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
    nodes: b,
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
  host.catalog.pings.set(a[0], 40);
  host.catalog.pings.set(a[1], 90);
  for (final n in b) {
    host.catalog.pings.put(
      n,
      PingEntry(ms: -1, at: host.catalog.pings.now, fails: 5),
    );
  }
  return host;
}

Future<void> _openNodes(WidgetTester tester, FakeCoreHost host) async {
  await pumpApp(tester, host);
  await tester.tap(find.byIcon(AppTab.nodes.icon));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'chain card: an exit that answers through the entry works, whatever its direct ping says',
    (tester) async {
      final host = _host();
      final cat = host.catalog;
      final chain = cat.chainsData['c1']!;
      final a1 = cat.sourcesData['s1']!.nodes[0];
      final b2 = cat.sourcesData['s2']!.nodes[1];

      // nothing measured through the entry: the exits are unknown, the card has no server
      expect(cat.chainExitNode(chain), isNull);
      await _openNodes(tester, host);
      expect(find.text('no working server'), findsOneWidget);

      // the pair is measured: Beta two works, the card shows it with the pair's latency
      cat.pairs.set(a1, b2, 70, cat.pings.now);
      host.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('no working server'), findsNothing);
      expect(find.textContaining('Beta two'), findsOneWidget);
      expect(find.text('70 ms'), findsOneWidget);
      expect(cat.isUsable('c1'), isTrue);
      expect(cat.mayWork('c1'), isTrue);
      expect(cat.chainLatency(chain), 70);

      // unfolded, the exit rows show the pair, not the direct miss; a tap measures through the entry
      await tester.tap(find.text('Alpha via Beta'));
      await tester.pumpAndSettle();
      expect(find.text('70 ms'), findsNWidgets(2));
      await tester.ensureVisible(find.textContaining('Beta one'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Beta one'));
      await tester.pumpAndSettle();
      expect(host.calls, contains('pingChain c1 1 exits-only'));
      expect(host.calls.where((c) => c.startsWith('pingNodes')), isEmpty);
    },
  );

  testWidgets('chain card ⚡ measures the chain (entries direct, exits through the entry)', (
    tester,
  ) async {
    final host = _host();
    await _openNodes(tester, host);
    await tester.tap(find.byTooltip('Test latency').last);
    await tester.pumpAndSettle();
    expect(host.calls, contains('pingEntry c1'));
  });
}
