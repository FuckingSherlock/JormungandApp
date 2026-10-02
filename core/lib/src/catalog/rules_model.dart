/// Rules, apps, quick rules, rule sets and DNS as the snapshot keeps them (docs/rules.md).
/// The catalog only needs them to build `plan.routing` (plan_builder.dart) and for the
/// delete dialog (`targetImpact`); the condition groups and the composite JSON of a rule
/// stay open maps — the core's `routing.dart` reads them.
library;

import '../routing.dart' as core show services;
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

/// A DNS server (`dnsServers[id]`).
class DnsServerCfg with RoundTrip {
  DnsServerCfg({required this.id, this.name = '', this.addr = '', this.via = 'vpn', this.on = true});

  factory DnsServerCfg.fromJson(Json j) {
    final s = DnsServerCfg(
      id: '${j['id']}',
      name: _get(j, 'name', ''),
      addr: _get(j, 'addr', ''),
      via: _get(j, 'via', 'vpn'),
      on: truthy(j['on']),
    );
    s.capture(j, _known);
    return s;
  }

  static const _known = {'id', 'name', 'addr', 'via', 'on'};

  final String id;
  String name;

  /// `https://…`, `tls://…`, `system`…
  String addr;

  /// `vpn` | `direct`.
  String via;
  bool on;

  Json toJson() => {'id': id, 'name': name, 'addr': addr, 'via': via, 'on': on, ...deepCopy(unknown) as Json};
}

/// Settings → DNS (`dnsCfg`).
class DnsCfg with RoundTrip {
  DnsCfg({this.hijack = true, this.fakeip = false, this.auto = true, this.resolve = 'auto', List<String>? fakeipExclude})
      : fakeipExclude = fakeipExclude ?? [..._defaultFakeipExclude];

  factory DnsCfg.fromJson(Json j) {
    final c = DnsCfg(
      hijack: j['hijack'] != false,
      fakeip: _get(j, 'fakeip', false),
      auto: _get(j, 'auto', true),
      resolve: _get(j, 'resolve', 'auto'),
      fakeipExclude: j['fakeipExclude'] is List ? strList(j['fakeipExclude']) : null,
    );
    c.capture(j, _known);
    return c;
  }

  static const _known = {'hijack', 'fakeip', 'auto', 'resolve', 'fakeipExclude'};
  static const _defaultFakeipExclude = [
    '*.sberbank.ru',
    '*.tinkoff.ru',
    '*.gosuslugi.ru',
    '*.steamserver.net',
    '*.xboxlive.com',
    'time.*.com',
  ];

  /// TUN only: the core answers every DNS query.
  bool hijack;
  bool fakeip;

  /// Switch servers automatically (sent with connect, not in the plan).
  bool auto;

  /// `auto` | `off` | a server id: the `resolve` step before IP rules.
  String resolve;
  List<String> fakeipExclude;

  Json toJson() => {
        'hijack': hijack,
        'fakeip': fakeip,
        'auto': auto,
        'resolve': resolve,
        'fakeipExclude': [...fakeipExclude],
        ...deepCopy(unknown) as Json,
      };
}
