/// Logs tab model: the events journal as rows (repeats folded, day separators, filter, seen
/// warnings / errors, notification kinds) and the raw log (level / search filter, unread
/// lines). The Dart port of design/src/js/46-logs.js and 47-events.js; the words stay with
/// the UI (it knows the catalog and the language).
library;

import 'ignored_sites.dart';
import 'logbook.dart' show connLineRe;

/// One event of the journal (`events()['events']` item, eventbook.dart).
class EventRecord {
  EventRecord({
    required this.id,
    required this.at,
    required this.cat,
    required this.type,
    required this.level,
    required this.own,
    required this.log,
    required this.data,
    this.bg = false,
  });

  factory EventRecord.fromJson(Map m) => EventRecord(
    id: (m['id'] as num).toInt(),
    at: (m['at'] as num?)?.toInt() ?? 0,
    cat: '${m['cat']}',
    type: '${m['type']}',
    level: '${m['level'] ?? 'info'}',
    own: m['own'] == true,
    bg: m['bg'] == true,
    log: (m['log'] as num?)?.toInt(),
    data: m['data'] is Map ? Map<String, dynamic>.from(m['data'] as Map) : <String, dynamic>{},
  );

  final int id, at;
  final String cat, type, level;
  final bool own;

  /// It happened while the screen was off (a background failure, eventbook.dart).
  final bool bg;

  /// The number of the raw line written at the same moment (null = none).
  final int? log;
  final Map<String, dynamic> data;

  String get key => '$cat/$type';
  bool get isProblem => level != 'info';
}

/// Categories of the journal and their types, in the filter's order (the labels are the UI's).
const eventCats = <(String, List<String>)>[
  ('conn', ['connected', 'disconnected', 'connectFailed', 'lost', 'restored', 'offline', 'online']),
  ('auto', ['switched', 'fastest', 'unstable']),
  ('site', ['blocked', 'unreachable']),
  ('sub', ['updated', 'failed', 'removed', 'back', 'dead']),
  ('rules', ['fallback', 'targetBack', 'ruleSetFailed', 'ruleSetUpdated']),
  ('dns', ['switched']),
  ('core', ['crashed', 'restarted', 'restartFailed', 'tunNeedsAdmin', 'down', 'sysProxy', 'deprecated', 'stateRestored', 'stateLost']),
];

/// Which Settings → Notifications toggle an event type answers to (none: never a notification).
const eventNotifKind = <String, String>{
  'auto/switched': 'autoSwitch', 'auto/fastest': 'autoSwitch', 'auto/unstable': 'unstable',
  'conn/lost': 'connLost', 'conn/restored': 'connLost', 'conn/offline': 'connLost', 'conn/online': 'connLost',
  'core/crashed': 'coreCrash', 'core/restarted': 'coreCrash', 'core/restartFailed': 'coreCrash',
  'core/down': 'connLost',
  'site/blocked': 'blocked', 'site/unreachable': 'blocked', 'sub/updated': 'subUpdated',
  'sub/failed': 'subFailed', 'sub/removed': 'subFailed', 'sub/back': 'subFailed', 'sub/dead': 'subFailed',
  'rules/ruleSetFailed': 'ruleSets',
  'rules/fallback': 'autoSwitch', 'rules/targetBack': 'autoSwitch', 'dns/switched': 'autoSwitch',
};

/// Settings → Notifications as they start (`notifCfg` of the snapshot, names as in the mockup).
const notifDefaults = <String, bool>{
  'enabled': true,
  'status': true,
  'autoSwitch': true,
  'unstable': true,
  'connLost': true,
  'coreCrash': false,
  'blocked': true,
  'subUpdated': false,
  'subFailed': true,
  'ruleSets': true,
  // not one of the toggles of the three groups: failures while the screen is off notify like the others
  'bgErrors': false,
};

/// A background event of the kind [kind] (a value of [eventNotifKind]) may notify: the master
/// switch and its own toggle are on. [cfg] is the saved `notifCfg` (null = the defaults).
bool notifAllows(Object? cfg, String kind) {
  bool on(String k) => cfg is Map && cfg[k] is bool ? cfg[k] as bool : notifDefaults[k] ?? false;
  return on('enabled') && on(kind);
}

/// [e] may notify (toast / system notification): its kind is on ([notifAllows]) and, when it
/// happened while the screen was off (`bg`), «Errors while the screen is off» is on too. Judged by
/// the event's own flag, never by the screen as it is when the notification would be shown.
bool eventNotifies(Object? cfg, EventRecord e) {
  final kind = eventNotifKind[e.key];
  if (kind == null || !notifAllows(cfg, kind)) return false;
  return !e.bg || (cfg is Map && cfg['bgErrors'] is bool ? cfg['bgErrors'] as bool : notifDefaults['bgErrors']!);
}

const eventRepeatWindow =Duration(minutes: 10);
const eventKeep = 1000;
const logKeep = 5500; // the log book: 5000 + its 500 connection lines

const _keyFields = <String, List<String>>{
  'site/blocked': ['host', 'entry'],
  'site/unreachable': ['host', 'entry'],
  'auto/switched': ['route', 'from', 'to'],
  'auto/fastest': ['route', 'from', 'to'],
  'auto/unstable': ['id'],
  'rules/fallback': ['target', 'to'],
  'rules/targetBack': ['target'],
  'dns/switched': ['from', 'to'],
  'rules/ruleSetFailed': ['tag'],
  'rules/ruleSetUpdated': ['tag'],
};

/// What makes two events "the same" for folding.
String eventFoldKey(EventRecord e) {
  final f = _keyFields[e.key] ?? (e.cat == 'sub' ? const ['source'] : null);
  final String tail;
  if (f != null) {
    tail = f.map((k) => '${e.data[k] ?? ''}').join('|');
  } else if (e.cat == 'user') {
    tail = '${e.data}';
  } else {
    tail = '';
  }
  return '${e.key}|$tail';
}

/// A row of the Events list: one event, or the same event again within 10 minutes of its last time.
class EventGroup {
  EventGroup(EventRecord e) : items = [e], at = e.at, ev = e, level = e.level;

  final List<EventRecord> items;

  /// The last time and the last event of the row.
  int at;
  EventRecord ev;

  /// The worst level among the repeats.
  String level;

  int get key => items.first.id;
  bool get problem => level != 'info';
}

int _rank(String l) => l == 'error' ? 2 : l == 'warn' ? 1 : 0;

/// Folds [list] (oldest first) into rows; a repeated row sits where its last time puts it.
List<EventGroup> foldEvents(Iterable<EventRecord> list) {
  final groups = <EventGroup>[], last = <String, EventGroup>{};
  for (final e in list) {
    final k = eventFoldKey(e), g = last[k];
    if (g != null && e.at - g.at <= eventRepeatWindow.inMilliseconds) {
      g.items.add(e);
      g.at = e.at;
      g.ev = e;
      if (_rank(e.level) > _rank(g.level)) g.level = e.level;
      groups.remove(g);
      groups.add(g);
    } else {
      final n = EventGroup(e);
      groups.add(n);
      last[k] = n;
    }
  }
  return groups;
}

int dayStart(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// Whole days between [ms] and [now] (calendar days).
int daysAgo(int ms, int now) {
  final a = DateTime.fromMillisecondsSinceEpoch(now), b = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;
}

/// The temporary filter of the Events tab (forgotten with the page).
class EventFilter {
  String q = '';
  bool problems = false;

  /// The «Background» chip is off: events from while the screen was off are hidden.
  bool hideBg = false;

  /// Switched-off types (`cat/type`).
  final off = <String>{};

  int get count => (q.isEmpty ? 0 : 1) + (problems ? 1 : 0) + (hideBg ? 1 : 0) + offCats.length;

  /// The categories with at least one type switched off.
  List<(String, List<String>)> get offCats => [
    for (final c in eventCats)
      if (c.$2.any((t) => off.contains('${c.$1}/$t'))) c,
  ];

  /// The number of types still on in a category.
  int typesOn((String, List<String>) c) => c.$2.where((t) => !off.contains('${c.$1}/$t')).length;

  /// [text] is the sentence of the event plus its data values, lower case (the UI words it).
  bool visible(EventRecord e, {required bool showOwn, required String Function(EventRecord e) text}) {
    if (e.cat == 'user' && !showOwn) return false;
    if (problems && e.level == 'info') return false;
    if (hideBg && e.bg) return false;
    if (off.contains(e.key)) return false;
    if (q.isNotEmpty && !text(e).toLowerCase().contains(q)) return false;
    return true;
  }

  void reset() {
    q = '';
    problems = false;
    hideBg = false;
    off.clear();
  }

  void toggleType(String key) {
    if (!off.remove(key)) off.add(key);
  }

  /// All of a category's types on -> all off; otherwise -> all on.
  void toggleCat(String cat) {
    final types = [for (final t in eventCats.firstWhere((c) => c.$1 == cat).$2) '$cat/$t'];
    final allOn = types.every((k) => !off.contains(k));
    for (final k in types) {
      allOn ? off.add(k) : off.remove(k);
    }
  }
}

/// The kept part of the Logs state (`unknown['logCfg']` of the snapshot).
class LogCfg {
  LogCfg({this.showOwn = false, this.showConns = false, this.showIgnored = false, Set<int>? seen, this.rawTop, Set<int>? rawUnread})
      : seen = seen ?? <int>{},
        rawUnread = rawUnread ?? <int>{};

  factory LogCfg.fromJson(Object? j) {
    if (j is! Map) return LogCfg();
    final top = j['rawTop'];
    final unread = <int>{};
    final a = j['rawUnread'];
    if (a is List) {
      for (var i = 0; i + 1 < a.length; i += 2) {
        final from = (a[i] as num).toInt(), to = (a[i + 1] as num).toInt();
        for (var n = from; n <= to && n - from < logKeep; n++) {
          unread.add(n);
        }
      }
    }
    return LogCfg(
      showOwn: j['showOwn'] == true,
      showConns: j['showConns'] == true,
      showIgnored: j['showIgnored'] == true,
      seen: {for (final x in (j['seen'] as List? ?? const [])) if (x is num) x.toInt()},
      // -1: the core had no line yet (its numbers start at 0)
      rawTop: top is num && top >= -1 ? top.toInt() : null,
      rawUnread: unread,
    );
  }

  bool showOwn;

  /// Raw: show the lines of successful connections (off by default, they flood the log).
  bool showConns;

  /// Raw: show the failed-connection lines of ignored sites (off by default).
  bool showIgnored;

  /// Ids of the warning / error events already seen.
  final Set<int> seen;

  /// The newest raw line number taken into account; null = never kept (what the core holds counts as read).
  int? rawTop;

  /// The numbers of the raw lines not read yet.
  final Set<int> rawUnread;

  Map<String, dynamic> toJson() => {
    'showOwn': showOwn,
    'showConns': showConns,
    'showIgnored': showIgnored,
    'seen': seen.toList()..sort(),
    'rawUnread': unreadRanges(rawUnread),
    'rawTop': rawTop,
  };
}

/// `[from, to, from, to...]` of the sorted numbers.
List<int> unreadRanges(Iterable<int> set) {
  final out = <int>[];
  for (final n in ([...set]..sort())) {
    final k = out.length;
    if (k > 0 && out[k - 1] == n - 1) {
      out[k - 1] = n;
    } else {
      out.addAll([n, n]);
    }
  }
  return out;
}

/// One line of the raw log (`log()['lines']` item).
class LogLine {
  LogLine({required this.n, required this.t, required this.src, required this.lvl, required this.msg});

  factory LogLine.fromJson(Map m) => LogLine(
    n: (m['n'] as num).toInt(),
    t: (m['t'] as num?)?.toInt() ?? 0,
    src: '${m['src'] ?? 'sing-box'}',
    lvl: '${m['lvl'] ?? 'info'}',
    msg: '${m['msg'] ?? ''}',
  );

  final int n, t;
  final String src, lvl, msg;

  /// Lines of the same second, level and source follow each other under one meta line.
  String get groupKey => '${t ~/ 1000}|$lvl|$src';

  bool get problem => lvl == 'warn' || lvl == 'error';

  /// A successful connection of sing-box: `[id 5ms] inbound/mixed[mixed-in]: inbound connection to host:443`
  /// (also `outbound connection`, `packet connection`). Warnings and errors are never one.
  bool get isConn => !problem && src != 'core' && connLineRe.hasMatch(msg);
}

/// The events list as the Logs tab keeps it, fed by `events()` pages and the push stream.
class EventFeed {
  final list = <EventRecord>[];

  /// The id to ask for next (`events(since)`); null before the first answer.
  int? next;

  /// What was there when the page first looked is history: only ids from here on notify.
  int? notifyFrom;

  /// Applies an `events()` answer. Returns the events that are new (to notify: not own, from
  /// [notifyFrom]); `reset` = the numbering started over, the list was dropped (ask again).
  ({List<EventRecord> fresh, List<EventRecord> notify, bool reset, bool changed}) apply(Map r) {
    final first = next == null;
    final rNext = (r['next'] as num?)?.toInt() ?? 0;
    if (!first && rNext < next!) {
      next = null;
      list.clear();
      return (fresh: const [], notify: const [], reset: true, changed: true);
    }
    final n0 = list.length;
    final firstId = r['first'];
    if (firstId is num) list.removeWhere((e) => e.id < firstId.toInt());
    final fresh = [
      for (final m in (r['events'] as List? ?? const []))
        if (first || (m['id'] as num).toInt() >= next!) EventRecord.fromJson(m as Map),
    ];
    if (first) notifyFrom = rNext;
    next = rNext;
    list.addAll(fresh);
    if (list.length > eventKeep) list.removeRange(0, list.length - eventKeep);
    final notify = [for (final e in fresh) if (e.id >= (notifyFrom ?? 0) && !e.own) e];
    return (fresh: fresh, notify: notify, reset: false, changed: fresh.isNotEmpty || first || list.length != n0);
  }

  void clear() => list.clear();
}

/// The raw lines the Logs tab keeps, with the unread numbers (a line is read once it was in view).
class LogFeed {
  LogFeed(this.cfg);

  final LogCfg cfg;
  final lines = <LogLine>[];
  int? next;

  IgnoredSites _ignored = IgnoredSites.empty;

  // Numbers of the problem lines that name an ignored site (decided here against the current
  // list, so a site ignored a minute ago also hides what it wrote before).
  final _ignNs = <int>{};

  /// The ignored sites changed: the lines are sorted again.
  void setIgnored(IgnoredSites s) {
    _ignored = s;
    _ignNs.clear();
    for (final l in lines) {
      _markIgnored(l);
    }
  }

  void _markIgnored(LogLine l) {
    if (l.problem && _ignored.matchesText(l.msg)) _ignNs.add(l.n);
  }

  /// [l] is a failed-connection line of an ignored site.
  bool isIgnored(LogLine l) => _ignNs.contains(l.n);

  /// How many of the kept lines are from ignored sites (the hint over the Raw list).
  int get ignoredCount => _ignNs.length;

  /// Applies a `log()` answer. Returns the new lines; `reset` = the core's numbers started over.
  ({List<LogLine> fresh, bool reset}) apply(Map r) {
    final rNext = (r['next'] as num?)?.toInt() ?? 0;
    if (next != null && rNext < next!) {
      lines.clear();
      _ignNs.clear();
      next = null;
      resetUnread();
      return (fresh: const [], reset: true);
    }
    // a saved read state from a core that has since started over
    if (next == null && cfg.rawTop != null && cfg.rawTop! >= rNext) resetUnread();
    final fresh = [
      for (final m in (r['lines'] as List? ?? const []))
        if (next == null || (m['n'] as num).toInt() >= next!) LogLine.fromJson(m as Map),
    ];
    next = rNext;
    final top = cfg.rawTop;
    if (top != null) {
      for (final l in fresh) {
        if (l.n > top) cfg.rawUnread.add(l.n);
      }
    }
    cfg.rawTop = (top ?? -1) > rNext - 1 ? top : rNext - 1;
    lines.addAll(fresh);
    if (!_ignored.isEmpty) {
      for (final l in fresh) {
        _markIgnored(l);
      }
    }
    if (lines.length > logKeep) lines.removeRange(0, lines.length - logKeep);
    final lo = lines.isNotEmpty ? lines.first.n : next ?? 0;
    cfg.rawUnread.removeWhere((n) => n < lo);
    _ignNs.removeWhere((n) => n < lo);
    return (fresh: fresh, reset: false);
  }

  void resetUnread() {
    cfg.rawUnread.clear();
    cfg.rawTop = -1;
  }

  /// A Clear: the unread are gone, what the core wrote so far is taken into account.
  void clear() {
    lines.clear();
    _ignNs.clear();
    cfg.rawUnread.clear();
    final top = cfg.rawTop ?? -1, n = (next ?? 0) - 1;
    cfg.rawTop = top > n ? top : n;
  }

  /// Marks the given numbers as read; true when something was unread.
  bool markRead(Iterable<int> ns) {
    var any = false;
    for (final n in ns) {
      if (cfg.rawUnread.remove(n)) any = true;
    }
    return any;
  }

  /// The lines of the Raw tab for a level filter ('all' / 'warn') and a search.
  List<LogLine> shown(String level, String query) {
    final q = query.trim().toLowerCase();
    return [for (final l in lines) if (lineShows(l, level, q)) l];
  }

  /// [shows] with this feed's switches: Connections and Ignored sites (hidden unless switched on).
  bool lineShows(LogLine l, String level, String q) =>
      shows(l, level, q, conns: cfg.showConns) && (cfg.showIgnored || !isIgnored(l));

  /// Whether the Raw tab shows [l] for [level] and [q] (a search already trimmed and lower case).
  /// With [conns] off the sing-box lines of successful connections are left out (problems never are).
  static bool shows(LogLine l, String level, String q, {bool conns = true}) =>
      (level == 'all' || l.problem) &&
      (conns || !l.isConn) &&
      (q.isEmpty || l.msg.toLowerCase().contains(q) || l.src.contains(q));

  /// The lines the Connections switch lets through (before the level chip and the search).
  int get visibleCount => cfg.showConns && (cfg.showIgnored || _ignNs.isEmpty) ? lines.length : lines.where((l) => (cfg.showConns || !l.isConn) && (cfg.showIgnored || !isIgnored(l))).length;

  List<LogLine> get unread => [for (final l in lines) if (cfg.rawUnread.contains(l.n)) l];
}

/// The raw lines as text, one per line (copy and export).
String rawLogText(Iterable<LogLine> lines) => lines
    .map((l) => '${DateTime.fromMillisecondsSinceEpoch(l.t, isUtc: true).toIso8601String()} '
        '${l.lvl.toUpperCase().padRight(5)} ${l.src == 'core' ? '[core] ' : ''}${l.msg}')
    .join('\n');
