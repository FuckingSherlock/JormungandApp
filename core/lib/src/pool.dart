/// The probe pool: one place the checks of the core's modules (Auto, the "If unavailable"
/// service, the UI's ping, the launch ping) put their results into and read them from, so a
/// server is not measured three times by three schedules; and the network status all of
/// them share (docs/core.md → Probe pool).
///
/// **Key** = what was measured, not how sing-box names it: the server's identity
/// ([serverIdentity]: a fingerprint of its outbound, so the same node is one key as a member
/// of Auto's route, a leaf of a rule target's group or `t/<key>` in the tester), a chain's
/// exit through its entry is the pair [pairIdentity]; plus the test URL and the backup
/// checkers: a result only answers the same kind of test.
///
/// **Coalescing**: a request for a key being measured awaits that measurement.
///
/// **Freshness** is the caller's: `maxAge` for an answer (a hit older than it is measured
/// again), `missAge` for a miss (default zero: a miss is never served, so "is it back?" is
/// always a real test, and a server's recovery or the return to it is never hidden by a
/// cached miss). A pool made with [ProbePool.solo] (a module run alone) never reuses
/// anything; coalescing and the status still work.
///
/// **Network status** ([status]): `up` / `down` / `unknown`. Any answered probe from any
/// module is `up` at once (and clears every sign below). `down` only on a guaranteed sign:
/// the OS has no network ([offline]), or the routes are silent and the direct path is too
/// ([silent]). A doubt (the route in use just missed: [doubt]) is `unknown`: judging waits,
/// probing goes on. Nothing yet = presumed `up`, as the modules presumed before.
library;

import 'dart:async';
import 'dart:convert';

import 'probe.dart' show withCheckers;

enum NetStatus { up, down, unknown }

/// The pool key of the direct path (the network check).
const directIdentity = 'direct';

/// A stable fingerprint of a server's outbound (FNV-1a, 64 bit, of its canonical JSON
/// without `tag` / `detour`): equal servers have equal identities whatever they are
/// called in a config.
String serverIdentity(Map outbound) {
  Object? canon(Object? o) => o is Map
      ? {for (final k in (o.keys.map((k) => '$k').toList()..sort())) k: canon(o[k])}
      : o is List
          ? o.map(canon).toList()
          : o;
  final m = {...outbound}..remove('tag')..remove('detour');
  var h = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16), mask = (BigInt.one << 64) - BigInt.one;
  for (final b in utf8.encode(jsonEncode(canon(m)))) {
    h = ((h ^ BigInt.from(b)) * prime) & mask;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// A chain: [exit] measured through [entry].
String pairIdentity(String entry, String exit) => '$entry>$exit';

/// The last result of one key.
class PoolResult {
  const PoolResult(this.ms, this.at);

  /// Delay in ms; -1 = no answer.
  final int ms;

  /// When it was measured, ms since epoch.
  final int at;

  bool get answered => ms >= 0;
}

class ProbePool {
  ProbePool({int Function()? clock, this.direct, bool share = true, this.missCap = const Duration(seconds: 3)})
      : _clock = clock ?? _wallClock,
        _share = share;

  /// A pool for one module run alone: it never reuses a result.
  ProbePool.solo({int Function()? clock, this.direct})
      : _clock = clock ?? _wallClock,
        _share = false,
        missCap = const Duration(seconds: 3);

  /// Measures the direct path (through the probe inbound's `direct`): ms, -1 = no answer.
  /// Set by the one that owns the probe inbound; null = the direct path cannot be tested.
  Future<int> Function(String url, int timeoutMs)? direct;

  /// The most a miss is ever served for, whatever `missAge` a caller gives.
  final Duration missCap;
  final int Function() _clock;
  final bool _share;
  final _results = <String, PoolResult>{};
  final _inflight = <String, Future<int>>{};

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  static String keyOf(String identity, String url, List<String> checkers) =>
      '$identity|$url|${(checkers.where((c) => c != url).toSet().toList()..sort()).join(',')}';

  /// ms of one test of [identity] by [one] (a request to the URL it is given, see
  /// [withCheckers]): [url] first, then every one of [checkers] when it misses — at once, or
  /// [checkerFanOut] at a time. Served from the pool when a result is younger than [maxAge]
  /// (an answer) or [missAge] (a miss), else measured — or joined, when the same key is being
  /// measured.
  Future<int> probe(
    String identity,
    Future<int> Function(String url) one, {
    required String url,
    List<String> checkers = const [],
    Duration maxAge = Duration.zero,
    Duration missAge = Duration.zero,
    int checkerFanOut = 0,
  }) {
    final key = keyOf(identity, url, checkers);
    final had = _results[key];
    if (_share && had != null) {
      final age = _clock() - had.at;
      final limit = had.answered ? maxAge : (missAge < missCap ? missAge : missCap);
      if (limit > Duration.zero && age <= limit.inMilliseconds) return Future.value(had.ms);
    }
    final running = _inflight[key];
    if (running != null) return running;
    final done = Completer<int>();
    _inflight[key] = done.future;
    withCheckers(one, url, checkers, fanOut: checkerFanOut).catchError((_) => -1).then((ms) {
      _inflight.remove(key);
      _put(key, ms);
      done.complete(ms);
    });
    return done.future;
  }

  /// A result measured elsewhere (the UI's ping): the pool has it from now on.
  void record(String identity, int ms, {required String url, List<String> checkers = const []}) => _put(keyOf(identity, url, checkers), ms);

  /// The last result of [identity] for this kind of test, or null.
  PoolResult? peek(String identity, {required String url, List<String> checkers = const []}) => _results[keyOf(identity, url, checkers)];

  /// Whether [probe] with this [maxAge] would be served from the pool (an answer that fresh).
  bool fresh(String identity, {required String url, List<String> checkers = const [], Duration maxAge = Duration.zero}) {
    final had = _results[keyOf(identity, url, checkers)];
    return _share && had != null && had.answered && maxAge > Duration.zero && _clock() - had.at <= maxAge.inMilliseconds;
  }

  void _put(String key, int ms) {
    _results[key] = PoolResult(ms, _clock());
    if (_results.length > 5000) {
      final old = _clock() - 600000;
      _results.removeWhere((_, r) => r.at < old);
    }
    if (ms >= 0) answered();
  }

  /// Whether the direct path answers ([directIdentity] through the pool; an answer is `up`).
  /// null = it cannot be tested ([direct] unset and no [runner]).
  Future<bool?> directAnswers({required String url, List<String> checkers = const [], int timeoutMs = 5000, Future<int> Function(String url)? runner}) async {
    final run = runner ?? (direct == null ? null : (String u) => direct!(u, timeoutMs));
    if (run == null) return null;
    return await probe(directIdentity, run, url: url, checkers: checkers) >= 0;
  }

  /* ── Network status ── */

  bool _offline = false, _silent = false, _doubt = false;
  int? _upAt, _changedAt;
  NetStatus _last = NetStatus.up;

  NetStatus get status => _refresh();

  // The flags as last pushed: a change of any of them is pushed, even when the status stays (`os` vs `probes`).
  (bool, bool, bool) _pushed = (false, false, false);

  // Every mutator ends here: the Sentinel learns of a change when it happens, not when someone reads.
  NetStatus _refresh() {
    final s = _offline || _silent ? NetStatus.down : (_doubt ? NetStatus.unknown : NetStatus.up);
    final flags = (_offline, _silent, _doubt);
    final moved = s != _last;
    if (moved) {
      _last = s;
      _changedAt = _clock();
    }
    if (moved || flags != _pushed) {
      _pushed = flags;
      onChange?.call(s);
    }
    return s;
  }

  /// Called whenever the status or the flags behind it change, from the call that changed them (the
  /// Sentinel's network context follows it, sentinel/context.dart).
  void Function(NetStatus status)? onChange;

  /// The OS says it has no network (see [offline]).
  bool get osOffline => _offline;

  /// Anything answered: the network is up, whatever was doubted or thought down.
  void answered() {
    _upAt = _clock();
    _offline = _silent = _doubt = false;
    _refresh();
  }

  /// The route in use missed (a failing route is not yet a failing network): `unknown` until
  /// something answers. [on] false takes the doubt back (the route answers).
  void doubt(bool on) {
    _doubt = on;
    _refresh();
  }

  /// The OS says it has no network (sing-box: `missing default interface`), or has it again.
  void offline(bool on) {
    _offline = on;
    _refresh();
  }

  /// Every route is silent and so is the direct path (see [directAnswers]): no network.
  void silent(bool on) {
    _silent = on;
    _refresh();
  }

  /// A new connection starts from a clean slate (results are kept: servers are the same).
  void resetNetwork() {
    _offline = _silent = _doubt = false;
    _refresh();
  }

  /// `{status, since (ms), lastAnswer (ms), offline, silent, doubt}` for /api/status.
  Map<String, dynamic> toJson() => {
        'status': status.name,
        'since': _changedAt,
        'lastAnswer': _upAt,
        'offline': _offline,
        'silent': _silent,
        'doubt': _doubt,
      };
}
