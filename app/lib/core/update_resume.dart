import 'dart:async';

import '../platform/notify_channel.dart';
import '../platform/tile_channel.dart';
import 'core_host.dart';
import 'settings_model.dart';
import 'tile_sync.dart';

/// After the app's own update (docs/updates.md, "Подключение после обновления"): brings the core
/// up and lets the host reconnect the VPN that the update interrupted. Runs from `main()`, so it
/// works with no window (the process was started by the package replacement and the engine has no
/// view yet): the UI is not involved, only the platform pieces the window would have kept in sync -
/// the Quick Settings tile and the VPN notification's name - are told here.
Future<ResumeOutcome> resumeInBackground(
  CoreHost host, {
  TilePort? tile,
  NotifyIo? notify,
}) async {
  await host.init();
  final outcome = await host.resumeAfterUpdate();
  if (outcome == ResumeOutcome.resumed) {
    final dock = host.dock;
    try {
      await tile?.push(TileState('on', tileName(dock), dock.hasEntry));
    } catch (_) {}
    try {
      await notify?.setVpnNode(_vpnNodeLabel(host));
    } catch (_) {}
  }
  return outcome;
}

/// What the VPN notification shows (`Entry · server`, as `SystemNotifier` does while the window is
/// open); null where the user switched the name off.
String? _vpnNodeLabel(CoreHost host) {
  final n = host.notif;
  if (!n.enabled || !n.flag('status')) return null;
  final d = host.dock;
  if (!d.hasEntry) return null;
  final server = d.node?.name ?? '';
  return server.isEmpty || server == d.name ? d.name : '${d.name} · $server';
}
