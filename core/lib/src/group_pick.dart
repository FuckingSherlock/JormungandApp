/// Choosing a server of a group by a fresh check (docs/core.md → Auto → «Выбор сервера группы»): the pure part. The
/// callers (auto.dart, fallback.dart, the connect) give a [Probe1] — one real test of a server by its key, through the
/// probe pool (pool.dart) — and get the key to use; nothing here knows sing-box, a route or a plan.
///
/// - [pickPriority]: the keys in the user's order, all tested in parallel; the answer is the first one in the order that
///   answered, so only the servers above the best answer so far are waited for (the ones below it never matter).
///   An answer of the backup checker alone ([PoolResult.byChecker]) is an answer here.
/// - [pickFastest]: the first strong answer (the test URL answered) opens a window of [pickWindow]; the fastest strong
///   answer of the window wins. A weak answer (only a backup checker answered: the node passes traffic, the test URL
///   missed through it) is not "alive with a delay" here: when a batch ends with weak answers only, ONE more wave of
///   [pickParallel] next candidates is tested for a strong answer (a strong one found wins, by the window rule); if
///   there is none, the best weak answer of everything tried wins.
///
/// Both go by batches: the first [pickFirstBatch] keys (in the order given) are tested at once; if none of them answered
/// at all, the rest follow at once at the normal ping parallelism ([pickParallel], the same as `measureLatency`), in the
/// same order, until one answers. There is no cap on the number of rounds: a group of dead servers is tested to its end.
///
/// [rankCandidates] puts the keys in the order the batches go by.
library;

import 'dart:async';

import 'pool.dart';
import 'sentinel/model.dart' show Cancel;

/// One real test of the server [key]: the pool's result ([PoolResult.ms] -1 = no answer).
typedef Probe1 = Future<PoolResult> Function(String key);

/// How many servers the first batch tests at once.
const pickFirstBatch = 5;

/// How long after the first strong answer the other answers are still waited for ([pickFastest]).
const pickWindow = Duration(seconds: 1);

/// The parallelism of the batches after the first (the ping's: `measureLatency`).
const pickParallel = 16;

/// What a pick found. [key] null = nobody answered (or [cancelled]).
class GroupPick {
  const GroupPick({this.key, this.ms = -1, this.weak = false, required this.tried, required this.answered, required this.tookMs, this.cancelled = false});

  /// The server chosen; null = none answered.
  final String? key;

  /// Its delay, ms (-1 with no [key]).
  final int ms;

  /// It answered only by a backup checker (the test URL missed through it).
  final bool weak;

  /// How many servers were tested, how many of them answered by the time the pick was made.
  final int tried, answered;

  /// How long the pick took, ms.
  final int tookMs;

  /// The caller cancelled it: nothing was decided.
  final bool cancelled;

  bool get found => key != null;

  Map<String, dynamic> toJson() => {'key': key, 'ms': ms, 'weak': weak, 'tried': tried, 'answered': answered, 'tookMs': tookMs};
}

/// The order the batches go by: the servers with a strong answer in the pool (the caller gives [peek] only the fresh
/// ones) by their ms, then the rest in the order given (the plan's), the servers on the dead ladder ([dead]) last.
List<String> rankCandidates(List<String> keys, {required PoolResult? Function(String key) peek, bool Function(String key)? dead}) {
  final strong = <String, int>{}, rest = <String>[], gone = <String>[];
  for (final k in keys) {
    final p = peek(k);
    if (p != null && p.answered && !p.byChecker) {
      strong[k] = p.ms;
    } else if (dead != null && dead(k)) {
      gone.add(k);
    } else {
      rest.add(k);
    }
  }
  // stable by ms: equal ones keep the order given
  final sorted = [
    for (final k in keys)
      if (strong.containsKey(k)) k,
  ]..sort((a, b) => strong[a]!.compareTo(strong[b]!));
  return [...sorted, ...rest, ...gone];
}

/// [afterEmpty] (both): asked once, when the first batch ended with no answer and servers are left; true = stop here
/// (nothing was decided: no [GroupPick.key]). The connect tests the direct path there, no network = no point in testing on.
Future<GroupPick> pickPriority(List<String> ordered, Probe1 probe,
        {Cancel? cancel, int first = pickFirstBatch, int parallel = pickParallel, Future<bool> Function()? afterEmpty}) =>
    _run(ordered, probe, fastest: false, window: Duration.zero, cancel: cancel, first: first, parallel: parallel, afterEmpty: afterEmpty);

Future<GroupPick> pickFastest(List<String> keys, Probe1 probe,
        {Duration window = pickWindow, Cancel? cancel, int first = pickFirstBatch, int parallel = pickParallel, Future<bool> Function()? afterEmpty}) =>
    _run(keys, probe, fastest: true, window: window, cancel: cancel, first: first, parallel: parallel, afterEmpty: afterEmpty);

Future<GroupPick> _run(List<String> keys, Probe1 probe,
    {required bool fastest, required Duration window, Cancel? cancel, required int first, required int parallel, Future<bool> Function()? afterEmpty}) async {
  final sw = Stopwatch()..start();
  final n = keys.length;
  final res = List<PoolResult?>.filled(n, null);
  var launched = 0, running = 0;
  var streaming = false; // the first batch ended with no answer: the rest go at the ping's parallelism
  var extraDone = false; // Fastest: the one more wave after a batch of weak answers only is made
  Stopwatch? opened; // the window of Fastest, opened by the first strong answer
  Completer<void>? wake;

  void launch() {
    final i = launched++;
    running++;
    Future<PoolResult> run() async {
      try {
        return await probe(keys[i]);
      } catch (_) {
        return const PoolResult(-1, 0);
      }
    }

    run().then((r) {
      res[i] = r;
      running--;
      final w = wake;
      wake = null;
      if (w != null && !w.isCompleted) w.complete();
    });
  }

  int answeredCount() => res.where((r) => r != null && r.answered).length;

  GroupPick done(int? i, {bool cancelled = false}) => GroupPick(
        key: i == null ? null : keys[i],
        ms: i == null ? -1 : res[i]!.ms,
        weak: i != null && res[i]!.byChecker,
        tried: launched,
        answered: answeredCount(),
        tookMs: sw.elapsedMilliseconds,
        cancelled: cancelled,
      );

  // the index chosen now, or null while it is not decided
  int? decide() {
    if (!fastest) {
      // the first in the order that answered, when everything above it has been heard from
      for (var i = 0; i < n; i++) {
        final r = res[i];
        if (r == null) return null;
        if (r.answered) return i;
      }
      return null;
    }
    int? best;
    for (var i = 0; i < n; i++) {
      final r = res[i];
      if (r != null && r.answered && !r.byChecker && (best == null || r.ms < res[best]!.ms)) best = i;
    }
    if (best != null) {
      opened ??= Stopwatch()..start();
      return running == 0 || opened!.elapsed >= window ? best : null;
    }
    if (running > 0) return null; // a strong one may still come
    if (!extraDone && launched < n && res.any((r) => r != null && r.answered)) return null; // weak only: one more wave first
    int? weak;
    for (var i = 0; i < n; i++) {
      final r = res[i];
      if (r != null && r.answered && (weak == null || r.ms < res[weak]!.ms)) weak = i;
    }
    return weak;
  }

  // any answer in hand: no new server is started (the ones below a Priority answer never matter; Fastest has what it needs)
  bool haveAnswer() => res.any((r) => r != null && r.answered);

  if (n == 0) return done(null);
  while (launched < first && launched < n) {
    launch();
  }
  for (;;) {
    if (cancel?.cancelled == true) return done(null, cancelled: true);
    final i = decide();
    if (i != null) return done(i);
    if (running == 0) {
      if (launched >= n) return done(null); // everything asked and nobody answered
      if (haveAnswer()) {
        // (only Fastest gets here: weak answers alone) one more wave for a strong answer
        extraDone = true;
        while (running < parallel && launched < n) {
          launch();
        }
      } else {
        // the first batch ended with no answer and servers are left: the caller may know why (the network is gone)
        if (!streaming && afterEmpty != null && await afterEmpty()) return done(null, cancelled: cancel?.cancelled == true);
        streaming = true;
      }
    }
    if (streaming && !haveAnswer()) {
      while (running < parallel && launched < n) {
        launch();
      }
    }
    if (running == 0) continue; // (nothing left to launch: decided above next turn)
    final w = wake = Completer<void>();
    final waits = <Future<void>>[w.future];
    if (cancel != null) waits.add(cancel.done);
    final o = opened;
    if (o != null) {
      final left = window - o.elapsed;
      waits.add(Future<void>.delayed(left > Duration.zero ? left : Duration.zero));
    }
    await Future.any(waits);
  }
}
