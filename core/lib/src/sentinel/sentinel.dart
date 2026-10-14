/// The Sentinel: before a failure is reported as one, it is checked against the state of the world
/// (docs/failures.md). Detectors do not emit failure events on their own: they [Sentinel.suspect],
/// and get a [Verdict] back (the Sentinel writes the journal entry with the trail of what it checked).
///
/// One owner inside the core, on its own async loop: suspicions go through an input queue and are
/// judged concurrently (at most [maxActive]); a suspicion with a key that is being judged joins that
/// judgement. Pure Dart; the clock and the waits are injected ([SentinelClock]).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../eventbook.dart';
import 'clock.dart';
import 'context.dart';
import 'model.dart';
import 'roots.dart';
import 'windows.dart';

export 'clock.dart';
export 'context.dart';
export 'model.dart';
export 'retry.dart';
export 'roots.dart';
export 'windows.dart';

class _Running {
  _Running(this.check, this.cancel, this.done);

  final Check check;
  final Cancel cancel;
  final Completer<CheckResult> done;
}

class _Job {
  _Job(this.s, this.since) : evidence = {...s.evidence};

  final Suspicion s;
  final Map<String, dynamic> evidence;
  final DateTime since;
  final done = Completer<Verdict>();
  final trail = <TrailStep>[];
  bool recovered = false;
  String? recoveredBy;
  String? droppedBy;
  Duration deferred = Duration.zero;

  /// How long the suspicion has been parked behind failed nodes in all (bounded by [Sentinel.parkMax]).
  Duration parked = Duration.zero;
  int restarts = 0;
  int joined = 0;

  /// The check that is running now (the context may make it moot).
  _Running? running;

  Completer<void>? _wake;
  Timer? _timer;

  Future<void> sleep(SentinelClock clock, Duration d) {
    if (d <= Duration.zero) return Future.value();
    final c = _wake = Completer<void>();
    _timer = clock.timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future.whenComplete(() {
      _timer?.cancel();
      _timer = null;
      if (identical(_wake, c)) _wake = null;
    });
  }

  /// Wakes the wait this job is in (the context moved, or the detector says it recovered).
  void poke() {
    final c = _wake;
    if (c != null && !c.isCompleted) c.complete();
  }
}

class Sentinel {
  Sentinel({
    SentinelClock? clock,
    ContextTracker? context,
    Duration settle = const Duration(seconds: 5),
    this.book,
    this.note,
    this.deferMax = const Duration(seconds: 60),
    this.checkTimeout = const Duration(seconds: 10),
    this.maxActive = 32,
    this.parkMax = parkLimit,
    RootRegistry? roots,
  })  : clock = clock ?? context?.clock ?? SentinelClock(),
        roots = roots ?? RootRegistry() {
    this.context = context ?? ContextTracker(clock: this.clock, settle: settle);
    _lastCoreEpoch = this.context.coreEpoch;
    this.context.onChange = _onContext;
    _syncContextRoots();
  }

  final SentinelClock clock;
  late final ContextTracker context;
  final RootRegistry roots;

  /// Where the verdicts are written (a suspicion with an `event`); null = nothing is written.
  final EventBook? book;

  /// The raw log (`level`, text): root opened / closed, deferred suspicions.
  final void Function(String level, String text)? note;

  /// The longest an own restart of the core is waited out before a suspicion is let go as `deferred`.
  final Duration deferMax;

  /// A check that takes longer is `inconclusive`.
  final Duration checkTimeout;

  /// How many suspicions are judged at once; the rest wait in the queue.
  final int maxActive;

  /// The longest a suspicion waits parked behind a failed node (all parks together); then `deferred`.
  final Duration parkMax;

  final _queue = Queue<_Job>();
  final _byKey = <String, _Job>{};
  int _active = 0;
  bool _closed = false;
  late int _lastCoreEpoch;

  final _verdicts = StreamController<Verdict>.broadcast();
  final _changes = StreamController<Map<String, dynamic>>.broadcast();

  /// Every verdict as it is made (repeats included).
  Stream<Verdict> get verdicts => _verdicts.stream;

  /// The context again whenever it changed (network, core phase, roots): [contextJson].
  Stream<Map<String, dynamic>> get changes => _changes.stream;

  /// `{network, core, roots}`: the context for /api/status.
  Map<String, dynamic> contextJson() => {...context.toJson(), 'roots': roots.openJson()};

  // ── suspicions ──

  /// Reports a failure to be judged. The future completes with the verdict (after the window, the
  /// checks and any wait for our own restart); it never throws.
  Future<Verdict> suspect(Suspicion s) {
    if (_closed) return Future.value(Verdict(kind: VerdictKind.deferred, key: s.key, why: const Why('sentinel.closed')));
    _sweepRoots();
    final root = roots.byKey(s.key);
    if (root != null) {
      // the same failure again: no new event (the root's one says so), but every occurrence is counted and in the raw log
      final at = clock.now().millisecondsSinceEpoch, id = root.eventId, b = book;
      root.repeats++;
      if (id == null || b == null || b.tally(id, [at]) == 0) {
        root.unwrittenCount++;
        root.unwritten.add(at);
        if (root.unwritten.length > EventBook.repeatKeep) root.unwritten.removeAt(0);
      }
      note?.call('info', 'sentinel: ${s.key} again while root ${root.id} is open (${root.repeats + 1} times)');
      final v = Verdict(kind: VerdictKind.confirmed, key: s.key, rootId: root.id, cause: root.eventId, repeat: true);
      if (!_verdicts.isClosed) _verdicts.add(v);
      return Future.value(v);
    }
    final running = _byKey[s.key];
    if (running != null) {
      running.joined++;
      running.evidence.addAll(s.evidence);
      return running.done.future;
    }
    final j = _Job(s, s.firstSeen ?? clock.now());
    _byKey[s.key] = j;
    _queue.add(j);
    scheduleMicrotask(_pump);
    return j.done.future;
  }

  void _pump() {
    while (!_closed && _active < maxActive && _queue.isNotEmpty) {
      final j = _queue.removeFirst();
      _active++;
      _run(j).whenComplete(() {
        _active--;
        _byKey.remove(j.s.key);
        scheduleMicrotask(_pump);
      });
    }
  }

  Future<void> _run(_Job j) async {
    Verdict v;
    try {
      v = await _evaluate(j);
    } catch (e) {
      _step(j, 'sentinel.error', Outcome.info, {'error': '$e'});
      note?.call('error', 'sentinel: judging ${j.s.key} failed: $e');
      v = _verdict(j, VerdictKind.deferred, const Why('sentinel.error'));
    }
    if (!_verdicts.isClosed) _verdicts.add(v);
    if (!j.done.isCompleted) j.done.complete(v);
  }

  /// The detector saw the thing work again: a suspicion under way ends as a `blip`, an open root with
  /// this key closes. True when there was either.
  bool recovered(String key, {String reason = 'recovered'}) {
    var any = false;
    final j = _byKey[key];
    if (j != null) {
      j.recovered = true;
      j.recoveredBy = reason;
      j.poke();
      any = true;
    }
    final r = roots.byKey(key);
    if (r != null && !r.fromContext) {
      _close(r, reason);
      any = true;
    }
    return any;
  }

  /// The sing-box session the suspicions under way were seen in is over (a stop, a new connect): they
  /// are let go as `deferred` without a record; what is still wrong is suspected again by its detector.
  /// [park]: an own restart or a crash-recovery instead: nothing is lost, the suspicions go on (the context
  /// makes them wait for the core to settle, or parks them behind `core.down`).
  void dropAll({String reason = 'session.ended', bool park = false}) {
    if (park) return;
    for (final j in _byKey.values.toList()) {
      j.droppedBy = reason;
      _abort(j, reason);
      j.poke();
    }
  }

  // ── roots ──

  /// A root a detector confirmed by itself (it wrote the event): opened with [eventId]; an open root of
  /// the same [key] (or of the same context kind) only gets the event. Open roots it covers become its
  /// consequences.
  Root openRoot({
    required String kind,
    String? key,
    Map<String, dynamic> subject = const {},
    Scope? scope,
    int? eventId,
    bool session = true,
    Level level = Level.destination,
    List<TrailStep>? trail,
  }) {
    final k = key ?? kind;
    final had = roots.byKey(k);
    if (had != null) {
      if (eventId != null) attachEvent(had, eventId);
      return had;
    }
    final r = Root(
      id: roots.nextId(kind),
      kind: kind,
      key: k,
      subject: subject,
      scope: scope ?? (subject.isEmpty ? Scope.none : Scope.of(subject)),
      since: clock.now(),
      eventId: eventId,
      session: session,
      level: level,
      trail: trail,
    );
    roots.add(r);
    note?.call('info', 'sentinel: root ${r.id} opened');
    _relink(r);
    _pokeAll();
    _changed();
    return r;
  }

  /// Gives a root its journal event; the consequences already written get it as their `cause`.
  void attachEvent(Root r, int eventId) {
    r.eventId = eventId;
    if (r.unwrittenCount > 0) {
      // the repeats that came before the root had an event: they are on it now
      book?.tally(eventId, List.of(r.unwritten), r.unwrittenCount - r.unwritten.length);
      r.unwritten.clear();
      r.unwrittenCount = 0;
    }
    for (final id in r.consequences) {
      book?.update(id, cause: eventId);
    }
    _changed();
  }

  /// Closes the open root [idOrKey]; false when there is none.
  bool closeRoot(String idOrKey, {String reason = 'closed'}) {
    final r = roots.byId(idOrKey) ?? roots.byKey(idOrKey);
    if (r == null) return false;
    _close(r, reason);
    return true;
  }

  void _close(Root r, String reason) {
    final now = clock.now();
    if (!roots.close(r, now, reason)) return;
    final after = now.difference(r.since);
    note?.call('info', 'sentinel: root ${r.id} closed after ${after.inSeconds} s ($reason)');
    final id = r.eventId;
    if (id != null) {
      book?.update(id, appendTrail: [TrailStep('root.closed', Outcome.pass, now.millisecondsSinceEpoch, {'reason': reason, 'afterMs': after.inMilliseconds}).toJson()]);
    }
    _pokeAll(); // the suspicions parked behind it go on
    _changed();
  }

  void _sweepRoots() {
    for (final r in roots.expired(clock.now())) {
      _close(r, 'expired');
    }
  }

  // Open roots that [root] covers are its consequences from now on.
  void _relink(Root root) {
    final now = clock.now().millisecondsSinceEpoch;
    for (final r in roots.open.toList()) {
      if (identical(r, root) || r.parent != null || r.fromContext || !root.covers(r.subject) || r.covers(root.subject)) continue;
      r.parent = root.id;
      final id = r.eventId;
      if (id != null) {
        root.consequences.add(id);
        book?.update(id,
            verdict: 'consequence',
            cause: root.eventId,
            why: Why(root.kind, {'root': root.id}).toJson(),
            appendTrail: [TrailStep('root.relinked', Outcome.info, now, {'root': root.id, 'kind': root.kind}).toJson()]);
      }
    }
  }

  // ── context ──

  void _onContext() {
    _syncContextRoots();
    final phase = context.phase, epoch = context.coreEpoch;
    // a stop, or a new sing-box: the roots of the old session are void
    if (epoch != _lastCoreEpoch) {
      _lastCoreEpoch = epoch;
      if (phase == CorePhase.stopped) {
        _closeSession('core.stopped');
      } else if (phase == CorePhase.starting || phase == CorePhase.settling) {
        _closeSession('core.restart');
      }
    }
    _pokeAll();
    _changed();
  }

  // The suspicions under way look at the world again; a check that has become moot is cancelled at once.
  void _pokeAll() {
    for (final j in _byKey.values.toList()) {
      final r = j.running;
      if (r != null) {
        final by = _moot(j.s, r.check);
        if (by != null) _abort(j, by);
      }
      j.poke();
    }
  }

  // ── levels ──

  Level _levelOf(Suspicion s, Check c) => c.level ?? (s.viaCore ? Level.destination : Level.network);

  /// The open root that stops [c] (network -> core -> route -> destination): one on its level or above, that
  /// it goes through. A `route` root only stops the checks `via` that route, a `dns` root those that resolve
  /// through that server. The highest, then the oldest.
  Root? _blocker(Suspicion s, Check c) {
    final lvl = _levelOf(s, c);
    Root? best;
    for (final r in roots.open) {
      if (r.level == Level.destination || r.key == s.key) continue;
      // an explicit binding beats the level order: a check that resolves through a server depends on it
      // whatever its level (a route whose server is a domain name resolves it through the default resolver)
      final bound = r.level == Level.dns && c.resolver != null && r.subject['dns'] == c.resolver;
      if (!bound) {
        if (r.level.index > lvl.index) continue;
        if (r.level == Level.route && (c.via == null || r.subject['route'] != c.via)) continue;
        if (r.level == Level.dns) continue;
      }
      if (best == null || r.level.index < best.level.index || (r.level == best.level && r.since.isBefore(best.since))) best = r;
    }
    return best;
  }

  /// Why [c] is moot now (a root id, or `core.<phase>` while our own sing-box is not settled); null = it is not.
  String? _moot(Suspicion s, Check c) {
    final b = _blocker(s, c);
    if (b != null) return b.id;
    if (s.viaCore && _levelOf(s, c) != Level.network && !context.settled) return 'core.${context.phase.name}';
    return null;
  }

  void _abort(_Job j, String by) {
    final r = j.running;
    if (r == null || r.done.isCompleted) return;
    r.cancel.cancel(by);
    r.done.complete(CheckResult(r.check.code, Outcome.inconclusive, {'reason': 'aborted', 'by': by}));
  }

  void _closeSession(String reason) {
    for (final r in roots.open.toList()) {
      if (r.session && !r.fromContext) _close(r, reason);
    }
  }

  void _syncContextRoots() {
    final net = context.network;
    final netSince = DateTime.fromMillisecondsSinceEpoch(net.since);
    _contextRoot(rootNetOffline, net.state == NetState.none, 'net.restored', {'source': net.source}, Level.network, netSince);
    _contextRoot(rootNetCaptive, net.state == NetState.captive, 'net.restored', const {}, Level.network, netSince);
    // the core failed when it stopped being settled (the crash), not when the 30 s of retries ran out
    _contextRoot(rootCoreDown, context.phase == CorePhase.down, 'core.up', const {}, Level.core, context.unsettledSince);
  }

  void _contextRoot(String kind, bool want, String closeReason, Map<String, dynamic> subject, Level level, DateTime? since) {
    final have = roots.byKind(kind);
    if (want && have == null) {
      final r = Root(
        id: roots.nextId(kind),
        kind: kind,
        key: kind,
        subject: subject,
        scope: Scope.all,
        since: since ?? clock.now(),
        session: false,
        fromContext: true,
        level: level,
      );
      roots.add(r);
      note?.call('info', 'sentinel: root ${r.id} opened');
      _relink(r);
    } else if (!want && have != null && have.fromContext) {
      _close(have, closeReason);
    }
  }

  void _changed() {
    if (!_changes.isClosed && _changes.hasListener) _changes.add(contextJson());
  }

  // ── the ladder ──

  void _step(_Job j, String code, Outcome outcome, [Map<String, dynamic> params = const {}, bool once = false]) {
    if (once) {
      for (var i = j.trail.length - 1; i >= 0; i--) {
        if (j.trail[i].code != code) continue;
        if (j.trail[i].outcome == outcome && jsonEncode(j.trail[i].params) == jsonEncode(params)) return;
        break;
      }
    }
    j.trail.add(TrailStep(code, outcome, clock.now().millisecondsSinceEpoch, params));
  }

  static Map<String, dynamic> _facts(Map<String, dynamic> evidence) {
    final out = <String, dynamic>{};
    for (final e in evidence.entries) {
      final v = e.value;
      if (v is num || v is String || v is bool) out[e.key] = v;
      if (out.length >= 12) break;
    }
    return out;
  }

  Future<Verdict> _evaluate(_Job j) async {
    final s = j.s;
    var since = j.since;
    _step(j, 'suspect', Outcome.fail, {
      'kind': s.kind,
      'subject': s.subject,
      'facts': _facts(j.evidence),
      'windowMs': s.window.inMilliseconds,
      'firstSeen': since.millisecondsSinceEpoch,
    });
    while (true) {
      if (_closed) return _verdict(j, VerdictKind.deferred, const Why('sentinel.closed'));
      final dropped = j.droppedBy;
      if (dropped != null) {
        _step(j, 'session.dropped', Outcome.info, {'reason': dropped});
        return _deferred(j, Why(dropped));
      }
      if (j.recovered) return _blip(j, since, j.recoveredBy ?? 'recovered');

      // a. an external cause: no network, a captive portal
      final external = _external(j);
      if (external != null) {
        final v = await _park(j, external);
        if (v != null) return v;
        continue;
      }
      final net = context.network;
      _step(j, 'ctx.net', net.state == NetState.up ? Outcome.pass : Outcome.inconclusive, {'state': net.state.name, 'since': net.since}, true);

      // b. ourselves
      if (j.evidence['ownReject'] == true) {
        _step(j, 'self.reject', Outcome.fail, const {});
        return _deferred(j, const Why('self.reject'));
      }
      if (s.viaCore) {
        final phase = context.phase;
        if (phase == CorePhase.stopped) {
          _step(j, 'ctx.core', Outcome.fail, {'phase': phase.name});
          return _deferred(j, const Why('core.stopped'));
        }
        if (phase != CorePhase.down && phase != CorePhase.settled) {
          final c = context.core;
          _step(j, 'ctx.core', Outcome.fail, {'phase': phase.name, 'reason': ?c.restartReason, 'since': c.since}, true);
          final left = deferMax - j.deferred;
          if (left <= Duration.zero) {
            _step(j, 'defer.timeout', Outcome.fail, {'maxMs': deferMax.inMilliseconds});
            return _deferred(j, const Why('self.notSettled'));
          }
          var wait = left;
          final toSettle = context.untilSettled();
          if (toSettle != null && toSettle < wait) wait = toSettle;
          final t0 = clock.now();
          await j.sleep(clock, wait);
          j.deferred += clock.now().difference(t0);
          continue;
        }
        if (phase == CorePhase.settled) {
          final u = context.lastUnsettled(since);
          if (u != null && u.isAfter(since)) {
            _step(j, 'self.restarted', Outcome.info, {'reason': ?context.core.restartReason, 'settledAt': u.millisecondsSinceEpoch});
            since = u; // the failure must last the window after our own restart
          } else {
            _step(j, 'ctx.core', Outcome.pass, {'phase': phase.name}, true);
          }
        }
      }

      // c. a root that already explains it
      final root = roots.covering(s.subject, except: s.key);
      if (root != null) {
        _step(j, 'root.covers', Outcome.fail, {'root': root.id, 'kind': root.kind});
        if (root.level == Level.destination) return _consequence(j, root);
        final v = await _park(j, root);
        if (v != null) return v;
        continue;
      }

      // e. persistence
      final now = clock.now();
      final due = since.add(s.window);
      if (now.isBefore(due)) {
        _step(j, 'persist.wait', Outcome.info, {'windowMs': s.window.inMilliseconds}, true);
        await j.sleep(clock, due.difference(now));
        continue;
      }
      _step(j, 'persist.window', Outcome.fail, {'windowMs': s.window.inMilliseconds, 'elapsedMs': now.difference(since).inMilliseconds}, true);

      // d. the active checks, in the order given
      Why? diag;
      var again = false; // a check was skipped or cancelled: the context moved, look at it again
      for (final c in s.checks) {
        if (_closed) break;
        final blocker = _blocker(s, c);
        if (blocker != null) {
          _step(j, 'check.skipped', Outcome.inconclusive, {'check': c.code, 'role': c.role.name, 'root': blocker.id});
          final v = await _park(j, blocker);
          if (v != null) return v;
          again = true;
          break;
        }
        final r = await _runCheck(j, c);
        _step(j, r.code, r.outcome, {'role': c.role.name, ...r.params});
        if (j.recovered || j.droppedBy != null) break;
        if (r.params['reason'] == 'aborted') {
          again = true;
          break;
        }
        if (r.outcome == Outcome.pass && c.role == CheckRole.recovery) return _blip(j, since, r.code);
        if (r.outcome == Outcome.pass && c.role == CheckRole.alternative) {
          return _emit(j, VerdictKind.workaround, Why('workaround', {'by': r.code}));
        }
        if (r.outcome == Outcome.fail && c.role == CheckRole.diagnostic) diag ??= Why(r.code, r.params);
      }
      if (j.recovered || j.droppedBy != null || again) continue;
      // the checks took time: the world may have changed under them
      final late = _external(j);
      if (late != null) {
        final v = await _park(j, late);
        if (v != null) return v;
        continue;
      }
      if (s.viaCore && !context.settled && context.phase != CorePhase.down && j.restarts++ < 3) continue;
      final lateRoot = roots.covering(s.subject, except: s.key);
      if (lateRoot != null) {
        _step(j, 'root.covers', Outcome.fail, {'root': lateRoot.id, 'kind': lateRoot.kind});
        if (lateRoot.level == Level.destination) return _consequence(j, lateRoot);
        final v = await _park(j, lateRoot);
        if (v != null) return v;
        continue;
      }

      // f. nothing says why: the journal only
      final why = diag ?? s.why ?? s.whyLate?.call(j.evidence);
      if (why == null) {
        _step(j, 'why.unknown', Outcome.inconclusive, const {});
        return _emit(j, VerdictKind.unexplained, const Why('why.unknown'));
      }
      return _confirm(j, why, since);
    }
  }

  // The network is known to be missing: the root that says so (the suspicion is its consequence, or parked behind it).
  Root? _external(_Job j) {
    final net = context.network;
    if (net.state != NetState.none && net.state != NetState.captive) return null;
    _step(j, 'ctx.net', Outcome.fail, {'state': net.state.name, 'since': net.since, 'source': net.source});
    _syncContextRoots();
    return roots.byKind(net.state == NetState.none ? rootNetOffline : rootNetCaptive);
  }

  /// A failed node ([root]: the network, the core, a dead route, any root above the suspicion) stands in the
  /// way. If the failure began after the node failed, it is the node's consequence. If it began before, the
  /// node did not cause it and what was being tested must not be lost: the suspicion is parked until the root
  /// closes (at most [parkMax] altogether, then `deferred`), and the ladder starts again with the checks to re-run.
  /// Null = the wait is over, look at the world again.
  Future<Verdict?> _park(_Job j, Root root) async {
    if (!j.since.isBefore(root.since)) return _consequence(j, root);
    final t0 = clock.now();
    _step(j, 'park', Outcome.info, {'root': root.id, 'since': t0.millisecondsSinceEpoch});
    while (!_closed && j.droppedBy == null && !j.recovered && root.open) {
      final left = parkMax - j.parked - clock.now().difference(t0);
      if (left <= Duration.zero) {
        j.parked += clock.now().difference(t0);
        _step(j, 'park.expired', Outcome.fail, {'root': root.id, 'maxMs': parkMax.inMilliseconds});
        return _deferred(j, const Why('parked.expired'));
      }
      await j.sleep(clock, left);
    }
    final after = clock.now().difference(t0);
    j.parked += after;
    _step(j, 'resume', Outcome.info, {'root': root.id, 'afterMs': after.inMilliseconds});
    return null;
  }

  Future<CheckResult> _runCheck(_Job j, Check c) async {
    final limit = c.timeout ?? checkTimeout;
    final cancel = Cancel();
    final done = Completer<CheckResult>();
    j.running = _Running(c, cancel, done);
    final t = clock.timer(limit, () {
      if (!done.isCompleted) {
        cancel.cancel('timeout');
        done.complete(CheckResult(c.code, Outcome.inconclusive, {'reason': 'timeout', 'afterMs': limit.inMilliseconds}));
      }
    });
    Future.sync(() => c.run(cancel)).then((r) {
      if (!done.isCompleted) done.complete(r);
    }, onError: (Object e) {
      if (!done.isCompleted) done.complete(CheckResult(c.code, Outcome.inconclusive, {'reason': 'error', 'error': '$e'}));
    });
    // the context may have moved while the check was being started
    final by = _moot(j.s, c);
    if (by != null) _abort(j, by);
    final r = await done.future;
    t.cancel();
    j.running = null;
    return r;
  }

  Verdict _verdict(_Job j, VerdictKind kind, Why? why, {Root? root, int? eventId}) => Verdict(
        kind: kind,
        key: j.s.key,
        why: why,
        trail: List.of(j.trail),
        rootId: root?.id,
        cause: kind == VerdictKind.consequence ? root?.eventId : null,
        eventId: eventId,
      );

  Verdict _deferred(_Job j, Why why) {
    note?.call('info', 'sentinel: ${j.s.key} let go: ${why.code}');
    return _verdict(j, VerdictKind.deferred, why);
  }

  Verdict _blip(_Job j, DateTime since, String by) {
    final after = clock.now().difference(since);
    _step(j, 'blip.recovered', Outcome.pass, {'afterMs': after.inMilliseconds, 'by': by});
    return _emit(j, VerdictKind.blip, Why('recovered', {'afterMs': after.inMilliseconds, 'by': by}));
  }

  Verdict _consequence(_Job j, Root root) {
    final why = Why(root.kind, {'root': root.id});
    return _emit(j, VerdictKind.consequence, why, root: root);
  }

  Verdict _confirm(_Job j, Why why, DateTime since) {
    final s = j.s;
    final root = Root(
      id: roots.nextId(s.kind),
      kind: s.kind,
      key: s.key,
      subject: s.subject,
      scope: s.scope ?? (s.subject.isEmpty ? Scope.none : Scope.of(s.subject)),
      since: since,
      session: s.session,
      level: s.level,
      trail: List.of(j.trail),
    );
    roots.add(root);
    note?.call('info', 'sentinel: root ${root.id} opened (${why.code})');
    final v = _emit(j, VerdictKind.confirmed, why, root: root);
    _relink(root);
    _pokeAll();
    _changed();
    return v;
  }

  // Writes the journal entry (when the suspicion has one) and makes the verdict.
  Verdict _emit(_Job j, VerdictKind kind, Why? why, {Root? root}) {
    final s = j.s;
    int? eventId;
    final e = s.event;
    final b = book;
    if (e != null && b != null && kind != VerdictKind.deferred) {
      final level = switch (kind) {
        VerdictKind.confirmed => e.level,
        VerdictKind.unexplained => 'warn',
        _ => 'info',
      };
      final cause = kind == VerdictKind.consequence ? root?.eventId : null;
      final pick = e.kindFor == null ? (e.cat, e.type) : e.kindFor!(kind, j.evidence);
      if (pick == null) return _verdict(j, kind, why, root: root);
      final line = e.note?.call(kind, j.evidence);
      final data = e.dataFor?.call(kind, j.evidence) ?? j.evidence;
      // the same thing again within the window: the earlier event says so (count, times) instead of a second one
      final foldId = e.foldOnto?.call(pick.$1, pick.$2, data);
      final prev = foldId == null ? null : b.byId(foldId);
      if (line != null) {
        final n = prev == null ? 0 : ((((prev['data'] as Map)['repeat'] as Map?)?['count'] as num?)?.toInt() ?? 1) + 1;
        note?.call(level, prev == null ? line : '$line (again, $n times)');
      }
      final trail = [for (final t in j.trail) t.toJson()];
      if (prev != null) {
        eventId = prev['id'] as int;
        b.repeated(eventId, data: data, level: level, verdict: kind.name, why: why?.toJson(), trail: trail, cause: cause);
      } else {
        eventId = b.add(pick.$1, pick.$2, level,
            data: data, own: e.own, bg: e.bg, link: e.link, verdict: kind.name, why: why?.toJson(), trail: trail, cause: cause);
      }
      if (root != null) {
        if (kind == VerdictKind.confirmed) {
          root.eventId = eventId;
        } else if (kind == VerdictKind.consequence) {
          if (!root.consequences.contains(eventId)) root.consequences.add(eventId);
        }
      }
    }
    return _verdict(j, kind, why, root: root, eventId: eventId);
  }

  /// Ends the loop: the suspicions under way are let go as `deferred`, the context stops moving.
  void dispose() {
    if (_closed) return;
    _closed = true;
    context.onChange = null;
    _pokeAll();
    for (final j in _queue.toList()) {
      if (!j.done.isCompleted) j.done.complete(_verdict(j, VerdictKind.deferred, const Why('sentinel.closed')));
    }
    _queue.clear();
    context.dispose();
    unawaited(_verdicts.close());
    unawaited(_changes.close());
  }
}
