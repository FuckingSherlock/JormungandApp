// «VPN не работает» with its third cause `routes` (docs/logs.md «VPN не работает», «Тексты», «Кнопки»): conn/vpnDown
// reads «VPN is down» for any routes cause; its reason gives «no route answers, the internet works directly» (or «none
// of N routes answers …» when data.routes is above 1) in the order of `causes`, the system-proxy line last. conn/vpnUp
// names its parts in the fixed order core, network, routes; no known cause reads «VPN works again». A live vpnDown
// with routes offers Check now and Open, and its notification offers checkNow (at most two buttons). A vpnDown with
// no cause and data.pending 'routes' (the network is back, no route answered yet) reads «Checking routes …» with an
// empty reason line and offers the same Check now / Open; with the network alone it has no Check now.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/core/system_notifier.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/platform/notify_channel.dart';
import 'package:jormungand/platform/power_channel.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/event_rows.dart' show eventOpenTarget;
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;
import 'system_notification_test.dart' show FakeNotifyIo, FakePowerIo;

const _t0 = 1800000000000; // a fixed clock: the journal times are counted from here, in seconds
const _routesPhrase = 'no route answers, the internet works directly';

final _en = lookupAppLocalizations(const Locale('en'));

/// An event as the journal holds it (the fields Sentinel sets are passed when given).
EventRecord _ev(
  int id,
  String cat,
  String type, {
  String level = 'error',
  Map<String, dynamic> data = const {},
  int? opens,
}) => EventRecord.fromJson({
  'id': id,
  'at': _t0,
  'cat': cat,
  'type': type,
  'level': level,
  'own': false,
  'data': data,
  'opens': ?opens,
});

/// A vpnDown with the given causes (and [data] for the rest).
EventRecord _down(List<String> causes, {String level = 'error', Map<String, dynamic> data = const {}}) =>
    _ev(1, 'conn', 'vpnDown', level: level, data: {'causes': causes, ...data});

/// A vpnUp that closes an outage by [causes] (absent when null).
EventRecord _up(List<String>? causes, {Map<String, dynamic> data = const {}}) => _ev(
  2,
  'conn',
  'vpnUp',
  level: 'info',
  opens: 1,
  data: {'downMs': 185000, 'causes': ?causes, ...data},
);

/// Title, sub and detail joined as one line with « · » between them (a part that starts with « · » does not double it).
String _joinParts(String title, String sub, String detail) => [title, sub, detail]
    .map((s) => s.replaceFirst(RegExp(r'^\s*·\s*'), '').trim())
    .where((s) => s.isNotEmpty)
    .join(' · ');

/// The whole text of an event's own row.
String _text(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return _joinParts(d.title, d.sub, d.detail);
}

/// The title a plain event shows as its own row.
String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    EventWords(_en, host.catalog).describe(EventRecord.fromJson(e)).title;

Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.logs.icon));
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

void main() {
  final words = EventWords(_en, FakeCoreHost().catalog);

  late NotifyIo savedNotify;
  late PowerIo savedPower;

  setUp(() {
    savedNotify = NotifyIo.current;
    NotifyIo.current = FakeNotifyIo();
    savedPower = PowerIo.current;
    PowerIo.current = FakePowerIo();
  });

  tearDown(() {
    NotifyIo.current = savedNotify;
    PowerIo.current = savedPower;
  });

  group('conn/vpnDown with the routes cause reads «VPN is down»', () {
    test('any routes cause is a down, not a wait; network alone is still the wait', () {
      for (final causes in [
        ['routes'],
        ['core', 'routes'],
        ['routes', 'network'],
        ['routes', 'core', 'network'],
      ]) {
        expect(words.describe(_down(causes)).title, 'VPN is down', reason: '$causes');
      }
      expect(
        _text(words, _down(['network'], level: 'warn')),
        'Waiting for network · VPN is on, no internet connection',
      );
    });

    test('routes alone: no route answers, the internet works directly', () {
      expect(_text(words, _down(['routes'])), 'VPN is down · $_routesPhrase');
    });

    test('data.routes above 1 names the count; 1 or no count keeps the plain phrase', () {
      expect(
        _text(words, _down(['routes'], data: {'routes': 3})),
        'VPN is down · none of 3 routes answers, the internet works directly',
      );
      for (final data in <Map<String, dynamic>>[{}, {'routes': 1}]) {
        expect(_text(words, _down(['routes'], data: data)), 'VPN is down · $_routesPhrase', reason: '$data');
      }
    });

    test('the reasons follow the order of causes, joined by « · »; the system-proxy line comes last', () {
      // the case of the words is not the point here: the phrases are compared lower-cased
      String lower(EventRecord e) => _text(words, e).toLowerCase();
      expect(
        lower(_down(['core', 'routes'])),
        'vpn is down · sing-box stopped and has not restarted for 30 s · $_routesPhrase',
      );
      expect(
        lower(_down(['routes', 'core'])),
        'vpn is down · $_routesPhrase · sing-box stopped and has not restarted for 30 s',
      );
      expect(
        lower(_down(['routes', 'network'])),
        'vpn is down · $_routesPhrase · no internet connection',
      );
      expect(
        lower(_down(['routes'], data: {'proxy': 'kept'})),
        'vpn is down · $_routesPhrase · system proxy is still set, so programs that use it have no internet',
      );
    });
  });

  group('conn/vpnUp with the routes cause: VPN works again · the parts in the fixed order core, network, routes', () {
    test('the parts named by the causes that cleared', () {
      for (final (causes, text) in [
        (['routes'], 'VPN works again · a route answers'),
        (['routes', 'network'], 'VPN works again · internet is available, a route answers'),
        (['routes', 'core'], 'VPN works again · sing-box is running, a route answers'),
        (['network', 'core'], 'VPN works again · sing-box is running, internet is available'),
        (['core', 'network', 'routes'],
            'VPN works again · sing-box is running, internet is available, a route answers'),
        (['routes', 'network', 'core'],
            'VPN works again · sing-box is running, internet is available, a route answers'),
      ]) {
        expect(_text(words, _up(causes)), text, reason: '$causes');
      }
    });

    test('no known cause reads VPN works again; closed by you or the system it is the outage-ended text', () {
      expect(_text(words, _up([])), 'VPN works again', reason: 'empty causes');
      expect(_text(words, _up(null)), 'VPN works again', reason: 'no causes');
      for (final by in ['user', 'system']) {
        expect(
          _text(words, _up(['routes'], data: {'by': by})),
          'VPN outage ended · VPN disconnected',
          reason: by,
        );
      }
    });
  });

  group('the buttons with the routes cause', () {
    testWidgets('a live conn/vpnDown with routes: Check now and Open', (tester) async {
      final host = FakeCoreHost();
      final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['routes']})
        ..['verdict'] = 'confirmed';
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, down));

      expect(find.text(_en.checkNow), findsOneWidget);
      expect(find.text(_en.open), findsOneWidget);
    });

    testWidgets('the closing vpnUp takes Check now away: the buttons follow the current causes', (tester) async {
      final host = FakeCoreHost();
      final down = host.addEvent('conn', 'vpnDown', level: 'error', data: const {'causes': ['routes']})
        ..['verdict'] = 'confirmed';
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, down));
      expect(find.text(_en.checkNow), findsOneWidget, reason: 'live');

      host.addEvent('conn', 'vpnUp', level: 'info', data: const {'downMs': 4000, 'causes': ['routes']})['opens'] = down['id'];
      await tester.pump(const Duration(milliseconds: 600)); // the feed reads the journal after its debounce
      await tester.pumpAndSettle();
      expect(find.text(_en.checkNow), findsNothing, reason: 'closed');
    });
  });

  group('the notification buttons with the routes cause', () {
    test('conn/vpnDown with routes offers checkNow; never more than two buttons', () {
      final host = FakeCoreHost();
      List<String> buttons(List<String> causes) {
        final e = EventRecord.fromJson(host.addEvent('conn', 'vpnDown', level: 'error', data: {'causes': causes}));
        final actions = SystemNotifier.eventActions(e, EventWords(_en, host.catalog), host);
        expect(actions.length, lessThanOrEqualTo(2), reason: '$causes');
        return [for (final a in actions) a.$1];
      }

      expect(buttons(['routes']), contains('checkNow'));
      expect(buttons(['network', 'routes']), containsAll(['checkNow', 'networkSettings']));
      expect(buttons(['core', 'routes']), containsAll(['checkNow', 'retry']));
      buttons(['core', 'network', 'routes']); // the cap of two holds for all three
    });
  });

  group('conn/vpnDown pending routes: the network is back, no route has answered yet', () {
    const pendingTitle = 'Checking routes · the network is back, no route has answered yet';

    test('the title is the pending text; the reason line is empty', () {
      final d = words.describe(_down([], level: 'warn', data: {'pending': 'routes'}));
      expect(_joinParts(d.title, d.sub, ''), pendingTitle);
      expect(d.detail, isEmpty);
    });

    testWidgets('a live pending vpnDown has Check now and Open', (tester) async {
      final host = FakeCoreHost();
      final down = host.addEvent('conn', 'vpnDown', level: 'warn', data: const {'causes': [], 'pending': 'routes'})
        ..['verdict'] = 'confirmed';
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, down));

      expect(find.text(_en.checkNow), findsOneWidget);
      expect(find.text(_en.open), findsOneWidget);
    });

    test('the open target is route for pending and for routes; the network alone is not route', () {
      final host = FakeCoreHost();
      expect(eventOpenTarget(_down([], level: 'warn', data: {'pending': 'routes'}), host), 'route');
      expect(eventOpenTarget(_down(['routes']), host), 'route');
      expect(eventOpenTarget(_down(['network'], level: 'warn'), host), isNot('route'));
    });

    test('the notification offers checkNow for pending; the network alone does not', () {
      final host = FakeCoreHost();
      List<String> buttons(Map<String, dynamic> data, String level) {
        final e = EventRecord.fromJson(host.addEvent('conn', 'vpnDown', level: level, data: data));
        final actions = SystemNotifier.eventActions(e, EventWords(_en, host.catalog), host);
        expect(actions.length, lessThanOrEqualTo(2), reason: '$data');
        return [for (final a in actions) a.$1];
      }

      expect(buttons({'causes': [], 'pending': 'routes'}, 'warn'), contains('checkNow'));
      expect(buttons({'causes': ['network']}, 'warn'), isNot(contains('checkNow')));
    });

    testWidgets('the network alone: the wait row has no Check now', (tester) async {
      final host = FakeCoreHost();
      final wait = host.addEvent('conn', 'vpnDown', level: 'warn', data: const {'causes': ['network']})
        ..['verdict'] = 'confirmed';
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, wait));

      expect(find.text(_en.checkNow), findsNothing);
    });
  });
}
