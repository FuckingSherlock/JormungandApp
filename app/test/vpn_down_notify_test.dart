// «VPN не работает» as system notifications (docs/logs.md → «„VPN не работает“», «Свёртки» 2 and 5): one
// notification per failure under the id of `conn/vpnDown`; the closing `conn/vpnUp` replaces it even when its
// switch was turned off after it showed; a crash and its failed restarts never notify; a network cause notifies,
// a lone offline line without a connection does not; a cause that comes while the failure is open changes the
// notification in place.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';

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
Map<String, dynamic> _vpnDown(
  FakeCoreHost host,
  List<String> causes, {
  Map<String, dynamic> extra = const {},
  List<int> joins = const [],
}) {
  // the network alone is the waiting, a warn; the core makes it an error
  final waiting = causes.length == 1 && causes.first == 'network';
  final e = host.addEvent('conn', 'vpnDown', level: waiting ? 'warn' : 'error', data: {'causes': causes, ...extra})
    ..['verdict'] = 'confirmed'
    ..['why'] = {'code': causes.first == 'core' ? 'core.down' : 'net.offline', 'params': <String, dynamic>{}};
  if (joins.isNotEmpty) e['joins'] = joins;
  return e;
}

/// `conn/vpnUp`: info, closing the failure `down`.
Map<String, dynamic> _vpnUp(FakeCoreHost host, Map<String, dynamic> down, Map<String, dynamic> data) =>
    host.addEvent('conn', 'vpnUp', level: 'info', data: data)..['opens'] = down['id'];

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

  List<int> postedIds() => [for (final n in io.posted) n.id];

  testWidgets('a crash that turns into a VPN failure: the failure posts once, its closing replaces it under the same id', (
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
    final down = _vpnDown(host, ['core'], extra: {'proxy': 'kept'}, joins: [crash['id'] as int]);
    await settle(tester);
    expect(postedIds(), [down['id']], reason: 'the crash and its restarts post nothing; one id, the failure\'s');

    host.addEvent('core', 'restarted', level: 'info')['opens'] = crash['id'];
    _vpnUp(host, down, {'downMs': 9000, 'causes': ['core']});
    await settle(tester);
    expect(postedIds(), [down['id'], down['id']], reason: 'the closing one takes the same id');
    final closing = io.posted.last;
    expect(
      '${closing.title}\n${closing.text}',
      contains(_en.vpnWorksAgain),
      reason: 'the closing replaces the words: «VPN works again»',
    );
  });

  testWidgets('the closing (network back) replaces the shown notification after its switch was turned off', (tester) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final down = _vpnDown(host, ['network'], extra: {'source': 'probes'});
    await settle(tester);
    expect(postedIds(), [down['id']]);

    host.notif.setFlag('connLost', false);
    _vpnUp(host, down, {'downMs': 3000, 'causes': ['network']});
    await settle(tester);
    expect(postedIds(), [down['id'], down['id']], reason: 'the same id, whatever the switch says now');
  });

  testWidgets('the closing by the user posts nothing: it takes only the shown failure off the shade, by its id', (tester) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final down = _vpnDown(host, ['network'], extra: {'source': 'probes'});
    await settle(tester);
    expect(postedIds(), [down['id']]);

    host.notif.setFlag('connLost', false);
    _vpnUp(host, down, {'downMs': 3000, 'causes': ['network'], 'by': 'user'});
    await settle(tester);
    expect(postedIds(), [down['id']], reason: 'the closing of a disconnect has no notification of its own');
    expect(io.cancelledIds, [down['id']], reason: 'the shown failure goes by its id, whatever the switch says now');
    expect(io.cancels, 0, reason: 'cancelEvents() would take every event notification off');
  });

  testWidgets('with the switch off from the start, neither the failure nor its closing posts anything', (tester) async {
    final host = await open(tester);
    host.notif.setFlag('connLost', false);
    _lifecycleTo(AppLifecycleState.paused);
    final down = _vpnDown(host, ['core']);
    _vpnUp(host, down, {'downMs': 3000, 'causes': ['core']});
    await settle(tester);
    expect(io.posted, isEmpty);
  });

  testWidgets('a crash and its failed restarts never notify', (tester) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final crash = host.addEvent('core', 'crashed', level: 'error', data: const {'code': 2})..['verdict'] = 'confirmed';
    for (var n = 1; n <= 2; n++) {
      host.addEvent('core', 'restartFailed', level: 'error', data: {'attempt': n, 'error': 'boom'})
        ..['verdict'] = 'consequence'
        ..['cause'] = crash['id'];
    }
    await settle(tester);
    expect(io.posted, isEmpty);
  });

  testWidgets('a network failure notifies as the VPN is down; an offline line without a connection only goes to the journal', (
    tester,
  ) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    host.addEvent('conn', 'offline', level: 'info', data: const {'source': 'probes'});
    await settle(tester);
    expect(io.posted, isEmpty);

    final down = _vpnDown(host, ['network'], extra: {'source': 'probes'});
    await settle(tester);
    expect(postedIds(), [down['id']]);
  });

  testWidgets('a cause that comes while the failure is open changes its notification in place: the same id, new words', (
    tester,
  ) async {
    final host = await open(tester);
    _lifecycleTo(AppLifecycleState.paused);
    final down = _vpnDown(host, ['core'], extra: {'proxy': 'kept'});
    await settle(tester);
    final first = io.posted.single;

    // the core changes the event in place (`rev`); the app reads the change with the next journal read
    down['data'] = {'causes': ['core', 'network'], 'proxy': 'kept'};
    down['rev'] = 1;
    host.addEvent('core', 'updateInstalled', level: 'info', data: const {'from': '1.0', 'to': '1.1'});
    await settle(tester);
    expect(postedIds(), [down['id'], down['id']], reason: 'the notification of the same failure');
    expect(
      '${io.posted.last.title}\n${io.posted.last.text}',
      isNot('${first.title}\n${first.text}'),
      reason: 'the words follow the causes now',
    );
  });
}
