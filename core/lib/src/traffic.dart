/// Live traffic of the running sing-box, shaped for the UI: totals, speed and every open
/// connection with the server it really goes through.
///
/// All of it comes from the streams of sing-box's API service (sbapi.dart), kept up to
/// date by sing-box's pushes: status (speed over the last second, session totals — the
/// bytes of connections already closed included) and the connections table (each with
/// its server — the leaf outbound — its app and its own speed).
library;

import 'sbapi.dart';

/// `{down, up (B/s), downTotal, upTotal, tcp, udp,
///   conns: [{id, host, port, net, rule, out: [tag…], process, down, up, downRate, upRate, start}]}`
/// `out` lists the real outbounds, exit first: `route<i>/<key>` then `route<i>-entry/<key>`
/// for a chain (plan.dart); a rule target `<target>/<key>` then `<target>>entry/<key>`
/// (routing.dart); or `direct`.
Map<String, dynamic> trafficOf(SingBoxApi api) {
  final groups = api.groups;
  String resolve(String tag) {
    for (var i = 0; i < 8; i++) {
      final now = groups[tag]?.selected;
      if (now == null || now.isEmpty) break;
      tag = now;
    }
    return tag;
  }

  final list = <Map<String, dynamic>>[];
  var tcp = 0, udp = 0;
  for (final c in api.connections) {
    c.network == 'udp' ? udp++ : tcp++;
    final out = [c.outbound.isNotEmpty ? c.outbound : resolve(c.chain.isEmpty ? '' : c.chain.last)];
    // a chain's exit (`route1/…`, a rule target's `chain:c/…`) dials through its entry
    // group (`route1-entry`, `chain:c>entry`): show where it enters too
    final slash = out.first.indexOf('/');
    final group = slash > 0 ? out.first.substring(0, slash) : '';
    final entry = ['$group-entry', '$group>entry'].where(groups.containsKey).firstOrNull;
    if (slash > 0 && entry != null) out.add(resolve(entry));
    final (host, port) = c.hostPort;
    list.add({
      'id': c.id,
      'host': host,
      'port': port,
      'net': c.network.isEmpty ? 'tcp' : c.network,
      'rule': c.rule,
      'out': out,
      'process': c.process,
      'down': c.down,
      'up': c.up,
      'downRate': c.downRate,
      'upRate': c.upRate,
      'start': c.start.toUtc().toIso8601String(),
    });
  }
  final s = api.status;
  return {
    'down': s?.downlink.toInt() ?? 0,
    'up': s?.uplink.toInt() ?? 0,
    'downTotal': s?.downlinkTotal.toInt() ?? 0,
    'upTotal': s?.uplinkTotal.toInt() ?? 0,
    'tcp': tcp,
    'udp': udp,
    'conns': list,
  };
}
