/// AutoService: keeps the connection on a working route while sing-box runs, through
/// sing-box's Clash API and with no restart — the failover Auto promises
/// (docs/connect-model.md → Auto / Manual).
///
/// The config (config.dart) holds the plan's routes under the selector `proxy`: the Auto
/// entries by priority from the top down to the current one and `standby` more; in Manual
/// only the pinned entry. Every `checkEvery` the service tests the server each route would
/// use now — the current route, the routes above it (to go back up) and, with keep warm,
/// the standby ones — one delay test per group (a chain: its entry, then the exit through
/// it):
///
/// - a Fastest group (urltest) whose server did not answer has urltest test again and
///   pick again at once (sing-box itself drops a server after one miss);
/// - a Priority group (selector) leaves its server after `failAfter` misses in a row, for
///   the first answering one in its order; a server above the current one that answered
///   `failAfter` checks in a row and is no slower than the current by more than `threshold`
///   takes over again. A pinned server (Manual on a server) is never moved;
/// - a route that still does not answer, `failAfter` checks in a row: `proxy` moves to the
///   first route by priority that answers (failover); a route above the current one comes
///   back by the same rule as a Priority server.
/// While the current route misses, checks come every `retryEvery` instead of `checkEvery`.
///
/// Pure Dart with no UI in it: the app reads [toJson] and listens to [switches]
/// (jormd serves both through /api/status; Flutter will call it directly).
library;

import 'dart:async';
import 'dart:math';

import 'config.dart' show defaultTestUrl;
import 'plan.dart';
import 'runtime.dart' show ClashApi;

class AutoSettings {
  const AutoSettings({
    this.failAfter = 2,
    this.threshold = 50,
    this.checkEvery = const Duration(minutes: 1),
    this.keepWarm = true,
    this.standby = 2,
    this.url = defaultTestUrl,
    this.timeoutMs = 5000,
    this.retryEvery = const Duration(seconds: 10),
    this.firstCheck = const Duration(seconds: 3),
  });

  /// From a plan: `auto` = {failAfter, threshold (ms), checkEvery (s), keepWarm, standby}
  /// (the UI's autoCfg), the test URL from `urlTest`.
  factory AutoSettings.fromPlan(Map<String, dynamic> plan) {
    final a = (plan['auto'] as Map?) ?? const {};
    final t = (plan['urlTest'] as Map?) ?? const {};
    int n(Object? v, int def) => v is num ? v.toInt() : def;
    final every = Duration(seconds: n(a['checkEvery'] ?? t['interval'], 60).clamp(10, 3600));
    const retry = Duration(seconds: 10);
    return AutoSettings(
      failAfter: n(a['failAfter'], 2).clamp(1, 10),
      threshold: n(a['threshold'] ?? t['tolerance'], 50).clamp(0, 10000),
      checkEvery: every,
      keepWarm: a['keepWarm'] != false,
      standby: n(a['standby'], 2).clamp(0, 10),
      url: (t['url'] as String?) ?? defaultTestUrl,
      retryEvery: every < retry ? every : retry,
    );
  }

  final int failAfter; // misses in a row before leaving a server / route
  final int threshold; // ms: how much slower a higher one may be and still come back
  final Duration checkEvery;
  final bool keepWarm; // test the standby routes on every check
  final int standby;
  final String url;
  final int timeoutMs;
  final Duration retryEvery; // while the current route misses
  final Duration firstCheck; // after start
}

/// What the checks know about one server or route.
class Health {
  int ms = -2; // last result: delay in ms, -1 = no answer, -2 = not tested yet
  int fails = 0; // misses in a row
  int oks = 0; // answers in a row
  int at = 0; // when, ms since epoch

  bool get answered => ms >= 0;

  void record(int delay, int now) {
    ms = delay;
    at = now;
    if (delay >= 0) {
      oks++;
      fails = 0;
    } else {
      fails++;
      oks = 0;
    }
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
  bool checked = false; // tested in the running check

  List<_Group> get groups => [?entry, main];
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

class AutoService {
  AutoService(this.api, Map<String, dynamic> plan, {AutoSettings? settings, int Function()? clock})
      : settings = settings ?? AutoSettings.fromPlan(plan),
        _clock = clock ?? _wallClock {
    final rs = planRoutes(plan);
    _routes = [for (var i = 0; i < rs.length; i++) _Route(i, rs[i])];
    index = planCurrent(plan, _routes.length);
  }

  final ClashApi api;
  final AutoSettings settings;
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

  /// The current route misses `failAfter` checks in a row and no other route answers.
  bool allDown = false;
  int? checkedAt;
  int? refreshedAt;

  final _switches = StreamController<AutoSwitch>.broadcast();
  Timer? _timer;
  bool _busy = false, _started = false, _stopped = false;

  /// Every move between routes and between Priority servers.
  Stream<AutoSwitch> get switches => _switches.stream;

  /// Checks on a timer from now on (the first one after `firstCheck`).
  void start() {
    _started = true;
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _switches.close();
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
      for (final r in _routes) {
        r.checked = false;
      }
      final todo = {
        index,
        for (var i = 0; i < index; i++) i,
        if (settings.keepWarm)
          for (var i = index + 1; i <= index + settings.standby && i < _routes.length; i++) i,
      };
      await Future.wait(todo.map((i) => _checkRoute(_routes[i])));
      if (_stopped) return;
      await _decide();
      checkedAt = _clock();
    } finally {
      _busy = false;
      final h = _routes[index].health;
      _schedule(h.fails > 0 && !allDown ? settings.retryEvery : settings.checkEvery);
    }
  }

  /// Reads which route and servers sing-box uses now (`now` of the groups in /proxies).
  /// False when the Clash API does not answer.
  Future<bool> refresh() async {
    final px = await api.clashGet('/proxies');
    final by = px?['proxies'];
    if (px == null || px['_status'] != 200 || by is! Map) return false;
    String? nowOf(String tag) {
      final n = (by[tag] as Map?)?['now'];
      return n is String && n.isNotEmpty ? n : null;
    }

    final i = _routes.indexWhere((r) => r.tag == nowOf(topTag));
    if (i >= 0) index = i;
    for (final r in _routes) {
      for (final g in r.groups) {
        g.now = g.keyOf(nowOf(g.tag)) ?? g.now;
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
      if (ms >= 0) return _priorityBack(r, g, key, ms);
      if (g.of(key).fails < settings.failAfter) return -1;
      final to = await _firstAnswering(g, [for (final k in g.keys) if (k != key) k]);
      return to != null && await _pick(r, g, to, 'failover') ? g.of(to).ms : -1;
    }
    return ms >= 0 ? ms : _heal(g, key);
  }

  Future<int> _test(_Group g, String key) async {
    final t = settings.timeoutMs;
    final r = await api.clashGet('/proxies/${Uri.encodeComponent(g.member(key))}/delay?timeout=$t&url=${Uri.encodeQueryComponent(settings.url)}',
        timeout: Duration(milliseconds: t + 2000));
    final ms = r != null && r['_status'] == 200 && r['delay'] is int ? r['delay'] as int : -1;
    if (!_stopped) g.of(key).record(ms, _clock());
    return ms;
  }

  // In order, 8 at a time: the first that answers.
  Future<String?> _firstAnswering(_Group g, List<String> keys) async {
    for (var i = 0; i < keys.length && !_stopped; i += 8) {
      final batch = keys.sublist(i, min(i + 8, keys.length));
      await Future.wait(batch.map((k) => _test(g, k)));
      for (final k in batch) {
        if (g.of(k).answered) return k;
      }
    }
    return null;
  }

  bool _mayReturn(Health h, int curMs) => h.oks >= settings.failAfter && (curMs < 0 || h.ms <= curMs + settings.threshold);

  // Priority: a server above the current one that is back takes over again.
  Future<int> _priorityBack(_Route r, _Group g, String cur, int curMs) async {
    final above = g.keys.takeWhile((k) => k != cur).toList();
    for (var i = 0; i < above.length && !_stopped; i += 8) {
      await Future.wait(above.sublist(i, min(i + 8, above.length)).map((k) => _test(g, k)));
    }
    for (final k in above) {
      if (_mayReturn(g.of(k), curMs) && await _pick(r, g, k, 'back')) return g.of(k).ms;
    }
    return curMs;
  }

  // Fastest: our failed test took the server's history away; urltest tests again (the
  // Clash API group delay) and picks again among the ones that answer.
  Future<int> _heal(_Group g, String failed) async {
    final t = settings.timeoutMs;
    final res = await api.clashGet('/group/${Uri.encodeComponent(g.tag)}/delay?timeout=$t&url=${Uri.encodeQueryComponent(settings.url)}',
        timeout: Duration(milliseconds: t + 20000));
    if (_stopped) return -1;
    final answered = <String, int>{};
    res?.forEach((tag, v) {
      final k = g.keyOf(tag);
      if (k != null && v is int) answered[k] = v;
    });
    final now = _clock();
    // the group test covers every server: the ones missing from the answer missed (the
    // failed one is counted once, by its own test just before)
    if (res != null) {
      for (final k in g.keys) {
        final v = answered[k];
        if (v != null || k != failed) g.of(k).record(v ?? -1, now);
      }
    }
    final px = await api.clashGet('/proxies/${Uri.encodeComponent(g.tag)}');
    g.now = g.keyOf(px?['now']) ?? g.now;
    if (g.current == failed) return -1;
    return answered[g.current] ?? await _test(g, g.current);
  }

  Future<bool> _pick(_Route r, _Group g, String key, String reason) async {
    if (_stopped || await api.clashPut('/proxies/${Uri.encodeComponent(g.tag)}', {'name': g.member(key)}) != 204) return false;
    final from = g.current;
    g.now = key;
    _emit(AutoSwitch(route: r.id, from: from, to: key, reason: reason, at: _clock()));
    return true;
  }

  Future<bool> _moveTo(int i, String reason) async {
    if (_stopped || await api.clashPut('/proxies/$topTag', {'name': _routes[i].tag}) != 204) return false;
    final from = _routes[index].id;
    index = i;
    _emit(AutoSwitch(from: from, to: _routes[i].id, reason: reason, at: _clock()));
    return true;
  }

  void _emit(AutoSwitch s) {
    switchCount++;
    switchedAt = s.at;
    lastSwitch = s;
    if (!_switches.isClosed) _switches.add(s);
  }

  Future<void> _decide() async {
    final cur = _routes[index];
    if (cur.health.fails >= settings.failAfter) {
      // failover: the first route by priority that answers; one not tested in this round
      // (keep warm off) is tested now, one at a time, until one answers
      for (var i = 0; i < _routes.length && !_stopped; i++) {
        final r = _routes[i];
        if (i == index) continue;
        if (!r.checked) await _checkRoute(r);
        if (r.health.answered && await _moveTo(i, 'failover')) {
          allDown = false;
          return;
        }
      }
      allDown = true;
      return;
    }
    allDown = false;
    for (var i = 0; i < index; i++) {
      if (_mayReturn(_routes[i].health, cur.health.ms) && await _moveTo(i, 'back')) return;
    }
  }

  /// For the app: `{now: route id, index, server, entryServer (chain), routes: [{id, ms,
  /// fails, oks, at}], members: [{key, ms, fails, oks, at}] (every server tested so far,
  /// not a chain's exits: those are measured through the entry), switches (count),
  /// switchedAt, lastSwitch ({route?, from, to, reason, at}; with `route` = a Priority
  /// server move inside that route, `from`/`to` are then server keys), allDown, checkedAt}`.
  Map<String, dynamic> toJson() {
    final cur = _routes[index];
    return {
      'now': cur.id,
      'index': index,
      'server': cur.main.now,
      'entryServer': cur.entry?.now,
      'routes': [
        for (final r in _routes) {'id': r.id, ...r.health.toJson()},
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
      'allDown': allDown,
      'checkedAt': checkedAt,
    };
  }
}
