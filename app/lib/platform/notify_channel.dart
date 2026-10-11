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
  const SystemNote({
    required this.id,
    required this.title,
    this.text = '',
    this.actions = const [],
    this.site = '',
    this.via = '',
    this.ignoredText = '',
    this.undoLabel = '',
  });

  final int id;
  final String title;
  final String text;

  /// Buttons of the notification: `(id, label)`; a press brings [NoteActionTap] back (`ignore` does
  /// not: it is done on the native side, see [NotifyIo.takeIgnoreOps]).
  final List<(String, String)> actions;

  /// The site / the entry it opens through, carried by the buttons (the event itself may be gone
  /// from the journal when one is pressed).
  final String site, via;

  /// The words of the notification that replaces this one when `ignore` is pressed («{host} added to
  /// ignored sites», «Undo»), in the app's language: the native side has nothing to translate with.
  final String ignoredText, undoLabel;
}

/// A notification about the app's own update (not a journal event: its own slot on the shade, its own
/// tap). [install] = the update is downloaded: the [installLabel] button leads straight to the system
/// install dialog; otherwise the tap opens the update block (Settings -> Data).
class UpdateNote {
  const UpdateNote({
    required this.title,
    this.text = '',
    required this.version,
    this.install = false,
    this.installLabel = '',
    this.file,
  });

  final String title;
  final String text;

  /// The offered version: what the native "announced" record keeps (one «available» per version).
  final String version;
  final bool install;
  final String installLabel;

  /// The downloaded, verified APK of an [install] note. With it the button hands the file to the system
  /// installer by itself (no app window, the native side re-checks the file against `ready.json` next to
  /// it); a file that is gone or does not match opens the app at the update block instead. Without it
  /// the button opens the app and the app starts the installer.
  final String? file;
}

/// A choice made on the shade without the app: «Ignore site» ([ignore]) or its «Undo». They are applied
/// to the ignored sites list in the order they were made.
class SiteIgnoreOp {
  const SiteIgnoreOp({required this.ignore, required this.site});

  final bool ignore;
  final String site;

  static SiteIgnoreOp? fromMap(Object? m) {
    if (m is! Map) return null;
    final op = m['op'], site = '${m['site'] ?? ''}';
    if (site.isEmpty || (op != 'ignore' && op != 'unignore')) return null;
    return SiteIgnoreOp(ignore: op == 'ignore', site: site);
  }
}

/// A press on a button of an event notification (`rule` | `ignore`): the app comes to the front and
/// this arrives, through [NotifyIo.actionTaps] or [NotifyIo.takeLaunchAction].
class NoteActionTap {
  const NoteActionTap({
    required this.id,
    required this.action,
    this.site = '',
    this.via = '',
  });

  final int id;
  final String action, site, via;

  static NoteActionTap? fromMap(Object? m) => m is Map && m['id'] is int
      ? NoteActionTap(
          id: m['id'] as int,
          action: '${m['act'] ?? ''}',
          site: '${m['site'] ?? ''}',
          via: '${m['via'] ?? ''}',
        )
      : null;
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

  /// Whether the VPN notification is on the shade at all (Settings -> Notifications: master and
  /// Status). The native side keeps it, so the service obeys it with no Dart running; hidden, the
  /// VPN still runs (the system's key icon stays).
  Future<void> setVpnVisible(bool visible);

  /// Taps on event notifications (the event ids) while the app runs.
  Stream<int> get eventTaps;

  /// The event of the notification that started the app and was not handed over yet.
  Future<int?> takeLaunchEvent();

  /// Presses on the buttons of event notifications (Create rule / Ignore site) while the app runs.
  Stream<NoteActionTap> get actionTaps;

  /// The button that started the app and was not handed over yet.
  Future<NoteActionTap?> takeLaunchAction();

  /// The native side queued an «Ignore site» / «Undo» made on the shade: read it with [takeIgnoreOps].
  Stream<void> get ignoreQueued;

  /// The queued choices, oldest first; the queue is emptied. The native side keeps them until asked, so
  /// nothing is lost when no Dart ran at the time.
  Future<List<SiteIgnoreOp>> takeIgnoreOps();

  /// The Disconnect button of the VPN notification. The handler answers when it has taken the
  /// request; none set = the native side closes the tunnel itself.
  set onDisconnect(FutureOr<void> Function()? handler);

  /// «Update available» / «Update ready · Install» (one slot: a newer one replaces the older, silently).
  Future<void> postUpdate(UpdateNote note);

  /// The version the user was last told about by a notification (this app or the background job, which
  /// keep the same native record); null = none yet.
  Future<String?> updateAnnounced();
  Future<void> setUpdateAnnounced(String version);

  /// Taps on the update notification while the app runs: `true` = lead to the install dialog.
  Stream<bool> get updateTaps;

  /// The update notification that started the app and was not handed over yet (`true` = install);
  /// null = the app was not started by one.
  Future<bool?> takeLaunchUpdate();
}

class PlatformNotifyIo implements NotifyIo {
  PlatformNotifyIo() {
    if (available) _channel.setMethodCallHandler(_fromNative);
  }

  static const MethodChannel _channel = MethodChannel('jormungand/notify');

  final _permission = ValueNotifier(NotifyPermission.unsupported);
  final _taps = StreamController<int>.broadcast();
  final _actTaps = StreamController<NoteActionTap>.broadcast();
  final _ignoreQueued = StreamController<void>.broadcast();
  final _updateTaps = StreamController<bool>.broadcast();
  FutureOr<void> Function()? _disconnect;

  @override
  bool get available => !kIsWeb && Platform.isAndroid;

  @override
  ValueListenable<NotifyPermission> get permission => _permission;

  @override
  set onDisconnect(FutureOr<void> Function()? handler) => _disconnect = handler;

  @override
  Stream<int> get eventTaps => _taps.stream;

  @override
  Stream<NoteActionTap> get actionTaps => _actTaps.stream;

  @override
  Stream<void> get ignoreQueued => _ignoreQueued.stream;

  Future<Object?> _fromNative(MethodCall call) async {
    switch (call.method) {
      case 'ignoreQueued':
        _ignoreQueued.add(null);
        return null;
      case 'openEvent':
        final id = call.arguments;
        if (id is int) _taps.add(id);
        return null;
      case 'eventAct':
        final t = NoteActionTap.fromMap(call.arguments);
        if (t != null) _actTaps.add(t);
        return null;
      case 'openUpdate':
        _updateTaps.add(call.arguments == true);
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
    if (note.actions.isNotEmpty) ...{
      'actions': [
        for (final (id, label) in note.actions) {'id': id, 'label': label},
      ],
      'site': note.site,
      'via': note.via,
      if (note.ignoredText.isNotEmpty) 'ignoredText': note.ignoredText,
      if (note.undoLabel.isNotEmpty) 'undoLabel': note.undoLabel,
    },
  });

  @override
  Future<void> cancelEvents() => _call('cancelEvents');

  @override
  Future<void> postUpdate(UpdateNote note) => _call('postUpdate', <String, Object?>{
    'title': note.title,
    'text': note.text,
    'version': note.version,
    'install': note.install,
    'installLabel': note.installLabel,
    if (note.file != null && note.file!.isNotEmpty) 'file': note.file,
  });

  @override
  Future<String?> updateAnnounced() async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<String>('updateAnnounced');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> setUpdateAnnounced(String version) =>
      _call('setUpdateAnnounced', <String, Object?>{'version': version});

  @override
  Stream<bool> get updateTaps => _updateTaps.stream;

  @override
  Future<bool?> takeLaunchUpdate() async {
    if (!available) return null;
    try {
      return await _channel.invokeMethod<bool>('takeLaunchUpdate');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> setVpnNode(String? node) =>
      _call('setStatus', <String, Object?>{'node': node});

  @override
  Future<void> setVpnVisible(bool visible) =>
      _call('setStatus', <String, Object?>{'visible': visible});

  @override
  Future<NoteActionTap?> takeLaunchAction() async {
    if (!available) return null;
    try {
      return NoteActionTap.fromMap(await _channel.invokeMethod<Object>('takeLaunchAction'));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<SiteIgnoreOp>> takeIgnoreOps() async {
    if (!available) return const [];
    try {
      final r = await _channel.invokeMethod<List<Object?>>('takeIgnoreOps');
      return [
        for (final m in r ?? const <Object?>[]) ?SiteIgnoreOp.fromMap(m),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

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
