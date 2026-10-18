// The Events row model (docs/logs.md → «Свёртки», «По типам»): foldEvents puts the events into rows by four mechanisms
// — cause (root → consequences), opens (a pair), op (one operation), repeats — keeps the root in place, takes the worst
// level, makes a group row when the root is not in the journal, and answers the filter / the search.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const min = 60 * 1000;

/// An event as the core writes it (`events()['events']` item).
EventRecord ev(
  int id,
  String cat,
  String type, {
  int at = 0,
  String level = 'info',
  bool own = false,
  Map<String, dynamic> data = const {},
  int? cause,
  int? opens,
  String? opId,
  String? opKind,
  String? verdict,
  String? why,
}) => EventRecord.fromJson({
  'id': id,
  'at': at,
  'cat': cat,
  'type': type,
  'level': level,
  'own': own,
  'data': data,
  'cause': ?cause,
  'opens': ?opens,
  if (opId != null) 'op': {'id': opId, 'kind': opKind ?? 'x'},
  'verdict': ?verdict,
  if (why != null) 'why': {'code': why, 'params': <String, dynamic>{}},
});

/// A consequence of [cause] by the Sentinel's verdict.
EventRecord conseq(int id, String cat, String type, {required int at, int? cause, String level = 'warn', String why = 'net.offline', Map<String, dynamic> data = const {}}) =>
    ev(id, cat, type, at: at, level: level, cause: cause, verdict: 'consequence', why: why, data: data);

List<int> ids(EventGroup g) => [for (final e in g.items) e.id];

void main() {
  group('root -> consequences (cause)', () {
    test('a root and its consequences are one row; the row says how many and when the last came', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        conseq(2, 'conn', 'lost', at: 1 * min, cause: 1),
        conseq(3, 'site', 'unreachable', at: 3 * min, cause: 1, data: {'host': 'a.example'}),
      ]);
      expect(rows, hasLength(1));
      final g = rows.single;
      expect(g.head!.id, 1);
      expect(g.isGroup, isFalse);
      expect([for (final e in g.related) e.id], [2, 3]);
      expect(g.relatedCount, 2);
      expect(g.relatedLastAt, 3 * min);
      expect(g.lastAt, 3 * min);
      expect(ids(g), [1, 2, 3]);
    });

    test('the row is as bad as its worst event, whichever it is', () {
      final g = foldEvents([
        ev(1, 'conn', 'offline', level: 'info'),
        conseq(2, 'conn', 'lost', at: 1, cause: 1, level: 'error'),
        conseq(3, 'sub', 'failed', at: 2, cause: 1, level: 'warn', data: {'source': 's'}),
      ]).single;
      expect(g.level, 'error');
      expect(g.worst.id, 2);

      final h = foldEvents([
        ev(1, 'conn', 'offline', level: 'error'),
        conseq(2, 'conn', 'lost', at: 1, cause: 1, level: 'info'),
      ]).single;
      expect(h.level, 'error', reason: 'a mild consequence does not lower the root');
    });

    test('the root stays where it is: a new consequence changes the counter and lastAt, not the place', () {
      final before = [
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        ev(2, 'core', 'sysProxy', at: 1 * min, data: {'on': true}),
        ev(3, 'dns', 'failed', at: 2 * min, level: 'warn', data: {'server': 'd'}),
      ];
      final a = foldEvents(before);
      final b = foldEvents([...before, conseq(4, 'conn', 'lost', at: 5 * min, cause: 1)]);
      expect([for (final g in a) g.head!.id], [1, 2, 3]);
      expect([for (final g in b) g.head!.id], [1, 2, 3], reason: 'no new row, the root is not moved to the end');
      expect(b.first.at, 0);
      expect(b.first.relatedCount, 1);
      expect(b.first.lastAt, 5 * min);
      expect(a.first.relatedCount, 0);
    });

    test('a consequence is never a row of its own while its root is there; a consequence of a consequence joins the same row', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', level: 'warn'),
        conseq(2, 'conn', 'lost', at: 1, cause: 1),
        conseq(3, 'site', 'unreachable', at: 2, cause: 2, data: {'host': 'h'}),
      ]);
      expect(rows, hasLength(1));
      expect(ids(rows.single), [1, 2, 3]);
    });

    test('a repeated consequence counts its repeats; two different consequences of one type are two, not a repeat', () {
      final g = foldEvents([
        ev(1, 'conn', 'offline', level: 'warn'),
        conseq(2, 'sub', 'failed', at: 1, cause: 1, data: {'source': 's', 'repeat': {'count': 4, 'at': [1, 2, 3, 4 * min]}}),
        conseq(3, 'sub', 'failed', at: 5 * min, cause: 1, data: {'source': 's'}),
      ]).single;
      expect(g.relatedCount, 5);
      expect(g.relatedLastAt, 5 * min);
    });

    test('rows of different roots do not mix; every event is in exactly one row', () {
      final all = [
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        ev(2, 'dns', 'failed', at: 1, level: 'warn', data: {'server': 'd'}),
        conseq(3, 'conn', 'lost', at: 2, cause: 1),
        conseq(4, 'dns', 'failedOnNode', at: 3, cause: 2, data: {'server': 'd', 'node': 'n'}),
        ev(5, 'user', 'mode', at: 4, own: true, data: {'value': 'tun'}),
        ev(6, 'core', 'deprecated', at: 5),
      ];
      final rows = foldEvents(all);
      expect([for (final g in rows) g.head!.id], [1, 2, 5, 6]);
      expect(ids(rows[0]), [1, 3]);
      expect(ids(rows[1]), [2, 4]);
      final seen = [for (final g in rows) ...ids(g)]..sort();
      expect(seen, [1, 2, 3, 4, 5, 6]);
    });
  });

  group('pairs (opens)', () {
    test('the closing event is a row of its own, placed by its time; the opening row is closed with the duration and points at the closer', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', at: 10 * min, level: 'warn'),
        ev(2, 'site', 'blocked', at: 11 * min, data: {'host': 'x'}),
        ev(3, 'conn', 'online', at: 14 * min, opens: 1),
      ]);
      expect([for (final g in rows) g.head!.id], [1, 2, 3]);
      final g = rows.first;
      expect(ids(g), [1], reason: 'the closing event is not merged into the opening row');
      expect(g.closed, isTrue);
      expect(g.closedById, 3);
      expect(g.closedAfter, 4 * min);
      expect(g.level, 'warn', reason: 'the worst of its events; the UI paints a closed pair «resolved»');
      expect(g.at, 10 * min, reason: 'the pair stays where it opened');
      expect(rows[1].closed, isFalse);
      expect(rows[2].isGroup, isFalse);
      expect(rows[2].closed, isFalse);
      expect(rows[2].opensId, 1);
      expect(rows[2].closedById, isNull, reason: 'a closing event closes nothing');
    });

    test('an open pair is not closed', () {
      final g = foldEvents([ev(1, 'conn', 'lost', level: 'warn')]).single;
      expect(g.closed, isFalse);
      expect(g.closer, isNull);
      expect(g.closedAfter, isNull);
    });

    test('the opening event is gone: the closing one is a row of its own (a row with a head, not a group)', () {
      final rows = foldEvents([ev(9, 'conn', 'online', at: 5, opens: 1)]);
      expect(rows, hasLength(1));
      expect(rows.single.isGroup, isFalse);
      expect(rows.single.head!.id, 9);
      expect(rows.single.closed, isFalse);
      expect(rows.single.opensId, isNull);
    });

    test('a pair with consequences under the opening event: root and consequences are one row, the closer a row of its own', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        conseq(2, 'conn', 'lost', at: 1 * min, cause: 1),
        ev(3, 'conn', 'online', at: 2 * min, opens: 1),
      ]);
      expect(rows, hasLength(2));
      expect(ids(rows[0]), [1, 2]);
      expect(rows[0].closed, isTrue);
      expect(rows[0].closedById, 3);
      expect(rows[0].relatedCount, 1);
      expect(ids(rows[1]), [3]);
      expect(rows[1].opensId, 1);
    });

    test('the newest closer is the one that counts', () {
      final rows = foldEvents([
        ev(1, 'rules', 'targetLost', at: 0, level: 'warn', data: {'target': 't'}),
        ev(2, 'rules', 'targetFound', at: 1 * min, opens: 1, data: {'target': 't'}),
        ev(3, 'rules', 'targetFound', at: 2 * min, opens: 1, data: {'target': 't'}),
      ]);
      expect([for (final g in rows) g.head!.id], [1, 2, 3]);
      expect(rows.first.closedById, 3);
      expect(rows.first.closedAfter, 2 * min);
    });
  });

  group('operations (op)', () {
    test('sub/updated + removed + back of one update are one row with the operation inside', () {
      final rows = foldEvents([
        ev(1, 'sub', 'updated', at: 0, opId: 'o1', opKind: 'subUpdate', data: {'source': 's', 'added': 1, 'removed': 2}),
        ev(2, 'sub', 'removed', at: 1, opId: 'o1', opKind: 'subUpdate', level: 'warn', data: {'source': 's', 'count': 2}),
        ev(3, 'sub', 'back', at: 2, opId: 'o1', opKind: 'subUpdate', opens: 2, data: {'source': 's', 'count': 1}),
        ev(4, 'sub', 'updated', at: 30 * min, opId: 'o2', opKind: 'subUpdate', data: {'source': 's'}),
      ]);
      expect(rows, hasLength(2));
      expect(rows[0].opId, 'o1');
      expect(rows[0].opKind, 'subUpdate');
      expect(ids(rows[0]), [1, 2, 3]);
      expect(rows[0].head!.id, 1, reason: 'the first event of the operation heads the row');
      expect(rows[0].level, 'warn');
      expect(rows[1].opId, 'o2');
      expect(rows[1].items, hasLength(1));
    });

    test('the same operation id far apart in time is still one row (not a repeat with a window)', () {
      final rows = foldEvents([
        ev(1, 'rules', 'ruleSetUpdated', at: 0, opId: 'rs', opKind: 'ruleSets', data: {'tag': 'a'}),
        ev(2, 'rules', 'ruleSetUpdated', at: 40 * min, opId: 'rs', opKind: 'ruleSets', data: {'tag': 'b'}),
      ]);
      expect(rows, hasLength(1));
      expect(ids(rows.single), [1, 2]);
    });

    test('different operations of one type with the same data are different rows', () {
      final rows = foldEvents([
        ev(1, 'sub', 'updated', at: 0, opId: 'a', opKind: 'subUpdate', data: {'source': 's'}),
        ev(2, 'sub', 'updated', at: 1000, opId: 'b', opKind: 'subUpdate', data: {'source': 's'}),
      ]);
      expect(rows, hasLength(2), reason: 'one update, one row: the repeat window does not glue two operations');
    });

    test('"update all": the subscriptions are inside one row', () {
      final rows = foldEvents([
        for (var i = 1; i <= 3; i++) ev(i, 'sub', 'updated', at: i, opId: 'all', opKind: 'subUpdateAll', data: {'source': 's$i'}),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.opKind, 'subUpdateAll');
      expect(ids(rows.single), [1, 2, 3]);
    });

    test('a reconnect: the user\'s mode change that started it, conn/reconnected and core/sysProxy are one row', () {
      final rows = foldEvents([
        ev(1, 'user', 'mode', at: 0, own: true, opId: 'r', opKind: 'reconnect', data: {'value': 'proxy'}),
        ev(2, 'core', 'sysProxy', at: 100, opId: 'r', opKind: 'reconnect', data: {'on': true}),
        ev(3, 'conn', 'reconnected', at: 900, opId: 'r', opKind: 'reconnect', cause: 1, data: {'reason': 'user', 'tookMs': 800}),
      ]);
      expect(rows, hasLength(1));
      expect(ids(rows.single), [1, 2, 3]);
      expect(rows.single.opKind, 'reconnect');
    });

    test('a user action with no consequence in the journal stays a row of its own', () {
      final rows = foldEvents([
        ev(1, 'user', 'mode', at: 0, own: true, opId: 'u', opKind: 'connection', data: {'value': 'tun'}),
        ev(2, 'user', 'route', at: 1 * min, own: true, data: {'value': 'rules'}),
      ]);
      expect(rows, hasLength(2));
    });

    test('an app update: one row for the stages, worded by the last one', () {
      final rows = foldEvents([
        ev(1, 'core', 'updateAvailable', at: 0, opId: 'u1', opKind: 'appUpdate', data: {'version': '1.2'}),
        ev(2, 'core', 'updateDownloaded', at: 5 * min, opId: 'u1', opKind: 'appUpdate', data: {'version': '1.2'}),
        ev(3, 'core', 'updateInstalled', at: 6 * min, opId: 'u1', opKind: 'appUpdate', data: {'version': '1.2'}),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.ev.type, 'updateInstalled');
      expect(rows.single.opKind, 'appUpdate');
      expect(ids(rows.single), [1, 2, 3]);
    });

    test('an operation row stays in place when its later events come', () {
      final rows = foldEvents([
        ev(1, 'sub', 'updated', at: 0, opId: 'o', opKind: 'subUpdate', data: {'source': 's'}),
        ev(2, 'dns', 'failed', at: 1, level: 'warn', data: {'server': 'd'}),
        ev(3, 'sub', 'removed', at: 2, opId: 'o', opKind: 'subUpdate', level: 'warn', data: {'source': 's'}),
      ]);
      expect([for (final g in rows) g.head!.id], [1, 2]);
      expect(rows.first.lastAt, 2);
    });
  });

  group('rows without a root (group rows)', () {
    test('consequences with no root event (net.captive is never written) are one group row keyed by the reason code', () {
      final rows = foldEvents([
        conseq(1, 'conn', 'lost', at: 0, why: 'net.captive'),
        conseq(2, 'site', 'unreachable', at: 1 * min, why: 'net.captive', data: {'host': 'h'}),
      ]);
      expect(rows, hasLength(1));
      final g = rows.single;
      expect(g.isGroup, isTrue);
      expect(g.head, isNull);
      expect(g.whyCode, 'net.captive');
      expect(g.relatedCount, 2);
      expect(ids(g), [1, 2]);
      expect(g.level, 'warn');
    });

    test('different reason codes are different group rows; a consequence with a root present is not a group', () {
      final rows = foldEvents([
        conseq(1, 'conn', 'lost', at: 0, why: 'net.captive'),
        conseq(2, 'conn', 'lost', at: 1, why: 'core.down'),
        ev(3, 'conn', 'offline', at: 2, level: 'warn'),
        conseq(4, 'site', 'unreachable', at: 3, cause: 3, why: 'net.offline', data: {'host': 'h'}),
      ]);
      expect([for (final g in rows) g.isGroup ? 'group:${g.whyCode}' : '${g.head!.id}'], ['group:net.captive', 'group:core.down', '3']);
    });

    test('a root that fell out of the journal: its consequences are a group row, the worst level counts', () {
      final rows = foldEvents([
        conseq(5, 'conn', 'lost', at: 0, cause: 1, why: 'net.offline', level: 'warn'),
        conseq(6, 'site', 'unreachable', at: 1, cause: 1, why: 'net.offline', level: 'error', data: {'host': 'h'}),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.isGroup, isTrue);
      expect(rows.single.whyCode, 'net.offline');
      expect(rows.single.level, 'error');
    });
  });

  group('the filter and the search', () {
    final root = ev(1, 'conn', 'offline', at: 0, level: 'warn');
    final lost = conseq(2, 'conn', 'lost', at: 1 * min, cause: 1);
    final site = conseq(3, 'site', 'unreachable', at: 2 * min, cause: 1, data: {'host': 'needle.example'});

    test('the root is hidden by the filter, the consequence fits: the consequence is a row of its own (not a group)', () {
      final rows = foldEvents([root, lost, site], shown: (e) => e.key != 'conn/offline');
      expect([for (final g in rows) g.head?.id], [2, 3]);
      expect(rows.every((g) => !g.isGroup), isTrue);
      expect(rows.every((g) => g.related.isEmpty || g.head != null), isTrue);
    });

    test('the consequence is hidden by the filter, the root fits: it is counted in the root\'s row, not shown alone', () {
      final rows = foldEvents([root, lost, site], shown: (e) => e.key != 'site/unreachable');
      expect([for (final g in rows) g.head!.id], [1]);
      expect(rows.single.relatedCount, 2, reason: 'the status of the row stays true under a filter');
    });

    test('the filter hides both: no row', () {
      expect(foldEvents([root, lost, site], shown: (e) => e.cat == 'user'), isEmpty);
    });

    test('a hidden opening event: the closer of a pair that does fit is its own row', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        ev(2, 'conn', 'online', at: 1, opens: 1),
      ], shown: (e) => e.type != 'offline');
      expect([for (final g in rows) g.head?.id], [2]);
    });

    test('a search that hits only a consequence keeps the root\'s row and says the hit is inside', () {
      final rows = foldEvents([root, lost, site], matches: (e) => '${e.data['host']}'.contains('needle'));
      expect(rows, hasLength(1));
      expect(rows.single.head!.id, 1);
      expect(rows.single.hitInside, isTrue);
    });

    test('a search that hits the root itself is not "inside"; no hit: no row', () {
      final hit = foldEvents([root, lost, site], matches: (e) => e.type == 'offline');
      expect(hit, hasLength(1));
      expect(hit.single.hitInside, isFalse);
      expect(foldEvents([root, lost, site], matches: (e) => false), isEmpty);
    });

    test('EventFilter.fold: the whole journal goes in, the filter and the search decide', () {
      String text(EventRecord e) => '${e.key} ${e.data.values.join(' ')}';
      final f = EventFilter()..q = 'needle';
      final rows = f.fold([root, lost, site], showOwn: true, text: text);
      expect(rows, hasLength(1));
      expect(rows.single.head!.id, 1);
      expect(rows.single.hitInside, isTrue);

      final g = EventFilter()..off.add('conn/offline');
      final r2 = g.fold([root, lost, site], showOwn: true, text: text);
      expect([for (final x in r2) x.head!.id], [2, 3], reason: 'the root is hidden by type: its consequences stand alone');

      final p = EventFilter()..problems = true;
      expect(p.fold([ev(1, 'core', 'deprecated'), ev(2, 'conn', 'lost', level: 'warn')], showOwn: true, text: text).map((x) => x.head!.id), [2]);
    });

    test('shown() and matches() are the two halves of visible()', () {
      String text(EventRecord e) => e.key;
      final f = EventFilter()
        ..q = 'lost'
        ..problems = true;
      final w = ev(1, 'conn', 'lost', level: 'warn'), i = ev(2, 'conn', 'restored');
      expect(f.shown(w, showOwn: true), isTrue);
      expect(f.shown(i, showOwn: true), isFalse);
      expect(f.matches(w, text), isTrue);
      expect(f.matches(ev(3, 'conn', 'offline', level: 'warn'), text), isFalse);
      expect(f.visible(w, showOwn: true, text: text), isTrue);
      expect(f.visible(i, showOwn: true, text: text), isFalse);
      expect(EventFilter().matches(w, text), isTrue, reason: 'an empty search matches everything');
    });
  });

  group('repeats without op / cause behave as before', () {
    test('the same event within 10 minutes is one row at its last place; after 10 minutes a new row', () {
      final rows = foldEvents([
        ev(1, 'site', 'blocked', at: 0, data: {'host': 'a', 'entry': 'e'}),
        ev(2, 'conn', 'lost', at: 1 * min, level: 'warn'),
        ev(3, 'site', 'blocked', at: 10 * min, level: 'warn', data: {'host': 'a', 'entry': 'e'}),
        ev(4, 'site', 'blocked', at: 20 * min + 1, data: {'host': 'a', 'entry': 'e'}),
      ]);
      expect([for (final g in rows) ids(g)], [
        [2],
        [1, 3],
        [4],
      ]);
      expect(rows[1].level, 'warn');
      expect(rows[1].at, 10 * min);
      expect(rows[1].times, 2);
      expect(rows[1].ev.id, 3);
    });

    test('the core\'s own repeats (data.repeat) count: ×N and the last time', () {
      final g = foldEvents([
        ev(1, 'sub', 'failed', at: 0, level: 'warn', data: {'source': 's', 'repeat': {'count': 7, 'at': [0, 5 * min]}}),
      ]).single;
      expect(g.times, 7);
      expect(g.lastAt, 5 * min);
    });

    test('events that carry a cause / op / opens are not glued as plain repeats of each other', () {
      final rows = foldEvents([
        ev(1, 'conn', 'offline', at: 0, level: 'warn'),
        ev(2, 'conn', 'offline', at: 1 * min, level: 'warn'), // a plain repeat of 1
        conseq(3, 'conn', 'lost', at: 2 * min, cause: 1),
        conseq(4, 'conn', 'lost', at: 3 * min, cause: 2),
      ]);
      // whichever row the roots make, no event is lost and the consequences are under a root, not rows of their own
      expect([for (final g in rows) ...ids(g)]..sort(), [1, 2, 3, 4]);
      expect(rows.every((g) => g.head != null && g.head!.cause == null), isTrue);
    });
  });

  group('a crashed core: one row from the crash to the restart', () {
    EventRecord crashed() => ev(1, 'core', 'crashed', at: 0, level: 'error', data: {'code': 1});

    test('crashed -> restartFailed x N -> down is one row, its status the last of them; restarted closes it from a row of its own', () {
      final rows = foldEvents([
        crashed(),
        for (var i = 0; i < 6; i++) ev(10 + i, 'core', 'restartFailed', at: (i + 1) * 5000, level: 'error', cause: 1, data: {'attempt': i + 1}),
        ev(20, 'core', 'down', at: 40000, level: 'error', cause: 1, data: {'proxy': 'kept'}),
        ev(21, 'core', 'restarted', at: 90000, opens: 1, cause: 1, data: {'downMs': 90000}),
      ]);
      expect(rows, hasLength(2));
      final g = rows.first;
      expect(g.head!.id, 1);
      expect(g.relatedCount, greaterThanOrEqualTo(7));
      expect(g.last.type, 'down');
      expect(g.closed, isTrue);
      expect(g.closedById, 21);
      expect(g.level, 'error', reason: 'the worst of the row; the UI paints it resolved by the closer');
      expect(g.at, 0);
      expect(rows.last.head!.id, 21);
      expect(rows.last.opensId, 1);
    });

    test('not restarted yet: the row is open and its last event is down; a restartFailed repeated by the core counts its times', () {
      final g = foldEvents([
        crashed(),
        ev(2, 'core', 'restartFailed', at: 5000, level: 'error', cause: 1, data: {'repeat': {'count': 9, 'at': [5000, 9000]}}),
        ev(3, 'core', 'down', at: 40000, level: 'error', cause: 1),
      ]).single;
      expect(g.closed, isFalse);
      expect(g.last.type, 'down');
      expect(g.relatedCount, 10);
      expect(g.relatedLastAt, 40000);
    });

    test('a second crash far later is its own row; the restart that closes the first is a row of its own too', () {
      final rows = foldEvents([
        crashed(),
        ev(2, 'core', 'restarted', at: 1000, opens: 1, cause: 1),
        ev(3, 'core', 'crashed', at: 60 * min, level: 'error'),
      ]);
      expect(rows, hasLength(3));
      expect(rows[0].closed, isTrue);
      expect(rows[0].closedById, 2);
      expect(rows[1].head!.id, 2);
      expect(rows[1].opensId, 1);
      expect(rows[2].head!.id, 3);
      expect(rows[2].closed, isFalse);
    });
  });

  test('folding is repeatable: the same list gives the same rows, and the input list is not changed', () {
    final all = [
      ev(1, 'conn', 'offline', level: 'warn'),
      conseq(2, 'conn', 'lost', at: 1, cause: 1),
      ev(3, 'conn', 'online', at: 2, opens: 1),
      ev(4, 'sub', 'updated', at: 3, opId: 'o', opKind: 'subUpdate', data: {'source': 's'}),
    ];
    String sig(List<EventGroup> r) => [for (final g in r) '${g.head?.id}:${ids(g)}:${g.level}:${g.lastAt}'].join(';');
    expect(sig(foldEvents(all)), sig(foldEvents(all)));
    expect(all, hasLength(4));
  });
}
