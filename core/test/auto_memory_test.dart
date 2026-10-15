// What Auto and "If unavailable" remember outside one service (auto_memory.dart): health, the flap guard, «already
// failed», the fallback targets' strikes and the `auto/unstable` counter survive a service made anew, a new CoreService
// on the same data dir and a restart (the file); a change of the network starts the flap guard over; an unfinished series
// of misses older than two intervals is dropped. docs/failures.md → «Вердикт меняется только после перепроверки».
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, everyRound, plan, unit;

const _min = 60000;

/// One AutoService on [memory], on the clock [t]; [alive] = node key → ms.
class _Run {
  _Run(Map<String, dynamic> pl, this.alive, this.memory, this.t) {
    fake = FakeBox(buildConfig(pl), alive);
    auto = AutoService(fake, pl, delay: fake.delayTest, clock: () => t(), memory: memory, pool: everyRound());
  }

  final Map<String, int> alive;
  final AutoMemory memory;
  final int Function() t;
  late final FakeBox fake;
  late final AutoService auto;

  Map<String, dynamic> get j => auto.toJson();
  Map route(String id) => (j['routes'] as List).cast<Map>().firstWhere((r) => r['id'] == id);
}

Map<String, dynamic> _flap({int current = 0}) => plan([unit('A', ['s::a']), unit('B', ['s::b'])], current: current, auto: {'flapGuard': true, 'failAfter': 1});

void main() {
  group('Auto keeps what it learned across a service made anew', () {
    test('a half-finished series of misses: the next miss in the new service is the second', () async {
      var now = 0;
      final mem = AutoMemory();
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final r1 = _Run(p, {'s::a': 40, 's::b': 60}, mem, () => now);
      await r1.auto.check();
      r1.alive.remove('s::a');
      now += 10000;
      await r1.auto.check();
      expect(r1.j['now'], 'A', reason: 'one miss is not enough with failAfter 2');
      r1.auto.stop();

      now += 10000;
      final r2 = _Run(p, {'s::b': 60}, mem, () => now);
      await r2.auto.check();
      expect(r2.j['now'], 'B', reason: 'the miss before the new service counts: this one is the second');

      // the control: a service with a memory of its own starts the count from 1
      final r3 = _Run(p, {'s::b': 60}, AutoMemory(), () => now);
      await r3.auto.check();
      expect(r3.j['now'], 'A');
    });

    test('an unfinished series older than two intervals is dropped: a node that missed once long ago is not dead after one miss', () async {
      var now = 0;
      final mem = AutoMemory();
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final r1 = _Run(p, {'s::a': 40, 's::b': 60}, mem, () => now);
      await r1.auto.check();
      r1.alive.remove('s::a');
      now += 10000;
      await r1.auto.check();
      r1.auto.stop();
      expect(AutoSettings.fromPlan(p).streakGap, const Duration(minutes: 2), reason: 'two of the slower of checkEvery / warmEvery');

      now += 5 * _min;
      final r2 = _Run(p, {'s::b': 60}, mem, () => now);
      await r2.auto.check();
      expect(r2.j['now'], 'A', reason: 'the old miss is forgotten: this is the first');
      await r2.auto.check();
      expect(r2.j['now'], 'B');
    });

    test('dropStaleStreaks: a finished series (a verdict) and an object that answers stay', () {
      final m = AutoMemory();
      final one = m.server('one')..record(-1, 0);
      final dead = m.server('dead')
        ..record(-1, 0)
        ..record(-1, 0);
      final ok = m.server('ok')..record(40, 0);
      m.route('R').health.record(-1, 0);
      m.target('T').health.record(-1, 0);
      expect(m.dropStaleStreaks(60 * _min, const Duration(minutes: 2), 2), isTrue);
      expect([one.fails, one.ms, one.at], [0, -2, 0]);
      expect([dead.fails, dead.ms], [2, -1]);
      expect([ok.ms, ok.oks], [40, 1]);
      expect([m.route('R').health.fails, m.target('T').health.fails], [0, 0]);
      expect(m.dropStaleStreaks(60 * _min, const Duration(minutes: 2), 2), isFalse);
      final fresh = m.server('fresh')..record(-1, 59 * _min);
      m.dropStaleStreaks(60 * _min, const Duration(minutes: 2), 2);
      expect(fresh.fails, 1, reason: 'within the gap');
    });

    test('the flap guard: strikes and the hold go to the next service; the count of unstable routes goes on, not from 1', () async {
      var now = 0;
      final mem = AutoMemory();
      final p = _flap();
      final r1 = _Run(p, {'s::a': 30, 's::b': 60}, mem, () => now);
      Future<void> at(_Run r, int m) async {
        now = m * _min;
        await r.auto.check();
      }

      await at(r1, 0);
      r1.alive.remove('s::a');
      await at(r1, 1);
      expect([r1.j['now'], r1.route('A')['strikes']], ['B', 1]);
      r1.alive['s::a'] = 30;
      await at(r1, 2);
      await at(r1, 3);
      expect(r1.j['now'], 'A', reason: 'the 1 min hold served');
      r1.alive.remove('s::a');
      await at(r1, 4);
      expect([r1.j['now'], r1.route('A')['strikes'], r1.j['unstable']], ['B', 2, 1]);
      r1.auto.stop();

      // a new service (a reconnect, a restart for a rule set): on B, A answers again from 5:00
      final r2 = _Run(_flap(current: 1), {'s::a': 30, 's::b': 60}, mem, () => now);
      expect([r2.route('A')['strikes'], r2.j['unstable'], (r2.j['lastUnstable'] as Map)['strikes']], [2, 1, 2]);
      await at(r2, 5);
      await at(r2, 6);
      expect(r2.j['now'], 'B', reason: 'strikes 2 = a 2 min hold: A answers since 5:00, it is not served yet');
      await at(r2, 7);
      expect(r2.j['now'], 'A');

      // the control: a service with a memory of its own takes A back at once, the counter starts from nothing
      final r3 = _Run(p, {'s::a': 30, 's::b': 60}, AutoMemory(), () => now);
      expect([r3.route('A')['strikes'], r3.j['unstable']], [0, 0]);
    });

    test('a change of the network starts the flap guard and the unstable count over; answers and misses stay', () async {
      var now = 0;
      final mem = AutoMemory();
      final p = _flap();
      final r1 = _Run(p, {'s::a': 30, 's::b': 60}, mem, () => now);
      await r1.auto.check();
      r1.alive.remove('s::a');
      now += _min;
      await r1.auto.check();
      expect(r1.route('A')['strikes'], 1);
      expect(mem.route('A').health.fails, 1);
      mem.unstableCount = 3;
      r1.auto.networkChanged();
      expect([r1.route('A')['strikes'], r1.j['unstable'], r1.j['lastUnstable']], [0, 0, null]);
      expect(mem.route('A').health.fails, 1, reason: 'what was learned about the route stays');
      r1.auto.stop();
    });

    test('a move up to a server that missed in the old service is `back`, not `preferred`', () async {
      Future<List<String>> run(bool shared) async {
        var now = 0;
        final mem = AutoMemory();
        final pl = plan([unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p1')], auto: {'returnTo': 'faster'});
        final r1 = _Run(pl, {'s::p1': 40, 's::p2': 60}, mem, () => now);
        await r1.auto.check();
        r1.alive.remove('s::p1');
        await r1.auto.check();
        await r1.auto.check();
        expect(r1.j['server'], 's::p2');
        r1.auto.stop();

        // a new service on p2 (what sing-box kept); p1 is slow, then fast
        final pl2 = plan([unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p2')], auto: {'returnTo': 'faster'});
        final r2 = _Run(pl2, {'s::p1': 200, 's::p2': 60}, shared ? mem : AutoMemory(), () => now);
        final ev = <AutoSwitch>[];
        r2.auto.switches.listen(ev.add);
        for (var i = 0; i < 4; i++) {
          now += 10000;
          await r2.auto.check();
        }
        expect(r2.j['server'], 's::p2', reason: 'p1 is slower than p2 + threshold: held');
        r2.alive['s::p1'] = 10;
        for (var i = 0; i < 2; i++) {
          now += 10000;
          await r2.auto.check();
        }
        await Future<void>.delayed(Duration.zero);
        expect(r2.j['server'], 's::p1');
        return [for (final e in ev) '${e.from}>${e.to} ${e.reason}'];
      }

      expect(await run(true), ['s::p2>s::p1 back']);
      expect(await run(false), ['s::p2>s::p1 preferred'], reason: 'the control: a memory of its own has not seen p1 miss');
    });
  });

  group('AutoMemory', () {
    test('the network: the first look and the same network change nothing; another id / type / epoch starts the flap guard over', () {
      final m = AutoMemory();
      m.route('A').strikes = 2;
      m.target('T').strikes = 1;
      m.unstableCount = 1;
      expect(m.network('wifi|home', 1), isFalse);
      expect(m.network('wifi|home', 1), isFalse);
      expect(m.route('A').strikes, 2);
      expect(m.network('|', 1), isFalse, reason: 'the platform has not said: nothing is judged');
      expect(m.network('wifi|work', 1), isTrue);
      expect([m.route('A').strikes, m.target('T').strikes, m.unstableCount], [0, 0, 0]);
      m.route('A').strikes = 1;
      expect(m.network('wifi|work', 2), isTrue, reason: 'the Sentinel saw it move (the epoch)');
      expect(m.route('A').strikes, 0);
    });

    test('a network that changed while the app was closed: the file knows the last one', () {
      final m = AutoMemory();
      m.route('A')
        ..health.record(40, 1000)
        ..strikes = 2;
      m.network('wifi|home', 1);
      final json = jsonDecode(jsonEncode(m.toJson(2000)));
      final same = AutoMemory()..load(json, 2000);
      expect(same.route('A').strikes, 2);
      expect(same.network('wifi|home', 0), isFalse);
      expect(same.route('A').strikes, 2);
      final other = AutoMemory()..load(json, 2000);
      expect(other.network('wifi|work', 0), isTrue);
      expect([other.route('A').strikes, other.route('A').health.ms], [0, 40], reason: 'strikes go, the answer stays');
    });

    test('round trip: health, missed, routes, targets and the unstable count; unseen for keepFor is left out; unreadable is skipped', () {
      final m = AutoMemory();
      m.server('R|m|k1')
        ..record(40, 5000)
        ..record(-1, 6000);
      m.server('R|m|never'); // never checked: not kept
      m.markMissed('R|m|k1', 6000);
      m.route('R')
        ..health.record(30, 7000)
        ..up = true
        ..strikes = 2;
      m.target('proxy')
        ..health.record(-1, 8000)
        ..strikes = 1
        ..usedSince = 7500;
      m.unstableCount = 4;
      m.lastUnstable = const AutoUnstable(id: 'R', strikes: 2, holdMs: 120000, at: 6500);
      m.markMissed('R|m|old', 1);
      final json = jsonDecode(jsonEncode(m.toJson(9000))) as Map<String, dynamic>;
      expect((json['servers'] as List), hasLength(1));
      expect((json['missed'] as List).map((e) => e['k']), ['R|m|k1', 'R|m|old']);

      final n = AutoMemory();
      expect(n.load(json, 9000), 3);
      expect([n.server('R|m|k1').ms, n.server('R|m|k1').fails, n.server('R|m|k1').oks, n.server('R|m|k1').at], [-1, 1, 0, 6000]);
      expect(n.hasMissed('R|m|k1'), isTrue);
      expect([n.route('R').health.ms, n.route('R').up, n.route('R').strikes], [30, true, 2]);
      expect([n.target('proxy').health.fails, n.target('proxy').strikes, n.target('proxy').usedSince], [1, 1, 7500]);
      expect([n.unstableCount, n.lastUnstable?.id, n.lastUnstable?.holdMs], [4, 'R', 120000]);
      expect(jsonEncode(n.toJson(9000)), jsonEncode(m.toJson(9000)));

      // a month unseen: out
      final late = AutoMemory(keepFor: const Duration(days: 30));
      expect(late.load(json, 9000 + 31 * 24 * 60 * _min), 0);
      expect(late.hasMissed('R|m|k1'), isFalse);
      // garbage in the file is skipped, not thrown
      expect(AutoMemory().load('nope', 1), 0);
      expect(AutoMemory().load({'servers': [1, {'k': 3}, {'k': 'x'}], 'routes': 'x'}, 1), 0);
    });

    test('retainNodes: the entries of a node gone from the catalog go, a pair needs both of its nodes', () {
      final m = AutoMemory();
      m.server('R|m|aaa').record(40, 1);
      m.server('R|m|bbb').record(40, 1);
      m.server('R|m|aaa>bbb').record(40, 1);
      m.server('R|m|aaa>ccc').record(40, 1);
      m.markMissed('R|e|ccc', 1);
      m.markMissed('R|e|aaa', 1);
      m.route('R').health.record(30, 1);
      expect(m.retainNodes({'aaa', 'bbb'}), 2);
      expect(m.hasMissed('R|e|aaa'), isTrue);
      expect(m.hasMissed('R|e|ccc'), isFalse);
      expect(m.toJson(2)['servers'].map((e) => e['k']), ['R|m|aaa', 'R|m|bbb', 'R|m|aaa>bbb']);
      expect(m.toJson(2)['routes'], hasLength(1), reason: 'a route is not a node');
    });
  });

  group('AutoMemoryStore', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('jorm-automem'));
    tearDown(() => dir.delete(recursive: true));

    test('written a moment after a change and at close; read back by a new store', () async {
      final f = File(p.join(dir.path, 'auto-state.json'));
      var now = 10000;
      final m = AutoMemory();
      final s = AutoMemoryStore(f, m, clock: () => now, debounce: const Duration(milliseconds: 10));
      expect(s.load(), 0, reason: 'no file: nothing known');
      m.route('R')
        ..health.record(40, now)
        ..strikes = 1;
      m.changed();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(f.existsSync(), isTrue);
      m.target('proxy').health.record(-1, now);
      m.changed();
      await s.close();

      final m2 = AutoMemory();
      expect(AutoMemoryStore(File(f.path), m2, clock: () => now).load(), 2);
      expect([m2.route('R').strikes, m2.target('proxy').health.fails], [1, 1]);
      f.writeAsStringSync('{broken');
      expect(AutoMemoryStore(f, AutoMemory(), clock: () => now).load(), 0, reason: 'a damaged file = nothing known');
    });

    test('two services share one memory through the store: what the first learned is in the second', () async {
      final f = File(p.join(dir.path, 'auto-state.json'));
      var now = 0;
      final m = AutoMemory();
      final s = AutoMemoryStore(f, m, clock: () => now, debounce: const Duration(milliseconds: 10));
      final pl = _flap();
      final r1 = _Run(pl, {'s::a': 30, 's::b': 60}, m, () => now);
      await r1.auto.check();
      r1.alive.remove('s::a');
      now += _min;
      await r1.auto.check();
      expect(r1.route('A')['strikes'], 1);
      r1.auto.stop();
      await s.close(); // the app closes

      // the app starts again: a memory from the file, a service on it
      final m2 = AutoMemory();
      AutoMemoryStore(f, m2, clock: () => now).load();
      final r2 = _Run(pl, {'s::a': 30, 's::b': 60}, m2, () => now);
      expect(r2.route('A')['strikes'], 1);
      expect(m2.route('A').up, isFalse);
    });
  });

  group('FallbackService', () {
    Map<String, dynamic> pl() => {
          'routes': [unit('A', ['s::a'])],
          'current': 0,
          'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': true},
          'routing': {
            'fallback': 'main',
            'targets': {'src:x': unit('src:x', ['s::x1'])},
            'rules': [
              {
                'id': 'r1',
                'name': '',
                'on': true,
                'action': 'proxy',
                'target': 'src:x',
                'fallback': 'block',
                'dns': 'auto',
                'groups': {
                  'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}},
                },
              },
            ],
          },
        };

    (FallbackService, FakeBox) make(AutoMemory mem, int Function() clock, Map<String, int> alive, {bool onFallback = false}) {
      final info = RoutingInfo();
      final fake = FakeBox(buildConfig(pl(), info: info), alive);
      if (onFallback) fake.groups['src:x~block']!.now = 'block'; // sing-box kept the selector on the fallback
      final svc = FallbackService(fake, info.fallbacks,
          delay: fake.delayTest,
          settings: const AutoSettings(failAfter: 2, flapGuard: true, stallAfter: Duration(milliseconds: 30)),
          pool: ProbePool.solo(clock: clock, ladder: DeadLadder(steps: const [Duration.zero])),
          clock: clock,
          memory: mem);
      return (svc, fake);
    }

    test('the strikes of a target that dropped and its hold go to the next service; a change of the network clears them', () async {
      var now = 1000000;
      final mem = AutoMemory();
      final (s1, f1) = make(mem, () => now, {});
      await s1.check();
      await s1.check();
      expect(f1.groups['src:x~block']!.now, 'block');
      expect(mem.target('src:x').strikes, 1, reason: 'the drop is a strike');
      s1.stop();

      // a new service, the target answers; sing-box kept the selector on the fallback
      final (s2, f2) = make(mem, () => now, {'s::x1': 40}, onFallback: true);
      for (var i = 0; i < 3; i++) {
        now += 5000;
        await s2.check();
      }
      expect(f2.groups['src:x~block']!.now, 'block', reason: 'answers, but the hold of the first drop is not served');
      now += 61000;
      await s2.check();
      expect(f2.groups['src:x~block']!.now, 'src:x');
      s2.stop();

      // the control: no memory, no hold
      final (s3, f3) = make(AutoMemory(), () => now, {'s::x1': 40}, onFallback: true);
      await s3.check();
      await s3.check();
      expect(f3.groups['src:x~block']!.now, 'src:x');

      // the strikes and a network change
      mem.target('src:x').strikes = 2;
      mem.network('wifi|home', 1);
      mem.network('wifi|work', 1);
      expect(mem.target('src:x').strikes, 0);
    });
  });

  group('CoreService', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-automem-svc'));
    tearDown(() => tmp.delete(recursive: true));

    CoreService core(String dataDir) => CoreService(singBox: 'none', dataDir: dataDir, resolveAddresses: false, isElevated: () => true);

    test('a new core on the same data dir starts from the file; the servers of nodes gone from the catalog are dropped', () async {
      final dir = p.join(tmp.path, 'data');
      Directory(dir).createSync(recursive: true);
      final known = serverIdentity({'o': 'a1'}), gone = serverIdentity({'o': 'zz'});
      final at = DateTime.now().millisecondsSinceEpoch - 1000;
      File(p.join(dir, 'ui-state.json')).writeAsStringSync(jsonEncode({
        'sourcesData': {
          'a': {
            'id': 'a',
            'kind': 'sub',
            'name': 'A',
            'enabled': true,
            'nodes': [
              {'id': 'a1', 'name': 'a1', 'protocol': 'vless', 'address': 'a1.example', 'port': 443, 'outbound': {'o': 'a1'}},
            ],
          },
        },
        'sourceOrder': ['a'],
      }));
      File(p.join(dir, 'auto-state.json')).writeAsStringSync(jsonEncode({
        'v': 1,
        'unstable': {'count': 2, 'last': {'id': 'R', 'strikes': 2, 'hold': 60000, 'at': at}},
        'servers': [
          {'k': 'R|m|$known', 'ms': 40, 'fails': 0, 'oks': 3, 'at': at},
          {'k': 'R|m|$gone', 'ms': 40, 'fails': 0, 'oks': 3, 'at': at},
        ],
        'routes': [
          {'k': 'R', 'ms': 30, 'fails': 0, 'oks': 1, 'at': at, 'up': true, 'strikes': 1},
        ],
      }));
      final svc = core(dir);
      await svc.init();
      final j = svc.autoMemory.toJson(DateTime.now().millisecondsSinceEpoch);
      expect([for (final e in j['servers'] as List) e['k']], ['R|m|$known']);
      expect(svc.autoMemory.route('R').strikes, 1);
      expect(svc.autoMemory.unstableCount, 2);
      await svc.dispose();
      // closed: written again, the same content
      final again = jsonDecode(File(p.join(dir, 'auto-state.json')).readAsStringSync()) as Map;
      expect(again['unstable'], containsPair('count', 2));
    });

    test('a catalog with no nodes at all (or unreadable) keeps the memory as it is', () async {
      final dir = p.join(tmp.path, 'data');
      Directory(dir).createSync(recursive: true);
      final at = DateTime.now().millisecondsSinceEpoch - 1000;
      File(p.join(dir, 'auto-state.json')).writeAsStringSync(jsonEncode({
        'v': 1,
        'servers': [
          {'k': 'R|m|abc', 'ms': 40, 'fails': 0, 'oks': 3, 'at': at},
        ],
      }));
      final svc = core(dir);
      await svc.init();
      expect(svc.autoMemory.toJson(at + 1)['servers'], hasLength(1));
      await svc.dispose();
    });
  });
}
