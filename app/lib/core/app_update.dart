/// The app's own update as the Data settings show it: the core's `UpdateStatus.toJson`
/// (docs/updates.md, core/lib/src/appupdate.dart) read into plain fields.
library;

enum UpdPhase {
  /// The host gave the core no app version (no updater).
  unavailable,
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  failed;

  static UpdPhase parse(Object? v) => values.firstWhere(
    (p) => p.name == v,
    orElse: () => UpdPhase.unavailable,
  );
}

/// What the manifest offers this device (`UpdateOffer.toJson`).
class UpdOffer {
  const UpdOffer({
    required this.version,
    required this.channel,
    required this.size,
    required this.notes,
    this.forced = false,
    this.page,
    this.kind = '',
    this.deltaSize = 0,
  });

  factory UpdOffer.fromJson(Map<String, dynamic> j) => UpdOffer(
    version: '${j['version'] ?? ''}',
    channel: j['channel'] == 'beta' ? 'beta' : 'stable',
    size: (j['size'] as num?)?.toInt() ?? 0,
    notes: {
      if (j['notes'] is Map)
        for (final e in (j['notes'] as Map).entries) '${e.key}': '${e.value}',
    },
    forced: j['forced'] == true,
    page: j['page'] as String?,
    kind: '${j['kind'] ?? ''}',
    deltaSize: j['delta'] == true ? (j['deltaSize'] as num?)?.toInt() ?? 0 : 0,
  );

  final String version;
  final String channel;
  final int size;

  /// > 0: a patch for the installed file is on offer, this many bytes (docs/updates.md, delta updates);
  /// [size] stays the whole installer's.
  final int deltaSize;

  /// What the download will fetch: the patch when there is one, else the installer.
  int get downloadSize => deltaSize > 0 ? deltaSize : size;

  /// Release notes by language (`en`, `ru`).
  final Map<String, String> notes;
  final bool forced;
  final String? page;

  /// `apk` | `zip` | `installer`.
  final String kind;

  /// The notes in [lang], else English, else any.
  String notesFor(String lang) =>
      notes[lang] ?? notes['en'] ?? (notes.values.isEmpty ? '' : notes.values.first);
}

/// Why a check or a download failed (`UpdateError` name + the core's message).
class UpdError {
  const UpdError(this.code, this.message);

  final String code;
  final String message;
}

class AppUpdate {
  const AppUpdate({
    this.phase = UpdPhase.unavailable,
    this.current = '',
    this.offer,
    this.received = 0,
    this.total = 0,
    this.file,
    this.error,
    this.checkedAt,
  });

  factory AppUpdate.fromJson(Map<String, dynamic> j) {
    final o = j['offer'];
    final e = j['error'];
    return AppUpdate(
      phase: UpdPhase.parse(j['phase']),
      current: '${j['current'] ?? ''}',
      offer: o is Map ? UpdOffer.fromJson(Map<String, dynamic>.from(o)) : null,
      received: (j['received'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      file: j['file'] as String?,
      error: e is Map ? UpdError('${e['code']}', '${e['message'] ?? ''}') : null,
      checkedAt: (j['checkedAt'] as num?)?.toInt(),
    );
  }

  final UpdPhase phase;
  final String current;
  final UpdOffer? offer;
  final int received;
  final int total;

  /// ready: the verified file.
  final String? file;
  final UpdError? error;

  /// ms since epoch of the last finished check.
  final int? checkedAt;

  /// failed with nothing offered = the check failed; with an offer = the download did.
  bool get checkFailed => phase == UpdPhase.failed && offer == null;
  bool get busy => phase == UpdPhase.checking || phase == UpdPhase.downloading;
}
