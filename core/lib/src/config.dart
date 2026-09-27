/// sing-box configs built from what the UI decided to connect through.
///
/// A connect plan (JSON from the UI):
/// ```
/// { routes: [Route…], current: 0,  // Auto entries by priority (plan.dart); Manual: one
///   mixedPort: 2080, global: false,
///   urlTest: { url, interval /*s*/, tolerance /*ms*/ },
///   auto: { failAfter, threshold, checkEvery, keepWarm, standby } }   // auto.dart
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
/// through the Clash API, with no restart.
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
/// [probe]: the loopback inbound the core measures latency through (probe.dart), its
/// route rule per server first of all.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'plan.dart';
import 'probe.dart';
import 'routing.dart';

const defaultTestUrl = 'https://www.gstatic.com/generate_204';

Map<String, dynamic> buildConfig(Map<String, dynamic> plan,
    {int clashPort = 9090,
    int? tunnelPort,
    Probe? probe,
    Map<String, String> ruleSetFiles = const {},
    List<String>? warnings}) {
  final outs = <Map<String, dynamic>>[];
  final test = (plan['urlTest'] as Map?) ?? const {};

  void group(String tag, Map g, {String? detour}) {
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
        'interrupt_exist_connections': true,
      });
    } else {
      outs.add({
        'type': 'urltest',
        'tag': tag,
        'outbounds': members,
        'url': test['url'] ?? defaultTestUrl,
        'interval': '${test['interval'] ?? 60}s',
        'tolerance': test['tolerance'] ?? 50,
        'interrupt_exist_connections': true,
      });
    }
  }

  final routes = planRoutes(plan), tags = <String>[];
  for (var i = 0; i < routes.length; i++) {
    final r = routes[i];
    if (r['kind'] == 'chain') {
      group(routeEntryTag(i), r['entry'] as Map);
      group(routeTag(i), r['main'] as Map, detour: routeEntryTag(i));
    } else {
      group(routeTag(i), r['main'] as Map);
    }
    tags.add(routeTag(i));
  }
  // Auto moves between the routes by switching this selector (auto.dart), no restart
  outs.add({
    'type': 'selector',
    'tag': topTag,
    'outbounds': tags,
    'default': tags[planCurrent(plan, tags.length)],
    'interrupt_exist_connections': true,
  });
  outs.add({'type': 'direct', 'tag': 'direct'});
  final routing = buildRouting(plan, group, ruleSetFiles: ruleSetFiles);
  outs.addAll(routing.outbounds);
  warnings?.addAll(routing.warnings);
  // cache_file keeps a selector's pick made over the clash API across restarts, over the
  // config's `default`: keyed by the defaults, a new pick from the UI starts clean.
  final picks = [for (final o in outs) if (o['type'] == 'selector') '${o['tag']}=${o['default']}'].join(' ');
  final pr = probe?.inbound(_servers(outs));

  return {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': routing.dnsServers,
      if (routing.dnsRules.isNotEmpty) 'rules': routing.dnsRules,
      'final': routing.dnsFinal,
    },
    'inbounds': [
      {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': plan['mixedPort'] ?? 2080},
      if (tunnelPort != null) {'type': 'mixed', 'tag': 'tunnel-in', 'listen': '127.0.0.1', 'listen_port': tunnelPort},
      ?pr?.inbound,
    ],
    'outbounds': outs,
    'route': {
      'rules': [
        ...?pr?.rules,
        {'action': 'sniff'},
        if (tunnelPort != null) {'inbound': ['tunnel-in'], 'action': 'route', 'outbound': topTag},
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
      'clash_api': {'external_controller': '127.0.0.1:$clashPort'},
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
  required int clashPort,
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
  final pr = probe?.inbound(_servers(outs));
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
    'experimental': {
      'clash_api': {'external_controller': '127.0.0.1:$clashPort'},
    },
  };
}

/// The outbounds that are servers (not groups, not direct / block): what a probe tests.
Iterable<String> _servers(List<Map<String, dynamic>> outs) => [
      for (final o in outs)
        if (!const {'selector', 'urltest', 'direct', 'block', 'dns'}.contains(o['type'])) '${o['tag']}',
    ];
