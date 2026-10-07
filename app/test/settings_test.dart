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
import 'package:jormungand/widgets/settings_dns.dart' show DnsForm;
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand_core/jormungand_core.dart';

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

class _FakeBackupIo implements BackupIo {
  PickedFile? file;
  String? saved;

  @override
  Future<String?> save(String name, String text) async {
    saved = text;
    return name;
  }

  @override
  Future<PickedFile?> pick() async => file;
}

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

    test('DNS: at least one server stays on', () {
      final c = Catalog();
      final on = c.dnsActive;
      expect(on, isNotEmpty);
      while (c.dnsActive.length > 1) {
        expect(c.dnsToggle(c.dnsActive.last.id), isTrue);
      }
      final last = c.dnsActive.single;
      expect(c.dnsToggle(last.id), isFalse);
      expect(c.dnsDelete(last.id), isFalse);
      expect(c.dnsActive.single.id, last.id);
      final id = c.dnsSave(null, name: '', addr: 'tls://9.9.9.9', via: 'direct');
      expect(c.dnsServers[id]!.name, '9.9.9.9');
      expect(c.dnsDelete(id), isTrue);
      expect(c.dnsServers.containsKey(id), isFalse);
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
    late _FakeBackupIo io;
    setUp(() {
      io = _FakeBackupIo();
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
      final j = jsonDecode(io.saved!) as Map;
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
