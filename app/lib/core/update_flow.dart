import 'dart:async';

import '../l10n/l10n.dart';
import '../platform/notify_channel.dart';
import 'app_update.dart';
import 'core_host.dart';
import 'settings_model.dart';

/// What happens with the app's own update after the core has found or downloaded it, around the
/// Settings -> Data card (docs/updates.md, section 6 "Установка сразу после загрузки"). Owned by the
/// shell, like [SystemNotifier].
///
///  - «Download & install» (the user's own press, [CoreHost.updateInstallWanted]): the moment the file is
///    ready and the app is in front, the file goes to the installer - the system dialog is up at once.
///    The card's Install button stays for a dialog that was declined or an installer that failed.
///    If the app went behind meanwhile nothing pops over another app: an «Update ready · Install»
///    notification is posted and the install starts when the app comes back (the tap on it does too).
///  - An automatic download never opens a dialog by itself (nobody asked to install now, and the
///    replacement ends the VPN): behind the app it posts the same notification, in front it leaves
///    the card alone.
///  - A newer version found while the app is behind (the daily tick of a process the VPN keeps alive)
///    posts «Update {version} available», once per version ([NotifyIo.updateAnnounced], the record the
///    background job shares); in front it shows nothing, the card is the news.
/// Both notifications obey Settings -> Notifications ([NotifCfg] `updateAvailable` and the master switch).
class UpdateFlow {
  UpdateFlow(
    this.host, {
    required NotifyIo io,
    required this.l10n,
    required this.inBackground,
  }) : _io = io;

  final CoreHost host;
  final NotifyIo _io;

  /// The app's language, read when a notification is built.
  final AppLocalizations Function() l10n;

  /// The app is not in front (a notification instead of a dialog).
  final bool Function() inBackground;

  bool _started = false;
  bool _disposed = false;

  // the version whose «available» / «ready» was already dealt with in this run
  String? _availableFor, _readyFor;
  bool _installing = false;
  DateTime? _lastInstall;

  /// The app comes to the front through the notification's tap: the resume already sent a wanted
  /// install to the installer a moment before the tap arrives; it is not asked a second time.
  static const _tapAfterResume = Duration(seconds: 5);

  void start() {
    if (_started) return;
    _started = true;
    final u = host.appUpdate;
    // what is there at the start is not news (a ready file restored from an earlier run)
    if (u.phase == UpdPhase.available) _availableFor = u.offer?.version;
    if (u.phase == UpdPhase.ready) _readyFor = u.offer?.version;
    host.addListener(_onHost);
  }

  void dispose() {
    _disposed = true;
    if (_started) host.removeListener(_onHost);
  }

  bool get _notifies {
    final n = host.notif;
    return _io.available && n.enabled && n.flag('updateAvailable');
  }

  void _onHost() {
    if (_disposed) return;
    final u = host.appUpdate;
    final v = u.offer?.version;
    if (v == null) return;
    if (u.phase == UpdPhase.ready && v != _readyFor) {
      _readyFor = v;
      unawaited(_ready(u));
    } else if (u.phase == UpdPhase.available && v != _availableFor) {
      _availableFor = v;
      if (inBackground()) unawaited(_announceAvailable(v));
    }
  }

  Future<void> _ready(AppUpdate u) async {
    if (host.updateInstallWanted && !inBackground()) {
      await _install();
      return;
    }
    // behind the app: no dialog over another app, only the notification (the install, if wanted,
    // follows when the app is back)
    if (inBackground()) await _postReady(u);
  }

  Future<void> _install() async {
    if (_installing || !host.canInstallUpdate) return;
    _installing = true;
    _lastInstall = DateTime.now();
    try {
      host.takeUpdateInstallWanted();
      await host.installUpdate();
    } catch (_) {
      // the card shows the Install button again; the core journalled the refusal
    } finally {
      _installing = false;
    }
  }

  Future<void> _postReady(AppUpdate u) async {
    if (!_notifies) return;
    final v = u.offer!.version;
    final t = l10n();
    await _io.postUpdate(
      UpdateNote(
        title: t.updateReady(v),
        text: t.tapToInstall,
        version: v,
        install: host.canInstallUpdate,
        installLabel: t.install,
      ),
    );
    await _io.setUpdateAnnounced(v);
  }

  Future<void> _announceAvailable(String v) async {
    if (!_notifies) return;
    if (await _io.updateAnnounced() == v) return;
    final t = l10n();
    await _io.postUpdate(
      UpdateNote(title: t.updateAvailable(v), text: t.tapToSeeWhatSNew, version: v),
    );
    await _io.setUpdateAnnounced(v);
  }

  /// The app came to the front: a «Download & install» that finished behind it goes to the installer now.
  void onResumed() {
    if (_disposed) return;
    final u = host.appUpdate;
    if (u.phase == UpdPhase.ready && host.updateInstallWanted) unawaited(_install());
  }

  /// A tap on the update notification ([NotifyIo.updateTaps] / [NotifyIo.takeLaunchUpdate]): the install
  /// dialog when the notification said «Install» and the file is still ready. The shell opens the card.
  Future<void> openedFromShade({required bool install}) async {
    if (_disposed || !install) return;
    final last = _lastInstall;
    if (last != null && DateTime.now().difference(last) < _tapAfterResume) return;
    if (host.appUpdate.phase == UpdPhase.ready) await _install();
  }
}
