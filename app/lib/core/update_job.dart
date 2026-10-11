import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant, Locale;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:jormungand_core/jormungand_core.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import '../platform/notify_channel.dart';
import '../platform/update_job_channel.dart';

/// The background update check of Android while the app's process is NOT running (docs/updates.md,
/// section 6 "Фоновая проверка при закрытом процессе"). A WorkManager job (UpdateJob.kt) starts a
/// FlutterEngine with [updateJobMain] as the entry point; this file is that isolate. It does what the
/// core's own daily schedule does for a live process - the same [AppUpdater] (manifest, signature,
/// feeds, delta), in the same `<dataDir>/updates` folder, so a file this job downloads is picked up by
/// the app later through `restore()` - and then tells the user the way the live [UpdateFlow] does:
/// «Update X available» once per version (the shared native "announced" record), or, when the download
/// was allowed and the network fits, «Update X ready · Install» (never an install dialog).
///
/// The job never starts the core service and never touches the VPN: only the updater, the notification
/// seam and one native channel (`jormungand/updatejob`) live in this isolate. It has no tunnel, so the
/// feeds are tried direct only.

/// What the native side hands the job: the settings the app mirrored plus the facts read at run time.
class UpdateJobInput {
  const UpdateJobInput({
    required this.autoCheck,
    required this.channel,
    required this.autoDownload,
    required this.notify,
    required this.metered,
    required this.versionName,
    required this.versionCode,
    this.lang,
    this.systemLang = 'en',
    this.abis = const [],
    this.installedPackage,
    this.alive = false,
  });

  final bool autoCheck;
  final UpdateChannel channel;
  final UpdateAutoDownload autoDownload;

  /// The update notifications are allowed (Settings -> Notifications).
  final bool notify;

  /// The network the phone really uses is metered (read natively when the job starts).
  final bool metered;
  final String versionName;
  final int versionCode;

  /// The app's language, null = never chosen; [systemLang] decides then.
  final String? lang;
  final String systemLang;
  final List<String> abis;
  final String? installedPackage;

  /// The app's process came alive while the job was starting (a window opened): its own schedule
  /// covers the check and its updater owns the updates folder.
  final bool alive;

  static UpdateJobInput fromMap(Map<String, Object?> m) {
    String? str(String k) => m[k] is String && (m[k] as String).isNotEmpty ? m[k] as String : null;
    return UpdateJobInput(
      autoCheck: m['autoCheck'] != false,
      channel: UpdateChannel.of(str('channel')),
      autoDownload: switch (str('autoDownload')) {
        'off' => UpdateAutoDownload.off,
        'always' => UpdateAutoDownload.always,
        _ => UpdateAutoDownload.wifi,
      },
      notify: m['notify'] != false,
      metered: m['metered'] != false, // unknown: do not spend the user's traffic
      versionName: str('versionName') ?? '',
      versionCode: m['versionCode'] is num ? (m['versionCode'] as num).toInt() : 0,
      lang: str('lang'),
      systemLang: str('systemLang') ?? 'en',
      abis: [for (final a in (m['abis'] as List? ?? const [])) '$a'],
      installedPackage: str('installedPackage'),
      alive: m['alive'] == true,
    );
  }

  /// The app's language for the notification: the chosen one, else the system's, else English.
  AppLocalizations l10n() {
    final have = {for (final l in AppLocalizations.supportedLocales) l.languageCode};
    final code = have.contains(lang)
        ? lang!
        : have.contains(systemLang)
        ? systemLang
        : 'en';
    return lookupAppLocalizations(Locale(code));
  }
}

/// The part of [AppUpdater] the job uses (a fake in tests).
abstract interface class JobUpdater {
  /// Picks up a file downloaded earlier and the time of the last check.
  Future<void> restore();
  Future<UpdateStatus> check(UpdateChannel channel);
  Future<UpdateStatus> download();
  void cancel();
}

class CoreJobUpdater implements JobUpdater {
  CoreJobUpdater(this.updater);
  final AppUpdater updater;

  @override
  Future<void> restore() async {
    await updater.restore();
  }

  @override
  Future<UpdateStatus> check(UpdateChannel channel) => updater.check(channel: channel);

  @override
  Future<UpdateStatus> download() => updater.download();

  @override
  void cancel() => updater.cancelDownload();
}

enum UpdateJobOutcome {
  /// Not run: auto-check is off or the app is alive.
  skipped,
  upToDate,

  /// The check failed (silent: the next run tries again).
  failed,

  /// A new version found, announced («available») or already announced.
  available,

  /// A new version downloaded now: «ready · Install».
  downloaded,

  /// The offer is a file that was downloaded before: nothing new to tell.
  alreadyReady,
}

class UpdateJobResult {
  const UpdateJobResult(this.outcome, [this.detail = '']);
  final UpdateJobOutcome outcome;
  final String detail;

  @override
  String toString() => detail.isEmpty ? outcome.name : '${outcome.name}: $detail';
}

/// One run of the job. Bounded by [limit] (WorkManager stops a job at about ten minutes); never throws.
Future<UpdateJobResult> runUpdateJob({
  required UpdateJobInput input,
  required JobUpdater updater,
  required NotifyIo io,
  void Function(String line)? log,
  Duration limit = const Duration(minutes: 8),
}) async {
  void say(String s) {
    try {
      log?.call(s);
    } catch (_) {}
  }

  if (input.alive) return const UpdateJobResult(UpdateJobOutcome.skipped, 'the app is running');
  if (!input.autoCheck) return const UpdateJobResult(UpdateJobOutcome.skipped, 'auto-check is off');
  try {
    return await _run(input, updater, io, say).timeout(
      limit,
      onTimeout: () {
        updater.cancel();
        say('time limit of ${limit.inSeconds} s reached');
        return UpdateJobResult(UpdateJobOutcome.failed, 'time limit');
      },
    );
  } catch (e) {
    say('failed: $e');
    return UpdateJobResult(UpdateJobOutcome.failed, '$e');
  }
}

Future<UpdateJobResult> _run(
  UpdateJobInput input,
  JobUpdater updater,
  NotifyIo io,
  void Function(String) say,
) async {
  await updater.restore();
  final st = await updater.check(input.channel);
  final offer = st.offer;
  switch (st.phase) {
    case UpdatePhase.upToDate:
      say('up to date (${st.current})');
      return const UpdateJobResult(UpdateJobOutcome.upToDate);
    case UpdatePhase.ready:
      say('${offer?.version.semver} is downloaded already');
      return const UpdateJobResult(UpdateJobOutcome.alreadyReady);
    case UpdatePhase.available when offer != null:
      break;
    default:
      final why = st.lastError?.message ?? st.error?.message ?? st.phase.name;
      say('check failed: $why');
      return UpdateJobResult(UpdateJobOutcome.failed, why);
  }

  final v = offer.version.semver;
  say('$v is available (${input.channel.name}, ${offer.route.name})');
  final notifies = io.available && input.notify;
  final t = input.l10n();

  final mayDownload =
      input.autoDownload == UpdateAutoDownload.always ||
      (input.autoDownload == UpdateAutoDownload.wifi && !input.metered);
  if (mayDownload) {
    final d = await updater.download();
    if (d.phase == UpdatePhase.ready) {
      say('$v downloaded');
      if (notifies) {
        await io.postUpdate(
          UpdateNote(
            title: t.updateReady(v),
            text: t.tapToInstall,
            version: v,
            install: true,
            installLabel: t.install,
            file: d.file,
          ),
        );
        await io.setUpdateAnnounced(v);
      }
      return UpdateJobResult(UpdateJobOutcome.downloaded, v);
    }
    // the offer stays: tell about it the plain way
    say('download of $v did not finish (${d.error?.message ?? d.phase.name})');
  } else {
    say('download of $v not allowed (${input.autoDownload.name}${input.metered ? ', metered network' : ''})');
  }
  if (notifies && await io.updateAnnounced() != v) {
    await io.postUpdate(UpdateNote(title: t.updateAvailable(v), text: t.tapToSeeWhatSNew, version: v));
    await io.setUpdateAnnounced(v);
  }
  return UpdateJobResult(UpdateJobOutcome.available, v);
}

/// The last lines of the job's runs, `<dataDir>/update_job.log` (next to the core's folder, not in
/// `updates/`: the updater sweeps files it does not know there). Together with logcat (`debugPrint`)
/// the only trace of a run with no app.
class UpdateJobLog {
  UpdateJobLog(this.file, {this.keep = 80});
  final File file;
  final int keep;

  void add(String text) {
    final line = '${DateTime.now().toIso8601String()} $text';
    debugPrint('[update job] $line');
    try {
      final old = file.existsSync() ? file.readAsLinesSync() : <String>[];
      final lines = [...old, line];
      file.writeAsStringSync('${lines.sublist(lines.length > keep ? lines.length - keep : 0).join('\n')}\n', flush: true);
    } catch (_) {
      // the log is a convenience
    }
  }
}

/// The entry point of the worker's FlutterEngine (UpdateJob.kt: library `package:jormungand/core/update_job.dart`,
/// function `updateJobMain`). Reads the input from the native side, runs once, reports done.
@pragma('vm:entry-point')
Future<void> updateJobMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = UpdateJobChannel();
  var summary = 'no input';
  try {
    final m = await channel.input();
    if (m != null) {
      final input = UpdateJobInput.fromMap(m);
      final support = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final log = UpdateJobLog(File('${support.path}${sep}update_job.log'));
      final current = AppVersion.tryParse(input.versionName, build: input.versionCode);
      if (current == null) {
        log.add('the installed version "${input.versionName}" does not parse');
        summary = 'bad version';
      } else {
        // the same folder as the app's core: `<dataDir>/updates` (platform_seams.dart: `<support>/core`)
        final updater = AppUpdater(
          dir: Directory('${support.path}${sep}core${sep}updates'),
          current: current,
          platforms: updatePlatforms(os: 'android', abis: input.abis),
          installedPackage: input.installedPackage,
          onEvent: (type, level, data) => log.add('event $type ($level) $data'),
        );
        final r = await runUpdateJob(
          input: input,
          updater: CoreJobUpdater(updater),
          io: NotifyIo.current,
          log: log.add,
        );
        await updater.dispose();
        log.add('result: $r');
        summary = '$r';
      }
    }
  } catch (e) {
    summary = 'error: $e';
  } finally {
    await channel.done(summary);
  }
}
