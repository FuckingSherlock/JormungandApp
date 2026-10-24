// Event rows wired to the cards (docs/logs.md «DNS-события: состав и карточки», docs/connect-model.md «Новый вид
// карточки», «Карточка сайта»): EventRow draws an EventCard for dns/switched, dns/down, dns/transport, dns/up,
// site/unreachable and site/blocked; an old-format DNS event keeps the old view; net/switched shows the DNS block of
// data.dns and nothing without it; the card's actions go where the spec says: Details ▾ opens the event, DNS settings
// goes to Settings → DNS, Network event opens the event that caused it, Ignore site ▾ ignores the host, Create rule
// keeps its Fallback (the entry or node that opened the site), a Checked node row retries through the core and the
// checker row asks the checker.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/shell/app_links.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/event_card.dart';
import 'package:jormungand/widgets/event_rows.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

final _en = lookupAppLocalizations(const Locale('en'));

/// The time of the n-th second of the test journal (a minute ago, so all of it is inside one window).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 60000 + s * 1000;

void _catalog(FakeCoreHost host) {
  host.catalog.addSource(
    Source(
      id: 'sub1',
      kind: 'sub',
      name: 'Alpha',
      url: 'https://sub.example/list',
      nodes: [
        CatalogNode(id: 'n1', name: 'One', protocol: 'vless', address: 'one.example.com'),
        CatalogNode(id: 'n2', name: 'Two', protocol: 'hysteria2', address: 'two.example.com'),
      ],
    ),
  );
}

// ---- events in the new format (docs/logs.md «DNS-события», `data` of each type) ----

Map<String, dynamic> _dnsSwitched() => {
  'reason': 'failed',
  'sides': [
    {
      'side': 'vpn',
      'from': {'provider': 'p-ag', 'name': 'AdGuard', 'silent': ['udp'], 'since': _at(0)},
      'to': {'provider': 'p-cf', 'name': 'Cloudflare', 'kind': 'doh', 'ms': 40},
    },
  ],
  'same': false,
  'cause': {'kind': 'itself', 'a': 'AdGuard', 'b': 'Cloudflare'},
};

Map<String, dynamic> _dnsDown({Map<String, dynamic>? cause}) => {
  'sides': [
    {
      'side': 'vpn',
      'servers': [
        {'provider': 'p-ag', 'name': 'AdGuard', 'kinds': ['udp']},
      ],
      'selected': 'p-ag',
    },
  ],
  'noSpare': true,
  'cause': cause ?? {'kind': 'none'},
};

Map<String, dynamic> _dnsTransport() => {
  'sides': [
    {'side': 'vpn', 'provider': 'p-ag', 'name': 'AdGuard', 'from': ['udp'], 'to': 'doh', 'ms': 30},
  ],
  'same': false,
  'cause': {'kind': 'transport', 'a': 'udp', 'b': 'doh'},
};

Map<String, dynamic> _dnsUp() => {
  'afterMs': 4000,
  'sides': [
    {'side': 'vpn', 'provider': 'p-ag', 'name': 'AdGuard', 'kind': 'doh'},
  ],
};

/// A site/blocked event: the entry opened through another server (viaServer) and failed through `server`.
Map<String, dynamic> _blocked({Map<String, dynamic>? extra}) => {
  'host': 'blocked.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'dest': 'blocked.example:443',
  'via': 'sub1',
  'viaServer': 'sub1::n2',
  'rule': {'kind': 'final'},
  ...?extra,
};

/// A site/unreachable event: the work route failed; the one other route tried is `sub1::n2` (a Checked row).
Map<String, dynamic> _unreachable({Map<String, dynamic>? extra}) => {
  'host': 'dead.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'tried': [
    {'entry': 'main', 'server': 'sub1::n2'},
  ],
  ...?extra,
};

String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    EventWords(_en, host.catalog).describe(EventRecord.fromJson(e)).title;

/// Records what the card's buttons ask of the shell, one string per call.
class _Calls {
  final list = <String>[];

  AppLinks links() => AppLinks(
    openDns: () => list.add('dns'),
    openLogsEvent: (id) => list.add('event:$id'),
    newRuleFor: ({host, app, via}) => list.add('newRule:${host ?? '-'}|${app ?? '-'}|${via ?? '-'}'),
    openRoute: ({bool edit = false, String? node}) => list.add('route:${node ?? '-'}'),
    openRuleForm: (id) => list.add('ruleForm:$id'),
  );
}

/// Shows the row of the event [id] alone (the group of the whole journal, as the Events page shows it).
Future<LogsController> _pump(WidgetTester tester, FakeCoreHost host, int id, {AppLinks links = const AppLinks()}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 2400);
  addTearDown(tester.view.reset);
  final logs = LogsController(host)..l10n = _en;
  logs.start();
  final words = EventWords(_en, host.catalog);
  await tester.pumpWidget(
    _EndWith(
      key: UniqueKey(), // a second row in the same test replaces the first one (and its controller)
      logs: logs,
      child: AppSettingsScope(
        settings: AppSettings(textScale: 1.0, locale: const Locale('en')),
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
              home: Scaffold(
                body: ListView(
                  children: [
                    AnimatedBuilder(
                      animation: logs,
                      builder: (_, _) {
                        final groups = foldEvents([for (final e in host.journal) EventRecord.fromJson(e)]);
                        final group = groups.firstWhere((g) => g.ev.id == id);
                        return EventRow(group: group, logs: logs, words: words, first: true);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  return logs;
}

/// Disposes [logs] (its timers) when the widget tree of the test goes.
class _EndWith extends StatefulWidget {
  const _EndWith({super.key, required this.logs, required this.child});

  final LogsController logs;
  final Widget child;

  @override
  State<_EndWith> createState() => _EndWithState();
}

class _EndWithState extends State<_EndWith> {
  @override
  void dispose() {
    widget.logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Opens the row by a tap on its title, as on the page. Plain pumps: a marquee never settles.
Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pump(const Duration(milliseconds: 500));
}

/// Opens a site card by a tap on its header, which names the host (the header words are the card's own).
Future<void> _openSite(WidgetTester tester, Map<String, dynamic> e) async {
  final host = (e['data'] as Map)['host'] as String;
  await tester.tap(find.textContaining(host).first);
  await tester.pump(const Duration(milliseconds: 500));
}

/// A heading of the opened row, whatever its letter case.
Finder _heading(String text) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').toLowerCase() == text.toLowerCase(),
  description: 'heading "$text"',
);

void main() {
  group('EventRow draws the card for the new formats', () {
    final cases = <(String, String, String, Map<String, dynamic>)>[
      ('dns', 'switched', 'warn', _dnsSwitched()),
      ('dns', 'down', 'error', _dnsDown()),
      ('dns', 'transport', 'info', _dnsTransport()),
      ('dns', 'up', 'info', _dnsUp()),
      ('site', 'unreachable', 'warn', _unreachable()),
      ('site', 'blocked', 'warn', _blocked()),
    ];
    for (final (cat, type, level, data) in cases) {
      testWidgets('$cat/$type with its new fields: an EventCard, no old view', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        final e = host.addEvent(cat, type, level: level, at: _at(0), data: data);
        await _pump(tester, host, e['id'] as int);
        expect(find.byType(EventCard), findsOneWidget);
      });
    }

    testWidgets('an old-format dns/switched (side, from, to as strings) and an old dns/failed keep the old view', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final oldSwitch = host.addEvent('dns', 'switched', level: 'warn', at: _at(0), data: const {
        'side': 'vpn',
        'from': 'p-ag',
        'to': 'p-cf',
        'fromProvider': 'p-ag',
        'toProvider': 'p-cf',
      });
      await _pump(tester, host, oldSwitch['id'] as int);
      expect(find.byType(EventCard), findsNothing);
      expect(find.text(_titleOf(host, oldSwitch)), findsWidgets, reason: 'the old row still shows its title');

      final oldFailed = host.addEvent('dns', 'failed', level: 'warn', at: _at(10), data: const {'server': 'Cloudflare', 'side': 'vpn'});
      await _pump(tester, host, oldFailed['id'] as int);
      expect(find.byType(EventCard), findsNothing);
      expect(find.text(_titleOf(host, oldFailed)), findsWidgets, reason: 'an old record is read, not dropped');
    });
  });

  group('net/switched with data.dns', () {
    for (final withDns in [true, false]) {
      testWidgets(withDns ? 'the DNS block is in its details' : 'without data.dns there is no DNS block', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        final e = host.addEvent(
          'net',
          'switched',
          level: 'info',
          at: _at(0),
          data: {
            'from': {'type': 'wifi'},
            'to': {'type': 'mobile'},
            if (withDns) 'dns': {'switches': _dnsSwitched()['sides'], 'same': false, 'transports': <Object>[]},
          },
        );
        await _pump(tester, host, e['id'] as int);
        await _expand(tester, _titleOf(host, e));
        expect(find.byType(CardBlockView), withDns ? findsWidgets : findsNothing);
      });
    }
  });

  group('the buttons of a card', () {
    testWidgets('Details ▾ opens the event: its Why and Raw sections show', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent('dns', 'down', level: 'error', at: _at(0), data: _dnsDown());
      await _pump(tester, host, e['id'] as int);
      expect(_heading('Why'), findsNothing);

      await tester.tap(find.text('Details ▾'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_heading('Why'), findsOneWidget);
      expect(_heading('Raw'), findsOneWidget);
    });

    for (final (type, level, data) in [
      ('switched', 'warn', _dnsSwitched()),
      ('down', 'error', _dnsDown()),
    ]) {
      testWidgets('dns/$type: DNS settings goes to Settings → DNS', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        final e = host.addEvent('dns', type, level: level, at: _at(0), data: data);
        final calls = _Calls();
        await _pump(tester, host, e['id'] as int, links: calls.links());
        await tester.tap(find.text('DNS settings'));
        await tester.pump();
        expect(calls.list, ['dns']);
      });
    }

    testWidgets('Network event opens the net event that caused the DNS event; without a net cause there is none', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final net = host.addEvent('net', 'switched', level: 'info', at: _at(0), data: const {
        'from': {'type': 'wifi'},
        'to': {'type': 'mobile'},
      });
      final e = host.addEvent('dns', 'down', level: 'error', at: _at(1), data: _dnsDown(cause: {'kind': 'net', 'id': net['id']}));
      final calls = _Calls();
      await _pump(tester, host, e['id'] as int, links: calls.links());
      await tester.tap(find.text('Network event'));
      await tester.pump();
      expect(calls.list, ['event:${net['id']}']);

      final own = host.addEvent('dns', 'down', level: 'error', at: _at(2), data: _dnsDown());
      await _pump(tester, host, own['id'] as int, links: calls.links());
      expect(find.text('Network event'), findsNothing);
    });

    testWidgets('Ignore site ▾ opens the list: Everywhere, On this route only, Ignored sites…; Everywhere ignores the host', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked());
      await _pump(tester, host, e['id'] as int);

      await tester.tap(find.text('Ignore site ▾'));
      await tester.pump();
      for (final t in ['Everywhere', 'On this route only', 'Ignored sites…']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }

      await tester.tap(find.text('Everywhere'));
      await tester.pump();
      expect(find.textContaining('blocked.example ignored'), findsOneWidget, reason: 'the «host ignored · Undo» line');
    });

    for (final (label, extra, via) in [
      ('the entry opened the site', null, 'sub1'),
      ('a node of the entry opened it (viaTarget)', {'viaTarget': 'node:sub1::n2'}, 'node:sub1::n2'),
    ]) {
      testWidgets('site/blocked, no app: Create rule prefills the new rule, Fallback = the opening route ($label)', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked(extra: extra));
        final calls = _Calls();
        await _pump(tester, host, e['id'] as int, links: calls.links());
        await _openSite(tester, e);
        await tester.tap(find.text('Create blocked.example rule'));
        await tester.pump();
        expect(calls.list, ['newRule:blocked.example|-|$via']);
      });
    }

    testWidgets('a Checked node row retries through the core for its site', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent('site', 'unreachable', level: 'warn', at: _at(0), data: _unreachable());
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('Two').first);
      await tester.pump();
      expect(host.recheckCalls, [e['id']]);
    });

    testWidgets('the checker row of a site with a check asks the checker for this event', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(
          extra: {
            'check': {'state': 'down', 'at': _at(0), 'kind': 'http', 'via': 'tunnel', 'ok': 0, 'total': 8, 'nodes': <Object>[], 'error': 'no answer in 20 s'},
          },
        ),
      );
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('check-host.net').first);
      await tester.pump();
      expect(host.checkedSites, [e['id']]);
    });
  });
}
