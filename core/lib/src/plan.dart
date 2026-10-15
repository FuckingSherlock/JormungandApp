/// The routes of a connect plan and the sing-box tags they get (config.dart builds them,
/// auto.dart switches between them).
///
/// A plan carries `routes`: every Auto entry by priority, `current` = the one the UI starts
/// on; in Manual just the pinned entry. A route
/// is `{id, kind: 'unit' | 'chain', main: Group, entry?: Group}` (Group: see config.dart).
/// A plan without `routes` (the old shape: kind / main / entry at the top) is one route.
///
/// Tags: route i is the group `route<i>` (a chain's exit), its servers `route<i>/<key>`; a
/// chain's entry is `route<i>-entry`, servers `route<i>-entry/<key>`. The top selector
/// `proxy` holds the routes and is the proxy outbound everything goes to.
library;

const topTag = 'proxy';
String routeTag(int i) => 'route$i';
String routeEntryTag(int i) => 'route$i-entry';

/// The routes of [plan] in priority order.
List<Map<String, dynamic>> planRoutes(Map<String, dynamic> plan) {
  final rs = plan['routes'];
  if (rs is List && rs.isNotEmpty) return [for (final r in rs) (r as Map).cast<String, dynamic>()];
  return [plan];
}

/// A copy of [plan] whose groups start on [chosen] (group tag → server key; tags as above, a missing tag keeps the
/// group as it is). A plan without `routes` is one route: its own `main` / `entry` are changed.
Map<String, dynamic> planWithChosen(Map<String, dynamic> plan, Map<String, String> chosen) {
  if (chosen.isEmpty) return plan;
  Map<String, dynamic> route(Map<String, dynamic> r, int i) {
    final out = {...r};
    for (final (field, tag) in [('main', routeTag(i)), ('entry', routeEntryTag(i))]) {
      final g = r[field], key = chosen[tag];
      if (g is Map && key != null) out[field] = {...g.cast<String, dynamic>(), 'chosen': key};
    }
    return out;
  }

  final rs = plan['routes'];
  if (rs is List && rs.isNotEmpty) {
    return {...plan, 'routes': [for (var i = 0; i < rs.length; i++) route((rs[i] as Map).cast<String, dynamic>(), i)]};
  }
  return {...plan, ...route(plan, 0)};
}

/// [plan] with each group that is not pinned and has the server of [now] (group tag → key; Auto's `groupServers`)
/// among its members started on it (`chosen`): a plan change while running keeps the servers the core's checks found.
Map<String, dynamic> planKeepingServers(Map<String, dynamic> plan, Map<String, String> now) {
  final keep = <String, String>{};
  final rs = planRoutes(plan);
  for (var i = 0; i < rs.length; i++) {
    for (final (field, tag) in [('main', routeTag(i)), ('entry', routeEntryTag(i))]) {
      final g = rs[i][field], key = now[tag];
      if (g is! Map || key == null || g['pinned'] == true) continue;
      if ((g['nodes'] as List? ?? const []).any((n) => n is Map && '${n['key']}' == key)) keep[tag] = key;
    }
  }
  return planWithChosen(plan, keep);
}

/// The route the top selector starts on.
int planCurrent(Map<String, dynamic> plan, int count) => ((plan['current'] as num?)?.toInt() ?? 0).clamp(0, count - 1);

/// TUN mode: the plan's `mode` is `'tun'` (anything else, or none = the local proxy port).
bool planTun(Map<String, dynamic> plan) => plan['mode'] == 'tun';

/// The TUN stacks sing-box has; the plan's `tunStack` picks one, `mixed` when missing or unknown.
const tunStacks = ['mixed', 'system', 'gvisor'];
String planTunStack(Map<String, dynamic> plan) => tunStacks.contains(plan['tunStack']) ? plan['tunStack'] as String : 'mixed';

/// Settings → Connection → IPv6 (`plan.ipv6`; off when missing): off = the core's DNS answers no
/// AAAA (`dns.strategy: ipv4_only`) and IPv6 connections entering the TUN are rejected at once
/// (config.dart `ipv6OffRule`), so nothing hangs on an address the network and the exits may not
/// carry; on = dual stack as is.
bool planIpv6(Map<String, dynamic> plan) => plan['ipv6'] == true;

/// Settings → DNS → Hijack DNS (`plan.routing.dns.hijack`; on unless the UI says off): in TUN,
/// every DNS query is answered by the core's DNS, even one aimed at a hard-coded server.
bool planHijackDns(Map<String, dynamic> plan) {
  final dns = ((plan['routing'] as Map?) ?? const {})['dns'];
  return !(dns is Map && dns['hijack'] == false);
}
