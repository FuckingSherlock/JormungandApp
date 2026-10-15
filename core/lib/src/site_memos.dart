/// What the site checks remember of each `site/*` verdict (docs/failures.md → Проверки сайтов в Sentinel → Память
/// вердикта): until the timer of a verdict runs out, the failures of the site through that route are only counted on its
/// event. Kept across a reconnect, an own restart and a restart of the app ([SiteMemoStore], `<dataDir>/site-verdicts.json`):
/// only a new check of the same site, a connection through the route that gets data back, or (the ladder, not «dead
/// everywhere») another network changes or ends a verdict.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';

/// One remembered verdict of `<dest>|<route>`.
class SiteMemo {
  SiteMemo({required this.eventId, required this.kind, required this.dead, required this.step, required this.until, required this.dest, required this.route, this.net = ''});
  final int eventId, step;

  /// [dest] lower case; [route] the route's one identity (`CoreService._siteRoute`).
  final String kind, dest, route;
  final bool dead;

  /// The network the verdict was taken on (`<type>|<id>`, `|` or empty = not known): a ladder verdict (not [dead]) is void
  /// on another one, also when the change happened while the core was not running.
  final String net;

  /// Ms since epoch: failures before it are only counted.
  int until;

  /// The checker alone is looking again (after a «dead» verdict): failures that come meanwhile are counted. Not kept.
  bool rechecking = false;

  Map<String, dynamic> toJson(String key) => {
        'key': key,
        'event': eventId,
        'kind': kind,
        'dead': dead,
        'step': step,
        'until': until,
        'dest': dest,
        'route': route,
        if (net.isNotEmpty) 'net': net,
      };
}

/// The memos by `<dest>|<route>`; every change that is worth keeping calls [onChange].
class SiteMemoBook {
  /// Called when something worth keeping changed ([SiteMemoStore]).
  void Function()? onChange;

  final _m = <String, SiteMemo>{};

  bool get isEmpty => _m.isEmpty;
  int get length => _m.length;
  SiteMemo? operator [](String key) => _m[key];

  void operator []=(String key, SiteMemo memo) {
    _m[key] = memo;
    onChange?.call();
  }

  /// The memo's timer moved ([SiteMemo.until]): write it.
  void touch() => onChange?.call();

  void remove(String key) {
    if (_m.remove(key) != null) onChange?.call();
  }

  void removeWhere(bool Function(String key, SiteMemo m) test) {
    final n = _m.length;
    _m.removeWhere(test);
    if (_m.length != n) onChange?.call();
  }

  /// Drops the memos whose event is gone (the journal was cleared or pruned): they are judged anew anyway. Writes nothing
  /// by itself (it runs just before a write).
  void prune(bool Function(int eventId) alive) => _m.removeWhere((_, m) => !alive(m.eventId));

  /// Takes what [toJson] kept; unreadable entries and those whose event is gone ([alive]) are left out. Returns how many it took.
  int load(Object? json, bool Function(int eventId) alive) {
    if (json is! List) return 0;
    var taken = 0;
    for (final e in json) {
      if (e is! Map || e['key'] is! String || e['event'] is! num || e['kind'] is! String || e['dead'] is! bool || e['until'] is! num) continue;
      if (e['dest'] is! String || e['route'] is! String) continue;
      final id = (e['event'] as num).toInt();
      if (!alive(id)) continue;
      _m[e['key'] as String] = SiteMemo(
          eventId: id,
          kind: e['kind'] as String,
          dead: e['dead'] as bool,
          step: (e['step'] as num?)?.toInt() ?? 0,
          until: (e['until'] as num).toInt(),
          dest: e['dest'] as String,
          route: e['route'] as String,
          net: e['net'] is String ? e['net'] as String : '');
      taken++;
    }
    return taken;
  }

  List<Map<String, dynamic>> toJson() => [for (final e in _m.entries) e.value.toJson(e.key)];
}

/// Keeps the book in a file (`<dataDir>/site-verdicts.json`): written a moment after it changed, read at the start.
class SiteMemoStore {
  SiteMemoStore(this.file, this.book, {required this.alive, this.debounce = const Duration(seconds: 2)}) {
    book.onChange = _changed;
  }

  final File file;
  final SiteMemoBook book;

  /// Whether the journal still has the event with this id.
  final bool Function(int eventId) alive;
  final Duration debounce;
  Timer? _timer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Reads the file (none / damaged = an empty book); returns how many verdicts were taken.
  int load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      return book.load(j is Map ? j['sites'] : null, alive);
    } catch (_) {
      return 0;
    }
  }

  void _changed() {
    if (_closed || _timer != null) return;
    _timer = Timer(debounce, () {
      _timer = null;
      _writing = _writing.then((_) => _write());
    });
  }

  Future<void> _write() async {
    try {
      book.prune(alive);
      await writeFileDurable(file, jsonEncode({'v': 1, 'sites': book.toJson()}));
    } catch (_) {} // a full disk or a locked file: the book lives in memory, the next change writes again
  }

  /// Writes what waits now (the app closes) and stops watching the book.
  Future<void> close() async {
    final pending = _timer != null;
    _timer?.cancel();
    _timer = null;
    _closed = true;
    if (book.onChange == _changed) book.onChange = null;
    if (pending) _writing = _writing.then((_) => _write());
    await _writing;
  }
}
