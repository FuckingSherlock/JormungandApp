/// Catalog entities as the mockup keeps them (docs/connect-model.md → «Сущности»):
/// sources, their servers, profiles, chains, and the per-mode state of the Route list.
/// JSON = the mockup's snapshot, see json_util.dart for the round-trip rules.
library;

import 'json_util.dart';

/// One server of a source (`sourcesData[sid].nodes[i]` / `.gone[i]`).
///
/// The core's [Node](../node.dart) made it; this is the catalog's view: only what the
/// decisions need, the rest (`key`, `base`, `num`, mock fields…) stays in [unknown].
/// [port] is kept as the JSON had it (a number from the core, a string in the mock).
class CatalogNode with RoundTrip {
  CatalogNode({
    required this.id,
    this.name = '',
    this.flag = '🌐',
    this.protocol = '',
    this.address = '',
    this.port,
    this.outbound,
    this.unsupported,
    this.goneAt,
  });

  factory CatalogNode.fromJson(Json j) {
    final n = CatalogNode(
      id: '${j['id']}',
      name: (j['name'] ?? '') as String,
      flag: (j['flag'] ?? '🌐') as String,
      protocol: (j['protocol'] ?? '') as String,
      address: (j['address'] ?? '') as String,
      port: j['port'],
      outbound: j['outbound'] is Map ? asJson(j['outbound']) : null,
      unsupported: j['unsupported'] is String ? j['unsupported'] as String : null,
      goneAt: j['goneAt'] is num ? j['goneAt'] as num : null,
    );
    n.capture(j, _known);
    return n;
  }

  static const _known = {'id', 'name', 'flag', 'protocol', 'address', 'port', 'outbound', 'unsupported', 'goneAt'};

  /// Identity of the server variant; every setting names it (docs/connect-model.md).
  final String id;
  final String name;
  final String flag;
  final String protocol;
  final String address;
  final Object? port;

  /// The sing-box outbound without a tag. Null = the mock's server (no outbound).
  final Json? outbound;

  /// Why sing-box cannot run this server; non-empty = never put into a config.
  final String? unsupported;

  /// When the provider dropped it (ms), only for `gone` servers.
  final num? goneAt;

  /// The core can put it into a config (`usableRef` in 95-live.js).
  bool get usable => outbound != null && !(unsupported != null && unsupported!.isNotEmpty);

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    put(o, 'name', name, omit: name.isEmpty);
    put(o, 'flag', flag, omit: flag == '🌐');
    put(o, 'protocol', protocol, omit: protocol.isEmpty);
    put(o, 'address', address, omit: address.isEmpty);
    put(o, 'port', port, omit: port == null);
    put(o, 'outbound', outbound == null ? null : deepCopy(outbound), omit: outbound == null);
    put(o, 'unsupported', unsupported, omit: unsupported == null);
    put(o, 'goneAt', goneAt, omit: goneAt == null);
    putUnknown(o);
    return o;
  }
}

/// A server of a unit: the source it comes from and the server (`{sid, node}` in the JS).
/// Compared by identity of [node] (the JS compares objects).
class NodeRef {
  const NodeRef(this.sid, this.node);
  final String sid;
  final CatalogNode node;

  /// `sid::nid`, the key every setting uses (`refKey`).
  String get key => '$sid::${node.id}';
}

/// What a Route entry / a chain end can be: a source, a profile or a chain
/// (`connectEntry`).
abstract interface class Entry {
  String get id;
  String get name;
  set name(String v);
  bool get inAuto;
  set inAuto(bool v);
}

/// A "unit": what a Route entry or a chain end stands for — a profile or (Simple mode) a
/// source. [pickMode] / [pickOrder] are the entry's own choice of server (`unitOwner`).
abstract interface class Unit implements Entry {
  String get pickMode;
  set pickMode(String v);
  List<String> get pickOrder;
  set pickOrder(List<String> v);
}

/// A subscription (`kind: 'sub'`) or a hand-made set of servers (`kind: 'node'`).
///
/// Typed: what the catalog logic reads. Everything else a form keeps on a subscription
/// (`userAgent`, `hwid`, `filter`, `usage`, `expire`, `updateInterval`…) stays in
/// [unknown] and goes back as it was. `updating` (a spinner) is never loaded: the
/// mockup deletes it on load too.
class Source with RoundTrip implements Unit {
  Source({
    required this.id,
    this.kind = 'sub',
    this.name = '',
    this.enabled = true,
    this.inAuto = true,
    this.url,
    this.count,
    this.pickMode = 'fastest',
    List<String>? offNodes,
    List<String>? disabledNodes,
    List<String>? pickOrder,
    List<CatalogNode>? nodes,
    List<CatalogNode>? gone,
  })  : offNodes = offNodes ?? [],
        disabledNodes = disabledNodes ?? [],
        pickOrder = pickOrder ?? [],
        nodes = nodes ?? [],
        gone = gone ?? [];

  factory Source.fromJson(Json j) {
    final s = Source(
      id: '${j['id']}',
      kind: (j['kind'] ?? 'sub') as String,
      name: (j['name'] ?? '') as String,
      enabled: truthy(j['enabled']),
      inAuto: truthy(j['inAuto']),
      url: j['url'] is String ? j['url'] as String : null,
      count: j['count'] is num ? (j['count'] as num).toInt() : null,
      pickMode: (j['pickMode'] ?? 'fastest') as String,
      offNodes: strList(j['offNodes']),
      disabledNodes: strList(j['disabledNodes']),
      pickOrder: strList(j['pickOrder']),
      nodes: [for (final n in (j['nodes'] as List? ?? const [])) CatalogNode.fromJson(asJson(n))],
      gone: [for (final n in (j['gone'] as List? ?? const [])) CatalogNode.fromJson(asJson(n))],
    );
    s.capture(j, _known);
    s.unknown.remove('updating');
    return s;
  }

  static const _known = {
    'id', 'kind', 'name', 'enabled', 'inAuto', 'url', 'count', 'pickMode', 'pickOrder', 'offNodes', 'disabledNodes', 'nodes', 'gone', //
    'updating',
  };

  @override
  final String id;

  /// `sub` or `node`.
  String kind;
  @override
  String name;

  /// The switch of the source in Nodes (a disabled source is hidden everywhere).
  bool enabled;
  @override
  bool inAuto;
  String? url;

  /// `nodes.length` as the last update left it (the mockup also sets it on delete).
  int? count;

  /// `fastest` | `priority`: how the source's own Simple-mode entry picks a server.
  @override
  String pickMode;
  @override
  List<String> pickOrder;

  /// Servers (ids) switched off for the source's own entry.
  List<String> offNodes;

  /// Servers (ids) switched off one by one in Nodes: hidden everywhere (`liveNodes`).
  List<String> disabledNodes;
  List<CatalogNode> nodes;

  /// Servers the provider dropped, kept for their settings (`goneAt` each).
  List<CatalogNode> gone;

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    put(o, 'kind', kind, omit: kind == 'sub');
    put(o, 'name', name, omit: name.isEmpty);
    put(o, 'enabled', enabled, omit: !enabled);
    put(o, 'inAuto', inAuto, omit: !inAuto);
    put(o, 'url', url, omit: url == null);
    put(o, 'count', count, omit: count == null);
    put(o, 'pickMode', pickMode, omit: pickMode == 'fastest');
    put(o, 'pickOrder', [...pickOrder], omit: pickOrder.isEmpty);
    put(o, 'offNodes', [...offNodes], omit: offNodes.isEmpty);
    put(o, 'disabledNodes', [...disabledNodes], omit: disabledNodes.isEmpty);
    o['nodes'] = [for (final n in nodes) n.toJson()];
    put(o, 'gone', [for (final n in gone) n.toJson()], omit: gone.isEmpty);
    putUnknown(o);
    return o;
  }
}

/// A profile: whole sources and / or single servers (`sid::nid`).
class Profile with RoundTrip implements Unit {
  Profile({
    required this.id,
    this.name = '',
    List<String>? sources,
    List<String>? nodes,
    this.inAuto = true,
    this.pickMode = 'fastest',
    List<String>? pickOrder,
  })  : sources = sources ?? [],
        nodes = nodes ?? [],
        pickOrder = pickOrder ?? [];

  factory Profile.fromJson(Json j) {
    final p = Profile(
      id: '${j['id']}',
      name: (j['name'] ?? '') as String,
      sources: strList(j['sources']),
      nodes: strList(j['nodes']),
      inAuto: truthy(j['inAuto']),
      pickMode: (j['pickMode'] ?? 'fastest') as String,
      pickOrder: strList(j['pickOrder']),
    );
    p.capture(j, _known);
    return p;
  }

  static const _known = {'id', 'name', 'sources', 'nodes', 'inAuto', 'pickMode', 'pickOrder'};

  @override
  final String id;
  @override
  String name;

  /// Whole sources (every server, including ones a later update adds).
  List<String> sources;

  /// Single servers, `sid::nid` (kept while the provider has dropped the server).
  List<String> nodes;
  @override
  bool inAuto;
  @override
  String pickMode;
  @override
  List<String> pickOrder;

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    o['name'] = name;
    o['sources'] = [...sources];
    o['nodes'] = [...nodes];
    put(o, 'inAuto', inAuto, omit: !inAuto);
    put(o, 'pickMode', pickMode, omit: pickMode == 'fastest');
    put(o, 'pickOrder', [...pickOrder], omit: pickOrder.isEmpty);
    putUnknown(o);
    return o;
  }
}

/// A chain: [inId] (first hop) → [outId] (exit). The ends are units of the chain's tab:
/// sources on Simple, profiles on Profiles. [inOff] / [outOff] are `sid::nid` keys
/// switched off for this chain only; the exit picks by [exitMode]. [inOn] / [outOn] are `sid::nid`
/// keys of servers a source's own editor has switched off, that this chain uses anyway.
class Chain with RoundTrip implements Entry {
  Chain({
    required this.id,
    this.name = '',
    this.inId,
    this.outId,
    List<String>? inOff,
    List<String>? outOff,
    List<String>? inOn,
    List<String>? outOn,
    this.exitMode = 'fastest',
    List<String>? exitOrder,
    this.inAuto = true,
  })  : inOff = inOff ?? [],
        outOff = outOff ?? [],
        inOn = inOn ?? [],
        outOn = outOn ?? [],
        exitOrder = exitOrder ?? [];

  factory Chain.fromJson(Json j) {
    final c = Chain(
      id: '${j['id']}',
      name: (j['name'] ?? '') as String,
      inId: j['inId'] as String?,
      outId: j['outId'] as String?,
      inOff: strList(j['inOff']),
      outOff: strList(j['outOff']),
      inOn: strList(j['inOn']),
      outOn: strList(j['outOn']),
      exitMode: (j['exitMode'] ?? 'fastest') as String,
      exitOrder: strList(j['exitOrder']),
      inAuto: truthy(j['inAuto']),
    );
    c.capture(j, _known);
    return c;
  }

  static const _known = {'id', 'name', 'inId', 'outId', 'inOff', 'outOff', 'inOn', 'outOn', 'exitMode', 'exitOrder', 'inAuto'};

  @override
  final String id;
  @override
  String name;
  String? inId;
  String? outId;
  List<String> inOff;
  List<String> outOff;

  /// Servers off in their source's own editor (`offNodes`) that this chain's end uses anyway.
  List<String> inOn;
  List<String> outOn;

  /// `fastest` | `priority`.
  String exitMode;
  List<String> exitOrder;
  @override
  bool inAuto;

  Chain copy() => Chain.fromJson(toJson());

  Json toJson() {
    final o = <String, dynamic>{};
    o['id'] = id;
    o['name'] = name;
    put(o, 'inId', inId, omit: inId == null);
    put(o, 'outId', outId, omit: outId == null);
    put(o, 'inOff', [...inOff], omit: inOff.isEmpty);
    put(o, 'outOff', [...outOff], omit: outOff.isEmpty);
    put(o, 'inOn', [...inOn], omit: inOn.isEmpty);
    put(o, 'outOn', [...outOn], omit: outOn.isEmpty);
    put(o, 'exitMode', exitMode, omit: exitMode == 'fastest');
    put(o, 'exitOrder', [...exitOrder], omit: exitOrder.isEmpty);
    put(o, 'inAuto', inAuto, omit: !inAuto);
    putUnknown(o);
    return o;
  }
}

/// The Route state of a mode that is not the active one (`modeState[mode]`): its priority
/// list, pinned entry, Auto flag and pinned server. The active mode's live in the
/// [Catalog] fields.
class ModeSlot with RoundTrip {
  ModeSlot({List<String>? order, this.active, this.auto = true, this.pin}) : order = order ?? [];

  factory ModeSlot.fromJson(Json j) {
    final m = ModeSlot(
      order: strList(j['order']),
      active: j['active'] as String?,
      auto: j['auto'] != false,
      pin: j['pin'] as String?,
    );
    m.capture(j, _known);
    return m;
  }

  static const _known = {'order', 'active', 'auto', 'pin'};

  List<String> order;
  String? active;
  bool auto;
  String? pin;

  Json toJson() {
    final o = <String, dynamic>{};
    o['order'] = [...order];
    o['active'] = active;
    o['auto'] = auto;
    put(o, 'pin', pin, omit: pin == null);
    putUnknown(o);
    return o;
  }
}

/// What to switch back on for an unusable entry (`brokenBy`): a whole source (`nid` null)
/// or one server.
class OffReason {
  const OffReason(this.sid, [this.nid]);
  final String sid;
  final String? nid;

  @override
  bool operator ==(Object other) => other is OffReason && other.sid == sid && other.nid == nid;

  @override
  int get hashCode => Object.hash(sid, nid);

  @override
  String toString() => nid == null ? 'OffReason($sid)' : 'OffReason($sid::$nid)';
}
