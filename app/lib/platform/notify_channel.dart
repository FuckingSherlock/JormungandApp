import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app may show system notifications (Android 13 permission + the system switch).
enum NotifyPermission {
  granted,
  denied,

  /// No system notifications on this platform (the desktop keeps toasts).
  unsupported,
}

/// A journal event for the shade: [id] is the event's id (a tap brings it back through
/// [NotifyIo.eventTaps]).
class SystemNote {
  const SystemNote({required this.id, required this.title, this.text = ''});

  final int id;
  final String title;
  final String text;
}

/// The seam to the system's notifications: the Android channel `jormungand/notify`
/// (android_overlay/kotlin/NotifyChannel.kt.tmpl, AppNotifier.kt.tmpl) in the app, a fake in
/// tests (put it into [current]). Where it is not [available] every call does nothing and the
/// in-app toasts are all there is.
abstract class NotifyIo {
  static NotifyIo current = PlatformNotifyIo();

  /// This platform has system notifications.
  bool get available;

  /// Last known permission; [refresh] / [request] update it (a settings page listens).
  ValueListenable<NotifyPermission> get permission;

  /// Reads the permission without asking.
  Future<NotifyPermission> refresh();

  /// Shows the system permission dialog (Android 13+). With [once] at most one dialog per
  /// install: a later call only reads the state, so nothing nags on every start. Answers the state
  /// after the dialog.
  Future<NotifyPermission> request({bool once = false});

  /// The app's notification page of the system settings.
  Future<void> openSettings();

  /// One event as a system notification (grouped by the system side).
  Future<void> post(SystemNote note);

  /// Removes the event notifications (the app is in front again).
  Future<void> cancelEvents();

  /// The entry / server shown in the VPN notification; null = the plain text.
  Future<void> setVpnNode(String? node);

  /// Taps on event notifications (the event ids) while the app runs.
  Stream<int> get eventTaps;

  /// The event of the notification that started the app and was not handed over yet.
  Future<int?> takeLaunchEvent();

  /// The Disconnect button of the VPN notification. The handler answers when it has taken the
  /// request; none set = the native side closes the tunnel itself.
  set onDisconnect(FutureOr<void> Function()? handler);
}

class PlatformNotifyIo implements NotifyIo {
  PlatformNotifyIo() {
    if (available) _channel.setMethodCallHandler(_fromNative);
  }

  static const MethodChannel _channel = MethodChannel('jormungand/notify');

  final _permission = ValueNotifier(NotifyPermission.unsupported);
  final _taps = StreamController<int>.broadcast();
  FutureOr<void> Function()? _disconnect;

  @override
  bool get available => !kIsWeb && Platform.isAndroid;

  @override
  ValueListenable<NotifyPermission> get permission => _permission;

  @override
  set onDisconnect(FutureOr<void> Function()? handler) => _disconnect = handler;

  @override
  Stream<int> get eventTaps => _taps.stream;

  Future<Object?> _fromNative(MethodCall call) async {
    switch (call.method) {
      case 'openEvent':
        final id = call.arguments;
        if (id is int) _taps.add(id);
        return null;
      case 'disconnect':
        final h = _disconnect;
        if (h == null) throw MissingPluginException('no disconnect handler');
        await h();
        return true;
    }
    throw MissingPluginException(call.method);
  }

  NotifyPermission _parse(String? s) => switch (s) {
    'granted' => NotifyPermission.granted,
    'denied' => NotifyPermission.denied,
    _ => NotifyPermission.unsupported,
  };

  Future<NotifyPermission> _ask(String method, [Object? args]) async {
    if (!available) return NotifyPermission.unsupported;
    try {
      final s = await _channel.invokeMethod<String>(method, args);
      return _permission.value = _parse(s);
    } on MissingPluginException {
      return _permission.value = NotifyPermission.unsupported;
    } on PlatformException {
      return _permission.value;
    }
  }

  @override
  Future<NotifyPermission> refresh() => _ask('permission');

  @override
  Future<NotifyPermission> request({bool once = false}) =>
      _ask('request', <String, Object?>{'once': once});

  Future<void> _call(String method, [Object? args]) async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // no native side
    } on PlatformException {
      // a notification that did not show is not worth more than that
    }
  }

  @override
  Future<void> openSettings() => _call('openSettings');

  @override
  Future<void> post(SystemNote note) => _call('post', <String, Object?>{
    'id': note.id,
    'title': note.title,
    'text': note.text,
  });

  @override
  Future<void> cancelEvents() => _call('cancelEvents');

  @override
  Future<void> setVpnNode(String? node) =>
      _call('setStatus', <String, Object?>{'node': node});

  @override
  Future<int?> takeLaunchEvent() async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<int>('takeLaunchEvent');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
