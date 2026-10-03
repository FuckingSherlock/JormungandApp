import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, NodeRef, reorderKeys;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'gone_block.dart';
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
  final live = host.catalog.liveNodes(s).length;
  if (live > 0 && live - host.catalog.offCount(s) == 0) {
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
    final live = catalog.liveNodes(s);
    final on = live.length - catalog.offCount(s);
    final hidden = s.nodes.length - live.length;
    final none = on == 0 && live.isNotEmpty;
    final priority = s.pickMode == 'priority';
    final refs = priority
        ? catalog.sourceEntryRefs(sid)
        : catalog.byPing<NodeRef>([
            for (final n in live) NodeRef(sid, n),
          ], (r) => r.node);
    final updating = host.isUpdating(sid);
    return SheetFrame(
      title: s.name,
      full: true,
      footer: [
        if (none) WarnNote(l10n.selectAtLeast1ServerOtherwise),
        PrimaryButton(
          label: l10n.done,
          onPressed: none ? null : () => Navigator.of(context).pop(),
        ),
      ],
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
          NodesBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (refs.isEmpty)
                  EmptyLine(l10n.noServersYet)
                else
                  PickRows(
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
                  refs: catalog.goneRefs(sid),
                  isOn: (r) => !catalog.isNodeOff(s, r.node.id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
