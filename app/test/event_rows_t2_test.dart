// Event rows, t2 (docs/logs.md «По типам», «Задетые настройки», plan «App row API»): the buttons of a folded row per
// type (Connect for a system disconnect; Switch on before Choose for all; Choose for all only over more than one
// rule / app / connection; Open subscription for the sub/updated warn; no buttons on sub/back and node/back; the
// auto/unstable exclude actions hidden); the affected rows (kind, name, where the traffic goes now; a tap opens the
// setting); Choose for all retargets through the picker; the pair links call onJump; the filter sheet shows the
// always-shown types as «Always shown». Phrases fixed by the doc are written out as literals; the pair status is
// the project's English «Finished at … · lasted …» (i18n_extra.json).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/app_links.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/state/app_settings.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/event_rows.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

final _en = lookupAppLocalizations(const Locale('en'));

/// The time of the n-th second of the test journal (a minute ago, so all of it is inside one window).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 60000 + s * 1000;

/// Adds an event to the journal; [opens] is the id of the opening event of a pair (Sentinel writes it).
Map<String, dynamic> _ev(
  FakeCoreHost host,
  String cat,
  String type, {
  String level = 'warn',
  bool own = false,
  int s = 0,
  Map<String, dynamic> data = const {},
  int? opens,
}) {
  final e = host.addEvent(cat, type, level: level, own: own, at: _at(s), data: data);
  if (opens != null) e['opens'] = opens;
  return e;
}

/// One affected setting, as `affected` carries it: `kind` connection / chain / profile / rule / app, `to` where
/// its traffic goes now (`block` / `direct` / `main` / a target id / `none`).
Map<String, dynamic> _item(String kind, String id, String name, String to) => {
  'kind': kind,
  'id': id,
  'name': name,
  'to': to,
};

final _rules = [_item('rule', 'r1', 'Netflix', 'block'), _item('rule', 'r2', 'YouTube', 'direct')];

const _vless = 'vless://11111111-1111-1111-1111-111111111111@one.example.com:443?security=tls&sni=one.example.com#One\n';

/// A server switched off (or deleted) that some settings use. `nodes` are the names of the servers (for the text),
/// `nodeIds` their ids (core writes both; «Switch on» reads the ids).
Map<String, dynamic> _nodeLost(
  List<Map<String, dynamic>> affected, {
  String action = 'off',
  String source = 's1',
  List<String> nodes = const ['One'],
  List<String> nodeIds = const ['n1'],
}) => {
  'action': action,
  'source': source,
  'name': 'Alpha',
  'nodes': nodes,
  'nodeIds': nodeIds,
  'nodeCount': nodes.length,
  'affected': affected,
};

/// A subscription update that removed servers in use (the warn variation of sub/updated).
Map<String, dynamic> _subWarn(List<Map<String, dynamic>> affected, {String source = 's1'}) => {
  'source': source,
  'name': 'Alpha',
  'added': 0,
  'removed': 2,
  'total': 3,
  'own': false,
  'lost': ['A', 'B'],
  'lostCount': 2,
  'affected': affected,
};

/// The two events that carry an affected list: (cat, type, own, data built from the list).
final _lostKinds = <(String, String, bool, Map<String, dynamic> Function(List<Map<String, dynamic>>))>[
  ('node', 'lost', true, (a) => _nodeLost(a)),
  ('sub', 'updated', false, _subWarn),
];

/// A subscription in Nodes with one server «One» (id n1), switched off there when [off]: the state a `node/lost`
/// `off` of it is about. Returns the source id, the server's name and id (what the event lists).
({String sid, String node, String nid}) _subscription(FakeCoreHost host, {bool off = false}) {
  const sid = 'sub1';
  host.catalog.addSource(
    Source(
      id: sid,
      kind: 'sub',
      name: 'Alpha',
      url: 'https://sub.example/list',
      nodes: [CatalogNode(id: 'n1', name: 'One', protocol: 'vless', address: 'one.example.com')],
    ),
  );
  if (off) host.toggleNodeEnabled(sid, 'n1');
  return (sid: sid, node: 'One', nid: 'n1');
}

String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    EventWords(_en, host.catalog).describe(EventRecord.fromJson(e)).title;

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// A text that matches the pattern (case-insensitive): the words the row sets with a value in them.
Finder _textLike(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && RegExp(pattern, caseSensitive: false).hasMatch(w.data ?? ''),
  description: 'text like $pattern',
);

/// [a] sits before [b] in reading order (above, or on the same line and to the left).
void _expectBefore(WidgetTester tester, Finder a, Finder b) {
  final pa = tester.getTopLeft(a), pb = tester.getTopLeft(b);
  final before = pa.dy < pb.dy - 1 || ((pa.dy - pb.dy).abs() <= 1 && pa.dx < pb.dx);
  expect(before, isTrue, reason: 'the first button is at $pa, the second at $pb');
}

/// The host of these tests: it records what Choose for all hands to the core.
class _RetargetHost extends FakeCoreHost {
  final retargets = <(List<Map<String, dynamic>>, String)>[];

  @override
  Future<void> retargetAll(List<Map<String, dynamic>> affected, String target) async {
    retargets.add((affected, target));
  }
}

/// Shows the row of the event [id] alone, as the Events page would (the group of the whole journal), with the
/// links and [onJump] of the test. The row is opened by a tap on its title, as on the page.
Future<void> _pumpRow(
  WidgetTester tester,
  FakeCoreHost host,
  int id, {
  AppLinks links = const AppLinks(),
  void Function(int eventId)? onJump,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 2400);
  addTearDown(tester.view.reset);
  // started, so the feed holds the journal (the row finds the opening event's title in it); its timers end with the
  // widget tree (_EndWith)
  final logs = LogsController(host)..l10n = _en;
  logs.start();
  final groups = foldEvents([for (final e in host.journal) EventRecord.fromJson(e)]);
  final group = groups.firstWhere((g) => g.ev.id == id);
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
                      builder: (_, _) => EventRow(
                        group: group,
                        logs: logs,
                        words: words,
                        first: true,
                        onJump: onJump,
                      ),
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
  await tester.pumpAndSettle();
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

void main() {
  group('buttons of the folded row (docs/logs.md «По типам»)', () {
    for (final (by, data) in <(String, Map<String, dynamic>)>[
      ('error', {'by': 'error', 'reason': 'down'}),
      ('system', {'by': 'system', 'reason': 'revoked'}),
    ]) {
      testWidgets('conn/disconnected by $by: Connect', (tester) async {
        final host = FakeCoreHost();
        final e = _ev(host, 'conn', 'disconnected', data: data);
        await _pumpRow(tester, host, e['id'] as int);
        expect(find.text('Connect'), findsOneWidget);
      });
    }

    testWidgets('node/lost off with two affected rules: Switch on first, then Choose for all', (tester) async {
      final host = FakeCoreHost();
      final off = _subscription(host, off: true);
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost(_rules, source: off.sid, nodes: [off.node], nodeIds: [off.nid]),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsOneWidget);
      expect(find.text('Choose for all'), findsOneWidget);
      _expectBefore(tester, find.text('Switch on'), find.text('Choose for all'));
    });

    testWidgets('node/lost off with one affected rule: Switch on, no Choose for all', (tester) async {
      final host = FakeCoreHost();
      final off = _subscription(host, off: true);
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost([_rules.first], source: off.sid, nodes: [off.node], nodeIds: [off.nid]),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsOneWidget);
      expect(find.text('Choose for all'), findsNothing);
    });

    testWidgets('node/lost off: Switch on finds the server by its id, not by its name', (tester) async {
      final host = FakeCoreHost();
      final off = _subscription(host, off: true);
      // the name in the list matches no server; the id does
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost(_rules, source: off.sid, nodes: ['Nowhere'], nodeIds: [off.nid]),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsOneWidget);
    });

    testWidgets('node/lost off: names alone, with no id of a switched-off server, give no Switch on', (tester) async {
      final host = FakeCoreHost();
      final off = _subscription(host, off: true);
      // the name «One» is the switched-off server, but the id is not one of its ids
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost(_rules, source: off.sid, nodes: [off.node], nodeIds: ['n9']),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsNothing);
    });

    testWidgets('node/lost off: no Switch on once its server is switched on again', (tester) async {
      final host = FakeCoreHost();
      final on = _subscription(host);
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost(_rules, source: on.sid, nodes: [on.node], nodeIds: [on.nid]),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsNothing);
    });

    testWidgets('node/lost off of a whole source: Switch on when the source is switched off', (tester) async {
      final host = FakeCoreHost();
      final src = _subscription(host);
      host.toggleSourceEnabled(src.sid);
      final e = _ev(
        host,
        'node',
        'lost',
        own: true,
        data: _nodeLost(_rules, source: src.sid, nodes: [src.node], nodeIds: [src.nid]),
      );
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsOneWidget);
    });

    for (final whole in [false, true]) {
      testWidgets('Switch on turns the ${whole ? 'whole source' : 'server'} back on', (tester) async {
        final host = FakeCoreHost();
        final src = _subscription(host, off: !whole);
        if (whole) host.toggleSourceEnabled(src.sid);
        final e = _ev(
          host,
          'node',
          'lost',
          own: true,
          data: _nodeLost(_rules, source: src.sid, nodes: [src.node], nodeIds: [src.nid]),
        );
        await _pumpRow(tester, host, e['id'] as int);
        await tester.tap(find.text('Switch on'));
        await tester.pumpAndSettle();
        final s = host.catalog.sourcesData[src.sid]!;
        expect(s.enabled, isTrue, reason: 'the source is on');
        expect(s.disabledNodes, isNot(contains(src.nid)), reason: 'the server is on');
      });
    }

    testWidgets('chains and profiles do not count towards Choose for all', (tester) async {
      final host = FakeCoreHost();
      final affected = [
        _rules.first,
        _item('chain', 'c1', 'Chain A', 'none'),
        _item('chain', 'c2', 'Chain B', 'none'),
        _item('profile', 'p1', 'Home', 'none'),
      ];
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(affected));
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Choose for all'), findsNothing);
    });

    testWidgets('a connection and an app both count: two items give Choose for all', (tester) async {
      final host = FakeCoreHost();
      final affected = [_item('connection', 'route', 'Route', 'main'), _item('app', 'org.telegram.messenger', 'Telegram', 'direct')];
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(affected));
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Choose for all'), findsOneWidget);
    });

    testWidgets('node/lost deleted: no Switch on; Choose for all still over more than one rule', (tester) async {
      final host = FakeCoreHost();
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(_rules, action: 'deleted'));
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Switch on'), findsNothing);
      expect(find.text('Choose for all'), findsOneWidget);
    });

    testWidgets('sub/updated warn: Open subscription and Choose for all over two rules; no Switch on', (tester) async {
      final host = FakeCoreHost();
      final warn = _ev(host, 'sub', 'updated', data: _subWarn(_rules, source: _subscription(host).sid));
      await _pumpRow(tester, host, warn['id'] as int);
      expect(find.text('Open subscription'), findsOneWidget);
      expect(find.text('Choose for all'), findsOneWidget);
      expect(find.text('Switch on'), findsNothing);
    });

    testWidgets('sub/updated info: no Open subscription', (tester) async {
      final host = FakeCoreHost();
      final info = _ev(
        host,
        'sub',
        'updated',
        level: 'info',
        data: const {'source': 's1', 'name': 'Alpha', 'added': 1, 'removed': 0, 'total': 5, 'own': false},
      );
      await _pumpRow(tester, host, info['id'] as int);
      expect(find.text('Open subscription'), findsNothing);
    });

    testWidgets('sub/back and node/back have no buttons', (tester) async {
      final host = FakeCoreHost();
      final back = _ev(
        host,
        'sub',
        'back',
        level: 'info',
        data: {'source': 's1', 'name': 'Alpha', 'count': 2, 'names': ['A', 'B'], 'affected': _rules},
      );
      final nodeBack = _ev(
        host,
        'node',
        'back',
        level: 'info',
        data: {'source': 's1', 'name': 'Alpha', 'nodes': ['n1'], 'affected': _rules},
      );
      for (final id in [back['id'] as int, nodeBack['id'] as int]) {
        await _pumpRow(tester, host, id);
        expect(find.text('Switch on'), findsNothing, reason: 'event $id');
        expect(find.text('Choose for all'), findsNothing, reason: 'event $id');
        expect(find.text('Open subscription'), findsNothing, reason: 'event $id');
      }
    });

    testWidgets('auto/unstable: no Return once or Don\'t exclude; Check now stays', (tester) async {
      final host = FakeCoreHost();
      final e = _ev(host, 'auto', 'unstable', data: const {'id': 'e0', 'strikes': 2, 'holdMs': 60000});
      await _pumpRow(tester, host, e['id'] as int);
      expect(find.text('Return once'), findsNothing);
      expect(find.text("Don't exclude"), findsNothing);
      expect(find.text('Check now'), findsOneWidget);
    });

    test('the exclude actions of auto/unstable are built but hidden behind kAutoExcludeActions', () {
      expect(kAutoExcludeActions, isFalse);
    });
  });

  group('the affected settings of a lost server (docs/logs.md «Задетые настройки»)', () {
    final affected = [
      _item('rule', 'r1', 'Netflix', 'block'),
      _item('app', 'org.telegram.messenger', 'Telegram', 'direct'),
      _item('connection', 'route', 'Route', 'main'),
      _item('chain', 'c1', 'Chain A', 'none'),
    ];

    for (final (cat, type, own, data) in _lostKinds) {
      testWidgets('$cat/$type: the expanded row lists each setting with its kind, name and «→ where it goes now»', (
        tester,
      ) async {
        final host = FakeCoreHost();
        final e = _ev(host, cat, type, own: own, data: data(affected));
        await _pumpRow(tester, host, e['id'] as int);
        await _expand(tester, _titleOf(host, e));

        for (final name in ['Netflix', 'Telegram', 'Route', 'Chain A']) {
          expect(find.text(name), findsOneWidget, reason: name);
        }
        for (final kind in ['Rule', 'App', 'Connection', 'Chain']) {
          expect(find.text(kind), findsWidgets, reason: kind);
        }
        expect(_textLike(r'^→ .*block'), findsOneWidget);
        expect(_textLike(r'^→ .*direct'), findsOneWidget);
        expect(_textLike(r'^→ .*main'), findsOneWidget);
        expect(_textLike(r'^→ .*not working'), findsOneWidget, reason: 'a chain with to: none');
      });
    }

    testWidgets('a tap on an affected row opens its setting: rule → rule form, app → app dialog, connection → Route', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final calls = <String>[];
      final links = AppLinks(
        openRuleForm: (id) => calls.add('rule:$id'),
        openAppAct: (pkg) => calls.add('app:$pkg'),
        openRoute: ({bool edit = false}) => calls.add('route'),
      );
      final items = [
        _item('rule', 'r1', 'Netflix', 'block'),
        _item('app', 'org.telegram.messenger', 'Telegram', 'direct'),
        _item('connection', 'route', 'Route', 'main'),
      ];
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(items));
      await _pumpRow(tester, host, e['id'] as int, links: links);
      await _expand(tester, _titleOf(host, e));

      await tester.tap(find.text('Netflix'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegram'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Route'));
      await tester.pumpAndSettle();
      expect(calls, ['rule:r1', 'app:org.telegram.messenger', 'route']);
    });
  });

  group('Choose for all (docs/logs.md «Задетые настройки»)', () {
    testWidgets('the target picked in the picker goes to every affected rule and app through retargetAll', (tester) async {
      final host = _RetargetHost();
      // a subscription in the catalog, so the picker has a whole item to mark (its AUTO header)
      final sid = (await host.importConfigFile('pick.txt', _vless)).sourceId!;
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(_rules));
      await _pumpRow(tester, host, e['id'] as int);

      await tester.tap(find.text('Choose for all'));
      await tester.pumpAndSettle();
      // the picker: AUTO in the subscription's header marks the whole item; Save applies the mark
      await tester.tap(find.text('AUTO').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(host.retargets, hasLength(1));
      final (affected, target) = host.retargets.single;
      expect([for (final a in affected) a['id']], ['r1', 'r2']);
      expect(target, 'src:$sid');
    });

    testWidgets('a cancelled picker retargets nothing', (tester) async {
      final host = _RetargetHost();
      final e = _ev(host, 'node', 'lost', own: true, data: _nodeLost(_rules));
      await _pumpRow(tester, host, e['id'] as int);

      await tester.tap(find.text('Choose for all'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(host.retargets, isEmpty);
    });
  });

  group('pair links (plan «App row API»)', () {
    testWidgets('the opening row: its «Finished at … · lasted …» status calls onJump with closedById', (tester) async {
      final host = FakeCoreHost();
      final off = _ev(host, 'conn', 'offline', level: 'warn');
      final on = _ev(host, 'conn', 'online', level: 'info', s: 5, opens: off['id'] as int);
      final jumps = <int>[];
      await _pumpRow(tester, host, off['id'] as int, onJump: jumps.add);
      await _expand(tester, _titleOf(host, off));

      await tester.tap(_textLike(r'^Finished at').first);
      await tester.pumpAndSettle();
      expect(jumps, [on['id']]);
    });

    testWidgets('the closing row: «Back to start: …» calls onJump with opensId', (tester) async {
      final host = FakeCoreHost();
      final off = _ev(host, 'conn', 'offline', level: 'warn');
      final on = _ev(host, 'conn', 'online', level: 'info', s: 5, opens: off['id'] as int);
      final jumps = <int>[];
      await _pumpRow(tester, host, on['id'] as int, onJump: jumps.add);
      await _expand(tester, _titleOf(host, on));
      await tester.tap(_textLike(r'^Back to start: ').first);
      await tester.pumpAndSettle();
      expect(jumps, [off['id']]);
    });

    testWidgets('a closing row whose opening event left the journal has no «Back to start» link', (tester) async {
      final host = FakeCoreHost();
      final on = _ev(host, 'conn', 'online', level: 'info', opens: 987654);
      await _pumpRow(tester, host, on['id'] as int, onJump: (_) {});
      await _expand(tester, _titleOf(host, on));
      expect(_textLike(r'^Back to start'), findsNothing);
    });
  });

  testWidgets('filter sheet: the always-shown types say «Always shown» instead of a toggle', (tester) async {
    final host = FakeCoreHost();
    host.addEvent('conn', 'vpnDown', level: 'warn', at: _at(0), data: const {'causes': ['core']});
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    final words = EventWords(_en, host.catalog);
    // categories start folded (event_filter_test): unfold conn
    await tester.tap(find.text(words.catLabel('conn')).last);
    await tester.pumpAndSettle();

    final alwaysInCats = [
      for (final (cat, types) in eventCats)
        for (final t in types)
          if (alwaysShownTypes.contains('$cat/$t')) '$cat/$t',
    ];
    expect(alwaysInCats, hasLength(alwaysShownTypes.length), reason: 'every always-shown type is in the catalog');
    expect(find.byKey(const ValueKey('evCount:conn/vpnDown')), findsOneWidget);
    expect(find.text('Always shown'), findsNWidgets(alwaysShownTypes.length));
  });
}
