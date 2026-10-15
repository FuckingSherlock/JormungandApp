/// The one latency store of the app (`pingCache` in 15-ping.js), keyed by server variant:
/// `protocol://address:port#id` — a dead variant never looks alive because a sibling
/// answered, and one variant in two subscriptions shares one entry. A chain's exit is not
/// the same server through its entry as on its own, so those results live apart, in the
/// [PairBook] (key: entry's key `>` exit's key).
library;

import 'models.dart';

/// Freshness of a measure: older results are re-measured before use (`PING_FRESH_MS`).
const pingFreshMs = 5 * 60 * 1000;

/// One result: [ms] (`-1` = timeout; null while [testing] or never), [at] = when it was
/// measured (ms since epoch), [fails] = timeouts in a row (Auto's `failAfter`).
class PingEntry {
  PingEntry({this.ms, this.testing = false, this.at = 0, this.fails = 0, this.was, this.byChecker = false});

  num? ms;

  /// The answer came only from a backup checker (the test URL missed, the server passes traffic): a weak
  /// answer, ranked after every strong one ([PingBook.rank]). Only meaningful with an answer ([ms] >= 0).
  bool byChecker;

  /// The [ms] from before the ping in flight went out: what stays when that ping fails to run
  /// at all ([PingBook.unmarkTesting]). Null outside a ping.
  num? was;

  /// A ping is in flight. The entry keeps [at] and [fails], so `knownDead` holds meanwhile.
  bool testing;
  num at;
  int fails;

  PingEntry copy() => PingEntry(ms: ms, testing: testing, at: at, fails: fails, was: was, byChecker: byChecker);

  /// Rank key of the entry: a strong answer by ms, a weak one after every strong one (by ms), unknown, dead last.
  double get rank {
    final v = ms;
    if (v == null) return 1e9;
    if (v < 0) return 2e9;
    return byChecker ? weakRankBase + v : v.toDouble();
  }
}

/// A weak answer ranks at this plus its ms: after any strong ms, before "not measured" (1e9).
const weakRankBase = 1e8;

/// `byChecker` as the stored / core map spells it (`weak` in `status.auto`, `byChecker` in the ping stream and the
/// snapshot): true only for an answer.
bool _weakOf(Map m, num ms) => ms >= 0 && (m['weak'] == true || m['byChecker'] == true);

Map<String, dynamic> _entryJson(PingEntry e) =>
    {'ms': e.ms, 'at': e.at, 'fails': e.fails, if (e.byChecker && e.ms! >= 0) 'byChecker': true};

class PingBook {
  PingBook({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  final Map<String, PingEntry> _m = {};

  int get now => _now();

  /// The server, any variant (`serverKey`).
  static String serverKey(CatalogNode n) => '${n.protocol}://${n.address}:${n.port}';

  /// The variant (`pingKey`).
  static String keyOf(CatalogNode n) => '${serverKey(n)}#${n.id}';

  PingEntry? entry(CatalogNode n) => _m[keyOf(n)];

  /// ms of the last result; null = never measured or a ping in flight (`ping(n)`).
  num? ping(CatalogNode n) => entry(n)?.ms;

  bool isAlive(CatalogNode n) {
    final v = ping(n);
    return v != null && v >= 0;
  }

  /// Batch / list order by the cache: strong answers by ms, then weak ones ([PingEntry.byChecker]) by ms, then never
  /// measured, dead last (`pingRank`).
  double rank(CatalogNode n) => entry(n)?.rank ?? 1e9;

  /// A finished measure (`setPing`): a timeout counts one more fail, an answer resets them. [byChecker]: the answer
  /// came only from a backup checker.
  void set(CatalogNode n, num ms, {bool byChecker = false}) {
    final prev = entry(n);
    _m[keyOf(n)] = PingEntry(ms: ms, at: _now(), fails: ms == -1 ? (prev?.fails ?? 0) + 1 : 0, byChecker: byChecker && ms >= 0);
  }

  /// A ping goes out (`pingNodes` before the request).
  void markTesting(Iterable<CatalogNode> nodes) {
    for (final n in nodes) {
      final e = entry(n)?.copy() ?? PingEntry();
      e.was = e.ms ?? e.was; // a second ping on the same node must not lose it
      e.ms = null; // [byChecker] stays with [was]: it comes back with it
      e.testing = true;
      _m[keyOf(n)] = e;
    }
  }

  /// A ping that could not run (no tester, an error of the call) measured nothing: the node
  /// goes back to what it had before [markTesting] — a value, or none when it never had one.
  /// Only an answer or a timeout replaces a value; a dash means "never pinged".
  void unmarkTesting(Iterable<CatalogNode> nodes) {
    for (final n in nodes) {
      final e = entry(n);
      if (e == null || !e.testing) continue;
      if (e.was == null) {
        _m.remove(keyOf(n));
      } else {
        _m[keyOf(n)] = PingEntry(ms: e.was, at: e.at, fails: e.fails, byChecker: e.byChecker);
      }
    }
  }

  /// Sets an entry as it is (stored results, tests).
  void put(CatalogNode n, PingEntry e) => _m[keyOf(n)] = e;

  void remove(CatalogNode n) => _m.remove(keyOf(n));
  bool get anyTesting => _m.values.any((e) => e.testing);
  Iterable<String> get keys => _m.keys;
  void clear() => _m.clear();

  /// The core's own checks (`status.auto.members`: `{key: 'sid::nid', ms, at, fails, weak?}`; `weak` = answered only by
  /// a backup checker) land here: newer ones only, a ping in flight wins (`mergeCorePings`). True when changed.
  bool mergeCore(Iterable<Map> members, CatalogNode? Function(String key) nodeOfKey) {
    var changed = false;
    for (final m in members) {
      final n = nodeOfKey('${m['key']}');
      final ms = m['ms'], at = m['at'];
      final e = n == null ? null : entry(n);
      if (n == null || ms is! num || ms < -1 || (e != null && (e.testing || e.at >= (at is num ? at : 0)))) continue;
      _m[keyOf(n)] = PingEntry(
          ms: ms, at: at is num ? at : 0, fails: m['fails'] is num ? (m['fails'] as num).toInt() : 0, byChecker: _weakOf(m, ms));
      changed = true;
    }
    return changed;
  }

  /// `snapshot.pings`: `[[key, {ms, at, fails, byChecker?}], …]`, measured results only.
  List<dynamic> toJson() => [
        for (final e in _m.entries)
          if (!e.value.testing && e.value.ms != null) [e.key, _entryJson(e.value)],
      ];

  /// Loads stored results (`restorePings`): a key from before the per-variant key
  /// (`protocol://address:port`) goes to its node only when that server has exactly one
  /// variant among [all] (nodes and gone ones); its `-1` counts as one timeout.
  void restore(Object? list, Iterable<CatalogNode> all) {
    _m.clear();
    final variants = <String, Set<String>>{};
    for (final n in all) {
      variants.putIfAbsent(serverKey(n), () => {}).add(keyOf(n));
    }
    if (list is! List) return;
    for (final item in list) {
      if (item is! List || item.length < 2 || item[0] is! String || item[1] is! Map) continue;
      final k = item[0] as String, e = item[1] as Map;
      final ms = e['ms'];
      if (ms is! num) continue;
      final fails = e['fails'] is num ? (e['fails'] as num).toInt() : (ms == -1 ? 1 : 0);
      final entry = PingEntry(ms: ms, at: e['at'] is num ? e['at'] as num : 0, fails: fails, byChecker: _weakOf(e, ms));
      if (k.contains('#')) {
        _m[k] = entry;
        continue;
      }
      final v = variants[k];
      if (v != null && v.length == 1 && !_m.containsKey(v.first)) _m[v.first] = entry;
    }
  }
}

/// Latency of a chain's exit measured through one of its entry servers (the whole chain's
/// round trip): the same fields as [PingBook], keyed by the pair `pingKey(entry) > pingKey(exit)`.
/// Kept in the snapshot as `pairs` (`[[key, {ms, at, fails, byChecker?}], …]`).
class PairBook {
  final Map<String, PingEntry> _m = {};

  static String keyOf(CatalogNode entry, CatalogNode exit) => '${PingBook.keyOf(entry)}>${PingBook.keyOf(exit)}';

  PingEntry? entry(CatalogNode entry, CatalogNode exit) => _m[keyOf(entry, exit)];

  /// ms of the last result; null = never measured or a ping in flight.
  num? ping(CatalogNode entry, CatalogNode exit) => this.entry(entry, exit)?.ms;

  bool isAlive(CatalogNode entry, CatalogNode exit) {
    final v = ping(entry, exit);
    return v != null && v >= 0;
  }

  /// A finished measure: a timeout counts one more fail, an answer resets them. [at] is the
  /// time of the measure (ms since epoch). [byChecker]: the answer came only from a backup checker ([PingEntry.byChecker]).
  void set(CatalogNode entry, CatalogNode exit, num ms, int at, {bool byChecker = false}) {
    final prev = this.entry(entry, exit);
    _m[keyOf(entry, exit)] = PingEntry(ms: ms, at: at, fails: ms == -1 ? (prev?.fails ?? 0) + 1 : 0, byChecker: byChecker && ms >= 0);
  }

  /// Pings of [exits] through [entry] go out.
  void markTesting(CatalogNode entry, Iterable<CatalogNode> exits) {
    for (final x in exits) {
      final e = this.entry(entry, x)?.copy() ?? PingEntry();
      e.was = e.ms ?? e.was;
      e.ms = null;
      e.testing = true;
      _m[keyOf(entry, x)] = e;
    }
  }

  /// A ping that could not run: the pair goes back to what it had ([PingBook.unmarkTesting]).
  void unmarkTesting(CatalogNode entry, Iterable<CatalogNode> exits) {
    for (final x in exits) {
      final e = this.entry(entry, x);
      if (e == null || !e.testing) continue;
      if (e.was == null) {
        _m.remove(keyOf(entry, x));
      } else {
        _m[keyOf(entry, x)] = PingEntry(ms: e.was, at: e.at, fails: e.fails, byChecker: e.byChecker);
      }
    }
  }

  void put(CatalogNode entry, CatalogNode exit, PingEntry e) => _m[keyOf(entry, exit)] = e;
  void remove(CatalogNode entry, CatalogNode exit) => _m.remove(keyOf(entry, exit));
  bool get anyTesting => _m.values.any((e) => e.testing);
  Iterable<String> get keys => _m.keys;
  void clear() => _m.clear();

  /// The core's own pair checks (`status.auto.pairs`: `{entry, key: 'sid::nid', ms, at, fails, weak?}`; `weak` =
  /// answered only by a backup checker) land here: newer ones only, a ping in flight wins. True when changed.
  bool mergeCore(Iterable<Map> pairs, CatalogNode? Function(String key) nodeOfKey) {
    var changed = false;
    for (final m in pairs) {
      final a = nodeOfKey('${m['entry']}'), b = nodeOfKey('${m['key']}');
      final ms = m['ms'], at = m['at'];
      final e = a == null || b == null ? null : entry(a, b);
      if (a == null || b == null || ms is! num || ms < -1 || (e != null && (e.testing || e.at >= (at is num ? at : 0)))) continue;
      _m[keyOf(a, b)] = PingEntry(
          ms: ms, at: at is num ? at : 0, fails: m['fails'] is num ? (m['fails'] as num).toInt() : 0, byChecker: _weakOf(m, ms));
      changed = true;
    }
    return changed;
  }

  List<dynamic> toJson() => [
        for (final e in _m.entries)
          if (!e.value.testing && e.value.ms != null) [e.key, _entryJson(e.value)],
      ];

  void restore(Object? list) {
    _m.clear();
    if (list is! List) return;
    for (final item in list) {
      if (item is! List || item.length < 2 || item[0] is! String || item[1] is! Map) continue;
      final e = item[1] as Map, ms = e['ms'];
      if (ms is! num) continue;
      _m[item[0] as String] = PingEntry(
          ms: ms,
          at: e['at'] is num ? e['at'] as num : 0,
          fails: e['fails'] is num ? (e['fails'] as num).toInt() : (ms == -1 ? 1 : 0),
          byChecker: _weakOf(e, ms));
    }
  }
}
