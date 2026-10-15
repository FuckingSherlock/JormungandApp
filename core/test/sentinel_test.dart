// The Sentinel's ladder (sentinel/sentinel.dart, docs/failures.md): every branch with a fake clock and
// fake checks, the journal entries it writes, the roots and their re-linking.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

const _ev = SuspicionEvent('conn', 'failing');

void main() {
  late FakeTime time;
  late EventBook book;
  late Sentinel sentinel;
  late List<String> notes;

  setUp(() {
    time = FakeTime();
    book = EventBook(null, clock: () => time.t);
    notes = [];
    sentinel = Sentinel(clock: time.clock, book: book, note: (l, t) => notes.add('$l: $t'));
    sentinel.context.switchGrace = Duration.zero; // the grace after a move has its own tests (net.switched)
  });

  tearDown(() => sentinel.dispose());

  // A settled core: connected 6 s ago.
  Future<void> settledCore() async {
    sentinel.context.starting('userConnect');
    sentinel.context.started();
    await time.advanceSeconds(6);
  }

  List<String> codes(Verdict v) => [for (final t in v.trail) t.code];
  Map<String, dynamic> event(int id) => book.byId(id)!;

  Suspicion failing({
    String host = 'a.com',
    Duration window = Duration.zero,
    List<Check> checks = const [],
    Why? why = const Why('conn.timeout'),
    Map<String, dynamic> evidence = const {'count': 3, 'kind': 'timeout'},
    String? key,
    Scope? scope,
    Map<String, dynamic>? subject,
    SuspicionEvent? event = _ev,
    DateTime? firstSeen,
  }) =>
      Suspicion(
        firstSeen: firstSeen,
        kind: 'conn.failing',
        subject: subject ?? {'app': 'org.x', 'host': host, 'route': 'A'},
        evidence: evidence,
        checks: checks,
        window: window,
        why: why,
        key: key,
        scope: scope,
        event: event,
      );

  group('a. an external cause', () {
    test('no network: a consequence of net.offline, written as a quiet journal entry linked to the root', () async {
      await settledCore();
      sentinel.context.pool(NetStatus.down, osOffline: true);
      final v = await sentinel.suspect(failing());
      expect(v.kind, VerdictKind.consequence);
      expect(v.why!.code, rootNetOffline);
      expect(v.rootId, startsWith('net.offline#'));
      expect(codes(v), containsAllInOrder(['suspect', 'ctx.net']));
      final e = event(v.eventId!);
      expect((e['verdict'], e['level'], e['cat'], e['type']), ('consequence', 'info', 'conn', 'failing'));
      expect(e['data'], {'count': 3, 'kind': 'timeout'}, reason: 'the evidence is the event data, as the detector had it');
      expect(EventBook.isQuiet(e), isTrue);
      expect(sentinel.roots.byKind(rootNetOffline), isNotNull);
    });

    test('a captive portal: a consequence of net.captive', () async {
      await settledCore();
      sentinel.context.platform(captive: true, type: 'wifi', id: '3');
      final v = await sentinel.suspect(failing());
      expect(v.kind, VerdictKind.consequence);
      expect(v.why!.code, rootNetCaptive);
      expect(v.trail.firstWhere((t) => t.code == 'ctx.net' && t.outcome == Outcome.fail).params['state'], 'captive');
    });

    test('a doubt about the network does not excuse a failure: it goes on down the ladder', () async {
      await settledCore();
      sentinel.context.pool(NetStatus.unknown, osOffline: false);
      final v = await sentinel.suspect(failing());
      expect(v.kind, VerdictKind.confirmed);
      expect(v.trail.firstWhere((t) => t.code == 'ctx.net').outcome, Outcome.inconclusive);
    });

    test('the network goes while the failure is inside its window: the failure began first, so it is parked, not a consequence', () async {
      await settledCore();
      final f = sentinel.suspect(failing(window: const Duration(seconds: 20)));
      await time.advanceSeconds(5);
      sentinel.context.pool(NetStatus.down, osOffline: false);
      await time.advanceSeconds(30);
      expect(book.length, 0, reason: 'parked: nothing is written');
      sentinel.context.pool(NetStatus.up, osOffline: false);
      await time.advanceSeconds(21); // the failure lasts its window after the move (net.switched)
      final v = await f;
      expect(v.kind, VerdictKind.confirmed, reason: 'the network is back and the failure is still there');
      expect(codes(v), containsAllInOrder(['suspect', 'ctx.net', 'park', 'resume', 'persist.window']));
      expect(v.trail.firstWhere((t) => t.code == 'park').params['root'], startsWith('net.offline#'));
    });

    test('the network goes under the checks: the running check is cancelled at once and re-run when the network is back', () async {
      await settledCore();
      final runs = <Cancel>[];
      final f = sentinel.suspect(failing(checks: [
        Check.recovery('probe.target', (cancel) {
          runs.add(cancel);
          return runs.length == 1 ? Completer<CheckResult>().future : Future.value(const CheckResult('probe.target', Outcome.pass));
        })
      ]));
      await time.advanceSeconds(1);
      expect(runs.length, 1);
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advanceSeconds(1); // far less than the check's timeout
      expect(runs[0].cancelled, isTrue);
      expect(runs[0].reason, startsWith('net.offline#'));
      expect(runs.length, 1, reason: 'not started again while the network is gone');
      sentinel.context.pool(NetStatus.up, osOffline: false);
      final v = await f;
      expect(runs.length, 2);
      expect(v.kind, VerdictKind.blip);
      expect(codes(v), containsAllInOrder(['suspect', 'persist.window', 'probe.target', 'park', 'resume', 'probe.target', 'blip.recovered']));
      final aborted = v.trail.firstWhere((t) => t.code == 'probe.target');
      expect((aborted.outcome, aborted.params['reason']), (Outcome.inconclusive, 'aborted'));
    });

    test('a failure that began after the outage is its consequence, whatever the checks', () async {
      await settledCore();
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advanceSeconds(5);
      var ran = false;
      final v = await sentinel.suspect(failing(checks: [
        Check.recovery('probe.target', (_) async {
          ran = true;
          return const CheckResult('probe.target', Outcome.pass);
        })
      ]));
      expect(v.kind, VerdictKind.consequence);
      expect(ran, isFalse);
    });
  });

  group('parking behind a failed node (levels)', () {
    Check viaB(void Function() ran) => Check.recovery('probe.target', (_) async {
          ran();
          return const CheckResult('probe.target', Outcome.pass);
        }, via: 'B');

    Root deadRoute() => sentinel.openRoot(kind: 'route.dead', subject: const {'route': 'B'}, scope: const Scope.of({'route': 'B'}), level: Level.route);

    test('a check via a route with an open root is not started: the trail says which root; a failure after the root is its consequence', () async {
      await settledCore();
      final root = deadRoute();
      var ran = 0;
      final v = await sentinel.suspect(failing(checks: [viaB(() => ran++)]));
      expect(v.kind, VerdictKind.consequence);
      expect(ran, 0);
      final skip = v.trail.firstWhere((t) => t.code == 'check.skipped');
      expect((skip.params['check'], skip.params['root']), ('probe.target', root.id));
    });

    test('a failure that began before the route died is parked, and re-checks when the root closes', () async {
      await settledCore();
      final before = time.t.subtract(const Duration(minutes: 1));
      final root = deadRoute();
      var ran = 0;
      final f = sentinel.suspect(failing(firstSeen: before, checks: [viaB(() => ran++)]));
      await time.advanceSeconds(30);
      expect(ran, 0);
      expect(book.length, 0);
      sentinel.closeRoot(root.id, reason: 'route.back');
      final v = await f;
      expect(ran, 1);
      expect(v.kind, VerdictKind.blip);
      expect(codes(v), containsAllInOrder(['check.skipped', 'park', 'resume', 'probe.target', 'blip.recovered']));
    });

    test('a check of another route is not stopped by it', () async {
      await settledCore();
      deadRoute();
      var ran = 0;
      final v = await sentinel.suspect(failing(checks: [
        Check.recovery('probe.target', (_) async {
          ran++;
          return const CheckResult('probe.target', Outcome.pass);
        }, via: 'C')
      ], scope: Scope.none, subject: const {'host': 'a.com', 'route': 'C'}));
      expect(ran, 1);
      expect(v.kind, VerdictKind.blip);
    });

    Root deadDns(String id) => sentinel.openRoot(kind: 'dns.down', key: 'dns|$id', subject: {'dns': id, 'path': 'direct'}, scope: Scope.of({'dns': id}), level: Level.dns);

    Check probeVia(String? resolver, void Function() ran, {String via = 'B'}) => Check.recovery('probe.target', (_) async {
          ran();
          return const CheckResult('probe.target', Outcome.pass);
        }, level: Level.route, via: via, resolver: resolver);

    test('a dns root stops a check bound to its server at any level (a route resolving its domain servers), by the binding, not the level', () async {
      await settledCore();
      final root = deadDns('g');
      var ran = 0;
      final v = await sentinel.suspect(failing(checks: [probeVia('g', () => ran++)]));
      expect(v.kind, VerdictKind.consequence);
      expect(ran, 0);
      expect(v.trail.firstWhere((t) => t.code == 'check.skipped').params['root'], root.id);
    });

    test('a check bound to another server, or to none, is not stopped by a dns root', () async {
      await settledCore();
      deadDns('g');
      var ran = 0;
      for (final r in ['h', null]) {
        await sentinel.suspect(failing(
            checks: [probeVia(r, () => ran++, via: 'C')], scope: Scope.none, subject: {'host': 'a.com', 'route': 'C'}, key: 'k|$r'));
      }
      expect(ran, 2);
    });

    test('a dead route stops the check of a via-VPN dns server (the route is the cause, as before)', () async {
      await settledCore();
      deadRoute();
      var ran = 0;
      final v = await sentinel.suspect(failing(checks: [
        Check.recovery('dns.answers', (_) async {
          ran++;
          return const CheckResult('dns.answers', Outcome.pass);
        }, level: Level.dns, via: 'B', resolver: 'v')
      ]));
      expect(v.kind, VerdictKind.consequence);
      expect(ran, 0);
    });

    test('a core restart cancels the running check; it is run again once the core has settled', () async {
      await settledCore();
      final runs = <Cancel>[];
      final f = sentinel.suspect(failing(checks: [
        Check.recovery('probe.target', (cancel) {
          runs.add(cancel);
          return runs.length == 1 ? Completer<CheckResult>().future : Future.value(const CheckResult('probe.target', Outcome.pass));
        })
      ]));
      await time.advanceSeconds(1);
      sentinel.context.starting('refreshLists');
      await time.advanceSeconds(1);
      expect(runs[0].reason, 'core.starting');
      sentinel.context.started();
      await time.advanceSeconds(10);
      final v = await f;
      expect(runs.length, 2);
      expect(v.kind, VerdictKind.blip);
    });

    test('parking is bounded: after parkMax the suspicion is let go as deferred, nothing written', () async {
      await settledCore();
      final f = sentinel.suspect(failing(window: const Duration(seconds: 20)));
      await time.advanceSeconds(5);
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advance(parkLimit - const Duration(minutes: 1));
      sentinel.context.pool(NetStatus.up, osOffline: false);
      await time.advanceSeconds(21); // the failure lasts its window after the move (net.switched)
      final v = await f;
      expect(v.kind, VerdictKind.confirmed, reason: 'back inside the bound');

      final g = sentinel.suspect(failing(host: 'b.com', window: const Duration(seconds: 20)));
      await time.advanceSeconds(5);
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advance(parkLimit + const Duration(seconds: 1));
      final w = await g;
      expect(w.kind, VerdictKind.deferred);
      expect(w.why!.code, 'parked.expired');
      expect(codes(w), containsAllInOrder(['park', 'park.expired']));
      expect(book.length, 1, reason: 'only the first one was written');
    });

    test('recovered() while parked is a blip', () async {
      await settledCore();
      final f = sentinel.suspect(failing(window: const Duration(seconds: 20), key: 'k1'));
      await time.advanceSeconds(5);
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advanceSeconds(5);
      expect(sentinel.recovered('k1'), isTrue);
      final v = await f;
      expect(v.kind, VerdictKind.blip);
    });

    test('a user disconnect (dropAll) still drops a parked suspicion; an own restart or recovery (park: true) does not', () async {
      await settledCore();
      final kept = sentinel.suspect(failing(window: const Duration(seconds: 20), key: 'kept'));
      final dropped = sentinel.suspect(failing(host: 'b.com', window: const Duration(seconds: 20), key: 'dropped'));
      await time.advanceSeconds(5);
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advanceSeconds(5);
      sentinel.dropAll(park: true);
      await time.advanceSeconds(1);
      sentinel.context.pool(NetStatus.up, osOffline: false);
      await time.advanceSeconds(21); // the rest of the window (counted from the return of the network, net.switched)
      final k = await kept;
      expect(k.kind, VerdictKind.confirmed, reason: "${k.why?.code} ${codes(k)}");
      sentinel.context.pool(NetStatus.down, osOffline: true);
      await time.advanceSeconds(1);
      final d = sentinel.suspect(failing(host: 'c.com', window: const Duration(seconds: 20), key: 'again', firstSeen: time.t.subtract(const Duration(minutes: 1))));
      await time.advanceSeconds(1);
      sentinel.dropAll();
      final v = await d;
      expect((v.kind, v.why!.code), (VerdictKind.deferred, 'session.ended'));
      await dropped;
    });
  });

  group('b. ourselves', () {
    test('our own restart under way: nothing is decided until it settles, then the failure must last its window', () async {
      await settledCore();
      sentinel.context.starting('refreshLists');
      var done = false;
      final f = sentinel.suspect(failing(window: const Duration(seconds: 10))).whenComplete(() => done = true);
      await time.advanceSeconds(2);
      sentinel.context.started(); // settled 5 s later, at +7
      await time.advanceSeconds(4); // +6: 1 s before the settle
      expect(done, isFalse);
      await time.advanceSeconds(2); // +8: the window runs from the settle, due at +17
      expect(done, isFalse, reason: 'the window starts over at the settle');
      await time.advanceSeconds(8); // +16
      expect(done, isFalse);
      expect(book.length, 0, reason: 'nothing is written while it is waited out');
      await time.advanceSeconds(2); // +18
      final v = await f;
      expect(v.kind, VerdictKind.confirmed);
      expect(codes(v), containsAllInOrder(['suspect', 'ctx.core', 'self.restarted', 'persist.window']));
      final c = v.trail.firstWhere((t) => t.code == 'ctx.core');
      expect((c.outcome, c.params['phase'], c.params['reason']), (Outcome.fail, 'starting', 'refreshLists'));
      expect(v.trail.firstWhere((t) => t.code == 'self.restarted').params['reason'], 'refreshLists');
      expect(book.length, 1);
    });

    test('a failure seen during our restart and gone after it settles is a blip, not an error', () async {
      await settledCore();
      sentinel.context.starting('refreshLists');
      sentinel.context.started();
      final v = sentinel.suspect(failing(checks: [Check.recovery('probe.target', (_) async => const CheckResult('probe.target', Outcome.pass))]));
      await time.advanceSeconds(6);
      expect((await v).kind, VerdictKind.blip);
    });

    test('a restart in the middle of the window starts the window over', () async {
      await settledCore();
      final t0 = time.t;
      var done = false;
      final f = sentinel.suspect(failing(window: const Duration(seconds: 20))).whenComplete(() => done = true);
      await time.advanceSeconds(5);
      sentinel.context.starting('refreshLists'); // at +5
      await time.advanceSeconds(1);
      sentinel.context.started(); // +6, settled at +11
      await time.advanceSeconds(14); // +20: the original window is over
      expect(done, isFalse);
      await time.advanceSeconds(10); // +30
      expect(done, isFalse);
      await time.advanceSeconds(2); // +32 > 11 + 20
      final v = await f;
      expect(v.kind, VerdictKind.confirmed);
      expect(time.t.difference(t0).inSeconds, 32);
      expect(codes(v), contains('self.restarted'));
    });

    test('a core that never settles: let go as deferred after the bound, nothing written', () async {
      sentinel.dispose();
      sentinel = Sentinel(clock: time.clock, book: book, deferMax: const Duration(seconds: 10));
      sentinel.context.starting('userConnect');
      final f = sentinel.suspect(failing());
      await time.advanceSeconds(11);
      final v = await f;
      expect(v.kind, VerdictKind.deferred);
      expect(v.why!.code, 'self.notSettled');
      expect(codes(v), contains('defer.timeout'));
      expect(book.length, 0);
      expect(v.eventId, isNull);
    });

    test('our own reject rule fired: deferred at once, never an error', () async {
      await settledCore();
      final v = await sentinel.suspect(failing(evidence: const {'count': 9, 'ownReject': true}));
      expect(v.kind, VerdictKind.deferred);
      expect(v.why!.code, 'self.reject');
      expect(book.length, 0);
    });

    test('no connection: a failure through the core is deferred; one that does not go through it is judged', () async {
      expect((await sentinel.suspect(failing())).kind, VerdictKind.deferred);
      final v = await sentinel.suspect(Suspicion(kind: 'svc.fetch', subject: const {'what': 'rules'}, viaCore: false, why: const Why('svc.timeout')));
      expect(v.kind, VerdictKind.confirmed);
    });
  });

  group('c. an open root', () {
    test('a failure inside the scope of an open root is its consequence, linked to its event', () async {
      await settledCore();
      final a = await sentinel.suspect(failing(key: 'tun', subject: const {'route': 'A'}, scope: const Scope.of({'route': 'A'})));
      expect(a.kind, VerdictKind.confirmed);
      expect(a.rootId, isNotNull);
      final v = await sentinel.suspect(failing(host: 'b.com'));
      expect(v.kind, VerdictKind.consequence);
      expect(v.rootId, a.rootId);
      expect(v.cause, a.eventId);
      final e = event(v.eventId!);
      expect((e['verdict'], e['cause']), ('consequence', a.eventId));
      expect(e['why'], {'code': 'conn.failing', 'params': {'root': a.rootId}});
      // a subject outside the scope is judged on its own
      final other = await sentinel.suspect(failing(subject: const {'route': 'B', 'host': 'c.com'}));
      expect(other.kind, VerdictKind.confirmed);
      expect(other.rootId, isNot(a.rootId));
    });

    test('the core is down: a consequence of core.down', () async {
      await settledCore();
      sentinel.context.crashed();
      sentinel.context.down();
      final v = await sentinel.suspect(failing());
      expect(v.kind, VerdictKind.consequence);
      expect(v.why!.code, rootCoreDown);
      sentinel.context.starting('recover');
      sentinel.context.started();
      expect(sentinel.roots.byKind(rootCoreDown), isNull, reason: 'closes when the core is back');
    });

    test('the core is recovering: deferred until it is down, then a consequence', () async {
      await settledCore();
      sentinel.context.crashed();
      final f = sentinel.suspect(failing());
      await time.advanceSeconds(5);
      sentinel.context.down();
      final v = await f;
      expect(v.kind, VerdictKind.consequence);
      expect(codes(v), containsAllInOrder(['ctx.net', 'ctx.core', 'root.covers']));
    });

    test('a suspicion under way turns into a consequence when a root covering it opens', () async {
      await settledCore();
      final f = sentinel.suspect(failing(window: const Duration(seconds: 30)));
      await time.advanceSeconds(5);
      final root = sentinel.openRoot(kind: 'tun.tcpDead', subject: const {'route': 'A'}, scope: const Scope.of({'route': 'A'}), eventId: 77);
      final v = await f;
      expect(v.kind, VerdictKind.consequence);
      expect(v.rootId, root.id);
      expect(v.cause, 77);
      expect(event(v.eventId!)['cause'], 77);
    });
  });

  group('d. the checks', () {
    test('another path works: a workaround, with the check in the trail, no root', () async {
      await settledCore();
      final v = await sentinel.suspect(failing(checks: [
        Check.recovery('probe.same', (_) async => const CheckResult('probe.same', Outcome.fail, {'ms': -1})),
        Check.alternative('probe.direct', (_) async => const CheckResult('probe.direct', Outcome.pass, {'ms': 120})),
      ]));
      expect(v.kind, VerdictKind.workaround);
      expect(v.why, isA<Why>().having((w) => w.params['by'], 'by', 'probe.direct'));
      expect(codes(v), containsAllInOrder(['suspect', 'probe.same', 'probe.direct']));
      final step = v.trail.last;
      expect((step.outcome, step.params['ms'], step.params['role']), (Outcome.pass, 120, 'alternative'));
      expect(sentinel.roots.open, isEmpty);
      expect((event(v.eventId!)['level'], event(v.eventId!)['verdict']), ('info', 'workaround'));
    });

    test('the checks run in the order given, and stop at the first that decides', () async {
      await settledCore();
      final ran = <String>[];
      CheckResult r(String c, Outcome o) {
        ran.add(c);
        return CheckResult(c, o);
      }

      final v = await sentinel.suspect(failing(checks: [
        Check.diagnostic('dns.resolve', (_) async => r('dns.resolve', Outcome.pass)),
        Check.alternative('probe.a', (_) async => r('probe.a', Outcome.pass)),
        Check.alternative('probe.b', (_) async => r('probe.b', Outcome.pass)),
      ]));
      expect(ran, ['dns.resolve', 'probe.a']);
      expect(v.kind, VerdictKind.workaround);
    });

    test('a failing diagnostic is the reason, and wins over the detector\'s own reading', () async {
      await settledCore();
      final v = await sentinel.suspect(failing(checks: [
        Check.diagnostic('dns.resolve', (_) async => const CheckResult('dns.resolve', Outcome.fail, {'host': 'a.com'})),
      ]));
      expect(v.kind, VerdictKind.confirmed);
      expect(v.why!.code, 'dns.resolve');
      expect(v.why!.params, {'host': 'a.com'});
    });

    test('a check that throws or hangs is inconclusive and does not stop the ladder', () async {
      await settledCore();
      final f = sentinel.suspect(failing(checks: [
        Check.alternative('probe.boom', (_) async => throw StateError('x')),
        Check.alternative('probe.hang', (_) => Completer<CheckResult>().future, timeout: const Duration(seconds: 2)),
      ]));
      await time.advanceSeconds(3);
      final v = await f;
      expect(v.kind, VerdictKind.confirmed);
      final boom = v.trail.firstWhere((t) => t.code == 'probe.boom');
      final hang = v.trail.firstWhere((t) => t.code == 'probe.hang');
      expect((boom.outcome, boom.params['reason']), (Outcome.inconclusive, 'error'));
      expect((hang.outcome, hang.params['reason'], hang.params['afterMs']), (Outcome.inconclusive, 'timeout', 2000));
    });
  });

  group('e. persistence', () {
    test('recovered by itself inside the window: a blip that says what failed and for how long', () async {
      await settledCore();
      final f = sentinel.suspect(failing(evidence: const {'count': 3, 'kind': 'timeout', 'port': 443}, window: const Duration(seconds: 20)));
      await time.advanceSeconds(7);
      expect(sentinel.recovered('conn.failing|{"app":"org.x","host":"a.com","route":"A"}'), isTrue);
      final v = await f;
      expect(v.kind, VerdictKind.blip);
      final first = v.trail.first;
      expect(first.code, 'suspect');
      expect(first.params['subject'], {'app': 'org.x', 'host': 'a.com', 'route': 'A'});
      expect(first.params['facts'], {'count': 3, 'kind': 'timeout', 'port': 443});
      final b = v.trail.last;
      expect((b.code, b.outcome, b.params['afterMs']), ('blip.recovered', Outcome.pass, 7000));
      expect(v.why!.code, 'recovered');
      final e = event(v.eventId!);
      expect((e['verdict'], e['level']), ('blip', 'info'));
      expect(EventBook.isQuiet(e), isTrue);
      expect(sentinel.roots.open, isEmpty);
    });

    test('a recovery check that passes at the end of the window is a blip too', () async {
      await settledCore();
      final f = sentinel.suspect(failing(window: const Duration(seconds: 10), checks: [
        Check.recovery('probe.target', (_) async => const CheckResult('probe.target', Outcome.pass, {'ms': 80})),
      ]));
      await time.advanceSeconds(10);
      final v = await f;
      expect(v.kind, VerdictKind.blip);
      expect(v.why!.params, {'afterMs': 10000, 'by': 'probe.target'});
    });

    test('still failing after the window: confirmed, a root is open, the event is a loud one', () async {
      await settledCore();
      var done = false;
      final f = sentinel.suspect(failing(window: const Duration(seconds: 20))).whenComplete(() => done = true);
      await time.advanceSeconds(19);
      expect(done, isFalse);
      expect(book.length, 0, reason: 'nothing is written before the verdict');
      await time.advanceSeconds(2);
      final v = await f;
      expect(v.kind, VerdictKind.confirmed);
      expect(v.why, isA<Why>().having((w) => w.code, 'code', 'conn.timeout'));
      expect(codes(v), containsAllInOrder(['suspect', 'ctx.net', 'ctx.core', 'persist.wait', 'persist.window']));
      final e = event(v.eventId!);
      expect((e['verdict'], e['level']), ('confirmed', 'warn'));
      expect(e['why'], {'code': 'conn.timeout', 'params': {}});
      expect(e.containsKey('cause'), isFalse);
      expect(EventBook.isQuiet(e), isFalse);
      final root = sentinel.roots.byId(v.rootId!)!;
      expect((root.kind, root.eventId), ('conn.failing', v.eventId));
      expect(sentinel.contextJson()['roots'], hasLength(1));
    });

    test('the same failure again while it is being judged joins it; while it is a root it is a repeat, nothing new written', () async {
      await settledCore();
      final a = sentinel.suspect(failing(window: const Duration(seconds: 5)));
      final b = sentinel.suspect(failing(window: const Duration(seconds: 5), evidence: const {'count': 6}));
      await time.advanceSeconds(6);
      final va = await a, vb = await b;
      expect(identical(va, vb), isTrue);
      expect(book.length, 1);
      expect(event(va.eventId!)['data'], {'count': 6, 'kind': 'timeout'}, reason: 'the newer evidence is laid over');
      final again = await sentinel.suspect(failing());
      expect((again.kind, again.repeat, again.rootId, again.cause), (VerdictKind.confirmed, true, va.rootId, va.eventId));
      expect(book.length, 1);
    });

    test('nothing says why: unexplained, a warning in the journal and no root', () async {
      await settledCore();
      final v = await sentinel.suspect(failing(why: null));
      expect(v.kind, VerdictKind.unexplained);
      expect(v.why!.code, 'why.unknown');
      final e = event(v.eventId!);
      expect((e['verdict'], e['level']), ('unexplained', 'warn'));
      expect(EventBook.isQuiet(e), isTrue, reason: 'never a notification');
      expect(sentinel.roots.open, isEmpty);
    });

    test('a suspicion without an event writes nothing; the caller has the verdict', () async {
      await settledCore();
      final v = await sentinel.suspect(failing(event: null));
      expect(v.kind, VerdictKind.confirmed);
      expect(v.eventId, isNull);
      expect(book.length, 0);
    });

    test('the verdicts are also on a stream', () async {
      await settledCore();
      final seen = <VerdictKind>[];
      final sub = sentinel.verdicts.listen((v) => seen.add(v.kind));
      await sentinel.suspect(failing());
      await sentinel.suspect(failing(host: 'b.com', why: null));
      await pumpEventQueue();
      expect(seen, [VerdictKind.confirmed, VerdictKind.unexplained]);
      await sub.cancel();
    });
  });

  group('roots', () {
    test('close on recovery, and the close is in the trail of the root\'s event', () async {
      await settledCore();
      final v = await sentinel.suspect(failing());
      time.t = time.t.add(const Duration(seconds: 42));
      expect(sentinel.recovered(v.key), isTrue);
      expect(sentinel.roots.open, isEmpty);
      expect(sentinel.roots.closed.single.closeReason, 'recovered');
      final trail = (event(v.eventId!)['trail'] as List).cast<Map>();
      expect(trail.last['code'], 'root.closed');
      expect(trail.last['params'], {'reason': 'recovered', 'afterMs': 42000});
      expect(notes.last, contains('closed after 42 s'));
      // the same thing failing again is judged anew
      expect((await sentinel.suspect(failing())).repeat, isFalse);
    });

    test('a root that opens later re-links the open roots it covers: their events become consequences of it', () async {
      await settledCore();
      final a = await sentinel.suspect(failing());
      expect(event(a.eventId!)['verdict'], 'confirmed');
      sentinel.context.pool(NetStatus.down, osOffline: true); // net.offline opens
      final e = event(a.eventId!);
      expect(e['verdict'], 'consequence');
      expect(e['why'], {'code': rootNetOffline, 'params': {'root': sentinel.roots.byKind(rootNetOffline)!.id}});
      expect(((e['trail'] as List).last as Map)['code'], 'root.relinked');
      expect(e['rev'], 1);
      expect(sentinel.roots.byId(a.rootId!)!.parent, sentinel.roots.byKind(rootNetOffline)!.id);
      expect(EventBook.isQuiet(e), isTrue);
    });

    test('a detector that writes its own root event attaches it: the consequences already written get it as their cause', () async {
      await settledCore();
      sentinel.context.pool(NetStatus.down, osOffline: true);
      final c = await sentinel.suspect(failing());
      expect(event(c.eventId!).containsKey('cause'), isFalse, reason: 'the context root has no event yet');
      final root = sentinel.openRoot(kind: rootNetOffline, eventId: 500);
      expect(root.fromContext, isTrue, reason: 'the open context root got the event, no second root');
      expect(sentinel.roots.open.where((r) => r.kind == rootNetOffline), hasLength(1));
      expect(event(c.eventId!)['cause'], 500);
      sentinel.context.pool(NetStatus.up, osOffline: false);
      expect(sentinel.roots.open, isEmpty);
    });

    test('the network coming back closes net.offline and the log says so', () async {
      await settledCore();
      sentinel.context.pool(NetStatus.down, osOffline: true);
      expect(notes.last, contains('net.offline#'));
      await time.advanceSeconds(30);
      sentinel.context.pool(NetStatus.up, osOffline: false);
      expect(notes.last, allOf(contains('closed after 30 s'), contains('net.restored')));
    });

    test('a root of the connection ends with it: a stop, or a new sing-box', () async {
      await settledCore();
      await sentinel.suspect(failing(host: 'a.com'));
      await sentinel.suspect(failing(host: 'b.com', subject: const {'host': 'b.com', 'route': 'Z'}));
      sentinel.openRoot(kind: 'x.keep', session: false);
      expect(sentinel.roots.open, hasLength(3));
      sentinel.context.starting('refreshLists');
      expect(sentinel.roots.open.map((r) => r.kind), ['x.keep']);
      sentinel.context.started();
      await time.advanceSeconds(6);
      await sentinel.suspect(failing());
      expect(sentinel.roots.open, hasLength(2));
      sentinel.context.stopped();
      expect(sentinel.roots.open.map((r) => r.kind), ['x.keep']);
      expect(sentinel.roots.closed.last.closeReason, 'core.stopped');
    });

    test('a root nobody closed expires', () async {
      sentinel.dispose();
      sentinel = Sentinel(clock: time.clock, book: book, roots: RootRegistry(maxAge: const Duration(hours: 1)));
      sentinel.openRoot(kind: 'x.old', subject: const {'a': 1}, scope: const Scope.of({'a': 1}));
      await time.advance(const Duration(hours: 2));
      final v = await sentinel.suspect(Suspicion(kind: 'conn.failing', subject: const {'a': 1, 'b': 2}, viaCore: false, why: const Why('w')));
      expect(v.kind, VerdictKind.confirmed, reason: 'the stale root no longer explains it');
      expect(sentinel.roots.closed.single.closeReason, 'expired');
    });

    test('the context in the status: network, core, roots', () async {
      await settledCore();
      sentinel.context.platform(connected: true, validated: true, type: 'wifi', id: '9');
      await sentinel.suspect(failing());
      final j = sentinel.contextJson();
      expect((j['network'] as Map)['state'], 'up');
      expect((j['network'] as Map)['type'], 'wifi');
      expect((j['core'] as Map)['phase'], 'settled');
      expect((j['core'] as Map)['restartReason'], 'userConnect');
      expect((j['roots'] as List).single['kind'], 'conn.failing');
    });
  });

  test('the same failure while its root is open: counted on the root\'s event (data.repeat, last time), a raw line each, nothing new written', () async {
    await settledCore();
    final v = await sentinel.suspect(failing());
    expect(v.kind, VerdictKind.confirmed);
    await sentinel.suspect(failing());
    await time.advanceSeconds(10);
    final again = await sentinel.suspect(failing());
    expect(again.repeat, isTrue);
    final r = (event(v.eventId!)['data'] as Map)['repeat'] as Map;
    expect([r['count'], (r['at'] as List).length, r['lastAt']], [3, 3, time.t.millisecondsSinceEpoch]);
    expect(notes.where((n) => n.contains('again while root')).length, 2);
    expect(book.since(null)['events'], hasLength(1));
  });

  test('concurrency: the rest wait in the queue', () async {
    sentinel.dispose();
    sentinel = Sentinel(clock: time.clock, book: book, maxActive: 2);
    sentinel.context.starting('userConnect');
    sentinel.context.started();
    await time.advanceSeconds(6);
    final started = <int>[];
    final gates = [for (var i = 0; i < 5; i++) Completer<CheckResult>()];
    final fs = [
      for (var i = 0; i < 5; i++)
        sentinel.suspect(failing(subject: {'host': 'h$i.com'}, checks: [
          Check.recovery('probe.$i', (_) {
            started.add(i);
            return gates[i].future;
          }),
        ])),
    ];
    await pumpEventQueue();
    expect(started, [0, 1], reason: 'two at a time');
    gates[0].complete(const CheckResult('probe.0', Outcome.pass));
    await pumpEventQueue();
    expect(started, [0, 1, 2]);
    for (var i = 1; i < 5; i++) {
      gates[i].complete(CheckResult('probe.$i', Outcome.pass));
      await pumpEventQueue();
    }
    expect(started, [0, 1, 2, 3, 4]);
    expect((await Future.wait(fs)).map((v) => v.kind), everyElement(VerdictKind.blip));
  });
}
