// A switch of the network (Wi-Fi → Wi-Fi, the connection back): the Sentinel context's window (`settling`, `switching`,
// `failureInSwitch`), and what holds by it — Auto's rounds and requests, the failure book, the Sentinel's judgement and
// the targets of FallbackService. Nothing is dropped: every held failure is counted and told (docs/failures.md → Сеть).
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, everyRound, plan, unit;
import 'sentinel_fakes.dart';

ClosedConnection _closed({String dest = 'blocked.example:443', int up = 0, int down = 0, int? ms = 500, String inbound = 'tun-in'}) => ClosedConnection(
    outbound: 'route0/s::a', chain: const ['route0/s::a', 'route0', 'proxy'], destination: dest, up: up, down: down, network: 'tcp', inbound: inbound, durationMs: ms);

void main() {
  group('the context: the window of a switch', () {
    late FakeTime time;
    late ContextTracker ctx;

    setUp(() {
      time = FakeTime();
      ctx = ContextTracker(clock: time.clock);
    });

    test('another network id (no loss of connection in between) is a move: settling for switchGrace, then not', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      expect((ctx.settling, ctx.switching, ctx.lastMove), (false, false, null), reason: 'the first look is not a move');
      final epoch = ctx.netEpoch;
      await time.advanceSeconds(30);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect(ctx.network.state, NetState.up, reason: 'never none in between');
      expect(ctx.netEpoch, epoch + 1);
      expect((ctx.settling, ctx.switching), (true, true));
      expect(ctx.lastMove, time.t);
      await time.advanceSeconds(9);
      expect(ctx.settling, isTrue);
      await time.advanceSeconds(2);
      expect((ctx.settling, ctx.switching), (false, false));
    });

    test('failureInSwitch: inside the window every failure; after it only a connection opened before the move, for oldConnGrace', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      await time.advanceSeconds(100);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect(ctx.failureInSwitch(100), isTrue, reason: 'inside switchGrace');
      expect(ctx.failureInSwitch(null), isTrue);
      await time.advanceSeconds(15);
      expect(ctx.failureInSwitch(30000), isTrue, reason: 'opened 30 s ago, the move was 15 s ago: opened on the old network');
      expect(ctx.failureInSwitch(5000), isFalse, reason: 'opened on the new network after the grace: judged as usual');
      expect(ctx.failureInSwitch(null), isFalse, reason: 'age not told: only the window');
      await time.advanceSeconds(50); // 65 s after the move
      expect(ctx.failureInSwitch(120000), isFalse, reason: 'oldConnGrace is over');
    });

    test('the none of the platform is a switching state, the none of the probes is not (Auto\'s own verdict)', () async {
      ctx.pool(NetStatus.down, osOffline: false);
      await time.advanceSeconds(20);
      expect((ctx.network.source, ctx.switching), ('probes', false));
      ctx.pool(NetStatus.up, osOffline: false);
      expect((ctx.settling, ctx.lastMove, ctx.switching), (false, null, false), reason: 'Auto\'s own verdict recovering is not the device arriving');
      ctx.platform(connected: false);
      await time.advanceSeconds(20);
      expect((ctx.network.state, ctx.settling, ctx.switching), (NetState.none, false, true));
      ctx.platform(connected: true, validated: true, type: 'wifi', id: 'B');
      expect((ctx.settling, ctx.lastMove, ctx.switching), (true, time.t, true), reason: 'the connection back is a move');
    });

    test('the interface line sing-box writes while it starts is not a move; the one of a running core is', () async {
      ctx.starting('userConnect');
      ctx.interfaceChanged(); // `updated default interface Ethernet` at the start
      ctx.started();
      expect((ctx.settling, ctx.lastMove), (false, null));
      await time.advanceSeconds(30);
      ctx.interfaceChanged();
      expect((ctx.settling, ctx.lastMove), (true, time.t));
      await time.advanceSeconds(30);
      ctx.crashed();
      ctx.interfaceChanged(); // the restart's own
      expect(ctx.settling, isFalse);
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

    test('rounds held while the network settles: nobody is marked or left, they are told and counted; after the window a dead route fails over', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      var settling = false;
      final notes = <String>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), netSettling: () => settling, note: notes.add);
      await auto.check();
      fake.alive.remove('s::a'); // the old network's connections and transport: A does not answer for now
      settling = true;
      for (var i = 0; i < 4; i++) {
        await auto.check();
      }
      var j = auto.toJson();
      expect([j['now'], j['netHeldRounds'], j['noNet']], ['A', 4, false], reason: 'four failAfter-2 rounds, none judged');
      expect(notes.where((n) => n.contains('the network is changing')).length, 4);
      expect(fake.groups['proxy']!.now, 'route0');
      settling = false; // the grace is over and A is really dead
      await auto.check();
      await auto.check();
      j = auto.toJson();
      expect([j['now'], j['netHeldRounds']], ['B', 4], reason: 'judged as usual: failAfter misses, then the failover');
    });

    test('a route that answers is not held, and an answer ends the hold', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), netSettling: () => true);
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
          netSwitch: (age) => inSwitch,
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

  group('FallbackService: a target is not judged while the network switches', () {
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

    test('misses in the window are not counted and no fallback happens, the round is repeated; after it the miss counts', () async {
      final info = RoutingInfo();
      final fake = FakeBox(buildConfig(planWith(), info: info), {});
      var switching = true;
      final svc = FallbackService(fake, info.fallbacks,
          delay: fake.delayTest,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, stallAfter: Duration(milliseconds: 30)),
          pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])),
          netSwitching: () => switching);
      for (var i = 0; i < 4; i++) {
        await svc.check();
      }
      expect(fake.groups['src:x~block']!.now, 'src:x', reason: 'four rounds of misses, none counted');
      switching = false;
      await svc.check();
      await svc.check();
      expect(fake.groups['src:x~block']!.now, 'block', reason: 'dead after the window: failAfter misses, then the fallback');
      svc.stop();
    });
  });

  group('Sentinel: net.switched', () {
    test('a failure that spans a move is judged only when it has lasted its window after the grace', () async {
      final time = FakeTime();
      final book = EventBook(null, clock: () => time.t);
      final sentinel = Sentinel(clock: time.clock, book: book, note: (l, t) {});
      addTearDown(sentinel.dispose);
      sentinel.context.starting('userConnect');
      sentinel.context.started();
      await time.advanceSeconds(6);
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'A');
      Verdict? v;
      unawaited(sentinel
          .suspect(Suspicion(
              kind: 'conn.failing',
              subject: const {'app': 'org.x', 'host': 'a.com', 'route': 'A'},
              evidence: const {'count': 3, 'kind': 'timeout'},
              checks: const [],
              window: const Duration(seconds: 20),
              why: const Why('conn.timeout'),
              event: const SuspicionEvent('conn', 'failing')))
          .then((x) => v = x));
      await time.advanceSeconds(5);
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: 'B'); // 5 s in: the move
      await time.advanceSeconds(29); // 34 s: the 20 s window alone would have ended at 20, the move + grace + window ends at 35
      expect(v, isNull, reason: 'the new network is still settling and the window starts over after it');
      await time.advanceSeconds(3);
      expect(v?.kind, VerdictKind.confirmed);
      final trail = [for (final t in v!.trail) t.code];
      expect(trail, containsAllInOrder(['suspect', 'net.switched', 'persist.window']));
      expect(v!.trail.firstWhere((t) => t.code == 'net.switched').params['graceMs'], 10000);
    });
  });
}
