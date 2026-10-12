/// DNS failover while sing-box runs (docs/rules.md §6): sing-box has no fallback between DNS
/// servers (one is `dns.final`), so the core does it. With two or more servers in use every
/// one has a DNS rule for its own clash mode (routing.dart `_dnsModes`); this service sets the
/// mode of the highest-priority one that is not down, through the API service (sbapi.dart
/// `setClashMode`), with no restart and no clash_api in the config.
///
/// Whether a server is down is not decided here: the Sentinel judges it (docs/failures.md → DNS).
/// A round (every `checkEvery`, the first after `firstCheck`; after a miss the next comes after
/// `retryPause`) resolves a well-known name through each server alone — a real query on the
/// server's own path, direct or through the VPN as it is set (probe.dart `probeDns`, the probe
/// inbound) — with backup names as with the node checks. A miss is evidence for the suspicion
/// `dns.down` of that server (the Sentinel's window, then its checks: does it answer now; does
/// another server of the same path), an answer ends it (a blip, or the open root closes). The
/// failover acts on the verdicts: it listens to the Sentinel's changes and, when the root of the
/// server in use opens, moves to the highest-priority server that answers and has no root; when
/// a higher server's root is closed and it has answered `failAfter` times in a row plus, once it
/// dropped, the flap guard's hold (auto.dart, watched.dart), it goes back.
///
/// The servers the failover does not switch (a rule's own server, not ticked) are watched
/// the same way ([watch]): probed, judged, a root opened — nothing moves, there is no live switch for them.
///
/// Nothing is probed unless the probe pool's network status is `up` ([pool], pool.dart: the
/// status Auto, the fallback service and the UI's pings share; a name resolved by a local
/// resolver proves nothing about the internet, so DNS answers do not feed it) and nothing is
/// switched unless the network is up and the core settled (the Sentinel's context). With [auto]
/// off the checks still run (Settings → DNS shows which server fails) but nothing is switched,
/// and the first server in use answers again.
library;

import 'dart:async';

import 'auto.dart' show AutoSettings;
import 'plan.dart' show topTag;
import 'pool.dart' show NetStatus, ProbePool;
import 'probe.dart' show withCheckers;
import 'routing.dart' show DnsEntry, dnsModeOf;
import 'sentinel/sentinel.dart';
import 'watched.dart';

/// Names every ordinary resolver answers: the server works when any of them resolves.
const dnsCheckNames = ['cp.cloudflare.com', 'www.gstatic.com', 'captive.apple.com'];

/// The Sentinel's key of the suspicion / root of the DNS server [id].
String dnsRootKey(String id) => 'dns|$id';

/// The DNS server in use changed. [from] / [to] are the UI's server ids; [reason]:
/// `failover` (the one in use is down), `back` (a higher one answers again) or
/// `off` (Switch automatically was turned off: the first server in use answers again).
class DnsSwitch {
  const DnsSwitch({required this.from, required this.to, required this.reason, required this.at});

  final String from, to, reason;
  final int at;

  Map<String, dynamic> toJson() => {'from': from, 'to': to, 'reason': reason, 'at': at};
}

class _Server {
  _Server(this.entry, {required this.vpn});

  final DnsEntry entry;

  /// Set «via VPN»: its queries go out through the main flow.
  final bool vpn;
  final w = Watched();

  /// When the current run of misses began (ms since epoch); null = it answered last.
  int? missSince;
  String get id => entry.id;
  String get path => vpn ? 'proxy' : 'direct';
}

class DnsFailover {
  DnsFailover(
    List<DnsEntry> servers, {
    required this.setMode,
    required this.query,
    required this.settings,
    required this.sentinel,
    Set<String> vpn = const {},
    List<DnsEntry> watch = const [],
    this.window = Duration.zero,
    this.auto = true,
    String? active,
    this.pool,
    int Function()? clock,
    this.note,
  }) : _clock = clock ?? _wallClock {
    _servers = [for (final s in servers) _Server(s, vpn: vpn.contains(s.id))];
    _watch = [for (final s in watch) if (!servers.any((x) => x.id == s.id)) _Server(s, vpn: vpn.contains(s.id))];
    _active = _servers.where((s) => s.id == active).firstOrNull ?? _servers.firstOrNull;
    _sub = sentinel.changes.listen((_) => unawaited(_react()));
  }

  /// Sets sing-box's clash mode; false when it refused.
  final Future<bool> Function(String mode) setMode;

  /// ms until the DNS server [tag] resolved [name] (probe.dart `probeDns`); -1 = no answer.
  final Future<int> Function(String tag, String name, int timeoutMs) query;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;

  final Sentinel sentinel;

  /// How long a server must keep missing before the Sentinel may call it down (windows.dart `dnsDown`).
  final Duration window;

  /// Settings → DNS → Switch automatically (`POST /api/dns/auto`, takes effect at once).
  bool auto;
  final ProbePool? pool;
  final void Function(String line)? note;
  final int Function() _clock;
  late final List<_Server> _servers, _watch;
  _Server? _active;
  final _switches = StreamController<DnsSwitch>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  bool _busy = false, _started = false, _stopped = false, _again = false;
  Future<void>? _loop;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// The id of the server in use now.
  String? get active => _active?.id;

  bool get isEmpty => _servers.isEmpty;

  Stream<DnsSwitch> get switches => _switches.stream;

  Iterable<_Server> get _all => [..._servers, ..._watch];

  void start() {
    _started = true;
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    unawaited(_sub?.cancel());
    _switches.close();
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_started && !_stopped) _timer = Timer(d, () => unawaited(check()));
  }

  /// Turning it off puts the first server in use back at once; turning it on waits for the
  /// next round.
  Future<void> setAuto(bool on) async {
    auto = on;
    if (on || _servers.length < 2 || _stopped) return;
    final first = _servers.first;
    if (!identical(_active, first)) await _switchTo(first, 'off');
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

  /// One round: test every server, hand the misses to the Sentinel, then move to the right one.
  Future<void> check() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      if (pool != null && pool!.status != NetStatus.up) return;
      if (sentinel.context.network.state != NetState.up) return;
      await Future.wait(_all.map(_test));
      if (_stopped) return;
      for (final s in _all) {
        if (s.w.health.answered) {
          s.missSince = null;
          sentinel.recovered(dnsRootKey(s.id), reason: 'dns.answers');
        } else if (s.w.health.ms == -1) {
          _suspect(s);
        }
      }
      await _react();
    } finally {
      _busy = false;
      final a = _active;
      _schedule(a != null && a.missSince != null && !_down(a) ? settings.retryPause : settings.checkEvery);
    }
  }

  Future<void> _test(_Server s) async {
    final ms = await _ask(s, null);
    if (_stopped) return;
    final now = _clock();
    s.w.health.record(ms, now);
    if (ms < 0) {
      s.missSince ??= now;
    } else {
      s.missSince = null;
    }
    if (identical(s, _active)) s.w.forgetIfStable(settings, now);
  }

  // The names are tried in turn (backup names as with the node checks); [cancel] ends the wait at once.
  Future<int> _ask(_Server s, Cancel? cancel) {
    final q = withCheckers((name) => query(s.entry.tag, name, settings.timeoutMs), dnsCheckNames.first, dnsCheckNames);
    return cancel == null ? q : Future.any([q, cancel.done.then((_) => -1)]);
  }

  // The root of the server is open and no wider failure explains it.
  bool _down(_Server s) {
    final r = sentinel.roots.byKey(dnsRootKey(s.id));
    return r != null && r.parent == null;
  }

  void _suspect(_Server s) {
    final key = dnsRootKey(s.id);
    if (sentinel.roots.byKey(key) != null) return;
    final since = s.missSince ?? _clock();
    final others = _all.where((o) => !identical(o, s) && o.vpn == s.vpn).toList();
    final via = s.vpn ? topTag : null;
    unawaited(sentinel.suspect(Suspicion(
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
        // it answers now: a blip
        Check.recovery('dns.answers', (cancel) async {
          final ms = await _ask(s, cancel);
          return CheckResult('dns.answers', ms >= 0 ? Outcome.pass : Outcome.fail, {'server': s.id});
        }, timeout: const Duration(seconds: 20), level: Level.dns, via: via, resolver: s.id),
        // another server of the same path answers: it is this server, not the path
        if (others.isNotEmpty)
          Check.diagnostic('dns.path', (cancel) async {
            final asked = await Future.wait(others.map((o) => _ask(o, cancel)));
            if (cancel.cancelled) return const CheckResult('dns.path', Outcome.inconclusive, {'reason': 'aborted'});
            final ok = [for (var i = 0; i < others.length; i++) if (asked[i] >= 0) others[i].id];
            return CheckResult('dns.path', ok.isNotEmpty ? Outcome.pass : Outcome.fail, {'path': s.path, 'answering': ok});
          }, timeout: const Duration(seconds: 20), level: Level.dns, via: via),
      ],
      event: SuspicionEvent('dns', 'failed',
          level: 'warn',
          kindFor: (kind, e) => kind == VerdictKind.confirmed ? ('dns', 'failed') : null,
          dataFor: (kind, e) => {'server': e['server'], 'path': e['path'], 'since': e['since']},
          note: (kind, e) => 'DNS server ${e['server']} (${e['path'] == 'proxy' ? 'via VPN' : 'direct'}) does not answer'),
    )));
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

  Future<void> _decide() async {
    final cur = _active;
    if (!auto || _servers.length < 2 || cur == null || _stopped || !_ready) return;
    if (_down(cur)) {
      // the highest-priority one that answers and is not down; none: nothing to move to
      final to = _servers.where((s) => !identical(s, cur) && !_down(s) && s.w.health.answered).firstOrNull;
      if (to != null && await _switchTo(to, 'failover')) cur.w.struck();
      return;
    }
    final now = _clock();
    for (final s in _servers.take(_servers.indexOf(cur))) {
      if (!_down(s) && s.w.mayReturn(settings, now) && await _switchTo(s, 'back')) return;
    }
  }

  Future<bool> _switchTo(_Server to, String reason) async {
    final from = _active;
    if (from == null || _stopped || !await setMode(dnsModeOf(to.entry.tag))) return false;
    _active = to;
    to.w.usedSince = _clock();
    note?.call('dns: ${from.id} → ${to.id} ($reason)');
    if (!_switches.isClosed) _switches.add(DnsSwitch(from: from.id, to: to.id, reason: reason, at: _clock()));
    return true;
  }

  /// `{active: server id, auto, servers: [{id, ok, ms}]}` in priority order. `ok`: null = not
  /// tested yet, false = the last probe missed or the Sentinel has an open root for the server;
  /// `ms`: the last result, -1 = no answer, -2 = not tested. The watched-only servers (a rule's own, the OS
  /// resolver `system`) follow the ones in use with `watched: true`: never `active`, never switched to.
  Map<String, dynamic> toJson() => {
        'active': active,
        'auto': auto,
        'servers': [
          for (final s in _servers) _json(s),
          for (final s in _watch) {..._json(s), 'watched': true},
        ],
      };

  Map<String, dynamic> _json(_Server s) => {
        'id': s.id,
        'ok': s.w.health.ms == -2 ? null : s.w.health.answered && sentinel.roots.byKey(dnsRootKey(s.id)) == null,
        'ms': s.w.health.ms,
      };
}
