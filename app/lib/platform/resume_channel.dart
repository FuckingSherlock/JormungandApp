import 'package:flutter/services.dart';

/// What the app remembers across its own update (docs/updates.md, "Подключение после обновления").
///
/// Written natively next to the tunnel and before the installer ([ResumePort.save]); the system
/// replacing the package arms it (`armedAt`), the first start after that [ResumePort.take]s it.
class ResumeRecord {
  const ResumeRecord({
    required this.connected,
    required this.entry,
    required this.fromCode,
    required this.code,
    required this.at,
  });

  /// The VPN was on (and not switched off by the user) when the old build went away.
  final bool connected;

  /// The entry (profile / chain / source) it went through (`Catalog.effectiveConnectId`); the
  /// connect itself uses the catalog's current one, this is for the journal and checks.
  final String entry;

  /// `versionCode` of the build that wrote the record.
  final int fromCode;

  /// `versionCode` of the build that runs now.
  final int code;

  /// When the system replaced the package (ms since epoch).
  final int at;
}

/// The seam to the native "resume after update" store (Kotlin `ResumeStore` / `ResumeChannel`); a
/// fake in tests. Where it is not [available] (the desktop) nothing is remembered or restored.
abstract interface class ResumePort {
  bool get available;

  /// Before the installer: remembers whether the VPN is on and through which entry.
  Future<void> save({required bool connected, required String entry});

  /// After an update: the record the package replacement armed, once (taking it consumes it, so a
  /// resume can never run twice); null = this start follows no update.
  Future<ResumeRecord?> take();

  /// Consent for the VPN is missing: a notification "Updated - tap to connect" whose tap opens the
  /// app and connects.
  Future<void> promptConnect();

  /// The resume is dealt with (the native side lets go of the process it kept alive for it).
  Future<void> done();
}

/// Android: MethodChannel `jormungand/resume` (Kotlin: android_overlay/kotlin/ResumeAfterUpdate.kt.tmpl).
class ResumeChannel implements ResumePort {
  const ResumeChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/resume');

  @override
  bool get available => true;

  /// A window attached to the (process-owned) engine: [onAttached] runs for every attach from now
  /// on, and once at once when one attached before this was called (the native side keeps that
  /// answer, so a window that came while Dart was still starting is not missed).
  static void onWindowAttached(void Function() onAttached) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'windowAttached') onAttached();
      return null;
    });
    () async {
      try {
        if (await _channel.invokeMethod<bool>('attached') == true) onAttached();
      } on MissingPluginException {
        // not Android
      }
    }();
  }

  @override
  Future<void> save({required bool connected, required String entry}) async {
    try {
      await _channel.invokeMethod<void>('save', <String, Object?>{
        'connected': connected,
        'entry': entry,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  @override
  Future<ResumeRecord?> take() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('take');
      if (m == null) return null;
      return ResumeRecord(
        connected: m['connected'] == true,
        entry: '${m['entry'] ?? ''}',
        fromCode: (m['fromCode'] as num?)?.toInt() ?? 0,
        code: (m['code'] as num?)?.toInt() ?? 0,
        at: (m['at'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> promptConnect() async {
    try {
      await _channel.invokeMethod<void>('prompt');
    } on MissingPluginException {
      // not Android
    }
  }

  @override
  Future<void> done() async {
    try {
      await _channel.invokeMethod<void>('done');
    } on MissingPluginException {
      // not Android
    }
  }
}
