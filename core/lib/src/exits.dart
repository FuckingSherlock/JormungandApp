/// Where each node leaves to: the exit IP and country the exit check (exitip.dart) found the last time traffic went
/// through the node (docs/failures.md → Проверки сайтов → разведчик, docs/core.md → Выход нод). The controller (Auto,
/// auto.dart) reads it for the country of a node the provider gave no flag to.
///
/// Keyed by the server's own pool identity (pool.dart [serverIdentity]: the same key the dead ladder uses, ladder.dart),
/// not by a chain's pair: a chain's exit leaves where its exit server does, whatever entry it is dialed through.
/// Kept across a restart of the app ([ExitBookStore], `<dataDir>/exit-nodes.json`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';

/// The ISO 3166 [code] ('DE') as the flag emoji the plan names countries by ('🇩🇪'); '' = not a two-letter code.
String flagOfCountry(String code) {
  final c = code.trim().toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(c)) return '';
  return String.fromCharCodes([for (final r in c.codeUnits) 0x1F1E6 + r - 0x41]);
}

/// What the exit check found about one node.
class NodeExit {
  const NodeExit(this.ip, this.country, this.at);

  /// The exit IP.
  final String ip;

  /// ISO code of the last country the check named for this node ('' = never named).
  final String country;

  /// When the node was checked last, ms since epoch.
  final int at;

  Map<String, dynamic> toJson() => {'ip': ip, 'country': country, 'at': at};
}

class ExitBook {
  ExitBook({this.keepFor = const Duration(days: 90), this.cap = 5000});

  /// How long a node nobody has checked stays (a subscription's node that left the plans).
  final Duration keepFor;

  /// The most nodes kept: the oldest checks go first.
  final int cap;

  /// Called when something worth keeping changed ([ExitBookStore]).
  void Function()? onChange;

  final _nodes = <String, NodeExit>{};

  int get length => _nodes.length;
  NodeExit? operator [](String id) => _nodes[id];

  /// The ISO code of the last country the exit check named for [id]; '' = unknown.
  String countryOf(String id) => _nodes[id]?.country ?? '';

  /// An exit check through node [id] answered with [ip] and, maybe, a [country]. A check that names no country
  /// keeps the last one named earlier (the geo services all missed this time; the IP is still the fresh fact).
  void record(String id, {required String ip, String? country, required int at}) {
    final c = (country ?? '').trim().toUpperCase(), had = _nodes[id];
    final code = RegExp(r'^[A-Z]{2}$').hasMatch(c) ? c : had?.country ?? '';
    _nodes[id] = NodeExit(ip, code, at);
    onChange?.call();
  }

  /// Forgets the nodes not checked for [keepFor] and, over [cap], the oldest. True when some went.
  bool prune(int now) {
    final n = _nodes.length, cut = now - keepFor.inMilliseconds;
    _nodes.removeWhere((_, v) => v.at < cut);
    if (_nodes.length > cap) {
      final old = _nodes.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in old.take(_nodes.length - cap)) {
        _nodes.remove(e.key);
      }
    }
    return _nodes.length != n;
  }

  /// Takes what [toJson] kept ([ExitBookStore.load]); unreadable entries and the ones older than [keepFor] are left out.
  /// Returns how many nodes it took.
  int load(Object? json, int now) {
    if (json is! List) return 0;
    final cut = now - keepFor.inMilliseconds;
    var taken = 0;
    for (final e in json) {
      if (e is! Map || e['id'] is! String || e['ip'] is! String || e['at'] is! num) continue;
      final at = (e['at'] as num).toInt();
      if (at < cut) continue;
      final c = '${e['country'] ?? ''}';
      _nodes[e['id'] as String] = NodeExit(e['ip'] as String, RegExp(r'^[A-Z]{2}$').hasMatch(c) ? c : '', at);
      taken++;
    }
    return taken;
  }

  /// `[{id, ip, country, at}]`.
  List<Map<String, dynamic>> toJson() => [
        for (final e in _nodes.entries) {'id': e.key, ...e.value.toJson()},
      ];
}

/// Keeps the book in a file (`<dataDir>/exit-nodes.json`): written a moment after it changed (one write for a burst
/// of checks), read at the start. The same shape as the dead ladder's store (ladder.dart).
class ExitBookStore {
  ExitBookStore(this.file, this.book, {int Function()? clock, this.debounce = const Duration(seconds: 2)})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    book.onChange = _changed;
  }

  final File file;
  final ExitBook book;
  final Duration debounce;
  final int Function() _clock;
  Timer? _timer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Reads the file (none / damaged = an empty book); returns how many nodes were taken.
  int load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      return book.load(j is Map ? j['nodes'] : null, _clock());
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
      book.prune(_clock());
      await writeFileDurable(file, jsonEncode({'v': 1, 'nodes': book.toJson()}));
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
