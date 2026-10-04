import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, CatalogNode, Source;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'catalog_card.dart';
import 'form_parts.dart';
import 'gone_block.dart';
import 'node_row.dart';
import 'nodes_text.dart';
import 'source_error_strip.dart';

/// Nodes -> Simple: one card per source (a subscription or a group of manual servers), mockup
/// `renderSourceCard`. Head: name, meta (format, working / all servers, last update), update, ping
/// and menu buttons - in edit mode the grip and the on / off switch instead. Under it the usage
/// line, the error strip with Retry and the provider's announce. Opened: the servers (tap = their
/// menu, in edit mode tap = on / off), "Add server" on a manual group, the "Unavailable" block.
///
/// [nodes] are the servers to list (the page filters them by the search [searching]); the card
/// sorts them by the Nodes sort. Menus and the add form belong to the page ([onMenu],
/// [onNodeMenu], [onGoneMenu], [onAddServer]); the rest the card asks of the [CoreHost].
class SourceCard extends StatelessWidget {
  const SourceCard({
    super.key,
    required this.source,
    required this.nodes,
    required this.open,
    required this.edit,
    required this.searching,
    required this.onToggleOpen,
    required this.onPing,
    required this.onMenu,
    required this.onNodeMenu,
    required this.onGoneMenu,
    required this.onAddServer,
    this.grip,
  });

  final Source source;
  final List<CatalogNode> nodes;
  final bool open;
  final bool edit;
  final bool searching;
  final VoidCallback onToggleOpen;

  /// The bolt of the head: opens the card and pings its servers.
  final VoidCallback onPing;
  final VoidCallback onMenu;
  final void Function(CatalogNode) onNodeMenu;
  final void Function(CatalogNode) onGoneMenu;
  final VoidCallback onAddServer;

  /// The reorder handle of edit mode (a [ReorderableDragStartListener] over a [GripHandle]).
  final Widget? grip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final s = source;
    final updating = host.isUpdating(s.id);
    final isSub = s.kind == 'sub';
    final sorted = catalog.sortedNodes<CatalogNode>(
      nodes,
      host.nodeSort,
      (n) => n,
    );

    final head = CardHead(
      name: s.name,
      open: open,
      onTap: onToggleOpen,
      dimMain: !s.enabled,
      tag: s.enabled || edit ? null : ConnTag(l10n.off2, tone: TagTone.off),
      meta: _meta(context, host),
      actions: [
        if (isSub && !edit)
          IconBtn(
            kind: IconBtnKind.ghost,
            tooltip: l10n.update,
            onTap: () => host.updateSource(s.id),
            icon: Spin(spinning: updating, child: const Icon(Icons.refresh)),
          ),
        if (edit)
          Tooltip(
            message: l10n.useThisSource,
            child: MiniToggle(
              on: s.enabled,
              onChanged: (_) => host.toggleSourceEnabled(s.id),
            ),
          )
        else
          IconBtn(
            kind: IconBtnKind.ghost,
            tooltip: l10n.testLatency,
            onTap: onPing,
            icon: const Icon(Icons.bolt),
          ),
        IconBtn(
          kind: IconBtnKind.ghost,
          tooltip: l10n.more,
          onTap: onMenu,
          icon: const Icon(Icons.more_vert),
        ),
      ],
    );

    final announce = s.unknown['announce'];
    final below = <Widget>[
      if (isSub)
        _Fade(
          faded: !s.enabled,
          child: _Usage(source: s),
        ),
      SourceErrorStrip(
        source: s,
        updating: updating,
        onRetry: () => host.updateSource(s.id),
      ),
      if (announce is String && announce.isNotEmpty)
        _Fade(
          faded: !s.enabled,
          child: Container(
            margin: const EdgeInsets.only(right: 14, bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.accent.tint(.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              announce,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.35, color: c.t2),
            ),
          ),
        ),
    ];

    final body = _Fade(
      faded: !s.enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, n) in sorted.indexed) _row(host, n, i),
          if (s.kind == 'node') _AddRow(onTap: onAddServer),
          if (!searching)
            GoneBlock(
              refs: catalog.goneRefs(s.id),
              onRowTap: (r) => onGoneMenu(r.node),
              onForgetAll: () => host.forgetGone(s.id),
            ),
        ],
      ),
    );

    return CatalogCard(
      head: head,
      below: below,
      body: body,
      open: open,
      grip: edit ? (searching ? const GripHandle(hidden: true) : grip) : null,
    );
  }

  Widget _row(CoreHost host, CatalogNode n, int i) {
    final on = !host.catalog.isNodeDisabled(source, n.id);
    return NodeRow(
      node: n,
      framed: edit,
      on: on,
      dim: !on,
      topBorder: i > 0,
      onTap: edit
          ? () => host.toggleNodeEnabled(source.id, n.id)
          : () => onNodeMenu(n),
      onPing: () => host.pingNodes([n]),
    );
  }

  /// `.src-meta`: format, working / all servers, last update.
  Widget _meta(BuildContext context, CoreHost host) {
    final l10n = context.l10n;
    final c = context.colors;
    final s = source;
    final catalog = host.catalog;
    final isSub = s.kind == 'sub';
    final live = catalog.liveNodes(s).length;
    final gone = s.gone.length;
    final total = s.nodes.length + gone;
    final format = '${s.unknown['format'] ?? ''}';
    final updatedAt = s.unknown['updatedAt'];
    final TextStyle warnOrDim = TextStyle(color: gone > 0 ? c.warn : c.t3);
    return MetaLine(
      parts: [
        if (isSub ? format.isNotEmpty : true)
          FmtTag(isSub ? format : l10n.manual3),
        live < total
            ? Text(
                isSub
                    ? l10n.nodes2('$live', '$total')
                    : l10n.servers2('$live', '$total'),
                style: warnOrDim,
              )
            : Text(isSub ? l10n.nodesPlural(total) : l10n.serversPlural(total)),
        if (isSub && updatedAt is num) Text(shortAgo(l10n, updatedAt)),
      ],
    );
  }
}

/// The meta line of a source card, for the cards of the target picker.
Widget sourceMetaLine(BuildContext context, CoreHost host, Source s) =>
    SourceCard(
      source: s,
      nodes: const [],
      open: false,
      edit: false,
      searching: false,
      onToggleOpen: () {},
      onPing: () {},
      onMenu: () {},
      onNodeMenu: (_) {},
      onGoneMenu: (_) {},
      onAddServer: () {},
    )._meta(context, host);

/// The usage line (traffic, expiry) of a subscription card.
Widget sourceUsageLine(Source s) => _Usage(source: s);

/// A part of a card faded when the source is switched off in Nodes.
class _Fade extends StatelessWidget {
  const _Fade({required this.faded, required this.child});

  final bool faded;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      faded ? Opacity(opacity: .45, child: child) : child;
}

/// `.src-usage`: traffic used / total with a bar, and the expiry date.
class _Usage extends StatelessWidget {
  const _Usage({required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final u = source.unknown['usage'];
    final used = u is Map && u['used'] is num ? u['used'] as num : 0;
    final total = u is Map && u['total'] is num ? u['total'] as num : 0;
    final expire = source.unknown['expire'];
    final left = total > 0
        ? l10n.gb(fmtGb(used), fmtGb(total))
        : l10n.gbUnlimited(fmtGb(used));
    final right = expire != null && '$expire'.isNotEmpty
        ? l10n.until(fmtDate(expire))
        : l10n.noExpiry;
    final pct = total > 0 ? (used / total).clamp(0, 1).toDouble() : 0.0;
    final style = monoText.copyWith(fontSize: 12, color: c.t2);
    return Padding(
      padding: const EdgeInsets.only(right: 14, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: c.t1.tint(.06))),
                    FractionallySizedBox(
                      widthFactor: pct,
                      child: ColoredBox(color: pct > .8 ? c.warn : c.accent),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: total > 0 ? 6 : 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(left, style: style)),
                const SizedBox(width: 8),
                Flexible(child: Text(right, style: style)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `.node-add`: "Add server" at the bottom of a manual group.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.t1.tint(.035))),
        ),
        child: Row(
          children: [
            Icon(Icons.add, size: 16, color: c.accent),
            const SizedBox(width: 8),
            Text(
              context.l10n.addServer,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
