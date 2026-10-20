import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand_core/jormungand_core.dart' show Catalog;
import 'package:jormungand/app.dart';
import 'package:jormungand/core/app_update.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/core/system_notifier.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand/widgets/settings_look.dart' show NotifSheet;

import 'fake_core_host.dart';

/// A system-notification seam that records what the app asks of it.
class FakeNotifyIo implements NotifyIo {
  FakeNotifyIo({NotifyPermission state = NotifyPermission.granted})
    : _state = ValueNotifier(state);

  final ValueNotifier<NotifyPermission> _state;
  final posted = <SystemNote>[];
  final requests = <bool>[]; // the `once` of each request
  final vpnNodes = <String?>[];
  final vpnVisible = <bool>[];
  int cancels = 0;
  final cancelledIds = <int>[]; // the ids of the per-event cancels
  int settingsOpened = 0;
  int? launchEvent;
  final _taps = StreamController<int>.broadcast();

  /// What a request answers (the user's choice in the system dialog).
  NotifyPermission answer = NotifyPermission.granted;

  void tap(int id) => _taps.add(id);

  @override
  bool get available => true;

  @override
  ValueListenable<NotifyPermission> get permission => _state;

  @override
  Future<NotifyPermission> refresh() async => _state.value;

  @override
  Future<NotifyPermission> request({bool once = false}) async {
    requests.add(once);
    return _state.value = answer;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<void> post(SystemNote note) async => posted.add(note);

  @override
  Future<void> cancelEvents() async => cancels++;

  @override
  Future<void> cancelEvent(int id) async => cancelledIds.add(id);

  /// The update notifications asked for, and the version the native record says was announced.
  final updatePosted = <UpdateNote>[];
  String? announced;
  bool? launchUpdate;
  final _updTaps = StreamController<bool>.broadcast();

  /// A tap on the update notification (`install`: it said «Install»).
  void tapUpdate({bool install = false}) => _updTaps.add(install);

  @override
  Future<void> postUpdate(UpdateNote note) async => updatePosted.add(note);

  @override
  Future<String?> updateAnnounced() async => announced;

  @override
  Future<void> setUpdateAnnounced(String version) async => announced = version;

  @override
  Stream<bool> get updateTaps => _updTaps.stream;

  @override
  Future<bool?> takeLaunchUpdate() async {
    final l = launchUpdate;
    launchUpdate = null;
    return l;
  }

  @override
  Future<void> setVpnNode(String? node) async => vpnNodes.add(node);

  @override
  Future<void> setVpnVisible(bool visible) async => vpnVisible.add(visible);

  @override
  Stream<int> get eventTaps => _taps.stream;

  final _actTaps = StreamController<NoteActionTap>.broadcast();

  /// A press on a button of a notification (`rule` | `ignore`).
  void press(NoteActionTap t) => _actTaps.add(t);

  @override
  Stream<NoteActionTap> get actionTaps => _actTaps.stream;

  NoteActionTap? launchAction;

  /// The «Ignore site» / «Undo» choices made on the shade that Dart has not taken yet.
  final ignoreQueue = <SiteIgnoreOp>[];
  final _queued = StreamController<void>.broadcast();

  /// The native side queues a choice and pings Dart ([ping] false: Dart was not listening).
  void shade(String op, String site, {bool ping = true}) {
    ignoreQueue.add(SiteIgnoreOp(ignore: op == 'ignore', site: site));
    if (ping) _queued.add(null);
  }

  @override
  Stream<void> get ignoreQueued => _queued.stream;

  @override
  Future<List<SiteIgnoreOp>> takeIgnoreOps() async {
    final ops = List.of(ignoreQueue);
    ignoreQueue.clear();
    return ops;
  }

  @override
  Future<NoteActionTap?> takeLaunchAction() async {
    final a = launchAction;
    launchAction = null;
    return a;
  }

  @override
  Future<int?> takeLaunchEvent() async {
    final id = launchEvent;
    launchEvent = null;
    return id;
  }

  @override
  FutureOr<void> Function()? onDisconnect;
}

/// The battery-exemption seam: records the asks.
class FakePowerIo implements PowerIo {
  final requests = <bool>[]; // the `once` of each request
  final _access = ValueNotifier(BackgroundAccess.denied);

  @override
  bool get available => true;

  @override
  ValueListenable<BackgroundAccess> get access => _access;

  @override
  Future<BackgroundAccess> refresh() async => _access.value;

  @override
  Future<BackgroundAccess> request({bool once = false}) async {
    requests.add(once);
    return _access.value;
  }
}

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

void main() {
  late FakeNotifyIo io;
  late NotifyIo saved;
  late FakePowerIo power;
  late PowerIo savedPower;

  setUp(() {
    saved = NotifyIo.current;
    io = FakeNotifyIo();
    NotifyIo.current = io;
    savedPower = PowerIo.current;
    power = FakePowerIo();
    PowerIo.current = power;
  });

  tearDown(() {
    NotifyIo.current = saved;
    PowerIo.current = savedPower;
    _lifecycleTo(AppLifecycleState.resumed);
  });

  Future<FakeCoreHost> open(WidgetTester tester) async {
    final host = FakeCoreHost(android: true);
    await tester.pumpWidget(JormungandApp(coreHost: host));
    await tester.pumpAndSettle();
    // the first look at the journal is history; only later events notify
    await tester.pump(const Duration(seconds: 4));
    return host;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  }

  void goBackground(WidgetTester tester) =>
      _lifecycleTo(AppLifecycleState.paused);

  void comeBack(WidgetTester tester) => _lifecycleTo(AppLifecycleState.resumed);

  group('events', () {
    testWidgets('in the foreground: a toast, no system notification', (
      tester,
    ) async {
      final host = await open(tester);
      host.addEvent('conn', 'lost', level: 'warn');
      await settle(tester);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(io.posted, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('in the background: a system notification, no toast', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      final e = host.addEvent('conn', 'lost', level: 'warn');
      await settle(tester);

      expect(find.byType(SnackBar), findsNothing);
      expect(io.posted, hasLength(1));
      expect(io.posted.single.id, e['id']);
      expect(io.posted.single.title, startsWith('No connection through the VPN')); // т1 «По событиям»
    });

    testWidgets('only what Settings -> Notifications lets through; never own events', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      host.notif.setFlag('connLost', false);
      host.addEvent('conn', 'lost', level: 'warn');
      host.addEvent('conn', 'lost', level: 'warn', own: true);
      host.addEvent('core', 'deprecated'); // journalOnly: a kind that never notifies
      await settle(tester);
      expect(io.posted, isEmpty);

      host.notif.setFlag('connLost', true);
      host.notif.setFlag('enabled', false);
      host.addEvent('conn', 'restored');
      await settle(tester);
      expect(io.posted, isEmpty);
    });

    testWidgets('coming back clears the shade and toasts work again', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      comeBack(tester);
      await tester.pump();
      expect(io.cancels, 1);

      host.addEvent('conn', 'lost', level: 'warn');
      await settle(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(io.posted, isEmpty);
      await tester.pumpAndSettle();
    });

    testWidgets('a tap on a notification opens Logs -> Events', (tester) async {
      await open(tester);
      io.tap(3);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.selectedIndex, AppTab.logs.index);
    });

    testWidgets('a site notification has Create rule and Ignore site; a pressed button acts', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        data: {'host': 'dead.example.com', 'via': 'nope'},
      );
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'other.org', 'tried': const []});
      host.addEvent('conn', 'lost', level: 'warn');
      await settle(tester);
      expect(io.posted, hasLength(3));
      expect(io.posted[0].actions.map((a) => a.$1), ['rule', 'ignore']);
      expect([io.posted[0].site, io.posted[0].via], ['dead.example.com', 'nope']);
      expect(io.posted[1].actions.map((a) => a.$1), ['ignore'], reason: 'no working route: no rule to offer');
      // «Check now» is the bold button of conn/lost in the table «По типам»
      expect([for (final a in io.posted[2].actions) a.$1], ['checkNow']);

      comeBack(tester);
      await tester.pump();
      io.press(const NoteActionTap(id: 0, action: 'ignore', site: 'dead.example.com'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.notif.ignoredSites, ['dead.example.com']);
      expect(find.text('dead.example.com ignored'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));

      io.press(const NoteActionTap(id: 0, action: 'rule', site: 'dead.example.com', via: 'nope'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'dead.example.com'), findsOneWidget);
    });

    testWidgets('Ignore site is done natively: the notification carries its words, the choice comes as a queue', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'dead.example.com', 'tried': const []});
      await settle(tester);
      final note = io.posted.single;
      expect(note.ignoredText, 'dead.example.com added to ignored sites');
      expect(note.undoLabel, 'Undo');

      // pressed on the shade: no app, no toast; the list changes and Undo takes it back
      io.shade('ignore', 'dead.example.com');
      await tester.pump();
      expect(host.notif.ignoredSites, ['dead.example.com']);
      expect(find.byType(SnackBar), findsNothing);
      io.shade('unignore', 'dead.example.com');
      await tester.pump();
      expect(host.notif.ignoredSites, isEmpty);
      expect(io.ignoreQueue, isEmpty);
    });

    testWidgets('a site that opens again after Check again (changed in place) takes its notification off; other changes do not', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      final e = host.addEvent('site', 'blocked', level: 'warn', data: {'host': 'dead.example.com', 'via': 'nope'});
      await settle(tester);
      expect(io.posted.single.id, e['id']);

      // a check that changed it in place without reopening it: the notification stays
      e['rev'] = 1;
      e['data'] = {...e['data'] as Map<String, dynamic>, 'check': {'state': 'pending'}};
      host.addEvent('core', 'deprecated'); // journal only: it only makes the journal be read
      await settle(tester);
      expect(io.cancelledIds, isEmpty);

      // the core says it opens again: same id, rev grows, data.reopened set
      e['rev'] = 2;
      e['data'] = {...e['data'] as Map<String, dynamic>, 'reopened': {'at': 1}};
      host.addEvent('core', 'deprecated');
      await settle(tester);
      expect(io.cancelledIds, [e['id']]);
      expect(io.posted, hasLength(1), reason: 'the change in place never notifies again');
    });

    testWidgets('the words of the replaced notification follow the app language', (tester) async {
      final host = FakeCoreHost(android: true);
      host.gen.lang = 'ru';
      await tester.pumpWidget(JormungandApp(coreHost: host));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      goBackground(tester);
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'dead.example.com', 'tried': const []});
      await settle(tester);
      expect(io.posted.single.ignoredText, 'dead.example.com добавлен в игнорируемые сайты');
      expect(io.posted.single.undoLabel, 'Отменить');
    });

    testWidgets('choices made while no Dart ran are applied, in order, once the app is up', (tester) async {
      io
        ..shade('ignore', 'a.example.com', ping: false)
        ..shade('ignore', 'b.example.com', ping: false)
        ..shade('unignore', 'a.example.com', ping: false);
      final host = await open(tester);
      expect(host.notif.ignoredSites, ['b.example.com']);
      expect(io.ignoreQueue, isEmpty);

      // one that arrives with the app behind and is only read when it comes back
      goBackground(tester);
      io.shade('ignore', 'c.example.com', ping: false);
      comeBack(tester);
      await tester.pump();
      expect(host.notif.ignoredSites, ['b.example.com', 'c.example.com']);
    });

    testWidgets('a button that started the app is handled once the app is up', (tester) async {
      io.launchAction = const NoteActionTap(id: 0, action: 'ignore', site: 'dead.example.com');
      final host = await open(tester);
      expect(host.notif.ignoredSites, ['dead.example.com']);
      expect(io.launchAction, isNull);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('the notification that started the app opens Logs too', (
      tester,
    ) async {
      io.launchEvent = 5;
      await open(tester);
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.selectedIndex, AppTab.logs.index);
      expect(io.launchEvent, isNull);
    });
  });

  group('permission and the VPN notification', () {
    testWidgets('the first connect asks once; a master switch that is off does not', (
      tester,
    ) async {
      final host = await open(tester);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.requests, [true]);

      host.setPhase(ConnectionPhase.disconnected);
      host.notif.setFlag('enabled', false);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.requests, [true]); // nothing more
    });

    testWidgets('the first connect also asks for the background access, once-only, even with notifications off', (
      tester,
    ) async {
      final host = await open(tester);
      host.notif.setFlag('enabled', false);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.requests, isEmpty);
      expect(power.requests, [true]); // `once`: the native side keeps the count
    });

    testWidgets('the VPN notification gets the entry and server; none with Status off', (
      tester,
    ) async {
      final host = await open(tester);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.vpnNodes, ['Remnawave · Frankfurt 1']);

      // a dock change that is not a new name sends nothing
      host.setTraffic(host.traffic);
      await tester.pump();
      expect(io.vpnNodes, hasLength(1));

      host.setPhase(ConnectionPhase.disconnected);
      host.notif.setFlag('status', false);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.vpnNodes.last, isNull);
    });

    testWidgets('the Disconnect button of the notification disconnects through the host', (
      tester,
    ) async {
      final host = await open(tester);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      await io.onDisconnect!();
      expect(host.phase, ConnectionPhase.disconnected);
    });

    Future<void> openNotifSettings(WidgetTester tester) async {
      // tall enough that the sheet's lazy list builds every row
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(640, 5000);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-setnotif')));
      await tester.pumpAndSettle();
    }

    testWidgets('denied: the Notifications page offers the system settings', (
      tester,
    ) async {
      io = FakeNotifyIo(state: NotifyPermission.denied);
      NotifyIo.current = io;
      await open(tester);
      await openNotifSettings(tester);

      expect(find.text('Notifications are blocked'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(io.settingsOpened, 1);
    });

    testWidgets('granted: no hint; turning a switch on asks only when blocked', (
      tester,
    ) async {
      await open(tester);
      await openNotifSettings(tester);
      expect(find.text('Notifications are blocked'), findsNothing);

      Finder toggleOf(String label) => find.descendant(
        of: find
            .ancestor(of: find.text(label), matching: find.byType(SetRow))
            .first,
        matching: find.byType(MiniToggle),
      );
      await tester.tap(toggleOf('Subscription updated')); // off -> on
      await tester.pumpAndSettle();
      expect(io.requests, isEmpty); // already granted
    });

    // every switch of the sheet, tapped on screen, end to end: what it saved, what the journal lets
    // through (toast in front / shade behind) and what a reloaded state still says
    testWidgets('each switch of the sheet decides its events; the master mutes all', (
      tester,
    ) async {
      final host = await open(tester);
      await openNotifSettings(tester);
      final toggles = find.descendant(
        of: find.byType(NotifSheet),
        matching: find.byType(MiniToggle),
      );
      // «Errors while the screen is off» (not counted in allKeys) sits under «Site does not open»
      final order = [
        'enabled',
        for (final k in NotifCfg.allKeys) ...[k, if (k == 'blocked') 'bgErrors'],
      ];
      expect(toggles, findsNWidgets(order.length));
      // the two switches of т1 are found by their label: the sheet groups them, so their place is not pinned here
      const newLabels = {'appData': 'App data', 'dnsFailed': 'DNS server does not answer'};
      Future<void> tap(String key) async {
        final label = newLabels[key];
        final target = label == null
            ? toggles.at(order.indexOf(key))
            : find.descendant(
                of: find.ancestor(of: find.text(label), matching: find.byType(SetRow)).first,
                matching: find.byType(MiniToggle),
              );
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      const events = {
        'autoSwitch': ('auto', 'switched'),
        'unstable': ('auto', 'unstable'),
        'connLost': ('conn', 'lost'),
        'blocked': ('site', 'blocked'),
        'subUpdated': ('sub', 'updated'),
        'subFailed': ('sub', 'failed'),
        'ruleSets': ('rules', 'ruleSetFailed'),
        'appData': ('core', 'stateLost'),
        'dnsFailed': ('dns', 'failed'),
      };
      // how many notifications the kind's event makes now, in the background
      // `sub/updated` is the subUpdated kind only at info; at warn it is the subFailed kind
      const infoKeys = {'subUpdated'};
      Future<int> fire(String key) async {
        final before = io.posted.length;
        goBackground(tester);
        final (cat, type) = events[key]!;
        host.addEvent(cat, type, level: infoKeys.contains(key) ? 'info' : 'warn');
        await settle(tester);
        comeBack(tester);
        await tester.pump();
        return io.posted.length - before;
      }

      for (final key in events.keys) {
        final was = host.notif.flag(key);
        expect(await fire(key), was ? 1 : 0, reason: '$key as it starts');
        await tap(key);
        expect(host.notif.flag(key), !was, reason: '$key saved');
        expect(await fire(key), was ? 0 : 1, reason: '$key flipped');
        // a reloaded state reads the same
        final back = NotifCfg(
          Catalog.fromJson(host.catalog.toJson()).unknown['notifCfg'] as Map<String, dynamic>,
        );
        expect(back.flag(key), !was, reason: '$key persists');
        await tap(key); // as it was
      }

      // the master switch: nothing at all, in the background and in front
      for (final key in events.keys) {
        host.notif.setFlag(key, true);
      }
      await tap('enabled');
      expect(host.notif.enabled, isFalse);
      for (final key in events.keys) {
        expect(await fire(key), 0, reason: '$key under the master switch');
      }
      // in front: no toast either
      host.addEvent('conn', 'lost', level: 'warn');
      await settle(tester);
      expect(find.byType(SnackBar), findsNothing);

      await tap('enabled');
      expect(await fire('connLost'), 1);
      await tester.pumpAndSettle();
    });

    testWidgets('the Status switch changes the name in the VPN notification at once', (
      tester,
    ) async {
      final host = await open(tester);
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.vpnNodes.last, 'Remnawave · Frankfurt 1');
      await openNotifSettings(tester);
      final toggles = find.descendant(
        of: find.byType(NotifSheet),
        matching: find.byType(MiniToggle),
      );
      await tester.tap(toggles.at(1)); // Status
      await tester.pumpAndSettle();
      expect(host.notif.flag('status'), isFalse);
      expect(io.vpnNodes.last, isNull);
      await tester.tap(toggles.at(1));
      await tester.pumpAndSettle();
      expect(io.vpnNodes.last, 'Remnawave · Frankfurt 1');
      await tester.tap(toggles.at(0)); // the master
      await tester.pumpAndSettle();
      expect(io.vpnNodes.last, isNull);
    });

    testWidgets('the Status and master switches hide the VPN notification, on screen', (
      tester,
    ) async {
      final host = await open(tester);
      expect(io.vpnVisible, [true]); // the native side hears it before any connect
      host.setPhase(ConnectionPhase.connected);
      await tester.pump();
      expect(io.vpnVisible, [true]); // nothing new: sent only on a change
      expect(io.vpnNodes.last, 'Remnawave · Frankfurt 1');

      await openNotifSettings(tester);
      // Android: the row says that a hidden notification is not a stopped VPN
      expect(find.textContaining('The VPN keeps running'), findsOneWidget);
      final toggles = find.descendant(
        of: find.byType(NotifSheet),
        matching: find.byType(MiniToggle),
      );
      await tester.tap(toggles.at(1)); // Status off
      await tester.pumpAndSettle();
      expect(io.vpnVisible, [true, false]);
      await tester.tap(toggles.at(1)); // Status on, with the name
      await tester.pumpAndSettle();
      expect(io.vpnVisible, [true, false, true]);
      expect(io.vpnNodes.last, 'Remnawave · Frankfurt 1');

      await tester.tap(toggles.at(0)); // the master off: hidden whatever Status says
      await tester.pumpAndSettle();
      expect(io.vpnVisible.last, isFalse);
      await tester.tap(toggles.at(0));
      await tester.pumpAndSettle();
      expect(io.vpnVisible.last, isTrue);

      // off while disconnected is kept for the next start of the service
      host.setPhase(ConnectionPhase.disconnected);
      await tester.pump();
      await tester.tap(toggles.at(1));
      await tester.pumpAndSettle();
      expect(io.vpnVisible.last, isFalse);
    });

    test('a reloaded app pushes what the settings say; both switches on = shown', () {
      for (final (master, status, shown) in [
        (true, true, true),
        (true, false, false),
        (false, true, false),
        (false, false, false),
      ]) {
        final host = FakeCoreHost(android: true)
          ..notif.setFlag('enabled', master)
          ..notif.setFlag('status', status);
        final fake = FakeNotifyIo();
        SystemNotifier(host, io: fake, power: FakePowerIo()).start();
        expect(fake.vpnVisible, [shown], reason: 'master $master, Status $status');
        expect(host.notif.vpnStatusShown, shown);
      }
    });

    testWidgets('blocked: a switch turned on asks for the permission', (
      tester,
    ) async {
      io = FakeNotifyIo(state: NotifyPermission.denied)
        ..answer = NotifyPermission.granted;
      NotifyIo.current = io;
      final host = await open(tester);
      host.notif.setFlag('subUpdated', false);
      await openNotifSettings(tester);
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Subscription updated'),
                matching: find.byType(SetRow),
              )
              .first,
          matching: find.byType(MiniToggle),
        ),
      );
      await tester.pumpAndSettle();
      expect(io.requests, [false]);
      // answered: granted, so the hint is gone
      expect(find.text('Notifications are blocked'), findsNothing);
      expect(host.notif.flag('subUpdated'), isTrue);
    });
  });

  group('a tap on an event notification lands on the event', () {
    testWidgets('a sheet left open is closed first', (tester) async {
      final host = FakeCoreHost(android: true);
      host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'h0.test', 'tried': const []});
      await tester.pumpWidget(JormungandApp(coreHost: host));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      showDialog<void>(
        context: tester.element(find.byType(HomeShell)),
        builder: (_) => const AlertDialog(content: Text('left open')),
      );
      await tester.pumpAndSettle();
      expect(find.text('left open'), findsOneWidget);

      io.tap(0);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.text('left open'), findsNothing);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, AppTab.logs.index);
      expect(find.textContaining('h0.test'), findsWidgets);
    });

    testWidgets('(the notification started the app)', (tester) async {
      final host = FakeCoreHost(android: true);
      for (var i = 0; i < 60; i++) {
        host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'h$i.test', 'tried': const []});
      }
      io.launchEvent = 5;
      await tester.pumpWidget(JormungandApp(coreHost: host));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      final f = find.textContaining('h5.test');
      expect(f, findsWidgets);
      final r = tester.getRect(f.first);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(r.top >= 0 && r.bottom <= size.height, isTrue, reason: '$r in $size');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    for (final (paused, onLogs) in [(false, false), (true, false), (false, true), (true, true)]) {
      testWidgets('(lifecycle paused when the tap arrives: $paused; Logs already open: $onLogs)', (tester) async {
        final host = FakeCoreHost(android: true);
        for (var i = 0; i < 60; i++) {
          host.addEvent('site', 'unreachable', level: 'warn', data: {'host': 'h$i.test', 'tried': const []});
        }
        await tester.pumpWidget(JormungandApp(coreHost: host));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        if (onLogs) {
          await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Logs')));
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('h5.test'), findsNothing, reason: 'the list is at its end, the event far above');
        if (paused) _lifecycleTo(AppLifecycleState.paused);
        io.tap(5);
        await tester.pump();
        if (paused) _lifecycleTo(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        final f = find.textContaining('h5.test');
        expect(f, findsWidgets);
        final r = tester.getRect(f.first);
        final size = tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(r.top >= 0 && r.bottom <= size.height, isTrue, reason: '$r in $size');
        await tester.pumpAndSettle(const Duration(seconds: 5));
      });
    }
  });

  group('the app update (docs/updates.md, section 6)', () {
    AppUpdate upd(UpdPhase phase) => AppUpdate(
      phase: phase,
      current: '0.1.0',
      offer: const UpdOffer(version: '0.2.0', channel: 'stable', size: 1024, notes: {}),
      file: phase == UpdPhase.ready ? '/data/u.apk' : null,
    );

    Future<void> openDataSettings(WidgetTester tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(640, 5000);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-setdata')));
      await tester.pumpAndSettle();
    }

    testWidgets('Download & install: the installer gets the file the moment it is ready; a declined dialog leaves the Install button', (
      tester,
    ) async {
      final host = await open(tester);
      host.installable = true;
      host.installResult = false;
      host.update = upd(UpdPhase.available);
      host.changed();
      await openDataSettings(tester);
      host.installWanted = true; // the press on «Download & install»
      host.update = upd(UpdPhase.downloading);
      host.changed();
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains('installUpdate')));

      host.update = upd(UpdPhase.ready);
      host.changed();
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c == 'installUpdate'), hasLength(1));
      expect(io.updatePosted, isEmpty);
      // declined: the card still offers Install
      expect(find.text('Install'), findsOneWidget);
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(host.calls.where((c) => c == 'installUpdate'), hasLength(2));
    });

    testWidgets('an automatic download opens no dialog in front of the user', (tester) async {
      final host = await open(tester);
      host.installable = true;
      host.update = upd(UpdPhase.available);
      host.changed();
      await tester.pump();
      host.update = upd(UpdPhase.ready);
      host.changed();
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains('installUpdate')));
      expect(io.updatePosted, isEmpty);
    });

    testWidgets('behind the app: «Update ready · Install» instead of a dialog; the tap installs and opens the card', (
      tester,
    ) async {
      final host = await open(tester);
      host.installable = true;
      host.update = upd(UpdPhase.available);
      host.changed();
      await tester.pump();
      host.installWanted = true;
      goBackground(tester);
      host.update = upd(UpdPhase.ready);
      host.changed();
      await settle(tester);
      expect(host.calls, isNot(contains('installUpdate')));
      expect(io.updatePosted, hasLength(1));
      expect(io.updatePosted.single.title, 'Update 0.2.0 ready');
      expect(io.updatePosted.single.install, isTrue);

      comeBack(tester);
      io.tapUpdate(install: true);
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c == 'installUpdate'), hasLength(1));
      expect(find.text('Install'), findsOneWidget); // the Data sheet is open on the ready card
    });

    testWidgets('a newer version found behind the app: «Update 0.2.0 available» once; obeys the New version switch', (
      tester,
    ) async {
      final host = await open(tester);
      goBackground(tester);
      host.update = upd(UpdPhase.available);
      host.changed();
      await settle(tester);
      expect(io.updatePosted, hasLength(1));
      expect(io.updatePosted.single.title, 'Update 0.2.0 available');
      expect(io.updatePosted.single.install, isFalse);
      expect(io.announced, '0.2.0');

      io.updatePosted.clear();
      io.announced = null;
      host.notif.setFlag('updateAvailable', false);
      host.update = upd(UpdPhase.checking);
      host.changed();
      host.update = upd(UpdPhase.available);
      host.changed();
      await settle(tester);
      expect(io.updatePosted, isEmpty);
    });

    testWidgets('the notification that started the app opens the card', (tester) async {
      io.launchUpdate = false;
      final host = FakeCoreHost(android: true);
      host.update = upd(UpdPhase.available);
      await tester.pumpWidget(JormungandApp(coreHost: host));
      await tester.pumpAndSettle();
      expect(find.text('Update 0.2.0 available'), findsOneWidget);
    });
  });
}
