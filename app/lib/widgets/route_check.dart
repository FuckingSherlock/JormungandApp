import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogNode, Chain, PingBook, pingFreshMs;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'form_parts.dart';
import 'latency_text.dart';

/// Working pairs shown before "show all" (`ROUTE_TOP`).
const _routeTop = 4;

class _Pair {
  const _Pair(this.entry, this.exit, this.ms);
  final CatalogNode entry;
  final CatalogNode exit;
  final int ms;
}

/// One run of the check (`chainTest` in the mockup).
class _Check {
  bool running = true;
  bool stopped = false;
  String Function(AppLocalizations l10n) stage = _noStage;
  int done = 0;
  int total = 0;
  final pairs = <_Pair>[];
  bool showAll = false;
  final open = <String>{};

  static String _noStage(AppLocalizations _) => '';
}

/// `#cc-test`: the chain editor's route check (mockup `testChainRoute`, 70-profile-forms.js).
///
/// 1. Entry nodes: cached pings if all are younger than 5 min, otherwise ping them all.
/// 2. Alive entries fastest first; for each, every exit through it (one pair-ping call per
///    entry, `CoreHost.pingPairs`), the working pairs collected.
/// 3. Cached entry pings and no working pair through the first 2 entries: the cache is probably
///    stale, re-ping the entries once and start over.
/// A server never pairs with itself. Results: working pairs by total latency, as a list of
/// pairs or grouped by entry / by exit. Changing the chain's ends drops the result (a running
/// check stops).
class RouteCheck extends StatefulWidget {
  const RouteCheck({super.key, required this.draft});

  final Chain draft;

  @override
  State<RouteCheck> createState() => _RouteCheckState();
}

class _RouteCheckState extends State<RouteCheck> {
  _Check? _t;
  String _view = 'pairs'; // pairs | entry | exit; kept between checks
  String? _ends;

  @override
  void dispose() {
    _t?.stopped = true;
    super.dispose();
  }

  Future<void> _run() async {
    final host = CoreHostScope.read(context);
    final catalog = host.catalog;
    final entries = [
      for (final r in catalog.chainEntryRefs(widget.draft)) r.node,
    ];
    final exits = [for (final r in catalog.chainExitRefs(widget.draft)) r.node];
    final t = _t = _Check();
    bool live() => mounted && identical(_t, t) && !t.stopped;
    void step(String Function(AppLocalizations) stage) {
      t.stage = stage;
      if (mounted) setState(() {});
    }

    bool fresh() => entries.every((n) {
      final e = catalog.pings.entry(n);
      return e != null &&
          e.ms != null &&
          catalog.pings.now - e.at < pingFreshMs;
    });

    setState(() {});
    var fromCache = fresh();
    if (!fromCache) {
      step((l) => l.pingingEntryNodes(entries.length));
      await host.pingNodes(entries);
    }
    for (var attempt = 0; attempt < 2 && live(); attempt++) {
      final alive = entries.where(catalog.pings.isAlive).toList()
        ..sort(
          (a, b) => catalog.pings.ping(a)!.compareTo(catalog.pings.ping(b)!),
        );
      t.pairs.clear();
      t.done = 0;
      t.total = alive.length;
      var retry = false;
      for (var i = 0; i < alive.length && live(); i++) {
        final entry = alive[i];
        step(
          (l) => l.entryOfExits(
            '${i + 1}',
            alive.length,
            '${entry.flag} ${entry.name}',
            exits.length,
          ),
        );
        final to = [
          for (final x in exits)
            if (PingBook.serverKey(x) != PingBook.serverKey(entry)) x,
        ];
        final ms = await host.pingPairs(entry, to);
        if (!live()) return;
        for (var k = 0; k < to.length; k++) {
          if (ms[k] >= 0) t.pairs.add(_Pair(entry, to[k], ms[k]));
        }
        t.pairs.sort((a, b) => a.ms.compareTo(b.ms));
        t.done = i + 1;
        setState(() {});
        if (fromCache && i == 1 && t.pairs.isEmpty) {
          retry = true;
          break;
        }
      }
      if (!retry) break;
      step((l) => l.noPairThroughTheFirstEntries);
      fromCache = false;
      await host.pingNodes(entries);
    }
    if (!mounted || !identical(_t, t)) return;
    setState(() => t.running = false);
  }

  void _stop() {
    final t = _t;
    if (t == null) return;
    setState(() {
      t.stopped = true;
      t.running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    final d = widget.draft;
    final ends = '${d.inId}|${d.outId}';
    if (_ends != ends) {
      // the ends changed: the old check no longer applies (a running one stops)
      _t?.stopped = true;
      _t = null;
      _ends = ends;
    }
    final t = _t;
    final nEntry = catalog.chainEntryRefs(d).length;
    final nExit = catalog.chainExitRefs(d).length;
    final ready = nEntry > 0 && nExit > 0;

    final Widget sum;
    if (!ready) {
      sum = _sum(
        nEntry == 0
            ? l10n.entryHasNoSelectedWorkingNodes
            : l10n.exitHasNoSelectedWorkingNodes,
        c.warn,
      );
    } else if (t == null) {
      sum = _sum(l10n.triesEveryExitNodeThroughThe, c.t2);
    } else if (t.running) {
      sum = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.stage(l10n),
            style: TextStyle(fontSize: 13, height: 1.4, color: c.t2),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Container(
                height: 3,
                color: c.accent.tint(.15),
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: t.total > 0 ? t.done / t.total : 0),
                  duration: const Duration(milliseconds: 300),
                  builder: (_, v, _) => FractionallySizedBox(
                    widthFactor: v,
                    child: Container(color: c.accent),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    } else if (t.pairs.isNotEmpty) {
      final n = t.pairs.length, best = t.pairs.first.ms;
      sum = _sum(
        t.stopped
            ? l10n.workingPairsStoppedEarlyBestMsPlural(n, best)
            : l10n.workingPairsBestMsPlural(n, best),
        c.active,
      );
    } else {
      sum = _sum(
        t.stopped
            ? l10n.stoppedNoWorkingPairFoundYet
            : l10n.noExitNodeAnswersThroughAny,
        c.muted,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NodesBox(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                Expanded(child: sum),
                const SizedBox(width: 12),
                if (t != null && t.running)
                  SecondaryButton(label: l10n.stop, onPressed: _stop)
                else
                  SecondaryButton(
                    label: t != null ? l10n.checkAgain : l10n.checkRoute,
                    icon: Icons.bolt,
                    onPressed: ready ? _run : null,
                  ),
              ],
            ),
          ),
        ),
        if (t != null && t.pairs.isNotEmpty) _results(context, t),
      ],
    );
  }

  Widget _sum(String text, Color color) =>
      Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: color));

  Widget _results(BuildContext context, _Check t) {
    final c = context.colors;
    final l10n = context.l10n;
    final views = [
      ('pairs', l10n.pairs),
      ('entry', l10n.byEntry),
      ('exit', l10n.byExit),
    ];
    final rows = <Widget>[];
    if (_view == 'pairs') {
      for (final p in t.pairs) {
        rows.add(_pairRow(c, p));
      }
    } else {
      // grouped by one end; each group shows its best total and unfolds to its pairs
      final byEntry = _view == 'entry';
      final groups = <String, List<_Pair>>{};
      for (final p in t.pairs) {
        groups
            .putIfAbsent(
              PingBook.serverKey(byEntry ? p.entry : p.exit),
              () => [],
            )
            .add(p);
      }
      final list = groups.entries.toList()
        ..sort((a, b) => a.value.first.ms.compareTo(b.value.first.ms));
      for (final g in list) {
        final open = t.open.contains(g.key);
        final node = byEntry ? g.value.first.entry : g.value.first.exit;
        final count = Text(
          l10n.nodesPlural(g.value.length),
          style: TextStyle(fontSize: 14, color: c.t2),
        );
        rows.add(
          InkWell(
            onTap: () =>
                setState(() => open ? t.open.remove(g.key) : t.open.add(g.key)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  if (byEntry) ...[
                    Expanded(child: _endText(c, node)),
                    const SizedBox(width: 6),
                    _arrow(c),
                    const SizedBox(width: 6),
                    count,
                  ] else ...[
                    count,
                    const SizedBox(width: 6),
                    _arrow(c),
                    const SizedBox(width: 6),
                    Expanded(child: _endText(c, node)),
                  ],
                  const SizedBox(width: 6),
                  Text(
                    l10n.min2.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: .5,
                      color: c.t3,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: LatencyView(ms: g.value.first.ms, minWidth: 0),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: open ? .5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more, size: 14, color: c.t2),
                  ),
                ],
              ),
            ),
          ),
        );
        if (open) {
          rows.add(
            Container(
              color: c.accent.tint(.04),
              child: Column(
                children: [
                  for (var i = 0; i < g.value.length; i++)
                    Container(
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.border)),
                      ),
                      padding: const EdgeInsets.fromLTRB(26, 10, 12, 10),
                      child: Row(
                        children: [
                          if (byEntry) ...[
                            _arrow(c),
                            const SizedBox(width: 6),
                            Expanded(child: _endText(c, g.value[i].exit)),
                          ] else ...[
                            Expanded(child: _endText(c, g.value[i].entry)),
                            const SizedBox(width: 6),
                            _arrow(c),
                          ],
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: LatencyView(ms: g.value[i].ms, minWidth: 0),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }
      }
    }
    final shown = t.showAll ? rows : rows.take(_routeTop).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChipRow(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          children: [
            for (final (k, label) in views)
              AppChip(
                label: label,
                active: _view == k,
                small: true,
                onTap: () => setState(() {
                  _view = k;
                  t.showAll = false;
                }),
              ),
          ],
        ),
        NodesBox(
          margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < shown.length; i++)
                i == 0
                    ? shown[i]
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: c.border)),
                        ),
                        child: shown[i],
                      ),
              if (rows.length > _routeTop)
                InkWell(
                  onTap: () => setState(() => t.showAll = !t.showAll),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.border)),
                    ),
                    padding: const EdgeInsets.all(9),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            t.showAll
                                ? '${l10n.showTop} $_routeTop'
                                : l10n.showAll2(rows.length),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          t.showAll ? Icons.expand_less : Icons.expand_more,
                          size: 14,
                          color: c.accent,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// `.route-pair`: entry → exit and the total latency.
  Widget _pairRow(AppColors c, _Pair p) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Expanded(child: _endText(c, p.entry)),
        const SizedBox(width: 6),
        _arrow(c),
        const SizedBox(width: 6),
        Expanded(child: _endText(c, p.exit)),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: LatencyView(ms: p.ms, minWidth: 0),
        ),
      ],
    ),
  );

  Widget _arrow(AppColors c) =>
      Text('→', style: TextStyle(fontSize: 13, color: c.t3));

  /// `.route-end`: the server's flag and name, one line.
  Widget _endText(AppColors c, CatalogNode n) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: n.flag, style: const TextStyle(fontSize: 16, height: 1)),
        const WidgetSpan(child: SizedBox(width: 7)),
        TextSpan(text: n.name),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 14, height: 1.3, color: c.t1),
  );
}
