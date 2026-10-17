// System notifications of т1 («Свёртки», «По типам», «Уведомление»): at most two buttons, taken from the table;
// a closing event replaces the notification of its opening one (same id); a crash chain is one notification;
// a consequence (or a group row of a missing root) does not notify; the popup of a subscription that waits for
// the connection or the network appears and closes itself.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;
import 'system_notification_test.dart' show FakeNotifyIo, FakePowerIo;

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
  Future<FakeCoreHost> open(WidgetTester tester) async {
    final host = FakeCoreHost(android: true);
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

  Set<int> idsPosted() => {for (final n in io.posted) n.id};

  group('the buttons of a notification come from the table «По типам»', () {
    const cases = {
      'conn/lost': ('conn', 'lost', 'warn', <String, dynamic>{}, ['checkNow']),
      'rules/ruleSetFailed': ('rules', 'ruleSetFailed', 'warn', <String, dynamic>{'tag': 'geo'}, ['retryRuleSets']),
      'conn/vpnDown by network': ('conn', 'vpnDown', 'error', <String, dynamic>{'causes': ['network']}, ['networkSettings']),
      'conn/vpnDown by core, not running': ('conn', 'vpnDown', 'error', <String, dynamic>{'causes': ['core']}, ['retry']),
      'dns/failed': ('dns', 'failed', 'warn', <String, dynamic>{}, ['open']),
    };
    cases.forEach((name, c) {
      testWidgets('$name: the bold button of the table, and never more than two', (tester) async {
        final host = await open(tester);
        _lifecycleTo(AppLifecycleState.paused);
        host.addEvent(c.$1, c.$2, level: c.$3, data: c.$4)['verdict'] = 'confirmed';
        await settle(tester);

        expect(io.posted, hasLength(1));
        final ids = [for (final a in io.posted.single.actions) a.$1];
        expect(ids, c.$5);
        expect(ids.length, lessThanOrEqualTo(2));
      });
    });
  });

  testWidgets('a closing event replaces the notification of its opening one: same id, a new text', (tester) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final opener = host.addEvent('conn', 'lost', level: 'warn');
    await settle(tester);
    final closer = host.addEvent('conn', 'restored', level: 'info')..['opens'] = opener['id'];
    await settle(tester);

    expect(io.posted, hasLength(2));
    expect(idsPosted(), {opener['id']}, reason: 'the closer takes the opener\'s id');
    expect(closer['opens'], opener['id']);
    expect(io.posted.last.title, isNot(io.posted.first.title));
  });

  testWidgets('a crash that turns into a VPN failure: the crash and its failed restarts post nothing; the failure joins them, one id', (
    tester,
  ) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final crash = host.addEvent('core', 'crashed', level: 'error', data: const {'code': 2})..['verdict'] = 'confirmed';
    for (var n = 1; n <= 2; n++) {
      host.addEvent('core', 'restartFailed', level: 'error', data: {'attempt': n, 'error': 'boom'})
        ..['verdict'] = 'consequence'
        ..['cause'] = crash['id'];
    }
    final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['core'], 'proxy': 'kept'})
      ..['verdict'] = 'confirmed'
      ..['joins'] = [crash['id']];
    host.addEvent('core', 'restarted', level: 'info')['opens'] = crash['id'];
    await settle(tester);

    expect(io.posted, hasLength(1));
    expect(idsPosted(), {down['id']}, reason: 'the notification is the one of conn/vpnDown');
  });

  testWidgets('a step of the core does not notify, even when its root is shown: no update of the root\'s notification', (
    tester,
  ) async {
    final host = await open(tester);
    host.notif.setFlag('connLost', true);
    _lifecycleTo(AppLifecycleState.paused);
    final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['core']})..['verdict'] = 'confirmed';
    await settle(tester);
    expect(io.posted, hasLength(1));
    final first = io.posted.single;

    host.addEvent('core', 'restartFailed', level: 'error', data: const {'attempt': 1, 'error': 'boom'})
      ..['verdict'] = 'consequence'
      ..['cause'] = down['id'];
    await settle(tester);

    expect(io.posted, hasLength(1), reason: 'nothing is posted for the step');
    expect('${first.title}\n${first.text}', '${io.posted.single.title}\n${io.posted.single.text}');
  });

  testWidgets('a consequence does not notify; a group row of a missing root does not either', (tester) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final root = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['network']})
      ..['verdict'] = 'confirmed';
    host.addEvent('conn', 'lost', level: 'warn')
      ..['verdict'] = 'consequence'
      ..['cause'] = root['id']
      ..['why'] = {'code': 'net.offline', 'params': <String, dynamic>{}};
    host.addEvent('site', 'blocked', level: 'warn', data: const {'host': 'a.example.org', 'via': 'x'})
      ..['verdict'] = 'consequence'
      ..['cause'] = 9999
      ..['why'] = {'code': 'net.captive', 'params': <String, dynamic>{}};
    await settle(tester);

    expect(io.posted, hasLength(1));
    expect(io.posted.single.id, root['id']);
  });

  testWidgets('a subscription waiting for the connection or the network shows a popup, and the popup closes itself', (
    tester,
  ) async {
    final host = FakeCoreHost();
    await pumpApp(tester, host);

    // the popup carries a spinner, so the frames are pumped by time, not until the tree settles
    host.setSubWaits([(source: 's1', name: 'Alpha', forWhat: 'connection')]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Waiting for connection…'), findsOneWidget);
    expect(find.textContaining('Alpha'), findsOneWidget, reason: 'the popup names the subscription');

    host.setSubWaits([(source: 's2', name: 'Beta', forWhat: 'network')]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Waiting for connection…'), findsNothing);
    expect(find.text('Waiting for network…'), findsOneWidget);
    expect(find.textContaining('Beta'), findsOneWidget);
    expect(find.textContaining('Alpha'), findsNothing);

    host.setSubWaits([]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Waiting for network…'), findsNothing);
    expect(find.textContaining('Beta'), findsNothing);
  });
}
