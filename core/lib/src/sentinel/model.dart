/// The vocabulary of the Sentinel (docs/failures.md): what a detector reports ([Suspicion]),
/// the checks it can bring ([Check]), the steps that are written down ([TrailStep]) and what
/// comes back ([Verdict]). Codes and params only, never a ready sentence.
library;

import 'dart:async';
import 'dart:convert';

/// How one step of the trail ended. `info` = a fact noted, not a test.
enum Outcome { pass, fail, inconclusive, info }

/// One step of the trail: `{code, params, outcome, at}`.
class TrailStep {
  const TrailStep(this.code, this.outcome, this.at, [this.params = const {}]);

  final String code;
  final Outcome outcome;

  /// ms since epoch.
  final int at;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {'code': code, 'params': params, 'outcome': outcome.name, 'at': at};

  static TrailStep fromJson(Map<String, dynamic> j) => TrailStep(
        '${j['code']}',
        Outcome.values.firstWhere((o) => o.name == j['outcome'], orElse: () => Outcome.info),
        (j['at'] as num?)?.toInt() ?? 0,
        ((j['params'] as Map?) ?? const {}).cast<String, dynamic>(),
      );
}

/// The reason of a failure, as a code with its facts: `{code, params}`.
class Why {
  const Why(this.code, [this.params = const {}]);

  final String code;
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {'code': code, 'params': params};
}

/// What a check found. The [code] names the check (`probe.direct`, `svc.fetch`, …), [params] its facts.
class CheckResult {
  const CheckResult(this.code, this.outcome, [this.params = const {}]);

  final String code;
  final Outcome outcome;
  final Map<String, dynamic> params;
}

/// What a passing [Check] means.
enum CheckRole {
  /// The failed thing works now: the failure went by itself (`blip`).
  recovery,

  /// Another path / method / target works: `workaround`.
  alternative,

  /// Asks why: a failing one is the [Why] of the verdict.
  diagnostic,
}

/// Where a check (or a root) sits, top-down: a failure higher up explains everything below it.
/// network -> core (the tunnel) -> route -> dns -> destination. A DNS server sits below the route: one
/// set «via VPN» goes out through the main flow, so a dead route explains it (its root carries `route`);
/// a site resolves through a server, so a dead server explains the site. A `dns` root only stops the
/// checks that resolve through that server ([Check.resolver]).
enum Level { network, core, route, dns, destination }

/// Handed to a running [Check]: the Sentinel cancels it when the context makes it moot (the network
/// went, the core restarts, a root opened on the level it goes through) or when it times out.
/// A check that can stop early (a probe) watches [cancelled] / [done]; one that cannot is simply not awaited any more.
class Cancel {
  final _done = Completer<void>();
  String? _reason;

  bool get cancelled => _reason != null;

  /// Why: a root id, `core.<phase>`, `timeout`, `session.ended`.
  String? get reason => _reason;

  /// Completes when cancelled.
  Future<void> get done => _done.future;

  void cancel(String reason) {
    if (_reason != null) return;
    _reason = reason;
    _done.complete();
  }
}

/// An active check, run after the window. [code] is what the trail says when [run] throws or
/// takes longer than [timeout] (then the step is `inconclusive`, the check never breaks the ladder).
class Check {
  const Check(this.role, this.code, this.run, {this.timeout, this.level, this.via, this.resolver});

  const Check.recovery(String code, Future<CheckResult> Function(Cancel cancel) run, {Duration? timeout, Level? level, String? via, String? resolver})
      : this(CheckRole.recovery, code, run, timeout: timeout, level: level, via: via, resolver: resolver);
  const Check.alternative(String code, Future<CheckResult> Function(Cancel cancel) run, {Duration? timeout, Level? level, String? via, String? resolver})
      : this(CheckRole.alternative, code, run, timeout: timeout, level: level, via: via, resolver: resolver);
  const Check.diagnostic(String code, Future<CheckResult> Function(Cancel cancel) run, {Duration? timeout, Level? level, String? via, String? resolver})
      : this(CheckRole.diagnostic, code, run, timeout: timeout, level: level, via: via, resolver: resolver);

  /// A check the detector has already made (Auto re-tried the site before it told): the Sentinel only
  /// puts [result] into the trail, in its [role].
  factory Check.recorded(CheckRole role, CheckResult result) => Check(role, result.code, (_) async => result);

  final CheckRole role;
  final String code;
  final Future<CheckResult> Function(Cancel cancel) run;

  /// Null = the Sentinel's default.
  final Duration? timeout;

  /// The deepest level the check goes through; null = `destination` for a suspicion that goes through the
  /// core, `network` for one that does not ([Suspicion.viaCore]). A check whose level has an open root
  /// (`net.offline`, `core.down`, a dead route's root) is not started; one running is cancelled when it opens.
  final Level? level;

  /// The route (outbound) the check goes through: an open `route`-level root of that route blocks it.
  final String? via;

  /// The id of the DNS server the check resolves through: an open `dns`-level root of that server blocks it.
  final String? resolver;
}

/// Which later subjects a root covers: they become its consequences.
class Scope {
  const Scope._(this._all, this._match);

  /// Everything (no network, the core down).
  static const all = Scope._(true, {});

  /// Nothing but itself.
  static const none = Scope._(false, {});

  /// Subjects that hold every one of [match]'s fields (a list-valued field holds the value when it contains it).
  const Scope.of(Map<String, dynamic> match) : this._(false, match);

  final bool _all;
  final Map<String, dynamic> _match;

  bool get isAll => _all;

  bool covers(Map<String, dynamic> subject) {
    if (_all) return true;
    if (_match.isEmpty) return false;
    for (final e in _match.entries) {
      final v = subject[e.key];
      if (v == e.value) continue;
      if (v is Iterable && v.contains(e.value)) continue;
      return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => _all ? {'all': true} : {'match': _match};
}

/// The journal entry a [Suspicion] becomes when it is judged (the Sentinel writes it, with the
/// verdict, why, trail and cause; the evidence is its `data`).
class SuspicionEvent {
  const SuspicionEvent(this.cat, this.type,
      {this.level = 'warn', this.own = false, this.bg = false, this.link = true, this.note, this.kindFor, this.dataFor, this.foldOnto, this.causeFor});

  final String cat;
  final String type;

  /// The level of a `confirmed` one; the others are written as `info` (an `unexplained` one as `warn`).
  final String level;
  final bool own;
  final bool bg;
  final bool link;

  /// The raw-log line for the verdict (`kind`, the evidence): written first, so the event links to it.
  /// Null result = no line. A line of the log is prose by design; the event itself holds codes only.
  final String? Function(VerdictKind kind, Map<String, dynamic> evidence)? note;

  /// The journal entry by the verdict: `(cat, type)` instead of [cat] / [type] (a failure that is a
  /// `site/blocked` when another route opens it and a `conn/failing` when it only blipped). Null result =
  /// nothing is written for that verdict. Called at the same moment as [note] and [dataFor].
  final (String, String)? Function(VerdictKind kind, Map<String, dynamic> evidence)? kindFor;

  /// The `data` of the entry by the verdict (default: the evidence as it is).
  final Map<String, dynamic> Function(VerdictKind kind, Map<String, dynamic> evidence)? dataFor;

  /// The id of the earlier event the entry about to be written is a repeat of (`cat`, `type`, the `data`), or null =
  /// a new one. A verdict that has one says so in that event ([EventBook.repeated]: count, times, the newest
  /// verdict and trail) instead of writing another; the raw line is written either way. Nothing is dropped. The
  /// detector owns the memory of its verdicts (the site checks: a timer per site, service.dart).
  final int? Function(String cat, String type, Map<String, dynamic> data)? foldOnto;

  /// The `cause` of an entry of a verdict that is no consequence of a root of the Sentinel's (a `conn/failing` under the
  /// `site/*` of the same address, a `dns/failedOnNode` under the `dns/failed` of its server, anything in the window of a
  /// network switch under `net/switched`): the id of the earlier event, or null = none. A consequence's cause is its
  /// root's event.
  final int? Function(String cat, String type, VerdictKind kind, Map<String, dynamic> data)? causeFor;
}

/// A detector's report: "something failed, find out whether it is real".
class Suspicion {
  Suspicion({
    required this.kind,
    this.subject = const {},
    this.evidence = const {},
    this.checks = const [],
    this.window = Duration.zero,
    String? key,
    this.firstSeen,
    this.viaCore = true,
    this.why,
    this.whyLate,
    this.scope,
    this.event,
    this.session = true,
    this.level = Level.destination,
  }) : key = key ?? defaultKey(kind, subject);

  /// What failed, as a code: `conn.failing`, `tun.tcpDead`, `svc.fetch`, `site.blocked`, …
  final String kind;

  /// Who / where: `app`, `host`, `ip`, `route`, `outbound`, … Roots cover subjects by these fields.
  final Map<String, dynamic> subject;

  /// Raw facts (counts, addresses, durations). Becomes the `data` of the event; a repeat of the
  /// suspicion while it is judged lays its evidence over this one.
  final Map<String, dynamic> evidence;

  /// Run in order after the window, until one of the role `recovery` / `alternative` passes.
  final List<Check> checks;

  /// How long the failure must last. Counted from [firstSeen]; an own restart of the core inside it
  /// starts the count again at the settle.
  final Duration window;

  /// The same thing seen again has the same key (it joins the judgement under way, or the root that is open).
  final String key;

  /// When the failure was first seen (default: now). Not later than the first signs.
  final DateTime? firstSeen;

  /// Whether the failure goes through the core's sing-box: an own restart of it is then a possible cause.
  final bool viaCore;

  /// The detector's own reading of the evidence (`conn.refused`, …): without it and without a failing
  /// diagnostic the failure is `unexplained`.
  final Why? why;

  /// The detector's reading of the evidence as it stands at the end of the ladder (merged with what joined it
  /// meanwhile), asked only when nothing else says why; null result = none.
  final Why? Function(Map<String, dynamic> evidence)? whyLate;

  /// What a root made of this covers; null = its own subject exactly.
  final Scope? scope;

  /// The journal entry to write with the verdict; null = the caller writes (or nothing is written).
  final SuspicionEvent? event;

  /// The root made of this ends with the sing-box session (a stop, a new start).
  final bool session;

  /// The level of the root made of this: what it blocks (checks at its level or below that go through
  /// it; a `route` root only the checks `via` its `subject['route']`). `destination` blocks nothing.
  final Level level;

  static String defaultKey(String kind, Map<String, dynamic> subject) {
    final keys = subject.keys.toList()..sort();
    return '$kind|${jsonEncode({for (final k in keys) k: subject[k]})}';
  }
}

enum VerdictKind {
  /// Persistent, no external cause, no simple fix: a real failure (a root is open).
  confirmed,

  /// Recovered by itself inside the window.
  blip,

  /// Caused by another failure (no network, a captive portal, the core down, an open root).
  consequence,

  /// Another path / method / target works.
  workaround,

  /// Persistent but nothing says why: the journal only.
  unexplained,

  /// Our own doing (a restart under way, our own reject rule), or no core to judge by: nothing is
  /// written, never an error.
  deferred,
}

class Verdict {
  const Verdict({
    required this.kind,
    required this.key,
    this.why,
    this.trail = const [],
    this.rootId,
    this.cause,
    this.eventId,
    this.repeat = false,
  });

  final VerdictKind kind;
  final String key;
  final Why? why;
  final List<TrailStep> trail;

  /// The root this failure is (`confirmed`) or is a consequence of (`consequence`).
  final String? rootId;

  /// The id of the root's event, when it has one.
  final int? cause;

  /// The journal event the Sentinel wrote for it (a [Suspicion.event] was given).
  final int? eventId;

  /// The same failure is already a root: nothing new is written, the caller emits nothing.
  final bool repeat;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'key': key,
        if (why != null) 'why': why!.toJson(),
        'trail': [for (final t in trail) t.toJson()],
        'rootId': ?rootId,
        'cause': ?cause,
        'eventId': ?eventId,
        if (repeat) 'repeat': true,
      };
}
