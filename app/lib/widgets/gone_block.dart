import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show CatalogOps, NodeRef;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'form_parts.dart';
import 'node_row.dart';

/// Servers the provider dropped (`s.gone`): one collapsible "Unavailable · N" block, used by Nodes
/// and by every server picker (mockup `goneBlockHtml`). The rows are read-only; [isOn] frames the
/// ones whose kept selection is on (pickers); [onRowTap] (Nodes only) opens the server's own
/// menu; [onForgetAll] adds the "Forget all" chip. Each dropped server is kept for the days the
/// core says, then forgotten with its settings.
///
/// [unsupported] are the live servers that cannot go into a config (no outbound, or a protocol
/// the core cannot run): they join the block, with the reason instead of the days. [sliver] makes
/// the block a sliver (header + a lazy list of rows) for a lazy scroll view.
class GoneBlock extends StatefulWidget {
  const GoneBlock({
    super.key,
    required this.gone,
    this.unsupported = const [],
    this.isOn,
    this.onRowTap,
    this.onForgetAll,
    this.sliver = false,
    this.expandable = true,
  });

  final List<NodeRef> gone;
  /// False: the block stays collapsed and its header does not open it (source reorder mode).
  final bool expandable;
  final List<NodeRef> unsupported;
  final bool Function(NodeRef)? isOn;
  final void Function(NodeRef)? onRowTap;
  final VoidCallback? onForgetAll;
  final bool sliver;

  @override
  State<GoneBlock> createState() => _GoneBlockState();
}

class _GoneBlockState extends State<GoneBlock> {
  bool _open = false;

  Widget _row(NodeRef r, bool unsupported) {
    final catalog = CoreHostScope.of(context).catalog;
    return NodeRow(
      key: ValueKey(r.key),
      node: r.node,
      gone: true,
      framed: widget.isOn != null,
      on: !unsupported && (widget.isOn?.call(r) ?? false),
      onTap: widget.onRowTap == null || unsupported
          ? null
          : () => widget.onRowTap!(r),
      trailing: unsupported
          ? _WhyText(r.node.outbound == null
              ? context.l10n.notSupportedNoOutbound
              : context.l10n.notSupported2(r.node.unsupported ?? ''))
          : _DaysLeft(days: catalog.goneLeftDays(r.node)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gone = widget.gone;
    final unsupported = widget.unsupported;
    final count = gone.length + unsupported.length;
    if (count == 0) {
      return widget.sliver
          ? const SliverToBoxAdapter(child: SizedBox.shrink())
          : const SizedBox.shrink();
    }
    final c = context.colors;
    final l10n = context.l10n;
    final forget = widget.onForgetAll != null && gone.isNotEmpty;
    final open = _open && widget.expandable;
    final header = InkWell(
          onTap: widget.expandable ? () => setState(() => _open = !_open) : null,
          splashFactory: NoSplash.splashFactory,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: open ? 0 : -.25,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more, size: 16, color: c.t3),
                ),
                const SizedBox(width: 8),
                // every part may shrink, so the header fits a narrow screen at a large text size:
                // the count keeps the most room, the subtitle ellipsizes first, the chip wraps
                Flexible(
                  flex: forget ? 4 : 3,
                  child: Text(
                    l10n.unavailable3('$count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.t2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Text(
                    unsupported.isEmpty
                        ? l10n.removedByTheProviderSettingsKept
                        : l10n.removedByTheProviderOrNot,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.t3),
                  ),
                ),
                if (forget) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 3,
                    child: AppChip(
                      label: l10n.forgetAll,
                      active: false,
                      small: true,
                      onTap: widget.onForgetAll,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
    NodeRef at(int i) => i < gone.length ? gone[i] : unsupported[i - gone.length];
    if (widget.sliver) {
      return SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(child: header),
          if (open)
            SliverList.builder(
              itemCount: count,
              itemBuilder: (_, i) => _row(at(i), i >= gone.length),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (open)
          for (var i = 0; i < count; i++) _row(at(i), i >= gone.length),
      ],
    );
  }
}

/// The reason an unsupported server is listed, in the place of the days left.
class _WhyText extends StatelessWidget {
  const _WhyText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 150),
    child: Text(
      text,
      textAlign: TextAlign.right,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: context.colors.t3),
    ),
  );
}

/// Servers the source's own editor has switched off (`offNodes`), offered by the chain editor:
/// one collapsed "Disabled in subscription · N" block below the end's list. A tap on a row
/// calls [onSwitchOn]: the server joins this chain only, the subscription keeps it disabled.
class DisabledBlock extends StatefulWidget {
  const DisabledBlock({
    super.key,
    required this.refs,
    required this.onSwitchOn,
    this.sliver = false,
  });

  final List<NodeRef> refs;
  final void Function(NodeRef) onSwitchOn;

  /// A sliver (header + a lazy list of rows) for a lazy scroll view.
  final bool sliver;

  @override
  State<DisabledBlock> createState() => _DisabledBlockState();
}

class _DisabledBlockState extends State<DisabledBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    if (refs.isEmpty) {
      return widget.sliver
          ? const SliverToBoxAdapter(child: SizedBox.shrink())
          : const SizedBox.shrink();
    }
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    Widget row(NodeRef r) => NodeRow(
      key: ValueKey(r.key),
      node: r.node,
      framed: true,
      on: false,
      onTap: () => widget.onSwitchOn(r),
      onPing: () => host.pingNodes([r.node]),
    );
    final header = InkWell(
          onTap: () => setState(() => _open = !_open),
          splashFactory: NoSplash.splashFactory,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0 : -.25,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more, size: 16, color: c.t3),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.disabledInSubscription('${refs.length}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.t2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.canBeSwitchedOnForThis,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.t3),
                  ),
                ),
              ],
            ),
          ),
        );
    if (widget.sliver) {
      return SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(child: header),
          if (_open)
            SliverList.builder(
              itemCount: refs.length,
              itemBuilder: (_, i) => row(refs[i]),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [header, if (_open) for (final r in refs) row(r)],
    );
  }
}

/// `.gone-left`: the days before the dropped server is forgotten, amber in the last three.
class _DaysLeft extends StatelessWidget {
  const _DaysLeft({required this.days});

  final int? days;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = days;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 44),
      child: Text(
        d == null ? '—' : context.l10n.dLeft(d < 0 ? 0 : d),
        textAlign: TextAlign.right,
        style: monoText.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: d != null && d <= 3 ? c.warn : c.t3,
        ),
      ),
    );
  }
}
