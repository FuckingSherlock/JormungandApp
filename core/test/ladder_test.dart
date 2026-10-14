// The ladder of dead nodes (ladder.dart): 1, 2, 4, 8, then every 15 minutes, one light request per step, never
// started over (a reconnect, a restart of the app), an out-of-turn check after a reconnect / a network change.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, plan, unit;

const _min = 60000;

void main() {
  group('DeadLadder', () {
    test('the steps are 1, 2, 4, 8 and then every 15 min; an answer takes the node off', () {
      final l = DeadLadder();
      expect(l.gate('n', 0), LadderGate.free);
      expect(l.enter('n', 0), isTrue);
      expect(l.enter('n', 5), isFalse, reason: 'already on it');
      var now = 0;
      final waits = <int>[];
      for (var i = 0; i < 7; i++) {
        final due = l['n']!.nextAt;
        expect(l.gate('n', due - 5000), LadderGate.skip);
        expect(l.gate('n', due), LadderGate.light);
        waits.add(due - now);
        now = due;
        l.observe('n', -1, now);
      }
      expect(waits, [for (final m in [1, 2, 4, 8, 15, 15, 15]) m * _min]);
      expect(l['n']!.misses, 7);
      expect(l.observe('n', 80, now), isTrue);
      expect(l.has('n'), isFalse);
    });

    test('an early check that misses adds nothing; owe() makes one check out of turn, whatever the step', () {
      final l = DeadLadder()..enter('n', 0);
      l.observe('n', -1, 10 * 1000);
      expect([l['n']!.step, l['n']!.nextAt, l['n']!.misses], [0, _min, 0]);
      expect(l.gate('n', 10 * 1000), LadderGate.skip);
      l.owe();
      expect(l.gate('n', 10 * 1000), LadderGate.light);
      l.observe('n', -1, 10 * 1000);
      expect(l.gate('n', 10 * 1000), LadderGate.skip, reason: 'paid, once');
      expect([l['n']!.step, l['n']!.nextAt], [0, _min], reason: 'the step is kept');
    });

    test('snapshot / restore bring a rolled-back round back', () {
      final l = DeadLadder()..enter('a', 0);
      final snap = l.snapshot();
      l.enter('b', 0);
      l.observe('a', -1, _min);
      l.restore(snap);
      expect([l.ids.toList(), l['a']!.step], [['a'], 0]);
    });
  });

  group('DeadLadderStore', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ladder');
      file = File(p.join(dir.path, 'dead-nodes.json'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('round trip: the step, the next turn and the misses survive a restart; each node is owed one check', () async {
      var now = 1000 * _min;
      final a = DeadLadder();
      final store = DeadLadderStore(file, a, clock: () => now, debounce: Duration.zero);
      a.enter('n', now);
      for (var i = 0; i < 3; i++) {
        now = a['n']!.nextAt;
        a.observe('n', -1, now);
      }
      await store.close();
      expect((jsonDecode(file.readAsStringSync()) as Map)['nodes'], hasLength(1));

      final b = DeadLadder();
      expect(DeadLadderStore(file, b, clock: () => now + 30 * 1000).load(), 1);
      expect([b['n']!.step, b['n']!.misses, b['n']!.nextAt, b['n']!.since], [3, 3, a['n']!.nextAt, 1000 * _min]);
      expect(b.gate('n', now + 30 * 1000), LadderGate.light, reason: 'a start is a reconnect: one check out of turn');
      b.observe('n', -1, now + 30 * 1000);
      expect(b.gate('n', now + 40 * 1000), LadderGate.skip);
      expect(b['n']!.step, 3, reason: 'and the ladder goes on from the step it was on');
    });

    test('nodes unseen for 30 days are forgotten at load and when written; a damaged file is an empty ladder', () async {
      final now = 100 * 24 * 60 * _min;
      file.writeAsStringSync(jsonEncode({
        'v': 1,
        'nodes': [
          {'id': 'old', 'since': 0, 'lastAt': 0, 'seenAt': 0, 'nextAt': 0, 'step': 4, 'misses': 9},
          {'id': 'new', 'since': 0, 'lastAt': now - _min, 'seenAt': now - _min, 'nextAt': now + 99 * _min, 'step': 9, 'misses': 9},
          {'nope': 1},
        ],
      }));
      final l = DeadLadder();
      final store = DeadLadderStore(file, l, clock: () => now, debounce: Duration.zero);
      expect(store.load(), 1);
      expect(l.ids, ['new']);
      expect([l['new']!.step, l['new']!.nextAt], [4, now + 15 * _min], reason: 'a step beyond the ladder is the last; a turn too far is brought in');
      l.enter('x', now);
      await store.close();
      expect([for (final n in (jsonDecode(file.readAsStringSync()) as Map)['nodes'] as List) n['id']], ['new', 'x']);

      file.writeAsStringSync('{broken');
      expect(DeadLadderStore(file, DeadLadder(), clock: () => now).load(), 0);
    });
  });

  group('batches', () {
    test('a node due within the window rides along only when another one is due now; its steps stay its own', () {
      final l = DeadLadder()
        ..enter('a', 0)
        ..enter('b', 0)
        ..enter('c', 0);
      l['a']!.nextAt = 60 * 1000;
      l['b']!.nextAt = 90 * 1000;
      l['c']!.nextAt = 200 * 1000;
      expect(l.pending('a', 30 * 1000), isFalse, reason: 'nobody is due: no wake, no batch');
      expect(l.gate('b', 30 * 1000, ahead: batchAhead), LadderGate.light, reason: 'the gate itself only opens the window');
      expect(l.pending('a', 60 * 1000), isTrue);
      expect(l.gate('a', 60 * 1000, ahead: batchAhead), LadderGate.light);
      expect(l.gate('b', 60 * 1000, ahead: batchAhead), LadderGate.light);
      expect(l.gate('c', 60 * 1000, ahead: batchAhead), LadderGate.skip, reason: '140 s away');
      l.observe('a', -1, 60 * 1000);
      l.observe('b', -1, 60 * 1000);
      expect([l['a']!.step, l['a']!.nextAt], [1, 60 * 1000 + 2 * _min]);
      expect([l['b']!.step, l['b']!.nextAt], [1, 90 * 1000 + 2 * _min], reason: 'counted from its own turn');
      expect(l['b']!.misses, 1);
    });

    test('Auto: three dead nodes due within 60 s are asked in one round, in parallel; none due = none asked', () async {
      var t = 0;
      final pool = ProbePool.solo(clock: () => t);
      // D1..D3 are above C, which is in use; they are dead from the start
      final p0 = plan([unit('D1', ['s::d1']), unit('D2', ['s::d2']), unit('D3', ['s::d3']), unit('C', ['s::c'])], current: 3, auto: {'failAfter': 1});
      final fake = FakeBox(buildConfig(p0), {'s::c': 30});
      final auto = AutoService(fake, p0, delay: fake.delayTest, clock: () => t, pool: pool);
      await auto.check();
      expect(pool.ladder.length, 3);
      final ids = pool.ladder.ids.toList();
      for (final (i, ms) in [60000, 90000, 115000].indexed) {
        pool.ladder[ids[i]]!.nextAt = ms;
      }
      int dead() => fake.tested.where((x) => x.contains('s::d')).length;
      fake.tested.clear();
      t = 30000;
      await auto.check();
      expect(dead(), 0, reason: 'nobody is due: no wake for the ones due soon');
      t = 60000; // the first is due; the other two come due within the next 60 s
      await auto.check();
      expect(dead(), 3, reason: 'one batch');
      expect([for (final id in ids) pool.ladder[id]!.step], [1, 1, 1]);
      expect([for (final id in ids) pool.ladder[id]!.nextAt], [60000 + 2 * _min, 90000 + 2 * _min, 115000 + 2 * _min]);
    });
  });

  group('Auto asks a dead node on the ladder', () {
    late int t;
    late ProbePool pool;
    late Map<String, dynamic> p0;
    late FakeBox fake;
    late AutoService auto;
    final notes = <String>[];

    int asked(FakeBox f, String key) => f.tested.where((x) => x.contains(key)).length;

    Future<void> round(int minutes) async {
      t = minutes * _min;
      await auto.check();
    }

    setUp(() async {
      t = 0;
      notes.clear();
      pool = ProbePool.solo(clock: () => t);
      // A is first by priority and in use; B is the spare it goes to
      p0 = plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'failAfter': 1});
      fake = FakeBox(buildConfig(p0), {'s::a': 30, 's::b': 60});
      auto = AutoService(fake, p0, delay: fake.delayTest, clock: () => t, pool: pool, note: notes.add);
      await round(0);
      fake.alive.remove('s::a');
      await round(1); // A is found dead, B takes over
      expect(auto.toJson()['now'], 'B');
      fake.tested.clear();
    });

    test('one light request per step: skipped in between, then 2, 4, 8, 15 min; no backup checks; an answer brings it back', () async {
      await round(1); // same minute: the step is not over
      await round(2); // 1 min after it was found dead
      expect(asked(fake, 's::a'), 1, reason: 'one request, not the url and its backup checks');
      final id = pool.ladder.ids.single;
      expect(pool.ladder[id]!.step, 1);
      fake.tested.clear();
      for (var m = 3; m < 4; m++) {
        await round(m);
      }
      expect(asked(fake, 's::a'), 0, reason: 'the second step is 2 min');
      await round(4);
      expect(asked(fake, 's::a'), 1);
      expect(pool.ladder[id]!.step, 2);
      fake.alive['s::a'] = 30;
      await round(8); // the third step (4 min) is over
      expect(pool.ladder.has(id), isFalse);
      expect(notes.where((n) => n.contains('is unavailable')), hasLength(1), reason: 'the log hears of it once');
      expect(notes.where((n) => n.contains('is back')), hasLength(1));
      await round(9);
      expect(auto.toJson()['now'], 'A');
    });

    test('a reconnect asks it once out of turn and keeps the step; the UI ping and a network change count too', () async {
      await round(2);
      await round(4);
      final id = pool.ladder.ids.single;
      final next = pool.ladder[id]!.nextAt;
      expect(pool.ladder[id]!.step, 2);

      // a new connection: another AutoService on the same pool, B in use
      final p1 = plan([unit('A', ['s::a']), unit('B', ['s::b'])], current: 1, auto: {'failAfter': 1});
      final fake2 = FakeBox(buildConfig(p1), {'s::b': 60});
      auto = AutoService(fake2, p1, delay: fake2.delayTest, clock: () => t, pool: pool);
      await round(5);
      expect(asked(fake2, 's::a'), 1, reason: 'one check out of turn');
      expect([pool.ladder[id]!.step, pool.ladder[id]!.nextAt], [2, next], reason: 'a miss out of turn keeps the step');
      await round(6);
      expect(asked(fake2, 's::a'), 1, reason: 'and then on its turn only');

      // another network: once more
      auto.networkChanged();
      await round(6);
      expect(asked(fake2, 's::a'), 2);
      expect(pool.ladder[id]!.step, 2);

      // a ping of the user's that answers takes it off the ladder
      pool.record(id, 40, url: 'https://t.example/');
      expect(pool.ladder.has(id), isFalse);
    });
  });
}
