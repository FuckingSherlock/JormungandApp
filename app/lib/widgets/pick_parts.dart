import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show NodeRef;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'catalog_card.dart';
import 'form_parts.dart';
import 'node_row.dart';

/// Pieces the three server pickers share: the source entry sheet, the profile editor and the
/// chain editor (mockup 40-sheets.css `.se-*`, `.cc-*`, `.ps-*`).

/// The English-keyed hint under the Fastest / Priority switch of a picker (`pickModeHint`).
String pickModeHint(AppLocalizations l10n, bool priority) => priority
    ? l10n.framedServersAreUsedTheFirst
    : l10n.framedServersAreUsedTapTo;

/// `.seg-ping`: the bolt next to the Fastest / Priority switch.
class PingAllButton extends StatelessWidget {
  const PingAllButton({super.key, required this.onTap, this.tooltip});

  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => IconBtn(
    kind: IconBtnKind.ghost,
    tooltip: tooltip ?? context.l10n.testLatency,
    onTap: onTap,
    icon: const Icon(Icons.bolt),
  );
}

/// `.se-bar`: a count at the left, All / None and the buttons at the right.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    this.chip,
    this.onChip,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(20, 4, 14, 8),
  });

  final Widget count;
  final String? chip;
  final VoidCallback? onChip;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 13, color: c.t2),
              child: count,
            ),
          ),
          if (chip != null)
            AppChip(label: chip!, active: false, onTap: onChip, small: true),
          ...actions,
        ],
      ),
    );
  }
}

/// `.profile-radio`.
class ProfileRadio extends StatelessWidget {
  const ProfileRadio({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: active ? c.accent : c.borderHi, width: 2),
      ),
      child: active
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
            )
          : null,
    );
  }
}

/// `.cc-rank`: the place of a server in a Priority list.
class RankText extends StatelessWidget {
  const RankText(this.rank, {super.key});

  /// Null = a blank slot (a server that is left out).
  final int? rank;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 14,
    child: Text(
      rank == null ? '' : '$rank',
      textAlign: TextAlign.center,
      style: monoText.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.colors.accent,
      ),
    ),
  );
}

/// The servers of a picker as framed rows (`.node-row.ps-node.pick`): framed = used, a tap ticks
/// or unticks one, the latency pings it. With [orderable] (Priority) each row has a grip and its
/// rank, and dragging a grip calls [onReorder] with the new order of every shown key.
class PickRows extends StatelessWidget {
  const PickRows({
    super.key,
    required this.refs,
    required this.isOn,
    required this.onTap,
    this.orderable = false,
    this.onReorder,
    this.protoOf,
    this.sourceNames = false,
  });

  final List<NodeRef> refs;
  final bool Function(NodeRef) isOn;
  final void Function(NodeRef) onTap;
  final bool orderable;
  final void Function(List<String> keys)? onReorder;

  /// Replaces the protocol badge (the profile's order list names the source there).
  final String? Function(NodeRef)? protoOf;
  final bool sourceNames;

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    var rank = 0;
    final ranks = [for (final r in refs) isOn(r) ? ++rank : null];

    Widget row(int i) {
      final r = refs[i];
      final on = isOn(r);
      return NodeRow(
        key: ValueKey(r.key),
        node: r.node,
        framed: true,
        on: on,
        proto: protoOf?.call(r),
        sourceName: sourceNames ? host.catalog.sourcesData[r.sid]?.name : null,
        lead: orderable
            ? [
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(0, 8, 6, 8),
                    child: GripHandle(),
                  ),
                ),
                RankText(ranks[i]),
                const SizedBox(width: 8),
              ]
            : const [],
        onTap: () => onTap(r),
        onPing: () => host.pingNodes([r.node]),
      );
    }

    if (!orderable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = 0; i < refs.length; i++) row(i)],
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: refs.length,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      onReorderItem: (from, to) {
        final keys = [for (final r in refs) r.key];
        final moved = keys.removeAt(from);
        keys.insert(to, moved);
        onReorder?.call(keys);
      },
      itemBuilder: (context, i) => row(i),
    );
  }
}
