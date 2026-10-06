import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/platform_seams.dart';
import 'core/update_resume.dart';
import 'core/view_gate.dart';
import 'platform/notify_channel.dart';
import 'platform/resume_channel.dart';
import 'platform/tile_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The core runs inside the app: its data dir and this platform's seams (sing-box process or
  // libbox, system proxy) are chosen in platform_seams.dart; the host starts it (init) in the app.
  final host = await openCoreHost();
  // Android: right after the app's own update the system starts the process with no window; the
  // core comes up here anyway and brings the VPN back (a no-op on any other start).
  if (Platform.isAndroid) {
    unawaited(
      resumeInBackground(host, tile: const TileChannel(), notify: NotifyIo.current),
    );
  }
  _runWhenThereIsAView(JormungandApp(coreHost: host));
}

/// `runApp` needs the platform's view; a headless engine (the process started by the package
/// replacement) has none until the first window attaches, so the UI waits for it. The core above
/// does not. Two ways to learn that the view is there, the first one wins ([ViewGate]): its
/// metrics arrive, or the native side says a window attached (it cannot be missed, unlike a
/// callback that may not fire for a view added late).
void _runWhenThereIsAView(Widget app) {
  final d = PlatformDispatcher.instance;
  final gate = ViewGate(
    hasView: () => d.implicitView != null,
    run: () => runApp(app),
  );
  gate.check();
  if (gate.started) return;
  final previous = d.onMetricsChanged;
  d.onMetricsChanged = () {
    previous?.call();
    gate.check();
  };
  if (Platform.isAndroid) {
    ResumeChannel.onWindowAttached(gate.windowAttached);
  }
}
