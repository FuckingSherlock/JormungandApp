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
        eventNotifies,
        foldEvents,
        rawLogText;

import '../l10n/l10n.dart';
import 'core_host.dart';
import 'event_text.dart';
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
/// - the streams only arm a ~300 ms timer ([_pollSoon]); one poll then reads what is new
///   (the core finds it by number, `since`), so a burst is one read;
/// - the events are read always (toasts, the dots: [unseenNotifier], which is all the shell's nav
///   listens to), but this controller's own listeners (the Logs page) hear of a change, and the
///   derived lists are rebuilt, only while the Logs tab is on screen ([visible]);
/// - the raw lines are not read at all while it is not: no line stream, no list. The first look
///   catches up from the cursor ([LogFeed.next]); what arrived meanwhile is unread, as before;
/// - the unread numbers are written to the state when the tab or the app goes away ([flush]),
///   never per line.
class LogsController extends ChangeNotifier {
  LogsController(this.host);

  final CoreHost host;

  /// The words need the language; the owner hands it over when it changes.
  AppLocalizations? l10n;

  EventWords get words => EventWords(l10n!, host.catalog);

  final feed = EventFeed();
  final filter = EventFilter();
  LogCfg cfg = LogCfg();
  late LogFeed raw = LogFeed(cfg);

  /// `events` | `raw`.
  String tab = 'events';
  String rawLevel = 'all';
  String rawQuery = '';
  bool searching = false;

  /// Unfolded event rows (`EventGroup.key`).
  final openRows = <int>{};

  /// The Logs tab is the selected one (the owner sets it).
  bool onScreen = false;
  bool _foreground = true;

  /// The Logs tab is on screen and the app is in front: the only time the page needs anything.
  bool get visible => onScreen && _foreground;

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
  Timer? _timer, _debounce;
  List<EventGroup>? _groups;
  List<EventRecord>? _shown;

  /// How long a burst of lines / events is gathered before one read of the core.
  static const pollDelay = Duration(milliseconds: 300);

  /// Bumped whenever the events list or the filter over it changes / the raw lines or their
  /// unread numbers change: the pages cache what they derive from them by these.
  int evVersion = 0, rawVersion = 0;

  /// Starts listening; the first read waits for the host to be ready.
  void start() {
    _evSub ??= host.events.listen((_) => _pollSoon());
    _syncLineSub();
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    host.addListener(_onHost);
    _onHost();
  }

  // The raw lines are only wanted while the page shows them.
  void _syncLineSub() {
    if (_disposed) return;
    if (visible) {
      _lineSub ??= host.logLines.listen((_) => _pollSoon());
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

  /// A line or an event arrived: read the core soon, once for the burst.
  void _pollSoon() {
    if (_debounce != null || _disposed) return;
    _debounce = Timer(pollDelay, () {
      _debounce = null;
      _poll();
    });
  }

  /// Reads what is new from the core: events always, raw lines while [visible]. The page hears
  /// of a change only while it looks ([force]: tell it anyway, it just came into view).
  void _poll({bool force = false}) {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = null;
    if (!_loaded || l10n == null) {
      if (force) notifyListeners();
      return;
    }
    var changed = _syncIgnored();
    try {
      var r = feed.apply(host.eventsPage(since: feed.next));
      if (r.reset) r = feed.apply(host.eventsPage());
      if (r.changed) {
        changed = true;
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
          if (eventNotifies(host.catalog.unknown['notifCfg'], e)) _notify.add(e);
        }
        if (visible && tab == 'events' && !evFollow) {
          evUnseen += r.fresh.where(_visible).length;
        }
        _recountUnseen();
      }
    } catch (_) {
      // the core is not up yet: the next poll asks again
    }
    if (visible) {
      try {
        var r = raw.apply(host.logPage(since: raw.next));
        if (r.reset) r = raw.apply(host.logPage());
        if (r.fresh.isNotEmpty || r.reset) {
          changed = true;
          _rawChanged();
          if (tab == 'raw' && !rawFollow) {
            final q = rawQuery.trim().toLowerCase();
            rawUnseen += r.fresh.where((l) => raw.lineShows(l, rawLevel, q)).length;
          }
        }
      } catch (_) {}
    }
    if ((changed && visible) || force) notifyListeners();
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
    tab = 'events';
    evFollow = true;
    evUnseen = 0;
    pinToken++;
    notifyListeners();
  }

  void setTab(String t) {
    returnId = null; // a hand-made tab change forgets the journal return
    if (tab == t) return;
    tab = t;
    notifyListeners();
  }

  /// A notification was tapped: Logs -> Events at that event (the filter cleared if it hides it).
  void showEvent(int id) {
    tab = 'events';
    final e = feed.list.where((x) => x.id == id).firstOrNull;
    if (e != null && !_visible(e)) filter.reset();
    _dropGroups();
    final g = groupOf(id);
    if (g != null) markSeen(g.items.map((x) => x.id));
    hitEvent = (id: id, token: ++_token);
    notifyListeners();
  }

  /// Events -> "In raw log": the Raw tab at line [n], the filters cleared so it is there.
  void showRawLine(int n) {
    tab = 'raw';
    rawLevel = 'all';
    // the line asked for may be a connection one: the chip goes on so it is there
    if (!cfg.showConns && raw.lines.any((l) => l.n == n && l.isConn)) setShowConns(true);
    if (!cfg.showIgnored && raw.lines.any((l) => l.n == n && raw.isIgnored(l))) setShowIgnored(true);
    searching = false;
    rawQuery = '';
    _shownLines = null;
    rawVersion++;
    hitLine = (n: n, token: ++_token);
    notifyListeners();
  }

  /// The event an action left the journal from (Open, In raw log): Back returns to its row.
  int? returnId;

  /// Back in the journal with a row open and lit (after Open / In raw log).
  void returnTo(int id) {
    returnId = null;
    tab = 'events';
    final e = feed.list.where((x) => x.id == id).firstOrNull;
    if (e != null && !_visible(e)) filter.reset();
    _dropGroups();
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
    _recountUnseen();
    _save();
    _poll();
    notifyListeners();
  }

  /// Both logs as text: the events (readable), then the raw lines.
  String exportText() {
    _poll(); // up to the last line, whatever the timer has not read yet
    final w = words;
    final events = feed.list
        .map(
          (e) =>
              '${DateTime.fromMillisecondsSinceEpoch(e.at, isUtc: true).toIso8601String()} '
              '${e.level.toUpperCase().padRight(5)} ${e.own ? '[you] ' : ''}${e.bg ? '[bg] ' : ''}${w.text(e)}',
        )
        .join('\n');
    final all = raw.lines;
    return 'Jormungand logs, ${DateTime.now().toUtc().toIso8601String()}\n\n'
        '== Events (${feed.list.length}) ==\n$events\n\n'
        '== Raw log (${all.length} lines) ==\n${rawLogText(all)}\n';
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

  void setRawLevel(String lvl) {
    rawLevel = lvl;
    _shownLines = null;
    rawVersion++;
    notifyListeners();
  }

  /// The «Connections» chip: lines of successful connections shown or not (kept in the state).
  void setShowConns(bool v) {
    if (cfg.showConns == v) return;
    cfg.showConns = v;
    _save();
    _shownLines = null;
    _unreadLines = null;
    rawVersion++;
    notifyListeners();
  }

  /// The «from ignored sites» chip: the failed-connection lines of ignored sites shown or not (kept in the state).
  void setShowIgnored(bool v) {
    if (cfg.showIgnored == v) return;
    cfg.showIgnored = v;
    _save();
    _shownLines = null;
    _unreadLines = null;
    rawVersion++;
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
    notifyListeners();
  }

  void setRawQuery(String q) {
    rawQuery = q;
    _shownLines = null;
    rawVersion++;
    notifyListeners();
  }

  void toggleSearch([bool? on]) {
    searching = on ?? !searching;
    if (!searching) {
      rawQuery = '';
      _shownLines = null;
      rawVersion++;
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
    _rawChanged();
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
    super.dispose();
  }
}
