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
/// has urltest test again and pick again first (as Auto does), a Priority group is never
/// moved (its server is the user's choice; the target is down while it is). A target is
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
library;

import 'dart:async';

import 'auto.dart' show AutoSettings, DelayTest;
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
  String get initial => member(priority && keys.contains(chosen) ? chosen : keys.first);
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
  final w = Watched();
  bool down = false; // its selectors sit on the fallback
}

class FallbackService {
  FallbackService(this.api, Iterable<TargetFallback> fallbacks,
      {required this.delay, required this.settings, ProbePool? pool, this.mainIdentity, int Function()? clock, this.note})
      : pool = pool ?? ProbePool.solo(),
        _clock = clock ?? _wallClock {
    final by = <String, _Target>{};
    for (final f in fallbacks) {
      (by[f.target] ??= f.target == topTag ? _Target.mainFlow() : _Target(f.target, f.spec)).selectors.add(f);
      final fb = f.fallbackTarget;
      if (fb != null) (by[fb] ??= _Target(fb, f.fallbackSpec!)).asFallback.add(f);
    }
    _by = by;
    _targets = by.values.toList();
    _stall = StallSweeper(api);
  }

  final BoxControl api;
  final DelayTest delay;

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

  /// A line for the log (jormd: `[jormd] rules: …`).
  final void Function(String line)? note;
  final int Function() _clock;
  late final Map<String, _Target> _by;
  late final List<_Target> _targets;
  late final StallSweeper _stall;
  final _changes = StreamController<FallbackChange>.broadcast();
  Timer? _timer;
  bool _busy = false, _started = false, _stopped = false;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Every move to a fallback and back.
  Stream<FallbackChange> get changes => _changes.stream;

  /// Targets watched; nothing to run for none.
  bool get isEmpty => _targets.isEmpty;

  /// Whether [target] (the UI's id) is on its fallback now.
  bool isDown(String target) => _targets.any((t) => t.id == target && t.down);

  void start() {
    _started = true;
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
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
    try {
      if (!_sync()) return; // sing-box has not told its groups yet
      // the main flow is judged unless the network is known to be down (a dead main flow looks
      // like a doubt to Auto; it tells itself from a dead network); everything else only
      // while the network is up
      final st = pool.status;
      final judged = [for (final t in _targets) if (t.isMain ? st != NetStatus.down : st == NetStatus.up) t];
      if (judged.isEmpty) return;
      await Future.wait(judged.map(_test));
      if (_stopped) return;
      await _decide(judged);
    } finally {
      _busy = false;
      final retry = _targets.any((t) => !t.down && t.w.health.fails > 0 && !t.w.isDown(settings));
      _schedule(retry ? settings.retryPause : settings.checkEvery);
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
    return true;
  }

  Future<void> _test(_Target t) async {
    final ms = t.isMain ? await _probeMain(t) : await _probe(t);
    if (_stopped || ms == null) return;
    final now = _clock();
    t.w.health.record(ms, now);
    if (!t.down) t.w.forgetIfStable(settings, now);
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
  Future<int> _ping(String identity, String tag) => pool.probe(identity, (url) => delay(tag, url, settings.timeoutMs),
      url: settings.url, checkers: settings.checkers, maxAge: settings.reuse);

  Future<int> _probe(_Target t) async {
    final ms = await _ping(_identity(t, _current(t)), _current(t));
    if (ms >= 0 || _stopped) return ms;
    // urltest groups have all their servers tested again and pick one that answers
    var healed = false;
    for (final g in [?t.entry, t.main]) {
      if (g.priority) continue;
      await api.testGroup(g.tag, leaving: api.selected[g.tag], timeout: Duration(milliseconds: settings.timeoutMs + 5000));
      healed = true;
    }
    return healed && !_stopped ? _ping(_identity(t, _current(t)), _current(t)) : -1;
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
      if (!await api.select(s.tag, want)) {
        failed++;
        continue;
      }
      moved++;
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
