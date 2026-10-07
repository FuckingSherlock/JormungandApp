/// What the Nodes editors do with their drafts and what they save: the profile editor (tick a
/// source / single servers), the chain editor (pick ends, tick servers, swap, order the exit),
/// the source entry sheet, and the sort of the server lists. Ports of the mockup's functions of
/// the same names (70-profile-forms.js, 72-source-entry.js, 30-nodes.js, 31-catalog.js), without
/// the rendering: a draft is a [Profile] / [Chain] that is not in the catalog yet (or a copy of
/// one), the editor changes it through these and hands it to [CatalogDrafts.saveProfile] /
/// [CatalogDrafts.saveChain].
library;

import 'catalog.dart';
import 'json_util.dart';
import 'models.dart';
import 'ops.dart';
import 'validate.dart';

/// [shown] is a part of the longer order [cur]; [newShown] is [shown] reordered. Servers that
/// are not shown (off in Nodes, dropped by the provider) keep their slots, ones [cur] does not
/// have yet follow it (`dragShown` with the full order the editors build).
List<String> reorderKeys(List<String> cur, List<String> shown, List<String> newShown) =>
    CatalogOps.mergeShown([...cur, ...shown.where((k) => !cur.contains(k))], shown, newShown);

/// The state of a source in the profile editor's list (`cpSourceState`).
enum PickState { none, some, all }

extension CatalogDrafts on Catalog {
  // ───────────────────────────── server lists ─────────────────────────────

  /// Server lists in the sort chosen on Nodes: `order` (as the source has them), `latency` or
  /// `name`. [nodeOf] lets it sort [NodeRef]s as well as bare servers (`sortedNodes`).
  List<T> sortedNodes<T>(List<T> list, String sort, CatalogNode Function(T) nodeOf) {
    if (sort == 'latency') return stableSorted(list, (x) => pings.rank(nodeOf(x)));
    if (sort != 'name') return [...list];
    final xs = [for (final (i, x) in list.indexed) (i, x)];
    xs.sort((a, b) {
      final c = nodeOf(a.$2).name.toLowerCase().compareTo(nodeOf(b.$2).name.toLowerCase());
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final x in xs) x.$2];
  }

  /// Fastest lists (profile, chain, a route entry in Fastest) read by ping, quickest first, dead
  /// ones last; servers not answered yet keep their place between (`byPing`).
  List<T> byPing<T>(List<T> list, CatalogNode Function(T) nodeOf) =>
      stableSorted(list, (x) => pings.rank(nodeOf(x)));

  /// `byPing` for a chain's exits: by their answer through the entry in use ([chainExitRank]).
  List<T> byChainPing<T>(Chain c, List<T> list, CatalogNode Function(T) nodeOf) {
    final entry = chainEntryNode(c);
    return stableSorted(list, (x) => chainExitRank(c, nodeOf(x), entry));
  }

  // ───────────────────────────── ids ─────────────────────────────

  /// A fresh id for a profile made now: `profile<time>` like the mockup, bumped while taken.
  String newProfileId() {
    var t = now;
    while (profilesData.containsKey('profile$t')) {
      t++;
    }
    return 'profile$t';
  }

  // ───────────────────────────── profile editor ─────────────────────────────

  /// Whole source, some of its servers, or none ticked (`cpSourceState`).
  PickState profileDraftSourceState(Profile d, String sid) {
    if (d.sources.contains(sid)) return PickState.all;
    final s = sourcesData[sid];
    if (s != null && liveNodes(s).any((n) => d.nodes.contains('$sid::${n.id}'))) return PickState.some;
    return PickState.none;
  }

  /// The sources the editor lists: the ones switched on in Nodes, and switched-off ones the
  /// draft still uses (shown greyed so the user sees why) (`cpSourceIds`).
  List<String> profileDraftSourceIds(Profile d) => sourceOrder.where((id) {
        final s = sourcesData[id];
        return s != null && (s.enabled || profileDraftSourceState(d, id) != PickState.none);
      }).toList();

  void _dropDraftNodes(Profile d, String sid) => d.nodes = d.nodes.where((k) => !k.startsWith('$sid::')).toList();

  /// The tick of a source: none / some -> the whole source, whole -> none. A source switched off
  /// in Nodes only drops out (`toggleCreateProfileSource`).
  void toggleProfileDraftSource(Profile d, String sid) {
    final s = sourcesData[sid];
    if (s == null) return;
    if (!s.enabled) {
      d.sources = d.sources.where((x) => x != sid).toList();
      _dropDraftNodes(d, sid);
      return;
    }
    final all = profileDraftSourceState(d, sid) == PickState.all;
    _dropDraftNodes(d, sid);
    d.sources = all ? d.sources.where((x) => x != sid).toList() : [...d.sources, sid];
  }

  /// The tick of one server. Unticking one of a whole source turns it into "all but this one";
  /// ticking the last missing one turns the picks back into the whole source
  /// (`toggleCpNode`).
  void toggleProfileDraftNode(Profile d, String sid, String nid) {
    final s = sourcesData[sid];
    if (s == null) return;
    final key = '$sid::$nid';
    if (d.sources.contains(sid)) {
      d.sources = d.sources.where((x) => x != sid).toList();
      final keep = [
        for (final n in [...s.nodes, ...s.gone])
          if (n.id != nid) '$sid::${n.id}',
      ];
      d.nodes = [...d.nodes, ...keep.where((k) => !d.nodes.contains(k))];
    } else if (d.nodes.contains(key)) {
      d.nodes = d.nodes.where((k) => k != key).toList();
    } else {
      d.nodes = [...d.nodes, key];
      // disabled ones count: a pick is kept as a pick
      if (s.nodes.every((n) => d.nodes.contains('$sid::${n.id}'))) {
        _dropDraftNodes(d, sid);
        d.sources = [...d.sources, sid];
      }
    }
  }

  /// The servers of a Priority profile were dragged: [newShown] = the new order of the shown
  /// `sid::nid` keys, i.e. of `orderRefs(profileNodeRefs(d), d.pickOrder)` (`startCpOrderDrag`).
  void reorderProfileDraftPick(Profile d, List<String> newShown) {
    final shown = orderRefs(profileNodeRefs(d), d.pickOrder).map((r) => r.key).toList();
    d.pickOrder = reorderKeys(d.pickOrder, shown, newShown);
  }

  /// Save of the profile editor (`saveCreateProfile`): [editId] null = a new profile at the end of
  /// the Profiles tab. A blank name becomes `Profile N`. Null when saved, else the English reason
  /// it was not (a draft with no server to use, see [profileProblem]).
  String? saveProfile(Profile draft, {String? editId}) {
    final problem = profileProblem(draft.sources, draft.nodes);
    if (problem != null) return problem;
    final given = draft.name.trim();
    final name = given.isNotEmpty ? given : 'Profile ${++profileSeq}';
    final p = editId == null ? null : profilesData[editId];
    if (p != null) {
      p
        ..name = name
        ..sources = [...draft.sources]
        ..nodes = [...draft.nodes]
        ..inAuto = draft.inAuto
        ..pickMode = draft.pickMode
        ..pickOrder = [...draft.pickOrder];
    } else {
      final id = newProfileId();
      profilesData[id] = Profile(
        id: id,
        name: name,
        sources: [...draft.sources],
        nodes: [...draft.nodes],
        inAuto: draft.inAuto,
        pickMode: draft.pickMode,
        pickOrder: [...draft.pickOrder],
      );
      catalogOrder['profiles']!.add(id);
    }
    syncCatalog();
    return null;
  }

  // ───────────────────────────── chain editor ─────────────────────────────

  /// A chain draft: [id] is a placeholder, [saveChain] makes the real one.
  Chain newChainDraft(String? inId, String? outId) => Chain(id: 'draft', inId: inId, outId: outId);

  /// A saved chain as a draft the editor can change without touching the original.
  Chain chainDraftOf(String id) => chainsData[id]!.copy();

  /// A tap on a server of one end ([side] `in` | `out`): on / off for this chain only
  /// (`toggleChainNode`, `toggleChainNodeIn`). Works on a draft and on a saved chain alike.
  void chainToggleNode(Chain c, String side, String key) {
    final on = side == 'in' ? c.inOn : c.outOn;
    if (on.contains(key)) {
      // a server forced on from "Disabled in subscription": a tap sends it back there
      final rest = on.where((x) => x != key).toList();
      if (side == 'in') {
        c.inOn = rest;
      } else {
        c.outOn = rest;
      }
      return;
    }
    final off = side == 'in' ? c.inOff : c.outOff;
    final next = off.contains(key) ? off.where((x) => x != key).toList() : [...off, key];
    if (side == 'in') {
      c.inOff = next;
    } else {
      c.outOff = next;
    }
  }

  /// A server the source's own editor switched off, used by this chain anyway: on the end's
  /// `inOn` / `outOn` (`forceChainNode`). Only [chainOffRefs] keys; taps on it afterwards go
  /// through [chainToggleNode].
  void chainForceNode(Chain c, String side, String key) {
    if (!chainOffRefs(c, side).any((r) => r.key == key)) return;
    final on = side == 'in' ? c.inOn : c.outOn;
    if (on.contains(key)) return;
    if (side == 'in') {
      c.inOn = [...on, key];
      c.inOff = c.inOff.where((x) => x != key).toList();
    } else {
      c.outOn = [...on, key];
      c.outOff = c.outOff.where((x) => x != key).toList();
    }
  }

  /// "All" / "None" of an end: the ticks of its servers; dropped servers keep theirs
  /// (`setChainNodesAll`). Servers forced on are not touched.
  void chainSetNodesAll(Chain c, String side) {
    final off = side == 'in' ? c.inOff : c.outOff;
    final keys = unitRefs(side == 'in' ? c.inId : c.outId).map((r) => r.key).toList();
    final kept = off.where((x) => !keys.contains(x)).toList();
    final next = off.any(keys.contains) ? kept : [...kept, ...keys];
    if (side == 'in') {
      c.inOff = next;
    } else {
      c.outOff = next;
    }
  }

  /// A unit picked for an end; the servers left out on that end are forgotten when it is another
  /// unit (`pickChainSide`).
  void chainPickSide(Chain c, String side, String id) {
    if (side == 'in') {
      if (c.inId != id) {
        c.inOff = [];
        c.inOn = [];
      }
      c.inId = id;
    } else {
      if (c.outId != id) {
        c.outOff = [];
        c.outOn = [];
        c.exitOrder = [];
      }
      c.outId = id;
    }
  }

  /// A tap on the other end's pick: the ends change places, the servers ticked off go with their
  /// end, the exit order starts over (`swapChainEnds`).
  void chainSwapEnds(Chain c) {
    final inId = c.outId, outId = c.inId, inOff = c.outOff, outOff = c.inOff;
    final inOn = c.outOn, outOn = c.inOn;
    c
      ..inId = inId
      ..outId = outId
      ..inOff = inOff
      ..outOff = outOff
      ..inOn = inOn
      ..outOn = outOn
      ..exitOrder = [];
  }

  /// The exit servers of a Priority chain were dragged: [newShown] = the new order of
  /// `chainExitOrder(c)` keys (`startExitDrag`).
  void chainReorderExit(Chain c, List<String> newShown) {
    final shown = chainExitOrder(c).map((r) => r.key).toList();
    c.exitOrder = reorderKeys(c.exitOrder, shown, newShown);
  }

  /// Save of the chain editor (`saveCreateChain`): [editId] null = a new chain at the end of the
  /// Nodes tab [mode] (`simple` | `profiles`). A blank name becomes `Chain N`. Null when saved,
  /// else the English reason (see [chainSaveProblem]).
  String? saveChain(Chain draft, {String? editId, String mode = 'simple'}) {
    // the editor keeps Save off until both ends are picked; this is the guard behind it
    if (draft.inId == null || draft.outId == null) return 'Pick an entry and an exit';
    final problem = chainSaveProblem(draft);
    if (problem != null) return problem;
    final given = draft.name.trim();
    final name = given.isNotEmpty ? given : nextChainName();
    final c = editId == null ? null : chainsData[editId];
    if (c != null) {
      c
        ..name = name
        ..inId = draft.inId
        ..outId = draft.outId
        ..inOff = [...draft.inOff]
        ..outOff = [...draft.outOff]
        ..inOn = [...draft.inOn]
        ..outOn = [...draft.outOn]
        ..exitMode = draft.exitMode
        ..exitOrder = [...draft.exitOrder]
        ..inAuto = draft.inAuto;
    } else {
      final id = newChainId();
      chainsData[id] = Chain(
        id: id,
        name: name,
        inId: draft.inId,
        outId: draft.outId,
        inOff: [...draft.inOff],
        outOff: [...draft.outOff],
        inOn: [...draft.inOn],
        outOn: [...draft.outOn],
        exitMode: draft.exitMode,
        exitOrder: [...draft.exitOrder],
        inAuto: draft.inAuto,
      );
      catalogOrder[mode]!.add(id);
    }
    syncCatalog();
    return null;
  }

  // ───────────────────────────── a Route entry's own settings ─────────────────────────────

  /// The Fastest / Priority switch of any Route entry: a unit's `pickMode`, a chain's `exitMode`.
  void setEntryPickMode(String id, String mode) {
    final c = chainsData[id];
    if (c != null) {
      c.exitMode = mode;
    } else {
      setRouteRowMode(id, mode);
    }
  }

  /// The order of a Priority entry's servers (a unit's `pickOrder`, a chain's `exitOrder`).
  void setEntryPickOrder(String id, List<String> order) {
    final c = chainsData[id];
    if (c != null) {
      c.exitOrder = [...order];
    } else {
      unitOwner(id)?.pickOrder = [...order];
    }
  }

  // ───────────────────────────── source entry sheet ─────────────────────────────

  /// A source's servers in the order its own entry picks them: every listed one (left-out ones
  /// included), Priority by `pickOrder` (`seOrderRefs`).
  List<NodeRef> sourceEntryRefs(String sid) {
    final s = sourcesData[sid];
    if (s == null) return [];
    return orderRefs([for (final n in liveNodes(s)) NodeRef(sid, n)], s.pickOrder);
  }

  /// `offNodes` of [sid] after a tap on server [nid] (`toggleSourceEntryNode`).
  List<String> offNodesToggled(String sid, String nid) {
    final s = sourcesData[sid];
    if (s == null) return [];
    return isNodeOff(s, nid) ? s.offNodes.where((x) => x != nid).toList() : [...s.offNodes, nid];
  }

  /// `offNodes` of [sid] after "All" / "None": everything on when some is off, else everything
  /// off; dropped and disabled servers keep theirs (`setSourceEntryAll`).
  List<String> offNodesAll(String sid) {
    final s = sourcesData[sid];
    if (s == null) return [];
    final ids = liveNodes(s).map((n) => n.id).toList();
    final kept = s.offNodes.where((id) => !ids.contains(id)).toList();
    return offCount(s) > 0 ? kept : [...kept, ...ids];
  }

  /// The servers of a Priority source entry were dragged ([newShown] = the new order of
  /// [sourceEntryRefs] keys) (`startSourceEntryDrag`).
  void reorderSourceEntry(String sid, List<String> newShown) {
    final s = sourcesData[sid];
    if (s == null) return;
    s.pickOrder = reorderKeys(s.pickOrder, sourceEntryRefs(sid).map((r) => r.key).toList(), newShown);
  }
}
