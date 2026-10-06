import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/pages/route_page.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/connect_dock.dart';
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

/// One subscription (Simple has something), no profiles; the empty state follows the catalog.
FakeCoreHost _host({bool withSource = true, bool withProfile = false}) {
  final host = FakeCoreHost(emptyFromCatalog: true);
  final c = host.catalog;
  if (withSource) {
    c.sourcesData['s1'] = Source(
      id: 's1',
      name: 'Alpha',
      url: 'https://alpha.example.com/sub',
      nodes: [_node('a1', 'Alpha one'), _node('a2', 'Alpha two')],
    );
    c.sourceOrder = ['s1'];
  }
  if (withProfile) {
    c.profilesData['p1'] = Profile(id: 'p1', name: 'Work', sources: ['s1']);
    c.catalogOrder['profiles'] = ['p1'];
  }
  c.syncCatalog();
  return host;
}

Finder _inRoute(Finder f) =>
    find.descendant(of: find.byType(RouteSheet), matching: f);

int _navIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

void main() {
  testWidgets(
    'Profiles with no profiles: the switcher only views it, the route stays Simple, '
    'the empty state leads to creating one',
    (tester) async {
      final host = _host();
      await pumpApp(tester, host);
      await tester.tap(find.text('Remnawave')); // the dock row: Route
      await tester.pumpAndSettle();
      expect(find.byType(RouteSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('route-used-simple')), findsOneWidget);

      await tester.tap(_inRoute(find.text('Profiles')));
      await tester.pumpAndSettle();
      expect(host.catalog.connectMode, 'simple'); // nothing switched
      expect(find.byKey(const ValueKey('route-used-simple')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-used-profiles')), findsNothing);
      expect(_inRoute(find.text('No profiles yet')), findsOneWidget);
      expect(_inRoute(find.text('Use this mode')), findsNothing);

      await tester.tap(_inRoute(find.text('Create profile')));
      await tester.pumpAndSettle();
      expect(find.byType(RouteSheet), findsNothing);
      expect(_navIndex(tester), AppTab.nodes.index);
      expect(find.text('Create'), findsOneWidget); // the Profiles "+" menu
      expect(host.catalog.connectMode, 'simple');
    },
  );

  testWidgets(
    'the way back from an empty active mode: the dock opens Route on the other mode, '
    '"Use this mode" switches, never the add sheet',
    (tester) async {
      final host = _host()..catalog.setConnectMode('profiles'); // as the stuck state
      await pumpApp(tester, host);
      expect(find.text('No profiles yet'), findsOneWidget); // the dock row

      await tester.tap(find.text('No profiles yet'));
      await tester.pumpAndSettle();
      expect(find.byType(RouteSheet), findsOneWidget);
      expect(_navIndex(tester), AppTab.home.index);
      expect(find.text('Manual server'), findsNothing);
      expect(find.text('Create'), findsNothing);
      // on Simple, with the button; the dot is still on Profiles (the mode in use)
      expect(find.byKey(const ValueKey('route-use-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-used-profiles')), findsOneWidget);
      expect(_inRoute(find.text('Alpha')), findsOneWidget); // what is in Simple
      expect(host.catalog.connectMode, 'profiles');

      await tester.tap(_inRoute(find.text('Use this mode')));
      await tester.pumpAndSettle();
      expect(host.catalog.connectMode, 'simple');
      expect(find.byKey(const ValueKey('route-use-bar')), findsNothing);
      expect(find.byKey(const ValueKey('route-used-simple')), findsOneWidget);
    },
  );

  testWidgets('the power tab and the badge lead out of an empty mode the same way', (
    tester,
  ) async {
    final host = _host()..catalog.setConnectMode('profiles');
    await pumpApp(tester, host);
    await tester.tap(find.byType(PowerTab));
    await tester.pumpAndSettle();
    expect(find.byType(RouteSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('route-use-bar')), findsOneWidget);
    expect(_navIndex(tester), AppTab.home.index);
    expect(host.phase.name, 'disconnected');
  });

  testWidgets('both modes empty: the dock still goes to Nodes and its "+"', (
    tester,
  ) async {
    final host = _host(withSource: false);
    await pumpApp(tester, host);
    await tester.tap(find.text('No servers yet'));
    await tester.pumpAndSettle();
    expect(find.byType(RouteSheet), findsNothing);
    expect(_navIndex(tester), AppTab.nodes.index);
    expect(find.text('Manual server'), findsOneWidget);
  });

  testWidgets('the Nodes tab of the bottom nav never opens an add sheet by itself', (
    tester,
  ) async {
    final host = _host()..catalog.setConnectMode('profiles');
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.nodes.icon));
    await tester.pumpAndSettle();
    expect(_navIndex(tester), AppTab.nodes.index);
    expect(find.text('Create'), findsNothing);
    expect(find.text('Manual server'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a mode with something in it: view it, then use it', (tester) async {
    final host = _host(withProfile: true);
    await pumpApp(tester, host);
    await tester.tap(find.text('Remnawave'));
    await tester.pumpAndSettle();

    await tester.tap(_inRoute(find.text('Profiles')));
    await tester.pumpAndSettle();
    expect(host.catalog.connectMode, 'simple');
    expect(find.byKey(const ValueKey('route-use-bar')), findsOneWidget);
    expect(_inRoute(find.text('Work')), findsOneWidget);
    expect(_inRoute(find.text('No profiles yet')), findsNothing);

    // back to the mode in use: the list, no button
    await tester.tap(_inRoute(find.text('Simple')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('route-use-bar')), findsNothing);
    expect(_inRoute(find.text('Alpha')), findsWidgets);

    await tester.tap(_inRoute(find.text('Profiles')));
    await tester.pumpAndSettle();
    await tester.tap(_inRoute(find.text('Use this mode')));
    await tester.pumpAndSettle();
    expect(host.catalog.connectMode, 'profiles');
    expect(find.byKey(const ValueKey('route-use-bar')), findsNothing);
    expect(find.byKey(const ValueKey('route-used-profiles')), findsOneWidget);
  });

  testWidgets('a chain row unfolds into its entry and exit servers; the tap still selects', (
    tester,
  ) async {
    final host = _host();
    final c = host.catalog;
    c.sourcesData['s2'] = Source(
      id: 's2',
      name: 'Beta',
      url: 'https://beta.example.com/sub',
      nodes: [_node('b1', 'Beta one')],
    );
    c.sourceOrder = ['s1', 's2'];
    c.chainsData['c1'] = Chain(id: 'c1', name: 'Hop', inId: 's2', outId: 's1');
    c.catalogOrder['simple']!.add('c1');
    c.syncCatalog();
    await pumpApp(tester, host);
    await tester.tap(find.text('Remnawave'));
    await tester.pumpAndSettle();
    expect(_inRoute(find.text('Hop')), findsOneWidget);
    expect(_inRoute(find.text('EXIT · ALPHA')), findsNothing);

    await tester.tap(_inRoute(find.text('Hop')));
    await tester.pumpAndSettle();
    expect(_inRoute(find.text('ENTRY · BETA')), findsOneWidget);
    expect(_inRoute(find.text('EXIT · ALPHA')), findsOneWidget);
    expect(_inRoute(find.textContaining('Beta one', findRichText: true)), findsWidgets);
    expect(_inRoute(find.textContaining('Alpha two', findRichText: true)), findsWidgets);
    expect(host.catalog.effectiveConnectId(), isNot('c1')); // unfolding selected nothing

    await tester.tap(_inRoute(find.text('Hop')));
    await tester.pumpAndSettle();
    expect(_inRoute(find.text('EXIT · ALPHA')), findsNothing);
  });
}
