/// The ladder of dead nodes (docs/core.md → Auto → «Недоступные узлы»): a node that Auto (auto.dart) or the
/// "If unavailable" service (fallback.dart) found dead (`failAfter` misses in a row) and does not use now is
/// not tested every round any more: it is *unavailable*, asked again after 1, 2, 4, 8, 15 and then every 20
/// minutes, by one light request (the test URL alone, no backup checks). One answer takes it off the ladder.
///
/// The memory is the probe pool's ([ProbePool.ladder]): it lives as long as the core, so a reconnect, a
/// restart of sing-box or a change of settings does not start a node over. Keyed by the server's pool identity
/// (pool.dart: a fingerprint of its outbound; a chain's exit is the pair with its entry), which is what a ping
/// of the UI is recorded under too. Kept across a restart of the app ([DeadLadderStore]): a node may be
/// dead for months, and the ladder never starts over.
///
/// The ladder has no timer: a node is asked in a round of the module that watches it (Auto's, "If unavailable"),
/// which wakes the network for the round's own tests anyway. When a round has to ask some unavailable node (its
/// turn, or an out-of-turn check owed) the ones whose turn comes within the next [batchAhead] ride along in the
/// same go ([DeadLadder.gate] `ahead`), so the radio wakes once per batch; each keeps its own steps.
///
/// Out-of-turn checks ([owe]): a new connection and a change of network owe each unavailable node one check
/// at its next turn in a round; whether it answers or not, the ladder goes on from the step it was on.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';

/// How long an unavailable node waits after each miss: the step it is on (the last one repeats).
const deadLadderSteps = [Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 4), Duration(minutes: 8), Duration(minutes: 15), Duration(minutes: 20)];

/// How far ahead of its turn an unavailable node may be asked with a batch (the window of [DeadLadder.gate] `ahead`).
const batchAhead = Duration(minutes: 2);

/// What a round may do about one node.
enum LadderGate {
  /// Not on the ladder: tested as usual.
  free,

  /// On the ladder and its time has come (or a check is owed): one light request.
  light,

  /// On the ladder, not its time: not tested, the last result stands.
  skip,
}

/// One unavailable node.
class DeadNode {
  DeadNode(this.since, this.nextAt)
      : lastAt = since,
        seenAt = since;

  /// When it was found dead, ms since epoch.
  final int since;

  /// The last time it was asked (the miss that put it here, then each light request).
  int lastAt;

  /// The last time a round had to do with it (asked or skipped): a node nobody looks at any more is forgotten.
  int seenAt;

  /// The step of [deadLadderSteps] it waits on.
  int step = 0;

  /// When it is asked next (ms since epoch).
  int nextAt;

  /// Misses so far on the ladder (light requests).
  int misses = 0;

  /// Asked ahead of its turn with the batch of its round ([DeadLadder.gate] `ahead`): the next [DeadLadder.observe]
  /// counts as its step, though the turn had not come. Not kept.
  bool batched = false;

  DeadNode copy() => DeadNode(since, nextAt)
    ..lastAt = lastAt
    ..seenAt = seenAt
    ..step = step
    ..misses = misses;
}

class DeadLadder {
  DeadLadder({this.steps = deadLadderSteps, this.slack = const Duration(seconds: 1)});

  final List<Duration> steps;

  /// A turn that comes this much early still counts as due (a round is never to the millisecond).
  final Duration slack;

  /// How long a node nobody has looked at stays on the ladder.
  static const forgetAfter = Duration(days: 30);

  /// Called when the ladder changed in a way that is worth keeping ([DeadLadderStore]).
  void Function()? onChange;

  final _nodes = <String, DeadNode>{};
  final _owed = <String>{};

  bool has(String id) => _nodes.containsKey(id);
  DeadNode? operator [](String id) => _nodes[id];
  int get length => _nodes.length;
  Iterable<String> get ids => _nodes.keys;

  /// Whether the time of [id] has come (false for a node not on the ladder).
  bool due(String id, int now) {
    final n = _nodes[id];
    return n != null && now >= n.nextAt - slack.inMilliseconds;
  }

  /// A node found dead goes on the first step. False when it was on the ladder already.
  bool enter(String id, int now) {
    if (_nodes.containsKey(id)) return false;
    _nodes[id] = DeadNode(now, now + steps.first.inMilliseconds);
    onChange?.call();
    return true;
  }

  /// Whether a check of [id] is wanted now whatever the window: its turn has come or an out-of-turn one is owed.
  bool pending(String id, int now) => _nodes.containsKey(id) && (_owed.contains(id) || due(id, now));

  /// What a round may do about [id] now. [force]: the check is needed whatever the step (Auto looks for
  /// a route that answers). [ahead]: the round wakes the network for some other unavailable node anyway (a batch,
  /// [pending]), so this one rides along when its turn comes within [ahead]; its step stays its own ([observe]).
  /// The decision is not a check: [observe] tells the result.
  LadderGate gate(String id, int now, {bool force = false, Duration ahead = Duration.zero}) {
    final n = _nodes[id];
    if (n == null) return LadderGate.free;
    n.seenAt = now;
    n.batched = false;
    if (force || _owed.contains(id) || due(id, now)) return LadderGate.light;
    if (ahead > Duration.zero && now >= n.nextAt - slack.inMilliseconds - ahead.inMilliseconds) {
      n.batched = true;
      return LadderGate.light;
    }
    return LadderGate.skip;
  }

  /// A result for [id] (any module's, the UI's ping too): an answer takes the node off the ladder (true: it
  /// was on it); a miss makes it the next step when its time had come, else nothing changes (an early check
  /// adds nothing to what is known). A node asked ahead of its turn with a batch ([gate] `ahead`) takes its step
  /// too, and the next turn counts from the turn it had, not from the early check. Either way an owed
  /// out-of-turn check is paid.
  bool observe(String id, int ms, int now) {
    final n = _nodes[id];
    _owed.remove(id);
    if (n == null) return false;
    n.seenAt = now;
    final batched = n.batched;
    n.batched = false;
    if (ms >= 0) {
      _nodes.remove(id);
      onChange?.call();
      return true;
    }
    if (batched || now >= n.nextAt - slack.inMilliseconds) {
      if (n.step + 1 < steps.length) n.step++;
      n.nextAt = (batched && n.nextAt > now ? n.nextAt : now) + steps[n.step].inMilliseconds;
      n.lastAt = now;
      n.misses++;
      onChange?.call();
    }
    return false;
  }

  /// Forgets the nodes nobody has looked at for [forgetAfter] (they are in no plan any more). True when some went.
  bool prune(int now) {
    final cut = now - forgetAfter.inMilliseconds;
    final n = _nodes.length;
    _nodes.removeWhere((_, v) => v.seenAt < cut);
    _owed.retainAll(_nodes.keys);
    return _nodes.length != n;
  }

  /// Every node on the ladder is owed one check at its next turn, due or not (a new connection, a new network).
  void owe() => _owed.addAll(_nodes.keys);

  /// The ladder as it is, for a round that is taken back ([restore]).
  Map<String, DeadNode> snapshot() => {for (final e in _nodes.entries) e.key: e.value.copy()};

  /// Puts the ladder back to [snap], except the ids in [keep].
  void restore(Map<String, DeadNode> snap, {Set<String> keep = const {}}) {
    for (final id in _nodes.keys.toList()) {
      if (!keep.contains(id) && !snap.containsKey(id)) _nodes.remove(id);
    }
    for (final e in snap.entries) {
      if (!keep.contains(e.key)) _nodes[e.key] = e.value.copy();
    }
    onChange?.call();
  }

  /// Takes the ladder kept by [toJson] ([DeadLadderStore.load]): the nodes are put back on the step they were on,
  /// each owed one check (a start is a new connection). A step beyond this ladder's is its last; a next turn
  /// further away than the step's wait (the clock was set back) is brought to it. Entries unseen for
  /// [forgetAfter] and unreadable ones are left out. Returns how many nodes it took.
  int load(Object? json, int now) {
    if (json is! List) return 0;
    final cut = now - forgetAfter.inMilliseconds;
    var taken = 0;
    for (final e in json) {
      if (e is! Map || e['id'] is! String) continue;
      int i(String k, int d) => e[k] is num ? (e[k] as num).toInt() : d;
      final since = i('since', now);
      final seen = i('seenAt', i('lastAt', since));
      if (seen < cut) continue;
      final step = i('step', 0).clamp(0, steps.length - 1);
      final n = DeadNode(since, i('nextAt', now))
        ..lastAt = i('lastAt', since)
        ..seenAt = seen
        ..step = step
        ..misses = i('misses', 0);
      final latest = now + steps[step].inMilliseconds;
      if (n.nextAt > latest) n.nextAt = latest;
      _nodes[e['id'] as String] = n;
      taken++;
    }
    owe();
    return taken;
  }

  /// `[{id, since, lastAt, seenAt, nextAt, step, misses}]`.
  List<Map<String, dynamic>> toJson() => [
        for (final e in _nodes.entries)
          {'id': e.key, 'since': e.value.since, 'lastAt': e.value.lastAt, 'seenAt': e.value.seenAt, 'nextAt': e.value.nextAt, 'step': e.value.step, 'misses': e.value.misses},
      ];
}

/// Keeps the ladder in a file (`<dataDir>/dead-nodes.json`): written a moment after it changed (one write for
/// a round's worth of changes), read at the start.
class DeadLadderStore {
  DeadLadderStore(this.file, this.ladder, {int Function()? clock, this.debounce = const Duration(seconds: 2)})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    ladder.onChange = _changed;
  }

  final File file;
  final DeadLadder ladder;
  final Duration debounce;
  final int Function() _clock;
  Timer? _timer;
  Future<void> _writing = Future.value();
  bool _closed = false;

  /// Reads the file (none / damaged = an empty ladder); returns how many nodes were taken.
  int load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      return ladder.load(j is Map ? j['nodes'] : null, _clock());
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
      ladder.prune(_clock());
      await writeFileDurable(file, jsonEncode({'v': 1, 'nodes': ladder.toJson()}));
    } catch (_) {} // a full disk or a locked file: the ladder lives in memory, the next change writes again
  }

  /// Writes what waits now (the app closes) and stops watching the ladder.
  Future<void> close() async {
    final pending = _timer != null;
    _timer?.cancel();
    _timer = null;
    _closed = true;
    if (ladder.onChange == _changed) ladder.onChange = null;
    if (pending) _writing = _writing.then((_) => _write());
    await _writing;
  }
}
