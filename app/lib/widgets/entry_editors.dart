import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, CatalogNode, Chain, NodeRef, PickState, Profile, Source;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'catalog_card.dart';
import 'form_parts.dart';
import 'gone_block.dart';
import 'node_row.dart';
import 'nodes_help.dart';
import 'nodes_menus.dart';
import 'nodes_text.dart';
import 'pick_parts.dart';
import 'route_check.dart';

/// The profile editor and the chain editor (mockup 70-profile-forms.js). A draft ([Profile] /
/// [Chain] that is not in the catalog) is changed through the core's `CatalogDrafts` and handed to
/// the host on Save; nothing reaches the catalog before that. Both are full-height sheets; what
/// stops a Save is told in the footer, like the mockup's warn-note.

// ── Profile ──

/// Create a profile, or edit [id].
Future<void> showProfileEditor(BuildContext context, {String? id}) {
  return showAppSheet<void>(
    context,
    builder: (_) => _ProfileEditor(id: id, page: context),
  );
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.id, required this.page});

  final String? id;
  final BuildContext page;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final Profile _d;
  late final TextEditingController _name;
  final _open = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final catalog = CoreHostScope.read(context).catalog;
    final p = widget.id == null ? null : catalog.profilesData[widget.id];
    _d = Profile(
      id: 'draft',
      name: p?.name ?? '',
      sources: [...?p?.sources],
      nodes: [...?p?.nodes],
      inAuto: p?.inAuto ?? true,
      pickMode: p?.pickMode ?? 'fastest',
      pickOrder: [...?p?.pickOrder],
    );
    _name = TextEditingController(text: _d.name);
    // show where the single picks are
    for (final sid in catalog.profileDraftSourceIds(_d)) {
      if (catalog.profileDraftSourceState(_d, sid) == PickState.some) {
        _open.add(sid);
        break;
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final host = CoreHostScope.read(context);
    final problem = host.saveProfile(
      ProfileDraft(
        id: widget.id,
        name: _name.text.trim(),
        sources: _d.sources,
        nodes: _d.nodes,
        inAuto: _d.inAuto,
        pickMode: _d.pickMode,
        pickOrder: _d.pickOrder,
      ),
    );
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final l10n = context.l10n;
    final editing = widget.id != null;
    final warn = profileWarn(l10n, catalog, _d);
    final priority = _d.pickMode == 'priority';
    final refs = catalog.orderRefs(catalog.profileNodeRefs(_d), _d.pickOrder);
    return SheetFrame(
      title: editing ? l10n.editProfile : l10n.createProfile,
      titleBadge: const NodesHelpButton(NodesHelp.profile),
      full: true,
      footer: [
        if (warn != null) WarnNote(warn),
        if (warn == null && _error != null) WarnNote(_error!),
        PrimaryButton(
          label: editing ? l10n.saveChanges : l10n.createProfile,
          onPressed: warn == null ? _save : null,
        ),
        if (editing)
          DangerTextButton(
            label: l10n.deleteProfile,
            onPressed: () {
              Navigator.of(context).pop();
              if (widget.page.mounted) {
                confirmDeleteEntry(widget.page, widget.id!);
              }
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            label: l10n.name,
            child: AppTextField(controller: _name, hint: l10n.newProfile),
          ),
          FormGroup(
            label: l10n.subscriptionsServers,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: HintText(l10n.tickASubscriptionToTakeAll),
          ),
          const SizedBox(height: 8),
          for (final sid in catalog.profileDraftSourceIds(_d))
            _SourcePickCard(
              source: catalog.sourcesData[sid]!,
              draft: _d,
              open: _open.contains(sid),
              priority: priority,
              onToggleOpen: () => setState(
                () => _open.contains(sid) ? _open.remove(sid) : _open.add(sid),
              ),
              onOpen: () => setState(() => _open.add(sid)),
              onTick: () =>
                  setState(() => catalog.toggleProfileDraftSource(_d, sid)),
              onTickNode: (nid) =>
                  setState(() => catalog.toggleProfileDraftNode(_d, sid, nid)),
            ),
          FormGroup(
            label: l10n.connectThrough,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PickModeSwitch(
                  priority: priority,
                  onChanged: (p) =>
                      setState(() => _d.pickMode = p ? 'priority' : 'fastest'),
                  trailing: PingAllButton(
                    tooltip: l10n.testLatencyOfAllItsServers,
                    onTap: () => host.pingNodes([for (final r in refs) r.node]),
                  ),
                ),
                HintText(
                  priority
                      ? l10n.theFirstWorkingServerFromThe3
                      : l10n.theProfileConnectsThroughTheFastest,
                ),
              ],
            ),
          ),
          if (priority)
            NodesBox(
              child: refs.isEmpty
                  ? EmptyLine(l10n.pickServersAbove)
                  : PickRows(
                      refs: refs,
                      orderable: true,
                      isOn: (_) => true,
                      onTap: (_) {},
                      protoOf: (r) => catalog.sourcesData[r.sid]?.name,
                      onReorder: (keys) => setState(
                        () => catalog.reorderProfileDraftPick(_d, keys),
                      ),
                    ),
            ),
          SetGroup(
            children: [
              SetRow(
                label: l10n.useInAuto,
                hint: l10n.autoMayConnectThisProfileIn,
                trailing: MiniToggle(
                  on: _d.inAuto,
                  onChanged: (v) => setState(() => _d.inAuto = v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `.ps-card`: a source in the profile editor - tick = the whole source, tap the name for its
/// servers and tick single ones.
class _SourcePickCard extends StatelessWidget {
  const _SourcePickCard({
    required this.source,
    required this.draft,
    required this.open,
    required this.priority,
    required this.onToggleOpen,
    required this.onOpen,
    required this.onTick,
    required this.onTickNode,
  });

  final Source source;
  final Profile draft;
  final bool open;
  final bool priority;
  final VoidCallback onToggleOpen;
  final VoidCallback onOpen;
  final VoidCallback onTick;
  final void Function(String nid) onTickNode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final s = source;
    final state = catalog.profileDraftSourceState(draft, s.id);
    final check = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTick,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: SubCheckbox(state: state),
      ),
    );

    if (!s.enabled) {
      return _Frame(
        border: c.muted.tint(.55),
        child: Row(
          children: [
            check,
            Expanded(
              child: Opacity(
                opacity: .6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _nameStyle(c),
                      ),
                      MetaLine(
                        parts: [
                          Text(
                            l10n.offInNodes,
                            style: TextStyle(color: c.muted),
                          ),
                          Text(l10n.tapTheBoxToDropIt),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final live = catalog.liveNodes(s);
    final alive = live.where(catalog.pings.isAlive).length;
    final picked = state == PickState.all
        ? live.length
        : live.where((n) => draft.nodes.contains('${s.id}::${n.id}')).length;
    final rows = open
        ? (priority
              ? catalog.sortedNodes<CatalogNode>(live, host.nodeSort, (n) => n)
              : catalog.byPing<CatalogNode>(live, (n) => n))
        : const <CatalogNode>[];
    bool isOn(String nid) =>
        state == PickState.all || draft.nodes.contains('${s.id}::$nid');

    return _Frame(
      border: state != PickState.none ? c.accent.tint(.45) : c.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              check,
              Expanded(
                child: InkWell(
                  onTap: onToggleOpen,
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _nameStyle(c),
                              ),
                            ),
                            const SizedBox(width: 6),
                            AnimatedRotation(
                              turns: open ? .5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.expand_more,
                                size: 16,
                                color: c.t3,
                              ),
                            ),
                          ],
                        ),
                        MetaLine(
                          parts: [
                            Text(
                              s.kind == 'sub'
                                  ? l10n.subscription2
                                  : l10n.manual3,
                            ),
                            Text(
                              state == PickState.some
                                  ? l10n.ofNodes(picked, live.length)
                                  : l10n.nodesPlural(live.length),
                            ),
                            Text(l10n.alive('$alive')),
                            if (s.gone.isNotEmpty)
                              Text(
                                l10n.unavailable2('${s.gone.length}'),
                                style: TextStyle(color: c.warn),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (s.kind == 'sub')
                IconBtn(
                  kind: IconBtnKind.ghost,
                  tooltip: l10n.update,
                  onTap: () => host.updateSource(s.id),
                  icon: Spin(
                    spinning: host.isUpdating(s.id),
                    child: const Icon(Icons.refresh),
                  ),
                ),
              IconBtn(
                kind: IconBtnKind.ghost,
                tooltip: l10n.testLatency,
                onTap: () {
                  onOpen();
                  host.pingSource(s.id);
                },
                icon: const Icon(Icons.bolt),
              ),
              const SizedBox(width: 6),
            ],
          ),
          if (open)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final n in rows)
                    NodeRow(
                      node: n,
                      framed: true,
                      on: isOn(n.id),
                      onTap: () => onTickNode(n.id),
                      onPing: () => host.pingNodes([n]),
                    ),
                  GoneBlock(
                    refs: catalog.goneRefs(s.id),
                    isOn: (r) => isOn(r.node.id),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _nameStyle(AppColors c) =>
      TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.t1);
}

/// `.ps-card` frame.
class _Frame extends StatelessWidget {
  const _Frame({required this.border, required this.child});

  final Color border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }
}

// ── Chain ──

/// Create a chain on the Nodes tab [tab] (`simple` | `profiles`), or edit [id].
Future<void> showChainEditor(
  BuildContext context, {
  String? id,
  required String tab,
}) {
  final catalog = CoreHostScope.read(context).catalog;
  final mode = id == null ? tab : (catalog.modeOf(id) ?? tab);
  return showAppSheet<void>(
    context,
    builder: (_) => _ChainEditor(id: id, mode: mode, page: context),
  );
}

class _ChainEditor extends StatefulWidget {
  const _ChainEditor({
    required this.id,
    required this.mode,
    required this.page,
  });

  final String? id;
  final String mode;
  final BuildContext page;

  @override
  State<_ChainEditor> createState() => _ChainEditorState();
}

class _ChainEditorState extends State<_ChainEditor> {
  late final Chain _d;
  late final TextEditingController _name;
  late bool _inAuto;
  final _open = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final catalog = CoreHostScope.read(context).catalog;
    if (widget.id != null) {
      final c = catalog.chainsData[widget.id]!;
      _d = catalog.chainDraftOf(widget.id!);
      _name = TextEditingController(text: c.name);
      _inAuto = c.inAuto;
    } else {
      final ids = catalog.unitIdsOf(widget.mode);
      _d = catalog.newChainDraft(
        ids.isNotEmpty ? ids[0] : null,
        ids.length > 1 ? ids[1] : null,
      );
      _name = TextEditingController();
      _inAuto = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final problem = host.saveChain(
      ChainDraft(
        id: widget.id,
        mode: widget.mode,
        name: _name.text.trim(),
        inId: _d.inId,
        outId: _d.outId,
        inOff: _d.inOff,
        outOff: _d.outOff,
        exitMode: _d.exitMode,
        exitOrder: _d.exitOrder,
        inAuto: _inAuto,
      ),
    );
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(
        () => _error = problem == 'Entry and exit must be different'
            ? l10n.entryAndExitMustBeDifferent
            : problem,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final l10n = context.l10n;
    final editing = widget.id != null;
    final warns = chainWarns(l10n, catalog, _d);
    final priority = _d.exitMode == 'priority';
    final ready = _d.inId != null && _d.outId != null;
    return SheetFrame(
      title: editing ? l10n.editChain : l10n.createChain,
      titleBadge: const NodesHelpButton(NodesHelp.chain),
      full: true,
      footer: [
        if (warns.isNotEmpty) WarnNote(warns.join('. ')),
        if (warns.isEmpty && _error != null) WarnNote(_error!),
        PrimaryButton(
          label: editing ? l10n.saveChanges : l10n.createChain,
          onPressed: warns.isEmpty && ready ? _save : null,
        ),
        if (editing)
          DangerTextButton(
            label: l10n.deleteChain,
            onPressed: () {
              Navigator.of(context).pop();
              if (widget.page.mounted) {
                confirmDeleteEntry(widget.page, widget.id!);
              }
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            label: l10n.name,
            child: AppTextField(controller: _name, hint: l10n.newChain),
          ),
          FormGroup(
            label: l10n.entryFirstHop,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
            child: const SizedBox.shrink(),
          ),
          _side('in'),
          FormGroup(
            label: l10n.exitWhereTrafficLeaves,
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PickModeSwitch(
                  priority: priority,
                  onChanged: (p) => setState(() {
                    _d.exitMode = p ? 'priority' : 'fastest';
                    if (p && _d.outId != null) _open.add('out:${_d.outId}');
                  }),
                  trailing: PingAllButton(
                    tooltip: l10n.testLatencyOfTheExitServers,
                    onTap: () => host.pingNodes([
                      for (final r in catalog.chainExitRefs(_d)) r.node,
                    ]),
                  ),
                ),
                HintText(
                  priority
                      ? l10n.theFirstWorkingServerFromThe
                      : l10n.theFastestSelectedServerOfThe,
                ),
              ],
            ),
          ),
          _side('out'),
          FormGroup(
            label: l10n.routeCheck,
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 4),
            child: const SizedBox.shrink(),
          ),
          RouteCheck(draft: _d),
          SetGroup(
            children: [
              SetRow(
                label: l10n.useInAuto,
                hint: l10n.autoMayConnectThisChainIn,
                trailing: MiniToggle(
                  on: _inAuto,
                  onChanged: (v) => setState(() => _inAuto = v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `#cc-in-list` / `#cc-out-list`: one row per unit of the tab; the chosen one expands to its
  /// servers.
  Widget _side(String side) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final l10n = context.l10n;
    final c = context.colors;
    final current = side == 'in' ? _d.inId : _d.outId;
    final other = side == 'in' ? _d.outId : _d.inId;
    final off = side == 'in' ? _d.inOff : _d.outOff;
    final priority = side == 'out' && _d.exitMode == 'priority';
    final ids = [...catalog.unitIdsOf(widget.mode)];
    if (current != null &&
        !ids.contains(current) &&
        (catalog.sourcesData.containsKey(current) ||
            catalog.profilesData.containsKey(current))) {
      ids.add(current); // an end switched off in Nodes
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in ids)
          () {
            final taken = id == other;
            final key = '$side:$id';
            final open = _open.contains(key);
            final active = id == current;
            final all = catalog.unitRefs(id);
            final nOn = active
                ? all.where((r) => !off.contains(r.key)).length
                : all.length;
            final n = active
                ? (side == 'in'
                      ? catalog.chainEntryNode(_d)
                      : catalog.chainExitNode(_d))
                : catalog.unitNode(id);
            final broken = catalog.isBroken(id);
            final String sub = broken
                ? l10n.offInNodes
                : taken
                ? (side == 'in'
                      ? l10n.usedAsExitTapToSwap
                      : l10n.usedAsEntryTapToSwap)
                : '${n == null ? '' : '${n.flag} '}${nOn < all.length ? l10n.ofNodes(nOn, all.length) : l10n.nodesPlural(all.length)}';
            final List<NodeRef> list = active && priority
                ? catalog.chainExitOrder(_d)
                : catalog.byPing<NodeRef>(all, (r) => r.node);
            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Opacity(
                      opacity: taken ? .6 : 1,
                      child: InkWell(
                        onTap: () => setState(() {
                          if (taken) {
                            catalog.chainSwapEnds(_d);
                          } else {
                            catalog.chainPickSide(_d, side, id);
                          }
                        }),
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: c.t1.tint(.03),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 9, 48, 9),
                          child: Row(
                            children: [
                              ProfileRadio(active: active),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  catalog.unitName(id),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: broken ? c.t3 : c.t1,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                flex: 2,
                                child: Text(
                                  sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoText.copyWith(
                                    fontSize: 13,
                                    color: broken ? c.muted : c.t2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (open)
                      NodesBox(
                        margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (active && all.isNotEmpty)
                              Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: c.border),
                                  ),
                                ),
                                child: SelectionBar(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    6,
                                    10,
                                    6,
                                  ),
                                  count: Text(l10n.ofSelected(nOn, all.length)),
                                  chip: nOn == all.length
                                      ? l10n.none
                                      : l10n.all,
                                  onChip: () => setState(
                                    () => catalog.chainSetNodesAll(_d, side),
                                  ),
                                ),
                              ),
                            if (list.isEmpty)
                              EmptyLine(l10n.noEnabledNodes)
                            else if (active)
                              PickRows(
                                refs: list,
                                orderable: priority,
                                isOn: (r) => !off.contains(r.key),
                                onTap: (r) => setState(
                                  () =>
                                      catalog.chainToggleNode(_d, side, r.key),
                                ),
                                onReorder: (keys) => setState(
                                  () => catalog.chainReorderExit(_d, keys),
                                ),
                              )
                            else
                              for (final r in list)
                                NodeRow(
                                  node: r.node,
                                  onPing: () => host.pingNodes([r.node]),
                                ),
                            if (active)
                              GoneBlock(
                                refs: catalog.unitGoneRefs(id),
                                isOn: (r) => !off.contains(r.key),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (all.length > 1)
                  Positioned(
                    right: 8,
                    top: 4,
                    child: IconBtn(
                      kind: IconBtnKind.ghost,
                      tooltip: l10n.showNodes,
                      onTap: () => setState(
                        () => open ? _open.remove(key) : _open.add(key),
                      ),
                      icon: AnimatedRotation(
                        turns: open ? .5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.expand_more),
                      ),
                    ),
                  ),
              ],
            );
          }(),
      ],
    );
  }
}

