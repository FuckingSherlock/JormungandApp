// Time by hand for the Sentinel's tests: a clock that moves only when the test says so, and timers
// that fire in order of their due time while it moves.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

class FakeTime {
  FakeTime([DateTime? start]) : t = start ?? DateTime(2026, 10, 12, 12);

  DateTime t;
  final _timers = <_FakeTimer>[];

  late final SentinelClock clock = SentinelClock(now: () => t, timer: _make);

  Timer _make(Duration d, void Function() f) {
    final ft = _FakeTimer(t.add(d), f);
    _timers.add(ft);
    return ft;
  }

  int get pending => _timers.where((x) => x.isActive).length;

  /// Moves time by [d], firing every timer that falls due on the way (and letting what they wake run).
  Future<void> advance(Duration d) async {
    final end = t.add(d);
    while (true) {
      await pumpEventQueue();
      final due = _timers.where((x) => x.isActive && !x.due.isAfter(end)).toList()..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final x = due.first;
      if (x.due.isAfter(t)) t = x.due;
      x.fire();
    }
    t = end;
    await pumpEventQueue();
  }

  Future<void> advanceSeconds(int s) => advance(Duration(seconds: s));
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._f);

  final DateTime due;
  final void Function() _f;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _f();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
