/// The sites the user asked to hear nothing about (Settings → Notifications → Ignored sites):
/// a dead site that some program keeps opening. The host and its subdomains: `example.com` also
/// covers `api.example.com`. Only what is shown is filtered (events, notifications, the raw log's
/// failed-connection lines); routing never looks at the list.
class IgnoredSites {
  IgnoredSites([Iterable<String> hosts = const []]) : hosts = normalize(hosts);

  static final empty = IgnoredSites();

  /// Lower case, no repeats, in the order given.
  final List<String> hosts;

  bool get isEmpty => hosts.isEmpty;

  /// What a host is kept as: lower case, without a scheme, path, port, a leading `*.` / dot and a
  /// trailing dot. Empty = not a host.
  static String clean(String raw) {
    var s = raw.trim().toLowerCase();
    final scheme = s.indexOf('://');
    if (scheme >= 0) s = s.substring(scheme + 3);
    final cut = s.indexOf(RegExp(r'[/?#]'));
    if (cut >= 0) s = s.substring(0, cut);
    final at = s.lastIndexOf('@');
    if (at >= 0) s = s.substring(at + 1);
    if (!s.startsWith('[') && s.indexOf(':') == s.lastIndexOf(':')) {
      final c = s.indexOf(':'); // a port
      if (c >= 0) s = s.substring(0, c);
    }
    while (s.startsWith('*.') || s.startsWith('.')) {
      s = s.startsWith('*.') ? s.substring(2) : s.substring(1);
    }
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    return RegExp(r'^[a-z0-9_\-.:\[\]]+$').hasMatch(s) ? s : '';
  }

  static List<String> normalize(Iterable<String> hosts) {
    final out = <String>[];
    for (final h in hosts) {
      final c = clean(h);
      if (c.isNotEmpty && !out.contains(c)) out.add(c);
    }
    return out;
  }

  /// [host] is an ignored one or a subdomain of it.
  bool matches(String host) {
    if (hosts.isEmpty) return false;
    final h = clean(host);
    return h.isNotEmpty && _hit(h);
  }

  bool _hit(String h) {
    for (final i in hosts) {
      if (h == i || h.endsWith('.$i')) return true;
    }
    return false;
  }

  static final _word = RegExp(r'[A-Za-z0-9_\-.]+');

  /// A line of the log (sing-box's or the core's) names an ignored host: any word of it that is one.
  /// `dial tcp: lookup dead.example.com: no such host`, `outbound connection to dead.example.com:443`.
  bool matchesText(String text) {
    if (hosts.isEmpty) return false;
    for (final m in _word.allMatches(text)) {
      var w = m[0]!.toLowerCase();
      while (w.endsWith('.')) {
        w = w.substring(0, w.length - 1);
      }
      if (w.isNotEmpty && _hit(w)) return true;
    }
    return false;
  }
}
