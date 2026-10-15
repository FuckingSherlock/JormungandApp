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

/// How long a dead server of the VPN side (either kind: dead on this exit node only, or dead everywhere) waits before it is
/// asked again: a fixed interval, not the ladder (docs/failures.md → DNS на ноде).
const dnsVpnRecheck = Duration(minutes: 20);

/// How long an answer or a miss of a round counts for the Sentinel's checks of the same server (no second ask).
const dnsFreshResult = Duration(seconds: 10);

/// The Sentinel's key of the suspicion / root of the DNS server [id].
String dnsRootKey(String id) => 'dns|$id';

/// The sides, in the order the servers are listed.
const dnsSideNames = ['direct', 'vpn'];

/// The DNS server a side answers with changed. [from] / [to] are the candidates' ids (the Sentinel's node ids),
/// [fromProvider] / [toProvider] their providers'; [reason]: `failover` (the one in use is down, also the protocol the
/// race picks after the winner failed), `back` (a higher one answers again), `node` (another exit node: its stored
/// verdicts apply) or `off` (Switch automatically was turned off: every flag is on, the top candidate answers). The winner
/// of a protocol race at the start, on another network or on another exit node is an ordinary choice, not a switch: no
/// [DnsSwitch] (the raw log has the race's line with every transport's result).
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

/// The (category, type) of a DNS verdict's event, written so that the catalog test (event_catalog_test.dart) can read it.
(String, String) _dnsKind(String cat, String type) => (cat, type);

/// What the VPN side's check needs to ask the same server through another exit node (docs/failures.md → DNS на ноде).
class DnsNodes {
  const DnsNodes({required this.spare, required this.exitKey, required this.exitAlive, required this.ask});

  /// A node known to work that is not the exit node in use: `key` (its server key, `<subscription>::<node>`) and the
  /// outbound `tag` a request is pinned to; null = none.
  final ({String key, String tag})? Function() spare;

  /// The server key of the exit node in use; null = not known.
  final String? Function() exitKey;

  /// Whether the exit node in use carries traffic at all (Auto's own test of it); null = not known.
  final Future<bool?> Function() exitAlive;

  /// ms until the candidate answered a query for [name] sent through the node pinned by [tag]; -1 = no answer; null = this
  /// transport cannot be asked that way (a silence over the fallback transport proves nothing).
  final Future<int?> Function(DnsCandidate c, String tag, String name, int timeoutMs) ask;
}

/// What the check of one VPN-side miss found out (shared by its checks and the event it writes).
class _Finding {
  /// `node`: it answered through another node (dead on this one only); `server`: silent through the other one too, or no
  /// other node could be asked.
  String kind = 'server';
  bool nodeSilent = false;
  String? via, exit;
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

  /// A ping's measure while the network is not up (it only measures, nothing is recorded); [measured] is its last answer.
  Future<void>? measuring;
  int? measured;

  /// The Sentinel is judging a miss of it.
  bool suspecting = false;

  /// The flag as the core wrote it last.
  bool on = true;

  /// Its flag went off on a miss, before the Sentinel's verdict (the traffic moves at once); the flap guard's strike is
  /// counted when the verdict comes.
  bool missDropped = false;

  /// The last check of its miss found it dead on this exit node only ([DnsVerdict.node]).
  bool pairDead = false;

  /// The last check of its miss found it silent through another node too: the server itself is dead ([dnsServerKey]).
  bool serverDead = false;

  /// While its root is open: when it is asked next (ms since epoch) and the step of the ladder it is on.
  int? recheckAt;
  int recheckStep = 0;

  /// Its flag was off in the sing-box before this one (a restart) or since the stored verdicts: it returns on a single
  /// answer, the verdict that put it off is not known any more.
  bool restored = false;

  /// The provider's transports on its side this one belongs to (a member of a side only).
  _Group? group;

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

/// The transports of one provider on one side, in the provider's own order: they take part in the protocol race
/// (docs/rules.md §6 → Гонка протоколов). Of the group only [winner] has its flag on once the group has raced; the others
/// are in reserve (flag off, not dead) until the winner fails or a new race is owed.
class _Group {
  _Group(this.side, this.provider, this.members);

  final String side, provider;
  final List<_Node> members;

  /// The member put to work (chosen, its flag follows in the next decision); null = none answers fit to be.
  _Node? winner;

  /// A race has settled the group at least once: the winner (or its absence) is decided by it, not by the flags'
  /// priority order. The VPN side's groups lose it when the exit node changes.
  bool raced = false;

  /// The winner was just chosen by a race and its flags are not written yet; [freshWhy] is the race's cause (`failure`: the
  /// winner before it failed, so the move is a `failover`).
  bool fresh = false;
  String? freshWhy;

  /// Why a race is owed (`start`, `network`, `node`, `failure`); run once the network is up.
  String? owed;

  /// The race in flight (one per group at a time).
  Future<void>? racing;

  /// A group of one has nothing to choose between.
  bool get multi => members.length > 1;

  /// The winner is chosen by the race (not by the order of the flags).
  bool get holds => multi && (raced || racing != null);
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
    Set<String> reserve = const {},
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
    this.nodes,
    this.vpnRecheck = dnsVpnRecheck,
  })  : _clock = clock ?? _wallClock,
        book = book ?? DnsVerdictBook() {
    _sides = [
      for (final name in dnsSideNames)
        _Side(name, [for (final c in sides[name] ?? const <DnsCandidate>[]) _Node(c.entry, c, member: true)]),
    ];
    _groups = [
      for (final s in _sides)
        for (final p in {for (final n in s.members) n.provider})
          _Group(s.name, p, [for (final n in s.members) if (n.provider == p) n]),
    ];
    for (final g in _groups) {
      for (final n in g.members) {
        n.group = g;
      }
    }
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
    // a reserve (a working transport another of its provider's replaced) is off but not dead: it is not "restored", it
    // stays the ready fallback of its provider's winner, which is the one of the group still on
    for (final n in _members) {
      if (reserve.contains(n.id)) {
        n.on = false;
        n.restored = false;
      }
    }
    final stored = dnsStartFlags(sides, this.book, node: _lastNode, others: [for (final n in _watch) ?n.c], reserve: reserve);
    for (final n in _flagged) {
      if (stored[n.id] == false && n.on) {
        n.on = false;
        n.restored = true;
      }
    }
    for (final g in _groups) {
      if (g.multi && g.members.any((n) => reserve.contains(n.id))) {
        g.raced = true;
        g.winner = g.members.where((n) => n.on).firstOrNull;
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

  /// Asking the same server through another exit node ([DnsNodes]); null = the VPN side's misses are judged without it.
  final DnsNodes? nodes;

  /// How long a dead server of the VPN side waits before it is asked again ([dnsVpnRecheck]); the direct side has
  /// [recheckLadder].
  final Duration vpnRecheck;

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
  late final List<_Group> _groups;
  late final List<_Node> _watch;
  final _switches = StreamController<DnsSwitch>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer, _recheckTimer;
  bool _busy = false, _busyLadder = false, _started = false, _stopped = false, _again = false, _writeFailed = false;
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
  /// on (or it is a reserve: working, only another transport of its provider is at work) and no root is open. A server
  /// this config does not know is not judged: true.
  bool alive(String id) {
    final n = _all.where((x) => x.id == id).firstOrNull;
    return n == null || n.c == null || ((n.on || _reserved(n)) && !_down(n));
  }

  // A transport that is off only because another one of its provider's is at work: not dead, not silent, not dropped for a miss.
  bool _reserved(_Node n) {
    final g = n.group;
    return g != null && g.holds && g.winner != null && !identical(g.winner, n) && !n.on && !n.missDropped && n.w.health.ms != -1 && !_down(n);
  }

  /// The ids of the transports in reserve (see [_reserved]): kept with [flags] across a restart of sing-box, where they are
  /// the ready fallback of their provider's winner, not transports that are off.
  Set<String> get reserve => {for (final n in _members) if (_reserved(n)) n.id};

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
    unawaited(_owe('start', _groups));
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
        n.recheckAt ??= now + _recheckIn(n).inMilliseconds;
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
    if (advance && !n.vpn && n.recheckStep + 1 < recheckLadder.length) n.recheckStep++;
    n.recheckAt = now + _recheckIn(n).inMilliseconds;
  }

  // The VPN side's dead (either kind) are asked at a fixed interval, the direct side's on the ladder.
  Duration _recheckIn(_Node n) => n.vpn ? vpnRecheck : recheckLadder[n.recheckStep];

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
    // the winners of the old node mean nothing on the new one: the flags go by the stored verdicts until the race
    final raced = _groups.where((g) => g.side == 'vpn' && g.multi).toList();
    for (final g in raced) {
      g.raced = false;
      g.winner = null;
    }
    if (auto && _ready) {
      for (final n in vpn) {
        final want = stored[n.id];
        if (want != null && want != n.on && await _flag(n, want, 'node', strike: false)) n.restored = !want;
      }
    }
    _note('info', 'dns: exit node changed: the verdicts of the new node apply, the VPN side is checked');
    _hintNext = 'node';
    unawaited(_owe('node', raced));
    await _react();
    unawaited(_checkNodes([for (final n in vpn) if (!(n.group?.multi ?? false)) n]));
  }

  // A race is owed to [groups] (a group of one has nothing to choose between); run at once when the network is up, else by the
  // next round.
  Future<void> _owe(String why, Iterable<_Group> groups) {
    for (final g in groups) {
      if (g.multi) g.owed = why;
    }
    return _raceOwed();
  }

  /// Another network: the servers that answer now (each side's effective one) are asked at once; the dead ones keep
  /// their verdict until their own re-check.
  Future<void> networkChanged() async {
    if (_stopped || !_started) return;
    final active = {for (final s in _sides) ?s.effective}.toList();
    if (active.isEmpty) return;
    // the providers with several transports race again (their winner is the one that answers first on this network); the
    // others are asked as before: the server in use
    final race = _owe('network', _groups);
    final single = [for (final n in active) if (!(n.group?.multi ?? false)) n];
    if (!_online) {
      _note('debug', 'dns: network changed, not checked: the network is not up (the rounds will)');
      return;
    }
    _note('info', 'dns: network changed: checking ${active.map((n) => n.id).join(', ')}');
    await Future.wait([_checkNodes(single), race]);
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
      unawaited(_raceOwed()); // a race owed while the network was down
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
        // a miss not yet judged is asked again soon, wherever the traffic went meanwhile
        final retry = _writeFailed || _members.any((n) => n.missSince != null && !_down(n) && (n.on || n.missDropped));
        _writeFailed = false;
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
        final sk = dnsServerKey(s.c);
        if (sk != null && book[sk]?.dead == true) book.record(sk, dead: false, at: _clock()); // answers: not dead everywhere
      } else if (s.w.health.ms == -1) {
        _suspect(s);
      }
    }
  }

  // ── the protocol race (docs/rules.md §6 → Гонка протоколов) ──

  // Plain UDP: wins only when every encrypted transport of its provider is silent.
  bool _plain(_Node n) => n.kind == 'udp';

  // No answer at its last check, or dead.
  bool _silent(_Node n) => _down(n) || n.w.health.ms == -1;

  // Fit to be its group's winner: it answered at its last check and is not dead; one that dropped out of use before (a miss, a
  // verdict) only on the flap guard's terms ([_mayReturn]), so a blip of the winner does not bring it back at once.
  bool _fit(_Node n, int now) {
    if (n.w.health.ms < 0 || _down(n)) return false;
    return n.on || (!n.missDropped && n.w.strikes == 0) || _mayReturn(n, now);
  }

  // The best transport of [g] by what is known now (the fastest at the last check): an encrypted one when any is fit, plain
  // UDP only when every encrypted one is silent. Null = none.
  _Node? _best(_Group g, int now) {
    final enc = [for (final n in g.members) if (!_plain(n)) n];
    var pool = [for (final n in enc) if (_fit(n, now)) n];
    if (pool.isEmpty && enc.every(_silent)) pool = [for (final n in g.members) if (_plain(n) && _fit(n, now)) n];
    if (pool.isEmpty) return null;
    return pool.reduce((a, b) => b.w.health.ms < a.w.health.ms ? b : a);
  }

  // Runs the races that are owed, if the network is up (else they wait for the next round / event).
  Future<void> _raceOwed() async {
    if (_stopped || !_started || !_online) return;
    await Future.wait([for (final g in _groups) if (g.owed != null) _race(g)]);
  }

  // One race per group at a time; a race owed meanwhile runs after it.
  Future<void> _race(_Group g) => g.racing ??= _raceOnce(g).whenComplete(() {
        g.racing = null;
        if (g.owed != null && !_stopped && _started && _online) unawaited(_race(g));
      });

  /// All transports of the group are asked at once, each by the very check the rounds make; the first encrypted one that
  /// answers is the winner, plain UDP only when every encrypted one is silent. The winner is put to work at once (its flag,
  /// [_decide]); the others' results are still collected for the status and the verdicts. A dead transport is not asked
  /// (its ladder is).
  Future<void> _raceOnce(_Group g) async {
    final why = g.owed ?? 'start';
    g.owed = null;
    if (_stopped || !_online) {
      g.owed = why;
      return;
    }
    final list = [for (final n in g.members) if (!_down(n)) n];
    final encWin = Completer<_Node?>(), plainWin = Completer<_Node?>();
    var encLeft = list.where((n) => !_plain(n)).length, plainLeft = list.where(_plain).length;
    if (encLeft == 0) encWin.complete(null);
    if (plainLeft == 0) plainWin.complete(null);
    _note('info', 'dns race (${g.provider}, ${g.side}; $why): asking ${[for (final n in list) n.id].join(', ')}');
    void ended(_Node n) {
      if (_stopped) {
        for (final c in [encWin, plainWin]) {
          if (!c.isCompleted) c.complete(null);
        }
        return;
      }
      _judge([n]);
      final plain = _plain(n), win = plain ? plainWin : encWin, left = plain ? --plainLeft : --encLeft;
      if (win.isCompleted) return;
      if (_fit(n, _clock())) {
        win.complete(n);
      } else if (left == 0) {
        win.complete(null);
      }
    }

    final all = Future.wait([for (final n in list) _test(n).then((_) => ended(n))]);
    var win = await encWin.future;
    if (win == null && g.members.where((n) => !_plain(n)).every(_silent)) win = await plainWin.future;
    if (_stopped) return;
    g.raced = true;
    g.winner = win;
    g.fresh = true;
    g.freshWhy = why;
    await _react();
    await all;
    if (_stopped) return;
    String got(_Node n) => _down(n) ? '${n.kind} dead' : n.w.health.ms >= 0 ? '${n.kind} ${n.w.health.ms} ms' : n.w.health.ms == -1 ? '${n.kind} no answer' : '${n.kind} not asked';
    _note('info', 'dns race (${g.provider}, ${g.side}; $why): ${[for (final n in g.members) got(n)].join(', ')}; ${win == null ? 'no transport answers: the provider is out' : 'winner ${win.id}'}');
    _syncPark();
  }

  /// The ping of [provider]: the very check the rounds make (the probe inbound, the candidate's own path, the check names in
  /// turn) of every candidate on both sides at once. It does not wait for the checks: it starts them (a second ask joins the
  /// run in flight) and returns the run. Each candidate's answer is in [pingResults] / [providersJson] the moment it lands;
  /// the ones still asked read `testing`. Null when the config has no such provider (or the failover is stopped). While the
  /// network is up the answers count as a round's: an answer closes a dead candidate's root, a miss is evidence like any
  /// other (so the list's colour and the ping agree, and a provider just switched on is checked at once); otherwise it only
  /// measures.
  Future<void>? startPing(String provider) {
    if (_stopped) return null;
    final nodes = [for (final n in _all) if (n.c != null && n.provider == provider) n];
    if (nodes.isEmpty) return null;
    return _pings[provider] ??= _pingRun(nodes).whenComplete(() {
      _pings.remove(provider); // (a block: remove returns this very future, which whenComplete would wait for)
    });
  }

  /// A ping of [provider] is under way, or one of its candidates is being asked.
  bool pinging(String provider) =>
      _pings.containsKey(provider) || _all.any((n) => n.c != null && n.provider == provider && (n.testing != null || n.measuring != null));

  /// The latest answer of every candidate of [provider]: `(id, side, kind, ms)`, -1 = no answer, -2 = not asked yet.
  List<({String id, String side, String kind, int ms})> pingResults(String provider) =>
      [for (final n in _all) if (n.c != null && n.provider == provider) (id: n.id, side: n.side, kind: n.kind, ms: _msOf(n))];

  /// [startPing] awaited: the answer of every candidate. Empty when the config has no such provider.
  Future<List<({String id, String side, String kind, int ms})>> pingProvider(String provider) async {
    final run = startPing(provider);
    if (run == null) return const [];
    await run;
    return pingResults(provider);
  }

  final Map<String, Future<void>> _pings = {};

  Future<void> _pingRun(List<_Node> nodes) async {
    if (!_online) {
      await Future.wait(nodes.map(_measure));
      return;
    }
    final now = _clock();
    final parked = {for (final n in nodes) if (_down(n)) n};
    // each answer is judged as it lands, not when the slowest one has ended
    await Future.wait([
      for (final n in nodes)
        _test(n).then((_) {
          if (_stopped) return;
          _judge([n]);
          if (parked.contains(n)) _stepped(n, now, advance: false); // asked just now: the next one counts from here, the step stays
        }),
    ]);
    if (_stopped) return;
    await _react();
    _syncPark();
  }

  Future<void> _measure(_Node n) => n.measuring ??= _ask(n, null).then((ms) {
        if (!_stopped) n.measured = ms;
      }).whenComplete(() => n.measuring = null);

  // What the node answered last; a ping that only measured (the network is not up) counts while the network is not up.
  int _msOf(_Node n) => !_online && n.measured != null ? n.measured! : n.w.health.ms;

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
    // a miss moves the traffic off the server at once, in parallel with the Sentinel's judging of it (_decide)
    if (ms < 0) unawaited(_react());
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
      if (v == null || !v.dead) _recordDead(s, r.since.millisecondsSinceEpoch);
      return true;
    }
    return dnsDeadOf(book, s.c, s.vpn ? node?.call() : null) == true;
  }

  // The verdict "dead" made by the last check of [s]: of this exit node only, or of the server itself (silent through another
  // node too: its server-wide key, which every exit node sees).
  void _recordDead(_Node s, int at) {
    book.record(_key(s), dead: true, at: at, node: s.pairDead);
    final sk = dnsServerKey(s.c);
    if (sk != null && s.serverDead) book.record(sk, dead: true, at: at);
  }

  /// The other transports of the same provider on the same side.
  List<_Node> _siblings(_Node s) => [
        for (final o in _all)
          if (!identical(o, s) && o.c != null && s.c != null && o.provider == s.provider && o.side == s.side) o,
      ];

  // What a root made of this server's miss covers and the Sentinel's subject for it.
  Map<String, dynamic> _subject(_Node s) => {'dns': s.id, 'path': s.path, if (s.vpn) 'route': topTag};

  void _suspect(_Node s, {int? from}) {
    final key = dnsRootKey(s.id);
    if (sentinel.roots.byKey(key) != null) {
      // Dead already and a check of it (the recheck, a ping) missed again: the verdict stands, nothing is judged again; the
      // miss is counted on the root's event (repeat) and is a line of the raw log.
      unawaited(sentinel.suspect(Suspicion(kind: 'dns.down', key: key, subject: _subject(s), evidence: {'server': s.id, 'path': s.path}, scope: Scope.of({'dns': s.id}), level: Level.dns)));
      return;
    }
    if (dnsDeadOf(book, s.c, s.vpn ? node?.call() : null) == true) {
      // Dead already (stored, a reconnect or a restart did not forget it; the server dead through every node too): a miss
      // re-checks it and the verdict stands, so there is nothing to judge and no new event. Only an answer changes it.
      book.record(_key(s), dead: true, at: _clock(), node: book[_key(s)]?.node ?? false);
      return;
    }
    final since = from ?? s.missSince ?? _clock();
    final others = _all.where((o) => !identical(o, s) && o.vpn == s.vpn).toList();
    final via = s.vpn ? topTag : null;
    final nodes = s.vpn ? this.nodes : null;
    final found = _Finding();
    s.pairDead = s.serverDead = false;
    s.suspecting = true;
    unawaited(sentinel
        .suspect(Suspicion(
          kind: 'dns.down',
          key: key,
          subject: _subject(s),
          scope: Scope.of({'dns': s.id}),
          level: Level.dns,
          evidence: {'server': s.id, 'path': s.path, 'since': since},
          window: window,
          firstSeen: DateTime.fromMillisecondsSinceEpoch(since),
          // the reading of the evidence when the checks found no cause: the server is dead; unless the exit node itself
          // carries nothing (then it is not the server's doing, and nobody is blamed)
          whyLate: (e) => found.nodeSilent ? null : Why('dns.down', {'server': s.id, 'path': s.path}),
          checks: [
            // it answers now: a blip. A miss of the round just made is that ask: the server is not asked a second time.
            Check.recovery('dns.answers', (cancel) async {
              if (_fresh(s.missAt)) {
                return CheckResult('dns.answers', Outcome.fail, {'server': s.id, 'fresh': true, 'ageMs': _clock() - s.missAt!});
              }
              final ms = await _ask(s, cancel);
              return CheckResult('dns.answers', ms >= 0 ? Outcome.pass : Outcome.fail, {'server': s.id});
            }, timeout: const Duration(seconds: 20), level: Level.dns, via: via, resolver: s.id),
            // the VPN side: the exit node carries traffic (else it is not the server's doing) and the same server is asked
            // through another node that works: it answers there = dead on this node only; silent there too = dead itself
            if (nodes != null && s.c != null)
              Check.diagnostic('dns.node', (cancel) async {
                if (await nodes.exitAlive() == false) {
                  found.nodeSilent = true;
                  return const CheckResult('dns.node', Outcome.inconclusive, {'reason': 'nodeSilent'});
                }
                final spare = nodes.spare();
                if (spare == null) return const CheckResult('dns.node', Outcome.inconclusive, {'reason': 'noSpareNode'});
                if (cancel.cancelled) return const CheckResult('dns.node', Outcome.inconclusive, {'reason': 'aborted'});
                var unsure = false;
                final q = withCheckers((name) async {
                  final r = await nodes.ask(s.c!, spare.tag, name, settings.timeoutMs);
                  if (r == null) unsure = true;
                  return r ?? -1;
                }, dnsCheckNames.first, dnsCheckNames);
                final ms = await Future.any([q, cancel.done.then((_) => -1)]);
                if (cancel.cancelled) return const CheckResult('dns.node', Outcome.inconclusive, {'reason': 'aborted'});
                found.exit = nodes.exitKey();
                found.via = spare.key;
                if (ms >= 0) {
                  found.kind = 'node';
                  s.pairDead = true;
                  return CheckResult('dns.node', Outcome.fail, {'server': s.id, 'node': found.exit, 'via': spare.key, 'ms': ms});
                }
                if (unsure) return CheckResult('dns.node', Outcome.inconclusive, {'reason': 'cannotAsk', 'via': spare.key});
                s.serverDead = true;
                return CheckResult('dns.node', Outcome.pass, {'server': s.id, 'node': found.exit, 'silentVia': spare.key});
              }, timeout: const Duration(seconds: 30), level: Level.dns, via: via, resolver: s.id),
            // another server of the same path answers: it is this server, not the path. The ones known dead are not
            // asked (their verdict stands), nor the ones a round has just asked (their result stands).
            if (others.isNotEmpty)
              Check.diagnostic('dns.path', (cancel) async {
                if (found.nodeSilent) return const CheckResult('dns.path', Outcome.inconclusive, {'reason': 'nodeSilent'});
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
          // answers is a line in the log, not an entry in the journal (the provider works). Dead on this exit node only:
          // `dns/failedOnNode`; dead itself: `dns/failed`.
          event: SuspicionEvent('dns', 'failed',
              level: 'warn',
              kindFor: (kind, e) {
                if (kind != VerdictKind.confirmed) return null;
                final alive = _siblings(s).where((o) => !_down(o)).toList();
                if (alive.isNotEmpty) {
                  _note('info', 'dns: ${s.id} (${s.provider}, ${s.side}) does not answer, its provider still does through ${alive.map((o) => o.id).join(', ')}: not an event');
                  return null;
                }
                return found.kind == 'node' ? _dnsKind('dns', 'failedOnNode') : _dnsKind('dns', 'failed');
              },
              dataFor: (kind, e) => {
                    'server': e['server'],
                    'path': e['path'],
                    'since': e['since'],
                    'provider': s.provider,
                    'side': s.side,
                    'servers': [s.id, for (final o in _siblings(s)) o.id],
                    if (found.kind == 'node') ...{'node': found.exit, 'via': found.via},
                  },
              note: (kind, e) => found.kind == 'node'
                  ? 'DNS server ${e['server']} (via VPN) does not answer on the exit node ${found.exit}, it answers through ${found.via}'
                  : 'DNS server ${e['server']} (${e['path'] == 'proxy' ? 'via VPN' : 'direct'}) does not answer'),
        ))
        .then((v) {
      if (found.nodeSilent && v.kind != VerdictKind.confirmed) {
        _note('info', 'dns: ${s.id} (${s.side}) does not answer and the exit node ${node?.call()} carries no traffic either: not the server\'s doing, no verdict');
      }
    }).whenComplete(() => s.suspecting = false));
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

  // The last probe of it missed and no open root (the network, the core, the route) explains the miss.
  bool _missed(_Node n) => n.missAt != null && sentinel.roots.covering(_subject(n), except: dnsRootKey(n.id)) == null;

  bool _mayReturn(_Node n, int now) => n.restored ? n.w.health.answered : n.w.mayReturn(settings, now);

  Future<void> _decide() async {
    if (_stopped) return;
    _syncPark();
    final wrote = <String>{}, dropped = <String>{}, raceMoved = <String>{};
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
        final dead = _down(n), g = n.group;
        if (n.on && (dead || _missed(n))) {
          // a miss moves the traffic at once, the Sentinel's judging of it goes on in parallel (no strike yet: it may be a
          // blip); a verdict is the flap guard's strike
          if (await _flag(n, false, dead ? 'verdict' : 'miss', strike: dead)) {
            n.missDropped = !dead;
            wrote.add(n.side);
            dropped.add(n.side);
            if (g != null && g.holds && identical(g.winner, n)) {
              // the winner failed: another protocol of the provider takes over below (if one is known to work), and the
              // provider races again to find the best one now
              g.winner = null;
              g.owed ??= 'failure';
            }
          }
        } else if (!n.on && n.missDropped && dead) {
          n.missDropped = false;
          n.w.struck();
        } else if (!n.on && !dead && !(g?.holds ?? false) && _mayReturn(n, now)) {
          if (await _flag(n, true, 'back')) wrote.add(n.side);
        }
      }
      for (final g in _groups) {
        if (_stopped) return;
        if (g.multi && g.raced) await _settleGroup(g, now, wrote, dropped, raceMoved);
      }
      if (_groups.any((g) => g.owed != null)) unawaited(_raceOwed());
    }
    for (final s in _sides) {
      if (_stopped) return;
      final was = s.effective, now = _pick(s);
      s.effective = now;
      if (wrote.contains(s.name) && now != null) await _verify(s, 'after a flag write');
      if (was == null || now == null || identical(was, now)) continue;
      // `failover`: a flag went off on this side in this pass; `back`: a flag came on again (or the side's state
      // changed without a verdict); `node`: another exit node's verdicts; `off`: automatic switching was turned off.
      final reason = hint ?? (dropped.contains(s.name) ? 'failover' : raceMoved.contains(s.name) ? 'race' : 'back');
      // the winner of a race that nothing failed before is an ordinary choice: the race's own log line says it, no event
      if (reason == 'race') continue;
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

  // The flags of a group that has raced follow its winner: the winner on, the others in reserve (off, no failure). With no
  // winner (it failed, or the race found none) the best protocol known to work takes over; none = the provider is out and
  // the next one by priority answers (the flags of the others are what they were).
  Future<void> _settleGroup(_Group g, int now, Set<String> wrote, Set<String> dropped, Set<String> raceMoved) async {
    var w = g.winner;
    var byRace = g.fresh;
    // a race after the winner failed moves the side like the failover does (an event); any other race is a plain choice
    final why = g.freshWhy, moved = byRace && why != 'failure' ? raceMoved : dropped;
    g.fresh = false;
    if (w != null && !w.on && !_fit(w, now)) {
      w = g.winner = null; // chosen, but gone silent meanwhile
      byRace = false;
    }
    if (w == null) {
      w = _best(g, now);
      if (w == null) return;
      g.winner = w;
    }
    if (!w.on) {
      if (!await _flag(w, true, byRace ? (why == 'failure' ? 'failover' : 'race') : dropped.contains(g.side) ? 'failover' : 'back')) {
        g.fresh = byRace; // the write failed (the log says so): the choice stays and is written again soon
        _writeRetry();
        return;
      }
      wrote.add(g.side);
      if (byRace) moved.add(g.side);
    }
    for (final m in g.members) {
      if (_stopped) return;
      if (identical(m, w)) continue;
      if (m.on && await _flag(m, false, 'reserve', strike: false)) {
        wrote.add(g.side);
        if (byRace) moved.add(g.side);
      } else if (m.on) {
        g.fresh = byRace; // the write failed (the log says so): written again soon
        _writeRetry();
      }
      // a node that went off for a miss and answered `failAfter` times since: the blip is over, no strike is to come
      if (!m.on && m.missDropped && !_down(m) && _mayReturn(m, now)) m.missDropped = false;
    }
  }

  // A flag of a raced group could not be written: the next round (after the short pause, not the regular interval) decides again.
  void _writeRetry() {
    _writeFailed = true;
    if (!_busy) _schedule(settings.retryPause);
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
    if (on) n.missDropped = false;
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
      String why(_Node n) => _down(n)
          ? ' (down${next(n)})'
          : n.w.health.answered
              ? ((n.group?.holds ?? false) ? ' (answers, in reserve)' : ' (answers, returning)')
              : '';
      final off = [for (final n in s.members) if (!n.on) '${n.id}${why(n)}'];
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
  ///
  /// `providers`: the protocol race of every provider on every side it is on ([providersJson]).
  Map<String, dynamic> toJson() => {
        'active': active,
        'auto': auto,
        'sides': {
          for (final s in _sides) s.name: {'active': s.effective?.id, 'provider': s.effective?.provider},
        },
        'providers': providersJson(),
        'servers': [
          for (final s in _members) _json(s),
          for (final s in _watch) {..._json(s), 'watched': true},
        ],
      };

  /// The protocol race by provider and side (the ones in this config, or only [provider]): `{provider, side, racing, winner,
  /// transports}`. `winner`: `{id, kind, ms}`, the transport the side is answered with, null = none yet (the race has not run,
  /// or no transport answers); `racing`: a race is under way or owed. `transports`, in the provider's order, one per kind:
  /// `{kind, ids, ms, state}` — `ms` the best last answer (-1 = no answer, -2 = not asked yet), `state`: `testing` (a check
  /// is under way: the app shows a spinner and asks again until it ends), `ok` / `miss` (the last result), `untested`;
  /// `dead: true` when every candidate of the kind has a dead verdict; `reserve: true` when the kind answers but another
  /// one is at work.
  List<Map<String, dynamic>> providersJson([String? provider]) => [
        for (final g in _groups)
          if (provider == null || g.provider == provider) _groupJson(g),
      ];

  Map<String, dynamic> _groupJson(_Group g) {
    // a group of one has no race: its member is the winner while it answers
    final _Node? w = g.multi ? (auto ? g.winner : g.members.firstOrNull) : (g.members.single.w.health.answered && !_down(g.members.single) ? g.members.single : null);
    final kinds = {for (final n in g.members) n.kind};
    return {
      'provider': g.provider,
      'side': g.side,
      'racing': g.racing != null || g.owed != null,
      'winner': w == null ? null : {'id': w.id, 'kind': w.kind, 'ms': w.w.health.ms},
      'transports': [
        for (final k in kinds) _transportJson(g, k, w),
      ],
    };
  }

  Map<String, dynamic> _transportJson(_Group g, String kind, _Node? winner) {
    final ns = [for (final n in g.members) if (n.kind == kind) n];
    final ok = [for (final n in ns) if (_msOf(n) >= 0) _msOf(n)];
    final ms = ok.isNotEmpty ? ok.reduce((a, b) => a < b ? a : b) : ns.any((n) => _msOf(n) == -1) ? -1 : -2;
    final testing = ns.any((n) => n.testing != null || n.measuring != null || n.suspecting);
    final dead = ns.every(_down);
    return {
      'kind': kind,
      'ids': [for (final n in ns) n.id],
      'ms': ms,
      'state': testing ? 'testing' : ms >= 0 ? 'ok' : ms == -1 ? 'miss' : 'untested',
      if (dead) 'dead': true,
      if (ms >= 0 && winner != null && !ns.contains(winner)) 'reserve': true,
    };
  }

  Map<String, dynamic> _json(_Node s) {
    final dead = _down(s), known = dnsDeadOf(book, s.c, s.vpn ? node?.call() : null) != null;
    return {
      'id': s.id,
      'ok': dead ? false : known ? true : (s.w.health.ms == -2 ? null : s.w.health.answered),
      'rechecking': s.testing != null || s.suspecting,
      if (dead && book[_key(s)]?.node == true) 'deadOn': 'node', // dead on this exit node only; the server answers through another
      'ms': s.w.health.ms,
      'provider': s.provider,
      'side': s.side,
      'kind': s.kind,
      if (s.c != null) 'flag': s.on,
    };
  }
}
