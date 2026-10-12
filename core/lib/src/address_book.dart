import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'durable.dart';

// The last known addresses of the hostnames the config needs (proxy servers, DoH / DoT servers named by a
// host): what the core resolved itself (address_resolver.dart) so that the config can hold the IP and the
// name stays only where the protocol needs it (address_pin.dart). One file, `<dataDir>/addresses.json`,
// written atomically; an old entry is still used (a stale address beats none) until it is [maxAge] old.

/// One hostname: its addresses as the resolver last saw them, the time, who answered, and which one the
/// config uses now.
class AddressEntry {
  AddressEntry({
    required this.v4,
    required this.v6,
    required this.at,
    required this.ttl,
    required this.via,
    this.with6 = false,
    this.cursor = 0,
  });

  /// IPv4 and IPv6 addresses in the order the answer gave them.
  final List<String> v4, v6;

  /// When it was resolved (ms since epoch) and the smallest TTL of the answer (s).
  final int at, ttl;

  /// Who answered: a candidate id (`cloudflare-doh1`), `udp:…`, `system`.
  final String via;

  /// AAAA was asked for as well (the IPv6 setting was on): an entry resolved without it knows nothing about v6.
  final bool with6;

  /// Which of [ips] the config uses; moved to the next one when the node does not answer on this one.
  int cursor;

  /// The addresses a config may use: IPv4 first, IPv6 after them when [ipv6] is on.
  List<String> ips(bool ipv6) => [...v4, if (ipv6) ...v6];

  /// The address the config holds; null when there is none for this IPv6 setting.
  String? pick(bool ipv6) {
    final l = ips(ipv6);
    return l.isEmpty ? null : l[cursor.clamp(0, l.length - 1)];
  }

  /// The same set of addresses (order does not matter).
  bool sameSet(AddressEntry o) => _same(v4, o.v4) && _same(v6, o.v6);

  static bool _same(List<String> a, List<String> b) => a.length == b.length && a.toSet().containsAll(b);

  Map<String, dynamic> toJson() => {'v4': v4, 'v6': v6, 'at': at, 'ttl': ttl, 'via': via, 'with6': with6, 'cursor': cursor};

  static AddressEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    List<String> l(Object? x) => x is List ? [for (final e in x) '$e'] : const [];
    final v4 = l(j['v4']), v6 = l(j['v6']);
    if (v4.isEmpty && v6.isEmpty) return null;
    return AddressEntry(
      v4: v4,
      v6: v6,
      at: (j['at'] as num?)?.toInt() ?? 0,
      ttl: (j['ttl'] as num?)?.toInt() ?? 0,
      via: '${j['via'] ?? ''}',
      with6: j['with6'] == true,
      cursor: (j['cursor'] as num?)?.toInt() ?? 0,
    );
  }
}

class AddressBook {
  AddressBook(this.file, {DateTime Function()? now, this.maxAge = const Duration(days: 30), this.minFresh = const Duration(minutes: 10), this.maxFresh = const Duration(hours: 6)})
      : _now = now ?? DateTime.now {
    _load();
  }

  final File file;
  final DateTime Function() _now;

  /// An entry older than this is forgotten.
  final Duration maxAge;

  /// How long an answer counts as fresh: its TTL, within these bounds.
  final Duration minFresh, maxFresh;
  final _m = <String, AddressEntry>{};

  static String key(String host) => host.trim().toLowerCase();

  int get length => _m.length;

  /// The entry of [host]; one older than [maxAge] is forgotten.
  AddressEntry? get(String host) {
    final e = _m[key(host)];
    if (e == null) return null;
    if (_now().millisecondsSinceEpoch - e.at > maxAge.inMilliseconds) {
      _m.remove(key(host));
      return null;
    }
    return e;
  }

  Iterable<String> get hosts => _m.keys;

  /// Fresh = younger than its TTL (kept between [minFresh] and [maxFresh]). A stale entry is still used by a
  /// config and is refreshed in the background.
  bool fresh(String host) {
    final e = get(host);
    if (e == null) return false;
    final ttl = (e.ttl * 1000).clamp(minFresh.inMilliseconds, maxFresh.inMilliseconds);
    return _now().millisecondsSinceEpoch - e.at < ttl;
  }

  void put(String host, AddressEntry e) {
    _m[key(host)] = e;
    save();
  }

  /// Moves the cursor of [host] to [i] (the config uses another address of the same entry).
  void setCursor(String host, int i) {
    final e = get(host);
    if (e == null) return;
    e.cursor = max(0, i);
    save();
  }

  void remove(String host) {
    if (_m.remove(key(host)) != null) save();
  }

  void _load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      final hosts = j is Map ? j['hosts'] : null;
      if (hosts is! Map) return;
      final cutoff = _now().millisecondsSinceEpoch - maxAge.inMilliseconds;
      for (final e in hosts.entries) {
        final v = AddressEntry.fromJson(e.value);
        if (v != null && v.at >= cutoff) _m['${e.key}'] = v;
      }
    } catch (_) {} // no file yet, or a damaged one: the book starts empty and fills again
  }

  /// The addresses are a cache: a write that fails costs a lookup later, never a connect.
  void save() {
    try {
      file.parent.createSync(recursive: true);
      writeFileDurableSync(file, jsonEncode({'v': 1, 'hosts': {for (final e in _m.entries) e.key: e.value.toJson()}}));
    } catch (_) {}
  }
}
