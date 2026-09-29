import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'logbook.dart';

/// The events journal: what happened, as structured records (the Logs → Events tab and
/// every notification are made of it; the raw lines stay in [LogBook]).
///
/// An event is `{id, at, cat, type, level, own, log?, data}`: [id] grows by one for every
/// event and never goes back (also across restarts and [clear]); [at] is ms since epoch;
/// [own] = the user's own action caused it (no notification for it); [log] = the number of
/// the [LogBook] line written at the same moment (a jump to Raw); [data] holds structured
/// fields only, never a ready sentence (the app words it in the user's language).
///
/// Kept: the last [maxAge] and at most [cap] events. With a [file] the journal is a JSON
/// Lines file: an append per event, a rewrite when something is pruned or cleared (the
/// rewrite starts with a `{"seq": N}` line, so the ids go on after a restart even when no
/// event is left). A line that does not parse (a write cut off by a crash) is dropped.
/// Without a [file] it lives in memory only. Disk trouble never reaches the caller.
class EventBook {
  EventBook(this.file, {this.log, this.maxAge = const Duration(days: 7), this.cap = 1000, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final File? file;

  /// Where [add] takes the `log` link from.
  final LogBook? log;
  final Duration maxAge;
  final int cap;
  final DateTime Function() _clock;

  static const cats = {'conn', 'auto', 'site', 'sub', 'rules', 'core', 'user'};
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
    if (_prune() || dropped) _rewrite();
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
  int add(String cat, String type, String level, {Map<String, dynamic> data = const {}, bool own = false, bool link = true}) {
    load();
    final n = link ? log?.last : null;
    final e = <String, dynamic>{
      'id': _next++,
      'at': _clock().millisecondsSinceEpoch,
      'cat': cat,
      'type': type,
      'level': level,
      'own': own,
      'log': ?n,
      'data': data,
    };
    _events.add(e);
    if (_prune()) {
      _rewrite();
    } else {
      _append(e);
    }
    return e['id'] as int;
  }

  /// `{events (oldest first, ids from [from]; the last [tail] without it), next (the id the
  /// next event gets), first (the oldest id kept: the app sees a gap or a clear)}`.
  Map<String, dynamic> since(int? from, {int tail = 200}) {
    load();
    final l = [for (final e in _events) if (from == null || (e['id'] as int) >= from) e];
    return {
      'events': from == null && l.length > tail ? l.sublist(l.length - tail) : l,
      'next': _next,
      'first': _events.isEmpty ? _next : _events.first['id'],
    };
  }

  /// Empties the journal (and the file); ids go on.
  void clear() {
    load();
    _events.clear();
    _rewrite();
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
      any = true;
    }
    return any;
  }

  void _append(Map<String, dynamic> e) {
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode(e)}\n', mode: FileMode.append);
    } on FileSystemException {
      // memory keeps it
    }
  }

  void _rewrite() {
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync('${jsonEncode({'seq': _next})}\n${[for (final e in _events) '${jsonEncode(e)}\n'].join()}');
      tmp.renameSync(f.path);
    } on FileSystemException {
      // the old file stays; the next rewrite tries again
    }
  }
}
