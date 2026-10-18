// «VPN turned off by the system» (docs/connect-model.md → Notifications, docs/logs.md → «„VPN не работает“»,
// revoke plan «Прогон 2», кусок B): the `vpnRevoked` switch (on by default, Connection group, Android only); a
// `conn/disconnected by: system` takes the id of the «VPN не работает» notification that is shown (its `vpnUp`
// came right before it); a closing `conn/vpnUp` by the user or by the system posts nothing.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand/widgets/settings_look.dart' show NotifSheet;

import 'fake_core_host.dart';
import 'system_notification_test.dart' show FakeNotifyIo, FakePowerIo;

final _en = lookupAppLocalizations(const Locale('en'));

/// The platform only goes resumed <-> inactive <-> hidden <-> paused one step at a time.
const _lifecycle = [
  AppLifecycleState.resumed,
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

void _lifecycleTo(AppLifecycleState target) {
  final binding = TestWidgetsFlutterBinding.instance;
  var i = _lifecycle.indexOf(binding.lifecycleState ?? AppLifecycleState.resumed);
  final to = _lifecycle.indexOf(target);
  while (i != to) {
    i += to > i ? 1 : -1;
    binding.handleAppLifecycleStateChanged(_lifecycle[i]);
  }
}

/// `conn/vpnDown` as the core writes it: an error that Sentinel confirmed, with its causes.
Map<String, dynamic> _vpnDown(FakeCoreHost host, List<String> causes, Map<String, dynamic> extra) {
  return host.addEvent('conn', 'vpnDown', level: 'error', data: {'causes': causes, ...extra})
    ..['verdict'] = 'confirmed'
    ..['why'] = {'code': causes.first == 'core' ? 'core.down' : 'net.offline', 'params': <String, dynamic>{}};
}

/// `conn/vpnUp`: info, closing the failure `down`; `by` is `user` / `system` for a closing that is not a recovery.
Map<String, dynamic> _vpnUp(FakeCoreHost host, Map<String, dynamic> down, {String? by}) =>
    host.addEvent('conn', 'vpnUp', level: 'info', data: {'downMs': 3000, 'causes': ['core'], 'by': ?by})
      ..['opens'] = down['id'];

/// `conn/disconnected by: system`: the system took the VPN away (`reason: revoked`), warn, not the user's own.
Map<String, dynamic> _revoked(FakeCoreHost host) =>
    host.addEvent('conn', 'disconnected', level: 'warn', data: const {'by': 'system', 'reason': 'revoked'});

void main() {
  late FakeNotifyIo io;
  late NotifyIo savedNotify;
  late PowerIo savedPower;

  setUp(() {
    savedNotify = NotifyIo.current;
    io = FakeNotifyIo();
    NotifyIo.current = io;
    savedPower = PowerIo.current;
    PowerIo.current = FakePowerIo();
  });

  tearDown(() {
    NotifyIo.current = savedNotify;
    PowerIo.current = savedPower;
    _lifecycleTo(AppLifecycleState.resumed);
  });

  /// The app is up and the first look at the journal is history: only later events notify.
  Future<FakeCoreHost> open(WidgetTester tester, {bool android = true}) async {
    final host = FakeCoreHost(android: android);
    await tester.pumpWidget(JormungandApp(coreHost: host));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    return host;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  List<int> postedIds() => [for (final n in io.posted) n.id];

  /// Settings → Notifications, tall enough that the sheet's lazy list builds every row.
  Future<void> openNotifSheet(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(640, 5000);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-setnotif')));
    await tester.pumpAndSettle();
  }

  test('vpnRevoked is on by default and is one of the Connection switches', () {
    expect(NotifCfg(const <String, dynamic>{}).flag('vpnRevoked'), isTrue);
    expect(NotifCfg.connectionKeys, contains('vpnRevoked'));
  });

  group('Settings → Notifications → Connection', () {
    for (final android in [true, false]) {
      testWidgets('the «VPN turned off by the system» row is shown on Android only (android: $android)', (
        tester,
      ) async {
        await open(tester, android: android);
        await openNotifSheet(tester);
        final inSheet = find.descendant(of: find.byType(NotifSheet), matching: find.text(_en.vpnTurnedOffByTheSystem));
        expect(inSheet, android ? findsOneWidget : findsNothing);
        if (android) {
          expect(find.text(_en.anotherVpnAppTookOverOr), findsOneWidget);
        }
      });
    }

    testWidgets('the switch of the row saves vpnRevoked', (tester) async {
      final host = await open(tester);
      await openNotifSheet(tester);
      final toggle = find.descendant(
        of: find.ancestor(of: find.text(_en.vpnTurnedOffByTheSystem), matching: find.byType(SetRow)).first,
        matching: find.byType(MiniToggle),
      );
      expect(host.notif.flag('vpnRevoked'), isTrue);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(host.notif.flag('vpnRevoked'), isFalse);
    });
  });

  group('the revoke as a system notification', () {
    testWidgets('the disconnect by the system takes the id of the shown «VPN не работает»; its vpnUp posts nothing', (
      tester,
    ) async {
      final host = await open(tester);
      _lifecycleTo(AppLifecycleState.paused);
      final down = _vpnDown(host, ['core'], {'proxy': 'kept'});
      await settle(tester);
      expect(postedIds(), [down['id']]);

      _vpnUp(host, down, by: 'system');
      await settle(tester);
      expect(postedIds(), [down['id']], reason: 'the closing by the system posts nothing');

      _revoked(host);
      await settle(tester);
      expect(
        postedIds(),
        [down['id'], down['id']],
        reason: 'the disconnect replaces the shown failure under its id, not under its own event id',
      );
    });

    for (final by in ['user', 'system']) {
      testWidgets('a closing vpnUp by the $by posts nothing', (
        tester,
      ) async {
        final host = await open(tester);
        _lifecycleTo(AppLifecycleState.paused);
        final down = _vpnDown(host, ['core'], {'proxy': 'kept'});
        await settle(tester);
        expect(postedIds(), [down['id']]);

        _vpnUp(host, down, by: by);
        await settle(tester);
        expect(postedIds(), [down['id']], reason: 'vpnUp by $by posts nothing');
      });
    }

    testWidgets('a closing vpnUp by the user cancels the shown failure by its id, not every event notification', (
      tester,
    ) async {
      final host = await open(tester);
      _lifecycleTo(AppLifecycleState.paused);
      final down = _vpnDown(host, ['core'], {'proxy': 'kept'});
      await settle(tester);
      expect(postedIds(), [down['id']]);
      final cancelEventsBefore = io.cancels;
      io.cancelledIds.clear();

      _vpnUp(host, down, by: 'user');
      await settle(tester);
      expect(io.cancelledIds, [down['id']], reason: 'only the shown vpnDown notification is removed, by its id');
      expect(io.cancels, cancelEventsBefore, reason: 'cancelEvents() would remove every event notification');
      expect(postedIds(), [down['id']], reason: 'the closing by the user posts nothing');
    });

    testWidgets('a revoke with no failure shown posts under its own event id', (tester) async {
      final host = await open(tester);
      _lifecycleTo(AppLifecycleState.paused);
      final disc = _revoked(host);
      await settle(tester);
      expect(postedIds(), [disc['id']]);
    });

    testWidgets('with vpnRevoked off, the revoke posts nothing', (tester) async {
      final host = await open(tester);
      host.notif.setFlag('vpnRevoked', false);
      _lifecycleTo(AppLifecycleState.paused);
      _revoked(host);
      await settle(tester);
      expect(io.posted, isEmpty);
    });

    testWidgets('the revoke notification carries the Connect button', (tester) async {
      final host = await open(tester);
      _lifecycleTo(AppLifecycleState.paused);
      _revoked(host);
      await settle(tester);
      expect(io.posted, isNotEmpty);
      expect(io.posted.last.actions.any((a) => a.$1 == 'connect'), isTrue);
    });
  });
}
