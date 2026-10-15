// The retry rules (sentinel/retry.dart): 1 → 2 → 5 → 15 min after a network failure, an own restart's
// failure waits for the settle, no network waits for it, and a move to another network starts over.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

void main() {
  late FakeTime time;
  late ContextTracker ctx;
  late RetryPolicy policy;

  setUp(() {
    time = FakeTime();
    ctx = ContextTracker(clock: time.clock)
      ..noSignalGrace = Duration.zero // the disturbance after a move has its own tests (net_switch_test.dart)
      ..switchCap = Duration.zero;
    policy = RetryPolicy(ctx);
  });

  Duration? after(RetryKind k) => policy.advise(k).after;

  test('network failures: 1, 2, 5, 15 and then 15 minutes', () {
    expect([for (var i = 0; i < 6; i++) after(RetryKind.network)!.inMinutes], [1, 2, 5, 15, 15, 15]);
    expect(policy.failures, 6);
  });

  test('attempt numbers count the failures in a row', () {
    expect([for (var i = 0; i < 3; i++) policy.advise(RetryKind.network).attempt], [1, 2, 3]);
  });

  test('reset(): the next failure is the first step again', () {
    after(RetryKind.network);
    after(RetryKind.network);
    policy.reset();
    expect(after(RetryKind.network)!.inMinutes, 1);
  });

  test('the count starts over when the device moves to another network, or the interface changes', () {
    ctx.platform(connected: true, validated: true, type: 'wifi', id: '1');
    after(RetryKind.network);
    after(RetryKind.network);
    ctx.platform(connected: true, validated: true, type: 'cellular', id: '2');
    expect(after(RetryKind.network)!.inMinutes, 1);
    after(RetryKind.network);
    ctx.interfaceChanged();
    expect(after(RetryKind.network)!.inMinutes, 1);
  });

  test('the count starts over when the connection is made again (a new start of the core)', () {
    ctx.starting('userConnect');
    ctx.started();
    after(RetryKind.network);
    after(RetryKind.network);
    ctx.stopped();
    ctx.starting('userConnect');
    ctx.started();
    expect(after(RetryKind.network)!.inMinutes, 1);
  });

  test('the network coming back after a loss starts over too', () {
    after(RetryKind.network);
    ctx.pool(NetStatus.down, osOffline: true);
    ctx.pool(NetStatus.up, osOffline: false);
    expect(after(RetryKind.network)!.inMinutes, 1);
  });

  test('a failure of our own restart waits for the settle and does not count', () {
    final a = policy.advise(RetryKind.ownRestart);
    expect((a.waitFor, a.attempt), (RetryWait.settled, 0));
    expect(after(RetryKind.network)!.inMinutes, 1);
  });

  test('no network (none / captive): wait for it, whatever failed, nothing is counted', () {
    ctx.pool(NetStatus.down, osOffline: true);
    expect(policy.advise(RetryKind.network).waitFor, RetryWait.networkUp);
    expect(policy.advise(RetryKind.ownRestart).waitFor, RetryWait.networkUp);
    expect(policy.failures, 0);
    ctx.pool(NetStatus.up, osOffline: false);
    ctx.platform(captive: true);
    expect(policy.advise(RetryKind.network).waitFor, RetryWait.networkUp);
  });

  group('wait', () {
    test('time: the pause passes', () async {
      var done = false;
      policy.wait(const RetryAdvice(RetryWait.time, after: Duration(minutes: 1))).then((_) => done = true);
      await time.advance(const Duration(seconds: 59));
      expect(done, isFalse);
      await time.advance(const Duration(seconds: 2));
      expect(done, isTrue);
    });

    test('time: another network cuts it short, the same network does not', () async {
      var done = false;
      policy.wait(const RetryAdvice(RetryWait.time, after: Duration(minutes: 15))).then((_) => done = true);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '1');
      await time.advance(const Duration(minutes: 1));
      expect(done, isFalse);
      ctx.platform(connected: true, validated: true, type: 'wifi', id: '2');
      await time.advance(const Duration(milliseconds: 1));
      expect(done, isTrue);
      expect(time.pending, 0, reason: 'the timer is gone');
    });

    test('time: a move to a network that is not there does not cut it short', () async {
      var done = false;
      policy.wait(const RetryAdvice(RetryWait.time, after: Duration(minutes: 15))).then((_) => done = true);
      ctx.platform(connected: false);
      await time.advance(const Duration(minutes: 1));
      expect(done, isFalse);
    });

    test('settled: at once when the core is settled or not running, else at the settle', () async {
      ctx.starting('userConnect');
      ctx.started();
      var done = false;
      policy.wait(const RetryAdvice(RetryWait.settled)).then((_) => done = true);
      await time.advanceSeconds(4);
      expect(done, isFalse);
      await time.advanceSeconds(2);
      expect(done, isTrue);
      var again = false;
      policy.wait(const RetryAdvice(RetryWait.settled)).then((_) => again = true);
      await time.advance(const Duration(milliseconds: 1));
      expect(again, isTrue, reason: 'settled already');
    });

    test('networkUp: when the network is back', () async {
      ctx.pool(NetStatus.down, osOffline: true);
      var done = false;
      policy.wait(const RetryAdvice(RetryWait.networkUp)).then((_) => done = true);
      await time.advanceSeconds(600);
      expect(done, isFalse);
      ctx.pool(NetStatus.up, osOffline: false);
      await time.advance(const Duration(milliseconds: 1));
      expect(done, isTrue);
    });
  });
}
