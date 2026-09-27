/// AutoService: keeps the connection on a working route while sing-box runs, through
/// sing-box's API service (sbapi.dart) and with no restart — the failover Auto promises
/// (docs/connect-model.md → Auto / Manual).
///
/// The config (config.dart) holds every Auto entry of the plan as a route under the
/// selector `proxy` (in Manual only the pinned entry). A switch never cuts open
/// connections (`interrupt_exist_connections: false`): after leaving a route or server
/// that stopped answering, the service closes only the connections still on it whose
/// byte counters stand still (`stallAfter`).
///
/// A round (every `checkEvery`) tests the server each route would use now — the current
/// route, the routes above it (to go back up; not with `returnTo: never`) and, every
/// `warmEvery`, the `standby` ones below (spares; 0 = none) — one test per group (a chain:
/// its entry, then the exit through it):
///
/// - a Fastest group (urltest) whose server did not answer has urltest test again and
///   pick again at once (sing-box itself drops a server after one miss);
/// - a Priority group (selector) leaves its server after `failAfter` misses in a row, for
///   the first answering one in its order; a server above the current one comes back by
///   the return rule (`returnTo`). A pinned server (Manual on a server) is never moved;
/// - the current route missed: the next rounds test it alone, `retryPause` apart; after
///   `failAfter` misses in a row it is dead: the routes above and the spares are tested
///   together, then the next [AutoSettings.batch] routes by priority; `proxy` moves to the
///   first one by priority that answered (failover). The whole batch silent too = no
///   network (`noNet`): nothing is moved, marked or struck, a round every `noNetEvery`;
/// - a route above the current one comes back by `returnTo` (always: answered `failAfter`
///   rounds in a row and no slower than the current by more than `threshold`; faster:
///   faster than it by `threshold`; never: not until a reconnect) and only after its hold
///   (flap guard): every drop of a route while another one answered in the same round is
///   a strike, and it must answer for 1, 2, 4 … `flapMax` minutes in a row before it gets
///   the traffic back; the strikes are forgotten after `flapReset` of stable work on it.
///
/// A round in which no route answered strikes and marks no one: the misses of every route
/// but the current one are put back as they were.
///
/// A test is [delay] (see [_ping]): one round trip on an open connection through the
/// config's probe inbound (probe.dart), what the catalog shows.
///
/// Pure Dart with no UI in it: the app reads [toJson] and listens to [switches] and
/// [unstable] (jormd serves them through /api/status; Flutter will call it directly).
library;

import 'dart:async';
import 'dart:math';

import 'config.dart' show defaultTestUrl, planCheckers;
import 'plan.dart';
import 'probe.dart' show withCheckers;
import 'sbapi.dart' show BoxControl, ClosedConnection;

/// When a route above the current one takes the traffic back.
enum ReturnTo { always, faster, never }

class AutoSettings {
  const AutoSettings({
    this.failAfter = 2,
    this.threshold = 50,
    this.checkEvery = const Duration(minutes: 1),
    this.standby = 2,
    this.warmEvery = const Duration(minutes: 1),
    this.url = defaultTestUrl,
    this.checkers = const [],
    this.timeoutMs = 5000,
    this.retryPause = const Duration(milliseconds: 500),
    this.returnTo = ReturnTo.always,
    this.flapGuard = true,
    this.flapMax = const Duration(minutes: 30),
    this.flapReset = const Duration(minutes: 15),
    this.firstCheck = const Duration(seconds: 3),
    this.noNetEvery = const Duration(seconds: 10),
    this.stallAfter = const Duration(seconds: 10),
    this.batch = 10,
    this.failWindow = const Duration(seconds: 10),
  });

  /// From a plan: `auto` = {failAfter, threshold (ms), checkEvery (s), standby, warmEvery (s),
  /// retryPause (s, 0.1–10), returnTo ('always' | 'faster' | 'never'), flapGuard, flapMax
  /// (min, 1–60), flapReset (min, 5–60)} (the UI's autoCfg), the test URL from `urlTest`.
  /// Missing fields = the defaults (an older plan: `returnTo` always); an older plan's
  /// `keepWarm: false` = standby 0.
  factory AutoSettings.fromPlan(Map<String, dynamic> plan) {
    final a = (plan['auto'] as Map?) ?? const {};
    final t = (plan['urlTest'] as Map?) ?? const {};
    int n(Object? v, int def) => v is num ? v.toInt() : def;
    final pause = a['retryPause'];
    return AutoSettings(
      failAfter: n(a['failAfter'], 2).clamp(1, 5),
      threshold: n(a['threshold'] ?? t['tolerance'], 50).clamp(0, 10000),
      checkEvery: Duration(seconds: n(a['checkEvery'] ?? t['interval'], 60).clamp(10, 3600)),
      standby: a['keepWarm'] == false ? 0 : n(a['standby'], 2).clamp(0, 20),
      warmEvery: Duration(seconds: n(a['warmEvery'], 60).clamp(10, 3600)),
      url: (t['url'] as String?) ?? defaultTestUrl,
      checkers: planCheckers(plan),
      retryPause: Duration(milliseconds: pause is num ? (pause * 1000).round().clamp(100, 10000) : 500),
      returnTo: ReturnTo.values.firstWhere((m) => m.name == a['returnTo'], orElse: () => ReturnTo.always),
      flapGuard: a['flapGuard'] != false,
      flapMax: Duration(minutes: n(a['flapMax'], 30).clamp(1, 60)),
      flapReset: Duration(minutes: n(a['flapReset'], 15).clamp(5, 60)),
    );
  }

  final int failAfter; // misses in a row before leaving a server / route
  final int threshold; // ms: how much slower a higher one may be and still come back
  final Duration checkEvery;
  final int standby; // spares: routes below the current one tested ahead
  final Duration warmEvery; // how often the spares are tested (at a check, not more often)
  final String url;
  final List<String> checkers; // backup checks when [url] does not answer (probe.dart withCheckers)
  final int timeoutMs;
  final Duration retryPause; // between the tests of a current route that missed
  final ReturnTo returnTo;
  final bool flapGuard; // hold a route that keeps dropping before going back to it
  final Duration flapMax; // the longest hold
  final Duration flapReset; // stable work on a route that forgets its strikes
  final Duration firstCheck; // after start
  final Duration noNetEvery; // rounds while no route answers
  final Duration stallAfter; // a connection left on a dead route with no bytes this long is closed
  final int batch; // routes / servers tested at once when looking for one that answers
  final Duration failWindow; // failed requests of the current route within it = one check

  /// The hold after [strikes] drops: 1, 2, 4 … minutes, up to [flapMax].
  Duration hold(int strikes) {
    if (!flapGuard || strikes <= 0) return Duration.zero;
    final m = Duration(minutes: 1) * (1 << min(strikes - 1, 20));
    return m < flapMax ? m : flapMax;
  }
}

/// What the checks know about one server or route.
class Health {
  int ms = -2; // last result: delay in ms, -1 = no answer, -2 = not tested yet
  int fails = 0; // misses in a row
  int oks = 0; // answers in a row
  int at = 0; // when, ms since epoch
  int? since; // when the answers in a row began

  bool get answered => ms >= 0;

  void record(int delay, int now) {
    ms = delay;
    at = now;
    if (delay >= 0) {
      if (oks == 0) since = now;
      oks++;
      fails = 0;
    } else {
      fails++;
      oks = 0;
      since = null;
    }
  }

  List<int?> _save() => [ms, fails, oks, at, since];
  void _load(List<int?> s) {
    ms = s[0]!;
    fails = s[1]!;
    oks = s[2]!;
    at = s[3]!;
    since = s[4];
  }

  Map<String, dynamic> toJson() => {'ms': ms, 'fails': fails, 'oks': oks, 'at': at};
}

/// A move the service made: between routes ([route] null, [from] / [to] = route ids), or
/// between the servers of a Priority group ([route] = its route's id, [from] / [to] =
/// server keys). [reason]: `failover` (the current one stopped answering) or `back` (a
/// higher one answers again).
class AutoSwitch {
  const AutoSwitch({required this.from, required this.to, required this.reason, required this.at, this.route});
  final String? route;
  final String from, to, reason;
  final int at;

  bool get isRoute => route == null;
  Map<String, dynamic> toJson() => {'from': from, 'to': to, 'reason': reason, 'at': at, 'route': ?route};
}

/// A route dropped again ([strikes] ≥ 2, flap guard on): it gets the traffic back only
/// after answering [holdMs] in a row.
class AutoUnstable {
  const AutoUnstable({required this.id, required this.strikes, required this.holdMs, required this.at});
  final String id;
  final int strikes, holdMs, at;
  Map<String, dynamic> toJson() => {'id': id, 'strikes': strikes, 'hold': holdMs, 'at': at};
}

/// A site ([dest], `host:port`) that does not open through [route]'s server [server]
/// while the node passes traffic, and opens through the route [via]: the app offers a
/// rule (the site → [via]).
class AutoBlocked {
  const AutoBlocked({required this.route, required this.server, required this.dest, required this.via, required this.at});
  final String route, server, dest, via;
  final int at;
  Map<String, dynamic> toJson() => {'route': route, 'server': server, 'dest': dest, 'via': via, 'at': at};
}

class _Group {
  _Group(this.tag, Map g, {this.pair = false})
      : priority = g['pick'] == 'priority',
        pinned = g['pinned'] == true,
        keys = {for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) '${n['key']}'}.toList() {
    if (priority && keys.contains(g['chosen'])) now = g['chosen'] as String;
  }

  final String tag;
  final bool priority, pinned;
  final bool pair; // its servers dial through another group: a result is the whole chain's
  final List<String> keys;
  final health = <String, Health>{};
  String? now; // the server in use (key)

  String get current => now ?? keys.first;
  String member(String key) => '$tag/$key';
  String? keyOf(Object? t) => t is String && t.startsWith('$tag/') ? t.substring(tag.length + 1) : null;
  Health of(String key) => health.putIfAbsent(key, Health.new);
}

class _Route {
  _Route(int i, Map<String, dynamic> r)
      : id = '${r['id'] ?? routeTag(i)}',
        tag = routeTag(i),
        entry = r['kind'] == 'chain' ? _Group(routeEntryTag(i), r['entry'] as Map) : null,
        main = _Group(routeTag(i), r['main'] as Map, pair: r['kind'] == 'chain');

  final String id, tag;
  final _Group? entry;
  final _Group main;
  final health = Health();
  bool checked = false; // tested in the running round
  bool up = false; // answered since its last strike: a drop from here is a strike
  int strikes = 0; // drops (flap guard)
  int inUseSince = 0; // when it became the current route

  List<_Group> get groups => [?entry, main];
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

/// ms through the outbound [tag] to [url]; -1 = no answer.
typedef DelayTest = Future<int> Function(String tag, String url, int timeoutMs);

class AutoService {
  AutoService(this.api, Map<String, dynamic> plan, {required this.delay, AutoSettings? settings, int Function()? clock, this.reach, this.note})
      : settings = settings ?? AutoSettings.fromPlan(plan),
        _clock = clock ?? _wallClock {
    final rs = planRoutes(plan);
    _routes = [for (var i = 0; i < rs.length; i++) _Route(i, rs[i])];
    index = planCurrent(plan, _routes.length);
    _routes[index].inUseSince = _clock();
  }

  final BoxControl api;
  final DelayTest delay;

  /// Whether a site (`host:port`) opens through an outbound tag (probe.dart probeReach);
  /// null = cannot be told. Without it the sites of failed requests are not tried again.
  final Future<bool?> Function(String tag, String dest)? reach;

  /// A line for the log (jormd: the Logs tab, as `[jormd] auto: …`).
  final void Function(String line)? note;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;
  final int Function() _clock;
  late final List<_Route> _routes;

  /// The plan's routes (entry ids) in priority order.
  List<String> get routeIds => [for (final r in _routes) r.id];

  /// The route in use (index into the plan's routes).
  late int index;

  /// Moves so far (routes and Priority servers, as on [switches]); a Fastest group's own
  /// re-picks inside sing-box are not counted.
  int switchCount = 0;
  int? switchedAt;
  AutoSwitch? lastSwitch;

  /// Routes found unstable so far (as on [unstable]) and the last one.
  int unstableCount = 0;
  AutoUnstable? lastUnstable;

  /// The current route is dead and no other route answers (the next batch silent too):
  /// everything stays as it is, a round every `noNetEvery`.
  bool noNet = false;

  /// The OS has no network (sing-box: `missing default interface`): like [noNet], nothing
  /// is tested, moved or marked until it is back.
  bool offline = false;

  /// Requests through the current route that could not open (see [onLog]) and the last.
  int requestFails = 0;
  Map<String, dynamic>? lastRequestFail;

  /// Sites found blocked on a node (as on [blocked]) and the last.
  int blockedCount = 0;
  AutoBlocked? lastBlocked;

  /// Connections closed as stalled on a route / server left for a dead one.
  int stalledClosed = 0;
  int? checkedAt;
  int? refreshedAt;

  final _switches = StreamController<AutoSwitch>.broadcast();
  final _unstable = StreamController<AutoUnstable>.broadcast();
  final _blocked = StreamController<AutoBlocked>.broadcast();
  Timer? _timer;
  StreamSubscription<void>? _groupsSub;
  final _sweeps = <Timer>{};
  bool _busy = false, _started = false, _stopped = false;
  bool _kick = false; // a check is due at once when the running one ends
  bool _failCheck = false; // the running / next check was asked for by failed requests
  int? _failAt; // the first failed request of the current window
  final _failDests = <String, String>{}; // sites that got nothing back → the server's outbound tag
  final _blockedAt = <String, int>{}; // 'route site' → when it was reported
  int? _warmedAt; // when the spares were tested last

  /// Every move between routes and between Priority servers.
  Stream<AutoSwitch> get switches => _switches.stream;

  /// A route that keeps dropping (flap guard).
  Stream<AutoUnstable> get unstable => _unstable.stream;

  /// A site that does not open through the current node but does through another route.
  Stream<AutoBlocked> get blocked => _blocked.stream;

  /// Checks on a timer from now on (the first one after `firstCheck`).
  void start() {
    _started = true;
    // urltest re-picks on its own after its rounds: the groups stream tells at once
    _groupsSub = api.groupsChanged.listen((_) => refresh());
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _groupsSub?.cancel();
    for (final t in _sweeps) {
      t.cancel();
    }
    _switches.close();
    _unstable.close();
    _blocked.close();
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_started && !_stopped) _timer = Timer(d, () => unawaited(check()));
  }

  /// One round: test, heal inside the routes, move between them.
  Future<void> check() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      if (!await refresh()) return; // sing-box not answering: nothing to judge
      if (offline) {
        noNet = true;
        return;
      }
      for (final r in _routes) {
        r.checked = false;
      }
      final cur = _routes[index];
      // the misses of this round that may be put back (no route answered): all but the
      // current route's own and its servers'
      final keep = <Health>{cur.health, for (final g in cur.groups) g.of(g.current)};
      final saved = {
        for (final r in _routes) ...{
          r.health: r.health._save(),
          for (final g in r.groups)
            for (final h in g.health.values) h: h._save(),
        },
      }..removeWhere((h, _) => keep.contains(h));
      final retry = cur.health.fails > 0 && cur.health.fails < settings.failAfter;
      final todo = {index};
      if (!retry) {
        // the spares are due a little early rather than a whole check late
        final now = _clock();
        final warm = settings.standby > 0 && (_warmedAt == null || now - _warmedAt! >= settings.warmEvery.inMilliseconds - 1000);
        if (warm) _warmedAt = now;
        if (settings.returnTo != ReturnTo.never) todo.addAll([for (var i = 0; i < index; i++) i]);
        if (warm) todo.addAll([for (var i = index + 1; i <= index + settings.standby && i < _routes.length; i++) i]);
      }
      await Future.wait(todo.map((i) => _checkRoute(_routes[i])));
      if (_stopped) return;
      await _decide();
      if (_stopped) return;
      if (!_routes.any((r) => r.checked && r.health.answered)) {
        // no network (or not yet sure): nobody is marked by this round
        saved.forEach((h, s) => h._load(s));
      } else {
        noNet = false;
        _judge();
      }
      checkedAt = _clock();
      if (_failCheck) {
        _failCheck = false;
        if (identical(_routes[index], cur) && cur.health.answered) {
          unawaited(_sites(cur));
        } else if (identical(_routes[index], cur) && !noNet) {
          note?.call('auto: ${cur.id} does not pass traffic: tests again every ${settings.retryPause.inMilliseconds} ms');
        }
      }
    } finally {
      _busy = false;
      final f = _routes[index].health.fails;
      _schedule(_kick
          ? Duration.zero
          : noNet
              ? settings.noNetEvery
              : f > 0
                  ? settings.retryPause
                  : settings.checkEvery);
      _kick = false;
    }
  }

  /// A line sing-box wrote (runtime `onLog`): the OS without a network (`missing default
  /// interface`) sets [offline], its return (`updated default interface`) clears it and
  /// has a check run at once.
  void onLog(String line) {
    if (_stopped) return;
    if (line.contains('missing default interface')) {
      if (!offline) note?.call('auto: the system has no network: nothing is tested or moved until it is back');
      offline = true;
    } else if (line.contains('updated default interface') && offline) {
      offline = false;
      note?.call('auto: the system network is back: checking');
      _kickNow();
    }
  }

  /// A connection sing-box closed (its API service, sbapi.dart). One through the current
  /// route that got nothing back is a failed request: sent nothing either — it could not
  /// open (the node: dial, handshake, the server gone); sent something — the node or the
  /// site. The first one has the route checked at once instead of at the next round; the
  /// ones within `failWindow` go into that one check. The check tests the node with the
  /// backup checks: it does not answer — the usual retries, `failAfter`, failover; it
  /// answers — the sites the requests went to are tried again ([_sites]).
  void onClosed(ClosedConnection c) {
    if (_stopped || offline || c.down > 0) return;
    if (c.chain.map(_routeOf).firstWhere((i) => i != null, orElse: () => null) != index) return;
    final now = _clock();
    requestFails++;
    lastRequestFail = {'route': _routes[index].id, 'dest': c.destination, 'sent': c.up, 'at': now};
    if (c.up > 0 && _failDests.length < 20) _failDests[c.destination] = c.outbound;
    if (_failAt != null && now - _failAt! < settings.failWindow.inMilliseconds) return;
    _failAt = now;
    _failDests.removeWhere((d, _) => d != c.destination);
    note?.call('auto: a request through ${_routes[index].id} got nothing back (${c.destination}): checking it now');
    _failCheck = true;
    _kickNow();
  }

  // The node passes traffic, yet requests through it got nothing back: each site again
  // through it; opens now — one-off; not — through another route that answers: opens
  // there — the site is blocked on this node ([blocked], once an hour per site and route);
  // not there either — the site is down (a log line).
  Future<void> _sites(_Route cur) async {
    final dests = Map.of(_failDests);
    _failDests.clear();
    if (reach == null || dests.isEmpty) return;
    final alt = [for (var i = 0; i < _routes.length; i++) if (i != index && _routes[i].health.answered) _routes[i]].firstOrNull;
    for (final MapEntry(key: dest, value: tag) in dests.entries) {
      if (_stopped) return;
      final here = await reach!(tag, dest);
      if (here != false) continue; // opens now, or cannot be told
      final altTag = alt?.main.member(alt.main.current);
      final there = altTag == null ? null : await reach!(altTag, dest);
      if (there != true) {
        note?.call('auto: $dest does not open through ${cur.id}${alt == null ? '' : ' nor ${alt.id}'}: the site is down or blocked everywhere');
        continue;
      }
      final key = '${cur.id} $dest', now = _clock();
      if (now - (_blockedAt[key] ?? -3600000) < 3600000) continue;
      _blockedAt[key] = now;
      final b = AutoBlocked(route: cur.id, server: cur.main.current, dest: dest, via: alt!.id, at: now);
      blockedCount++;
      lastBlocked = b;
      note?.call('auto: $dest does not open through ${cur.id}, opens through ${alt.id}');
      if (!_blocked.isClosed) _blocked.add(b);
    }
  }

  void _kickNow() {
    if (_busy) {
      _kick = true;
    } else {
      _schedule(Duration.zero);
    }
  }

  // The route an outbound tag of a log line belongs to: `proxy` = the current one; a
  // route's group or one of its servers.
  int? _routeOf(String tag) {
    if (tag == topTag) return index;
    for (var i = 0; i < _routes.length; i++) {
      for (final g in _routes[i].groups) {
        if (g.tag == tag || g.keyOf(tag) != null) return i;
      }
    }
    return null;
  }

  /// Reads which route and servers sing-box uses now (the groups stream, sbapi.dart). A
  /// Fastest group of the current route that moved by itself (urltest re-picked) is a
  /// switch too (reason `fastest`). False before sing-box first told.
  Future<bool> refresh() async {
    final by = api.selected;
    if (by.isEmpty || _stopped) return false;
    final i = _routes.indexWhere((r) => r.tag == by[topTag]);
    if (i >= 0 && i != index) {
      index = i;
      _routes[i].inUseSince = _clock();
    }
    for (final r in _routes) {
      for (final g in r.groups) {
        final was = g.now, now = g.keyOf(by[g.tag]) ?? g.now;
        g.now = now;
        if (!g.priority && identical(r, _routes[index]) && was != null && now != null && now != was) {
          _emit(AutoSwitch(route: r.id, from: was, to: now, reason: 'fastest', at: _clock()));
        }
      }
    }
    refreshedAt = _clock();
    return true;
  }

  Future<void> _checkRoute(_Route r) async {
    var ms = -1;
    for (final g in r.groups) {
      ms = await _checkGroup(r, g);
      if (ms < 0) break;
    }
    if (_stopped) return;
    r.health.record(ms, _clock());
    r.checked = true;
  }

  // The server the group uses now; when it misses, the group heals by its kind.
  Future<int> _checkGroup(_Route r, _Group g) async {
    final key = g.current;
    final ms = await _test(g, key);
    if (g.pinned) return ms;
    if (g.priority) {
      if (ms >= 0) return settings.returnTo == ReturnTo.never ? ms : _priorityBack(r, g, key, ms);
      if (g.of(key).fails < settings.failAfter) return -1;
      final to = await _firstAnswering(g, [for (final k in g.keys) if (k != key) k]);
      if (to == null || !await _pick(r, g, to, 'failover')) return -1;
      _closeStalled(g.member(key), () => g.current != key);
      return g.of(to).ms;
    }
    return ms >= 0 ? ms : _heal(g, key);
  }

  /// The one test of a server: ms through the group member [key], -1 = no answer. The
  /// test URL, then the backup checks at once (withCheckers): it passes traffic when any
  /// answers.
  Future<int> _ping(_Group g, String key) => withCheckers((url) => _pingUrl(g.member(key), url), settings.url, settings.checkers);

  Future<int> _pingUrl(String tag, String url) => delay(tag, url, settings.timeoutMs);

  Future<int> _test(_Group g, String key) async {
    final ms = await _ping(g, key);
    if (!_stopped) g.of(key).record(ms, _clock());
    return ms;
  }

  // In order, a batch at a time: the first that answers.
  Future<String?> _firstAnswering(_Group g, List<String> keys) async {
    final b = settings.batch;
    for (var i = 0; i < keys.length && !_stopped; i += b) {
      final batch = keys.sublist(i, min(i + b, keys.length));
      await Future.wait(batch.map((k) => _test(g, k)));
      for (final k in batch) {
        if (g.of(k).answered) return k;
      }
    }
    return null;
  }

  // The return rule (returnTo) for a higher route / server [h] over the current one.
  bool _mayReturn(Health h, int curMs) {
    if (h.oks < settings.failAfter) return false;
    return switch (settings.returnTo) {
      ReturnTo.never => false,
      ReturnTo.faster => curMs < 0 || h.ms + settings.threshold <= curMs,
      ReturnTo.always => curMs < 0 || h.ms <= curMs + settings.threshold,
    };
  }

  // Flap guard: a route with strikes gets the traffic back after answering its hold.
  bool _onHold(_Route r) {
    final hold = settings.hold(r.strikes);
    if (hold == Duration.zero) return false;
    final since = r.health.since;
    return since == null || _clock() - since < hold.inMilliseconds;
  }

  // Priority: a server above the current one that is back takes over again.
  Future<int> _priorityBack(_Route r, _Group g, String cur, int curMs) async {
    final above = g.keys.takeWhile((k) => k != cur).toList();
    final b = settings.batch;
    for (var i = 0; i < above.length && !_stopped; i += b) {
      await Future.wait(above.sublist(i, min(i + b, above.length)).map((k) => _test(g, k)));
    }
    for (final k in above) {
      if (_mayReturn(g.of(k), curMs) && await _pick(r, g, k, 'back')) return g.of(k).ms;
    }
    return curMs;
  }

  // Fastest: our failed test does not reach urltest's own history; it tests all its
  // servers again (the API's group test) and picks among the ones that answer.
  Future<int> _heal(_Group g, String failed) async {
    final res = await api.testGroup(g.tag, leaving: g.member(failed), timeout: Duration(milliseconds: settings.timeoutMs + 5000));
    if (_stopped) return -1;
    final now = _clock();
    // urltest's numbers are sing-box's (first request, handshakes and all). The group test
    // covers every member: the ones missing from the answer missed too (the failed one is
    // counted once, by its own test just before _heal was called). No fresh result at all =
    // sing-box skipped the test (it ignores one asked too soon after its last): nothing known.
    if (res != null && res.isNotEmpty) {
      for (final k in g.keys) {
        if (k == failed) continue;
        g.of(k).record(res[g.member(k)] ?? -1, now);
      }
    }
    await refresh();
    if (g.current == failed) return -1;
    _closeStalled(g.member(failed), () => g.current != failed);
    return _test(g, g.current);
  }

  Future<bool> _pick(_Route r, _Group g, String key, String reason) async {
    if (_stopped || !await api.select(g.tag, g.member(key))) return false;
    final from = g.current;
    g.now = key;
    _emit(AutoSwitch(route: r.id, from: from, to: key, reason: reason, at: _clock()));
    return true;
  }

  Future<bool> _moveTo(int i, String reason) async {
    if (_stopped || !await api.select(topTag, _routes[i].tag)) return false;
    final from = _routes[index].id;
    index = i;
    _routes[i].inUseSince = _clock();
    _emit(AutoSwitch(from: from, to: _routes[i].id, reason: reason, at: _clock()));
    return true;
  }

  void _emit(AutoSwitch s) {
    switchCount++;
    switchedAt = s.at;
    lastSwitch = s;
    if (!_switches.isClosed) _switches.add(s);
  }

  int? _firstAnswered() {
    for (var i = 0; i < _routes.length; i++) {
      if (i != index && _routes[i].checked && _routes[i].health.answered) return i;
    }
    return null;
  }

  Future<void> _decide() async {
    final cur = _routes[index];
    if (cur.health.fails >= settings.failAfter) {
      // dead: the routes above and the spares at once, then the next batch by priority;
      // the first by priority that answered takes over
      bool untested(int i) => i != index && !_routes[i].checked;
      final first = [for (var i = 0; i < _routes.length; i++) if (untested(i) && (i < index || i <= index + settings.standby)) i];
      await Future.wait(first.map((i) => _checkRoute(_routes[i])));
      var to = _firstAnswered();
      // the rest by priority, a batch at a time, until one answers; once in no network,
      // only the first batch (the whole list again every noNetEvery would be a waste)
      final rest = [for (var i = 0; i < _routes.length; i++) if (untested(i)) i];
      final upTo = noNet ? min(settings.batch, rest.length) : rest.length;
      for (var b = 0; to == null && b < upTo && !_stopped; b += settings.batch) {
        await Future.wait(rest.sublist(b, min(b + settings.batch, upTo)).map((i) => _checkRoute(_routes[i])));
        to = _firstAnswered();
      }
      if (_stopped) return;
      if (to == null) {
        noNet = true; // no route answers: no network, not this route
        return;
      }
      final old = cur.tag;
      if (await _moveTo(to, 'failover')) _closeStalled(old, () => _routes[index].tag != old);
      return;
    }
    for (var i = 0; i < index; i++) {
      final r = _routes[i];
      if (r.checked && _mayReturn(r.health, cur.health.ms) && !_onHold(r) && await _moveTo(i, 'back')) return;
    }
  }

  // After a round in which some route answered: strikes for the ones that dropped (flap
  // guard), stable work forgets them.
  void _judge() {
    final now = _clock();
    for (final r in _routes) {
      if (!r.checked) continue;
      if (r.health.answered) {
        r.up = true;
      } else if (r.up && r.health.fails >= settings.failAfter && _routes.any((o) => o != r && o.checked && o.health.answered)) {
        r.up = false;
        r.strikes++;
        if (settings.flapGuard && r.strikes >= 2) {
          final u = AutoUnstable(id: r.id, strikes: r.strikes, holdMs: settings.hold(r.strikes).inMilliseconds, at: now);
          unstableCount++;
          lastUnstable = u;
          if (!_unstable.isClosed) _unstable.add(u);
        }
      }
    }
    final cur = _routes[index], since = cur.health.since;
    if (cur.strikes > 0 && since != null && now - max(since, cur.inUseSince) >= settings.flapReset.inMilliseconds) cur.strikes = 0;
  }

  /// Connections left on [tag] (a route or a server Auto just left because it stopped
  /// answering): the ones whose byte counters stood still for `stallAfter` are closed, the
  /// ones still moving live on. Again every `stallAfter`, up to 6 times, while [away].
  void _closeStalled(String tag, bool Function() away) {
    Map<String, int>? before;
    var left = 6;
    Future<void> pass() async {
      if (_stopped || !away()) return;
      final now = <String, int>{
        for (final c in api.connections)
          if (c.chain.contains(tag)) c.id: c.up + c.down,
      };
      if (before != null) {
        for (final e in [...now.entries]) {
          if (before![e.key] == e.value && !_stopped) {
            if (await api.closeConnection(e.key)) stalledClosed++;
            now.remove(e.key);
          }
        }
      }
      before = now;
      if (now.isEmpty || --left <= 0 || _stopped) return;
      late final Timer t;
      t = Timer(settings.stallAfter, () {
        _sweeps.remove(t);
        unawaited(pass());
      });
      _sweeps.add(t);
    }

    unawaited(pass());
  }

  /// For the app: `{now: route id, index, server, entryServer (chain), routes: [{id, ms,
  /// fails, oks, at, strikes, holdUntil}], members: [{key, ms, fails, oks, at}] (every
  /// server tested so far, not a chain's exits: those are measured through the entry),
  /// switches (count), switchedAt, lastSwitch ({route?, from, to, reason, at}; with
  /// `route` = a Priority server move inside that route, `from`/`to` are then server
  /// keys), unstable (count), lastUnstable ({id, strikes, hold, at}), noNet, stalledClosed,
  /// checkedAt}`. `holdUntil`: when a route on hold may take the traffic back if it keeps
  /// answering (null: not on hold, or not answering now).
  Map<String, dynamic> toJson() {
    final cur = _routes[index];
    int? holdUntil(_Route r) {
      final s = r.health.since;
      return _onHold(r) && s != null ? s + settings.hold(r.strikes).inMilliseconds : null;
    }

    return {
      'now': cur.id,
      'index': index,
      'server': cur.main.now,
      'entryServer': cur.entry?.now,
      'routes': [
        for (final r in _routes) {'id': r.id, ...r.health.toJson(), 'strikes': r.strikes, 'holdUntil': holdUntil(r)},
      ],
      'members': [
        for (final r in _routes)
          for (final g in r.groups)
            if (!g.pair)
              for (final e in g.health.entries)
                if (e.value.at > 0) {'key': e.key, ...e.value.toJson()},
      ],
      'switches': switchCount,
      'switchedAt': switchedAt,
      'lastSwitch': lastSwitch?.toJson(),
      'unstable': unstableCount,
      'lastUnstable': lastUnstable?.toJson(),
      'noNet': noNet,
      'offline': offline,
      'requestFails': requestFails,
      'lastRequestFail': lastRequestFail,
      'blocked': blockedCount,
      'lastBlocked': lastBlocked?.toJson(),
      'stalledClosed': stalledClosed,
      'checkedAt': checkedAt,
    };
  }
}
