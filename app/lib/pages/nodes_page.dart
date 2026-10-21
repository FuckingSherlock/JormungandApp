import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show Catalog, CatalogNode;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_view.dart';
import '../widgets/catalog_card.dart';
import '../widgets/entry_card.dart';
import '../widgets/form_parts.dart';
import '../widgets/nodes_forms.dart';
import '../widgets/nodes_help.dart';
import '../widgets/nodes_menus.dart';
import '../widgets/entry_editors.dart';
import '../widgets/source_card.dart';

/// Nodes tab (mockup markup/20-nodes.html, 30-nodes.js, 31-catalog.js): the catalog. Two tabs,
/// Simple (subscriptions, manual groups and their chains) and Profiles (profiles and their
/// chains), swipeable; the header has search, ping all, the menu and Add. Edit mode (the pencil
/// left of the tabs): grips to reorder, switches for sources and servers.
///
/// The page owns only what is on screen (tab, edit, search, which cards are open); the catalog
/// is the [CoreHost]'s.
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => NodesPageState();
}

/// One key per card, so [NodesPageState.openEntry] can scroll to it.
final _cardKeys = <String, GlobalKey>{};

/// The same for the reorder list, whose cards are boxes: a GlobalKey cannot move an element between
/// a sliver and a box parent, so each list has its own.
final _boxKeys = <String, GlobalKey>{};

class NodesPageState extends State<NodesPage> {
  static const _tabs = ['simple', 'profiles'];

  final _pager = PageController();
  final _query = TextEditingController();
  final _open = <String, bool>{};
  String _tab = 'simple';
  bool _tabFromRoute = false;
  bool _edit = false;
  bool _searching = false;

  @override
  void dispose() {
    _pager.dispose();
    _query.dispose();
    super.dispose();
  }

  /// Shows [tab] (a tap or a swipe only changes what is shown, never the route).
  void showTab(String tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (_pager.hasClients) {
      _pager.animateToPage(
        _tabs.indexOf(tab),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  /// Opens the "+" of [tab] (Home leads here when there is nothing to connect through).
  void openAdd({String? tab}) {
    if (tab != null) showTab(tab);
    showNodesAdd(context, tab: tab ?? _tab, onOpenCard: _openCard);
  }

  /// The card of a source / profile / chain, on its tab, unfolded and brought into view (Logs
  /// "Open", the Route sheet's "Edit ...").
  void openEntry(String id) {
    final catalog = CoreHostScope.read(context).catalog;
    if (catalog.connectEntry(id) == null) return;
    setState(() {
      _searching = false;
      _query.clear();
      _open[id] = true;
    });
    // the tab the entry lives in: sources and Simple chains / profiles and Profiles chains
    showTab(catalog.sourcesData[id] != null ? 'simple' : catalog.modeOf(id) ?? 'profiles');
    for (final delay in const [60, 320]) {
      Future.delayed(Duration(milliseconds: delay), () {
        final ctx = _cardKeys[id]?.currentContext ?? _boxKeys[id]?.currentContext;
        if (mounted && ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: .1,
            duration: const Duration(milliseconds: 250),
          );
        }
      });
    }
  }

  void _openCard(String id) {
    if (mounted) setState(() => _open[id] = true);
  }

  void _toggleOpen(String id) =>
      setState(() => _open[id] = !(_open[id] ?? false));

  void _setAllOpen(bool open) {
    final catalog = CoreHostScope.read(context).catalog;
    setState(() {
      for (final id in catalog.catalogOrder[_tab] ?? const <String>[]) {
        _open[id] = open;
      }
    });
  }

  void _toggleSearch([bool? force]) {
    final on = force ?? !_searching;
    setState(() {
      _searching = on;
      if (!on) _query.clear();
    });
  }

  String get _q => _searching ? _query.text.trim().toLowerCase() : '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    if (!_tabFromRoute && host.ready) {
      // the tab the route uses is the one shown first
      _tabFromRoute = true;
      if (_tabs.contains(catalog.connectMode) && catalog.connectMode != _tab) {
        _tab = catalog.connectMode;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pager.hasClients) _pager.jumpToPage(_tabs.indexOf(_tab));
        });
      }
    }
    return AppView(
      title: l10n.nodes,
      titleBadge: const NodesHelpButton(NodesHelp.nodes),
      summary: _summary(context, catalog),
      actions: [
        IconBtn(
          tooltip: l10n.search,
          active: _searching,
          onTap: _toggleSearch,
          icon: const Icon(Icons.search, size: 19),
        ),
        const SizedBox(width: 8),
        IconBtn(
          tooltip: l10n.testLatency,
          onTap: () => host.pingAll(),
          icon: const Icon(Icons.bolt, size: 19),
        ),
        const SizedBox(width: 8),
        IconBtn(
          tooltip: l10n.more,
          onTap: () => showNodesMore(
            context,
            anyOpen: (catalog.catalogOrder[_tab] ?? const <String>[]).any(
              (id) => _open[id] ?? false,
            ),
            onSetAllOpen: _setAllOpen,
          ),
          icon: const Icon(Icons.more_horiz, size: 19),
        ),
        const SizedBox(width: 8),
        IconBtn(
          tooltip: l10n.add2,
          kind: IconBtnKind.primary,
          onTap: openAdd,
          icon: const Icon(Icons.add, size: 19),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_searching)
            _SearchBar(
              controller: _query,
              onChanged: (_) => setState(() {}),
              onClose: () => _toggleSearch(false),
            ),
          _TabsBar(
            pager: _pager,
            tab: _tab,
            usedTab: catalog.connectMode,
            edit: _edit,
            onEdit: () => setState(() => _edit = !_edit),
            onTab: showTab,
          ),
          Expanded(
            child: PageView(
              controller: _pager,
              onPageChanged: (i) => setState(() => _tab = _tabs[i]),
              children: [
                for (final tab in _tabs)
                  _TabList(
                    key: PageStorageKey(tab),
                    tab: tab,
                    query: _q,
                    edit: _edit,
                    open: _open,
                    onToggleOpen: _toggleOpen,
                    onOpenCard: _openCard,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _summary(BuildContext context, Catalog catalog) {
    final l10n = context.l10n;
    if (_tab == 'simple') {
      final total = catalog.sourceOrder.fold<int>(
        0,
        (sum, id) =>
            sum + (catalog.sourcesData[id]?.nodes.where((n) => n.usable).length ?? 0),
      );
      return '${l10n.sourcesPlural(catalog.sourceOrder.length)} · ${l10n.nodesPlural(total)}';
    }
    final p = catalog.getProfileIds().length;
    final c = (catalog.catalogOrder['profiles'] ?? const <String>[])
        .where(catalog.chainsData.containsKey)
        .length;
    return '${l10n.profilesPlural(p)} · ${l10n.chainsPlural(c)}';
  }
}

/// `.search`: the field under the header.
class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _focused ? c.accent : c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: c.t3),
          const SizedBox(width: 8),
          Expanded(
            child: Focus(
              onFocusChange: (f) => setState(() => _focused = f),
              child: TextField(
                controller: widget.controller,
                autofocus: true,
                onChanged: widget.onChanged,
                style: TextStyle(fontSize: 15, color: c.t1),
                cursorColor: c.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: l10n.searchNodes,
                  hintStyle: TextStyle(color: c.t3),
                ),
              ),
            ),
          ),
          IconBtn(
            kind: IconBtnKind.ghost,
            tooltip: l10n.closeSearch,
            onTap: widget.onClose,
            icon: const Icon(Icons.close, size: 15),
          ),
        ],
      ),
    );
  }
}

/// `.nodes-bar`: the edit button and the Simple / Profiles tabs with their ink.
class _TabsBar extends StatelessWidget {
  const _TabsBar({
    required this.pager,
    required this.tab,
    required this.usedTab,
    required this.edit,
    required this.onEdit,
    required this.onTab,
  });

  final PageController pager;
  final String tab;
  final String usedTab;
  final bool edit;
  final VoidCallback onEdit;
  final ValueChanged<String> onTab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    Widget button(String id, String label) => Expanded(
      child: Tooltip(
        message: '',
        child: InkWell(
          onTap: () => onTab(id),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tab == id ? c.t1 : c.t3,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: l10n.theRouteUsesThisTabNow,
                  child: Opacity(
                    opacity: usedTab == id ? 1 : 0,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.active,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Row(
        children: [
          IconBtn(
            tooltip: edit ? l10n.done : l10n.editReorderSwitchSourcesAndServers,
            active: edit,
            activeColor: c.active,
            onTap: onEdit,
            icon: Icon(edit ? Icons.check : Icons.edit_outlined, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Stack(
                children: [
                  Row(
                    children: [
                      button('simple', l10n.simple),
                      button('profiles', l10n.profiles),
                    ],
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -1,
                    child: AnimatedBuilder(
                      animation: pager,
                      builder: (context, _) {
                        final page =
                            pager.hasClients && pager.position.haveDimensions
                            ? (pager.page ?? 0).clamp(0, 1).toDouble()
                            : (tab == 'simple' ? 0.0 : 1.0);
                        return Align(
                          alignment: Alignment(-1 + page * 2, 0),
                          child: FractionallySizedBox(
                            widthFactor: .5,
                            child: Container(
                              height: 2,
                              decoration: BoxDecoration(
                                color: c.accent,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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

/// One tab's list of cards (`#nodes-list` / `#nodes-profiles`).
class _TabList extends StatelessWidget {
  const _TabList({
    super.key,
    required this.tab,
    required this.query,
    required this.edit,
    required this.open,
    required this.onToggleOpen,
    required this.onOpenCard,
  });

  final String tab;
  final String query;
  final bool edit;
  final Map<String, bool> open;
  final ValueChanged<String> onToggleOpen;
  final ValueChanged<String> onOpenCard;

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    final catalog = host.catalog;
    final searching = query.isNotEmpty;
    final ids = <String>[
      for (final id in catalog.catalogOrder[tab] ?? const <String>[])
        if (catalog.connectEntry(id) != null) id,
    ];
    // what each card shows under the search: null = the card is hidden
    final shown = <String, List<CatalogNode>?>{};
    for (final id in ids) {
      final s = catalog.sourcesData[id];
      if (s == null) {
        shown[id] = catalog.connectEntry(id)!.name.toLowerCase().contains(query)
            ? const []
            : null;
        continue;
      }
      // servers the core cannot use are listed in the card's "Unavailable" block, not here
      final usable = [for (final n in s.nodes) if (n.usable) n];
      var nodes = usable;
      if (searching) {
        nodes = [
          for (final n in nodes)
            if ('${n.name} ${n.protocol}'.toLowerCase().contains(query)) n,
        ];
        final nameHit = s.name.toLowerCase().contains(query);
        if (nodes.isEmpty && !nameHit) {
          shown[id] = null;
          continue;
        }
        if (nameHit && nodes.isEmpty) nodes = usable;
      }
      shown[id] = nodes;
    }
    final visible = [
      for (final id in ids)
        if (!searching || shown[id] != null) id,
    ];

    if (visible.isEmpty) return _Empty(tab: tab, query: query);

    final reorder = edit && !searching;
    // [sliver]: the card is a sliver of the lazy list (the servers of an open card are built as
    // they scroll into view); the reorder list needs boxes
    Widget item(String id, int i, {bool sliver = false}) {
      final grip = reorder
          ? ReorderableDragStartListener(index: i, child: const GripHandle())
          : null;
      final s = catalog.sourcesData[id];
      final isOpen = searching ? true : (open[id] ?? false);
      final Widget card = s != null
            ? SourceCard(
                sliver: sliver,
                source: s,
                nodes: shown[id] ?? [for (final n in s.nodes) if (n.usable) n],
                open: isOpen,
                edit: edit,
                searching: searching,
                grip: grip,
                onToggleOpen: () => onToggleOpen(id),
                onPing: () {
                  onOpenCard(id);
                  host.pingSource(id);
                },
                onMenu: () =>
                    showSourceActions(context, s, onOpenCard: onOpenCard),
                onNodeMenu: (n) => showNodeActions(context, s, n),
                onGoneMenu: (n) => showGoneActions(context, s, n),
                onAddServer: () =>
                    showNodeForm(context, sid: s.id, onOpenCard: onOpenCard),
              )
            : EntryCard(
                id: id,
                open: isOpen,
                edit: edit,
                searching: searching,
                grip: grip,
                onToggleOpen: () => onToggleOpen(id),
                onEdit: () => catalog.isChain(id)
                    ? showChainEditor(context, id: id, tab: tab)
                    : showProfileEditor(context, id: id),
              );
      final key = (sliver ? _cardKeys : _boxKeys).putIfAbsent(id, () => GlobalKey());
      if (sliver) {
        return SliverPadding(
          key: ValueKey(id),
          padding: const EdgeInsets.only(bottom: 10),
          sliver: KeyedSubtree(
            key: key,
            child: s != null ? card : SliverToBoxAdapter(child: card),
          ),
        );
      }
      return Padding(
        key: ValueKey(id),
        padding: const EdgeInsets.only(bottom: 10),
        child: KeyedSubtree(key: key, child: card),
      );
    }

    const padding = EdgeInsets.fromLTRB(14, 0, 14, 24);
    if (!reorder) {
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: padding,
            sliver: SliverMainAxisGroup(
              slivers: [
                for (final (i, id) in visible.indexed)
                  item(id, i, sliver: true),
              ],
            ),
          ),
        ],
      );
    }
    return ReorderableListView.builder(
      padding: padding,
      buildDefaultDragHandles: false,
      itemCount: visible.length,
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      onReorderItem: (from, to) {
        final next = [...visible];
        final moved = next.removeAt(from);
        next.insert(to, moved);
        host.reorderCatalog(tab, next);
      },
      itemBuilder: (context, i) => item(visible[i], i),
    );
  }
}

/// `.nodes-empty`.
class _Empty extends StatelessWidget {
  const _Empty({required this.tab, required this.query});

  final String tab;
  final String query;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final style = TextStyle(fontSize: 14, height: 1.5, color: c.t2);
    final Widget text;
    if (query.isNotEmpty) {
      text = Text(
        l10n.nothingMatches2(query),
        style: style,
        textAlign: TextAlign.center,
      );
    } else {
      text = Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: tab == 'simple'
                  ? l10n.noSubscriptionsOrServersYet
                  : l10n.noProfilesYet2,
            ),
            const TextSpan(text: '\n'),
            TextSpan(text: '${l10n.tap} '),
            TextSpan(
              text: '+',
              style: TextStyle(fontWeight: FontWeight.w700, color: c.t1),
            ),
            TextSpan(
              text:
                  ' ${tab == 'simple' ? l10n.toAddOne : l10n.toGroupServersIntoOne}',
            ),
          ],
        ),
        style: style,
        textAlign: TextAlign.center,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
      children: [text],
    );
  }
}
