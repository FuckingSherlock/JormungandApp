/// DNS failover while sing-box runs (docs/rules.md §6): sing-box has no fallback between DNS servers, so the
/// core does it, by the DNS flags (dns_flags.dart). Every DNS server of the config is a candidate
/// (routing.dart [DnsCandidate]: one transport of a provider on one side) with a flag file; the DNS rules of a
/// side try its candidates in priority order and the first whose flag is on answers. This service only
/// executes: a candidate whose root the Sentinel confirmed gets its flag off, and one whose root is closed gets
/// it on again once it has answered `failAfter` times in a row (plus the flap guard's hold if it had dropped).
/// sing-box picks the answering candidate itself, no restart, no API call; the open connections stay.
/// The sides (direct, VPN) are independent: the rules of one never look at the other's flags.
///
/// Whether a candidate is down is not decided here: the Sentinel judges it (docs/failures.md → DNS).
/// A round (every `checkEvery`, the first after `firstCheck`; after a miss the next comes after
/// `retryPause`) resolves a well-known name through each candidate alone — a real query on the
/// candidate's own path, direct or through the VPN as it is set (probe.dart `probeDns`, the probe
/// inbound) — with backup names as with the node checks. A miss is evidence for the suspicion
/// `dns.down` of that candidate (the Sentinel's window, then its checks: does it answer now; does
/// another candidate of the same path), an answer ends it (a blip, or the open root closes). A miss of the
/// last [fresh] counts as the answer to "does it answer now" (the round's own query is that ask), and the other
/// candidates of the path are not asked again when their verdict is known: dead ones by their verdict, the ones the
/// round just asked by that answer. The failover acts on the verdicts: it listens to the Sentinel's changes.
///
/// The verdicts are kept ([DnsVerdictBook], dns_verdicts.dart) per server (address + transport + side; the VPN side
/// also per exit node) and only a new check of the same object changes one: a reconnect, a change of the settings,
/// a restart of the core, a provider switched off and on keep them. A new failover starts with the flags by the stored
/// verdicts ([dnsStartFlags]) and checks the servers stored as dead at once; moving to another exit node applies the
/// verdicts of that node and checks the VPN side again ([nodeChanged]); another network checks the servers that
/// answer now ([networkChanged]). One check runs per server at a time, whoever asks.
///
/// A side whose flags are all off is answered by its top candidate (the config's last rule has no flag):
/// nothing is flipped then, a candidate that answers again turns its flag on. The candidates a rule names
/// that are not in a side's list (a provider that is off) and the OS resolver are watched the same way;
/// the former have flags too (a rule's chain of several transports follows them), the latter none.
///
/// Nothing is probed unless the probe pool's network status is `up` ([pool], pool.dart: the status Auto, the
/// fallback service and the UI's pings share; a name resolved by a local resolver proves nothing about the
/// internet, so DNS answers do not feed it) and no flag is changed by a verdict unless the network is up and
/// the core settled (the Sentinel's context). With [auto] off the checks still run (Settings → DNS shows which
/// server fails) but every flag is on; turning it on applies the verdicts at once.
///
/// A candidate with an open root (confirmed dead) is not asked by the periodic rounds: it has its own ladder,
/// 30 s → 1 min → 2 min → 5 min (then every 5 min, [recheckLadder]) from the moment the root opened; the first
/// answer closes the root and hands the candidate back to the rounds, which bring its flag on after `failAfter`
/// answers. A provider ping ([pingProvider]) is the same check, so what it shows and the colour in the list agree.
///
/// After each flag write the effective candidate of the side is asked back through the probe inbound
/// ([flagCheck], the side's flagcheck name that the DNS rules answer with no network): the delay until sing-box
/// applied the file is logged, a file it did not apply within [flagWait] is a warning.
library;

import 'dart:async';

import 'auto.dart' show AutoSettings;
import 'dns_verdicts.dart';
import 'plan.dart' show topTag;
import 'pool.dart' show NetStatus, ProbePool;
import 'probe.dart' show withCheckers;
import 'routing.dart' show DnsCandidate, DnsEntry;
import 'sentinel/sentinel.dart';
import 'watched.dart';

/// Names every ordinary resolver answers: the server works when any of them resolves.
const dnsCheckNames = ['cp.cloudflare.com', 'www.gstatic.com', 'captive.apple.com'];

/// How long a candidate with a confirmed dead verdict waits before it is asked again; the last step repeats.
const dnsRecheckLadder = [Duration(seconds: 30), Duration(minutes: 1), Duration(minutes: 2), Duration(minutes: 5)];

/// How long an answer or a miss of a round counts for the Sentinel's checks of the same server (no second ask).
const dnsFreshResult = Duration(seconds: 10);

/// The Sentinel's key of the suspicion / root of the DNS server [id].
String dnsRootKey(String id) => 'dns|$id';

/// The sides, in the order the servers are listed.
const dnsSideNames = ['direct', 'vpn'];

/// The DNS server a side answers with changed. [from] / [to] are the candidates' ids (the Sentinel's node ids),
/// [fromProvider] / [toProvider] their providers'; [reason]: `failover` (the one in use is down), `back` (a higher one
/// answers again), `node` (another exit node: its stored verdicts apply) or `off` (Switch automatically was turned
/// off: every flag is on, the top candidate answers).
class DnsSwitch {
  const DnsSwitch({
    required this.side,
    required this.from,
    required this.to,
    required this.fromProvider,
    required this.toProvider,
    required this.reason,
    required this.at,
  });

  final String side, from, to, fromProvider, toProvider, reason;
  final int at;

  Map<String, dynamic> toJson() => {
        'side': side,
        'from': from,
        'to': to,
        'fromProvider': fromProvider,
        'toProvider': toProvider,
        'reason': reason,
        'at': at,
      };
}

/// Which servers a round asks: all of them, those without an open root (the timer's), the dead ones that are due,
/// every dead one (the start).
enum _Round { all, periodic, ladder, dead }

class _Node {
  _Node(this.entry, this.c, {required this.member});

  final DnsEntry entry;

  /// The config's candidate; null for the OS resolver `system` (no flag, never switched).
  final DnsCandidate? c;

  /// In a side's list (switched between); else watched only (its flag still moves a rule's chain).
  final bool member;
  Watched w = Watched();

  /// When the current run of misses began (ms since epoch); null = it answered last.
  int? missSince;

  /// When the last probe of it ended with a miss / an answer (ms since epoch); the other is null.
  int? missAt, okAt;

  /// The one check in flight; a second ask joins it.
  Future<void>? testing;

  /// The Sentinel is judging a miss of it.
  bool suspecting = false;

  /// The flag as the core wrote it last.
  bool on = true;

  /// While its root is open: when it is asked next (ms since epoch) and the step of the ladder it is on.
  int? recheckAt;
  int recheckStep = 0;

  /// Its flag was off in the sing-box before this one (a restart) or since the stored verdicts: it returns on a single
  /// answer, the verdict that put it off is not known any more.
  bool restored = false;

  String get id => entry.id;
  String get side => c?.side ?? 'direct';
  String get provider => c?.provider ?? 'system';
  String get kind => c?.kind ?? 'system';
  bool get vpn => side == 'vpn';
  String get path => vpn ? 'proxy' : 'direct';
}

class _Side {
  _Side(this.name, this.members);

  final String name;
  final List<_Node> members;

  /// The member the config answers with now, as the flags say.
  _Node? effective;
}

class DnsFailover {
  DnsFailover({
    required Map<String, List<DnsCandidate>> sides,
    required this.setFlag,
    required this.query,
    required this.settings,
    required this.sentinel,
    this.flagCheck,
    List<DnsEntry> watch = const [],
    List<DnsCandidate> candidates = const [],
    Set<String> off = const {},
    this.window = Duration.zero,
    this.auto = true,
    this.pool,
    int Function()? clock,
    this.note,
    this.flagWait = const Duration(seconds: 3),
    this.flagPoll = const Duration(milliseconds: 60),
    this.recheckLadder = dnsRecheckLadder,
    this.fresh = dnsFreshResult,
    DnsVerdictBook? book,
    this.node,
  })  : _clock = clock ?? _wallClock,
        book = book ?? DnsVerdictBook() {
    _sides = [
      for (final name in dnsSideNames)
        _Side(name, [for (final c in sides[name] ?? const <DnsCandidate>[]) _Node(c.entry, c, member: true)]),
    ];
    final byTag = {for (final c in candidates) c.tag: c};
    final inSides = {for (final s in _sides) for (final n in s.members) n.id};
    _watch = [
      for (final e in watch)
        if (!inSides.contains(e.id)) _Node(e, byTag[e.tag], member: false),
    ];
    for (final n in _all) {
      if (n.c != null && off.contains(n.id)) {
        n.on = false;
        n.restored = true;
      }
    }
    _lastNode = node?.call();
    // the flags by the verdicts of the last time: the dead ones off, the best that worked answers
    final stored = dnsStartFlags(sides, this.book, node: _lastNode, others: [for (final n in _watch) ?n.c]);
    for (final n in _flagged) {
      if (stored[n.id] == false && n.on) {
        n.on = false;
        n.restored = true;
      }
    }
    for (final s in _sides) {
      s.effective = _pick(s);
    }
    _sub = sentinel.changes.listen((_) => unawaited(_react()));
  }

  /// Writes the flag of [c] (dns_flags.dart `setDnsFlag`, with the log line); false = not written. [reason]: `verdict`
  /// (its root is confirmed), `back` (it answers again), `node` (another exit node), `auto off`.
  final Future<bool> Function(DnsCandidate c, bool on, String reason) setFlag;

  /// ms until the DNS server [tag] resolved [name] (probe.dart `probeDns`); -1 = no answer.
  final Future<int> Function(String tag, String name, int timeoutMs) query;

  /// Whether the candidate [c] is the one the DNS rules of its side answer with now (probe.dart `probeFlag`);
  /// null = it cannot be told (no flagcheck in this sing-box).
  final Future<bool?> Function(DnsCandidate c)? flagCheck;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;

  final Sentinel sentinel;

  /// The verdicts of the servers (dns_verdicts.dart); kept by the owner across failovers.
  final DnsVerdictBook book;

  /// The exit node the VPN side is checked through now (its pool identity); null = not bound to a node.
  final String? Function()? node;

  /// How long a result of a round counts for the Sentinel's checks of the same server ([dnsFreshResult]).
  final Duration fresh;

  /// How long a server must keep missing before the Sentinel may call it down (windows.dart `dnsDown`).
  final Duration window;

  /// Settings → DNS → Switch automatically (`POST /api/dns/auto`, takes effect at once).
  bool auto;
  final ProbePool? pool;

  /// The core log: `(level, text)`.
  final void Function(String level, String line)? note;

  /// How long sing-box may take to apply a flag file, and how often it is asked meanwhile.
  final Duration flagWait, flagPoll;

  /// How long a candidate whose root is open waits before it is asked again (the last step repeats).
  final List<Duration> recheckLadder;
  final int Function() _clock;
  late final List<_Side> _sides;
  late final List<_Node> _watch;
  final _switches = StreamController<DnsSwitch>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer, _recheckTimer;
  bool _busy = false, _busyLadder = false, _started = false, _stopped = false, _again = false;
  String? _lastNode, _hintNext;

  /// The ladder's timer does not fire before this (ms since epoch): a tick found the network down or a round busy.
  int _recheckNotBefore = 0;
  Future<void>? _loop;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  Iterable<_Node> get _members => _sides.expand((s) => s.members);
  Iterable<_Node> get _all => [..._members, ..._watch];
  Iterable<_Node> get _flagged => _all.where((n) => n.c != null);
  _Side _sideOf(String name) => _sides.firstWhere((s) => s.name == name);

  /// The key of the verdict about [n] now (dns_verdicts.dart).
  String _key(_Node n) => dnsVerdictKey(n.c, n.vpn ? node?.call() : null);

  /// The id of the server that answers what goes through the VPN now (the VPN side's), else the direct side's.
  String? get active => _sideOf('vpn').effective?.id ?? _sideOf('direct').effective?.id;

  /// The id of the candidate that answers [side] now.
  String? activeOf(String side) => _sideOf(side).effective?.id;

  /// Whether lookups of the core's own (node addresses, address_resolver.dart) may ask the candidate [id]: its flag is
  /// on and no root is open. A server this config does not know is not judged: true.
  bool alive(String id) {
    final n = _all.where((x) => x.id == id).firstOrNull;
    return n == null || n.c == null || (n.on && !_down(n));
  }

  /// A lookup of the core's own (address_resolver.dart) got no answer from the candidate [id]: evidence for ITS suspicion
  /// (the server's own check decides, [_suspect]); never a verdict by itself. A server this config does not watch, and a
  /// network that is not up (the miss may be the network's), are left alone.
  void lookupMissed(String id) {
    final n = _all.where((x) => x.id == id && x.c != null).firstOrNull;
    if (n == null || _stopped || !_online) return;
    _suspect(n, from: _clock());
  }

  bool get isEmpty => _members.isEmpty;

  /// Every candidate's flag as the core wrote it (id → on): what a restarted sing-box is given again.
  Map<String, bool> get flags => {for (final n in _flagged) n.id: n.on};

  Stream<DnsSwitch> get switches => _switches.stream;

  void start() {
    _started = true;
    _schedule(settings.firstCheck);
    unawaited(_verifyAll('start'));
    if (_all.any(_down)) unawaited(_round(_Round.dead)); // stored as dead: checked at once, not after `firstCheck`
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _recheckTimer?.cancel();
    unawaited(_sub?.cancel());
    _switches.close();
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_started && !_stopped) _timer = Timer(d, () => unawaited(_round(_Round.periodic)));
  }

  // ── the ladder of the dead ──

  // A candidate is parked while its root is open: the periodic rounds leave it alone, the ladder asks it.
  bool _due(_Node n, int now) => n.recheckAt != null && n.recheckAt! <= now;

  // Gives a candidate that just got its root a place on the ladder, takes it off when the root closed, and sets the
  // timer for the earliest one due.
  void _syncPark() {
    if (_stopped) return;
    final now = _clock();
    for (final n in _all) {
      if (_down(n)) {
        n.recheckAt ??= now + recheckLadder.first.inMilliseconds;
      } else if (n.recheckAt != null) {
        n.recheckAt = null;
        n.recheckStep = 0;
      }
    }
    _recheckTimer?.cancel();
    _recheckTimer = null;
    if (!_started) return;
    final next = _all.map((n) => n.recheckAt).whereType<int>().fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (next == null) return;
    final wait = (next > _recheckNotBefore ? next : _recheckNotBefore) - now;
    _recheckTimer = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () => unawaited(checkDue()));
  }

  // A parked candidate was asked: the next step of the ladder, or off it when it answered.
  void _stepped(_Node n, int now, {bool advance = true}) {
    if (!_down(n)) {
      n.recheckAt = null;
      n.recheckStep = 0;
      return;
    }
    if (advance && n.recheckStep + 1 < recheckLadder.length) n.recheckStep++;
    n.recheckAt = now + recheckLadder[n.recheckStep].inMilliseconds;
  }

  bool get _online => (pool == null || pool!.status == NetStatus.up) && sentinel.context.network.state == NetState.up;

  void _note(String level, String line) => note?.call(level, line);

  /// Turning it off puts every flag on at once (the top candidate of a side answers); turning it on applies the
  /// verdicts at once.
  Future<void> setAuto(bool on) async {
    if (auto == on) return;
    auto = on;
    _note('info', 'dns: switch automatically ${on ? 'on: the verdicts apply' : 'off: every flag on'}');
    if (_stopped) return;
    await _react();
  }

  /// A live traffic check (a site resolved through [id] did not) says the server misses: the same suspicion
  /// as a failed round of its own. False when [id] is not a server of this config.
  bool suspectServer(String id) {
    final s = _all.where((x) => x.id == id).firstOrNull;
    if (s == null || _stopped) return false;
    s.missSince ??= _clock();
    _suspect(s);
    return true;
  }

  /// One round over every server, the dead ones too: test them, hand the misses to the Sentinel, then set the flags by
  /// the verdicts. The timer's rounds skip the candidates with an open root (the ladder asks those, [checkDue]).
  Future<void> check() => _round(_Round.all);

  /// The ladder's tick: asks the dead candidates whose time has come (30 s, 1 min, 2 min, then every 5 min after
  /// their root opened); an answer closes the root. Nothing while the network is not up.
  Future<void> checkDue() => _round(_Round.ladder);

  /// The exit node of the VPN side changed (Auto moved, Manual): the verdicts of the new node apply at once (the dead
  /// ones off, the best that worked answers) and the VPN side is checked again; the verdicts of the old node stay.
  Future<void> nodeChanged() async {
    final cur = node?.call();
    if (_stopped || node == null || cur == _lastNode) return;
    _lastNode = cur;
    final vpn = [for (final n in _flagged) if (n.vpn) n];
    if (vpn.isEmpty) return;
    for (final n in vpn) {
      sentinel.closeRoot(dnsRootKey(n.id), reason: 'node'); // the root was about the other node
      n.w = Watched();
      n.missSince = n.missAt = n.okAt = null;
    }
    final members = [for (final n in vpn) if (n.member) n.c!];
    final stored = dnsStartFlags({'vpn': members}, book, node: cur, others: [for (final n in vpn) if (!n.member) n.c!]);
    if (auto && _ready) {
      for (final n in vpn) {
        final want = stored[n.id];
        if (want != null && want != n.on && await _flag(n, want, 'node', strike: false)) n.restored = !want;
      }
    }
    _note('info', 'dns: exit node changed: the verdicts of the new node apply, the VPN side is checked');
    _hintNext = 'node';
    await _react();
    unawaited(_checkNodes(vpn));
  }

  /// Another network: the servers that answer now (each side's effective one) are asked at once; the dead ones keep
  /// their verdict until their own re-check.
  Future<void> networkChanged() async {
    if (_stopped || !_started) return;
    final active = {for (final s in _sides) ?s.effective}.toList();
    if (active.isEmpty) return;
    if (!_online) {
      _note('debug', 'dns: network changed, not checked: the network is not up (the rounds will)');
      return;
    }
    _note('info', 'dns: network changed: checking ${active.map((n) => n.id).join(', ')}');
    await _checkNodes(active);
  }

  Future<void> _checkNodes(List<_Node> list) async {
    if (list.isEmpty || _stopped || !_online) return;
    await Future.wait(list.map(_test));
    if (_stopped) return;
    _judge(list);
    await _react();
    _syncPark();
  }

  Future<void> _round(_Round kind) async {
    final ladder = kind == _Round.ladder || kind == _Round.dead;
    if (_stopped) return;
    if (ladder ? _busyLadder : _busy) {
      if (ladder) {
        _recheckNotBefore = _clock() + 1000;
        _syncPark();
      }
      return;
    }
    if (ladder) {
      _busyLadder = true;
    } else {
      _busy = true;
    }
    try {
      if (!_online) {
        if (ladder) _recheckNotBefore = _clock() + 10000;
        return;
      }
      if (!ladder && node != null && node!() != _lastNode) await nodeChanged();
      final now = _clock();
      final list = [
        for (final n in _all)
          if (switch (kind) { _Round.all => true, _Round.periodic => !_down(n), _Round.ladder => _down(n) && _due(n, now), _Round.dead => _down(n) }) n,
      ];
      if (list.isEmpty && ladder) return;
      final parked = [for (final n in list) if (_down(n)) n];
      await Future.wait(list.map(_test));
      if (_stopped) return;
      _judge(list);
      for (final n in parked) {
        _stepped(n, now, advance: kind == _Round.ladder);
      }
      await _react();
      if (!ladder) _summary();
    } finally {
      if (ladder) {
        _busyLadder = false;
      } else {
        _busy = false;
        final retry = _sides.any((s) {
          final a = s.effective;
          return a != null && a.missSince != null && !_down(a);
        });
        _schedule(retry ? settings.retryPause : settings.checkEvery);
      }
      _syncPark();
    }
  }

  // The answers close the roots and make the verdict, the misses are evidence for the Sentinel.
  void _judge(Iterable<_Node> list) {
    for (final s in list) {
      if (s.w.health.answered) {
        s.missSince = null;
        sentinel.recovered(dnsRootKey(s.id), reason: 'dns.answers');
        book.record(_key(s), dead: false, at: _clock());
      } else if (s.w.health.ms == -1) {
        _suspect(s);
      }
    }
  }

  /// The latency of every candidate of [provider] in this config, on both sides, by the very check the rounds
  /// make (the probe inbound, the candidate's own path, the check names in turn): `(id, side, kind, ms)`, -1 =
  /// no answer. Empty when the config has no such provider. While the network is up the answers count as a round's:
  /// an answer closes a dead candidate's root, a miss is evidence like any other (so the list's colour and the ping
  /// agree, and a provider just switched on is checked at once); otherwise it only measures.
  Future<List<({String id, String side, String kind, int ms})>> pingProvider(String provider) async {
    final nodes = [for (final n in _all) if (n.c != null && n.provider == provider) n];
    if (nodes.isEmpty || _stopped) return const [];
    if (_online) {
      final now = _clock();
      final parked = [for (final n in nodes) if (_down(n)) n];
      await Future.wait(nodes.map(_test));
      if (!_stopped) {
        _judge(nodes);
        for (final n in parked) {
          _stepped(n, now, advance: false); // asked just now: the next one counts from here, the step stays
        }
        await _react();
        _syncPark();
      }
      return [for (final n in nodes) (id: n.id, side: n.side, kind: n.kind, ms: n.w.health.ms)];
    }
    final ms = await Future.wait(nodes.map((n) => _ask(n, null)));
    return [for (var i = 0; i < nodes.length; i++) (id: nodes[i].id, side: nodes[i].side, kind: nodes[i].kind, ms: ms[i])];
  }

  // One check per server at a time: a second ask joins the one in flight.
  Future<void> _test(_Node s) => s.testing ??= _testOnce(s).whenComplete(() => s.testing = null);

  Future<void> _testOnce(_Node s) async {
    final ms = await _ask(s, null);
    if (_stopped) return;
    final now = _clock();
    s.w.health.record(ms, now);
    if (ms < 0) {
      s.missSince ??= now;
      s.missAt = now;
      s.okAt = null;
    } else {
      s.missSince = null;
      s.missAt = null;
      s.okAt = now;
    }
    if (s.on) s.w.forgetIfStable(settings, now);
  }

  // The names are tried in turn (backup names as with the node checks); [cancel] ends the wait at once.
  Future<int> _ask(_Node s, Cancel? cancel) {
    final q = withCheckers((name) => query(s.entry.tag, name, settings.timeoutMs), dnsCheckNames.first, dnsCheckNames);
    return cancel == null ? q : Future.any([q, cancel.done.then((_) => -1)]);
  }

  // Whether [at] (ms since epoch) is recent enough to stand for a new ask.
  bool _fresh(int? at) => at != null && _clock() - at <= fresh.inMilliseconds;

  // The server is dead: its root is open and no wider failure explains it, or the last check of it said so (the book).
  // A root that opened after the last answer makes the verdict; an answer after it unmakes it.
  bool _down(_Node s) {
    final key = _key(s), r = sentinel.roots.byKey(dnsRootKey(s.id)), v = book[key];
    if (r != null && r.parent == null && (v == null || v.dead || r.since.millisecondsSinceEpoch >= v.at)) {
      if (v == null || !v.dead) book.record(key, dead: true, at: r.since.millisecondsSinceEpoch);
      return true;
    }
    return v?.dead == true;
  }

  /// The other transports of the same provider on the same side.
  List<_Node> _siblings(_Node s) => [
        for (final o in _all)
          if (!identical(o, s) && o.c != null && s.c != null && o.provider == s.provider && o.side == s.side) o,
      ];

  void _suspect(_Node s, {int? from}) {
    final key = dnsRootKey(s.id);
    if (sentinel.roots.byKey(key) != null) return;
    if (book[_key(s)]?.dead == true) {
      // Dead already (stored, a reconnect or a restart did not forget it): a miss re-checks it and the verdict stands, so
      // there is nothing to judge and no new event. Only an answer changes it.
      book.record(_key(s), dead: true, at: _clock());
      return;
    }
    final since = from ?? s.missSince ?? _clock();
    final others = _all.where((o) => !identical(o, s) && o.vpn == s.vpn).toList();
    final via = s.vpn ? topTag : null;
    s.suspecting = true;
    unawaited(sentinel
        .suspect(Suspicion(
          kind: 'dns.down',
          key: key,
          subject: {'dns': s.id, 'path': s.path, if (s.vpn) 'route': topTag},
          scope: Scope.of({'dns': s.id}),
          level: Level.dns,
          evidence: {'server': s.id, 'path': s.path, 'since': since},
          window: window,
          firstSeen: DateTime.fromMillisecondsSinceEpoch(since),
          why: Why('dns.down', {'server': s.id, 'path': s.path}),
          checks: [
            // it answers now: a blip. A miss of the round just made is that ask: the server is not asked a second time.
            Check.recovery('dns.answers', (cancel) async {
              if (_fresh(s.missAt)) {
                return CheckResult('dns.answers', Outcome.fail, {'server': s.id, 'fresh': true, 'ageMs': _clock() - s.missAt!});
              }
              final ms = await _ask(s, cancel);
              return CheckResult('dns.answers', ms >= 0 ? Outcome.pass : Outcome.fail, {'server': s.id});
            }, timeout: const Duration(seconds: 20), level: Level.dns, via: via, resolver: s.id),
            // another server of the same path answers: it is this server, not the path. The ones known dead are not
            // asked (their verdict stands), nor the ones a round has just asked (their result stands).
            if (others.isNotEmpty)
              Check.diagnostic('dns.path', (cancel) async {
                final answering = <String>[], dead = <String>[], ask = <_Node>[];
                for (final o in others) {
                  if (_down(o)) {
                    dead.add(o.id);
                  } else if (_fresh(o.okAt)) {
                    answering.add(o.id);
                  } else if (!_fresh(o.missAt)) {
                    ask.add(o);
                  }
                }
                final asked = await Future.wait(ask.map((o) => _ask(o, cancel)));
                if (cancel.cancelled) return const CheckResult('dns.path', Outcome.inconclusive, {'reason': 'aborted'});
                for (var i = 0; i < ask.length; i++) {
                  if (asked[i] >= 0) answering.add(ask[i].id);
                }
                return CheckResult('dns.path', answering.isNotEmpty ? Outcome.pass : Outcome.fail,
                    {'path': s.path, 'answering': answering, if (dead.isNotEmpty) 'dead': dead});
              }, timeout: const Duration(seconds: 20), level: Level.dns, via: via),
          ],
          // The event is per provider and side: a transport that is down while another transport of its provider
          // answers is a line in the log, not an entry in the journal (the provider works).
          event: SuspicionEvent('dns', 'failed',
              level: 'warn',
              kindFor: (kind, e) {
                if (kind != VerdictKind.confirmed) return null;
                final alive = _siblings(s).where((o) => !_down(o)).toList();
                if (alive.isNotEmpty) {
                  _note('info', 'dns: ${s.id} (${s.provider}, ${s.side}) does not answer, its provider still does through ${alive.map((o) => o.id).join(', ')}: not an event');
                  return null;
                }
                return ('dns', 'failed');
              },
              dataFor: (kind, e) => {
                    'server': e['server'],
                    'path': e['path'],
                    'since': e['since'],
                    'provider': s.provider,
                    'side': s.side,
                    'servers': [s.id, for (final o in _siblings(s)) o.id],
                  },
              note: (kind, e) => 'DNS server ${e['server']} (${e['path'] == 'proxy' ? 'via VPN' : 'direct'}) does not answer'),
        ))
        .whenComplete(() => s.suspecting = false));
  }

  // The Sentinel's context moved (a root opened or closed, the network, the core), or a round ended.
  // One decision at a time; a trigger that comes while one is under way makes it look again and waits for it.
  Future<void> _react() {
    if (_stopped) return Future.value();
    final running = _loop;
    if (running != null) {
      _again = true;
      return running;
    }
    return _loop = _decideLoop().whenComplete(() => _loop = null);
  }

  Future<void> _decideLoop() async {
    do {
      _again = false;
      await _decide();
    } while (_again && !_stopped);
  }

  bool get _ready => sentinel.context.network.state == NetState.up && sentinel.context.settled;

  /// The member of [s] the DNS rules answer with: the first whose flag is on, the top one when none is.
  _Node? _pick(_Side s) => s.members.where((n) => n.on).firstOrNull ?? s.members.firstOrNull;

  bool _mayReturn(_Node n, int now) => n.restored ? n.w.health.answered : n.w.mayReturn(settings, now);

  Future<void> _decide() async {
    if (_stopped) return;
    _syncPark();
    final wrote = <String>{}, dropped = <String>{};
    String? hint = _hintNext;
    _hintNext = null;
    if (!auto) {
      for (final n in _flagged.where((n) => !n.on).toList()) {
        if (await _flag(n, true, 'auto off')) wrote.add(n.side);
      }
      hint = 'off';
    } else if (_ready) {
      final now = _clock();
      for (final n in _flagged.toList()) {
        if (_stopped) return;
        if (n.on && _down(n)) {
          if (await _flag(n, false, 'verdict')) {
            wrote.add(n.side);
            dropped.add(n.side);
          }
        } else if (!n.on && !_down(n) && _mayReturn(n, now)) {
          if (await _flag(n, true, 'back')) wrote.add(n.side);
        }
      }
    }
    for (final s in _sides) {
      if (_stopped) return;
      final was = s.effective, now = _pick(s);
      s.effective = now;
      if (wrote.contains(s.name) && now != null) await _verify(s, 'after a flag write');
      if (was == null || now == null || identical(was, now)) continue;
      // `failover`: a flag went off on this side in this pass; `back`: a flag came on again (or the side's state
      // changed without a verdict); `node`: another exit node's verdicts; `off`: automatic switching was turned off.
      final reason = hint ?? (dropped.contains(s.name) ? 'failover' : 'back');
      _note('info', 'dns ${s.name}: ${was.id} → ${now.id} ($reason)');
      if (!_switches.isClosed) {
        _switches.add(DnsSwitch(
          side: s.name,
          from: was.id,
          to: now.id,
          fromProvider: was.provider,
          toProvider: now.provider,
          reason: reason,
          at: _clock(),
        ));
      }
    }
  }

  Future<bool> _flag(_Node n, bool on, String reason, {bool strike = true}) async {
    final c = n.c;
    if (c == null || _stopped) return false;
    bool ok;
    try {
      ok = await setFlag(c, on, reason);
    } catch (e) {
      _note('error', 'dns flag: ${n.id}: $e');
      ok = false;
    }
    if (!ok) {
      _note('warn', 'dns flag: ${n.id} stays ${n.on ? 'on' : 'off'} ($reason): the write failed');
      return false;
    }
    n.on = on;
    n.restored = false;
    if (on) {
      n.w.usedSince = _clock();
    } else if (strike) {
      n.w.struck();
    }
    return true;
  }

  /// Asks sing-box which candidate answers [s] until it is the one the flags say (the file is applied), and
  /// tells how long it took; a warning when it did not within [flagWait].
  Future<void> _verify(_Side s, String why) async {
    final want = s.effective;
    final check = flagCheck;
    if (want == null || want.c == null || check == null) return;
    if (s.members.length < 2) return; // one candidate: the config has no flag rule to look at
    final t = Stopwatch()..start();
    while (!_stopped) {
      final r = await check(want.c!);
      if (r == null) {
        _note('debug', 'dns flag check (${s.name}): cannot be told, this sing-box has no flagcheck');
        return;
      }
      if (r) {
        _note('info', 'dns flag check (${s.name}): ${want.id} answers after ${t.elapsedMilliseconds} ms ($why)');
        return;
      }
      if (t.elapsed >= flagWait) {
        String? got;
        for (final m in s.members) {
          if (!identical(m, want) && await check(m.c!) == true) {
            got = m.id;
            break;
          }
        }
        _note('warn',
            'dns flag not applied after ${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)} s (${s.name}): expected ${want.id}, ${got == null ? 'no candidate answers the flagcheck' : '$got answers'} ($why)');
        return;
      }
      await Future<void>.delayed(flagPoll);
    }
  }

  Future<void> _verifyAll(String why) async {
    for (final s in _sides) {
      if (_stopped) return;
      await _verify(s, why);
    }
  }

  /// One line per side per round for the log: who answers, who is live, who is dead.
  void _summary() {
    for (final s in _sides) {
      if (s.members.isEmpty) continue;
      String ms(_Node n) => n.w.health.ms >= 0 ? '${n.id} ${n.w.health.ms} ms' : n.id;
      final live = [for (final n in s.members) if (n.on) ms(n)];
      String next(_Node n) => n.recheckAt == null ? '' : ', asked again in ${((n.recheckAt! - _clock()) / 1000).ceil().clamp(0, 86400)} s';
      final off = [for (final n in s.members) if (!n.on) '${n.id}${_down(n) ? ' (down${next(n)})' : n.w.health.answered ? ' (answers, returning)' : ''}'];
      _note('debug', 'dns ${s.name}: answers ${s.effective?.id}; flags on [${live.join(', ')}]; off [${off.join(', ')}]');
    }
  }

  /// `{active, auto, sides: {direct: {active, provider}, vpn: {...}}, servers: [...]}`. `active`: the id of the
  /// server that answers what goes through the VPN (the direct side's when the VPN side has none); `sides`: the
  /// candidate and the provider that answer each side now. `servers`, the direct side's in priority order, then
  /// the VPN side's, then the watched-only ones with `watched: true` (a rule's own, the OS resolver `system`):
  /// `ok`: the verdict, false = dead (an open root or the last check said so), true = answers, null = never checked
  /// (a server without a verdict falls back to its last probe); `rechecking`: a check of it is under way (the verdict
  /// shown is the old one until it ends); `ms`: the last result, -1 = no answer, -2 = not tested; `provider`, `side`,
  /// `kind` (doh / dot / doq / udp / system); `flag`: the DNS flag as written (the watched `system` has none).
  Map<String, dynamic> toJson() => {
        'active': active,
        'auto': auto,
        'sides': {
          for (final s in _sides) s.name: {'active': s.effective?.id, 'provider': s.effective?.provider},
        },
        'servers': [
          for (final s in _members) _json(s),
          for (final s in _watch) {..._json(s), 'watched': true},
        ],
      };

  Map<String, dynamic> _json(_Node s) {
    final dead = _down(s), known = book[_key(s)] != null;
    return {
      'id': s.id,
      'ok': dead ? false : known ? true : (s.w.health.ms == -2 ? null : s.w.health.answered),
      'rechecking': s.testing != null || s.suspecting,
      'ms': s.w.health.ms,
      'provider': s.provider,
      'side': s.side,
      'kind': s.kind,
      if (s.c != null) 'flag': s.on,
    };
  }
}
