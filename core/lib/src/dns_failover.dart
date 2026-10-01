/// DNS failover while sing-box runs (docs/rules.md §6): sing-box has no fallback between DNS
/// servers (one is `dns.final`), so the core does it. With two or more servers in use every
/// one has a DNS rule for its own clash mode (routing.dart `_dnsModes`); this service checks
/// the servers and sets the mode of the highest-priority one that answers, through the API
/// service (sbapi.dart `setClashMode`), with no restart and no clash_api in the config.
///
/// A round (every `checkEvery`, the first after `firstCheck`; after a miss of the server in
/// use the next comes after `retryPause`) resolves a well-known name through each server
/// alone — a real query on the server's own path, direct or through the VPN as it is set
/// (probe.dart `probeDns`, the probe inbound) — with backup names as with the node checks. A
/// server is down after `failAfter` misses in a row and back after `failAfter` answers in a
/// row plus, once it dropped, the flap guard's hold (auto.dart, watched.dart). The one in use
/// down → the highest-priority server that answers; a higher one back → it again.
///
/// Nothing is judged unless the probe pool's network status is `up` ([pool], pool.dart: the
/// status Auto, the fallback service and the UI's pings share; a name resolved by a local
/// resolver proves nothing about the internet, so DNS answers do not feed it). With [auto] off
/// the checks still run (Settings → DNS shows which server fails) but nothing is switched,
/// and the first server in use answers again.
library;

import 'dart:async';

import 'auto.dart' show AutoSettings;
import 'pool.dart' show NetStatus, ProbePool;
import 'probe.dart' show withCheckers;
import 'routing.dart' show DnsEntry, dnsModeOf;
import 'watched.dart';

/// Names every ordinary resolver answers: the server works when any of them resolves.
const dnsCheckNames = ['cp.cloudflare.com', 'www.gstatic.com', 'captive.apple.com'];

/// The DNS server in use changed. [from] / [to] are the UI's server ids; [reason]:
/// `failover` (the one in use stopped answering), `back` (a higher one answers again) or
/// `off` (Switch automatically was turned off: the first server in use answers again).
class DnsSwitch {
  const DnsSwitch({required this.from, required this.to, required this.reason, required this.at});

  final String from, to, reason;
  final int at;

  Map<String, dynamic> toJson() => {'from': from, 'to': to, 'reason': reason, 'at': at};
}

class _Server {
  _Server(this.entry);

  final DnsEntry entry;
  final w = Watched();
  String get id => entry.id;
}

class DnsFailover {
  DnsFailover(
    List<DnsEntry> servers, {
    required this.setMode,
    required this.query,
    required this.settings,
    this.auto = true,
    String? active,
    this.pool,
    int Function()? clock,
    this.note,
  }) : _clock = clock ?? _wallClock {
    _servers = [for (final s in servers) _Server(s)];
    _active = _servers.where((s) => s.id == active).firstOrNull ?? _servers.firstOrNull;
  }

  /// Sets sing-box's clash mode; false when it refused.
  final Future<bool> Function(String mode) setMode;

  /// ms until the DNS server [tag] resolved [name] (probe.dart `probeDns`); -1 = no answer.
  final Future<int> Function(String tag, String name, int timeoutMs) query;

  /// Replaceable while running (Settings → Auto mode changed): the next round uses it.
  AutoSettings settings;

  /// Settings → DNS → Switch automatically (`POST /api/dns/auto`, takes effect at once).
  bool auto;
  final ProbePool? pool;
  final void Function(String line)? note;
  final int Function() _clock;
  late final List<_Server> _servers;
  _Server? _active;
  final _switches = StreamController<DnsSwitch>.broadcast();
  Timer? _timer;
  bool _busy = false, _started = false, _stopped = false;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// The id of the server in use now.
  String? get active => _active?.id;

  bool get isEmpty => _servers.isEmpty;

  Stream<DnsSwitch> get switches => _switches.stream;

  void start() {
    _started = true;
    _schedule(settings.firstCheck);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
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

  /// One round: test every server, then move to the right one.
  Future<void> check() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      if (pool != null && pool!.status != NetStatus.up) return;
      await Future.wait(_servers.map(_test));
      if (_stopped) return;
      await _decide();
    } finally {
      _busy = false;
      final a = _active;
      _schedule(a != null && a.w.health.fails > 0 && !a.w.isDown(settings) ? settings.retryPause : settings.checkEvery);
    }
  }

  Future<void> _test(_Server s) async {
    final ms = await withCheckers((name) => query(s.entry.tag, name, settings.timeoutMs), dnsCheckNames.first, dnsCheckNames);
    if (_stopped) return;
    final now = _clock();
    s.w.health.record(ms, now);
    if (identical(s, _active)) s.w.forgetIfStable(settings, now);
  }

  Future<void> _decide() async {
    final cur = _active;
    if (!auto || _servers.length < 2 || cur == null || _stopped) return;
    if (cur.w.isDown(settings)) {
      // the highest-priority one that answers; none does: nothing to move to
      final to = _servers.where((s) => !identical(s, cur) && s.w.health.answered).firstOrNull;
      if (to != null && await _switchTo(to, 'failover')) cur.w.struck();
      return;
    }
    final now = _clock();
    for (final s in _servers.take(_servers.indexOf(cur))) {
      if (s.w.mayReturn(settings, now) && await _switchTo(s, 'back')) return;
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

  /// `{active: server id, auto, servers: [{id, ok, ms}]}` in priority order. `ok`: null =
  /// not tested yet, false = down (`failAfter` misses in a row); `ms`: the last result, -1
  /// = no answer, -2 = not tested.
  Map<String, dynamic> toJson() => {
        'active': active,
        'auto': auto,
        'servers': [
          for (final s in _servers) {'id': s.id, 'ok': s.w.health.ms == -2 ? null : !s.w.isDown(settings), 'ms': s.w.health.ms},
        ],
      };
}
