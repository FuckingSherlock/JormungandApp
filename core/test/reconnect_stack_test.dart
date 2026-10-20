// The stack of reconnects (docs/logs.md → «Повторы», item 4, «Стопка переподключений»): reconnect rows that follow each
// other, each within 10 min of the previous one, are one stack row; every other row passes through as it is.
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
  if (opId != null) 'op': {'id': opId, 'kind': opKind ?? 'x'},
  'verdict': ?verdict,
  if (why != null) 'why': {'code': why, 'params': <String, dynamic>{}},
});

/// A consequence with no root in the journal: a row of its own without a head.
EventRecord conseq(int id, String cat, String type, {required int at, String why = 'net.offline'}) =>
    ev(id, cat, type, at: at, level: 'warn', verdict: 'consequence', why: why);

/// A reconnect as the core writes it: the user's change that started it (the head of the row), an optional user/pin
/// in the same operation, and the outcome [outcome] `at + 500`. Ids: 10 * [n] + 1 (the change), + 2 (the pin), + 3 (the outcome).
List<EventRecord> reconnect(
  int n,
  int at, {
  String kind = 'reconnect',
  String outcome = 'reconnected',
  String level = 'info',
  bool pin = false,
}) {
  final base = 10 * n;
  final op = 'op$n';
  return [
    ev(base + 1, 'user', 'mode', at: at, own: true, opId: op, opKind: kind, data: {'value': 'proxy'}),
    if (pin) ev(base + 2, 'user', 'pin', at: at + 100, own: true, opId: op, opKind: kind, data: {'value': 'x'}),
    ev(base + 3, 'conn', outcome, at: at + 500, level: level, opId: op, opKind: kind, data: {'reason': 'user', 'tookMs': 800}),
  ];
}

/// The rows as the app has them: folded, then sorted by `at`.
List<EventGroup> rowsOf(List<EventRecord> all, {bool Function(EventRecord e)? matches}) =>
    [...foldEvents(all, matches: matches)]..sort((a, b) => a.at.compareTo(b.at));

List<int> ids(EventGroup g) => [for (final e in g.items) e.id];

void main() {
  group('stackReconnects', () {
    test('three adjacent reconnects are one row; its stack is the members oldest first, worded and placed by the newest', () {
      final rows = rowsOf([...reconnect(1, 0, pin: true), ...reconnect(2, 2 * min), ...reconnect(3, 4 * min)]);
      expect(rows, hasLength(3));
      final out = stackReconnects(rows);
      expect(out, hasLength(1));
      final s = out.single;
      expect(s.isStack, isTrue);
      expect(s.stack, hasLength(3));
      expect(s.stack, orderedEquals(rows), reason: 'the member rows themselves, oldest first');
      expect(rows.every((g) => !g.isStack), isTrue, reason: 'the input rows are not changed');

      final last = rows.last;
      expect(s.key, rows.first.key, reason: 'the first member\'s key');
      expect(s.ev.id, 33, reason: 'worded by the newest reconnect');
      expect(s.ev.key, 'conn/reconnected');
      expect(s.at, last.at, reason: 'the row sits where its newest reconnect is');
      expect(s.lastAt, rows.map((g) => g.lastAt).reduce((a, b) => a > b ? a : b));
      expect(s.head!.id, last.head!.id);
      expect(s.opId, last.opId);
      expect(s.opKind, 'reconnect');
      expect(ids(s), [11, 12, 13, 21, 23, 31, 33], reason: 'every member\'s events, oldest first by id');
    });

    test('a lone reconnect row is returned as it is', () {
      final rows = rowsOf(reconnect(1, 0));
      final out = stackReconnects(rows);
      expect(out.single, same(rows.single));
      expect(out.single.isStack, isFalse);
      expect(out.single.stack, isEmpty);
    });

    test('no rows, no stacks', () {
      expect(stackReconnects([]), isEmpty);
    });

    group('what splits a run', () {
      final breakers = <(String, List<EventRecord> Function(int))>[
        ('a site event', (at) => [ev(50, 'site', 'blocked', at: at, data: {'host': 'a.example'})]),
        ('a connection that ended with conn/connected', (at) => reconnect(5, at, kind: 'connection', outcome: 'connected')),
        ('a reconnected row without a root (no head)', (at) => [conseq(50, 'conn', 'reconnected', at: at)]),
      ];
      for (final (name, between) in breakers) {
        test('$name between two reconnects splits them into two stacks, the breaker passes through', () {
          final rows = rowsOf([
            ...reconnect(1, 0),
            ...reconnect(2, 1 * min),
            ...between(2 * min),
            ...reconnect(3, 3 * min),
            ...reconnect(4, 4 * min),
          ]);
          final out = stackReconnects(rows);
          expect(out, hasLength(3));
          expect(out[0].stack, hasLength(2));
          expect(identical(out[1], rows[2]), isTrue);
          expect(out[2].stack, hasLength(2));
        });
      }

      for (final (gap, stacked) in [(10 * min, true), (10 * min + 1, false)]) {
        test('a gap of $gap ms between two reconnects: ${stacked ? 'they stack' : 'they split'}', () {
          final rows = rowsOf([...reconnect(1, 0), ...reconnect(2, gap)]);
          final out = stackReconnects(rows);
          expect(out, hasLength(stacked ? 1 : 2));
          if (stacked) {
            expect(out.single.stack, hasLength(2));
          } else {
            expect(identical(out[0], rows[0]) && identical(out[1], rows[1]), isTrue);
          }
        });
      }

      test('each member is within 10 min of the previous one, not of the first: a chain of 6-min steps is one stack', () {
        final out = stackReconnects(rowsOf([...reconnect(1, 0), ...reconnect(2, 6 * min), ...reconnect(3, 12 * min)]));
        expect(out, hasLength(1));
        expect(out.single.stack, hasLength(3));
      });
    });

    group('what a reconnect is', () {
      test('a connection op whose newest outcome is conn/reconnected counts', () {
        final out = stackReconnects(rowsOf([
          ...reconnect(1, 0, kind: 'connection'),
          ...reconnect(2, 1 * min, kind: 'connection'),
        ]));
        expect(out.single.stack, hasLength(2));
      });

      test('a connection op worded by its newest outcome: conn/connected then conn/reconnected counts, the reverse does not', () {
        final counts = stackReconnects(rowsOf([
          ev(61, 'user', 'mode', at: 0, own: true, opId: 'c6', opKind: 'connection', data: {'value': 'tun'}),
          ev(62, 'conn', 'connected', at: 100, opId: 'c6', opKind: 'connection'),
          ev(63, 'conn', 'reconnected', at: 500, opId: 'c6', opKind: 'connection'),
          ...reconnect(7, 2 * min),
        ]));
        expect(counts.single.stack, hasLength(2));
        expect(counts.single.ev.id, 73);

        final notCounted = rowsOf([
          ev(61, 'user', 'mode', at: 0, own: true, opId: 'c6', opKind: 'connection', data: {'value': 'tun'}),
          ev(62, 'conn', 'reconnected', at: 100, opId: 'c6', opKind: 'connection'),
          ev(63, 'conn', 'connected', at: 500, opId: 'c6', opKind: 'connection'),
          ...reconnect(7, 2 * min),
        ]);
        final out = stackReconnects(notCounted);
        expect(out, hasLength(2));
        expect(out.every((g) => !g.isStack), isTrue);
      });
    });

    test('a key stays the same when a fourth reconnect joins; the row stays where its newest is', () {
      final rows = rowsOf([...reconnect(1, 0), ...reconnect(2, 2 * min), ...reconnect(3, 4 * min), ...reconnect(4, 6 * min)]);
      final three = stackReconnects(rows.take(3).toList()).single;
      final four = stackReconnects(rows).single;
      expect(three.stack, hasLength(3));
      expect(four.stack, hasLength(4));
      expect(four.key, three.key);
      expect(four.key, rows.first.key);
      expect(four.at, rows.last.at);
      expect(four.ev.id, 43);
    });

    test('the stack is as bad as its worst member', () {
      final calm = stackReconnects(rowsOf([...reconnect(1, 0), ...reconnect(2, 1 * min)])).single;
      expect(calm.level, 'info');

      final warned = stackReconnects(rowsOf([
        ...reconnect(1, 0),
        ...reconnect(2, 1 * min, level: 'warn'),
        ...reconnect(3, 2 * min),
      ])).single;
      expect(warned.level, 'warn');
    });

    test('hitInside is true when any member has the hit inside; a hit on the heads only leaves it false', () {
      final all = [...reconnect(1, 0), ...reconnect(2, 1 * min)];

      final inside = rowsOf(all, matches: (e) => e.id == 11 || e.id == 23);
      expect(inside, hasLength(2));
      expect([for (final g in inside) g.hitInside], [false, true]);
      expect(stackReconnects(inside).single.hitInside, isTrue);

      final heads = rowsOf(all, matches: (e) => e.id == 11 || e.id == 21);
      expect(stackReconnects(heads).single.hitInside, isFalse);
    });

    test('the other rows keep their order and identity', () {
      final rows = rowsOf([
        ev(50, 'site', 'blocked', at: 0, data: {'host': 'a.example'}),
        ...reconnect(1, 1 * min),
        ...reconnect(2, 2 * min),
        ev(51, 'site', 'blocked', at: 3 * min, data: {'host': 'b.example'}),
        ...reconnect(3, 4 * min),
      ]);
      final out = stackReconnects(rows);
      expect(out, hasLength(4));
      expect(identical(out[0], rows[0]), isTrue);
      expect(out[1].stack, hasLength(2));
      expect(identical(out[2], rows[3]), isTrue);
      expect(identical(out[3], rows[4]), isTrue);
    });
  });
}
