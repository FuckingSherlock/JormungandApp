import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';
import 'logbook.dart';

/// The events journal: what happened, as structured records (the Logs → Events tab and
/// every notification are made of it; the raw lines stay in [LogBook]).
///
/// An event is `{id, at, cat, type, level, own, bg?, rev?, log?, data}` (`rev`: how often [update]
/// changed it): [id] grows by one for every
/// event and never goes back (also across restarts and [clear]); [at] is ms since epoch;
/// [own] = the user's own action caused it (no notification for it); `bg` (only when true) = it
/// happened while the phone's screen was off (a background failure: Settings → Notifications
/// decides whether it notifies; the journal keeps it either way); [log] = the number of
/// the [LogBook] line written at the same moment (a jump to Raw); [data] holds structured
/// fields only, never a ready sentence (the app words it in the user's language).
///
/// Kept: the last [maxAge] and at most [cap] events (in memory strictly). With a [file] the
/// journal is a JSON Lines file written behind the memory: new events are collected and
/// appended in one write [flushEvery] after the first of them (and by [flush], which the
/// owner calls on shutdown), so a burst costs one fsync, not one per event; a crash loses
/// at most that last second. What is pruned stays in the file until [pruneChunk] lines are
/// stale, then the file is rewritten once (also on [clear]); the rewrite starts with a
/// `{"seq": N}` line, so the ids go on after a restart even when no event is left, and the
/// start trims the file to the limits. A line that does not parse (a write cut off by a
/// crash) is dropped. The writes are asynchronous and run one after another. Without a
/// [file] it lives in memory only. Disk trouble never reaches the caller (a failed write
/// makes the next one a rewrite).
class EventBook {
  EventBook(this.file,
      {this.log,
      this.maxAge = const Duration(days: 7),
      this.cap = 1000,
      this.flushEvery = const Duration(milliseconds: 1500),
      this.pruneChunk = 100,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final File? file;

  /// How long new events wait in memory before they are appended to the file.
  final Duration flushEvery;

  /// How many pruned events may stay in the file before it is rewritten.
  final int pruneChunk;

  /// Where [add] takes the `log` link from.
  final LogBook? log;
  final Duration maxAge;
  final int cap;
  final DateTime Function() _clock;

  static const cats = {'conn', 'auto', 'site', 'sub', 'rules', 'dns', 'core', 'user'};
  static const levels = {'info', 'warn', 'error'};

  final _events = ListQueue<Map<String, dynamic>>();
  int _next = 0;
  bool _loaded = false;

  /// Reads the file and prunes it. Called by every other method when needed; jormd calls it
  /// at start so an old journal is trimmed then.
  void load() {
    if (_loaded) return;
    _loaded = true;
    final f = file;
    if (f == null) return;
    var dropped = false;
    try {
      f.parent.createSync(recursive: true);
      if (!f.existsSync()) return;
      for (final line in f.readAsLinesSync(encoding: const Utf8Codec(allowMalformed: true))) {
        if (line.trim().isEmpty) continue;
        final e = _parse(line);
        if (e == null) {
          dropped = true;
        } else if (e is int) {
          if (e > _next) _next = e;
        } else if (e is Map<String, dynamic>) {
          final id = e['id'] as int;
          if (_events.isNotEmpty && id <= (_events.last['id'] as int)) {
            dropped = true; // out of order: not one of ours
            continue;
          }
          _events.add(e);
          if (id >= _next) _next = id + 1;
        }
      }
    } on FileSystemException {
      return;
    }
    if (_prune() || dropped) _rewriteSync();
    _stale = 0;
  }

  // A journal line: an event map, the `seq` marker (its number) or null (corrupt).
  static Object? _parse(String line) {
    try {
      final j = jsonDecode(line);
      if (j is! Map) return null;
      if (j['id'] == null && j['seq'] is int) return j['seq'] as int;
      if (j['id'] is int && j['at'] is int && j['cat'] is String && j['type'] is String && j['level'] is String && j['data'] is Map) {
        return j.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  /// Writes a new event and returns its id. [link]: put the current [LogBook] number on it
  /// (the caller writes the raw line first; an event without a raw line of its own, like
  /// the UI's, passes false).
  int add(String cat, String type, String level, {Map<String, dynamic> data = const {}, bool own = false, bool link = true, bool bg = false}) {
    load();
    final n = link ? log?.last : null;
    final e = <String, dynamic>{
      'id': _next++,
      'at': _clock().millisecondsSinceEpoch,
      'cat': cat,
      'type': type,
      'level': level,
      'own': own,
      if (bg) 'bg': true,
      'log': ?n,
      'data': data,
    };
    _events.add(e);
    _prune();
    if (file != null) {
      _pending.add('${jsonEncode(e)}\n');
      _timer ??= Timer(flushEvery, () {
        _timer = null;
        unawaited(flush());
      });
    }
    if (!_added.isClosed) _added.add(e);
    return e['id'] as int;
  }

  /// Changes event [id] in place (a check that finished later): [data] fields are laid over its
  /// own, [level] replaces the level when given. The event keeps its id and place, gets `rev`
  /// (the number of changes, absent = 0), is pushed on [stream] again and rides in [since]'s
  /// `updated` for [updatedFor]; the file is rewritten behind the memory like after a prune.
  /// Returns false when the event is not there any more.
  bool update(int id, {Map<String, dynamic> data = const {}, String? level}) {
    load();
    final i = _indexOf(id);
    if (i < 0) return false;
    // the queue has no indexed write: the map changes where it is (readers compare `rev`)
    final e = _events.elementAt(i);
    if (level != null) e['level'] = level;
    e['rev'] = ((e['rev'] as int?) ?? 0) + 1;
    e['data'] = {...(e['data'] as Map<String, dynamic>), ...data};
    _updatedAt[id] = _clock().millisecondsSinceEpoch;
    if (_updatedAt.length > 50) _updatedAt.remove(_updatedAt.keys.first);
    if (file != null) {
      _rewrite = true;
      _timer ??= Timer(flushEvery, () {
        _timer = null;
        unawaited(flush());
      });
    }
    if (!_added.isClosed) _added.add(e);
    return true;
  }

  /// The event with this id, or null.
  Map<String, dynamic>? byId(int id) {
    load();
    final i = _indexOf(id);
    return i < 0 ? null : _events.elementAt(i);
  }

  /// How long a changed event stays in the `updated` list of [since].
  static const updatedFor = Duration(minutes: 10);
  final _updatedAt = <int, int>{};

  // The ids only grow along the queue: binary search; -1 = not there.
  int _indexOf(int id) {
    var lo = 0, hi = _events.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1, v = _events.elementAt(mid)['id'] as int;
      if (v == id) return mid;
      if (v < id) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }

  final _added = StreamController<Map<String, dynamic>>.broadcast();

  /// Every event as it is written (notifications, the live Events view, instead of polling [since]).
  Stream<Map<String, dynamic>> get stream => _added.stream;

  /// Ends [stream]; events written later are still kept.
  void close() {
    if (!_added.isClosed) unawaited(_added.close());
  }

  /// `{events (oldest first, ids from [from]; the last [tail] without it), updated? (events
  /// changed by [update] in the last [updatedFor], whatever their id: a reader compares `rev`),
  /// next (the id the next event gets), first (the oldest id kept: the app sees a gap or a clear)}`.
  ///
  /// The ids only grow along the queue: the start is found by a binary search, so a poll
  /// that finds nothing new costs nothing, whatever the size of the journal.
  Map<String, dynamic> since(int? from, {int tail = 200}) {
    load();
    final n = _events.length;
    var i = 0;
    if (from == null) {
      if (n > tail) i = n - tail;
    } else if (n > 0 && from > (_events.last['id'] as int)) {
      i = n;
    } else {
      var hi = n;
      while (i < hi) {
        final mid = (i + hi) >> 1;
        if ((_events.elementAt(mid)['id'] as int) < from) {
          i = mid + 1;
        } else {
          hi = mid;
        }
      }
    }
    final now = _clock().millisecondsSinceEpoch;
    final updated = [
      for (final MapEntry(key: id, value: at) in _updatedAt.entries)
        if (now - at <= updatedFor.inMilliseconds && _indexOf(id) >= 0) _events.elementAt(_indexOf(id)),
    ];
    return {
      'events': [for (var k = i; k < n; k++) _events.elementAt(k)],
      if (updated.isNotEmpty) 'updated': updated,
      'next': _next,
      'first': _events.isEmpty ? _next : _events.first['id'],
    };
  }

  /// Empties the journal (and the file, by a rewrite); ids go on.
  void clear() {
    load();
    _events.clear();
    _pending.clear();
    _rewrite = true;
    if (file != null) unawaited(flush());
  }

  int get length {
    load();
    return _events.length;
  }

  // Drops what is too old or over the cap; whether anything went.
  bool _prune() {
    var any = false;
    final oldest = _clock().millisecondsSinceEpoch - maxAge.inMilliseconds;
    while (_events.isNotEmpty && ((_events.first['at'] as int) < oldest || _events.length > cap)) {
      _events.removeFirst();
      _stale++;
      any = true;
    }
    return any;
  }

  // New events not in the file yet (each a whole line), the timer that writes them, the last
  // write (the next one waits for it), the lines of the file that are no longer kept, and a
  // rewrite that is due (a clear, a failed write).
  final _pending = <String>[];
  Timer? _timer;
  Future<void> _io = Future<void>.value();
  int _stale = 0;
  bool _rewrite = false;

  String get _whole => '${jsonEncode({'seq': _next})}\n${[for (final e in _events) '${jsonEncode(e)}\n'].join()}';

  /// Puts what waits in memory into the file now: an append, or the rewrite when it is due.
  /// Completes when it is written (and everything before it). The owner calls it on shutdown.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final f = file;
    final whole = _rewrite || _stale >= pruneChunk;
    if (f == null || (_pending.isEmpty && !whole)) return _io;
    final String text;
    if (whole) {
      text = _whole;
      _rewrite = false;
      _stale = 0;
    } else {
      text = _pending.join();
    }
    _pending.clear();
    return _io = _io.then((_) => _write(f, text, whole));
  }

  Future<void> _write(File f, String text, bool whole) async {
    try {
      // the directory is made by [load]: a write that comes late (the data directory is gone,
      // as in a test that cleaned up) must not bring it back
      if (whole) {
        await writeFileDurable(f, text);
      } else {
        await f.writeAsString(text, mode: FileMode.append, flush: true);
      }
    } catch (_) {
      _rewrite = true; // memory keeps it; the next write puts the whole journal back
    }
  }

  // The synchronous rewrite of [load] (nothing else writes yet).
  void _rewriteSync() {
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      writeFileDurableSync(f, _whole);
    } on FileSystemException {
      // the old file stays; the next rewrite tries again
      _rewrite = true;
    }
  }
}
