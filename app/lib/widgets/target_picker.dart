import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show Catalog, CatalogDrafts, CatalogNode, CatalogPlan, NodeRef, Source;

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'entry_card.dart';
import 'form_parts.dart';
import 'latency_text.dart';
import 'node_row.dart';
import 'pick_parts.dart';
import 'rules_parts.dart';
import 'source_card.dart';

/// The picker of what traffic goes through (mockup 44-target-picker.js): a rule's or an app's Via,
/// a Fallback's Via. One sheet over everything: Main flow, then the whole Nodes catalog whatever the
/// route's mode - subscriptions / server groups, profiles, chains. A card with servers
/// (subscription, profile) unfolds on a tap; AUTO in its header marks the whole item, a server row
/// marks that server. A tap on the marked item unmarks it (-> main flow). A mark does not close the
/// sheet: a Save bar shows while the selection differs from the one it opened with; closing any other
/// way applies nothing.
///
/// Resolves to the picked target (`''` = the main flow) or null when nothing was applied. [exclude]
/// is a target that cannot be picked here (the fallback must differ from the route's Via).
Future<String?> showTargetPicker(
  BuildContext context, {
  required String current,
  String exclude = '',
}) => showAppSheet<String>(
  context,
  builder: (_) => _TargetPicker(current: current, exclude: exclude),
);

class _TargetPicker extends StatefulWidget {
  const _TargetPicker({required this.current, required this.exclude});

  final String current;
  final String exclude;

  @override
  State<_TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<_TargetPicker> {
  final _search = TextEditingController();
  late String _cur = widget.current;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    if (_cur.startsWith('node:')) {
      _open.add('src:${_cur.substring(5).split('::').first}');
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _q => _search.text.trim().toLowerCase();

  bool _hit(String s) => _q.isEmpty || s.toLowerCase().contains(_q);

  void _pick(String t) {
    if (widget.exclude.isNotEmpty && t == widget.exclude) return;
    setState(() => _cur = t == _cur ? '' : t);
  }

  void _toggle(String t) =>
      setState(() => _open.contains(t) ? _open.remove(t) : _open.add(t));

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final cat = host.catalog;
    final l10n = context.l10n;
    final c = context.colors;

    bool nodeHit(CatalogNode n) => _hit('${n.name} ${n.protocol}');

    // Servers of an unfolded card: all, or (the search hit servers, not the card) the matching ones.
    List<NodeRef> listed(String id, List<NodeRef> refs, bool nameHit) {
      final rs = nameHit ? refs : refs.where((r) => nodeHit(r.node)).toList();
      return cat.unitPriority(id)
          ? cat.orderRefs(rs, cat.unitOwner(id)?.pickOrder)
          : cat.byPing<NodeRef>(rs, (r) => r.node);
    }

    final cards = <Widget>[];
    void label(String text, List<Widget> items) {
      if (items.isEmpty) return;
      cards.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: .6,
              color: c.t3,
            ),
          ),
        ),
      );
      cards.addAll(items);
    }

    if (_hit('main flow') || _hit(l10n.mainFlow2)) {
      final ce = cat.connectEntry(cat.effectiveConnectId());
      cards.add(
        _TpCard(
          target: '',
          name: l10n.mainFlow2,
          meta: Text(l10n.whatHomeConnectsThroughFollowsRoute),
          now: [
            ConnTag(l10n.now2, tone: TagTone.muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                ce?.name ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.t2),
              ),
            ),
          ],
          picked: _cur.isEmpty,
          onTap: () => _pick(''),
        ),
      );
    }

    final srcs = <Widget>[];
    for (final sid in cat.sourceOrder) {
      final s = cat.sourcesData[sid];
      if (s == null) continue;
      final t = 'src:$sid';
      final refs = [for (final n in s.nodes) NodeRef(sid, n)];
      final nameHit = _hit(s.name);
      if (!nameHit && !refs.any((r) => nodeHit(r.node))) continue;
      srcs.add(
        _TpCard(
          target: t,
          name: s.name,
          meta: sourceMetaLine(context, host, s),
          usage: s.kind == 'sub' ? sourceUsageLine(s) : null,
          now: _srcNow(context, cat, s),
          ok: cat.targetInfo(t).ok,
          picked: _cur == t,
          excluded: widget.exclude == t,
          fold: true,
          open: _open.contains(t) || (_q.isNotEmpty && !nameHit),
          unit: sid,
          rows: listed(sid, refs, nameHit),
          current: _cur,
          exclude: widget.exclude,
          onTap: () => _toggle(t),
          onPick: _pick,
        ),
      );
    }
    label(l10n.subscriptionsServers, srcs);

    final profs = <Widget>[];
    for (final id in cat.getProfileIds()) {
      final p = cat.profilesData[id]!;
      final t = 'profile:$id';
      final refs = cat.unitRefs(id, withOff: true);
      final nameHit = _hit(p.name);
      if (!nameHit && !refs.any((r) => nodeHit(r.node))) continue;
      profs.add(
        _TpCard(
          target: t,
          name: p.name,
          meta: entryMetaLine(context, host, id),
          now: null,
          nowWidget: entryNowLine(context, host, id),
          ok: cat.targetInfo(t).ok,
          picked: _cur == t,
          excluded: widget.exclude == t,
          fold: true,
          open: _open.contains(t) || (_q.isNotEmpty && !nameHit),
          unit: id,
          rows: listed(id, refs, nameHit),
          current: _cur,
          exclude: widget.exclude,
          onTap: () => _toggle(t),
          onPick: _pick,
        ),
      );
    }
    label(l10n.profiles, profs);

    final chains = <Widget>[];
    for (final id in [
      ...?cat.catalogOrder['simple'],
      ...?cat.catalogOrder['profiles'],
    ]) {
      final ch = cat.chainsData[id];
      if (ch == null || !_hit(ch.name)) continue;
      final t = 'chain:$id';
      chains.add(
        _TpCard(
          target: t,
          name: ch.name,
          meta: entryMetaLine(context, host, id),
          nowWidget: entryNowLine(context, host, id),
          ok: cat.targetInfo(t).ok,
          picked: _cur == t,
          excluded: widget.exclude == t,
          onTap: () => _pick(t),
        ),
      );
    }
    label(l10n.chains, chains);

    final dirty = _cur != widget.current;
    return SheetFrame(
      title: l10n.sendThrough,
      full: true,
      bodyPadding: EdgeInsets.fromLTRB(14, 10, 14, dirty ? 24 : 24),
      subHeader: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: SearchBox(
          controller: _search,
          hint: l10n.searchProfilesChainsServers,
          icon: true,
          onChanged: (_) => setState(() {}),
        ),
      ),
      footer: dirty
          ? [
              if (_cur.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.nothingPickedGoesThroughTheMain,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: c.t2),
                  ),
                ),
              PrimaryButton(
                label: l10n.save,
                onPressed: () => Navigator.of(context).pop(_cur),
              ),
            ]
          : null,
      child: cards.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
              child: Text(
                l10n.nothingMatches2(_search.text.trim()),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.5, color: c.t2),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, w) in cards.indexed) ...[
                  if (i > 0) const SizedBox(height: 8),
                  w,
                ],
              ],
            ),
    );
  }

  /// `.entry-now` of a source: how it picks and the server it would use now.
  List<Widget> _srcNow(BuildContext context, Catalog cat, Source s) {
    final l10n = context.l10n;
    final c = context.colors;
    final best = cat.bestAlive(cat.liveNodes(s));
    final style = TextStyle(fontSize: 13, color: c.t2);
    return [
      ConnTag(
        cat.unitPriority(s.id) ? l10n.priority2 : fastestLabel,
        tone: TagTone.muted,
      ),
      const SizedBox(width: 6),
      if (best == null)
        Flexible(
          child: Text(
            l10n.noWorkingNodes,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        )
      else ...[
        Flexible(
          child: Text(
            '${best.flag} ${best.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 6),
        LatencyText(best),
      ],
    ];
  }
}

/// `.src-card.tp-card`: a head (AUTO, name, meta), the usage and "now" lines, and when opened the
/// servers. The picked one is framed in the accent with a bar at its left edge.
class _TpCard extends StatelessWidget {
  const _TpCard({
    required this.target,
    required this.name,
    required this.meta,
    required this.picked,
    required this.onTap,
    this.usage,
    this.now,
    this.nowWidget,
    this.ok = true,
    this.excluded = false,
    this.fold = false,
    this.open = false,
    this.unit = '',
    this.rows = const [],
    this.current = '',
    this.exclude = '',
    this.onPick,
  });

  final String target;
  final String name;
  final Widget meta;
  final Widget? usage;
  final List<Widget>? now;
  final Widget? nowWidget;
  final bool ok;
  final bool picked;
  final bool excluded;
  final bool fold;
  final bool open;
  final String unit;
  final List<NodeRef> rows;
  final String current;
  final String exclude;
  final VoidCallback onTap;
  final void Function(String)? onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final cat = CoreHostScope.of(context).catalog;
    final head = InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Expanded(
              child: Opacity(
                opacity: ok ? 1 : .6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (fold) ...[
                          _AutoButton(
                            on: picked,
                            onTap: () => onPick?.call(target),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: c.t1,
                            ),
                          ),
                        ),
                        if (!ok) ...[
                          const SizedBox(width: 6),
                          ConnTag(l10n.off2, tone: TagTone.off),
                        ],
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: meta,
                    ),
                  ],
                ),
              ),
            ),
            if (fold)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AnimatedRotation(
                  turns: open ? .5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more, size: 16, color: c.t3),
                ),
              ),
          ],
        ),
      ),
    );

    final nowLine =
        nowWidget ??
        Padding(
          padding: const EdgeInsets.only(right: 14, bottom: 12),
          child: Row(children: now ?? const []),
        );
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        if (usage != null)
          Padding(padding: const EdgeInsets.only(left: 14), child: usage),
        Padding(padding: const EdgeInsets.only(left: 14), child: nowLine),
        if (open) _body(context, cat),
      ],
    );
    return Opacity(
      opacity: excluded ? .45 : 1,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: picked ? Color.alphaBlend(c.accent.tint(.07), c.card) : c.card,
          borderRadius: BorderRadius.circular(c.radius),
          border: Border.all(color: picked ? c.accent : c.border),
        ),
        child: Stack(
          children: [
            column,
            if (picked)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: c.accent),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Catalog cat) {
    final c = context.colors;
    final l10n = context.l10n;
    final priority = cat.unitPriority(unit);
    var rank = 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: HintText(pickModeHint(l10n, priority)),
            ),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(c.radius),
                border: Border.all(color: c.border),
              ),
              child: rows.isEmpty
                  ? EmptyLine(l10n.noServers)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, r) in rows.indexed)
                          _serverRow(
                            context,
                            cat,
                            r,
                            i,
                            priority ? ++rank : null,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverRow(
    BuildContext context,
    Catalog cat,
    NodeRef r,
    int i,
    int? rank,
  ) {
    final c = context.colors;
    final t = 'node:${r.sid}::${r.node.id}';
    final src = cat.sourcesData[r.sid];
    final off = src != null && cat.isNodeDisabled(src, r.node.id);
    final picked = t == current;
    final excl = exclude.isNotEmpty && t == exclude;
    return Opacity(
      opacity: excl ? .45 : 1,
      child: Stack(
        children: [
          Container(
            color: picked ? c.accent.tint(.10) : null,
            child: NodeRow(
              node: r.node,
              topBorder: i > 0,
              dim: off,
              lead: [if (rank != null) RankText(rank)],
              onTap: () => onPick?.call(t),
            ),
          ),
          if (picked)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: c.accent),
            ),
        ],
      ),
    );
  }
}

/// `.conn-state`: the AUTO mark of a card; on = the whole item is the target.
class _AutoButton extends StatelessWidget {
  const _AutoButton({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: context.l10n.useTheWholeItemAsThe,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 54,
          padding: const EdgeInsets.symmetric(vertical: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? c.active.tint(.12) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? c.active.tint(.45) : c.border),
          ),
          child: Text(
            'AUTO',
            style: TextStyle(
              fontSize: 9.5,
              height: 13 / 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
              color: on ? c.active : c.t3,
            ),
          ),
        ),
      ),
    );
  }
}

/// How a [TargetRow] behaves: the real picker, a fixed value (the main flow, not changeable) or a dash.
enum TargetRowMode { normal, fixed, inert }

/// `.tgt-row`: a label at the left, the picked target at the right (flag, name in the accent, its
/// kind, `unavailable` when it is off / empty / deleted) and a chevron; a tap opens the picker.
class TargetRow extends StatelessWidget {
  const TargetRow({
    super.key,
    required this.label,
    required this.target,
    this.onPick,
    this.exclude = '',
    this.mode = TargetRowMode.normal,
  });

  final String label;
  final String target;
  final ValueChanged<String>? onPick;
  final String exclude;
  final TargetRowMode mode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final cat = CoreHostScope.of(context).catalog;
    final i = cat.targetInfo(target);
    final valStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: c.accent,
    );
    final Widget value;
    if (mode == TargetRowMode.inert) {
      value = Text('—', style: valStyle.copyWith(color: c.t3));
    } else if (mode == TargetRowMode.fixed) {
      value = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.mainFlow2, style: valStyle),
          const SizedBox(width: 6),
          Opacity(
            opacity: .7,
            child: Icon(Icons.lock_outline, size: 12, color: c.t3),
          ),
        ],
      );
    } else {
      value = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '${i.flag.isNotEmpty ? '${i.flag} ' : ''}${targetText(l10n, cat, target)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valStyle,
            ),
          ),
          if (target.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              kindLabel(l10n, i.kind).toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: .4,
                color: c.t3,
              ),
            ),
          ],
          if (!i.ok) ...[
            const SizedBox(width: 6),
            ConnTag(l10n.unavailable4, tone: TagTone.warn),
          ],
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 16, color: c.t3),
        ],
      );
    }
    final row = SetRow(
      label: label,
      trailing: Flexible(child: value),
      onTap: mode == TargetRowMode.normal
          ? () async {
              final t = await showTargetPicker(
                context,
                current: target,
                exclude: exclude,
              );
              if (t != null) onPick?.call(t);
            }
          : null,
    );
    return mode == TargetRowMode.inert
        ? IgnorePointer(child: Opacity(opacity: .5, child: row))
        : row;
  }
}

/// A row with a [label] at the left and a wide [Seg3] beside it while it fits (its natural width),
/// else under it: `.aa-route`.
class SegRow extends StatelessWidget {
  const SegRow({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final seg = Seg3(
      options: options,
      value: value,
      onChanged: onChanged,
      wide: true,
      enabled: enabled,
    );
    final text = Text(label, style: TextStyle(fontSize: 15, color: c.t1));
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < 330
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text, const SizedBox(height: 8), seg],
              )
            : Row(
                children: [
                  text,
                  const SizedBox(width: 12),
                  Expanded(child: seg),
                ],
              ),
      ),
    );
    return enabled
        ? row
        : Opacity(opacity: .5, child: IgnorePointer(child: row));
  }
}

/// The Fallback rows (segment + its own Via) shared by the rule form and an app's dialog. [on] =
/// Fallback can be set (else dimmed and inert, in place); [own] = the Via target to leave out of the
/// picker ('' = none). The Via row is always in place, inert unless Fallback = Proxy.
class FallbackRows extends StatelessWidget {
  const FallbackRows({
    super.key,
    required this.fallback,
    required this.fallbackTarget,
    required this.on,
    required this.onFallback,
    required this.onTarget,
    this.own = '',
  });

  final String fallback;
  final String fallbackTarget;
  final bool on;
  final String own;
  final ValueChanged<String> onFallback;
  final ValueChanged<String> onTarget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final viaOn = on && fallback == 'main';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegRow(
          label: l10n.fallback,
          enabled: on,
          options: [
            ('default', 'Default'),
            ('main', 'Proxy'),
            ('direct', 'Direct'),
            ('block', 'Block'),
          ],
          value: fallback,
          onChanged: onFallback,
        ),
        Divider(height: 1, thickness: 1, color: context.colors.border),
        TargetRow(
          label: l10n.via,
          target: fallbackTarget,
          exclude: own,
          mode: viaOn ? TargetRowMode.normal : TargetRowMode.inert,
          onPick: onTarget,
        ),
      ],
    );
  }
}
