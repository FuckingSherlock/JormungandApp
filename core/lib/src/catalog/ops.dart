/// The state changes of the catalog the screens make: pick (Auto / Manual / pin), switches,
/// mode, order, add / delete, forgetting dropped servers. Ports of the mockup's functions of
/// the same names (20-profiles.js, 30-nodes.js, 70-profile-forms.js, 80-drag.js), without
/// the rendering, toasts and the journal: each one changes the [Catalog] and returns what the
/// caller needs to tell the user.
library;

import 'catalog.dart';
import 'models.dart';

/// Dropped servers are kept this long from their own `goneAt`, then forgotten with their
/// settings (`GONE_KEEP_DAYS`).
const goneKeepDays = 15;
const _day = 86400000;

extension CatalogOps on Catalog {
  // ───────────────────────────── order and sync ─────────────────────────────

  /// Keeps the catalog, [sourceOrder] and both route lists in step after anything was added
  /// or deleted: entries that no longer exist drop out; a route that follows Nodes copies the
  /// catalog, a route with its own order keeps it and appends new entries (`syncCatalog`).
  /// Call after every change, before reading the route.
  void syncCatalog() {
    bool exists(String id) => sourcesData.containsKey(id) || profilesData.containsKey(id) || chainsData.containsKey(id);
    catalogOrder['simple'] = catalogOrder['simple']!.where(exists).toList();
    for (final id in sourceOrder) {
      if (!catalogOrder['simple']!.contains(id)) catalogOrder['simple']!.add(id);
    }
    catalogOrder['profiles'] = catalogOrder['profiles']!.where(exists).toList();
    sourceOrder = catalogOrder['simple']!.where(sourcesData.containsKey).toList();
    for (final m in const ['simple', 'profiles']) {
      final cat = catalogOrder[m]!, cur = modeOrder(m);
      final next = routeCustom[m]! ? [...cur.where(cat.contains), ...cat.where((id) => !cur.contains(id))] : [...cat];
      setModeOrder(m, next);
      if (m == connectMode) {
        if (activeConnectId == null || !next.contains(activeConnectId)) activeConnectId = next.isEmpty ? null : next.first;
      } else {
        final st = modeSlot(m);
        if (st.active == null || !next.contains(st.active)) st.active = next.isEmpty ? null : next.first;
      }
    }
  }

  /// Reorder the shown part of a longer list: hidden items (a source switched off in Nodes, a
  /// server the provider dropped) keep their slots (`dragShown`): [full] with the items of
  /// [shown] replaced, in the order of [newShown] (the same items as [shown]).
  static List<String> mergeShown(List<String> full, List<String> shown, List<String> newShown) {
    final set = shown.toSet();
    var i = 0;
    return [for (final x in full) set.contains(x) ? newShown[i++] : x];
  }

  /// The Route list was dragged: [newShown] is the new order of [visibleOrder]. The route then
  /// has its own order apart from Nodes (until [resetRouteOrder]) (`startConnectDrag`).
  void reorderRoute(List<String> newShown) {
    final o = mergeShown(connectOrder, visibleOrder(), newShown);
    if (o.join(',') != connectOrder.join(',')) routeCustom[connectMode] = true;
    connectOrder = o;
  }

  /// "Follow Nodes order" (`resetRouteOrder`).
  void resetRouteOrder() {
    routeCustom[connectMode] = false;
    syncCatalog();
  }

  /// A Nodes tab was dragged: the new order of that tab's catalog (every entry of it)
  /// (`startSourceDrag`).
  void reorderCatalog(String tab, List<String> newOrder) {
    catalogOrder[tab] = [...newOrder];
    syncCatalog();
  }

  // ───────────────────────────── Auto / Manual ─────────────────────────────

  /// The AUTO / MANUAL button of a row: another entry becomes the Manual one, the pinned one
  /// goes back to Auto (`selectConnect`).
  void selectConnect(String id) {
    pinnedNode = null;
    if (!autoConnect && activeConnectId == id) {
      autoConnect = true; // second tap on the pinned entry → back to Auto
    } else {
      autoConnect = false;
      activeConnectId = id;
    }
  }

  /// The Auto / Manual badge. Switching to Manual pins what Auto would pick (`setAutoConnect`).
  void setAutoConnect(bool on) {
    autoConnect = on;
    pinnedNode = null;
    if (!on) activeConnectId = effectiveConnectIdWhenAuto();
  }

  /// A tap on a server of an unfolded row: Manual on this entry and this server; the pinned
  /// server again: the entry stays Manual and picks by its Fastest / Priority again
  /// (`pinRouteNode`). [key] = `sid::nid`.
  void pinRouteNode(String id, String key) {
    final again = !autoConnect && activeConnectId == id && pinnedNode == key;
    autoConnect = false;
    activeConnectId = id;
    pinnedNode = again ? null : key;
  }

  /// "Use in Auto". True when that left Auto with nothing: the tunnel stays on its server
  /// until the user disconnects, the app says so (`toggleEntryAuto`).
  bool toggleEntryAuto(String id) {
    final e = connectEntry(id);
    if (e == null) return false;
    e.inAuto = !e.inAuto;
    return nothingInAuto();
  }

  /// The Simple / Profiles switch of Route (`setConnectMode`): the active mode's list,
  /// pick and pin are put away and the other mode's brought back.
  void setConnectMode(String mode) {
    if (mode == connectMode) return;
    final old = modeSlot(connectMode);
    old
      ..order = [...connectOrder]
      ..active = activeConnectId
      ..auto = autoConnect
      ..pin = pinnedNode;
    final next = modeSlot(mode);
    connectOrder = [...next.order];
    activeConnectId = next.active;
    autoConnect = next.auto;
    pinnedNode = next.pin != null && next.pin!.isNotEmpty ? next.pin : null;
    connectMode = mode;
  }

  /// The Fastest / Priority switch of a Route row (`setRouteRowMode`).
  void setRouteRowMode(String id, String mode) {
    unitOwner(id)?.pickMode = mode;
  }

  /// The servers of a Priority row were dragged: [newShown] = new order of its `sid::nid`
  /// keys as shown (`startRouteNodeDrag`).
  void reorderUnitPick(String id, List<String> newShown) {
    final u = unitOwner(id);
    if (u == null) return;
    final shown = unitPickRefs(id).map((r) => r.key).toList(), cur = u.pickOrder;
    u.pickOrder = mergeShown([...cur, ...shown.where((k) => !cur.contains(k))], shown, newShown);
  }

  // ───────────────────────────── add ─────────────────────────────

  /// A new source joins the end of the Simple tab (and so of the simple-mode route)
  /// (`sourceAdded`). A source that did not say whether it is in Auto starts in it.
  void sourceAdded(String id) {
    final s = sourcesData[id];
    if (s == null) return;
    if (!s.had.contains('inAuto')) {
      s.inAuto = true;
      s.had.add('inAuto');
    }
    if (!catalogOrder['simple']!.contains(id)) catalogOrder['simple']!.add(id);
    syncCatalog();
  }

  /// Puts [s] into the catalog and runs [sourceAdded].
  void addSource(Source s) {
    sourcesData[s.id] = s;
    if (!sourceOrder.contains(s.id)) sourceOrder.add(s.id);
    sourceAdded(s.id);
  }

  // ───────────────────────────── on / off ─────────────────────────────

  void toggleSourceEnabled(String id) {
    final s = sourcesData[id];
    if (s != null) s.enabled = !s.enabled;
  }

  void enableSource(String sid) {
    final s = sourcesData[sid];
    if (s != null) s.enabled = true;
  }

  /// Switch a server off / on everywhere (hidden, its settings kept) (`toggleNodeEnabled`).
  void toggleNodeEnabled(String sid, String nid) {
    final s = sourcesData[sid];
    if (s == null) return;
    s.disabledNodes = isNodeDisabled(s, nid) ? s.disabledNodes.where((x) => x != nid).toList() : [...s.disabledNodes, nid];
  }

  void enableNode(String sid, String nid) {
    final s = sourcesData[sid];
    if (s != null) s.disabledNodes = s.disabledNodes.where((x) => x != nid).toList();
  }

  // ───────────────────────────── delete ─────────────────────────────

  /// Every setting that names these servers of a source, gone for good (`purgeNodeSettings`).
  void purgeNodeSettings(String sid, Set<String> ids) {
    final s = sourcesData[sid];
    if (s == null) return;
    final keys = {for (final nid in ids) '$sid::$nid'};
    s.offNodes = s.offNodes.where((nid) => !ids.contains(nid)).toList();
    s.disabledNodes = s.disabledNodes.where((nid) => !ids.contains(nid)).toList();
    s.pickOrder = s.pickOrder.where((k) => !keys.contains(k)).toList();
    for (final p in profilesData.values) {
      p.nodes = p.nodes.where((k) => !keys.contains(k)).toList();
      p.pickOrder = p.pickOrder.where((k) => !keys.contains(k)).toList();
    }
    for (final c in chainsData.values) {
      c.inOff = c.inOff.where((k) => !keys.contains(k)).toList();
      c.outOff = c.outOff.where((k) => !keys.contains(k)).toList();
      c.inOn = c.inOn.where((k) => !keys.contains(k)).toList();
      c.outOn = c.outOn.where((k) => !keys.contains(k)).toList();
      c.exitOrder = c.exitOrder.where((k) => !keys.contains(k)).toList();
    }
  }

  /// Remove a unit and every chain that uses it from both modes' lists (`dropConnectEntry`).
  void dropConnectEntry(String id) {
    final gone = {id};
    for (final c in chainsData.values.toList()) {
      if (c.inId == id || c.outId == id) {
        gone.add(c.id);
        chainsData.remove(c.id);
      }
    }
    for (final mode in const ['simple', 'profiles']) {
      catalogOrder[mode] = catalogOrder[mode]!.where((x) => !gone.contains(x)).toList();
      final order = modeOrder(mode).where((x) => !gone.contains(x)).toList();
      setModeOrder(mode, order);
      if (mode == connectMode) {
        if (gone.contains(activeConnectId)) activeConnectId = order.isEmpty ? null : order.first;
      } else {
        final st = modeSlot(mode);
        if (gone.contains(st.active)) st.active = order.isEmpty ? null : order.first;
      }
    }
  }

  /// Delete a source with its servers, its place in profiles and chains, and the chains that
  /// end on it (`deleteSource`). Ask first: [deleteSourceImpact].
  void deleteSource(String id) {
    if (!sourcesData.containsKey(id)) return;
    sourceOrder = sourceOrder.where((x) => x != id).toList();
    sourcesData.remove(id);
    for (final p in profilesData.values) {
      p.sources = p.sources.where((x) => x != id).toList();
      p.nodes = p.nodes.where((k) => !k.startsWith('$id::')).toList();
      p.pickOrder = p.pickOrder.where((k) => !k.startsWith('$id::')).toList();
    }
    for (final c in chainsData.values) {
      c.inOff = c.inOff.where((k) => !k.startsWith('$id::')).toList();
      c.outOff = c.outOff.where((k) => !k.startsWith('$id::')).toList();
      c.inOn = c.inOn.where((k) => !k.startsWith('$id::')).toList();
      c.outOn = c.outOn.where((k) => !k.startsWith('$id::')).toList();
      c.exitOrder = c.exitOrder.where((k) => !k.startsWith('$id::')).toList();
    }
    dropConnectEntry(id);
  }

  /// Delete one server of a source (`deleteNode`). Ask first: [deleteNodeImpact].
  void deleteNode(String sid, String nid) {
    final s = sourcesData[sid];
    if (s == null) return;
    s.nodes = s.nodes.where((n) => n.id != nid).toList();
    s.count = s.nodes.length;
    purgeNodeSettings(sid, {nid});
  }

  /// Delete a profile (`deleteEditingProfile`): its chains move to the first other profile
  /// (a chain left with the same profile on both ends, or with none, is deleted); the
  /// connection, if it was this profile, falls to that profile. Ask first: [deleteEntryImpact].
  void deleteProfile(String id) {
    if (profilesData.remove(id) == null) return;
    final others = getProfileIds();
    final fallback = others.isEmpty ? null : others.first; // none: it was the last one
    if (activeConnectId == id) activeConnectId = fallback;
    for (final c in chainsData.values.toList()) {
      if (c.inId != id && c.outId != id) continue;
      if (c.inId == id) c.inId = fallback;
      if (c.outId == id) c.outId = fallback;
      if (fallback == null || c.inId == c.outId) {
        // a chain through one profile is pointless: drop it
        chainsData.remove(c.id);
        if (activeConnectId == c.id) activeConnectId = fallback;
      }
    }
  }

  /// Delete a chain (`deleteEditingChain`).
  void deleteChain(String id) {
    chainsData.remove(id);
  }

  // ───────────────────────────── servers the provider dropped ─────────────────────────────

  /// Days left before a dropped server is forgotten; null = never (no `goneAt`)
  /// (`goneLeftDays`).
  int? goneLeftDays(CatalogNode n) {
    final at = n.goneAt;
    if (at == null) return null;
    return ((at + goneKeepDays * _day - now) / _day).ceil();
  }

  /// Forget dropped servers (all of a source, or the given ids) with their settings
  /// (`forgetGone`). Returns how many.
  int forgetGone(String sid, [List<String>? only]) {
    final s = sourcesData[sid];
    if (s == null) return 0;
    final ids = {for (final n in s.gone) if (only == null || only.contains(n.id)) n.id};
    s.gone = s.gone.where((n) => !ids.contains(n.id)).toList();
    purgeNodeSettings(sid, ids);
    return ids.length;
  }

  /// Forget the servers dropped longer ago than [goneKeepDays] (`purgeExpiredGone`): on start
  /// and after every update. Returns how many.
  int purgeExpiredGone() {
    var total = 0;
    for (final sid in [...sourceOrder]) {
      final s = sourcesData[sid];
      if (s == null) continue;
      final ids = {
        for (final n in s.gone)
          if ((goneLeftDays(n) ?? 1) <= 0) n.id,
      };
      if (ids.isEmpty) continue;
      s.gone = s.gone.where((n) => !ids.contains(n.id)).toList();
      purgeNodeSettings(sid, ids);
      total += ids.length;
    }
    return total;
  }

  /// A fresh id for a chain made now: `chain<time>` like the mockup, bumped while taken.
  String newChainId() {
    var t = now;
    while (chainsData.containsKey('chain$t')) {
      t++;
    }
    return 'chain$t';
  }

  /// The default name of a new chain: `Chain N` (`++chainSeq`).
  String nextChainName() => 'Chain ${++chainSeq}';
}
