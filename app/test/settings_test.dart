import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/app_update.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/format.dart' show fmtBytes;
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/pages/home_page.dart';
import 'package:jormungand/pages/settings_page.dart';
import 'package:jormungand/platform/files_channel.dart';
import 'package:jormungand/platform/platform_caps.dart';
import 'package:jormungand/shell/app_links.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/catalog_card.dart' show GripHandle;
import 'package:jormungand/widgets/settings_dns.dart' show DnsForm;
import 'package:jormungand/widgets/settings_parts.dart' show DimWhen;
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_backup_io.dart';
import 'fake_core_host.dart';

/// The Settings page (or Home) alone, 320 dp wide and tall enough that a sheet's lazy lists
/// build every row; the shell is not needed here.
Future<AppSettings> _pump(
  WidgetTester tester,
  FakeCoreHost host, {
  Widget page = const SettingsPage(),
  double textScale = 1.0,
  AppLinks links = const AppLinks(),
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 2400);
  addTearDown(tester.view.reset);
  // a second pump in one test starts from nothing, not under the first one's open sheet
  await tester.pumpWidget(const SizedBox.shrink());
  final settings = AppSettings(
    textScale: textScale,
    locale: const Locale('en'),
  );
  await tester.pumpWidget(
    AppSettingsScope(
      settings: settings,
      child: CoreHostScope(
        host: host,
        child: AppLinksScope(
          links: links,
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              child: child!,
            ),
            home: Scaffold(body: page),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

Future<void> _open(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('settings-$id')));
  await tester.pumpAndSettle();
}

/// The toggle of the row labelled [label].
Finder _toggleOf(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(SetRow)).first,
  matching: find.byType(MiniToggle),
);

const _rows = [
  'setauto',
  'setlook',
  'setgeneral',
  'setnotif',
  'setconn',
  'setdns',
  'setdata',
];

void main() {
  group('settings model', () {
    test('the ports: 1024..65535, digits only', () {
      expect(parsePort('7890'), 7890);
      expect(parsePort(' 1024 '), 1024);
      expect(parsePort('1023'), isNull);
      expect(parsePort('65536'), isNull);
      expect(parsePort('80a'), isNull);
      expect(parsePort(''), isNull);
    });

    test('Auto numbers: ranges, comma, one decimal for the retry pause', () {
      expect(parseThreshold('0'), 0);
      expect(parseThreshold('1000'), 1000);
      expect(parseThreshold('1001'), isNull);
      expect(parseThreshold('-1'), isNull);
      expect(parseThreshold('1.5'), isNull);
      expect(parseAutoNum('retryPause', '0,5'), 0.5);
      expect(parseAutoNum('retryPause', '0.05'), isNull);
      expect(parseAutoNum('retryPause', '10'), 10);
      expect(parseAutoNum('retryPause', '10.1'), isNull);
      expect(parseAutoNum('flapMax', '60'), 60);
      expect(parseAutoNum('flapMax', '61'), isNull);
      expect(parseAutoNum('flapMax', '2.5'), isNull);
      expect(parseAutoNum('flapReset', '4'), isNull);
    });

    test('periods: whole seconds inside the limits, 0 only where off', () {
      final every = intervals['checkEvery']!;
      expect(parseInterval(every, '30', 1), 30);
      expect(parseInterval(every, '9', 1), isNull);
      expect(parseInterval(every, '2', 60), 120);
      expect(parseInterval(every, '61', 60), isNull);
      expect(parseInterval(every, '0', 1), isNull);
      final subs = intervals['subsEvery']!;
      expect(parseInterval(subs, '0', 3600), 0);
      expect(parseInterval(subs, '12', 3600), 43200);
      expect(parseInterval(subs, '31', 86400), isNull);
      expect(intervalUnitFor(every, 120), 60);
      expect(intervalUnitFor(every, 90), 1);
      expect(intervalUnitFor(subs, 0), 3600);
      expect(intervalUnitFor(subs, 86400), 86400);
    });

    test('proxy login and password rules', () {
      expect(proxyCredProblem(user: true, v: ''), CredProblem.empty);
      expect(proxyCredProblem(user: true, v: 'a b'), CredProblem.spaces);
      expect(proxyCredProblem(user: true, v: 'a:b'), CredProblem.colon);
      expect(proxyCredProblem(user: true, v: 'a' * 65), CredProblem.tooLong);
      expect(proxyCredProblem(user: true, v: 'user'), isNull);
      expect(proxyCredProblem(user: false, v: 'abc'), CredProblem.tooShort);
      expect(proxyCredProblem(user: false, v: 'a:bcd'), isNull);
      expect(proxyCredProblem(user: false, v: 'a' * 129), CredProblem.tooLong);
      expect(newProxyLogin().length, 8);
      expect(proxyCredProblem(user: false, v: newProxySecret()), isNull);
    });

    test('the proxy address a program is told to use', () {
      expect(
        proxyUrl('socks5', port: 7890, user: 'u', pass: 'p@ss'),
        'socks5://u:p%40ss@127.0.0.1:7890',
      );
      expect(proxyUrl('http', port: 7890), 'http://127.0.0.1:7890');
    });

    test('test URLs and DNS addresses', () {
      expect(validTestUrl('https://www.gstatic.com/generate_204'), isTrue);
      expect(validTestUrl('ftp://x.example'), isFalse);
      expect(validTestUrl('https://localhost'), isFalse);
      expect(hostOf('https://cp.cloudflare.com/generate_204'), 'cp.cloudflare.com');
      for (final ok in [
        'system',
        '1.1.1.1',
        '1.1.1.1:5353',
        'https://dns.google/dns-query',
        'tls://1.1.1.1',
        'quic://dns.adguard.com',
        'tcp://8.8.8.8',
      ]) {
        expect(dnsAddrRe.hasMatch(ok), isTrue, reason: ok);
      }
      for (final bad in ['', 'dns.google', 'http://x', 'tls://', '1.1.1']) {
        expect(dnsAddrRe.hasMatch(bad), isFalse, reason: bad);
      }
      expect(dnsKind('https://x/dns-query'), 'doh');
      expect(dnsKind('tls://x'), 'dot');
      expect(dnsKind('quic://x'), 'doq');
      expect(dnsKind('1.1.1.1'), 'udp');
      expect(dnsKind('system'), 'system');
    });

    test('DNS: any server can be switched off, built-ins cannot be deleted', () {
      final c = Catalog();
      expect(c.dnsActive, isNotEmpty);
      for (final s in c.dnsActive.toList()) {
        c.dnsToggle(s.id);
      }
      expect(c.dnsActive, isEmpty);
      expect(c.dnsDelete('cloudflare'), isFalse);
      expect(c.dnsServers.containsKey('cloudflare'), isTrue);
      final id = c.dnsSave(null, name: '', transports: [DnsTransport('dot', 'tls://9.9.9.9')], sides: ['direct']);
      expect(c.dnsServers[id]!.name, '9.9.9.9');
      expect(c.dnsServers[id]!.activeSides, ['direct']);
      expect(c.dnsDelete(id), isTrue);
      expect(c.dnsServers.containsKey(id), isFalse);
    });

    group('dnsSave: transports and use', () {
      List<DnsTransport> tr(List<String> a) => [for (final x in a) DnsTransport(dnsKindOf(x), x)];

      test('a new server uses the kinds of its addresses, sides default to VPN', () {
        final c = Catalog();
        final id = c.dnsSave(null, name: '', transports: tr(['https://9.9.9.9/dns-query', 'tls://9.9.9.9', '9.9.9.9']));
        final s = c.dnsServers[id]!;
        expect(s.transports.map((t) => t.addr), ['https://9.9.9.9/dns-query', 'tls://9.9.9.9', '9.9.9.9']);
        expect(s.use, {'doh', 'dot', 'udp'});
        expect(s.name, '9.9.9.9');
        expect(s.activeSides, {'vpn'});
      });

      test('use is cut to the kinds with an address and never ends empty', () {
        final c = Catalog();
        final id = c.dnsSave(null, name: 'M', transports: tr(['tls://9.9.9.9', '9.9.9.9']), use: {'dot', 'doq'});
        expect(c.dnsServers[id]!.use, {'dot'});
        c.dnsSave(id, name: 'M', use: {'doq'}); // nothing left of it: every kind with an address
        expect(c.dnsServers[id]!.use, {'dot', 'udp'});
        c.dnsSave(id, name: 'M', use: {'udp'});
        expect(c.dnsServers[id]!.use, {'udp'});
      });

      test('null / empty transports and use keep the current ones', () {
        final c = Catalog();
        final id = c.dnsSave(null, name: 'M', transports: tr(['tls://9.9.9.9', '9.9.9.9']), use: {'udp'});
        c.dnsSave(id, name: 'M2', transports: const [], use: <String>{});
        final s = c.dnsServers[id]!;
        expect(s.name, 'M2');
        expect(s.transports.map((t) => t.addr), ['tls://9.9.9.9', '9.9.9.9']);
        expect(s.use, {'udp'});
      });

      test('replacing the addresses drops the kinds that are gone from use', () {
        final c = Catalog();
        final id = c.dnsSave(null, name: 'M', transports: tr(['tls://9.9.9.9', '9.9.9.9']));
        c.dnsSave(id, name: 'M', transports: tr(['https://9.9.9.9/dns-query', '9.9.9.9']), use: {'dot', 'doh'});
        final s = c.dnsServers[id]!;
        expect(s.transports.first.addr, 'https://9.9.9.9/dns-query');
        expect(s.use, {'doh'});
      });

      test('a built-in provider keeps its addresses and takes use; Local takes the name only', () {
        final c = Catalog();
        final n = c.dnsServers['cloudflare']!.transports.length;
        c.dnsSave('cloudflare', name: 'Cloudflare', use: {'doh', 'udp', 'doq'});
        final cf = c.dnsServers['cloudflare']!;
        expect(cf.transports.length, n);
        expect(cf.use, {'doh', 'udp'}); // Cloudflare has no DoQ address
        c.dnsSave('local', name: 'Mine', transports: tr(['9.9.9.9']), use: {'udp'}, sides: ['vpn']);
        final l = c.dnsServers['local']!;
        expect(l.system, isTrue);
        expect(l.name, 'Mine');
        expect(l.activeSides, {'direct'});
      });
    });

    test('what Android hides', () {
      const a = PlatformCaps(android: true);
      expect(a.systemProxy, isFalse);
      expect(a.tunSwitch, isFalse);
      expect(a.killSwitch, isFalse);
      expect(a.dnsResolveForIp, isFalse);
      const w = PlatformCaps(android: false);
      expect(w.systemProxy && w.tunSwitch && w.killSwitch && w.dnsResolveForIp, isTrue);
    });
  });

  group('settings menu', () {
    testWidgets('seven rows, Connection names what is left on Android', (
      tester,
    ) async {
      await _pump(tester, FakeCoreHost());
      for (final id in _rows) {
        expect(find.byKey(ValueKey('settings-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('System proxy, kill switch, TUN'), findsOneWidget);

      await _pump(tester, FakeCoreHost(android: true));
      expect(find.text('System proxy, kill switch, TUN'), findsNothing);
      expect(find.text('Proxy port, TUN stack, test URL'), findsOneWidget);
    });

    testWidgets('every sheet fits 320 dp at the largest text size', (
      tester,
    ) async {
      for (final android in [false, true]) {
        final host = FakeCoreHost(android: android);
        await _pump(tester, host, textScale: 1.2);
        for (final id in _rows) {
          await _open(tester, id);
          expect(
            tester.takeException(),
            isNull,
            reason: '$id (android: $android)',
          );
          await tester.binding.handlePopRoute(); // Back closes the sheet
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('settings-$id')), findsOneWidget);
        }
      }
    });

    testWidgets('the DNS server form fits 320 dp at the largest text size', (
      tester,
    ) async {
      await _pump(tester, FakeCoreHost(), textScale: 1.2);
      await _open(tester, 'setdns');
      await tester.tap(find.text('Add DNS server'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsForm), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Connection: the system proxy and the kill switch are desktop only', (
      tester,
    ) async {
      await _pump(tester, FakeCoreHost());
      await _open(tester, 'setconn');
      expect(find.text('System proxy'), findsOneWidget);
      expect(find.text('Kill switch'), findsOneWidget);

      await _pump(tester, FakeCoreHost(android: true));
      await _open(tester, 'setconn');
      expect(find.text('System proxy'), findsNothing);
      expect(find.text('Kill switch'), findsNothing);
      expect(find.text('Also while the app is closed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DNS: Resolve for IP rules is desktop only', (tester) async {
      await _pump(tester, FakeCoreHost());
      await _open(tester, 'setdns');
      expect(find.text('Switch automatically'), findsOneWidget);
      expect(find.text('Resolve for IP rules'), findsOneWidget);

      await _pump(tester, FakeCoreHost(android: true));
      await _open(tester, 'setdns');
      expect(find.text('Switch automatically'), findsOneWidget);
      expect(find.text('Resolve for IP rules'), findsNothing);
    });

    testWidgets('DNS: a toggle lands in the catalog and is saved', (
      tester,
    ) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setdns');
      final before = host.catalog.dnsCfg.auto;
      final changes = host.changes;
      await tester.tap(_toggleOf('Switch automatically'));
      await tester.pumpAndSettle();
      expect(host.catalog.dnsCfg.auto, !before);
      expect(host.changes, greaterThan(changes));
    });

    group('DNS form', () {
      Finder chipOf(String kind) =>
          find.descendant(of: find.byType(DnsForm), matching: find.widgetWithText(AppChip, kind));
      Finder fields() => find.descendant(of: find.byType(DnsForm), matching: find.byType(TextField));
      Finder removes() => find.descendant(of: find.byType(DnsForm), matching: find.byTooltip('Remove'));
      bool lit(WidgetTester t, String kind) => t.widget<AppChip>(chipOf(kind)).active;

      Future<void> openNew(WidgetTester tester, FakeCoreHost host, {double scale = 1.0}) async {
        await _pump(tester, host, textScale: scale);
        await _open(tester, 'setdns');
        await tester.tap(find.text('Add DNS server'));
        await tester.pumpAndSettle();
      }

      Future<void> openEdit(WidgetTester tester, FakeCoreHost host, String name) async {
        await _pump(tester, host);
        await _open(tester, 'setdns');
        await tester.tap(find.text(name).first);
        await tester.pumpAndSettle();
      }

      Future<void> type(WidgetTester tester, int row, String text) async {
        await tester.enterText(fields().at(row + 1), text); // field 0 is the name
        await tester.pump();
      }

      testWidgets('chips only for kinds with an address; Local has none', (tester) async {
        final host = FakeCoreHost();
        await openEdit(tester, host, 'Cloudflare');
        expect(chipOf('DoH'), findsOneWidget);
        expect(chipOf('DoT'), findsOneWidget);
        expect(chipOf('UDP'), findsOneWidget);
        expect(chipOf('DoQ'), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await tester.tap(find.text('AdGuard (unfiltered)').first);
        await tester.pumpAndSettle();
        expect(chipOf('DoQ'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await tester.tap(find.text('Local').first);
        await tester.pumpAndSettle();
        expect(find.byType(DnsForm), findsOneWidget);
        for (final k in ['DoH', 'DoT', 'DoQ', 'UDP']) {
          expect(chipOf(k), findsNothing, reason: k);
        }
      });

      testWidgets('an own server: chips follow the addresses, the last lit one ignores taps', (tester) async {
        await openNew(tester, FakeCoreHost());
        expect(chipOf('DoH'), findsNothing); // no valid address yet
        await type(tester, 0, 'https://9.9.9.9/dns-query');
        expect(lit(tester, 'DoH'), isTrue);
        await tester.tap(chipOf('DoH'));
        await tester.pump();
        expect(lit(tester, 'DoH'), isTrue); // the only lit one stays

        // a new kind appears and turns on
        await tester.tap(find.text('+ Address'));
        await tester.pump();
        await type(tester, 1, 'tls://9.9.9.9');
        expect(lit(tester, 'DoT'), isTrue);
        expect(lit(tester, 'DoH'), isTrue);
        await tester.tap(chipOf('DoH'));
        await tester.pump();
        expect(lit(tester, 'DoH'), isFalse);
        expect(lit(tester, 'DoT'), isTrue);
        await tester.tap(chipOf('DoT')); // last lit now
        await tester.pump();
        expect(lit(tester, 'DoT'), isTrue);

        // the last address of a kind goes: its chip goes
        await tester.tap(removes().last);
        await tester.pump();
        expect(chipOf('DoT'), findsNothing);
        expect(lit(tester, 'DoH'), isTrue); // something stays on
        expect(removes(), findsNothing); // one row left
      });

      testWidgets('+ Address adds a row, the kind tag shows for a valid address', (tester) async {
        await openNew(tester, FakeCoreHost());
        expect(fields(), findsNWidgets(2)); // name + one address
        expect(removes(), findsNothing);
        expect(find.text('UDP'), findsNothing);
        await tester.tap(find.text('+ Address'));
        await tester.pump();
        expect(fields(), findsNWidgets(3));
        expect(removes(), findsNWidgets(2));
        await type(tester, 1, '9.9.9.9');
        // the tag and the chip both read UDP
        expect(find.text('UDP'), findsNWidgets(2));
        await type(tester, 1, 'nonsense');
        expect(find.text('UDP'), findsNothing);
      });

      testWidgets('save: an invalid address stops it, a duplicate counts once, order and use kept', (tester) async {
        final host = FakeCoreHost();
        await openNew(tester, host);
        final before = host.catalog.dnsServers.length;
        await type(tester, 0, 'bad address');
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.text('Address: https://…, tls://…, quic://…, udp://…, an IP or system'), findsOneWidget);
        expect(find.byType(DnsForm), findsOneWidget);
        expect(host.catalog.dnsServers.length, before);

        await type(tester, 0, 'tls://9.9.9.9');
        await tester.tap(find.text('+ Address'));
        await tester.pump();
        await type(tester, 1, 'https://9.9.9.9/dns-query');
        await tester.tap(find.text('+ Address'));
        await tester.pump();
        await type(tester, 2, 'tls://9.9.9.9');
        await tester.tap(find.text('+ Address'));
        await tester.pump(); // an empty row is skipped
        await tester.enterText(fields().at(1), 'tls://9.9.9.9');
        await tester.pump();
        await tester.tap(chipOf('DoT')); // DoT off, DoH stays
        await tester.pump();
        await tester.enterText(fields().first, 'Mine');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(DnsForm), findsNothing);
        final s = host.catalog.dnsServers.values.firstWhere((s) => s.name == 'Mine');
        expect([for (final t in s.transports) t.addr], ['tls://9.9.9.9', 'https://9.9.9.9/dns-query']);
        expect([for (final t in s.transports) t.kind], ['dot', 'doh']);
        expect(s.use.toSet(), {'doh'});
      });

      testWidgets('an edited built-in keeps its addresses and saves the transports in use', (tester) async {
        final host = FakeCoreHost();
        final c = host.catalog.dnsServers['cloudflare']!;
        final addrs = [for (final t in c.transports) t.addr];
        await openEdit(tester, host, 'Cloudflare');
        final wasUdp = lit(tester, 'UDP');
        await tester.tap(chipOf('UDP'));
        await tester.pump();
        expect(lit(tester, 'UDP'), !wasUdp);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect([for (final t in c.transports) t.addr], addrs);
        expect(c.use.contains('udp'), !wasUdp);
        expect(c.use, isNotEmpty);
      });

      testWidgets('three address rows fit 320 dp at 120 %', (tester) async {
        await openNew(tester, FakeCoreHost(), scale: 1.2);
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.text('+ Address'));
          await tester.pump();
        }
        await type(tester, 0, 'https://unfiltered.adguard-dns.com/dns-query');
        await type(tester, 1, 'quic://unfiltered.adguard-dns.com');
        await type(tester, 2, 'tls://unfiltered.adguard-dns.com');
        expect(tester.takeException(), isNull);
      });
    });

    group('DNS list', () {
      Finder rowOf(String id) => find.byKey(ValueKey(id));
      Finder chip(String id, String side) => find.byKey(ValueKey('dns-$id-$side'));

      /// Only [keep] stays on, the other providers (Local too) are off.
      void only(FakeCoreHost host, String keep) {
        for (final s in host.catalog.dnsServers.values) {
          s.on = s.id == keep;
        }
      }

      Future<void> openDns(WidgetTester tester, FakeCoreHost host) async {
        await _pump(tester, host);
        await _open(tester, 'setdns');
      }

      testWidgets('a side chip toggles the side of the provider', (tester) async {
        final host = FakeCoreHost();
        await openDns(tester, host);
        final g = host.catalog.dnsServers['google']!;
        expect(g.activeSides, containsAll(['direct', 'vpn']));
        final changes = host.changes;
        await tester.tap(chip('google', 'vpn'));
        await tester.pumpAndSettle();
        expect(g.activeSides, {'direct'});
        expect(host.changes, greaterThan(changes));
        await tester.tap(chip('google', 'vpn'));
        await tester.pumpAndSettle();
        expect(g.activeSides, {'direct', 'vpn'});
      });

      testWidgets('dead on every active side -> Unavailable block; on one side -> main list', (
        tester,
      ) async {
        final host = FakeCoreHost();
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'c1', provider: 'cloudflare', side: 'direct', ok: false),
            DnsServerStatus(id: 'c2', provider: 'cloudflare', side: 'vpn', ok: false),
            DnsServerStatus(id: 'g1', provider: 'google', side: 'direct', ok: false),
            DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: true),
          ],
        );
        await openDns(tester, host);
        expect(find.byKey(const ValueKey('dns-dead')), findsOneWidget);
        expect(find.text('Unavailable · 1'), findsOneWidget);
        expect(rowOf('cloudflare'), findsNothing); // the block is folded
        expect(rowOf('google'), findsOneWidget);

        // cloudflare restricted to the dead-direct side only is dead there too
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'g1', provider: 'google', side: 'direct', ok: false),
            DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: true),
          ],
        );
        host.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('dns-dead')), findsNothing);
        expect(rowOf('cloudflare'), findsOneWidget);
        expect(rowOf('google'), findsOneWidget);

        // an unfolded block shows its rows
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'c1', provider: 'cloudflare', side: 'direct', ok: false),
            DnsServerStatus(id: 'c2', provider: 'cloudflare', side: 'vpn', ok: false),
          ],
        );
        host.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Unavailable · 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(rowOf('cloudflare'), findsOneWidget);
      });

      testWidgets('no ring beside the chip while rechecking; the verdict stays', (
        tester,
      ) async {
        final host = FakeCoreHost();
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: true),
          ],
        );
        await openDns(tester, host);
        const ring = ValueKey('dns-rechecking-google-vpn');
        expect(find.byKey(ring), findsNothing);
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(
              id: 'g2',
              provider: 'google',
              side: 'vpn',
              ok: true,
              rechecking: true,
            ),
          ],
        );
        host.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(ring), findsNothing);
        expect(chip('google', 'vpn'), findsOneWidget);
        expect(find.byKey(const ValueKey('dns-rechecking-google-direct')), findsNothing);

        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: true),
          ],
        );
        host.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(ring), findsNothing);
        expect(chip('google', 'vpn'), findsOneWidget);
      });

      testWidgets('dead on the exit node in use only -> "Dead on this node" under the address', (
        tester,
      ) async {
        final host = FakeCoreHost();
        host.dnsHealthValue = const DnsHealth(
          servers: [
            DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: false, deadOnNode: true),
            DnsServerStatus(id: 'g1', provider: 'google', side: 'direct', ok: true),
          ],
        );
        await openDns(tester, host);
        expect(find.byKey(const ValueKey('dns-dead-on-node-google')), findsOneWidget);
        expect(find.text('Dead on this node'), findsOneWidget);

        // dead everywhere (no deadOn): no such line
        host.dnsHealthValue = const DnsHealth(
          servers: [DnsServerStatus(id: 'g2', provider: 'google', side: 'vpn', ok: false)],
        );
        host.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('dns-dead-on-node-google')), findsNothing);
      });

      testWidgets('switching off the last provider of a side asks first (checkbox)', (
        tester,
      ) async {
        final host = FakeCoreHost();
        only(host, 'google');
        await openDns(tester, host);
        final g = host.catalog.dnsServers['google']!;
        final box = find.descendant(of: rowOf('google'), matching: find.byType(SubCheckbox));

        await tester.tap(box);
        await tester.pumpAndSettle();
        expect(find.text('Switch off'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(g.on, isTrue);
        expect(find.text('Switch off'), findsNothing);

        await tester.tap(box);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Switch off'));
        await tester.pumpAndSettle();
        expect(g.on, isFalse);
      });

      testWidgets('switching off the last provider of a side asks first (side chip)', (
        tester,
      ) async {
        final host = FakeCoreHost();
        only(host, 'google');
        await openDns(tester, host);
        final g = host.catalog.dnsServers['google']!;

        await tester.tap(chip('google', 'vpn'));
        await tester.pumpAndSettle();
        expect(find.text('Switch off'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(g.activeSides, containsAll(['direct', 'vpn']));

        await tester.tap(chip('google', 'vpn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Switch off'));
        await tester.pumpAndSettle();
        expect(g.activeSides, {'direct'});

        // another provider covers the side: no dialog; the last side of a provider stays
        host.catalog.dnsServers['cloudflare']!.on = true;
        host.changed();
        await tester.pumpAndSettle();
        await tester.tap(chip('google', 'direct'));
        await tester.pumpAndSettle();
        expect(find.text('Switch off'), findsNothing);
        expect(g.activeSides, {'vpn'}); // the last side flips to the other one
      });

      testWidgets('the last lit side chip of a provider flips it to the other side', (tester) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(null, name: 'Mine', transports: [DnsTransport('dot', 'tls://9.9.9.9')], sides: ['direct']);
        await openDns(tester, host);
        await tester.tap(chip(id, 'direct'));
        await tester.pumpAndSettle();
        expect(host.catalog.dnsServers[id]!.activeSides, {'vpn'});
        host.catalog.dnsSave(id, name: 'Mine', sides: const []);
        expect(host.catalog.dnsServers[id]!.activeSides, {'vpn'});
      });

      testWidgets('the form flips the last side instead of emptying it', (tester) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(null, name: 'Mine', transports: [DnsTransport('dot', 'tls://9.9.9.9')], sides: ['direct']);
        await openDns(tester, host);
        await tester.tap(find.descendant(of: rowOf(id), matching: find.text('Mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byType(DnsForm), matching: find.text('Direct')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(host.catalog.dnsServers[id]!.activeSides, {'vpn'});
      });

      DnsRace race(String id, String side, {String? win, int? winMs, required List<DnsRaceTransport> ts}) =>
          DnsRace(provider: id, side: side, winnerKind: win, winnerMs: winMs, transports: ts);

      testWidgets('the row names the protocol that answers each side, at 320 / 120 %', (tester) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(
          null,
          name: 'Mine',
          transports: [DnsTransport('dot', 'tls://9.9.9.9'), DnsTransport('udp', '9.9.9.9')],
          sides: ['direct', 'vpn'],
        );
        host.raceReplies[id] = [
          [
            race(id, 'direct', win: 'dot', winMs: 24, ts: const [DnsRaceTransport(kind: 'dot', ms: 24, state: 'ok')]),
            race(id, 'vpn', win: 'udp', winMs: 30, ts: const [DnsRaceTransport(kind: 'udp', ms: 30, state: 'ok')]),
          ],
        ];
        await _pump(tester, host, textScale: 1.2);
        await _open(tester, 'setdns');
        expect(find.byKey(ValueKey('dns-race-$id-direct')), findsOneWidget);
        expect((tester.widget(find.byKey(ValueKey('dns-race-$id-direct'))) as Text).data, 'DoT');
        expect((tester.widget(find.byKey(ValueKey('dns-race-$id-vpn'))) as Text).data, 'UDP');
        expect(find.descendant(of: find.byKey(ValueKey('dns-ping-$id-direct')), matching: find.text('24 ms')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the card spins per transport and side until the core answers, then shows the result', (
        tester,
      ) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(
          null,
          name: 'Mine',
          transports: [DnsTransport('doh', 'https://9.9.9.9/dns-query'), DnsTransport('udp', '9.9.9.9')],
          sides: ['vpn'],
        );
        DnsRace at(List<DnsRaceTransport> ts, {String? win}) => race(id, 'vpn', win: win, ts: ts);
        const testingRace = [
          DnsRaceTransport(kind: 'doh', state: 'testing'),
          DnsRaceTransport(kind: 'udp', ms: 12, state: 'ok', reserve: true),
        ];
        host.raceReplies[id] = [
          [at(testingRace)], // the list's own ping on opening
          [at(testingRace)],
          [
            at(const [
              DnsRaceTransport(kind: 'doh', ms: 31, state: 'ok'),
              DnsRaceTransport(kind: 'udp', ms: 12, state: 'ok', reserve: true),
            ], win: 'doh'),
          ],
        ];
        await _pump(tester, host);
        await _open(tester, 'setdns');
        await tester.tap(find.descendant(of: find.byKey(ValueKey(id)), matching: find.text('Mine')));
        await tester.pump();
        await tester.pump();
        final doh = find.byKey(ValueKey('dns-race-vpn-doh'));
        expect(doh, findsOneWidget);
        expect(find.descendant(of: doh, matching: find.byType(PingSpinner)), findsOneWidget);
        expect(find.descendant(of: find.byKey(ValueKey('dns-race-vpn-udp')), matching: find.text('Reserve')), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.descendant(of: doh, matching: find.byType(PingSpinner)), findsNothing);
        expect(find.descendant(of: doh, matching: find.text('31 ms')), findsOneWidget);
        expect(find.descendant(of: doh, matching: find.text('In use')), findsOneWidget);
      });

      testWidgets('a check that stays testing past the cap ends as "No answer"', (tester) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(
          null,
          name: 'Mine',
          transports: [DnsTransport('doh', 'https://9.9.9.9/dns-query')],
          sides: ['vpn'],
        );
        host.raceReplies[id] = [
          [race(id, 'vpn', ts: const [DnsRaceTransport(kind: 'doh', state: 'testing')])],
        ];
        await _pump(tester, host);
        await _open(tester, 'setdns');
        await tester.tap(find.descendant(of: find.byKey(ValueKey(id)), matching: find.text('Mine')));
        await tester.pump();
        for (var i = 0; i < 32; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        final doh = find.byKey(ValueKey('dns-race-vpn-doh'));
        expect(find.descendant(of: doh, matching: find.byType(PingSpinner)), findsNothing);
        expect(find.descendant(of: doh, matching: find.text('No answer')), findsOneWidget);
      });

      testWidgets('the confirm text says which side is left empty', (tester) async {
        const direct = 'DNS for direct traffic will go through the VPN servers.';
        const vpn =
            'DNS for traffic through the VPN will bypass the tunnel: your ISP will see which sites you open.';
        const both =
            'DNS will go through the system resolver only. For traffic through the VPN that bypasses the tunnel: your ISP will see which sites you open.';

        // both sides: the only provider
        final h1 = FakeCoreHost();
        only(h1, 'google');
        await openDns(tester, h1);
        await tester.tap(
          find.descendant(of: rowOf('google'), matching: find.byType(SubCheckbox)),
        );
        await tester.pumpAndSettle();
        expect(find.text(both), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // vpn only: the chip of the sole vpn provider
        await tester.tap(chip('google', 'vpn'));
        await tester.pumpAndSettle();
        expect(find.text(vpn), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // direct only: cloudflare covers vpn alone, google is the sole direct one
        final h2 = FakeCoreHost();
        only(h2, 'google');
        final cf = h2.catalog.dnsServers['cloudflare']!;
        cf.on = true;
        cf.sides = {'vpn'};
        await openDns(tester, h2);
        await tester.tap(chip('google', 'direct'));
        await tester.pumpAndSettle();
        expect(find.text(direct), findsOneWidget);
        expect(find.text(both), findsNothing);
      });

      testWidgets('Local is first under localFirst, last under priority, no drag handle', (
        tester,
      ) async {
        final first = FakeCoreHost();
        await openDns(tester, first);
        expect(first.catalog.dnsCfg.directPolicy, 'localFirst');
        expect(
          tester.getTopLeft(rowOf('local')).dy,
          lessThan(tester.getTopLeft(rowOf('cloudflare')).dy),
        );
        expect(
          find.descendant(of: rowOf('local'), matching: find.byType(GripHandle)),
          findsNothing,
        );
        expect(
          find.descendant(of: rowOf('cloudflare'), matching: find.byType(GripHandle)),
          findsOneWidget,
        );

        final last = FakeCoreHost();
        last.catalog.dnsSetDirectPolicy('priority');
        await openDns(tester, last);
        expect(
          tester.getTopLeft(rowOf('local')).dy,
          greaterThan(tester.getTopLeft(rowOf('adguard')).dy),
        );
        expect(
          find.descendant(of: rowOf('local'), matching: find.byType(GripHandle)),
          findsNothing,
        );
      });

      testWidgets('a built-in provider has no Delete button, an own server has', (
        tester,
      ) async {
        final host = FakeCoreHost();
        final id = host.catalog.dnsSave(null, name: 'Mine', transports: [DnsTransport('dot', 'tls://9.9.9.9')], sides: ['direct']);
        await openDns(tester, host);

        await tester.tap(
          find.descendant(of: rowOf('cloudflare'), matching: find.text('Cloudflare')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DnsForm), findsOneWidget);
        expect(find.text('Delete server'), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: rowOf(id), matching: find.text('Mine')));
        await tester.pumpAndSettle();
        expect(find.byType(DnsForm), findsOneWidget);
        expect(find.text('Delete server'), findsOneWidget);
      });

      testWidgets('the direct policy row is disabled while Local is off', (tester) async {
        bool dim() => tester
            .widget<DimWhen>(
              find.ancestor(
                of: find.text('Local for direct traffic'),
                matching: find.byType(DimWhen),
              ),
            )
            .dim;

        final on = FakeCoreHost();
        await openDns(tester, on);
        expect(dim(), isFalse);

        final off = FakeCoreHost();
        off.catalog.dnsServers['local']!.on = false;
        await openDns(tester, off);
        expect(dim(), isTrue);
        final policy = off.catalog.dnsCfg.directPolicy;
        await tester.tap(find.text('First'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(off.catalog.dnsCfg.directPolicy, policy);
        expect(find.text('Last'), findsNothing); // no dropdown opened
      });

      testWidgets('an answering chip animates without breaking the sheet', (tester) async {
        final host = FakeCoreHost();
        host.dnsHealthValue = const DnsHealth(answering: {'vpn': 'cloudflare'});
        await _pump(tester, host);
        await tester.tap(find.byKey(const ValueKey('settings-setdns')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(seconds: 1));
        expect(chip('cloudflare', 'vpn'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('Connection: IPv6 is off by default, the toggle lands in the catalog and is saved (both platforms)', (
      tester,
    ) async {
      for (final android in [false, true]) {
        final host = FakeCoreHost(android: android);
        await _pump(tester, host);
        await _open(tester, 'setconn');
        expect(host.catalog.connCfg.ipv6, isFalse);
        final t = _toggleOf('IPv6');
        await tester.ensureVisible(t);
        await tester.pumpAndSettle();
        final changes = host.changes;
        await tester.tap(t);
        await tester.pumpAndSettle();
        expect(host.catalog.connCfg.ipv6, isTrue, reason: 'android: $android');
        expect(host.changes, greaterThan(changes));
        await tester.tap(t);
        await tester.pumpAndSettle();
        expect(host.catalog.connCfg.ipv6, isFalse);
      }
    });

    testWidgets('Connection: Close connections on route switch is on by default, the toggle lands in the catalog, is saved and survives the snapshot', (
      tester,
    ) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setconn');
      expect(host.catalog.connCfg.closeOnSwitch, isTrue);
      final t = _toggleOf('Close connections on route switch');
      await tester.ensureVisible(t);
      await tester.pumpAndSettle();
      final changes = host.changes;
      await tester.tap(t);
      await tester.pumpAndSettle();
      expect(host.catalog.connCfg.closeOnSwitch, isFalse);
      expect(host.changes, greaterThan(changes));
      expect(ConnCfg.fromJson(host.catalog.connCfg.toJson()).closeOnSwitch, isFalse);
      await tester.tap(t);
      await tester.pumpAndSettle();
      expect(host.catalog.connCfg.closeOnSwitch, isTrue);
    });

    testWidgets('General and Notifications: switches persist in the state', (
      tester,
    ) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setgeneral');
      final was = host.gen.connectOnLaunch;
      await tester.tap(_toggleOf('Connect on launch'));
      await tester.pumpAndSettle();
      expect(host.gen.connectOnLaunch, !was);
      // the state a backup carries holds it
      expect(
        (host.exportState()['genCfg'] as Map)['connectOnLaunch'],
        !was,
      );
    });

    testWidgets('Appearance: a theme row switches the theme', (tester) async {
      final host = FakeCoreHost();
      final settings = await _pump(tester, host);
      await _open(tester, 'setlook');
      await tester.tap(find.text(AppThemeId.github.label));
      await tester.pumpAndSettle();
      expect(settings.theme, AppThemeId.github);
    });
  });

  group('Data', () {
    late FakeBackupIo io;
    setUp(() {
      io = FakeBackupIo(folder: null);
      BackupIo.current = io;
    });

    testWidgets('About: «Build» is build number · short commit, sing-box comes from the core\'s version', (tester) async {
      final host = FakeCoreHost()..versionInfo = const {'singBox': '1.12.0'};
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(find.text('Build'), findsOneWidget);
      expect(find.text('7 · abc1234'), findsOneWidget);
      expect(find.text('1.12.0'), findsOneWidget);
      expect(find.text('Core'), findsNothing);
    });

    testWidgets('About: no commit given -> only the build number', (tester) async {
      final host = FakeCoreHost()..commit = '';
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('restore asks first, then imports', (tester) async {
      final host = FakeCoreHost();
      io.file = PickedFile(
        'b.json',
        jsonEncode({
          'app': 'jormungand',
          'backup': 1,
          'snapshot': host.exportState(),
        }),
      );
      await _pump(tester, host);
      await _open(tester, 'setdata');
      await tester.tap(find.text('Restore from file'));
      await tester.pumpAndSettle();
      expect(find.text('Restore backup?'), findsOneWidget);
      expect(host.calls, isNot(contains('importState')));
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(host.calls, contains('importState'));
    });

    testWidgets('restore: a file that is not a backup changes nothing', (
      tester,
    ) async {
      final host = FakeCoreHost();
      io.file = const PickedFile('x.json', '{"hello": 1}');
      await _pump(tester, host);
      await _open(tester, 'setdata');
      await tester.tap(find.text('Restore from file'));
      await tester.pumpAndSettle();
      expect(find.text('Restore backup?'), findsNothing);
      expect(host.calls, isNot(contains('importState')));
    });

    testWidgets('restore: closing the file dialog does nothing', (
      tester,
    ) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setdata');
      await tester.tap(find.text('Restore from file'));
      await tester.pumpAndSettle();
      expect(find.text('Restore backup?'), findsNothing);
      expect(host.calls, isNot(contains('importState')));
    });

    testWidgets('export writes the whole state', (tester) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setdata');
      await tester.tap(find.text('Export backup'));
      await tester.pumpAndSettle();
      final j = jsonDecode(io.text!) as Map;
      expect(j['app'], 'jormungand');
      expect((j['snapshot'] as Map).containsKey('sourcesData'), isTrue);
    });

    testWidgets('updates: check, offer, download, ready', (tester) async {
      final host = FakeCoreHost();
      host.update = const AppUpdate(phase: UpdPhase.idle, current: '0.1.0');
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(find.text('Not checked yet'), findsOneWidget);
      await tester.tap(find.text('Check now'));
      await tester.pump();
      expect(host.calls, contains('checkUpdate'));

      host.update = const AppUpdate(
        phase: UpdPhase.available,
        current: '0.1.0',
        offer: UpdOffer(
          version: '0.2.0',
          channel: 'stable',
          size: 40 * 1024 * 1024,
          notes: {'en': 'Faster Auto'},
        ),
      );
      host.changed();
      await tester.pumpAndSettle();
      expect(find.text('Update 0.2.0 available'), findsOneWidget);
      expect(find.text('Faster Auto'), findsOneWidget);
      await tester.tap(find.text('Download & install'));
      await tester.pump();
      expect(host.calls, contains('downloadUpdate'));

      host.update = const AppUpdate(
        phase: UpdPhase.ready,
        current: '0.1.0',
        file: r'C:\u\jormungand-0.2.0.zip',
        offer: UpdOffer(
          version: '0.2.0',
          channel: 'stable',
          size: 1024,
          notes: {},
        ),
      );
      host.changed();
      await tester.pumpAndSettle();
      // no installer here (desktop): the path is shown, there is no Install button
      expect(find.text('Install'), findsNothing);
      expect(find.text(r'C:\u\jormungand-0.2.0.zip'), findsOneWidget);
      host.installable = true;
      host.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(host.calls, contains('installUpdate'));
    });

    testWidgets('updates: an offer with a delta shows the patch size, not the installer\'s', (tester) async {
      final host = FakeCoreHost();
      host.update = const AppUpdate(
        phase: UpdPhase.available,
        current: '0.1.0',
        offer: UpdOffer(
          version: '0.2.0',
          channel: 'stable',
          size: 100 * 1000 * 1000,
          deltaSize: 5 * 1024 * 1024,
          notes: {},
        ),
      );
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(find.text(fmtBytes(5 * 1024 * 1024)), findsOneWidget);
      expect(find.text(fmtBytes(100 * 1000 * 1000)), findsNothing);
      // the JSON the core sends
      final o = UpdOffer.fromJson({'version': '0.2.0', 'size': 100, 'delta': true, 'deltaSize': 7, 'notes': {}});
      expect([o.size, o.deltaSize, o.downloadSize], [100, 7, 7]);
      expect(UpdOffer.fromJson({'version': '0.2.0', 'size': 100, 'notes': {}}).downloadSize, 100);
    });

    testWidgets('updates: Install shows a status until the install returns; a refusal brings the button back', (tester) async {
      final host = FakeCoreHost();
      host.installable = true;
      host.update = const AppUpdate(
        phase: UpdPhase.ready,
        current: '0.1.0',
        file: r'C:\u\jormungand-0.2.0.apk',
        offer: UpdOffer(version: '0.2.0', channel: 'stable', size: 1024, notes: {}),
      );
      final gate = host.installGate = Completer<bool>();
      await _pump(tester, host);
      await _open(tester, 'setdata');
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(host.calls, contains('installUpdate'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Installing… the app will close and restart'), findsOneWidget);
      // a second tap does nothing while it runs
      await tester.tap(find.text('Install'));
      await tester.pump();
      expect(host.calls.where((c) => c == 'installUpdate'), hasLength(1));

      gate.complete(false);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Installing… the app will close and restart'), findsNothing);
      expect(find.text('Install'), findsOneWidget);
    });

    testWidgets('updates: a build without an updater says so', (tester) async {
      final host = FakeCoreHost();
      host.update = const AppUpdate(phase: UpdPhase.unavailable);
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(
        find.text('Update checks are not available in this build yet'),
        findsOneWidget,
      );
      await tester.tap(find.text('Check now'));
      await tester.pump();
      expect(host.calls, isNot(contains('checkUpdate')));
    });

    testWidgets('updates: Auto-download is Off / Wi-Fi only / Always on Android, Off / Always on the desktop, and needs Auto-check', (tester) async {
      final host = FakeCoreHost(android: true);
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(host.gen.updAutoDownload, 'wifi'); // the default
      expect(find.text('Wi-Fi only'), findsOneWidget);
      await tester.tap(find.text('Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Always'), findsOneWidget);
      await tester.tap(find.text('Always'));
      await tester.pumpAndSettle();
      expect(host.gen.updAutoDownload, 'always');

      // Auto-check off: the choice is dimmed and does nothing
      host.gen.updates = false;
      host.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Always'));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('updates: on the desktop Auto-download has no Wi-Fi only', (tester) async {
      final host = FakeCoreHost();
      await _pump(tester, host);
      await _open(tester, 'setdata');
      expect(find.text('Wi-Fi only'), findsNothing);
      expect(find.text('Always'), findsOneWidget); // the stored default `wifi` reads as Always
      await tester.tap(find.text('Always'));
      await tester.pumpAndSettle();
      expect(find.text('Wi-Fi only'), findsNothing);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(host.gen.updAutoDownload, 'off');
    });
  });

  group('Home', () {
    testWidgets('NavCards: real values, no demo ones', (tester) async {
      final host = FakeCoreHost();
      await _pump(tester, host, page: const HomePage());
      expect(find.text('Auto mode'), findsOneWidget);
      expect(find.text('DNS'), findsOneWidget);
      expect(find.text('Speed Test'), findsOneWidget);
      expect(find.text('No test yet'), findsOneWidget);
      expect(find.textContaining('312'), findsNothing);
      // Rules is the shell's to open: not offered until it is wired
      expect(find.byKey(const ValueKey('nav-rules')), findsNothing);

      host.speed = SpeedResult(
        downMbps: 87.4,
        upMbps: 22.1,
        latencyMs: 34,
        rpm: 900,
        at: DateTime.now(),
      );
      host.changed();
      await tester.pump();
      expect(find.textContaining('↓ 87.4 · ↑ 22.1 Mbps'), findsOneWidget);
      expect(find.textContaining('34 ms'), findsOneWidget);
    });

    testWidgets('Speed Test card: disabled while disconnected, a tap says so', (
      tester,
    ) async {
      final host = FakeCoreHost();
      await _pump(tester, host, page: const HomePage());
      await tester.tap(find.byKey(const ValueKey('nav-speed')));
      await tester.pump();
      expect(find.text('Connect first'), findsOneWidget);
      expect(host.speedRunning, isFalse);
      expect(host.calls, isNot(contains('speedTest start')));
    });

    testWidgets(
      'Speed Test card: a tap runs the test, progress on the card, a second tap stops it',
      (tester) async {
        final host = FakeCoreHost()..setPhase(ConnectionPhase.connected);
        await _pump(tester, host, page: const HomePage());
        await tester.tap(find.byKey(const ValueKey('nav-speed')));
        await tester.pump();
        expect(host.calls, contains('speedTest start'));
        expect(host.speedRunning, isTrue);
        expect(find.text('Measuring latency…'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('nav-speed-progress')),
          findsOneWidget,
        );

        host.speedStep = const {
          'phase': 1,
          'down': 45000000,
          'up': 12000000,
          'elapsed': 8000,
        };
        host.changed();
        await tester.pump();
        expect(find.text('Speed test: ↓ 45.0 · ↑ 12.0 Mbps'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('nav-speed')));
        await tester.pump();
        expect(host.calls.last, 'speedTest stop');
        expect(host.speedRunning, isFalse);
        expect(find.byKey(const ValueKey('nav-speed-progress')), findsNothing);
        expect(find.text('No test yet'), findsOneWidget);
      },
    );

    testWidgets('Speed Test card: a failed test says so', (tester) async {
      final host = FakeCoreHost()..setPhase(ConnectionPhase.connected);
      host.speedFailed = 'connection reset';
      await _pump(tester, host, page: const HomePage());
      expect(find.text('Test failed'), findsOneWidget);
    });

    testWidgets('NavCards: Auto mode and DNS open their sheets, Rules the link', (
      tester,
    ) async {
      var opened = 0;
      final host = FakeCoreHost();
      await _pump(
        tester,
        host,
        page: const HomePage(),
        links: AppLinks(openRules: ([_]) => opened++),
      );
      await tester.tap(find.byKey(const ValueKey('nav-rules')));
      await tester.pump();
      expect(opened, 1);
      await tester.tap(find.byKey(const ValueKey('nav-dns')));
      await tester.pumpAndSettle();
      expect(find.text('Switch automatically'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-auto')));
      await tester.pumpAndSettle();
      expect(find.text('Auto mode'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android: Global | Rules is one row, side by side', (
      tester,
    ) async {
      await _pump(tester, FakeCoreHost(android: true), page: const HomePage());
      final g = tester.getCenter(find.text('Global'));
      final r = tester.getCenter(find.text('Rules').first);
      expect(g.dy, closeTo(r.dy, 1));
      expect(r.dx, greaterThan(g.dx));
    });
  });
}
