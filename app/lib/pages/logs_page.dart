import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show EventGroup, dayStart, rawLogText;

import '../core/logs_controller.dart';
import '../l10n/l10n.dart';
import '../platform/files_channel.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_sheet.dart';
import '../widgets/app_view.dart';
import '../widgets/event_rows.dart';
import '../widgets/follow_list.dart';
import '../widgets/form_parts.dart';
import '../widgets/log_parts.dart';
import '../widgets/nodes_menus.dart' show copyText;
import '../widgets/search_field.dart';

/// Logs tab (mockup markup/35-logs.html, js/46-logs.js, 47-events.js): Events, the journal as
/// sentences, and Raw, the lines of sing-box and the core. Both lists open at the bottom, follow
/// what arrives while they are there, and show a pill ("up N new") when scrolled up. What the
/// user has looked at is marked by the [LogsController]: seen warnings (the dots on the nav) and
/// read lines (the badges on the level chips).
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.controller});

  final LogsController controller;

  @override
  State<LogsPage> createState() => _LogsPageState();
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
  final _search = TextEditingController();
  Timer? _seenTimer;
  int? _lastEvTok, _lastLineTok, _lastPin;
  String _evSig = '', _rawSig = '';
  List<RawGroup> _rawGroups = const [];

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
    _search.dispose();
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
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _afterContent();
      _hits();
      _markSoon();
    });
  }

  /// Keeps a following list at its bottom when its content changed.
  void _afterContent() {
    final evSig = '${_c.groups.length}|${_c.groups.lastOrNull?.at}|${_c.groups.lastOrNull?.items.length}|${_c.tab}';
    if (evSig != _evSig) {
      final first = _evSig.isEmpty;
      _evSig = evSig;
      _ev.follow = _c.evFollow;
      if (_c.evFollow) _ev.toBottom(smooth: !first && _c.onScreen && _c.tab == 'events');
    }
    final lines = _c.raw.lines;
    final rawSig = '${lines.length}|${lines.lastOrNull?.n}|${lines.firstOrNull?.n}|${_c.rawLevel}|${_c.rawQuery}';
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
        scrollToRow(scroll: _ev.scroll, key: _hitEvKey, index: i, count: items.length);
      }
    }
    final hl = _c.hitLine;
    if (hl != null && hl.token != _lastLineTok) {
      _lastLineTok = hl.token;
      _goToLine(hl.n, retry: true);
    }
  }

  void _goToLine(int n, {required bool retry}) {
    _rawGroups = groupRaw(_c.shownLines);
    final i = _rawGroups.indexWhere((g) => g.lines.any((l) => l.n == n));
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
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        scrollToRow(scroll: _rawF.scroll, key: _hitLineKey, index: i, count: _rawGroups.length);
      }
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
    if (!mounted || !_c.onScreen) return;
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

  List<Object> _evItems() {
    final out = <Object>[];
    int? day;
    for (final g in _c.groups) {
      final dk = dayStart(g.at);
      if (dk != day) {
        day = dk;
        out.add(_Day(_c.words.dayLabel(g.at, DateTime.now().millisecondsSinceEpoch)));
      }
      out.add(g);
    }
    return out;
  }

  String _summary(AppLocalizations l10n) {
    final warn = _c.tab == 'events'
        ? _c.feed.list.where((e) => e.level == 'warn').length
        : _c.raw.lines.where((e) => e.lvl == 'warn').length;
    final err = _c.tab == 'events'
        ? _c.feed.list.where((e) => e.level == 'error').length
        : _c.raw.lines.where((e) => e.lvl == 'error').length;
    final String head;
    if (_c.tab == 'events') {
      final all = _c.feed.list.length;
      head = _c.filter.count > 0 || !_c.cfg.showOwn && _c.shownCount != all
          ? l10n.ofEvents(_c.shownCount, all)
          : l10n.eventsPlural(all);
    } else {
      head = l10n.linesPlural(_c.raw.lines.length);
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

  void _toggleSearch([bool? on]) {
    _c.toggleSearch(on);
    if (!_c.searching) _search.clear();
  }

  Future<void> _export() async {
    final l10n = context.l10n;
    final name = 'jormungand-logs-${DateTime.now().toIso8601String().substring(0, 10)}.txt';
    try {
      final saved = await BackupIo.current.save(name, _c.exportText());
      if (saved != null && mounted) showToast(context, l10n.logsSaved(saved));
    } catch (e) {
      if (mounted) showToast(context, l10n.exportFailed('$e'));
    }
  }

  void _copy() {
    final l10n = context.l10n;
    final shown = _c.shownLines;
    if (shown.isEmpty) {
      showToast(context, l10n.noLinesToCopy);
      return;
    }
    copyText(context, rawLogText(shown), l10n.linesPlural(shown.length));
  }

  void _confirmClear() {
    final l10n = context.l10n;
    showAppSheet<void>(
      context,
      builder: (sheet) => SheetFrame(
        title: l10n.clearEvents2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuNote(l10n.theEventsListIsEmptiedThe),
            MenuRow(
              icon: const Icon(Icons.delete_outline),
              label: l10n.clearEvents,
              danger: true,
              onTap: () {
                Navigator.of(sheet).pop();
                _c.clearEvents();
              },
            ),
            MenuRow(
              icon: const Icon(Icons.close),
              label: l10n.cancel,
              onTap: () => Navigator.of(sheet).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final events = _c.tab == 'events';
    final filterCount = _c.filter.count;
    if (!_c.searching && _search.text.isNotEmpty) _search.clear();
    return AppView(
      title: l10n.logs,
      summary: _c.l10n == null ? null : _summary(l10n),
      actions: [
        SizedBox(
          width: 124,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: events
                ? [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconBtn(
                          tooltip: l10n.filterEvents,
                          active: filterCount > 0,
                          onTap: () => showEventFilter(context, _c),
                          icon: const Icon(Icons.filter_alt_outlined, size: 19),
                        ),
                        if (filterCount > 0)
                          Positioned(
                            top: -3,
                            right: -3,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: c.accent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$filterCount',
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
                    ),
                    const SizedBox(width: 8),
                    IconBtn(
                      tooltip: l10n.exportBothLogs,
                      onTap: _export,
                      icon: const Icon(Icons.file_download_outlined, size: 19),
                    ),
                    const SizedBox(width: 8),
                    IconBtn(
                      tooltip: l10n.clearEvents,
                      onTap: _confirmClear,
                      icon: const Icon(Icons.delete_outline, size: 19),
                    ),
                  ]
                : [
                    IconBtn(
                      tooltip: l10n.search,
                      active: _c.searching,
                      onTap: _toggleSearch,
                      icon: const Icon(Icons.search, size: 19),
                    ),
                    const SizedBox(width: 8),
                    IconBtn(
                      tooltip: l10n.copyAll,
                      onTap: _copy,
                      icon: const Icon(Icons.copy, size: 17),
                    ),
                    const SizedBox(width: 8),
                    IconBtn(
                      tooltip: l10n.clear,
                      onTap: _c.clearRaw,
                      icon: const Icon(Icons.delete_outline, size: 19),
                    ),
                  ],
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Tabs(tab: _c.tab, onTab: _setTab),
          if (events && filterCount > 0 && _c.l10n != null)
            EventFilterBar(logs: _c, words: _c.words),
          if (!events && _c.searching)
            SearchField(
              controller: _search,
              hint: l10n.searchTheLog,
              autofocus: true,
              onChanged: _c.setRawQuery,
              onClose: () => _toggleSearch(false),
              closeTooltip: l10n.closeSearch,
            ),
          if (!events) _levels(l10n),
          Expanded(
            child: Stack(
              children: [
                Offstage(offstage: !events, child: _eventsList(l10n)),
                Offstage(offstage: events, child: _rawList(l10n)),
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

  Widget _levels(AppLocalizations l10n) {
    final unread = _c.raw.unread;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          LevelChip(
            label: l10n.all,
            active: _c.rawLevel == 'all',
            unread: unread,
            onTap: () => _c.setRawLevel('all'),
          ),
          LevelChip(
            label: l10n.warningsErrors,
            active: _c.rawLevel == 'warn',
            unread: [for (final x in unread) if (x.lvl == 'warn' || x.lvl == 'error') x],
            onTap: () => _c.setRawLevel('warn'),
          ),
        ],
      ),
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
    return ListView.builder(
      key: _evKey,
      controller: _ev.scroll,
      padding: const EdgeInsets.only(bottom: 64),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        if (it is _Day) return EventDay(it.label);
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
        return row;
      },
    );
  }

  Widget _rawList(AppLocalizations l10n) {
    final lines = _c.shownLines;
    if (lines.isEmpty) {
      return _empty(_c.raw.lines.isEmpty ? l10n.noLinesYetSingBoxWrites : l10n.nothingMatches);
    }
    _rawGroups = groupRaw(lines);
    final unread = _c.cfg.rawUnread;
    final hit = _c.hitLine;
    return ListView.builder(
      key: _rawKey,
      controller: _rawF.scroll,
      padding: const EdgeInsets.only(bottom: 64),
      itemCount: _rawGroups.length,
      itemBuilder: (context, i) => RawGroupView(
        group: _rawGroups[i],
        query: _c.rawQuery,
        unread: unread,
        hit: hit?.n,
        hitToken: hit?.token,
        hitKey: _hitLineKey,
        first: i == 0,
      ),
    );
  }
}

class _Day {
  const _Day(this.label);

  final String label;
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
