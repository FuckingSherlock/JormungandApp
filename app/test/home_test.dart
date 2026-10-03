import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/format.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/connect_dock.dart';

import 'fake_core_host.dart';

/// 320 dp wide, like the smallest phone the mockup is checked at.
Future<void> pumpApp(WidgetTester tester, FakeCoreHost host) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 1280);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(JormungandApp(coreHost: host));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the power tab connects and disconnects: badge and dock follow', (
    tester,
  ) async {
    final host = FakeCoreHost()..gate = Completer<void>();
    await pumpApp(tester, host);

    expect(find.text('Tap to connect'), findsOneWidget);
    expect(find.text('Remnawave'), findsOneWidget);
    expect(find.text('AUTO'), findsOneWidget);
    expect(find.text('SUB'), findsOneWidget);
    expect(find.text('REALITY'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);

    await tester.tap(find.byType(PowerTab));
    await tester.pump();
    expect(host.phase, ConnectionPhase.connecting);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('DIRECT IP'), findsOneWidget);

    host.gate!.complete();
    await tester.pumpAndSettle();
    expect(host.phase, ConnectionPhase.connected);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('EXIT IP'), findsOneWidget);
    expect(find.text('203.0.113.7'), findsOneWidget);
    expect(find.text('Frankfurt, DE'), findsOneWidget);

    await tester.tap(find.byType(PowerTab));
    await tester.pumpAndSettle();
    expect(host.phase, ConnectionPhase.disconnected);
    expect(find.text('Tap to connect'), findsOneWidget);
    expect(host.toggles, 2);
  });

  testWidgets('the header badge connects too', (tester) async {
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    await tester.tap(find.text('Tap to connect'));
    await tester.pumpAndSettle();
    expect(host.phase, ConnectionPhase.connected);
  });

  testWidgets('nothing in Auto: the alert, no connect', (tester) async {
    final host = FakeCoreHost()
      ..outcomeOverride = ConnectOutcome.nothingInAuto
      ..dockSummary = const DockSummary(
        kind: DockKind.simple,
        none: DockNone.nothingInAuto,
      );
    await pumpApp(tester, host);

    expect(find.text('Nothing in Auto'), findsOneWidget); // the dock row
    expect(find.text('turn on Use in Auto in Route'), findsOneWidget);

    await tester.tap(find.byType(PowerTab));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Open Route'), findsOneWidget);
    expect(host.phase, ConnectionPhase.disconnected);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'first run: the dock says add something, a tap opens the Add menu',
    (tester) async {
      final host = FakeCoreHost(
        catalogIsEmpty: true,
        dock: const DockSummary(kind: DockKind.simple, none: DockNone.empty),
      )..outcomeOverride = ConnectOutcome.catalogEmpty;
      await pumpApp(tester, host);

      expect(find.text('No servers yet'), findsOneWidget);
      expect(find.text('Add in Nodes'), findsOneWidget);
      expect(find.text('—'), findsOneWidget); // no latency

      await tester.tap(find.text('No servers yet'));
      await tester.pumpAndSettle();
      expect(find.text('Subscription'), findsOneWidget); // the Add menu
      expect(find.text('Manual server'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, AppTab.nodes.index);
    },
  );

  testWidgets('VPN down: the alert, the dock line, the red tab', (
    tester,
  ) async {
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    host.setPhase(
      ConnectionPhase.down,
      down: VpnDown(
        since: DateTime.now().millisecondsSinceEpoch - 3 * 60 * 1000,
        proxy: 'kept',
      ),
    );
    await tester.pump();

    expect(find.text('VPN is down'), findsOneWidget); // the badge
    expect(find.text('VPN is down — internet is blocked'), findsOneWidget);
    expect(find.text('Disable sys proxy'), findsOneWidget);
    expect(find.textContaining('VPN is down · 3 min'), findsOneWidget);

    await tester.tap(find.text('Disable sys proxy'));
    await tester.pump();
    expect(find.text('Disable sys proxy'), findsNothing);
  });

  testWidgets('segments flip the mode, the route and the system proxy', (
    tester,
  ) async {
    final host = FakeCoreHost();
    await pumpApp(tester, host);
    expect(host.tun, isFalse);
    await tester.tap(find.text('TUN'));
    await tester.pump();
    expect(host.tun, isTrue);
    await tester.tap(find.text('Global'));
    await tester.pump();
    expect(host.global, isTrue);
    await tester.tap(find.text('Sys proxy'));
    await tester.pump();
    expect(host.sysProxy, isTrue);
  });

  testWidgets('Android: no system proxy segment, mode stays TUN', (
    tester,
  ) async {
    final host = FakeCoreHost(android: true);
    await pumpApp(tester, host);
    expect(find.text('Sys proxy'), findsNothing);
    await tester.tap(find.text('Proxy'));
    await tester.pump();
    expect(host.tun, isTrue);
  });

  testWidgets('everything fits 320 dp at the largest text size', (
    tester,
  ) async {
    final host = FakeCoreHost()
      ..setTraffic(
        const TrafficInfo(
          down: 48.3 * 1024 * 1024,
          up: 6.1 * 1024 * 1024,
          downTotal: 1.84 * 1024 * 1024 * 1024,
          upTotal: 312 * 1024 * 1024,
          tcp: 43,
          udp: 8,
        ),
      );
    await pumpApp(tester, host);
    host.setPhase(ConnectionPhase.connected);
    await tester.tap(find.byIcon(AppTab.settings.icon));
    await tester.pumpAndSettle();
    // Settings -> Appearance -> Text size to the right end
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppTab.home.icon));
    await tester.pumpAndSettle();
    expect(find.text('6.1'), findsOneWidget);
    expect(find.text('1.84 GB'), findsOneWidget);
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });

  group('formats', () {
    test(
      'speed keeps its slot: one decimal under 10, units switch at 1000',
      () {
        expect(fmtRate(0), ('0', 'B/s'));
        expect(fmtRate(999), ('999', 'B/s'));
        expect(fmtRate(1000), ('1.0', 'KB/s'));
        expect(fmtRate(48.3 * 1024 * 1024), ('48', 'MB/s'));
        expect(fmtRate(6.1 * 1024 * 1024), ('6.1', 'MB/s'));
      },
    );

    test('totals', () {
      expect(fmtBytes(512), '512 B');
      expect(fmtBytes(1.84 * 1024 * 1024 * 1024), '1.84 GB');
      expect(fmtBytes(312 * 1024 * 1024), '312 MB');
      expect(fmtBytes(87.3 * 1024 * 1024), '87.3 MB');
    });

    test('duration units', () {
      expect(
        splitDuration(const Duration(seconds: 42)).unit,
        DurationUnit.seconds,
      );
      final m = splitDuration(const Duration(minutes: 3));
      expect((m.unit, m.a), (DurationUnit.minutes, 3));
      final h = splitDuration(const Duration(hours: 2, minutes: 5));
      expect((h.unit, h.a, h.b), (DurationUnit.hoursMinutes, 2, 5));
    });

    test('flags', () {
      expect(flagOf('de'), '\u{1F1E9}\u{1F1EA}');
      expect(flagOf(null), '\u{1F310}');
      expect(flagOf('xyz'), '\u{1F310}');
    });
  });
}
