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
  void platform({bool? connected, bool? validated, bool captive = false, String? type, String? id}) {
    _connected = connected;
    _validated = validated;
    _captive = captive;
    final moved = (id != null && _id != null && id != _id) || (type != null && _type != null && type != _type);
    _type = type;
    _id = id;
    _deriveNet(moved: moved);
  }

  /// The default interface changed (sing-box: `updated default interface`), or the device moved to
  /// another network: timers that wait for the network start over.
  void interfaceChanged() => _deriveNet(moved: true);

  void _deriveNet({bool moved = false}) {
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
    if (moved || ((s == NetState.none || s == NetState.captive) != (_net == NetState.none || _net == NetState.captive))) netEpoch++;
    _net = s;
    _netSource = src;
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
    unawaited(_changes.close());
  }
}
