// Events in Logs (т1, «Строка в Logs → Events», «Свёртки», «По типам», «Тексты»): a row says what happened and
// why; consequences fold under their root; a closed pair is one row; a missing root gives a group row; the checks
// trail is folded past 8 steps; repeats are one row; the row's buttons follow the table; a search by a
// consequence opens its root. Phrases fixed by docs/logs.md «Тексты» are written out here as literals; the
// per-event titles that the doc leaves to the words are read from EventWords (the same words the row shows).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// The time of the n-th second of the test journal (a minute ago, so all of it is inside one window).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 60000 + s * 1000;

EventWords _words(FakeCoreHost host) =>
    EventWords(lookupAppLocalizations(const Locale('en')), host.catalog);

/// Adds an event to the journal, then sets the fields Sentinel writes on it (`verdict`, `why`, `cause`,
/// `opens`, `trail`, `op`).
Map<String, dynamic> _add(
  FakeCoreHost host,
  String cat,
  String type, {
  String level = 'warn',
  int s = 0,
  Map<String, dynamic> data = const {},
  Map<String, dynamic> fields = const {},
}) {
  final e = host.addEvent(cat, type, level: level, at: _at(s), data: data);
  for (final f in fields.entries) {
    e[f.key] = f.value;
  }
  return e;
}

EventRecord _rec(int id, {String cat = 'conn', String type = 'lost', Map<String, dynamic> extra = const {}}) {
  final m = <String, dynamic>{
    'id': id,
    'at': _at(0),
    'cat': cat,
    'type': type,
    'level': 'warn',
    'own': false,
    'data': <String, dynamic>{},
  };
  for (final f in extra.entries) {
    m[f.key] = f.value;
  }
  return EventRecord.fromJson(m);
}

/// The rows the Events page folds from the whole journal (no filter, no search).
List<EventGroup> _rows(FakeCoreHost host) =>
    foldEvents([for (final e in host.journal) EventRecord.fromJson(e)]);

/// The title a plain event shows as its own row.
String _titleOf(FakeCoreHost host, Map<String, dynamic> e) =>
    _words(host).describe(EventRecord.fromJson(e)).title;

Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.logs.icon));
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// A section heading of the opened row; the row may set it in capitals, so the case is not compared.
Finder _heading(String text) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').toLowerCase() == text.toLowerCase(),
  description: 'heading "$text"',
);

String _reasonOnScreen(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('evReason'))).data!;

Map<String, dynamic> _consequence(Object cause, String code) => {
  'cause': cause,
  'verdict': 'consequence',
  'why': {'code': code, 'params': <String, dynamic>{}},
};

/// A step of a checks trail: unknown codes read as the code itself, so each step is findable by it.
List<Map<String, dynamic>> _steps(int n, {int t0 = 0}) => [
  for (var i = 1; i <= n; i++)
    {
      'code': 'zz.step${i.toString().padLeft(2, '0')}',
      'params': <String, dynamic>{},
      'outcome': 'pass',
      'at': _at(0) + t0 + 100 * i,
    },
];

void main() {
  group('the reason line, by the verdict (docs/logs.md «Общие строки»)', () {
    Future<FakeCoreHost> shown(
      WidgetTester tester, {
      required String cat,
      required String type,
      required String level,
      required Map<String, dynamic> data,
      required Map<String, dynamic> fields,
    }) async {
      final host = FakeCoreHost();
      _add(host, cat, type, level: level, data: data, fields: fields);
      await pumpApp(tester, host);
      await _openLogs(tester);
      return host;
    }

    testWidgets('a blip: it recovered on its own', (tester) async {
      await shown(tester, cat: 'conn', type: 'lost', level: 'info', data: const {}, fields: const {
        'verdict': 'blip',
        'why': {'code': 'recovered', 'params': {'afterMs': 1200, 'by': 'net.restored'}},
      });
      expect(_reasonOnScreen(tester), startsWith('Recovered on its own'));
    });

    testWidgets('a workaround: it opens through another route', (tester) async {
      await shown(tester, cat: 'sub', type: 'failed', level: 'info', data: const {'name': 'Prov', 'error': 'boom'}, fields: const {
        'verdict': 'workaround',
        'why': {'code': 'workaround', 'params': {'by': 'proxy/Alpha'}},
      });
      expect(_reasonOnScreen(tester), startsWith('Opens through'));
    });

    testWidgets('an unexplained failure says the cause is not established', (tester) async {
      await shown(tester, cat: 'auto', type: 'unstable', level: 'warn', data: const {'id': 'e0', 'strikes': 2, 'holdMs': 60000}, fields: const {
        'verdict': 'unexplained',
        'why': {'code': 'why.unknown', 'params': {}},
      });
      expect(_reasonOnScreen(tester), 'Cause not established — see the checks');
    });

    test('an event nobody judged shows the reason of its type from data', () {
      final host = FakeCoreHost();
      final e = _rec(1, cat: 'sub', type: 'failed', extra: const {'data': {'name': 'Prov', 'error': 'certificate expired'}});
      // reasonOf = the reason itself; reasonLine drops it when the detail already says it (the row shows it once)
      expect(_words(host).reasonOf(e), contains('certificate expired'));
    });

    testWidgets('a consequence says "Cause: <title of the root>" when its root is hidden by the filter', (tester) async {
      final host = FakeCoreHost();
      final root = _add(host, 'conn', 'offline');
      final cons = _add(host, 'conn', 'lost', s: 1, fields: _consequence(root['id']!, 'net.offline'));
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, _titleOf(host, root));
      await tester.ensureVisible(find.byKey(const ValueKey('evHideType')));
      await tester.tap(find.byKey(const ValueKey('evHideType')));
      await tester.pumpAndSettle();

      expect(find.text(_titleOf(host, root)), findsNothing, reason: 'the root type is hidden');
      expect(find.text(_titleOf(host, cons)), findsOneWidget, reason: 'the consequence is a row of its own now');
      expect(_reasonOnScreen(tester), startsWith('Cause: No internet connection'));
    });
  });

  group('folds', () {
    testWidgets('a root says "+N related"; the consequences are no rows; the opened root has Related (N) with them', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final root = _add(host, 'conn', 'offline');
      _add(host, 'conn', 'lost', s: 1, fields: _consequence(root['id']!, 'net.offline'));
      _add(host, 'conn', 'lost', s: 2, fields: _consequence(root['id']!, 'net.offline'));
      await pumpApp(tester, host);
      await _openLogs(tester);

      final consTitle = _titleOf(host, host.journal[1]);
      expect(tester.widget<Text>(find.byKey(const ValueKey('evRelated'))).data, startsWith('+2 related'));
      expect(find.text(consTitle), findsNothing);
      expect(_heading('Related (2)'), findsNothing, reason: 'the list is for the opened row');

      await _expand(tester, _titleOf(host, root));
      expect(_heading('Related (2)'), findsOneWidget);
      expect(find.text(consTitle), findsWidgets);
    });

    testWidgets('a new consequence changes only the counter: the root stays where it is in the feed', (tester) async {
      final host = FakeCoreHost();
      final root = _add(host, 'conn', 'offline');
      _add(host, 'conn', 'lost', s: 1, fields: _consequence(root['id']!, 'net.offline'));
      _add(host, 'auto', 'unstable', s: 2, data: const {'id': 'e0', 'strikes': 2, 'holdMs': 60000});
      await pumpApp(tester, host);
      await _openLogs(tester);
      final rootTitle = find.text(_titleOf(host, root));
      final before = tester.getTopLeft(rootTitle);
      expect(tester.widget<Text>(find.byKey(const ValueKey('evRelated'))).data, startsWith('+1 related'));

      _add(host, 'conn', 'lost', s: 3, fields: _consequence(root['id']!, 'net.offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.widget<Text>(find.byKey(const ValueKey('evRelated'))).data, startsWith('+2 related'));
      expect(tester.getTopLeft(rootTitle), before);
    });

    testWidgets('a closed pair: the opener row says Finished at … · lasted …, the colour of "resolved"; the closer is a row of its own', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final opener = _add(host, 'conn', 'lost');
      _add(host, 'conn', 'restored', level: 'info', s: 60, fields: {'opens': opener['id']});
      _add(host, 'conn', 'lost', s: 61, fields: const {}); // a later, still open pair of the same type
      await pumpApp(tester, host);
      await _openLogs(tester);

      final rows = _rows(host);
      expect(rows, hasLength(3), reason: 'the opener, the closer (its own row) and the later open one');
      expect(rows.first.closedById, host.journal[1]['id']);
      expect(rows[1].opensId, opener['id']);
      final closed = find.byKey(const ValueKey('evClosed'));
      expect(closed, findsOneWidget, reason: 'only the pair that ended has the status');
      final text = tester.widget<Text>(find.descendant(of: closed, matching: find.byType(Text)));
      expect(text.data, matches(RegExp(r'^Finished at \d\d:\d\d · lasted .+')));
      final c = tester.element(closed).colors;
      expect(text.style?.color, c.active);
      expect(text.style?.color, isNot(c.warn));
      expect(find.text(_titleOf(host, host.journal[1])), findsOneWidget, reason: 'the closer has a row of its own');
      expect(find.text('Check now'), findsOneWidget, reason: 'only the open one can still be checked');
    });

    testWidgets('a closer whose opener left the journal is a row of its own', (tester) async {
      final host = FakeCoreHost();
      final closer = _add(host, 'conn', 'restored', level: 'info', fields: const {'opens': 987654});
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text(_titleOf(host, closer)), findsOneWidget);
    });

    testWidgets('consequences of a root that is not in the journal are one group row per code, no root needed', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _add(host, 'sub', 'failed', data: const {'name': 'Prov', 'error': 'boom'}, fields: _consequence(9999, 'net.captive'));
      _add(host, 'conn', 'lost', s: 1, fields: _consequence(9999, 'net.captive'));
      _add(host, 'conn', 'failing', s: 2, data: const {'app': 'org.x.app'}, fields: _consequence(9999, 'net.offline'));
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text('The network requires sign-in (login page) · events: 2'), findsOneWidget);
      expect(find.text(_titleOf(host, host.journal[1])), findsNothing, reason: 'its events are inside the group');
      expect(_rows(host).where((g) => g.isGroup), hasLength(2), reason: 'net.captive and net.offline are two groups');
    });

    testWidgets('three identical failures are one row: ×3, and the opened one lists the repeats', (tester) async {
      final host = FakeCoreHost();
      for (var s = 0; s < 3; s++) {
        _add(host, 'sub', 'failed', s: s * 10, data: const {'name': 'Prov', 'error': 'boom'});
      }
      await pumpApp(tester, host);
      await _openLogs(tester);

      final title = _words(host).describeGroup(_rows(host).single).$1;
      expect(find.textContaining('×3'), findsOneWidget);
      expect(_heading('Repeats'), findsNothing);
      await _expand(tester, title);
      expect(_heading('Repeats'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('evRepeats'))).data,
        matches(RegExp(r'^3 times · from \d\d:\d\d to \d\d:\d\d$')),
      );
    });
  });

  group('operations: one row with the result of the operation', () {
    Map<String, dynamic> op(String id, String kind) => {'op': {'id': id, 'kind': kind}};

    testWidgets('subscriptions updated together: "Subscriptions updated: N of M", the events inside are no rows', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final f = op('all', 'subUpdateAll');
      _add(host, 'sub', 'updated', level: 'info', data: const {'source': 's1', 'name': 'Alpha', 'added': 1, 'removed': 0, 'total': 5}, fields: f);
      _add(host, 'sub', 'updated', level: 'info', s: 1, data: const {'source': 's2', 'name': 'Beta', 'added': 0, 'removed': 1, 'total': 4}, fields: f);
      _add(host, 'sub', 'failed', s: 2, data: const {'source': 's3', 'name': 'Gamma', 'error': 'boom'}, fields: f);
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text('Subscriptions updated: 2 of 3'), findsOneWidget);
      expect(find.textContaining('Alpha'), findsNothing, reason: 'the subscriptions are inside');
    });

    testWidgets('an app update is worded by its last stage', (tester) async {
      final host = FakeCoreHost();
      final f = op('u1', 'appUpdate');
      _add(host, 'core', 'updateAvailable', level: 'info', data: const {'version': '1.2'}, fields: f);
      _add(host, 'core', 'updateDownloaded', level: 'info', s: 10, data: const {'version': '1.2'}, fields: f);
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text('Update 1.2: downloaded'), findsOneWidget);
      expect(find.text('Update 1.2: available'), findsNothing);

      _add(host, 'core', 'updateInstalled', level: 'info', s: 20, data: const {'version': '1.2'}, fields: f);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Update 1.2: installed'), findsOneWidget);
      expect(find.text('Update 1.2: downloaded'), findsNothing);
    });

    testWidgets('a reconnect: the row is the result; the user action that started it is its cause, not a row', (tester) async {
      final host = FakeCoreHost();
      final f = op('r', 'reconnect');
      final user = _add(host, 'user', 'mode', level: 'info', data: const {'value': 'proxy'}, fields: f)..['own'] = true;
      _add(host, 'conn', 'reconnected', level: 'info', s: 1, data: const {'reason': 'lists', 'tookMs': 800}, fields: {...f, 'cause': user['id']});
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text(_titleOf(host, host.journal[1])), findsOneWidget);
      expect(_titleOf(host, host.journal[1]), startsWith('Reconnected'));
      expect(find.text(_titleOf(host, user)), findsNothing);
    });
  });

  group('the checks trail', () {
    testWidgets('the opened row has Checks; more than 8 steps are the first 3, "N more" and the last 3', (tester) async {
      final host = FakeCoreHost();
      _add(host, 'conn', 'lost', fields: {'trail': _steps(12)});
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(_heading('Checks'), findsNothing);
      await _expand(tester, _titleOf(host, host.journal.single));

      expect(_heading('Checks'), findsOneWidget);
      for (final n in [1, 2, 3, 10, 11, 12]) {
        expect(find.textContaining('zz.step${n.toString().padLeft(2, '0')}'), findsOneWidget, reason: 'step $n');
      }
      for (var n = 4; n <= 9; n++) {
        expect(find.textContaining('zz.step0$n'), findsNothing, reason: 'step $n is folded');
      }
      expect(find.textContaining('6 more'), findsOneWidget);
    });

    test('3 + "N more" + 3 past 8 steps; exactly 8 are all shown', () {
      final w = _words(FakeCoreHost());
      final rows = w.trailRows(_rec(1, extra: {'trail': _steps(12)}));
      expect(rows, hasLength(7));
      expect([for (final i in [0, 1, 2, 4, 5, 6]) rows[i].text.contains('zz.step')], everyElement(isTrue));
      expect(rows[2].text, contains('zz.step03'));
      expect(rows[3].text, contains('6 more'));
      expect(rows[4].text, contains('zz.step10'));
      expect(rows[6].text, contains('zz.step12'));
      expect(w.trailRows(_rec(1, extra: {'trail': _steps(8)})), hasLength(8));
    });

    test('a step reads ✓ pass, ✗ fail, ? inconclusive, · info; its time counts from the first step', () {
      final t0 = _at(0);
      Map<String, dynamic> step(String code, String outcome, int at) =>
          {'code': code, 'params': <String, dynamic>{}, 'outcome': outcome, 'at': at};
      final rows = _words(FakeCoreHost()).trailRows(_rec(1, extra: {
        'trail': [
          step('zz.a', 'pass', t0),
          step('zz.b', 'fail', t0 + 1200),
          step('zz.c', 'inconclusive', t0 + 1500),
          step('zz.d', 'info', t0 + 2000),
        ],
      }));
      expect([for (final r in rows) r.mark], ['✓', '✗', '?', '·']);
      expect(rows[1].at, '+1.2 s');
    });
  });

  group('the buttons of the table «По типам»', () {
    testWidgets('Check now on a lost connection checks the round through the host', (tester) async {
      final host = FakeCoreHost();
      final e = _add(host, 'conn', 'lost');
      await pumpApp(tester, host);
      await _openLogs(tester);
      await tester.tap(find.text('Check now'));
      await tester.pump();
      expect(host.checkedNow, [e['id']]);
    });

    testWidgets('Retry on a failed rule list retries its lists through the host', (tester) async {
      final host = FakeCoreHost();
      final e = _add(host, 'rules', 'ruleSetFailed', data: const {'tag': 'geo'});
      await pumpApp(tester, host);
      await _openLogs(tester);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(host.retriedRuleSets, [e['id']]);
    });

    testWidgets('Network settings on an offline event opens the network settings through the host', (tester) async {
      final host = FakeCoreHost();
      _add(host, 'conn', 'offline');
      await pumpApp(tester, host);
      await _openLogs(tester);
      await tester.tap(find.text('Network settings'));
      await tester.pump();
      expect(host.networkSettingsOpened, 1);
    });

    testWidgets('a failed DNS server offers Check now and Open, and no switch of server', (tester) async {
      final host = FakeCoreHost();
      _add(host, 'dns', 'failed', data: const {'server': 'Cloudflare', 'side': 'vpn'});
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text('Check now'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Switch server'), findsNothing);
    });

    testWidgets('a check that is running reads Checking… and does nothing; a finished one gives the button back', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _add(host, 'conn', 'lost', data: const {'recheck': {'state': 'pending'}});
      _add(host, 'dns', 'failed', s: 1, data: const {'server': 'Cloudflare', 'side': 'vpn', 'recheck': {'state': 'fail'}});
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.text('Check now'), findsOneWidget, reason: 'the other event: its check is over');
      await tester.tap(find.text('Checking…'));
      await tester.pump();
      expect(host.checkedNow, isEmpty);
    });

    for (final type in ['blocked', 'unreachable']) {
      testWidgets('site/$type: the folded row holds Check with checker, Create rule, Ignore site; Copy site only in the opened row', (
        tester,
      ) async {
        final host = FakeCoreHost();
        final e = _add(host, 'site', type, data: const {'host': 'dead.example.com', 'via': 'nope', 'tried': []});
        await pumpApp(tester, host);
        await _openLogs(tester);

        for (final b in ['Check with checker', 'Create rule', 'Ignore site']) {
          expect(find.text(b), findsOneWidget, reason: b);
        }
        expect(find.text('Copy site'), findsNothing);
        await _expand(tester, _titleOf(host, e));
        expect(find.text('Copy site'), findsOneWidget);
      });
    }
  });

  group('search and filter over the folded journal', () {
    testWidgets('a search by a consequence finds its root and opens it', (tester) async {
      final host = FakeCoreHost();
      final root = _add(host, 'conn', 'offline');
      final cons = _add(host, 'conn', 'lost', s: 1, fields: _consequence(root['id']!, 'net.offline'));
      _add(host, 'auto', 'unstable', s: 2, data: const {'id': 'e0', 'strikes': 2, 'holdMs': 60000});
      await pumpApp(tester, host);
      await _openLogs(tester);

      await tester.tap(find.byKey(const ValueKey('logsSearch')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('evSearch')), matching: find.byType(TextField)),
        _titleOf(host, cons).toLowerCase(),
      );
      await tester.pumpAndSettle();

      expect(find.text(_titleOf(host, root)), findsOneWidget, reason: 'the root is kept');
      expect(find.textContaining('is unstable'), findsNothing);
      expect(_heading('Related (1)'), findsOneWidget, reason: 'the row is open: the hit is inside');
      expect(find.text(_titleOf(host, cons)), findsWidgets);
    });
  });

  group('texts through EventWords', () {
    test('net/switched names both networks with provider and operator, and the time without network', () {
      final e = _rec(1, cat: 'net', type: 'switched', extra: const {
        'data': {
          'from': {'type': 'wifi', 'provider': 'ISP'},
          'to': {'type': 'mobile', 'operator': 'operator'},
          'downMs': 3000,
        },
      });
      final text = _words(FakeCoreHost()).describe(e);
      // the case of "mobile" is not fixed by the spec
      expect(
        '${text.title} ${text.detail}'.toLowerCase(),
        contains('network switched: wi-fi (isp) → mobile (operator) · no network for 3 s'),
      );
    });

    test('net/switched without a provider or operator names only the types', () {
      final e = _rec(1, cat: 'net', type: 'switched', extra: const {
        'data': {'from': {'type': 'wifi'}, 'to': {'type': 'mobile'}},
      });
      final text = _words(FakeCoreHost()).describe(e);
      final s = '${text.title} ${text.detail}'.toLowerCase();
      expect(s, contains('network switched: wi-fi → mobile'));
      expect(s, isNot(contains('(')));
      expect(s, isNot(contains('no network')));
    });

    test('closedLine, relatedLine and repeatsLine', () {
      final words = _words(FakeCoreHost());
      final pair = foldEvents([_rec(1), _rec(2, type: 'restored', extra: const {'opens': 1, 'level': 'info'})]).first;
      expect(words.closedLine(pair), matches(RegExp(r'^Finished at \d\d:\d\d · lasted .+')));
      final repeats = foldEvents([
        for (var i = 0; i < 3; i++) _rec(10 + i, cat: 'sub', type: 'failed', extra: const {'data': {'name': 'P'}}),
      ]).single;
      expect(words.repeatsLine(repeats), matches(RegExp(r'^3 times · from \d\d:\d\d to \d\d:\d\d$')));
      final root = foldEvents([_rec(1, type: 'offline'), _rec(2, extra: _consequence(1, 'net.offline'))]).single;
      expect(words.relatedLine(root), startsWith('+1 related'));
      expect(words.relatedLine(pair), isNull);
    });
  });
}
