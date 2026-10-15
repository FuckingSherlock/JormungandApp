// A switch of the network (Wi-Fi → Wi-Fi, the connection back): the Sentinel context's disturbance (`stable`, `switching`,
// `failureInSwitch`, `proved`), the gate (`Sentinel.networkGate`), and what holds by it — Auto's rounds and requests, the
// failure book, the Sentinel's judgement and the targets of FallbackService. Nothing is dropped: every held failure is
// counted and told (docs/failures.md → Сеть).
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, everyRound, plan, unit;
import 'sentinel_fakes.dart';

ClosedConnection _closed({String dest = 'blocked.example:443', int up = 0, int down = 0, int? ms = 500, String inbound = 'tun-in'}) => ClosedConnection(
    outbound: 'route0/s::a', chain: const ['route0/s::a', 'route0', 'proxy'], destination: dest, up: up, down: down, network: 'tcp', inbound: inbound, durationMs: ms);

int _ms(DateTime t) => t.millisecondsSinceEpoch;

void main() {
  group('the context: the disturbance of a switch', () {
    late FakeTime time;
    late ContextTracker ctx;

    setUp(() {
      time = FakeTime();
      ctx = ContextTracker(clock: time.clock);
    });

    test('another network id (no loss of connection in between) is a move: unstable until data comes in on the new network', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      expect((ctx.stable, ctx.switching, ctx.lastMove), (true, false, null), reason: 'the first look is not a move');
      final epoch = ctx.netEpoch;
      await time.advanceSeconds(30);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect(ctx.network.state, NetState.up, reason: 'never none in between');
      expect(ctx.netEpoch, epoch + 1);
      expect((ctx.stable, ctx.switching), (false, true));
      expect(ctx.lastMove, time.t);
      ctx.proved(since: _ms(time.t) - 1000);
      expect(ctx.stable, isFalse, reason: 'a request opened before the move is the old network\'s');
      await time.advanceSeconds(2);
      ctx.proved(since: _ms(time.t) - 500);
      expect((ctx.stable, ctx.switching, ctx.stableBy), (true, false, 'event'));
      expect(ctx.stableAt, time.t);
    });

    test('validated is not asked for: a network that never validates is stable with data coming in; validated alone is not enough', () async {
      ctx.platform(connected: true, validated: false, type: 'wifi', id: 'A');
      await time.advanceSeconds(10);
      ctx.platform(connected: true, validated: false, type: 'wifi', id: 'B');
      expect(ctx.stable, isFalse);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect(ctx.stable, isFalse, reason: 'validated without any data coming in is not the event');
      await time.advanceSeconds(3);
      ctx.platform(connected: true, validated: false, type: 'wifi', id: 'B');
      ctx.proved(since: _ms(time.t));
      expect((ctx.stable, ctx.stableBy), (true, 'event'), reason: 'connected and not a portal + data');
    });

    test('a portal or a lost connection keeps it open even with data; the cap ends a disturbance nothing proved', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      await time.advanceSeconds(10);
      ctx.platform(connected: true, validated: false, captive: true, type: 'wifi', id: 'B');
      ctx.proved(since: _ms(time.t));
      expect(ctx.stable, isFalse);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      await time.advanceSeconds(29);
      expect(ctx.stable, isFalse, reason: 'the cap starts over from the portal\'s end');
      await time.advanceSeconds(3);
      expect((ctx.stable, ctx.stableBy), (true, 'cap'));
    });

    test('no platform signal (Windows): the interface line opens it, any data ends it, noSignalGrace is only the cap', () async {
      ctx.starting('userConnect');
      ctx.interfaceChanged(); // `updated default interface Ethernet` at the start
      ctx.started();
      expect((ctx.stable, ctx.lastMove, ctx.signalKnown), (true, null, false), reason: 'the start\'s own line is not a move');
      await time.advanceSeconds(30);
      ctx.interfaceChanged();
      expect((ctx.stable, ctx.lastMove), (false, time.t));
      await time.advanceSeconds(1);
      ctx.proved(since: _ms(time.t));
      expect((ctx.stable, ctx.stableBy), (true, 'event'));
      final moved = ctx.lastMove;
      await time.advanceSeconds(30);
      ctx.interfaceChanged();
      await time.advanceSeconds(11);
      expect((ctx.stable, ctx.stableBy), (true, 'cap'), reason: 'nothing proved it: the cap');
      ctx.crashed();
      ctx.interfaceChanged(); // the restart's own
      expect((ctx.stable, ctx.lastMove == moved), (true, false));
      final last = ctx.lastMove;
      ctx.crashed();
      ctx.interfaceChanged();
      expect(ctx.lastMove, last);
    });

    test('failureInSwitch: closed before the drop is a candidate; at/after it while unstable is the network\'s; an old connection after, for oldConnTail', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      await time.advanceSeconds(100);
      final drop = _ms(time.t) - 2000; // the system dated it 2 s ago
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B', at: drop);
      expect(ctx.lastMove, DateTime.fromMillisecondsSinceEpoch(drop));
      expect(ctx.failureInSwitch(closedAt: drop - 1000), isFalse, reason: 'closed before the drop: a real failure candidate');
      expect(ctx.failureInSwitch(closedAt: drop + 500), isTrue);
      expect(ctx.failureInSwitch(durationMs: 100), isTrue, reason: 'closed now (after the drop), unstable');
      await time.advanceSeconds(1);
      ctx.proved(since: _ms(time.t) - 100); // stable now
      expect(ctx.failureInSwitch(durationMs: 100), isFalse, reason: 'opened and closed on the stable new network: judged as usual');
      expect(ctx.failureInSwitch(durationMs: 30000), isTrue, reason: 'opened before the drop: the old network\'s dead socket');
      expect(ctx.failureInSwitch(openedAt: drop - 5000), isTrue);
      expect(ctx.failureInSwitch(openedAt: drop + 600), isFalse);
      await time.advanceSeconds(61);
      expect(ctx.failureInSwitch(durationMs: 120000), isFalse, reason: 'oldConnTail is over');
    });

    test('the none of the platform is a switching state, the none of the probes is not (Auto\'s own verdict)', () async {
      ctx.pool(NetStatus.down, osOffline: false);
      await time.advanceSeconds(20);
      expect((ctx.network.source, ctx.switching), ('probes', false));
      ctx.pool(NetStatus.up, osOffline: false);
      expect((ctx.stable, ctx.lastMove, ctx.switching), (true, null, false), reason: 'Auto\'s own verdict recovering is not the device arriving');
      ctx.platform(connected: false);
      final dropped = time.t;
      await time.advanceSeconds(20);
      expect((ctx.network.state, ctx.outage, ctx.switching), (NetState.none, true, true));
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect((ctx.stable, ctx.lastMove, ctx.switching), (false, dropped, true), reason: 'the connection back is a move of the same disturbance, dated by the drop');
    });
  });

  group('the gate', () {
    late FakeTime time;
    late Sentinel sentinel;
    var probes = 0;
    bool? answer = true;

    setUp(() {
      time = FakeTime();
      probes = 0;
      answer = true;
      sentinel = Sentinel(clock: time.clock, note: (l, t) {}, netProbe: () async {
        probes++;
        return answer;
      });
      addTearDown(sentinel.dispose);
    });

    test('a stable network with a platform signal is answered from the context, no probe', () async {
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      final g = await sentinel.networkGate();
      expect((g.allow, probes), (true, 0));
    });

    test('platform signal known, a move not proved: the gate holds (failures preceded the signal), a probe that answers proves the network', () async {
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      await time.advanceSeconds(20);
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      answer = null; // cannot be tested: nothing proved
      var g = await sentinel.networkGate();
      expect((g.allow, g.switching, probes), (false, true, 1));
      answer = true;
      await time.advanceSeconds(1);
      g = await sentinel.networkGate();
      expect((g.allow, probes), (true, 2), reason: 'the answered probe is data on the new network');
      expect(sentinel.context.stableBy, 'event');
    });

    test('validated:false with data coming in: stable (and asked, since the platform is fine)', () async {
      sentinel.context.platform(connected: true, validated: false, type: 'wifi', id: 'A');
      await time.advanceSeconds(20);
      sentinel.context.platform(connected: true, validated: false, type: 'wifi', id: 'B');
      final g = await sentinel.networkGate();
      expect((g.allow, probes), (true, 1));
    });

    test('Windows-like (no platform signal): the gate probes before allowing; a silent probe is an outage, not a switch', () async {
      var g = await sentinel.networkGate();
      expect((g.allow, probes), (true, 1));
      answer = false;
      g = await sentinel.networkGate();
      expect((g.allow, g.outage, g.switching, probes), (false, true, false, 2));
    });

    test('a platform outage is answered without a probe', () async {
      sentinel.context.platform(connected: false);
      final g = await sentinel.networkGate();
      expect((g.allow, g.outage, probes), (false, true, 0));
    });
  });

  group('FailureBook: a failure of a switch is counted and told, never a streak', () {
    test('held failures: counted in failed10m and netSwitch, told one by one, no event however many; the same failures later are reported', () async {
      var t = DateTime.utc(2026, 10, 10, 12);
      var inSwitch = true;
      final reports = <FailureReport>[];
      final told = <String>[];
      final b = FailureBook(
        now: () => t,
        report: (r) async {
          reports.add(r);
          return 1;
        },
        netSwitch: (c) => inSwitch,
        netHeld: (c, o) => told.add('${c.destination} ${o.kind.name}'),
      )..start();
      for (var i = 0; i < 8; i++) {
        b.onClosed(_closed());
        t = t.add(const Duration(seconds: 1));
      }
      await Future<void>.delayed(Duration.zero);
      expect(reports, isEmpty, reason: 'no streak, no suspicion');
      expect(told.length, 8, reason: 'every failure has its line');
      final j = b.toJson();
      expect([j['netSwitch'], j['failed10m'], j['entries'], j['events']], [8, 8, 0, 0]);
      inSwitch = false;
      for (var i = 0; i < 8; i++) {
        b.onClosed(_closed());
        t = t.add(const Duration(seconds: 1));
      }
      await Future<void>.delayed(Duration.zero);
      expect(reports, isNotEmpty, reason: 'out of the switch the same failures are judged as always');
      expect(b.toJson()['netSwitch'], 8);
      b.stop();
    });
  });

  group('Auto', () {
    ClosedConnection cc({String dest = 'blocked.example:443', int up = 120, int? ms = 500}) => _closed(dest: dest, up: up, ms: ms);

    test('rounds held while the network is not stable: nobody is marked or left, they are told and counted; once stable a dead route fails over', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      var stable = true;
      final asked = <bool>[];
      final notes = <String>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          pool: everyRound(),
          netGate: ({bool suspicious = false}) async {
            asked.add(suspicious);
            return NetGate(stable: stable);
          },
          note: notes.add);
      await auto.check();
      fake.alive.remove('s::a'); // the old network's connections and transport: A does not answer for now
      stable = false;
      for (var i = 0; i < 4; i++) {
        await auto.check();
      }
      var j = auto.toJson();
      expect([j['now'], j['netHeldRounds'], j['noNet']], ['A', 4, false], reason: 'four failAfter-2 rounds, none judged');
      expect(notes.where((n) => n.contains('the network is changing')).length, 4);
      expect(fake.groups['proxy']!.now, 'route0');
      expect(asked, isNotEmpty, reason: 'the gate is asked when the route in use does not answer');
      stable = true; // the network proved itself and A is really dead
      await auto.check();
      await auto.check();
      j = auto.toJson();
      expect([j['now'], j['netHeldRounds']], ['B', 4], reason: 'judged as usual: failAfter misses, then the failover');
    });

    test('a dead route on a stable network fails over promptly (the gate allows)', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), netGate: ({bool suspicious = false}) async => const NetGate(stable: true));
      await auto.check();
      fake.alive.remove('s::a');
      await auto.check();
      await auto.check();
      final j = auto.toJson();
      expect([j['now'], j['netHeldRounds']], ['B', 0]);
    });

    test('the gate holds the failover when every route missed and the network is not proven (the platform signal came after the failures)', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      final asked = <bool>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          pool: everyRound(),
          netGate: ({bool suspicious = false}) async {
            asked.add(suspicious);
            return const NetGate(stable: false);
          });
      await auto.check();
      fake.alive.remove('s::a');
      fake.alive.remove('s::b');
      for (var i = 0; i < 3; i++) {
        await auto.check();
      }
      expect(asked, isNotEmpty);
      final j = auto.toJson();
      expect([j['now'], j['netHeldRounds'] > 0], ['A', true]);
    });

    test('a route that answers is not held, and an answer ends the hold', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), netGate: ({bool suspicious = false}) async => const NetGate(stable: false));
      await auto.check();
      await auto.check();
      expect(auto.toJson()['netHeldRounds'], 0);
      expect(auto.checkedAt, isNotNull);
    });

    test('requests that the switch closed (old connection, or inside the window): requestFailsNet, not requestFails, no check, no site', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final told = <AutoSiteFail>[];
      final notes = <String>[];
      var inSwitch = true;
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          clock: () => 0,
          reach: (tag, dest) async => false,
          netSwitch: (c) => inSwitch,
          note: notes.add,
          settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.siteFails.listen(told.add);
      await auto.check();
      auto.onClosed(cc(ms: 90000));
      auto.onClosed(cc(dest: 'other.example:443', up: 0));
      expect([auto.requestFails, auto.requestFailsNet, auto.lastRequestFail], [0, 2, isNull]);
      expect(auto.toJson()['requestFailsNet'], 2);
      expect(notes.where((n) => n.contains('while the network changes')).length, 2, reason: 'a line for each');
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect([auto.siteFailCount, told], [0, isEmpty], reason: 'a held request is not remembered as a site');
      inSwitch = false;
      auto.onClosed(cc());
      expect(auto.requestFails, 1, reason: 'out of the window the same request is the route\'s');
    });

    test('up == 0 failures are remembered too, and their sites are tried only if the route answered', () async {
      Future<(AutoService, FakeBox)> run({required bool routeAnswers}) async {
        final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
        final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
        final auto = AutoService(fake, p,
            delay: fake.delayTest, pool: everyRound(), clock: () => 7, reach: (tag, dest) async => false, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
        await auto.check();
        auto.onClosed(cc(up: 0));
        if (!routeAnswers) fake.alive.remove('s::a');
        await auto.check();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return (auto, fake);
      }

      final (answers, _) = await run(routeAnswers: true);
      expect([answers.requestFails, answers.siteFailCount, answers.lastSiteFail?.dest], [1, 1, 'blocked.example:443'], reason: 'it sent nothing and is still told');
      final (dead, _) = await run(routeAnswers: false);
      expect([dead.requestFails, dead.siteFailCount], [1, 0], reason: 'the route did not answer: the node is at fault, not the site');
    });
  });

  group('FallbackService: a target is not judged while the network is not stable', () {
    Map<String, dynamic> planWith() => {
          'routes': [unit('A', ['s::a'])],
          'current': 0,
          'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
          'routing': {
            'fallback': 'main',
            'targets': {'src:x': unit('src:x', ['s::x1', 's::x2'])},
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

    test('misses before the network is stable are not counted and no fallback happens, the round is repeated; after it the miss counts', () async {
      final info = RoutingInfo();
      final fake = FakeBox(buildConfig(planWith(), info: info), {});
      var stable = false;
      final svc = FallbackService(fake, info.fallbacks,
          delay: fake.delayTest,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, stallAfter: Duration(milliseconds: 30)),
          pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])),
          netGate: ({bool suspicious = false}) async => NetGate(stable: stable));
      for (var i = 0; i < 4; i++) {
        await svc.check();
      }
      expect(fake.groups['src:x~block']!.now, 'src:x', reason: 'four rounds of misses, none counted');
      stable = true;
      await svc.check();
      await svc.check();
      expect(fake.groups['src:x~block']!.now, 'block', reason: 'dead on a stable network: failAfter misses, then the fallback');
      svc.stop();
    });
  });

  group('Sentinel: net.switched', () {
    Suspicion suspicion(Duration window) => Suspicion(
        kind: 'conn.failing',
        subject: const {'app': 'org.x', 'host': 'a.com', 'route': 'A'},
        evidence: const {'count': 3, 'kind': 'timeout'},
        checks: const [],
        window: window,
        why: const Why('conn.timeout'),
        event: const SuspicionEvent('conn', 'failing'));

    late FakeTime time;
    late Sentinel sentinel;

    setUp(() async {
      time = FakeTime();
      sentinel = Sentinel(clock: time.clock, book: EventBook(null, clock: () => time.t), note: (l, t) {});
      addTearDown(sentinel.dispose);
      sentinel.context.starting('userConnect');
      sentinel.context.started();
      await time.advanceSeconds(6);
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'A');
    });

    test('a failure that began before the drop waits until the network is stable, then is judged at once (its window ran on the old clock)', () async {
      Verdict? v;
      unawaited(sentinel.suspect(suspicion(const Duration(seconds: 20))).then((x) => v = x));
      await time.advanceSeconds(5);
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'B'); // 5 s in: the drop
      await time.advanceSeconds(25); // 30 s since the failure began: its window is long over, the network is not stable
      expect(v, isNull, reason: 'a candidate: its check waits until the network is stable');
      sentinel.context.proved(since: _ms(time.t));
      await time.advanceSeconds(1);
      expect(v?.kind, VerdictKind.confirmed);
      final trail = [for (final t in v!.trail) t.code];
      expect(trail, containsAllInOrder(['suspect', 'net.switched', 'persist.window']));
      expect(v!.trail.firstWhere((t) => t.code == 'net.switched').params['stable'], false);
    });

    test('a failure that began in the disturbance must last its window after the network is stable', () async {
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'B'); // the drop
      await time.advanceSeconds(2);
      Verdict? v;
      unawaited(sentinel.suspect(suspicion(const Duration(seconds: 20))).then((x) => v = x));
      await time.advanceSeconds(3);
      sentinel.context.proved(since: _ms(time.t)); // stable 5 s after the drop
      await time.advanceSeconds(19);
      expect(v, isNull, reason: 'the window starts over from the stable moment');
      await time.advanceSeconds(3);
      expect(v?.kind, VerdictKind.confirmed);
      final step = v!.trail.firstWhere((t) => t.code == 'net.switched' && t.params['by'] != null);
      expect(step.params['by'], 'event');
    });
  });
}
