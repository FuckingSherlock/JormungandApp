/// The one latency store of the app (`pingCache` in 15-ping.js), keyed by server variant:
/// `protocol://address:port#id` — a dead variant never looks alive because a sibling
/// answered, and one variant in two subscriptions shares one entry.
library;

import 'models.dart';

/// Freshness of a measure: older results are re-measured before use (`PING_FRESH_MS`).
const pingFreshMs = 5 * 60 * 1000;

/// One result: [ms] (`-1` = timeout; null while [testing] or never), [at] = when it was
/// measured (ms since epoch), [fails] = timeouts in a row (Auto's `failAfter`).
class PingEntry {
  PingEntry({this.ms, this.testing = false, this.at = 0, this.fails = 0});

  num? ms;

  /// A ping is in flight. The entry keeps [at] and [fails], so `knownDead` holds meanwhile.
  bool testing;
  num at;
  int fails;

  PingEntry copy() => PingEntry(ms: ms, testing: testing, at: at, fails: fails);
}

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

  /// Batch / list order by the cache: alive by ms, then never measured, dead last (`pingRank`).
  double rank(CatalogNode n) {
    final v = ping(n);
    if (v == null) return 1e9;
    return v >= 0 ? v.toDouble() : 2e9;
  }

  /// A finished measure (`setPing`): a timeout counts one more fail, an answer resets them.
  void set(CatalogNode n, num ms) {
    final prev = entry(n);
    _m[keyOf(n)] = PingEntry(ms: ms, at: _now(), fails: ms == -1 ? (prev?.fails ?? 0) + 1 : 0);
  }

  /// A ping goes out (`pingNodes` before the request).
  void markTesting(Iterable<CatalogNode> nodes) {
    for (final n in nodes) {
      final e = entry(n)?.copy() ?? PingEntry();
      e.ms = null;
      e.testing = true;
      _m[keyOf(n)] = e;
    }
  }

  /// Sets an entry as it is (stored results, tests).
  void put(CatalogNode n, PingEntry e) => _m[keyOf(n)] = e;

  void remove(CatalogNode n) => _m.remove(keyOf(n));
  bool get anyTesting => _m.values.any((e) => e.testing);
  Iterable<String> get keys => _m.keys;
  void clear() => _m.clear();

  /// The core's own checks (`status.auto.members`: `{key: 'sid::nid', ms, at, fails}`) land
  /// here: newer ones only, a ping in flight wins (`mergeCorePings`). True when changed.
  bool mergeCore(Iterable<Map> members, CatalogNode? Function(String key) nodeOfKey) {
    var changed = false;
    for (final m in members) {
      final n = nodeOfKey('${m['key']}');
      final ms = m['ms'], at = m['at'];
      final e = n == null ? null : entry(n);
      if (n == null || ms is! num || ms < -1 || (e != null && (e.testing || e.at >= (at is num ? at : 0)))) continue;
      _m[keyOf(n)] = PingEntry(ms: ms, at: at is num ? at : 0, fails: m['fails'] is num ? (m['fails'] as num).toInt() : 0);
      changed = true;
    }
    return changed;
  }

  /// `snapshot.pings`: `[[key, {ms, at, fails}], …]`, measured results only.
  List<dynamic> toJson() => [
        for (final e in _m.entries)
          if (!e.value.testing && e.value.ms != null) [e.key, {'ms': e.value.ms, 'at': e.value.at, 'fails': e.value.fails}],
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
      final entry = PingEntry(ms: ms, at: e['at'] is num ? e['at'] as num : 0, fails: fails);
      if (k.contains('#')) {
        _m[k] = entry;
        continue;
      }
      final v = variants[k];
      if (v != null && v.length == 1 && !_m.containsKey(v.first)) _m[v.first] = entry;
    }
  }
}
