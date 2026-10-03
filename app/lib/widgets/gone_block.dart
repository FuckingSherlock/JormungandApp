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
class GoneBlock extends StatefulWidget {
  const GoneBlock({
    super.key,
    required this.refs,
    this.isOn,
    this.onRowTap,
    this.onForgetAll,
  });

  final List<NodeRef> refs;
  final bool Function(NodeRef)? isOn;
  final void Function(NodeRef)? onRowTap;
  final VoidCallback? onForgetAll;

  @override
  State<GoneBlock> createState() => _GoneBlockState();
}

class _GoneBlockState extends State<GoneBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    if (refs.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
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
                Text(
                  l10n.unavailable3('${refs.length}'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.t2,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.removedByTheProviderSettingsKept,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.t3),
                  ),
                ),
                if (widget.onForgetAll != null) ...[
                  const SizedBox(width: 8),
                  AppChip(
                    label: l10n.forgetAll,
                    active: false,
                    small: true,
                    onTap: widget.onForgetAll,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_open)
          for (final r in refs)
            NodeRow(
              node: r.node,
              gone: true,
              framed: widget.isOn != null,
              on: widget.isOn?.call(r) ?? false,
              onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(r),
              trailing: _DaysLeft(days: catalog.goneLeftDays(r.node)),
            ),
      ],
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
