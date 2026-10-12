/// Root causes: confirmed failures, open until they recover (docs/failures.md → Корневые причины).
library;

import 'model.dart';

/// The kinds the Sentinel opens from the context itself (no detector confirms them).
const rootNetOffline = 'net.offline';
const rootNetCaptive = 'net.captive';
const rootCoreDown = 'core.down';

/// An open (or closed) root cause.
class Root {
  Root({
    required this.id,
    required this.kind,
    required this.key,
    required this.subject,
    required this.scope,
    required this.since,
    this.eventId,
    this.session = true,
    this.fromContext = false,
    this.level = Level.destination,
    List<TrailStep>? trail,
  }) : trail = trail ?? [];

  final String id;
  final String kind;

  /// The dedup key of the suspicion it was confirmed from (the kind itself for a context root).
  final String key;
  final Map<String, dynamic> subject;
  final Scope scope;
  final DateTime since;

  /// The journal event that shows it; null for a root the context opened, until a detector attaches one.
  int? eventId;

  /// Ends with the sing-box session (a stop, a new start).
  final bool session;

  /// Opened and closed by the context (network, core down).
  final bool fromContext;

  /// Where it sits (network -> core -> route -> destination): checks on or below it that go through it are
  /// not started while it is open, and suspicions older than it are parked, not judged its consequences.
  final Level level;
  final List<TrailStep> trail;

  /// The root this one turned out to be a consequence of (a wider root opened after it).
  String? parent;

  /// The journal events of the failures judged to be consequences of this root.
  final consequences = <int>[];
  DateTime? closedAt;
  String? closeReason;

  bool get open => closedAt == null;

  bool covers(Map<String, dynamic> subject) => scope.covers(subject);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'key': key,
        'subject': subject,
        'scope': scope.toJson(),
        'level': level.name,
        'since': since.millisecondsSinceEpoch,
        'eventId': ?eventId,
        'parent': ?parent,
        if (fromContext) 'context': true,
        if (closedAt != null) 'closedAt': closedAt!.millisecondsSinceEpoch,
        'closeReason': ?closeReason,
      };
}

/// The open roots (and the last closed ones, for the report).
class RootRegistry {
  RootRegistry({this.maxAge = const Duration(hours: 24), this.keepClosed = 30});

  /// An open root older than this is closed as `expired` the next time the registry is asked: a root
  /// nobody closed must not swallow failures for ever.
  final Duration maxAge;
  final int keepClosed;

  final _open = <String, Root>{}; // by id
  final _closed = <Root>[];
  int _seq = 0;

  Iterable<Root> get open => _open.values;
  List<Root> get closed => List.unmodifiable(_closed);

  String nextId(String kind) => '$kind#${++_seq}';

  void add(Root r) => _open[r.id] = r;

  Root? byId(String id) => _open[id];

  /// The open root made from the suspicion with this key (or of this context kind).
  Root? byKey(String key) {
    for (final r in _open.values) {
      if (r.key == key) return r;
    }
    return null;
  }

  Root? byKind(String kind) {
    for (final r in _open.values) {
      if (r.kind == kind) return r;
    }
    return null;
  }

  /// The open root that covers [subject] (the oldest wins: the cause is older than its consequences).
  /// [except]: a key not to answer with (the suspicion's own).
  Root? covering(Map<String, dynamic> subject, {String? except}) {
    Root? best;
    for (final r in _open.values) {
      if (r.key == except || !r.covers(subject)) continue;
      if (best == null || r.since.isBefore(best.since)) best = r;
    }
    return best;
  }

  /// Closes [r]; false when it was closed already.
  bool close(Root r, DateTime at, String reason) {
    if (_open.remove(r.id) == null) return false;
    r.closedAt = at;
    r.closeReason = reason;
    _closed.add(r);
    if (_closed.length > keepClosed) _closed.removeAt(0);
    return true;
  }

  /// The roots older than [maxAge] at [now].
  List<Root> expired(DateTime now) => [for (final r in _open.values) if (now.difference(r.since) > maxAge) r];

  List<Map<String, dynamic>> openJson() => [for (final r in _open.values) r.toJson()];
}
