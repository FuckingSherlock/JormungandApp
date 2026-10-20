// Event rows, the second line and Check again (docs/logs.md «Заголовок и подробности», docs/connect-model.md «Строка
// ноды в событии», «Check again»): an event row shows its title and its sub line as two lines; Check again on
// site/blocked and site/unreachable while the VPN is on (one press calls recheckSite once, shows progress, a press
// meanwhile does nothing, the same event is changed in place); «Earlier checks» in the expanded row; a reopened event
// has no Check again / Create rule; a server row names the node and its protocol (serverLabel) and scrolls when it
// does not fit (MarqueeText). MarqueeText: still when the text fits, scrolls to the left when it does not, ellipsis
// with disableAnimations, still with TickerMode off, disposed cleanly.
import 'dart:async';

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
import 'package:jormungand/widgets/event_rows.dart';
import 'package:jormungand/widgets/marquee_text.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

final _en = lookupAppLocalizations(const Locale('en'));

/// The time of the n-th second of the test journal (a minute ago, so all of it is inside one window).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 60000 + s * 1000;

Map<String, dynamic> _ev(
  FakeCoreHost host,
  String cat,
  String type, {
  String level = 'warn',
  Map<String, dynamic> data = const {},
}) => host.addEvent(cat, type, level: level, at: _at(0), data: data);

/// A site/blocked event: the entry opened through another server (the ✅ row) and failed through `server` (⚠️).
Map<String, dynamic> _blocked({String host = 'blocked.example'}) => {
  'host': host,
  'entry': 'main',
  'server': 'sub1::n1',
  'dest': '$host:443',
  'via': 'Second',
  'viaServer': 'sub1::n2',
  'rule': {'kind': 'final'},
};

/// A site/unreachable event: the work route failed and no other route was tried.
Map<String, dynamic> _unreachable() => {
  'host': 'dead.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'tried': <Object>[],
};

/// One earlier check of a site (as `data.checks` carries it): what it said and through which server it opened.
Map<String, dynamic> _check(int s, {String viaServer = 'sub1::n2'}) => {
  'at': _at(s),
  'kind': 'blocked',
  'server': 'sub1::n1',
  'via': 'Second',
  'viaServer': viaServer,
};

/// A subscription with two servers: «One» (vless, n1) and «Two» (hysteria2, n2) under the id sub1.
void _catalog(FakeCoreHost host, {String oneName = 'One'}) {
  host.catalog.addSource(
    Source(
      id: 'sub1',
      kind: 'sub',
      name: 'Alpha',
      url: 'https://sub.example/list',
      nodes: [
        CatalogNode(id: 'n1', name: oneName, protocol: 'vless', address: 'one.example.com'),
        CatalogNode(id: 'n2', name: 'Two', protocol: 'hysteria2', address: 'two.example.com'),
      ],
    ),
  );
}

String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    EventWords(_en, host.catalog).describe(EventRecord.fromJson(e)).title;

/// Opens the row by a tap on its title, as on the page. Plain pumps: a progress indicator or a marquee never settles.
Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pump(const Duration(milliseconds: 500));
}

/// The heading of the «Earlier checks» block, whatever its letter case (a section heading may be drawn in capitals).
final _earlierHeading = find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').toLowerCase() == 'earlier checks',
  description: 'the Earlier checks heading',
);

/// [lower] is drawn under [upper] (the sub line under the title).
void _expectBelow(WidgetTester tester, Finder lower, Finder upper) {
  final a = tester.getTopLeft(lower.first).dy, b = tester.getTopLeft(upper.first).dy;
  expect(a, greaterThan(b), reason: 'the lower text is at $a, the upper one at $b');
}

/// The host of these tests: a site check goes to [rechecks]; [recheckGate] holds the answer until the test completes
/// it; [onRecheck] writes what the core writes into the event (the journal is what the rows show).
class _RecheckHost extends FakeCoreHost {
  final rechecks = <int>[];
  Completer<bool>? recheckGate;
  void Function(Map<String, dynamic> event)? onRecheck;

  @override
  Future<bool> recheckSite(int eventId) async {
    rechecks.add(eventId);
    final g = recheckGate;
    if (g != null) await g.future;
    final e = journal.where((x) => x['id'] == eventId).firstOrNull;
    if (e != null) onRecheck?.call(e);
    return true;
  }
}

/// Shows the row of the event [id] alone (the group of the whole journal, as the Events page shows it), with the
/// VPN phase the test set. The group is rebuilt from the journal on every change, so an updated event shows.
Future<void> _pump(WidgetTester tester, FakeCoreHost host, int id) async {
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
            links: const AppLinks(),
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
  logs.setOnScreen(true);
  await tester.pump(const Duration(milliseconds: 500));
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

/// A MarqueeText of [text] in a box [width] wide, on a plain screen; [disableAnimations] and [tickers] are the
/// MediaQuery and TickerMode the widget sees.
Future<void> _pumpMarquee(
  WidgetTester tester,
  String text, {
  required double width,
  bool disableAnimations = false,
  bool tickers = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
          child: TickerMode(
            enabled: tickers,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: MarqueeText(text, style: const TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps [frames] frames of 100 ms and returns the x of [text] in each of them.
Future<List<double>> _xs(WidgetTester tester, String text, {int frames = 100}) async {
  final xs = <double>[];
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    xs.add(tester.getTopLeft(find.text(text)).dx);
  }
  return xs;
}

const _long = 'A long server name that is much wider than the narrow box it is shown in';

void main() {
  group('title and sub line (docs/logs.md «Заголовок и подробности»)', () {
    testWidgets('auto/unstable: the title and the sub line are separate Text widgets, the sub line under the title', (
      tester,
    ) async {
      final host = _RecheckHost();
      final e = _ev(host, 'auto', 'unstable', data: const {'id': 'e0', 'strikes': 2, 'holdMs': 60000});
      final d = EventWords(_en, host.catalog).describe(EventRecord.fromJson(e));
      expect(d.sub, isNotEmpty, reason: 'the details are the sub line');
      expect(d.title, isNot(contains(d.sub)), reason: 'the title carries no details');
      await _pump(tester, host, e['id'] as int);
      expect(find.text(d.title), findsWidgets);
      expect(find.text(d.sub), findsWidgets);
      _expectBelow(tester, find.text(d.sub), find.text(d.title));
    });
  });

  group('Check again (docs/connect-model.md «Check again»)', () {
    for (final (type, phase, shown) in [
      ('blocked', ConnectionPhase.connected, true),
      ('unreachable', ConnectionPhase.connected, true),
      ('blocked', ConnectionPhase.disconnected, false),
      ('unreachable', ConnectionPhase.disconnected, false),
    ]) {
      testWidgets('site/$type with the VPN ${phase.name}: Check again ${shown ? 'is' : 'is not'} shown', (tester) async {
        final host = _RecheckHost()..setPhase(phase);
        _catalog(host);
        final e = _ev(host, 'site', type, data: type == 'blocked' ? _blocked() : _unreachable());
        await _pump(tester, host, e['id'] as int);
        expect(find.text(_titleOf(host, e)), findsWidgets, reason: 'the row is there');
        expect(find.text('Check again'), shown ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('a press calls recheckSite once with the id; meanwhile the button shows progress and a press does nothing', (
      tester,
    ) async {
      final host = _RecheckHost()
        ..setPhase(ConnectionPhase.connected)
        ..recheckGate = Completer<bool>();
      _catalog(host);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      await _pump(tester, host, e['id'] as int);

      await tester.tap(find.text('Check again'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.rechecks, [e['id']]);
      expect(find.byWidgetPredicate((w) => w is ProgressIndicator), findsWidgets, reason: 'the button shows progress');

      final again = find.text('Check again');
      if (again.evaluate().isNotEmpty) await tester.tap(again.first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.rechecks, [e['id']], reason: 'no second call while the first one runs');

      host.recheckGate!.complete(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.rechecks, [e['id']]);
      expect(find.text('Check again'), findsOneWidget, reason: 'the button is back once the check is done');
    });

    testWidgets('the answer changes the same event in place: same id, no new event, the old check is under Earlier checks', (
      tester,
    ) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      final before = _check(0);
      host.onRecheck = (ev) {
        ev['rev'] = ((ev['rev'] as int?) ?? 0) + 1;
        ev['data'] = {...(ev['data'] as Map<String, dynamic>), 'checks': [before]};
      };
      await _pump(tester, host, e['id'] as int);

      await tester.tap(find.text('Check again'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(host.journal, hasLength(1), reason: 'no new event');
      expect(host.journal.single['id'], e['id']);
      expect(host.journal.single['rev'], 1, reason: 'the revision grows');

      final lines = EventWords(_en, host.catalog).earlierChecks(EventRecord.fromJson(host.journal.single));
      expect(lines, isNotEmpty);
      await _expand(tester, _titleOf(host, e));
      expect(_earlierHeading, findsOneWidget);
      for (final line in lines) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
    });
  });

  group('Earlier checks and a reopened event (docs/connect-model.md «Check again»)', () {
    testWidgets('an expanded site row with data.checks shows «Earlier checks» with one line per check', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(
        host,
        'site',
        'blocked',
        data: {
          ..._blocked(),
          'checks': [_check(0), _check(30, viaServer: 'sub1::n1')],
        },
      );
      final lines = EventWords(_en, host.catalog).earlierChecks(EventRecord.fromJson(e));
      expect(lines, isNotEmpty);
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));
      expect(_earlierHeading, findsOneWidget);
      for (final line in lines) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
    });

    testWidgets('without data.checks there is no «Earlier checks» block', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));
      expect(_earlierHeading, findsNothing);
    });

    testWidgets('a reopened event has no Check again (connected) and no Create rule (disconnected)', (tester) async {
      // the folded row holds up to three buttons, so Check again and Create rule are not looked for together
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final open = _ev(host, 'site', 'unreachable', data: _unreachable());
      await _pump(tester, host, open['id'] as int);
      expect(find.text('Check again'), findsOneWidget, reason: 'precondition: an open site has it');

      final reopened = {..._unreachable(), 'reopened': {'at': _at(10), 'entry': 'main', 'server': 'sub1::n2'}};
      final closed = _ev(host, 'site', 'unreachable', data: reopened);
      await _pump(tester, host, closed['id'] as int);
      expect(find.text('Check again'), findsNothing, reason: 'connected, but the event is closed');

      host.setPhase(ConnectionPhase.disconnected);
      await _pump(tester, host, closed['id'] as int);
      expect(find.text('Create rule'), findsNothing, reason: 'the closed event has no Create rule');
    });
  });

  group('server rows (docs/connect-model.md «Строка ноды в событии»)', () {
    testWidgets('a server row names the node and its protocol (serverLabel)', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      final words = EventWords(_en, host.catalog);
      for (final key in ['sub1::n1', 'sub1::n2']) {
        final label = words.serverLabel(key);
        expect(label.protocol, isNotEmpty, reason: key);
        expect(find.textContaining(label.name), findsWidgets, reason: 'the name of $key');
        expect(find.textContaining(label.protocol), findsWidgets, reason: 'the protocol of $key');
      }
    });

    testWidgets('a server name that does not fit its row scrolls as a marquee', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host, oneName: _long);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));
      expect(find.byType(MarqueeText), findsWidgets);
    });
  });

  group('MarqueeText (app/lib/widgets/marquee_text.dart)', () {
    testWidgets('text that fits stays still', (tester) async {
      await _pumpMarquee(tester, 'Short', width: 300);
      final xs = await _xs(tester, 'Short', frames: 80);
      expect(xs.toSet(), hasLength(1));
    });

    testWidgets('text that does not fit a narrow box scrolls: its position changes and goes to the left', (tester) async {
      await _pumpMarquee(tester, _long, width: 80);
      final start = tester.getTopLeft(find.text(_long)).dx;
      final xs = await _xs(tester, _long, frames: 300);
      expect(xs.toSet().length, greaterThan(1), reason: 'it moves');
      expect(xs.reduce((a, b) => a < b ? a : b), lessThan(start), reason: 'it scrolls to the left');
    });

    testWidgets('with disableAnimations a long text stays still and is cut with an ellipsis', (tester) async {
      await _pumpMarquee(tester, _long, width: 80, disableAnimations: true);
      final xs = await _xs(tester, _long, frames: 80);
      expect(xs.toSet(), hasLength(1));
      expect(tester.widget<Text>(find.text(_long)).overflow, TextOverflow.ellipsis);
    });

    testWidgets('with its ticker off (not visible) a long text does not move', (tester) async {
      await _pumpMarquee(tester, _long, width: 80, tickers: false);
      final xs = await _xs(tester, _long, frames: 80);
      expect(xs.toSet(), hasLength(1));
    });

    testWidgets('disposed while scrolling: the tree goes cleanly, no exception and no ticker left', (tester) async {
      await _pumpMarquee(tester, _long, width: 80);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(find.text(_long), findsNothing);
    });
  });
}
