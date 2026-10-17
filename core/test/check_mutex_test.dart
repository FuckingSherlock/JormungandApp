// A manual check («Check now», docs/core.md POST /api/check-now) and the scheduled round of the same module never run
// at the same time: one waits for the other. AutoService.routeNow / roundNow and FallbackService.checkTarget against
// the fake sing-box of auto_test.dart; every delay test is counted while in flight and can be held on a gate.
// DnsFailover.checkServer / startPing against a fake DNS query (counted, held per server).
//
// Not covered here: CoreService.checkNow when Auto is replaced by a reconnect mid-run (-> notConnected, no
// data.recheck). It needs a whole CoreService with a fake runner and a second connect() (the harness is private to
// check_now_test.dart, another writer's file); the dispose mid-run variant is there.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, plan, unit;
import 'sentinel_fakes.dart';

/// The delay test the services are given: counts probes in flight (per tag and all together) and holds each one while
/// [gate] is set (read when the probe starts).
class Probes {
  Probes(this.fake);
  final FakeBox fake;
  Completer<void>? gate;
  int calls = 0, inFlight = 0, maxAll = 0;
  final inFlightBy = <String, int>{};
  int maxPerTag = 0;

  Future<int> delay(String tag, String url, int timeoutMs) async {
    calls++;
    inFlight++;
    final n = inFlightBy[tag] = (inFlightBy[tag] ?? 0) + 1;
    if (inFlight > maxAll) maxAll = inFlight;
    if (n > maxPerTag) maxPerTag = n;
    try {
      final g = gate;
      if (g != null) await g.future;
      return await fake.delayTest(tag, url, timeoutMs);
    } finally {
      inFlight--;
      inFlightBy[tag] = inFlightBy[tag]! - 1;
    }
  }
}

Future<void> until(bool Function() cond, String what) async {
  for (var i = 0; i < 400; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for $what');
}

/// Real time passes (a wrongly started round has had its chance to probe).
Future<void> quiet() => Future<void>.delayed(const Duration(milliseconds: 60));

const _settings = AutoSettings(failAfter: 2, flapGuard: false, firstCheck: Duration(hours: 1), checkEvery: Duration(hours: 1));

(AutoService, Probes) _auto() {
  final p = plan([unit('A', ['s::a1'])]);
  final fake = FakeBox(buildConfig(p), {'s::a1': 40});
  final probes = Probes(fake);
  final auto = AutoService(fake, p, delay: probes.delay, settings: _settings, pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])));
  auto.start();
  addTearDown(auto.stop);
  return (auto, probes);
}

Map<String, dynamic> _rule(String id, String target) => {
      'id': id,
      'name': '',
      'on': true,
      'action': 'proxy',
      'target': target,
      'fallback': 'block',
      'dns': 'auto',
      'groups': {
        'domain': {'not': false, 'v': {'domain_suffix': ['$id.test']}},
      },
    };

(FallbackService, Probes) _fallback() {
  final p = {
    'routes': [unit('A', ['s::a'])],
    'current': 0,
    'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
    'routing': {
      'fallback': 'main',
      'targets': {'src:x': unit('src:x', ['s::x1'])},
      'rules': [_rule('r1', 'src:x')],
    },
  };
  final info = RoutingInfo();
  final fake = FakeBox(buildConfig(p, info: info), {'s::a': 40, 's::x1': 40});
  final probes = Probes(fake);
  final svc = FallbackService(fake, info.fallbacks,
      delay: probes.delay, settings: _settings, pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])));
  svc.start();
  addTearDown(svc.stop);
  return (svc, probes);
}

/// The DNS query the failover is given: counts the asks (per server tag) and the ones in flight, holds every ask while
/// [gate] is set and the asks of one server while its entry in [hold] is set (both read when the ask starts).
class DnsProbes {
  Completer<void>? gate;
  final hold = <String, Completer<void>>{};
  final callsBy = <String, int>{};
  int calls = 0, inFlight = 0, maxAll = 0;

  Future<int> query(String tag, String name, int timeoutMs) async {
    calls++;
    callsBy[tag] = (callsBy[tag] ?? 0) + 1;
    inFlight++;
    if (inFlight > maxAll) maxAll = inFlight;
    try {
      final g = gate, h = hold[tag];
      if (g != null) await g.future;
      if (h != null) await h.future;
      return 20;
    } finally {
      inFlight--;
    }
  }

  int by(String tag) => callsBy[tag] ?? 0;
}

DnsCandidate _dnsCand(String id) => DnsCandidate(
      side: 'direct',
      provider: id,
      kind: 'udp',
      n: 1,
      tag: 'dns-$id',
      addr: 'udp://192.0.2.1:53/$id',
      flagTag: 'flag-dns-$id',
      flagPath: 'flags/dns-$id.json',
      inUse: true,
    );

/// Two servers, `a` and `b`, of two providers on the direct side; started (a round that comes due follows at once) with
/// the timers far away.
(DnsFailover, DnsProbes) _dns() {
  final time = FakeTime();
  final book = EventBook(null, clock: () => time.t);
  final sentinel = Sentinel(clock: time.clock, book: book);
  final pr = DnsProbes();
  final cands = [_dnsCand('a'), _dnsCand('b')];
  final fo = DnsFailover(
    sides: {'direct': cands},
    candidates: cands,
    setFlag: (c, on, reason) async => true,
    query: pr.query,
    settings: const AutoSettings(failAfter: 2, flapGuard: false, firstCheck: Duration(hours: 1), checkEvery: Duration(hours: 1)),
    sentinel: sentinel,
    pool: ProbePool.solo(),
    clock: () => time.t.millisecondsSinceEpoch,
    flagWait: const Duration(milliseconds: 30),
    flagPoll: Duration.zero,
  );
  fo.start();
  addTearDown(() {
    fo.stop();
    sentinel.dispose();
  });
  return (fo, pr);
}

void main() {
  group('DNS', () {
    test('a scheduled check() during checkServer probes nothing and returns; a round follows right after the manual check', () async {
      final (fo, pr) = _dns();
      await quiet();
      final gate = pr.gate = Completer<void>();
      final manual = fo.checkServer('a');
      await until(() => pr.inFlight > 0, 'the manual probe');
      final before = pr.calls;

      var returned = false;
      await fo.check().then((_) => returned = true);
      expect(returned, isTrue, reason: 'the scheduled round does not wait: it marks itself due and returns');
      await quiet();
      expect(pr.calls, before, reason: 'no probe of the round while the manual check holds the module');
      expect(pr.by('dns-b'), 0, reason: 'the round has not asked the other server');

      gate.complete();
      expect(await manual, isTrue);
      await until(() => pr.by('dns-b') > 0, 'the round that came due');
      await quiet();
      expect(pr.by('dns-a'), greaterThan(1), reason: 'the round asked the first server too');
    });

    test('without a round due, nothing follows checkServer', () async {
      final (fo, pr) = _dns();
      await quiet();
      expect(await fo.checkServer('a'), isTrue);
      final n = pr.calls;
      await quiet();
      expect(pr.calls, n, reason: 'a round is scheduled only when one came due meanwhile');
      expect(pr.by('dns-b'), 0);
    });

    test('two checkServer for different servers run one after the other', () async {
      final (fo, pr) = _dns();
      await quiet();
      final gate = pr.gate = Completer<void>();
      final a = fo.checkServer('a');
      await until(() => pr.inFlight > 0, 'the first probe');
      final b = fo.checkServer('b');
      var bDone = false;
      unawaited(b.then((_) => bDone = true));
      await quiet();
      expect(pr.by('dns-b'), 0, reason: 'the second waits for the first, it does not probe beside it');
      expect(bDone, isFalse);

      gate.complete();
      expect([await a, await b], [true, true]);
      expect(pr.by('dns-b'), greaterThan(0), reason: 'the second check probed after the first');
      expect(pr.maxAll, 1, reason: 'one probe at a time over both checks');
    });

    test('checkServer during a round waits for it, then asks its own server again', () async {
      final (fo, pr) = _dns();
      await quiet();
      final hold = pr.hold['dns-b'] = Completer<void>();
      final round = fo.check();
      await until(() => pr.inFlight > 0 && pr.by('dns-a') > 0 && pr.by('dns-b') > 0, 'the round to ask both servers');
      await until(() => pr.inFlight == 1, 'the answer of a');
      final asked = pr.by('dns-a');
      var done = false;
      final manual = fo.checkServer('a')..then((_) => done = true);
      await quiet();
      expect(done, isFalse, reason: 'a was answered, but the round still judges: the check waits for the whole round');
      expect(pr.by('dns-a'), asked);

      hold.complete();
      await round;
      expect(await manual, isTrue);
      expect(pr.by('dns-a'), greaterThan(asked), reason: 'a check of its own was made after the round, not joined');
    });

    test('the provider\'s ping is a check by hand too: it waits for a round under way', () async {
      final (fo, pr) = _dns();
      await quiet();
      final hold = pr.hold['dns-b'] = Completer<void>();
      final round = fo.check();
      await until(() => pr.inFlight == 1 && pr.by('dns-a') > 0, 'the round with b held');
      final ping = fo.startPing('a')!;
      var done = false;
      unawaited(ping.then((_) => done = true));
      await quiet();
      expect(done, isFalse, reason: 'the ping waits for the round');

      hold.complete();
      await round;
      await ping;
      expect(fo.pingResults('a').single.ms, 20);
    });
  });

  group('Auto', () {
    test('a scheduled check() during routeNow probes nothing and returns; a round follows right after the manual check', () async {
      final (auto, pr) = _auto();
      pr.gate = Completer<void>();
      final manual = auto.routeNow('A');
      await until(() => pr.inFlight > 0, 'the manual probe to start');
      final before = pr.calls;

      var returned = false;
      await auto.check().then((_) => returned = true);
      expect(returned, isTrue, reason: 'the scheduled round does not wait: it marks itself due and returns');
      await quiet();
      expect(pr.calls, before, reason: 'no probe of the round while the manual check holds the module');

      pr.gate!.complete();
      expect(await manual, isTrue);
      final afterManual = pr.calls;
      await until(() => pr.calls > afterManual, 'the round that came due');
      await quiet();
      expect(pr.maxPerTag, 1, reason: 'never two probes of one subject at once');
      expect(pr.maxAll, 1);
    });

    test('without a round due, nothing follows the manual check', () async {
      final (auto, pr) = _auto();
      expect(await auto.routeNow('A'), isTrue);
      final n = pr.calls;
      await quiet();
      expect(pr.calls, n, reason: 'a round is scheduled only when one came due meanwhile');
    });

    test('two manual checks run one after the other', () async {
      final (auto, pr) = _auto();
      pr.gate = Completer<void>();
      final a = auto.routeNow('A');
      await until(() => pr.inFlight > 0, 'the first probe');
      final b = auto.routeNow('A');
      var bDone = false;
      unawaited(b.then((_) => bDone = true));
      final held = pr.calls;
      await quiet();
      expect(pr.calls, held, reason: 'the second waits for the first, it does not probe beside it');
      expect(bDone, isFalse);

      pr.gate!.complete();
      expect([await a, await b], [true, true]);
      expect(pr.calls, greaterThan(held), reason: 'the second check probed after the first');
      expect(pr.maxAll, 1, reason: 'one probe at a time over both checks');
    });

    test('roundNow during a manual check waits for it and then runs its own round', () async {
      final (auto, pr) = _auto();
      pr.gate = Completer<void>();
      final manual = auto.routeNow('A');
      await until(() => pr.inFlight > 0, 'the manual probe');
      final held = pr.calls;
      var done = false;
      final round = auto.roundNow()..then((_) => done = true);
      await quiet();
      expect(done, isFalse, reason: 'a check by hand is no round to join');
      expect(pr.calls, held);

      pr.gate!.complete();
      await manual;
      final afterManual = pr.calls;
      expect(await round, isTrue, reason: 'its own round found the route answering');
      expect(pr.calls, greaterThan(afterManual), reason: 'a round of its own was run, not just awaited');
      expect(pr.maxAll, 1);
    });

    test('roundNow during a real round joins it: one round for the scheduled check and both commands', () async {
      final (base, basePr) = _auto();
      await base.check();
      final oneRound = basePr.calls;
      expect(oneRound, greaterThan(0));

      final (auto, pr) = _auto();
      pr.gate = Completer<void>();
      final scheduled = auto.check();
      await until(() => pr.inFlight > 0, 'the round to probe');
      final a = auto.roundNow(), b = auto.roundNow();
      await quiet();
      pr.gate!.complete();
      await scheduled;
      expect([await a, await b], [true, true]);
      await quiet();
      expect(pr.calls, oneRound, reason: 'joined, not started again');
      expect(pr.maxPerTag, 1);
    });
  });

  group('Fallback', () {
    test('a scheduled check() during checkTarget probes nothing; a round follows the manual check', () async {
      final (svc, pr) = _fallback();
      pr.gate = Completer<void>();
      final manual = svc.checkTarget('src:x');
      await until(() => pr.inFlight > 0, 'the manual probe');
      final before = pr.calls;

      var returned = false;
      await svc.check().then((_) => returned = true);
      expect(returned, isTrue);
      await quiet();
      expect(pr.calls, before, reason: 'no probe of the round while the manual check holds the module');

      pr.gate!.complete();
      expect(await manual, isTrue);
      final afterManual = pr.calls;
      await until(() => pr.calls > afterManual, 'the round that came due');
      await quiet();
      expect(pr.maxPerTag, 1);
    });

    test('without a round due, nothing follows checkTarget', () async {
      final (svc, pr) = _fallback();
      expect(await svc.checkTarget('src:x'), isTrue);
      final n = pr.calls;
      await quiet();
      expect(pr.calls, n);
    });

    test('two checkTarget run one after the other', () async {
      final (svc, pr) = _fallback();
      pr.gate = Completer<void>();
      final a = svc.checkTarget('src:x');
      await until(() => pr.inFlight > 0, 'the first probe');
      final b = svc.checkTarget('src:x');
      var bDone = false;
      unawaited(b.then((_) => bDone = true));
      final held = pr.calls;
      await quiet();
      expect(pr.calls, held);
      expect(bDone, isFalse);

      pr.gate!.complete();
      expect([await a, await b], [true, true]);
      expect(pr.calls, greaterThan(held));
      expect(pr.maxPerTag, 1);
    });
  });
}
