/// sing-box configs built from what the UI decided to connect through.
///
/// A connect plan (JSON from the UI):
/// ```
/// { routes: [Route…], current: 0,  // Auto entries by priority (plan.dart); Manual: one
///   mixedPort: 2080, global: false,
///   ipv6: false,   // Settings → Connection → IPv6: off = no AAAA answers, IPv6 refused in the TUN (plan.dart)
///   mixedAuth: { user, pass },   // optional: the user port asks for this login / password
///   urlTest: { url, interval /*s*/, tolerance /*ms*/ },
///   auto: { failAfter, threshold, checkEvery, standby, warmEvery, retryPause,
///           returnTo, flapGuard, flapMax, flapReset, siteRetry } }   // auto.dart
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
///
/// TUN: with `plan.mode == 'tun'` a `tun-in` inbound is added (docs/core.md → «TUN»); the user's
/// rules, apps and quick rules apply to its traffic as to the proxy port's (Global: everything
/// goes to the main flow). [selfPaths] = the executables of the core itself and of the sing-box
/// instances it starts (ping, speed test); [selfPackages] = the app's package (Android): their
/// connections go direct, ahead of the user's rules — through the tunnel they would loop. Behind
/// `tunnel-in`'s rule, so what the core sends through that inbound still goes into the tunnel;
/// their DNS lookups are answered by a direct DNS server ([selfDnsRules]). What must work outside
/// the tunnel is listed in outside_tunnel.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'plan.dart';
import 'probe.dart';
import 'routing.dart';
import 'rulenames.dart';

const defaultTestUrl = 'https://www.gstatic.com/generate_204';

/// The TUN's own addresses (always dual stack: the `::/0` route keeps IPv6 inside the tunnel, where
/// the plan's `ipv6` off rejects it, [ipv6OffRule]); the second of each is the "gateway" the system's DNS points at.
const tunAddress = ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'];
const tunDnsAddress = ['172.19.0.2/32', 'fdfe:dcba:9876::2/128'];

/// IPv6 off, TUN: every IPv6 connection that enters the tunnel is refused at once (TCP RST / ICMP
/// unreachable), so apps fall back to IPv4 instead of hanging. The IPv6 route stays in the TUN on purpose:
/// without it IPv6 literals would leave past the VPN on a network that has IPv6.
const ipv6OffRule = {'inbound': [tunTag], 'ip_version': 6, 'action': 'reject', 'no_drop': true};

/// Local networks stay out of the tunnel (the same ground as the `Private networks` rule):
/// private, link-local, multicast and broadcast, IPv4 and IPv6.
const tunBypass = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '224.0.0.0/4',
  '255.255.255.255/32',
  'fc00::/7',
  'fe80::/10',
  'ff00::/8',
];

/// The executables whose connections must never enter the tunnel: this process (the dart VM
/// for jormd, the app later) and the sing-box binary (ping / speed-test instances are separate
/// processes). Resolved to real paths; a sing-box that is not a file (looked up on PATH) is left out.
/// Android: none. `Platform.resolvedExecutable` there is the zygote's `app_process64`, shared by every
/// app, so a `process_path → direct` rule on it would be wrong; the app is matched by its package
/// ([selfPackageNames], `package_name`) instead, and the sing-box instances run inside the app
/// ([android] is for tests).
List<String> selfProcessPaths(String singBox, {bool? android}) {
  if (android ?? Platform.isAndroid) return const [];
  final out = <String>{Platform.resolvedExecutable};
  try {
    final f = File(singBox);
    if (f.existsSync()) out.add(f.resolveSymbolicLinksSync());
  } catch (_) {}
  return out.toList();
}

/// Android: the app's own package, the match of its self rule ([selfRules]). [package] is what the
/// platform said (the app may pass it); without it the process's own name is read from
/// `/proc/self/cmdline` (an app's main process is named after its package; `pkg:service` →
/// `pkg`). Empty off Android and when neither is known — then the app's traffic has no self rule
/// and is routed like any app's, which the service says in the log ([android] is for tests).
List<String> selfPackageNames({String? package, bool? android}) {
  if (!(android ?? Platform.isAndroid)) return const [];
  final p = package != null && package.isNotEmpty ? package : _procPackage();
  return p == null ? const [] : [p];
}

final _packageName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');

String? _procPackage() {
  try {
    final raw = File('/proc/self/cmdline').readAsBytesSync();
    final end = raw.indexOf(0);
    final name = utf8.decode(end < 0 ? raw : raw.sublist(0, end), allowMalformed: true).split(':').first.trim();
    return _packageName.hasMatch(name) ? name : null;
  } catch (_) {
    return null;
  }
}

/// "These programs go direct": Windows compares paths without case, so a regex there.
Map<String, dynamic> selfProcessRule(List<String> paths) => {
      if (Platform.isWindows) 'process_path_regex': [for (final p in paths) globToRegex(p)] else 'process_path': paths,
      'action': 'route',
      'outbound': 'direct',
    };

/// The self rules: what the app's own connections (OutsideHow.ownRule in outside_tunnel.dart: the
/// Dart HTTP clients, the desktop sing-box helper processes) are matched by once they enter the
/// TUN, sent direct. Android: its package (`package_name`); desktop: the executables
/// ([selfProcessPaths]). One rule per platform in practice; the TUN's own DNS rules for the
/// same processes are made from these ([selfDnsRules]), so the two cannot disagree.
List<Map<String, dynamic>> selfRules({List<String> paths = const [], List<String> packages = const []}) => [
      if (packages.isNotEmpty) {'package_name': packages, 'action': 'route', 'outbound': 'direct'},
      if (paths.isNotEmpty) selfProcessRule(paths),
    ];

/// The DNS rules for the same processes as [selfRules] ([rules]): their queries that the TUN's DNS
/// hijack hands to the core's DNS ([inbound], the TUN) are answered by [server], a DNS server
/// that resolves outside the tunnel (`Routing.domainResolver`). Without it a refresh of a
/// subscription with every node dead would fail on its own DNS: the core's DNS `final` may go
/// through the very proxy that is down.
List<Map<String, dynamic>> selfDnsRules(List<Map<String, dynamic>> rules, {required String server, String inbound = tunTag}) => [
      for (final r in rules)
        {
          'inbound': [inbound],
          for (final e in r.entries)
            if (e.key != 'action' && e.key != 'outbound') e.key: e.value,
          'action': 'route',
          'server': server,
        },
    ];

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
    RoutingInfo? info,
    List<String> selfPaths = const [],
    List<String> selfPackages = const []}) {
  final outs = <Map<String, dynamic>>[];
  final tun = planTun(plan);
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
  // TUN: DNS the core answers itself. Aimed at the tunnel's own resolver (what the system's DNS
  // points at on the TUN interface) it always does — nothing else could answer it, the app's own
  // lookups included, so this rule stands before the self rules; with Hijack DNS on, any other
  // DNS query does, even one for a hard-coded server (by port and by sniffed protocol), after
  // the self rules: the app's own DNS probes (Settings → DNS) must reach the server they test.
  final tunResolverHijack = {'inbound': [tunTag], 'ip_cidr': tunDnsAddress, 'port': [53], 'action': 'hijack-dns'};
  final hijackAll = <Map<String, dynamic>>[
    if (tun && planHijackDns(plan)) ...[
      {'inbound': [tunTag], 'port': [53], 'action': 'hijack-dns'},
      {'inbound': [tunTag], 'protocol': ['dns'], 'action': 'hijack-dns'},
    ],
  ];
  final hijack = [if (tun) tunResolverHijack, ...hijackAll];
  final selfRuleList = selfRules(paths: selfPaths, packages: selfPackages);
  // The app's own lookups reach the core's DNS through the hijack: answered by a direct server
  // first of all, whatever `final` and the rules say (they may lead through a proxy that is down)
  final dnsRules = [
    if (tun) ...selfDnsRules(selfRuleList, server: routing.domainResolver),
    ...routing.dnsRules,
  ];
  if (info != null) {
    // the route rules in the config's order, named for Live connections (rulenames.dart)
    for (final r in pr?.rules ?? const <Map<String, dynamic>>[]) {
      final dns = r.containsKey('server') || r.containsKey('override_address');
      info.ruleNames.add(r, dns ? const RuleOrigin('system', 'DNS check', id: 'dns-check') : const RuleOrigin('system', 'Latency check', id: 'probe'));
    }
    for (final r in hijack) {
      info.ruleNames.add(r, const RuleOrigin('system', 'DNS hijack', id: 'dns-hijack'));
    }
    if (tunnelRule != null) info.ruleNames.add(tunnelRule, const RuleOrigin('system', 'Core checks', id: 'tunnel'));
    for (final r in selfRuleList) {
      info.ruleNames.add(r, const RuleOrigin('system', 'Core and speed tests', id: 'core'));
    }
    for (var i = 0; i < routing.rules.length; i++) {
      final o = routing.origins[i];
      if (o != null) info.ruleNames.add(routing.rules[i], o);
    }
  }

  return {
    'log': {'level': 'info', 'timestamp': true},
    'dns': {
      'servers': routing.dnsServers,
      if (dnsRules.isNotEmpty) 'rules': dnsRules,
      'final': routing.dnsFinal,
      // IPv6 off: no AAAA answers to apps / the proxy port's clients (sing-box answers them empty) and
      // names are resolved to IPv4 only, TUN or not (a literal IPv6 address in TUN: [ipv6OffRule])
      if (!planIpv6(plan)) 'strategy': 'ipv4_only',
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
      if (tun) _tunInbound(plan),
      ?pr?.inbound,
    ],
    'outbounds': outs,
    'route': {
      'rules': [
        ...?pr?.rules,
        {'action': 'sniff'},
        if (tun) tunResolverHijack,
        ?tunnelRule,
        ...selfRuleList, // the app's own connections (docs/core.md → «TUN»): direct; behind tunnel-in's rule
        ...hijackAll,
        if (tun && !planIpv6(plan)) ipv6OffRule, // after the DNS hijack: DNS to the tunnel's IPv6 resolver is still answered
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

const tunTag = 'tun-in';

/// The TUN inbound: dual stack always (IPv6 off is a reject rule, [ipv6OffRule], not a missing
/// address: no `::/0` route would let IPv6 literals bypass the VPN), strict routes (no leaks past the tunnel on the other
/// interfaces), local networks excluded ([tunBypass]), the stack from the plan. sing-box's
/// own outbounds bind to the real interface (`route.auto_detect_interface`), so they
/// do not loop back into it. Android: an app set to Direct as a whole (Rules → Per-app routing, not
/// split, Rules mode) is left out of the VPN altogether (`exclude_package` →
/// `VpnService.Builder.addDisallowedApplication`), so its traffic never enters the tunnel.
Map<String, dynamic> _tunInbound(Map<String, dynamic> plan) {
  final direct = tunDirectPackages(plan);
  return {
    'type': 'tun',
    'tag': tunTag,
    'address': tunAddress,
    'mtu': 9000,
    'auto_route': true,
    'strict_route': true,
    'stack': planTunStack(plan),
    'route_exclude_address': tunBypass,
    if (direct.isNotEmpty) 'exclude_package': direct,
  };
}

/// The packages of the apps that go Direct whole: Direct on both halves when split. Empty in
/// Global (rules and apps are ignored there) and for process / path apps (desktop).
List<String> tunDirectPackages(Map<String, dynamic> plan) {
  if (plan['global'] == true) return const [];
  final apps = (plan['routing'] is Map ? (plan['routing'] as Map)['apps'] : null) as List? ?? const [];
  return [
    for (final a in apps)
      if (a is Map &&
          (a['kind'] ?? 'package') == 'package' &&
          '${a['id'] ?? ''}'.isNotEmpty &&
          a['act'] == 'direct' &&
          (a['split'] != true || (a['udp'] is Map && (a['udp'] as Map)['act'] == 'direct')))
        '${a['id']}',
  ];
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
