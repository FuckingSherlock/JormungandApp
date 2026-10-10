import 'package:flutter/services.dart';

/// A tunnel that went away without being asked to: the user (or another VPN app) took the VPN
/// away in system settings.
class VpnStopped {
  const VpnStopped(this.reason);

  /// `revoked`.
  final String reason;
}

/// Dart side of the Android VpnService bridge: MethodChannel `jormungand/vpn` + EventChannel
/// `jormungand/vpn_events` (Kotlin: android_overlay/kotlin/VpnChannel.kt.tmpl). On other
/// platforms the methods are no-ops (the Windows core handles its own tunnel).
///
/// Errors of `start` / `startBox` arrive as [PlatformException] (code `start_failed`, message =
/// sing-box's reason).
class VpnChannel {
  const VpnChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/vpn');
  static const EventChannel _events = EventChannel('jormungand/vpn_events');

  /// Asks Android for the VPN consent dialog when it was not given yet.
  /// Returns true when the app may start the VPN.
  Future<bool> prepare() async {
    try {
      return (await _channel.invokeMethod<bool>('prepare')) ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Starts (or restarts, when it already runs) the tunnel: the foreground VpnService runs
  /// libbox (sing-box) with [config] (JSON, the one the core built). Returns when sing-box is up.
  Future<void> start({String? config}) async {
    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{
        'config': config,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  /// Closes the tunnel and the service; returns when that is done.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // not Android
    }
  }

  /// A libbox with NO tunnel under [id] (latency tests, Speed Test): the same engine, a config
  /// without a `tun` inbound. Returns when it is up.
  Future<void> startBox(String id, String config) async {
    try {
      await _channel.invokeMethod<void>('startBox', <String, Object?>{
        'id': id,
        'config': config,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  Future<void> stopBox(String id) async {
    try {
      await _channel.invokeMethod<void>('stopBox', <String, Object?>{'id': id});
    } on MissingPluginException {
      // not Android
    }
  }

  /// Whether the tunnel runs now.
  Future<bool> running() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('status');
      return m?['running'] == true;
    } on MissingPluginException {
      return false;
    }
  }

  /// Keeps [record] in the service next to the running tunnel (dropped when the tunnel stops, so
  /// it can never describe one that is gone). A new engine reads it with [recall].
  Future<void> remember(String record) async {
    try {
      await _channel.invokeMethod<void>('remember', <String, Object?>{
        'record': record,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  /// Whether the tunnel runs and what [remember] was given for it.
  Future<({bool running, String? record})> recall() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('status');
      final r = m?['record'];
      return (running: m?['running'] == true, record: r is String ? r : null);
    } on MissingPluginException {
      return (running: false, record: null);
    }
  }

  /// The device's ABIs, best first (`Build.SUPPORTED_ABIS`); empty off Android.
  Future<List<String>> abis() async {
    try {
      final l = await _channel.invokeListMethod<String>('abis');
      return l ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// The device for the support report: `model`, `manufacturer`, `brand`, `androidApi` (int),
  /// `androidRelease`; empty off Android.
  Future<Map<String, dynamic>> deviceInfo() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('device');
      return {...?m};
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  /// The sing-box version built into libbox; null when unknown.
  Future<String?> libboxVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('libboxVersion');
      return v == null || v.isEmpty ? null : v;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The installed app's `versionName` and `versionCode`; null off Android.
  Future<({String name, int code})?> appVersion() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('appVersion');
      final name = m?['name'];
      final code = m?['code'];
      if (name is! String || name.isEmpty || code is! num) return null;
      return (name: name, code: code.toInt());
    } on MissingPluginException {
      return null;
    }
  }

  // One platform listen for every consumer: the Kotlin side keeps a single sink, and a second
  // `receiveBroadcastStream()` would replace it (and a cancel of the first would drop it).
  static final Stream<dynamic> _all = _events.receiveBroadcastStream();

  /// The tunnel going away on its own. A broadcast stream; a plain [stop] sends nothing.
  Stream<VpnStopped> get stopped => _all
      .where((e) => e is Map && e['type'] == 'stopped')
      .map((e) => VpnStopped('${(e as Map)['reason'] ?? ''}'));

  /// What the Kotlin side says about itself (libbox start / stop, networks, DNS, protect):
  /// `level` is debug, info, warn or error. What was said before the first listener is kept
  /// there and arrives first.
  Stream<({String level, String text})> get logs => _all
      .where((e) => e is Map && e['type'] == 'log')
      .map((e) => (level: '${(e as Map)['level'] ?? 'info'}', text: '${e['text'] ?? ''}'));
}
