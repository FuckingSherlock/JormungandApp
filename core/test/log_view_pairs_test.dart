// Mechanism 2 of the Events list (docs/logs.md → «Свёртки», item 2): a closing event (`opens`) is written with its place
// in time and shows as its own row; the two rows point at each other (`closedById` on the opening row, `opensId` on the
// closing one). The consequences of the opening event stay in its row (mechanism 1); joins (mechanism 5) is tested
// in vpn_down_fold_test.dart.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const sec = 1000;

EventRecord ev(
  int id,
  String cat,
  String type, {
  int at = 0,
  String level = 'info',
  Map<String, dynamic> data = const {},
  int? cause,
  int? opens,
}) =>
    EventRecord.fromJson({
      'id': id,
      'at': at,
      'cat': cat,
      'type': type,
      'level': level,
      'own': false,
      'data': data,
      'cause': ?cause,
      'opens': ?opens,
    });

List<int> ids(EventGroup g) => [for (final e in g.items) e.id];

void main() {
  test('a closing event is a row of its own, placed by its time; the opening row keeps the close and points at it', () {
    final rows = foldEvents([
      ev(1, 'conn', 'lost', at: 0, level: 'warn'),
      ev(2, 'sub', 'updated', at: 20 * sec, data: {'source': 's1', 'total': 3}),
      ev(3, 'conn', 'restored', at: 60 * sec, opens: 1),
    ]);
    expect([for (final g in rows) g.ev.id], [1, 2, 3]);

    final opening = rows[0];
    expect(ids(opening), [1], reason: 'the closing event is not merged into the opening row');
    expect(opening.level, 'warn', reason: 'the row keeps its own level, the closer does not change it');
    expect(opening.closed, isTrue);
    expect(opening.closedById, 3);
    expect(opening.closedAfter, 60 * sec);
    expect(opening.opensId, isNull, reason: 'an opening event has no opener');

    final closing = rows[2];
    expect(ids(closing), [3]);
    expect(closing.level, 'info');
    expect(closing.opensId, 1);
    expect(closing.closedById, isNull, reason: 'a closing event closes nothing');
  });

  test('a consequence stays in the opening row; the closer is still a row of its own', () {
    final rows = foldEvents([
      ev(10, 'conn', 'vpnDown', at: 30 * sec, level: 'error', data: {'causes': ['core']}),
      ev(11, 'site', 'unreachable', at: 40 * sec, level: 'warn', cause: 10, data: {'host': 'a.example'}),
      ev(13, 'conn', 'vpnUp', at: 70 * sec, opens: 10, data: {'downMs': 40 * sec, 'causes': ['core']}),
    ]);
    expect(rows, hasLength(2));
    expect(ids(rows[0]), unorderedEquals([10, 11]));
    expect(rows[0].closedById, 13);
    expect(rows[0].closedAfter, 40 * sec);
    expect(rows[1].ev.id, 13);
    expect(rows[1].opensId, 10);
  });

  test('a closing event whose opening event is not in the journal stays as it is, with no link', () {
    final rows = foldEvents([ev(3, 'conn', 'restored', at: 60 * sec, opens: 1)]);
    expect(rows, hasLength(1));
    expect(rows.single.ev.id, 3);
    expect(rows.single.opensId, isNull);
  });

  test('an opening event without a closer is open: no closedById, not closed', () {
    final rows = foldEvents([ev(1, 'conn', 'lost', level: 'warn'), ev(2, 'sub', 'updated', at: sec, data: {'source': 's1'})]);
    expect(rows, hasLength(2));
    expect(rows.first.closed, isFalse);
    expect(rows.first.closedById, isNull);
    expect(rows.first.closedAfter, isNull);
  });
}
