/// The Sentinel's context: the single source of truth about the network and about the core's own
/// state (docs/failures.md → Контекст). Inputs come from the probe pool (Auto's `offline` is in it),
/// from sing-box's own log lines, from the platform ([ContextTracker.platform]) and from the
/// service, which says when it starts, stops and loses sing-box.
library;

import 'dart:async';

import '../pool.dart' show NetStatus;
import 'clock.dart';

enum NetState {
  /// Presumed up (nothing says otherwise).
  up,

  /// No network at all (the OS says so, or every route and the direct path are silent).
  none,

  /// The network wants a login first (the platform says so).
  captive,

  /// Doubted: a route missed, or the platform could not validate the network. Judging waits.
  unknown,
}

enum CorePhase {
  /// No connection.
  stopped,

  /// sing-box is being started (a connect, a restart of ours).
  starting,

  /// Running, but less than the settle time since the last (re)start.
  settling,

  /// Running and quiet for the settle time.
  settled,

  /// Crashed; being started again.
  recovering,

  /// Crashed and not back for 30 s (the service's `down`).
  down,
}

/// The network as the Sentinel sees it.
class NetworkContext {
  const NetworkContext({required this.state, required this.since, required this.changedAt, this.type, this.id, this.source = 'default'});

  final NetState state;

  /// When [state] last changed (ms since epoch).
  final int since;

  /// When the state, the network id / type or the default interface last changed. Backoffs start over by it.
  final int changedAt;

  /// `wifi` / `cellular` / `ethernet` / … as the platform names it; null = not known.
  final String? type;

  /// An opaque id of the network (changes when the device moves to another one); null = not known.
  final String? id;

  /// What decided the state: `default` (nothing says otherwise), `platform`, `os` (sing-box:
  /// no default interface), `probes` (every route and the direct path are silent), `doubt`.
  final String source;

  Map<String, dynamic> toJson() => {
        'state': state.name,
        'since': since,
        'changedAt': changedAt,
        'type': ?type,
        'id': ?id,
        'source': source,
      };
}

/// The core's own state.
class CoreContext {
  const CoreContext({required this.phase, required this.since, this.restartReason, this.restartAt});

  final CorePhase phase;

  /// When [phase] last changed (ms since epoch). A settle (`settling` → `settled`) is not a change of
  /// the stored state: `since` is then the moment of the start.
  final int since;

  /// Why sing-box was (re)started last: `userConnect`, `refreshLists`, `recover`, `adopt`, …
  final String? restartReason;
  final int? restartAt;

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'since': since,
        'restartReason': ?restartReason,
        'restartAt': ?restartAt,
      };
}

/// Holds the context and its inputs; [onChange] is called synchronously on every change of the
/// network state / id, or of the core phase (including the moment a start settles).
class ContextTracker {
  ContextTracker({SentinelClock? clock, this.settle = const Duration(seconds: 5)}) : clock = clock ?? SentinelClock() {
    final now = this.clock.now().millisecondsSinceEpoch;
    _netSince = _netChangedAt = now;
    _coreSince = now;
  }

  final SentinelClock clock;

  /// How long a start is quiet before the core counts as settled.
  Duration settle;

  /// Called after every change (and when a settle passes).
  void Function()? onChange;

  final _changes = StreamController<void>.broadcast(sync: true);

  /// Every change, for whoever waits (the evaluations, the app's status).
  Stream<void> get changes => _changes.stream;

  void _fire() {
    onChange?.call();
    if (!_changes.isClosed) _changes.add(null);
  }

  // ── network ──

  bool _poolDown = false, _poolDoubt = false, _osOffline = false;
  bool? _connected, _validated;
  bool _captive = false;
  String? _type, _id;
  NetState _net = NetState.up;
  String _netSource = 'default';
  late int _netSince, _netChangedAt;

  /// Counts the moves to another network (id, type, default interface) and every loss or return of
  /// connectivity (`none` / `captive` ↔ the rest): what the retry timers start over by.
  int netEpoch = 0;

  // A switch of the network is a disturbance that opens at the drop (the platform's own time `at`, else the moment we
  // learned of it) and ends with an event (docs/failures.md → Смена сети): the platform reports the network
  // connected (not a portal) AND any data came in on it after the move ([proved]: a connection with down > 0 that opened
  // after the move, direct or through any outbound, an answered probe). Not `validated`, not a route: only the network
  // matters. The timers below are only the safety cap.

  /// Where the platform reports the network: the longest a disturbance stays open without its event.
  Duration switchCap = const Duration(seconds: 30);

  /// Where nothing reports the network (no platform signal: Windows / jormd, the move is sing-box's interface line):
  /// how long after the move the network counts as settled when no request has proved it sooner.
  Duration noSignalGrace = const Duration(seconds: 10);

  /// The connections that were opened before the drop die with the old network, the dead sockets of it time out for a
  /// while: their failure is the network's this long after the network is stable again (a safety bound).
  Duration oldConnTail = const Duration(seconds: 60);

  int? _disturbedAt; // the drop: when the open (or last) disturbance began (ms since epoch)
  int? _eventAt; // the latest move / loss / return of the network (ms): a proof must begin after it
  bool _proved = false; // a request went through after [_eventAt]
  bool _stable = true;
  int? _stableAt;
  String? _stableBy; // `event` | `cap`
  Timer? _capTimer;
  bool _platformSeen = false;
  int? _platformAt, _unconfirmedAt;

  /// When the last (or the open) disturbance began: the drop of the network or the move to another one, by the system's
  /// own time when it told it; null = none since the start.
  DateTime? get lastMove => _disturbedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(_disturbedAt!);

  /// When the last disturbance ended (null = none, or it is open) and by what: `event` / `cap`.
  DateTime? get stableAt => _stableAt == null ? null : DateTime.fromMillisecondsSinceEpoch(_stableAt!);
  String? get stableBy => _stableBy;

  /// No disturbance is open: the network is where it was, or the new one has proved itself.
  bool get stable => _stable;

  /// The network is down or has just changed. No connection / a portal (said by the platform or the OS; the `none` of
  /// the probes is Auto's own verdict, a conclusion from the failures, not a cause of them), or a disturbance not yet stable.
  bool get switching => outage || !_stable;

  /// No connection / a portal said by the platform or the OS.
  bool get outage => _net == NetState.captive || (_net == NetState.none && _netSource != 'probes');

  /// The platform reports the network (Android): false = nothing does (Windows / jormd).
  bool get signalKnown => _platformSeen;

  /// A move was seen by sing-box / the OS and the platform has not reported since: its state may be the old one.
  bool get signalStale => _unconfirmedAt != null && (_platformAt == null || _platformAt! < _unconfirmedAt!);

  /// A failed connection belongs to a network switch. [closedAt] / [openedAt]: sing-box's stamps (ms), else it closed now
  /// and opened [durationMs] before that. Closed before the drop = a candidate for a real failure (false; its check waits
  /// for [stable], sentinel.dart). Closed at or after the drop while the network is not stable = the network's (true).
  /// A connection opened before the drop that fails up to [oldConnTail] after the network is stable is the old network's
  /// too. Not the steady `none` / `captive`: a failure there is judged by the Sentinel as the consequence of that outage
  /// (`conn/offline`), which is its visible record.
  bool failureInSwitch({int? openedAt, int? closedAt, int? durationMs}) {
    final d = _disturbedAt;
    if (d == null || outage) return false;
    final closed = closedAt ?? clock.now().millisecondsSinceEpoch;
    if (closed < d) return false;
    if (!_stable) return true;
    final opened = openedAt ?? (durationMs == null ? null : closed - durationMs);
    return opened != null && opened < d && _stableAt != null && closed - _stableAt! < oldConnTail.inMilliseconds;
  }

  /// Data came in on the network: a connection with data back that was [since] (ms) opened, or a probe that was
  /// started then. It counts for the open disturbance only if it began after the latest move (a null [since] is not
  /// told apart from an old one: the caller skips it); with the platform's `connected` and not captive (or none
  /// reported) it ends the disturbance.
  void proved({int? since}) {
    if (_stable) return;
    if (since != null && _eventAt != null && since < _eventAt!) return;
    _proved = true;
    if (_evalStable()) _fire();
  }

  // Whether the open disturbance ends now (by the event, or by the cap); sets the state, the caller fires.
  bool _evalStable() {
    if (_stable) return false;
    _capTimer?.cancel();
    _capTimer = null;
    if (outage) return false; // nothing to settle while the connection is gone: the cap starts over from its return
    final now = clock.now().millisecondsSinceEpoch, at = _eventAt ?? now;
    // `validated` is not asked for: where the OS's validation endpoints are blocked it never comes while the network works
    final platformOk = !_platformSeen || (_connected != false && !_captive);
    final capMs = (_platformSeen ? switchCap : noSignalGrace).inMilliseconds;
    final String? by = platformOk && _proved ? 'event' : (now - at >= capMs ? 'cap' : null);
    if (by == null) {
      _capTimer = clock.timer(Duration(milliseconds: capMs - (now - at) + 1), _capReached);
      return false;
    }
    _stable = true;
    _stableAt = now;
    _stableBy = by;
    return true;
  }

  void _capReached() {
    _capTimer = null;
    if (_evalStable()) _fire();
  }

  /// Counts the changes of the stored core state (a start, a stop, a crash).
  int coreEpoch = 0;

  NetworkContext get network => NetworkContext(
        state: _net,
        since: _netSince,
        changedAt: _netChangedAt,
        type: _type,
        id: _id,
        source: _netSource,
      );

  /// The probe pool's status moved (it already holds Auto's `offline`): [osOffline] = the OS has no network.
  void pool(NetStatus status, {required bool osOffline}) {
    _poolDown = status == NetStatus.down;
    _poolDoubt = status == NetStatus.unknown;
    _osOffline = osOffline;
    _deriveNet();
  }

  /// What the platform says of the network (Android: `NET_CAPABILITY_VALIDATED`, `NET_CAPABILITY_CAPTIVE_PORTAL`,
  /// the transport and an id of the network). Replaces the previous report as a whole; null = not said.
  ///
  /// `connected: false` is `none`, `captive: true` is `captive`; `validated: false` alone is only a doubt
  /// (the validation endpoints of the OS are often blocked where this app is used, while the network works).
  ///
  /// [at]: the system's own time of the change (ms since epoch; Android takes it in the callback): the drop is dated by
  /// it, not by when the message got here. Null = now; one from the future is now.
  void platform({bool? connected, bool? validated, bool captive = false, String? type, String? id, int? at}) {
    _connected = connected;
    _validated = validated;
    _captive = captive;
    _platformSeen = true;
    _platformAt = clock.now().millisecondsSinceEpoch;
    final moved = (id != null && _id != null && id != _id) || (type != null && _type != null && type != _type);
    _type = type;
    _id = id;
    _deriveNet(moved: moved, at: at);
    if (_evalStable()) _fire(); // `validated` may have come without any other change
  }

  /// The default interface changed (sing-box: `updated default interface`), or the device moved to
  /// another network: timers that wait for the network start over. The line sing-box writes while it starts (and
  /// restarts) names the interface it began on: not a move, so it opens no switch window; the line of a core that
  /// runs (or of none) is one.
  void interfaceChanged() {
    if (_core == 'starting' || _core == 'recovering' || _core == 'down') return;
    _unconfirmedAt = clock.now().millisecondsSinceEpoch;
    _deriveNet(moved: true);
  }

  void _deriveNet({bool moved = false, int? at}) {
    final NetState s;
    final String src;
    if (_captive) {
      (s, src) = (NetState.captive, 'platform');
    } else if (_connected == false) {
      (s, src) = (NetState.none, 'platform');
    } else if (_osOffline) {
      (s, src) = (NetState.none, 'os');
    } else if (_poolDown) {
      (s, src) = (NetState.none, 'probes');
    } else if (_poolDoubt) {
      (s, src) = (NetState.unknown, 'doubt');
    } else if (_validated == false) {
      (s, src) = (NetState.unknown, 'platform');
    } else {
      (s, src) = (NetState.up, 'default');
    }
    final now = clock.now().millisecondsSinceEpoch;
    final changed = s != _net;
    if (!changed && !moved && src == _netSource) return;
    if (changed) _netSince = now;
    if (changed || moved) _netChangedAt = now;
    // A loss or return of connectivity counts for the timers that start over by [netEpoch]; only a real move opens the
    // switch window ([_movedAt]): the platform's / the OS's `none` ↔ the rest, or another network. The `none` of the probes is
    // Auto's own verdict, its recovery is not the device arriving on a network.
    bool out(NetState st, String from) => st == NetState.captive || (st == NetState.none && from != 'probes');
    final realMove = moved || out(s, src) != out(_net, _netSource);
    if (realMove || ((s == NetState.none || s == NetState.captive) != (_net == NetState.none || _net == NetState.captive))) {
      netEpoch++;
      if (realMove) {
        final evAt = at == null || at > now ? now : at;
        if (_stable) {
          _stable = false; // a new disturbance opens at the drop
          _disturbedAt = evAt;
          _stableAt = null;
          _stableBy = null;
        } else if (evAt < (_disturbedAt ?? evAt)) {
          _disturbedAt = evAt;
        }
        _eventAt = evAt;
        _proved = false; // what went through before this move proves nothing of the new network
      }
    }
    _net = s;
    _netSource = src;
    _evalStable();
    _fire();
  }

  // ── core ──

  // The stored state: `starting` | `running` | `recovering` | `down` | `stopped`; `settling` / `settled`
  // is told from the clock.
  String _core = 'stopped';
  late int _coreSince;
  DateTime? _runningSince;
  String? _restartReason;
  int? _restartAt;
  Timer? _settleTimer;
  // The spans in which the core was not settled: the closed ones, and the open one (from [_openFrom];
  // [_openTo] = the settle that will end it, once the core runs).
  final _closed = <(DateTime, DateTime)>[];
  DateTime? _openFrom, _openTo;

  CorePhase get phase {
    switch (_core) {
      case 'starting':
        return CorePhase.starting;
      case 'running':
        return clock.now().difference(_runningSince!) >= settle ? CorePhase.settled : CorePhase.settling;
      case 'recovering':
        return CorePhase.recovering;
      case 'down':
        return CorePhase.down;
      default:
        return CorePhase.stopped;
    }
  }

  bool get settled => phase == CorePhase.settled;

  CoreContext get core => CoreContext(phase: phase, since: _coreSince, restartReason: _restartReason, restartAt: _restartAt);

  /// sing-box is about to be started by us ([reason]: `userConnect`, `refreshLists`, `recover`, …).
  /// A crashed one being started again stays `recovering` / `down` (the attempt is the [reason]).
  void starting(String reason) {
    _restartReason = reason;
    _restartAt = clock.now().millisecondsSinceEpoch;
    if (_core == 'recovering' || _core == 'down') {
      _fire();
      return;
    }
    _begin();
    _set('starting');
  }

  /// sing-box is up. [since]: when it really started (an adopted one has been up for a while).
  void started({DateTime? since}) {
    final now = clock.now();
    _runningSince = since ?? now;
    _set('running');
    final end = _runningSince!.add(settle);
    if (end.isAfter(now)) {
      _begin();
      _openTo = end;
      _settleTimer = clock.timer(end.difference(now), _settleReached);
    } else {
      _end(now); // settled already (an adopted one): a span from `starting` ends here
    }
  }

  void _settleReached() {
    _settleTimer = null;
    if (_core == 'running') _fire();
  }

  /// sing-box stopped on its own; it is being started again.
  void crashed() {
    _begin();
    _set('recovering');
  }

  /// Not back for long enough: `down`.
  void down() {
    if (_core == 'down') return;
    _begin();
    _set('down');
  }

  /// No connection (a disconnect).
  void stopped() {
    _end(clock.now());
    _set('stopped');
  }

  void _set(String s) {
    _settleTimer?.cancel();
    _settleTimer = null;
    _core = s;
    _coreSince = clock.now().millisecondsSinceEpoch;
    coreEpoch++;
    _fire();
  }

  // An open span whose settle has passed is closed at it.
  void _roll(DateTime now) {
    final to = _openTo;
    if (_openFrom != null && to != null && !to.isAfter(now)) _end(to);
  }

  void _begin() {
    _roll(clock.now());
    _openFrom ??= clock.now();
    _openTo = null;
  }

  void _end(DateTime at) {
    final from = _openFrom;
    if (from == null) return;
    _closed.add((from, at.isBefore(from) ? from : at));
    if (_closed.length > 64) _closed.removeAt(0);
    _openFrom = _openTo = null;
  }

  /// The latest moment since [from] at which the core was not settled (our own start, a crash and its
  /// restarts); null = it was settled all along. While it is not settled now: now.
  DateTime? lastUnsettled(DateTime from) {
    final now = clock.now();
    _roll(now);
    DateTime? best;
    void see(DateTime a, DateTime b) {
      if (b.isBefore(from) || a.isAfter(now)) return;
      if (best == null || b.isAfter(best!)) best = b;
    }

    for (final (a, b) in _closed) {
      see(a, b);
    }
    final open = _openFrom;
    if (open != null) see(open, now);
    return best;
  }

  /// Since when the core has not been settled (our own start, a crash and its restarts); null = it is settled.
  DateTime? get unsettledSince {
    _roll(clock.now());
    return _openFrom;
  }

  /// Time until the settle (null when the core is not running).
  Duration? untilSettled() {
    if (_core != 'running') return null;
    final left = _runningSince!.add(settle).difference(clock.now());
    return left < Duration.zero ? Duration.zero : left;
  }

  Map<String, dynamic> toJson() => {'network': network.toJson(), 'core': core.toJson()};

  void dispose() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _capTimer?.cancel();
    _capTimer = null;
    unawaited(_changes.close());
  }
}
