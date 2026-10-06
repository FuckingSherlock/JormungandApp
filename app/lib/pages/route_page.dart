import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogDrafts, CatalogNode, OffReason;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_sheet.dart';
import '../widgets/catalog_card.dart' show GripHandle;
import '../widgets/entry_editors.dart';
import '../widgets/form_parts.dart';
import '../widgets/latency_text.dart';
import '../widgets/node_row.dart';
import '../widgets/pick_parts.dart';
import '../widgets/source_entry_sheet.dart';

/// The Route sheet (mockup markup/50-sheets-connect.html, js/20-profiles.js): the entries Auto
/// picks from, in the order it tries them. The Simple / Profiles switch (which tab of Nodes the
/// route uses), the Auto / Manual badge, a row per entry (AUTO / MANUAL button, tap to unfold its
/// servers, tap a server to use only it), ✎ for the order, the Use in Auto switches and
/// Fastest / Priority. Everything is created and edited in Nodes; this only picks.
///
/// The Simple / Profiles switcher only VIEWS a mode (the dot marks the one the route uses now);
/// another mode gets a "Use this mode" button, and a mode with nothing in it an empty state that
/// leads to creating something, so the switch is explicit and never a dead end.
///
/// All the logic is the core's (`Catalog` Route ops through the [CoreHost]); this is the view.
Future<void> showRouteSheet(
  BuildContext context, {
  bool edit = false,
  String? mode,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) => RouteSheet(edit: edit, mode: mode),
  );
}

class RouteSheet extends StatefulWidget {
  const RouteSheet({super.key, this.edit = false, this.mode});

  /// Opens in edit mode (the "Nothing in Auto" alert).
  final bool edit;

  /// The mode to look at first (`simple` / `profiles`); null = the one the route uses.
  final String? mode;

  @override
  State<RouteSheet> createState() => _RouteSheetState();
}

class _RouteSheetState extends State<RouteSheet> {
  late bool _edit = widget.edit;

  /// The mode on screen; null = the one the route uses (follows it).
  late String? _view = widget.mode;

  /// Unfolded rows: each on its own, unfolding one never folds another.
  final _open = <String>{};

  /// Where the list slides in from after the mode switch (+1 = from the right).
  int _swap = 1;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final c = context.colors;
    final broken = catalog.brokenOrder();
    final visible = catalog.visibleOrder();
    final view = _view ?? catalog.connectMode;
    final used = view == catalog.connectMode; // what is on screen is what the route uses
    return SheetFrame(
      title: l10n.route,
      full: true,
      titleBadge: _HelpButton(onTap: () => _showHelp(context)),
      headerActions: [
        if (used)
          _AutoBadge(auto: catalog.autoConnect, onTap: () => host.setAutoMode(!catalog.autoConnect)),
      ],
      subHeader: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
        child: Row(
          children: [
            // the order and the Fastest / Priority are the active mode's: not for a mode only viewed
            Opacity(
              opacity: used ? 1 : .35,
              child: IgnorePointer(
                ignoring: !used,
                child: IconBtn(
                  tooltip: _edit && used ? l10n.done : l10n.editPriorityOrderFastestPriority,
                  active: _edit && used,
                  activeColor: c.active,
                  onTap: () => setState(() => _edit = !_edit),
                  icon: Icon(_edit && used ? Icons.check : Icons.edit_outlined, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeSwitch(
                mode: view,
                used: catalog.connectMode,
                onChanged: (m) {
                  if (m == view) return;
                  // only what is shown changes; the route switches with "Use this mode"
                  setState(() {
                    _swap = m == 'profiles' ? 1 : -1;
                    _view = m;
                  });
                },
              ),
            ),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (used)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.priority.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .6,
                    color: c.t3,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: _edit
                      ? Text(
                          l10n.orderSwitchInAuto,
                          textAlign: TextAlign.end,
                          style: TextStyle(fontSize: 12, color: c.t3),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, size: 13, color: c.t3),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                l10n.pingItsServers,
                                style: TextStyle(fontSize: 12, color: c.t3),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: Offset(_swap * .05, 0),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey('$view/$used'),
              child: used
                  ? _list(context, host, visible)
                  : _OtherMode(
                      mode: view,
                      onUse: () => host.setConnectMode(view),
                      onCreate: () => _create(context, view),
                    ),
            ),
          ),
          if (used && broken.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.only(top: 8),
              child: CustomPaint(
                painter: _DashedTop(c.border),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    children: [
                      for (final (i, id) in broken.indexed)
                        Padding(
                          padding: EdgeInsets.only(top: i > 0 ? 4 : 0),
                          child: _BrokenRow(id: id, edit: _edit, onTap: () => _explainBroken(context, id)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (used)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: _note(context, host),
            ),
        ],
      ),
    );
  }

  /// "Create profile" / "Add subscription or server" of an empty mode: Nodes at its "+".
  void _create(BuildContext context, String mode) {
    final open = AppLinksScope.of(context).openNodesAdd;
    if (open == null) return;
    Navigator.of(context).pop();
    open(tab: mode);
  }

  Widget _note(BuildContext context, CoreHost host) {
    final l10n = context.l10n;
    final c = context.colors;
    final catalog = host.catalog;
    final style = TextStyle(fontSize: 12, color: c.t3);
    if (catalog.routeCustom[catalog.connectMode] ?? false) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(l10n.ownPriorityOrder, style: style)),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: host.resetRouteOrder,
            child: Text(
              l10n.followNodesOrder,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent),
            ),
          ),
        ],
      );
    }
    return Text(
      _edit
          ? '${l10n.priorityFollowsTheOrderInNodes2} ${l10n.dragHereToOverrideIt}'
          : l10n.priorityFollowsTheOrderInNodes,
      style: style,
    );
  }

  Widget _list(BuildContext context, CoreHost host, List<String> visible) {
    final l10n = context.l10n;
    final c = context.colors;
    final catalog = host.catalog;
    if (visible.isEmpty) {
      if (catalog.modeEmpty(catalog.connectMode)) {
        return _EmptyMode(
          mode: catalog.connectMode,
          onCreate: () => _create(context, catalog.connectMode),
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Text(
          catalog.simpleMode
              ? l10n.noEnabledSubscriptionsOrServersAdd
              : l10n.noWorkingProfilesCreateOneIn,
          style: TextStyle(fontSize: 13, color: c.t3),
        ),
      );
    }
    Widget row(int i) => Padding(
      key: ValueKey(visible[i]),
      padding: EdgeInsets.only(top: i > 0 ? 2 : 0),
      child: _EntryRow(
        id: visible[i],
        index: i,
        edit: _edit,
        open: _open.contains(visible[i]),
        onToggleOpen: () => setState(() {
          if (!_open.remove(visible[i])) _open.add(visible[i]);
        }),
      ),
    );
    if (!_edit) {
      return Column(children: [for (var i = 0; i < visible.length; i++) row(i)]);
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: visible.length,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      onReorderItem: (from, to) {
        final next = [...visible];
        next.insert(to, next.removeAt(from));
        host.reorderRoute(next);
      },
      itemBuilder: (context, i) => row(i),
    );
  }

  // ── help ──

  void _showHelp(BuildContext context) {
    final l10n = context.l10n;
    final items = [
      (l10n.simpleProfiles, l10n.whichTabOfNodesTheRoute2),
      ('Auto', l10n.connectsTheFirstWorkingEntryFrom),
      (l10n.manual, l10n.tapManualOnAnEntryTo),
      (l10n.edit2, l10n.showsDragThemToChangeThe),
      (l10n.switchIn, l10n.letsAutoPickTheEntryOr),
      (l10n.oneServer, l10n.tapAServerOfAnUnfolded),
      (l10n.ownOrder, l10n.byDefaultTheOrderIsThe),
      (l10n.chain, l10n.trafficGoesThroughTwoServersThe),
      (l10n.greyedOutBelow, l10n.somethingItNeedsIsSwitchedOff),
    ];
    showAppSheet<void>(
      context,
      builder: (sheet) {
        final c = sheet.colors;
        return SheetFrame(
          title: l10n.route,
          bodyPadding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (term, text) in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: term,
                          style: TextStyle(fontWeight: FontWeight.w600, color: c.t1),
                        ),
                        TextSpan(text: ' — $text'),
                      ],
                    ),
                    style: TextStyle(fontSize: 14, height: 1.45, color: c.t2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ── a broken entry ──

  void _explainBroken(BuildContext context, String id) {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final catalog = host.catalog;
    final rs = catalog.brokenBy(id);
    final isChain = catalog.chainsData[id] != null;
    final isProfile = catalog.profilesData[id] != null;
    final kind = isChain ? l10n.chain2 : isProfile ? l10n.profile2 : l10n.entry2;
    final many = rs.length > 1;
    final what = rs.any((r) => r.nid == null)
        ? (rs.any((r) => r.nid != null)
              ? l10n.sourcesAndServersItUsesAre
              : many
              ? l10n.sourcesItUsesAre
              : l10n.sourceItUsesIs)
        : many
        ? l10n.serversItUsesAre
        : l10n.serverItUsesIs;
    final entry = catalog.connectEntry(id);
    showAppSheet<void>(
      context,
      builder: (sheet) => SheetFrame(
        title: entry?.name ?? id,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuNote(
              '${l10n.thisHasNothingToConnectThrough(kind)} $what ${l10n.switchedOffInNodes} '
              '${l10n.switchOnOrSelectAnotherServer(many ? 'one' : 'it', kind)}',
            ),
            for (final r in rs) _switchOnRow(sheet, host, r),
            MenuRow(
              icon: const Icon(Icons.edit_outlined),
              label: isChain
                  ? l10n.editChain
                  : isProfile
                  ? l10n.editProfile
                  : l10n.editEntry,
              onTap: () {
                Navigator.of(sheet).pop();
                if (isChain) {
                  showChainEditor(context, id: id, tab: catalog.modeOf(id) ?? catalog.connectMode);
                } else if (isProfile) {
                  showProfileEditor(context, id: id);
                } else {
                  showSourceEntry(context, id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchOnRow(BuildContext sheet, CoreHost host, OffReason r) {
    final l10n = sheet.l10n;
    final catalog = host.catalog;
    return MenuRow(
      icon: const Icon(Icons.power_settings_new),
      label: '${l10n.switchOn} ${catalog.reasonLabel(r)}',
      sub: r.nid != null ? catalog.sourcesData[r.sid]?.name : null,
      onTap: () {
        Navigator.of(sheet).pop();
        if (r.nid != null) {
          host.toggleNodeEnabled(r.sid, r.nid!);
        } else {
          host.toggleSourceEnabled(r.sid);
        }
      },
    );
  }
}

// ── header pieces ──

/// The round ? after the title.
class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 4, 4, 4),
        child: Tooltip(
          message: context.l10n.whatIsThis,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.borderHi),
            ),
            child: Text(
              '?',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 1, color: c.t3),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.auto-badge`: Auto (accent) or Manual (muted); a tap flips it.
class _AutoBadge extends StatelessWidget {
  const _AutoBadge({required this.auto, required this.onTap});

  final bool auto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final color = auto ? c.accent : c.muted;
    return Tooltip(
      message: l10n.autoFirstWorkingEntryInList,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: color.tint(auto ? .12 : .10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.tint(auto ? .3 : .22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                auto ? 'Auto' : l10n.manual,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
              ),
              const SizedBox(width: 6),
              DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 6, height: 6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.route-modes`: Simple / Profiles with a sliding ink. The ink is the mode on screen, the dot
/// the one the route uses ([used]), like the Nodes tabs.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.used, required this.onChanged});

  final String mode;
  final String used;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    Widget side(String id, String label) => Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 250),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: mode == id ? onAccentOf(context) : c.t2,
                    ),
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (used == id) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: l10n.theRouteUsesThisTabNow,
                    child: DecoratedBox(
                      key: ValueKey('route-used-$id'),
                      decoration: BoxDecoration(
                        color: mode == id ? onAccentOf(context) : c.active,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: 6, height: 6),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Tooltip(
      message: l10n.whichTabOfNodesTheRoute,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 280),
                curve: const Cubic(.32, 1, .4, 1),
                alignment: mode == 'simple' ? Alignment.centerLeft : Alignment.centerRight,
                child: FractionallySizedBox(
                  widthFactor: .5,
                  heightFactor: 1,
                  child: ColoredBox(color: c.accent),
                ),
              ),
            ),
            Row(children: [side('simple', l10n.simple), side('profiles', l10n.profiles)]),
          ],
        ),
      ),
    );
  }
}

/// A mode that only is viewed (the route uses the other): the "Use this mode" bar and what is in
/// it, read-only; nothing in it = [_EmptyMode].
class _OtherMode extends StatelessWidget {
  const _OtherMode({required this.mode, required this.onUse, required this.onCreate});

  final String mode;
  final VoidCallback onUse;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    if (catalog.modeEmpty(mode)) return _EmptyMode(mode: mode, onCreate: onCreate);
    final usedLabel = catalog.simpleMode ? l10n.simple : l10n.profiles;
    final ids = catalog.modeOrder(mode).where(catalog.entryVisible).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('route-use-bar'),
          margin: const EdgeInsets.fromLTRB(14, 6, 14, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.theRouteUsesNow(usedLabel),
                style: TextStyle(fontSize: 13, color: c.t2),
              ),
              const SizedBox(height: 10),
              PrimaryButton(label: l10n.useThisMode, onPressed: onUse),
            ],
          ),
        ),
        for (final id in ids) _PreviewRow(id: id),
      ],
    );
  }
}

/// A row of a mode that is not the route's: the name and what is in it, nothing to tap.
class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    final e = catalog.connectEntry(id);
    if (e == null) return const SizedBox.shrink();
    final isChain = catalog.chainsData[id] != null;
    return Opacity(
      opacity: catalog.isBroken(id) ? .5 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 9, 20, 9),
        child: Row(
          children: [
            Flexible(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.t1),
              ),
            ),
            const SizedBox(width: 8),
            if (isChain)
              ConnTag(l10n.chain2)
            else
              Text(
                l10n.nodesPlural(catalog.unitRefs(id).length),
                maxLines: 1,
                style: TextStyle(fontSize: 13, color: c.t3),
              ),
          ],
        ),
      ),
    );
  }
}

/// A mode with nothing to connect through: no profiles / no servers, and the way to make one
/// (Nodes at its "+"), never a dead end.
class _EmptyMode extends StatelessWidget {
  const _EmptyMode({required this.mode, required this.onCreate});

  final String mode;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final simple = mode == 'simple';
    final wired = AppLinksScope.of(context).openNodesAdd != null;
    return Padding(
      key: ValueKey('route-empty-$mode'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            simple ? l10n.noServersYet : l10n.noProfilesYet,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.t2),
          ),
          if (wired) ...[
            const SizedBox(height: 14),
            PrimaryButton(
              label: simple ? l10n.addSubscriptionOrServer : l10n.createProfile,
              onPressed: onCreate,
            ),
          ],
        ],
      ),
    );
  }
}

class _DashedTop extends CustomPainter {
  const _DashedTop(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 10.0; x < size.width - 10; x += 6) {
      canvas.drawLine(Offset(x, 0), Offset(x + 3, 0), p);
    }
  }

  @override
  bool shouldRepaint(_DashedTop old) => old.color != color;
}

// ── rows ──

/// `.conn-row`: one entry of the route.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.id,
    required this.index,
    required this.edit,
    required this.open,
    required this.onToggleOpen,
  });

  final String id;
  final int index;
  final bool edit;
  final bool open;
  final VoidCallback onToggleOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final e = catalog.connectEntry(id);
    if (e == null) return const SizedBox.shrink();
    final isChain = catalog.chainsData[id] != null;
    final current = id == catalog.effectiveConnectId();
    final auto = catalog.autoConnect;
    final skip = auto && !e.inAuto;
    final src = catalog.sourcesData[id];
    final off = src == null ? 0 : catalog.offCount(src);

    final tags = <Widget>[
      if (isChain)
        ConnTag(l10n.chain2)
      else if (off > 0)
        ConnTag(l10n.off3('$off'), tone: TagTone.muted),
      if (auto && !e.inAuto && !edit) ConnTag(l10n.notInAuto, tone: TagTone.muted),
    ];

    final main = Opacity(
      opacity: skip ? .5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StateButton(
                  on: current,
                  label: current && auto ? l10n.auto2 : l10n.manual3,
                  tooltip: current && !auto ? l10n.backToAuto : l10n.useOnlyThisOneManual,
                  onTap: () => host.selectConnect(id),
                ),
                if (edit) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: l10n.useInAutoAutoMayPick,
                    child: MiniToggle(on: e.inAuto, onChanged: (v) => host.setEntryInAuto(id, v)),
                  ),
                ],
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.t1),
                  ),
                ),
                for (final t in tags) ...[const SizedBox(width: 8), t],
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: _Summary(id: id),
            ),
          ],
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      decoration: BoxDecoration(
        color: current ? c.active.tint(.07) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: current ? c.active.tint(.35) : Colors.transparent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (edit)
                Transform.translate(
                  offset: const Offset(-8, 0),
                  child: ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: l10n.dragToSetAutoPriority,
                      child: const SizedBox(width: 26, height: 40, child: Center(child: GripHandle())),
                    ),
                  ),
                ),
              Expanded(
                child: InkWell(
                  onTap: isChain ? null : onToggleOpen,
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  child: Padding(
                    padding: EdgeInsets.only(left: edit ? 0 : 2),
                    child: main,
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 34),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PingAllButton(
                    tooltip: l10n.pingItsServers2,
                    onTap: () => host.pingEntry(id),
                  ),
                ),
              ),
            ],
          ),
          if (!isChain && open) _Body(id: id, edit: edit),
        ],
      ),
    );
  }
}

/// `.conn-state`: the AUTO / MANUAL button of a row.
class _StateButton extends StatelessWidget {
  const _StateButton({
    required this.on,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final bool on;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 54,
          padding: const EdgeInsets.symmetric(vertical: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? c.active.tint(.12) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? c.active.tint(.45) : c.border),
          ),
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            style: TextStyle(
              fontSize: 9.5,
              height: 13 / 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: .3,
              color: on ? c.active : c.t3,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.conn-sub`: the server the entry connects through now, or "entry -> exit" of a chain.
class _Summary extends StatelessWidget {
  const _Summary({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    final style = TextStyle(fontSize: 13, height: 1.3, color: c.t2);
    Widget node(CatalogNode n) => Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '${n.flag} ', style: const TextStyle(fontSize: 11)),
          TextSpan(text: n.name),
        ],
      ),
      style: style,
    );
    final chain = catalog.chainsData[id];
    if (chain != null) {
      Widget end(String? uid, CatalogNode? n) => Text.rich(
        TextSpan(
          children: [
            if (n != null) TextSpan(text: '${n.flag} ', style: const TextStyle(fontSize: 11)),
            TextSpan(text: catalog.unitName(uid)),
          ],
        ),
        style: style,
      );
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 2,
        children: [
          end(chain.inId, catalog.chainEntryNode(chain)),
          Text('→', style: TextStyle(fontSize: 13, color: c.t3)),
          if (chain.exitMode == 'priority') ConnTag(l10n.priority.toLowerCase(), tone: TagTone.muted),
          end(chain.outId, catalog.chainExitNode(chain)),
        ],
      );
    }
    final n = catalog.unitNode(id);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 2,
      children: [
        if (catalog.unitPriority(id)) ConnTag(l10n.priority.toLowerCase(), tone: TagTone.muted),
        if (n == null) Text(l10n.noWorkingNodes, style: style) else ...[node(n), LatencyText(n)],
      ],
    );
  }
}

/// `.conn-body`: the unfolded servers of an entry, with Fastest / Priority in edit mode.
class _Body extends StatelessWidget {
  const _Body({required this.id, required this.edit});

  final String id;
  final bool edit;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final priority = catalog.unitPriority(id);
    final refs = priority
        ? catalog.unitPickRefs(id)
        : catalog.byPing(catalog.unitRefs(id), (r) => r.node);
    final pin = catalog.pinnedRef(id);
    final subs = {
      for (final r in catalog.unitRefs(id, withOff: true))
        if (catalog.sourcesData[r.sid]?.kind == 'sub') r.sid,
    };
    final updating = subs.any(host.isUpdating);
    final update = subs.isEmpty
        ? null
        : IconBtn(
            kind: IconBtnKind.ghost,
            tooltip: l10n.update,
            onTap: () {
              for (final sid in subs) {
                host.updateSource(sid);
              }
            },
            icon: Spin(spinning: updating, child: const Icon(Icons.refresh)),
          );
    final hint = pin != null
        ? l10n.manualOnlyTheHighlightedServer
        : priority
        ? l10n.theFirstWorkingOneFromThe + (edit ? ' ${l10n.dragToOrder}' : '')
        : l10n.connectsThroughTheFastestOfThem;

    var rank = 0;
    final ranks = [for (final _ in refs) priority ? ++rank : null];

    Widget row(int i) {
      final r = refs[i];
      final pinned = pin != null && pin.key == r.key;
      return Container(
        key: ValueKey(r.key),
        decoration: pinned
            ? BoxDecoration(
                color: c.warn.tint(.12),
                border: Border(left: BorderSide(color: c.warn, width: 3)),
              )
            : null,
        child: NodeRow(
          node: r.node,
          topBorder: i > 0,
          lead: priority
              ? [
                  if (edit)
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
          onTap: () => host.pinRouteNode(id, r.key),
          onPing: () => host.pingNodes([r.node]),
        ),
      );
    }

    final Widget list;
    if (refs.isEmpty) {
      list = Padding(
        padding: const EdgeInsets.all(10),
        child: Text(l10n.noServers, style: TextStyle(fontSize: 13, color: c.t3)),
      );
    } else if (priority && edit) {
      list = ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: refs.length,
        proxyDecorator: (child, index, animation) =>
            Material(type: MaterialType.transparency, child: child),
        onReorderItem: (from, to) {
          final keys = [for (final r in refs) r.key];
          keys.insert(to, keys.removeAt(from));
          host.reorderPick(id, keys);
        },
        itemBuilder: (context, i) => row(i),
      );
    } else {
      list = Column(children: [for (var i = 0; i < refs.length; i++) row(i)]);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (edit) ...[
            PickModeSwitch(
              priority: priority,
              onChanged: (p) => host.setPickMode(id, p ? 'priority' : 'fastest'),
              trailing: update,
            ),
            HintText(hint),
          ] else
            Row(
              children: [
                Expanded(child: HintText(hint)),
                ?update,
              ],
            ),
          list,
        ],
      ),
    );
  }
}

/// `.conn-row.broken`: an entry with nothing to connect through; a tap says what to switch on.
class _BrokenRow extends StatelessWidget {
  const _BrokenRow({required this.id, required this.edit, required this.onTap});

  final String id;
  final bool edit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final catalog = CoreHostScope.of(context).catalog;
    final e = catalog.connectEntry(id);
    if (e == null) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.t1.tint(.04),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        margin: const EdgeInsets.symmetric(horizontal: 10),
        padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.muted.tint(.55)),
        ),
        child: Row(
          children: [
            if (edit) const SizedBox(width: 18),
            Expanded(
              child: Opacity(
                opacity: .5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.t1),
                            ),
                          ),
                          if (catalog.chainsData[id] != null) ...[
                            const SizedBox(width: 8),
                            ConnTag(l10n.chain2),
                          ],
                          const SizedBox(width: 8),
                          ConnTag(l10n.off2, tone: TagTone.off),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          catalog.reasonsText(catalog.brokenBy(id)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: c.t2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
