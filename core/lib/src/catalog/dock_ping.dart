/// The ping a tap on the latency in the dock starts (docs/connect-model.md → «Тап по задержке в
/// доке»). Port of `dockTopRefs` / `dockPingBatches` / `pingDockTop` (57-general.js), with the
/// chain's exits measured as pairs through an entry, not directly.
///
/// [Catalog.dockPingBatches] is the pure order (what to measure, in which batches); [DockPingRun]
/// walks it: batch after batch until [dockPingEnough] servers answered or all are measured,
/// stopped by [DockPingRun.stop] (the batch in flight is waited for).
library;

import 'catalog.dart';
import 'json_util.dart';
import 'models.dart';
import 'ping_book.dart';

/// Servers per batch after the first one.
const dockPingBatchSize = 8;

/// The run ends when this many servers answered (`DOCK_PING_ENOUGH`).
const dockPingEnough = 10;

/// The first batch: servers taken from each of this many top Auto entries ...
const dockPingTopEntries = 4;

/// ... this many from each (a chain: this many from each end).
const dockPingPerEntry = 3;

/// One thing to measure: a server directly, or (with [chain]) a chain's exit through the
/// entry the chain is on.
class DockPingItem {
  const DockPingItem(this.node, [this.chain]);

  final CatalogNode node;

  /// Set for a chain's exit: it is measured as a pair `entry in use > node` (never directly).
  final Chain? chain;

  /// What makes two items one measure.
  String get key => chain == null ? PingBook.keyOf(node) : '${chain!.id}>${PingBook.keyOf(node)}';
}

extension CatalogDockPing on Catalog {
  /// The batches of the dock ping, in order: the first one is the quick look at what Auto
  /// would use — the first 3 servers (in the entry's own pick order; Fastest: best known first)
  /// of the first 4 Auto entries by priority; in Manual the pinned entry comes first and its
  /// pinned server before the others; a chain: 3 of each end, the exits as pairs. Then every
  /// other server of the Route list (Auto entries first, each in its own order) by
  /// [dockPingBatchSize].
  List<List<DockPingItem>> dockPingBatches() {
    final order = visibleOrder();
    final manual = autoConnect ? null : effectiveConnectId();
    final auto = order.where((id) => connectEntry(id)?.inAuto == true).toList();
    final top = {?manual, ...auto}.take(dockPingTopEntries);

    final first = <DockPingItem>[];
    final seen = <String>{};
    void add(Iterable<DockPingItem> items, List<DockPingItem> to) {
      for (final i in items) {
        if (seen.add(i.key)) to.add(i);
      }
    }

    for (final id in top) {
      final c = chainsData[id];
      if (c != null) {
        add(_chainEntries(c, byRank: true).take(dockPingPerEntry), first);
        add(_chainExits(c, byRank: c.exitMode != 'priority').take(dockPingPerEntry), first);
        continue;
      }
      final pin = pinnedRef(id);
      final own = _unitItems(id, byRank: !unitPriority(id));
      final picked = <String>{if (pin != null) PingBook.keyOf(pin.node)};
      final three = [
        if (pin != null) DockPingItem(pin.node),
        ...own.where((i) => picked.add(i.key)),
      ].take(dockPingPerEntry);
      add(three, first);
    }

    final all = {?manual, ...auto, ...order};
    final rest = <DockPingItem>[];
    for (final id in all) {
      final c = chainsData[id];
      if (c != null) {
        add(_chainEntries(c, byRank: false), rest);
        add(_chainExits(c, byRank: false), rest);
      } else {
        add(_unitItems(id, byRank: !unitPriority(id)), rest);
      }
    }
    return [
      if (first.isNotEmpty) first,
      for (var i = 0; i < rest.length; i += dockPingBatchSize) rest.sublist(i, (i + dockPingBatchSize).clamp(0, rest.length)),
    ];
  }

  /// What the background ping after a connect measures, in order: the route's own servers first
  /// (in its pick order; Fastest: best known first, a weak answer after a strong one — a chain: its
  /// entries), then every other live server of the subscriptions the route is made of. A chain's
  /// exits are not here: they are measured as pairs through the entry, never directly.
  List<CatalogNode> routePingOrder(String id) {
    final c = chainsData[id];
    final refs = c != null ? chainEntryRefs(c) : unitPickRefs(id);
    final top = c != null || !unitPriority(id) ? stableSorted(refs, (NodeRef r) => pings.rank(r.node)) : refs;
    final seen = <CatalogNode>{};
    final out = <CatalogNode>[];
    void add(Iterable<CatalogNode> ns) {
      for (final n in ns) {
        if (seen.add(n)) out.add(n);
      }
    }

    add(top.map((r) => r.node));
    for (final sid in {for (final r in refs) r.sid}) {
      final s = sourcesData[sid];
      if (s != null && s.enabled) add(liveNodes(s));
    }
    return out;
  }

  List<DockPingItem> _unitItems(String id, {required bool byRank}) {
    final refs = unitPickRefs(id);
    return [for (final r in byRank ? stableSorted(refs, (NodeRef r) => pings.rank(r.node)) : refs) DockPingItem(r.node)];
  }

  List<DockPingItem> _chainEntries(Chain c, {required bool byRank}) {
    final refs = chainEntryRefs(c);
    return [for (final r in byRank ? stableSorted(refs, (NodeRef r) => pings.rank(r.node)) : refs) DockPingItem(r.node)];
  }

  List<DockPingItem> _chainExits(Chain c, {required bool byRank}) {
    final refs = chainExitRefs(c), entry = chainEntryNode(c);
    return [for (final r in byRank ? stableSorted(refs, (NodeRef r) => chainExitRank(c, r.node, entry)) : refs) DockPingItem(r.node, c)];
  }

  /// The item answered: a server by its own ping, a chain's exit by its pair through the
  /// entry in use.
  bool dockPingAlive(DockPingItem i) {
    final c = i.chain;
    if (c == null) return pings.isAlive(i.node);
    final entry = chainEntryNode(c);
    return entry != null && pairs.isAlive(entry, i.node);
  }
}

/// A dock ping in progress. [measure] performs one batch (the host's ping); the run decides
/// what is next.
class DockPingRun {
  DockPingRun(this.catalog, this.measure);

  final Catalog catalog;
  final Future<void> Function(List<DockPingItem> batch) measure;

  bool _stopped = false;
  bool get stopped => _stopped;

  /// Servers that answered so far.
  int alive = 0;

  /// Lets the batch in flight finish and starts no more.
  void stop() => _stopped = true;

  /// Batch after batch until [dockPingEnough] answered, all are measured, or [stop].
  Future<void> run() async {
    final batches = catalog.dockPingBatches();
    for (final batch in batches) {
      if (_stopped || alive >= dockPingEnough) return;
      await measure(batch);
      alive += batch.where(catalog.dockPingAlive).length;
    }
  }
}
