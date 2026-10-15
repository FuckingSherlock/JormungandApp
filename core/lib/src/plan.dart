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

/// The entry group of a rule target that is a chain (`routing.targets[t]`); the target's own group `t` is the exit.
String targetEntryTag(String t) => '$t>entry';

/// The groups of the rule targets of [plan] (`routing.targets`) by their config tags: a unit's `main` is `t`, a
/// chain's `entry` is `t>entry` and its exit (`main`) is `t`.
Iterable<(String, Map)> planTargetGroups(Map<String, dynamic> plan) sync* {
  final routing = plan['routing'];
  final targets = routing is Map ? routing['targets'] : null;
  if (targets is! Map) return;
  for (final e in targets.entries) {
    final spec = e.value;
    if (spec is! Map) continue;
    if (spec['entry'] is Map) yield (targetEntryTag('${e.key}'), spec['entry'] as Map);
    if (spec['main'] is Map) yield ('${e.key}', spec['main'] as Map);
  }
}

/// A copy of [plan] whose groups start on [chosen] (group tag → server key; tags as above, a missing tag keeps the
/// group as it is). A plan without `routes` is one route: its own `main` / `entry` are changed. The rule targets'
/// groups (`routing.targets`, tags as [planTargetGroups]) the same.
Map<String, dynamic> planWithChosen(Map<String, dynamic> plan, Map<String, String> chosen) {
  if (chosen.isEmpty) return plan;
  Map<String, dynamic> targets(Map<String, dynamic> p) {
    final routing = p['routing'], specs = routing is Map ? routing['targets'] : null;
    if (specs is! Map) return p;
    Object? withKey(Object? g, String? key) => g is Map && key != null && g['pinned'] != true ? {...g.cast<String, dynamic>(), 'chosen': key} : g;
    final out = {
      for (final e in specs.entries)
        e.key: e.value is Map
            ? {
                ...(e.value as Map).cast<String, dynamic>(),
                if (e.value['main'] is Map) 'main': withKey(e.value['main'], chosen['${e.key}']),
                if (e.value['entry'] is Map) 'entry': withKey(e.value['entry'], chosen[targetEntryTag('${e.key}')]),
              }
            : e.value,
    };
    return {...p, 'routing': {...(routing as Map).cast<String, dynamic>(), 'targets': out}};
  }

  Map<String, dynamic> route(Map<String, dynamic> r, int i) {
    final out = {...r};
    for (final (field, tag) in [('main', routeTag(i)), ('entry', routeEntryTag(i))]) {
      final g = r[field], key = chosen[tag];
      if (g is Map && key != null && g['pinned'] != true) out[field] = {...g.cast<String, dynamic>(), 'chosen': key};
    }
    return out;
  }

  final rs = plan['routes'];
  if (rs is List && rs.isNotEmpty) {
    return targets({...plan, 'routes': [for (var i = 0; i < rs.length; i++) route((rs[i] as Map).cast<String, dynamic>(), i)]});
  }
  return targets({...plan, ...route(plan, 0)});
}

/// [plan] with each group that is not pinned and has the server of [now] (group tag → key; Auto's and the rule
/// service's `groupServers`) among its members started on it (`chosen`): a plan change while running keeps the servers
/// the core's checks found.
Map<String, dynamic> planKeepingServers(Map<String, dynamic> plan, Map<String, String> now) {
  final keep = <String, String>{};
  void take(String tag, Object? g) {
    final key = now[tag];
    if (g is! Map || key == null || g['pinned'] == true) return;
    if ((g['nodes'] as List? ?? const []).any((n) => n is Map && '${n['key']}' == key)) keep[tag] = key;
  }

  final rs = planRoutes(plan);
  for (var i = 0; i < rs.length; i++) {
    take(routeTag(i), rs[i]['main']);
    take(routeEntryTag(i), rs[i]['entry']);
  }
  for (final (tag, g) in planTargetGroups(plan)) {
    take(tag, g);
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
