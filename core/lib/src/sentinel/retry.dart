/// The retry rules of the core's own traffic (updates, reports, rule sets; docs/failures.md → Повторы):
/// what to wait for after a failed attempt. Pure advice plus one wait; nothing here sends anything.
library;

import 'dart:async';

import 'context.dart';

/// What the failed attempt ran into.
enum RetryKind {
  /// It failed while our own restart of sing-box was under way (or just after): not the path's fault.
  ownRestart,

  /// The network or the server did not answer.
  network,
}

/// What to wait for before the next attempt.
enum RetryWait {
  /// Just [RetryAdvice.after].
  time,

  /// The core to settle (an own restart is over).
  settled,

  /// The network to come back (it is known to be missing).
  networkUp,
}

class RetryAdvice {
  const RetryAdvice(this.waitFor, {this.after, this.attempt = 0});

  final RetryWait waitFor;

  /// For [RetryWait.time]: how long.
  final Duration? after;

  /// The number of the network failure in a row this advice follows (0 = it does not count).
  final int attempt;

  @override
  String toString() => 'RetryAdvice($waitFor, after: $after, attempt: $attempt)';
}

/// 1 → 2 → 5 → 15 min after a network failure (and 15 min from then on); a failure of an own restart
/// is retried as soon as the core settles; no network is waited out. The count starts over when the
/// network changes (another network, an interface change) and when the connection is made again.
class RetryPolicy {
  RetryPolicy(this.context, {this.steps = const [Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 5), Duration(minutes: 15)]});

  final ContextTracker context;
  final List<Duration> steps;

  int _failures = 0;
  int? _netEpoch, _coreEpoch;

  /// Network failures in a row since the last reset.
  int get failures {
    _syncEpoch();
    return _failures;
  }

  /// An attempt worked: the next failure starts from the first step.
  void reset() => _failures = 0;

  void _syncEpoch() {
    final n = context.netEpoch, c = context.coreEpoch;
    if ((_netEpoch != null && n != _netEpoch) || (_coreEpoch != null && c != _coreEpoch)) _failures = 0;
    _netEpoch = n;
    _coreEpoch = c;
  }

  /// What to do after an attempt failed with [kind].
  RetryAdvice advise(RetryKind kind) {
    _syncEpoch();
    final net = context.network.state;
    if (net == NetState.none || net == NetState.captive) return const RetryAdvice(RetryWait.networkUp);
    if (kind == RetryKind.ownRestart) return const RetryAdvice(RetryWait.settled);
    final n = _failures++;
    return RetryAdvice(RetryWait.time, after: steps[n < steps.length ? n : steps.length - 1], attempt: n + 1);
  }

  /// Waits as [advice] says: the time (cut short when the network changes: the attempt is worth making on
  /// the new one), the settle, or the network's return. Completes at once when the condition holds already.
  Future<void> wait(RetryAdvice advice) {
    final done = Completer<void>();
    Timer? timer;
    StreamSubscription<void>? sub;
    final netAtStart = context.netEpoch;

    bool ready() {
      switch (advice.waitFor) {
        case RetryWait.time:
          return context.netEpoch != netAtStart && context.network.state != NetState.none && context.network.state != NetState.captive;
        case RetryWait.settled:
          final p = context.phase;
          return p == CorePhase.settled || p == CorePhase.stopped || p == CorePhase.down;
        case RetryWait.networkUp:
          final s = context.network.state;
          return s == NetState.up || s == NetState.unknown;
      }
    }

    void finish() {
      if (done.isCompleted) return;
      timer?.cancel();
      unawaited(sub?.cancel());
      done.complete();
    }

    if (advice.waitFor != RetryWait.time && ready()) return Future.value();
    sub = context.changes.listen((_) {
      if (ready()) finish();
    });
    // (the settle is a change of the context itself: the tracker's timer fires it)
    if (advice.waitFor == RetryWait.time) timer = context.clock.timer(advice.after ?? Duration.zero, finish);
    return done.future;
  }
}
