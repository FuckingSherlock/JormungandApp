import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventGroup, EventRecord;

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

  /// The id of the `conn/vpnDown` notification posted and not closed yet.
  int? _downId;

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
  ///
  /// The words are the row's ([EventWords.describeGroup], [EventWords.reasonLine]); up to two bold buttons
  /// of the row. The notification's id is the event's, except: the closer of a pair (`opens`) replaces the
  /// opener's; any consequence (`cause`) is the root's business and stays silent.
  Future<void> postEvent(EventRecord e, EventWords words) {
    final cause = e.cause;
    if (cause != null) return Future.value();
    if (e.key == 'conn/vpnUp' && e.data['by'] != null) {
      // ended by the user: the shown «VPN is down» comes off the shade; by the system: it stays for the revoke's
      // notification to replace; either way the closing has no notification of its own
      if (e.data['by'] == 'user' && _downId != null && e.opens == _downId) {
        final shown = _downId!;
        _downId = null;
        return io.cancelEvent(shown);
      }
      // the app ended without a disconnect: the «VPN is down» shown by the process that died is still on the shade
      // (this process knows no `_downId`, the notification's id is the opened event's)
      if (e.data['by'] == 'app' && e.opens != null) {
        _downId = null;
        return io.cancelEvent(e.opens!);
      }
      return Future.value();
    }
    var id = e.opens ?? cause ?? e.id;
    if (e.key == 'conn/vpnDown') _downId = e.id;
    if (e.key == 'conn/vpnUp' && e.opens == _downId) _downId = null;
    if (e.key == 'conn/disconnected' && e.data['by'] == 'system') {
      // the VPN was taken away: this replaces the «VPN is down» that was on the shade (its `vpnUp` came right before)
      id = _downId ?? id;
      _downId = null;
    }
    final g = EventGroup(e);
    // the closing of «VPN is down» speaks for itself (a lone group of it would read as the failure)
    final (title, sub, detail) = e.key == 'conn/vpnUp'
        ? (words.describe(e).title, words.describe(e).sub, words.describe(e).detail)
        : words.describeGroup(g);
    final reason = e.key == 'conn/vpnUp' ? null : words.reasonLine(g);
    // "does not open": Create rule (when it opens through another entry) and Ignore site
    final site = e.cat == 'site' || e.key == 'conn/failing' ? words.host(e.data) : '';
    final via = e.cat == 'site' ? '${e.data['viaTarget'] ?? e.data['via'] ?? ''}' : '';
    return io.post(
      SystemNote(
        id: id,
        title: title,
        text: [sub, detail, reason ?? ''].where((s) => s.isNotEmpty).join('\n'),
        site: site,
        via: via,
        // what «Ignore site» turns the notification into (done natively, in the app's language)
        ignoredText: e.cat != 'site' || site.isEmpty ? '' : words.l10n.addedToIgnoredSites(site),
        undoLabel: e.cat != 'site' || site.isEmpty ? '' : words.l10n.undo,
        actions: e.opens != null ? const [] : eventActions(e, words, host),
      ),
    );
  }

  /// A site event changed in place to «opens again» (`data.reopened`): its notification, if it is on the shade,
  /// comes off. [id] is the one [postEvent] posted it with (`opens ?? id`).
  Future<void> dropEvent(int id) => io.available ? io.cancelEvent(id) : Future.value();

  static List<String> _vpnCauses(Map<String, dynamic> d) {
    final c = d['causes'];
    return c is List ? [for (final x in c) '$x'] : const [];
  }

  /// The bold buttons of an event (docs/logs.md → «По типам»; the plain ones live in the row only), two at
  /// most: `(id, label)`, the ids are what the shell's `_actFromShade` understands.
  static List<(String, String)> eventActions(EventRecord e, EventWords words, CoreHost host) {
    final l = words.l10n, d = e.data;
    final site = e.cat == 'site' || e.key == 'conn/failing' ? words.host(d) : '';
    // an event with an app has no Create rule: its rule is a row of the app in the event (docs/connect-model.md)
    final withApp = words.appPkg(d).isNotEmpty;
    final isSub = host.catalog.sourcesData['${d['source']}']?.kind == 'sub';
    final out = switch (e.key) {
      // Connect is bold for every `by: error` (logs.md «По типам»); Choose server of a lost pin stays in the row
      'conn/disconnected' when d['by'] == 'error' || d['by'] == 'system' => [('connect', l.connect)],
      // `retry` of a failed connect connects again (the shell routes it by the event: the same call as the row's Retry)
      'conn/connectFailed' => [('retry', l.retry)],
      'conn/lost' => [('checkNow', l.checkNow)],
      'conn/offline' => [('networkSettings', l.networkSettings)],
      'conn/vpnDown' => [
        if (_vpnCauses(d).contains('core') && host.phase != ConnectionPhase.connected) ('retry', l.retry),
        if (_vpnCauses(d).contains('network')) ('networkSettings', l.networkSettings),
        if (_vpnCauses(d).contains('routes') || d['pending'] == 'routes') ('checkNow', l.checkNow),
      ],
      'conn/failing' => [if (site.isNotEmpty && !withApp) ('rule', l.createRule)],
      'auto/unstable' => [('open', l.open)],
      // `open` of a DNS event opens Settings → DNS (eventOpenTarget: dns → 'dns'); dns/up replaces it in place
      'dns/down' => [('open', l.dnsSettings)],
      'sub/updated' || 'sub/removed' || 'sub/back' => [('open', l.open)],
      'sub/failed' => [if (isSub) ('retrySub', l.retry)],
      'node/addressMissing' => [if (isSub) ('retrySub', l.updateSubscription)],
      'rules/targetLost' || 'rules/targetFound' || 'rules/fallback' => [('open', l.openRule)],
      'rules/ruleSetFailed' => [('retryRuleSets', l.retry)],
      'core/crashed' || 'core/restartFailed' || 'core/down' when host.phase != ConnectionPhase.connected => [('retry', l.retry)],
      'core/tunNeedsAdmin' => [('open', l.openSettings)],
      'core/tunTcpDead' => [('reconnect', l.reconnect)],
      'core/sysProxy' when d['error'] != null => [('retry', l.retry)],
      _ when site.isNotEmpty => [
        if (e.type == 'blocked' && !withApp && '${d['viaTarget'] ?? d['via'] ?? ''}'.isNotEmpty) ('rule', l.createRule),
        ('ignore', l.ignoreSite),
      ],
      _ => <(String, String)>[],
    };
    return out.take(2).toList();
  }

  /// The app came to the front: what was posted meanwhile is stale.
  void onResumed() {
    if (!io.available) return;
    io.cancelEvents();
    _downId = null;
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
