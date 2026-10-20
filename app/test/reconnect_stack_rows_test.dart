// The reconnect stack in the Events feed (docs/logs.md «Повторы» 4, «Стопка переподключений»): adjacent
// reconnect rows (no other shown row between, at most 10 min from the last one) are one row, worded by the
// newest, with ×N and the time span; opened, every reconnect is its own line (oldest first); another kind of row
// between two reconnects splits them; a reconnect that joins an opened stack
// keeps it open and under the same key; a search hit inside a folded stack opens it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// The time of the n-th second of the test journal (an hour ago, so all of it is in the past).
int _at(int s) => DateTime.now().millisecondsSinceEpoch - 3600000 + s * 1000;

/// «HH:MM» of the n-th second of the journal, in local time as the row shows it.
String _hhmm(int s) {
  final d = DateTime.fromMillisecondsSinceEpoch(_at(s));
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// A `conn/reconnected` event of its own operation (`op {id, kind}`), as the core writes it.
Map<String, dynamic> _reconnect(
  FakeCoreHost host,
  int s, {
  String reason = 'lists',
  String kind = 'reconnect',
}) => host.addEvent(
  'conn',
  'reconnected',
  level: 'info',
  at: _at(s),
  data: {'reason': reason, 'tookMs': 800},
)..['op'] = {'id': 'r$s', 'kind': kind};

Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.byIcon(AppTab.logs.icon));
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

String _repeatsOnScreen(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('evRepeats'))).data!;

/// The rows of the Events feed as the controller folds them, over the whole journal.
Future<LogsController> _feed(WidgetTester tester, FakeCoreHost host) async {
  final c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
  c.start();
  c.setOnScreen(true);
  await tester.pump(const Duration(milliseconds: 600));
  return c;
}

void main() {
  group('the reconnect stack in LogsController.groups', () {
    testWidgets('adjacent reconnects are one stack row: members oldest first, worded by the newest, keyed by the first', (
      tester,
    ) async {
      final host = FakeCoreHost();
      final first = _reconnect(host, 0, reason: 'settings');
      final mid = _reconnect(host, 60, kind: 'connection');
      final last = _reconnect(host, 120, reason: 'lists');
      final c = await _feed(tester, host);
      try {
        expect(c.groups, hasLength(1));
        final g = c.groups.single;
        expect(g.isStack, isTrue);
        expect(g.stack, hasLength(3));
        expect(g.times, 3);
        expect([for (final m in g.stack) m.ev.id], [first['id'], mid['id'], last['id']]);
        expect(g.ev.id, last['id'], reason: 'the row is worded by the newest reconnect');
        expect(g.key, g.stack.first.key, reason: "the stack's key is its first member's");
      } finally {
        c.dispose();
      }
    });

    testWidgets('a reconnect joins while it is at most 10 min after the last one; 10 min and 1 s later it starts a row', (
      tester,
    ) async {
      for (final gap in [600, 601]) {
        final host = FakeCoreHost();
        _reconnect(host, 0);
        _reconnect(host, gap);
        final c = await _feed(tester, host);
        try {
          final joined = gap == 600;
          expect(c.groups, hasLength(joined ? 1 : 2), reason: 'gap $gap s');
          expect(c.groups.where((g) => g.isStack), hasLength(joined ? 1 : 0), reason: 'gap $gap s');
        } finally {
          c.dispose();
        }
      }
    });

    testWidgets('a row of another kind between two reconnects splits them into two rows', (tester) async {
      final host = FakeCoreHost();
      _reconnect(host, 0);
      host.addEvent(
        'site',
        'blocked',
        level: 'info',
        at: _at(30),
        data: const {'host': 'dead.example.com', 'via': 'nope', 'tried': []},
      );
      _reconnect(host, 60);
      final c = await _feed(tester, host);
      try {
        expect(c.groups, hasLength(3), reason: 'reconnect, the site row, reconnect');
        expect(c.groups.where((g) => g.isStack), isEmpty);
      } finally {
        c.dispose();
      }
    });
  });

  group('the reconnect stack on the Events page', () {
    testWidgets('folded: one row with ×3, worded by the newest; the others are not shown', (tester) async {
      final host = FakeCoreHost();
      _reconnect(host, 0, reason: 'settings');
      _reconnect(host, 60, reason: 'settings');
      _reconnect(host, 120, reason: 'lists');
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.textContaining('×3'), findsOneWidget);
      expect(find.text('Reconnected'), findsOneWidget, reason: 'the newest is a lists reconnect');
      expect(find.text('Reconnected · by you'), findsNothing, reason: 'the settings ones are inside the stack');
      expect(find.byKey(const ValueKey('evRepeats')), findsNothing);
    });

    testWidgets('opened: one line per reconnect, oldest first, the repeats line', (tester) async {
      final host = FakeCoreHost();
      _reconnect(host, 0, reason: 'settings');
      _reconnect(host, 60, reason: 'settings');
      _reconnect(host, 120, reason: 'lists');
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, 'Reconnected');

      final settings = find.text('Reconnected · by you');
      expect(settings, findsNWidgets(2), reason: 'one line per settings reconnect');
      final lists = find.text('Reconnected');
      expect(lists, findsNWidgets(2), reason: 'the row and the line of the lists reconnect');
      expect(tester.getTopLeft(settings.at(0)).dy, lessThan(tester.getTopLeft(settings.at(1)).dy),
          reason: 'the oldest first');
      expect(tester.getTopLeft(lists.last).dy, greaterThan(tester.getTopLeft(settings.last).dy),
          reason: 'the newest line is the last one');
      for (final s in [0, 60, 120]) {
        expect(find.textContaining(_hhmm(s)), findsWidgets, reason: 'the time of the reconnect at ${s}s');
      }
      expect(_repeatsOnScreen(tester), '3 times · from ${_hhmm(0)} to ${_hhmm(120)}');
    });

    testWidgets('a search that finds a reconnect inside a folded stack opens the stack', (tester) async {
      Future<void> search(WidgetTester tester, String q) async {
        await tester.tap(find.byKey(const ValueKey('logsSearch')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('evSearch')), matching: find.byType(TextField)),
          q,
        );
        await tester.pumpAndSettle();
      }

      final host = FakeCoreHost();
      _reconnect(host, 0, reason: 'settings');
      // non-head events of the operations: the only place the word below occurs (both rows match, so both stay)
      host.addEvent('user', 'pin', level: 'info', at: _at(1), data: const {'value': 'zzqtag'})
        ..['op'] = {'id': 'r0', 'kind': 'reconnect'};
      _reconnect(host, 60, reason: 'lists');
      host.addEvent('user', 'pin', level: 'info', at: _at(61), data: const {'value': 'zzqtag'})
        ..['op'] = {'id': 'r60', 'kind': 'reconnect'};
      await pumpApp(tester, host);
      await _openLogs(tester);
      expect(find.textContaining('×2'), findsOneWidget, reason: 'folded: one stack row of two');
      expect(find.byKey(const ValueKey('evRepeats')), findsNothing);

      // the hit is inside the first member (its pin), the other member does not match and is hidden
      await search(tester, 'zzqtag');
      expect(find.byKey(const ValueKey('evRepeats')), findsOneWidget, reason: 'the hit is inside: the stack is open');
    });

    testWidgets('a search that hits only the heads leaves the stack folded', (tester) async {
      final host = FakeCoreHost();
      _reconnect(host, 0, reason: 'lists');
      _reconnect(host, 60, reason: 'lists');
      await pumpApp(tester, host);
      await _openLogs(tester);
      await tester.tap(find.byKey(const ValueKey('logsSearch')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('evSearch')), matching: find.byType(TextField)),
        'reconnected',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('×2'), findsOneWidget);
      expect(find.byKey(const ValueKey('evRepeats')), findsNothing, reason: 'a hit on the heads does not open it');
    });

    testWidgets('an opened stack stays open when a reconnect joins it: same key, ×4, the new one is a line', (
      tester,
    ) async {
      final host = FakeCoreHost();
      _reconnect(host, 0, reason: 'settings');
      _reconnect(host, 60, reason: 'settings');
      _reconnect(host, 120, reason: 'lists');
      await pumpApp(tester, host);
      await _openLogs(tester);
      await _expand(tester, 'Reconnected');
      expect(_repeatsOnScreen(tester), startsWith('3 times'));

      final before = await _feed(tester, host);
      final keyBefore = before.groups.single.key;
      before.dispose();

      _reconnect(host, 300, reason: 'lists');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('×4'), findsOneWidget);
      expect(_repeatsOnScreen(tester), '4 times · from ${_hhmm(0)} to ${_hhmm(300)}', reason: 'still open');
      expect(find.text('Reconnected · by you'), findsNWidgets(2), reason: 'the settings lines are still there');

      final after = await _feed(tester, host);
      try {
        expect(after.groups.single.isStack, isTrue);
        expect(after.groups.single.key, keyBefore);
      } finally {
        after.dispose();
      }
    });
  });
}
