/// "If unavailable" while sing-box runs (docs/rules.md §0): a rule or app that sends traffic
/// through a target (a subscription, node, profile or chain) goes there by a selector
/// `[target, fallback]` (routing.dart → [TargetFallback]); this service watches each target
/// and flips its selectors through sing-box's API service with no restart: the target
/// stops answering → the fallback the rule chose (Block, Direct or the main flow), and back
/// when it answers again.
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
/// Nothing is judged while the network may be down ([networkUncertain]: Auto has no
/// answering route): a dead network is not a dead target. After a switch to the fallback
/// the connections still on the target whose bytes stand still are closed (stall.dart), so
/// their apps reconnect the new way; a switch back keeps every open connection.
///
/// The selectors keep their choice across a sing-box restart (`cache_file`): the service
/// starts from what sing-box says each one is on.
library;

import 'dart:async';

import 'auto.dart' show AutoSettings, DelayTest;
import 'probe.dart' show withCheckers;
import 'routing.dart' show TargetFallback;
import 'sbapi.dart' show BoxControl;
import 'stall.dart';
import 'watched.dart';

/// A rule target went to its fallback ([back] false) or came back.
class FallbackChange {
  const FallbackChange({required this.target, required this.to, required this.rules, this.apps = const [], required this.back, required this.at});

  final String target; // the UI's target id
  final String to; // the fallback: 'block' | 'direct' | 'main' (also on the way back: what it left)
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
        chosen = '${g['chosen']}';

  final String tag;
  final bool priority;
  final List<String> keys;
  final String chosen;

  String member(String key) => '$tag/$key';

  /// What sing-box starts the group on.
  String get initial => member(priority && keys.contains(chosen) ? chosen : keys.first);
}

class _Target {
  _Target(this.id, Map spec)
      : main = _Group(id, spec['main'] as Map),
        entry = spec['kind'] == 'chain' ? _Group('$id>entry', spec['entry'] as Map) : null;

  final String id;
  final _Group main;
  final _Group? entry;
  final selectors = <TargetFallback>[];
  final w = Watched();
  bool down = false; // its selectors sit on the fallback
}

class FallbackService {
  FallbackService(this.api, Iterable<TargetFallback> fallbacks,
      {required this.delay, required this.settings, this.networkUncertain, int Function()? clock, this.note})
      : _clock = clock ?? _wallClock {
    final by = <String, _Target>{};
    for (final f in fallbacks) {
      (by[f.target] ??= _Target(f.target, f.spec)).selectors.add(f);
    }
    _targets = by.values.toList();
    _stall = StallSweeper(api);
  }

  final BoxControl api;
  final DelayTest delay;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;

  /// True while the network may be down: the round judges nothing.
  final bool Function()? networkUncertain;

  /// A line for the log (jormd: `[jormd] rules: …`).
  final void Function(String line)? note;
  final int Function() _clock;
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
      if (networkUncertain?.call() == true) return;
      await Future.wait(_targets.map(_test));
      if (_stopped) return;
      for (final t in _targets) {
        await _decide(t);
      }
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
      t.down = t.selectors.any((s) => by[s.tag] == s.fallbackTag);
    }
    return true;
  }

  Future<void> _test(_Target t) async {
    final ms = await _probe(t);
    if (_stopped) return;
    final now = _clock();
    t.w.health.record(ms, now);
    if (!t.down) t.w.forgetIfStable(settings, now);
  }

  // The server the target's group stands on now (a chain's exit: through its entry).
  String _current(_Target t) => api.selected[t.main.tag] ?? t.main.initial;

  Future<int> _ping(String tag) => withCheckers((url) => delay(tag, url, settings.timeoutMs), settings.url, settings.checkers);

  Future<int> _probe(_Target t) async {
    final ms = await _ping(_current(t));
    if (ms >= 0 || _stopped) return ms;
    // urltest groups have all their servers tested again and pick one that answers
    var healed = false;
    for (final g in [?t.entry, t.main]) {
      if (g.priority) continue;
      await api.testGroup(g.tag, leaving: api.selected[g.tag], timeout: Duration(milliseconds: settings.timeoutMs + 5000));
      healed = true;
    }
    return healed && !_stopped ? _ping(_current(t)) : -1;
  }

  Future<void> _decide(_Target t) async {
    if (_stopped) return;
    final now = _clock();
    if (!t.down && t.w.isDown(settings)) {
      await _flip(t, toFallback: true);
    } else if (t.down && t.w.mayReturn(settings, now)) {
      await _flip(t, toFallback: false);
    }
  }

  Future<void> _flip(_Target t, {required bool toFallback}) async {
    var any = false;
    for (final s in t.selectors) {
      if (_stopped || !await api.select(s.tag, toFallback ? s.fallbackTag : s.target)) continue;
      any = true;
      final c = FallbackChange(target: t.id, to: s.to, rules: List.of(s.rules), apps: List.of(s.apps), back: !toFallback, at: _clock());
      final names = [...s.rules, ...s.apps.map((a) => 'app $a')].join(', ');
      note?.call(toFallback ? 'rules: ${t.id} does not answer: $names → ${s.to}' : 'rules: ${t.id} answers again: $names back to it');
      if (!_changes.isClosed) _changes.add(c);
    }
    if (!any || _stopped) return;
    t.down = toFallback;
    if (toFallback) {
      t.w.struck();
      _stall.sweep(t.main.tag, () => t.down, every: settings.stallAfter);
    } else {
      t.w.usedSince = _clock();
    }
  }

  /// `{targets: [{target, down, ms, fails, oks, at, strikes}]}`.
  Map<String, dynamic> toJson() => {
        'targets': [
          for (final t in _targets) {'target': t.id, 'down': t.down, ...t.w.health.toJson(), 'strikes': t.w.strikes},
        ],
      };
}
