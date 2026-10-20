// AutoService.reorder / FallbackService.reorder: a new Priority order applied to a running group
// without restarting sing-box (docs/connect-model.md, "Порядок Priority — вживую").
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, chain, plan, unit;

class _Box extends FakeBox {
  _Box(super.config, super.alive);
  final selects = <String>[]; // 'group>outbound' of every select, in order
  @override
  Future<bool> select(String group, String outbound) {
    selects.add('$group>$outbound');
    return super.select(group, outbound);
  }
}

(AutoService, _Box, List<AutoSwitch>) _rig(Map<String, dynamic> p, Map<String, int> alive, {DelayTest? gate}) {
  final fake = _Box(buildConfig(p), alive);
  final auto = AutoService(fake, p,
      delay: gate == null ? fake.delayTest : (t, u, ms) async => gate(t, u, ms),
      pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])));
  final events = <AutoSwitch>[];
  auto.switches.listen(events.add);
  return (auto, fake, events);
}

Map<String, dynamic> _prio(List<String> keys, String chosen) => plan([unit('P', keys, pick: 'priority', chosen: chosen)]);

void main() {
  const keys3 = ['s::p1', 's::p2', 's::p3'];
  final allAlive = {'s::p1': 50, 's::p2': 60, 's::p3': 70};

  group('AutoService.reorder', () {
    test('the current server keeps first place among the alive: no select, no event', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0', ['s::p1', 's::p3', 's::p2']), isTrue);
      await auto.check();
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, isEmpty);
      expect(events, isEmpty);
      expect(fake.groups['route0']!.now, 'route0/s::p1');
    });

    test('a live server moved above the current: one select to it and the usual auto/switched', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0', ['s::p3', 's::p1', 's::p2']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, ['route0>route0/s::p3']);
      expect(fake.groups['route0']!.now, 'route0/s::p3');
      expect(auto.toJson()['server'], 's::p3');
      expect([for (final e in events) '${e.route}: ${e.from}>${e.to} ${e.reason}'], ['P: s::p1>s::p3 back']);
      await auto.check();
      await auto.check();
      expect(fake.selects, hasLength(1), reason: 'settled: later rounds do not move it again');
    });

    test('of several moved above, the first alive one in the new order wins', () async {
      final (auto, fake, _) = _rig(_prio(keys3, 's::p3'), {'s::p1': 50, 's::p3': 70}); // p2 silent
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0', ['s::p2', 's::p1', 's::p3']), isTrue);
      expect(fake.groups['route0']!.now, 'route0/s::p1', reason: 'p2 is above but does not answer');
      expect(fake.selects, ['route0>route0/s::p1']);
    });

    test('a dead server moved above does not switch by itself', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), {'s::p1': 50, 's::p3': 70}); // p2 dead
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0', ['s::p2', 's::p1', 's::p3']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, isEmpty);
      expect(events, isEmpty);
      expect(fake.groups['route0']!.now, 'route0/s::p1');
    });

    test('an untested server moved above does not switch (reorder before any round)', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), allAlive);
      expect(await auto.reorder('route0', ['s::p2', 's::p1', 's::p3']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, isEmpty);
      expect(events, isEmpty);
    });

    test('the new order is what failover and back read from then on', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      expect(await auto.reorder('route0', ['s::p1', 's::p3', 's::p2']), isTrue);
      fake.alive.remove('s::p1');
      await auto.check();
      await auto.check();
      expect(auto.toJson()['server'], 's::p3', reason: 'the next in the NEW order, not p2');
      fake.alive['s::p1'] = 50;
      await auto.check();
      await auto.check();
      expect(auto.toJson()['server'], 's::p1');
      await Future<void>.delayed(Duration.zero);
      expect([for (final e in events) '${e.from}>${e.to} ${e.reason}'], ['s::p1>s::p3 failover', 's::p3>s::p1 back']);
    });

    test('a chain: the entry group is reordered by its own tag, the exit group by its own', () async {
      final p = plan([
        {
          'id': 'X',
          'kind': 'chain',
          'entry': chain('X', ['s::e1', 's::e2'], ['s::x1', 's::x2'])['entry'],
          'main': chain('X', ['s::e1', 's::e2'], ['s::x1', 's::x2'])['main'],
        }
      ]);
      (p['routes'] as List).first['entry']['pick'] = 'priority';
      (p['routes'] as List).first['entry']['chosen'] = 's::e1';
      final (auto, fake, _) = _rig(p, {'s::e1': 10, 's::e2': 10, 's::x1': 10, 's::x2': 10});
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0-entry', ['s::e2', 's::e1']), isTrue);
      expect(fake.groups['route0-entry']!.now, 'route0-entry/s::e2');
    });

    test('an unknown tag: false, nothing changes', () async {
      final (auto, fake, _) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route9', ['s::p3', 's::p1', 's::p2']), isFalse);
      expect(await auto.reorder('nope', keys3), isFalse);
      expect(fake.selects, isEmpty);
    });

    test('a different key set (missing, extra, duplicate-padded): false and the order is unchanged', () async {
      final (auto, fake, events) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      fake.selects.clear();
      expect(await auto.reorder('route0', ['s::p3', 's::p1']), isFalse);
      expect(await auto.reorder('route0', ['s::p3', 's::p1', 's::p2', 's::p4']), isFalse);
      expect(await auto.reorder('route0', ['s::p3', 's::p1', 's::p9']), isFalse);
      expect(fake.selects, isEmpty, reason: 'rejected: no switch');
      // the order is still the old one: failover goes to p2, not to p3
      fake.alive.remove('s::p1');
      await auto.check();
      await auto.check();
      expect(auto.toJson()['server'], 's::p2');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
    });

    test('after stop: false, nothing selected', () async {
      final (auto, fake, _) = _rig(_prio(keys3, 's::p1'), allAlive);
      await auto.check();
      fake.selects.clear();
      auto.stop();
      expect(await auto.reorder('route0', ['s::p3', 's::p1', 's::p2']), isFalse);
      expect(fake.selects, isEmpty);
    });

    test('during a running round: the round ends, the switch follows the new order, no select to a stale pick', () async {
      final gate = Completer<void>();
      var hold = false;
      late _Box fakeRef;
      Future<int> delay(String tag, String url, int ms) async {
        if (hold) await gate.future;
        return fakeRef.delayTest(tag, url, ms);
      }

      final p = _prio(keys3, 's::p1');
      final (auto, fake, events) = _rig(p, allAlive, gate: delay);
      fakeRef = fake;
      await auto.check();
      fake.selects.clear();
      hold = true;
      final round = auto.check(); // blocked in the probes
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final re = auto.reorder('route0', ['s::p2', 's::p1', 's::p3']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      expect(await re, isTrue);
      await round;
      await auto.check();
      await Future<void>.delayed(Duration.zero);
      expect(fake.groups['route0']!.now, 'route0/s::p2');
      expect(fake.selects, ['route0>route0/s::p2'], reason: 'one select, to the new top; none to the old pick');
      expect([for (final e in events) '${e.from}>${e.to}'], ['s::p1>s::p2']);
    });

    test('during a failover round: the pick made lands in the new order', () async {
      final gate = Completer<void>();
      var hold = false;
      late _Box fakeRef;
      Future<int> delay(String tag, String url, int ms) async {
        if (hold) await gate.future;
        return fakeRef.delayTest(tag, url, ms);
      }

      final (auto, fake, _) = _rig(_prio(keys3, 's::p1'), allAlive, gate: delay);
      fakeRef = fake;
      await auto.check();
      fake.alive.remove('s::p1');
      await auto.check(); // one miss
      hold = true;
      final round = auto.check(); // the second miss, blocked
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final re = auto.reorder('route0', ['s::p1', 's::p3', 's::p2']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      expect(await re, isTrue);
      await round;
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::p3', reason: 'no failover to p2 from the old list');
    });
  });

  group('FallbackService.reorder', () {
    Map<String, dynamic> fplan() => {
          'routes': [unit('A', ['s::a'])],
          'current': 0,
          'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
          'routing': {
            'fallback': 'main',
            'targets': {'src:p': unit('src:p', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p1')},
            'rules': [
              {
                'id': 'r1',
                'name': '',
                'on': true,
                'action': 'proxy',
                'target': 'src:p',
                'fallback': 'block',
                'dns': 'auto',
                'groups': {
                  'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}},
                },
              }
            ],
          },
        };

    (FallbackService, _Box) frig(Map<String, int> alive) {
      final info = RoutingInfo();
      final fake = _Box(buildConfig(fplan(), info: info), alive);
      final svc = FallbackService(fake, info.fallbacks,
          delay: fake.delayTest,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, stallAfter: Duration(milliseconds: 30)),
          pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])));
      return (svc, fake);
    }

    test('unknown tag / a different key set: false; stopped: false', () async {
      final (svc, fake) = frig({'s::p1': 40, 's::p2': 60});
      await svc.check();
      fake.selects.clear();
      expect(await svc.reorder('src:nope', ['s::p2', 's::p1']), isFalse);
      expect(await svc.reorder('src:p', ['s::p2']), isFalse);
      expect(await svc.reorder('src:p', ['s::p2', 's::p1', 's::p3']), isFalse);
      expect(fake.selects, isEmpty);
      svc.stop();
      expect(await svc.reorder('src:p', ['s::p2', 's::p1']), isFalse);
    });

    test('the target\'s pick stays when it is still the highest alive: nothing selected', () async {
      final (svc, fake) = frig({'s::p1': 40, 's::p2': 60});
      await svc.check();
      fake.selects.clear();
      expect(await svc.reorder('src:p', ['s::p1', 's::p2']), isTrue);
      expect(fake.selects, isEmpty);
      expect(fake.groups['src:p']!.now, 'src:p/s::p1');
    });

    test('a live server above the pick: the target group is selected to it', () async {
      final (svc, fake) = frig({'s::p1': 40, 's::p2': 60});
      await svc.check();
      fake.selects.clear();
      expect(await svc.reorder('src:p', ['s::p2', 's::p1']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, ['src:p>src:p/s::p2']);
    });

    test('a dead server above the pick: no select', () async {
      final (svc, fake) = frig({'s::p1': 40});
      await svc.check();
      fake.selects.clear();
      expect(await svc.reorder('src:p', ['s::p2', 's::p1']), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fake.selects, isEmpty);
      expect(fake.groups['src:p']!.now, 'src:p/s::p1');
    });
  });
}
