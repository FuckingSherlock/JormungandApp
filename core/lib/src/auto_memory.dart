/// What Auto (auto.dart) and the "If unavailable" service (fallback.dart) know about the servers, routes and rule
/// targets they watch, outside the ladder of dead nodes (ladder.dart): the verdict of an object changes only after a
/// new check of that same object (docs/failures.md → «Вердикт меняется только после перепроверки»), and a service
/// that is made anew (a connect, a restart after a crash, an adopt, a restart for a rule set) must not forget it.
///
/// The services do not own this state, they borrow it: the [Health] of a server (ms, misses and answers in a row,
/// since when it answers), the route's flap guard (strikes, `up`), the servers that missed here ("already failed": a
/// return to one is `back`, not `preferred`) and a target's [Watched] (health, strikes). The owner ([CoreService]) holds
/// one [AutoMemory] for as long as the core lives and keeps it across a restart of the app ([AutoMemoryStore],
/// `<dataDir>/auto-state.json`), the same way the ladder is kept.
///
/// **Keys.** A server is keyed by its pool identity (pool.dart: a fingerprint of its outbound, a chain's exit through
/// its entry is the pair), which is what the ladder is keyed by; the route and the group it is a member of go in front
/// of it (the same node in two routes is two objects: each group counts its own misses). A server without an outbound
/// (identity = a tag, not the same on the next start) is not kept. A route is keyed by its id (the entry of the plan), a
/// target by the UI's target id.
///
/// **Forgetting.** Nothing is cleared by a new service. The flap guard's strikes are cleared by a change of the
/// network ([resetFlap]; [network] also sees a change that happened while no service ran), and by Auto's own rule (stable
/// work on the route in use, `flapReset`). An entry unseen for [keepFor] is left out of the file; at the start of the app
/// the ones whose nodes are gone from the catalog are dropped ([retainNodes]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auto.dart' show AutoUnstable, Health;
import 'durable.dart';
import 'watched.dart';

/// A route's own state: its health and the flap guard (auto.dart `_Route`).
class RouteMark {
  final health = Health();

  /// Answered since its last strike: a drop from here is a strike.
  bool up = false;

  /// Drops while another route answered (flap guard).
  int strikes = 0;
}

class AutoMemory {
  AutoMemory({this.keepFor = const Duration(days: 30)});

  /// How long an object nobody has checked stays in the file.
  final Duration keepFor;

  /// Called when something worth keeping changed ([AutoMemoryStore]).
  void Function()? onChange;

  final _servers = <String, Health>{};
  final _missed = <String, int>{};
  final _routes = <String, RouteMark>{};
  final _targets = <String, Watched>{};

  /// Routes the flap guard held back so far and the last one (`auto/unstable`, `status.auto.unstable`): the counter
  /// goes with the strikes it counts, so a service made anew goes on from it, not from 1.
  int unstableCount = 0;
  AutoUnstable? lastUnstable;

  /// The network (`type|id`, '|' = the platform has not said) and the Sentinel's `netEpoch` at the last look.
  String? _net;
  int? _epoch;

  /// The last [network] look saw another `type|id` than the one before (not just a move of the epoch, which a loss of
  /// the connection alone also makes): the verdicts about the network of the old one are void.
  bool keyMoved = false;

  /// Auto's «no network»: no route answered and nothing has since. Kept here (not in the service) so a service made
  /// anew starts with it; only a round in which a route answered clears it ([answered]). Not stored in the file: a
  /// restarted app knows nothing of the network yet.
  bool noNet = false;

  /// Since when no route answers while the `lost` of it stands (owed a `restored`); null = nothing stands. Survives the
  /// network change too: the answer that ends the outage still closes the event written for it.
  int? lostAt;

  /// Another network than the one the «no network» was found on: it is unknown now, not «no network» and not «online»
  /// (the next round tells). The open [lostAt] stays, so the outage is closed by the answer, not told twice.
  void netUnknown() => noNet = false;

  /// A route answered: the network is there; returns since when it was lost (null = it was not).
  int? answered() {
    noNet = false;
    final since = lostAt;
    lostAt = null;
    return since;
  }

  void changed() => onChange?.call();

  /// The health of a server by its key (see the library comment); made when missing.
  Health server(String key) => _servers.putIfAbsent(key, Health.new);

  /// A server missed a test here: true when it was not marked yet.
  bool markMissed(String key, int now) {
    final had = _missed.containsKey(key);
    _missed[key] = now;
    if (!had) changed();
    return !had;
  }

  /// Takes the mark off: true when the server had missed (a return to it is `back`).
  bool takeMissed(String key) {
    if (_missed.remove(key) == null) return false;
    changed();
    return true;
  }

  bool hasMissed(String key) => _missed.containsKey(key);

  RouteMark route(String id) => _routes.putIfAbsent(id, RouteMark.new);

  Watched target(String id) => _targets.putIfAbsent(id, Watched.new);

  int get length => _servers.length + _routes.length + _targets.length;

  /// Another network: the flap guard starts over (the strikes of a route say how it behaved on the old one, and the
  /// count of the routes it held back goes with them). The answers and misses stay. True when something went.
  bool resetFlap() {
    var any = unstableCount > 0 || lastUnstable != null;
    unstableCount = 0;
    lastUnstable = null;
    for (final r in _routes.values) {
      if (r.strikes > 0) {
        r.strikes = 0;
        any = true;
      }
    }
    for (final t in _targets.values) {
      if (t.strikes > 0) {
        t.strikes = 0;
        any = true;
      }
    }
    if (any) changed();
    return any;
  }

  /// A series of misses that is not finished ([Health.fails] below [failAfter]) is a series only while the checks
  /// follow each other: when the last one is older than [gap] the next miss starts a count of its own, so a server that
  /// missed once long ago is not one miss from dead. Such an object is made «not tested» (its old answer says nothing
  /// now either). A finished series (a verdict) and an object that answers stay. For the start of a service, [gap] =
  /// [AutoSettings.streakGap]. True when something was dropped.
  bool dropStaleStreaks(int now, Duration gap, int failAfter) {
    var any = false;
    void check(Health h) {
      if (h.fails <= 0 || h.fails >= failAfter || now - h.at <= gap.inMilliseconds) return;
      h
        ..ms = -2
        ..fails = 0
        ..oks = 0
        ..at = 0
        ..since = null;
      any = true;
    }

    _servers.values.forEach(check);
    for (final r in _routes.values) {
      check(r.health);
    }
    for (final t in _targets.values) {
      check(t.health);
    }
    if (any) changed();
    return any;
  }

  /// A look at the network: [key] = `type|id` ('|' = not said), [epoch] = the Sentinel context's `netEpoch`. Another
  /// network than at the last look (the epoch moved, or the id / type did while the app was closed or no service ran)
  /// resets the flap guard ([resetFlap]). True when it did move.
  bool network(String key, int epoch) {
    final known = key != '|';
    keyMoved = known && _net != null && key != _net;
    final moved = _epoch != null && epoch != _epoch || keyMoved;
    if (keyMoved) netUnknown();
    _epoch = epoch;
    if (known && key != _net) {
      _net = key;
      changed();
    }
    if (moved) resetFlap();
    return moved;
  }

  /// Drops what belongs to a node that is not among [known] (pool identities of the catalog's nodes): the servers and the
  /// marks of a pair need both of theirs. For the start of the app, before a service holds the objects.
  int retainNodes(Set<String> known) {
    bool gone(String key) => key.substring(key.lastIndexOf('|') + 1).split('>').any((id) => !known.contains(id));
    final n = length + _missed.length;
    _servers.removeWhere((k, _) => gone(k));
    _missed.removeWhere((k, _) => gone(k));
    final dropped = n - length - _missed.length;
    if (dropped > 0) changed();
    return dropped;
  }

  /// Takes what [toJson] kept ([AutoMemoryStore.load]); unreadable entries and those unseen for [keepFor] are left
  /// out. Returns how many objects it took.
  int load(Object? json, int now) {
    if (json is! Map) return 0;
    final cut = now - keepFor.inMilliseconds;
    var taken = 0;
    Iterable<Map> list(String k) => json[k] is List ? (json[k] as List).whereType<Map>().where((e) => e['k'] is String) : const [];
    int? i(Map e, String k) => e[k] is num ? (e[k] as num).toInt() : null;
    bool ok(Map e) => (i(e, 'at') ?? 0) >= cut && i(e, 'ms') != null && i(e, 'fails') != null && i(e, 'oks') != null;
    for (final e in list('servers')) {
      if (!ok(e)) continue;
      _servers[e['k'] as String] = Health()..loadStore(e);
      taken++;
    }
    for (final e in list('missed')) {
      final at = i(e, 'at');
      if (at == null || at < cut) continue;
      _missed[e['k'] as String] = at;
    }
    for (final e in list('routes')) {
      if (!ok(e)) continue;
      _routes[e['k'] as String] = RouteMark()
        ..health.loadStore(e)
        ..up = e['up'] == true
        ..strikes = i(e, 'strikes') ?? 0;
      taken++;
    }
    for (final e in list('targets')) {
      if (!ok(e)) continue;
      _targets[e['k'] as String] = Watched()
        ..health.loadStore(e)
        ..strikes = i(e, 'strikes') ?? 0
        ..usedSince = i(e, 'usedSince') ?? 0;
      taken++;
    }
    if (json['net'] is String) _net = json['net'] as String;
    final u = json['unstable'];
    if (u is Map && (i(u, 'count') ?? 0) > 0) {
      unstableCount = i(u, 'count')!;
      final l = u['last'];
      if (l is Map && l['id'] is String && i(l, 'strikes') != null && i(l, 'hold') != null && i(l, 'at') != null) {
        lastUnstable = AutoUnstable(id: l['id'] as String, strikes: i(l, 'strikes')!, holdMs: i(l, 'hold')!, at: i(l, 'at')!);
      }
    }
    return taken;
  }

  /// `{v, net, servers: [{k, ms, fails, oks, at, since}], missed: [{k, at}], routes: [{k, …health, up, strikes}],
  /// targets: [{k, …health, strikes, usedSince}], unstable: {count, last}}`. Objects never checked and those unseen for [keepFor] before [now]
  /// are left out.
  Map<String, dynamic> toJson(int now) {
    final cut = now - keepFor.inMilliseconds;
    return {
      'v': 1,
      'net': ?_net,
      if (unstableCount > 0) 'unstable': {'count': unstableCount, 'last': lastUnstable?.toJson()},
      'servers': [
        for (final e in _servers.entries)
          if (e.value.at >= cut && e.value.at > 0) {'k': e.key, ...e.value.toStore()},
      ],
      'missed': [
        for (final e in _missed.entries)
          if (e.value >= cut) {'k': e.key, 'at': e.value},
      ],
      'routes': [
        for (final e in _routes.entries)
          if (e.value.health.at >= cut && e.value.health.at > 0) {'k': e.key, ...e.value.health.toStore(), 'up': e.value.up, 'strikes': e.value.strikes},
      ],
      'targets': [
        for (final e in _targets.entries)
          if (e.value.health.at >= cut && e.value.health.at > 0)
            {'k': e.key, ...e.value.health.toStore(), 'strikes': e.value.strikes, 'usedSince': e.value.usedSince},
      ],
    };
  }
}

/// Keeps the memory in a file (`<dataDir>/auto-state.json`): written a moment after it changed (one write for a
/// round's worth of changes), read at the start. The same shape as the dead ladder's store (ladder.dart).
class AutoMemoryStore {
  AutoMemoryStore(this.file, this.memory, {int Function()? clock, this.debounce = const Duration(seconds: 2)})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    memory.onChange = _changed;
  }

  final File file;
  final AutoMemory memory;
  final Duration debounce;
  final int Function() _clock;
  Timer? _timer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Reads the file (none / damaged = nothing known); returns how many objects were taken.
  int load() {
    try {
      return memory.load(jsonDecode(file.readAsStringSync()), _clock());
    } catch (_) {
      return 0;
    }
  }

  void _changed() {
    if (_closed || _timer != null) return;
    _timer = Timer(debounce, () {
      _timer = null;
      _writing = _writing.then((_) => _write());
    });
  }

  Future<void> _write() async {
    try {
      await writeFileDurable(file, jsonEncode(memory.toJson(_clock())));
    } catch (_) {} // a full disk or a locked file: it lives in memory, the next change writes again
  }

  /// Writes what waits now (the app closes) and stops watching the memory.
  Future<void> close() async {
    final pending = _timer != null;
    _timer?.cancel();
    _timer = null;
    _closed = true;
    if (memory.onChange == _changed) memory.onChange = null;
    if (pending) _writing = _writing.then((_) => _write());
    await _writing;
  }
}
