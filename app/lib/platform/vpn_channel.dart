import 'dart:typed_data';

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

  /// The device's ABIs, best first (`Build.SUPPORTED_ABIS`); empty off Android.
  Future<List<String>> abis() async {
    try {
      final l = await _channel.invokeListMethod<String>('abis');
      return l ?? const [];
    } on MissingPluginException {
      return const [];
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

  /// The installed apps (Rules -> Per-app routing): package, label, system or not. Empty off
  /// Android.
  Future<List<({String pkg, String name, bool system})>> apps() async {
    try {
      final l = await _channel.invokeListMethod<Map<Object?, Object?>>('apps');
      return [
        for (final m in l ?? const <Map<Object?, Object?>>[])
          if (m['pkg'] is String)
            (
              pkg: m['pkg'] as String,
              name: '${m['name'] ?? m['pkg']}',
              system: m['system'] == true,
            ),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// An app's icon as PNG bytes; null when it has none (or off Android).
  Future<Uint8List?> appIcon(String pkg) async {
    try {
      return await _channel.invokeMethod<Uint8List>('appIcon', <String, Object?>{
        'pkg': pkg,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The tunnel going away on its own. A broadcast stream; a plain [stop] sends nothing.
  Stream<VpnStopped> get stopped => _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['type'] == 'stopped')
      .map((e) => VpnStopped('${(e as Map)['reason'] ?? ''}'));
}
