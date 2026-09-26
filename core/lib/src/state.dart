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
class SnapshotStore {
  SnapshotStore(this.file);

  final File file;
  Map<String, dynamic>? _snap;
  bool _loaded = false;
  Future<void> _queue = Future.value();

  /// Bumped when the core changed the snapshot on its own.
  int rev = 0;

  Future<T> _locked<T>(Future<T> Function() fn) {
    final r = _queue.then((_) => fn());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<Map<String, dynamic>?> _load() async {
    if (!_loaded) {
      _snap = file.existsSync() ? (jsonDecode(await file.readAsString()) as Map?)?.cast<String, dynamic>() : null;
      _loaded = true;
    }
    return _snap;
  }

  Future<void> _write() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_snap));
    await tmp.rename(file.path);
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
