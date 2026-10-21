import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, NodeRef, reorderKeys;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'gone_block.dart';
import 'nodes_help.dart';
import 'pick_parts.dart';

/// Nodes -> a source's menu -> Route settings (mockup 72-source-entry.js): which of the source's
/// servers its route entry may use, Fastest / Priority (drag to order), Use in Auto. Changes
/// apply at once. With every server unticked a warning shows, Done is off, and closing the sheet
/// puts the selection back to what it was when it opened.
Future<void> showSourceEntry(BuildContext context, String sid) async {
  final host = CoreHostScope.read(context);
  final source = host.catalog.sourcesData[sid];
  if (source == null) return;
  final snapshot = [...source.offNodes];
  final l10n = context.l10n;
  await showAppSheet<void>(
    context,
    builder: (_) => _SourceEntrySheet(sid: sid),
  );
  final s = host.catalog.sourcesData[sid];
  if (s == null) return;
  // only the servers the core can use count: the unusable ones are not in the list
  final liveNodes = [for (final n in host.catalog.liveNodes(s)) if (n.usable) n];
  final live = liveNodes.length;
  final off = liveNodes.where((n) => host.catalog.isNodeOff(s, n.id)).length;
  if (live > 0 && live - off == 0) {
    host.setSourceOffNodes(sid, snapshot);
    if (context.mounted) showToast(context, l10n.atLeast1ServerIsNeeded);
  }
}

class _SourceEntrySheet extends StatelessWidget {
  const _SourceEntrySheet({required this.sid});

  final String sid;

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final s = catalog.sourcesData[sid];
    final l10n = context.l10n;
    final c = context.colors;
    if (s == null) return const SizedBox.shrink();
    final live = [for (final n in catalog.liveNodes(s)) if (n.usable) n];
    final on = live.where((n) => !catalog.isNodeOff(s, n.id)).length;
    final hidden = s.nodes.where((n) => n.usable).length - live.length;
    final none = on == 0 && live.isNotEmpty;
    final priority = s.pickMode == 'priority';
    final refs = priority
        ? [
            for (final r in catalog.sourceEntryRefs(sid))
              if (r.node.usable) r,
          ]
        : catalog.byPing<NodeRef>([
            for (final n in live) NodeRef(sid, n),
          ], (r) => r.node);
    final updating = host.isUpdating(sid);
    return SheetFrame(
      title: s.name,
      titleBadge: const NodesHelpButton(NodesHelp.sourceEntry),
      full: true,
      footer: [
        if (none) WarnNote(l10n.selectAtLeast1ServerOtherwise),
        PrimaryButton(
          label: l10n.done,
          onPressed: none ? null : () => Navigator.of(context).pop(),
        ),
      ],
      scrolls: false,
      // a lazy list: a big subscription has hundreds of servers (the frame keeps the sheet's
      // swipe-down-to-close and its footer)
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(top: 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
          SetGroup(
            children: [
              SetRow(
                label: l10n.useInAuto,
                hint: l10n.autoMayConnectThisEntryIn,
                trailing: MiniToggle(
                  on: s.inAuto,
                  onChanged: (v) => host.setEntryInAuto(sid, v),
                ),
              ),
            ],
          ),
          FormGroup(
            label: l10n.servers,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PickModeSwitch(
                  priority: priority,
                  onChanged: (p) =>
                      host.setPickMode(sid, p ? 'priority' : 'fastest'),
                ),
                HintText(pickModeHint(l10n, priority)),
              ],
            ),
          ),
          SelectionBar(
            count: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: l10n.ofOn(on, live.length)),
                  if (hidden > 0)
                    TextSpan(
                      text: ' · $hidden ${l10n.offInNodes}',
                      style: TextStyle(color: c.muted),
                    ),
                ],
              ),
            ),
            chip: on == live.length ? l10n.none : l10n.all,
            onChip: () => host.setSourceOffNodes(sid, catalog.offNodesAll(sid)),
            actions: [
              if (s.kind == 'sub')
                IconBtn(
                  kind: IconBtnKind.ghost,
                  tooltip: l10n.update,
                  onTap: () => host.updateSource(sid),
                  icon: Spin(
                    spinning: updating,
                    child: const Icon(Icons.refresh),
                  ),
                ),
              PingAllButton(onTap: () => host.pingSource(sid)),
            ],
          ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            sliver: DecoratedSliver(
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(c.radius),
                border: Border.all(color: c.border),
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  if (refs.isEmpty)
                    SliverToBoxAdapter(child: EmptyLine(l10n.noServersYet))
                  else
                    PickRows(
                      sliver: true,
                      refs: refs,
                      orderable: priority,
                      isOn: (r) => !catalog.isNodeOff(s, r.node.id),
                      onTap: (r) => host.setSourceOffNodes(
                        sid,
                        catalog.offNodesToggled(sid, r.node.id),
                      ),
                      onReorder: (keys) => host.setPickOrder(
                        sid,
                        reorderKeys(s.pickOrder, [
                          for (final r in refs) r.key,
                        ], keys),
                      ),
                    ),
                  GoneBlock(
                    sliver: true,
                    gone: catalog.goneRefs(sid),
                    unsupported: catalog.unsupportedRefs(sid),
                    isOn: (r) => !catalog.isNodeOff(s, r.node.id),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
