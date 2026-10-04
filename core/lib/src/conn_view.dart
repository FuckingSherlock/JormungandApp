/// The Live connections list as the UI shows it: the connections of `traffic()['conns']`
/// (traffic.dart) filtered, sorted and grouped. The Dart port of design/src/js/76-conns.js.
///
/// Pure data: names of servers (`direct`, `route0/sid::nid`) and every text stay with the UI,
/// which hands in [ConnView.via] (an exit tag → its readable name) where the search needs them.
library;

import 'routing.dart' show services, serviceTitles;

/// One open connection (`traffic()['conns']` item).
class LiveConn {
  LiveConn({
    required this.id,
    required this.host,
    required this.port,
    required this.net,
    required this.rule,
    required this.ruleName,
    required this.ruleKind,
    required this.ruleId,
    required this.out,
    required this.process,
    required this.down,
    required this.up,
    required this.downRate,
    required this.upRate,
    required this.start,
  });

  factory LiveConn.fromJson(Map m) => LiveConn(
    id: '${m['id']}',
    host: '${m['host'] ?? ''}',
    port: '${m['port'] ?? ''}' == '0' ? '' : '${m['port'] ?? ''}',
    net: '${m['net'] ?? 'tcp'}',
    rule: '${m['rule'] ?? ''}',
    ruleName: '${m['ruleName'] ?? ''}',
    ruleKind: '${m['ruleKind'] ?? ''}',
    ruleId: '${m['ruleId'] ?? ''}',
    out: [for (final t in (m['out'] as List? ?? const [])) '$t'],
    process: '${m['process'] ?? ''}',
    down: (m['down'] as num?) ?? 0,
    up: (m['up'] as num?) ?? 0,
    downRate: (m['downRate'] as num?) ?? 0,
    upRate: (m['upRate'] as num?) ?? 0,
    start: DateTime.tryParse('${m['start'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String id, host, port, net, rule, ruleName, ruleKind, ruleId, process;
  final List<String> out;
  final num down, up, downRate, upRate;
  final DateTime start;

  /// The file name of the process path ('' = unknown).
  String get app => process.isEmpty ? '' : process.split(RegExp(r'[\\/]')).last;

  /// sing-box's own text of the rule ('' for the final route).
  String get raw => rule.isNotEmpty && rule != 'final' ? rule : '';

  /// The user's name of the rule; '' = the default / final route; a rule the core could not
  /// name = its raw text.
  String get ruleLabel => ruleKind == 'final' || (ruleKind.isEmpty && raw.isEmpty) ? '' : (ruleName.isNotEmpty ? ruleName : raw);

  bool get isIp => connIsIp(host);

  /// The exit tag (`direct` when the list is empty).
  String get exit => out.isEmpty ? 'direct' : out.first;
}

bool connIsIp(String h) => RegExp(r'^[\d.]+$').hasMatch(h) || h.contains(':');

const _sld = {'co', 'com', 'net', 'org', 'gov', 'edu', 'ac'}; // under a two-letter country domain: bbc.co.uk

/// The registrable domain of a host (a rough one: the last two labels, three under `co.uk`).
String connDomain(String h) {
  final p = h.split('.');
  if (p.length <= 2) return h;
  final three = p.length >= 3 && p.last.length == 2 && _sld.contains(p[p.length - 2]);
  return p.sublist(p.length - (three ? 3 : 2)).join('.');
}

/// A service's addresses that no domain shows (a client that connects by IP).
const serviceCidrs = <String, List<String>>{
  'telegram': ['149.154.160.0/20', '91.108.4.0/22', '91.108.8.0/22', '91.108.12.0/22', '91.108.16.0/22', '91.108.56.0/22', '185.76.151.0/24'],
};

/// The packages of the per-app rules that belong to a service (Rules → Services).
const serviceApps = <String, List<String>>{
  'telegram': ['org.telegram.messenger'],
  'youtube': ['com.google.android.youtube'],
  'discord': ['com.discord'],
  'netflix': ['com.netflix.mediaclient'],
  'spotify': ['com.spotify.music'],
  'chatgpt': ['com.openai.chatgpt'],
  'instagram': ['com.instagram.android'],
  'x': ['com.twitter.android'],
};

/// The service key an app package belongs to, or null.
String? serviceOfApp(String pkg) {
  for (final e in serviceApps.entries) {
    if (e.value.contains(pkg)) return e.key;
  }
  return null;
}

int? _ip4(String s) {
  final p = s.split('.');
  if (p.length != 4) return null;
  var n = 0;
  for (final o in p) {
    final v = int.tryParse(o);
    if (v == null || v < 0 || v > 255) return null;
    n = n * 256 + v;
  }
  return n;
}

/// [ip] (IPv4) is inside [cidr] (`a.b.c.d/p`).
bool inCidr4(String ip, String cidr) {
  final parts = cidr.split('/');
  final a = _ip4(ip), b = _ip4(parts[0]);
  if (a == null || b == null) return false;
  final p = parts.length > 1 ? int.tryParse(parts[1]) ?? 32 : 32;
  final size = 1 << (32 - p);
  return a ~/ size == b ~/ size;
}

bool _onDomain(String host, String d) => host == d || host.endsWith('.$d');

/// The known service (a [services] key) a connection belongs to: the rule that caught it, else its host.
String? connService(LiveConn c) {
  if (c.ruleKind == 'service' && services.containsKey(c.ruleId)) return c.ruleId;
  if (c.ruleKind == 'app') {
    final s = serviceOfApp(c.ruleId);
    if (s != null) return s;
  }
  final h = c.host.toLowerCase();
  if (connIsIp(h)) {
    if (h.contains(':')) return null;
    for (final k in services.keys) {
      if ((serviceCidrs[k] ?? const []).any((x) => inCidr4(h, x))) return k;
    }
    return null;
  }
  for (final e in services.entries) {
    if (e.value.domains.any((d) => _onDomain(h, d))) return e.key;
  }
  return null;
}

enum ConnSort {
  newest,
  downSpeed,
  upSpeed,
  downloaded,
  uploaded,
  duration;

  int compare(LiveConn a, LiveConn b) => switch (this) {
    ConnSort.newest => b.start.compareTo(a.start),
    ConnSort.downSpeed => b.downRate.compareTo(a.downRate),
    ConnSort.upSpeed => b.upRate.compareTo(a.upRate),
    ConnSort.downloaded => b.down.compareTo(a.down),
    ConnSort.uploaded => b.up.compareTo(a.up),
    ConnSort.duration => a.start.compareTo(b.start),
  };
}

enum ConnGroupBy { service, app, none }

/// The filter sections, in the order of the sheet.
enum ConnSection {
  net,
  app,
  rule,
  exit,
  host;

  /// The values of a connection in this section (the raw value, the label is the UI's).
  List<String> valuesOf(LiveConn c) => switch (this) {
    ConnSection.net => [c.net],
    ConnSection.app => [c.app],
    ConnSection.rule => [c.ruleLabel],
    ConnSection.exit => [c.exit],
    ConnSection.host => [c.host],
  };
}

/// The selected values per section: OR inside a section, AND across sections.
class ConnFilter {
  ConnFilter([Map<ConnSection, Set<String>>? sel]) : sel = {for (final s in ConnSection.values) s: {...?sel?[s]}};

  final Map<ConnSection, Set<String>> sel;

  int get count => sel.values.fold(0, (n, s) => n + s.length);
  bool get isEmpty => count == 0;

  ConnFilter copy() => ConnFilter(sel);

  bool matches(LiveConn c) => ConnSection.values.every((s) {
    final want = sel[s]!;
    return want.isEmpty || s.valuesOf(c).any(want.contains);
  });

  /// Toggles one value (a draft being edited).
  void toggle(ConnSection s, String v) {
    if (!sel[s]!.remove(v)) sel[s]!.add(v);
  }

  void clear() {
    for (final s in sel.values) {
      s.clear();
    }
  }
}

/// A group of the grouped list: its rows, the summed speed and totals, its newest (or, for
/// [ConnSort.duration], oldest) start.
class ConnGroup {
  ConnGroup(this.key, this.name, this.start);

  final String key, name;
  final rows = <LiveConn>[];
  num downRate = 0, upRate = 0, down = 0, up = 0;
  DateTime start;
}

/// One value of a filter section with the number of connections that have it (0 = selected, none now).
class ConnValue {
  const ConnValue(this.value, this.count, [this.via = const []]);
  final String value;
  final int count;

  /// For the Exit section: the entries (readable routes) its connections come through.
  final List<String> via;
}

class ConnView {
  ConnView({
    this.sort = ConnSort.newest,
    this.group = ConnGroupBy.service,
    ConnFilter? filter,
    this.query = '',
  }) : filter = filter ?? ConnFilter();

  ConnSort sort;
  ConnGroupBy group;
  ConnFilter filter;
  String query;

  /// The route text of a connection for the search ("🇩🇪 Berlin → direct"), from the UI's names.
  String Function(LiveConn c)? via;

  /// The sort and group are not the defaults (the button is lit).
  bool get sortChanged => sort != ConnSort.newest || group != ConnGroupBy.service;

  bool matchesQuery(LiveConn c) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [c.host, c.process, c.ruleLabel.isEmpty ? 'default / final' : c.ruleLabel, c.raw, via?.call(c) ?? c.out.join(' ')]
        .any((v) => v.toLowerCase().contains(q));
  }

  /// The list as shown: filtered by the query and the sections, sorted.
  List<LiveConn> shown(Iterable<LiveConn> src) => [for (final c in src) if (matchesQuery(c) && filter.matches(c)) c]..sort(sort.compare);

  /// [list] (what [shown] returned) in groups; null = [ConnGroupBy.none]. A group sorts as one
  /// connection with the sums.
  List<ConnGroup>? groups(List<LiveConn> list) {
    if (group == ConnGroupBy.none) return null;
    final map = <String, ConnGroup>{}, oldest = sort == ConnSort.duration;
    for (final c in list) {
      final (key, name) = groupOf(c);
      final g = map.putIfAbsent(key, () => ConnGroup(key, name, c.start));
      g.rows.add(c);
      g.downRate += c.downRate;
      g.upRate += c.upRate;
      g.down += c.down;
      g.up += c.up;
      if (c.start.isBefore(g.start) == oldest) g.start = c.start;
    }
    int cmp(ConnGroup a, ConnGroup b) => switch (sort) {
      ConnSort.newest => b.start.compareTo(a.start),
      ConnSort.downSpeed => b.downRate.compareTo(a.downRate),
      ConnSort.upSpeed => b.upRate.compareTo(a.upRate),
      ConnSort.downloaded => b.down.compareTo(a.down),
      ConnSort.uploaded => b.up.compareTo(a.up),
      ConnSort.duration => a.start.compareTo(b.start),
    };
    return map.values.toList()..sort(cmp);
  }

  /// (key, name) of the group of [c]. A service's name is [serviceTitles]; 'Other' / 'Unknown'
  /// are returned as '' (the UI words them).
  (String, String) groupOf(LiveConn c) {
    final app = c.app;
    if (group == ConnGroupBy.app) return ('a:$app', app);
    final s = connService(c);
    if (s != null) return ('s:$s', serviceTitles[s] ?? s);
    if (!c.isIp) {
      final d = connDomain(c.host.toLowerCase());
      return ('d:$d', d);
    }
    return app.isNotEmpty ? ('a:$app', app) : ('o', '');
  }

  /// The values of [s] over [src] with their counts, most first; [selected] values with no
  /// connection are kept (0). [label] turns a value into the text the search matches.
  List<ConnValue> values(
    ConnSection s,
    Iterable<LiveConn> src,
    Set<String> selected, {
    required String Function(String v) label,
    String query = '',
    String Function(List<String> tags)? viaText,
  }) {
    final count = <String, int>{}, entry = <String, Set<String>>{};
    for (final c in src) {
      for (final v in s.valuesOf(c)) {
        count[v] = (count[v] ?? 0) + 1;
        if (s == ConnSection.exit && c.out.length > 1 && viaText != null) {
          (entry[v] ??= {}).add(viaText(c.out.sublist(1)));
        }
      }
    }
    for (final v in selected) {
      count.putIfAbsent(v, () => 0);
    }
    final q = query.trim().toLowerCase();
    final vals = [for (final e in count.entries) if (q.isEmpty || label(e.key).toLowerCase().contains(q)) e]
      ..sort((a, b) {
        final d = b.value.compareTo(a.value);
        return d != 0 ? d : label(a.key).compareTo(label(b.key));
      });
    return [for (final e in vals) ConnValue(e.key, e.value, [...?entry[e.key]])];
  }
}
