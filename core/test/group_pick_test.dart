import 'dart:async';

import 'package:jormungand_core/src/group_pick.dart';
import 'package:jormungand_core/src/pool.dart';
import 'package:jormungand_core/src/sentinel/model.dart' show Cancel;
import 'package:test/test.dart';

/// A probe whose answers are [ms] after [delayMs] each (key -> (delay, ms, byChecker)); records the keys asked.
Probe1 probe(Map<String, (int, int, bool)> spec, List<String> asked) => (k) async {
      asked.add(k);
      final (d, ms, weak) = spec[k] ?? (1, -1, false);
      await Future<void>.delayed(Duration(milliseconds: d));
      return PoolResult(ms, 0, byChecker: weak);
    };

void main() {
  test('Priority: waits only for the servers above the best answer, a checker-only answer counts', () async {
    final asked = <String>[];
    final p = await pickPriority(['a', 'b', 'c'], probe({'a': (60, -1, false), 'b': (10, 30, true), 'c': (5, 10, false)}, asked));
    expect([p.key, p.weak, p.tried], ['b', true, 3], reason: 'a missed, b (weak) is the first answering in the order; c is below');
    final q = await pickPriority(['a', 'b'], probe({'a': (300, 50, false), 'b': (5, 5, false)}, []));
    expect(q.key, 'a', reason: 'a is above b: waited for');
  });

  test('Fastest: the first strong answer opens the window, the fastest strong in it wins, a weak one only without strong', () async {
    final w = const Duration(milliseconds: 100);
    final p = await pickFastest(['a', 'b', 'c', 'd'], probe({'a': (10, 90, false), 'b': (40, 20, false), 'c': (5, 5, true), 'd': (500, 1, false)}, []), window: w);
    expect([p.key, p.ms, p.weak], ['b', 20, false], reason: 'c is weak (ignored), d is outside the window');
    expect(p.tookMs, lessThan(400));
    final q = await pickFastest(['a', 'b'], probe({'a': (5, 40, true), 'b': (20, 25, true)}, []), window: w);
    expect([q.key, q.weak], ['b', true], reason: 'nothing left to ask: the best weak one');
  });

  test('Fastest: a batch of weak answers only gets ONE more wave for a strong answer', () async {
    final w = const Duration(milliseconds: 20);
    final keys = [for (var i = 0; i < 60; i++) 'k$i'];
    final asked = <String>[];
    // k1 weak in the first batch (0-4); the extra wave is k5..k20: k20 is strong and beats the weak k1
    final p = await pickFastest(keys, probe({'k1': (5, 10, true), 'k20': (5, 80, false)}, asked), window: w);
    expect([p.key, p.weak, p.tried], ['k20', false, 21]);
    asked.clear();
    // the strong one is beyond the one wave (k30): the best weak of everything tried wins, no more waves
    final q = await pickFastest(keys, probe({'k1': (5, 70, true), 'k3': (5, 40, true), 'k30': (5, 5, false)}, asked), window: w);
    expect([q.key, q.weak, q.tried], ['k3', true, 21]);
    expect(asked.contains('k21'), isFalse);
    // the first batch had no answer at all: the batching goes on; a weak answer in a later wave gets its one more wave
    final r = await pickFastest(keys, probe({'k8': (5, 30, true), 'k25': (5, 90, false)}, []), window: w);
    expect([r.key, r.weak], ['k25', false], reason: 'wave 2 = k5..k20 (k8 weak), the extra wave = k21..k36 (k25 strong)');
  });

  test('batches: five at once, the rest at the ping parallelism only when nobody answered; none answered = no key', () async {
    final asked = <String>[];
    final keys = [for (var i = 0; i < 40; i++) 'k$i'];
    final p = await pickFastest(keys, probe({'k3': (5, 10, false)}, asked), window: const Duration(milliseconds: 20));
    expect([p.key, p.tried], ['k3', 5], reason: 'the first batch had an answer: the rest are never asked');
    asked.clear();
    final none = await pickFastest(keys, probe({'k30': (5, 10, false)}, asked), window: const Duration(milliseconds: 20));
    expect(none.key, 'k30');
    expect(none.tried, lessThanOrEqualTo(40));
    expect(asked.take(5), keys.take(5));
    final dead = await pickPriority(keys.take(7).toList(), probe({}, []));
    expect([dead.key, dead.tried, dead.answered], [null, 7, 0]);
  });

  test('cancel stops the pick; rankCandidates: strong by ms, the rest in order, dead last', () async {
    final c = Cancel();
    final f = pickFastest(['a', 'b'], probe({'a': (500, 5, false), 'b': (500, 6, false)}, []), cancel: c);
    c.cancel('x');
    final p = await f;
    expect([p.key, p.cancelled], [null, true]);
    final r = rankCandidates(['a', 'b', 'c', 'd', 'e'],
        peek: (k) => switch (k) { 'c' => const PoolResult(30, 0), 'd' => const PoolResult(10, 0), 'e' => const PoolResult(5, 0, byChecker: true), _ => null },
        dead: (k) => k == 'a');
    expect(r, ['d', 'c', 'b', 'e', 'a']);
  });
}
