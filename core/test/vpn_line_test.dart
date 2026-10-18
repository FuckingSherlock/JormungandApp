// The VPN line of the Events list (docs/logs.md → «Линия VPN»; plan events-t2, core log_view.dart): `vpnLineMarks` gives,
// for every event of the journal, the VPN state above it (before) and below it (after), and the dot. Computed over the
// whole journal, oldest first, so events hidden by the Events filter do not break the line.
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
  int? opens,
  int rev = 0,
}) =>
    EventRecord.fromJson({
      'id': id,
      'at': at,
      'cat': cat,
      'type': type,
      'level': level,
      'own': false,
      'data': data,
      'opens': ?opens,
      if (rev > 0) 'rev': rev,
    });

EventRecord connected(int id, {int at = 0}) => ev(id, 'conn', 'connected', at: at);
EventRecord reconnected(int id, {int at = 0}) => ev(id, 'conn', 'reconnected', at: at, data: {'reason': 'settings'});
EventRecord disconnected(int id, {int at = 0, String by = 'user'}) =>
    ev(id, 'conn', 'disconnected', at: at, level: 'warn', data: {'by': by});
EventRecord vpnDown(int id, List<String> causes, {int at = 0, int rev = 0}) => ev(
      id,
      'conn',
      'vpnDown',
      at: at,
      level: causes.length == 1 && causes.single == 'network' ? 'warn' : 'error',
      data: {'causes': causes},
      rev: rev,
    );
EventRecord vpnUp(int id, {required int opens, int at = 0, String? by}) => ev(
      id,
      'conn',
      'vpnUp',
      at: at,
      opens: opens,
      data: {'downMs': 30 * sec, 'causes': ['core'], 'by': ?by},
    );

List<Object?> sig(VpnMark m) => [m.above, m.below, m.dot];

void main() {
  test('the sample: connect, waiting for the network, down, on again, reconnected, off; every event has its mark', () {
    final journal = [
      connected(1, at: 0),
      vpnDown(2, ['network'], at: 10 * sec),
      vpnDown(3, ['core'], at: 40 * sec), // the same outage, now with a sing-box that did not come back
      vpnUp(4, opens: 3, at: 60 * sec),
      reconnected(5, at: 100 * sec),
      disconnected(6, at: 120 * sec),
    ];
    final m = vpnLineMarks(journal);
    expect(m.keys, unorderedEquals([1, 2, 3, 4, 5, 6]));
    expect(sig(m[1]!), [VpnLine.on, VpnLine.on, VpnDot.change], reason: 'connected first: the line above it is on');
    expect(sig(m[2]!), [VpnLine.on, VpnLine.waiting, VpnDot.change]);
    expect(sig(m[3]!), [VpnLine.waiting, VpnLine.down, VpnDot.change]);
    expect(sig(m[4]!), [VpnLine.down, VpnLine.on, VpnDot.change]);
    expect(sig(m[5]!), [VpnLine.on, VpnLine.on, VpnDot.reconnect], reason: 'reconnected: the line goes through, the dot is a ring');
    expect(sig(m[6]!), [VpnLine.on, VpnLine.off, VpnDot.change]);
  });

  test('a vpnDown is waiting only when its one cause is the network; any core cause is down', () {
    for (final (causes, want) in [
      (['network'], VpnLine.waiting),
      (['core'], VpnLine.down),
      (['network', 'core'], VpnLine.down),
    ]) {
      final m = vpnLineMarks([connected(1), vpnDown(2, causes, at: 5 * sec)]);
      expect(m[2]!.below, want, reason: '$causes');
    }
  });

  test('vpnUp: on when it is a recovery, off when the user or the system ended the connection', () {
    for (final (by, want) in [
      (null, VpnLine.on),
      ('user', VpnLine.off),
      ('system', VpnLine.off),
    ]) {
      final m = vpnLineMarks([connected(1), vpnDown(2, ['core']), vpnUp(3, opens: 2, by: by)]);
      expect(sig(m[3]!), [VpnLine.down, want, VpnDot.change], reason: 'by: $by');
    }
  });

  test('a vpnDown that changes nothing is no dot: the state before and after are the same', () {
    final m = vpnLineMarks([connected(1), vpnDown(2, ['network']), vpnDown(3, ['network'], at: sec)]);
    expect(sig(m[3]!), [VpnLine.waiting, VpnLine.waiting, VpnDot.none]);
  });

  test('reconnected keeps the state it finds, during a waiting too', () {
    final m = vpnLineMarks([connected(1), vpnDown(2, ['network']), reconnected(3)]);
    expect(sig(m[3]!), [VpnLine.waiting, VpnLine.waiting, VpnDot.reconnect]);
  });

  test('before the first state event the line is inferred from it: connected, reconnected and vpnDown mean on above it', () {
    expect(sig(vpnLineMarks([connected(1)])[1]!), [VpnLine.on, VpnLine.on, VpnDot.change]);
    expect(sig(vpnLineMarks([reconnected(1)])[1]!), [VpnLine.on, VpnLine.on, VpnDot.reconnect]);
    expect(sig(vpnLineMarks([vpnDown(1, ['network'])])[1]!), [VpnLine.on, VpnLine.waiting, VpnDot.change]);
    expect(sig(vpnLineMarks([vpnDown(1, ['core'])])[1]!), [VpnLine.on, VpnLine.down, VpnDot.change]);
  });

  test('the first state event decides the line above it: disconnected means on, vpnUp (outage began before the journal) means down', () {
    for (final (first, above) in [
      (disconnected(1), [VpnLine.on, VpnLine.off, VpnDot.change]),
      (vpnUp(1, opens: 99), [VpnLine.down, VpnLine.on, VpnDot.change]),
    ]) {
      final m = vpnLineMarks([first]);
      expect(sig(m[1]!), above, reason: first.key);
    }
  });

  test('events before the first state event sit on the line inferred from that event', () {
    final site = ev(1, 'site', 'blocked', level: 'warn', data: {'host': 'a.example', 'entry': 'e'});
    final disc = vpnLineMarks([site, disconnected(2, at: sec)]);
    expect(sig(disc[1]!), [VpnLine.on, VpnLine.on, VpnDot.none]);
    expect(sig(disc[2]!), [VpnLine.on, VpnLine.off, VpnDot.change]);
    final up = vpnLineMarks([site, vpnUp(2, opens: 99, at: sec)]);
    expect(sig(up[1]!), [VpnLine.down, VpnLine.down, VpnDot.none]);
    expect(sig(up[2]!), [VpnLine.down, VpnLine.on, VpnDot.change]);
  });

  test('a journal with no state event is off all the way', () {
    final m = vpnLineMarks([ev(1, 'site', 'blocked', level: 'warn', data: {'host': 'a.example', 'entry': 'e'})]);
    expect(sig(m[1]!), [VpnLine.off, VpnLine.off, VpnDot.none]);
  });

  test('other events sit on the line: the state before and after is the current one, no dot', () {
    final m = vpnLineMarks([
      connected(1),
      ev(2, 'site', 'blocked', level: 'warn', data: {'host': 'a.example', 'entry': 'e'}),
      vpnDown(3, ['network']),
      ev(4, 'conn', 'failing', level: 'warn'),
      ev(5, 'sub', 'updated', level: 'warn', data: {'source': 's1'}),
      vpnUp(6, opens: 3),
    ]);
    expect(sig(m[2]!), [VpnLine.on, VpnLine.on, VpnDot.none]);
    expect(sig(m[4]!), [VpnLine.waiting, VpnLine.waiting, VpnDot.none]);
    expect(sig(m[5]!), [VpnLine.waiting, VpnLine.waiting, VpnDot.none]);
    expect(sig(m[6]!), [VpnLine.waiting, VpnLine.on, VpnDot.change]);
  });

  test('events hidden from the list do not break the line: the state marks are the same without them', () {
    final full = [
      connected(1),
      ev(2, 'site', 'blocked', level: 'warn', data: {'host': 'a.example', 'entry': 'e'}),
      vpnDown(3, ['network'], at: 10 * sec),
      ev(4, 'site', 'unreachable', level: 'warn', data: {'host': 'b.example'}),
      vpnUp(5, opens: 3, at: 20 * sec),
    ];
    final reduced = [for (final e in full) if (e.key.startsWith('conn/')) e];
    final a = vpnLineMarks(full);
    final b = vpnLineMarks(reduced);
    for (final id in [1, 3, 5]) {
      expect(sig(a[id]!), sig(b[id]!), reason: 'event $id');
    }
    expect(sig(a[5]!), [VpnLine.waiting, VpnLine.on, VpnDot.change]);
  });
}
