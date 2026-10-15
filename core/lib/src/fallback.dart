/// "If unavailable" while sing-box runs (docs/rules.md §0): a rule or app that sends traffic
/// through a target (a subscription, node, profile or chain) goes there by a selector
/// `[target, fallback]` (routing.dart → [TargetFallback]); this service watches each target
/// and flips its selectors through sing-box's API service with no restart: the target
/// stops answering → the fallback the rule chose (Block, Direct, the main flow or another
/// target), and back when it answers again.
///
/// A fallback that is a target of the catalog is watched like any other (its own test, its
/// own hysteresis): the selector `[target, fallback target, main flow]` sits on the target
/// while it answers, else on the fallback target while that answers, else on the main flow
/// (both down; journalled as a move to 'main'). A fallback target coming back takes the
/// traffic from the main flow; the target coming back takes it from either.
///
/// A round (every `checkEvery`, the first after `firstCheck`; after a miss the next test
/// comes after `retryPause`, as with Auto) tests the server each target's group stands on
/// now, with the backup checks (probe.dart `withCheckers`, the AutoService's settings and
/// probe inbound): a chain's exit, through its entry. A Fastest group whose server missed
/// `failAfter` times in a row moves to the fastest answering one of a fresh check (as Auto does,
/// group_pick.dart), and while the server answers looks now and then for one faster by the threshold;
/// a Priority group is never moved (its server is the user's choice; the target is down while it is). A target is
/// down after `failAfter` misses in a row and back after `failAfter` answers in a row plus,
/// once it dropped, the flap guard's hold (auto.dart, watched.dart), so a target that
/// flaps does not make its rules flap.
///
/// The main flow can be the "target" (an app on Default / Proxy with the main flow and an
/// explicit fallback: block, direct or a target; selector `proxy~<fallback>`). Auto keeps the
/// main flow healed, so it is judged here by what a user sees: the test through the `proxy`
/// selector (its current server, as Auto left it), `failAfter` misses in a row = down. A
/// dead main flow looks like a dead network to Auto (no route answers: the pool's status is
/// `unknown`), so it is told apart here: after a miss the direct path and each fallback
/// target are tested, and only when one of them answers is the miss counted (the network is
/// up, the main flow is not; the answer also makes the pool's status `up`); none answering =
/// a dead network, nothing is judged. Only a `down` status (the OS offline, or the direct
/// path silent too) stops it for good. The main flow's selector never moves on from its
/// fallback because the fallback target dies too (nothing is better then); it comes back
/// like any target.
///
/// Nothing else is judged unless the pool's network status is `up` (Auto's route in use just
/// missed, or the network is down): a dead network is not a dead target. After a switch to the fallback
/// the connections still on the target whose bytes stand still are closed (stall.dart), so
/// their apps reconnect the new way; a switch back keeps every open connection.
///
/// The selectors keep their choice across a sing-box restart (`cache_file`): the service
/// starts from what sing-box says each one is on.
///
/// A selector whose fallback is Direct has a flag file ([TargetFallback.flagPath], written through [FallbackService.setFlag]):
/// on while the selector sits on Direct, off otherwise. The flag turns on before the selector moves and off after it came
/// back, so the resolve ladder in front of the rules that route there (routing.dart) holds exactly while their names go
/// direct; sing-box reads the file itself, no restart.
library;

import 'dart:async';

import 'auto.dart' show AutoSettings, DelayTest;
import 'auto_memory.dart';
import 'group_pick.dart';
import 'ladder.dart' show LadderGate;
import 'plan.dart' show topTag;
import 'pool.dart';
import 'routing.dart' show TargetFallback;
import 'sbapi.dart' show BoxControl;
import 'stall.dart';
import 'watched.dart';

/// A rule target went to its fallback ([back] false) or came back.
class FallbackChange {
  const FallbackChange({required this.target, required this.to, required this.rules, this.apps = const [], required this.back, required this.at});

  final String target; // the UI's target id
  final String to; // the fallback: 'block' | 'direct' | 'main' | the fallback target's id (also on the way back: what it left)
  final List<String> rules; // the names of the rules that route through this selector
  final List<String> apps; // … and of the apps
  final bool back;
  final int at;

  Map<String, dynamic> toJson() => {'target': target, 'to': to, 'rules': rules, 'apps': apps, 'back': back, 'at': at};
}

class _Group {
  _Group(this.tag, Map g)
      : priority = g['pick'] == 'priority',
        keys = {for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) '${n['key']}'}.toList(),
        chosen = '${g['chosen']}' {
    for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) {
      final o = n['outbound'];
      ids['${n['key']}'] = o is Map ? serverIdentity(o) : '$tag/${n['key']}'; // no outbound: nothing to share
    }
  }

  final ids = <String, String>{}; // key → the server's pool identity (pool.dart)
  final String tag;
  final bool priority;
  final List<String> keys;
  final String chosen;

  String member(String key) => '$tag/$key';
  String? keyOf(String member) => member.startsWith('$tag/') ? member.substring(tag.length + 1) : null;

  /// What sing-box starts the group on.
  String get initial => member(keys.contains(chosen) ? chosen : keys.first);
}

class _Target {
  _Target(this.id, Map spec)
      : main = _Group(id, spec['main'] as Map),
        entry = spec['kind'] == 'chain' ? _Group('$id>entry', spec['entry'] as Map) : null,
        isMain = false;

  /// The main flow: no groups of its own (Auto keeps it healed).
  _Target.mainFlow()
      : id = topTag,
        main = _Group(topTag, const {}),
        entry = null,
        isMain = true;

  final String id;
  final bool isMain;
  final _Group main;
  final _Group? entry;
  final selectors = <TargetFallback>[]; // the ones it is the target of
  final asFallback = <TargetFallback>[]; // the ones it is the fallback target of
  Watched w = Watched(); // the memory's (auto_memory.dart) once the service is made: a service made anew goes on from it
  bool down = false; // its selectors sit on the fallback
}

class FallbackService {
  FallbackService(this.api, Iterable<TargetFallback> fallbacks,
      {required this.delay, required this.settings, ProbePool? pool, this.mainIdentity, int Function()? clock, this.note, this.onDown, this.setFlag, this.netSwitching, AutoMemory? memory})
      : pool = pool ?? ProbePool.solo(),
        memory = memory ?? AutoMemory(),
        _clock = clock ?? _wallClock {
    final by = <String, _Target>{};
    for (final f in fallbacks) {
      (by[f.target] ??= f.target == topTag ? _Target.mainFlow() : _Target(f.target, f.spec)).selectors.add(f);
      final fb = f.fallbackTarget;
      if (fb != null) (by[fb] ??= _Target(fb, f.fallbackSpec!)).asFallback.add(f);
    }
    _by = by;
    _flagged = [for (final f in fallbacks) if (f.flagPath != null) f];
    _targets = by.values.toList();
    for (final t in _targets) {
      t.w = this.memory.target(t.id);
    }
    _stall = StallSweeper(api);
  }

  final BoxControl api;
  final DelayTest delay;

  /// A target's health and strikes live here, outside the service (auto_memory.dart): a service made anew (a connect, a
  /// restart) goes on from what the checks found, a target returns by the hold its drops earned. Without one given the
  /// service has its own. Keyed by the UI's target id (the main flow: `proxy`).
  final AutoMemory memory;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;

  /// The probe pool (pool.dart): the tests go through it and its network status says when to
  /// judge: only while `up` (a doubt or a dead network: a dead network is not a dead target),
  /// the main flow also while `unknown`. Without one given the service has its own (reuses
  /// nothing, status always up).
  final ProbePool pool;

  /// The pool identity of a main-flow server by its outbound tag (AutoService.identityOf):
  /// the main flow is Auto's, its servers are not in the targets. null = not shared.
  final String? Function(String tag)? mainIdentity;

  /// A target's server (its group tag and key; a chain target's entry too) missed `failAfter` tests in a row,
  /// like Auto's: the core may look at its address again (service.dart `_serverDown`). Not for the main flow.
  final void Function(String groupTag, String key)? onDown;

  /// The network is down or has just changed (the Sentinel context's `switching`): a miss now is the network's, so a
  /// target that does not answer is not judged (no miss counted, no server left, no fallback), asked again a retry pause
  /// later. null = never.
  final bool Function()? netSwitching;
  bool _netHeld = false; // a target was not judged in the running round for [netSwitching]

  /// Writes the flag of a selector that falls back to Direct (service.dart: the file); null = none.
  final void Function(TargetFallback s, bool on)? setFlag;
  late final List<TargetFallback> _flagged;
  final _flagOn = <String, bool>{}; // selector tag → the flag as last written

  /// A line for the log (jormd: `[jormd] rules: …`).
  final void Function(String line)? note;
  final int Function() _clock;
  late final Map<String, _Target> _by;
  late final List<_Target> _targets;
  late final StallSweeper _stall;
  final _changes = StreamController<FallbackChange>.broadcast();
  Timer? _timer;
  bool _busy = false, _started = false, _stopped = false;
  bool _kick = false; // a network change came in the middle of a round: another one follows at once
  bool _improveNow = false; // the network moved: the next round looks for a better server out of turn
  bool _improveForce = false; // … the running round does
  Duration _ahead = Duration.zero; // the running round asks the unavailable targets due within it too

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Every move to a fallback and back.
  Stream<FallbackChange> get changes => _changes.stream;

  /// Targets watched; nothing to run for none.
  bool get isEmpty => _targets.isEmpty;

  /// Whether [target] (the UI's id) is on its fallback now.
  bool isDown(String target) => _targets.any((t) => t.id == target && t.down);

  void start() {
    _started = true;
    // sing-box's cache_file may have restored an older pick over a group's default: the server chosen for this start wins
    if (reconcileStart) {
      _groupsSub = api.groupsChanged.listen((_) => unawaited(_reconcile()));
      unawaited(_reconcile());
    }
    _schedule(settings.firstCheck);
  }

  /// Whether the first look at the groups puts back what sing-box's cache restored (a connect); false for a taken-over
  /// sing-box, whose groups stand where the core before this one left them.
  bool reconcileStart = true;
  StreamSubscription<void>? _groupsSub;
  bool _startChecked = false;

  /// The groups the core itself selected on since this start (marked before the `select` goes): never put back.
  final _coreSelected = <String>{};

  Future<bool> _select(String group, String outbound) async {
    final fresh = _coreSelected.add(group);
    final ok = await api.select(group, outbound);
    if (!ok && fresh) _coreSelected.remove(group);
    return ok;
  }

  /// A server chosen for the group [groupTag] after the start (the connect's check that ended late, service.dart):
  /// false when the group is not here, was moved by the core already (that is the newer pick) or sing-box refused.
  Future<bool> select(String groupTag, String key) async {
    if (_stopped || _coreSelected.contains(groupTag)) return false;
    final ok = await _select(groupTag, '$groupTag/$key');
    if (ok) note?.call('rules: $groupTag: server $key (the check at the connect)');
    return ok;
  }

  Future<void> _reconcile() async {
    if (_startChecked || _stopped) return;
    final by = {...api.selected};
    if (by.isEmpty) return;
    _startChecked = true;
    for (final t in _targets) {
      if (t.isMain) continue;
      for (final g in [?t.entry, t.main]) {
        final cur = by[g.tag];
        if (cur == null || cur == g.initial || _coreSelected.contains(g.tag)) continue;
        if (_stopped) return;
        if (await _select(g.tag, g.initial)) note?.call('rules: ${g.tag} was restored on $cur by sing-box: put on ${g.initial}, the server chosen for this start');
      }
    }
  }

  /// The server every group of the rule targets is on now (group tag → key): what a restart with the same plan starts
  /// them on, so that a server chosen by a check is not forgotten (service.dart `_continuationPlan`).
  Map<String, String> groupServers() => {
        for (final t in _targets)
          if (!t.isMain)
            for (final g in [?t.entry, t.main])
              if (g.keyOf(api.selected[g.tag] ?? g.initial) case final k? when g.keys.contains(k)) g.tag: k,
      };

  /// The device moved to another network: a round runs now, out of turn, and in it the Fastest groups look for a better
  /// server whatever the time since the last look ([_improve]), like Auto's.
  void networkChanged() {
    if (_stopped) return;
    _improveNow = true;
    if (!_started) return;
    if (_busy) {
      _kick = true;
    } else {
      _schedule(Duration.zero);
    }
  }

  void stop() {
    _stopped = true;
    memory.changed(); // what it learned is written (the next service goes on from it)
    _timer?.cancel();
    _groupsSub?.cancel();
    _stall.stop();
    _changes.close();
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_started && !_stopped) _timer = Timer(d, () => unawaited(check()));
  }

  /// One round: test every target, move the ones that changed.
  Future<void> check() async {
    if (_busy || _stopped) return;
    _busy = true;
    _improveForce = _improveNow;
    _improveNow = false;
    try {
      if (!_sync()) return; // sing-box has not told its groups yet
      // the main flow is judged unless the network is known to be down (a dead main flow looks
      // like a doubt to Auto; it tells itself from a dead network); everything else only
      // while the network is up
      final st = pool.status;
      final judged = [for (final t in _targets) if (t.isMain ? st != NetStatus.down : st == NetStatus.up) t];
      if (judged.isEmpty) return;
      // some unavailable target is asked in this round anyway: the ones due within the window go with it (ladder.dart)
      final now = _clock();
      _ahead = judged.any((t) => !t.isMain && pool.ladder.pending(_identity(t, _current(t)), now)) ? settings.ladderAhead : Duration.zero;
      await Future.wait(judged.map(_test));
      if (_stopped) return;
      await _decide(judged);
    } finally {
      _busy = false;
      _ahead = Duration.zero;
      _improveForce = false;
      final retry = _netHeld || _targets.any((t) => !t.down && t.w.health.fails > 0 && !t.w.isDown(settings));
      _netHeld = false;
      final kick = _kick;
      _kick = false;
      _schedule(kick ? Duration.zero : retry ? settings.retryPause : settings.checkEvery);
    }
  }

  // What each selector is on now (after a sing-box restart the cache_file may have kept a
  // fallback); false before sing-box first told.
  bool _sync() {
    final by = api.selected;
    if (by.isEmpty || _stopped) return false;
    for (final t in _targets) {
      if (t.selectors.isNotEmpty) t.down = t.selectors.any((s) => by[s.tag] != null && by[s.tag] != s.target);
      // a selector on the main flow: both are down (the fallback target never ran its own selector)
      if (t.asFallback.any((s) => s.target != topTag && by[s.tag] == topTag)) t.down = true;
    }
    for (final s in _flagged) {
      _flag(s, by[s.tag] == s.fallbackTag);
    }
    return true;
  }

  // Sets the flag of [s] when it is not as written last (the first look after a start writes whatever sing-box says).
  void _flag(TargetFallback s, bool on) {
    if (setFlag == null || s.flagPath == null || _flagOn[s.tag] == on) return;
    try {
      setFlag!(s, on);
      _flagOn[s.tag] = on;
    } catch (e) {
      note?.call('rules: the Direct flag of ${s.tag} was not written: $e');
    }
  }

  Future<void> _test(_Target t) async {
    final ms = t.isMain ? await _probeMain(t) : await _probe(t);
    if (_stopped || ms == null) return;
    final now = _clock();
    final failing = t.w.health.fails > 0, strikes = t.w.strikes;
    t.w.health.record(ms, now);
    if (ms < 0 || failing) memory.changed();
    if (!t.isMain) {
      final id = _identity(t, _current(t));
      if (ms >= 0) {
        pool.ladder.observe(id, ms, now);
      } else if (t.w.health.fails >= settings.failAfter) {
        pool.ladder.enter(id, now); // dead: asked on the ladder from now on
      }
    }
    if (!t.down) t.w.forgetIfStable(settings, now);
    if (t.w.strikes != strikes) memory.changed();
    if (ms < 0 && !t.isMain && onDown != null && t.w.health.fails >= settings.failAfter) {
      for (final g in [?t.entry, t.main]) {
        final key = g.keyOf(api.selected[g.tag] ?? g.initial);
        if (key != null) onDown!(g.tag, key);
      }
    }
  }

  // A miss while the network is down or has just changed ([netSwitching]) is not judged: the round says so and is repeated.
  bool _heldByNetwork() {
    if (netSwitching?.call() != true) return false;
    _netHeld = true;
    return true;
  }

  // The server the main flow stands on now: down the selectors from `proxy` to a server.
  String _mainLeaf() {
    final sel = api.selected;
    var tag = topTag;
    for (var i = 0; i < 8; i++) {
      final next = sel[tag];
      if (next == null) break;
      tag = next;
    }
    return tag;
  }

  /// The main flow's test: ms, -1 = a miss, null = not judged (the network is down too).
  Future<int?> _probeMain(_Target t) async {
    final leaf = _mainLeaf();
    final ms = await _ping(mainIdentity?.call(leaf) ?? 'tag:$leaf', leaf);
    if (ms >= 0 || _stopped) return ms;
    if (_heldByNetwork()) return null;
    // missed: only counts when the network is up: the direct path or a fallback target answers
    final fbs = {for (final s in t.selectors) if (s.fallbackTarget != null) s.fallbackTarget!};
    final answers = await Future.wait([
      _ping(directIdentity, 'direct'),
      for (final id in fbs) _ping(_identity(_by[id]!, _current(_by[id]!)), _current(_by[id]!)),
    ]);
    return answers.any((a) => a >= 0) ? -1 : null;
  }

  // The server the target's group stands on now (a chain's exit: through its entry).
  String _current(_Target t) => api.selected[t.main.tag] ?? t.main.initial;

  // The pool identity of the server the target's group stands on (a chain's exit: the pair
  // with the entry server in use).
  String _identity(_Target t, String tag) {
    final key = t.main.keyOf(tag);
    final own = key == null ? null : t.main.ids[key];
    if (own == null) return 'tag:$tag';
    final e = t.entry;
    if (e == null) return own;
    final ek = e.keyOf(api.selected[e.tag] ?? e.initial);
    return pairIdentity(ek == null ? 'tag:${e.tag}' : e.ids[ek] ?? 'tag:${e.tag}', own);
  }

  /// One test of [tag] through the pool: a fresh enough answer of the same server (Auto's, the
  /// UI's ping) is the result.
  Future<int> _ping(String identity, String tag, {bool light = false}) async => (await _pingResult(identity, tag, light: light)).ms;

  Future<PoolResult> _pingResult(String identity, String tag, {bool light = false}) => pool.probeResult(identity, (url) => delay(tag, url, settings.timeoutMs),
      url: settings.url, checkers: light ? const [] : settings.checkers, maxAge: settings.reuse);

  // A target whose server is unavailable (ladder.dart: found dead, asked on a ladder) is asked on its turn by one
  // light request; between the turns it is not judged (null) and stays as it is. A Fastest group moves off a
  // server that missed (after failAfter misses in a row, as Auto's does) to the fastest answering one of a fresh
  // check (group_pick.dart), and looks for a better one while the server answers ([_improve]); a Priority group
  // never moves (its server is the user's choice).
  Future<int?> _probe(_Target t) async {
    final id = _identity(t, _current(t)), ladder = pool.ladder;
    final gate = ladder.gate(id, _clock(), ahead: _ahead);
    if (gate == LadderGate.skip) {
      // unavailable from an earlier connection: this service has not tested it, but knows it is dead
      for (var i = t.w.health.fails; i < settings.failAfter; i++) {
        t.w.health.record(-1, ladder[id]!.lastAt);
      }
      return null;
    }
    if (gate == LadderGate.light) {
      final ms = await _ping(id, _current(t), light: true);
      if (_stopped) return ms;
      if (ms < 0 && _heldByNetwork()) return null;
      ladder.observe(id, ms, _clock());
      return ms >= 0 ? ms : _heal(t); // its turn: the other servers of a Fastest group are looked at too
    }
    final r = await _pingResult(id, _current(t));
    if (_stopped) return r.ms;
    if (r.ms >= 0) return await _improve(t, r) ?? r.ms;
    if (_heldByNetwork()) return null;
    if (t.w.health.fails + 1 < settings.failAfter) return -1; // this miss is not yet the failAfter-th
    return _heal(t);
  }

  // The pool identity of the server [key] of [g] (a chain's exit: with the entry server in use).
  String _gid(_Target t, _Group g, String key) => identical(g, t.main) ? _identity(t, g.member(key)) : g.ids[key] ?? 'tag:${g.member(key)}';

  // One test of the server [key] of [g] as group_pick.dart asks it.
  Probe1 _probe1(_Target t, _Group g) => (key) async {
        final id = _gid(t, g, key);
        final r = await _pingResult(id, g.member(key));
        if (r.answered && !_stopped) pool.ladder.observe(id, r.ms, _clock()); // an unavailable server that answers is back
        return r;
      };

  // The candidates in the order the batches go by (group_pick.dart): the strong answers in the pool by ms, the group's
  // order, the unavailable ones last. [key]: the server in use, left out.
  List<String> _ranked(_Target t, _Group g, String? key, {bool withDead = true}) {
    final now = _clock();
    final keys = [
      for (final k in g.keys)
        if (k != key && (withDead || !pool.ladder.has(_gid(t, g, k)))) k,
    ];
    return rankCandidates(keys, peek: (k) {
      final p = pool.peek(_gid(t, g, k), url: settings.url, checkers: settings.checkers);
      return p != null && now - p.at <= const Duration(minutes: 10).inMilliseconds ? p : null;
    }, dead: (k) => pool.ladder.has(_gid(t, g, k)));
  }

  Future<bool> _move(_Target t, _Group g, String from, String to) async {
    if (_stopped || !await _select(g.tag, g.member(to))) return false;
    note?.call('rules: ${t.id}: server $from → $to (fastest)');
    return true;
  }

  // The target missed: each Fastest group whose own server misses is moved to the fastest answering one. The first
  // group's miss is the one just seen; a chain's exit is judged again after its entry moved. Returns the target's
  // delay after the moves (-1 = nothing moved or nobody answered).
  Future<int> _heal(_Target t) async {
    var moved = false, entryMoved = false;
    for (final g in [?t.entry, t.main]) {
      if (g.priority || _stopped) continue;
      final cur = g.keyOf(api.selected[g.tag] ?? g.initial);
      if (cur == null) continue;
      // (a unit's own server and a chain's exit through an entry that did not move are known to have missed just now)
      final known = identical(g, t.main) && !entryMoved;
      if (!known && (await _pingResult(_gid(t, g, cur), g.member(cur))).answered) continue;
      if (_stopped) return -1;
      final p = await pickFastest(_ranked(t, g, cur), _probe1(t, g));
      if (_stopped || !p.found || !await _move(t, g, cur, p.key!)) continue;
      moved = true;
      if (identical(g, t.entry)) entryMoved = true;
    }
    return moved && !_stopped ? _ping(_identity(t, _current(t)), _current(t)) : -1;
  }

  final _improvedAt = <String, int>{}; // group tag → when the better-server look last ran

  // The server of a Fastest group answers: once per checkEvery the best of the other servers (the top
  // [pickFirstBatch] by the ranking) are tested, and the group moves to the fastest one faster by the threshold. An
  // answer of a backup checker alone is never «faster», and any strong answer beats a weak server in use. Returns the
  // main group's delay when it moved, else null.
  Future<int?> _improve(_Target t, PoolResult r) async {
    int? out;
    for (final g in [?t.entry, t.main]) {
      if (g.priority || _stopped) continue;
      final now = _clock();
      if (!_improveForce && now - (_improvedAt[g.tag] ?? 0) < settings.checkEvery.inMilliseconds - 1000) continue;
      final cur = g.keyOf(api.selected[g.tag] ?? g.initial);
      if (cur == null) continue;
      _improvedAt[g.tag] = now;
      final others = _ranked(t, g, cur, withDead: false).take(pickFirstBatch).toList();
      if (others.isEmpty) continue;
      // the main group's server was just tested (the target's own test); a chain's entry alone is tested here
      final own = identical(g, t.main) ? r : await _pingResult(_gid(t, g, cur), g.member(cur));
      if (_stopped || !own.answered) continue;
      final probe = _probe1(t, g);
      final results = await Future.wait(others.map((k) async => (k, await probe(k))));
      if (_stopped || g.keyOf(api.selected[g.tag] ?? g.initial) != cur) continue;
      String? best;
      var bestMs = 0;
      for (final (k, p) in results) {
        if (!p.answered || p.byChecker) continue;
        if (best == null || p.ms < bestMs) {
          best = k;
          bestMs = p.ms;
        }
      }
      if (best == null || !(own.byChecker || bestMs + settings.threshold <= own.ms)) continue;
      if (await _move(t, g, cur, best) && identical(g, t.main)) out = bestMs;
    }
    return out;
  }

  // Every target is judged first (all the flags set), then the selectors move once to where
  // the flags say: a target and its fallback target dying in one round is one move, to the
  // main flow, not two.
  Future<void> _decide(List<_Target> judged) async {
    if (_stopped) return;
    final now = _clock();
    final moves = <(_Target, bool)>[];
    for (final t in judged) {
      if (!t.down && t.w.isDown(settings)) {
        moves.add((t, true));
      } else if (t.down && t.w.mayReturn(settings, now)) {
        moves.add((t, false));
      }
    }
    for (final (t, down) in moves) {
      t.down = down;
    }
    for (final (t, down) in moves) {
      await _flip(t, down: down);
    }
  }

  /// Where [s] sits for the targets' states now: its target; else the fallback; else, for a
  /// target as the fallback, the main flow when that is down too (not when the main flow is
  /// the target itself: it stays on the fallback, nothing is better).
  String _want(TargetFallback s) {
    if (!_by[s.target]!.down) return s.target;
    final fb = s.fallbackTarget;
    return fb != null && s.target != topTag && _by[fb]!.down ? topTag : s.fallbackTag;
  }

  /// Moves the selectors [t] decides on (as the target or as the fallback target) to where
  /// the targets' states put them. A target none of whose moves went through is not judged
  /// yet (back to what it was: the next round tries again).
  Future<void> _flip(_Target t, {required bool down}) async {
    var moved = 0, failed = 0;
    final left = <(String, _Target)>{}; // what traffic moved off: the tag whose connections to sweep, its target
    for (final s in {...t.selectors, ...t.asFallback}) {
      if (_stopped) return;
      final want = _want(s), cur = api.selected[s.tag] ?? s.target;
      if (cur == want) continue;
      if (want == s.fallbackTag) _flag(s, true); // the ladder is ready before the traffic arrives
      if (!await api.select(s.tag, want)) {
        failed++;
        _flag(s, cur == s.fallbackTag);
        continue;
      }
      moved++;
      _flag(s, want == s.fallbackTag);
      // 0 = the target, 1 = the fallback, 2 = the main flow behind a target fallback
      int rank(String x) => x == s.target ? 0 : x == s.fallbackTag ? 1 : 2;
      final names = [...s.rules, ...s.apps.map((a) => 'app $a')].join(', ');
      FallbackChange change(String to, bool back) =>
          FallbackChange(target: s.target, to: to, rules: List.of(s.rules), apps: List.of(s.apps), back: back, at: _clock());
      final to = want == topTag && s.fallbackTarget != null && s.target != topTag ? 'main' : s.to;
      final name = s.target == topTag ? 'main flow' : s.target;
      if (rank(want) > rank(cur)) {
        final from = _by[cur == s.target ? s.target : s.fallbackTarget ?? ''];
        // the main flow's stuck connections are the ones through this selector (the rest are Auto's)
        if (from != null) left.add((from.isMain ? s.tag : from.main.tag, from));
        note?.call('rules: $name does not answer: $names → $to');
        if (!_changes.isClosed) _changes.add(change(to, false));
      } else if (want == s.target) {
        note?.call('rules: $name answers again: $names back to it');
        if (!_changes.isClosed) _changes.add(change(cur == topTag ? 'main' : s.to, true));
      } else {
        note?.call('rules: ${s.fallbackTarget} answers again: $names moved back to it from the main flow'); // only target fallbacks have a rank 2
      }
    }
    if (_stopped) return;
    if (moved == 0 && failed > 0) {
      t.down = !down;
      return;
    }
    if (down) {
      t.w.struck();
    } else {
      t.w.usedSince = _clock();
    }
    memory.changed();
    for (final (tag, x) in left) {
      _stall.sweep(tag, () => x.down, every: settings.stallAfter);
    }
  }

  /// `{targets: [{target, down, ms, fails, oks, at, strikes}]}`.
  Map<String, dynamic> toJson() => {
        'targets': [
          for (final t in _targets) {'target': t.id, 'down': t.down, ...t.w.health.toJson(), 'strikes': t.w.strikes},
        ],
      };
}
