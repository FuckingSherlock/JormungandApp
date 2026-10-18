/// Logs tab model: the events journal as rows (repeats folded, day separators, filter, seen
/// warnings / errors, notification kinds) and the raw log (level / search filter, unread
/// lines). The Dart port of design/src/js/46-logs.js and 47-events.js; the words stay with
/// the UI (it knows the catalog and the language).
library;

import 'ignored_sites.dart';
import 'logbook.dart' show isNoiseLine;

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
    this.rev = 0,
    this.verdict,
    this.cause,
    this.op,
    this.opens,
    this.joins,
    this.why,
    this.trail,
  });

  factory EventRecord.fromJson(Map m) => EventRecord(
    id: (m['id'] as num).toInt(),
    at: (m['at'] as num?)?.toInt() ?? 0,
    cat: '${m['cat']}',
    type: '${m['type']}',
    level: '${m['level'] ?? 'info'}',
    own: m['own'] == true,
    bg: m['bg'] == true,
    rev: (m['rev'] as num?)?.toInt() ?? 0,
    log: (m['log'] as num?)?.toInt(),
    data: m['data'] is Map ? Map<String, dynamic>.from(m['data'] as Map) : <String, dynamic>{},
    verdict: m['verdict'] is String ? m['verdict'] as String : null,
    cause: (m['cause'] as num?)?.toInt(),
    op: m['op'] is Map ? Map<String, dynamic>.from(m['op'] as Map) : null,
    opens: (m['opens'] as num?)?.toInt(),
    joins: m['joins'] is List ? [for (final x in m['joins'] as List) if (x is num) x.toInt()] : null,
    why: m['why'] is Map ? Map<String, dynamic>.from(m['why'] as Map) : null,
    trail: m['trail'] is List ? [for (final s in m['trail'] as List) if (s is Map) Map<String, dynamic>.from(s)] : null,
  );

  final int id, at;
  final String cat, type, level;
  final bool own;

  /// It happened while the screen was off (a background failure, eventbook.dart).
  final bool bg;

  /// How often the core changed the event in place (a finished check); 0 = never.
  final int rev;

  /// The number of the raw line written at the same moment (null = none).
  final int? log;
  final Map<String, dynamic> data;

  /// What the Sentinel found (docs/failures.md): null = not judged; [cause] = the root event of a consequence.
  final String? verdict;
  final int? cause;

  /// The operation the event belongs to (`{id, kind}`) and, on the closing event of a pair, the id of the event it
  /// closes (eventbook.dart).
  final Map<String, dynamic>? op;
  final int? opens;

  /// The events whose rows this event takes into its own (top-level, like [cause]; docs/logs.md → «Свёртки», 5): the crash
  /// of a `conn/vpnDown`. Null = none.
  final List<int>? joins;

  /// The reason the Sentinel gave (`{code, params}`) and the checks it ran (`[{code, params, outcome, at}]`); null =
  /// none (top-level fields of the event, like [verdict]).
  final Map<String, dynamic>? why;
  final List<Map<String, dynamic>>? trail;

  String get key => '$cat/$type';

  /// The code of [why] (`net.offline`, `core.down` ...), null = no reason.
  String? get whyCode {
    final c = why?['code'];
    return c is String && c.isNotEmpty ? c : null;
  }

  /// The operation's id and kind (`reconnect`, `subUpdate` ...), null = not part of one.
  String? get opId => op?['id'] is String ? op!['id'] as String : null;
  String? get opKind => op?['kind'] is String ? op!['kind'] as String : null;
  bool get isProblem => level != 'info';

  /// The times the same thing happened (`data.repeat.at`, the newest 50: eventbook.dart → `repeated`), [at] alone for
  /// an event that was not repeated.
  List<int> get occurrences {
    final r = data['repeat'];
    final at = r is Map ? r['at'] : null;
    return at is List && at.isNotEmpty ? [for (final t in at) (t as num).toInt()] : [this.at];
  }

  /// How often it happened (`data.repeat.count`; more than [occurrences] once that list was capped), 1 = once.
  int get times {
    final r = data['repeat'];
    final n = r is Map ? r['count'] : null;
    return n is num && n > 1 ? n.toInt() : 1;
  }

  /// The last time it happened.
  int get lastAt => occurrences.last;
}

/// Categories of the journal and their types, in the filter's order (the labels are the UI's).
///
/// The complete list of what the core and the app write: `core/test/event_catalog_test.dart` scans
/// the emit sites and fails on a pair that is not here (a new event: the catalog, the label in the
/// app's `event_text.dart`, the table in docs/logs.md — one commit). `user/*` (the app's own
/// actions) is outside the catalog by design. `sub/dead` is written by the mockup only (a source
/// that stopped answering, see docs/logs.md).
const eventCats = <(String, List<String>)>[
  ('conn', ['connected', 'reconnected', 'disconnected', 'connectFailed', 'lost', 'restored', 'offline', 'online', 'failing', 'vpnDown', 'vpnUp']),
  ('net', ['switched']),
  ('auto', ['switched', 'fastest', 'unstable']),
  ('site', ['blocked', 'unreachable']),
  ('sub', ['updated', 'failed', 'removed', 'back', 'dead', 'diverged']),
  ('rules', ['fallback', 'targetBack', 'targetLost', 'targetFound', 'ruleSetFailed', 'ruleSetUpdated']),
  ('dns', ['switched', 'failed', 'failedOnNode']),
  ('node', ['addressMissing', 'lost', 'back']),
  ('speed', ['done', 'failed']),
  (
    'core',
    [
      'crashed', 'restarted', 'restartFailed', 'tunNeedsAdmin', 'down', 'sysProxy', 'deprecated', 'stateRestored', 'stateLost',
      // the app's own update (appupdate.dart)
      'updateAvailable', 'updateFailed', 'updateChannelEmpty', 'updateDownloaded', 'updateDeltaFailed', 'updateInstalled',
      // TCP through the TUN (tun_ingress.dart)
      'tunTcpDead', 'tunTcpBack',
    ],
  ),
];

/// Which Settings → Notifications toggle an event type answers to (none: never a notification).
const eventNotifKind = <String, String>{
  'auto/switched': 'autoSwitch', 'auto/fastest': 'autoSwitch', 'auto/unstable': 'unstable',
  'conn/lost': 'connLost', 'conn/restored': 'connLost',
  // «VPN не работает»: the one notification of a sing-box that does not come up or a network that is gone (docs/logs.md);
  // the crash events, conn/offline / online and the old core/down are the journal's
  'conn/vpnDown': 'connLost', 'conn/vpnUp': 'connLost',
  // TCP through the TUN is dead / back: the same family as a lost connection
  'core/tunTcpDead': 'connLost', 'core/tunTcpBack': 'connLost',
  // many failing connections of one app: what «Site does not open» is, one level up
  'conn/failing': 'blocked',
  'site/blocked': 'blocked', 'site/unreachable': 'blocked', 'sub/updated': 'subUpdated',
  'sub/failed': 'subFailed', 'sub/removed': 'subFailed', 'sub/back': 'subFailed', 'sub/dead': 'subFailed',
  'rules/ruleSetFailed': 'ruleSets',
  'rules/fallback': 'autoSwitch', 'rules/targetBack': 'autoSwitch', 'dns/switched': 'autoSwitch',
  // a rule's target is gone / off / without servers: its traffic goes by "If unavailable" (the same family as rules/fallback)
  'rules/targetLost': 'autoSwitch', 'rules/targetFound': 'autoSwitch',
  // the node's server name does not exist: the provider's subscription is wrong
  'node/addressMissing': 'subFailed',
  // the connection ended by an error / the system proxy failed (eventNotifies narrows both down); a disconnect by the
  // system (a revoked VPN) is `vpnRevoked`, see [eventNotifKindOf]
  'conn/connectFailed': 'connLost', 'conn/disconnected': 'connLost', 'core/tunNeedsAdmin': 'connLost', 'core/sysProxy': 'connLost',
  'core/stateLost': 'appData', 'core/stateRestored': 'appData',
  'dns/failed': 'dnsFailed',
};

/// The toggle [e] answers to: [eventNotifKind] by its type, except `conn/disconnected` by the system (the VPN was
/// revoked), which has a toggle of its own.
String? eventNotifKindOf(EventRecord e) {
  if (e.key == 'conn/disconnected' && e.data['by'] == 'system') return 'vpnRevoked';
  // the warn variation of a subscription update (it removed used servers) is a failure, a plain one is the news
  if (e.key == 'sub/updated') return e.level == 'info' ? 'subUpdated' : 'subFailed';
  return eventNotifKind[e.key];
}

/// The end of an outage by the user or the system (`conn/vpnUp` with `by: user` / `system`): not a recovery, never a
/// notification of its own.
bool _vpnUpEndsByDisconnect(EventRecord e) => e.key == 'conn/vpnUp' && (e.data['by'] == 'user' || e.data['by'] == 'system');

/// Warnings and errors that are a journal entry only, never a notification, with the reason. The guard test
/// (`core/test/event_catalog_test.dart`) checks that every warn / error type of the catalog is either in
/// [eventNotifKind] or here, so a new problem type must decide on purpose. `net/switched` is info but listed so the
/// choice is explicit.
const journalOnly = <String, String>{
  'dns/failedOnNode': 'a consequence of dns/failed, the node is only named',
  'core/deprecated': 'a hint about the config, nothing the user can fix right now',
  'speed/failed': 'the user ran the test and sees the result',
  'core/updateFailed': 'a background update check; the user is not waiting for it',
  'core/updateDeltaFailed': 'the full download follows',
  'core/updateChannelEmpty': 'nothing to update to',
  'sub/diverged': 'a note about two copies of a subscription',
  'net/switched': 'the network changed; the journal explains what followed',
  'core/crashed': 'joins conn/vpnDown when sing-box does not come back in 30 s, which is the notification',
  'core/restartFailed': 'joins conn/vpnDown when sing-box does not come back in 30 s, which is the notification',
  'core/down': 'no longer written; replaced by conn/vpnDown',
  'conn/offline': 'only a journal entry; a network that stays gone while connected is conn/vpnDown',
  'node/lost': 'the user switched the node off or deleted it themselves',
  'node/back': 'the user switched the node on again',
};

/// Settings → Notifications as they start (`notifCfg` of the snapshot, names as in the mockup).
const notifDefaults = <String, bool>{
  'enabled': true,
  'status': true,
  'autoSwitch': true,
  'unstable': true,
  'connLost': true,
  'vpnRevoked': true,
  'blocked': true,
  'subUpdated': false,
  'subFailed': true,
  'ruleSets': true,
  'updateAvailable': true,
  'appData': true,
  'dnsFailed': true,
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
  final kind = eventNotifKindOf(e);
  if (kind == null || !notifAllows(cfg, kind)) return false;
  if (_vpnUpEndsByDisconnect(e)) return false;
  // only a disconnect by an error or by the system is news (not the user's own); the system proxy only when it failed
  if (e.key == 'conn/disconnected' && e.data['by'] != 'error' && e.data['by'] != 'system') return false;
  if (e.key == 'core/sysProxy' && e.data['error'] == null) return false;
  // judged by the Sentinel: only a confirmed root cause notifies (a blip, a consequence, a workaround, an unexplained failure stay
  // in the journal); site/blocked is always a workaround and notifies as before: it offers a rule for the route that opens it
  final v = e.verdict;
  if (v != null && e.key != 'site/blocked' && (v != 'confirmed' || e.cause != null)) return false;
  // A site that failed through every route is quiet until the external checker says it opens elsewhere
  // (pending, off, failed and "down everywhere" stay in the journal); a manual check is the user's own.
  // a node that is not in use is a journal entry only (the user does not lean on it)
  if (e.key == 'node/addressMissing' && e.data['inUse'] != true) return false;
  final check = e.key == 'site/unreachable' ? e.data['check'] : null;
  if (check is Map && (check['state'] != 'opens' || check['manual'] == true)) return false;
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
  'rules/targetLost': ['rule', 'app', 'target'],
  'rules/targetFound': ['rule', 'app', 'target'],
  'dns/switched': ['from', 'to'],
  'dns/failed': ['server'],
  'dns/failedOnNode': ['server', 'node'],
  'node/addressMissing': ['host'],
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

/// A row of the Events list (docs/logs.md → «Свёртки»). Five mechanisms put events into one row:
///
/// - **repeats** ([repeats]): the same event again within 10 minutes of its last time (only events with no `cause`,
///   `op` or `opens` of their own; the core's own repeats are one event with `data.repeat`, see [EventRecord.times]);
/// - **consequences** ([related]): events whose `cause` is the row's event (the root);
/// - **closing** ([closers]): events whose `opens` is the row's event ([closer], [closed]);
/// - **operation** ([parts]): events with the same `op.id` (the first of them is the [head] of the row);
/// - **joining** ([EventRecord.joins]): the rows of the listed events (their consequences, repeats and closing too) are
///   steps in [related] of the joining event's row; a closing event of a joined event is a step, it does not close the row.
///
/// A row of consequences whose root is not in the journal (`net.captive` is never written, or the root was pruned) has
/// no [head]: [isGroup], [whyCode] is its heading. [items] is every event of the row, oldest first.
///
/// The place of a row in the list is [at]: an anchored row (it has consequences, a closer or operation parts, or it is
/// a group) stays where it first appeared; a row of plain repeats sits where its last time puts it.
class EventGroup {
  EventGroup(EventRecord e)
      : head = e,
        whyCode = null,
        items = [e],
        repeats = [e],
        related = [],
        closers = [],
        parts = [],
        at = e.at,
        level = e.level,
        lastAt = e.lastAt,
        opId = e.opId,
        opKind = e.opKind;

  EventGroup._noRoot(EventRecord e, String code)
      : head = null,
        whyCode = code,
        items = [e],
        repeats = [],
        related = [e],
        closers = [],
        parts = [],
        at = e.at,
        level = e.level,
        lastAt = e.lastAt,
        opId = null,
        opKind = null;

  /// The event the row stands for: the root, the opening event of a pair, the first event of an operation, the first
  /// of the repeats. Null for a group row ([isGroup]).
  final EventRecord? head;

  /// A row of consequences without a root event; [whyCode] is the `why.code` they share.
  bool get isGroup => head == null;
  final String? whyCode;

  /// Every event of the row, oldest first.
  final List<EventRecord> items;

  /// [head] and its repeats (empty for a group row).
  final List<EventRecord> repeats;

  /// The consequences (`cause`) of [head]; for a group row all of its events.
  final List<EventRecord> related;

  /// The events that close a pair (`opens`): of [head] (see [closer]) or of another event of the row (`sub/back` of a
  /// `sub/removed` inside). May overlap [parts].
  final List<EventRecord> closers;

  /// The other events of the same operation as [head] (`op.id`), the user's `user/*` that started it among them.
  final List<EventRecord> parts;

  /// The operation of the row (set when [head] has one): `reconnect`, `subUpdate`, `subUpdateAll`, `ruleSets`,
  /// `connection`, `appUpdate`.
  final String? opId, opKind;

  /// The place of the row in the list (see above) and the last time of anything in it ([EventRecord.lastAt]).
  int at;
  int lastAt;

  /// The worst level of all the events of the row.
  String level;

  /// For a search: the row is shown because of an event other than [head] (the UI unfolds it).
  bool hitInside = false;

  /// The row's identity: [head]'s id (rows that took others in, [_join], keep it), the first event of a group row.
  int get key => head?.id ?? items.first.id;
  bool get problem => level != 'info';

  /// The event that words the row: the last of the repeats of [head]; the last event of an `appUpdate` operation
  /// (the status is the last stage); the first event of a group row. [head] and [last] are there for the UI to choose.
  EventRecord get ev {
    if (head == null) return related.first;
    return opKind == 'appUpdate' ? items.last : repeats.last;
  }

  /// The newest event of the row (a crash chain: its status is that of the last event).
  EventRecord get last => items.last;

  /// The worst event of the row, the newest on a tie.
  EventRecord get worst => items.reversed.reduce((a, b) => _rank(b.level) > _rank(a.level) ? b : a);

  /// How often the row's events happened in all (a repeated event counts its repeats): [head]'s repeats; the events of
  /// a group row.
  int get times => (head == null ? items : repeats).fold(0, (n, x) => n + x.times);

  /// «+N связанных»: how many consequences, a repeated one counted by its repeats.
  int get relatedCount => related.fold(0, (n, x) => n + x.times);

  /// The time of the newest consequence (0 = none).
  int get relatedLastAt => related.isEmpty ? 0 : related.map((x) => x.lastAt).reduce((a, b) => a > b ? a : b);

  /// The row of a closing event stands on its own: the id of the event it closes (null = not a closing row, or the
  /// opening event is not in the journal).
  int? opensId;

  /// The id of the event that closed [head] (its row is the closing event's own), null = not closed.
  int? get closedById => closer?.id;

  /// The event that closed [head], the newest if several; null = not closed (or a group row).
  EventRecord? get closer {
    for (var i = closers.length - 1; i >= 0; i--) {
      final o = closers[i].opens;
      if (o != null && _isHead(o)) return closers[i];
    }
    return null;
  }

  /// [head] is closed («завершилось»: the UI colours the row «resolved»).
  bool get closed => closer != null;

  /// How long [head] lasted until [closer], null = not closed.
  int? get closedAfter => closer == null ? null : closer!.at - head!.at;

  /// Event [id] of this row was closed by another event of it.
  bool isClosed(int id) => closers.any((c) => c.opens == id);

  /// Whether the row keeps its place (see the class comment).
  bool get anchored => head == null || related.isNotEmpty || closers.isNotEmpty || parts.isNotEmpty || (opId != null);

  bool _isHead(int id) => repeats.any((r) => r.id == id);

  void _take(EventRecord e) {
    items.add(e);
    if (_rank(e.level) > _rank(level)) level = e.level;
    if (e.lastAt > lastAt) lastAt = e.lastAt;
  }

  void _repeat(EventRecord e) {
    if (!anchored) at = e.at;
    _take(e);
    repeats.add(e);
  }

  void _relate(EventRecord e) {
    _take(e);
    related.add(e);
  }

  /// Notes the closing event [e]; its row is its own, so it is not one of [items].
  void _close(EventRecord e) {
    closers.add(e);
  }

  /// Takes the row [g] of an event listed in [EventRecord.joins] into this one: all its events are steps (`related`),
  /// whatever they were there; [items] stay oldest first.
  void _join(EventGroup g) {
    related.addAll(g.items);
    items.addAll(g.items);
    related.sort((a, b) => a.id.compareTo(b.id));
    items.sort((a, b) => a.id.compareTo(b.id));
    for (final x in g.items) {
      if (_rank(x.level) > _rank(level)) level = x.level;
      if (x.lastAt > lastAt) lastAt = x.lastAt;
    }
  }

  void _part(EventRecord e) {
    _take(e);
    parts.add(e);
    final o = e.opens;
    if (o != null && _isHead(o)) closers.add(e);
  }
}

int _rank(String l) => l == 'error' ? 2 : l == 'warn' ? 1 : 0;

/// Folds [list] (oldest first) into rows (see [EventGroup]).
///
/// [shown]: whether the filter lets an event stand as a row of its own (type, level, Own, Background). An event the
/// filter hides never makes a row, but still joins the row of its root / pair / operation when that row exists (the
/// status of a row stays true under a filter). A consequence whose root is hidden is a row of its own (not a group row:
/// the root is not missing); so is a closing event whose opening one is hidden or gone.
/// [matches]: the text search, apart from [shown] on purpose: a row stays when its [EventGroup.head] or any event of it
/// matches, and [EventGroup.hitInside] says that it was an event other than the head. The caller passes the whole
/// journal here (`EventFilter.fold` does it); a list already narrowed by the filter folds as before, without the
/// consequences of a hidden root.
List<EventGroup> foldEvents(
  Iterable<EventRecord> list, {
  bool Function(EventRecord e)? shown,
  bool Function(EventRecord e)? matches,
}) {
  final window = eventRepeatWindow.inMilliseconds;
  final rows = <EventGroup>[];
  final plain = <String, EventGroup>{}, byOp = <String, EventGroup>{}, byCode = <String, EventGroup>{};
  final byId = <int, EventGroup>{};
  final hidden = <int>{};
  final events = list.toList();
  // joined event -> the event that joins it; an id the journal does not have joins nothing
  final present = {for (final e in events) e.id};
  final joinedBy = <int, int>{};
  for (final e in events) {
    for (final id in e.joins ?? const <int>[]) {
      if (id != e.id && present.contains(id)) joinedBy.putIfAbsent(id, () => e.id);
    }
  }
  // [e] has landed in [row]: the rows of the events it joins (when they already stand) become steps of [row]
  void join(EventRecord e, EventGroup row) {
    for (final id in e.joins ?? const <int>[]) {
      final g = byId[id];
      // only a row that stands for the joined event itself; one it is merely a part of is not taken whole
      if (g == null || identical(g, row) || g.head?.id != id) continue;
      row._join(g);
      rows.remove(g);
      byId.updateAll((_, v) => identical(v, g) ? row : v);
      byOp.updateAll((_, v) => identical(v, g) ? row : v);
      // a later crash of the same kind must not repeat into this row
      plain.removeWhere((_, v) => identical(v, g));
      byCode.removeWhere((_, v) => identical(v, g));
    }
  }

  for (final e in events) {
    final opId = e.opId;
    // the operation's row, if it started: a `user/*` that started it, `core/sysProxy` inside a reconnect ...
    final inOp = opId == null ? null : byOp[opId];
    if (inOp != null) {
      inOp._part(e);
      byId[e.id] = inOp;
      join(e, inOp);
      continue;
    }
    // the closing event lies in the row of the event it closes; the closing of a joined event is a step there
    final opened = e.opens == null ? null : byId[e.opens!];
    if (opened != null) {
      if (joinedBy.containsKey(e.opens)) {
        opened._relate(e);
        byId[e.id] = opened;
        if (opId != null) byOp[opId] = opened;
        join(e, opened);
        continue;
      }
      // the opening row knows its closer; the closing event is a row of its own (when the filter lets it)
      opened._close(e);
      if (shown != null && !shown(e)) {
        hidden.add(e.id);
        byId[e.id] = opened;
        continue;
      }
      final n = EventGroup(e)..opensId = e.opens;
      rows.add(n);
      byId[e.id] = n;
      if (opId != null) byOp[opId] = n;
      join(e, n);
      continue;
    }
    // a consequence lies in the row of its root
    final root = e.cause == null ? null : byId[e.cause!];
    if (root != null) {
      root._relate(e);
      byId[e.id] = root;
      if (opId != null) byOp[opId] = root;
      join(e, root);
      continue;
    }
    // an event the row of its joiner (written earlier) takes in, the filter or not
    final joiner = joinedBy[e.id];
    final into = joiner == null ? null : byId[joiner];
    if (into != null) {
      into._relate(e);
      byId[e.id] = into;
      if (opId != null) byOp[opId] = into;
      continue;
    }
    if (shown != null && !shown(e)) {
      hidden.add(e.id);
      continue;
    }
    // a consequence of a root that is not in the journal: a group row by the reason (a hidden root is not missing)
    final code = e.verdict == 'consequence' ? e.whyCode : null;
    if (code != null && (e.cause == null || !hidden.contains(e.cause))) {
      final k = '$code|${e.cause ?? ''}', h = byCode[k];
      if (h != null && e.at - h.lastAt <= window) {
        h._relate(e);
        byId[e.id] = h;
        join(e, h);
      } else {
        final n = EventGroup._noRoot(e, code);
        rows.add(n);
        byCode[k] = n;
        byId[e.id] = n;
        join(e, n);
      }
      continue;
    }
    final linked = e.cause != null || opId != null || e.opens != null || (e.joins?.isNotEmpty ?? false);
    final k = linked ? '' : eventFoldKey(e), p = linked ? null : plain[k];
    if (p != null && p.closer == null && e.at - p.repeats.last.at <= window) {
      final moves = !p.anchored;
      p._repeat(e);
      byId[e.id] = p;
      if (moves) {
        rows.remove(p);
        rows.add(p);
      }
      continue;
    }
    final n = EventGroup(e);
    if (e.opens != null && present.contains(e.opens)) n.opensId = e.opens;
    rows.add(n);
    byId[e.id] = n;
    if (!linked) plain[k] = n;
    if (opId != null) byOp[opId] = n;
    join(e, n);
  }
  if (matches == null) return rows;
  return [
    for (final g in rows)
      if (_searchHit(g, matches)) g,
  ];
}

bool _searchHit(EventGroup g, bool Function(EventRecord e) matches) {
  if (g.repeats.any(matches)) return true;
  if (!g.items.any((e) => !g.repeats.contains(e) && matches(e))) return false;
  g.hitInside = true;
  return true;
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

/// Types the Events type filter never hides (docs/logs.md → «Линия VPN»): the rows of the VPN line.
const Set<String> alwaysShownTypes = {'conn/connected', 'conn/disconnected', 'conn/reconnected', 'conn/vpnDown', 'conn/vpnUp'};

/// The state of the VPN on the line of the Events list.
enum VpnLine { on, down, waiting, off }

/// The mark of an event on the line: none, a state change (dot), a reconnect with no change (ring).
enum VpnDot { none, change, reconnect }

/// The VPN line at one event: the state [above] it (the older side), [below] it (after it) and the mark.
class VpnMark {
  final VpnLine above;
  final VpnLine below;
  final VpnDot dot;
  const VpnMark(this.above, this.below, this.dot);
}

/// The VPN line over the whole journal (not the filtered view), oldest first; the key is the event id.
Map<int, VpnMark> vpnLineMarks(Iterable<EventRecord> journal) {
  const stateKeys = {'conn/connected', 'conn/disconnected', 'conn/reconnected', 'conn/vpnDown', 'conn/vpnUp'};
  final events = journal.toList();
  // before the first state event: connected first - the VPN was off; vpnUp first - it was down; any other state
  // event first - it was on; no state events at all - off
  var cur = VpnLine.off;
  for (final e in events) {
    if (stateKeys.contains(e.key)) {
      cur = switch (e.key) { 'conn/connected' => VpnLine.off, 'conn/vpnUp' => VpnLine.down, _ => VpnLine.on };
      break;
    }
  }
  final out = <int, VpnMark>{};
  for (final e in events) {
    final above = cur;
    var dot = VpnDot.none;
    switch (e.key) {
      case 'conn/connected':
        cur = VpnLine.on;
        dot = VpnDot.change;
      case 'conn/disconnected':
        cur = VpnLine.off;
        dot = VpnDot.change;
      case 'conn/reconnected':
        dot = VpnDot.reconnect;
      case 'conn/vpnDown':
        final c = e.data['causes'];
        final next = c is List && c.length == 1 && c.first == 'network' ? VpnLine.waiting : VpnLine.down;
        if (next != cur) dot = VpnDot.change;
        cur = next;
      case 'conn/vpnUp':
        cur = e.data['by'] == 'user' || e.data['by'] == 'system' ? VpnLine.off : VpnLine.on;
        dot = VpnDot.change;
    }
    out[e.id] = VpnMark(above, cur, dot);
  }
  return out;
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
      if (c.$2.any((t) => off.contains('${c.$1}/$t') && !alwaysShownTypes.contains('${c.$1}/$t'))) c,
  ];

  /// The number of types still on in a category (the always shown ones count as on).
  int typesOn((String, List<String>) c) =>
      c.$2.where((t) => !off.contains('${c.$1}/$t') || alwaysShownTypes.contains('${c.$1}/$t')).length;

  /// [text] is the sentence of the event plus its data values, lower case (the UI words it).
  bool visible(EventRecord e, {required bool showOwn, required String Function(EventRecord e) text}) =>
      shown(e, showOwn: showOwn) && matches(e, text);

  /// Everything of the filter but the text: [e] may stand as a row of its own (what [foldEvents] asks as `shown`).
  bool shown(EventRecord e, {required bool showOwn}) {
    if (e.cat == 'user' && !showOwn) return false;
    if (problems && e.level == 'info') return false;
    if (hideBg && e.bg) return false;
    if (off.contains(e.key) && !alwaysShownTypes.contains(e.key)) return false;
    return true;
  }

  /// The text search alone: [text] words [e] ([visible]); true when the search is empty.
  bool matches(EventRecord e, String Function(EventRecord e) text) => q.isEmpty || text(e).toLowerCase().contains(q);

  /// The rows of the Events list for the whole journal [all] (oldest first) under this filter: a consequence whose root
  /// the filter hides is a row of its own, a search that hits a consequence keeps the root's row
  /// ([EventGroup.hitInside]). Prefer it to `foldEvents` of an already filtered list.
  List<EventGroup> fold(Iterable<EventRecord> all, {required bool showOwn, required String Function(EventRecord e) text}) =>
      foldEvents(all, shown: (e) => shown(e, showOwn: showOwn), matches: q.isEmpty ? null : (e) => matches(e, text));

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
    final types = [for (final t in eventCats.firstWhere((c) => c.$1 == cat).$2) if (!alwaysShownTypes.contains('$cat/$t')) '$cat/$t'];
    final allOn = types.every((k) => !off.contains(k));
    for (final k in types) {
      allOn ? off.add(k) : off.remove(k);
    }
  }
}

/// The kept part of the Logs state (`unknown['logCfg']` of the snapshot).
class LogCfg {
  LogCfg({
    this.showOwn = false,
    this.showConns = false,
    this.showIgnored = false,
    Set<int>? seen,
    this.rawTop,
    Set<int>? rawUnread,
    Set<String>? openCats,
  })  : seen = seen ?? <int>{},
        rawUnread = rawUnread ?? <int>{},
        openCats = openCats ?? <String>{};

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
      openCats: {for (final x in (j['openCats'] as List? ?? const [])) if (x is String) x},
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

  /// The categories the user unfolded in the Events filter sheet (all folded by default); kept.
  final Set<String> openCats;

  Map<String, dynamic> toJson() => {
    'showOwn': showOwn,
    'showConns': showConns,
    'showIgnored': showIgnored,
    'openCats': openCats.toList()..sort(),
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

  /// A line of the connection flood — what the Raw view's «Connections» switch shows: a successful
  /// connection of sing-box (`[id 5ms] inbound/mixed[mixed-in]: inbound connection to host:443`, also
  /// `outbound connection`, `packet connection`) or the program behind one (`router: found package
  /// name: org.x`, `found process path`). Warnings and errors are never one ([isNoiseLine]).
  ///
  /// Decided once per line (lazily): the Raw view asks for every kept line on each filter pass and
  /// each count, and two regexes over thousands of lines were the cost of opening and scrolling it.
  late final bool isConn = !problem && src != 'core' && isNoiseLine(msg);
}

/// The events list as the Logs tab keeps it, fed by `events()` pages and the push stream.
class EventFeed {
  final list = <EventRecord>[];

  /// The id to ask for next (`events(since)`); null before the first answer.
  int? next;

  /// What was there when the page first looked is history: only ids from here on notify.
  int? notifyFrom;

  final _told = <int>{};

  /// Records that event [id] was notified; false when it already was. An event notifies once, whatever changes it
  /// afterwards in place (a repeat of the same site event, a finished check): the caller asks this after
  /// [eventNotifies] said yes.
  bool markNotified(int id) => _told.add(id);

  // The ids of the notifications shown (`opens ?? cause ?? id` of a notified event: what a closing event replaces).
  final _shown = <int>{};

  /// Whether [e] notifies now (the caller shows it when true): [eventNotifies] says yes, or [e] is a closing event
  /// (`opens`) and the notification it replaces was already shown, whatever the closing event's own toggle says (nothing
  /// stays in the shade after the recovery; docs/logs.md → «Свёртки», 2). True once per event, whatever changes it in
  /// place afterwards. Replaces `eventNotifies(cfg, e) && markNotified(e.id)`.
  bool notify(Object? cfg, EventRecord e) {
    if (_told.contains(e.id) || _vpnUpEndsByDisconnect(e)) return false;
    final opens = e.opens;
    if (!eventNotifies(cfg, e) && !(opens != null && _shown.contains(opens))) return false;
    _told.add(e.id);
    _shown.add(opens ?? e.cause ?? e.id);
    return true;
  }

  /// Applies an `events()` answer. Returns the events that are new (to notify: not own, from
  /// [notifyFrom]); `reset` = the numbering started over, the list was dropped (ask again).
  ({List<EventRecord> fresh, List<EventRecord> notify, bool reset, bool changed}) apply(Map r) {
    final first = next == null;
    final rNext = (r['next'] as num?)?.toInt() ?? 0;
    if (!first && rNext < next!) {
      next = null;
      list.clear();
      _told.clear();
      _shown.clear();
      return (fresh: const [], notify: const [], reset: true, changed: true);
    }
    final n0 = list.length;
    final firstId = r['first'];
    if (firstId is num) {
      list.removeWhere((e) => e.id < firstId.toInt());
      _told.removeWhere((id) => id < firstId.toInt());
      _shown.removeWhere((id) => id < firstId.toInt());
    }
    final fresh = [
      for (final m in (r['events'] as List? ?? const []))
        if (first || (m['id'] as num).toInt() >= next!) EventRecord.fromJson(m as Map),
    ];
    if (first) notifyFrom = rNext;
    next = rNext;
    list.addAll(fresh);
    if (list.length > eventKeep) list.removeRange(0, list.length - eventKeep);
    final notify = [for (final e in fresh) if (e.id >= (notifyFrom ?? 0) && !e.own) e];
    // events the core changed in place (a finished check): the newer `rev` replaces the one kept; it may
    // newly be worth a notification (the caller still asks [eventNotifies])
    var moved = false;
    for (final m in (r['updated'] as List? ?? const [])) {
      final e = EventRecord.fromJson(m as Map);
      final at = list.indexWhere((x) => x.id == e.id);
      if (at < 0 || list[at].rev >= e.rev) continue;
      list[at] = e;
      moved = true;
      if (e.id >= (notifyFrom ?? 0) && !e.own && !notify.any((x) => x.id == e.id)) notify.add(e);
    }
    return (fresh: fresh, notify: notify, reset: false, changed: fresh.isNotEmpty || first || list.length != n0 || moved);
  }

  void clear() {
    list.clear();
    _told.clear();
    _shown.clear();
  }
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
