// Buttons and reason line of an event (т1, docs/logs.md «По типам» and «Тексты»): the buttons a folded row shows
// per type; the bold ones are the notification's buttons (`SystemNotifier.eventActions`); a notification's Retry
// makes the same host call as the row's Retry; a consequence's reason is "Cause: <title of its root>"; a reason
// that equals the detail is shown once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/core/system_notifier.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;
import 'system_notification_test.dart' show FakeNotifyIo, FakePowerIo;

final _en = lookupAppLocalizations(const Locale('en'));

EventWords _words(FakeCoreHost host) => EventWords(_en, host.catalog);

/// The title a plain event shows as its own row.
String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    _words(host).describe(EventRecord.fromJson(e)).title;

/// Sets the fields Sentinel writes on an event (`verdict`, `why`, `cause`).
Map<String, dynamic> _consequenceOf(Map<String, dynamic> root, String code, Map<String, dynamic> e) => e
  ..['verdict'] = 'consequence'
  ..['cause'] = root['id']
  ..['why'] = {'code': code, 'params': <String, dynamic>{}};

Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.logs.icon));
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// The host of these tests: it records the two calls a row's (or a notification's) Retry can make.
class _SpyHost extends FakeCoreHost {
  final hostCalls = <String>[];

  @override
  Future<void> retry() async => hostCalls.add('retry');

  @override
  Future<ConnectResult> connect() async {
    hostCalls.add('connect');
    return super.connect();
  }
}

late FakeNotifyIo io;
late NotifyIo _savedNotify;
late PowerIo _savedPower;

void main() {
  setUp(() {
    _savedNotify = NotifyIo.current;
    io = FakeNotifyIo();
    NotifyIo.current = io;
    _savedPower = PowerIo.current;
    PowerIo.current = FakePowerIo();
  });

  tearDown(() {
    NotifyIo.current = _savedNotify;
    PowerIo.current = _savedPower;
  });

  group('the row buttons of the table «По типам»', () {
    testWidgets('conn/lost: Check now and Open, without opening the row', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'lost', level: 'warn');
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.checkNow), findsOneWidget);
      expect(find.text(_en.open), findsOneWidget);
    });

    testWidgets('conn/failing: Open (the app in Per-app)', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'failing', level: 'warn', data: const {'app': 'org.x.app'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.open), findsOneWidget);
    });

    for (final type in ['switched', 'fastest']) {
      testWidgets('auto/$type: Open', (tester) async {
        final host = FakeCoreHost();
        host.addEvent(
          'auto',
          type,
          level: 'info',
          data: type == 'switched'
              ? const {'from': 'Alpha', 'to': 'Beta', 'reason': 'failover'}
              : const {'route': 'r1', 'from': 'Alpha', 'to': 'Beta'},
        );
        await pumpApp(tester, host);
        await _openLogs(tester);

        expect(find.text(_en.open), findsOneWidget);
      });
    }

    testWidgets('speed/failed: Retry', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('speed', 'failed', level: 'warn', data: const {'error': 'boom'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.retry), findsOneWidget);
    });

    testWidgets('core/updateAvailable: Open update', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('core', 'updateAvailable', level: 'info', data: const {'version': '1.2'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.openUpdate), findsOneWidget);
    });

    testWidgets('sub/removed (old journal) in use: Choose server', (tester) async {
      final host = FakeCoreHost();
      host.addEvent(
        'sub',
        'removed',
        level: 'warn',
        data: const {'source': 's1', 'name': 'Alpha', 'count': 1, 'names': ['Beta'], 'inUse': true},
      );
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.chooseServer), findsOneWidget);
    });

    testWidgets('sub/back has no buttons (docs/logs.md «По типам»)', (tester) async {
      final host = FakeCoreHost();
      host.addEvent(
        'sub',
        'back',
        level: 'info',
        data: const {'source': 's1', 'name': 'Alpha', 'count': 1, 'names': ['Beta']},
      );
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.chooseServer), findsNothing);
      expect(find.text(_en.open), findsNothing);
    });

    testWidgets('core/crashed: Retry while the core is not running; «restarted» closes the row and the Retry goes', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final crash = host.addEvent('core', 'crashed', level: 'error', data: const {'code': 2});
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text(_en.retry), findsOneWidget, reason: 'not running');

      host.addEvent('core', 'restarted', level: 'info')['opens'] = crash['id'];
      await tester.pump(const Duration(milliseconds: 600)); // the feed reads the journal after its debounce
      await tester.pumpAndSettle();
      expect(find.text(_en.retry), findsNothing, reason: 'running again');
    });

    // «VPN не работает»: the buttons come from the causes (docs/logs.md → «Кнопки»)
    for (final (label, data, shown, hidden) in [
      (
        'core',
        const {'causes': ['core']},
        [_en.retry, _en.sendReport],
        [_en.networkSettings, _en.removeSystemProxy],
      ),
      (
        'core kept proxy',
        const {'causes': ['core'], 'proxy': 'kept'},
        [_en.retry, _en.removeSystemProxy, _en.sendReport],
        [_en.networkSettings],
      ),
      (
        'core removed proxy',
        const {'causes': ['core'], 'proxy': 'removed'},
        [_en.retry],
        [_en.removeSystemProxy, _en.networkSettings],
      ),
      (
        'network',
        const {'causes': ['network'], 'source': 'probes'},
        [_en.networkSettings],
        [_en.retry, _en.removeSystemProxy],
      ),
      (
        'core and network',
        const {'causes': ['core', 'network']},
        [_en.retry, _en.networkSettings],
        [_en.removeSystemProxy],
      ),
    ]) {
      testWidgets('conn/vpnDown, $label: shows ${shown.join(', ')}; not ${hidden.join(', ')}', (tester) async {
        final host = FakeCoreHost();
        final down = host.addEvent('conn', 'vpnDown', level: 'error', data: data)..['verdict'] = 'confirmed';
        await pumpApp(tester, host);
        await _openLogs(tester);
        await _expand(tester, _titleOf(host, down));

        for (final label in shown) {
          expect(find.text(label), findsOneWidget);
        }
        for (final label in hidden) {
          expect(find.text(label), findsNothing);
        }
      });
    }

    testWidgets('conn/vpnDown Retry is live: it goes once the core runs, and the closing vpnUp takes the buttons away', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['core'], 'proxy': 'kept'})
        ..['verdict'] = 'confirmed';
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, down));
      expect(find.text(_en.retry), findsOneWidget, reason: 'not connected to the core');

      host.setPhase(ConnectionPhase.connected);
      await tester.pumpAndSettle();
      expect(find.text(_en.retry), findsNothing, reason: 'the core runs now');

      host.addEvent('conn', 'vpnUp', level: 'info', data: const {'downMs': 4000, 'causes': ['core']})['opens'] = down['id'];
      await tester.pump(const Duration(milliseconds: 600)); // the feed reads the journal after its debounce
      await tester.pumpAndSettle();
      expect(find.text(_en.removeSystemProxy), findsNothing, reason: 'closed: the proxy is back');
      expect(find.text(_en.retry), findsNothing);
    });

    testWidgets('a crash chain joined into conn/vpnDown keeps Remove system proxy until the vpnUp closes it', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final crash = host.addEvent('core', 'crashed', level: 'error', data: const {'code': 2})..['verdict'] = 'confirmed';
      final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['core'], 'proxy': 'kept'})
        ..['verdict'] = 'confirmed'
        ..['joins'] = [crash['id']];
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text(_en.removeSystemProxy), findsOneWidget);

      host.addEvent('conn', 'vpnUp', level: 'info', data: const {'downMs': 4000, 'causes': ['core']})['opens'] = down['id'];
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text(_en.removeSystemProxy), findsNothing);
    });

    testWidgets('conn/connectFailed: Retry', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'connectFailed', level: 'error', data: const {'reason': 'boom'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.retry), findsOneWidget);
      expect(find.text(_en.openSettings), findsNothing);
      expect(find.text(_en.chooseServer), findsNothing);
    });

    testWidgets('conn/connectFailed fix: settings: Open settings leads to Settings → Connection', (tester) async {
      final host = FakeCoreHost();
      host.addEvent(
        'conn',
        'connectFailed',
        level: 'error',
        data: const {'reason': 'sing-box failed to start: listen tcp 127.0.0.1:2080: bind: address already in use', 'fix': 'settings'},
      );
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text(_en.retry), findsOneWidget);
      expect(find.text(_en.chooseServer), findsNothing);
      expect(find.text(_en.proxyPort), findsNothing);

      await tester.tap(find.text(_en.openSettings));
      await tester.pumpAndSettle();
      expect(find.text(_en.proxyPort), findsWidgets, reason: 'the Connection sheet with the proxy port');
    });

    testWidgets('conn/connectFailed fix: pick: Choose server, no Open settings', (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'connectFailed', level: 'error', data: const {'reason': 'Manual pick x is not usable', 'fix': 'pick'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_en.chooseServer), findsOneWidget);
      expect(find.text(_en.openSettings), findsNothing);
    });

    test('the buttons of conn/connectFailed go by `fix`, never by the words of `reason`', () {
      final host = FakeCoreHost();
      EventRecord ev(Map<String, dynamic> d) => EventRecord.fromJson(host.addEvent('conn', 'connectFailed', level: 'error', data: d));
      final portWords = ev(const {'reason': 'the proxy port is busy, change it in settings'});
      expect(eventCauseInSettings(portWords), isFalse);
      final pickWords = ev(const {'reason': 'Manual pick "A" is unavailable: it is switched off.'});
      expect(eventPinLost(pickWords), isFalse);
      expect(eventCauseInSettings(ev(const {'reason': 'x', 'fix': 'settings'})), isTrue);
      expect(eventPinLost(ev(const {'reason': 'x', 'fix': 'pick'})), isTrue);
      expect(eventCauseInSettings(ev(const {'reason': 'x', 'fix': 'pick'})), isFalse);
    });

    test('conn/disconnected by a lost pin: a server gone without its name is not named by the entry', () {
      final host = FakeCoreHost();
      String detail(Map<String, dynamic> d) =>
          _words(host).describe(EventRecord.fromJson(host.addEvent('conn', 'disconnected', level: 'warn', data: d))).title;
      expect(
        detail(const {'by': 'error', 'reason': 'pinLost', 'pick': 'Frankfurt 1', 'why': 'off'}),
        _en.vpnDisconnectedErrorServerIsUnavailable('Frankfurt 1', _en.switchedOff),
      );
      expect(
        detail(const {'by': 'error', 'reason': 'pinLost', 'pick': '', 'why': 'deleted'}),
        _en.vpnDisconnectedErrorServerIsUnavailable2(_en.deleted2),
      );
    });
  });

  group('the notification buttons (bold in the table)', () {
    test('sub/updated: one button, Open', () {
      final host = FakeCoreHost();
      final e = host.addEvent(
        'sub',
        'updated',
        level: 'info',
        data: const {'source': 's1', 'name': 'Alpha', 'added': 1, 'removed': 0, 'total': 5},
      );
      final actions = SystemNotifier.eventActions(EventRecord.fromJson(e), _words(host), host);
      expect([for (final a in actions) a.$2], ['Open']);
    });

    test('conn/vpnDown: Retry while the core is not running, Network settings for a network cause; two at most', () {
      final host = FakeCoreHost();
      List<String> bold(List<String> causes) {
        final e = EventRecord.fromJson(host.addEvent('conn', 'vpnDown', level: 'error', data: {'causes': causes}));
        final actions = SystemNotifier.eventActions(e, _words(host), host);
        expect(actions.length, lessThanOrEqualTo(2));
        return [for (final a in actions) a.$1];
      }

      expect(bold(['core']), ['retry']);
      expect(bold(['network']), ['networkSettings']);
      expect(bold(['core', 'network']).toSet(), {'retry', 'networkSettings'});

      host.setPhase(ConnectionPhase.connected);
      expect(bold(['core']), isNot(contains('retry')), reason: 'the core runs: nothing to retry');
    });

    testWidgets('the notification Retry of conn/connectFailed makes the same host call as the row Retry', (
      tester,
    ) async {
      final host = _SpyHost();
      final e = host.addEvent('conn', 'connectFailed', level: 'error', data: const {'reason': 'boom'});
      await pumpApp(tester, host);
      await _openLogs(tester);

      await tester.tap(find.text(_en.retry));
      await tester.pumpAndSettle();
      final rowCalls = [...host.hostCalls];
      expect(rowCalls, hasLength(1));

      host.hostCalls.clear();
      io.press(NoteActionTap(id: e['id'] as int, action: 'retry'));
      await tester.pumpAndSettle();
      expect(host.hostCalls, rowCalls);
    });
  });

  group('the reason line', () {
    testWidgets('a consequence reads "Cause: <title of its root>" with the root event\'s own title', (tester) async {
      final host = FakeCoreHost();
      final root = host.addEvent('conn', 'offline', level: 'warn');
      _consequenceOf(
        root,
        'net.offline',
        host.addEvent('conn', 'lost', level: 'warn'),
      );
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, root));
      // the root's type is hidden by the filter: the consequence shows as a row of its own
      await tester.ensureVisible(find.byKey(const ValueKey('evHideType')));
      await tester.tap(find.byKey(const ValueKey('evHideType')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('evReason'))).data,
        'Cause: ${_titleOf(host, root)}',
      );
    });

    testWidgets('a reason equal to the detail is shown once', (tester) async {
      final host = FakeCoreHost();
      final e = host.addEvent(
        'sub',
        'failed',
        level: 'warn',
        data: const {'source': 's1', 'name': 'Prov', 'error': 'boom', 'own': false},
      );
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('boom'), findsWidgets, reason: 'the detail is shown');
      expect(find.byKey(const ValueKey('evReason')), findsNothing, reason: 'the reason repeats the detail: not shown');
    });

    test('a reason code the detail already words (auto failover, disconnect down) is no reason line', () {
      final host = FakeCoreHost();
      final w = _words(host);
      for (final (cat, type, data) in [
        ('auto', 'switched', <String, dynamic>{'from': 'a', 'to': 'b', 'reason': 'failover', 'fails': 3}),
        ('dns', 'switched', <String, dynamic>{'from': 'a', 'to': 'b', 'reason': 'failover', 'side': 'direct'}),
        ('conn', 'disconnected', <String, dynamic>{'by': 'error', 'reason': 'down', 'attempts': 3}),
      ]) {
        final g = EventGroup(
          EventRecord.fromJson({'id': 1, 'at': 1000, 'cat': cat, 'type': type, 'level': 'warn', 'own': false, 'data': data}),
        );
        expect(w.reasonLine(g), isNull, reason: '$cat/$type');
      }
    });
  });
}
