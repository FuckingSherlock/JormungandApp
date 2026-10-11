import 'dart:async';

/// The Sentinel's time: the clock and the waits come from here, so a test moves them by hand.
class SentinelClock {
  SentinelClock({DateTime Function()? now, Timer Function(Duration, void Function())? timer})
      : _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _timer;

  DateTime now() => _now();

  Timer timer(Duration d, void Function() f) => _timer(d, f);

  /// Completes after [d] (at once for zero or less).
  Future<void> delay(Duration d) {
    if (d <= Duration.zero) return Future.value();
    final c = Completer<void>();
    _timer(d, c.complete);
    return c.future;
  }
}
