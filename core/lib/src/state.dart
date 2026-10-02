import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fields of a subscription source the core owns: an update rewrites them, the user never
/// edits them. Everything else on a source (name, url, switches, offNodes, filter…) is the
/// user's. The UI keeps the same list (`SERVER_FIELDS` in 95-live.js).
const sourceServerFields = [
  'nodes',
  'gone',
  'count',
  'uaStrategy',
  'discoveredAt',
  'usage',
  'expire',
  'format',
  'providerInterval',
  'webPage',
  'supportUrl',
  'announce',
  'updatedAt',
  'lastError', // {msg, at} of a failed update; the UI sets it for its own (Retry on the card)
];

/// The UI's state as one JSON snapshot (`ui-state.json`), written by the UI (every change)
/// and by the core's own jobs (subscription updates on a timer, updater.dart). All reads
/// and writes go through one queue, so they never interleave.
///
/// Conflicts: the UI saves its whole state, the core patches one source's
/// [sourceServerFields]. A source's `updatedAt` (core clock) is the version of those fields:
///  - a UI save whose source is older than the stored one (a timer update the UI has not
///    picked up yet) keeps the stored server fields and takes everything else from the UI;
///  - a timer update lands only if the source still has the url, UA, filter, HWID, gone
///    list and `updatedAt` it was fetched with (the user did not edit, update or delete it
///    meanwhile), else it is dropped.
/// [rev] moves on every core-side change; `/api/status` shows it and the UI reloads sources
/// when it moves.
///
/// Durability (a power cut must not cost the user's state): a write goes to `<file>.tmp`,
/// is flushed to the disk, and only then replaces the file; the file it replaces is kept as
/// `<file>.bak` (and the older `.bak` as `.bak2` when it is at least [bak2Every] old, so a
/// valid-but-bad save does not push the last good copy out within seconds). Renames only
/// move data that is already on the disk, so at any crash point the file is the old or the
/// new snapshot (between the two renames it is missing and the `.bak` is the old one).
/// A load that finds the file missing, unreadable, empty / NUL-filled, not JSON or not an
/// object moves it aside as `<file>.corrupt-<time>` (never deleted; the newest
/// [keepCorrupt] stay), takes the `.bak`, then the `.bak2`, writes it back as the file, and
/// reports through [onRecovery]: `stateRestored` (warn, `{from: 'bak' | 'bak2', savedAt,
/// reason, kept?}`) or, when no copy is good either and the state starts empty,
/// `stateLost` (error, `{reason, kept?}`). Saves work after either.
class SnapshotStore {
  SnapshotStore(this.file, {this.onRecovery, this.bak2Every = const Duration(minutes: 10), this.keepCorrupt = 5, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final File file;

  /// (type, level, data, note): [note] is a ready line for the raw log.
  final void Function(String type, String level, Map<String, dynamic> data, String note)? onRecovery;
  final Duration bak2Every;
  final int keepCorrupt;
  final DateTime Function() _clock;
  Map<String, dynamic>? _snap;
  bool _loaded = false;
  bool _fileGood = false; // what is on the disk under [file] is a snapshot we read or wrote
  Future<void> _queue = Future.value();

  /// Bumped when the core changed the snapshot on its own.
  int rev = 0;

  File get _bak => File('${file.path}.bak');
  File get _bak2 => File('${file.path}.bak2');

  Future<T> _locked<T>(Future<T> Function() fn) {
    final r = _queue.then((_) => fn());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  // The snapshot in [f], or why it is no good: unreadable, empty, nul (all NUL bytes: a write
  // that never reached the disk), invalid (not JSON) or notObject. Never throws.
  static Future<({Map<String, dynamic>? snap, String? bad})> _read(File f) async {
    try {
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return (snap: null, bad: 'empty');
      if (bytes.every((b) => b == 0)) return (snap: null, bad: 'nul');
      final j = jsonDecode(utf8.decode(bytes));
      if (j == null) return (snap: null, bad: null); // saved as "no state"
      if (j is Map) return (snap: j.cast<String, dynamic>(), bad: null);
      return (snap: null, bad: 'notObject');
    } on FileSystemException {
      return (snap: null, bad: 'unreadable');
    } on FormatException {
      return (snap: null, bad: 'invalid');
    } catch (_) {
      return (snap: null, bad: 'invalid');
    }
  }

  // Moves a damaged [f] to `<f>.corrupt-<time>`; the name, null when that did not work.
  Future<String?> _setAside(File f) async {
    try {
      final t = _clock().toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
      var path = '${f.path}.corrupt-$stamp';
      for (var i = 1; File(path).existsSync(); i++) {
        path = '${f.path}.corrupt-$stamp-$i';
      }
      await f.rename(path);
      _pruneCorrupt();
      return path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);
    } catch (_) {
      return null;
    }
  }

  void _pruneCorrupt() {
    try {
      final base = file.uri.pathSegments.last;
      final old = [
        for (final e in file.parent.listSync())
          if (e is File && e.uri.pathSegments.last.startsWith('$base.') && e.uri.pathSegments.last.contains('.corrupt-')) e
      ];
      String key(File f) => f.uri.pathSegments.last.substring(f.uri.pathSegments.last.indexOf('.corrupt-'));
      old.sort((a, b) => key(a).compareTo(key(b)));
      for (final f in old.take(old.length - keepCorrupt)) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  void _report(String type, String level, Map<String, dynamic> data, String note) {
    try {
      onRecovery?.call(type, level, data, note);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _load() async {
    if (_loaded) return _snap;
    _loaded = true;
    String? reason, kept; // why the file is no good; where it went
    if (file.existsSync()) {
      final r = await _read(file);
      if (r.bad == null) {
        _fileGood = true;
        return _snap = r.snap;
      }
      reason = r.bad;
      kept = await _setAside(file);
    }
    for (final (name, f) in [('bak', _bak), ('bak2', _bak2)]) {
      if (!f.existsSync()) continue;
      final r = await _read(f);
      if (r.bad != null) {
        reason ??= r.bad;
        final k = await _setAside(f); // a bad copy must not be rotated over a good one
        kept ??= k;
        continue;
      }
      var savedAt = 0;
      try {
        savedAt = f.lastModifiedSync().millisecondsSinceEpoch;
      } catch (_) {}
      _snap = r.snap;
      try {
        await _write(); // the copy becomes the file again
      } catch (_) {}
      _report('stateRestored', 'warn', {'from': name, 'savedAt': savedAt, 'reason': reason ?? 'missing', 'kept': ?kept},
          'Saved UI state ${reason == null ? 'was missing' : 'was damaged ($reason)'}: restored the $name copy saved ${DateTime.fromMillisecondsSinceEpoch(savedAt).toIso8601String()}${kept == null ? '' : '; the damaged file is kept as $kept'}');
      return _snap;
    }
    if (reason != null) {
      _report('stateLost', 'error', {'reason': reason, 'kept': ?kept},
          'Saved UI state was damaged ($reason) and no copy is usable: starting empty${kept == null ? '' : '; the damaged file is kept as $kept'}');
    }
    return _snap = null;
  }

  Future<void> _write() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_snap), flush: true);
    if (_fileGood && file.existsSync()) {
      // keep the file we replace; the older copy only moves on when it is old enough
      if (_bak.existsSync()) {
        final age = _clock().difference(_bak.lastModifiedSync());
        if (age >= bak2Every) await _bak.rename(_bak2.path);
      }
      await file.rename(_bak.path);
    }
    await tmp.rename(file.path);
    _fileGood = true;
  }

  /// The stored snapshot (null = nothing saved yet). Shared: read it, do not change it.
  Future<Map<String, dynamic>?> read() => _locked(_load);

  /// One source, as a deep copy (safe to hand to a long fetch).
  Future<Map<String, dynamic>?> source(String sid) => _locked(() async {
        final s = _sources(await _load())?[sid];
        return s is Map ? (jsonDecode(jsonEncode(s)) as Map).cast<String, dynamic>() : null;
      });

  /// A save from the UI.
  Future<void> save(Map<String, dynamic>? incoming) => _locked(() async {
        final cur = await _load();
        final theirs = _sources(incoming), mine = _sources(cur);
        if (theirs != null && mine != null) {
          for (final e in theirs.entries) {
            final m = mine[e.key], t = e.value;
            if (m is! Map || t is! Map || m['kind'] != 'sub' || m['url'] != t['url']) continue;
            if (_num(m['updatedAt']) <= _num(t['updatedAt'])) continue;
            for (final f in sourceServerFields) {
              if (m.containsKey(f)) {
                t[f] = m[f];
              } else {
                t.remove(f);
              }
            }
          }
        }
        _snap = incoming;
        await _write();
      });

  /// Puts [patch] on source [sid] when it is still there and every [expect] field still
  /// has the value it had when the job started. True when applied.
  Future<bool> patchSource(String sid, Map<String, dynamic> expect, Map<String, dynamic> patch) => _locked(() async {
        final s = _sources(await _load())?[sid];
        if (s is! Map) return false;
        for (final e in expect.entries) {
          if (jsonEncode(s[e.key]) != jsonEncode(e.value)) return false;
        }
        s.addAll(patch);
        rev++;
        await _write();
        return true;
      });

  static Map? _sources(Map<String, dynamic>? snap) => snap?['sourcesData'] is Map ? snap!['sourcesData'] as Map : null;
  static num _num(Object? v) => v is num ? v : 0;
}
