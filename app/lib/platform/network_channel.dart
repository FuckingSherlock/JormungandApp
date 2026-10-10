import 'package:flutter/services.dart';

/// The seam to what the platform knows about the network the phone really uses (not our own VPN
/// on top of it): is it metered. Settings -> Data «Auto-download» (Wi-Fi only) goes by it; a fake
/// in tests. Where there is no port (the desktop) the network counts as unmetered.
abstract interface class NetworkPort {
  /// The value now.
  Future<bool> metered();

  /// Every change of [metered]; the current value comes at once on listen.
  Stream<bool> get meteredChanges;

  /// What the phone is really on, for the support report: `wifi` | `ethernet` | `mobile` | `other` |
  /// `none` | `unknown`.
  Future<String> type();
}

/// Android: MethodChannel `jormungand/network` + EventChannel `jormungand/network_events`
/// (Kotlin: android_overlay/kotlin/NetworkChannel.kt.tmpl).
class NetworkChannel implements NetworkPort {
  const NetworkChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/network');
  static const EventChannel _events = EventChannel('jormungand/network_events');

  @override
  Future<bool> metered() async {
    try {
      return await _channel.invokeMethod<bool>('metered') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<String> type() async {
    try {
      return await _channel.invokeMethod<String>('type') ?? 'unknown';
    } on MissingPluginException {
      return 'unknown';
    } on PlatformException {
      return 'unknown';
    }
  }

  @override
  Stream<bool> get meteredChanges =>
      _events.receiveBroadcastStream().where((e) => e is bool).cast<bool>();
}
