/// Rules, apps, quick rules and DNS from the UI's rule model (`plan.routing`) turned into
/// sing-box route rules, the outbounds they send traffic to, DNS servers / rules and the
/// rule sets they need. docs/rules.md is the spec; the Flutter app sends the same model.
///
/// ```
/// routing: {
///   apps:   [{ id, kind: 'package'|'process'|'path', name, act: 'default'|'direct'|'proxy'|'block',
///              target, fallback: 'default'|'main'|'block'|'direct'|<target id>,  // as a rule's
///              split, udp: { act, target, fallback } }], // split: the fields above = TCP, udp = UDP
///   rules:  [{ id, name, action: 'proxy'|'direct'|'block', target, fallback:
///              'default'|'main'|'block'|'direct'|<target id>, block: 'drop'|'reject', dns: 'auto'|<dns id>,
///              ipTunOnly?: true,                 // IP conditions do not force a `resolve`
///              groups: { domain|ip|port|source|network|process: { not, v: {field: [..]}, flag } },
///              composite?, extra? }],             // enabled ones, in order
///   quick:  { ads, region: 'RU'|…|null, services: {key: 'vpn'|'direct'},
///             final: 'proxy'|'direct'|'block' },
///   fallback: 'main'|'block'|'direct',            // Rules → Target unavailable
///   targets: { '<target>': { kind: 'unit'|'chain', main: Group, entry?: Group } },
///   ruleSets: [{ name, url, format: 'srs'|'json', via, every /*s*/ }],   // the user's lists
///   geo: { geosite: {via, every}, geoip: {via, every} },  // the built-in lists
///   dns: { servers: [{ id, on, sides: ['direct','vpn'], use: ['doh','dot'],          // providers, in priority order
///                       transports: [{ kind: 'doh'|'dot'|'doq'|'udp'|'system', addr }] }],
///          directPolicy?: 'localFirst'|'priority',   // Local on the direct side: always first (default) or always last
///          resolve: 'auto'|'off'|<dns id>,    // `resolve` before IP rules (proxy ports only, also in TUN); default 'auto'
///          hijack?: bool }                    // TUN: the core answers every DNS query; default on (config.dart)
/// }
/// ```
/// A DNS server of the older plan, `{ id, addr, via: 'direct'|'vpn', on }`, is read as a provider with one
/// transport (its kind from the address) on the one side `via` names.
/// A target missing from `targets` is unavailable now (off in Nodes, no usable server,
/// deleted): its rules take their "If unavailable" when the config is built.
///
/// A rule's / app's `fallback` is a keyword or a real target of the catalog (an id of
/// `targets`: any string that is not a keyword): "If unavailable → go through that target".
/// A fallback target equal to the target, or empty, is the main flow; one that is unavailable
/// now (not in `targets`, or null there) is `default` (the global `fallback`) and a warning
/// says so. The global `fallback` is a keyword only (anything else = main).
///
/// The main flow has "If unavailable" too, only when asked for explicitly (never the global
/// one): an app whose act is `default` or `proxy` with no target and a `fallback` of `block`,
/// `direct` or a target id goes through a selector `proxy~<fallback>` = `[proxy, fallback]`;
/// `default` / `main` (empty) = none. An act `default` with none has no rule, as before. A
/// rule with an empty target does the same, but the UI sends `default` for it.
///
/// A target that is available goes through a selector `<target>~<fallback>` =
/// `[target, fallback]` (with a target as the fallback: `[target, fallback target, main
/// flow]`, the last for both being down; [TargetFallback], listed in [RoutingInfo]), so the
/// core can move its traffic to the fallback and back with no restart when the target stops
/// answering (fallback.dart).
///
/// DNS (docs/rules.md §6): every enabled transport of every enabled provider on each of its sides is one
/// sing-box DNS server ([DnsCandidate]), with a flag: a local rule set that matches every name (on) or
/// none (off). The DNS rules of a side are `AND(what the side answers, flag) → server` in priority order,
/// so the first candidate whose flag is on answers; with every flag off the side's top candidate does.
/// The core flips a flag by rewriting its file (dns_flags.dart), with no restart.
library;

import 'dart:io';

import 'package:path/path.dart' as pth;

import 'plan.dart';
import 'rulenames.dart';

/// Adds a server group as [tag] (see buildConfig): its members are `tag/<key>`.
typedef GroupEmitter = void Function(String tag, Map g, {String? detour});

/// A rule set sing-box reads from a local file the core downloads (see rulesets.dart).
class RuleSetSource {
  const RuleSetSource(this.tag, this.urls, {this.binary = true, this.viaVpn = true, this.every = const Duration(days: 1)});

  final String tag;

  /// Tried in order: a 404 moves to the next one (runetfreedom, then SagerNet).
  final List<String> urls;
  final bool binary;
  final bool viaVpn;
  final Duration every;
}

// runetfreedom (RU lists, rebuilt every 6 h) first; SagerNet for what it lacks.
const _rfBase = 'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box';
String geositeTag(String name) => 'geosite-${name.toLowerCase()}';
String geoipTag(String cc) => 'geoip-${cc.toLowerCase()}';
String userSetTag(String name) => 'set-$name';
List<String> geositeUrls(String name) => [
      '$_rfBase/rule-set-geosite/geosite-${name.toLowerCase()}.srs',
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${name.toLowerCase()}.srs',
    ];
List<String> geoipUrls(String cc) => [
      '$_rfBase/rule-set-geoip/geoip-${cc.toLowerCase()}.srs',
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-${cc.toLowerCase()}.srs',
    ];

/// Built-in services (Rules → Services): geosite / geoip categories, and the domains that
/// stand in while the lists are not downloaded. Keys match the UI's SERVICES.
const services = <String, ({List<String> geosite, List<String> geoip, List<String> domains})>{
  'telegram': (geosite: ['telegram'], geoip: ['telegram'], domains: ['telegram.org', 't.me', 'telegram.me', 'telegra.ph', 'tdesktop.com']),
  'youtube': (geosite: ['youtube'], geoip: [], domains: ['youtube.com', 'googlevideo.com', 'ytimg.com', 'youtu.be', 'ggpht.com']),
  'discord': (geosite: ['discord'], geoip: [], domains: ['discord.com', 'discord.gg', 'discordapp.com', 'discordapp.net', 'discord.media']),
  'netflix': (geosite: ['netflix'], geoip: ['netflix'], domains: ['netflix.com', 'nflxvideo.net', 'nflximg.net', 'nflxext.com']),
  'spotify': (geosite: ['spotify'], geoip: [], domains: ['spotify.com', 'scdn.co', 'spotifycdn.com']),
  'chatgpt': (geosite: ['openai'], geoip: [], domains: ['openai.com', 'chatgpt.com', 'oaiusercontent.com', 'oaistatic.com']),
  'instagram': (geosite: ['instagram'], geoip: [], domains: ['instagram.com', 'cdninstagram.com']),
  'x': (geosite: ['twitter'], geoip: ['twitter'], domains: ['x.com', 'twitter.com', 'twimg.com', 't.co']),
};

/// "My region direct": the region's sites (geosite + its TLDs, IDN ones as punycode:
/// рф = xn--p1ai) and IPs (geoip).
const regions = <String, ({List<String> geosite, List<String> geoip, List<String> tlds})>{
  'RU': (geosite: ['category-ru', 'ru-available-only-inside'], geoip: ['ru'], tlds: ['ru', 'xn--p1ai', 'su']),
  'BY': (geosite: [], geoip: ['by'], tlds: ['by', 'xn--90ais']),
  'KZ': (geosite: [], geoip: ['kz'], tlds: ['kz', 'xn--80ao21a']),
  'UA': (geosite: [], geoip: ['ua'], tlds: ['ua', 'xn--j1amh']),
  'CN': (geosite: ['cn'], geoip: ['cn'], tlds: ['cn']),
  'IR': (geosite: ['category-ir'], geoip: ['ir'], tlds: ['ir']),
};
/// The services' names as the UI shows them (keys as in [services]).
const serviceTitles = {
  'telegram': 'Telegram',
  'youtube': 'YouTube',
  'discord': 'Discord',
  'netflix': 'Netflix',
  'spotify': 'Spotify',
  'chatgpt': 'ChatGPT',
  'instagram': 'Instagram',
  'x': 'X / Twitter',
};
const adsGeosite = 'category-ads-all';
const adsDomains = ['doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adservice.google.com', 'an.yandex.ru'];

/// Names only a local network resolves (mDNS, the loopback, routers' own zones, RFC 8375).
const lanSuffixes = ['local', 'localhost', 'lan', 'home.arpa'];

Map<String, dynamic> _routing(Map plan) =>
    ((plan['routing'] as Map?) ?? const {'quick': {'final': 'proxy'}}).cast<String, dynamic>();
List<Map> _list(Object? l) => (l as List? ?? const []).cast<Map>();
List<String> _strs(Object? l) => [for (final x in (l as List? ?? const [])) '$x'];

/// Every rule set the plan's routing would use: what the core must have on disk before
/// it builds the config. Lists that fail to download are left out of the config (rules
/// then fall back to their plain domains, or are skipped — see [buildRouting]).
List<RuleSetSource> ruleSetsNeeded(Map plan) {
  if (plan['global'] == true) return const [];
  final r = _routing(plan);
  final geo = (r['geo'] as Map?) ?? const {};
  ({bool vpn, Duration every}) geoOf(String k) {
    final g = (geo[k] as Map?) ?? const {};
    return (vpn: g['via'] != 'direct', every: Duration(seconds: (g['every'] as num?)?.toInt() ?? 7 * 86400));
  }

  final gs = geoOf('geosite'), gi = geoOf('geoip');
  final out = <String, RuleSetSource>{};
  void site(String n) => out[geositeTag(n)] ??= RuleSetSource(geositeTag(n), geositeUrls(n), viaVpn: gs.vpn, every: gs.every);
  void ip(String n) => out[geoipTag(n)] ??= RuleSetSource(geoipTag(n), geoipUrls(n), viaVpn: gi.vpn, every: gi.every);
  final userSets = {for (final s in _list(r['ruleSets'])) '${s['name']}': s};
  void user(String n) {
    final s = userSets[n];
    if (s == null || out.containsKey(userSetTag(n))) return;
    out[userSetTag(n)] = RuleSetSource(userSetTag(n), ['${s['url']}'],
        binary: s['format'] != 'json', viaVpn: s['via'] != 'direct', every: Duration(seconds: (s['every'] as num?)?.toInt() ?? 86400));
  }

  void scan(Object? o) {
    if (o is Map) {
      o.forEach((k, v) {
        if (k == 'geosite') _strs(v).forEach(site);
        if (k == 'geoip') _strs(v).forEach(ip);
        if (k == 'rule_set') _strs(v).forEach(user);
        if (v is Map || v is List) scan(v);
      });
    } else if (o is List) {
      o.forEach(scan);
    }
  }

  for (final rule in _list(r['rules'])) {
    scan(rule['groups']);
    scan(rule['composite']);
  }
  final q = (r['quick'] as Map?) ?? const {};
  if (q['ads'] == true) site(adsGeosite);
  ((q['services'] as Map?) ?? const {}).forEach((k, v) {
    final s = services[k];
    if (s == null || (v != 'vpn' && v != 'direct')) return;
    s.geosite.forEach(site);
    s.geoip.forEach(ip);
  });
  final reg = regions[q['region']];
  if (reg != null) {
    reg.geosite.forEach(site);
    reg.geoip.forEach(ip);
  }
  return out.values.toList();
}

/// A rule target with its "If unavailable" (docs/rules.md §0) as the config holds it: the
/// selector [tag] = [target's group, fallback], which rules and apps route to. The core
/// flips it while sing-box runs (fallback.dart): the target stops answering → [fallbackTag],
/// answers again → the target.
class TargetFallback {
  TargetFallback(this.tag, this.target, this.spec, this.fallbackTag, {this.fallbackTarget, this.fallbackSpec});

  final String tag;

  /// The UI's target id (`src:…`, `chain:…`); its group in the config has the same tag.
  final String target;

  /// The plan's `targets[target]`: `{kind, main: Group, entry?: Group}` (the groups' tags:
  /// `target`, and `target>entry` for a chain).
  final Map spec;

  /// `proxy` (the main flow), `direct`, or `block`; for a target as the
  /// fallback, that target's group (= its id).
  final String fallbackTag;

  /// The UI's id of the fallback when it is a target of the catalog (null for the keywords),
  /// with its `targets` entry. The selector then also holds the main flow, where traffic goes
  /// while both the target and this one are down.
  final String? fallbackTarget;
  final Map? fallbackSpec;

  /// Only a selector whose fallback is Direct: its flag rule set (the file at [flagPath], on = the selector sits on
  /// Direct, fallback.dart flips it). The resolve ladder in front of the rules that route here holds only while it is on
  /// (docs/rules.md §6), so the names a rule sends direct after its target died are resolved by the flagged DNS servers,
  /// not by `route.default_domain_resolver`; what still goes through the proxy is never resolved here.
  String? flagTag, flagPath;

  /// The rules and the apps that route here (their names, for the journal).
  final rules = <String>[];
  final apps = <String>[];

  /// The fallback as the journal names it: 'block' | 'direct' | 'main', or the fallback
  /// target's id.
  String get to => fallbackTarget ?? (fallbackTag == 'block' ? 'block' : (fallbackTag == topTag ? 'main' : 'direct'));
}

/// Transport kinds of a DNS provider (not `system`), in the order the defaults list them.
const dnsKinds = ['doh', 'dot', 'doq', 'udp'];

/// The kind of the OS resolver: a provider with this one transport and no other (Local).
const dnsKindSystem = 'system';

/// The sides a provider's queries can take: out directly, or through the main flow.
const dnsSidesAll = ['direct', 'vpn'];

/// A provider's `use` when it is not said (the defaults).
const dnsUseDefault = ['doh', 'dot'];

/// The kind of a Settings → DNS address: `system`, `https://` = doh, `tls://` = dot, `quic://` = doq,
/// anything else (`udp://`, `tcp://`, a bare IP) = udp.
String dnsKindOf(String addr) {
  addr = addr.trim();
  if (addr == 'system') return dnsKindSystem;
  return switch (RegExp(r'^([a-z]+)://').firstMatch(addr)?.group(1)) {
    'https' => 'doh',
    'tls' => 'dot',
    'quic' => 'doq',
    _ => 'udp',
  };
}

/// A DNS server in use ([id] = the Sentinel's node id, the candidate's tag without `dns-`; [tag] = the DNS
/// server in the config) — the core checks each one (dns_failover.dart).
typedef DnsEntry = ({String id, String tag});

/// One DNS server of the config: a transport of a provider on one side. Its [flagTag] rule set (the file
/// at [flagPath]) matches every name while the candidate is live and none when it is judged dead; the
/// DNS rules take the first live one of a side's list.
class DnsCandidate {
  DnsCandidate({
    required this.side,
    required this.provider,
    required this.kind,
    required this.n,
    required this.tag,
    required this.addr,
    required this.flagTag,
    required this.flagPath,
    required this.inUse,
  });

  /// `direct` | `vpn`.
  final String side;

  /// The catalog's provider id.
  final String provider;

  /// `doh` | `dot` | `doq` | `udp` | `system`.
  final String kind;

  /// The number among the provider's addresses of this kind, from 1 (0: the OS resolver).
  final int n;

  /// The DNS server's tag: `dns-<provider>-<kind><n>`, `-v` added on the VPN side; `dns-<provider>` for `system`.
  final String tag;
  final String addr;

  /// The rule set tag (in `route.rule_set`) and the file of the flag.
  final String flagTag, flagPath;

  /// The provider is on (a candidate of a provider that is off exists only because a rule names it).
  final bool inUse;

  bool get vpn => side == 'vpn';
  String get id => tag.startsWith('dns-') ? tag.substring(4) : tag;
  DnsEntry get entry => (id: id, tag: tag);
}

/// The name the flags of a side are checked with (docs/rules.md §6 → flagcheck): the DNS rules answer it,
/// without any network, with the address of the side's effective candidate ([DnsFlagCheck.address]).
String dnsFlagcheckName(String side) => '$side.flagcheck.jorm.invalid';

/// One candidate's answer to the side's flagcheck name: `127.77.<side>.<n>` (side 1 = direct, 2 = vpn; n = the
/// place in the side's list from 1). Reached through the probe inbound (probe.dart `flagChecks`).
class DnsFlagCheck {
  const DnsFlagCheck({required this.candidate, required this.address});

  final DnsCandidate candidate;
  final String address;

  String get side => candidate.side;
  String get name => dnsFlagcheckName(side);
}

/// The Sentinel's id of the OS resolver (`local`) when the settings have no `system` server: it resolves the
/// DNS servers' hostnames and what goes out directly, so it is watched like the others (never switched to).
const systemDnsId = 'system';

/// What [buildConfig] learned besides the config, for the services that run beside sing-box.
class RoutingInfo {
  /// One per selector, in the order the rules use them.
  final fallbacks = <TargetFallback>[];

  /// The config's route rules by the text sing-box reports for a connection (rulenames.dart):
  /// Live connections name the rule a connection went by with it.
  final ruleNames = RuleNames();

  /// The DNS servers in use (enabled providers' transports on each side), the direct side first, each side by
  /// its priority.
  final dnsServers = <DnsEntry>[];

  /// The same by side: `direct` / `vpn`, each list in the order the DNS rules try its candidates.
  final dnsSides = <String, List<DnsCandidate>>{};

  /// Every DNS server the config holds with its flag (in use or named by a rule), for the core that drives the
  /// flags (dns_flags.dart).
  final dnsCandidates = <DnsCandidate>[];

  /// The flagcheck of every candidate of a side (the probe inbound asks them, see [DnsFlagCheck]).
  final dnsFlagChecks = <DnsFlagCheck>[];

  /// Servers of the config that are not in use (provider off) but a rule names: the Sentinel still
  /// watches them (docs/rules.md §6). Also the OS resolver `system` when no Local provider is on.
  final dnsExtra = <DnsEntry>[];

  /// The ids of the config's DNS servers that go through the VPN (`detour`).
  final dnsVpn = <String>{};

  /// A user rule's id → the tag of the DNS server its traffic resolves through (the top one of its chain).
  final ruleDns = <String, String>{};

  /// A user rule's id → the tags of its chain of DNS servers, in the order the DNS rules try them (the first
  /// whose flag is on answers).
  final ruleChains = <String, List<String>>{};

  /// The tag of the server that resolves what goes out directly (`default_domain_resolver`); `local` is the OS resolver.
  String domainResolver = 'local';

  /// The tag of the server that resolves the names of node outbounds (`domain_resolver` of each, [nodeResolverOf]): the
  /// top of the system chain. Null when the config was built without a node resolver; then nodes use [domainResolver].
  String? nodeResolver;

  /// The ids of the routes (plan `id`, else `route<i>`) with a server sing-box looks up by name itself: still named by
  /// a host (not pinned) in the group it dials directly (a chain's entry, a single route's nodes). Such a route depends
  /// on [nodeResolver] (or [domainResolver] without one); a chain's exit does not (the entry resolves it).
  final nameRoutes = <String>{};
}

/// What [buildRouting] adds to a config.
class Routing {
  Routing._();

  /// Route rules, after the sniff rule.
  final rules = <Map<String, dynamic>>[];

  /// The origin of each of [rules] (same index); null = one that never names a connection
  /// (a resolve step, a bare reject).
  final origins = <RuleOrigin?>[];

  void _add(Map<String, dynamic> rule, [RuleOrigin? origin]) {
    rules.add(rule);
    origins.add(origin);
  }

  /// Outbounds besides the target groups (added through the emitter): the "If unavailable"
  /// selectors and `block`.
  final outbounds = <Map<String, dynamic>>[];

  /// The "If unavailable" selectors rules and apps route to (see [TargetFallback]).
  final fallbacks = <TargetFallback>[];
  String finalOutbound = topTag;
  final dnsServers = <Map<String, dynamic>>[];
  final dnsRules = <Map<String, dynamic>>[];
  String dnsFinal = 'local';

  /// The servers in use (direct side first, each by priority), by side, and all with their flags
  /// ([RoutingInfo.dnsServers], [RoutingInfo.dnsSides], [RoutingInfo.dnsCandidates]).
  final dnsEnabled = <DnsEntry>[];
  final dnsSides = <String, List<DnsCandidate>>{'direct': [], 'vpn': []};
  final dnsCandidates = <DnsCandidate>[];
  final dnsFlagChecks = <DnsFlagCheck>[];

  /// Servers named by a rule but not in use ([RoutingInfo.dnsExtra]), the ids of those via VPN, and each
  /// rule's first server.
  final dnsExtra = <DnsEntry>[];
  final dnsVpn = <String>{};
  final ruleDns = <String, String>{};
  final ruleChains = <String, List<String>>{};

  /// Resolves the servers' own hostnames (proxy outbounds, DoH hosts) and what goes out
  /// directly: the direct side's top candidate, never one that needs the tunnel.
  String domainResolver = 'local';

  /// The bootstrap server (the OS resolver's tag): what resolves a DoH / DoT host when nothing better is on.
  String bootResolver = 'local';

  /// `route.rule_set`: local files only (the lists, and the DNS flags).
  final ruleSets = <Map<String, dynamic>>[];

  /// Rules left out or narrowed (a list not downloaded, a bad value) — told to the user.
  final warnings = <String>[];
}

/// The DNS rules that send what [match] (null = every query) asks to the candidates [l], in priority order: with
/// several, one rule per candidate `AND(match, its flag)` — the first one whose flag is on answers — and then
/// [match] with the top candidate and no flag (every flag off: the top one answers); one candidate needs no flag.
/// [fallback] false (no [match]: the catch-all, `dns.final` does it) leaves the last step out.
/// [action] makes the rule's action for a candidate (default: route to its server).
List<Map<String, dynamic>> dnsChainRules(Map<String, dynamic>? match, List<DnsCandidate> l,
    {bool fallback = true, Map<String, dynamic> Function(DnsCandidate c, int i)? action}) {
  if (l.isEmpty) return const [];
  Map<String, dynamic> act(int i) => action?.call(l[i], i) ?? {'action': 'route', 'server': l[i].tag};
  return [
    if (l.length > 1)
      for (var i = 0; i < l.length; i++)
        match == null
            ? {'rule_set': [l[i].flagTag], ...act(i)}
            : {
                'type': 'logical',
                'mode': 'and',
                'rules': [match, {'rule_set': [l[i].flagTag]}],
                ...act(i),
              },
    if (fallback && match != null) {...match, ...act(0)},
  ];
}

const _dnsMatchKeys = {
  'process_name', 'process_path', 'process_path_regex', 'package_name', 'network', 'inbound', //
  'source_ip_cidr', 'source_ip_is_private', 'source_port', 'source_port_range',
  'domain', 'domain_suffix', 'domain_keyword', 'domain_regex',
  'type', 'mode', 'rules', 'invert',
};

/// Whether a DNS rule can tell the connections [m] matches by the query of a route `resolve`: only what the query
/// carries (the process / package, network, inbound, source, the name), no destination port, IP or rule set of an
/// unknown content (a geosite list is names).
bool dnsMatchable(Object? m) => switch (m) {
      Map m => m.entries.every((e) => switch (e.key) {
            'rule_set' => (e.value as List).every((t) => '$t'.startsWith('geosite-')),
            'rules' => dnsMatchable(e.value),
            final k => _dnsMatchKeys.contains(k),
          }),
      List l => l.every(dnsMatchable),
      _ => false,
    };

/// [l] with the OS resolver (`system`) moved behind the others, the order otherwise kept: the core resolves the addresses
/// of rules and its own destinations preferably NOT through the local resolver (it knows nothing of our flags and may
/// be the one that fails), which stays the last resort (docs/rules.md §6). The DNS rules that answer the apps' own
/// queries keep the user's order (Local first / last).
List<DnsCandidate> localLast(List<DnsCandidate> l) => [
      ...l.where((c) => c.kind != dnsKindSystem),
      ...l.where((c) => c.kind == dnsKindSystem),
    ];

/// The DNS server (its tag) that resolves the names of nodes the core could not pre-resolve in time: the top of the system
/// chain (docs/rules.md §6 → «Адреса серверов»), never the user's rule DNS. The first enabled direct-side server for
/// which [usable] says yes (the caller keeps it to built-in servers whose stored verdict is not dead), encrypted before
/// plain like the address resolver's ladder, DoQ left out; the OS resolver only when there is none.
String nodeResolverOf(Routing r, bool Function(DnsCandidate c) usable) {
  final direct = r.dnsSides['direct'] ?? const <DnsCandidate>[];
  final ok = [for (final c in direct) if (c.kind != dnsKindSystem && c.kind != 'doq' && usable(c)) c];
  final l = [...ok.where((c) => c.kind == 'doh' || c.kind == 'dot'), ...ok.where((c) => c.kind != 'doh' && c.kind != 'dot')];
  if (l.isNotEmpty) return l.first.tag;
  final local = direct.where((c) => c.kind == dnsKindSystem).firstOrNull;
  if (local != null) return local.tag;
  return r.dnsServers.any((s) => s['tag'] == 'local') ? 'local' : r.bootResolver;
}

/// The route rules `resolve` that resolve what [match] (conditions ANDed; empty = every connection) names through
/// the first live candidate of [l]: with several, a rule per candidate that holds only while its flag is on and
/// no flag above it is (so exactly one of them acts, whatever the connection already holds), and a last one for
/// every flag off (the top candidate). One candidate: a plain `resolve` with its server; none: `resolve` without a
/// server (the DNS rules and `dns.final` decide).
List<Map<String, dynamic>> resolveRules(List<DnsCandidate> l, {List<Map<String, dynamic>> match = const []}) {
  l = localLast(l);
  Map<String, dynamic> make(List<Map<String, dynamic>> parts, Map<String, dynamic> act) => parts.isEmpty
      ? act
      : parts.length == 1
          ? {...parts.first, ...act}
          : {'type': 'logical', 'mode': 'and', 'rules': parts, ...act};
  Map<String, dynamic> resolve(DnsCandidate c) => {'action': 'resolve', 'server': c.tag};
  if (l.isEmpty) return [make(match, {'action': 'resolve'})];
  if (l.length == 1) return [make(match, resolve(l.first))];
  return [
    for (var i = 0; i < l.length; i++)
      make([
        ...match,
        {'rule_set': [l[i].flagTag]},
        if (i > 0) {'rule_set': [for (final c in l.take(i)) c.flagTag], 'invert': true},
      ], resolve(l[i])),
    make([...match, {'rule_set': [for (final c in l) c.flagTag], 'invert': true}], resolve(l.first)),
  ];
}

/// Builds the routing part of a config. [group] adds a target's server group(s) the same
/// way as the main flow; [ruleSetFiles] = rule-set tag → local file, only the ones on disk;
/// [dnsFlagDir] = the directory of the DNS flag files (dns_flags.dart writes them).
Routing buildRouting(Map plan, GroupEmitter group, {Map<String, String> ruleSetFiles = const {}, String dnsFlagDir = 'dns-flags'}) =>
    _Builder(plan, group, ruleSetFiles, dnsFlagDir).build();

/// The DNS candidates of each side (`direct` / `vpn`) that a `routing.dns` plan ([dns]: the `dns` block of a plan's
/// `routing`) makes, in the order the DNS rules try them, without building a config. The address resolver
/// (address_resolver.dart) reads the direct side of it.
Map<String, List<DnsCandidate>> dnsSidesOf(Map dns, {String dnsFlagDir = 'dns-flags'}) {
  final b = _Builder({'routing': {'dns': dns}}, (tag, g, {detour}) {}, const {}, dnsFlagDir);
  b._dns();
  return {for (final e in b.out.dnsSides.entries) e.key: [...e.value]};
}

/// The addresses of the BUILT-IN providers ([builtin]: their ids) of a `routing.dns` plan that are not enabled for the
/// direct side: a provider that is off, a kind not in use, a provider without the direct side. Candidates on the direct
/// side with `inUse: false`, in the provider's order. The address resolver tries them only when every enabled server
/// failed (address_resolver.dart); they are not in the config and nobody checks them periodically.
List<DnsCandidate> dnsDisabledOf(Map dns, Set<String> builtin, {String dnsFlagDir = 'dns-flags'}) {
  final b = _Builder({'routing': {'dns': dns}}, (tag, g, {detour}) {}, const {}, dnsFlagDir);
  b._dns();
  final enabled = {for (final c in b.out.dnsSides['direct'] ?? const <DnsCandidate>[]) '${c.provider}|${c.kind}|${c.addr}'};
  return [
    for (final p in b._providers)
      if (builtin.contains(p.id))
        for (final t in p.transports)
          if ((p.system ? t.kind == dnsKindSystem : t.kind != dnsKindSystem) &&
              dnsServerJson('x', t.addr) != null &&
              !enabled.contains('${p.id}|${t.kind}|${t.addr}'))
            DnsCandidate(
              side: 'direct',
              provider: p.id,
              kind: t.kind,
              n: t.n,
              tag: b._tagOf(p, t.kind, t.n, 'direct'),
              addr: t.addr,
              flagTag: 'flag-${b._tagOf(p, t.kind, t.n, 'direct')}',
              flagPath: pth.join(dnsFlagDir, '${b._tagOf(p, t.kind, t.n, 'direct')}.json'),
              inUse: false,
            ),
  ];
}

/// A DNS provider of the plan (the old single-address server too), as the builder reads it.
class _Provider {
  _Provider(this.id, {required this.on, required this.system, required this.sides, required this.use, required this.transports});

  final String id;
  final bool on, system;
  final Set<String> sides, use;

  /// `n`: the number among the addresses of its kind, from 1 (0 for the OS resolver).
  final List<({String kind, String addr, int n})> transports;

  factory _Provider.of(Map s) {
    final id = '${s['id']}';
    final List<({String kind, String addr})> raw;
    Set<String> sides, use;
    if (s['transports'] is List) {
      raw = [for (final t in _list(s['transports'])) (kind: '${t['kind'] ?? dnsKindOf('${t['addr'] ?? ''}')}', addr: '${t['addr'] ?? ''}'.trim())];
      sides = {...(s['sides'] is List ? _strs(s['sides']) : const ['vpn'])};
      use = {...(s['use'] is List ? _strs(s['use']) : dnsUseDefault)};
    } else {
      final addr = '${s['addr'] ?? ''}'.trim();
      raw = [if (addr.isNotEmpty) (kind: dnsKindOf(addr), addr: addr)];
      sides = {s['via'] == 'direct' ? 'direct' : 'vpn'};
      use = {for (final t in raw) t.kind};
    }
    final system = raw.length == 1 && raw.first.kind == dnsKindSystem;
    if (system) sides = {'direct'}; // the OS resolver is not reached through the tunnel
    final counts = <String, int>{};
    return _Provider(id,
        on: s['on'] != false,
        system: system,
        sides: sides,
        use: use,
        transports: [for (final t in raw) (kind: t.kind, addr: t.addr, n: system ? 0 : (counts[t.kind] = (counts[t.kind] ?? 0) + 1))]);
  }
}

/// The DNS servers one kind of query goes through, in the order the DNS rules try them: a side's
/// candidates, or the candidates of one named provider on a side.
class _Chain {
  _Chain(this.list);

  final List<DnsCandidate> list;

  /// The same candidates in the same order are the same chain, whoever named them.
  late final String key = list.map((c) => c.tag).join(',');
}

/// The names one DNS rule group answers and the chain it goes through.
class _DnsGroup {
  _DnsGroup(this.chain, this.alts);

  final _Chain chain;
  final List<Map<String, dynamic>> alts;
}

class _Builder {
  _Builder(this.plan, this.group, this.files, this.flagDir) : r = _routing(plan);

  final Map plan;
  final Map<String, dynamic> r;
  final GroupEmitter group;
  final Map<String, String> files;
  final String flagDir;
  final out = Routing._();
  final _usedSets = <String>{};
  final _targetTags = <String, String?>{};

  Routing build() {
    _dns();
    // local addresses always go direct: first of all, in Global too (docs/rules.md §2)
    out._add({'ip_is_private': true, 'domain_suffix': lanSuffixes, ..._route('direct')}, const RuleOrigin('system', 'Private networks', id: 'private'));
    if (plan['global'] == true) {
      // Global: everything else through the main flow, rules included (docs/rules.md).
      out.finalOutbound = topTag;
      _dnsRules();
      _flagSets();
      return out;
    }
    _apps();
    _ownRules();
    _quick();
    _dnsRules();
    for (final tag in _usedSets) {
      final path = files[tag]!;
      out.ruleSets.add({'type': 'local', 'tag': tag, 'format': path.endsWith('.json') ? 'source' : 'binary', 'path': path});
    }
    _flagSets();
    return out;
  }

  /* ── DNS ── */

  late final List<_Provider> _providers;
  late final Map<String, _Provider> _providerById;
  late final bool _localFirst;

  /// The side that answers the queries no DNS rule claims (`dns.final`): the VPN side, with the main flow as
  /// the route's final; the direct side when "Everything else" is Direct.
  late final String _catchSide;
  _Chain? _catchChain;

  /// The bootstrap: resolves the hostnames of DoH / DoT servers.
  String _boot = 'local';

  void _dns() {
    final dns = (r['dns'] as Map?) ?? const {};
    _providers = [for (final s in _list(dns['servers'])) _Provider.of(s)];
    _providerById = {for (final p in _providers) p.id: p};
    _localFirst = dns['directPolicy'] != 'priority';
    final q = (r['quick'] as Map?) ?? const {};
    _catchSide = plan['global'] != true && q['final'] == 'direct' ? 'direct' : 'vpn';
    final system = _providers.where((p) => p.on && p.system).firstOrNull;
    _boot = system != null ? 'dns-${system.id}' : 'local';
    if (system == null) {
      out.dnsServers.add({'type': 'local', 'tag': 'local'});
      // the OS resolver has no provider of its own in the settings: watched by the Sentinel under a stable id
      out.dnsExtra.add((id: systemDnsId, tag: 'local'));
    }
    for (final side in dnsSidesAll) {
      out.dnsSides[side]!.addAll(_side(side));
    }
    out.dnsEnabled.addAll([for (final c in [...out.dnsSides['direct']!, ...out.dnsSides['vpn']!]) c.entry]);
    final directList = localLast(out.dnsSides['direct']!); // the OS resolver only when nothing else is on the side
    out.domainResolver = directList.isNotEmpty ? directList.first.tag : _boot;
    out.bootResolver = _boot;
    _catchChain = _autoChain(_catchSide);
    out.dnsFinal = _catchChain?.list.first.tag ?? _boot;
  }

  /// The providers in use, as the plan lists them. Local (when on) is pinned on the direct side by the policy,
  /// wherever the list has it: first under `localFirst`, last under `priority`. A side with nothing on is empty.
  List<DnsCandidate> _side(String side) {
    final all = [for (final p in _providers) if (p.on) ..._candidates(p, side)];
    if (side != 'direct') return all;
    final local = all.where((c) => c.kind == dnsKindSystem), rest = all.where((c) => c.kind != dnsKindSystem);
    return _localFirst ? [...local, ...rest] : [...rest, ...local];
  }

  final _made = <String, DnsCandidate>{};

  /// The candidates of [p] on [side]: its enabled transports with a usable address, in the provider's order.
  /// Each becomes a DNS server of the config (once) with its flag.
  List<DnsCandidate> _candidates(_Provider p, String side) {
    if (!p.sides.contains(side)) return const [];
    return [
      for (final t in p.transports)
        if ((p.system ? t.kind == dnsKindSystem : t.kind != dnsKindSystem && p.use.contains(t.kind)) && dnsServerJson('x', t.addr) != null)
          _made.putIfAbsent(_tagOf(p, t.kind, t.n, side), () => _candidate(p, t, side)),
    ];
  }

  String _tagOf(_Provider p, String kind, int n, String side) =>
      p.system ? 'dns-${p.id}' : 'dns-${p.id}-$kind$n${side == 'vpn' ? '-v' : ''}';

  DnsCandidate _candidate(_Provider p, ({String kind, String addr, int n}) t, String side) {
    final tag = _tagOf(p, t.kind, t.n, side);
    final c = DnsCandidate(
      side: side,
      provider: p.id,
      kind: t.kind,
      n: t.n,
      tag: tag,
      addr: t.addr,
      flagTag: 'flag-$tag',
      flagPath: pth.join(flagDir, '$tag.json'),
      inUse: p.on,
    );
    final j = dnsServerJson(tag, t.addr)!;
    if (c.vpn) {
      j['detour'] = topTag;
      out.dnsVpn.add(c.id);
    }
    if (j['server'] is String && InternetAddress.tryParse(j['server'] as String) == null) j['domain_resolver'] = _boot;
    out.dnsServers.add(j);
    out.dnsCandidates.add(c);
    return c;
  }

  /// The flags as local rule sets (`route.rule_set`), after the lists.
  void _flagSets() {
    for (final c in out.dnsCandidates) {
      out.ruleSets.add({'type': 'local', 'tag': c.flagTag, 'format': 'source', 'path': c.flagPath});
    }
    for (final f in out.fallbacks) {
      if (f.flagTag != null) out.ruleSets.add({'type': 'local', 'tag': f.flagTag, 'format': 'source', 'path': f.flagPath});
    }
  }

  /// In front of a rule that routes to a selector falling back to Direct: the names it sends direct once its target died
  /// are resolved by the flag-aware ladder of [chain] (the OS resolver last, [resolveRules]), only while the selector's
  /// flag is on; while it sits on the target nothing is resolved here. [act]: the rule's action; [match]: its conditions.
  void _resolveOnFallback(Map<String, dynamic>? act, _Chain? chain, Map<String, dynamic> match) {
    final f = act == null ? null : out.fallbacks.where((x) => x.tag == act['outbound'] && x.flagTag != null).firstOrNull;
    if (f == null || _needsIp(match)) return; // a rule that needs the IP has it already
    for (final step in resolveRules(chain?.list ?? const [], match: [match, {'rule_set': [f.flagTag]}])) {
      out._add(step);
    }
  }

  /// "Auto": the side's candidates in use; the other side's when it has none (a rule must still be answered).
  /// null = no server at all.
  _Chain? _autoChain(String side) {
    for (final s in [side, if (side == 'direct') 'vpn' else 'direct']) {
      final l = out.dnsSides[s]!;
      if (l.isNotEmpty) return _Chain(l);
    }
    return null;
  }

  /// A rule's DNS chain: "Auto" = the side of its traffic (direct → the direct side, VPN → the VPN side);
  /// or the provider the rule names (on in Settings → DNS or not) on that side, on its other side when it has
  /// no such. null = nothing can answer (no server is on).
  _Chain? _dnsFor(String? pick, {required bool direct}) {
    final side = direct ? 'direct' : 'vpn';
    final named = pick == null || pick == 'auto' ? null : _providerById[pick];
    if (named != null) {
      final s = named.sides.contains(side) ? side : dnsSidesAll.where(named.sides.contains).firstOrNull;
      final list = s == null ? const <DnsCandidate>[] : _candidates(named, s);
      if (list.isNotEmpty) {
        for (final c in list) {
          if (!c.inUse && !out.dnsExtra.any((e) => e.tag == c.tag)) out.dnsExtra.add(c.entry);
        }
        return _Chain(list);
      }
    }
    return _autoChain(side);
  }

  /// The DNS rule groups of the rules, in the rules' order; adjacent groups of one chain are one.
  final _groups = <_DnsGroup>[];

  /// DNS rule for the domains a rule matches (for the resolve step and, with TUN, the
  /// apps' own queries). Only domain conditions: DNS sees names, not IPs. What the catch-all side
  /// answers anyway needs none.
  void _dnsRule(List<Map<String, dynamic>> domainAlts, _Chain? chain, {bool force = false}) {
    if (chain == null || domainAlts.isEmpty || (chain.key == _catchChain?.key && !force)) return;
    final last = _groups.lastOrNull;
    if (last != null && last.chain.key == chain.key) {
      last.alts.addAll(domainAlts);
    } else {
      _groups.add(_DnsGroup(chain, [...domainAlts]));
    }
  }

  Map<String, dynamic> _or(List<Map<String, dynamic>> alts) => alts.length == 1 ? alts.first : {'type': 'logical', 'mode': 'or', 'rules': alts};

  /// The DNS rules: first the groups of the rules, then the queries nobody claimed (the catch-all side).
  /// A chain of several candidates is a rule per candidate, `AND(names, flag) → server`, in priority order,
  /// so the first live one answers; with every flag off the chain's top candidate does (a rule without a
  /// flag after them, `dns.final` for the catch-all). One candidate needs no flag.
  void _dnsRules() {
    _flagChecks();
    for (final g in _groups) {
      out.dnsRules.addAll(dnsChainRules(_or(g.alts), g.chain.list));
    }
    final catchList = _catchChain?.list ?? const <DnsCandidate>[];
    if (catchList.length > 1) out.dnsRules.addAll(dnsChainRules(null, catchList, fallback: false));
  }

  /// The flagcheck of each side that has several candidates (first among the DNS rules): [dnsFlagcheckName] is answered, with no network, by
  /// a predefined A record naming the side's effective candidate; the core asks it through the probe inbound
  /// after each flag write to see that sing-box applied the file (probe.dart `flagChecks`).
  void _flagChecks() {
    for (final side in dnsSidesAll) {
      final l = out.dnsSides[side]!;
      final checks = [for (var i = 0; i < l.length && i < 253; i++) DnsFlagCheck(candidate: l[i], address: '127.77.${dnsSidesAll.indexOf(side) + 1}.${i + 1}')];
      if (checks.length < 2) continue; // a side with one candidate has no flag rule to look at
      out.dnsFlagChecks.addAll(checks);
      final name = dnsFlagcheckName(side);
      out.dnsRules.addAll(dnsChainRules({'domain': [name]}, [for (final k in checks) k.candidate], action: (c, i) {
        return {'action': 'predefined', 'rcode': 'NOERROR', 'answer': ['$name. IN A ${checks[i].address}']};
      }));
    }
  }

  /// A route rule `resolve` (no server) in front of a rule that sends names direct: the names are resolved by
  /// the DNS rules (so by the flags and the rule's provider), and the direct outbound uses the addresses.
  /// Without it the direct outbound resolves with `default_domain_resolver`, which no rule can move.
  void _resolveFirst(Map<String, dynamic> match) => out._add({...match, 'action': 'resolve'});

  /// The same for what [match] names without domains (an app, a source, a network): the DNS rules can tell it too,
  /// as a query of a route `resolve` carries the connection's own process / package / network / inbound / source
  /// (measured on sing-box 1.14.2; not its destination port), so [match] becomes one more alternative of the
  /// rule group of [chain] (`AND(OR(matches), flag) → server` per candidate) and the step in front of the rule is
  /// the same plain `resolve`: the number of rules grows with the candidates, not with the apps and rules.
  /// What the DNS rules cannot tell (a port, an unknown rule set, an IP) is resolved explicitly, through a ladder
  /// over the chain's flags ([resolveRules]: a rule per candidate), which is the only part that multiplies.
  /// No chain: the DNS rules decide ([chain] null → the plain step).
  void _resolveDirect(_Chain? chain, Map<String, dynamic> match) {
    if (chain == null || dnsMatchable(match)) {
      _resolveFirst(match);
      if (chain != null) _dnsRule([match], chain, force: true);
      return;
    }
    for (final step in resolveRules(chain.list, match: [match])) {
      out._add(step);
    }
  }

  /* ── Targets and actions ── */

  /// The outbound tag of a target, adding its groups once; null = unavailable now.
  String? _target(String t) {
    if (t.isEmpty) return topTag;
    return _targetTags.putIfAbsent(t, () {
      final spec = ((r['targets'] as Map?) ?? const {})[t] as Map?;
      bool usable(Object? g) => g is Map && (g['nodes'] as List? ?? const []).isNotEmpty;
      if (spec == null || !usable(spec['main'])) return null;
      if (spec['kind'] == 'chain') {
        if (!usable(spec['entry'])) return null;
        group('$t>entry', spec['entry'] as Map);
        group(t, spec['main'] as Map, detour: '$t>entry');
      } else {
        group(t, spec['main'] as Map);
      }
      return t;
    });
  }

  Map<String, dynamic> _reject({bool drop = false}) => {'action': 'reject', if (drop) 'method': 'drop'};
  Map<String, dynamic> _route(String outbound) => {'action': 'route', 'outbound': outbound};

  static const _keywords = {'main', 'block', 'direct'};

  /// Proxy through [target]; unavailable → [fallback] (default / main / block / direct, or
  /// another target: see the library comment). Unavailable now = the config's choice; a target
  /// that goes down later is the core's (fallback.dart): the route leads to a selector
  /// [target, fallback outbound] it flips. [label] names the rule / app ([app]) in the journal.
  ({Map<String, dynamic> action, bool direct}) _proxyAction(String target, String fallback, String label, {bool app = false}) {
    final tag = _target(target);
    if (tag == topTag) return (action: _mainFlowAction(fallback, label, app), direct: false);
    // default = the global one; a target that is not usable now = the global one too; the
    // target itself (a fallback to itself) or empty = the main flow
    String? fbTarget;
    if (fallback.isEmpty || fallback == 'default') {
      fallback = _fallback;
    } else if (!_keywords.contains(fallback)) {
      if (fallback == target) {
        fallback = 'main';
      } else if (_target(fallback) != null) {
        fbTarget = fallback;
      } else {
        out.warnings.add('$label: "If unavailable" target $fallback is not available, the default applies');
        fallback = _fallback;
      }
    }
    if (tag == null && fbTarget != null) {
      // the target is out now: straight to the fallback target (the main flow behind it)
      return _proxyAction(fbTarget, 'main', label, app: app);
    }
    if (tag != null) {
      final fb = fbTarget ??
          switch (fallback) {
            'block' => _blockOutbound(),
            'direct' => 'direct',
            _ => topTag,
          };
      return (action: _route(_fallbackSelector(target, fb, label, app, fbTarget: fbTarget)), direct: false);
    }
    return switch (fallback) {
      'block' => (action: _reject(), direct: false),
      'direct' => (action: _route('direct'), direct: true),
      _ => (action: _route(topTag), direct: false),
    };
  }

  /// Through the main flow. It has "If unavailable" only when one is asked for explicitly
  /// (never the global default; `default` / `main` / empty / a target that is not available
  /// = none, the last with a warning): `block`, `direct` or a target of the catalog, as a
  /// selector [main flow, fallback] the core flips when the main flow dies (fallback.dart).
  Map<String, dynamic> _mainFlowAction(String fallback, String label, bool app) {
    switch (fallback) {
      case '' || 'default' || 'main':
        break;
      case 'block':
        return _route(_fallbackSelector('', _blockOutbound(), label, app));
      case 'direct':
        return _route(_fallbackSelector('', 'direct', label, app));
      default:
        if (_target(fallback) != null) return _route(_fallbackSelector('', fallback, label, app, fbTarget: fallback));
        out.warnings.add('$label: "If unavailable" target $fallback is not available, the main flow has none');
    }
    return _route(topTag);
  }

  /// Block as an outbound: only a selector can hold it (a rule blocks with `reject`).
  /// sing-box 1.11.10 brought `block` back for selectors.
  String _blockOutbound() {
    if (!out.outbounds.any((o) => o['tag'] == 'block')) out.outbounds.add({'type': 'block', 'tag': 'block'});
    return 'block';
  }

  /// The selector [target, fallbackTag] for [target] (once per pair; '' = the main flow, as
  /// [topTag]): the config's `default` is the target, the core moves it. With a [fbTarget] (a
  /// catalog target as the fallback) a catalog target also has the main flow as the third
  /// member: both down.
  String _fallbackSelector(String target, String fallbackTag, String label, bool app, {String? fbTarget}) {
    final main = target.isEmpty;
    if (main) target = topTag;
    final tag = '$target~$fallbackTag';
    var f = out.fallbacks.where((x) => x.tag == tag).firstOrNull;
    if (f == null) {
      // no `targets` key = an empty catalog: only the main flow has a selector then (a catalog
      // target that is not there never gets here, [_target] said null)
      final targets = (r['targets'] as Map?) ?? const {};
      f = TargetFallback(tag, target, main ? const {} : (targets[target] as Map?) ?? const {}, fallbackTag,
          fallbackTarget: fbTarget, fallbackSpec: fbTarget == null ? null : (targets[fbTarget] as Map?) ?? const {});
      out.fallbacks.add(f);
      if (fallbackTag == 'direct') {
        final i = out.fallbacks.length - 1;
        f.flagTag = 'flag-fb$i';
        f.flagPath = pth.join(flagDir, 'fb$i.json');
      }
      out.outbounds.add({
        'type': 'selector',
        'tag': tag,
        'outbounds': [target, fallbackTag, if (fbTarget != null && !main) topTag],
        'default': target,
        // a switch keeps the open connections; the core closes the stalled ones (stall.dart)
        'interrupt_exist_connections': false,
      });
    }
    final names = app ? f.apps : f.rules;
    if (!names.contains(label)) names.add(label);
    return tag;
  }

  /// The global "If unavailable": a keyword only.
  String get _fallback => _keywords.contains('${r['fallback']}') ? '${r['fallback']}' : 'main';

  /* ── Apps: first in the order ── */

  /// An app's rules: one for all its traffic, or with `split` one per network (TCP = the
  /// app's own fields, UDP = `udp`). A half that is `default` has no rule: its traffic goes
  /// by the rules below. A proxy half has "If unavailable" like a rule's.
  void _apps() {
    for (final a in _list(r['apps'])) {
      final id = '${a['id'] ?? ''}';
      if (id.isEmpty) continue;
      final field = switch (a['kind']) { 'process' => 'process_name', 'path' => 'process_path', _ => 'package_name' };
      final match = <String, dynamic>{field: [id]};
      final label = '${a['name'] ?? ''}'.isNotEmpty ? '${a['name']}' : id;
      void half(Map h, List<String>? network) {
        final fallback = '${h['fallback'] ?? 'default'}';
        var direct = false;
        final act = switch (h['act']) {
          'block' => _reject(),
          'direct' => () {
              direct = true;
              return _route('direct');
            }(),
          'proxy' => () {
              final p = _proxyAction('${h['target'] ?? ''}', fallback, label, app: true);
              direct = p.direct;
              return p.action;
            }(),
          // Default has a rule only to give the main flow an "If unavailable" (it then goes by
          // the selector, not by the rules below); none asked for = by the rules below
          _ => switch (_mainFlowAction(fallback, label, true)) { {'outbound': topTag} => null, final a => a },
        };
        final name = network == null ? label : '$label (${network.first.toUpperCase()})';
        // an app that goes direct has its names resolved by the first live candidate of the direct side
        if (act != null && direct) _resolveDirect(_autoChain('direct'), {...match, 'network': ?network});
        _resolveOnFallback(act, _autoChain('direct'), {...match, 'network': ?network});
        if (act != null) out._add({...match, 'network': ?network, ...act}, RuleOrigin('app', name, id: id));
      }

      if (a['split'] == true) {
        half(a, ['tcp']);
        half((a['udp'] as Map?) ?? const {}, ['udp']);
      } else {
        half(a, null);
      }
    }
  }

  /* ── Own rules ── */

  String? _set(String tag) {
    if (!files.containsKey(tag)) return null;
    _usedSets.add(tag);
    return tag;
  }

  void _ownRules() {
    var resolved = false;
    for (final rule in _list(r['rules'])) {
      final title = '${rule['name'] ?? ''}'.isNotEmpty ? '"${rule['name']}"' : 'rule ${rule['id']}';
      final built = rule['composite'] is Map ? _composite(rule['composite'] as Map, title) : _conditions(rule, title);
      if (built == null) continue;
      final action = '${rule['action'] ?? 'proxy'}';
      final fallback = '${rule['fallback'] ?? 'default'}';
      final dns = rule['dns']?.toString();
      late final Map<String, dynamic> act;
      var direct = false;
      switch (action) {
        case 'block':
          act = _reject(drop: rule['block'] != 'reject');
        case 'direct':
          act = _route('direct');
          direct = true;
        default:
          final p = _proxyAction('${rule['target'] ?? ''}', fallback, '${rule['name'] ?? ''}'.isNotEmpty ? '${rule['name']}' : 'rule ${rule['id']}');
          act = p.action;
          direct = p.direct;
      }
      // IP conditions need the destination's IP: resolve it once, before the first such rule
      // that has not asked to see IPs only when known (`ipTunOnly`). Later rules see the
      // resolved address whatever their flag says (sing-box resolves once).
      // In TUN the destination IP of tun-in traffic arrives as it is: no step for it; the proxy
      // ports (mixed-in, sys-in) stay open in TUN and bring domains, so the step is limited to them.
      if (!resolved && rule['ipTunOnly'] != true && _needsIp(built.match)) {
        resolved = true;
        for (final step in _resolveStep([if (plan['mode'] == 'tun') {'inbound': const ['mixed-in', 'sys-in']}])) {
          out._add(step);
        }
      }
      final chain = action == 'block' ? null : _dnsFor(dns, direct: direct);
      // a direct rule's names are resolved here (the direct outbound uses the addresses and never asks a resolver
      // of its own): by the DNS rules when the rule names domains (so by the rule's DNS provider and the flags),
      // else by the first live candidate of its DNS chain; a rule that needs the IP has it already
      if (direct) {
        if (built.domainAlts.isNotEmpty) {
          _resolveFirst(built.match);
        } else if (!_needsIp(built.match)) {
          _resolveDirect(chain, built.match);
        }
      }
      if (action != 'block') _resolveOnFallback(act, _dnsFor(dns, direct: true), built.match);
      out._add({...built.match, ...act, ...((rule['extra'] as Map?) ?? const {}).cast<String, dynamic>()},
          RuleOrigin('user', '${rule['name'] ?? ''}'.isNotEmpty ? '${rule['name']}' : 'rule ${rule['id']}', id: '${rule['id'] ?? ''}'));
      if (action != 'block') {
        _dnsRule(built.domainAlts, chain);
        final id = '${rule['id'] ?? ''}';
        if (id.isNotEmpty) {
          out.ruleDns[id] = chain?.list.first.tag ?? out.dnsFinal;
          out.ruleChains[id] = [for (final c in chain?.list ?? const <DnsCandidate>[]) c.tag];
        }
      }
    }
  }

  /// The `resolve` step before the IP rules (Settings → DNS "Resolve for IP rules",
  /// `dns.resolve`): null = off. `auto` (also a provider that is deleted or off) = the top candidate of
  /// the VPN side, so the name never goes to the provider's DNS; a provider id = its candidates (on the
  /// VPN side when it has one). The server is named explicitly (the rules' own DNS servers do not apply to this
  /// step) but it follows the flags: the first live candidate of the list resolves ([resolveRules]). No VPN
  /// candidate: `resolve` without a server (the DNS rules and `dns.final` decide), with a warning.
  List<Map<String, dynamic>> _resolveStep(List<Map<String, dynamic>> match) {
    final pick = '${((r['dns'] as Map?) ?? const {})['resolve'] ?? 'auto'}';
    if (pick == 'off') return const [];
    final named = pick == 'auto' ? null : _providerById[pick];
    final fromNamed = named != null && named.on ? _dnsFor(pick, direct: false)?.list : null;
    final list = fromNamed != null && fromNamed.isNotEmpty ? fromNamed : out.dnsSides['vpn']!;
    if (list.isEmpty && out.dnsEnabled.isNotEmpty) {
      out.warnings.add('Resolve for IP rules: no DNS server via VPN is on, the first one in use resolves and its query may leave outside the tunnel');
    }
    return resolveRules(list, match: match);
  }

  bool _needsIp(Object? o) => switch (o) {
        Map m => m.keys.any((k) => k == 'ip_cidr' || k == 'ip_is_private') ||
            _strs(m['rule_set']).any((t) => t.startsWith('geoip-')) ||
            m.values.any(_needsIp),
        List l => l.any(_needsIp),
        _ => false,
      };

  /// The rule's condition groups → one match (a flat rule when sing-box's own logic gives
  /// the same meaning, else logical AND of the groups). null = the rule can never be
  /// built faithfully (a list it names is missing, every value bad) — it is skipped.
  ({Map<String, dynamic> match, List<Map<String, dynamic>> domainAlts})? _conditions(Map rule, String title) {
    final groups = ((rule['groups'] as Map?) ?? const {}).cast<String, dynamic>();
    final parts = <(String, bool, List<Map<String, dynamic>>)>[];
    var domainAlts = <Map<String, dynamic>>[];
    for (final key in const ['domain', 'ip', 'port', 'source', 'network', 'process']) {
      final g = groups[key] as Map?;
      if (g == null) continue;
      final not = g['not'] == true;
      final missing = <String>[];
      final alts = _alts(key, g, missing);
      if (missing.isNotEmpty && (not || alts.isEmpty)) {
        out.warnings.add('Rule $title skipped: ${missing.join(', ')} not available');
        return null;
      }
      if (missing.isNotEmpty) out.warnings.add('Rule $title: ${missing.join(', ')} not available, the rest of it works');
      if (alts.isEmpty) continue;
      if (key == 'domain' && !not) domainAlts = alts.where((a) => !a.containsKey('rule_set') || _strs(a['rule_set']).every((t) => t.startsWith('geosite-'))).toList();
      parts.add((key, not, alts));
    }
    if (parts.isEmpty) {
      out.warnings.add('Rule $title skipped: no conditions');
      return null;
    }
    Map<String, dynamic> one((String, bool, List<Map<String, dynamic>>) p) {
      final (_, not, alts) = p;
      final m = alts.length == 1 ? {...alts.first} : <String, dynamic>{'type': 'logical', 'mode': 'or', 'rules': alts};
      if (not) m['invert'] = true;
      return m;
    }

    // sing-box ORs domain and IP fields inside one rule; the form promises AND.
    final keys = parts.map((p) => p.$1).toSet();
    final flat = parts.every((p) => !p.$2 && p.$3.length == 1) && !(keys.contains('domain') && keys.contains('ip'));
    final Map<String, dynamic> match;
    if (parts.length == 1) {
      match = one(parts.first);
    } else if (flat) {
      match = {for (final p in parts) ...p.$3.first};
    } else {
      match = {'type': 'logical', 'mode': 'and', 'rules': [for (final p in parts) one(p)]};
    }
    return (match: match, domainAlts: domainAlts);
  }

  /// One condition group → alternatives (OR). [missing] collects lists not on disk.
  List<Map<String, dynamic>> _alts(String key, Map g, List<String> missing) {
    final v = ((g['v'] as Map?) ?? const {}).cast<String, dynamic>();
    List<String> f(String name) => _strs(v[name]).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final alts = <Map<String, dynamic>>[];
    void add(Map<String, dynamic> m) {
      m.removeWhere((_, x) => x is List && x.isEmpty);
      if (m.isNotEmpty) alts.add(m);
    }

    List<String> sets(List<String> names, String Function(String) tagOf, String label) {
      final tags = <String>[];
      for (final n in names) {
        final t = _set(tagOf(n));
        t != null ? tags.add(t) : missing.add('$label$n');
      }
      return tags;
    }

    switch (key) {
      case 'domain':
        final exact = f('domain');
        add({
          'domain': exact.where((d) => !d.startsWith('*.')).toList(),
          'domain_suffix': [...f('domain_suffix').map((d) => d.startsWith('.') ? d.substring(1) : d), ...exact.where((d) => d.startsWith('*.')).map((d) => d.substring(2))],
          'domain_keyword': f('domain_keyword'),
          'domain_regex': f('domain_regex'),
        });
        add({'rule_set': [...sets(f('geosite'), geositeTag, 'geosite:'), ...sets(f('rule_set'), userSetTag, 'rule set ')]});
      case 'ip':
        final cidrs = <String>[];
        for (final x in f('ip_cidr')) {
          final c = ipToCidrs(x);
          if (c == null) {
            missing.add('bad IP "$x"');
          } else {
            cidrs.addAll(c);
          }
        }
        add({'ip_cidr': cidrs, if (g['flag'] == true) 'ip_is_private': true});
        add({'rule_set': sets(f('geoip'), geoipTag, 'geoip:')});
      case 'port':
      case 'source':
        final m = <String, dynamic>{};
        if (key == 'source') {
          final cidrs = [for (final x in f('source_ip_cidr')) ...?ipToCidrs(x)];
          if (cidrs.isNotEmpty) m['source_ip_cidr'] = cidrs;
        }
        final field = key == 'port' ? 'port' : 'source_port';
        final (one, ranges) = splitPorts(f(field), (bad) => missing.add('bad port "$bad"'));
        if (one.isNotEmpty) m[field] = one;
        if (ranges.isNotEmpty) m['${field}_range'] = ranges;
        add(m);
      case 'network':
        add({'network': f('network'), 'protocol': f('protocol')});
      case 'process':
        final vals = f('process');
        final paths = vals.where((x) => x.contains('/') || x.contains(r'\')).toList();
        add({'process_name': vals.where((x) => !paths.contains(x)).toList()});
        add({'process_path': paths.where((x) => !x.contains('*')).toList()});
        add({'process_path_regex': paths.where((x) => x.contains('*')).map(globToRegex).toList()});
    }
    return alts;
  }

  /// A rule written in JSON (logical, nested): passed as is, with geosite / geoip / named
  /// rule sets swapped for the local lists.
  ({Map<String, dynamic> match, List<Map<String, dynamic>> domainAlts})? _composite(Map c, String title) {
    final missing = <String>[];
    final userNames = {for (final s in _list(r['ruleSets'])) '${s['name']}'};
    Object? walk(Object? o) {
      if (o is List) return o.map(walk).toList();
      if (o is! Map) return o;
      final m = <String, dynamic>{};
      final sets = <String>[];
      o.forEach((k, v) {
        if (k == 'action' || k == 'outbound' || k == 'method') return;
        if (k == 'geosite' || k == 'geoip' || k == 'rule_set') {
          for (final n in _strs(v)) {
            final tag = k == 'geosite' ? geositeTag(n) : k == 'geoip' ? geoipTag(n) : userNames.contains(n) ? userSetTag(n) : n;
            if (_set(tag) != null) {
              sets.add(tag);
            } else {
              missing.add(k == 'rule_set' ? 'rule set $n' : '$k:$n');
            }
          }
        } else {
          m['$k'] = walk(v);
        }
      });
      if (sets.isNotEmpty) m['rule_set'] = sets;
      return m;
    }

    final m = walk(c) as Map<String, dynamic>;
    if (missing.isNotEmpty) {
      // inside a composite rule a missing list can flip its meaning: leave it out
      out.warnings.add('Rule $title skipped: ${missing.join(', ')} not available');
      return null;
    }
    return (match: m, domainAlts: const []);
  }

  /* ── Quick rules, then everything else ── */

  void _quick() {
    final q = ((r['quick'] as Map?) ?? const {}).cast<String, dynamic>();
    if (q['ads'] == true) {
      final set = _set(geositeTag(adsGeosite));
      out._add({'domain_suffix': adsDomains, if (set != null) 'rule_set': [set], ..._reject()}, const RuleOrigin('quick', 'Block ads', id: 'ads'));
      if (set == null) out.warnings.add('Block ads: the ad list is not downloaded yet, only a few known domains are blocked');
    }
    final svc = ((q['services'] as Map?) ?? const {}).cast<String, dynamic>();
    for (final MapEntry(:key, :value) in svc.entries) {
      final s = services[key];
      if (s == null || (value != 'vpn' && value != 'direct')) continue;
      final direct = value == 'direct';
      final domains = <Map<String, dynamic>>[
        {'domain_suffix': s.domains},
        if (s.geosite.map((n) => _set(geositeTag(n))).nonNulls.toList() case final l when l.isNotEmpty) {'rule_set': l},
      ];
      final ips = s.geoip.map((n) => _set(geoipTag(n))).nonNulls.toList();
      final alts = [...domains, if (ips.isNotEmpty) {'rule_set': ips}];
      if (direct) _resolveFirst(_or(domains));
      out._add({...(alts.length == 1 ? alts.first : {'type': 'logical', 'mode': 'or', 'rules': alts}), ..._route(direct ? 'direct' : topTag)},
          RuleOrigin('service', serviceTitles[key] ?? key, id: key));
      _dnsRule(domains, _dnsFor('auto', direct: direct));
    }
    final reg = regions[q['region']];
    if (reg != null) {
      final sites = reg.geosite.map((n) => _set(geositeTag(n))).nonNulls.toList();
      final ips = reg.geoip.map((n) => _set(geoipTag(n))).nonNulls.toList();
      final domains = <Map<String, dynamic>>[
        {'domain_suffix': reg.tlds},
        if (sites.isNotEmpty) {'rule_set': sites},
      ];
      final alts = [...domains, if (ips.isNotEmpty) {'rule_set': ips}];
      _resolveFirst(_or(domains));
      out._add({'type': 'logical', 'mode': 'or', 'rules': alts, ..._route('direct')}, const RuleOrigin('quick', 'My region direct', id: 'region'));
      _dnsRule(domains, _dnsFor('auto', direct: true));
      if (sites.length < reg.geosite.length || ips.length < reg.geoip.length) {
        out.warnings.add('My region direct: the ${q['region']} lists are not downloaded yet, only its domains (.${reg.tlds.first}) go direct');
      }
    }
    switch (q['final']) {
      case 'direct':
        // everything else goes direct: its names are resolved by the DNS rules (the direct side answers them)
        out._add({'action': 'resolve'});
        out.finalOutbound = 'direct';
      case 'block':
        out._add(_reject());
      default:
        out.finalOutbound = topTag;
    }
  }
}

/* ── Values ── */

/// A typed DNS server from a Settings → DNS address: `system`, `1.1.1.1[:53]`,
/// `udp|tcp|tls|quic|https://host[:port][/path]`. null = not an address.
Map<String, dynamic>? dnsServerJson(String tag, String addr) {
  addr = addr.trim();
  if (addr == 'system') return {'type': 'local', 'tag': tag};
  final bare = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d+))?$').firstMatch(addr);
  if (bare != null) {
    if (InternetAddress.tryParse(bare[1]!) == null) return null;
    return {'type': 'udp', 'tag': tag, 'server': bare[1], if (bare[2] != null) 'server_port': int.parse(bare[2]!)};
  }
  final u = Uri.tryParse(addr);
  if (u == null || u.host.isEmpty || !const {'udp', 'tcp', 'tls', 'quic', 'https'}.contains(u.scheme)) return null;
  return {
    'type': u.scheme,
    'tag': tag,
    'server': u.host,
    if (u.hasPort) 'server_port': u.port,
    if (u.scheme == 'https' && u.path.isNotEmpty && u.path != '/' && u.path != '/dns-query') 'path': u.path,
  };
}

/// An IP, CIDR or IPv4 range (1.1.1.1-1.1.1.9) → CIDR blocks; null = not valid.
List<String>? ipToCidrs(String v) {
  v = v.trim();
  final range = v.split('-');
  if (range.length == 2) {
    final a = _ip4(range[0]), b = _ip4(range[1]);
    if (a == null || b == null || a > b) return null;
    final out = <String>[];
    var s = a;
    while (s <= b) {
      var size = 32;
      while (size > 0) {
        final block = 1 << (32 - size + 1);
        if (s % block != 0 || s + block - 1 > b) break;
        size--;
      }
      out.add('${[24, 16, 8, 0].map((sh) => (s >> sh) & 255).join('.')}/$size');
      s += 1 << (32 - size);
    }
    return out;
  }
  final parts = v.split('/');
  final ip = InternetAddress.tryParse(parts[0]);
  if (ip == null || parts.length > 2) return null;
  if (parts.length == 2) {
    final p = int.tryParse(parts[1]);
    if (p == null || p < 0 || p > (ip.type == InternetAddressType.IPv4 ? 32 : 128)) return null;
  }
  return [v];
}

int? _ip4(String s) {
  final p = s.trim().split('.');
  if (p.length != 4) return null;
  var n = 0;
  for (final o in p) {
    final x = int.tryParse(o);
    if (x == null || x < 0 || x > 255) return null;
    n = n * 256 + x;
  }
  return n;
}

/// '443', '8000-9000' → ports and sing-box ranges ('8000:9000').
(List<int>, List<String>) splitPorts(List<String> vals, void Function(String bad) onBad) {
  final one = <int>[], ranges = <String>[];
  for (final v in vals) {
    final m = RegExp(r'^(\d+)(?:\s*[-:]\s*(\d+))?$').firstMatch(v.trim());
    final a = m == null ? null : int.parse(m[1]!), b = m?[2] == null ? a : int.parse(m![2]!);
    if (a == null || b == null || a < 1 || b > 65535 || a > b) {
      onBad(v);
    } else if (a == b) {
      one.add(a);
    } else {
      ranges.add('$a:$b');
    }
  }
  return (one, ranges);
}

/// A process path with `*` → a process_path_regex (case-insensitive for Windows paths).
String globToRegex(String glob) {
  final body = glob.split('*').map(RegExp.escape).join('.*');
  final windows = glob.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(glob);
  return '${windows ? '(?i)' : ''}^$body\$';
}
