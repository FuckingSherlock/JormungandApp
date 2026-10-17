import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventGroup, dayStart;

import '../core/logs_controller.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_sheet.dart' show showToast;
import '../widgets/app_view.dart';
import '../widgets/event_rows.dart';
import '../widgets/follow_list.dart';
import '../widgets/form_parts.dart';
import '../widgets/ignored_sites.dart';
import '../widgets/log_parts.dart';
import '../widgets/raw_filter_sheet.dart';
import '../widgets/search_field.dart';

/// Logs tab (mockup markup/35-logs.html, js/46-logs.js, 47-events.js): Events, the journal as
/// sentences, and Raw, the lines of sing-box and the core. Both lists open at the bottom, follow
/// what arrives while they are there, and show a pill ("up N new") when scrolled up. What the
/// user has looked at is marked by the [LogsController]: seen warnings (the dots on the nav) and
/// read lines (the badges on the level chips).
///
/// The header is the same on both tabs: the filter (a sheet of its own for each tab, a badge with
/// what is set), the search (a field under the tabs), ⋮ (clear, download, send, ignored sites).
///
/// A list scrolled up keeps what the user looks at where it is ([_Anchor]): rows that fall off
/// its head, a filter, the Connections switch, a search do not move the row in view.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.controller});

  final LogsController controller;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

/// What keeps the row in view of a list where it is while the data under it changes: the pivot
/// ([AnchoredList.pivot]) is the data order of the topmost visible row; the scroll origin is moved
/// so that this row stays at its screen position.
class _Anchor {
  int? pivot;
  int shape = 0;
  int head = -1;

  /// The data was reshaped (a filter, a clear...) or lost rows at its head ([head] is a token
  /// of the first row). [list] is the built list of the data as it was rendered last, [follow]:
  /// the list is at its end and pinned there.
  void sync({
    required bool follow,
    required int shape,
    required int head,
    required BuildContext? list,
    required ScrollController scroll,
    required List<int> orders,
  }) {
    final reshaped = shape != this.shape;
    final changed = reshaped || head != this.head;
    this.shape = shape;
    this.head = head;
    if (follow) {
      // pinned to the end: it jumps there after the build; no place to keep
      if (reshaped) pivot = null;
      return;
    }
    if (!changed || list == null) return;
    // a row that is gone in the new data cannot be held: the next one in view is (the topmost
    // anyway when none of them is left)
    final row =
        firstVisibleRow(list, where: (o) => _hasOrder(orders, o)) ?? firstVisibleRow(list);
    if (row == null) return;
    pivot = row.order;
    shiftScroll(scroll, -row.top);
  }

  /// The numbering started over (the core restarted): a pivot from before is of no use.
  void check(int? last) {
    if (pivot != null && last != null && pivot! > last) pivot = null;
  }

  /// [order] is among [orders] (ascending, equal ones in a row).
  static bool _hasOrder(List<int> orders, int order) {
    var lo = 0, hi = orders.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (orders[mid] < order) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < orders.length && orders[lo] == order;
  }
}

class _LogsPageState extends State<LogsPage> {
  late final LogsController _c = widget.controller;
  late final FollowController _ev = FollowController(
    onChange: (f) => _followChanged(true, f),
  );
  late final FollowController _rawF = FollowController(
    onChange: (f) => _followChanged(false, f),
  );
  final _evKey = GlobalKey(), _rawKey = GlobalKey();
  final _hitEvKey = GlobalKey(), _hitLineKey = GlobalKey();
  final _evSearch = TextEditingController(), _rawSearch = TextEditingController();
  final _evAnchor = _Anchor(), _rawAnchor = _Anchor();
  Timer? _seenTimer;
  int? _lastEvTok, _lastLineTok, _lastPin;
  String _evSig = '', _rawSig = '';

  // What is derived from the controller's lists, kept until they change ([LogsController.evVersion]
  // / [LogsController.rawVersion]): a frame or a rebuild for another reason does not fold 1000
  // events or group 2000 lines again.
  List<RawGroup> _rawGroups = const [];
  List<int> _rawOrders = const [];
  Map<int, int> _rawIndex = const {};
  (int, String, String)? _rawGroupsFor;

  /// The views made for the groups (by the number of the first line), handed out again while a
  /// group and its look are the same: a batch of lines then rebuilds only the group it touched.
  final _rawViews = <int, _RawView>{};
  int _rawViewsShape = -1;
  List<Object> _items = const [];
  List<int> _evOrders = const [];
  Map<String, int> _evIndex = const {};
  (int, AppLocalizations?, int)? _itemsFor;

  /// The lists as last built: the one behind the other tab is shown again, as the identical
  /// widget (nothing of it is rebuilt or laid out again), while its tab is not in front.
  Widget? _evList, _rawList;

  /// The page as last built while it was on screen: shown again, untouched, while it is not (the
  /// shell rebuilds all tabs for its own reasons; this one has nothing to redo behind the others).
  Widget? _built;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onCtl);
    _ev.scroll.addListener(_markSoon);
    _rawF.scroll.addListener(_markSoon);
    _lastEvTok = _c.hitEvent?.token;
    _lastLineTok = _c.hitLine?.token;
    _lastPin = _c.pinToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ev.toBottom();
      _rawF.toBottom();
      _markSoon();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.l10n = context.l10n;
  }

  @override
  void dispose() {
    _c.removeListener(_onCtl);
    _seenTimer?.cancel();
    _ev.dispose();
    _rawF.dispose();
    _evSearch.dispose();
    _rawSearch.dispose();
    super.dispose();
  }

  void _followChanged(bool events, bool follow) {
    if (events) {
      _c.evFollow = follow;
      if (follow) _c.evUnseen = 0;
    } else {
      _c.rawFollow = follow;
      if (follow) _c.rawUnseen = 0;
    }
    if (mounted) setState(() {});
  }

  void _onCtl() {
    // not on screen: nothing to redraw; coming into view the controller tells again
    if (!mounted || !_c.visible) return;
    _syncSearch();
    _reanchor();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _afterContent();
      _hits();
      _markSoon();
    });
  }

  /// The search fields show what the controller holds (a Reset elsewhere clears the text).
  void _syncSearch() {
    if (!_c.evSearching && _evSearch.text.isNotEmpty) {
      _evSearch.clear();
    } else if (_evSearch.text.trim().toLowerCase() != _c.filter.q) {
      _evSearch.text = _c.filter.q;
    }
    if (!_c.rawSearching && _rawSearch.text.isNotEmpty) {
      _rawSearch.clear();
    } else if (_rawSearch.text.trim().toLowerCase() != _c.rawQuery.trim().toLowerCase()) {
      _rawSearch.text = _c.rawQuery;
    }
  }

  /// Before the new rows are built: the list on screen keeps the row in view in place. The tree
  /// still holds the rows of the last build, which is what is measured.
  void _reanchor() {
    if (_c.l10n == null) return;
    if (_c.tab == 'events') {
      _evItems();
      final groups = _c.groups;
      _evAnchor.sync(
        follow: _c.evFollow,
        shape: _c.evShape,
        head: groups.firstOrNull?.key ?? -1,
        list: _evKey.currentContext,
        scroll: _ev.scroll,
        orders: _evOrders,
      );
      _evAnchor.check(_evOrders.lastOrNull);
    } else {
      _rawGroupsNow();
      final groups = _rawGroups;
      _rawAnchor.sync(
        follow: _c.rawFollow,
        shape: _c.rawShape,
        head: groups.firstOrNull?.lines.first.n ?? -1,
        list: _rawKey.currentContext,
        scroll: _rawF.scroll,
        orders: _rawOrders,
      );
      _rawAnchor.check(groups.lastOrNull?.lines.last.n);
    }
  }

  /// Keeps a following list at its bottom when its content changed.
  void _afterContent() {
    final evSig =
        '${_c.groups.length}|${_c.groups.lastOrNull?.at}|${_c.groups.lastOrNull?.items.length}|${_c.tab}|${_c.evShape}';
    if (evSig != _evSig) {
      final first = _evSig.isEmpty;
      _evSig = evSig;
      _ev.follow = _c.evFollow;
      if (_c.evFollow) _ev.toBottom(smooth: !first && _c.onScreen && _c.tab == 'events');
    }
    final lines = _c.raw.lines;
    final rawSig =
        '${lines.length}|${lines.lastOrNull?.n}|${lines.firstOrNull?.n}|${_c.rawLevel}|${_c.rawQuery}|${_c.cfg.showConns}|${_c.cfg.showIgnored}|${_c.ignoredLineCount}|${_c.rawShape}';
    if (rawSig != _rawSig) {
      _rawSig = rawSig;
      _rawF.follow = _c.rawFollow;
      if (_c.rawFollow) _rawF.toBottom();
    }
    if (_c.pinToken != _lastPin) {
      _lastPin = _c.pinToken;
      _ev.toBottom();
    }
  }

  /// A row to jump to (a notification, "In raw log", Back from an Open).
  void _hits() {
    final he = _c.hitEvent;
    if (he != null && he.token != _lastEvTok) {
      _lastEvTok = he.token;
      _ev.follow = false;
      _c.evFollow = false;
      final items = _evItems();
      final i = items.indexWhere((x) => x is EventGroup && x.items.any((e) => e.id == he.id));
      if (i >= 0) {
        // the origin is put on the row: it is built where it is looked for, then brought to the middle
        _evAnchor.pivot = _evOrders[i];
        shiftScroll(_ev.scroll, 0);
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showRow(_hitEvKey);
        });
      }
    }
    final hl = _c.hitLine;
    if (hl != null && hl.token != _lastLineTok) {
      _lastLineTok = hl.token;
      _goToLine(hl.n, retry: true);
    }
  }

  /// The Raw tab's groups for the lines the filter lets through, grouped once per change.
  List<RawGroup> _rawGroupsNow() {
    final key = (_c.rawVersion, _c.rawLevel, _c.rawQuery);
    if (_rawGroupsFor != key) {
      final groups = groupRaw(_c.shownLines);
      _rawGroups = groups;
      // a group sits where its last line is: the group of a line is never before the line
      _rawOrders = [for (final g in groups) g.lines.last.n];
      _rawIndex = {for (var i = 0; i < groups.length; i++) groups[i].lines.first.n: i};
      _rawViews.removeWhere((n, _) => !_rawIndex.containsKey(n));
      _rawGroupsFor = key;
    }
    return _rawGroups;
  }

  void _goToLine(int n, {required bool retry}) {
    final groups = _rawGroupsNow();
    final i = groups.indexWhere((g) => g.lines.any((l) => l.n == n));
    if (i < 0) {
      if (retry) {
        _c.refresh();
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) _goToLine(n, retry: false);
        });
      } else if (mounted) {
        showToast(context, context.l10n.thatLineIsNoLongerIn);
      }
      return;
    }
    _rawF.follow = false;
    _c.rawFollow = false;
    _rawAnchor.pivot = _rawOrders[i];
    shiftScroll(_rawF.scroll, 0);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showRow(_hitLineKey);
    });
  }

  void _markSoon() {
    _seenTimer ??= Timer(const Duration(milliseconds: 150), () {
      _seenTimer = null;
      _mark();
    });
  }

  /// The warnings / errors and lines whose row is in the viewport are seen / read.
  void _mark() {
    if (!mounted || !_c.visible) return;
    if (_c.tab == 'events') {
      final ctx = _evKey.currentContext;
      if (ctx == null) return;
      _c.markSeen([for (final ids in visibleMarks<List<int>>(ctx)) ...ids]);
    } else {
      final ctx = _rawKey.currentContext;
      if (ctx == null) return;
      _c.markRead(visibleMarks<int>(ctx));
    }
  }

  // ── content ──

  /// The Events rows with the day headers between them, built once per change of the journal
  /// (or of the language / the day: the labels say "Today"). Also the order of each row (what
  /// [AnchoredList] cuts at) and where each key is.
  List<Object> _evItems() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = (_c.evVersion, _c.l10n, dayStart(now));
    if (_itemsFor == key) return _items;
    final out = <Object>[], orders = <int>[];
    final index = <String, int>{};
    int? day;
    final groups = _c.groups;
    var prev = 0; // the order of the row before
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      // the rows are in `at` order (LogsController.groups); rows of one millisecond still get orders of their own
      // (strictly ascending), or a list pivoted on one of them could not put it at the origin. A day header takes the
      // order of the row before it, so all of `orders` never decreases (AnchoredList.orderAt); a pivot on a row
      // (its own order, not `at`) cuts right before it, whatever drift `prev + 1` adds to the orders
      final order = gi == 0 || g.at > prev ? g.at : prev + 1;
      final dk = dayStart(g.at);
      if (dk != day) {
        day = dk;
        index['d$dk'] = out.length;
        out.add(_Day(_c.words.dayLabel(g.at, now), dk));
        // the header belongs before its first row: a list pivoted on that row keeps it in place
        orders.add(gi == 0 ? order - 1 : prev);
      }
      index['e${g.key}'] = out.length;
      out.add(g);
      orders.add(order);
      prev = order;
    }
    _itemsFor = key;
    _evOrders = orders;
    _evIndex = index;
    return _items = out;
  }

  String _summary(AppLocalizations l10n) {
    final (:warn, :err) = _c.tab == 'events' ? _c.evLevels : _c.rawLevels;
    final String head;
    if (_c.tab == 'events') {
      final all = _c.feed.list.length;
      head = _c.filter.count > 0 || !_c.cfg.showOwn && _c.shownCount != all
          ? l10n.ofEvents(_c.shownCount, all)
          : l10n.eventsPlural(all);
    } else {
      head = l10n.linesPlural(_c.raw.visibleCount);
    }
    return [
      head,
      if (err > 0) l10n.errorsPlural(err),
      if (warn > 0) l10n.warningsPlural(warn),
    ].join(' · ');
  }

  // ── actions ──

  void _setTab(String t) {
    _c.setTab(t);
    if (t == 'events' && _c.evFollow) _ev.toBottom();
    if (t == 'raw' && _c.rawFollow) _rawF.toBottom();
  }

  @override
  Widget build(BuildContext context) {
    // behind another tab (or the app) the controller does not tell of changes: the page keeps what it was
    if (!_c.visible && _built != null) return _built!;
    return _built = _page(context);
  }

  /// The filter settings of the Events tab shown on the button's badge (the search is its own button).
  int get _evFilterCount => _c.filter.count - (_c.filter.q.isEmpty ? 0 : 1);

  Widget _page(BuildContext context) {
    final l10n = context.l10n;
    final events = _c.tab == 'events';
    final filterCount = events ? _evFilterCount : _c.rawFilterCount;
    final searchOn = _c.searching || (events ? _c.filter.q.isNotEmpty : _c.rawQuery.isNotEmpty);
    // the list behind the other tab is not touched: the same widget as it was
    final evList = events || _evList == null ? (_evList = _eventsList(l10n)) : _evList!;
    final rawList = !events || _rawList == null ? (_rawList = _rawListWidget(l10n)) : _rawList!;
    return AppView(
      title: l10n.logs,
      summary: _c.l10n == null ? null : _summary(l10n),
      actions: [
        SizedBox(
          width: 124,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _FilterButton(
                tooltip: events ? l10n.filterEvents : l10n.filterLog,
                count: filterCount,
                onTap: () => events ? showEventFilter(context, _c) : showRawFilter(context, _c),
              ),
              const SizedBox(width: 8),
              IconBtn(
                key: const ValueKey('logsSearch'),
                tooltip: l10n.search,
                active: searchOn,
                onTap: _c.toggleSearch,
                icon: const Icon(Icons.search, size: 19),
              ),
              const SizedBox(width: 8),
              IconBtn(
                key: const ValueKey('logsMenu'),
                tooltip: l10n.more,
                onTap: () => showLogsMenu(context, _c),
                icon: const Icon(Icons.more_vert, size: 19),
              ),
            ],
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Tabs(tab: _c.tab, onTab: _setTab),
          if (events && _c.evSearching)
            SearchField(
              key: const ValueKey('evSearch'),
              controller: _evSearch,
              hint: l10n.searchEvents,
              autofocus: true,
              onChanged: _c.setQuery,
              onClose: _c.toggleSearch,
              closeTooltip: l10n.closeSearch,
            ),
          if (!events && _c.rawSearching)
            SearchField(
              key: const ValueKey('rawSearch'),
              controller: _rawSearch,
              hint: l10n.searchTheLog,
              autofocus: true,
              onChanged: _c.setRawQuery,
              onClose: _c.toggleSearch,
              closeTooltip: l10n.closeSearch,
            ),
          if (!events)
            _RawStatus(
              shown: _c.shownLines.length,
              hidden: _c.cfg.showConns ? null : _c.rawHidden,
              onHidden: () => showRawFilter(context, _c),
            ),
          Expanded(
            child: Stack(
              children: [
                Offstage(offstage: !events, child: evList),
                Offstage(offstage: events, child: rawList),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(child: _pill(l10n, events)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(AppLocalizations l10n, bool events) {
    final follow = events ? _c.evFollow : _c.rawFollow;
    if (follow) return const SizedBox.shrink();
    final n = events ? _c.evUnseen : _c.rawUnseen;
    return JumpPill(
      label: n > 0 ? l10n.newText2(n) : l10n.latest,
      onTap: () {
        final f = events ? _ev : _rawF;
        if (events) {
          _c.evUnseen = 0;
        } else {
          _c.rawUnseen = 0;
        }
        f.toBottom(smooth: true);
        setState(() {});
      },
    );
  }

  Widget _empty(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 14, color: context.colors.t3),
      ),
    ),
  );

  Widget _eventsList(AppLocalizations l10n) {
    if (_c.l10n == null) return const SizedBox.shrink();
    final items = _evItems();
    if (items.isEmpty) {
      return _empty(_c.feed.list.isEmpty ? l10n.noEventsYet : l10n.noEventsMatchTheFilter);
    }
    final words = _c.words;
    final hit = _c.hitEvent;
    final orders = _evOrders, index = _evIndex;
    return AnchoredList(
      key: _evKey,
      controller: _ev.scroll,
      count: items.length,
      orderAt: (i) => orders[i],
      pivot: _evAnchor.pivot,
      indexOfKey: (k) => k is ValueKey<String> ? index[k.value] : null,
      itemBuilder: (context, i) {
        final it = items[i];
        if (it is _Day) return KeyedSubtree(key: ValueKey('d${it.day}'), child: EventDay(it.label));
        final g = it as EventGroup;
        Widget row = EventRow(
          group: g,
          logs: _c,
          words: words,
          first: i == 0 || items[i - 1] is _Day,
        );
        if (g.problem) {
          row = RowMark<List<int>>(value: [for (final e in g.items) e.id], child: row);
        }
        if (hit != null && g.items.any((e) => e.id == hit.id)) {
          row = KeyedSubtree(key: _hitEvKey, child: row);
        }
        return RowMark<RowAnchor>(
          key: ValueKey('e${g.key}'),
          value: RowAnchor(orders[i]),
          child: row,
        );
      },
    );
  }

  Widget _rawListWidget(AppLocalizations l10n) {
    final lines = _c.shownLines;
    if (lines.isEmpty) {
      return _empty(_c.raw.lines.isEmpty ? l10n.noLinesYetSingBoxWrites : l10n.nothingMatches);
    }
    final groups = _rawGroupsNow();
    final orders = _rawOrders, index = _rawIndex;
    final unread = _c.cfg.rawUnread;
    final hit = _c.hitLine;
    final query = _c.rawQuery;
    // the lines the cached views were made of are the filter's: any other filter starts over
    if (_rawViewsShape != _c.rawShape) {
      _rawViews.clear();
      _rawViewsShape = _c.rawShape;
    }
    Widget view(int i) {
      final g = groups[i];
      final n = g.lines.first.n;
      final hitN = hit != null && g.lines.any((l) => l.n == hit.n) ? hit.n : null;
      final hitToken = hitN == null ? null : hit!.token;
      final made = _rawViews[n];
      if (made != null &&
          made.sig == g.sig &&
          made.query == query &&
          made.hit == hitN &&
          made.hitToken == hitToken &&
          made.first == (i == 0) &&
          identical(made.unread, unread)) {
        return made.view;
      }
      final v = RawGroupView(
        group: g,
        query: query,
        unread: unread,
        hit: hitN,
        hitToken: hitToken,
        hitKey: _hitLineKey,
        first: i == 0,
      );
      _rawViews[n] = _RawView(g.sig, query, hitN, hitToken, i == 0, unread, v);
      return v;
    }

    return AnchoredList(
      key: _rawKey,
      controller: _rawF.scroll,
      count: groups.length,
      orderAt: (i) => orders[i],
      pivot: _rawAnchor.pivot,
      indexOfKey: (k) => k is ValueKey<int> ? index[k.value] : null,
      itemBuilder: (context, i) => RowMark<RowAnchor>(
        key: ValueKey(groups[i].lines.first.n),
        value: RowAnchor(orders[i]),
        child: view(i),
      ),
    );
  }
}

/// A [RawGroupView] and what it was made of.
class _RawView {
  const _RawView(this.sig, this.query, this.hit, this.hitToken, this.first, this.unread, this.view);

  final (int, int, int) sig;
  final String query;
  final int? hit, hitToken;
  final bool first;
  final Set<int> unread;
  final Widget view;
}

class _Day {
  const _Day(this.label, this.day);

  final String label;
  final int day;
}

/// The filter button of the header with the number of what is set on its corner.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.tooltip, required this.count, required this.onTap});

  final String tooltip;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconBtn(
          key: const ValueKey('logsFilter'),
          tooltip: tooltip,
          active: count > 0,
          onTap: onTap,
          icon: const Icon(Icons.filter_alt_outlined, size: 19),
        ),
        if (count > 0)
          Positioned(
            top: -3,
            right: -3,
            child: Container(
              key: const ValueKey('logsFilterBadge'),
              constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                  color: onAccentOf(context),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The line under the tabs of Raw: how many lines are in the list and, while the successful
/// connections are off, how many of them the core left out (a tap opens the filter to switch
/// them on). [hidden] null: they are shown.
class _RawStatus extends StatelessWidget {
  const _RawStatus({required this.shown, required this.hidden, required this.onHidden});

  final int shown;
  final int? hidden;
  final VoidCallback onHidden;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final style = TextStyle(fontSize: 12.5, color: c.t3);
    return Padding(
      key: const ValueKey('rawStatus'),
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
      // the same height with and without the count of hidden lines (which has a bigger tap target):
      // the list under it does not move when it comes and goes
      child: Row(
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                l10n.linesPlural(shown),
                key: const ValueKey('rawStatusLines'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
          if (hidden != null) ...[
            Text(' · ', style: style),
            Flexible(
              child: GestureDetector(
                key: const ValueKey('rawStatusHidden'),
                behavior: HitTestBehavior.opaque,
                onTap: onHidden,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    l10n.connectionsHidden(hidden!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: c.accent, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `.log-tabbar`: Events / Raw with a sliding ink.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onTab});

  final String tab;
  final ValueChanged<String> onTab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    Widget button(String id, String label) => Expanded(
      child: InkWell(
        onTap: () => onTab(id),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
          child: Center(
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
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
        child: Stack(
          children: [
            Row(children: [button('events', l10n.events), button('raw', l10n.raw)]),
            Positioned(
              left: 0,
              right: 0,
              bottom: -1,
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: tab == 'events' ? Alignment.centerLeft : Alignment.centerRight,
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
              ),
            ),
          ],
        ),
      ),
    );
  }
}
