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
/// selector set to the server the UI picked. The routes sit under the selector `proxy`;
/// moving between routes and between Priority servers (failAfter, standby) is the
/// AutoService (auto.dart), through the Clash API, with no restart.
library;

import 'plan.dart';

const defaultTestUrl = 'https://www.gstatic.com/generate_204';

Map<String, dynamic> buildConfig(Map<String, dynamic> plan, {int clashPort = 9090}) {
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

  return {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': 'local'},
      ],
    },
    'inbounds': [
      {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': plan['mixedPort'] ?? 2080},
    ],
    'outbounds': outs,
    'route': {
      'rules': [
        {'action': 'sniff'},
        if (plan['global'] != true) {'ip_is_private': true, 'outbound': 'direct'},
      ],
      'final': topTag,
      'auto_detect_interface': true,
      'default_domain_resolver': 'local',
      // which app opened a connection: shown in Live connections
      'find_process': true,
    },
    'experimental': {
      'clash_api': {'external_controller': '127.0.0.1:$clashPort'},
    },
  };
}

/// A config with no inbounds that only exists to measure latency through the clash API:
/// every node as `t/<key>`, every entry → exit pair as `p/<key>` (the exit dialing
/// through its own copy of the entry, `pe/<key>`).
Map<String, dynamic> buildTesterConfig({
  required List<Map> nodes,
  List<Map> pairs = const [],
  required int clashPort,
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
  return {
    'log': {'level': 'warn'},
    'dns': {
      'servers': [
        {'type': 'local', 'tag': 'local'},
      ],
    },
    'outbounds': outs,
    'route': {'final': 'direct', 'auto_detect_interface': true, 'default_domain_resolver': 'local'},
    'experimental': {
      'clash_api': {'external_controller': '127.0.0.1:$clashPort'},
    },
  };
}
