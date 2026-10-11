import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/update_job.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'system_notification_test.dart' show FakeNotifyIo;

UpdateOffer _offer([String version = '1.2.0']) => UpdateOffer(
  manifest: UpdateManifest(
    channel: UpdateChannel.stable,
    version: AppVersion.tryParse(version, build: 12)!,
    assets: const {},
  ),
  asset: const UpdateAsset(platform: 'android-arm64-v8a', file: 'jorm.apk', size: 100, sha256: 'ab'),
  forced: false,
  feed: 'https://feed.example',
  route: UpdateRoute.direct,
);

final _current = AppVersion.tryParse('1.0.0', build: 10)!;

UpdateStatus _st(UpdatePhase p, {UpdateOffer? offer, String? file, UpdateException? lastError}) =>
    UpdateStatus(p, current: _current, offer: offer, file: file, lastError: lastError);

/// The updater of the job with scripted answers.
class _Updater implements JobUpdater {
  _Updater(this.checkAnswer, {UpdateStatus? downloadAnswer}) : _download = downloadAnswer;

  final UpdateStatus checkAnswer;
  final UpdateStatus? _download;
  final calls = <String>[];
  Completer<UpdateStatus>? hangCheck;

  @override
  Future<void> restore() async => calls.add('restore');

  @override
  Future<UpdateStatus> check(UpdateChannel channel) {
    calls.add('check:${channel.name}');
    return hangCheck?.future ?? Future.value(checkAnswer);
  }

  @override
  Future<UpdateStatus> download() async {
    calls.add('download');
    return _download ?? _st(UpdatePhase.failed, offer: checkAnswer.offer);
  }

  @override
  void cancel() => calls.add('cancel');
}

UpdateJobInput _input({
  bool autoCheck = true,
  UpdateAutoDownload auto = UpdateAutoDownload.off,
  bool metered = false,
  bool notify = true,
  bool alive = false,
  String? lang = 'en',
}) => UpdateJobInput(
  autoCheck: autoCheck,
  channel: UpdateChannel.beta,
  autoDownload: auto,
  notify: notify,
  metered: metered,
  versionName: '1.0.0',
  versionCode: 10,
  lang: lang,
  alive: alive,
);

Future<UpdateJobResult> _run(
  _Updater u,
  FakeNotifyIo io, {
  UpdateJobInput? input,
  Duration limit = const Duration(minutes: 8),
}) => runUpdateJob(input: input ?? _input(), updater: u, io: io, limit: limit);

void main() {
  group('the background update check (no app process)', () {
    test('skipped without touching the updater: auto-check off, the app running', () async {
      final io = FakeNotifyIo();
      final off = _Updater(_st(UpdatePhase.available, offer: _offer()));
      expect((await _run(off, io, input: _input(autoCheck: false))).outcome, UpdateJobOutcome.skipped);
      final alive = _Updater(_st(UpdatePhase.available, offer: _offer()));
      expect((await _run(alive, io, input: _input(alive: true))).outcome, UpdateJobOutcome.skipped);
      expect(off.calls, isEmpty);
      expect(alive.calls, isEmpty);
      expect(io.updatePosted, isEmpty);
    });

    test('a new version: «available» once per version, the record is shared with the live flow', () async {
      final io = FakeNotifyIo();
      final u = _Updater(_st(UpdatePhase.available, offer: _offer()));

      final r = await _run(u, io);
      expect(r.outcome, UpdateJobOutcome.available);
      expect(u.calls, ['restore', 'check:beta']); // the user's channel; auto-download is off: no download
      expect(io.updatePosted, hasLength(1));
      final n = io.updatePosted.single;
      expect(n.title, contains('1.2.0'));
      expect(n.version, '1.2.0');
      expect(n.install, isFalse);
      expect(n.file, isNull);
      expect(io.announced, '1.2.0');

      // the next day: the same version is not announced again
      await _run(_Updater(_st(UpdatePhase.available, offer: _offer())), io);
      expect(io.updatePosted, hasLength(1));

      // a newer one is
      await _run(_Updater(_st(UpdatePhase.available, offer: _offer('1.3.0'))), io);
      expect(io.updatePosted, hasLength(2));
      expect(io.announced, '1.3.0');

      // already told by the live process (it wrote the same record): nothing
      io.announced = '1.4.0';
      await _run(_Updater(_st(UpdatePhase.available, offer: _offer('1.4.0'))), io);
      expect(io.updatePosted, hasLength(2));
    });

    test('«New version» off (or the master switch): nothing is posted, nothing is recorded', () async {
      final io = FakeNotifyIo();
      final u = _Updater(_st(UpdatePhase.available, offer: _offer()));
      final r = await _run(u, io, input: _input(notify: false));
      expect(r.outcome, UpdateJobOutcome.available);
      expect(io.updatePosted, isEmpty);
      expect(io.announced, isNull);
    });

    test('auto-download Wi-Fi: only on an unmetered network; then «ready · Install» with the file', () async {
      final io = FakeNotifyIo();
      final metered = _Updater(_st(UpdatePhase.available, offer: _offer()));
      await _run(metered, io, input: _input(auto: UpdateAutoDownload.wifi, metered: true));
      expect(metered.calls, isNot(contains('download')));
      expect(io.updatePosted.single.install, isFalse); // announced, not downloaded

      final io2 = FakeNotifyIo();
      final wifi = _Updater(
        _st(UpdatePhase.available, offer: _offer()),
        downloadAnswer: _st(UpdatePhase.ready, offer: _offer(), file: '/data/updates/jorm.apk'),
      );
      final r = await _run(wifi, io2, input: _input(auto: UpdateAutoDownload.wifi));
      expect(r.outcome, UpdateJobOutcome.downloaded);
      expect(wifi.calls, ['restore', 'check:beta', 'download']);
      final n = io2.updatePosted.single; // one notification, «ready», no «available» before it
      expect(n.install, isTrue);
      expect(n.file, '/data/updates/jorm.apk');
      expect(n.title, contains('1.2.0'));
      expect(n.installLabel, isNotEmpty);
      expect(io2.announced, '1.2.0');
    });

    test('«ready» follows an «available» of the same version; always ignores the metered network', () async {
      final io = FakeNotifyIo()..announced = '1.2.0';
      final u = _Updater(
        _st(UpdatePhase.available, offer: _offer()),
        downloadAnswer: _st(UpdatePhase.ready, offer: _offer(), file: '/f.apk'),
      );
      await _run(u, io, input: _input(auto: UpdateAutoDownload.always, metered: true));
      expect(io.updatePosted.single.install, isTrue);
    });

    test('a download without notifications is silent but still done', () async {
      final io = FakeNotifyIo();
      final u = _Updater(
        _st(UpdatePhase.available, offer: _offer()),
        downloadAnswer: _st(UpdatePhase.ready, offer: _offer(), file: '/f.apk'),
      );
      final r = await _run(u, io, input: _input(auto: UpdateAutoDownload.always, notify: false));
      expect(r.outcome, UpdateJobOutcome.downloaded);
      expect(io.updatePosted, isEmpty);
    });

    test('a download that fails leaves the plain «available»', () async {
      final io = FakeNotifyIo();
      final u = _Updater(_st(UpdatePhase.available, offer: _offer())); // download answers failed
      final r = await _run(u, io, input: _input(auto: UpdateAutoDownload.always));
      expect(r.outcome, UpdateJobOutcome.available);
      expect(u.calls, contains('download'));
      expect(io.updatePosted.single.install, isFalse);
      expect(io.announced, '1.2.0');
    });

    test('nothing to tell: up to date, a file that was downloaded before, a failed check', () async {
      final io = FakeNotifyIo();
      expect((await _run(_Updater(_st(UpdatePhase.upToDate)), io)).outcome, UpdateJobOutcome.upToDate);
      expect(
        (await _run(_Updater(_st(UpdatePhase.ready, offer: _offer(), file: '/f.apk')), io)).outcome,
        UpdateJobOutcome.alreadyReady,
      );
      final bad = _Updater(
        _st(UpdatePhase.idle, lastError: UpdateException(UpdateError.network, 'No update feed answered')),
      );
      final r = await _run(bad, io);
      expect(r.outcome, UpdateJobOutcome.failed);
      expect(r.detail, contains('No update feed'));
      expect(io.updatePosted, isEmpty);
    });

    test('an updater that throws, or hangs past the limit, ends the run quietly', () async {
      final io = FakeNotifyIo();
      final hang = _Updater(_st(UpdatePhase.upToDate))..hangCheck = Completer();
      final r = await _run(hang, io, limit: const Duration(milliseconds: 30));
      expect(r.outcome, UpdateJobOutcome.failed);
      expect(hang.calls, contains('cancel'));
      expect(io.updatePosted, isEmpty);
    });

    test('the lines of a run go to the log', () async {
      final io = FakeNotifyIo();
      final lines = <String>[];
      await runUpdateJob(
        input: _input(),
        updater: _Updater(_st(UpdatePhase.available, offer: _offer())),
        io: io,
        log: lines.add,
      );
      expect(lines.join('\n'), contains('1.2.0 is available'));
    });
  });

  group('UpdateJobInput', () {
    test('reads what the native side hands over; unknown values fall back safely', () {
      final i = UpdateJobInput.fromMap({
        'autoCheck': true,
        'channel': 'beta',
        'autoDownload': 'always',
        'notify': false,
        'lang': 'ru',
        'systemLang': 'de',
        'metered': false,
        'versionName': '0.1.0',
        'versionCode': 7,
        'abis': ['arm64-v8a'],
        'installedPackage': '/data/app/base.apk',
        'alive': false,
      });
      expect(i.channel, UpdateChannel.beta);
      expect(i.autoDownload, UpdateAutoDownload.always);
      expect(i.notify, isFalse);
      expect(i.versionCode, 7);
      expect(i.abis, ['arm64-v8a']);
      expect(i.l10n().localeName, 'ru');

      final d = UpdateJobInput.fromMap({'lang': '', 'systemLang': 'de'});
      expect(d.autoDownload, UpdateAutoDownload.wifi); // the default
      expect(d.metered, isTrue); // unknown: do not spend the traffic
      expect(d.l10n().localeName, 'en'); // neither chosen nor supported system language
      expect(UpdateJobInput.fromMap({'lang': '', 'systemLang': 'ru'}).l10n().localeName, 'ru');
    });
  });
}
