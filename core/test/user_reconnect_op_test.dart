// The user's "disconnect → connect" within 7 s (journal 20261020-aozb2w): the user's taps and the core's events share one
// op, the row is worded by the outcome (`conn/reconnected`), the VPN line does not go off (docs/logs.md → «Операция»,
// «Линия VPN»).
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

Map<String, Object?> op(String id) => {'id': id, 'kind': 'connection'};

EventRecord ev(int id, String cat, String type, {Map<String, dynamic> data = const {}, Map<String, Object?>? withOp, int at = 0}) =>
    EventRecord.fromJson({
      'id': id,
      'at': at,
      'cat': cat,
      'type': type,
      'level': 'info',
      'own': true,
      'data': data,
      'op': ?withOp,
    });

List<EventRecord> bugJournal({bool tapsInOp = true}) {
  final o = tapsInOp ? op('connection-1-702') : null;
  return [
    ev(2071, 'conn', 'connected', at: 1000),
    ev(2072, 'user', 'disconnect', data: {'action': 'disconnect'}, withOp: o, at: 2000),
    ev(2073, 'conn', 'disconnected', data: {'by': 'user'}, withOp: op('connection-1-702'), at: 2001),
    ev(2074, 'conn', 'reconnected', data: {'reason': 'user', 'tookMs': 900, 'downMs': 5000}, withOp: op('connection-1-702'), at: 7000),
    ev(2075, 'user', 'connect', data: {'action': 'connect', 'entry': 'e'}, withOp: o, at: 7001),
  ];
}

void main() {
  test('one row for the user reconnect, worded by conn/reconnected, the taps and the disconnect inside', () {
    final rows = foldEvents(bugJournal());
    expect(rows.length, 2); // the first connected, then the operation
    final g = rows.last;
    expect(g.head!.id, 2072);
    expect(g.ev.key, 'conn/reconnected');
    expect(g.items.map((e) => e.id), [2072, 2073, 2074, 2075]);
  });

  test('a head that is a core event: the wording is still the outcome', () {
    final g = foldEvents(bugJournal(tapsInOp: false).where((e) => e.cat != 'user')).last;
    expect(g.head!.id, 2073);
    expect(g.ev.key, 'conn/reconnected');
  });

  test('a disconnect alone stays a "disconnected" row', () {
    final g = foldEvents(bugJournal().take(3)).last;
    expect(g.ev.key, 'conn/disconnected');
  });

  test('two connects of different operations do not fold as a repeat', () {
    final rows = foldEvents([
      ev(1, 'user', 'connect', data: {'action': 'connect'}, withOp: op('a')),
      ev(2, 'conn', 'connected', withOp: op('a')),
      ev(3, 'user', 'connect', data: {'action': 'connect'}, withOp: op('b')),
      ev(4, 'conn', 'connected', withOp: op('b')),
    ]);
    expect(rows.length, 2);
    expect(rows.every((g) => g.times == 1), isTrue);
  });

  test('the line stays on through the user reconnect: no dot at the disconnect, a ring at the reconnect', () {
    final m = vpnLineMarks(bugJournal());
    expect(m[2073]!.dot, VpnDot.none);
    expect(m[2073]!.above, VpnLine.on);
    expect(m[2073]!.below, VpnLine.on);
    expect(m[2074]!.dot, VpnDot.reconnect);
    expect(m[2074]!.above, VpnLine.on);
    expect(m[2074]!.below, VpnLine.on);
  });

  test('a plain disconnect is still a grey dot', () {
    final m = vpnLineMarks(bugJournal().take(3));
    expect(m[2073]!.dot, VpnDot.change);
    expect(m[2073]!.below, VpnLine.off);
  });

  EventRecord vpnDown(int id, List<String> causes) =>
      ev(id, 'conn', 'vpnDown', data: {'causes': causes}, at: 1500);
  EventRecord vpnUp(int id, int opens) => EventRecord.fromJson({
        'id': id, 'at': 2002, 'cat': 'conn', 'type': 'vpnUp', 'level': 'info', 'own': true,
        'opens': opens, 'data': {'downMs': 500, 'causes': ['network'], 'by': 'user'},
      });

  for (final (causes, down) in [
    (['network'], VpnLine.waiting),
    (['core'], VpnLine.down),
  ]) {
    test('user reconnect closing an open vpnDown $causes: no dot at disconnect and vpnUp, $down up to the ring, on after, never off', () {
      final m = vpnLineMarks([
        ev(1, 'conn', 'connected', at: 1000),
        vpnDown(2, causes),
        ev(3, 'conn', 'disconnected', data: {'by': 'user'}, withOp: op('X'), at: 2001),
        vpnUp(4, 2),
        ev(5, 'conn', 'reconnected', data: {'reason': 'user', 'tookMs': 900, 'downMs': 5000}, withOp: op('X'), at: 7000),
      ]);
      expect(m[3]!.dot, VpnDot.none);
      expect(m[3]!.above, down);
      expect(m[3]!.below, down);
      expect(m[4]!.dot, VpnDot.none, reason: 'the vpnUp of the user disconnect inside the reconnect');
      expect(m[4]!.above, down);
      expect(m[4]!.below, down);
      expect(m[5]!.dot, VpnDot.reconnect);
      expect(m[5]!.above, down);
      expect(m[5]!.below, VpnLine.on);
      for (final k in m.keys) {
        expect(m[k]!.below, isNot(VpnLine.off), reason: 'event $k');
      }
    });
  }

  test('a plain user disconnect during vpnDown (no reconnect): vpnUp by user turns the line off with a dot', () {
    final m = vpnLineMarks([
      ev(1, 'conn', 'connected', at: 1000),
      vpnDown(2, ['network']),
      ev(3, 'conn', 'disconnected', data: {'by': 'user'}, withOp: op('X'), at: 2001),
      vpnUp(4, 2),
    ]);
    expect(m[3]!.dot, VpnDot.change);
    expect(m[4]!.below, VpnLine.off);
    expect(m[4]!.dot, VpnDot.change);
  });
}
