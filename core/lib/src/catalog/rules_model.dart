/// Rules, apps, quick rules, rule sets and DNS as the snapshot keeps them (docs/rules.md).
/// The catalog only needs them to build `plan.routing` (plan_builder.dart) and for the
/// delete dialog (`targetImpact`); the condition groups and the composite JSON of a rule
/// stay open maps — the core's `routing.dart` reads them.
library;

import '../routing.dart' as core show services;
import '../routing.dart' show dnsKindOf, dnsKindSystem, dnsKinds, dnsSidesAll, dnsUseDefault;
import 'json_util.dart';

T _get<T>(Json j, String k, T def) => j[k] is T ? j[k] as T : def;

/// A user rule (`rulesData[id]`).
class UserRule with RoundTrip {
  UserRule({
    required this.id,
    this.name = '',
    this.enabled = false,
    this.action = 'proxy',
    this.target = '',
    this.block,
    this.fallback = 'default',
    this.fallbackTarget,
    this.dns,
    this.groups,
    this.composite,
    this.extra,
    this.ipTunOnly = false,
  });

  factory UserRule.fromJson(Json j) {
    final r = UserRule(
      id: '${j['id']}',
      name: _get(j, 'name', ''),
      enabled: truthy(j['enabled']),
      action: _get(j, 'action', 'proxy'),
      target: _get(j, 'target', ''),
      block: j['block'] as String?,
      fallback: _get(j, 'fallback', 'default'),
      fallbackTarget: j['fallbackTarget'] as String?,
      dns: j['dns'] as String?,
      groups: j['groups'] is Map ? asJson(deepCopy(j['groups'])) : null,
      composite: j['composite'] is Map ? asJson(deepCopy(j['composite'])) : null,
      extra: j['extra'] is Map ? asJson(deepCopy(j['extra'])) : null,
      ipTunOnly: truthy(j['ipTunOnly']),
    );
    r.capture(j, _known);
    return r;
  }

  static const _known = {
    'id', 'name', 'enabled', 'action', 'target', 'block', 'fallback', 'fallbackTarget', 'dns', 'groups', 'composite', 'extra', 'ipTunOnly', //
  };

  final String id;
  String name;
  bool enabled;

  /// `proxy` | `direct` | `block`.
  String action;

  /// '' = the main flow; `src:` / `node:` / `profile:` / `chain:` + id.
  String target;
  String? block;

  /// "If unavailable" of a Proxy rule: `default` | `main` | `block` | `direct`
  /// (`main` + [fallbackTarget] = Proxy via that target).
  String fallback;
  String? fallbackTarget;
  String? dns;

  /// Condition groups: `{domain: {not, v: {domain_suffix: […]}}, …}`.
  Json? groups;

  /// A rule the form cannot express (raw sing-box logical rule).
  Json? composite;
  Json? extra;
  bool ipTunOnly;

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    put(o, 'name', name, omit: name.isEmpty);
    o['enabled'] = enabled;
    o['action'] = action;
    put(o, 'target', target, omit: target.isEmpty);
    put(o, 'block', block, omit: block == null);
    put(o, 'fallback', fallback, omit: fallback == 'default');
    put(o, 'fallbackTarget', fallbackTarget, omit: fallbackTarget == null);
    put(o, 'dns', dns, omit: dns == null);
    put(o, 'groups', deepCopy(groups), omit: groups == null);
    put(o, 'composite', deepCopy(composite), omit: composite == null);
    put(o, 'extra', deepCopy(extra), omit: extra == null);
    put(o, 'ipTunOnly', ipTunOnly, omit: !ipTunOnly);
    putUnknown(o);
    return o;
  }
}

/// One protocol half of an app rule (`appBlankHalf`): TCP + UDP together, or one of them
/// when the app is split.
class AppHalf with RoundTrip {
  AppHalf({this.act = 'default', this.target = '', this.fallback = 'default', this.fallbackTarget = ''});

  factory AppHalf.fromJson(Json j) {
    final h = AppHalf(
      act: _get(j, 'act', 'default'),
      target: _get(j, 'target', ''),
      fallback: _get(j, 'fallback', 'default'),
      fallbackTarget: _get(j, 'fallbackTarget', ''),
    );
    h.capture(j, _known);
    return h;
  }

  static const _known = {'act', 'target', 'fallback', 'fallbackTarget'};

  /// `default` | `proxy` | `direct` | `block`.
  String act;
  String target;
  String fallback;
  String fallbackTarget;

  Json toJson() => {'act': act, 'target': target, 'fallback': fallback, 'fallbackTarget': fallbackTarget};

  Json _jsonWithUnknown() => {...toJson(), ...deepCopy(unknown) as Json};
}

/// A per-app rule (`appRules[pkg]`), normalised like `appNormalize` (42-apps.js): the
/// top-level fields are the whole app's traffic, or TCP when [split]; [udp] is UDP. The
/// old `{act, split, udpTarget}` becomes `udp: {act: 'proxy', target: udpTarget}`.
class AppRule with RoundTrip {
  AppRule({AppHalf? tcp, AppHalf? udp, this.split = false})
      : tcp = tcp ?? AppHalf(),
        udp = udp ?? AppHalf();

  factory AppRule.fromJson(Json j) {
    final tcp = AppHalf.fromJson(j);
    final split = truthy(j['split']);
    AppHalf udp;
    if (j['udp'] is Map) {
      udp = AppHalf.fromJson(asJson(j['udp']));
    } else if (j.containsKey('udpTarget') && split) {
      udp = AppHalf(act: 'proxy', target: (j['udpTarget'] ?? '') as String);
    } else {
      udp = AppHalf();
    }
    final a = AppRule(tcp: tcp, udp: udp, split: split);
    a.capture(j, _known);
    a.tcp.unknown = {}; // the app's unknown keys are the app's, not the half's
    return a;
  }

  static const _known = {'split', 'act', 'target', 'fallback', 'fallbackTarget', 'udp', 'udpTarget'};

  AppHalf tcp;
  AppHalf udp;
  bool split;

  /// [protocol label, half]: one half for the whole app, or TCP and UDP when split
  /// (`appHalves`).
  List<(String, AppHalf)> get halves => split ? [('TCP', tcp), ('UDP', udp)] : [('', tcp)];

  Json toJson() => {
        'split': split,
        ...tcp.toJson(),
        'udp': udp._jsonWithUnknown(),
        ...deepCopy(unknown) as Json,
      };
}

/// Quick rules and the global "If unavailable" (`quickCfg`).
class QuickCfg with RoundTrip {
  QuickCfg({
    this.regionOn = true,
    this.region = 'RU',
    this.ads = false,
    this.finalAction = 'proxy',
    this.fallback = 'main',
    Map<String, String>? services,
  }) : services = services ?? {for (final k in _serviceKeys) k: 'default'};

  factory QuickCfg.fromJson(Json j) {
    final svc = j['services'] is Map ? asJson(j['services']) : Json();
    final c = QuickCfg(
      regionOn: _get(j, 'regionOn', true),
      region: _get(j, 'region', 'RU'),
      ads: _get(j, 'ads', false),
      finalAction: _get(j, 'final', 'proxy'),
      fallback: _get(j, 'fallback', 'main'),
      // like the mockup: every built-in service has a state, `|| 'default'`
      services: {
        for (final e in svc.entries) e.key: truthy(e.value) ? '${e.value}' : 'default',
        for (final k in _serviceKeys)
          if (!svc.containsKey(k)) k: 'default',
      },
    );
    c.capture(j, _known);
    return c;
  }

  static const _known = {'regionOn', 'region', 'ads', 'final', 'fallback', 'services'};
  static final _serviceKeys = core.services.keys.toList();

  bool regionOn;
  String region;
  bool ads;

  /// The `final` of the plan: `proxy` | `direct` | `block` — what everything else does.
  String finalAction;

  /// A rule's / an app's target is unavailable and it says Default: `main` | `block` | `direct`.
  String fallback;

  /// Built-in service → `default` | `vpn` | `direct`.
  Map<String, String> services;

  Json toJson() => {
        'regionOn': regionOn,
        'region': region,
        'ads': ads,
        'final': finalAction,
        'fallback': fallback,
        'services': {...services},
        ...deepCopy(unknown) as Json,
      };
}

/// A rule set (`ruleSets[i]`); the two built-in ones are `geosite` and `geoip`.
class RuleSetCfg with RoundTrip {
  RuleSetCfg({required this.id, this.name = '', this.builtin = false, this.url, this.format, this.via, this.every});

  factory RuleSetCfg.fromJson(Json j) {
    final s = RuleSetCfg(
      id: '${j['id']}',
      name: _get(j, 'name', ''),
      builtin: truthy(j['builtin']),
      url: j['url'] as String?,
      format: j['format'] as String?,
      via: j['via'] as String?,
      every: j['every'] as num?,
    );
    s.capture(j, _known);
    return s;
  }

  static const _known = {'id', 'name', 'builtin', 'url', 'format', 'via', 'every'};

  final String id;
  String name;
  bool builtin;
  String? url;
  String? format;

  /// `vpn` | `direct`.
  String? via;

  /// Update period, seconds.
  num? every;

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    o['name'] = name;
    put(o, 'builtin', builtin, omit: !builtin);
    put(o, 'url', url, omit: url == null);
    put(o, 'format', format, omit: format == null);
    put(o, 'via', via, omit: via == null);
    put(o, 'every', every, omit: every == null);
    putUnknown(o);
    return o;
  }
}

/// Version of the stored DNS list: below it the list is migrated once on load ([migrateDnsList]).
const dnsListVersion = 2;

/// One address of a DNS provider, in one transport.
class DnsTransport with RoundTrip {
  DnsTransport(this.kind, this.addr);

  factory DnsTransport.fromJson(Json j) {
    final addr = _get(j, 'addr', '');
    final t = DnsTransport(_get(j, 'kind', dnsKindOf(addr)), addr);
    t.capture(j, _known);
    return t;
  }

  static const _known = {'kind', 'addr'};

  /// `doh` | `dot` | `doq` | `udp` | `system`.
  final String kind;

  /// `https://1.1.1.1/dns-query`, `tls://1.1.1.1`, `quic://…`, `1.1.1.1`, `system`.
  final String addr;

  Json toJson() => {'kind': kind, 'addr': addr, ...deepCopy(unknown) as Json};
}

/// A DNS provider (`dnsServers[id]`, docs/rules.md §6): several addresses in different transports,
/// each usable on the direct side and / or through the VPN. The list's order (`dnsOrder`) is the
/// priority; inside a provider the [transports] are tried in their own order, only the kinds in [use].
/// The OS resolver (Local) is a provider with the one `system` transport and is direct only.
class DnsServerCfg with RoundTrip {
  /// With [addr] (and [via]): the one-address provider the list had before the rework (use = its kind,
  /// sides = [via], `vpn` when not said: a server the user adds is VPN-only). Else [transports], [use]
  /// and [sides] as given (the defaults of a provider: `doh` + `dot`, VPN only).
  DnsServerCfg({
    required this.id,
    this.name = '',
    String? addr,
    String? via,
    this.on = true,
    List<DnsTransport>? transports,
    Iterable<String>? sides,
    Iterable<String>? use,
  }) {
    this.transports = transports ?? [if (addr != null && addr.isNotEmpty) DnsTransport(dnsKindOf(addr), addr)];
    final kind = addr == null || addr.isEmpty ? null : dnsKindOf(addr);
    this.use = {...(use ?? (kind != null ? [kind] : dnsUseDefault))};
    this.sides = {...(sides ?? [via ?? 'vpn'])};
  }

  factory DnsServerCfg.fromJson(Json j) {
    final legacy = j['transports'] is! List;
    final addr = _get(j, 'addr', '');
    final s = DnsServerCfg(
      id: '${j['id']}',
      name: _get(j, 'name', ''),
      on: truthy(j['on']),
      transports: legacy ? null : [for (final t in j['transports'] as List) DnsTransport.fromJson(asJson(t))],
      addr: legacy ? addr : null,
      via: legacy ? _get(j, 'via', 'vpn') : null,
      sides: j['sides'] is List ? strList(j['sides']) : null,
      use: j['use'] is List ? strList(j['use']) : null,
    );
    s.capture(j, _known);
    return s;
  }

  /// `addr` / `via` are the single-address form of the list before the rework: read, never written back.
  static const _known = {'id', 'name', 'on', 'transports', 'sides', 'use', 'addr', 'via'};

  final String id;
  String name;
  bool on;

  /// The addresses, in the order they are tried inside the provider.
  late List<DnsTransport> transports;

  /// The enabled kinds (`doh` / `dot` / `doq` / `udp`); a kind with no address does nothing.
  late Set<String> use;

  /// `direct` and / or `vpn`. Read it through [activeSides]: Local never has `vpn`.
  late Set<String> sides;

  /// The OS resolver.
  bool get system => transports.length == 1 && transports.first.kind == dnsKindSystem;

  /// [sides] as they count: Local is direct only (the OS resolver is on the machine, not through the tunnel).
  Set<String> get activeSides => system ? {'direct'} : sides.where(dnsSidesAll.contains).toSet();

  /// The transports that count, in their order: only the enabled kinds (Local's `system` always).
  List<DnsTransport> get usedTransports => [for (final t in transports) if (system || use.contains(t.kind)) t];

  /// The first address (the list before the rework had one): what the old Settings → DNS shows.
  String get addr => transports.isEmpty ? '' : transports.first.addr;
  set addr(String v) {
    transports = [if (v.isNotEmpty) DnsTransport(dnsKindOf(v), v)];
    use = {if (v.isNotEmpty) dnsKindOf(v)};
  }

  /// `vpn` | `direct`: one of the sides (the old form had one); `vpn` when both.
  String get via => activeSides.contains('vpn') ? 'vpn' : 'direct';
  set via(String v) => sides = {v};

  Json toJson() => {
        'id': id,
        'name': name,
        'on': on,
        'sides': [for (final s in dnsSidesAll) if (activeSides.contains(s)) s],
        'use': [for (final k in [...dnsKinds, dnsKindSystem]) if (use.contains(k)) k, ...use.where((k) => ![...dnsKinds, dnsKindSystem].contains(k))],
        'transports': [for (final t in transports) t.toJson()],
        ...deepCopy(unknown) as Json,
      };
}

List<DnsTransport> _transports(String kind, List<String> addrs) => [for (final a in addrs) DnsTransport(kind, a)];

/// The list a fresh install has, and the one a migration puts in place of the old built-ins, in
/// priority order: Cloudflare, Google, AdGuard (unfiltered), Local. Providers use DoH + DoT (UDP is
/// plain text: off by default) on both sides; Local is the OS resolver, direct only.
List<DnsServerCfg> defaultDnsServers() => [
      DnsServerCfg(id: 'cloudflare', name: 'Cloudflare', sides: dnsSidesAll, transports: [
        ..._transports('doh', ['https://1.1.1.1/dns-query', 'https://1.0.0.1/dns-query']),
        ..._transports('dot', ['tls://1.1.1.1', 'tls://1.0.0.1']),
        ..._transports('udp', ['1.1.1.1', '1.0.0.1']),
      ]),
      DnsServerCfg(id: 'google', name: 'Google', sides: dnsSidesAll, transports: [
        ..._transports('doh', ['https://8.8.8.8/dns-query', 'https://8.8.4.4/dns-query']),
        ..._transports('dot', ['tls://8.8.8.8', 'tls://8.8.4.4']),
        ..._transports('udp', ['8.8.8.8', '8.8.4.4']),
      ]),
      DnsServerCfg(id: 'adguard', name: 'AdGuard (unfiltered)', sides: dnsSidesAll, transports: [
        ..._transports('doh', ['https://94.140.14.140/dns-query', 'https://94.140.14.141/dns-query']),
        ..._transports('dot', ['tls://94.140.14.140', 'tls://94.140.14.141']),
        ..._transports('doq', ['quic://94.140.14.140', 'quic://94.140.14.141']),
        ..._transports('udp', ['94.140.14.140', '94.140.14.141']),
      ]),
      DnsServerCfg(id: 'local', name: 'Local', sides: ['direct'], transports: [DnsTransport(dnsKindSystem, 'system')]),
    ];

/// The ids of the list before the rework that the migration replaces by [defaultDnsServers].
const _oldBuiltinDns = {'remote', 'local', 'google'};

/// The one-time migration of the stored list to [dnsListVersion] (docs/rules.md §6): the old built-ins
/// (`remote`, `local`, `google`) are replaced by [defaultDnsServers]; the user's own servers follow
/// them in their old order, converted by [DnsServerCfg.fromJson] (one address = one transport of its kind,
/// `via` = the side; a `system` one is direct only). [renamed]: old id → new id of what changed
/// (`remote` → `cloudflare`, an own server whose id the defaults took): ids that rules and the
/// "Resolve for IP rules" pick refer to.
({Map<String, DnsServerCfg> servers, List<String> order, Map<String, String> renamed}) migrateDnsList(
    Map<String, DnsServerCfg> old, List<String> oldOrder) {
  final servers = <String, DnsServerCfg>{for (final s in defaultDnsServers()) s.id: s};
  final order = [...servers.keys];
  final renamed = <String, String>{'remote': 'cloudflare'};
  final own = [...oldOrder.where(old.containsKey), ...old.keys.where((k) => !oldOrder.contains(k))];
  for (final id in own) {
    if (_oldBuiltinDns.contains(id)) continue;
    var nid = id;
    while (servers.containsKey(nid)) {
      nid = '$nid-2';
    }
    if (nid != id) renamed[id] = nid;
    final o = old[id]!;
    final s = DnsServerCfg(id: nid, name: o.name, on: o.on, transports: [...o.transports], sides: o.activeSides, use: o.use);
    s.unknown = deepCopy(o.unknown) as Json;
    servers[nid] = s;
    order.add(nid);
  }
  return (servers: servers, order: order, renamed: renamed);
}

/// Settings → DNS (`dnsCfg`).
class DnsCfg with RoundTrip {
  DnsCfg({this.hijack = true, this.auto = true, this.resolve = 'auto', this.directPolicy = 'localFirst', this.listVersion = dnsListVersion});

  factory DnsCfg.fromJson(Json j) {
    final c = DnsCfg(
      hijack: j['hijack'] != false,
      auto: _get(j, 'auto', true),
      resolve: _get(j, 'resolve', 'auto'),
      directPolicy: j['directPolicy'] == 'priority' ? 'priority' : 'localFirst',
      listVersion: j['listVersion'] is num ? (j['listVersion'] as num).toInt() : 1,
    );
    c.capture(j, _known);
    return c;
  }

  /// `fakeip` / `fakeipExclude` are listed only so that old saved data drops them instead of
  /// carrying them as unknown keys: FakeIP is removed until it is redesigned (`docs/rules.md` §DNS).
  static const _known = {'hijack', 'auto', 'resolve', 'directPolicy', 'listVersion', 'fakeip', 'fakeipExclude'};

  /// `localFirst` (default): the direct side tries Local first, then the list order; `priority`: the
  /// direct side follows the list order like the VPN side.
  String directPolicy;

  /// Which version of the list the stored `dnsServers` is ([dnsListVersion]); a store without the
  /// key is version 1 and is migrated once on load.
  int listVersion;

  /// TUN only: the core answers every DNS query.
  bool hijack;

  /// Switch servers automatically (sent with connect, not in the plan).
  bool auto;

  /// `auto` | `off` | a server id: the `resolve` step before IP rules.
  String resolve;

  Json toJson() => {
        'hijack': hijack,
        'auto': auto,
        'resolve': resolve,
        'directPolicy': directPolicy,
        'listVersion': listVersion,
        ...deepCopy(unknown) as Json,
      };
}
