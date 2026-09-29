/// Closing what a switch left behind: after a route, a server or a rule target stopped
/// answering and traffic moved off it, the connections still on it are mostly stuck. A switch
/// never cuts the open connections (`interrupt_exist_connections: false`, so a return
/// to a recovered route does not cut the ones that work); this closes the stuck ones so
/// their apps reconnect the new way.
library;

import 'dart:async';

import 'sbapi.dart' show BoxControl;

class StallSweeper {
  StallSweeper(this.api);

  final BoxControl api;
  final _timers = <Timer>{};
  bool _stopped = false;

  /// Connections whose chain has [tag] (the route, server or group left): the ones whose
  /// byte counters stood still for [every] are closed, the ones still moving live on.
  /// Again every [every], up to [times] passes, while [away]. [onClosed] per connection closed.
  void sweep(String tag, bool Function() away, {required Duration every, int times = 6, void Function()? onClosed}) {
    Map<String, int>? before;
    var left = times;
    Future<void> pass() async {
      if (_stopped || !away()) return;
      final now = <String, int>{
        for (final c in api.connections)
          if (c.chain.contains(tag)) c.id: c.up + c.down,
      };
      if (before != null) {
        for (final e in [...now.entries]) {
          if (before![e.key] == e.value && !_stopped) {
            if (await api.closeConnection(e.key)) onClosed?.call();
            now.remove(e.key);
          }
        }
      }
      before = now;
      if (now.isEmpty || --left <= 0 || _stopped) return;
      late final Timer t;
      t = Timer(every, () {
        _timers.remove(t);
        unawaited(pass());
      });
      _timers.add(t);
    }

    unawaited(pass());
  }

  void stop() {
    _stopped = true;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }
}
