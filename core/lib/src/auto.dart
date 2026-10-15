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
/// The current route's server is not tested when the user's own traffic proves it alive: since the last round
/// connections through it (not the core's own tests) got bytes back and no request through it failed. That round
/// counts as an answer with the last delay kept, and says so in the log ([_liveTraffic]). Without such traffic, with
/// a failed request, or with the route missing before, the test runs as always; the routes above and the spares
/// (no traffic goes through them) are tested as before.
///
/// A round in which no route answered strikes and marks no one: the misses of every route
/// but the current one are put back as they were.
///
/// A test is [delay] (see [_ping]): one round trip on an open connection through the
/// config's probe inbound (probe.dart), what the catalog shows. It goes through the probe
/// pool (pool.dart): an answer another module or the UI's ping got a moment ago
/// ([AutoSettings.reuse]; for a server not tested yet [AutoSettings.startAge]) stands for
/// the test, a miss never does, and the same server asked twice at once is tested once.
/// The network status the other modules judge by is kept in the pool: an OS without a
/// network, no route answering and the direct path silent too (`down`), the route in use
/// missing (`unknown`); any answer is `up`.
///
/// Pure Dart with no UI in it: the app reads [toJson] and listens to [switches] and
/// [unstable] (jormd serves them through /api/status; Flutter will call it directly).
library;

import 'dart:async';
import 'dart:math';

import 'auto_memory.dart';
import 'config.dart' show defaultTestUrl, planCheckers;
import 'exits.dart';
import 'failures.dart' show ConnOutcome;
import 'ladder.dart';
import 'plan.dart';
import 'pool.dart';
import 'probe.dart' show canProbeDest, probeInboundTag;
import 'sbapi.dart' show BoxControl, ClosedConnection;
import 'sentinel/model.dart' show Cancel;
import 'stall.dart';
import 'svc_in.dart' show svcInboundTag;

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
    this.siteAlternates = 3,
    this.ladderAhead = batchAhead,
  });

  /// From a plan: `auto` = {failAfter, threshold (ms), checkEvery (s), standby, warmEvery (s),
  /// retryPause (s, 0.1–10), returnTo ('always' | 'faster' | 'never'), flapGuard, flapMax
  /// (min, 1–60), flapReset (min, 5–60), siteRetry ('off' | '3' | 'all')} (the UI's autoCfg),
  /// the test URL from `urlTest`.
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
      siteAlternates: switch (a['siteRetry']) { 'off' => 0, 'all' => allSiteAlternates, _ => 3 },
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

  /// A round that has to ask some unavailable node (ladder.dart) asks the ones whose turn comes within this too.
  final Duration ladderAhead;

  /// How many of the other answering routes (in Auto's order) a failed site is tried through
  /// before it counts as unreachable: 0 = none, [allSiteAlternates] = every one.
  final int siteAlternates;
  static const allSiteAlternates = 1 << 20;

  /// How old a probe-pool answer (pool.dart) may be and still stand for a test of a server
  /// the module has results for: a third of a check interval, at most 20 s. Misses are never
  /// reused. For a server not tested yet by the module see [startAge].
  Duration get reuse => Duration(milliseconds: min(checkEvery.inMilliseconds ~/ 3, 20000));

  /// The same for a server the module has not tested yet (the first round after a
  /// connect starts from the UI's ping): 2 minutes.
  Duration get startAge => const Duration(minutes: 2);

  /// The pool answer age a test of a server with [h] accepts.
  Duration reuseFor(Health h) => h.ms == -2 ? startAge : reuse;

  /// How long after its last check an unfinished series of misses (below [failAfter]) of a server, route or target still
  /// counts as one with the next miss: two of the slower cadence (the round, the spares' [warmEvery]) — the same two
  /// intervals after which Auto takes «since the last look» as not known. Older ones are dropped when a service starts
  /// ([AutoMemory.dropStaleStreaks]).
  Duration get streakGap => (checkEvery > warmEvery ? checkEvery : warmEvery) * 2;

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

  /// A node known dead from before (the ladder, ladder.dart) that this service has not tested yet.
  void markDead(int misses, int when) {
    ms = -1;
    fails = misses;
    oks = 0;
    at = when;
    since = null;
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

  /// Everything it holds, for the file ([AutoMemory]); [loadStore] takes it back.
  Map<String, dynamic> toStore() => {'ms': ms, 'fails': fails, 'oks': oks, 'at': at, if (since != null) 'since': since};

  void loadStore(Map j) {
    int n(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    ms = n('ms', -2);
    fails = n('fails', 0);
    oks = n('oks', 0);
    at = n('at', 0);
    since = j['since'] is num ? (j['since'] as num).toInt() : null;
  }
}

/// A move the service made: between routes ([route] null, [from] / [to] = route ids), or
/// between the servers of a Priority group ([route] = its route's id, [from] / [to] =
/// server keys). [reason]: `failover` (the current one stopped answering), `back` (a
/// higher one that had missed answers again) or `preferred` (a higher one that never missed:
/// the group had started below it). Only moves of the route in use are emitted: a server move
/// inside a spare / higher route is a log note (`auto: standby …`), not a switch.
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

/// Requests to a site ([dest], `host:port`) got nothing back through [route]'s server [server] while the node
/// itself passes traffic: the Sentinel judges it (service.dart: one suspicion per destination, with the
/// connection failures of the same site) with the probes [AutoService.reachSame] / [AutoService.reachScout] /
/// [AutoService.reachElsewhere].
/// [tag] is the failed connection's own outbound (as the failure book records it; a test is aimed at the server
/// it resolves to, [AutoService.reachSame]); [rule] is the
/// rule sing-box matched for the failed request (its text, raw; '' = none, the final route), [process] the path
/// of the app that made it ('' = unknown), [pkg] its Android package: why the request went that way, and who
/// sent it. [firstSeen]: the first failed request of the window (ms).
class AutoSiteFail {
  const AutoSiteFail({required this.route, required this.server, required this.tag, required this.dest, required this.at, int? firstSeen, this.rule = '', this.process = '', this.pkg = ''})
      : firstSeen = firstSeen ?? at;
  final String route, server, tag, dest, rule, process, pkg;
  final int at, firstSeen;
  Map<String, dynamic> toJson() => {'route': route, 'server': server, 'tag': tag, 'dest': dest, 'rule': rule, 'process': process, 'pkg': pkg, 'firstSeen': firstSeen, 'at': at};
}

// A failed request: the server's outbound tag, the rule sing-box matched and the app's path.
typedef _Fail = ({String tag, String rule, String process, String pkg});

/// The network came or went: [kind] `lost` (no route answers) / `restored`, `offline` (the
/// OS has no network) / `online`; [downMs] on the second of each pair.
class AutoNet {
  const AutoNet({required this.kind, required this.at, this.downMs});
  final String kind;
  final int at;
  final int? downMs;
  Map<String, dynamic> toJson() => {'kind': kind, 'at': at, 'downMs': ?downMs};
}

/// Where a destination opens when the failing server cannot ([AutoService.reachScout] / [AutoService.reachElsewhere]):
/// [via] the route that opens it (and the server tried), else the working servers [tried] that did not. [unsure]: one
/// could not be tried, so [tried] alone proves nothing; [off]: the setting that allows the tries is off.
class AltReach {
  const AltReach({this.via, this.viaServer, this.tried = const [], this.unsure = false, this.off = false, this.subs = const []});
  final String? via, viaServer;
  final List<({String route, String server})> tried;
  final bool unsure, off;

  /// The subscriptions (source ids) the probes went through, for [AutoService.reachElsewhere] not to repeat them.
  final List<String> subs;

  /// How many routes of `siteRetry`'s allowance these probes used.
  int get probed => tried.length + (via == null ? 0 : 1);
}

/// A server of a route's main group that a site test can go through ([AutoService.workingNodes]): [route] its
/// entry's id, [server] its key (`<subscription id>::<node id>`), [tag] its outbound tag, [sub] the subscription
/// ('' = unknown), [country] the flag of its country ('' = unknown): the provider's flag from the plan, else the
/// country the last exit check through the node named ([AutoService.exits]). The choice below ([AutoService.reachScout])
/// reads nothing else.
class SiteNode {
  const SiteNode({required this.route, required this.server, required this.tag, required this.sub, this.country = ''});
  final String route, server, tag, sub, country;
}

class _Group {
  _Group(this.tag, Map g, {this.entry, this.memory, this.scope = ''})
      : priority = g['pick'] == 'priority',
        pinned = g['pinned'] == true,
        keys = {for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) '${n['key']}'}.toList() {
    if (priority && keys.contains(g['chosen'])) now = g['chosen'] as String;
    for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) {
      final o = n['outbound'];
      ids['${n['key']}'] = o is Map ? serverIdentity(o) : '$tag/${n['key']}'; // no outbound: nothing to share
      if (o is Map) real.add('${n['key']}');
      final flag = n['flag'];
      if (flag is String && flag.isNotEmpty && flag != '🌐') flags['${n['key']}'] = flag;
    }
  }

  final flags = <String, String>{}; // key → the flag of its country, where the plan knows one

  final String tag;
  final bool priority, pinned;
  final _Group? entry; // its servers dial through this group: a result is the whole chain's
  bool get pair => entry != null;
  final List<String> keys;
  final ids = <String, String>{}; // key → the server's pool identity (pool.dart)
  final real = <String>{}; // the keys whose identity is a fingerprint of an outbound (the same on the next start), not a tag

  /// Where what the checks learn outlives this service (auto_memory.dart), and the route + role (`<id>|m` / `<id>|e`)
  /// this group is in: the key of a server there is `<scope>|<pool identity>` (a chain's exit: the pair). A server without
  /// an outbound is not remembered.
  final AutoMemory? memory;
  final String scope;

  /// A server's health by [_hkey]: for a chain's exits it is the pair's (entry in use + exit). The objects are the
  /// memory's, so a service made anew starts from them.
  final health = <String, Health>{};
  String? now; // the server in use (key)
  final _missedHere = <String>{}; // the ones with no memory key

  String? _own(String key) => memory == null || !real.contains(key) ? null : '$scope|${ids[key]}';

  String? _memKey(String key) {
    final own = _own(key), e = entry;
    if (own == null || e == null) return own;
    return e.real.contains(e.current) ? '$scope|${pairIdentity(e.ids[e.current]!, ids[key]!)}' : null;
  }

  /// A server missed a test here: a move up to it later is a `back`. [at]: now, ms.
  void markMissed(String key, int at) {
    final m = _own(key);
    if (m == null) {
      _missedHere.add(key);
    } else {
      memory!.markMissed(m, at);
    }
  }

  /// Whether the server had missed here (and takes the mark off).
  bool takeMissed(String key) {
    final m = _own(key);
    return m == null ? _missedHere.remove(key) : memory!.takeMissed(m);
  }

  String get current => now ?? keys.first;
  String member(String key) => '$tag/$key';
  String? keyOf(Object? t) => t is String && t.startsWith('$tag/') ? t.substring(tag.length + 1) : null;

  /// A chain's exit is measured through the entry server in use, so its misses are that
  /// pair's: when the entry switches the exit starts a count of its own (the old pair keeps its).
  String _hkey(String key) => entry == null ? key : '${entry!.current}$_pairSep$key';
  Health of(String key) => health.putIfAbsent(_hkey(key), () {
        final m = _memKey(key);
        return m == null ? Health() : memory!.server(m);
      });
}

const _pairSep = '\n';

class _Route {
  _Route(int i, Map<String, dynamic> r, AutoMemory memory) : this._(i, r, memory, '${r['id'] ?? routeTag(i)}');

  _Route._(int i, Map<String, dynamic> r, AutoMemory memory, this.id)
      : tag = routeTag(i),
        mark = memory.route(id),
        entry = r['kind'] == 'chain' ? _Group(routeEntryTag(i), r['entry'] as Map, memory: memory, scope: '$id|e') : null {
    main = _Group(routeTag(i), r['main'] as Map, entry: entry, memory: memory, scope: '$id|m');
  }

  final String id, tag;
  final _Group? entry;
  late final _Group main;

  /// The route's health and flap guard are the memory's (auto_memory.dart): a service made anew goes on from them.
  final RouteMark mark;
  Health get health => mark.health;
  bool checked = false; // tested in the running round
  bool skipped = false; // … but its server is unavailable and was not asked (ladder.dart): it is not known to be dead right now
  bool get up => mark.up; // answered since its last strike: a drop from here is a strike
  set up(bool v) => mark.up = v;
  int get strikes => mark.strikes; // drops (flap guard)
  set strikes(int v) => mark.strikes = v;
  int inUseSince = 0; // when it became the current route

  List<_Group> get groups => [?entry, main];
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

/// ms through the outbound [tag] to [url]; -1 = no answer.
typedef DelayTest = Future<int> Function(String tag, String url, int timeoutMs);

class AutoService {
  AutoService(this.api, Map<String, dynamic> plan,
      {required this.delay,
      AutoSettings? settings,
      int Function()? clock,
      this.reach,
      this.note,
      this.trace,
      this.onDown,
      ProbePool? pool,
      ExitBook? exits,
      AutoMemory? memory,
      this.exitCheck,
      this.onExit})
      : settings = settings ?? AutoSettings.fromPlan(plan),
        memory = memory ?? AutoMemory(),
        pool = pool ?? ProbePool.solo(),
        exits = exits ?? ExitBook(),
        manual = plan['manual'] == true,
        _clock = clock ?? _wallClock {
    final rs = planRoutes(plan);
    _routes = [for (var i = 0; i < rs.length; i++) _Route(i, rs[i], this.memory)];
    index = planCurrent(plan, _routes.length);
    _routes[index].inUseSince = _clock();
    this.memory.dropStaleStreaks(_clock(), this.settings.streakGap, this.settings.failAfter);
    this.pool.ladder.owe(); // a new connection: each unavailable node is asked once out of turn (the ladder itself goes on)
  }

  final BoxControl api;
  final DelayTest delay;

  /// What the checks know of the servers and routes (health, flap guard, «already failed»), outside this service: the
  /// owner keeps one for the life of the core, so a service made anew (a connect, a restart) goes on from it
  /// (auto_memory.dart). Without one given the service has its own.
  final AutoMemory memory;

  /// The probe pool (pool.dart): every test of a server goes through it, so what the other
  /// modules or the UI's ping measured recently is not measured again, and the network
  /// status Auto knows of (the OS offline, no route answering, the route in use missing)
  /// goes into it for all of them. Without one given the service has its own, which reuses
  /// nothing.
  final ProbePool pool;

  /// Where each node leaves to, by the last exit check through it (exits.dart): the country of a node the provider
  /// gave no flag to ([SiteNode.country]), and `exit` of the node state ([toJson]). The controller fills it itself
  /// (the exit checks below, each pinned to the node it asks about); the owner keeps it across restarts.
  final ExitBook exits;

  /// The exit check through the outbound [tag] (probe.dart [probeGet] via the probe inbound: system traffic, the
  /// user's rules never apply, the answer is that node's by construction). null = Auto runs none.
  final Future<Map<String, dynamic>> Function(String tag)? exitCheck;

  /// An exit result arrived or the node in use changed: the status' exit ([exitInUse]) may differ.
  final void Function()? onExit;

  /// The least time between two background exit checks of one node (from the last completed check, kept with the
  /// [exits] entry): a switch to a node, the start and the scouts ask only when it has passed. The user's re-check
  /// ([recheckExit]) and an update of the node's subscription ([exitSourceRefreshed]) do not wait for it.
  static const exitEvery = Duration(minutes: 20);

  /// Whether a site (`host:port`) opens through an outbound tag (probe.dart probeReach);
  /// null = cannot be told. Without it the sites of failed requests are not tried again.
  final Future<bool?> Function(String tag, String dest)? reach;

  /// A line for the log (jormd: the Logs tab, as `[jormd] auto: …`).
  final void Function(String line)? note;

  /// A routine line for the log, one per round that skipped a test (info level in the core's book, not a warning:
  /// [note] is the runtime's `[jormd]` line, which the book keeps as one). null = [note].
  final void Function(String line)? trace;

  /// A server of a group missed `failAfter` tests in a row (and again with every further miss): the group's tag
  /// (`route0`, `route1-entry`) and the server's key. The owner decides what a dead server asks for (the core
  /// looks at its address, service.dart); Auto's own failover does not wait for it.
  final void Function(String groupTag, String key)? onDown;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;
  final int Function() _clock;
  late final List<_Route> _routes;

  /// The plan's routes (entry ids) in priority order.
  List<String> get routeIds => [for (final r in _routes) r.id];

  /// The route in use (index into the plan's routes).
  late int index;

  /// Manual (`plan.manual`): the plan holds every Auto route, but this one stays on the route in
  /// use — nothing is tested or moved between routes (servers inside the route still heal, a
  /// pinned one never moves). Switched live by [setManual]: no sing-box restart.
  bool manual;

  /// Auto ↔ Manual live ([manual]); in Manual [entry] (a route id) is the route to be on: the
  /// selector `proxy` goes there at once (the user's own pick, no switch event). False = [entry]
  /// is not a route of this plan (it needs a new plan, the host reconnects) or sing-box refused.
  /// Back in Auto a round runs at once: the routes above the current one are looked at again.
  /// With [closeOld] the connections of the main flow that went through the route left are
  /// closed after the move (Settings → Connection → Close connections on route switch); the
  /// rest (Direct, Block, a rule target's own group) and the tunnel stay.
  Future<bool> setManual(bool on, {String? entry, bool closeOld = false}) async {
    manual = on;
    var ok = true;
    final i = entry == null ? -1 : _routes.indexWhere((r) => r.id == entry);
    if (on && entry != null && i != index) {
      final old = _routes[index].tag;
      ok = i >= 0 && !_stopped && await api.select(topTag, _routes[i].tag);
      if (ok) {
        index = i;
        _routes[i].inUseSince = _clock();
        if (closeOld) await _closeOnRoute(old);
      }
    }
    if (!on) _kickNow();
    _syncExit();
    return ok;
  }

  /// Closes the connections whose chain went through the main flow ([topTag]) and the route
  /// [tag]; the ones that are moving no longer matter, the user asked for it.
  Future<void> _closeOnRoute(String tag) async {
    var n = 0;
    for (final c in [...api.connections]) {
      if (c.chain.contains(topTag) && c.chain.contains(tag) && await api.closeConnection(c.id)) n++;
    }
    if (n > 0) note?.call('auto: manual: closed $n connection${n == 1 ? '' : 's'} of the route left');
  }

  /// Moves so far (routes and Priority servers, as on [switches]); a Fastest group's own
  /// re-picks inside sing-box are not counted.
  int switchCount = 0;
  int? switchedAt;
  AutoSwitch? lastSwitch;

  /// Routes found unstable so far (as on [unstable]) and the last one: the memory's ([memory]), counted from the last
  /// change of the network.
  int get unstableCount => memory.unstableCount;
  AutoUnstable? get lastUnstable => memory.lastUnstable;

  /// The current route is dead and no other route answers (the next batch silent too):
  /// everything stays as it is, a round every `noNetEvery`. The memory's ([memory]): a service made anew starts with it,
  /// and only a round in which a route answered ends it (the network change makes it unknown, [networkChanged]).
  bool get noNet => memory.noNet;
  set noNet(bool v) => memory.noNet = v;

  /// The OS has no network (sing-box: `missing default interface`): like [noNet], nothing
  /// is tested, moved or marked until it is back.
  bool offline = false;

  /// Requests through the current route that could not open (see [onLog]) and the last.
  int requestFails = 0;
  Map<String, dynamic>? lastRequestFail;

  /// Sites that got nothing back through a node that passes traffic (as on [siteFails]) and the last.
  int siteFailCount = 0;
  AutoSiteFail? lastSiteFail;

  /// Connections closed as stalled on a route / server left for a dead one.
  int stalledClosed = 0;
  int? checkedAt;
  int _rounds = 0; // check rounds completed since the connect
  int? refreshedAt;

  final _switches = StreamController<AutoSwitch>.broadcast();
  final _unstable = StreamController<AutoUnstable>.broadcast();
  final _siteFails = StreamController<AutoSiteFail>.broadcast();
  final _net = StreamController<AutoNet>.broadcast();
  int? _offlineAt; // since when the OS has no network (the time no route answers is the memory's [AutoMemory.lostAt])
  Timer? _timer;
  StreamSubscription<void>? _groupsSub;
  late final _stall = StallSweeper(api);
  bool _busy = false, _started = false, _stopped = false;
  bool _kick = false; // a check is due at once when the running one ends
  bool _failCheck = false; // the running / next check was asked for by failed requests
  int? _failAt; // the first failed request of the current window
  final _failDests = <String, _Fail>{}; // sites that got nothing back → the server's outbound tag, the rule and the app of the request
  int? _warmedAt; // when the spares were tested last
  bool _directOk = false; // no route answers, but the direct path does (see _decide)
  Duration _ahead = Duration.zero; // the running round asks the unavailable nodes due within it too (ladder.dart)

  // Live traffic (see _liveTraffic): the bytes down each open connection of the user's had at the last look, what the
  // closed ones moved since (chain tag → connections, bytes), and whether a request of the user's through the current
  // route failed.
  var _downSeen = <String, int>{};
  final _closedLive = <String, ({int conns, int bytes})>{};
  int? _lookAt;
  bool _userFailed = false;

  /// Every move between routes and between Priority servers.
  Stream<AutoSwitch> get switches => _switches.stream;

  /// A route that keeps dropping (flap guard).
  Stream<AutoUnstable> get unstable => _unstable.stream;

  /// A site the requests to which got nothing back through the current node while it passes traffic. Auto only
  /// notices: the Sentinel decides what it is.
  Stream<AutoSiteFail> get siteFails => _siteFails.stream;

  /// No route answers, and answers again; the OS offline and back.
  Stream<AutoNet> get net => _net.stream;

  void _emitNet(String kind, int? since) {
    final now = _clock();
    if (!_net.isClosed) _net.add(AutoNet(kind: kind, at: now, downMs: since == null ? null : now - since));
  }

  /// The device moved to another network: the unavailable nodes (ladder.dart) are asked once out of turn,
  /// in a round now. The ladder itself goes on from the step each is on. The flap guard starts over (the strikes
  /// of a route say how it behaved on the old network); the answers and misses stay.
  void networkChanged() {
    if (_stopped) return;
    memory.resetFlap();
    memory.netUnknown(); // «no network» was found on the old one: unknown until the round below
    pool.ladder.owe();
    // (a node's exit does not depend on the user's network: no exit check starts here, only the hourly timer asks)
    if (_started) _kickNow();
  }

  /// Checks on a timer from now on (the first one after `firstCheck`).
  void start() {
    _started = true;
    // urltest re-picks on its own after its rounds: the groups stream tells at once
    _groupsSub = api.groupsChanged.listen((_) => refresh());
    _syncExit();
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    memory.changed(); // what it learned is written (the next service goes on from it)
    _timer?.cancel();
    _groupsSub?.cancel();
    _stall.stop();
    _switches.close();
    _unstable.close();
    _siteFails.close();
    _net.close();
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
      final ladderSaved = pool.ladder.snapshot();
      final failed = _userFailed;
      _userFailed = false;
      final traffic = _liveTraffic(); // taken every round: the next look counts from this one
      final retry = cur.health.fails > 0 && cur.health.fails < settings.failAfter;
      final todo = {index};
      if (!retry && !manual) {
        // the spares are due a little early rather than a whole check late
        final now = _clock();
        final warm = settings.standby > 0 && (_warmedAt == null || now - _warmedAt! >= settings.warmEvery.inMilliseconds - 1000);
        if (warm) _warmedAt = now;
        if (settings.returnTo != ReturnTo.never) todo.addAll([for (var i = 0; i < index; i++) i]);
        if (warm) todo.addAll([for (var i = index + 1; i <= index + settings.standby && i < _routes.length; i++) i]);
      }
      // the user's traffic through the current server proves it alive: no test of it this round (a failed request,
      // a failed check round or a server that missed before are not proven by it)
      final live = retry || failed || _failCheck ? null : _liveOn(cur, traffic);
      if (live != null) {
        todo.remove(index);
        _liveAnswer(cur, live);
      }
      _ahead = _ladderWakes(todo) ? settings.ladderAhead : Duration.zero;
      await Future.wait(todo.map((i) => _checkRoute(_routes[i])));
      if (_stopped) return;
      await _decide();
      if (_stopped) return;
      if (!_routes.any((r) => r.checked && r.health.answered)) {
        // no network (or not yet sure): nobody is marked by this round
        saved.forEach((h, s) => h._load(s));
        // the nodes of this round that missed are not dead either (the current route's own stay as they are)
        pool.ladder.restore(ladderSaved, keep: {for (final g in cur.groups) _identity(g, g.current)});
      } else {
        final since = memory.answered();
        _directOk = false;
        if (since != null) _emitNet('restored', since);
        _judge();
      }
      checkedAt = _clock();
      _rounds++;
      _scoutExits();
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
      _ahead = Duration.zero;
      final f = _routes[index].health.fails;
      // the route in use missing is a doubt about the network until something answers
      // (no route answering is one too, unless the direct path answers: the routes are at fault)
      if (!_stopped && !offline) pool.doubt(noNet ? !_directOk : f > 0);
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
      if (!offline) {
        note?.call('auto: the system has no network: nothing is tested or moved until it is back');
        _offlineAt = _clock();
        _emitNet('offline', null);
      }
      offline = true;
      pool.offline(true);
    } else if (line.contains('updated default interface') && offline) {
      offline = false;
      pool.offline(false);
      note?.call('auto: the system network is back: checking');
      _emitNet('online', _offlineAt);
      _offlineAt = null;
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
    if (_stopped || offline) return;
    if (!ConnOutcome.isFailure(c)) {
      _closedWithData(c);
      return;
    }
    if (c.chain.map(_routeOf).firstWhere((i) => i != null, orElse: () => null) != index) return;
    if (!_isOwn(c.inbound)) _userFailed = true;
    final now = _clock();
    requestFails++;
    lastRequestFail = {'route': _routes[index].id, 'dest': c.destination, 'sent': c.up, 'at': now};
    if (c.up > 0 && _failDests.length < 20) _failDests[c.destination] = (tag: c.outbound, rule: c.rule, process: c.process, pkg: c.pkg);
    if (_failAt != null && now - _failAt! < settings.failWindow.inMilliseconds) return;
    _failAt = now;
    _failDests.removeWhere((d, _) => d != c.destination);
    note?.call('auto: a request through ${_routes[index].id} got nothing back (${c.destination}): checking it now');
    _failCheck = true;
    _kickNow();
  }

  // The core's own tests and service requests (probe.dart, svc_in.dart) are not the user's traffic.
  static bool _isOwn(String inbound) => inbound == probeInboundTag || inbound == svcInboundTag;

  // A closed connection of the user's that got data back: what it moved since the last look is live traffic.
  void _closedWithData(ClosedConnection c) {
    if (_isOwn(c.inbound) || c.down <= 0) return;
    final grew = c.down - (_downSeen.remove(c.id) ?? 0);
    if (grew <= 0) return;
    for (final tag in c.chain) {
      final had = _closedLive[tag];
      _closedLive[tag] = (conns: (had?.conns ?? 0) + 1, bytes: (had?.bytes ?? 0) + grew);
    }
  }

  // What the user's connections got back since the last look, by the tags of their chains (the open ones by what
  // the connections table says now against the last look, the closed ones as [_closedWithData] kept). Nothing
  // when there was no look before or it is older than two check intervals: then "since the last check" is not known.
  Map<String, ({int conns, int bytes})> _liveTraffic() {
    final now = _clock();
    final known = _lookAt != null && now - _lookAt! <= settings.checkEvery.inMilliseconds * 2;
    final out = known ? Map.of(_closedLive) : <String, ({int conns, int bytes})>{};
    final seen = <String, int>{};
    for (final c in api.connections) {
      if (_isOwn(c.c.inbound)) continue;
      seen[c.id] = c.down;
      final grew = c.down - (_downSeen[c.id] ?? 0);
      if (!known || grew <= 0) continue;
      for (final tag in c.chain) {
        final had = out[tag];
        out[tag] = (conns: (had?.conns ?? 0) + 1, bytes: (had?.bytes ?? 0) + grew);
      }
    }
    _downSeen = seen;
    _closedLive.clear();
    _lookAt = now;
    return out;
  }

  // The traffic through [r]'s servers, when it is enough to count the route as answering: every group's server in
  // use answered its last test and did not miss since.
  ({int conns, int bytes})? _liveOn(_Route r, Map<String, ({int conns, int bytes})> traffic) {
    if (!r.health.answered || r.health.fails > 0) return null;
    for (final g in r.groups) {
      final h = g.of(g.current);
      if (!h.answered || h.fails > 0) return null;
    }
    return traffic[r.main.member(r.main.current)];
  }

  // The route in use counted as answering by live traffic: the numbers of its last test stay, the answer is now.
  void _liveAnswer(_Route r, ({int conns, int bytes}) live) {
    final now = _clock();
    for (final g in r.groups) {
      final h = g.of(g.current);
      h.record(h.ms, now);
    }
    r.skipped = false;
    r.health.record(r.health.ms, now);
    r.checked = true;
    (trace ?? note)?.call('auto: ${r.id} not tested this round: live traffic through ${r.main.member(r.main.current)} '
        '(${live.conns} connection${live.conns == 1 ? '' : 's'}, ${live.bytes} bytes down)');
  }

  // Whether the round has to ask some unavailable node of the routes it tests anyway (ladder.dart): then the ones due
  // soon are asked in the same go.
  bool _ladderWakes(Iterable<int> routes) {
    final ladder = pool.ladder, now = _clock();
    if (ladder.length == 0) return false;
    for (final i in routes) {
      if (i == index) continue;
      for (final g in _routes[i].groups) {
        for (final k in g.keys) {
          if (ladder.pending(_identity(g, k), now)) return true;
        }
      }
    }
    return false;
  }

  // The node passes traffic, yet requests through it got nothing back: each site they went to is
  // told to the Sentinel ([siteFails]) with the server it went through, unless a test cannot be aimed at it.
  // What it is (one-off, blocked on this node, down) is the Sentinel's to find out with [reachSame] /
  // [reachScout] / [reachElsewhere], together with the failures the connection book saw of the same site.
  Future<void> _sites(_Route cur) async {
    final dests = Map.of(_failDests);
    _failDests.clear();
    if (reach == null || dests.isEmpty) return;
    final first = _failAt;
    for (final MapEntry(key: dest, value: fail) in dests.entries) {
      if (_stopped) return;
      final tag = _serverTag(cur, fail.tag);
      if (tag == null || !canProbeDest(dest)) continue; // not a server / a site we can aim a test at: no evidence either way
      final f = AutoSiteFail(route: cur.id, server: cur.main.current, tag: fail.tag, dest: dest, at: _clock(), firstSeen: first, rule: fail.rule, process: fail.process, pkg: fail.pkg);
      siteFailCount++;
      lastSiteFail = f;
      note?.call('auto: $dest got nothing back through ${cur.id}');
      if (!_siteFails.isClosed) _siteFails.add(f);
    }
  }

  // A probe that gives up when [cancel] fires (null then: nothing was told; the request itself runs out by its timeout).
  Future<bool?> _reachCancellable(String tag, String dest, Cancel? cancel) {
    final r = reach!(tag, dest);
    return cancel == null ? r : Future.any<bool?>([r, cancel.done.then((_) => null)]);
  }

  /// Whether a test can be aimed at [dest] (`host:port`) through the server a failed connection went out of
  /// ([outbound]); what [reachSame] would try.
  bool canReachSame(String outbound, String dest) => reach != null && !_stopped && canProbeDest(dest) && _tagOf(outbound) != null;

  String? _tagOf(String outbound) {
    if (outbound == 'direct') return 'direct';
    for (final route in _routes) {
      final t = _serverTag(route, outbound);
      if (t != null) return t;
    }
    return null;
  }

  /// Whether [dest] (`host:port`) opens through the server a failed connection went out of ([outbound], a
  /// server of any route of the plan, or `direct`): true / false = the test really went through it; null =
  /// cannot be told (no probe, a port other than 443 / 80, not a server a test can aim at, [cancel] fired).
  Future<bool?> reachSame(String outbound, String dest, {Cancel? cancel}) async {
    if (reach == null || _stopped) return null;
    final tag = _tagOf(outbound);
    return tag == null ? null : _reachCancellable(tag, dest, cancel);
  }

  /// How long an answer of the probe pool (the UI's ping, another module's test) counts as «works now» for a
  /// server Auto has not tested itself.
  static const workingAge = Duration(minutes: 10);

  /// The servers of every route's main group that work now, in Auto's order (route, then the group's order): the last
  /// test of Auto answered and nothing missed since, or the pool has an answer not older than [workingAge]; never one
  /// on the dead ladder (ladder.dart). Manual lists none (it uses no other route). The controller's answer to «give me
  /// a working node» for the Sentinel's site checks.
  List<SiteNode> workingNodes() {
    if (manual || _stopped) return const [];
    final now = _clock(), out = <SiteNode>[];
    for (final r in _routes) {
      final g = r.main;
      for (final k in g.keys) {
        final id = _identity(g, k), h = g.of(k);
        if (pool.ladder.has(id)) continue;
        final p = pool.peek(id, url: settings.url, checkers: settings.checkers);
        final seen = h.answered && h.fails == 0 || p != null && p.answered && now - p.at <= workingAge.inMilliseconds;
        if (!seen || h.fails > 0) continue;
        out.add(SiteNode(route: r.id, server: k, tag: g.member(k), sub: _subOf(k), country: _countryOf(g, k)));
      }
    }
    return out;
  }

  /// The flag of a server's country: the provider's (the plan's `flag`), else the country the last exit check through
  /// it named; '' = unknown.
  String _countryOf(_Group g, String key) {
    final flag = g.flags[key];
    if (flag != null) return flag;
    return g.real.contains(key) ? flagOfCountry(exits.countryOf(g.ids[key]!)) : '';
  }

  // ── exit checks (docs/core.md → Проверка выхода) ──
  // The controller asks where a node leaves to, pinned to the node's own outbound (the probe inbound), so the answer is
  // the node's by construction. A running check is never cancelled by a switch: it ends and is recorded for its node;
  // the node now in use gets its own, in parallel. Background checks run at most once per [exitEvery] per node.

  final _exitResults = <String, Map<String, dynamic>>{}; // subject key → the latest answer ({ip, …} or {error})
  final _exitRunning = <String, int>{}; // subject key → the newest running check (its number)
  final _exitStored = <String, int>{}; // subject key → the number of the check whose answer is kept
  final _exitDoneAt = <String, int>{}; // subject key → when its last check answered (the ones with no [exits] entry)
  final _exitFailAt = <String, int>{}; // subject key → when its last check failed (a scout is not asked again within [exitEvery])
  final _exitLoud = <int>{}; // numbers of the checks the user asked for: a failure is shown, the answer is waited for
  final _exitRechecking = <String>{}; // keys whose status shows the kept answer as `rechecking` until the user's check answers
  final _exitError = <String, String>{}; // key → the user's check failed while an answer is kept: shown next to it
  String? _exitCur; // the key of the node in use at the last look
  int _exitSeq = 0;

  /// The node in use as an exit check sees it: [tag] its outbound (route's main group member), [id] its [exits] key
  /// (null = not a shareable node), [key] what the results are kept by. null = not known yet (a Fastest group before
  /// urltest picked).
  ({String key, String tag, String? id})? _exitSubject() {
    final g = _routes[index].main, k = g.now;
    if (k == null || !g.keys.contains(k)) return null;
    final id = g.real.contains(k) ? g.ids[k] : null;
    final tag = g.member(k);
    return (key: id ?? tag, tag: tag, id: id);
  }

  /// The latest exit answer of the node in use, as the status shows it (`direct: false`, `at`); `{error}` when
  /// the check failed. A node answered before (this run, or an earlier one: its [exits] entry) shows that answer at once,
  /// the check for it runs in the background; null = nothing known yet (being checked, or the node is not known yet).
  /// Any check of the node in use (the user's, a switch, the hourly one) keeps the answer on and adds `rechecking: true`
  /// until it answers; a failed check puts `error` (the message) next to the kept answer, and the app shows the error.
  Map<String, dynamic>? exitInUse() {
    final s = _exitSubject();
    if (s == null) return null;
    var out = _exitResults[s.key] ?? _exitKnown(s.id);
    final err = _exitError[s.key];
    if (err != null && out != null && out['ip'] is String) out = {...out, 'error': err};
    if (out != null && (_exitRechecking.contains(s.key) || _exitRunning.containsKey(s.key))) out = {...out, 'rechecking': true};
    return out;
  }

  /// What the [exits] book holds for [id] as a status answer; null = nothing.
  Map<String, dynamic>? _exitKnown(String? id) {
    final e = id == null ? null : exits[id];
    return e == null ? null : {'ip': e.ip, if (e.country.isNotEmpty) 'country': e.country, 'direct': false, 'at': e.at};
  }

  /// The answer shown for a node now (not an error): this run's latest, else the book's.
  Map<String, dynamic>? _exitShown(String key, String? id) {
    final r = _exitResults[key];
    return r != null && r['ip'] is String ? r : _exitKnown(id);
  }

  /// Whether a background check of a node may start: none yet, or the last completed one is [exitEvery] old.
  /// [failed]: a failed check counts too (the scouts do not ask a node that does not answer again at once).
  bool _exitDue(String key, String? id, {bool failed = false}) {
    int? last = id == null ? null : exits[id]?.at;
    for (final t in [_exitDoneAt[key], if (failed) _exitFailAt[key]]) {
      if (t != null && (last == null || t > last)) last = t;
    }
    return last == null || _clock() - last >= exitEvery.inMilliseconds;
  }

  /// Asks again where the node in use leaves to (the user's request): the timer does not apply; the status shows
  /// the answer known stays shown with `rechecking` until the new one. A check already running for it answers; none runs, a new one does.
  void recheckExit() {
    final s = _exitSubject();
    if (s == null) return;
    _exitCur = s.key;
    _startExit(s, loud: true);
  }

  /// A subscription ([sid]) was updated: its nodes are asked regardless of the timer, the one in use at once, the
  /// scouts (below) when their turn comes. The mark lives in the [exits] book (the owner sets it also while no
  /// controller runs); the check that starts takes it off, the timer moves to that check.
  void exitSourceRefreshed(String sid) {
    if (_stopped || exitCheck == null) return;
    for (final r in _routes) {
      final g = r.main;
      for (final k in g.real) {
        if (g.keys.contains(k) && _subOf(k) == sid) exits.markRefresh(g.ids[k]!);
      }
    }
    final s = _exitSubject();
    final now = _routes[index].main.now;
    if (s != null && _started && s.id != null && now != null && _subOf(now) == sid) {
      exits.takeRefresh(s.id!);
      _exitCur = s.key;
      _startExit(s, again: true);
    }
  }

  // The node in use changed (a switch, a pick of the groups, the start): it gets its check when the timer allows
  // (or its subscription was updated); else the status shows what is known of it.
  void _syncExit() {
    if (_stopped || exitCheck == null) return;
    final s = _exitSubject();
    if (s == null || s.key == _exitCur) return;
    _exitCur = s.key;
    final forced = s.id != null && exits.takeRefresh(s.id!);
    if (forced || _exitDue(s.key, s.id)) {
      _startExit(s, again: forced);
    } else {
      onExit?.call();
    }
  }

  // [again]: a check runs for it already, but not a fresh one (its subscription was updated): both go on.
  // [loud]: the user asked: the known answer shows `rechecking` until it answers, a failure is shown next to it.
  void _startExit(({String key, String tag, String? id}) s, {bool again = false, bool loud = false}) {
    if (_stopped || exitCheck == null) return;
    final running = _exitRunning[s.key];
    if (!again && running != null) {
      if (loud) {
        _exitLoud.add(running);
        if (_exitRechecking.add(s.key)) onExit?.call();
      }
      return;
    }
    final n = ++_exitSeq;
    _exitRunning[s.key] = n;
    if (loud) _exitLoud.add(n);
    _exitError.remove(s.key);
    if (_exitCur == s.key) {
      if (loud) _exitRechecking.add(s.key);
      if (_exitResults[s.key]?.containsKey('error') == true) _exitResults.remove(s.key); // a stale error is not shown while it is asked again
      onExit?.call();
    }
    unawaited(_runExit(s, n));
  }

  Future<void> _runExit(({String key, String tag, String? id}) s, int n) async {
    final since = Stopwatch()..start();
    Map<String, dynamic> out;
    var ok = false;
    for (;;) {
      final sw = Stopwatch()..start();
      try {
        final e = await exitCheck!(s.tag);
        out = {...e, 'direct': false, 'at': _clock()};
        ok = true;
        break;
      } catch (e) {
        // every service failing at once, fast, means the tunnel is not carrying yet (a urltest group still on an untested
        // dead server right after the connect): ask again in a couple of seconds, for up to 15 s, while the node is in use
        if (!_stopped && _exitCur == s.key && sw.elapsed < const Duration(seconds: 3) && since.elapsed < const Duration(seconds: 15)) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!_stopped && _exitRunning[s.key] == n && _exitCur == s.key) continue; // the node left meanwhile: the error stands
        }
        out = {'error': '$e', 'direct': false};
        break;
      }
    }
    if (_exitRunning[s.key] == n) _exitRunning.remove(s.key);
    final loud = _exitLoud.remove(n);
    if (n > (_exitStored[s.key] ?? 0)) {
      final at = _clock();
      if (ok) {
        _exitStored[s.key] = n;
        _exitDoneAt[s.key] = at;
        _exitError.remove(s.key);
        // the same IP (and country, when the check named one) as shown: only the time moves; another one replaces the answer
        final before = _exitShown(s.key, s.id), ip = out['ip'];
        final c = '${out['country'] ?? ''}'.trim().toUpperCase();
        final same = before != null && before['ip'] == ip && (c.isEmpty || before['country'] == c);
        if (s.id != null && ip is String) exits.record(s.id!, ip: ip, country: out['country'] as String?, at: out['at'] as int);
        _exitResults[s.key] = same ? {...before, 'at': out['at']} : out;
      } else {
        _exitFailAt[s.key] = at;
        // any failed check is shown (the user's decision 2026-10-14: the error, not the stored answer); the stored answer
        // stays in the book and comes back with the next good check
        _exitStored[s.key] = n;
        if (_exitShown(s.key, s.id) != null) {
          _exitError[s.key] = '${out['error']}';
        } else {
          _exitResults[s.key] = out;
        }
        if (_exitCur != s.key) trace?.call('auto: exit check through ${s.tag} failed: ${out['error']}');
      }
    }
    if (loud) _exitRechecking.remove(s.key);
    if (!_stopped) onExit?.call();
  }

  // The nodes that work now and have no country (the provider gave no flag, no check named one) are asked, each at most
  // once per [exitEvery] (a failed ask counts), up to [_scoutExitsPerRound] a round: the scout of a failed site ranks by
  // country ([scoutFor]). A node of an updated subscription ([exitSourceRefreshed]) is asked regardless.
  static const _scoutExitsPerRound = 3;

  void _scoutExits() {
    if (_stopped || manual || exitCheck == null) return;
    var left = _scoutExitsPerRound;
    for (final n in workingNodes()) {
      if (left == 0) return;
      if (n.country.isNotEmpty) continue;
      final g = _routes.firstWhere((r) => r.id == n.route).main;
      if (!g.real.contains(n.server)) continue;
      final id = g.ids[n.server]!;
      if (_exitRunning.containsKey(id)) continue;
      final forced = exits.takeRefresh(id);
      if (!forced && !_exitDue(id, id, failed: true)) continue;
      left--;
      _startExit((key: id, tag: n.tag, id: id));
    }
  }

  static String _subOf(String key) {
    final at = key.indexOf('::');
    return at < 0 ? '' : key.substring(0, at);
  }

  /// The route (entry id) a connection's [outbound] belongs to (a server of its groups, or its main group's own
  /// tag); null = not a route's outbound (`direct`, unknown). The one identity of a route for whoever reports a
  /// failure: Auto names it by the entry id, the connection book by the tag prefix (`route0`).
  String? routeIdOf(String outbound) {
    for (final r in _routes) {
      if (_serverTag(r, outbound) != null) return r.id;
    }
    return null;
  }

  /// The node a failed connection went out of ([outbound]); null = not a server of a route's main group.
  SiteNode? nodeOf(String outbound) {
    for (final r in _routes) {
      final tag = _serverTag(r, outbound), k = tag == null ? null : r.main.keyOf(tag);
      if (k != null && r.main.keys.contains(k)) return SiteNode(route: r.id, server: k, tag: tag!, sub: _subOf(k), country: _countryOf(r.main, k));
    }
    return null;
  }

  /// The one working node a failed site is tried through first (the user's step 2): of the same subscription as the
  /// server it failed through and of another country; else of the same subscription; else of another country; else
  /// any. Never the failing server itself. null = none works.
  SiteNode? scoutFor(String outbound, {bool Function(SiteNode)? skip}) {
    final from = nodeOf(outbound);
    int rank(SiteNode n) {
      final sameSub = from != null && n.sub.isNotEmpty && n.sub == from.sub;
      final other = n.country.isNotEmpty && n.country != from?.country;
      return sameSub && other ? 0 : sameSub ? 1 : other ? 2 : 3;
    }

    SiteNode? best;
    for (final n in workingNodes()) {
      if (n.tag == from?.tag || n.tag == outbound || skip != null && skip(n)) continue;
      if (best == null || rank(n) < rank(best)) best = n;
    }
    return best;
  }

  /// The working nodes of the subscriptions other than the failing server's and [exceptSubs], one per subscription (in
  /// Auto's order, one of another country first), at most [limit].
  List<SiteNode> elsewhere(String outbound, {Set<String> exceptSubs = const {}, int limit = 1 << 20}) {
    final from = nodeOf(outbound);
    final skip = {?from?.sub, ...exceptSubs};
    final bySub = <String, SiteNode>{};
    for (final n in workingNodes()) {
      if (n.tag == outbound || skip.contains(n.sub)) continue;
      final had = bySub[n.sub];
      if (had == null || (had.country.isEmpty || had.country == from?.country) && n.country.isNotEmpty && n.country != from?.country) bySub[n.sub] = n;
    }
    return bySub.values.take(limit).toList();
  }

  /// Step 2 of the site checks: [dest] through the [scoutFor] node. One of `siteRetry`'s allowance; Off (and Manual)
  /// probe nothing ([AltReach.off]).
  Future<AltReach> reachScout(String outbound, String dest, {Cancel? cancel}) async {
    final off = settings.siteAlternates == 0;
    if (reach == null || _stopped) return AltReach(off: off, unsure: true);
    if (off || manual) return AltReach(off: off);
    final n = scoutFor(outbound);
    if (n == null) return const AltReach();
    final r = await _tryNodes([n], dest, cancel);
    return AltReach(via: r.via?.route, viaServer: r.via?.server, tried: r.tried, unsure: r.unsure, subs: [n.sub]);
  }

  /// Step 3: [dest] through the working nodes of the other subscriptions ([elsewhere]), up to the first that opens it,
  /// as many as `siteRetry` allows after the [scout]'s probes; stops between them when [cancel] fires.
  Future<AltReach> reachElsewhere(String outbound, String dest, {AltReach? scout, Cancel? cancel}) async {
    final off = settings.siteAlternates == 0;
    if (reach == null || _stopped) return AltReach(off: off, unsure: true);
    if (off || manual) return AltReach(off: off);
    final left = settings.siteAlternates - (scout?.probed ?? 0);
    if (left <= 0) return const AltReach();
    final nodes = elsewhere(outbound, exceptSubs: {...?scout?.subs}, limit: left);
    final r = await _tryNodes(nodes, dest, cancel);
    return AltReach(via: r.via?.route, viaServer: r.via?.server, tried: r.tried, unsure: r.unsure, subs: [for (final n in nodes) n.sub]);
  }

  Future<({SiteNode? via, List<({String route, String server})> tried, bool unsure})> _tryNodes(List<SiteNode> nodes, String dest, Cancel? cancel) async {
    SiteNode? via;
    var unsure = false;
    final tried = <({String route, String server})>[];
    for (final n in nodes) {
      if (_stopped) break;
      if (cancel?.cancelled == true) {
        unsure = true;
        break;
      }
      final there = await _reachCancellable(n.tag, dest, cancel);
      if (there == true) {
        via = n;
        break;
      }
      if (there == false && cancel?.cancelled != true) {
        tried.add((route: n.route, server: n.server));
      } else {
        unsure = true;
      }
    }
    return (via: via, tried: tried, unsure: unsure);
  }

  // The server tag a site test can go through for a failed connection's outbound [tag]: a
  // server of the route's groups as is; the route's main group itself (its connection's
  // outbound while a urltest has not finished its first round — sing-box tells no member
  // yet) = the member in use, when known. Anything else (the entry group, a stranger):
  // null — the probe inbound has no user for a group, the test would never run.
  String? _serverTag(_Route r, String tag) {
    for (final g in r.groups) {
      final k = g.keyOf(tag);
      if (k != null && g.keys.contains(k)) return tag;
    }
    final now = r.main.now;
    return tag == r.main.tag && now != null && r.main.keys.contains(now) ? r.main.member(now) : null;
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
    _syncExit();
    return true;
  }

  // [force]: the nodes of the route that are unavailable (ladder.dart) are asked now, whatever their step: Auto
  // looks for a route that answers.
  Future<void> _checkRoute(_Route r, {bool force = false}) async {
    var ms = -1;
    r.skipped = false;
    for (final g in r.groups) {
      ms = await _checkGroup(r, g, force: force);
      if (ms < 0) break;
    }
    if (_stopped) return;
    final failing = r.health.fails > 0;
    r.health.record(ms, _clock());
    if (ms < 0 || failing) memory.changed();
    r.checked = true;
  }

  // The server the group uses now; when it misses, the group heals by its kind. The server of the route in
  // use is always tested in full; one of another route that is unavailable (ladder.dart) only on its turn.
  Future<int> _checkGroup(_Route r, _Group g, {bool force = false}) async {
    final key = g.current;
    final inUse = identical(r, _routes[index]);
    final ms = await _test(g, key, inUse: inUse, force: force);
    if (ms == _skipped) r.skipped = true;
    if (g.pinned) return ms == _skipped ? -1 : ms;
    if (g.priority) {
      if (ms >= 0) return settings.returnTo == ReturnTo.never ? ms : _priorityBack(r, g, key, ms);
      if (g.of(key).fails < settings.failAfter) return -1;
      final to = await _firstAnswering(g, [for (final k in g.keys) if (k != key) k], force: force);
      if (to == null || !await _pick(r, g, to, 'failover')) return -1;
      _closeStalled(g.member(key), () => g.current != key);
      return g.of(to).ms;
    }
    if (ms == _skipped) return -1; // sing-box's own tests watch a Fastest group; a group test for a node known dead is not worth it
    return ms >= 0 ? ms : _heal(g, key, inUse);
  }

  /// The pool identity of a server (pool.dart): its outbound's fingerprint; a chain's exit is
  /// measured through the entry server in use, so it is that pair's.
  String _identity(_Group g, String key) {
    final own = g.ids[key]!, e = g.entry;
    return e == null ? own : pairIdentity(e.ids[e.current]!, own);
  }

  /// The pool identity of a member / group outbound tag of a route (`route0/key`), for the
  /// other modules that test the same servers (fallback.dart's main flow); null = not ours.
  String? identityOf(String tag) {
    for (final r in _routes) {
      for (final g in r.groups) {
        final k = g.keyOf(tag);
        if (k != null && g.ids.containsKey(k)) return _identity(g, k);
      }
    }
    return null;
  }

  /// The pool identity of the exit server the main flow leaves through now (the main group's node in use; null = not
  /// known yet): what the DNS verdicts of the VPN side are bound to (dns_verdicts.dart). Read-only.
  String? exitNodeIdentity() {
    final g = _routes[index].main, k = g.now;
    return k == null ? null : g.ids[k];
  }

  /// The key (`<subscription>::<node>`) of the main group's node in use; null = not known yet. Read-only.
  String? exitNodeKey() => _routes.isEmpty ? null : _routes[index].main.now;

  /// Whether the node in use carries traffic at all: a fresh test of it (the test URL, then the backup checks; the
  /// answer joins the pool). null = not known (no node in use, Manual's own flow, stopped).
  Future<bool?> exitAlive() async {
    if (_stopped || _routes.isEmpty) return null;
    final g = _routes[index].main, k = g.now;
    if (k == null) return null;
    final ms = await pool.probe(_identity(g, k), (url) => _pingUrl(g.member(k), url), url: settings.url, checkers: settings.checkers);
    return _stopped ? null : ms >= 0;
  }

  /// A node that works now and is not the one in use (nor the entry of its chain): the working node another DNS check
  /// is asked through, ranked like the site checks' scout ([scoutFor]: the same subscription and another country first).
  /// null = none (Manual lists none).
  SiteNode? spareNode() {
    if (_routes.isEmpty) return null;
    final r = _routes[index], k = r.main.now, used = nodesInUse();
    return scoutFor(k == null ? '' : r.main.member(k), skip: (n) => used.contains(_routes.firstWhere((x) => x.id == n.route).main.ids[n.server]));
  }

  /// The pool identities of the servers the main flow leaves through now: the main group's node in use and, for a chain,
  /// the entry's one (it is dialled by its own name). Read-only.
  Set<String> nodesInUse() {
    if (_routes.isEmpty) return const {};
    final r = _routes[index];
    return {
      for (final g in [r.main, r.entry])
        if (g != null && g.now != null && g.ids[g.now] != null) g.ids[g.now]!,
    };
  }

  /// The one test of a server: ms through the group member [key], -1 = no answer. The
  /// test URL, then the backup checks at once (withCheckers): it passes traffic when any
  /// answers. Through the pool: a fresh enough answer of the same server is the result.
  /// [light]: the test URL alone, no backup checks (a node on the ladder, ladder.dart).
  Future<int> _ping(_Group g, String key, {bool light = false}) => pool.probe(_identity(g, key), (url) => _pingUrl(g.member(key), url),
      url: settings.url, checkers: light ? const [] : settings.checkers, maxAge: settings.reuseFor(g.of(key)));

  Future<int> _pingUrl(String tag, String url) => delay(tag, url, settings.timeoutMs);

  /// What [_test] returns for a server it did not test (unavailable, not its turn).
  static const _skipped = -3;

  // A server that missed `failAfter` times in a row and is not the one in use is unavailable (ladder.dart):
  // the log hears of it once, not with each miss.
  void _park(_Group g, String key, String id, [int? since]) {
    final steps = pool.ladder.steps;
    if (pool.ladder.enter(id, since ?? _clock())) {
      note?.call('auto: ${g.member(key)} is unavailable (${settings.failAfter} misses in a row): '
          'asked again after ${steps.map((d) => d.inMinutes).join(', ')} min, then every ${steps.last.inMinutes} min, by one light request');
    }
  }

  /// One test of a server. [inUse]: the route in use (its server is tested in full, never put on the ladder
  /// while it is the one in use); [force]: an unavailable server is asked now. An unavailable server whose turn
  /// has not come is not tested: [_skipped].
  Future<int> _test(_Group g, String key, {bool inUse = false, bool force = false}) async {
    final id = _identity(g, key), h = g.of(key), ladder = pool.ladder;
    var light = false;
    if (!inUse) {
      if (h.fails >= settings.failAfter) _park(g, key, id, h.at); // found dead earlier (its steps count from then), left only now
      switch (ladder.gate(id, _clock(), force: force, ahead: _ahead)) {
        case LadderGate.skip:
          // unavailable from an earlier connection: this service has not tested it, but knows it is dead
          if (h.fails < settings.failAfter) h.markDead(settings.failAfter, ladder[id]!.lastAt);
          return _skipped;
        case LadderGate.light:
          light = true;
        case LadderGate.free:
          break;
      }
    }
    final ms = await _ping(g, key, light: light);
    if (!_stopped) {
      final failing = h.fails > 0;
      h.record(ms, _clock());
      if (ms < 0 || failing) memory.changed();
      final back = ladder.observe(id, ms, _clock());
      if (ms >= 0) {
        if (back) note?.call('auto: ${g.member(key)} is back');
      } else {
        g.markMissed(key, _clock());
        if (h.fails >= settings.failAfter) {
          if (!inUse) _park(g, key, id);
          if (onDown != null) onDown!(g.tag, key);
        }
      }
    }
    return ms;
  }

  // In order, a batch at a time: the first that answers.
  Future<String?> _firstAnswering(_Group g, List<String> keys, {bool force = false}) async {
    final b = settings.batch;
    for (var i = 0; i < keys.length && !_stopped; i += b) {
      final batch = keys.sublist(i, min(i + b, keys.length));
      await Future.wait(batch.map((k) => _test(g, k, force: force)));
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
  Future<int> _heal(_Group g, String failed, bool inUse) async {
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
        final ms = res[g.member(k)] ?? -1;
        g.of(k).record(ms, now);
        if (ms < 0) memory.changed();
        if (ms >= 0) pool.ladder.observe(_identity(g, k), ms, now); // answered the group test: no longer unavailable
        if (ms < 0 && onDown != null && g.of(k).fails >= settings.failAfter) onDown!(g.tag, k);
      }
    }
    await refresh();
    if (g.current == failed) return -1;
    _closeStalled(g.member(failed), () => g.current != failed);
    return _test(g, g.current, inUse: inUse, force: true); // sing-box picked it: asked now whatever its step
  }

  Future<bool> _pick(_Route r, _Group g, String key, String reason) async {
    // `from` before the await: sing-box's groups stream can call refresh() meanwhile
    final from = g.current;
    if (_stopped || !await api.select(g.tag, g.member(key))) return false;
    g.now = key;
    // `back` = it failed here before; a higher server that never missed was just not the
    // one the plan started on (nothing "came back")
    if (reason == 'back') {
      if (!g.takeMissed(key)) reason = 'preferred';
    }
    // a route traffic does not use (a spare, one above): housekeeping, not a switch the
    // user sees — a log note only (judged after the await: `index` may have moved)
    if (!identical(r, _routes[index])) {
      note?.call('auto: standby ${r.id}: server $from → $key ($reason)');
      return true;
    }
    // the first rounds after the connect (the earliest a higher server has answered failAfter
    // times) putting the group on its preferred server: not news
    if (reason == 'preferred' && _rounds < settings.failAfter) {
      note?.call('auto: ${r.id}: server $from → $key ($reason, right after the connect)');
      return true;
    }
    _emit(AutoSwitch(route: r.id, from: from, to: key, reason: reason, at: _clock()));
    return true;
  }

  Future<bool> _moveTo(int i, String reason) async {
    final from = _routes[index].id; // before the await: refresh() may move `index` meanwhile
    if (_stopped || !await api.select(topTag, _routes[i].tag)) return false;
    index = i;
    _routes[i].inUseSince = _clock();
    _emit(AutoSwitch(from: from, to: _routes[i].id, reason: reason, at: _clock()));
    return true;
  }

  void _emit(AutoSwitch s) {
    switchCount++;
    switchedAt = s.at;
    lastSwitch = s;
    _syncExit(); // the node in use changed: it gets its own exit check
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
      // (Manual: no other route is looked at.) A route skipped for its unavailable server is not known to be dead:
      // now it is asked whatever its step (ladder.dart), by one light request.
      bool untested(int i) => !manual && i != index && (!_routes[i].checked || _routes[i].skipped);
      final first = [for (var i = 0; i < _routes.length; i++) if (untested(i) && (i < index || i <= index + settings.standby)) i];
      await Future.wait(first.map((i) => _checkRoute(_routes[i], force: true)));
      var to = _firstAnswered();
      // the rest by priority, a batch at a time, until one answers; once in no network,
      // only the first batch (the whole list again every noNetEvery would be a waste)
      final rest = [for (var i = 0; i < _routes.length; i++) if (untested(i)) i];
      final upTo = noNet ? min(settings.batch, rest.length) : rest.length;
      for (var b = 0; to == null && b < upTo && !_stopped; b += settings.batch) {
        await Future.wait(rest.sublist(b, min(b + settings.batch, upTo)).map((i) => _checkRoute(_routes[i], force: true)));
        to = _firstAnswered();
      }
      if (_stopped) return;
      if (to == null) {
        noNet = true; // no route answers: no network, not this route
        if (memory.lostAt == null) {
          memory.lostAt = _clock();
          note?.call('auto: no route answers: nothing is moved until one does');
          _emitNet('lost', null);
        }
        // down for the others only when the direct path is silent too (an answer there is `up`:
        // the network is fine, the routes are not); the direct path that cannot be tested
        // proves nothing: a doubt (`unknown`), not `down`
        final direct = await pool.directAnswers(url: settings.url, checkers: settings.checkers, timeoutMs: settings.timeoutMs);
        _directOk = direct == true;
        if (!_stopped && direct == false) pool.silent(true);
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
        if (!r.up) memory.changed();
        r.up = true;
      } else if (r.up && r.health.fails >= settings.failAfter && _routes.any((o) => o != r && o.checked && o.health.answered)) {
        r.up = false;
        r.strikes++;
        memory.changed();
        if (settings.flapGuard && r.strikes >= 2) {
          final u = AutoUnstable(id: r.id, strikes: r.strikes, holdMs: settings.hold(r.strikes).inMilliseconds, at: now);
          memory.unstableCount++;
          memory.lastUnstable = u;
          if (!_unstable.isClosed) _unstable.add(u);
        }
      }
    }
    final cur = _routes[index], since = cur.health.since;
    if (cur.strikes > 0 && since != null && now - max(since, cur.inUseSince) >= settings.flapReset.inMilliseconds) {
      cur.strikes = 0;
      memory.changed();
    }
  }

  /// Connections left on [tag] (a route or a server Auto just left because it stopped
  /// answering): the ones whose byte counters stood still for `stallAfter` are closed, the
  /// ones still moving live on. Again every `stallAfter`, up to 6 times, while [away].
  void _closeStalled(String tag, bool Function() away) =>
      _stall.sweep(tag, away, every: settings.stallAfter, onClosed: () => stalledClosed++);

  /// For the app: `{now: route id, index, server, entryServer (chain), manual, routes: [{id, ms,
  /// fails, oks, at, strikes, holdUntil, server, entryServer, exit}], members: [{key, ms, fails, oks, at, exit}] (every
  /// server tested so far, not a chain's exits: those are measured through the entry),
  /// pairs: [{entry, key, ms, fails, oks, at, exit}] (a chain's exit [key] through the entry
  /// server [entry]: the exits' own results, one per pair tested). `exit` = {ip, country (ISO, '' = never
  /// named), at} of the last exit check through that server ([exits]); null = never checked,
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

    // where the server leaves to by the last exit check through it: {ip, country (ISO, '' = never named), at}; null = never checked
    Map<String, dynamic>? exitOf(_Group g, String? key) => key != null && g.real.contains(key) ? exits[g.ids[key]!]?.toJson() : null;

    return {
      'now': cur.id,
      'index': index,
      'server': cur.main.now,
      'entryServer': cur.entry?.now,
      'routes': [
        // server / entryServer: where each route's groups stand, the standby ones too (a new plan
        // starts them there; null = not told by sing-box yet)
        for (final r in _routes)
          {'id': r.id, ...r.health.toJson(), 'strikes': r.strikes, 'holdUntil': holdUntil(r), 'server': r.main.now, 'entryServer': r.entry?.now, 'exit': exitOf(r.main, r.main.now)},
      ],
      'manual': manual,
      'members': [
        for (final r in _routes)
          for (final g in r.groups)
            if (!g.pair)
              for (final e in g.health.entries)
                if (e.value.at > 0) {'key': e.key, ...e.value.toJson(), 'exit': exitOf(g, e.key)},
      ],
      'pairs': [
        for (final r in _routes)
          if (r.main.pair)
            for (final e in r.main.health.entries)
              if (e.value.at > 0)
                {
                  'entry': e.key.substring(0, e.key.indexOf(_pairSep)),
                  'key': e.key.substring(e.key.indexOf(_pairSep) + 1),
                  ...e.value.toJson(),
                  'exit': exitOf(r.main, e.key.substring(e.key.indexOf(_pairSep) + 1)),
                },
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
      'siteFails': siteFailCount,
      'lastSiteFail': lastSiteFail?.toJson(),
      'stalledClosed': stalledClosed,
      'checkedAt': checkedAt,
    };
  }
}
