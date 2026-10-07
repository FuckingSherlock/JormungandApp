// LogsController: what it costs while the Logs tab is not on screen, and that a burst is one
// read. The host is a fake that counts what the controller asks of the core and how many
// listeners the raw line stream has.
import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/l10n/l10n.dart';

import 'fake_core_host.dart';

class _CountingHost extends FakeCoreHost {
  int eventReads = 0, logReads = 0, lineListeners = 0;
  final _lines = StreamController<Map<String, dynamic>>.broadcast();

  _CountingHost() {
    _lines.onListen = () {
      lineListeners++;
    };
    _lines.onCancel = () {
      lineListeners--;
    };
  }

  @override
  Map<String, dynamic> eventsPage({int? since}) {
    eventReads++;
    return super.eventsPage(since: since);
  }

  @override
  Map<String, dynamic> logPage({int? since}) {
    logReads++;
    return super.logPage(since: since);
  }

  @override
  Stream<Map<String, dynamic>> get logLines => _lines.stream;

  @override
  Map<String, dynamic> addLogLine(String msg, {String lvl = 'info', String src = 'sing-box', int? t}) {
    final l = super.addLogLine(msg, lvl: lvl, src: src, t: t);
    _lines.add(l);
    return l;
  }

  void resetCounts() => eventReads = logReads = 0;
}

void main() {
  late _CountingHost host;
  late LogsController c;
  var notified = 0;

  Future<void> start(WidgetTester tester) async {
    host = _CountingHost();
    c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    notified = 0;
    c.addListener(() => notified++);
    c.start();
    await tester.pump();
    host.resetCounts();
  }

  Future<void> wait(WidgetTester tester, [int ms = 400]) => tester.pump(Duration(milliseconds: ms));

  // the controller's timers must be gone before the test ends
  void it(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          c.dispose();
        }
      });

  it('a burst of lines and events is one read per list, after the debounce, not one per line', (tester) async {
    await start(tester);
    c.setOnScreen(true);
    await wait(tester);
    host.resetCounts();
    for (var i = 0; i < 50; i++) {
      host.addLogLine('line $i');
    }
    host.addEvent('conn', 'lost', level: 'warn');
    host.addEvent('conn', 'restored');
    await tester.pump(const Duration(milliseconds: 100));
    expect([host.eventReads, host.logReads], [0, 0], reason: 'still gathering the burst');
    await wait(tester, 300);
    expect([host.eventReads, host.logReads], [1, 1]);
    expect(c.raw.lines.length, 50);
    expect(c.feed.list.length, 2);

    host.addLogLine('one more');
    await wait(tester);
    expect(c.raw.lines.length, 51, reason: 'the next burst is read too');
  });

  it('while the Logs tab is not on screen: no line stream, no raw read, the controller\'s listeners hear nothing; events and the dot keep working', (tester) async {
    await start(tester);
    expect(host.lineListeners, 0);
    final dots = <({bool error, bool warn})>[];
    c.unseenNotifier.addListener(() => dots.add(c.unseen));

    for (var i = 0; i < 30; i++) {
      host.addLogLine('hidden $i');
    }
    host.addEvent('conn', 'lost', level: 'warn');
    await wait(tester, 4000); // the debounce and the 3 s safety poll both had their turn

    expect(host.logReads, 0, reason: 'the raw log is read when somebody looks');
    expect(host.eventReads, greaterThan(0));
    expect(c.feed.list.length, 1, reason: 'events are read for the toasts and the dot');
    expect(c.unseen, (error: false, warn: true));
    expect(dots, [(error: false, warn: true)], reason: 'the dot changed once');
    expect(notified, 0, reason: 'no list is redrawn behind another tab');
    expect(c.raw.lines, isEmpty);
  });

  it('showing the tab catches up from the cursor; what came meanwhile is unread; leaving it stops the stream again', (tester) async {
    await start(tester);
    for (var i = 0; i < 30; i++) {
      host.addLogLine('hidden $i');
    }
    await wait(tester);
    c.setOnScreen(true);
    expect(host.lineListeners, 1);
    expect(c.raw.lines.length, 30);
    expect(c.cfg.rawUnread.length, 30, reason: 'first run: what was there at the start is read, the 30 came after it');
    expect(notified, greaterThan(0), reason: 'the page is told it came into view');

    c.markRead(c.raw.lines.map((l) => l.n));
    expect(c.cfg.rawUnread, isEmpty);
    host.addLogLine('while looking');
    await wait(tester);
    expect(c.raw.lines.length, 31);
    markReadOf(c);

    c.setOnScreen(false);
    expect(host.lineListeners, 0);
    host.resetCounts();
    host.addLogLine('behind');
    await wait(tester, 4000);
    expect(host.logReads, 0);
    c.setOnScreen(true);
    expect(c.raw.lines.length, 32);
    expect(c.cfg.rawUnread.length, 1, reason: 'only the line that came behind is unread');
  });

  it('the unread numbers are written when the tab or the app goes away, never per line', (tester) async {
    await start(tester);
    c.setOnScreen(true);
    await wait(tester);
    host.saves = 0;
    for (var i = 0; i < 40; i++) {
      host.addLogLine('l$i');
      await wait(tester, 250);
    }
    expect(host.saves, 0, reason: 'ten seconds of lines: no state save');
    await wait(tester); // the last burst is read
    c.setOnScreen(false);
    expect(host.saves, 1);
    final saved = host.catalog.unknown['logCfg'] as Map;
    expect(saved['rawUnread'], isNotEmpty);

    c.setOnScreen(false);
    c.setOnScreen(true);
    c.setOnScreen(false);
    expect(host.saves, 1, reason: 'nothing changed: nothing saved');

    c.setOnScreen(true);
    host.addLogLine('again');
    await wait(tester);
    c.setForeground(false); // the app goes to the background with the tab open
    expect(host.saves, 2);
    expect(host.lineListeners, 0);
    c.setForeground(true);
    expect(host.lineListeners, 1);
  });

  it('the derived lists are built once per change: the same list until something arrives', (tester) async {
    await start(tester);
    c.setOnScreen(true);
    host.addEvent('conn', 'lost', level: 'warn');
    host.addEvent('conn', 'restored');
    host.addLogLine('a');
    host.addLogLine('b', lvl: 'warn');
    await wait(tester);

    final groups = c.groups, lines = c.shownLines, unread = c.unreadLines;
    final ev = c.evVersion, rv = c.rawVersion;
    expect(identical(c.groups, groups), isTrue);
    expect(identical(c.shownLines, lines), isTrue);
    expect(identical(c.unreadLines, unread), isTrue);
    expect(c.evLevels, (warn: 1, err: 0));
    expect(c.rawLevels, (warn: 1, err: 0));
    await wait(tester, 4000);
    expect([c.evVersion, c.rawVersion], [ev, rv], reason: 'a poll that finds nothing changes nothing');

    host.addLogLine('c');
    await wait(tester);
    expect(c.rawVersion, greaterThan(rv));
    expect(identical(c.shownLines, lines), isFalse);
    expect(c.shownLines.length, 3);
    expect(c.evVersion, ev, reason: 'the journal did not change');
    expect(identical(c.groups, groups), isTrue);

    c.setRawLevel('warn');
    expect(c.shownLines.length, 1);
    markReadOf(c);
    expect(identical(c.unreadLines, unread), isFalse, reason: 'read lines leave the badge');
  });

  it('first run: lines the core held before the first poll count as read', (tester) async {
    host = _CountingHost();
    host.addLogLine('old 1');
    host.addLogLine('old 2');
    c = LogsController(host)..l10n = lookupAppLocalizations(const Locale('en'));
    c.start();
    await tester.pump();
    host.addLogLine('new');
    c.setOnScreen(true);
    expect(c.raw.lines.length, 3);
    expect(c.cfg.rawUnread, {2});
  });
}

void markReadOf(LogsController c) => c.markRead(c.raw.lines.map((l) => l.n));
