// Event rows, the second line and retries (docs/logs.md «Заголовок и подробности», docs/connect-model.md «Строка ноды в
// событии», «Карточка сайта», «Check again»): an event row shows its title and its sub line as two lines; a site card
// has no Check again button (a retry is the tap on a row: one press calls recheckSiteNode once for the event and the
// row, that row shows progress while the check runs, a press on the busy row meanwhile does nothing, other rows stay
// usable, two rows can run at once, the same event is changed in place, no LinearProgressIndicator over the card);
// «Earlier checks» in the expanded row;
// a reopened event has no Create rule; a server row names the node and its protocol (serverLabel) and scrolls when it
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

/// A site/unreachable event: the work route failed; the other routes tried are `sub1::n2` and `sub1::n3` (Checked rows).
Map<String, dynamic> _unreachable({List<String> tried = const ['sub1::n2']}) => {
  'host': 'dead.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'tried': [for (final s in tried) {'entry': 'main', 'server': s}],
  'nodes': [for (final s in tried) {'entry': 'main', 'server': s, 'ok': false}],
};

/// One earlier check of a site (as `data.checks` carries it): what it said and through which server it opened.
Map<String, dynamic> _check(int s, {String viaServer = 'sub1::n2'}) => {
  'at': _at(s),
  'kind': 'blocked',
  'server': 'sub1::n1',
  'via': 'Second',
  'viaServer': viaServer,
};

/// One earlier check of one node of a site (`kind: node`, as the core writes it after a per-row recheck).
Map<String, dynamic> _nodeCheck(int s, String server, {required bool ok}) => {
  'at': _at(s),
  'kind': 'node',
  'server': server,
  'ok': ok,
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
        CatalogNode(id: 'n3', name: 'Three', protocol: 'vless', address: 'three.example.com'),
      ],
    ),
  );
}

/// Whether the busy indicator of a row is drawn in the row that shows [text] and none of [others]: the nearest ancestor
/// of an indicator that holds [text] must hold no text of the other rows.
bool _busyOn(WidgetTester tester, String text, {required List<String> others}) {
  for (final b in find.byKey(const ValueKey('eventCard.busy')).evaluate()) {
    var found = false;
    b.visitAncestorElements((a) {
      final texts = _textsUnder(a);
      if (texts.any((s) => s.contains(text))) {
        found = !texts.any((s) => others.any(s.contains));
        return false;
      }
      return true;
    });
    if (found) return true;
  }
  return false;
}

/// The data of every Text under [root].
List<String> _textsUnder(Element root) {
  final out = <String>[];
  void walk(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// Opens a site card by a tap on its header, which names the host (the header words are the card's own).
/// Plain pumps: a progress indicator or a marquee never settles.
Future<void> _openSite(WidgetTester tester, Map<String, dynamic> e) async {
  // "Details ▾" (the first action) opens the card; a tap on the host in the title copies it instead
  await tester.tap(find.byKey(const ValueKey('eventCard.action.0')).first);
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

/// The host of these tests: a row retry goes to [nodeRechecks] (the base class records it); [nodeGates] holds the
/// answer of a node until the test completes it (a node without a gate answers at once); [onRecheck] writes what the
/// core writes into the event (the journal is what the rows show). [rechecks] counts whole-site calls, which a row
/// retry must not make.
class _RecheckHost extends FakeCoreHost {
  final rechecks = <int>[];
  final nodeGates = <String, Completer<bool>>{};
  void Function(Map<String, dynamic> event)? onRecheck;

  @override
  Future<bool> recheckSite(int eventId) async {
    rechecks.add(eventId);
    return super.recheckSite(eventId);
  }

  @override
  Future<bool> recheckSiteNode(int eventId, String node) async {
    final r = await super.recheckSiteNode(eventId, node);
    final g = nodeGates[node];
    if (g != null) await g.future;
    final e = journal.where((x) => x['id'] == eventId).firstOrNull;
    if (e != null) onRecheck?.call(e);
    return r;
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

  group('a site card has no Check again (docs/connect-model.md «Карточка сайта»)', () {
    for (final type in ['blocked', 'unreachable']) {
      testWidgets('site/$type with the VPN on: no Check again, the row is there', (tester) async {
        final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
        _catalog(host);
        final e = _ev(host, 'site', type, data: type == 'blocked' ? _blocked() : _unreachable());
        await _pump(tester, host, e['id'] as int);
        expect(find.textContaining(type == 'blocked' ? 'blocked.example' : 'dead.example'), findsWidgets, reason: 'the row is there');
        expect(find.text('Check again'), findsNothing);
      });
    }
  });

  group('retry through a Checked row (docs/connect-model.md «Check again», «Карточка сайта»)', () {
    testWidgets('a tap on a Checked node row calls recheckSiteNode once with the event and the node; the row is busy meanwhile and a press does nothing', (
      tester,
    ) async {
      final host = _RecheckHost()
        ..setPhase(ConnectionPhase.connected)
        ..nodeGates['sub1::n2'] = Completer<bool>();
      _catalog(host);
      final e = _ev(host, 'site', 'unreachable', data: _unreachable());
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('Two').first);
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.nodeRechecks, [(eventId: e['id'] as int, node: 'sub1::n2')]);
      expect(host.rechecks, isEmpty, reason: 'a row retry is not a whole-site check');
      expect(_busyOn(tester, 'Two', others: ['Three', 'One']), isTrue, reason: 'the row shows progress');
      expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'no progress bar over the card');

      await tester.tap(find.textContaining('Two').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.nodeRechecks, hasLength(1), reason: 'no second call while the first one runs');

      host.nodeGates['sub1::n2']!.complete(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_busyOn(tester, 'Two', others: ['Three', 'One']), isFalse, reason: 'the row is done');
      await tester.tap(find.textContaining('Two').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(host.nodeRechecks, hasLength(2), reason: 'a finished check can be asked again');
    });

    testWidgets('the own route row retries the own node: recheckSiteNode with the own key, the row is busy meanwhile', (
      tester,
    ) async {
      final host = _RecheckHost()
        ..setPhase(ConnectionPhase.connected)
        ..nodeGates['sub1::n1'] = Completer<bool>();
      _catalog(host);
      final e = _ev(host, 'site', 'unreachable', data: _unreachable());
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('One').first);
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.nodeRechecks, [(eventId: e['id'] as int, node: 'sub1::n1')]);
      expect(_busyOn(tester, 'One', others: ['Two', 'Three']), isTrue);
      expect(_busyOn(tester, 'Two', others: ['One', 'Three']), isFalse, reason: 'the other rows stay');

      host.nodeGates['sub1::n1']!.complete(true);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('the answer changes the same event in place: same id, no new event, the old check is under Earlier checks', (
      tester,
    ) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(host, 'site', 'unreachable', data: _unreachable());
      final before = _check(0);
      host.onRecheck = (ev) {
        ev['rev'] = ((ev['rev'] as int?) ?? 0) + 1;
        ev['data'] = {
          ...(ev['data'] as Map<String, dynamic>),
          'checks': [before, _nodeCheck(30, 'sub1::n2', ok: false)],
        };
      };
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('Two').first);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(host.journal, hasLength(1), reason: 'no new event');
      expect(host.journal.single['id'], e['id']);
      expect(host.journal.single['rev'], 1, reason: 'the revision grows');

      final lines = EventWords(_en, host.catalog).earlierChecks(EventRecord.fromJson(host.journal.single));
      expect(lines, hasLength(2));
      expect(lines.where((l) => l.endsWith('· Two · did not open')), hasLength(1), reason: 'the node check reads by name');
      expect(_earlierHeading, findsOneWidget);
      for (final line in lines) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
    });
  });

  group('per-row busy with two nodes (docs/connect-model.md «Check again»)', () {
    testWidgets('two rows of one site run at once; each is busy on its own row only', (tester) async {
      final host = _RecheckHost()
        ..setPhase(ConnectionPhase.connected)
        ..nodeGates['sub1::n2'] = Completer<bool>()
        ..nodeGates['sub1::n3'] = Completer<bool>();
      _catalog(host);
      final e = _ev(host, 'site', 'unreachable', data: _unreachable(tried: const ['sub1::n2', 'sub1::n3']));
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

      await tester.tap(find.textContaining('Two').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.textContaining('Three').first);
      await tester.pump(const Duration(milliseconds: 200));
      expect(host.nodeRechecks.map((c) => c.node), ['sub1::n2', 'sub1::n3']);
      expect(_busyOn(tester, 'Two', others: ['Three', 'One']), isTrue);
      expect(_busyOn(tester, 'Three', others: ['Two', 'One']), isTrue);
      expect(_busyOn(tester, 'One', others: ['Two', 'Three']), isFalse, reason: 'the own route is not asked');

      host.nodeGates['sub1::n2']!.complete(true);
      host.nodeGates['sub1::n3']!.complete(true);
      await tester.pump(const Duration(milliseconds: 500));
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
      await _openSite(tester, e);
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
      await _openSite(tester, e);
      expect(_earlierHeading, findsNothing);
    });

    testWidgets('a reopened event has no Create rule and no retry', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.disconnected);
      _catalog(host);
      final reopened = {..._blocked(), 'reopened': {'at': _at(10), 'entry': 'main', 'server': 'sub1::n2'}};
      final closed = _ev(host, 'site', 'blocked', data: reopened);
      await _pump(tester, host, closed['id'] as int);
      await _openSite(tester, closed);
      expect(find.text('Create blocked.example rule'), findsNothing, reason: 'the closed event has no Create rule');
      expect(find.text('Check again'), findsNothing);
    });
  });

  group('server rows (docs/connect-model.md «Строка ноды в событии»)', () {
    testWidgets('a server row names the node and its protocol (serverLabel)', (tester) async {
      final host = _RecheckHost()..setPhase(ConnectionPhase.connected);
      _catalog(host);
      final e = _ev(host, 'site', 'blocked', data: _blocked());
      await _pump(tester, host, e['id'] as int);
      await _openSite(tester, e);

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
      await _openSite(tester, e);
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
