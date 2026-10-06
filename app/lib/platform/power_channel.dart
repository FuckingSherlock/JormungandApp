import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether Android lets the app work in the background without battery limits (the app is on
/// the "unrestricted" / "not optimized" list). Without it Doze and the OEM task killers stop the
/// tunnel's helpers (Auto, pings, the core's timers) and may kill the process.
enum BackgroundAccess {
  allowed,
  denied,

  /// Nothing to ask on this platform (the desktop).
  unsupported,
}

/// The seam to Android's battery-optimization exemption: the channel `jormungand/power`
/// (android_overlay/kotlin/PowerChannel.kt.tmpl), a fake in tests (put it into [current]).
/// Where it is not [available] the app never asks and [access] stays [BackgroundAccess.unsupported].
abstract class PowerIo {
  static PowerIo current = PlatformPowerIo();

  bool get available;

  /// Last known state; [refresh] / [request] update it (the Settings row listens).
  ValueListenable<BackgroundAccess> get access;

  /// Reads the state without asking.
  Future<BackgroundAccess> refresh();

  /// Shows the system dialog "Allow the app to always run in the background?"; answers the state
  /// after it. With [once] at most one dialog per install (the native side counts, and only a
  /// dialog that really opened counts): the first successful connect asks, nothing nags later.
  Future<BackgroundAccess> request({bool once = false});
}

class PlatformPowerIo implements PowerIo {
  static const MethodChannel _channel = MethodChannel('jormungand/power');

  final _access = ValueNotifier(BackgroundAccess.unsupported);

  @override
  bool get available => !kIsWeb && Platform.isAndroid;

  @override
  ValueListenable<BackgroundAccess> get access => _access;

  Future<BackgroundAccess> _ask(String method, [Object? args]) async {
    if (!available) return BackgroundAccess.unsupported;
    try {
      final ok = await _channel.invokeMethod<bool>(method, args);
      return _access.value = ok == true
          ? BackgroundAccess.allowed
          : BackgroundAccess.denied;
    } on MissingPluginException {
      return _access.value = BackgroundAccess.unsupported;
    } on PlatformException {
      return _access.value = BackgroundAccess.denied;
    }
  }

  @override
  Future<BackgroundAccess> refresh() => _ask('status');

  @override
  Future<BackgroundAccess> request({bool once = false}) =>
      _ask('request', <String, Object?>{'once': once});
}
