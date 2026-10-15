/// Failed connections, caught and surfaced: one classifier ([ConnOutcome]) for what a closed
/// connection says about itself, and the rolling book of them ([FailureBook]) with the
/// `conn/failing` event. The same numbers answer «what is failing right now, for whom, through
/// which route» in the report, and later «Direct → if it does not open → the target».
///
/// Two sources, both from the one sing-box that runs:
/// - the API service's closed connections ([ClosedConnection]): who asked for what, through which
///   outbound, how many bytes each way, how long it lived — the verdict;
/// - its log lines (`connection: open connection to H:P using outbound/…: <error>`): the reason a
///   dial failed, which the closed record does not carry — a hint that refines the verdict.
library;

import 'dart:async';

import 'rulenames.dart' show processEventData;
import 'sbapi.dart' show ClosedConnection;

/// How a request ended.
enum ConnKind {
  /// Something came back (`down > 0`).
  ok,

  /// The far side or the network said no: `connection refused`, a rejected handshake, no route.
  refused,

  /// The connection was cut after it was made: `connection reset`, EOF, broken pipe.
  reset,

  /// It did not answer in time: `i/o timeout`, `deadline exceeded`, or a dial that never ended
  /// (nothing sent, nothing back, a long time).
  timeout,

  /// Bytes went out and nothing came back for long (`up > 0`, `down == 0`, past
  /// [ConnOutcome.instantMs]): the node or the site swallows the request.
  stalled,

  /// Nothing came back and it was over almost at once ([ConnOutcome.instantMs]); sing-box reports
  /// `up == 0` for most of them, so the bytes sent do not decide this one.
  instantRefusal,

  /// The name did not resolve.
  dnsFail,
}

/// The verdict on one closed connection. One place for «did it get anything back»: Auto's failed
/// request ([isFailure]), the failure book and the reports read it from here.
class ConnOutcome {
  const ConnOutcome._(this.kind, {this.sent = false, this.durationMs, this.idle = false});

  final ConnKind kind;

  /// Bytes went out (`up > 0`).
  final bool sent;

  /// How long it lived, ms (null = not told).
  final int? durationMs;

  /// Nothing moved either way for a long time ([idleMs]): a pooled connection that was never used and
  /// was closed — neither a success nor a failed request. Its [kind] is [ConnKind.ok] and the book
  /// does not count it.
  final bool idle;

  bool get ok => kind == ConnKind.ok;
  bool get failed => !ok;

  /// `down == 0` and over within this many ms = [ConnKind.instantRefusal]; past it, [ConnKind.stalled]
  /// (bytes sent) or [ConnKind.timeout] (none). A refusal through a proxy chain takes the round trips
  /// to the far side, which a mobile link makes a second or more.
  static const instantMs = 2000;

  /// A connection that lived this long with no byte either way is idle, not failed.
  static const idleMs = 60000;

  /// The core's definition of a request that got nothing back: the connection closed with no byte
  /// from the far side. What Auto's `onClosed` has always judged by.
  static bool isFailure(ClosedConnection c) => c.down == 0;

  /// [hint]: the kind a nearby log line named for this connection (see [kindOfError]); it wins over
  /// the timing guess when nothing came back.
  factory ConnOutcome.of(ClosedConnection c, {ConnKind? hint}) {
    final d = c.durationMs, sent = c.up > 0;
    if (!isFailure(c)) return ConnOutcome._(ConnKind.ok, sent: sent, durationMs: d);
    if (hint != null) return ConnOutcome._(hint, sent: sent, durationMs: d);
    if (c.up == 0 && d != null && d >= idleMs) return ConnOutcome._(ConnKind.ok, durationMs: d, idle: true);
    final ConnKind k;
    if (d != null && d < instantMs) {
      k = ConnKind.instantRefusal;
    } else if (sent) {
      k = ConnKind.stalled;
    } else {
      k = d == null ? ConnKind.instantRefusal : ConnKind.timeout;
    }
    return ConnOutcome._(k, sent: sent, durationMs: d);
  }

  /// What the error text of a failed dial says (the tail of `open connection to H:P using …: <err>`);
  /// null = not a failure of the request (the client gave up: `canceled by local`) or not known —
  /// the timing decides then.
  static ConnKind? kindOfError(String err) {
    final e = err.toLowerCase();
    if (e.contains('canceled by local') || e.contains('context canceled')) return null;
    if (e.contains('no such host') || e.contains('lookup ') || e.contains('server misbehaving') || e.contains('dns')) return ConnKind.dnsFail;
    if (e.contains('timeout') || e.contains('timed out') || e.contains('deadline exceeded')) return ConnKind.timeout;
    if (e.contains('connection reset') ||
        e.contains('reset by peer') ||
        e.contains('broken pipe') ||
        e.contains('unexpected eof') ||
        e.contains('canceled by remote') ||
        e.trim() == 'eof' ||
        e.endsWith(': eof')) {
      return ConnKind.reset;
    }
    if (e.contains('refused') ||
        e.contains('unreachable') ||
        e.contains('no route to host') ||
        e.contains('verification failed') ||
        e.contains('handshake') ||
        e.contains('authentication') ||
        e.contains('unauthorized') ||
        e.contains('forbidden') ||
        e.contains('rejected') ||
        e.contains('tls:')) {
      return ConnKind.refused;
    }
    return null;
  }
}

/// A line of sing-box's log without its prefixes: the connection id (null = the line has none) and
/// the text after `[id duration] `. Takes the stamped (`+0300 2026-… INFO …`), the bare
/// (`INFO[0003] …`), the coloured and the exported (`2026-…Z INFO  …`) forms alike.
class SbLine {
  const SbLine(this.id, this.body);
  final String? id;
  final String body;

  static final _ansi = RegExp(r'\x1B\[[0-9;]*m');
  static final _idRe = RegExp(r'\[(\d{1,10}) [0-9][^\]\s]*\] ');

  factory SbLine.parse(String raw) {
    if (raw.contains('\x1B')) raw = raw.replaceAll(_ansi, '');
    final m = _idRe.firstMatch(raw);
    return m == null ? SbLine(null, raw) : SbLine(m[1], raw.substring(m.end));
  }
}

/// `host:port` of a destination as sing-box writes it (an IPv6 host stays in its brackets);
/// port 0 = none.
(String, int) splitDest(String dest) {
  final at = dest.lastIndexOf(':');
  if (at < 0 || dest.endsWith(']')) return (dest, 0);
  final port = int.tryParse(dest.substring(at + 1));
  return port == null ? (dest, 0) : (dest.substring(0, at), port);
}

/// The inbound the core's own measurements go in through (probe.dart): never counted.
const _probeInbound = 'probe-in';

/// The core's own service traffic (svc_fetch.dart): a failing path of the race is not a failed connection
/// of a user's app; a request that failed on every path is reported by the fetcher itself (`svc.fetch`).
const _svcInbound = 'svc-in';

/// The core's own requests through the tunnel (subscriptions, the exit check): counted, never an event.
const _tunnelInbound = 'tunnel-in';

// NB: a connection of this app's own process that entered the TUN (the self rule, config.dart → selfRules) is
// not a user's app either: the book takes it out through [FailureBook.own] before anything is counted.

// The ring of 10 one-minute buckets: «the last 10 minutes» without a timestamp per request.
class _Buckets {
  static const n = 10;
  final ok = List<int>.filled(n, 0), bad = List<int>.filled(n, 0), stamp = List<int>.filled(n, -1);

  void add(int minute, {required bool failed}) {
    final i = minute % n;
    if (stamp[i] != minute) {
      stamp[i] = minute;
      ok[i] = 0;
      bad[i] = 0;
    }
    if (failed) {
      bad[i]++;
    } else {
      ok[i]++;
    }
  }

  int okIn(int minute) => _sum(ok, minute);
  int badIn(int minute) => _sum(bad, minute);

  int _sum(List<int> a, int minute) {
    var s = 0;
    for (var i = 0; i < n; i++) {
      if (stamp[i] > minute - n && stamp[i] <= minute) s += a[i];
    }
    return s;
  }
}

class _Entry {
  _Entry(this.who, this.process, this.host, this.port, this.outbound, this.inbound, this.network);
  final String who, process, host, outbound, inbound, network;
  final int port;
  final buckets = _Buckets();

  /// The raw text of the rule the last connection of the entry matched (`rule` of the closed record): the judge
  /// finds the rule's own DNS server from it.
  String rule = '';
  int okSince = 0, failedSince = 0, bgSince = 0;
  final kinds = <ConnKind, int>{};
  int lastAt = 0, lastFailAt = 0, lastOkAt = 0;
  ConnKind? lastKind;
  int? lastDurationMs;

  // the event rule: failures within the streak window with no success between; `reported` until one
  final streak = <(int, ConnKind)>[];
  bool reported = false;

  // after a suspicion that did not stand: no new one before this (ms since epoch)
  int holdUntil = 0;

  // the journal event of the standing series (null while it is judged, or when none was written)
  int? eventId;
  bool judging = false;

  // the series started after [FailureBook.maxEvents] suspicions in the window: it has no event of its own, its failures
  // are counted on the latest `conn/failing` (the service finds it) until a success ends it
  bool limited = false;

  // failures of the series after it was reported (or inside the hold), not yet handed over: [FailureBook.repeated]
  final againAt = <int>[];
  int againN = 0;
  final againKinds = <ConnKind, int>{};

  String get route {
    final at = outbound.indexOf('/');
    return at < 0 ? outbound : outbound.substring(0, at);
  }

  /// The app as the journal names it: the package (Android), else the program's file name.
  String get app {
    if (who.isNotEmpty) return who;
    final p = processEventData(process);
    return p == null ? '' : '${p['name']}';
  }
}

class _Hint {
  _Hint(this.kind, this.tag, this.at);
  final ConnKind kind;
  final String tag;
  final int at;
}

class _Group {
  _Group(this.at);
  final int at;
  final hosts = <String>{};

  /// The journal event, once the judge has found the failure standing; null while it is judged.
  int? id;

  /// The entries that joined the group while it was judged.
  final joined = <_Entry>[];
}

/// Failures of a series that was already reported ([FailureBook.repeated]): [n] of them since the last hand-over, at
/// [at] (the newest 50) by [kinds]. [eventId]: the series' journal event, null when it has none (it did not stand,
/// or it was judged away). [limited]: the series is one beyond [FailureBook.maxEvents] per window, it has no [eventId]:
/// the service counts it on the latest `conn/failing` and says so in the raw log.
class FailureRepeat {
  const FailureRepeat({required this.key, required this.app, required this.host, required this.port, required this.outbound, required this.n, required this.at, required this.kinds, this.eventId, this.limited = false});
  final String key, app, host, outbound;
  final int port, n;
  final List<int> at;
  final Map<ConnKind, int> kinds;
  final int? eventId;
  final bool limited;
}

/// What the book hands to the judge (the Sentinel, in the service) when an entry's failures make a
/// suspicion: [key] / [subject] identify it, [data] is the event's data, [firstSeen] the first failure
/// of the streak.
class FailureReport {
  const FailureReport({required this.key, required this.subject, required this.data, required this.bg, required this.firstSeen, required this.kind});

  /// `conn.failing|app|host:port|outbound|inbound`: one per entry.
  final String key;

  /// `{app?, process?, host, port, outbound, route, path}`: scalars only (the Sentinel's roots match on them).
  final Map<String, dynamic> subject;
  final Map<String, dynamic> data;
  final bool bg;
  final DateTime firstSeen;

  /// The failure kind the streak mostly had (`refused`, `timeout`, …).
  final ConnKind kind;
}

/// The book of failed connections of the running sing-box: per (app, destination, outbound, inbound,
/// tcp/udp) the successes and failures of the last 10 minutes and since sing-box started, by kind;
/// bounded ([maxEntries]); fed by the closed-connection stream ([onClosed]) and the log ([onLog]).
///
/// `conn/failing`: [failAfter] failures of one entry within [streakWindow] with no success between make
/// a suspicion ([report]): the book never writes the event, the judge does (docs/failures.md); it answers
/// with the event's id when the failure stands, null when it does not (a blip, a consequence of something
/// else, a workaround, our own restart). One suspicion per entry until a success resets it ([recovered]
/// tells the judge); entries of the same app and outbound that fail while the event is [groupWindow]
/// fresh change it in place (`more`) instead of making new ones; at most [maxEvents] suspicions per
/// [window] overall; an entry whose suspicion did not stand waits [recheckAfter] before the next. Not
/// raised for UDP, for the core's own requests (`probe-in`, Auto's checks of the spare routes among them,
/// `svc-in` and `tunnel-in`), for an ignored site and for the app's own process ([own]: its connections that entered
/// the TUN under the self rule are not counted at all, a failed one is told to [ownFailed] for the raw log). The
/// judge key is the destination's ([siteKey]): Auto's notice of the same site joins the same suspicion.
///
/// The caller owns the clock and the lifetime: [start] when sing-box starts (counters begin), [stop]
/// when it ends; nothing here runs on a timer.
class FailureBook {
  FailureBook({
    DateTime Function()? now,
    bool Function(String host)? ignored,
    bool Function()? background,
    bool Function(ClosedConnection c)? own,
    this.ownFailed,
    this.report,
    this.recovered,
    this.update,
    this.repeated,
    this.worked,
    Timer Function(Duration, void Function())? timer,
  })  : _now = now ?? DateTime.now,
        _ignored = ignored,
        _background = background,
        _own = own,
        _timer = timer ?? Timer.new;

  /// Failures of a reported series are handed over in batches of this long ([repeated]): a browser retrying a dead
  /// site fails dozens of times a second, one raw line and one change of the event per batch.
  static const repeatEvery = Duration(seconds: 5);
  final Timer Function(Duration, void Function()) _timer;
  Timer? _repeatTimer;
  final _again = <_Entry>{};

  /// The window of the «last 10 minutes» counters (10 one-minute buckets).
  static const window = Duration(minutes: 10);

  /// Failures of one entry, within [streakWindow] and with no success between, that make `conn/failing`.
  static const failAfter = 3;
  static const streakWindow = Duration(seconds: 60);

  /// Entries of one app through one outbound that fail within this of the event change it in place.
  static const groupWindow = Duration(minutes: 5);

  /// At most this many `conn/failing` suspicions per [window]; the series beyond it are counted on the latest
  /// `conn/failing` event ([FailureRepeat.limited]), never dropped.
  static const maxEvents = 6;

  /// An entry whose suspicion did not stand is not suspected again for this long.
  static const recheckAfter = Duration(seconds: 60);

  /// Entries kept (least recently seen without a failure go first).
  static const maxEntries = 400;

  /// A log hint is used for the connection that closes within this of it.
  static const hintTtl = Duration(seconds: 20);

  /// The destinations whose resolving failed (`dns: exchange failed for …`), kept.
  static const maxDns = 50;

  final DateTime Function() _now;
  final bool Function(String host)? _ignored;
  final bool Function()? _background;

  /// Whether the connection was made by this app's own process (the self rule's match: the Dart HTTP clients, a
  /// socket of a measurement that was not kept out of the tunnel). Such a connection is the maker's business (the ping
  /// result, the check that asked), never a failure of an app the user runs: not counted in the book, no `conn/failing`.
  final bool Function(ClosedConnection c)? _own;

  /// A connection of the app's own process closed with nothing back ([_own]): skipped by the book, handed over to be
  /// written to the raw log (it is never silent), every one.
  final void Function(ClosedConnection c, ConnOutcome outcome)? ownFailed;

  /// A suspicion for the judge; completes with the id of the journal event when the failure stands (the
  /// event a group's `more` goes to), null otherwise.
  final Future<int?> Function(FailureReport report)? report;

  /// The entry of that key works again: the suspicion under way ends, the standing failure closes.
  final void Function(String key)? recovered;

  /// Changes the data of an event [report] answered with (a group's `more`).
  final void Function(int id, Map<String, dynamic> data)? update;

  /// The entry of a reported series (or of one inside the hold after a suspicion that did not stand) failed again:
  /// every failure is handed over, in a batch every [repeatEvery] (and when the series ends or [stop] comes), to be
  /// counted on the series' event and written to the raw log. Nothing is dropped.
  final void Function(FailureRepeat r)? repeated;

  /// A connection to [host]:[port] (lower case; the user's, not the core's own) through [outbound] closed having got
  /// data back: «the site opens through that route». Told for every such connection; the site checks' memory of a
  /// verdict ends by it (service.dart).
  final void Function(String host, int port, String outbound)? worked;

  bool _active = false;
  int _since = 0;
  final _entries = <String, _Entry>{}; // insertion order: the newest last
  final _hints = <String, _Hint>{};
  final _groups = <String, _Group>{};
  final _emitted = <int>[];
  final _total = _Buckets();
  int _okSince = 0, _failedSince = 0, _bgSince = 0, _events = 0, _ownOkSince = 0, _ownFailedSince = 0;
  final _kindsSince = <ConnKind, int>{};
  final _dns = <String, (int, int)>{}; // host → (count, last at)

  bool get active => _active;

  /// sing-box started: the counters begin from nothing.
  void start() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _again.clear();
    _entries.clear();
    _hints.clear();
    _groups.clear();
    _emitted.clear();
    _dns.clear();
    _kindsSince.clear();
    _okSince = _failedSince = _bgSince = _events = _ownOkSince = _ownFailedSince = 0;
    for (var i = 0; i < _Buckets.n; i++) {
      _total.ok[i] = _total.bad[i] = 0;
      _total.stamp[i] = -1;
    }
    _since = _now().millisecondsSinceEpoch;
    _active = true;
  }

  /// sing-box ended: nothing more is taken in; what was counted stays readable.
  void stop() {
    flushRepeats(all: true);
    _active = false;
    _hints.clear();
  }

  /// Hands over the failures that wait ([repeated]); the ones of a series still being judged wait for the verdict
  /// unless [all].
  void flushRepeats({bool all = false}) {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    for (final e in _again.toList()) {
      if (all || (!e.judging && !(e.limited && _judging))) _flush(e);
    }
  }

  // A suspicion of this book is being judged: its event may still come, which the limited series are counted on.
  bool get _judging => _groups.values.any((g) => g.id == null);

  // Hands over the limited series that waited for the events being judged (their verdicts are in, or there are none).
  void _flushLimited() {
    if (_judging) return;
    for (final e in _again.toList()) {
      if (e.limited) _flush(e);
    }
  }

  void _flush(_Entry e) {
    _again.remove(e);
    if (e.againN == 0) return;
    final r = FailureRepeat(
      key: _keyOf(e),
      app: e.app,
      host: e.host,
      port: e.port,
      outbound: e.outbound,
      n: e.againN,
      at: List.of(e.againAt),
      kinds: Map.of(e.againKinds),
      eventId: e.eventId,
      limited: e.limited,
    );
    e.againAt.clear();
    e.againKinds.clear();
    e.againN = 0;
    repeated?.call(r);
  }

  // A failure of an entry whose series was reported: it waits for the next batch.
  void _more(_Entry e, int at, ConnKind kind) {
    e.againN++;
    e.againAt.add(at);
    if (e.againAt.length > 50) e.againAt.removeAt(0);
    e.againKinds[kind] = (e.againKinds[kind] ?? 0) + 1;
    _again.add(e);
    if (!e.judging) _repeatTimer ??= _timer(repeatEvery, flushRepeats);
  }

  /// The judge's key of a destination: one suspicion per site, whoever reports it (this book, Auto).
  static String siteKey(String host, int? port) => 'site|${host.toLowerCase()}${port == null || port <= 0 ? '' : ':$port'}';

  /// A line of sing-box's log: a failed dial's reason (the hint for the closed record that follows) and
  /// a name that did not resolve.
  void onLog(String line) {
    if (!_active) return;
    if (!line.contains('open connection to') && !line.contains('failed for')) return;
    final l = SbLine.parse(line);
    final o = _openRe.firstMatch(l.body);
    if (o != null) {
      final kind = ConnOutcome.kindOfError(o[4]!);
      if (kind == null) return;
      final dest = o[1]!;
      _hints.remove(dest);
      _hints[dest] = _Hint(kind, o[3]!, _now().millisecondsSinceEpoch);
      while (_hints.length > 128) {
        _hints.remove(_hints.keys.first);
      }
      return;
    }
    final d = _dnsRe.firstMatch(l.body);
    if (d != null) {
      final host = d[1]!.toLowerCase();
      if (_ignored?.call(host) == true) return;
      final was = _dns.remove(host);
      _dns[host] = ((was?.$1 ?? 0) + 1, _now().millisecondsSinceEpoch);
      while (_dns.length > maxDns) {
        _dns.remove(_dns.keys.first);
      }
    }
  }

  // `connection: open connection to H:P using outbound/type[tag]: error`
  static final _openRe = RegExp(r'open connection to (\S+) using (\S+?)\[([^\]]*)\]: (.*)$');
  // `dns: exchange failed for example.com. IN A: error`
  static final _dnsRe = RegExp(r'dns: (?:exchange|lookup) failed for (\S+?)\.?(?:\s+IN\s+\w+)?:');

  /// A connection sing-box closed.
  void onClosed(ClosedConnection c) {
    if (!_active || c.inbound == _probeInbound || c.inbound == _svcInbound) return;
    if (_own?.call(c) == true) {
      final out = ConnOutcome.of(c);
      if (out.idle) return;
      if (out.ok) {
        _ownOkSince++;
      } else {
        _ownFailedSince++;
        ownFailed?.call(c, out);
      }
      return;
    }
    final (host, port) = splitDest(c.destination);
    final h = host.toLowerCase();
    if (_ignored?.call(h) == true) return;
    final hint = ConnOutcome.isFailure(c) ? _takeHint(c) : null;
    final out = ConnOutcome.of(c, hint: hint?.kind);
    if (out.idle) return;
    final at = _now().millisecondsSinceEpoch, minute = at ~/ 60000;
    final e = _entryFor(c, h, port, at);
    e.lastAt = at;
    if (c.rule.isNotEmpty) e.rule = c.rule;
    _total.add(minute, failed: out.failed);
    e.buckets.add(minute, failed: out.failed);
    if (out.ok) {
      e.okSince++;
      _okSince++;
      e.lastOkAt = at;
      worked?.call(h, port, c.outbound);
      e.streak.clear();
      _flush(e); // the failures that came before this success: counted before the series ends
      if (e.reported) {
        e.reported = false;
        e.limited = false;
        e.eventId = null;
        e.judging = false;
        recovered?.call(_keyOf(e));
      }
      return;
    }
    final bg = _background?.call() ?? false;
    e.failedSince++;
    _failedSince++;
    if (bg) {
      e.bgSince++;
      _bgSince++;
    }
    e.kinds[out.kind] = (e.kinds[out.kind] ?? 0) + 1;
    _kindsSince[out.kind] = (_kindsSince[out.kind] ?? 0) + 1;
    e.lastFailAt = at;
    e.lastKind = out.kind;
    e.lastDurationMs = out.durationMs;
    _streak(e, out.kind, at, h, bg);
  }

  _Hint? _takeHint(ClosedConnection c) {
    final h = _hints.remove(c.destination);
    if (h == null) return null;
    if (_now().millisecondsSinceEpoch - h.at > hintTtl.inMilliseconds) return null;
    return h.tag.isEmpty || h.tag == c.outbound ? h : null;
  }

  _Entry _entryFor(ClosedConnection c, String host, int port, int at) {
    final who = c.pkg.isNotEmpty ? c.pkg : c.process;
    final key = '$who\u0000$host:$port\u0000${c.outbound}\u0000${c.inbound}\u0000${c.network}';
    var e = _entries.remove(key);
    if (e == null) {
      e = _Entry(c.pkg, c.process, host, port, c.outbound, c.inbound, c.network);
      if (_entries.length >= maxEntries) _evict();
    }
    _entries[key] = e; // the newest last
    return e;
  }

  void _evict() {
    var drop = maxEntries ~/ 10;
    final plain = [for (final en in _entries.entries) if (en.value.failedSince == 0) en.key].take(drop).toList();
    for (final k in plain) {
      _entries.remove(k);
      drop--;
    }
    while (drop-- > 0 && _entries.isNotEmpty) {
      _entries.remove(_entries.keys.first);
    }
  }

  void _streak(_Entry e, ConnKind kind, int at, String host, bool bg) {
    final from = at - streakWindow.inMilliseconds;
    e.streak.removeWhere((s) => s.$1 < from);
    e.streak.add((at, kind));
    // the series was reported (or the suspicion of it did not stand a moment ago): this failure is counted, not lost
    if (e.reported || (e.streak.length >= failAfter && at < e.holdUntil)) {
      _more(e, at, kind);
      return;
    }
    if (e.streak.length < failAfter) return;
    if (e.network == 'udp' || e.inbound == _tunnelInbound || e.inbound == _probeInbound || e.inbound == _svcInbound) return;
    e.reported = true;
    _raise(e, at, bg);
  }

  void _raise(_Entry e, int at, bool bg) {
    final send = report;
    if (send == null) return;
    final gKey = '${e.who}\u0000${e.process}\u0000${e.outbound}';
    final g = _groups[gKey], dest = '${e.host}:${e.port}';
    // another destination of the same app through the same outbound joins the event; the same one
    // failing again after a success is a new outage and a new event
    if (g != null && at - g.at <= groupWindow.inMilliseconds && !g.hosts.contains(dest)) {
      g.hosts.add(dest);
      g.joined.add(e);
      final id = g.id;
      if (id != null) {
        e.eventId = id;
        update?.call(id, {'more': g.hosts.length - 1});
      } else {
        e.judging = true; // settled with the group
      }
      return;
    }
    final recent = at - window.inMilliseconds;
    _emitted.removeWhere((t) => t < recent);
    if (_emitted.length >= maxEvents) {
      // beyond the limit: no suspicion and no event of its own, but never silent: the failures of the streak and the
      // ones after it are handed over as the series' repeats ([FailureRepeat.limited]), the raw log says why
      e.limited = true;
      for (final s in e.streak) {
        _more(e, s.$1, s.$2);
      }
      _flushLimited();
      return;
    }
    final counts = <ConnKind, int>{};
    for (final s in e.streak) {
      counts[s.$2] = (counts[s.$2] ?? 0) + 1;
    }
    var kind = e.streak.last.$2;
    for (final k in counts.entries) {
      if (k.value > counts[kind]!) kind = k.key;
    }
    final process = processEventData(e.process);
    final r = FailureReport(
      key: _keyOf(e),
      subject: {
        if (e.who.isNotEmpty) 'app': e.who,
        if (process != null) 'process': process['name'],
        'host': e.host,
        if (e.port > 0) 'port': e.port,
        'outbound': e.outbound,
        'route': e.route,
        'path': e.route == 'direct' ? 'direct' : 'proxy',
      },
      data: {
        if (e.who.isNotEmpty) 'app': e.who,
        'process': ?process,
        'host': e.host,
        if (e.port > 0) 'port': e.port,
        'outbound': e.outbound,
        'route': e.route,
        'kind': kind.name,
        'count': e.streak.length,
        'windowMs': streakWindow.inMilliseconds,
        'source': 'closed',
        if (e.rule.isNotEmpty) 'rule': e.rule,
      },
      bg: bg,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(e.streak.first.$1, isUtc: true),
      kind: kind,
    );
    _emitted.add(at);
    final ng = _Group(at)..hosts.add(dest);
    _groups[gKey] = ng;
    if (_groups.length > 100) _groups.remove(_groups.keys.first);
    void settle(int? id) {
      if (id != null) {
        ng.id = id;
        _events++;
        if (ng.hosts.length > 1) update?.call(id, {'more': ng.hosts.length - 1});
        for (final x in [e, ...ng.joined]) {
          x.eventId = id;
          x.judging = false;
          _flush(x); // the failures that came while it was judged are on the event now
        }
        _flushLimited();
        return;
      }
      // it did not stand: the group ends; its entries may be suspected again after a pause
      if (identical(_groups[gKey], ng)) _groups.remove(gKey);
      final hold = _now().millisecondsSinceEpoch + recheckAfter.inMilliseconds;
      for (final x in [e, ...ng.joined]) {
        x.reported = false;
        x.holdUntil = hold;
        x.eventId = null;
        x.judging = false;
        _flush(x); // no event to count them on: the raw log has them
      }
      _flushLimited();
    }

    e.judging = true;
    send(r).then(settle, onError: (Object _) => settle(null));
  }

  /// The judge's key of an entry: its destination's ([siteKey]); [recovered] is told only when the very entry
  /// (app, outbound, inbound) that was reported works again.
  static String _keyOf(_Entry e) => siteKey(e.host, e.port);

  /// The outbounds through which [host]:[port] worked (for any app) after [sinceMs]: «did it recover by
  /// itself» (the failing outbound is among them) and «does it open another way» (another is), read from
  /// the live traffic, no request is made.
  Set<String> okOutbounds(String host, int port, int sinceMs) {
    final h = host.toLowerCase();
    return {
      for (final e in _entries.values)
        if (e.host == h && e.port == port && e.lastOkAt > sinceMs) e.outbound,
    };
  }

  /// Whether any connection to [host]:[port] (any app, any outbound) failed at or after [sinceMs]: «the live traffic
  /// still fails», read from the book, no request is made.
  bool failedSince(String host, int port, int sinceMs) {
    final h = host.toLowerCase();
    for (final e in _entries.values) {
      if (e.host == h && e.port == port && e.lastFailAt >= sinceMs) return true;
    }
    return false;
  }

  /// The numbers for the report: the totals, the apps and destinations that fail most (by the last
  /// 10 minutes, then since sing-box started), the names that did not resolve. [top] bounds the lists.
  Map<String, dynamic> toJson({int top = 20}) {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    final failing = [for (final e in _entries.values) if (e.failedSince > 0) e];
    int byWeight(_Entry a, _Entry b) {
      final w = b.buckets.badIn(minute).compareTo(a.buckets.badIn(minute));
      if (w != 0) return w;
      final s = b.failedSince.compareTo(a.failedSince);
      return s != 0 ? s : b.lastFailAt.compareTo(a.lastFailAt);
    }

    failing.sort(byWeight);
    // by app: the same numbers added up over the app's entries
    final apps = <String, Map<String, int>>{};
    for (final e in failing) {
      final a = apps.putIfAbsent(e.app.isEmpty ? '' : e.app, () => {'failed10m': 0, 'ok10m': 0, 'failedSince': 0, 'okSince': 0, 'bgSince': 0, 'destinations': 0});
      a['failed10m'] = a['failed10m']! + e.buckets.badIn(minute);
      a['ok10m'] = a['ok10m']! + e.buckets.okIn(minute);
      a['failedSince'] = a['failedSince']! + e.failedSince;
      a['okSince'] = a['okSince']! + e.okSince;
      a['bgSince'] = a['bgSince']! + e.bgSince;
      a['destinations'] = a['destinations']! + 1;
    }
    final appList = [for (final a in apps.entries) {'app': a.key, ...a.value}]
      ..sort((x, y) {
        final w = (y['failed10m'] as int).compareTo(x['failed10m'] as int);
        return w != 0 ? w : (y['failedSince'] as int).compareTo(x['failedSince'] as int);
      });
    return {
      'active': _active,
      'since': _since,
      'windowMs': window.inMilliseconds,
      'ok': _okSince,
      'failed': _failedSince,
      'ok10m': _total.okIn(minute),
      'failed10m': _total.badIn(minute),
      'bgFailed': _bgSince,
      'byKind': {for (final k in _kindsSince.entries) k.key.name: k.value},
      'ownOk': _ownOkSince, // the app's own process: not in the numbers above (see [own])
      'ownFailed': _ownFailedSince,
      'events': _events,
      'entries': _entries.length,
      'apps': appList.take(top).toList(),
      'top': [
        for (final e in failing.take(top))
          {
            if (e.who.isNotEmpty) 'app': e.who,
            'process': ?processEventData(e.process),
            'host': e.host,
            if (e.port > 0) 'port': e.port,
            'outbound': e.outbound,
            'route': e.route,
            if (e.inbound.isNotEmpty) 'inbound': e.inbound,
            if (e.network.isNotEmpty) 'network': e.network,
            'failed10m': e.buckets.badIn(minute),
            'ok10m': e.buckets.okIn(minute),
            'failedSince': e.failedSince,
            'okSince': e.okSince,
            if (e.bgSince > 0) 'bgSince': e.bgSince,
            'byKind': {for (final k in e.kinds.entries) k.key.name: k.value},
            'lastKind': e.lastKind?.name,
            'lastAt': e.lastFailAt,
            if (e.lastDurationMs != null) 'lastDurationMs': e.lastDurationMs,
            if (e.reported) 'failing': true,
          },
      ],
      'dns': [
        for (final d in (_dns.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1))).take(top))
          {'host': d.key, 'count': d.value.$1, 'lastAt': d.value.$2},
      ],
    };
  }
}
