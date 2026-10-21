// Event reason rows (docs/connect-model.md «Строки причины», «Конфликт приложение ↔ правило»; plan app-rules): above
// the ⚠️ / ✅ rows of a site/* event a Rule row names what decided the request (own rule, app rule, service, quick
// rule, main flow) and a tap goes to its place; an event with an app has no Create rule, its Rule row under the App
// row is the app's rule that caught the host, a disabled one with this host, or «New rule for <host>» (a new app rule
// with Fallback through the node that opened the site); a rule is named from the current UI data (renamed → new name,
// deleted → the event's name without a chevron, unnamed by the core → its raw text); an old event without data.rule
// has no reason rows; the App row and the matched rule say «overridden by rule» / «applied» and the own rules that
// would catch the host say «overridden by app» (labels follow the current settings, not the event); a tap on a rule
// row leaves a return to the event.
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
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

final _en = lookupAppLocalizations(const Locale('en'));

const _pkg = 'org.telegram.messenger';

/// The time of the n-th second of the test journal (a minute ago, so all of it is inside one window).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 60000 + s * 1000;

/// A subscription with two servers «One» (n1) and «Two» (n2) under sub1.
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

/// A condition group that matches one exact domain (the form of `UserRule.groups`).
Map<String, dynamic> _domain(String d) => {
  'domain': {
    'v': {
      'domain': [d],
    },
  },
};

/// Own rule r1 (Streaming, on, catches blocked.example) in the catalog's own list.
void _ownRule(FakeCoreHost host, {String name = 'Streaming'}) {
  host.catalog.rulesData['r1'] = UserRule(
    id: 'r1',
    name: name,
    enabled: true,
    action: 'direct',
    groups: _domain('blocked.example'),
  );
  host.catalog.ruleOrder = ['r1'];
}

/// A site/blocked event: the entry opened through another server (via, viaServer), failed through `server`.
/// [app] is the Android package that sent the request (null: none); [viaTarget] the node target of the opening.
Map<String, dynamic> _blocked({Map<String, dynamic>? rule, String? app, String? viaTarget}) => {
  'host': 'blocked.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'dest': 'blocked.example:443',
  'via': 'sub1',
  'viaServer': 'sub1::n2',
  'viaTarget': ?viaTarget,
  'rule': ?rule,
  'app': ?app,
};

/// A site/unreachable event: no other route was tried and none opened the site.
Map<String, dynamic> _unreachable({Map<String, dynamic>? rule, String? app}) => {
  'host': 'dead.example',
  'entry': 'main',
  'server': 'sub1::n1',
  'tried': <Object>[],
  'rule': ?rule,
  'app': ?app,
};

String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    EventWords(_en, host.catalog).describe(EventRecord.fromJson(e)).title;

/// Opens the row by a tap on its title, as on the page. Plain pumps: a marquee never settles.
Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pump(const Duration(milliseconds: 500));
}

/// Records what the rows ask of the shell, one string per call; '-' for a null argument.
class _Calls {
  final list = <String>[];

  AppLinks links() => AppLinks(
    openRuleForm: (id) => list.add('ruleForm:$id'),
    openRules: ([at]) => list.add('rules:${at ?? '-'}'),
    openRoute: ({bool edit = false}) => list.add('route'),
    newRuleFor: ({host, app, via}) => list.add('newRule:${host ?? '-'}|${app ?? '-'}'),
    openAppRule: ({required String app, String? ruleId, String? host, String? via}) =>
        list.add('appRule:$app|${ruleId ?? '-'}|${host ?? '-'}|${via ?? '-'}'),
  );
}

/// Shows the row of the event [id] alone (the group of the whole journal, as the Events page shows it) with [links].
/// Returns the controller of the feed, to read what a tap left behind (returnId).
Future<LogsController> _pump(WidgetTester tester, FakeCoreHost host, int id, {AppLinks links = const AppLinks()}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(640, 2400);
  addTearDown(tester.view.reset);
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
                      builder: (_, _) => EventRow(group: group, logs: logs, words: words, first: true),
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

/// The app rules of [_pkg] in the catalog: [rules] in their order, [tcp] its own TCP route (null: none).
void _appRules(FakeCoreHost host, {AppHalf? tcp, List<UserRule> rules = const []}) {
  host.catalog.appRules[_pkg] = AppRule(tcp: tcp, rules: [...rules]);
}

void main() {
  group('reason rows of a site event (connect-model «Строки причины»)', () {
    // the reason row names what decided the request (its label: «Rule», or «Service» for a service); a tap goes to
    // its place (the link named in the last column)
    final cases = <(String, String, Map<String, dynamic>, String, String)>[
      ('own rule', 'Rule', {'kind': 'user', 'id': 'r1', 'name': 'Streaming'}, 'Streaming', 'ruleForm:r1'),
      ('service', 'Service', {'kind': 'service', 'id': 'youtube', 'name': 'YouTube'}, 'YouTube', 'rules:svc:youtube'),
      ('quick: Block ads', 'Rule', {'kind': 'quick', 'id': 'ads', 'name': 'Block ads'}, 'Block ads', 'rules:quick:ads'),
      (
        'quick: My region direct',
        'Rule',
        {'kind': 'quick', 'id': 'region', 'name': 'My region direct'},
        'My region direct',
        'rules:quick:region',
      ),
      ('main flow', 'Rule', {'kind': 'final'}, 'None — main flow', 'route'),
    ];

    for (final (label, row, rule, name, call) in cases) {
      testWidgets('$label: a $row row with "$name" above the verdict rows; a tap goes to $call', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        _ownRule(host);
        final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked(rule: rule));
        final calls = _Calls();
        await _pump(tester, host, e['id'] as int, links: calls.links());
        await _expand(tester, _titleOf(host, e));

        expect(find.text(row), findsOneWidget);
        expect(find.textContaining(name), findsOneWidget);
        await tester.tap(find.textContaining(name).first);
        await tester.pump();
        expect(calls.list, [call]);
      });
    }

    testWidgets('an old event without data.rule has no reason rows', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked());
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.text('Rule'), findsNothing);
      expect(find.textContaining('None — main flow'), findsNothing);
    });

    testWidgets('a renamed own rule shows its current name, not the one the event kept', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host, name: 'New name');
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(rule: {'kind': 'user', 'id': 'r1', 'name': 'Old name'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('New name'), findsOneWidget);
      expect(find.textContaining('Old name'), findsNothing);
    });

    testWidgets('a deleted rule (not in the catalog) shows the name from the event', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(rule: {'kind': 'user', 'id': 'r9', 'name': 'Gone'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('Gone'), findsOneWidget);
    });

    testWidgets('a rule the core could not name shows its raw text', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(rule: {'kind': 'unknown', 'text': 'raw-rule-text'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('raw-rule-text'), findsOneWidget);
    });

    testWidgets('a tap on a rule row leaves a return to the event (Back comes back to it)', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(rule: {'kind': 'user', 'id': 'r1', 'name': 'Streaming'}),
      );
      final calls = _Calls();
      final logs = await _pump(tester, host, e['id'] as int, links: calls.links());
      await _expand(tester, _titleOf(host, e));
      await tester.tap(find.textContaining('Streaming').first);
      await tester.pump();

      expect(calls.list, ['ruleForm:r1']);
      expect(logs.returnId, e['id']);
    });
  });

  group('events with an app (connect-model «Событие с приложением»)', () {
    // the links are wired (newRuleFor included), so a missing Create rule is the app's doing, not an unwired link
    testWidgets('an event with an app has no Create rule (blocked and unreachable)', (tester) async {
      for (final e0 in [
        ('blocked', _blocked(app: _pkg)),
        ('unreachable', _unreachable(app: _pkg)),
      ]) {
        final host = FakeCoreHost();
        _catalog(host);
        final e = host.addEvent('site', e0.$1, level: 'warn', at: _at(0), data: e0.$2);
        await _pump(tester, host, e['id'] as int, links: _Calls().links());
        expect(find.text('Create rule'), findsNothing, reason: 'site/${e0.$1} with an app');
      }
    });

    testWidgets('site/unreachable never has Create rule, with or without an app (no working target)', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent('site', 'unreachable', level: 'warn', at: _at(0), data: _unreachable());
      await _pump(tester, host, e['id'] as int, links: _Calls().links());
      expect(find.text('Create rule'), findsNothing);
    });

    testWidgets('an event without an app keeps Create rule; a tap opens the new-rule form for the host', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked());
      final calls = _Calls();
      await _pump(tester, host, e['id'] as int, links: calls.links());
      expect(find.text('Create rule'), findsOneWidget);
      await tester.tap(find.text('Create rule'));
      await tester.pump();
      expect(calls.list, ['newRule:blocked.example|-']);
    });

    testWidgets('the app rule that caught the host: its Rule row under App names it; a tap opens that rule', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _catalog(host);
      _appRules(
        host,
        rules: [
          UserRule(id: 'ar1', name: 'Telegram direct', enabled: true, action: 'direct', groups: _domain('blocked.example')),
        ],
      );
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(app: _pkg, rule: {'kind': 'appRule', 'app': _pkg, 'id': 'ar1', 'name': 'Telegram direct'}),
      );
      final calls = _Calls();
      await _pump(tester, host, e['id'] as int, links: calls.links());
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('Telegram direct'), findsOneWidget);
      expect(find.text('New rule for blocked.example'), findsNothing, reason: 'no duplicate: the rule exists');
      await tester.tap(find.textContaining('Telegram direct').first);
      await tester.pump();
      expect(calls.list, ['appRule:$_pkg|ar1|-|-']);
    });

    testWidgets('no rule of the app caught the host, but a disabled one with this host is there: its Rule row, no duplicate', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _catalog(host);
      _appRules(
        host,
        rules: [
          UserRule(id: 'ar1', name: 'Other site', enabled: true, action: 'direct', groups: _domain('other.example')),
          UserRule(id: 'ar2', name: 'Old direct', enabled: false, action: 'direct', groups: _domain('blocked.example')),
        ],
      );
      final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked(app: _pkg, rule: {'kind': 'final'}));
      final calls = _Calls();
      await _pump(tester, host, e['id'] as int, links: calls.links());
      await _expand(tester, _titleOf(host, e));

      expect(find.textContaining('Old direct'), findsOneWidget);
      expect(find.text('New rule for blocked.example'), findsNothing);
      await tester.tap(find.textContaining('Old direct').first);
      await tester.pump();
      expect(calls.list, ['appRule:$_pkg|ar2|-|-']);
    });

    // «New rule for <host>»: the form of a new app rule, Fallback through the node that opened the site; an
    // unreachable site has no such node, so the Fallback stays Default
    final newRuleCases = <(String, Map<String, dynamic>, String, String)>[
      ('blocked, opened through the entry', _blocked(app: _pkg, rule: {'kind': 'final'}), 'blocked.example', 'sub1'),
      (
        'blocked, opened through a node of the entry (viaTarget)',
        _blocked(app: _pkg, rule: {'kind': 'final'}, viaTarget: 'node:sub1::n2'),
        'blocked.example',
        'node:sub1::n2',
      ),
      ('unreachable', _unreachable(app: _pkg, rule: {'kind': 'final'}), 'dead.example', '-'),
    ];
    for (final (label, data, host0, via) in newRuleCases) {
      testWidgets('no app rule with this host: "New rule for $host0" opens a new app rule ($label)', (tester) async {
        final host = FakeCoreHost();
        _catalog(host);
        _appRules(
          host,
          rules: [
            UserRule(id: 'ar1', name: 'Other site', enabled: true, action: 'direct', groups: _domain('other.example')),
          ],
        );
        final e = host.addEvent('site', data.containsKey('viaServer') ? 'blocked' : 'unreachable', level: 'warn', at: _at(0), data: data);
        final calls = _Calls();
        await _pump(tester, host, e['id'] as int, links: calls.links());
        await _expand(tester, _titleOf(host, e));

        expect(find.text('New rule for $host0'), findsOneWidget);
        await tester.tap(find.text('New rule for $host0'));
        await tester.pump();
        expect(calls.list, ['appRule:$_pkg|-|$host0|$via']);
      });
    }

    testWidgets('the App row names the app; a tap opens that app\'s dialog', (tester) async {
      final host = FakeCoreHost()..apps = [const InstalledApp(pkg: _pkg, name: 'Telegram')];
      await host.installedApps(); // the list of installed apps is read at start (live_core_host), before any event
      _catalog(host);
      final e = host.addEvent('site', 'blocked', level: 'warn', at: _at(0), data: _blocked(app: _pkg, rule: {'kind': 'final'}));
      final calls = _Calls();
      await _pump(tester, host, e['id'] as int, links: calls.links());
      await _expand(tester, _titleOf(host, e));

      await tester.tap(find.text('Telegram').first);
      await tester.pump();
      expect(calls.list, ['appRule:$_pkg|-|-|-']);
    });
  });

  group('conflict between an app and a rule (connect-model «Конфликт приложение ↔ правило»)', () {
    testWidgets('the rule decided and the app has its own route: the App row says overridden by rule, the rule says applied', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      _appRules(host, tcp: AppHalf(act: 'direct'));
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(app: _pkg, rule: {'kind': 'user', 'id': 'r1', 'name': 'Streaming'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.text('overridden by rule'), findsOneWidget);
      expect(find.text('applied'), findsOneWidget);
    });

    testWidgets('the app has no own route: no overridden or applied label', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(app: _pkg, rule: {'kind': 'user', 'id': 'r1', 'name': 'Streaming'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.text('overridden by rule'), findsNothing);
      expect(find.text('applied'), findsNothing);
    });

    testWidgets('the app route decided: own rules that would catch the host say overridden by app; the App row says applied', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      _appRules(host, tcp: AppHalf(act: 'block'));
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(app: _pkg, rule: {'kind': 'app', 'id': _pkg, 'name': 'Telegram'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));

      expect(find.text('overridden by app'), findsOneWidget);
      expect(find.text('applied'), findsOneWidget);
    });

    testWidgets('the labels follow the current settings: once the app has no route the labels go', (tester) async {
      final host = FakeCoreHost();
      _catalog(host);
      _ownRule(host);
      _appRules(host, tcp: AppHalf(act: 'direct'));
      final e = host.addEvent(
        'site',
        'blocked',
        level: 'warn',
        at: _at(0),
        data: _blocked(app: _pkg, rule: {'kind': 'user', 'id': 'r1', 'name': 'Streaming'}),
      );
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));
      expect(find.text('overridden by rule'), findsOneWidget, reason: 'precondition: the route is set');

      host.catalog.appRules.remove(_pkg);
      await _pump(tester, host, e['id'] as int);
      await _expand(tester, _titleOf(host, e));
      expect(find.text('overridden by rule'), findsNothing);
      expect(find.text('applied'), findsNothing);
    });
  });
}
