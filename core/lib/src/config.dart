/// sing-box configs built from what the UI decided to connect through.
///
/// A connect plan (JSON from the UI):
/// ```
/// { routes: [Route…], current: 0,  // Auto entries by priority (plan.dart); Manual: one
///   mixedPort: 2080, global: false,
///   mixedAuth: { user, pass },   // optional: the user port asks for this login / password
///   urlTest: { url, interval /*s*/, tolerance /*ms*/ },
///   auto: { failAfter, threshold, checkEvery, standby, warmEvery, retryPause,
///           returnTo, flapGuard, flapMax, flapReset } }   // auto.dart
/// Route = { id, kind: 'unit' | 'chain',
///   main:  Group,          // the unit, or the chain's exit
///   entry: Group }         // chain only: the exit dials through it
/// Group = { pick: 'fastest' | 'priority', chosen: key?, pinned?: bool, nodes: [{ key, outbound }] }
/// ```
/// `fastest` becomes a urltest group (interval = Auto mode's checkEvery, tolerance =
/// threshold — docs/connect-model.md → «Открытые вопросы для бэка»); `priority` a
/// selector set to the server the UI picked. The routes sit under the selector `proxy`
/// (the main flow: what rules send "through the VPN", and `final`); moving between routes
/// and between Priority servers (failAfter, standby) is the AutoService (auto.dart),
/// through sing-box's API service (sbapi.dart, added by runtime.dart), with no restart.
///
/// `routing` (rules, apps, quick rules, DNS — routing.dart) adds route rules, the rule
/// targets' groups, DNS servers and rule sets; [ruleSetFiles] = the lists on disk,
/// [warnings] collects what the rules could not use.
///
/// [tunnelPort]: a second loopback mixed inbound (`tunnel-in`) whose traffic always goes
/// through the tunnel (`proxy`: the route Auto is on), past every rule — the exit-IP check
/// and lists downloaded "via VPN" use it (a Russian probe or GitHub must not go direct
/// because a rule says so).
///
/// [sysPort]: with `mixedAuth` and the system proxy on, a third mixed inbound (`sys-in`) on
/// loopback without a password, routed like `mixed-in`: the Windows system proxy cannot pass
/// a login, so it points here (daemon.dart picks and keeps the port).
///
/// [probe]: the loopback inbound the core measures latency through (probe.dart), its
/// route rule per server first of all, and per DNS server in use a rule that resolves a
/// name through that server alone (the DNS check, dns_failover.dart).
///
/// [info] receives what the services beside sing-box need to know about the routing: the
/// "If unavailable" selectors (fallback.dart) and the DNS servers in use (dns_failover.dart).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'plan.dart';
import 'probe.dart';
import 'routing.dart';
import 'rulenames.dart';

const defaultTestUrl = 'https://www.gstatic.com/generate_204';

/// Backup checks (Settings → Connection): services of different owners tried when the
/// test URL does not answer through a node; the node passes traffic when any answers.
const defaultCheckers = [
  'https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204',
  'http://www.msftconnecttest.com/connecttest.txt',
  'http://captive.apple.com/hotspot-detect.html',
];

/// The plan's `auto.checkers` (the UI sends them with Settings → Auto mode, taken live) or
/// `urlTest.checkers`: a list of URLs; missing = [defaultCheckers], [] = none.
List<String> planCheckers(Map<String, dynamic> plan) {
  final c = ((plan['auto'] as Map?) ?? const {})['checkers'] ?? ((plan['urlTest'] as Map?) ?? const {})['checkers'];
  return c is List ? [for (final u in c) if (u is String && u.isNotEmpty) u] : defaultCheckers;
}

/// The plan's `mixedAuth` as a sing-box `users` entry; null = the user port is open. An empty
/// login or password (or a `:` in the login) is an error: better a failed connect than a port
/// that looks protected and is not.
Map<String, dynamic>? mixedAuthUser(Map<String, dynamic> plan) {
  final a = plan['mixedAuth'];
  if (a == null) return null;
  final user = a is Map ? a['user'] : null, pass = a is Map ? a['pass'] : null;
  if (user is! String || pass is! String || user.isEmpty || pass.isEmpty || user.contains(':')) {
    throw ArgumentError('Proxy password: the login and password must not be empty, and the login has no ":"');
  }
  return {'username': user, 'password': pass};
}

Map<String, dynamic> buildConfig(Map<String, dynamic> plan,
    {int? tunnelPort,
    int? sysPort,
    Probe? probe,
    Map<String, String> ruleSetFiles = const {},
    List<String>? warnings,
    RoutingInfo? info}) {
  final outs = <Map<String, dynamic>>[];
  final test = (plan['urlTest'] as Map?) ?? const {};
  final auth = mixedAuthUser(plan);

  // [auto]: a main-flow group the AutoService switches — a switch keeps the open
  // connections (auto.dart closes the stalled ones itself); a rule target's group is not.
  void group(String tag, Map g, {String? detour, bool auto = false}) {
    final members = <String>[];
    for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) {
      final t = '$tag/${n['key']}';
      if (members.contains(t)) continue;
      outs.add({...(n['outbound'] as Map).cast<String, dynamic>(), 'tag': t, 'detour': ?detour});
      members.add(t);
    }
    if (members.isEmpty) throw ArgumentError('No usable servers for "$tag"');
    if (g['pick'] == 'priority') {
      final chosen = '$tag/${g['chosen']}';
      outs.add({
        'type': 'selector',
        'tag': tag,
        'outbounds': members,
        'default': members.contains(chosen) ? chosen : members.first,
        'interrupt_exist_connections': !auto,
      });
    } else {
      outs.add({
        'type': 'urltest',
        'tag': tag,
        'outbounds': members,
        'url': test['url'] ?? defaultTestUrl,
        'interval': '${test['interval'] ?? 60}s',
        'tolerance': test['tolerance'] ?? 50,
        'interrupt_exist_connections': !auto,
      });
    }
  }

  final routes = planRoutes(plan), tags = <String>[];
  for (var i = 0; i < routes.length; i++) {
    final r = routes[i];
    if (r['kind'] == 'chain') {
      group(routeEntryTag(i), r['entry'] as Map, auto: true);
      group(routeTag(i), r['main'] as Map, detour: routeEntryTag(i), auto: true);
    } else {
      group(routeTag(i), r['main'] as Map, auto: true);
    }
    tags.add(routeTag(i));
  }
  // Auto moves between the routes by switching this selector (auto.dart), no restart and
  // no cut: open connections stay on the route they started on
  outs.add({
    'type': 'selector',
    'tag': topTag,
    'outbounds': tags,
    'default': tags[planCurrent(plan, tags.length)],
    'interrupt_exist_connections': false,
  });
  outs.add({'type': 'direct', 'tag': 'direct'});
  final routing = buildRouting(plan, group, ruleSetFiles: ruleSetFiles);
  outs.addAll(routing.outbounds);
  warnings?.addAll(routing.warnings);
  info?.fallbacks.addAll(routing.fallbacks);
  info?.dnsServers.addAll(routing.dnsEnabled);
  // cache_file keeps a selector's pick made over the API across restarts, over the
  // config's `default`: keyed by the defaults, a new pick from the UI starts clean.
  final picks = [for (final o in outs) if (o['type'] == 'selector') '${o['tag']}=${o['default']}'].join(' ');
  // 'direct' is tested too, always: the network check of the probe pool (pool.dart) tells a
  // dead network from dead routes by the direct path answering
  final pr = probe?.inbound([..._servers(outs), 'direct'], dnsServers: [for (final s in routing.dnsEnabled) s.tag]);
  final Map<String, dynamic>? tunnelRule = tunnelPort == null ? null : {'inbound': ['tunnel-in'], 'action': 'route', 'outbound': topTag};
  if (info != null) {
    // the route rules in the config's order, named for Live connections (rulenames.dart)
    for (final r in pr?.rules ?? const <Map<String, dynamic>>[]) {
      final dns = r.containsKey('server') || r.containsKey('override_address');
      info.ruleNames.add(r, dns ? const RuleOrigin('system', 'DNS check', id: 'dns-check') : const RuleOrigin('system', 'Latency check', id: 'probe'));
    }
    if (tunnelRule != null) info.ruleNames.add(tunnelRule, const RuleOrigin('system', 'Core checks', id: 'tunnel'));
    for (var i = 0; i < routing.rules.length; i++) {
      final o = routing.origins[i];
      if (o != null) info.ruleNames.add(routing.rules[i], o);
    }
  }

  return {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': routing.dnsServers,
      if (routing.dnsRules.isNotEmpty) 'rules': routing.dnsRules,
      'final': routing.dnsFinal,
    },
    'inbounds': [
      {
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': plan['mixedPort'] ?? 2080,
        if (auth != null) 'users': [auth],
      },
      if (sysPort != null) {'type': 'mixed', 'tag': 'sys-in', 'listen': '127.0.0.1', 'listen_port': sysPort},
      if (tunnelPort != null) {'type': 'mixed', 'tag': 'tunnel-in', 'listen': '127.0.0.1', 'listen_port': tunnelPort},
      ?pr?.inbound,
    ],
    'outbounds': outs,
    'route': {
      'rules': [
        ...?pr?.rules,
        {'action': 'sniff'},
        ?tunnelRule,
        ...routing.rules,
      ],
      if (routing.ruleSets.isNotEmpty) 'rule_set': routing.ruleSets,
      'final': routing.finalOutbound, // topTag (the main flow), or direct by a quick rule
      'auto_detect_interface': true,
      'default_domain_resolver': routing.domainResolver,
      // which app opened a connection: shown in Live connections
      'find_process': true,
    },
    'experimental': {
      'cache_file': {
        'enabled': true,
        if (picks.isNotEmpty) 'cache_id': sha1.convert(utf8.encode(picks)).toString().substring(0, 12),
      },
    },
  };
}

/// A config that only exists to measure latency (through its probe inbound, probe.dart):
/// every node as `t/<key>`, every entry → exit pair as `p/<key>` (the exit dialing
/// through its own copy of the entry, `pe/<key>`).
Map<String, dynamic> buildTesterConfig({
  required List<Map> nodes,
  List<Map> pairs = const [],
  Probe? probe,
}) {
  final outs = <Map<String, dynamic>>[
    {'type': 'direct', 'tag': 'direct'},
    for (final n in {for (final n in nodes) '${n['key']}': n}.values)
      {...(n['outbound'] as Map).cast<String, dynamic>(), 'tag': 't/${n['key']}'},
  ];
  for (final p in pairs) {
    final entry = p['entry'] as Map, exit = p['exit'] as Map;
    outs.add({...(entry['outbound'] as Map).cast<String, dynamic>(), 'tag': 'pe/${p['key']}'});
    outs.add({...(exit['outbound'] as Map).cast<String, dynamic>(), 'tag': 'p/${p['key']}', 'detour': 'pe/${p['key']}'});
  }
  final pr = probe?.inbound([..._servers(outs), 'direct']); // direct: the network check (pool.dart)
  return {
    'log': {'level': 'warn'},
    if (pr != null) 'inbounds': [pr.inbound],
    'dns': {
      'servers': [
        {'type': 'local', 'tag': 'local'},
      ],
    },
    'outbounds': outs,
    'route': {
      if (pr != null) 'rules': pr.rules,
      'final': 'direct',
      'auto_detect_interface': true,
      'default_domain_resolver': 'local',
    },
  };
}

/// The outbounds that are servers (not groups, not direct / block): what a probe tests.
Iterable<String> _servers(List<Map<String, dynamic>> outs) => [
      for (final o in outs)
        if (!const {'selector', 'urltest', 'direct', 'block', 'dns'}.contains(o['type'])) '${o['tag']}',
    ];
