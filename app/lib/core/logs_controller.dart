import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show
        EventFeed,
        EventFilter,
        EventGroup,
        EventRecord,
        LogCfg,
        LogFeed,
        LogLine,
        eventNotifKind,
        foldEvents,
        notifAllows,
        rawLogText;

import '../l10n/l10n.dart';
import 'core_host.dart';
import 'event_text.dart';

/// What the Logs tab shows and keeps (mockup 46-logs.js, 47-events.js): the events journal and
/// the raw log of the core, fed by the host's streams and a slow poll (the streams only say
/// "something new"; the pages are asked for it, so nothing is lost or doubled). The models
/// (`EventFeed`, `LogFeed`, `EventFilter`, `LogCfg`) are the core's; this is the glue: it
/// reads the pages, applies the user's filter, remembers what was seen and writes it back into the
/// kept state (`unknown['logCfg']`).
///
/// One per app, owned by the shell: it runs in the background too, because the in-app
/// notifications (toasts) and the dots on the Logs tab come from it.
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

  /// The Logs tab is on screen (the owner sets it).
  bool onScreen = false;

  /// The shell tells whether the Logs tab is the one on screen; the page marks what it shows as seen.
  void setOnScreen(bool on) {
    if (onScreen == on) return;
    onScreen = on;
    notifyListeners();
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
  Timer? _timer, _persist;
  bool _pollQueued = false;
  List<EventGroup>? _groups;
  List<EventRecord>? _shown;
  String _savedRaw = '';

  /// Starts listening; the first read waits for the host to be ready.
  void start() {
    _evSub ??= host.events.listen((_) => _pollSoon());
    _lineSub ??= host.logLines.listen((_) => _pollSoon());
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    host.addListener(_onHost);
    _onHost();
  }

  void _onHost() {
    if (!_loaded && host.ready) {
      _loaded = true;
      host.removeListener(_onHost);
      cfg = LogCfg.fromJson(host.catalog.unknown['logCfg']);
      raw = LogFeed(cfg);
      _savedRaw = '${cfg.rawTop}${cfg.rawUnread.length}';
      _poll();
    }
  }

  void _pollSoon() {
    if (_pollQueued || _disposed) return;
    _pollQueued = true;
    scheduleMicrotask(() {
      _pollQueued = false;
      _poll();
    });
  }

  /// Reads what is new from the core: events, then raw lines.
  void _poll() {
    if (!_loaded || _disposed || l10n == null) return;
    var changed = false;
    try {
      var r = feed.apply(host.eventsPage(since: feed.next));
      if (r.reset) r = feed.apply(host.eventsPage());
      if (r.changed) {
        changed = true;
        _groups = _shown = null;
        final ids = {for (final e in feed.list) e.id};
        final seen = cfg.seen.where(ids.contains).toSet();
        if (seen.length != cfg.seen.length) {
          cfg.seen
            ..clear()
            ..addAll(seen);
          _save();
        }
        for (final e in r.notify) {
          final kind = eventNotifKind[e.key];
          if (kind != null && notifAllows(host.catalog.unknown['notifCfg'], kind)) {
            _notify.add(e);
          }
        }
        if (onScreen && tab == 'events' && !evFollow) {
          evUnseen += r.fresh.where(_visible).length;
        }
      }
    } catch (_) {
      // the core is not up yet: the next poll asks again
    }
    try {
      var r = raw.apply(host.logPage(since: raw.next));
      if (r.reset) r = raw.apply(host.logPage());
      if (r.fresh.isNotEmpty || r.reset) {
        changed = true;
        if (onScreen && tab == 'raw' && !rawFollow) {
          rawUnseen += r.fresh.where((l) => _rawShown(l)).length;
        }
        _syncRaw();
      }
    } catch (_) {}
    if (changed) notifyListeners();
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

  /// The rows: repeats folded.
  List<EventGroup> get groups => _groups ??= foldEvents(shownEvents);

  int get shownCount => shownEvents.length;

  EventGroup? groupOf(int eventId) {
    for (final g in groups) {
      if (g.items.any((e) => e.id == eventId)) return g;
    }
    return null;
  }

  void _refilter() {
    _groups = _shown = null;
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
  /// the filter hides count too).
  ({bool error, bool warn}) get unseen {
    var err = false, warn = false;
    for (final e in feed.list) {
      if (cfg.seen.contains(e.id)) continue;
      if (e.level == 'error') err = true;
      if (e.level == 'warn') warn = true;
    }
    return (error: err, warn: warn);
  }

  /// The warnings / errors in the viewport are seen.
  void markSeen(Iterable<int> ids) {
    final n = cfg.seen.length;
    cfg.seen.addAll(ids);
    if (cfg.seen.length == n) return;
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
    _groups = _shown = null;
    final g = groupOf(id);
    if (g != null) markSeen(g.items.map((x) => x.id));
    hitEvent = (id: id, token: ++_token);
    notifyListeners();
  }

  /// Events -> "In raw log": the Raw tab at line [n], the filters cleared so it is there.
  void showRawLine(int n) {
    tab = 'raw';
    rawLevel = 'all';
    searching = false;
    rawQuery = '';
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
    _groups = _shown = null;
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
    _groups = _shown = null;
    _save();
    _poll();
    notifyListeners();
  }

  /// Both logs as text: the events (readable), then the raw lines.
  String exportText() {
    final w = words;
    final events = feed.list
        .map(
          (e) =>
              '${DateTime.fromMillisecondsSinceEpoch(e.at, isUtc: true).toIso8601String()} '
              '${e.level.toUpperCase().padRight(5)} ${e.own ? '[you] ' : ''}${w.text(e)}',
        )
        .join('\n');
    final all = raw.lines;
    return 'Jormungand logs, ${DateTime.now().toUtc().toIso8601String()}\n\n'
        '== Events (${feed.list.length}) ==\n$events\n\n'
        '== Raw log (${all.length} lines) ==\n${rawLogText(all)}\n';
  }

  // ── Raw ──

  bool _rawShown(LogLine l) =>
      raw.shown(rawLevel, rawQuery).any((x) => x.n == l.n);

  List<LogLine> get shownLines => raw.shown(rawLevel, rawQuery);

  void setRawLevel(String lvl) {
    rawLevel = lvl;
    notifyListeners();
  }

  void setRawQuery(String q) {
    rawQuery = q;
    notifyListeners();
  }

  void toggleSearch([bool? on]) {
    searching = on ?? !searching;
    if (!searching) rawQuery = '';
    notifyListeners();
  }

  /// The raw lines in the viewport are read.
  void markRead(Iterable<int> ns) {
    if (!raw.markRead(ns)) return;
    _syncRaw();
    notifyListeners();
  }

  void clearRaw() {
    host.clearLog();
    raw.clear();
    rawUnseen = 0;
    _syncRaw();
    notifyListeners();
    _poll();
  }

  /// The numbers of the unread lines keep with the state; written spaced out, so a stream of
  /// lines does not save the whole state every second.
  void _syncRaw() {
    final key = '${cfg.rawTop}${cfg.rawUnread.length}';
    if (key == _savedRaw || _persist != null) return;
    _persist = Timer(const Duration(seconds: 3), () {
      _persist = null;
      _savedRaw = '${cfg.rawTop}${cfg.rawUnread.length}';
      _save();
    });
  }

  void _save() {
    host.catalog.unknown['logCfg'] = cfg.toJson();
    host.saveSoon();
  }

  /// The kept state now (the app is going to the background).
  void flush() {
    if (_persist != null) {
      _persist!.cancel();
      _persist = null;
      _save();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _evSub?.cancel();
    _lineSub?.cancel();
    _timer?.cancel();
    _persist?.cancel();
    host.removeListener(_onHost);
    _notify.close();
    super.dispose();
  }
}
