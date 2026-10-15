import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand/widgets/latency_text.dart';
import 'package:jormungand/widgets/settings_dns.dart';
import 'package:jormungand_core/jormungand_core.dart' show DnsTransport;

import 'fake_core_host.dart';

DnsRace _race(String id, String side, List<DnsRaceTransport> ts, {String? win}) =>
    DnsRace(provider: id, side: side, winnerKind: win, transports: ts);

Future<void> _form(WidgetTester t, FakeCoreHost host, {String? id}) async {
  t.view.devicePixelRatio = 2;
  t.view.physicalSize = const Size(640, 2400);
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(
    AppSettingsScope(
      settings: AppSettings(locale: const Locale('en')),
      child: CoreHostScope(
        host: host,
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
          home: Scaffold(body: DnsForm(id: id)),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

String _own(FakeCoreHost host) => host.catalog.dnsSave(
  null,
  name: 'Mine',
  transports: [DnsTransport('doh', 'https://9.9.9.9/dns-query'), DnsTransport('udp', '9.9.9.9')],
  sides: ['direct', 'vpn'],
  use: {'doh', 'udp'},
);

void main() {
  test('the poll loop asks once, then polls (poll: true) and ends when testing is false', () async {
    final host = FakeCoreHost();
    final id = _own(host);
    const testing = [DnsRaceTransport(kind: 'doh', state: 'testing')];
    const done = [DnsRaceTransport(kind: 'doh', ms: 40, state: 'ok')];
    host.raceReplies[id] = [
      [_race(id, 'vpn', testing)],
      [_race(id, 'vpn', testing)],
      [_race(id, 'vpn', done)],
    ];
    final seen = <bool>[];
    final r = await pingDnsUntilDone(host, id, every: Duration.zero, onAnswer: (a) => seen.add(a.testing));
    expect(r.testing, isFalse);
    expect(seen, [true, true, false]);
    expect(host.calls.where((c) => c.startsWith('pingDnsSides')), ['pingDnsSides $id', 'pingDnsSides $id poll', 'pingDnsSides $id poll']);
  });

  test('the poll loop stops at the cap with testing still true', () async {
    final host = FakeCoreHost();
    final id = _own(host);
    host.raceReplies[id] = [
      [_race(id, 'vpn', const [DnsRaceTransport(kind: 'doh', state: 'testing')])],
    ];
    final r = await pingDnsUntilDone(host, id, every: Duration.zero, cap: 3);
    expect(r.testing, isTrue);
    expect(host.calls.where((c) => c == 'pingDnsSides $id poll').length, 3);
  });

  testWidgets('a saved provider has a row per enabled side and kind before any ping; no tunnel = VPN hint', (t) async {
    final host = FakeCoreHost();
    final id = _own(host);
    await _form(t, host, id: id);
    for (final k in ['vpn-doh', 'vpn-udp', 'direct-doh', 'direct-udp']) {
      expect(find.byKey(ValueKey('dns-race-$k')), findsOneWidget, reason: k);
    }
    expect(find.text('The VPN side is measured only while connected: it needs a tunnel'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the rows show the status of a connected core before a ping, no hint', (t) async {
    final host = FakeCoreHost();
    final id = _own(host);
    host.dnsHealthValue = DnsHealth(
      races: [
        _race(id, 'vpn', const [DnsRaceTransport(kind: 'doh', ms: 55, state: 'ok'), DnsRaceTransport(kind: 'udp', ms: 20, state: 'ok')]),
      ],
    );
    host.raceReplies[id] = [const []];
    await _form(t, host, id: id);
    expect(find.descendant(of: find.byKey(const ValueKey('dns-race-vpn-doh')), matching: find.text('55ms')), findsOneWidget);
    expect(find.text('The VPN side is measured only while connected: it needs a tunnel'), findsNothing);
  });

  testWidgets('the Ping summary is the best answer; "No answer" only when no transport on any side answered', (t) async {
    final host = FakeCoreHost();
    final id = _own(host);
    const miss = DnsRaceTransport(kind: 'doh', ms: -1, state: 'miss');
    host.raceReplies[id] = [
      [
        _race(id, 'vpn', const [miss, DnsRaceTransport(kind: 'udp', ms: 12, state: 'ok')]),
        _race(id, 'direct', const [miss, DnsRaceTransport(kind: 'udp', ms: -1, state: 'miss')]),
      ],
    ];
    await _form(t, host, id: id);
    expect(find.descendant(of: find.byKey(const ValueKey('dns-ping-summary')), matching: find.text('12ms')), findsOneWidget);

    final all = FakeCoreHost();
    final id2 = _own(all);
    all.raceReplies[id2] = [
      [
        _race(id2, 'vpn', const [miss, DnsRaceTransport(kind: 'udp', ms: -1, state: 'miss')]),
        _race(id2, 'direct', const [miss, DnsRaceTransport(kind: 'udp', ms: -1, state: 'miss')]),
      ],
    ];
    await _form(t, all, id: id2);
    expect(find.byKey(const ValueKey('dns-ping-summary')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const ValueKey('dns-ping-summary'))).data, 'No answer');
  });

  testWidgets('an unsaved draft pings every enabled kind address in this process, not the first only', (t) async {
    final host = FakeCoreHost();
    host.dnsPings['https://1.1.1.1/dns-query'] = -1;
    host.dnsPings['tls://1.1.1.1'] = 30;
    await _form(t, host);
    await t.enterText(find.byType(TextField).at(1), 'https://1.1.1.1/dns-query');
    await t.pump();
    await t.tap(find.byType(SecondaryButton).first); // + address
    await t.pump();
    await t.enterText(find.byType(TextField).at(2), 'tls://1.1.1.1');
    await t.pump();
    expect(find.byKey(const ValueKey('dns-race-direct-doh')), findsNothing); // no rows before a ping
    await t.tap(find.widgetWithText(SecondaryButton, 'Ping'));
    await t.pump();
    await t.pump();
    expect(host.calls, containsAll(['pingDns https://1.1.1.1/dns-query', 'pingDns tls://1.1.1.1']));
    expect(find.descendant(of: find.byKey(const ValueKey('dns-race-direct-doh')), matching: find.text('No answer')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('dns-race-direct-dot')), matching: find.text('30ms')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('dns-ping-summary')), matching: find.byType(LatencyView)), findsNothing);
    expect(find.text('30ms'), findsWidgets);
  });
}
