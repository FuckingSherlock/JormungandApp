/// Which rules catch a host (and port): the matcher behind "the rules that would catch a site"
/// (`rulesCatching`, port of `design/src/js/40-rules.js`). A light judge: a rule it cannot decide
/// from host and port alone is left out, so it can miss a rule, never invent one.
library;

import 'catalog.dart';
import 'json_util.dart';
import 'rules_model.dart';

/// The private networks of the `ip_is_private` flag of an IP card.
const _privateNets = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16'];

/// The fields a card can judge from host and port, by card key. Any other field the card holds
/// (geosite, rule set, GeoIP, source, network, process) makes the card undecidable.
const _judged = <String, Set<String>>{
  'domain': {'domain', 'domain_suffix', 'domain_keyword', 'domain_regex'},
  'ip': {'ip_cidr'},
  'port': {'port'},
};

final _octet = RegExp(r'^\d{1,3}$');
final _portValue = RegExp(r'^(\d+)(?:-(\d+))?$');

/// Does [r] catch [host] (on [port])? True only when the rule is enabled, not a composite, has
/// condition groups, and every group can be judged from host and port and matches. Without a
/// [port] a port group cannot be judged, so the rule is false.
bool ruleCatches(UserRule r, String host, {int? port}) {
  final groups = r.groups;
  if (!r.enabled || r.composite != null || groups == null || groups.isEmpty) return false;
  final t = _Target(host, port);
  for (final e in groups.entries) {
    if (e.value is! Map) return false;
    if (_groupResult(e.key, asJson(e.value), t) != true) return false;
  }
  return true;
}

/// The ids of the rules that catch [host] (on [port]): of [app]'s rules in their order when [app]
/// is given, else of the own rules in `ruleOrder`.
List<String> rulesCatching(Catalog cat, String host, {int? port, String? app}) {
  final rules = app != null
      ? [...?cat.appRules[app]?.rules]
      : [for (final id in cat.ruleOrder) ?cat.rulesData[id]];
  return [for (final r in rules) if (ruleCatches(r, host, port: port)) r.id];
}

/// What the matcher knows of the address: the lower-case [host], its IPv4 value when it is an IPv4
/// literal ([ip4]), and the [port] when given.
class _Target {
  _Target(String host, this.port)
      : host = host.toLowerCase(),
        ip4 = _v4(host.toLowerCase());

  final String host;
  final int? port;
  final int? ip4;

  bool get ip => ip4 != null;
}

/// A card's result for [t]: true / false, or null when it cannot be judged from host and port.
bool? _groupResult(String key, Json g, _Target t) {
  final judged = _judged[key];
  final v = _values(g);
  if (judged == null || v.keys.any((f) => !judged.contains(f))) return null;
  final flag = truthy(g['flag']);
  final bool? m = switch (key) {
    'domain' => t.ip ? (v.isEmpty ? false : null) : _domainHits(t.host, v),
    'ip' => t.ip4 == null
        ? (v.isEmpty && !flag ? false : null)
        : _ipHits(t.ip4!, v['ip_cidr'] ?? const [], flag),
    'port' => t.port == null
        ? (v.isEmpty ? false : null)
        : (v['port'] ?? const <String>[]).any((x) => _inPort(t.port!, x)),
    _ => null,
  };
  if (m == null) return null;
  return truthy(g['not']) ? !m : m;
}

/// The non-empty values of a card, by field (trimmed; a field with none is dropped).
Map<String, List<String>> _values(Json g) {
  final out = <String, List<String>>{};
  for (final e in asJson(g['v']).entries) {
    final xs = [for (final x in strList(e.value)) if (x.trim().isNotEmpty) x.trim()];
    if (xs.isNotEmpty) out[e.key] = xs;
  }
  return out;
}

bool _onDomain(String host, String d) => d.isNotEmpty && (host == d || host.endsWith('.$d'));

bool _domainHits(String host, Map<String, List<String>> v) {
  bool hits(String field, bool Function(String) hit) => (v[field] ?? const <String>[]).any(hit);
  return hits('domain', (x) {
        final d = x.toLowerCase();
        return d.startsWith('*.') ? _onDomain(host, d.substring(2)) : host == d;
      }) ||
      hits('domain_suffix', (x) => _onDomain(host, x.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))) ||
      hits('domain_keyword', (x) => host.contains(x.toLowerCase())) ||
      hits('domain_regex', (x) => _regexHits(x, host));
}

bool _regexHits(String pattern, String host) {
  try {
    return RegExp(pattern).hasMatch(host);
  } on FormatException {
    return false;
  }
}

bool _ipHits(int ip, List<String> cidrs, bool flag) =>
    cidrs.any((c) => _inIp(ip, c)) || (flag && _privateNets.any((c) => _inIp(ip, c)));

/// An IPv4 address as a number, null when [s] is not one.
int? _v4(String s) {
  final p = s.split('.');
  if (p.length != 4) return null;
  var n = 0;
  for (final o in p) {
    final x = _octet.hasMatch(o) ? int.parse(o) : 256;
    if (x > 255) return null;
    n = n * 256 + x;
  }
  return n;
}

/// [ip] (an IPv4 number) is in [v]: an address, a CIDR (`a.b.c.d/p`) or a range (`a-b`). IPv6 values
/// never match.
bool _inIp(int ip, String v) {
  final s = v.trim();
  if (s.contains(':')) return false;
  final r = s.split('-');
  if (r.length == 2) {
    final a = _v4(r[0].trim()), b = _v4(r[1].trim());
    return a != null && b != null && ip >= a && ip <= b;
  }
  final c = s.split('/');
  final base = c.length <= 2 ? _v4(c[0]) : null;
  final bits = c.length > 1 ? int.tryParse(c[1]) : 32;
  if (base == null || bits == null || bits < 0 || bits > 32) return false;
  final size = 1 << (32 - bits);
  return ip ~/ size == base ~/ size;
}

/// A port value (`443` or `8000-9000`) holds [port].
bool _inPort(int port, String v) {
  final m = _portValue.firstMatch(v.trim());
  if (m == null) return false;
  final a = int.tryParse(m[1]!), b = m[2] == null ? a : int.tryParse(m[2]!);
  return a != null && b != null && port >= a && port <= b;
}
