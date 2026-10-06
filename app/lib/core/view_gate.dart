import 'dart:async';

/// Starts the UI (`runApp`) exactly once, as soon as the platform has a view for it.
///
/// A headless engine (the process started by the package replacement, docs/updates.md) runs `main`
/// with no view; the window comes later. Two signals start the UI, whichever comes first, and a
/// second one does nothing: the view's metrics ([check], from `PlatformDispatcher.onMetricsChanged`)
/// and the native side saying a window attached to the engine ([windowAttached]). The second is the
/// one that cannot be missed; the view may still need a moment to report its size after it, so it
/// polls for [giveUp] at most.
class ViewGate {
  ViewGate({
    required this.hasView,
    required this.run,
    this.poll = const Duration(milliseconds: 100),
    this.giveUp = const Duration(seconds: 15),
  });

  /// `PlatformDispatcher.instance.implicitView != null`.
  final bool Function() hasView;

  /// `runApp(app)`.
  final void Function() run;
  final Duration poll;
  final Duration giveUp;

  bool _started = false;
  Timer? _timer;

  bool get started => _started;

  /// Starts the UI when there is a view and it has not been started yet.
  void check() {
    if (_started || !hasView()) return;
    _started = true;
    _timer?.cancel();
    run();
  }

  /// A window attached to the engine: start now, or as soon as its view reports in.
  void windowAttached() {
    check();
    if (_started || _timer != null) return;
    final sw = Stopwatch()..start();
    _timer = Timer.periodic(poll, (t) {
      check();
      if (_started || sw.elapsed >= giveUp) t.cancel();
    });
  }
}
