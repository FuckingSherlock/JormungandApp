/// The connect plan: what the catalog hands the core (docs/core.md → «План подключения»).
/// Port of `livePlan` / `planGroup` / `planSigOf` (95-live.js), `planRoute(s)` / `planAuto`
/// (94-live-auto.js) and `routingPlan` / `routingTarget` (93-routing-plan.js).
///
/// The plan is a plain JSON map, the exact thing the mockup POSTs to `/api/connect`: the
/// key order and the omitted-when-undefined keys are the mockup's too, so [planSigOf] gives
/// the same string. The core reads it (`config.dart`, `routing.dart`, `auto.dart`).
library;

import 'dart:convert';

import '../routing.dart' show dnsSidesAll;
import 'catalog.dart';
import 'json_util.dart';
import 'models.dart';
import 'rules_logic.dart' show AppRulesOps;
import 'rules_model.dart';

/// The plan (`{mode, mixedPort, tunStack, mixedAuth?, global, urlTest, auto, routing, routes,
/// current}`).
typedef Plan = Json;

/// A rule / app target as the picker names it: `''` the main flow, `src:` / `node:` /
/// `profile:` / `chain:` + id (`targetInfo`).
class TargetInfo {
  const TargetInfo({required this.kind, this.name = '', this.flag = '', this.gone = false, required this.ok});

  /// `main` | `subscription` | `servers` | `node` | `profile` | `chain`.
  final String kind;
  final String name;
  final String flag;

  /// The target was deleted (the reference is kept, so the rule shows it).
  final bool gone;

  /// Switched on in Nodes and has a server the traffic can use.
  final bool ok;
}

/// A rule / app target that cannot carry traffic ([CatalogPlan.targetLost]).
class TargetLost {
  const TargetLost(this.why, this.to, this.byDefault);

  /// `deleted` | `off` | `noServers` | `unsupported`.
  final String why;

  /// Where the traffic goes now: `block` | `direct` | `main` | a target id.
  final String to;

  /// The rule's "If unavailable" is Default: the global Rules → Target unavailable decided.
  final bool byDefault;
}

/// JS `String.slice(a)` / `slice(a, b)` for the one place that cuts with `-1`.
String _slice(String s, int a, [int? b]) {
  int clamp(int i) => i < 0 ? (s.length + i).clamp(0, s.length) : i.clamp(0, s.length);
  final from = clamp(a), to = b == null ? s.length : clamp(b);
  return from >= to ? '' : s.substring(from, to);
}

extension CatalogPlan on Catalog {
  // ───────────────────────────── groups and routes ─────────────────────────────

  /// A server group of the plan: the servers the core can use, Fastest ones with the known
  /// fastest first and the dead ones last (the order the core's pre-connect check goes in). Throws [CatalogException] `noUsableServer` when none
  /// can be put into a config (`planGroup`).
  ///
  /// [chosen] is the server the group starts on: Priority's pick, and for Fastest the app's known one, a hint
  /// only (the core checks it before connect and uses it as the start when it cannot; `pinned` is the
  /// separate flag that holds a group). Not in the mockup's plan ([mockupPlan]).
  Json planGroup(List<NodeRef> refs, String pick, [NodeRef? chosen, double Function(NodeRef)? rank]) {
    final ok = refs.where((r) => r.node.usable).toList();
    if (ok.isEmpty) {
      NodeRef? bad;
      for (final r in refs) {
        final u = r.node.unsupported;
        if (u != null && u.isNotEmpty) {
          bad = r;
          break;
        }
      }
      throw CatalogException(
          'noUsableServer', 'No server here the core can use${bad != null ? ' (${bad.node.unsupported} is not in sing-box)' : ''}');
    }
    final nodes = pick == 'fastest' ? stableSorted(ok, rank ?? (NodeRef r) => pings.rank(r.node)) : ok;
    return {
      'pick': pick,
      'chosen': (pick == 'priority' || !mockupPlan) && chosen != null ? chosen.key : null,
      'nodes': [
        // `flag`: the country as the catalog knows it (site checks prefer a node of another country; not in the mockup's plan)
        for (final r in nodes) {'key': r.key, 'outbound': r.node.outbound, if (!mockupPlan) 'flag': r.node.flag},
      ],
    };
  }

  NodeRef? _refOf(List<NodeRef> refs, CatalogNode? n) {
    if (n == null) return null;
    for (final r in refs) {
      if (identical(r.node, n)) return r;
    }
    return null;
  }

  /// A chain's `entry` and `main` groups: the exits ordered / chosen by their answer through the
  /// entry in use (the pair), not their direct one.
  Json _planChain(Chain c) {
    final exits = chainExitRefs(c), entryRefs = chainEntryRefs(c);
    // the servers the core has the groups on win over the catalog's guess (a reconnect keeps them)
    final entry = coreGroupNode(c.id, 'entryServer', entryRefs) ?? chainEntryNode(c);
    // no server of the core's: a Priority exit starts on the first one not known dead through the
    // entry (never measured is a candidate, as in Auto's own `mayWork`), else the catalog's pick
    CatalogNode? firstLive() {
      for (final r in exits) {
        if (!chainExitKnownDead(c, r.node, entry)) return r.node;
      }
      return null;
    }

    final exitNode = coreGroupNode(c.id, 'server', exits) ?? (c.exitMode == 'priority' && !mockupPlan ? firstLive() : null) ?? chainExitNode(c);
    return {
      'entry': planGroup(chainEntryRefs(c), 'fastest', _refOf(entryRefs, entry)),
      'main': planGroup(exits, c.exitMode == 'priority' ? 'priority' : 'fastest', _refOf(exits, exitNode), (r) => chainExitRank(c, r.node, entry)),
    };
  }

  /// One Route entry as a route of the plan (`planRoute`).
  Json planRoute(String id) {
    final c = chainsData[id];
    if (c != null) {
      return {'id': id, 'kind': 'chain', ..._planChain(c)};
    }
    final refs = unitPickRefs(id), n = coreGroupNode(id, 'server', refs) ?? unitNode(id), pin = pinnedRef(id);
    final main = planGroup(refs, pin != null || unitPriority(id) ? 'priority' : 'fastest', pin ?? _refOf(refs, n));
    // Manual on a server: held there, the core never moves it. A pick that is no longer a server of the entry never gets
    // here: [livePlan] refuses it ([pinLoss]), nothing takes another server in its place
    if (pin != null) main['pinned'] = true;
    return {'id': id, 'kind': 'unit', 'main': main};
  }

  /// The routes of the plan and the one to start on (the anchor). Auto: every Auto entry —
  /// the core moves between them through a selector, so a failover or a return never
  /// restarts sing-box; only a change of this list does. Manual: the same list (the core's Auto
  /// only stays on the anchor, see `plan.manual`), so Auto ↔ Manual is no new plan; the anchor
  /// alone when it is not an Auto entry, or in the mockup's plan ([mockupPlan]). Entries
  /// the core cannot use are left out; the anchor itself must be usable (`planRoutes`).
  ({List<Json> routes, int current}) planRoutesOf(String anchor) {
    final order = autoOrder(), i = order.indexOf(anchor);
    final ids = (!autoConnect && mockupPlan) || i < 0 ? [anchor] : order;
    final routes = <Json>[];
    for (final id in ids) {
      if (id == anchor) {
        routes.add(planRoute(id));
      } else {
        try {
          routes.add(planRoute(id));
        } on CatalogException {
          // nothing usable: not a route
        }
      }
    }
    return (routes: routes, current: routes.indexWhere((r) => r['id'] == anchor));
  }

  /// Settings → Auto mode as the core reads it (`planAuto`).
  Json planAuto() => {
        'failAfter': autoCfg.failAfter,
        'threshold': autoCfg.threshold,
        'checkEvery': autoCfg.checkEvery,
        'standby': autoCfg.standby,
        'warmEvery': autoCfg.warmEvery,
        'retryPause': autoCfg.retryPause,
        'returnTo': autoCfg.returnTo,
        'flapGuard': autoCfg.flapGuard,
        'flapMax': autoCfg.flapMax,
        'flapReset': autoCfg.flapReset,
        'siteRetry': autoCfg.siteRetry,
        if (!autoCfg.siteCheck) 'siteCheck': false,
        'checkers': [...connCfg.checkers], // Settings → Connection → Backup checks, taken live too
      };

  /// The plan around one entry ([anchor]; default: the catalog's own pick). Built on the
  /// catalog's own picks, not the core's ([withoutCore]), so the core moving a Priority group
  /// is no new plan. Throws [CatalogException] (`nothingInAuto` / `nothingToConnect` /
  /// `noUsableServer`) when there is nothing to connect through (`livePlan`).
  Plan livePlan([String? anchor]) => withoutCore(() {
        final id = anchor ?? effectiveConnectId(true);
        if (id == null || id.isEmpty || connectEntry(id) == null) {
          throw nothingInAuto()
              ? CatalogException('nothingInAuto', 'Nothing in Auto — turn on Use in Auto in Route')
              : CatalogException('nothingToConnect', 'Nothing to connect — add a subscription in Nodes');
        }
        // Manual on a server is the user's choice, working or not: a pick that is gone / off / unusable is an error, never
        // a plan on another server (the app also ends a running connection on it)
        final lost = pinLoss();
        if (lost != null) throw CatalogException('pinLost', lost);
        // mixedAuth: the port asks for a login; with the system proxy on the core opens a second, open port for it
        final plan = <String, dynamic>{
          'mode': segState.tun ? 'tun' : 'proxy',
          'mixedPort': connCfg.port != 0 ? connCfg.port : 2080,
          'tunStack': connCfg.tunStack.isNotEmpty ? connCfg.tunStack : 'mixed',
          'ipv6': connCfg.ipv6,
          if (connCfg.proxyAuth) 'mixedAuth': {'user': connCfg.proxyUser, 'pass': connCfg.proxyPass},
          'global': segState.global,
          'urlTest': {
            'interval': autoCfg.checkEvery,
            'tolerance': autoCfg.threshold,
            if (connCfg.testUrl.isNotEmpty) 'url': connCfg.testUrl,
          },
          'auto': planAuto(),
          'routing': routingPlan(),
          // Manual: the core's Auto stays on the anchor (the routes are the Auto ones all the same)
          if (!autoConnect && !mockupPlan) 'manual': true,
        };
        final r = planRoutesOf(id);
        plan['routes'] = r.routes;
        plan['current'] = r.current;
        return plan;
      });

  // ───────────────────────────── the plan's identity ─────────────────────────────

  /// What a reconnect is worth: the routes, rules and the servers in each group — not their
  /// ping order (a ping reorders Fastest, in routes and in rule targets alike, and flips
  /// servers to 'testing': neither may restart sing-box and drop every connection), nor the
  /// server a main-flow group is on (the core moves those itself; only a Manual pin counts).
  /// A rule target's Priority pick does count: nothing but a new plan moves it. The system
  /// proxy is in it: switched while connected, the core gets it with the reconnect. Auto ↔
  /// Manual is not (`plan.manual`; the routes are the same): the core switches it live. A string,
  /// compared by `==`; the same one the mockup's `planSigOf` gives (`planSigOf`).
  String planSigOf(Plan plan) {
    List<String> keys(Json x) {
      final ks = [for (final n in x['nodes'] as List) (n as Map)['key'] as String];
      return x['pick'] == 'fastest' ? (ks..sort()) : ks;
    }

    // a Priority group with no pick (nothing measured yet) starts on its first server: the same
    Object? pick(Json x) {
      if (x['pick'] != 'priority') return null;
      if (truthy(x['chosen'])) return x['chosen'];
      final ns = x['nodes'] as List;
      return ns.isNotEmpty ? (ns.first as Map)['key'] : null;
    }

    Json? g(Json? x) => x == null ? null : {...x, 'chosen': truthy(x['pinned']) ? x['chosen'] : null, 'nodes': keys(x)};
    Json? gt(Json? x) => x == null ? null : {...x, 'chosen': pick(x), 'nodes': keys(x)};
    Json? r(Json? x, Json? Function(Json?) f) {
      if (x == null) return null;
      final o = {...x};
      o['main'] = f(x['main'] as Json?);
      if (x.containsKey('entry')) o['entry'] = f(x['entry'] as Json?);
      return o;
    }

    final routing = plan['routing'] is Map
        ? <String, dynamic>{
            ...(plan['routing'] as Map).cast<String, dynamic>(),
            'targets': {
              for (final e in ((plan['routing'] as Map)['targets'] as Map? ?? const {}).entries)
                '${e.key}': r(e.value is Map ? asJson(e.value) : null, gt),
            },
          }
        : null;
    final out = <String, dynamic>{...plan};
    out['current'] = null;
    out['auto'] = null;
    out.remove('manual'); // switched live in the core, not a plan change
    if (routing != null) out['routing'] = routing;
    out['systemProxy'] = segState.systemProxy;
    out['tunStack'] = segState.tun ? plan['tunStack'] : null;
    out['routes'] = [
      for (final x in (plan['routes'] as List? ?? const [])) r(asJson(x), g),
    ];
    return jsonEncode(out);
  }

  /// [planSigOf] of the plan the catalog would build now; null when there is none
  /// (`planSig`).
  String? planSig() {
    try {
      return planSigOf(livePlan(liveSigAnchor()));
    } on CatalogException {
      return null;
    }
  }

  /// Which anchor the running plan is compared with (`liveSigAnchor`): in Auto the one it was
  /// built on while that is still an Auto entry — the core moves inside the plan by itself,
  /// so neither its moves nor a ping may restart sing-box; otherwise (Manual, the entry left
  /// Auto) the catalog's pick, and a different pick is a new plan.
  String? liveSigAnchor() {
    final a = liveAnchor;
    return autoConnect && a != null && a.isNotEmpty && autoOrder().contains(a) ? a : effectiveConnectId(true);
  }

  /// A page opened while connected: the anchor whose routes are the ones the core runs
  /// (`liveFindAnchor`).
  String? liveFindAnchor(List<String> ids) {
    bool same(String id) {
      try {
        return planRoutesOf(id).routes.map((r) => r['id']).join(',') == ids.join(',');
      } on CatalogException {
        return false;
      }
    }

    for (final id in ids) {
      if (same(id)) return id;
    }
    return coreRoute?.id;
  }

  // ───────────────────────────── rules, apps, DNS (plan.routing) ─────────────────────────────

  String? _entryTarget(String id) => profilesData.containsKey(id)
      ? 'profile:$id'
      : chainsData.containsKey(id)
          ? 'chain:$id'
          : sourcesData.containsKey(id)
              ? 'src:$id'
              : null;

  /// What a target is, and whether it can carry traffic now (`targetInfo`). A bare id (what
  /// the core names in events and plans) is taken as the entry of that id.
  TargetInfo targetInfo(String t) {
    if (t.isNotEmpty && !t.contains(':')) t = _entryTarget(t) ?? t;
    if (t.isEmpty) return const TargetInfo(kind: 'main', name: 'Main flow', ok: true);
    final at = t.indexOf(':'), kind = _slice(t, 0, at), ref = _slice(t, at + 1);
    if (kind == 'src') {
      final s = sourcesData[ref];
      return TargetInfo(
          kind: s != null && s.kind == 'node' ? 'servers' : 'subscription',
          name: s?.name ?? '',
          gone: s == null,
          ok: s != null && s.enabled && liveNodes(s).isNotEmpty);
    }
    if (kind == 'node') {
      final parts = ref.split('::'), sid = parts[0], nid = parts.length > 1 ? parts[1] : null;
      final s = sourcesData[sid];
      CatalogNode? n;
      if (s != null) {
        for (final x in s.nodes) {
          if (x.id == nid) n = x;
        }
      }
      return TargetInfo(kind: 'node', name: n?.name ?? '', flag: n?.flag ?? '', gone: n == null, ok: n != null && s!.enabled && !isNodeDisabled(s, nid!));
    }
    final Entry? e = kind == 'profile' ? profilesData[ref] : chainsData[ref];
    final ok = e != null &&
        (kind == 'profile' ? unitRefs(ref).isNotEmpty : chainEntryRefs(e as Chain).isNotEmpty && chainExitRefs(e).isNotEmpty);
    return TargetInfo(kind: kind, name: e?.name ?? '', gone: e == null, ok: ok);
  }

  /// Why the rule / app target [t] cannot carry traffic now, null = it can (or it is the main flow): `deleted`,
  /// `off` (switched off in Nodes, its source or servers), `noServers` (nothing left to connect through) or
  /// `unsupported` (only servers sing-box cannot run, e.g. XHTTP). docs/rules.md §0 «Потерянная цель».
  String? targetLoss(String t) {
    if (t.isEmpty) return null;
    if (!t.contains(':')) t = _entryTarget(t) ?? t;
    final i = targetInfo(t);
    if (i.gone) return 'deleted';
    final at = t.indexOf(':'), kind = _slice(t, 0, at), ref = _slice(t, at + 1);
    if (!i.ok) {
      return switch (kind) {
        'src' => sourcesData[ref]!.enabled && brokenBy(ref).isEmpty ? 'noServers' : 'off',
        'node' => 'off',
        _ => brokenBy(ref).isNotEmpty ? 'off' : 'noServers',
      };
    }
    final bool usable;
    if (kind == 'src') {
      usable = liveNodes(sourcesData[ref]!).any((n) => n.usable);
    } else if (kind == 'node') {
      final parts = ref.split('::');
      usable = sourcesData[parts[0]]!.nodes.any((n) => n.id == parts[1] && n.usable);
    } else if (kind == 'profile') {
      usable = unitPickRefs(ref).any((r) => r.node.usable);
    } else {
      final c = chainsData[ref]!;
      usable = chainEntryRefs(c).any((r) => r.node.usable) && chainExitRefs(c).any((r) => r.node.usable);
    }
    return usable ? null : 'unsupported';
  }

  /// A proxy rule / app half whose target [target] is lost ([targetLoss]): why, and where its traffic goes now by its
  /// "If unavailable" [planFallback] (the plan's form: `default` / `main` / `block` / `direct` / a target id): `to` is
  /// `block` | `direct` | `main` | a target id; [TargetLost.byDefault]: the global Rules → Target unavailable decided.
  /// The same answer as the config's (routing.dart `_proxyAction`). Null when the target is usable.
  TargetLost? targetLost(String target, String planFallback) {
    final why = targetLoss(target);
    if (why == null) return null;
    const keywords = ['main', 'block', 'direct'];
    final global = keywords.contains(quickCfg.fallback) ? quickCfg.fallback : 'main';
    if (planFallback.isEmpty || planFallback == 'default') return TargetLost(why, global, true);
    if (keywords.contains(planFallback)) return TargetLost(why, planFallback, false);
    if (planFallback == target) return TargetLost(why, 'main', false);
    return targetLoss(planFallback) == null ? TargetLost(why, planFallback, false) : TargetLost(why, global, true);
  }

  /// An app half's "If unavailable" as the plan holds it (same form as [planRuleFallback]).
  String planAppFallback(AppHalf h) =>
      h.fallback == 'main' && h.fallbackTarget.isNotEmpty ? h.fallbackTarget : (h.fallback.isNotEmpty ? h.fallback : 'default');

  /// A rule's "If unavailable" as the plan holds it ("Proxy via X" is the target id X).
  String planRuleFallback(UserRule r) => r.action == 'proxy'
      ? (r.fallback == 'main' && truthy(r.fallbackTarget) ? r.fallbackTarget! : (r.fallback.isNotEmpty ? r.fallback : 'default'))
      : 'default';

  /// A rule / app target as groups (same shape as the main flow's), or null = unavailable:
  /// off in Nodes, no server the core can use, deleted (`routingTarget`).
  Json? routingTarget(String t) {
    if (!targetInfo(t).ok) return null;
    final at = t.indexOf(':'), kind = _slice(t, 0, at), ref = _slice(t, at + 1);
    try {
      if (kind == 'src') {
        final refs = [for (final n in liveNodes(sourcesData[ref]!)) NodeRef(ref, n)];
        return {
          'kind': 'unit',
          'main': planGroup(refs, 'fastest', _refOf(refs, bestAlive([for (final r in refs) r.node]))),
        };
      }
      if (kind == 'node') {
        final parts = ref.split('::'), sid = parts[0];
        final node = sourcesData[sid]!.nodes.firstWhere((n) => n.id == parts[1]);
        final r = NodeRef(sid, node);
        return {'kind': 'unit', 'main': planGroup([r], 'priority', r)};
      }
      if (kind == 'profile') {
        final refs = unitPickRefs(ref), n = unitNode(ref);
        return {'kind': 'unit', 'main': planGroup(refs, unitPriority(ref) ? 'priority' : 'fastest', _refOf(refs, n))};
      }
      return {'kind': 'chain', ..._planChain(chainsData[ref]!)};
    } on Object {
      // nothing here sing-box can use (XHTTP only) — and, like the mockup's catch-all, a target that is
      // a bare id of a source ('src1': the chain branch finds no chain): unavailable
      return null;
    }
  }

  /// The Rules screen, apps and Settings → DNS as the model the core turns into sing-box
  /// route rules and DNS (`routingPlan`). The one thing resolved here is each target: it goes
  /// along as its server group(s), or null while it is unavailable.
  Json routingPlan() {
    final rules = <Json>[];
    Json ruleOut(UserRule r) {
      // a rule's Fallback only means something for Proxy (a target of its own or the main flow);
      // "Proxy via X" (fallback 'main' + fallbackTarget) goes as the target id X
      final fb = planRuleFallback(r);
      final o = <String, dynamic>{
        'id': r.id,
        if (r.name.isNotEmpty || r.had.contains('name')) 'name': r.name,
        'action': r.action,
        'target': r.target,
        'fallback': fb,
        // the target is lost (deleted / off / no servers / unsupported): the rule goes by its "If unavailable", loudly (not in the mockup's plan, [mockupPlan])
        'targetLost': ?(r.action == 'proxy' && !mockupPlan ? targetLoss(r.target) : null),
        if (r.block != null || r.had.contains('block')) 'block': r.block,
        'dns': truthy(r.dns) ? r.dns : 'auto',
        if (r.groups != null) 'groups': deepCopy(r.groups),
      };
      if (r.composite != null) {
        o['composite'] = {
          for (final e in r.composite!.entries)
            if (e.key != 'action' && e.key != 'outbound' && e.key != 'method') e.key: deepCopy(e.value),
        };
      }
      if (r.extra != null && r.extra!.isNotEmpty) o['extra'] = deepCopy(r.extra);
      if (r.ipTunOnly) o['ipTunOnly'] = true; // no `resolve` for its IP conditions
      return o;
    }

    for (final id in ruleOrder) {
      final r = rulesData[id];
      if (r == null || !r.enabled) continue;
      rules.add(ruleOut(r));
    }
    // an app: the top-level fields are all its traffic (TCP when split), udp the other half
    // "If unavailable → Proxy via X" (fallback 'main' + fallbackTarget) goes as the target id X;
    // 'main' alone = no fallback. Only Proxy and Default (= the main flow) have one: on Default or
    // Proxy with the main flow an explicit block / direct / target id gives the main flow its own
    // "If unavailable"; 'default' / 'main' there = none (Default without one has no rule)
    String fb(AppHalf h) => planAppFallback(h);
    Json half(AppHalf h) {
      final act = h.act.isNotEmpty ? h.act : 'default';
      return {
        'act': act,
        'target': h.act == 'proxy' ? h.target : '',
        'fallback': h.act == 'proxy' || h.act.isEmpty || h.act == 'default' ? fb(h) : 'default',
        'targetLost': ?(h.act == 'proxy' && !mockupPlan ? targetLoss(h.target) : null),
      };
    }

    final apps = <Json>[];
    for (final e in appRules.entries) {
      final info = appInfo?.call(e.key);
      final a = e.value;
      apps.add({
        'id': e.key,
        'kind': info != null && info.kind.isNotEmpty ? info.kind : 'package',
        'name': appLabel(e.key), // the installed list's name, else the one kept with the rule (before the list is read), else the package
        ...half(a.tcp),
        'split': a.split,
        'udp': half(a.udp),
        // the app's own rules, in check order, enabled ones only: they go right before its route rules
        if (a.rules.any((r) => r.enabled)) 'rules': [for (final r in a.rules) if (r.enabled) ruleOut(r)],
      });
    }
    final named = <String>{};
    // a fallback that is not a keyword is a target: its group(s) must exist in the config too
    void addFb(Object? f) {
      if (f is String && f.isNotEmpty && !const ['default', 'main', 'block', 'direct'].contains(f)) named.add(f);
    }

    for (final r in rules) {
      if (r['action'] == 'proxy') {
        if (truthy(r['target'])) named.add(r['target'] as String);
        addFb(r['fallback']);
      }
    }
    for (final a in apps) {
      for (final r in (a['rules'] as List?) ?? const []) {
        r as Json;
        if (r['action'] == 'proxy') {
          if (truthy(r['target'])) named.add(r['target'] as String);
          addFb(r['fallback']);
        }
      }
      for (final h in [a, if (a['split'] == true) asJson(a['udp'])]) {
        if (h['act'] == 'proxy' && truthy(h['target'])) named.add(h['target'] as String);
        if (h['act'] == 'proxy' || h['act'] == 'default') addFb(h['fallback']);
      }
    }
    Json geo(String id) {
      RuleSetCfg? s;
      for (final x in ruleSets) {
        if (x.id == id) {
          s = x;
          break;
        }
      }
      return {'via': s != null && truthy(s.via) ? s.via : 'vpn', 'every': s?.every != null && s!.every != 0 ? s.every : 7 * 86400};
    }

    final svc = <String, dynamic>{};
    for (final k in Catalog.serviceKeys) {
      final v = quickCfg.services[k];
      if (v != null && v.isNotEmpty && v != 'default') svc[k] = v;
    }
    return {
      'apps': apps,
      'rules': rules,
      'quick': {
        'ads': quickCfg.ads,
        'region': quickCfg.regionOn ? quickCfg.region : null,
        'final': quickCfg.finalAction,
        'services': svc,
      },
      'fallback': quickCfg.fallback,
      'targets': {for (final t in named) t: routingTarget(t)},
      'ruleSets': [
        for (final s in ruleSets)
          if (!s.builtin)
            {
              'name': s.name,
              if (s.url != null) 'url': s.url,
              if (s.format != null) 'format': s.format,
              if (s.via != null) 'via': s.via,
              if (s.every != null) 'every': s.every,
            },
      ],
      'geo': {'geosite': geo('geosite'), 'geoip': geo('geoip')},
      'dns': dnsPlan(),
    };
  }

  /// Settings → DNS as `routing.dns` of the plan; the address resolver reads the same block from the saved
  /// snapshot when nothing is connected (address_resolver.dart).
  Json dnsPlan() => {
        'servers': [
          for (final id in dnsOrder)
            if (dnsServers[id] != null && mockupPlan)
              // the frozen mockup's plan: one address and one side per server (what the golden files hold)
              {'id': dnsServers[id]!.id, 'addr': dnsServers[id]!.addr, 'via': dnsServers[id]!.via, 'on': dnsServers[id]!.on}
            else if (dnsServers[id] != null)
              {
                'id': dnsServers[id]!.id,
                'on': dnsServers[id]!.on,
                'sides': [for (final s in dnsSidesAll) if (dnsServers[id]!.activeSides.contains(s)) s],
                'use': [...dnsServers[id]!.use],
                'transports': [for (final t in dnsServers[id]!.transports) {'kind': t.kind, 'addr': t.addr}],
              },
        ],
        if (!mockupPlan) 'directPolicy': dnsCfg.directPolicy, // 'localFirst' | 'priority': Local first / last on the direct side
        'resolve': dnsCfg.resolve, // 'auto' | 'off' | a server id: the `resolve` step before IP rules
        'hijack': dnsCfg.hijack, // TUN only: the core answers every DNS query
      };
}
