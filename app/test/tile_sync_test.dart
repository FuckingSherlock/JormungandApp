import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/tile_sync.dart';
import 'package:jormungand/platform/tile_channel.dart';

import 'fake_core_host.dart';

class FakeTilePort implements TilePort {
  final _actions = StreamController<TileAction>.broadcast();
  final pushed = <TileState>[];
  String? launch;
  int backs = 0;
  bool listening = false;

  @override
  Stream<TileAction> get actions => _actions.stream;

  void tap(String action, {bool launch = false}) =>
      _actions.add(TileAction(action, launch: launch));

  @override
  Future<void> push(TileState state) async => pushed.add(state);

  @override
  Future<String?> takeLaunchAction() async {
    final l = launch;
    launch = null;
    return l;
  }

  @override
  Future<void> moveToBack() async => backs++;
}

const _chain = DockSummary(
  kind: DockKind.chain,
  name: 'Home → DE',
  node: DockNode(flag: 'DE', name: 'Frankfurt 1', protocol: 'vless'),
);

void main() {
  group('tileName', () {
    test('a chain shows its own name', () => expect(tileName(_chain), 'Home → DE'));
    test('else the server traffic leaves through', () {
      final s = FakeCoreHost().dockSummary;
      expect(tileName(s), '\u{1F1E9}\u{1F1EA} Frankfurt 1');
    });
    test('no node: the entry name', () {
      expect(tileName(const DockSummary(kind: DockKind.sub, name: 'Sub')), 'Sub');
    });
    test('no entry: empty', () {
      expect(
        tileName(const DockSummary(kind: DockKind.simple, none: DockNone.empty)),
        '',
      );
    });
  });

  group('TileSync', () {
    late FakeCoreHost host;
    late FakeTilePort port;
    late TileSync sync;

    setUp(() {
      host = FakeCoreHost();
      port = FakeTilePort();
      sync = TileSync(host, port)..start();
    });
    tearDown(() => sync.dispose());

    test('pushes the state at start and on every change, only changes', () async {
      await Future<void>.delayed(Duration.zero);
      expect(port.pushed.single.phase, 'off');
      expect(port.pushed.single.name, '\u{1F1E9}\u{1F1EA} Frankfurt 1');
      expect(port.pushed.single.canConnect, isTrue);

      host.setTraffic(TrafficInfo.zero); // nothing the tile shows moved
      host.setPhase(ConnectionPhase.connecting);
      host.setPhase(ConnectionPhase.connected);
      host.setPhase(ConnectionPhase.down);
      host.setPhase(ConnectionPhase.disconnecting);
      await Future<void>.delayed(Duration.zero);
      expect(port.pushed.map((s) => s.phase), [
        'off',
        'connecting',
        'on',
        'disconnecting',
      ]);
    });

    test('a route change moves the name; no entry = cannot connect', () async {
      await Future<void>.delayed(Duration.zero);
      host.dockSummary = _chain;
      host.setPhase(ConnectionPhase.disconnected);
      host.dockSummary = const DockSummary(
        kind: DockKind.simple,
        none: DockNone.empty,
      );
      host.setPhase(ConnectionPhase.connected);
      await Future<void>.delayed(Duration.zero);
      expect(port.pushed.last.name, '');
      expect(port.pushed.last.canConnect, isFalse);
      expect(port.pushed.last.phase, 'on');
    });

    test('a tap connects, a launch-started connect sends the app behind', () async {
      await Future<void>.delayed(Duration.zero);
      port.tap('connect');
      await Future<void>.delayed(Duration.zero);
      expect(host.phase, ConnectionPhase.connected);
      expect(port.backs, 0);

      port.tap('disconnect');
      await Future<void>.delayed(Duration.zero);
      expect(host.phase, ConnectionPhase.disconnected);

      port.tap('connect', launch: true);
      await Future<void>.delayed(Duration.zero);
      expect(host.phase, ConnectionPhase.connected);
      expect(port.backs, 1);
    });

    test('connect while on or busy is ignored; disconnect while off too', () async {
      await Future<void>.delayed(Duration.zero);
      host.setPhase(ConnectionPhase.connected);
      port.tap('connect', launch: true);
      await Future<void>.delayed(Duration.zero);
      expect(port.backs, 0);

      host.setPhase(ConnectionPhase.disconnected);
      port.tap('disconnect');
      await Future<void>.delayed(Duration.zero);
      expect(host.phase, ConnectionPhase.disconnected);
    });

    test('a request the app was started with runs once it is up', () async {
      sync.dispose();
      port = FakeTilePort()..launch = 'connect';
      host = FakeCoreHost();
      sync = TileSync(host, port)..start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(host.phase, ConnectionPhase.connected);
      expect(port.backs, 1);
      expect(port.launch, isNull);
    });
  });

  testWidgets('the app wires the tile sync to its host', (tester) async {
    final port = FakeTilePort();
    await tester.pumpWidget(
      JormungandApp(coreHost: FakeCoreHost(android: true), tilePort: port),
    );
    await tester.pump();
    expect(port.pushed, isNotEmpty);
  });

  testWidgets('long-press on the tile (home): Home tab, sheets closed', (tester) async {
    final port = FakeTilePort();
    await tester.pumpWidget(
      JormungandApp(coreHost: FakeCoreHost(android: true), tilePort: port),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.person_outline)); // Settings tab
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(
      nav.push(
        MaterialPageRoute<void>(builder: (_) => const Text('open sheet')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('open sheet'), findsOneWidget);

    port.tap('home');
    await tester.pumpAndSettle();
    expect(find.text('open sheet'), findsNothing);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);
  });
}
