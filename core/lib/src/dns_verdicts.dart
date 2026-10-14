/// What the core last found out about each DNS server: dead or answering (docs/failures.md → Вердикт меняет только
/// повторная проверка, docs/rules.md §6). The failover (dns_failover.dart) keeps its judgment here, so a reconnect, a
/// change of the settings, a restart of the core or a provider switched off and on does not forget it: only a new check
/// of the same object changes a verdict.
///
/// The object is the server as the config makes it: address + transport + side (`https://dns.google/dns-query|doh|direct`);
/// on the VPN side the verdict is also bound to the node the check went through (the exit server's pool identity,
/// pool.dart [serverIdentity]): the same server may answer through one node and not through another.
/// Kept across a restart ([DnsVerdictStore], `<dataDir>/dns-verdicts.json`), the same shape as the exit book (exits.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';
import 'plan.dart' show planCurrent, planRoutes;
import 'pool.dart' show serverIdentity;
import 'routing.dart' show DnsCandidate;

/// The key of the object a verdict is about: [c]'s address, transport and side; on the VPN side also the exit [node] the
/// check went through ('' = not known). A null [c] is the OS resolver (`system`).
String dnsVerdictKey(DnsCandidate? c, String? node) {
  if (c == null) return 'system|system|direct';
  return '${c.addr}|${c.kind}|${c.side}${c.vpn ? '|${node ?? ''}' : ''}';
}

/// The exit node the VPN side is bound to at a connect, before Auto runs: the main group's node the plan starts on
/// (the pick of a priority group, else the first), as its pool identity (the same as Auto's `exitNode`). Null = none.
String? dnsPlanNode(Map<String, dynamic>? plan) {
  if (plan == null) return null;
  final rs = planRoutes(plan);
  if (rs.isEmpty) return null;
  final main = rs[planCurrent(plan, rs.length)]['main'];
  if (main is! Map) return null;
  final nodes = (main['nodes'] as List? ?? const []).whereType<Map>().toList();
  if (nodes.isEmpty) return null;
  final pick = nodes.where((n) => n['key'] == main['chosen']).firstOrNull ?? nodes.first;
  final o = pick['outbound'];
  return o is Map ? serverIdentity(o) : null;
}

/// One verdict: [dead] or answering, and when the check that made it ended (ms since epoch).
class DnsVerdict {
  const DnsVerdict(this.dead, this.at);
  final bool dead;
  final int at;
}

class DnsVerdictBook {
  DnsVerdictBook({this.keepFor = const Duration(days: 90), this.cap = 2000, this.refresh = const Duration(minutes: 10)});

  /// How long a verdict nobody re-checked stays (a server that left the settings).
  final Duration keepFor;

  /// The most verdicts kept: the oldest checks go first.
  final int cap;

  /// A re-check that changes nothing but its time is written to the file at most this often.
  final Duration refresh;

  /// Called when something worth keeping changed ([DnsVerdictStore]).
  void Function()? onChange;

  final _v = <String, DnsVerdict>{};

  int get length => _v.length;
  DnsVerdict? operator [](String key) => _v[key];

  /// True = dead, false = answers, null = never checked.
  bool? deadOf(String key) => _v[key]?.dead;

  /// A check of [key] ended: the object is [dead] or answers. Returns whether the verdict itself changed.
  bool record(String key, {required bool dead, required int at}) {
    final had = _v[key];
    _v[key] = DnsVerdict(dead, at);
    final flipped = had == null || had.dead != dead;
    if (flipped || at - had.at >= refresh.inMilliseconds) onChange?.call();
    return flipped;
  }

  /// Forgets the verdicts nobody checked for [keepFor] and, over [cap], the oldest. True when some went.
  bool prune(int now) {
    final n = _v.length, cut = now - keepFor.inMilliseconds;
    _v.removeWhere((_, v) => v.at < cut);
    if (_v.length > cap) {
      final old = _v.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in old.take(_v.length - cap)) {
        _v.remove(e.key);
      }
    }
    return _v.length != n;
  }

  /// Takes what [toJson] kept; unreadable and too old entries are left out. Returns how many it took.
  int load(Object? json, int now) {
    if (json is! List) return 0;
    final cut = now - keepFor.inMilliseconds;
    var taken = 0;
    for (final e in json) {
      if (e is! Map || e['key'] is! String || e['dead'] is! bool || e['at'] is! num) continue;
      final at = (e['at'] as num).toInt();
      if (at < cut) continue;
      _v[e['key'] as String] = DnsVerdict(e['dead'] as bool, at);
      taken++;
    }
    return taken;
  }

  /// `[{key, dead, at}]`.
  List<Map<String, dynamic>> toJson() => [
        for (final e in _v.entries) {'key': e.key, 'dead': e.value.dead, 'at': e.value.at},
      ];
}

/// The flag each DNS candidate starts with, by the verdicts of the last time (docs/rules.md §6 → Старт): a candidate stored
/// as dead starts off (it is checked at once, [DnsFailover.start]); a side answers with the best candidate that worked
/// last time, so the ones above it that were never checked start off too until they answer; the rest are on. [sides]: the
/// candidates of each side in priority order; [others]: candidates outside the sides (a rule's own), off only when dead.
/// [node]: the exit node the VPN side is bound to. Id → on.
Map<String, bool> dnsStartFlags(Map<String, List<DnsCandidate>> sides, DnsVerdictBook book, {String? node, List<DnsCandidate> others = const []}) {
  final out = <String, bool>{};
  for (final l in sides.values) {
    final best = l.indexWhere((c) => book.deadOf(dnsVerdictKey(c, node)) == false);
    for (var i = 0; i < l.length; i++) {
      final v = book.deadOf(dnsVerdictKey(l[i], node));
      out[l[i].id] = v == true ? false : !(v == null && best > i);
    }
  }
  for (final c in others) {
    out.putIfAbsent(c.id, () => book.deadOf(dnsVerdictKey(c, node)) != true);
  }
  return out;
}

/// Keeps the book in a file (`<dataDir>/dns-verdicts.json`): written a moment after it changed, read at the start.
class DnsVerdictStore {
  DnsVerdictStore(this.file, this.book, {int Function()? clock, this.debounce = const Duration(seconds: 2)})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    book.onChange = _changed;
  }

  final File file;
  final DnsVerdictBook book;
  final Duration debounce;
  final int Function() _clock;
  Timer? _timer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Reads the file (none / damaged = an empty book); returns how many verdicts were taken.
  int load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      return book.load(j is Map ? j['servers'] : null, _clock());
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
      await writeFileDurable(file, jsonEncode({'v': 1, 'servers': book.toJson()}));
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
