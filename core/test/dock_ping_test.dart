// The dock ping (a tap on the latency in the dock): the order of the batches and the run that
// walks them — docs/connect-model.md → «Тап по задержке в доке».
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show clock, make, ping, snap, source, t0;

const five = ['1', '2', '3', '4', '5'];

/// Five sources s1..s5 of five servers each (ids s11..s15, s21..), all in Auto, plus a chain
/// s1 -> s2 (`c1`) when [chain]. Sources only: their own entries are the Route list.
Catalog build({bool chain = false, Map<String, dynamic>? over}) {
  final ids = ['s1', 's2', 's3', 's4', 's5'];
  return make(snap(over: {
    'sourcesData': {for (final s in ids) s: source(s, five)},
    'sourceOrder': ids,
    'connectOrder': [...ids, if (chain) 'c1'],
    'activeConnectId': 's1',
    'chainsData': {
      if (chain) 'c1': {'id': 'c1', 'name': 'S1 via S2', 'inId': 's1', 'outId': 's2', 'inAuto': true},
    },
    'catalogOrder': {'simple': [...ids, if (chain) 'c1'], 'profiles': <String>[]},
    'modeState': {'profiles': {'order': <String>[], 'active': null, 'auto': true}},
    'profilesData': <String, dynamic>{},
    ...?over,
  }));
}

List<String> names(List<DockPingItem> b) => [for (final i in b) '${i.chain == null ? '' : '${i.chain!.id}>'}${i.node.id}'];

void main() {
  setUp(() => clock = t0);

  group('order of the batches', () {
    test('Auto: the first 3 servers of the first 4 entries, then the rest by 8', () {
      final b = build().dockPingBatches();
      expect(names(b.first), ['s11', 's12', 's13', 's21', 's22', 's23', 's31', 's32', 's33', 's41', 's42', 's43']);
      // the 5th entry and the tails of the others: 25 - 12 = 13 servers, 8 + 5
      expect(b.map((x) => x.length), [12, 8, 5]);
      expect(names(b[1]), ['s14', 's15', 's24', 's25', 's34', 's35', 's44', 's45']);
      expect(names(b[2]), ['s51', 's52', 's53', 's54', 's55']);
      final all = [for (final x in b) ...names(x)];
      expect(all.toSet().length, 25);
    });

    test('Fastest: the best by cache first (alive by ms, never measured, dead last); Priority: by the list', () {
      final c = build(over: {
        'sourcesData': {
          for (final s in ['s1', 's2', 's3', 's4', 's5'])
            s: source(s, five, extra: s == 's2' ? {'pickMode': 'priority', 'pickOrder': ['s2::s25', 's2::s24', 's2::s21']} : null),
        },
      });
      ping(c, 's1::s15', 30);
      ping(c, 's1::s11', -1);
      ping(c, 's1::s13', 90);
      final b = c.dockPingBatches().first;
      expect(names(b).take(3), ['s15', 's13', 's12']);
      expect(names(b).skip(3).take(3), ['s25', 's24', 's21']);
    });

    test('Manual: the pinned entry first, its pinned server before the rest', () {
      final c = build(over: {'autoConnect': false, 'activeConnectId': 's3', 'pinnedNode': 's3::s34'});
      final first = c.dockPingBatches().first;
      expect(names(first).take(3), ['s34', 's31', 's32']);
      expect(names(first).skip(3).take(3), ['s11', 's12', 's13']);
      // 4 entries: s3, then s1, s2, s4 by the priority
      expect(names(first).skip(6), ['s21', 's22', 's23', 's41', 's42', 's43']);
      expect(first.length, 12);
    });

    test('a chain: 3 of each end, the exits as pairs through the entry, never directly', () {
      final c = build(chain: true);
      final top = c.dockPingBatches();
      // c1 is the 6th entry: out of the first 4, so it comes in the rest
      expect(names(top.first).where((n) => n.startsWith('c1>')), isEmpty);
      final rest = [for (final x in top.skip(1)) ...x];
      final exits = rest.where((i) => i.chain != null).toList();
      expect(exits.map((i) => i.node.id), ['s21', 's22', 's23', 's24', 's25']);
      expect(exits.every((i) => i.chain!.id == 'c1'), isTrue);
      // the chain's entries are servers of s1: measured once, not again for the chain
      final all = [for (final x in top) ...x];
      expect(all.length, 30);
      expect(all.map((i) => i.key).toSet().length, 30);
    });

    test('a chain among the top entries: 3 entries directly and 3 exits as pairs; the exits by the pair rank', () {
      final c = build(chain: true, over: {
        'connectOrder': ['c1', 's3', 's4', 's5', 's1', 's2'],
        'catalogOrder': {'simple': ['c1', 's3', 's4', 's5', 's1', 's2'], 'profiles': <String>[]},
      });
      final entry = c.nodeOfKey('s1::s11')!;
      ping(c, 's1::s11', 20);
      c.pairs.put(entry, c.nodeOfKey('s2::s23')!, PingEntry(ms: 40, at: clock - 1000));
      c.pairs.put(entry, c.nodeOfKey('s2::s21')!, PingEntry(ms: -1, at: clock - 1000, fails: 1));
      final first = c.dockPingBatches().first;
      final n = names(first);
      expect(n.take(3), ['s11', 's12', 's13']);
      expect(n.skip(3).take(3), ['c1>s23', 'c1>s22', 'c1>s24']);
      expect(first.skip(3).take(3).every((i) => i.chain?.id == 'c1'), isTrue);
      expect(n.skip(6).take(3), ['s31', 's32', 's33']);
    });

    test('nothing in the Route list: no batches', () {
      expect(build(over: {'connectOrder': <String>[]}).dockPingBatches(), isEmpty);
    });
  });

  group('the run', () {
    /// A measure that answers every server of the batch at [ms] (-1 = dead).
    Future<void> Function(List<DockPingItem>) answering(Catalog c, num ms, List<int> sizes, [void Function()? each]) => (batch) async {
          sizes.add(batch.length);
          for (final i in batch) {
            if (i.chain == null) c.pings.set(i.node, ms);
          }
          each?.call();
        };

    test('stops once 10 servers answered: the first batch (12) is enough', () async {
      final c = build();
      final sizes = <int>[];
      final run = DockPingRun(c, answering(c, 30, sizes));
      await run.run();
      expect(sizes, [12]);
      expect(run.alive, 12);
    });

    test('goes on while fewer than 10 answered, until all are measured', () async {
      final c = build();
      final sizes = <int>[];
      final run = DockPingRun(c, answering(c, -1, sizes));
      await run.run();
      expect(sizes, [12, 8, 5]);
      expect(run.alive, 0);
    });

    test('counts across batches: 4 of the first + 8 of the second = enough, the third is not measured', () async {
      final c = build();
      final sizes = <int>[];
      final run = DockPingRun(c, (batch) async {
        sizes.add(batch.length);
        for (final (k, i) in batch.indexed) {
          final alive = sizes.length == 1 ? k < 4 : sizes.length == 2;
          c.pings.set(i.node, alive ? 20 : -1);
        }
      });
      await run.run();
      expect(sizes, [12, 8]);
      expect(run.alive, 4 + 8);
    });

    test('stop: the batch in flight finishes and reports, no new one goes out', () async {
      final c = build();
      final sizes = <int>[];
      late DockPingRun run;
      run = DockPingRun(c, answering(c, -1, sizes, () => run.stop()));
      await run.run();
      expect(sizes, [12]);
      expect(run.stopped, isTrue);
    });

    test('a chain exit answers by its pair, not by its direct ping', () {
      final c = build(chain: true);
      final entry = c.nodeOfKey('s1::s11')!, x = c.nodeOfKey('s2::s21')!;
      ping(c, 's1::s11', 20);
      final item = DockPingItem(x, c.chainsData['c1']);
      ping(c, 's2::s21', 30); // alive directly ...
      expect(c.dockPingAlive(item), isFalse); // ... but the pair was never measured
      c.pairs.set(entry, x, 55, clock);
      expect(c.dockPingAlive(item), isTrue);
      c.pairs.set(entry, x, -1, clock);
      expect(c.dockPingAlive(item), isFalse);
    });
  });
}
