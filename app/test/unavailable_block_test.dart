// The «Unavailable · N» block (GoneBlock): removed and unsupported servers are counted together; the
// subtitle names the kinds that are there; an unsupported row says why; Forget all only when something
// can be forgotten; the rows are built lazily; an unusable server is never a live row of its source.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/catalog_card.dart' show GripHandle;
import 'package:jormungand/widgets/entry_editors.dart';
import 'package:jormungand/widgets/gone_block.dart';
import 'package:jormungand/widgets/node_row.dart';
import 'package:jormungand/widgets/target_picker.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

const _outbound = <String, dynamic>{'type': 'vless'};

/// A usable server (it has an outbound and nothing that sing-box refuses).
CatalogNode _live(String id) => CatalogNode(
  id: id,
  name: 'Live $id',
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
  outbound: _outbound,
);

/// A server the provider dropped: usable, with the time it was dropped.
CatalogNode _gone(String id) => CatalogNode(
  id: id,
  name: 'Gone $id',
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
  outbound: _outbound,
  goneAt: 1700000000000,
);

/// A server the core cannot run: it has an outbound and a reason sing-box refuses it.
CatalogNode _unsupported(String id, String reason) => CatalogNode(
  id: id,
  name: 'Xhttp $id',
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
  outbound: _outbound,
  unsupported: reason,
);

/// A server without an outbound and without a reason: the core cannot run it either.
CatalogNode _noOutbound(String id) => CatalogNode(
  id: id,
  name: 'Bare $id',
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'mock',
  address: '',
  port: 0,
);

NodeRef _ref(CatalogNode n) => NodeRef('s1', n);

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(720, 1600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppSettingsScope(
      settings: AppSettings(locale: const Locale('en')),
      child: CoreHostScope(
        host: FakeCoreHost(),
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
          home: Scaffold(body: body),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The block as the page builds it: a box inside a plain scroll view.
Widget _inList({
  List<NodeRef> gone = const [],
  List<NodeRef> unsupported = const [],
  VoidCallback? onForgetAll,
}) => ListView(
  children: [
    GoneBlock(gone: gone, unsupported: unsupported, onForgetAll: onForgetAll),
  ],
);

Future<void> _expand(WidgetTester tester, int count) async {
  await tester.tap(find.text('Unavailable · $count'));
  await tester.pumpAndSettle();
}

/// An editor sheet over the app (a tall screen: its lazy list builds every row of the test).
Future<void> _openSheet(WidgetTester tester, FakeCoreHost host, Future<void> Function(BuildContext) open) async {
  await pumpApp(tester, host);
  tester.view.physicalSize = const Size(640, 4000);
  await tester.pumpAndSettle();
  // ignore: unawaited_futures
  open(tester.element(find.byType(Scaffold).first));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the header counts removed and unsupported servers together; the block starts collapsed', (tester) async {
    await _pump(
      tester,
      _inList(
        gone: [_ref(_gone('g1')), _ref(_gone('g2'))],
        unsupported: [_ref(_unsupported('u1', 'xhttp transport'))],
      ),
    );
    expect(find.text('Unavailable · 3'), findsOneWidget);
    expect(find.textContaining('Gone g1'), findsNothing, reason: 'collapsed: no rows yet');
    expect(find.text('Not supported: xhttp transport'), findsNothing);

    await _expand(tester, 3);
    expect(find.textContaining('Gone g1'), findsOneWidget);
    expect(find.textContaining('Gone g2'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsOneWidget);
  });

  testWidgets('only removed servers: the subtitle says they were removed and the settings kept', (tester) async {
    await _pump(tester, _inList(gone: [_ref(_gone('g1')), _ref(_gone('g2'))]));
    await _expand(tester, 2);
    expect(find.text('removed by the provider, settings kept'), findsOneWidget);
    expect(find.text('removed by the provider or not supported'), findsNothing);
  });

  testWidgets('an unsupported server among them: the subtitle says "or not supported"', (tester) async {
    await _pump(
      tester,
      _inList(
        gone: [_ref(_gone('g1'))],
        unsupported: [_ref(_unsupported('u1', 'xhttp transport'))],
      ),
    );
    await _expand(tester, 2);
    expect(find.text('removed by the provider or not supported'), findsOneWidget);
    expect(find.text('removed by the provider, settings kept'), findsNothing);
  });

  testWidgets('an unsupported row says why: the reason, or "no outbound" when there is no outbound', (tester) async {
    await _pump(
      tester,
      _inList(
        unsupported: [_ref(_unsupported('u1', 'xhttp transport')), _ref(_noOutbound('n1'))],
      ),
    );
    await _expand(tester, 2);
    expect(find.text('Not supported: xhttp transport'), findsOneWidget);
    expect(find.text('Not supported: no outbound'), findsOneWidget);
  });

  testWidgets('Forget all is there with a removed server and calls onForgetAll', (tester) async {
    var forgets = 0;
    await _pump(
      tester,
      _inList(
        gone: [_ref(_gone('g1'))],
        unsupported: [_ref(_unsupported('u1', 'xhttp transport'))],
        onForgetAll: () => forgets++,
      ),
    );
    await _expand(tester, 2);
    expect(find.text('Forget all'), findsOneWidget);
    await tester.tap(find.text('Forget all'));
    await tester.pumpAndSettle();
    expect(forgets, 1);
  });

  testWidgets('Forget all is absent when only unsupported servers are there', (tester) async {
    await _pump(
      tester,
      _inList(
        unsupported: [_ref(_unsupported('u1', 'xhttp transport')), _ref(_noOutbound('n1'))],
        onForgetAll: () {},
      ),
    );
    await _expand(tester, 2);
    expect(find.text('Forget all'), findsNothing, reason: 'nothing to forget: unsupported servers are not removed');
  });

  testWidgets('Nodes: 3000 removed servers expanded in a source card: only a fraction of the rows is built', (tester) async {
    final host = FakeCoreHost();
    host.catalog.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [_live('a1')],
      gone: [for (var i = 0; i < 3000; i++) _gone('g$i')],
    );
    host.catalog.sourceOrder = ['s1'];
    host.catalog.syncCatalog();
    // wide enough for the card's meta line under the Ahem test font (it is not what is tested)
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.nodes.icon));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').first);
    await tester.pumpAndSettle();
    // the card's meta line overflows under the Ahem font with this many servers; not what is tested
    tester.takeException();
    await _expand(tester, 3000);
    tester.takeException();
    final built = find.byType(NodeRow).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(300), reason: 'rows are lazy: a 3000-row block must not build them all');
  });

  testWidgets('the header fits 320 dp at 120 % text with Forget all shown', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppSettingsScope(
        settings: AppSettings(locale: const Locale('en')),
        child: CoreHostScope(
          host: FakeCoreHost(),
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.2)),
              child: child!,
            ),
            home: Scaffold(
              body: _inList(
                gone: [_ref(_gone('g1'))],
                unsupported: [_ref(_unsupported('u1', 'xhttp transport'))],
                onForgetAll: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Forget all'), findsOneWidget);
  });

  testWidgets('3000 removed servers as a sliver in a lazy CustomScrollView: only a fraction of the rows is built', (tester) async {
    final refs = [for (var i = 0; i < 3000; i++) _ref(_gone('g$i'))];
    await _pump(
      tester,
      CustomScrollView(slivers: [GoneBlock(gone: refs, sliver: true)]),
    );
    await _expand(tester, 3000);
    final built = find.byType(NodeRow).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(300), reason: 'rows are lazy: a 3000-row block must not build them all');
  });

  testWidgets('Nodes: an unusable server is no live row of its source; it sits in Unavailable, with its reason', (tester) async {
    final host = FakeCoreHost();
    host.catalog.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [_live('a1'), _unsupported('u1', 'xhttp transport')],
    );
    host.catalog.sourceOrder = ['s1'];
    host.catalog.syncCatalog();
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.nodes.icon));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('Live a1'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsNothing, reason: 'an unusable server is not among the live rows');
    expect(find.text('Unavailable · 1'), findsOneWidget);

    // the core still sees it among the live servers of the source (the UI filters `usable`)
    final ids = host.catalog.liveNodes(host.catalog.sourcesData['s1']!).map((n) => n.id);
    expect(ids, containsAll(['a1', 'u1']));

    await _expand(tester, 1);
    expect(find.text('Not supported: xhttp transport'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsOneWidget);
  });

  testWidgets('Profile editor, Priority: an unusable server is no row; dragging a row keeps its place in the stored order', (tester) async {
    final host = FakeCoreHost();
    host.catalog.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [_live('a1'), _unsupported('u1', 'xhttp transport'), _live('a2'), _live('a3')],
    );
    host.catalog.sourceOrder = ['s1'];
    host.catalog.profilesData['p1'] = Profile(
      id: 'p1',
      name: 'Mine',
      sources: ['s1'],
      pickMode: 'priority',
      pickOrder: ['s1::a1', 's1::u1', 's1::a2', 's1::a3'],
    );
    host.catalog.syncCatalog();
    await _openSheet(tester, host, (context) => showProfileEditor(context, id: 'p1'));

    expect(find.textContaining('Live a3'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsNothing, reason: 'an unusable server is no live row');
    expect(find.byType(GripHandle), findsNWidgets(3));

    // a3 to the top
    await tester.drag(find.byType(GripHandle).at(2), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final y = [for (final id in ['a3', 'a1', 'a2']) tester.getTopLeft(find.textContaining('Live $id')).dy];
    expect(y, orderedEquals([...y]..sort()), reason: 'rows now read a3, a1, a2');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    // the unusable server keeps its slot in the stored order
    expect(host.savedProfile!.pickOrder, ['s1::a3', 's1::u1', 's1::a1', 's1::a2']);
  });

  testWidgets('Target picker: the "now" server of a source is never an unusable one, however fast it answered', (tester) async {
    final host = FakeCoreHost();
    final bad = _unsupported('u1', 'xhttp transport'), good = _live('a1');
    host.catalog.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [bad, good],
    );
    host.catalog.sourceOrder = ['s1'];
    host.catalog.syncCatalog();
    host.catalog.pings.set(bad, 10);
    host.catalog.pings.set(good, 90);
    await _openSheet(tester, host, (context) => showTargetPicker(context, current: ''));

    expect(find.textContaining('Live a1'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsNothing);
  });

  testWidgets('Chain editor, Priority exit: an unusable server is no row; dragging a row keeps its place in the stored order', (tester) async {
    final host = FakeCoreHost();
    host.catalog.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [_live('a1')],
    );
    host.catalog.sourcesData['s2'] = Source(
      id: 's2',
      name: 'Beta',
      url: 'https://beta.example.com/sub',
      nodes: [_live('b1'), _unsupported('u1', 'xhttp transport'), _live('b2'), _live('b3')],
    );
    host.catalog.sourceOrder = ['s1', 's2'];
    host.catalog.chainsData['c1'] = Chain(
      id: 'c1',
      name: 'Hop',
      inId: 's1',
      outId: 's2',
      exitMode: 'priority',
      exitOrder: ['s2::b1', 's2::u1', 's2::b2', 's2::b3'],
    );
    host.catalog.syncCatalog();
    await _openSheet(tester, host, (context) => showChainEditor(context, id: 'c1', tab: 'simple'));
    // the exit's own fold-out is the last one
    await tester.tap(find.byTooltip('Show nodes').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Live b3'), findsOneWidget);
    expect(find.textContaining('Xhttp u1'), findsNothing, reason: 'an unusable exit is no live row');
    expect(find.byType(GripHandle), findsNWidgets(3));

    await tester.drag(find.byType(GripHandle).at(2), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final y = [for (final id in ['b3', 'b1', 'b2']) tester.getTopLeft(find.textContaining('Live $id')).dy];
    expect(y, orderedEquals([...y]..sort()), reason: 'rows now read b3, b1, b2');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(host.savedChain!.exitOrder, ['s2::b3', 's2::u1', 's2::b1', 's2::b2']);
  });
}
