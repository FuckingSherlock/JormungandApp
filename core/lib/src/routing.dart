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
///   dns: { servers: [{ id, addr, via: 'direct'|'vpn', on }],            // in priority order
///          resolve: 'auto'|'off'|<dns id>,    // `resolve` before IP rules (proxy port only); default 'auto'
///          hijack?: bool }                    // TUN: the core answers every DNS query; default on (config.dart)
/// }
/// ```
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
/// answering (fallback.dart). With two or more DNS servers in use each also has a DNS rule for its own
/// clash mode, for the DNS failover (dns_failover.dart).
library;

import 'dart:io';

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

  /// `proxy` (the main flow), `direct` / `direct@dns-<id>`, or `block`; for a target as the
  /// fallback, that target's group (= its id).
  final String fallbackTag;

  /// The UI's id of the fallback when it is a target of the catalog (null for the keywords),
  /// with its `targets` entry. The selector then also holds the main flow, where traffic goes
  /// while both the target and this one are down.
  final String? fallbackTarget;
  final Map? fallbackSpec;

  /// The rules and the apps that route here (their names, for the journal).
  final rules = <String>[];
  final apps = <String>[];

  /// The fallback as the journal names it: 'block' | 'direct' | 'main', or the fallback
  /// target's id.
  String get to => fallbackTarget ?? (fallbackTag == 'block' ? 'block' : (fallbackTag == topTag ? 'main' : 'direct'));
}

/// A DNS server in use ([id] = the UI's, [tag] = `dns-<id>` in the config) — the core
/// checks each one and switches between them (dns_failover.dart).
typedef DnsEntry = ({String id, String tag});

/// What [buildConfig] learned besides the config, for the services that run beside sing-box.
class RoutingInfo {
  /// One per selector, in the order the rules use them.
  final fallbacks = <TargetFallback>[];

  /// The config's route rules by the text sing-box reports for a connection (rulenames.dart):
  /// Live connections name the rule a connection went by with it.
  final ruleNames = RuleNames();

  /// The enabled DNS servers by priority: the first is `dns.final`.
  final dnsServers = <DnsEntry>[];
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

  /// Outbounds besides the target groups (added through the emitter): direct ones with
  /// their own DNS server.
  final outbounds = <Map<String, dynamic>>[];

  /// The "If unavailable" selectors rules and apps route to (see [TargetFallback]).
  final fallbacks = <TargetFallback>[];
  String finalOutbound = topTag;
  final dnsServers = <Map<String, dynamic>>[];
  final dnsRules = <Map<String, dynamic>>[];
  String dnsFinal = 'local';

  /// The servers in use, by priority; with two or more, each also has a DNS rule for its
  /// own clash mode (its tag), so the core can make any of them the default ([dnsModeOf]).
  final dnsEnabled = <DnsEntry>[];

  /// Resolves the servers' own hostnames (proxy outbounds, DoH hosts) and what goes out
  /// directly: a direct DNS server, never one that needs the tunnel.
  String domainResolver = 'local';

  /// `route.rule_set`: local files only.
  final ruleSets = <Map<String, dynamic>>[];

  /// Rules left out or narrowed (a list not downloaded, a bad value) — told to the user.
  final warnings = <String>[];
}

/// Builds the routing part of a config. [group] adds a target's server group(s) the same
/// way as the main flow; [ruleSetFiles] = rule-set tag → local file, only the ones on disk.
Routing buildRouting(Map plan, GroupEmitter group, {Map<String, String> ruleSetFiles = const {}}) =>
    _Builder(plan, group, ruleSetFiles).build();

class _Builder {
  _Builder(this.plan, this.group, this.files) : r = _routing(plan);

  final Map plan;
  final Map<String, dynamic> r;
  final GroupEmitter group;
  final Map<String, String> files;
  final out = Routing._();
  final _usedSets = <String>{};
  final _targetTags = <String, String?>{};
  late final Map<String, Map> _dnsById;
  late final List<Map> _dnsOn;

  Routing build() {
    _dns();
    // local addresses always go direct: first of all, in Global too (docs/rules.md §2)
    out._add({'ip_is_private': true, 'domain_suffix': lanSuffixes, ..._route('direct')}, const RuleOrigin('system', 'Private networks', id: 'private'));
    if (plan['global'] == true) {
      // Global: everything else through the main flow, rules included (docs/rules.md).
      out.finalOutbound = topTag;
      _dnsModes();
      return out;
    }
    _apps();
    _ownRules();
    _quick();
    _dnsModes();
    for (final tag in _usedSets) {
      final path = files[tag]!;
      out.ruleSets.add({'type': 'local', 'tag': tag, 'format': path.endsWith('.json') ? 'source' : 'binary', 'path': path});
    }
    return out;
  }

  /* ── DNS ── */

  String _dnsTag(Map s) => 'dns-${s['id']}';
  bool _isSystem(Map s) => '${s['addr']}'.trim() == 'system';
  bool _viaVpn(Map s) => s['via'] == 'vpn' && !_isSystem(s);

  void _dns() {
    final all = _list(((r['dns'] as Map?) ?? const {})['servers']);
    _dnsById = {for (final s in all) '${s['id']}': s};
    _dnsOn = all.where((s) => s['on'] != false && dnsServerJson('x', '${s['addr']}') != null).toList();
    final system = _dnsOn.where(_isSystem).firstOrNull;
    // the bootstrap: resolves DoH / DoT hostnames and, without a direct server, the rest
    _boot = system != null ? _dnsTag(system) : 'local';
    if (system == null) out.dnsServers.add({'type': 'local', 'tag': 'local'});
    for (final s in _dnsOn) {
      _addDnsServer(s);
    }
    out.dnsFinal = _dnsOn.isEmpty ? _boot : _dnsTag(_dnsOn.first);
    out.dnsEnabled.addAll([for (final s in _dnsOn) (id: '${s['id']}', tag: _dnsTag(s))]);
    final direct = _dnsOn.where((s) => !_viaVpn(s)).firstOrNull;
    out.domainResolver = direct != null ? _dnsTag(direct) : _boot;
  }

  String _boot = 'local';
  final _dnsAdded = <String>{};
  void _addDnsServer(Map s) {
    final tag = _dnsTag(s);
    if (!_dnsAdded.add(tag)) return;
    final j = dnsServerJson(tag, '${s['addr']}')!;
    if (_viaVpn(s)) j['detour'] = topTag;
    if (j['server'] is String && InternetAddress.tryParse(j['server'] as String) == null) j['domain_resolver'] = _boot;
    out.dnsServers.add(j);
  }

  /// A rule's DNS server: "Auto" = the first server in use whose route matches the
  /// traffic's (direct → a direct one, VPN → one via VPN); or the one the rule names
  /// (ticked in Settings → DNS or not).
  String _dnsFor(String? pick, {required bool direct}) {
    final named = pick == null || pick == 'auto' ? null : _dnsById[pick];
    if (named != null && dnsServerJson('x', '${named['addr']}') != null) {
      _addDnsServer(named);
      return _dnsTag(named);
    }
    final auto = _dnsOn.where((s) => _viaVpn(s) != direct).firstOrNull;
    return auto != null ? _dnsTag(auto) : out.dnsFinal;
  }

  /// The failover switch: a DNS rule per server for the clash mode named like it, after
  /// every other DNS rule: a rule with its own server keeps it, the mode replaces only the
  /// default (`dns.final`, which is also what the initial mode `Rule` gives). The core
  /// sets the mode over the API (dns_failover.dart). One server has nothing to switch to.
  void _dnsModes() {
    if (_dnsOn.length < 2) return;
    for (final s in _dnsOn) {
      out.dnsRules.add({'clash_mode': dnsModeOf(_dnsTag(s)), 'action': 'route', 'server': _dnsTag(s)});
    }
  }

  /// DNS rule for the domains a rule matches (for the resolve step and, with TUN, the
  /// apps' own queries). Only domain conditions: DNS sees names, not IPs.
  void _dnsRule(List<Map<String, dynamic>> domainAlts, String server) {
    if (server == out.dnsFinal || domainAlts.isEmpty) return;
    final match = domainAlts.length == 1 ? domainAlts.first : {'type': 'logical', 'mode': 'or', 'rules': domainAlts};
    out.dnsRules.add({...match, 'action': 'route', 'server': server});
  }

  /// Where direct traffic goes: plain `direct` resolves with the default direct DNS
  /// server; a rule naming another server gets a direct outbound of its own (the direct
  /// outbound never asks the DNS rules — only its domain_resolver).
  String _directVia(String dnsTag) {
    if (dnsTag == out.domainResolver) return 'direct';
    final tag = 'direct@$dnsTag';
    if (!out.outbounds.any((o) => o['tag'] == tag)) out.outbounds.add({'type': 'direct', 'tag': tag, 'domain_resolver': dnsTag});
    return tag;
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
  ({Map<String, dynamic> action, bool direct}) _proxyAction(String target, String fallback, String? dns, String label, {bool app = false}) {
    final tag = _target(target);
    if (tag == topTag) return (action: _mainFlowAction(fallback, dns, label, app), direct: false);
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
      return _proxyAction(fbTarget, 'main', dns, label, app: app);
    }
    if (tag != null) {
      final fb = fbTarget ??
          switch (fallback) {
            'block' => _blockOutbound(),
            'direct' => _directVia(_dnsFor(dns, direct: true)),
            _ => topTag,
          };
      return (action: _route(_fallbackSelector(target, fb, label, app, fbTarget: fbTarget)), direct: false);
    }
    return switch (fallback) {
      'block' => (action: _reject(), direct: false),
      'direct' => (action: _route(_directVia(_dnsFor(dns, direct: true))), direct: true),
      _ => (action: _route(topTag), direct: false),
    };
  }

  /// Through the main flow. It has "If unavailable" only when one is asked for explicitly
  /// (never the global default; `default` / `main` / empty / a target that is not available
  /// = none, the last with a warning): `block`, `direct` or a target of the catalog, as a
  /// selector [main flow, fallback] the core flips when the main flow dies (fallback.dart).
  Map<String, dynamic> _mainFlowAction(String fallback, String? dns, String label, bool app) {
    switch (fallback) {
      case '' || 'default' || 'main':
        break;
      case 'block':
        return _route(_fallbackSelector('', _blockOutbound(), label, app));
      case 'direct':
        return _route(_fallbackSelector('', _directVia(_dnsFor(dns, direct: true)), label, app));
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
      final targets = r['targets'] as Map;
      f = TargetFallback(tag, target, main ? const {} : targets[target] as Map, fallbackTag,
          fallbackTarget: fbTarget, fallbackSpec: fbTarget == null ? null : targets[fbTarget] as Map);
      out.fallbacks.add(f);
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
        final act = switch (h['act']) {
          'block' => _reject(),
          'direct' => _route('direct'),
          'proxy' => _proxyAction('${h['target'] ?? ''}', fallback, null, label, app: true).action,
          // Default has a rule only to give the main flow an "If unavailable" (it then goes by
          // the selector, not by the rules below); none asked for = by the rules below
          _ => switch (_mainFlowAction(fallback, null, label, true)) { {'outbound': topTag} => null, final a => a },
        };
        final name = network == null ? label : '$label (${network.first.toUpperCase()})';
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
          act = _route(_directVia(_dnsFor(dns, direct: true)));
          direct = true;
        default:
          final p = _proxyAction('${rule['target'] ?? ''}', fallback, dns, '${rule['name'] ?? ''}'.isNotEmpty ? '${rule['name']}' : 'rule ${rule['id']}');
          act = p.action;
          direct = p.direct;
      }
      // IP conditions need the destination's IP: resolve it once, before the first such rule
      // that has not asked to see IPs only when known (`ipTunOnly`). Later rules see the
      // resolved address whatever their flag says (sing-box resolves once).
      // In TUN the destination IP arrives as it is: no step ("Resolve for IP rules" is for the proxy port).
      if (plan['mode'] != 'tun' && !resolved && rule['ipTunOnly'] != true && _needsIp(built.match)) {
        resolved = true;
        final step = _resolveAction();
        if (step != null) out._add(step);
      }
      out._add({...built.match, ...act, ...((rule['extra'] as Map?) ?? const {}).cast<String, dynamic>()},
          RuleOrigin('user', '${rule['name'] ?? ''}'.isNotEmpty ? '${rule['name']}' : 'rule ${rule['id']}', id: '${rule['id'] ?? ''}'));
      if (action != 'block') _dnsRule(built.domainAlts, _dnsFor(dns, direct: direct));
    }
  }

  /// The `resolve` step before the IP rules (Settings → DNS "Resolve for IP rules",
  /// `dns.resolve`): null = off. `auto` (also a server that is deleted or unticked) = the first
  /// ticked server via VPN, so the name never goes to the provider's DNS; a server id = that
  /// one. The server is named explicitly, so the DNS failover (clash modes) and the rules' own
  /// DNS servers do not apply to this step. No VPN server on: `resolve` without a server
  /// (the DNS rules and `dns.final` decide), with a warning.
  Map<String, dynamic>? _resolveAction() {
    final pick = '${((r['dns'] as Map?) ?? const {})['resolve'] ?? 'auto'}';
    if (pick == 'off') return null;
    final named = pick == 'auto' ? null : _dnsOn.where((s) => '${s['id']}' == pick).firstOrNull;
    final server = named ?? _dnsOn.where(_viaVpn).firstOrNull;
    if (server == null) {
      if (_dnsOn.isNotEmpty) {
        out.warnings.add('Resolve for IP rules: no DNS server via VPN is on, the first one in use resolves and its query may leave outside the tunnel');
      }
      return {'action': 'resolve'};
    }
    return {'action': 'resolve', 'server': _dnsTag(server)};
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
      out._add({'type': 'logical', 'mode': 'or', 'rules': alts, ..._route('direct')}, const RuleOrigin('quick', 'My region direct', id: 'region'));
      _dnsRule(domains, _dnsFor('auto', direct: true));
      if (sites.length < reg.geosite.length || ips.length < reg.geoip.length) {
        out.warnings.add('My region direct: the ${q['region']} lists are not downloaded yet, only its domains (.${reg.tlds.first}) go direct');
      }
    }
    switch (q['final']) {
      case 'direct':
        out.finalOutbound = 'direct';
      case 'block':
        out._add(_reject());
      default:
        out.finalOutbound = topTag;
    }
  }
}

/* ── Values ── */

/// The clash mode that makes the DNS server [tag] the default (see `_dnsModes`).
String dnsModeOf(String tag) => tag;

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
