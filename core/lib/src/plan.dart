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

/// The route the top selector starts on.
int planCurrent(Map<String, dynamic> plan, int count) => ((plan['current'] as num?)?.toInt() ?? 0).clamp(0, count - 1);

/// TUN mode: the plan's `mode` is `'tun'` (anything else, or none = the local proxy port).
bool planTun(Map<String, dynamic> plan) => plan['mode'] == 'tun';

/// The TUN stacks sing-box has; the plan's `tunStack` picks one, `mixed` when missing or unknown.
const tunStacks = ['mixed', 'system', 'gvisor'];
String planTunStack(Map<String, dynamic> plan) => tunStacks.contains(plan['tunStack']) ? plan['tunStack'] as String : 'mixed';

/// Settings → DNS → Hijack DNS (`plan.routing.dns.hijack`; on unless the UI says off): in TUN,
/// every DNS query is answered by the core's DNS, even one aimed at a hard-coded server.
bool planHijackDns(Map<String, dynamic> plan) {
  final dns = ((plan['routing'] as Map?) ?? const {})['dns'];
  return !(dns is Map && dns['hijack'] == false);
}
