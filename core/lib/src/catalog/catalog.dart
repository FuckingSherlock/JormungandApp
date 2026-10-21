/// The catalog model of the app: sources, profiles, chains, the Route order, Auto / Manual,
/// off / disabled servers and the settings the connect plan reads — the Dart port of the
/// mockup's catalog logic (design/src/js/20-profiles.js, 30-nodes.js, 31-catalog.js,
/// 94-live-auto.js, 95-live.js, 93-routing-plan.js). Pure Dart, no IO, no UI; the Flutter
/// app keeps one [Catalog] and asks it what to connect through.
///
/// State = the mockup's snapshot (`liveSnapshot()`, saved by the core as `ui-state.json`):
/// [Catalog.fromJson] / [Catalog.toJson] read and write the same JSON, unknown keys
/// untouched. This file holds the state and the "which servers / which entry" decisions;
/// the plan the core takes is in plan_builder.dart, validation in validate.dart, delete
/// impact in impact.dart, state changes (select, pin, delete, sync…) in ops.dart.
///
/// Names follow the mockup (`unitRefs`, `brokenBy`, `effectiveConnectId`…) so the two can be
/// read side by side. Not ported (UI-only): rendering, sheets / toasts, drag gestures,
/// edit modes, expanded rows, node sort, logs / events / notification settings, the
/// ping mock, `refreshSourceViews`, `sourcesDown` (posts a UI event), kill-switch plan
/// (`killPlan`, it goes in the connect body, not the plan).
library;

import '../routing.dart' show services;
import 'json_util.dart';
import 'models.dart';
import 'ping_book.dart';
import 'rules_model.dart';
import 'settings.dart';

/// What the core's Auto reports it stands on (`status.auto`: `{now, server, entryServer}`).
/// The dock and Route show it instead of the catalog's own guess ([Catalog.coreRoute]).
class CoreRoute {
  const CoreRoute({required this.id, this.server, this.entryServer});

  /// The Route entry the core is on.
  final String id;

  /// `sid::nid`: the unit's server, or a chain's exit server.
  final String? server;

  /// `sid::nid`: a chain's entry server.
  final String? entryServer;
}

/// Why a plan, or a connect, cannot be made. [message] is the mockup's text (English); the
/// app localises by [code]: `nothingInAuto`, `nothingToConnect`, `noUsableServer`.
class CatalogException implements Exception {
  CatalogException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// An app of the installed list (the mockup's `APPS`): the plan names apps by it.
typedef AppInfo = ({String name, String kind});

class Catalog {
  Catalog({int Function()? now}) : pings = PingBook(now: now) {
    _loadDefaults();
  }

  /// [s] = the snapshot, or null on a first run (nothing added yet; `liveApply(null)`).
  factory Catalog.fromJson(Json? s, {int Function()? now}) {
    final c = Catalog(now: now);
    if (s != null) c._load(s);
    return c;
  }

  // ───────────────────────────── state (the snapshot) ─────────────────────────────

  Map<String, Source> sourcesData = {};
  List<String> sourceOrder = [];
  int sourceSeq = 1;

  /// `simple` | `profiles`: which Nodes tab the Route list uses.
  String connectMode = 'simple';

  /// The priority list of the active mode (entries and chains together).
  List<String> connectOrder = [];
  String? activeConnectId;
  bool autoConnect = true;

  /// Manual on one server: `sid::nid` of a server of the pinned entry (Manual only).
  String? pinnedNode;

  /// The Route state of the mode that is not active (and a stale copy of the other).
  Map<String, ModeSlot> modeState = {};
  Map<String, Profile> profilesData = {};
  int profileSeq = 1;
  Map<String, Chain> chainsData = {};
  int chainSeq = 1;

  /// What each Nodes tab lists, in the user's order: `simple` (sources + chains of sources),
  /// `profiles` (profiles + chains of profiles).
  Map<String, List<String>> catalogOrder = {'simple': [], 'profiles': []};

  /// The mode's Route list has its own order (dragged in Route), apart from Nodes.
  Map<String, bool> routeCustom = {'simple': false, 'profiles': false};
  late SegState segState;
  late ConnCfg connCfg;
  late AutoCfg autoCfg;

  Map<String, UserRule> rulesData = {};
  List<String> ruleOrder = [];
  int ruleSeq = 1;
  late QuickCfg quickCfg;
  Map<String, AppRule> appRules = {};
  late List<RuleSetCfg> ruleSets;
  int rsSeq = 1;
  late Map<String, DnsServerCfg> dnsServers;
  late List<String> dnsOrder;
  int dnsSeq = 1;
  late DnsCfg dnsCfg;

  /// Measured pings (`snapshot.pings`).
  final PingBook pings;

  /// A chain's exits measured through one of its entries (`snapshot.pairs`): what decides
  /// whether an exit works in the chain, instead of the direct [pings].
  final PairBook pairs = PairBook();

  /// Keys of the snapshot this model does not know (`genCfg`, `notifCfg`, `logCfg`…):
  /// written back as they were.
  Json unknown = {};

  // ───────────────────────────── runtime (not in the snapshot) ─────────────────────────────

  /// Where the core's Auto really is (null = not connected / unknown). While set,
  /// [effectiveConnectId] and [unitNode] show it instead of their own guess.
  CoreRoute? coreRoute;

  /// The server every route group of the running plan stands on, by route id (`status.auto.routes`
  /// reports all of them, not only the current route): [coreNode] shows them for the routes Auto is
  /// not on, and a new plan starts each group where it was ([coreGroupNode]). Empty = not connected.
  Map<String, CoreRoute> coreGroups = {};

  /// The plan as the frozen mockup builds it (the golden tests set it): in Manual it holds the
  /// anchor alone, so Auto ↔ Manual is another plan (a reconnect), and a Priority chain exit starts
  /// on the first one measured alive. False (the real hosts): the plan holds every Auto route in
  /// either mode and carries `manual`, the core switches the mode live; a Priority chain exit starts
  /// on the first one not known dead.
  bool mockupPlan = false;

  /// The anchor the running plan was built on (`live.anchor`): [liveSigAnchor] keeps it
  /// while it is still an Auto entry.
  String? liveAnchor;

  /// Delete preview (`simExclude`): while set, units act as if these servers were gone.
  bool Function(NodeRef)? simExclude;

  /// The installed apps (name, kind) for the plan and the delete dialog; the host sets it.
  AppInfo? Function(String pkg)? appInfo;

  int get now => pings.now;

  // ───────────────────────────── JSON ─────────────────────────────

  static const _known = {
    'sourcesData', 'sourceOrder', 'sourceSeq', 'connectMode', 'connectOrder', 'activeConnectId', 'autoConnect', 'pinnedNode', //
    'modeState', 'profilesData', 'profileSeq', 'chainsData', 'chainSeq', 'catalogOrder', 'routeCustom', 'segState', 'connCfg', 'autoCfg',
    'rulesData', 'ruleOrder', 'ruleSeq', 'quickCfg', 'appRules', 'ruleSets', 'rsSeq', 'dnsServers', 'dnsOrder', 'dnsSeq', 'dnsCfg', 'pings', 'pairs',
  };

  void _loadDefaults() {
    segState = SegState();
    connCfg = ConnCfg();
    autoCfg = AutoCfg();
    quickCfg = QuickCfg();
    ruleSets = [
      for (final id in ['geosite', 'geoip'])
        RuleSetCfg.fromJson({
          'id': id,
          'name': id,
          'builtin': true,
          'url': 'built-in',
          'format': 'srs',
          'via': 'vpn',
          'every': 7 * 86400,
          'updated': 'with the first connect',
        }),
    ];
    dnsServers = {for (final s in defaultDnsServers()) s.id: s};
    dnsOrder = [...dnsServers.keys];
    dnsCfg = DnsCfg();
    modeState = {'profiles': ModeSlot()};
  }

  // `liveApply` (95-live.js) for the parts that decide the plan.
  void _load(Json s) {
    Map<String, T> mapOf<T>(Object? m, T Function(Json) f) =>
        m is Map ? {for (final e in m.entries) '${e.key}': f(asJson(e.value))} : <String, T>{};
    int seq(Object? v) => v is num && v != 0 ? v.toInt() : 1;

    sourcesData = mapOf(s['sourcesData'], Source.fromJson);
    sourceOrder = strList(s['sourceOrder']);
    sourceSeq = seq(s['sourceSeq']);
    connectMode = truthy(s['connectMode']) ? '${s['connectMode']}' : 'simple';
    connectOrder = strList(s['connectOrder']);
    activeConnectId = truthy(s['activeConnectId']) ? '${s['activeConnectId']}' : null;
    autoConnect = s['autoConnect'] != false;
    pinnedNode = truthy(s['pinnedNode']) ? '${s['pinnedNode']}' : null;
    profilesData = mapOf(s['profilesData'], Profile.fromJson);
    profileSeq = seq(s['profileSeq']);
    chainsData = mapOf(s['chainsData'], Chain.fromJson);
    chainSeq = seq(s['chainSeq']);
    if (s['modeState'] is Map) modeState = mapOf(s['modeState'], ModeSlot.fromJson);
    if (s['catalogOrder'] is Map) {
      final co = asJson(s['catalogOrder']);
      catalogOrder = {for (final e in co.entries) e.key: strList(e.value)};
    }
    for (final m in const ['simple', 'profiles']) {
      catalogOrder.putIfAbsent(m, () => []);
    }
    if (s['routeCustom'] is Map) {
      final rc = asJson(s['routeCustom']);
      routeCustom = {for (final e in rc.entries) e.key: truthy(e.value)};
    }
    for (final m in const ['simple', 'profiles']) {
      routeCustom.putIfAbsent(m, () => false);
    }
    if (s['segState'] is Map) segState = SegState.fromJson(asJson(s['segState']));
    if (s['connCfg'] is Map) connCfg = ConnCfg.fromJson(asJson(s['connCfg']));
    if (s['autoCfg'] is Map) autoCfg = AutoCfg.fromJson(asJson(s['autoCfg']));
    rulesData = mapOf(s['rulesData'], UserRule.fromJson);
    ruleOrder = strList(s['ruleOrder']);
    ruleSeq = seq(s['ruleSeq']);
    quickCfg = QuickCfg.fromJson(asJson(s['quickCfg']));
    appRules = mapOf(s['appRules'], AppRule.fromJson);
    if (s['ruleSets'] is List) {
      ruleSets = [for (final x in s['ruleSets'] as List) RuleSetCfg.fromJson(asJson(x))];
    }
    rsSeq = seq(s['rsSeq']);
    if (s['dnsServers'] is Map) {
      dnsServers = mapOf(s['dnsServers'], DnsServerCfg.fromJson);
      dnsOrder = s['dnsOrder'] is List ? strList(s['dnsOrder']) : dnsServers.keys.toList();
      dnsSeq = seq(s['dnsSeq']);
    }
    if (s['dnsCfg'] is Map) {
      dnsCfg = DnsCfg.fromJson(asJson(s['dnsCfg']));
    } else if (s['dnsServers'] is Map) {
      dnsCfg.listVersion = 1; // a list without settings next to it: from before the marker
    }
    // the stored DNS list of an older version is replaced once by the defaults (the user's own servers stay,
    // docs/rules.md §6); the marker in dnsCfg says it was done, so every later load keeps the list as it is
    if (dnsCfg.listVersion < dnsListVersion) {
      if (s['dnsServers'] is Map) {
        final m = migrateDnsList(dnsServers, dnsOrder);
        dnsServers = m.servers;
        dnsOrder = m.order;
        if (m.renamed.containsKey(dnsCfg.resolve)) dnsCfg.resolve = m.renamed[dnsCfg.resolve]!;
        for (final r in rulesData.values) {
          if (r.dns != null && m.renamed.containsKey(r.dns)) r.dns = m.renamed[r.dns];
        }
      }
      dnsCfg.listVersion = dnsListVersion;
    }
    applyBuiltinDnsAddresses(dnsServers); // after the migration: its input keeps the old stored addresses

    pings.restore(s['pings'], [for (final x in sourcesData.values) ...[...x.nodes, ...x.gone]]);
    pairs.restore(s['pairs']);
    unknown = {for (final e in s.entries) if (!_known.contains(e.key)) e.key: deepCopy(e.value)};
  }

  /// The snapshot, as `liveSnapshot()` writes it.
  Json toJson() => {
        'sourcesData': {for (final e in sourcesData.entries) e.key: e.value.toJson()},
        'sourceOrder': [...sourceOrder],
        'sourceSeq': sourceSeq,
        'connectMode': connectMode,
        'connectOrder': [...connectOrder],
        'activeConnectId': activeConnectId,
        'autoConnect': autoConnect,
        'pinnedNode': pinnedNode,
        'modeState': {for (final e in modeState.entries) e.key: e.value.toJson()},
        'profilesData': {for (final e in profilesData.entries) e.key: e.value.toJson()},
        'profileSeq': profileSeq,
        'chainsData': {for (final e in chainsData.entries) e.key: e.value.toJson()},
        'chainSeq': chainSeq,
        'catalogOrder': {for (final e in catalogOrder.entries) e.key: [...e.value]},
        'routeCustom': {...routeCustom},
        'segState': segState.toJson(),
        'connCfg': connCfg.toJson(),
        'autoCfg': autoCfg.toJson(),
        'rulesData': {for (final e in rulesData.entries) e.key: e.value.toJson()},
        'ruleOrder': [...ruleOrder],
        'ruleSeq': ruleSeq,
        'quickCfg': quickCfg.toJson(),
        'appRules': {for (final e in appRules.entries) e.key: e.value.toJson()},
        'ruleSets': [for (final r in ruleSets) r.toJson()],
        'rsSeq': rsSeq,
        'dnsServers': {for (final e in dnsServers.entries) e.key: e.value.toJson()},
        'dnsOrder': [...dnsOrder],
        'dnsSeq': dnsSeq,
        'dnsCfg': dnsCfg.toJson(),
        'pings': pings.toJson(),
        'pairs': pairs.toJson(),
        ...deepCopy(unknown) as Json,
      };

  /// The built-in services of the quick rules, in the UI's order.
  static List<String> get serviceKeys => services.keys.toList();

  // ───────────────────────────── entries and units ─────────────────────────────

  bool get simpleMode => connectMode == 'simple';

  /// A Route entry or a chain end by id: profile, chain or source (`connectEntry`).
  Entry? connectEntry(String? id) => id == null ? null : profilesData[id] ?? chainsData[id] ?? sourcesData[id];

  bool isChain(String? id) => id != null && chainsData.containsKey(id);

  /// Profile ids in catalog order (`getProfileIds`).
  List<String> getProfileIds() => catalogOrder['profiles']!.where(profilesData.containsKey).toList();

  /// Chain-able entries of a mode in catalog order: enabled sources, or profiles
  /// (`unitIdsOf`).
  List<String> unitIdsOf(String mode) => catalogOrder[mode]!
      .where((id) => mode == 'simple' ? (sourcesData[id]?.enabled ?? false) : profilesData.containsKey(id))
      .toList();

  /// Which Nodes tab (= connect mode) an entry belongs to (`modeOf`).
  String? modeOf(String id) => catalogOrder['simple']!.contains(id)
      ? 'simple'
      : catalogOrder['profiles']!.contains(id)
          ? 'profiles'
          : null;

  /// The priority list of either mode (the active one lives in [connectOrder]).
  List<String> modeOrder(String mode) => mode == connectMode ? connectOrder : modeSlot(mode).order;
  void setModeOrder(String mode, List<String> order) {
    if (mode == connectMode) {
      connectOrder = order;
    } else {
      modeSlot(mode).order = order;
    }
  }

  /// The stored state of a mode that is not active; made when missing.
  ModeSlot modeSlot(String mode) => modeState.putIfAbsent(mode, () => ModeSlot());

  bool isNodeDisabled(Source s, String nid) => s.disabledNodes.contains(nid);

  /// The servers the rest of the app sees (`liveNodes`). Unusable ones stay here (the plan names them `unsupported`);
  /// lists of the UI show them in the «Unavailable» block instead ([unsupportedRefs]).
  List<CatalogNode> liveNodes(Source s) => s.nodes.where((n) => !isNodeDisabled(s, n.id)).toList();

  bool isNodeOff(Source s, String nid) => s.offNodes.contains(nid);
  int offCount(Source s) => liveNodes(s).where((n) => isNodeOff(s, n.id)).length;

  /// A server by its `sid::nid` key (`nodeOfKey`).
  CatalogNode? nodeOfKey(String key) {
    final i = key.indexOf('::');
    final s = i > 0 ? sourcesData[key.substring(0, i)] : null;
    if (s == null) return null;
    final nid = key.substring(i + 2);
    for (final n in s.nodes) {
      if (n.id == nid) return n;
    }
    return null;
  }

  bool simKeep(NodeRef r) => simExclude == null || !simExclude!(r);

  /// The servers a profile can use now (enabled sources, live servers), `{sid, node}`;
  /// [withOff] also counts what is switched off in Nodes (to tell why a profile has none).
  List<NodeRef> profileNodeRefs(Profile p, {bool withOff = false}) => profileRefsOf(p.sources, p.nodes, withOff: withOff);

  /// [profileNodeRefs] for a draft: whole [sources] and single [nodes] (`sid::nid`).
  List<NodeRef> profileRefsOf(List<String> sources, List<String> nodes, {bool withOff = false}) {
    final refs = <NodeRef>[];
    for (final sid in sourceOrder) {
      final s = sourcesData[sid];
      if (s == null || !(s.enabled || withOff)) continue;
      final whole = sources.contains(sid);
      for (final n in withOff ? s.nodes : liveNodes(s)) {
        if (whole || nodes.contains('$sid::${n.id}')) refs.add(NodeRef(sid, n));
      }
    }
    return refs.where(simKeep).toList();
  }

  /// A unit's servers: a profile's, or a source's own entry (live servers minus the ones
  /// switched off for it) (`unitRefs`).
  List<NodeRef> unitRefs(String? id, {bool withOff = false}) {
    if (id == null) return [];
    final p = profilesData[id];
    if (p != null) return profileNodeRefs(p, withOff: withOff);
    final s = sourcesData[id];
    if (s == null || !(s.enabled || withOff)) return [];
    return [
      for (final n in withOff ? s.nodes : liveNodes(s))
        if (!isNodeOff(s, n.id)) NodeRef(id, n),
    ].where(simKeep).toList();
  }

  /// Servers of a unit the provider dropped (`s.gone`) — "Unavailable" with their kept
  /// settings. Disabled sources show nothing.
  List<NodeRef> unitGoneRefs(String id) {
    final p = profilesData[id];
    final sids = p != null ? sourceOrder : [id];
    final refs = <NodeRef>[];
    for (final sid in sids) {
      final s = sourcesData[sid];
      if (s == null || !s.enabled) continue;
      for (final node in s.gone) {
        if (p == null || p.sources.contains(sid) || p.nodes.contains('$sid::${node.id}')) refs.add(NodeRef(sid, node));
      }
    }
    return refs;
  }

  List<NodeRef> goneRefs(String sid) => [for (final n in sourcesData[sid]?.gone ?? <CatalogNode>[]) NodeRef(sid, n)];

  /// Servers of a source that cannot go into a config (not usable), not switched off in Nodes; empty when the
  /// source is missing.
  List<NodeRef> unsupportedRefs(String sid) {
    final s = sourcesData[sid];
    if (s == null) return [];
    return [for (final n in s.nodes) if (!n.usable && !isNodeDisabled(s, n.id)) NodeRef(sid, n)];
  }

  // ───────────────────────────── off in Nodes: "broken" entries ─────────────────────────────

  /// What to switch back on for these refs (a whole source, or one server).
  List<OffReason> offReasons(Iterable<NodeRef> allRefs) {
    final m = <String, OffReason>{};
    for (final r in allRefs) {
      final s = sourcesData[r.sid];
      if (s == null) continue;
      if (!s.enabled) {
        m[r.sid] = OffReason(r.sid);
      } else if (isNodeDisabled(s, r.node.id)) {
        m[r.key] = OffReason(r.sid, r.node.id);
      }
    }
    return m.values.toList();
  }

  /// A side that has no live server, but would with everything in Nodes switched on.
  List<OffReason> sideReasons(List<NodeRef> live, List<NodeRef> all) => live.isNotEmpty ? [] : offReasons(all);

  /// What to switch on for an entry that has nothing left to connect through; [] = it
  /// works (`brokenBy`).
  List<OffReason> brokenBy(String id) {
    final c = chainsData[id];
    if (c != null) {
      final seen = <String>{};
      return [
        ...sideReasons(chainEntryRefs(c), chainEntryRefs(c, withOff: true)),
        ...sideReasons(chainExitRefs(c), chainExitRefs(c, withOff: true)),
      ].where((r) => seen.add('${r.sid}::${r.nid ?? ''}')).toList();
    }
    return connectEntry(id) != null ? sideReasons(unitRefs(id), unitRefs(id, withOff: true)) : [];
  }

  String reasonLabel(OffReason r) {
    if (r.nid == null) return sourcesData[r.sid]?.name ?? r.sid;
    CatalogNode? n;
    for (final x in sourcesData[r.sid]?.nodes ?? <CatalogNode>[]) {
      if (x.id == r.nid) n = x;
    }
    return n == null ? r.nid! : '${n.flag} ${n.name}';
  }

  /// "Remnawave is off in Nodes" / "🇩🇪 Frankfurt 01, … are off in Nodes" (up to 3 named).
  String reasonsText(List<OffReason> rs) {
    final names = rs.take(3).map(reasonLabel).join(', ') + (rs.length > 3 ? ' +${rs.length - 3}' : '');
    return '$names${rs.length > 1 ? ' are' : ' is'} off in Nodes';
  }

  bool isBroken(String id) => brokenBy(id).isNotEmpty;

  /// A switched-off source's own entry is hidden (`entryVisible`).
  bool entryVisible(String? id) {
    final s = id == null ? null : sourcesData[id];
    return !(s != null && !s.enabled);
  }

  /// The Route list as shown: working entries in priority order (`visibleOrder`).
  List<String> visibleOrder() => connectOrder.where((id) => entryVisible(id) && !isBroken(id)).toList();

  /// Broken entries, shown below the list (`brokenOrder`).
  List<String> brokenOrder() => connectOrder.where((id) => entryVisible(id) && isBroken(id)).toList();

  /// First run or everything deleted: nothing in this mode to connect (`catalogEmpty`).
  bool catalogEmpty() => modeEmpty(connectMode);

  /// Nothing to connect through in [mode] (either one, active or not): the mode cannot be
  /// switched to, Route offers to create something there instead.
  bool modeEmpty(String mode) => !modeOrder(mode).any(entryVisible);

  String unitName(String? id) {
    final u = id == null ? null : profilesData[id] ?? sourcesData[id];
    return u?.name ?? '—';
  }

  // ───────────────────────────── which server a unit connects through ─────────────────────────────

  Unit? unitOwner(String? id) => id == null ? null : profilesData[id] ?? sourcesData[id];
  bool unitPriority(String? id) => unitOwner(id)?.pickMode == 'priority';

  /// The unit's servers in the order it picks them: Priority by `pickOrder`
  /// (`unitPickRefs`).
  List<NodeRef> unitPickRefs(String? id, {bool withOff = false}) {
    final refs = unitRefs(id, withOff: withOff);
    return unitPriority(id) ? orderRefs(refs, unitOwner(id)!.pickOrder) : refs;
  }

  /// Refs sorted by a list of `sid::nid` keys; the ones missing from it follow in their own
  /// order (`orderRefs`).
  List<NodeRef> orderRefs(List<NodeRef> refs, List<String>? order) {
    order ??= const [];
    num pos(NodeRef r) {
      final i = order!.indexOf(r.key);
      return i < 0 ? double.infinity : i;
    }

    return stableSorted(refs, pos);
  }

  /// The pinned server of the pinned entry, while it is still one of the entry's servers
  /// (`pinnedRef`).
  NodeRef? pinnedRef(String? id) {
    if (autoConnect || id != activeConnectId || pinnedNode == null) return null;
    for (final r in unitRefs(id)) {
      if (r.key == pinnedNode) return r;
    }
    return null;
  }

  /// Manual on a server is strict (docs/connect-model.md → «Auto / Manual»): when the pick cannot be used — the server
  /// is gone from its subscription, switched off, not a server sing-box can run, or its entry is gone — this says why
  /// (an English message naming the server), and nothing connects through another server. Null: no pick, or it is fine.
  ///
  /// Manual on an entry (no server pinned) is strict the same way: an entry that is removed, switched off in Nodes, left with
  /// no server or only ones sing-box cannot run is the same kind of loss (the message names the entry).
  String? pinLoss() => pinLossInfo()?.text;

  /// [pinLoss] with its parts: [why] is `deleted` (the server or the entry is gone, or has no server), `off` (switched off
  /// in Nodes) or `unsupported` (sing-box cannot run it); [pick] is the pinned server's name ('' when it is gone from its subscription), with no server pinned the entry's
  /// ('' when the entry is gone too).
  ({String text, String why, String pick})? pinLossInfo() {
    final key = pinnedNode, id = activeConnectId;
    if (autoConnect || id == null) return null;
    if (key == null) return _entryLoss(id);
    final parts = key.split('::'), s = sourcesData[parts[0]];
    CatalogNode? n;
    if (s != null) {
      for (final x in s.nodes) {
        if (parts.length > 1 && x.id == parts[1]) n = x;
      }
    }
    final who = n != null && n.name.isNotEmpty ? '"${n.name}"${s!.name.isNotEmpty ? ' (${s.name})' : ''}' : 'the pinned server';
    // the server's own name; one gone from its subscription has none left (never the entry's name in its place)
    final pick = n != null && n.name.isNotEmpty ? n.name : '';
    ({String text, String why, String pick}) lost(String why, String reason) => (
      text: 'Manual pick $who is unavailable: $reason. The tunnel is not moved to another server — choose a server in Route.',
      why: why,
      pick: pick,
    );
    if (!entryVisible(id) || isBroken(id)) return lost('deleted', 'its entry is gone or has no server the core can use');
    if (n == null) return lost('deleted', 'the subscription no longer has it');
    final r = pinnedRef(id);
    if (r == null) return lost('off', 'it is switched off');
    if (!r.node.usable) {
      final u = r.node.unsupported;
      return lost('unsupported', 'sing-box cannot run it${u != null && u.isNotEmpty ? ' ($u is not in sing-box)' : ''}');
    }
    return null;
  }

  /// Why the Manual entry [id] cannot carry the tunnel (`pinLossInfo`); null = it can (an entry that answers badly or not at all still can).
  ({String text, String why, String pick})? _entryLoss(String id) {
    final e = connectEntry(id);
    final who = e != null && e.name.isNotEmpty ? '"${e.name}"' : 'the pinned entry';
    final pick = e?.name ?? '';
    ({String text, String why, String pick}) lost(String why, String reason) => (
      text: 'Manual pick $who is unavailable: $reason. The tunnel is not moved to another entry — choose an entry in Route.',
      why: why,
      pick: pick,
    );
    if (e == null) return lost('deleted', 'it was removed');
    if (!entryVisible(id)) return lost('off', 'it is switched off in Nodes');
    final off = brokenBy(id);
    if (off.isNotEmpty) return lost('off', reasonsText(off));
    final c = chainsData[id];
    final refs = c != null ? [...chainEntryRefs(c), ...chainExitRefs(c)] : unitRefs(id);
    final both = c == null || (chainEntryRefs(c).any((r) => r.node.usable) && chainExitRefs(c).any((r) => r.node.usable));
    if (refs.isEmpty || !both || !refs.any((r) => r.node.usable)) {
      String? u;
      for (final r in refs) {
        final x = r.node.unsupported;
        if (x != null && x.isNotEmpty) u = x;
      }
      if (refs.isEmpty) return lost('deleted', 'it has no server');
      return lost('unsupported', 'sing-box cannot run its servers${u != null ? ' ($u is not in sing-box)' : ''}');
    }
    return null;
  }

  /// The server the core's Auto is on, when it is one of [refs] (`coreNode`).
  /// [which]: `server` or `entryServer`.
  CatalogNode? coreNode(String? id, String which, List<NodeRef> refs) {
    final c = coreRoute;
    if (c == null) return null;
    return _coreServer(c.id == id ? c : coreGroups[id], which, refs);
  }

  /// The server the core has a route's group on, whatever route it is on now and also while
  /// [withoutCore]: what a plan built for a reconnect starts the group on (`chosen`), so a standby
  /// route keeps the server Auto had moved it to. Null = not known / not one of [refs].
  CatalogNode? coreGroupNode(String? id, String which, List<NodeRef> refs) => _coreServer(coreGroups[id], which, refs);

  CatalogNode? _coreServer(CoreRoute? c, String which, List<NodeRef> refs) {
    if (c == null) return null;
    final key = which == 'server' ? c.server : c.entryServer;
    if (key == null) return null;
    for (final r in refs) {
      if (r.key == key) return r.node;
    }
    return null;
  }

  /// The fastest alive server (first wins on a tie); a weak answer ([PingEntry.byChecker]) loses to any strong
  /// one (`bestAlive`).
  CatalogNode? bestAlive(Iterable<CatalogNode> nodes) {
    CatalogNode? best;
    for (final n in nodes) {
      if (pings.isAlive(n) && (best == null || pings.rank(n) < pings.rank(best))) best = n;
    }
    return best;
  }

  /// The first server in order that is not known dead: one not measured yet is a candidate too
  /// (unmeasured is not dead, as in [mayWork]); a measured, answering one counts, a known-dead
  /// one is skipped. Null = every server is known dead.
  CatalogNode? _firstAlive(Iterable<CatalogNode> nodes) {
    for (final n in nodes) {
      if (!knownDead(n)) return n;
    }
    return null;
  }

  /// The server a unit connects through now: the pinned one (answering or not), the one
  /// the core is on, else by Fastest / Priority (`unitNode`).
  CatalogNode? unitNode(String? id) {
    final pin = pinnedRef(id);
    if (pin != null) return pin.node;
    final refs = unitPickRefs(id);
    final core = coreNode(id, 'server', refs);
    if (core != null) return core;
    final nodes = [for (final r in refs) r.node];
    return unitPriority(id) ? _firstAlive(nodes) : bestAlive(nodes);
  }

  CatalogNode? profileNode(Profile? p) => p == null ? null : unitNode(p.id);

  // ───────────────────────────── chains ─────────────────────────────

  /// Servers of a source end that the source's own editor switched off (`offNodes`) while
  /// still on in Nodes: the chain editor offers them in "Disabled in subscription". Only a
  /// source end has them (a profile ignores `offNodes`). [side]: `in` | `out`.
  List<NodeRef> chainOffRefs(Chain c, String side) {
    final id = side == 'in' ? c.inId : c.outId;
    final s = id == null || profilesData.containsKey(id) ? null : sourcesData[id];
    if (s == null || !s.enabled) return [];
    return [
      for (final n in liveNodes(s))
        if (isNodeOff(s, n.id)) NodeRef(id!, n),
    ].where(simKeep).toList();
  }

  /// The [chainOffRefs] this chain switched on for itself (`inOn` / `outOn`); [withOff] also
  /// counts a switched-off source and servers off in Nodes (to tell why an end has none).
  List<NodeRef> chainForcedRefs(Chain c, String side, {bool withOff = false}) {
    final id = side == 'in' ? c.inId : c.outId;
    final on = side == 'in' ? c.inOn : c.outOn;
    final s = id == null || profilesData.containsKey(id) ? null : sourcesData[id];
    if (s == null || on.isEmpty || !(s.enabled || withOff)) return [];
    return [
      for (final n in withOff ? s.nodes : liveNodes(s))
        if (isNodeOff(s, n.id) && on.contains('$id::${n.id}')) NodeRef(id!, n),
    ].where(simKeep).toList();
  }

  /// An end's servers before the chain's own ticks (`chainSideRefs`): the unit's, plus the ones
  /// this chain forced on.
  List<NodeRef> chainSideRefs(Chain c, String side, {bool withOff = false}) => [
        ...unitRefs(side == 'in' ? c.inId : c.outId, withOff: withOff),
        ...chainForcedRefs(c, side, withOff: withOff),
      ];

  List<NodeRef> chainEntryRefs(Chain c, {bool withOff = false}) =>
      chainSideRefs(c, 'in', withOff: withOff).where((r) => !c.inOff.contains(r.key)).toList();

  /// Every exit server in priority order, unticked ones included (`chainExitOrder`): the chain's
  /// own order first; servers it never ordered follow the exit unit's own `pickOrder`.
  List<NodeRef> chainExitOrder(Chain c, {bool withOff = false}) =>
      orderRefs(orderRefs(chainSideRefs(c, 'out', withOff: withOff), unitOwner(c.outId)?.pickOrder), c.exitOrder);

  List<NodeRef> chainExitRefs(Chain c, {bool withOff = false}) =>
      chainExitOrder(c, withOff: withOff).where((r) => !c.outOff.contains(r.key)).toList();

  CatalogNode? chainEntryNode(Chain c) {
    final refs = chainEntryRefs(c);
    return coreNode(c.id, 'entryServer', refs) ?? bestAlive([for (final r in refs) r.node]);
  }

  /// The exit [x] as the chain sees it: its pair with the entry in use ([entry], default
  /// [chainEntryNode]) — an exit may be unreachable directly and fine through the entry.
  /// An entry that never measured it hands over to the fastest fresh answer of [x] through
  /// another entry of the chain (a miss through another entry proves nothing: it may be that
  /// entry that was dead); null = no pair measured.
  PingEntry? chainPair(Chain c, CatalogNode x, [CatalogNode? entry]) {
    entry ??= chainEntryNode(c);
    final own = entry == null ? null : pairs.entry(entry, x);
    if (own != null) return own;
    PingEntry? best;
    for (final r in chainEntryRefs(c)) {
      final p = pairs.entry(r.node, x);
      if (p == null || p.ms == null || p.ms! < 0 || pings.now - p.at >= pingFreshMs) continue;
      if (best == null || p.rank < best.rank) best = p; // a weak answer loses to a strong one
    }
    return best;
  }

  /// What the exit [x] shows in the chain: the [chainPair]; a pair never measured shows the
  /// server's direct answer, but only a live one (a direct miss says nothing about the way
  /// through the entry). Null = unknown.
  PingEntry? chainExitEntry(Chain c, CatalogNode x, [CatalogNode? entry]) {
    final p = chainPair(c, x, entry);
    if (p != null) return p;
    final d = pings.entry(x);
    return d != null && d.ms != null && d.ms! >= 0 ? d : null;
  }

  /// ms the exit answers through the chain; null = unknown or a ping in flight, `-1` = dead.
  num? chainExitPing(Chain c, CatalogNode x, [CatalogNode? entry]) => chainExitEntry(c, x, entry)?.ms;

  bool chainExitAlive(Chain c, CatalogNode x, [CatalogNode? entry]) {
    final v = chainExitPing(c, x, entry);
    return v != null && v >= 0;
  }

  /// Order by the chain's own measures: strong answers by ms, weak ones (backup checker only) after them, unknown,
  /// dead last ([PingEntry.rank]).
  double chainExitRank(Chain c, CatalogNode x, [CatalogNode? entry]) => chainExitEntry(c, x, entry)?.rank ?? 1e9;

  CatalogNode? chainExitNode(Chain c) {
    final refs = chainExitRefs(c);
    final core = coreNode(c.id, 'server', refs);
    if (core != null) return core;
    final entry = chainEntryNode(c);
    final exits = [for (final r in refs) r.node];
    if (c.exitMode == 'priority') {
      for (final x in exits) {
        if (chainExitAlive(c, x, entry)) return x;
      }
      return null;
    }
    CatalogNode? best;
    for (final x in exits) {
      if (chainExitAlive(c, x, entry) && (best == null || chainExitRank(c, x, entry) < chainExitRank(c, best, entry))) best = x;
    }
    return best;
  }

  /// The chain's latency for the dock and the card: the pair measured for the entry and exit
  /// in use (the whole chain); both hops added up while that pair was never measured. Null =
  /// no answer or nothing measured.
  int? chainLatency(Chain c) {
    final a = chainEntryNode(c);
    if (a == null) return null;
    final b = chainExitNode(c);
    if (b == null) return null;
    final p = chainPair(c, b, a);
    if (p != null && p.ms != null) return p.ms! >= 0 ? p.ms!.round() : null;
    return pings.isAlive(a) && pings.isAlive(b) ? (pings.ping(a)! + pings.ping(b)!).round() : null;
  }

  /// The entry has a server to connect through and it answers (`isUsable`).
  bool isUsable(String id) {
    final c = chainsData[id];
    if (c != null) return chainEntryNode(c) != null && chainExitNode(c) != null;
    final n = unitNode(id);
    return n != null && pings.isAlive(n);
  }

  // ───────────────────────────── Auto / Manual: which entry ─────────────────────────────

  /// Known not to work: silent `failAfter` times in a row, the last time within
  /// [pingFreshMs] (a result being re-measured keeps counting until the new one is in).
  /// Servers not measured yet, or measured long ago, still count as working (`knownDead`).
  bool knownDead(CatalogNode n) => _deadEntry(pings.entry(n));

  bool _deadEntry(PingEntry? e) {
    if (e == null) return false;
    final missed = e.testing || (e.ms != null && e.ms! < 0);
    return missed && e.fails >= autoCfg.failAfter && pings.now - e.at < pingFreshMs;
  }

  /// A chain's exit is known not to work through the entry in use (its pair, [chainPair]); a
  /// direct miss says nothing, a pair never measured is not dead.
  bool chainExitKnownDead(Chain c, CatalogNode x, [CatalogNode? entry]) => _deadEntry(chainPair(c, x, entry));

  /// Auto passes over an entry only when it is known not to work (`mayWork`): some server
  /// not known dead; for a chain, an entry not known dead and an exit not known dead through
  /// the entry in use.
  bool mayWork(String id) {
    final c = chainsData[id];
    if (c != null) {
      if (!chainEntryRefs(c).any((r) => !knownDead(r.node))) return false;
      final entry = chainEntryNode(c);
      return chainExitRefs(c).any((r) => !chainExitKnownDead(c, r.node, entry));
    }
    return unitPickRefs(id).any((r) => !knownDead(r.node));
  }

  /// The Auto entries in priority order (`autoOrder`).
  List<String> autoOrder() => visibleOrder().where((id) => connectEntry(id)!.inAuto).toList();

  /// What is connected: the pinned entry, or Auto's pick. Connected, the entry the core's
  /// Auto is really on; [ownGuess] = the catalog's own pick regardless (to build a plan)
  /// (`effectiveConnectId`). Null: nothing to connect through.
  String? effectiveConnectId([bool ownGuess = false]) {
    final active = activeConnectId;
    // Manual is strict: the pinned entry stays the one, hidden / broken / unusable too ([pinLoss] refuses it, nothing
    // takes Auto's pick in its place)
    if (!autoConnect && (active == null || connectEntry(active) != null)) return active;
    final order = visibleOrder();
    final c = coreRoute;
    if (!ownGuess && c != null && order.contains(c.id) && connectEntry(c.id)!.inAuto) return c.id;
    for (final id in order) {
      if (connectEntry(id)!.inAuto && mayWork(id)) return id;
    }
    for (final id in order) {
      if (connectEntry(id)!.inAuto) return id; // every entry silent: still the first one in Auto
    }
    return null;
  }

  /// What Auto would pick, whatever the current mode (`effectiveConnectIdWhenAuto`).
  String? effectiveConnectIdWhenAuto() {
    final was = autoConnect;
    autoConnect = true;
    try {
      return effectiveConnectId();
    } finally {
      autoConnect = was;
    }
  }

  /// Auto with every Route entry switched off Auto: nothing to connect through.
  bool nothingInAuto() {
    final v = visibleOrder();
    return autoConnect && v.isNotEmpty && !v.any((id) => connectEntry(id)!.inAuto);
  }

  /// `f()` on the catalog's own picks: [coreRoute] off meanwhile (a plan is the catalog's
  /// guess; the core then moves inside it by itself) (`withoutCore`).
  T withoutCore<T>(T Function() f) {
    final c = coreRoute;
    coreRoute = null;
    try {
      return f();
    } finally {
      coreRoute = c;
    }
  }
}
