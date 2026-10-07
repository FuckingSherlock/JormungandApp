import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, CatalogNode, Chain, NodeRef;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'catalog_card.dart';
import 'form_parts.dart';
import 'latency_text.dart';
import 'node_row.dart';
import 'nodes_text.dart';

/// Nodes -> a profile or a chain card (mockup `renderEntryCard`). Head: name, what it is made of,
/// the ping and edit buttons. Under it the server it would use now with its ping (a chain: entry
/// -> exit and the measured pair's latency, `Catalog.chainLatency`), or what is off in Nodes. Opened: its servers - tap one to
/// ping it; a chain lists both ends, and in edit mode every server of each end, framed when this
/// chain uses it (tap = on / off for this chain only).
class EntryCard extends StatelessWidget {
  const EntryCard({
    super.key,
    required this.id,
    required this.open,
    required this.edit,
    required this.searching,
    required this.onToggleOpen,
    required this.onEdit,
    this.grip,
  });

  final String id;
  final bool open;
  final bool edit;
  final bool searching;
  final VoidCallback onToggleOpen;
  final VoidCallback onEdit;
  final Widget? grip;

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final entry = catalog.connectEntry(id);
    if (entry == null) return const SizedBox.shrink();
    final c = context.colors;
    final l10n = context.l10n;
    final chain = catalog.chainsData[id];
    final broken = catalog.isBroken(id);

    final head = CardHead(
      name: entry.name,
      open: open,
      onTap: onToggleOpen,
      dimMain: broken,
      dimOpacity: .6,
      tag: broken ? ConnTag(l10n.off2, tone: TagTone.off) : null,
      meta: _meta(context, host, chain),
      actions: [
        if (!edit)
          IconBtn(
            kind: IconBtnKind.ghost,
            large: true,
            tooltip: l10n.testLatency,
            onTap: () => host.pingEntry(id),
            icon: const Icon(Icons.bolt),
          ),
        IconBtn(
          kind: IconBtnKind.ghost,
          large: true,
          tooltip: chain != null ? l10n.editChain : l10n.editProfile,
          onTap: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    );

    return CatalogCard(
      head: head,
      below: [_now(context, host, chain, broken)],
      body: _body(context, host, chain),
      open: open,
      borderColor: broken ? c.muted.tint(.55) : null,
      grip: edit ? (searching ? const GripHandle(hidden: true) : grip) : null,
    );
  }

  Widget _meta(BuildContext context, CoreHost host, Chain? chain) {
    final l10n = context.l10n;
    final catalog = host.catalog;
    if (chain != null) {
      return MetaLine(
        parts: [
          FmtTag(l10n.chain2),
          Text(
            '${catalog.unitName(chain.inId)} → ${catalog.unitName(chain.outId)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (chain.exitMode == 'priority') Text(l10n.exitByPriority),
        ],
      );
    }
    final p = catalog.profilesData[id]!;
    final n = catalog.unitRefs(id).length;
    final made = [
      if (p.sources.isNotEmpty) l10n.sourcesPlural(p.sources.length),
      if (p.nodes.isNotEmpty) l10n.picked(p.nodes.length),
    ].join(' + ');
    return MetaLine(
      parts: [
        FmtTag(l10n.profile2),
        Text(l10n.serversPlural(n)),
        if (made.isNotEmpty) Text(made),
      ],
    );
  }

  /// `.entry-now`: the server it would use now.
  Widget _now(BuildContext context, CoreHost host, Chain? chain, bool broken) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = host.catalog;
    const pad = EdgeInsets.only(right: 14, bottom: 12);
    final base = TextStyle(fontSize: 13, color: c.t2);
    if (broken) {
      return Padding(
        padding: pad,
        child: Text(
          offReasonsText(l10n, catalog, catalog.brokenBy(id)),
          style: base.copyWith(color: c.muted),
        ),
      );
    }
    if (chain != null) {
      final a = catalog.chainEntryNode(chain);
      final b = catalog.chainExitNode(chain);
      Widget node(CatalogNode? n) => Flexible(
        child: Text(
          n == null ? l10n.noWorkingServer : '${n.flag} ${n.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base,
        ),
      );
      final total = catalog.chainLatency(chain);
      return Padding(
        padding: pad,
        child: Row(
          children: [
            node(a),
            const SizedBox(width: 6),
            Text('→', style: base.copyWith(color: c.t3)),
            const SizedBox(width: 6),
            node(b),
            if (total != null) ...[
              const Spacer(),
              LatencyView(ms: total, minWidth: 0),
            ],
          ],
        ),
      );
    }
    final n = catalog.unitNode(id);
    return Padding(
      padding: pad,
      child: Row(
        children: [
          if (catalog.unitPriority(id)) ...[
            ConnTag(l10n.priority2, tone: TagTone.muted),
            const SizedBox(width: 6),
          ],
          if (n == null)
            Flexible(
              child: Text(
                l10n.noWorkingNodes,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base,
              ),
            )
          else ...[
            Flexible(
              child: Text(
                '${n.flag} ${n.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: base,
              ),
            ),
            const SizedBox(width: 6),
            LatencyText(n),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, CoreHost host, Chain? chain) {
    final catalog = host.catalog;
    if (chain == null) {
      final refs = catalog.unitPriority(id)
          ? catalog.unitPickRefs(id)
          : catalog.byPing<NodeRef>(catalog.unitPickRefs(id), (r) => r.node);
      return _rows(context, host, refs, catalog.unitNode(id));
    }
    final l10n = context.l10n;
    Widget side(String side, String label, String? unitId) {
      final String name = catalog.unitName(unitId);
      final Widget rows;
      if (edit) {
        rows = _editRows(context, host, chain, side);
      } else if (side == 'in') {
        rows = _rows(
          context,
          host,
          catalog.byPing<NodeRef>(catalog.chainEntryRefs(chain), (r) => r.node),
          catalog.chainEntryNode(chain),
        );
      } else {
        final exits = catalog.chainExitRefs(chain);
        rows = _rows(
          context,
          host,
          chain.exitMode == 'priority'
              ? exits
              : catalog.byChainPing<NodeRef>(chain, exits, (r) => r.node),
          catalog.chainExitNode(chain),
          exitOf: chain,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Text(
              '$label · $name'.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: .5,
                color: context.colors.t3,
              ),
            ),
          ),
          rows,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        side('in', l10n.entry, chain.inId),
        side('out', l10n.exit, chain.outId),
      ],
    );
  }

  /// The source under a server name only when the list mixes sources: a chain end or a
  /// profile of one source has its name in the heading already.
  static bool _mixed(List<NodeRef> refs) =>
      refs.map((r) => r.sid).toSet().length > 1;

  Widget _rows(
    BuildContext context,
    CoreHost host,
    List<NodeRef> refs,
    CatalogNode? now, {
    Chain? exitOf,
  }) {
    if (refs.isEmpty) return const _EntryEmpty();
    final mixed = _mixed(refs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in refs.indexed)
          NodeRow(
            node: r.node,
            sourceName: mixed ? host.catalog.sourcesData[r.sid]?.name : null,
            now: identical(r.node, now),
            topBorder: i > 0,
            // a chain's exit answers through the chain's entry: that is what a tap measures
            trailing: exitOf == null ? null : ChainExitLatency(exitOf, r.node),
            onTap: () => exitOf == null
                ? host.pingNodes([r.node])
                : host.pingChain(exitOf, exits: [r.node], entries: false),
          ),
      ],
    );
  }

  /// Edit mode on a chain card: every server of the end, framed = used by this chain.
  Widget _editRows(
    BuildContext context,
    CoreHost host,
    Chain chain,
    String side,
  ) {
    final catalog = host.catalog;
    final off = side == 'in' ? chain.inOff : chain.outOff;
    final List<NodeRef> refs;
    if (side == 'in') {
      refs = catalog.byPing<NodeRef>(
        catalog.chainSideRefs(chain, 'in'),
        (r) => r.node,
      );
    } else if (chain.exitMode == 'priority') {
      refs = catalog.chainExitOrder(chain);
    } else {
      refs = catalog.byChainPing<NodeRef>(
        chain,
        catalog.chainExitOrder(chain),
        (r) => r.node,
      );
    }
    if (refs.isEmpty) return const _EntryEmpty();
    final mixed = _mixed(refs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in refs)
          NodeRow(
            node: r.node,
            sourceName: mixed ? catalog.sourcesData[r.sid]?.name : null,
            trailing: side == 'out' ? ChainExitLatency(chain, r.node) : null,
            framed: true,
            on: !off.contains(r.key),
            dim: off.contains(r.key),
            onTap: () => host.toggleChainNode(id, side, r.key),
          ),
      ],
    );
  }
}

EntryCard _probe(String id) => EntryCard(
  id: id,
  open: false,
  edit: false,
  searching: false,
  onToggleOpen: () {},
  onEdit: () {},
);

/// The meta line of a profile / chain card, for the cards of the target picker.
Widget entryMetaLine(BuildContext context, CoreHost host, String id) =>
    _probe(id)._meta(context, host, host.catalog.chainsData[id]);

/// The "server it would use now" line of a profile / chain card.
Widget entryNowLine(BuildContext context, CoreHost host, String id) => _probe(
  id,
)._now(context, host, host.catalog.chainsData[id], host.catalog.isBroken(id));

/// `.entry-empty`.
class _EntryEmpty extends StatelessWidget {
  const _EntryEmpty();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
    child: Text(
      context.l10n.noWorkingServers,
      style: TextStyle(fontSize: 13, color: context.colors.t3),
    ),
  );
}
