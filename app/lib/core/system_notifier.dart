import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventRecord;

import '../platform/notify_channel.dart';
import '../platform/power_channel.dart';
import 'core_host.dart';
import 'event_text.dart';
import 'settings_model.dart';

/// The app's side of the Android system notifications (the native side is `NotifyChannel` /
/// `AppNotifier`). Owned by the shell:
///  - an event the journal lets through (Settings -> Notifications) becomes a system notification
///    when the app is NOT in the foreground; in the foreground the shell shows its toast instead
///    ([systemNotifies] tells which);
///  - the first connect asks for the notification permission once (the system dialog is never
///    shown again on its own), and Settings asks when the user switches a kind on ([askForSwitch]);
///  - the VPN notification gets the name of the current connection and stays on the shade only while
///    the Status switch and the master switch are on ([NotifCfg.vpnStatusShown]); off, it is hidden
///    (the VPN keeps running).
///  - «Ignore site» on a notification is done on the native side without opening the app; the choices
///    queue up there and are applied here, in order, through [onIgnoreOp] (on start, when the app
///    comes back, and on the native side's ping).
/// Where there are no system notifications ([NotifyIo.available] is false) all of it does nothing.
class SystemNotifier {
  SystemNotifier(this.host, {NotifyIo? io, PowerIo? power, this.onIgnoreOp})
    : io = io ?? NotifyIo.current,
      power = power ?? PowerIo.current;

  final CoreHost host;
  final NotifyIo io;
  final PowerIo power;

  /// Applies one «Ignore site» / «Undo» made on the shade (the shell: the journal's ignored list).
  final void Function(SiteIgnoreOp op)? onIgnoreOp;

  StreamSubscription<void>? _queued;
  Future<void> _draining = Future.value();
  bool _disposed = false;
  bool _started = false;
  bool _wasOn = false;
  String? _sentNode;
  bool _nodeSent = false;
  bool? _sentShown;

  /// The app is not in front (anything but `resumed`; unknown yet counts as in front).
  static bool get inBackground {
    final s = WidgetsBinding.instance.lifecycleState;
    return s != null && s != AppLifecycleState.resumed;
  }

  /// Whether an event is to go to the shade rather than to a toast right now.
  bool get systemNotifies => io.available && inBackground;

  void start() {
    if (_started || !io.available) return;
    _started = true;
    io.refresh();
    io.onDisconnect = _disconnectFromShade;
    host.addListener(_onHost);
    _queued = io.ignoreQueued.listen((_) => drainIgnoreOps());
    _onHost();
    drainIgnoreOps(); // what was pressed while no Dart ran
  }

  void dispose() {
    _disposed = true;
    if (!_started) return;
    host.removeListener(_onHost);
    _queued?.cancel();
    io.onDisconnect = null;
  }

  /// Takes the «Ignore site» / «Undo» choices made on the shade and applies them in order once the host
  /// has loaded its state (the list lives in it). Calls follow one another, never overlap.
  Future<void> drainIgnoreOps() {
    if (!io.available || onIgnoreOp == null) return Future.value();
    return _draining = _draining.then((_) async {
      if (_disposed) return;
      await _whenReady();
      if (_disposed) return;
      for (final op in await io.takeIgnoreOps()) {
        try {
          onIgnoreOp!(op);
        } catch (_) {
          // one bad entry must not hold the rest back
        }
      }
    });
  }

  Future<void> _whenReady() {
    if (host.ready) return Future.value();
    final c = Completer<void>();
    void check() {
      if (!host.ready) return;
      host.removeListener(check);
      c.complete();
    }

    host.addListener(check);
    return c.future;
  }

  Future<void> _disconnectFromShade() => host.disconnect();

  /// An event that passed the journal's filter: the shade, with its own words.
  Future<void> postEvent(EventRecord e, EventWords words) {
    final d = words.describe(e);
    // "does not open": Create rule (when it opens through another entry) and Ignore site
    final site = e.cat == 'site' ? words.host(e.data) : '';
    final via = '${e.data['viaTarget'] ?? e.data['via'] ?? ''}';
    return io.post(
      SystemNote(
        id: e.id,
        title: d.title,
        text: d.detail,
        site: site,
        via: via,
        // what «Ignore site» turns the notification into (done natively, in the app's language)
        ignoredText: site.isEmpty ? '' : words.l10n.addedToIgnoredSites(site),
        undoLabel: site.isEmpty ? '' : words.l10n.undo,
        actions: [
          if (site.isNotEmpty && e.type == 'blocked' && via.isNotEmpty)
            ('rule', words.l10n.createRule),
          if (site.isNotEmpty) ('ignore', words.l10n.ignoreSite),
        ],
      ),
    );
  }

  /// The app came to the front: what was posted meanwhile is stale.
  void onResumed() {
    if (!io.available) return;
    io.cancelEvents();
    io.refresh(); // back from the system settings
    drainIgnoreOps(); // a ping that came before this Dart listened
  }

  /// Settings -> Notifications: a switch was turned on; asks for the permission when it is missing.
  /// Never when the user turns something off.
  static Future<void> askForSwitch(NotifyIo io, bool on) async {
    if (!on || !io.available) return;
    if (io.permission.value != NotifyPermission.granted) {
      await io.request();
    }
  }

  void _onHost() {
    // The notification's presence, connected or not: the native side keeps it for the next start of
    // the service (a reconnect, the tile, an update) when no Dart is there to say it.
    final shown = host.notif.vpnStatusShown;
    if (shown != _sentShown) {
      _sentShown = shown;
      io.setVpnVisible(shown);
    }
    final on = host.phase == ConnectionPhase.connected;
    if (on && !_wasOn) unawaited(_askOnce()); // the first connect only (the native side counts)
    _wasOn = on;
    if (!on) {
      _nodeSent = false; // the next connect shows its name again
      return;
    }
    final node = _nodeLabel();
    if (_nodeSent && node == _sentNode) return;
    _nodeSent = true;
    _sentNode = node;
    io.setVpnNode(node);
  }

  /// The first connect asks for the notification permission, then (one system dialog at a time,
  /// so after the first one is answered) for the battery-optimization exemption.
  Future<void> _askOnce() async {
    if (host.notif.enabled) await io.request(once: true);
    await power.request(once: true);
  }

  /// `Entry · server` of the dock; null when the name should not be shown or there is none.
  String? _nodeLabel() {
    if (!host.notif.vpnStatusShown) return null;
    final d = host.dock;
    if (!d.hasEntry) return null;
    final server = d.node?.name ?? '';
    return server.isEmpty || server == d.name ? d.name : '${d.name} · $server';
  }
}
