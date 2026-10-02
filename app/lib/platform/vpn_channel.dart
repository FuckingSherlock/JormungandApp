import 'package:flutter/services.dart';

/// Dart side of the Android VpnService bridge: MethodChannel `jormungand/vpn`
/// (Kotlin: android_overlay/.../VpnChannel.kt.tmpl). On other platforms the methods are no-ops
/// (the Windows core handles its own tunnel).
class VpnChannel {
  const VpnChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/vpn');

  /// Asks Android for the VPN consent dialog when it was not given yet.
  /// Returns true when the app may start the VPN.
  Future<bool> prepare() async {
    try {
      return (await _channel.invokeMethod<bool>('prepare')) ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Starts the foreground VpnService with the sing-box config (JSON).
  /// TODO(libbox): the service passes it to libbox; today it only goes foreground.
  Future<void> start({String? config}) async {
    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{
        'config': config,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // not Android
    }
  }
}
