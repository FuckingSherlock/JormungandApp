// The Sentinel's context (sentinel/context.dart): the network state from its inputs, the core phase
// and the settle, the spans in which our own restarts left the core unsettled.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

void main() {
  late FakeTime time;
  late ContextTracker ctx;
  var changes = 0;

  setUp(() {
    time = FakeTime();
    ctx = ContextTracker(clock: time.clock);
    changes = 0;
    ctx.onChange = () => changes++;
  });

  group('network', () {
    test('presumed up until something says otherwise', () {
      expect(ctx.network.state, NetState.up);
      expect(ctx.network.source, 'default');
    });

    test('the pool: down is none (os when the OS says so, probes otherwise), unknown is a doubt, up is up', () async {
      ctx.pool(NetStatus.down, osOffline: true);
      expect((ctx.network.state, ctx.network.source), (NetState.none, 'os'));
      final since = ctx.network.since;
      await time.advanceSeconds(3);
      ctx.pool(NetStatus.down, osOffline: false);
      expect((ctx.network.state, ctx.network.source), (NetState.none, 'probes'));
      expect(ctx.network.since, since, reason: 'still none: the state did not change, only what decided it');
      ctx.pool(NetStatus.unknown, osOffline: false);
      expect(ctx.network.state, NetState.unknown);
      expect(ctx.network.since, greaterThan(since));
      ctx.pool(NetStatus.up, osOffline: false);
      expect(ctx.network.state, NetState.up);
    });

    test('the platform: captive wins, connected:false is none, validated:false alone is only a doubt', () {
      ctx.platform(validated: false, type: 'wifi', id: '17');
      expect(ctx.network.state, NetState.unknown);
      expect((ctx.network.type, ctx.network.id), ('wifi', '17'));
      ctx.platform(validated: false, captive: true, type: 'wifi', id: '17');
      expect((ctx.network.state, ctx.network.source), (NetState.captive, 'platform'));
      ctx.platform(connected: false);
      expect(ctx.network.state, NetState.none);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '17');
      expect(ctx.network.state, NetState.up);
    });

    test('a platform "validated: false" does not hide that the probes say it works, and the pool\'s down is not hidden by it', () {
      ctx.pool(NetStatus.down, osOffline: false);
      ctx.platform(validated: true);
      expect(ctx.network.state, NetState.none, reason: 'the platform\'s "validated" is not proof against silent probes');
      ctx.pool(NetStatus.up, osOffline: false);
      expect(ctx.network.state, NetState.up);
    });

    test('changedAt moves with the network id, the type and the default interface, `since` only with the state', () async {
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '1');
      final since = ctx.network.since, at = ctx.network.changedAt;
      await time.advanceSeconds(10);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '1');
      expect(ctx.network.changedAt, at, reason: 'the same report again: nothing moved');
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '2');
      expect(ctx.network.changedAt, greaterThan(at));
      expect(ctx.network.since, since);
      final at2 = ctx.network.changedAt;
      await time.advanceSeconds(10);
      ctx.interfaceChanged();
      expect(ctx.network.changedAt, greaterThan(at2));
    });

    test('onChange fires for a change only, not for a repeated report', () {
      ctx.pool(NetStatus.down, osOffline: true);
      final n = changes;
      ctx.pool(NetStatus.down, osOffline: true);
      expect(changes, n);
    });
  });

  group('core phase', () {
    test('stopped → starting → settling → settled after the settle time', () async {
      expect(ctx.phase, CorePhase.stopped);
      ctx.starting('userConnect');
      expect(ctx.phase, CorePhase.starting);
      expect(ctx.core.restartReason, 'userConnect');
      ctx.started();
      expect(ctx.phase, CorePhase.settling);
      expect(ctx.settled, isFalse);
      await time.advance(const Duration(milliseconds: 4900));
      expect(ctx.phase, CorePhase.settling);
      final n = changes;
      await time.advance(const Duration(milliseconds: 100));
      expect(ctx.phase, CorePhase.settled);
      expect(changes, n + 1, reason: 'the settle is announced');
    });

    test('the settle time is configurable', () async {
      ctx.settle = const Duration(seconds: 1);
      ctx.started();
      await time.advanceSeconds(1);
      expect(ctx.settled, isTrue);
    });

    test('an own restart of a settled core is unsettled again; the reason is kept', () async {
      ctx.starting('userConnect');
      ctx.started();
      await time.advanceSeconds(6);
      expect(ctx.settled, isTrue);
      ctx.starting('refreshLists');
      expect(ctx.phase, CorePhase.starting);
      expect(ctx.core.restartReason, 'refreshLists');
      ctx.started();
      expect(ctx.phase, CorePhase.settling);
    });

    test('a crash is recovering, the attempt keeps it so, 30 s on the service says down, a start is settling', () async {
      ctx.starting('userConnect');
      ctx.started();
      await time.advanceSeconds(6);
      ctx.crashed();
      expect(ctx.phase, CorePhase.recovering);
      ctx.starting('recover');
      expect(ctx.phase, CorePhase.recovering, reason: 'an attempt is not a new state');
      expect(ctx.core.restartReason, 'recover');
      ctx.down();
      expect(ctx.phase, CorePhase.down);
      ctx.starting('recover');
      expect(ctx.phase, CorePhase.down);
      ctx.started();
      expect(ctx.phase, CorePhase.settling);
    });

    test('an adopted sing-box that has been up for long is settled at once', () {
      ctx.starting('adopt');
      ctx.started(since: time.t.subtract(const Duration(minutes: 10)));
      expect(ctx.phase, CorePhase.settled);
      // (attaching is instant: a failure seen after it was never ours)
      expect(ctx.lastUnsettled(time.t.add(const Duration(milliseconds: 1))), isNull);
    });

    test('stopped ends everything', () {
      ctx.starting('userConnect');
      ctx.started();
      ctx.stopped();
      expect(ctx.phase, CorePhase.stopped);
      expect(ctx.untilSettled(), isNull);
    });
  });

  group('lastUnsettled: the windows of our own restarts', () {
    test('null when the core was settled since the moment; the end of a past restart; now while it is not settled', () async {
      ctx.starting('userConnect');
      ctx.started();
      await time.advanceSeconds(6); // settled at +5
      final t0 = time.t;
      expect(ctx.lastUnsettled(t0), isNull);
      await time.advanceSeconds(20);
      final before = time.t;
      ctx.starting('refreshLists'); // at +26
      ctx.started();
      await time.advanceSeconds(2);
      expect(ctx.lastUnsettled(before), time.t, reason: 'not settled now: now');
      await time.advanceSeconds(10);
      final settledAt = before.add(const Duration(seconds: 5));
      expect(ctx.lastUnsettled(before), settledAt);
      expect(ctx.lastUnsettled(settledAt.add(const Duration(seconds: 1))), isNull, reason: 'a failure seen after the settle is not ours');
      expect(ctx.lastUnsettled(t0), settledAt);
    });

    test('a crash and its restarts count until the settle after the start', () async {
      ctx.starting('userConnect');
      ctx.started();
      await time.advanceSeconds(10);
      final seen = time.t;
      await time.advanceSeconds(1);
      ctx.crashed();
      await time.advanceSeconds(1);
      expect(ctx.lastUnsettled(seen), time.t);
      await time.advanceSeconds(3);
      ctx.starting('recover');
      ctx.started();
      await time.advanceSeconds(10);
      expect(ctx.lastUnsettled(seen), isNotNull);
      expect(ctx.settled, isTrue);
    });
  });
}
