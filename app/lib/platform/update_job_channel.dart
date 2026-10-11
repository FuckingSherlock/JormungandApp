import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the background update check (Android WorkManager job, lib/core/update_job.dart) needs of the
/// settings. The app mirrors it natively on every change; the job reads it with no app running.
class UpdateJobSettings {
  const UpdateJobSettings({
    required this.autoCheck,
    required this.channel,
    required this.autoDownload,
    required this.notify,
    this.lang,
  });

  /// Settings -> Data «Auto-check» (off = the job is cancelled).
  final bool autoCheck;

  /// `stable` | `beta`.
  final String channel;

  /// `off` | `wifi` | `always`.
  final String autoDownload;

  /// The update notifications may be shown: the master switch of Settings -> Notifications and its
  /// `updateAvailable` row.
  final bool notify;

  /// The app's language (`en` | `ru`); null = never chosen, the system language decides.
  final String? lang;

  Map<String, Object?> toMap() => {
    'autoCheck': autoCheck,
    'channel': channel,
    'autoDownload': autoDownload,
    'notify': notify,
    'lang': lang ?? '',
  };

  @override
  bool operator ==(Object other) =>
      other is UpdateJobSettings &&
      other.autoCheck == autoCheck &&
      other.channel == channel &&
      other.autoDownload == autoDownload &&
      other.notify == notify &&
      other.lang == lang;

  @override
  int get hashCode => Object.hash(autoCheck, channel, autoDownload, notify, lang);
}

/// The seam to the native side of the background update check: a fake in tests, null where there is
/// no such job (the desktop).
abstract interface class UpdateJobPort {
  /// Mirrors the settings and (re)schedules the periodic job, or cancels it when auto-check is off.
  Future<void> sync(UpdateJobSettings settings);
}

/// MethodChannel `jormungand/updatejob` (Kotlin: android_overlay/kotlin/UpdateJob.kt.tmpl). The app's
/// engine uses [sync]; the job's own engine (a separate FlutterEngine started by the worker) uses
/// [input] and [done].
class UpdateJobChannel implements UpdateJobPort {
  const UpdateJobChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/updatejob');

  static bool get available => !kIsWeb && Platform.isAndroid;

  @override
  Future<void> sync(UpdateJobSettings settings) async {
    if (!available) return;
    try {
      await _channel.invokeMethod<void>('sync', settings.toMap());
    } on MissingPluginException {
      // no native side
    } on PlatformException {
      // the job is a convenience: the in-process schedule still runs
    }
  }

  /// The job's input (mirrored settings + the device facts read at run time); null = not a job engine.
  Future<Map<String, Object?>?> input() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('input');
      return m;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The job is over: the worker destroys the engine and ends its work. [summary] goes to logcat.
  Future<void> done(String summary) async {
    try {
      await _channel.invokeMethod<void>('done', {'summary': summary});
    } on MissingPluginException {
      // nothing to tell
    } on PlatformException {
      // the worker has its own time limit
    }
  }
}
