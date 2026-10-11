// The Logs screen: one header on both tabs (filter with a badge, search, ⋮), the Raw filter sheet
// and its status line, search per tab, and what a list does while lines arrive: only the group
// that changed is rebuilt, and a list scrolled up keeps the row in view where it is.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/log_parts.dart'
    show RawGroupView, groupRaw, rawGroupMax;
import 'package:jormungand_core/jormungand_core.dart' show LogLine;

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

const _conn =
    '[1 5ms] inbound/mixed[mixed-in]: inbound connection to example.com:443';
const _t0 = 1700000000000;

Future<void> _openLogs(WidgetTester tester, {bool raw = false}) async {
  await tester.tap(find.byIcon(AppTab.logs.icon));
  await tester.pumpAndSettle();
  if (raw) {
    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
  }
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

/// The scroll position of the Raw list (the last list view of the page).
ScrollPosition _rawPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// The number of the first line of the topmost group that shows in the Raw list and where its top is.
(int, double) _topRow(
  WidgetTester tester, {
  bool Function(RawGroupView g)? where,
}) {
  final list = tester.getTopLeft(find.byType(CustomScrollView).last).dy;
  int? n;
  var best = double.infinity;
  for (final e in find.byType(RawGroupView).evaluate()) {
    if (where != null && !where(e.widget as RawGroupView)) continue;
    final box = e.renderObject! as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    if (top + box.size.height > list + 1 && top < best) {
      best = top;
      n = (e.widget as RawGroupView).group.lines.first.n;
    }
  }
  return (n!, best);
}

Finder _group(int n) => find.byWidgetPredicate(
  (w) => w is RawGroupView && w.group.lines.first.n == n,
);

void main() {
  testWidgets(
    'the header is the same on both tabs: filter, search, ⋮; nothing loose',
    (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'lost', level: 'warn');
      host.addLogLine('router: matched rule');
      await pumpApp(tester, host);
      await _openLogs(tester);

      void same() {
        expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
        expect(find.byKey(const ValueKey('logsSearch')), findsOneWidget);
        expect(find.byKey(const ValueKey('logsMenu')), findsOneWidget);
        expect(find.byIcon(Icons.copy), findsNothing, reason: 'Copy is gone');
        expect(
          find.byIcon(Icons.file_download_outlined),
          findsNothing,
          reason: 'Download is in the menu',
        );
        expect(
          find.byIcon(Icons.delete_outline),
          findsNothing,
          reason: 'Clear is in the menu',
        );
      }

      same();
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      same();
    },
  );

  testWidgets(
    '⋮: Clear (of the tab), Download log, Send report; no Copy, no Ignored sites',
    (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'lost', level: 'warn');
      host.addLogLine('router: matched rule');
      await pumpApp(tester, host);
      await _openLogs(tester);

      await tester.tap(find.byKey(const ValueKey('logsMenu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('logsClear')), findsOneWidget);
      expect(find.text('Clear events'), findsOneWidget);
      expect(find.text('Download log'), findsOneWidget);
      expect(find.text('Send report'), findsOneWidget);
      expect(
        find.text('Ignored sites'),
        findsNothing,
        reason: 'it lives in the filter sheets',
      );
      expect(find.text('Copy all'), findsNothing);

      // Events: Clear asks first
      await tester.tap(find.text('Clear events'));
      await tester.pumpAndSettle();
      expect(find.text('Clear events?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains('clearEvents')));

      // Raw: the row names the tab and clears at once
      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      expect(find.text('router: matched rule'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('logsMenu')));
      await tester.pumpAndSettle();
      expect(find.text('Clear raw log'), findsOneWidget);
      expect(find.text('Clear events'), findsNothing);
      await tester.tap(find.text('Clear raw log'));
      await tester.pumpAndSettle();
      expect(host.calls, contains('clearLog'));
      expect(find.text('router: matched rule'), findsNothing);

      // Send report opens its sheet
      await tester.tap(find.byKey(const ValueKey('logsMenu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('logsSendReport')));
      await tester.pumpAndSettle();
      expect(
        find.text('Send report'),
        findsNWidgets(2),
        reason: 'the sheet: its title and the button',
      );
      expect(find.byType(TextField), findsOneWidget, reason: 'the note');
    },
  );

  testWidgets(
    'Raw: the status line counts lines and what the core left out; the filter sheet switches it',
    (tester) async {
      final host = FakeCoreHost();
      host.addLogLine(_conn);
      host.addLogLine(_conn);
      host.addLogLine('router: matched rule');
      await pumpApp(tester, host);
      await _openLogs(tester, raw: true);

      expect(find.byKey(const ValueKey('rawStatus')), findsOneWidget);
      String statusLines() => tester
          .widget<Text>(find.byKey(const ValueKey('rawStatusLines')))
          .data!;
      expect(statusLines(), '1 line');
      expect(find.text('Connections hidden (2)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('logsFilterBadge')),
        findsNothing,
        reason: 'nothing is set',
      );

      // a tap on the hidden count opens the filter
      await tester.tap(find.byKey(const ValueKey('rawStatusHidden')));
      await tester.pumpAndSettle();
      expect(find.text('Filter log'), findsOneWidget);
      expect(
        find.text(
          'Successful connections and DNS answers: one line each, thousands per minute. Hidden by default; failed connections are always shown.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('rawFilterReset')),
        findsNothing,
        reason: 'nothing to reset',
      );
      await tester.tap(find.byKey(const ValueKey('rawConns')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rawFilterReset')), findsOneWidget);
      await _closeSheet(tester);

      expect(statusLines(), '3 lines');
      expect(find.textContaining('Connections hidden'), findsNothing);
      expect(find.text(_conn), findsNWidgets(2));
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('logsFilterBadge')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '1',
      );
      expect(host.logPageCalls.last, (since: null, conns: true));

      // Reset: back to the default, the connections are left out again
      await tester.tap(find.byIcon(Icons.filter_alt_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rawFilterReset')));
      await tester.pumpAndSettle();
      await _closeSheet(tester);
      expect(find.text('Connections hidden (2)'), findsOneWidget);
      expect(find.text(_conn), findsNothing);
    },
  );

  testWidgets(
    'Raw filter sheet: Ignored sites is a separate setting, outside the count and Reset',
    (tester) async {
      final host = FakeCoreHost();
      host.notif.ignoredSites = ['dead.example.com'];
      host.addLogLine(_conn);
      host.addLogLine('router: matched rule');
      await pumpApp(tester, host);
      await _openLogs(tester, raw: true);

      await tester.tap(find.byIcon(Icons.filter_alt_outlined));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ignoredSitesRow')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rawFilterReset')),
        findsNothing,
        reason: 'the row is no filter setting',
      );
      await tester.tap(find.byKey(const ValueKey('rawConns')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rawFilterReset')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rawFilterReset')));
      await tester.pumpAndSettle();
      expect(host.notif.ignoredSites, [
        'dead.example.com',
      ], reason: 'Reset leaves the list alone');
      expect(find.byKey(const ValueKey('ignoredSitesRow')), findsOneWidget);
      await _closeSheet(tester);
      expect(find.byKey(const ValueKey('logsFilterBadge')), findsNothing);
    },
  );

  test(
    'groupRaw: a run of one second is cut into groups of 24; only the last one changes as lines come',
    () {
      LogLine line(int n, {int sec = 5}) => LogLine(
        n: n,
        t: _t0 + sec * 1000 + n,
        src: 'sing-box',
        lvl: 'info',
        msg: 'm$n',
      );
      expect(rawGroupMax, 24);
      final lines = [for (var i = 1; i <= 60; i++) line(i)];
      var g = groupRaw(lines);
      expect(g.map((e) => e.lines.length), [24, 24, 12]);
      expect(g.map((e) => e.first.n), [1, 25, 49]);

      lines.addAll([for (var i = 61; i <= 70; i++) line(i)]);
      g = groupRaw(lines);
      expect(g.map((e) => e.lines.length), [24, 24, 22]);
      expect(g.map((e) => e.first.n), [
        1,
        25,
        49,
      ], reason: 'the first groups keep their numbers');

      lines.add(line(71, sec: 6));
      g = groupRaw(lines);
      expect(g.length, 4, reason: 'another second starts a new group');
      expect(g.last.lines.single.n, 71);
    },
  );

  testWidgets('Raw: 70 lines of one second still render, down to the last', (
    tester,
  ) async {
    final host = FakeCoreHost();
    for (var i = 0; i < 70; i++) {
      host.addLogLine('same second $i', t: _t0 + i);
    }
    await pumpApp(tester, host);
    await _openLogs(tester, raw: true);
    final pos = _rawPosition(tester);
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('same second 69', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Raw sheet and status line fit 320 dp at 120 % text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final host = FakeCoreHost();
    host.addLogLine(_conn);
    host.addLogLine('router: matched rule');
    await pumpApp(tester, host);
    await _openLogs(tester, raw: true);
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow');
    await _closeSheet(tester);
    expect(find.byKey(const ValueKey('rawStatus')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search is on each tab: it filters the events and the lines, and closing clears it',
    (tester) async {
      final host = FakeCoreHost();
      host.addEvent('conn', 'lost', level: 'warn');
      host.addEvent(
        'auto',
        'unstable',
        level: 'warn',
        data: {'id': 'e0', 'strikes': 2, 'holdMs': 60000},
      );
      host.addLogLine('router: matched rule');
      host.addLogLine('dns: resolved example.org');
      await pumpApp(tester, host);
      await _openLogs(tester);

      expect(find.text('Connection lost'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('logsSearch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('evSearch')), findsOneWidget);
      expect(find.text('Search events'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('evSearch')),
          matching: find.byType(TextField),
        ),
        'lost',
      );
      await tester.pumpAndSettle();
      expect(find.text('Connection lost'), findsWidgets);
      expect(find.textContaining('is unstable'), findsNothing);
      // the badge counts the filter settings; the search is the button's own highlight
      expect(find.byKey(const ValueKey('logsFilterBadge')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('evSearch')),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('evSearch')), findsNothing);
      expect(
        find.textContaining('is unstable'),
        findsWidgets,
        reason: 'the search was cleared with the field',
      );

      await tester.tap(find.text('Raw'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('evSearch')),
        findsNothing,
        reason: 'Raw has a search of its own',
      );
      await tester.tap(find.byKey(const ValueKey('logsSearch')));
      await tester.pumpAndSettle();
      expect(find.text('Search the log'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('rawSearch')),
          matching: find.byType(TextField),
        ),
        'dns',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('resolved example.org', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('router: matched rule'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('logsSearch')));
      await tester.pumpAndSettle();
      expect(find.text('router: matched rule'), findsOneWidget);
    },
  );

  testWidgets(
    'a batch of lines rebuilds the group it touched, not the visible rows again',
    (tester) async {
      final host = FakeCoreHost();
      for (var i = 0; i < 200; i++) {
        host.addLogLine('L$i', t: _t0 + i * 1000);
      }
      await pumpApp(tester, host);
      await _openLogs(tester, raw: true);
      expect(find.byType(RawGroupView), findsWidgets);

      var built = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is RawGroupView) built++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      host.addLogLine('L200', t: _t0 + 200 * 1000);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('L200', findRichText: true),
        findsOneWidget,
        reason: 'the list follows the end',
      );
      expect(
        built,
        inInclusiveRange(1, 2),
        reason:
            'the new group (and at most its neighbour), not the ~10 in view',
      );

      // a row read mark changing is no reason to rebuild them either
      built = 0;
      for (var i = 0; i < 5; i++) {
        host.addLogLine('M$i', t: _t0 + (201 + i) * 1000);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump();
      }
      expect(built, lessThanOrEqualTo(10), reason: 'one new group per batch');
    },
  );

  testWidgets(
    'scrolled up: new lines only grow the pill, a trimmed head does not move the row in view',
    (tester) async {
      final host = FakeCoreHost();
      // the core keeps 5500 lines: 5600 are trimmed to that on the first read
      for (var i = 0; i < 5600; i++) {
        host.addLogLine('L$i', t: _t0 + i * 1000);
      }
      await pumpApp(tester, host);
      await _openLogs(tester, raw: true);

      final pos = _rawPosition(tester);
      pos.jumpTo(pos.pixels - 20000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final target = tester
          .widget<RawGroupView>(find.byType(RawGroupView).at(2))
          .group
          .lines
          .first
          .n;
      final y0 = tester.getTopLeft(_group(target)).dy;
      expect(find.textContaining('↓ Latest'), findsOneWidget);

      // 300 more lines: the head of the 5500 falls off
      for (var i = 0; i < 300; i++) {
        host.addLogLine('N$i', t: _t0 + (5600 + i) * 1000);
      }
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_group(target), findsOneWidget);
      expect(
        tester.getTopLeft(_group(target)).dy,
        closeTo(y0, 1),
        reason: 'the row did not move',
      );
      expect(find.text('↓ 300 new'), findsOneWidget);

      // again: the head keeps falling off
      for (var i = 0; i < 100; i++) {
        host.addLogLine('P$i', t: _t0 + (5900 + i) * 1000);
      }
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getTopLeft(_group(target)).dy, closeTo(y0, 1));
      expect(find.text('↓ 400 new'), findsOneWidget);
    },
  );

  testWidgets('Connections on: the lines come in between, the row in view stays', (
    tester,
  ) async {
    final host = FakeCoreHost();
    for (var i = 0; i < 900; i++) {
      host.addLogLine(i % 3 == 0 ? _conn : 'L$i', t: _t0 + i * 1000);
    }
    await pumpApp(tester, host);
    await _openLogs(tester, raw: true);

    final pos = _rawPosition(tester);
    pos.jumpTo(pos.pixels - 6000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // the lines come in between the rows: what is held is the topmost one in view
    final (target, y0) = _topRow(tester);

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    await _closeSheet(tester);
    expect(_group(target), findsOneWidget);
    expect(tester.getTopLeft(_group(target)).dy, closeTo(y0, 1));
    expect(
      find.text(_conn),
      findsWidgets,
      reason: 'the connection lines are there',
    );

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    await _closeSheet(tester);
    expect(
      tester.getTopLeft(_group(target)).dy,
      closeTo(y0, 1),
      reason: 'and off again',
    );

    // on, then a bit up so that a connection line is the topmost: off holds the row that stays
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    await _closeSheet(tester);
    final pos2 = _rawPosition(tester);
    for (var step = 0; step < 40; step++) {
      pos2.jumpTo(pos2.pixels - 5);
      await tester.pump();
      final (n, _) = _topRow(tester);
      final top = find
          .byType(RawGroupView)
          .evaluate()
          .map((e) => e.widget as RawGroupView)
          .firstWhere((g) => g.group.lines.first.n == n);
      if (top.group.lines.first.isConn) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
    final (keep, y1) = _topRow(
      tester,
      where: (g) => !g.group.lines.first.isConn,
    );

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rawConns')));
    await tester.pumpAndSettle();
    await _closeSheet(tester);
    expect(find.text(_conn), findsNothing);
    expect(
      tester.getTopLeft(_group(keep)).dy,
      closeTo(y1, 1),
      reason: 'the topmost row that is still there is held',
    );
  });

  testWidgets(
    'In raw log: the line is brought into view in a list far from it',
    (tester) async {
      final host = FakeCoreHost();
      for (var i = 0; i < 800; i++) {
        host.addLogLine('L$i', t: _t0 + i * 1000);
      }
      host.addEvent('conn', 'lost', level: 'warn', log: 120);
      await pumpApp(tester, host);
      await _openLogs(tester);

      if (find.text('In raw log').evaluate().isEmpty) {
        await tester.tap(find.text('Connection lost').first);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('In raw log'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      final line = find.textContaining('L120', findRichText: true);
      expect(line, findsOneWidget);
      final y = tester.getCenter(line).dy;
      expect(
        y,
        inInclusiveRange(150, 500),
        reason: 'about the middle of the viewport',
      );
    },
  );

  testWidgets('Raw: a long press on a group copies its text and says Copied', (
    tester,
  ) async {
    final host = FakeCoreHost();
    host.addLogLine('router: matched rule');
    host.addLogLine('router: second line');
    await pumpApp(tester, host);
    await _openLogs(tester, raw: true);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.longPress(find.text('router: matched rule'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, contains('router: matched rule'));
    expect(find.text('Copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
