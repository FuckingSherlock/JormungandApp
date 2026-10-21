import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'catalog_card.dart' show GripHandle;
import 'form_parts.dart';
import 'pick_parts.dart';
import 'rules_parts.dart';

/// A rule of the list with the number it is shown under.
class RuleListEntry {
  const RuleListEntry(this.rule, this.rank);

  final UserRule rule;
  final int rank;
}

/// How many rules are visible before the rest go under "{n} more".
const ruleListHead = 4;

/// The list of rules of the Rules screen (My rules) and of an app's sheet: rows with a drag grip,
/// number, title, action badge and an on / off toggle; the first [ruleListHead] are visible, the
/// rest are under a row "{n} more" (a tap opens it; [searching] opens it too and stops the drag).
class RuleList extends StatefulWidget {
  const RuleList({
    super.key,
    required this.entries,
    required this.emptyText,
    required this.onTap,
    required this.onToggle,
    this.onReorder,
    this.searching = false,
  });

  final List<RuleListEntry> entries;
  final String emptyText;
  final void Function(UserRule rule) onTap;
  final void Function(UserRule rule, bool on) onToggle;

  /// Indices in [entries], the target one is the index after the move; null = no drag.
  final void Function(int from, int to)? onReorder;
  final bool searching;

  @override
  State<RuleList> createState() => _RuleListState();
}

class _RuleListState extends State<RuleList> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final entries = widget.entries;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Center(
          child: Text(
            widget.emptyText,
            style: TextStyle(fontSize: 13, color: c.t3),
          ),
        ),
      );
    }
    final expanded = _open || widget.searching;
    final shown = expanded ? entries : entries.take(ruleListHead).toList();
    final hidden = entries.length - shown.length;
    final drag = widget.onReorder != null && !widget.searching;
    final Widget rows = !drag
        ? Column(
            children: [
              for (final (i, e) in shown.indexed) _row(context, e, i, false),
            ],
          )
        : ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: shown.length,
            proxyDecorator: (child, index, animation) =>
                Material(type: MaterialType.transparency, child: child),
            onReorderItem: widget.onReorder!,
            itemBuilder: (_, i) => _row(context, shown[i], i, true),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        rows,
        if (hidden > 0)
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: SetRow(
              label: l10n.more2(hidden),
              onTap: () => setState(() => _open = true),
              trailing: Icon(Icons.keyboard_arrow_down, size: 18, color: c.t3),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, RuleListEntry e, int i, bool grip) {
    final l10n = context.l10n;
    final c = context.colors;
    final cat = CoreHostScope.of(context).catalog;
    final r = e.rule;
    final lostTag = r.action == 'proxy'
        ? targetLostTag(l10n, cat, r.target, cat.planRuleFallback(r))
        : null;
    return Container(
      key: ValueKey(r.id),
      decoration: BoxDecoration(
        border: i > 0 ? Border(top: BorderSide(color: c.border)) : null,
      ),
      child: Opacity(
        opacity: r.enabled ? 1 : .5,
        child: InkWell(
          onTap: () => widget.onTap(r),
          splashFactory: NoSplash.splashFactory,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                if (grip)
                  ReorderableDragStartListener(
                    index: i,
                    child: const GripHandle(),
                  )
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 4),
                RankText(e.rank),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            ruleTitleText(l10n, r),
                            style: TextStyle(fontSize: 15, color: c.t1),
                          ),
                          if (r.composite != null)
                            const ConnTag('JSON', tone: TagTone.muted),
                          if (lostTag != null)
                            ConnTag(lostTag, tone: TagTone.error),
                        ],
                      ),
                      if (r.name.isNotEmpty) HintText(ruleSummaryText(l10n, r)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ActionBadge(act: r.action, text: ruleTargetText(l10n, cat, r)),
                const SizedBox(width: 6),
                MiniToggle(
                  on: r.enabled,
                  onChanged: (v) => widget.onToggle(r, v),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
