/// What the checks of a service that moves traffic off something (a rule target:
/// fallback.dart; a DNS server: dns_failover.dart) remember about one thing: Auto's
/// [Health] and its flap guard (auto.dart), so "down" and "back" mean the same everywhere:
/// down after `failAfter` misses in a row; back after `failAfter` answers in a row and, for
/// a thing that dropped before, after answering the hold (1, 2, 4 … `flapMax` minutes) with no miss.
library;

import 'dart:math';

import 'auto.dart' show AutoSettings, Health;

class Watched {
  final health = Health();

  /// Times it dropped out of use (the flap guard's strikes); forgotten after `flapReset`
  /// of stable work in use.
  int strikes = 0;

  /// When it last went (back) into use, ms since epoch.
  int usedSince = 0;

  /// Missed `failAfter` times in a row.
  bool isDown(AutoSettings s) => health.fails >= s.failAfter;

  bool _onHold(AutoSettings s, int now) {
    final hold = s.hold(strikes);
    if (hold == Duration.zero) return false;
    final since = health.since;
    return since == null || now - since < hold.inMilliseconds;
  }

  /// Answers in a row and the hold served: fit to take the traffic back.
  bool mayReturn(AutoSettings s, int now) => health.oks >= s.failAfter && !_onHold(s, now);

  /// When the hold is served if it keeps answering; null = no hold, or not answering now.
  int? holdUntil(AutoSettings s, int now) {
    final since = health.since;
    return _onHold(s, now) && since != null ? since + s.hold(strikes).inMilliseconds : null;
  }

  /// It just dropped out of use.
  void struck() => strikes++;

  /// Called with each result while it is in use: stable work forgets the strikes.
  void forgetIfStable(AutoSettings s, int now) {
    final since = health.since;
    if (strikes > 0 && since != null && now - max(since, usedSince) >= s.flapReset.inMilliseconds) strikes = 0;
  }
}
