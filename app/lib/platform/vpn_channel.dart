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

  /// The tunnel going away on its own. A broadcast stream; a plain [stop] sends nothing.
  Stream<VpnStopped> get stopped => _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['type'] == 'stopped')
      .map((e) => VpnStopped('${(e as Map)['reason'] ?? ''}'));
}
