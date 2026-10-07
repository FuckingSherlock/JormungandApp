import 'package:flutter/services.dart';

/// The seam to the phone's screen state: on or off. The core marks a "site does not open" event
/// found while the screen is off as a background one (no toast / notification unless Settings ->
/// Notifications says so); a fake in tests. Where there is no port (the desktop) the screen is
/// always on.
abstract interface class ScreenPort {
  /// The state now.
  Future<bool> on();

  /// Every change of [on]; the current value comes at once on listen.
  Stream<bool> get changes;
}

/// Android: MethodChannel `jormungand/screen` + EventChannel `jormungand/screen_events`
/// (Kotlin: android_overlay/kotlin/ScreenChannel.kt.tmpl).
class ScreenChannel implements ScreenPort {
  const ScreenChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/screen');
  static const EventChannel _events = EventChannel('jormungand/screen_events');

  @override
  Future<bool> on() async {
    try {
      return await _channel.invokeMethod<bool>('on') ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Stream<bool> get changes => _events.receiveBroadcastStream().where((e) => e is bool).cast<bool>();
}
