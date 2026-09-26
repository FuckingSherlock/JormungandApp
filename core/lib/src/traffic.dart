/// Live traffic of the running sing-box, shaped for the UI: totals, speed and every open
/// connection with the server it really goes through.
///
/// sing-box's clash API gives byte counters only (`/connections`) and names just the
/// group a connection went to (`chains: ["proxy"]`); the server is the group's `now` in
/// `/proxies`. Speeds are counter deltas between two samples, so any poll rate works.
library;

class TrafficMeter {
  int? _at;
  int _down = 0, _up = 0;
  Map<String, (int, int)> _conns = {};

  /// [conns] = clash `/connections`, [proxies] = clash `/proxies` (may be null),
  /// [nowMs] = sample time. Result:
  /// `{down, up (B/s), downTotal, upTotal, tcp, udp,
  ///   conns: [{id, host, port, net, rule, out: [tag…], process, down, up, downRate, upRate, start}]}`
  /// `out` lists the real outbounds, exit first: `route<i>/<key>` then
  /// `route<i>-entry/<key>` for a chain (plan.dart); a rule target `<target>/<key>` then
  /// `<target>>entry/<key>` (routing.dart); or `direct`.
  Map<String, dynamic> sample(Map<String, dynamic> conns, Map<String, dynamic>? proxies, int nowMs) {
    final down = (conns['downloadTotal'] as num?)?.toInt() ?? 0;
    final up = (conns['uploadTotal'] as num?)?.toInt() ?? 0;
    final prevAt = _at;
    final dt = prevAt == null ? 0 : (nowMs - prevAt) / 1000;
    // counters restart with sing-box: a drop means a new run, not negative speed
    int rate(int now, int before) => dt <= 0 || now < before ? 0 : ((now - before) / dt).round();

    final byName = ((proxies?['proxies'] as Map?) ?? const {}).cast<String, dynamic>();
    String resolve(String tag) {
      for (var i = 0; i < 8; i++) {
        final now = (byName[tag] as Map?)?['now'];
        if (now is! String || now.isEmpty) break;
        tag = now;
      }
      return tag;
    }

    final list = <Map<String, dynamic>>[];
    final seen = <String, (int, int)>{};
    var tcp = 0, udp = 0;
    for (final c in ((conns['connections'] as List?) ?? const []).cast<Map>()) {
      final id = '${c['id']}';
      final m = ((c['metadata'] as Map?) ?? const {}).cast<String, dynamic>();
      final cd = (c['download'] as num?)?.toInt() ?? 0;
      final cu = (c['upload'] as num?)?.toInt() ?? 0;
      final before = _conns[id];
      seen[id] = (cd, cu);
      final net = '${m['network'] ?? 'tcp'}';
      net == 'udp' ? udp++ : tcp++;
      final chains = ((c['chains'] as List?) ?? const []).map((e) => '$e').toList();
      // chains = the server, then the groups it was picked by: all resolve to the server
      final out = {for (final t in chains) resolve(t)}.toList();
      // a chain's exit (`route1/…`, a rule target's `chain:c/…`) dials through its entry
      // group (`route1-entry`, `chain:c>entry`): show where it enters too
      final slash = out.isEmpty ? -1 : out.first.indexOf('/');
      final group = slash > 0 ? out.first.substring(0, slash) : '';
      final entry = ['$group-entry', '$group>entry'].where(byName.containsKey).firstOrNull;
      if (slash > 0 && entry != null) out.add(resolve(entry));
      final host = '${m['host'] ?? ''}';
      list.add({
        'id': id,
        'host': host.isNotEmpty ? host : '${m['destinationIP'] ?? ''}',
        'port': '${m['destinationPort'] ?? ''}',
        'net': net,
        'rule': '${c['rule'] ?? ''}',
        'out': out,
        'process': '${m['processPath'] ?? ''}',
        'down': cd,
        'up': cu,
        // a connection new since the last sample moved all its bytes within dt
        'downRate': rate(cd, before?.$1 ?? 0),
        'upRate': rate(cu, before?.$2 ?? 0),
        'start': '${c['start'] ?? ''}',
      });
    }
    final result = {
      'down': rate(down, _down),
      'up': rate(up, _up),
      'downTotal': down,
      'upTotal': up,
      'tcp': tcp,
      'udp': udp,
      'conns': list,
    };
    _at = nowMs;
    _down = down;
    _up = up;
    _conns = seen;
    return result;
  }

  void reset() {
    _at = null;
    _down = _up = 0;
    _conns = {};
  }
}
