import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';

/// The frame of a Nodes card (mockup `.src-card`): a [head] row with whatever sits [below] it
/// (usage, error strip, "now" line), and when [open] the [body] under a hairline. In edit mode a
/// [grip] column is added at the left (the drag handle of the reorder list).
class CatalogCard extends StatelessWidget {
  const CatalogCard({
    super.key,
    required this.head,
    this.below = const [],
    this.body,
    this.grip,
    this.open = false,
    this.borderColor,
  });

  final Widget head;
  final List<Widget> below;
  final Widget? body;
  final Widget? grip;
  final bool open;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [head, ...below],
    );
    final Widget top = grip == null
        ? Padding(padding: const EdgeInsets.only(left: 14), child: main)
        : IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: SizedBox(width: 26, child: grip),
                ),
                Expanded(child: main),
              ],
            ),
          );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: borderColor ?? c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          if (open && body != null)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: body,
            ),
        ],
      ),
    );
  }
}

/// `.src-head`: the tappable name + meta block with the buttons at its right.
class CardHead extends StatelessWidget {
  const CardHead({
    super.key,
    required this.name,
    required this.meta,
    required this.open,
    required this.onTap,
    this.tag,
    this.actions = const [],
    this.dimMain = false,
    this.dimOpacity = .45,
  });

  final String name;
  final Widget meta;
  final bool open;
  final VoidCallback onTap;

  /// Next to the name (the `off` tag).
  final Widget? tag;
  final List<Widget> actions;

  /// The name and meta are faded (a switched-off source, a broken entry).
  final bool dimMain;
  final double dimOpacity;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final main = Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
              if (tag != null) ...[const SizedBox(width: 6), tag!],
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: open ? .5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more, size: 16, color: c.t3),
              ),
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 3), child: meta),
        ],
      ),
    );
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 6, 10),
        child: Row(
          children: [
            Expanded(
              child: dimMain ? Opacity(opacity: dimOpacity, child: main) : main,
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// The meta line of a card (`.src-meta`): small parts separated by dots; a dot never starts a
/// wrapped line (it belongs to the part before it).
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.parts});

  final List<Widget> parts;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 13, color: c.t2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 2,
        children: [
          for (var i = 0; i < parts.length; i++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                parts[i],
                if (i < parts.length - 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text('·', style: TextStyle(color: c.t3)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The drag handle of an edit-mode card (`.drag-handle` with the grip glyph): the area the
/// [ReorderableDragStartListener] above it listens on.
class GripHandle extends StatelessWidget {
  const GripHandle({super.key, this.hidden = false});

  final bool hidden;

  @override
  Widget build(BuildContext context) => Center(
    child: Opacity(
      opacity: hidden ? 0 : 1,
      child: Icon(Icons.drag_indicator, size: 18, color: context.colors.t3),
    ),
  );
}
