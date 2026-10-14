import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show
        EventFeed,
        EventFilter,
        EventGroup,
        EventRecord,
        IgnoredSites,
        LogCfg,
        LogFeed,
        LogLine,
        eventCats,
        eventNotifies,
        foldEvents;

import '../l10n/l10n.dart';
import 'core_host.dart';
import 'event_text.dart';
import 'report_send.dart';
import 'settings_model.dart';

/// What the Logs tab shows and keeps (mockup 46-logs.js, 47-events.js): the events journal and
/// the raw log of the core, fed by the host's streams and a slow poll (the streams only say
/// "something new"; the pages are asked for it, so nothing is lost or doubled). The models
/// (`EventFeed`, `LogFeed`, `EventFilter`, `LogCfg`) are the core's; this is the glue: it
/// reads the pages, applies the user's filter, remembers what was seen and writes it back into the
/// kept state (`unknown['logCfg']`).
///
/// One per app, owned by the shell: it runs in the background too, because the in-app
/// notifications (toasts) and the dots on the Logs tab come from it.
///
/// What it costs is kept proportional to what the user can see (the core writes a line per
/// sing-box message, a failed connect or a ping run is a burst of hundreds):
/// - the streams only arm a timer ([_pollSoon]: ~300 ms for events, [rawBatch] for lines); one
///   poll then reads what is new (the core finds it by number, `since`), so a burst is one read
///   and the page is told of new lines at most twice a second;
/// - the raw read asks the core without the successful-connection lines while «Connections» is
///   off (`conns: false`): their flood is never marshalled; the core says how many it left out
///   ([rawHidden]);
/// - the events are read always (toasts, the dots: [unseenNotifier], which is all the shell's nav
///   listens to), but this controller's own listeners (the Logs page) hear of a change, and the
///   derived lists are rebuilt, only while the Logs tab is on screen ([visible]);
/// - the raw lines are not read at all while the Raw tab is not on screen (the Logs tab behind
///   another one, the app behind, or the Events tab in front): no line stream, no list. The first
///   look catches up from the cursor ([LogFeed.next]); what arrived meanwhile is unread, as before;
/// - the unread numbers are written to the state when the tab or the app goes away ([flush]),
///   never per line.
class LogsController extends ChangeNotifier {
  /// [reportSend]: tests hand in one with their own clock.
  LogsController(this.host, {ReportSendController? reportSend}) : reportSend = reportSend ?? ReportSendController(host);

  final CoreHost host;

  /// The words need the language; the owner hands it over when it changes.
  AppLocalizations? l10n;

  EventWords get words => EventWords(l10n!, host.catalog);

  /// «Send report»: the send and its result live here, not in the sheet (report_send.dart).
  final ReportSendController reportSend;

  final feed = EventFeed();
  final filter = EventFilter();
  LogCfg cfg = LogCfg();
  late LogFeed raw = LogFeed(cfg);

  /// `events` | `raw`.
  String tab = 'events';
  String rawLevel = 'all';
  String rawQuery = '';

  /// The search field of the tab is open (Events: the text is [EventFilter.q]; Raw: [rawQuery]).
  bool evSearching = false, rawSearching = false;

  /// The search of the tab on screen is open.
  bool get searching => tab == 'events' ? evSearching : rawSearching;

  /// How many lines of successful connections the core left out of the answers since the list was
  /// last read whole (the «Connections hidden (K)» of the Raw status line); 0 while they are shown.
  int rawHidden = 0;

  /// Unfolded event rows (`EventGroup.key`).
  final openRows = <int>{};

  /// The Logs tab is the selected one (the owner sets it).
  bool onScreen = false;
  bool _foreground = true;

  /// The Logs tab is on screen and the app is in front: the only time the page needs anything.
  bool get visible => onScreen && _foreground;

  /// The raw lines are wanted: the Raw tab of the Logs tab is on screen. Behind the Events tab
  /// nothing reads them (the core keeps them; the first look catches up from the cursor).
  bool get _rawWanted => visible && tab == 'raw';

  /// The shell tells whether the Logs tab is the one on screen; the page marks what it shows as seen.
  void setOnScreen(bool on) {
    if (onScreen == on) return;
    final was = visible;
    onScreen = on;
    _visibleChanged(was);
  }

  /// The shell tells whether the app is in front (not paused / hidden). Behind, the page is
  /// not fed and the unread numbers are kept.
  void setForeground(bool front) {
    if (_foreground == front) return;
    final was = visible;
    _foreground = front;
    _visibleChanged(was);
  }

  void _visibleChanged(bool was) {
    if (visible == was) return; // the tab changed behind the app: the page is not watching
    _syncLineSub();
    if (visible) {
      _poll(force: true); // catch up on what came while it was not looked at
    } else {
      flush();
      notifyListeners();
    }
  }

  /// Background events that may notify (not own, newer than the first look, switched on in
  /// Settings -> Notifications): the shell shows them as toasts.
  Stream<EventRecord> get notifications => _notify.stream;
  final _notify = StreamController<EventRecord>.broadcast();

  /// A row to bring into view and flash (an event id / a raw line number), with a counter so the
  /// same one can be asked again.
  ({int id, int token})? hitEvent;
  ({int n, int token})? hitLine;
  int _token = 0;

  bool _loaded = false;
  bool _disposed = false;
  StreamSubscription<Map<String, dynamic>>? _evSub, _lineSub;
  Timer? _timer, _debounce, _rawDebounce;
  List<EventGroup>? _groups;
  List<EventRecord>? _shown;

  /// How long a burst of events is gathered before one read of the core.
  static const pollDelay = Duration(milliseconds: 300);

  /// How long a burst of raw lines is gathered before one read: the page hears of new lines (and
  /// redraws) at most this often, however fast sing-box writes.
  static const rawBatch = Duration(milliseconds: 500);

  /// The safety poll: the streams only say "something new", this finds what they missed.
  static const safetyPoll = Duration(seconds: 5);

  /// Bumped whenever the events list or the filter over it changes / the raw lines or their
  /// unread numbers change: the pages cache what they derive from them by these.
  int evVersion = 0, rawVersion = 0;

  /// Bumped when the list under the user's eyes is made different by something else than lines
  /// arriving at its end (a filter, a search, the Connections switch, a clear): the page keeps the
  /// row the user looks at in place across it. Events / Raw.
  int evShape = 0, rawShape = 0;

  /// Starts listening; the first read waits for the host to be ready.
  void start() {
    _evSub ??= host.events.listen((_) => _pollSoon());
    _syncLineSub();
    _timer ??= Timer.periodic(safetyPoll, (_) => _poll());
    host.addListener(_onHost);
    _onHost();
  }

  // The raw lines are only wanted while the page shows them.
  void _syncLineSub() {
    if (_disposed) return;
    if (_rawWanted) {
      _lineSub ??= host.logLines.listen((_) => _rawSoon());
    } else if (_lineSub != null) {
      _lineSub!.cancel();
      _lineSub = null;
    }
  }

  void _onHost() {
    if (!_loaded && host.ready) {
      _loaded = true;
      host.removeListener(_onHost);
      cfg = LogCfg.fromJson(host.catalog.unknown['logCfg']);
      raw = LogFeed(cfg);
      if (cfg.rawTop == null) {
        // first run: what the core holds counts as read, what comes later is unread. The lines
        // are not read now (nobody looks), only the number the next one gets.
        try {
          cfg.rawTop = ((host.logPage(since: 0x7fffffff)['next'] as num?)?.toInt() ?? 0) - 1;
        } catch (_) {}
      }
      _poll();
    }
  }

  /// An event arrived: read the journal soon, once for the burst.
  void _pollSoon() {
    if (_debounce != null || _disposed) return;
    _debounce = Timer(pollDelay, () {
      _debounce = null;
      _poll(rawLines: false);
    });
  }

  /// A raw line arrived: read the log soon, once for the burst ([rawBatch]).
  void _rawSoon() {
    if (_rawDebounce != null || _disposed) return;
    _rawDebounce = Timer(rawBatch, () {
      _rawDebounce = null;
      _poll(events: false);
    });
  }

  /// One `log()` answer; [rawHidden] follows what the core says it left out: an answer from the
  /// start (no [since]) replaces the count, one from the cursor adds to it.
  Map<String, dynamic> _logPage({int? since}) {
    final page = host.logPage(since: since, conns: cfg.showConns);
    final hidden = (page['hidden'] as num?)?.toInt() ?? 0;
    rawHidden = since == null ? hidden : rawHidden + hidden;
    return page;
  }

  /// Reads what is new from the core: events always, raw lines while [visible] ([events] /
  /// [rawLines] limit the read to one of them: the timers of each). The page hears of a change
  /// only while it looks ([force]: tell it anyway, it just came into view).
  void _poll({bool force = false, bool events = true, bool rawLines = true}) {
    if (_disposed) return;
    if (events) {
      _debounce?.cancel();
      _debounce = null;
    }
    if (rawLines) {
      _rawDebounce?.cancel();
      _rawDebounce = null;
    }
    if (!_loaded || l10n == null) {
      if (force) notifyListeners();
      return;
    }
    // the ignored list also tells the events' notifications, so it is looked at on every read
    var changed = _syncIgnored();
    if (events && _readEvents()) changed = true;
    if (rawLines && _rawWanted && _readRaw()) changed = true;
    if ((changed && visible) || force) notifyListeners();
  }

  /// The journal's new events; true when the list changed.
  bool _readEvents() {
    try {
      var r = feed.apply(host.eventsPage(since: feed.next));
      if (r.reset) r = feed.apply(host.eventsPage());
      if (!r.changed) return false;
      _dropGroups();
      // the dots are for events the journal still has
      final first = feed.list.isEmpty ? (feed.next ?? 0) : feed.list.first.id;
      final n = cfg.seen.length;
      cfg.seen.removeWhere((id) => id < first);
      if (cfg.seen.length != n) _save();
      for (final e in r.notify) {
        // an event of a site ignored a moment ago (the core was not told yet) stays silent too
        if (e.cat == 'site' && _ign.matches('${e.data['host'] ?? ''}')) continue;
        // a background event (found while the screen was off) goes by its own flag, not by the screen now
        // once per event: a repeat of it, or a finished check, changes it in place and does not notify again
        if (eventNotifies(host.catalog.unknown['notifCfg'], e) && feed.markNotified(e.id)) _notify.add(e);
      }
      if (visible && tab == 'events' && !evFollow) {
        evUnseen += r.fresh.where(_visible).length;
      }
      _recountUnseen();
      return true;
    } catch (_) {
      // the core is not up yet: the next poll asks again
      return false;
    }
  }

  /// The log's new lines (without the successful connections while they are off); true when the
  /// list changed. The pill counts only lines that came after the list was read whole.
  bool _readRaw() {
    try {
      final incremental = raw.next != null;
      var r = raw.apply(_logPage(since: raw.next));
      var reset = r.reset;
      if (reset) r = raw.apply(_logPage());
      if (r.fresh.isEmpty && !reset) return false;
      _rawChanged();
      if (reset) rawShape++;
      if (incremental && !reset && tab == 'raw' && !rawFollow) {
        final q = rawQuery.trim().toLowerCase();
        rawUnseen += r.fresh.where((l) => raw.lineShows(l, rawLevel, q)).length;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// New lines/events that arrived while the list was scrolled up (the pill counts them); the
  /// page resets them when it follows again.
  int evUnseen = 0, rawUnseen = 0;

  /// The list is at its bottom and follows what arrives (the page sets it as it scrolls).
  bool evFollow = true, rawFollow = true;

  /// Asks the core again right now (an event the UI just posted).
  void refresh() => _poll();

  // ── Events ──

  bool _visible(EventRecord e) => filter.visible(
    e,
    showOwn: cfg.showOwn,
    text: (x) => words.searchText(x),
  );

  /// The events the filter lets through, oldest first.
  List<EventRecord> get shownEvents =>
      _shown ??= [for (final e in feed.list) if (_visible(e)) e];

  /// The rows: repeats folded. Rebuilt once per [evVersion], not per frame.
  List<EventGroup> get groups => _groups ??= foldEvents(shownEvents);

  int get shownCount => shownEvents.length;

  // The events list or what is shown of it changed: everything derived from it goes.
  void _dropGroups() {
    _groups = _shown = null;
    _evLevels = null;
    evVersion++;
  }

  ({int warn, int err})? _evLevels;

  /// How many warnings / errors the journal holds (the summary line; every event, not only the shown).
  ({int warn, int err}) get evLevels =>
      _evLevels ??= _count(feed.list.length, (i) => feed.list[i].level);

  ({int warn, int err}) _count(int n, String Function(int i) level) {
    var warn = 0, err = 0;
    for (var i = 0; i < n; i++) {
      final l = level(i);
      if (l == 'warn') warn++;
      if (l == 'error') err++;
    }
    return (warn: warn, err: err);
  }

  EventGroup? groupOf(int eventId) {
    for (final g in groups) {
      if (g.items.any((e) => e.id == eventId)) return g;
    }
    return null;
  }

  void _refilter() {
    _dropGroups();
    evShape++;
    notifyListeners();
  }

  void setQuery(String v) {
    filter.q = v.trim().toLowerCase();
    _refilter();
  }

  void setProblems(bool v) {
    filter.problems = v;
    _refilter();
  }

  /// The «Background» chip: events found while the screen was off shown (default) or hidden.
  void setHideBg(bool v) {
    filter.hideBg = v;
    _refilter();
  }

  void toggleType(String key) {
    filter.toggleType(key);
    _refilter();
  }

  void toggleCat(String cat) {
    filter.toggleCat(cat);
    _refilter();
  }

  /// «Show only this type»: every type of the catalog but [key] goes off ([key] on). Returns to
  /// normal with «Reset»; other parts of the filter (query, problems) stay as they are.
  void showOnlyType(String key) {
    filter.off
      ..clear()
      ..addAll([
        for (final (cat, types) in eventCats)
          for (final t in types)
            if ('$cat/$t' != key) '$cat/$t',
      ]);
    _refilter();
  }

  void resetFilter() {
    filter.reset();
    _refilter();
  }

  void setShowOwn(bool v) {
    cfg.showOwn = v;
    _save();
    _refilter();
  }

  void toggleRow(int key) {
    if (!openRows.remove(key)) openRows.add(key);
    notifyListeners();
  }

  /// A category of the Events filter sheet is unfolded (folded until the user opens it; kept).
  bool catOpen(String cat) => cfg.openCats.contains(cat);

  void toggleCatOpen(String cat) {
    if (!cfg.openCats.remove(cat)) cfg.openCats.add(cat);
    _save();
    notifyListeners();
  }

  /// Which levels of warning / error events are not seen yet (the dots on the Logs tab; events
  /// the filter hides count too). A notifier of its own: the nav bar listens to it, not to the
  /// controller, so a burst of lines or events does not rebuild anything unless a dot changes.
  final unseenNotifier = ValueNotifier<({bool error, bool warn})>((error: false, warn: false));

  ({bool error, bool warn}) get unseen => unseenNotifier.value;

  void _recountUnseen() {
    var err = false, warn = false;
    for (final e in feed.list) {
      if (cfg.seen.contains(e.id)) continue;
      if (e.level == 'error') err = true;
      if (e.level == 'warn') warn = true;
    }
    unseenNotifier.value = (error: err, warn: warn);
  }

  /// The warnings / errors in the viewport are seen.
  void markSeen(Iterable<int> ids) {
    final n = cfg.seen.length;
    cfg.seen.addAll(ids);
    if (cfg.seen.length == n) return;
    _recountUnseen();
    _save();
    notifyListeners();
  }

  /// Raised each time the page should pin itself to the bottom (the Logs tab was opened).
  int pinToken = 0;

  /// The Logs tab was tapped (mockup `openLogs`): Events, the latest at once, pinned to the bottom.
  void open() {
    returnId = null;
    _setTab('events');
    evFollow = true;
    evUnseen = 0;
    pinToken++;
    notifyListeners();
  }

  void setTab(String t) {
    returnId = null; // a hand-made tab change forgets the journal return
    if (tab == t) return;
    _setTab(t);
    notifyListeners();
  }

  /// Switches the tab: the line stream follows it, and the Raw tab catches up on what the core
  /// wrote while it was not looked at.
  void _setTab(String t) {
    tab = t;
    _syncLineSub();
    if (_rawWanted && _loaded && l10n != null) _readRaw();
  }

  /// A notification was tapped: Logs -> Events at that event (the filter cleared if it hides it).
  void showEvent(int id) {
    _setTab('events');
    final e = feed.list.where((x) => x.id == id).firstOrNull;
    if (e != null && !_visible(e)) filter.reset();
    _dropGroups();
    evShape++;
    final g = groupOf(id);
    if (g != null) markSeen(g.items.map((x) => x.id));
    hitEvent = (id: id, token: ++_token);
    notifyListeners();
  }

  /// Events -> "In raw log": the Raw tab at line [n], the filters cleared so it is there.
  void showRawLine(int n) {
    _setTab('raw');
    rawLevel = 'all';
    // the line asked for may be a connection one: the switch goes on so it is there (while they
    // are off the core does not send them, so the line is asked for by its number)
    if (!cfg.showConns && _isConnLine(n)) setShowConns(true);
    if (!cfg.showIgnored && raw.lines.any((l) => l.n == n && raw.isIgnored(l))) setShowIgnored(true);
    rawSearching = false;
    rawQuery = '';
    _shownLines = null;
    rawVersion++;
    rawShape++;
    hitLine = (n: n, token: ++_token);
    notifyListeners();
  }

  /// Whether raw line [n] is one of the successful-connection lines the list leaves out.
  bool _isConnLine(int n) {
    for (final l in raw.lines) {
      if (l.n == n) return l.isConn;
    }
    // not in the list: with the connections off the core did not send it; ask for it
    try {
      final lines = host.logPage(since: n)['lines'];
      if (lines is List && lines.isNotEmpty) {
        final first = LogLine.fromJson(lines.first as Map);
        return first.n == n && first.isConn;
      }
    } catch (_) {}
    return false;
  }

  /// The event an action left the journal from (Open, In raw log): Back returns to its row.
  int? returnId;

  /// Back in the journal with a row open and lit (after Open / In raw log).
  void returnTo(int id) {
    returnId = null;
    _setTab('events');
    final e = feed.list.where((x) => x.id == id).firstOrNull;
    if (e != null && !_visible(e)) filter.reset();
    _dropGroups();
    evShape++;
    final g = groupOf(id);
    if (g != null) openRows.add(g.key);
    hitEvent = (id: id, token: ++_token);
    notifyListeners();
  }

  Future<void> clearEvents() async {
    host.clearEvents();
    feed.clear();
    cfg.seen.clear();
    openRows.clear();
    evUnseen = 0;
    _dropGroups();
    evShape++;
    _recountUnseen();
    _save();
    _poll();
    notifyListeners();
  }

  // ── Raw ──

  // The raw lines or their unread numbers changed; the numbers are for the state (see [flush]).
  void _rawChanged() {
    rawVersion++;
    _shownLines = null;
    _rawLevels = null;
    _unreadLines = null;
    _rawDirty = true;
  }

  List<LogLine>? _shownLines;
  ({int warn, int err})? _rawLevels;
  List<LogLine>? _unreadLines;
  int _unreadFor = -1;

  /// The raw lines the level chip and the search let through. Filtered once per change.
  List<LogLine> get shownLines => _shownLines ??= raw.shown(rawLevel, rawQuery);

  /// How many warnings / errors the raw log holds.
  ({int warn, int err}) get rawLevels =>
      _rawLevels ??= _count(raw.lines.length, (i) => raw.lines[i].lvl);

  /// The lines not read yet (the badges on the level chips).
  List<LogLine> get unreadLines {
    // read lines leave the set without a change of the lines: the size tells
    if (_unreadFor != cfg.rawUnread.length) _unreadLines = null;
    _unreadFor = cfg.rawUnread.length;
    return _unreadLines ??= raw.unread;
  }

  /// How many of the Raw filters are set (the badge on the filter button): the level, the
  /// Connections switch, the ignored sites. The search is not one, it has its own button.
  int get rawFilterCount =>
      (rawLevel != 'all' ? 1 : 0) + (cfg.showConns ? 1 : 0) + (cfg.showIgnored ? 1 : 0);

  /// The Raw filters back to their defaults (level All, no connections, no ignored sites).
  void resetRawFilter() {
    final conns = cfg.showConns;
    rawLevel = 'all';
    cfg.showIgnored = false;
    cfg.showConns = false;
    _save();
    _rawChanged();
    rawShape++;
    if (conns) _reloadRaw();
    notifyListeners();
  }

  void setRawLevel(String lvl) {
    if (rawLevel == lvl) return;
    rawLevel = lvl;
    _shownLines = null;
    rawVersion++;
    rawShape++;
    notifyListeners();
  }

  /// The «Connections» switch: lines of successful connections shown or not (kept in the state).
  /// The core does not send them while it is off, so the lines are asked for again from the
  /// start (the numbers are the core's, the list keeps its place by them).
  void setShowConns(bool v) {
    if (cfg.showConns == v) return;
    cfg.showConns = v;
    _save();
    _reloadRaw();
    notifyListeners();
  }

  /// The raw lines read again, whole, with the current «Connections» switch.
  void _reloadRaw() {
    _rawChanged();
    rawShape++;
    rawUnseen = 0;
    if (!_loaded || l10n == null) {
      raw.lines.clear();
      raw.next = null;
      rawHidden = 0;
      return;
    }
    // a feed of its own: its own lines are replaced in one go, no half-cleared list in between
    final fresh = LogFeed(cfg)..setIgnored(_ign);
    try {
      fresh.apply(_logPage());
      raw = fresh;
    } catch (_) {
      // the core is not up: the next poll reads from the start
      raw.lines.clear();
      raw.next = null;
      rawHidden = 0;
    }
    _rawChanged();
  }

  /// The «from ignored sites» switch: the failed-connection lines of ignored sites shown or not (kept in the state).
  void setShowIgnored(bool v) {
    if (cfg.showIgnored == v) return;
    cfg.showIgnored = v;
    _save();
    _shownLines = null;
    _unreadLines = null;
    rawVersion++;
    rawShape++;
    notifyListeners();
  }

  // ── Ignored sites (kept in `notifCfg`, told to the core by the host; the raw view sorts by it) ──

  IgnoredSites _ign = IgnoredSites.empty;
  String _ignSig = '';

  /// The ignored hosts, cleaned, in the order added.
  List<String> get ignoredSites => host.notif.ignoredSites;

  /// Whether [h] is an ignored host or a subdomain of one.
  bool isSiteIgnored(String h) => _ign.matches(h);

  /// The raw lines the list covers (the hint over the Raw list).
  int get ignoredLineCount => raw.ignoredCount;

  /// The list in the state changed (here, a restored backup...): the raw lines are sorted again.
  /// True when it had.
  bool _syncIgnored() {
    final list = ignoredSites;
    final sig = list.join('\n');
    if (sig == _ignSig) return false;
    _ignSig = sig;
    _ign = IgnoredSites(list);
    raw.setIgnored(_ign);
    _rawChanged();
    return true;
  }

  /// Adds [input] (a host or an address) to the ignored sites. Returns the cleaned host, or null when
  /// it is not a host or is in the list already ([IgnoredSites.clean] tells which).
  String? ignoreSite(String input) {
    final h = IgnoredSites.clean(input);
    if (h.isEmpty) return null;
    final list = ignoredSites;
    if (list.contains(h)) return null;
    _setIgnored([...list, h]);
    return h;
  }

  /// Takes [h] off the list (Undo of [ignoreSite], the x of the list).
  void unignoreSite(String h) => _setIgnored([for (final x in ignoredSites) if (x != h) x]);

  void clearIgnored() => _setIgnored(const []);

  void _setIgnored(List<String> v) {
    host.notif.ignoredSites = v;
    host.changed(); // saves; the core hears of it at once, no reconnect
    _syncIgnored();
    _shownLines = null;
    _unreadLines = null;
    rawShape++;
    notifyListeners();
  }

  void setRawQuery(String q) {
    if (rawQuery == q) return;
    rawQuery = q;
    _shownLines = null;
    rawVersion++;
    rawShape++;
    notifyListeners();
  }

  /// The search field of the tab on screen opens or closes; closing it clears the search (Events:
  /// the text of the filter; Raw: [rawQuery]).
  void toggleSearch([bool? on]) {
    if (tab == 'events') {
      evSearching = on ?? !evSearching;
      if (!evSearching && filter.q.isNotEmpty) {
        filter.q = '';
        _dropGroups();
        evShape++;
      }
    } else {
      rawSearching = on ?? !rawSearching;
      if (!rawSearching && rawQuery.isNotEmpty) {
        rawQuery = '';
        _shownLines = null;
        rawVersion++;
        rawShape++;
      }
    }
    notifyListeners();
  }

  /// The raw lines in the viewport are read.
  void markRead(Iterable<int> ns) {
    if (!raw.markRead(ns)) return;
    _rawDirty = true;
    notifyListeners();
  }

  void clearRaw() {
    host.clearLog();
    raw.clear();
    rawUnseen = 0;
    rawHidden = 0;
    _rawChanged();
    rawShape++;
    notifyListeners();
    _poll();
  }

  /// The numbers of the unread lines changed since they were written to the state. They are
  /// written when the Logs tab or the app goes away ([flush]): never per line, a full state save
  /// is far more than a stream of lines should cost.
  bool _rawDirty = false;

  void _save() {
    host.catalog.unknown['logCfg'] = cfg.toJson();
    host.saveSoon();
  }

  /// The kept state now: the unread raw lines, when they changed (the Logs tab was left, the
  /// app is going to the background).
  void flush() {
    if (!_rawDirty) return;
    _rawDirty = false;
    _save();
  }

  @override
  void dispose() {
    flush();
    _disposed = true;
    _evSub?.cancel();
    _lineSub?.cancel();
    _timer?.cancel();
    _debounce?.cancel();
    host.removeListener(_onHost);
    _notify.close();
    reportSend.dispose();
    super.dispose();
  }
}
