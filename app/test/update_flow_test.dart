import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/app_update.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/core/update_flow.dart';
import 'package:jormungand/l10n/l10n.dart';

import 'fake_core_host.dart';
import 'system_notification_test.dart' show FakeNotifyIo;

AppUpdate _upd(UpdPhase phase, [String version = '1.2.0']) => AppUpdate(
  phase: phase,
  current: '1.0.0',
  offer: phase == UpdPhase.idle
      ? null
      : UpdOffer(version: version, channel: 'stable', size: 100, notes: const {}),
  file: phase == UpdPhase.ready ? '/tmp/u.apk' : null,
);

/// The update flow of the shell without the shell: a fake host, a fake notification seam and a
/// switchable "app is behind" flag.
class _Rig {
  _Rig({UpdPhase start = UpdPhase.idle, bool installable = true}) {
    host
      ..update = _upd(start)
      ..installable = installable;
    flow = UpdateFlow(
      host,
      io: io,
      l10n: () => lookupAppLocalizations(const Locale('en')),
      inBackground: () => background,
    )..start();
  }

  final host = FakeCoreHost();
  final io = FakeNotifyIo();
  late final UpdateFlow flow;
  bool background = false;

  int get installs => host.calls.where((c) => c == 'installUpdate').length;

  /// The core moves to [phase] (the host notifies, the flow reacts).
  Future<void> to(UpdPhase phase, [String version = '1.2.0']) async {
    host.update = _upd(phase, version);
    host.changed();
    await pumpEventQueue();
  }
}

void main() {
  group('Download & install: the dialog right after the download', () {
    test('wanted + in front: the file goes to the installer at once, no notification', () async {
      final r = _Rig();
      await r.to(UpdPhase.available);
      r.host.installWanted = true;
      await r.to(UpdPhase.downloading);
      await r.to(UpdPhase.ready);
      expect(r.installs, 1);
      expect(r.host.installWanted, isFalse);
      expect(r.io.updatePosted, isEmpty);
    });

    test('wanted + behind another app: a notification with Install, the dialog when the app is back', () async {
      final r = _Rig();
      await r.to(UpdPhase.available);
      r.host.installWanted = true;
      r.background = true;
      await r.to(UpdPhase.ready);
      expect(r.installs, 0);
      expect(r.io.updatePosted, hasLength(1));
      final n = r.io.updatePosted.single;
      expect(n.install, isTrue);
      expect(n.version, '1.2.0');
      expect(n.title, contains('1.2.0'));
      expect(r.io.announced, '1.2.0');

      r.background = false;
      r.flow.onResumed();
      await pumpEventQueue();
      expect(r.installs, 1);
      // nothing left to install: a second resume does nothing
      r.flow.onResumed();
      await pumpEventQueue();
      expect(r.installs, 1);
    });

    test('an automatic download never opens a dialog: silent in front, a notification behind', () async {
      final fg = _Rig();
      await fg.to(UpdPhase.available);
      await fg.to(UpdPhase.ready);
      expect(fg.installs, 0);
      expect(fg.io.updatePosted, isEmpty);

      final bg = _Rig()..background = true;
      await bg.to(UpdPhase.ready);
      expect(bg.installs, 0);
      expect(bg.io.updatePosted.single.install, isTrue);
    });

    test('a file restored from an earlier run is not news', () async {
      final r = _Rig(start: UpdPhase.ready)..background = true;
      r.host.installWanted = true;
      await r.to(UpdPhase.ready);
      expect(r.installs, 0);
      expect(r.io.updatePosted, isEmpty);
    });

    test('ready -> checking -> ready for the same version does not repeat', () async {
      final r = _Rig();
      r.host.installWanted = true;
      await r.to(UpdPhase.ready);
      expect(r.installs, 1);
      await r.to(UpdPhase.checking);
      await r.to(UpdPhase.ready);
      expect(r.installs, 1);
      // a newer file is news again
      r.host.installWanted = true;
      await r.to(UpdPhase.ready, '1.3.0');
      expect(r.installs, 2);
    });

    test('a declined dialog does not loop; the card keeps the Install button', () async {
      final r = _Rig();
      r.host.installResult = false;
      r.host.installWanted = true;
      await r.to(UpdPhase.ready);
      await r.to(UpdPhase.ready); // the host notifies again, same version
      r.flow.onResumed();
      await pumpEventQueue();
      expect(r.installs, 1);
      expect(r.host.update.phase, UpdPhase.ready);
    });

    test('an installer that cannot work (not installable) is not asked', () async {
      final r = _Rig(installable: false);
      r.host.installWanted = true;
      await r.to(UpdPhase.ready);
      expect(r.installs, 0);
    });

    test('the notification has no Install action where the file cannot be installed', () async {
      final r = _Rig(installable: false)..background = true;
      await r.to(UpdPhase.ready);
      expect(r.io.updatePosted.single.install, isFalse);
    });

    test('a tap on the notification installs only a still-ready file', () async {
      final r = _Rig();
      await r.flow.openedFromShade(install: true);
      expect(r.installs, 0); // nothing ready
      await r.to(UpdPhase.ready);
      await r.flow.openedFromShade(install: false);
      expect(r.installs, 0); // the "available" body: only the card opens
      await r.flow.openedFromShade(install: true);
      expect(r.installs, 1);
    });
  });

  group('A newer version while the app is behind', () {
    test('posted once per version, the native record keeps it across runs', () async {
      final r = _Rig()..background = true;
      await r.to(UpdPhase.available);
      expect(r.io.updatePosted, hasLength(1));
      final n = r.io.updatePosted.single;
      expect(n.install, isFalse);
      expect(n.version, '1.2.0');
      expect(r.io.announced, '1.2.0');

      // the same version again (a re-check): nothing
      await r.to(UpdPhase.checking);
      await r.to(UpdPhase.available);
      expect(r.io.updatePosted, hasLength(1));

      // a new run of the process that already announced it (the worker did): silent
      final other = _Rig()..background = true;
      other.io.announced = '1.4.0';
      await other.to(UpdPhase.available, '1.4.0');
      expect(other.io.updatePosted, isEmpty);

      // the next version is news again
      await r.to(UpdPhase.available, '1.3.0');
      expect(r.io.updatePosted, hasLength(2));
    });

    test('in front it is silent: the card is the news', () async {
      final r = _Rig();
      await r.to(UpdPhase.available);
      expect(r.io.updatePosted, isEmpty);
      expect(r.io.announced, isNull);
    });

    test('Settings -> Notifications: the New version row and the master switch are obeyed', () async {
      final off = _Rig()..background = true;
      off.host.notif.setFlag('updateAvailable', false);
      await off.to(UpdPhase.available);
      await off.to(UpdPhase.ready, '1.3.0');
      expect(off.io.updatePosted, isEmpty);

      final master = _Rig()..background = true;
      master.host.notif.setFlag('enabled', false);
      await master.to(UpdPhase.available);
      expect(master.io.updatePosted, isEmpty);
    });

    test('the flag is on by default and is a known key', () {
      expect(NotifCfg.defaults['updateAvailable'], isTrue);
      expect(NotifCfg.allKeys, contains('updateAvailable'));
    });

    test('after dispose the flow is quiet', () async {
      final r = _Rig()..background = true;
      r.flow.dispose();
      await r.to(UpdPhase.available);
      expect(r.io.updatePosted, isEmpty);
    });
  });
}
