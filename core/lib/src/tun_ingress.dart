/// Does TCP from the TUN reach sing-box? The detector for the silent outage of 2026-10-10: on the
/// Android `system` / `mixed` TUN stacks the app's own exclusion left TCP unanswered — sing-box saw
/// the first packet of every connection (and logged `router: found package name`) but never made
/// a connection of it, so no `inbound connection` line, no routing, no error, nothing in the closed
/// stream; only DNS and UDP lived. Nothing the closed-connection book ([FailureBook]) can see: the
/// requests never become connections.
///
/// It reads sing-box's log lines (the raw stream of the runner, never the Logs tab's ring, which
/// drops the connection lines first) and tells two things apart:
///
/// - a connection that arrived: the tun inbound's own line `inbound/tun[tun-in]: inbound connection …`
///   (`inbound packet connection` for UDP, `inbound DNS packet` for DNS), one per connection id;
/// - a connection that was only looked at: `router: found package name` / `found process path` of an id
///   that has no inbound line. A healthy stack logs one or two of those right next to every real
///   connection (the look-up happens before the connection is made: different ids, adjacent lines), so
///   each real line takes up to its capacity of orphans within [pairLines] lines, before or after.
///   Orphans nobody takes are «SYNs seen, never accepted».
///
/// Dead = [minUnpaired] of those within [window] while no TCP connection arrived in it, once
/// [grace] has passed since start. The numbers come from the three recorded sessions: healthy gVisor
/// stays at 4 or fewer unpaired orphans in any window of 10–60 s without TCP; the dead system and
/// mixed stacks reach 8 within 2–3 s and 10 within 4 s. One `tunTcpDead` per dead period; the first TCP
/// connection that arrives after it is `tunTcpBack`.
///
/// Our own `reject` rules (the plan's IPv6 off, [ownRejects]; a user's block rule) look exactly like a dead
/// stack at the log level `info`: the look-up is logged, no connection follows. At `debug` sing-box also
/// writes `router: pre-match[N] … => reject` with the same id: an orphan with such a line is ours, is not
/// counted, and a window the own rejects alone fill is reported with `ownReject: true` (the Sentinel lets it
/// go, never an error). At `info` the two cannot be told apart here; the Sentinel's persistence window and,
/// later, an active test connection through the TUN (a Check on `tun.tcpDead`) are what separate them.
library;

import 'dart:collection';

import 'failures.dart' show SbLine;

class TunIngressDetector {
  TunIngressDetector({DateTime Function()? now, this.onDead, this.onBack}) : _now = now ?? DateTime.now;

  /// The span the unpaired orphans and the TCP connections are counted over.
  static const window = Duration(seconds: 30);

  /// Orphans no real line took within [window] (and no TCP connection in it) that make «dead».
  static const minUnpaired = 8;

  /// A real line takes the orphans within this many lines (all sing-box lines count) before or after it.
  static const pairLines = 5;

  /// How many orphans one real line of each kind takes: a TCP connection looks twice (the
  /// SYN's pre-match and the route), UDP and DNS once.
  static const tcpCapacity = 2, otherCapacity = 1;

  /// After [start] nothing is judged for this long: the tunnel's first packets are the app's
  /// retries of what the previous connection left.
  static const grace = Duration(seconds: 5);

  /// Apps named in the event (those with most unpaired orphans).
  static const maxApps = 5;

  static const _seenCap = 1024;

  final DateTime Function() _now;

  /// `tunTcpDead`'s data: `{stack, synSeen, accepted, windowMs, apps, appCounts, firstSeen, ownRejects, ownRejected,
  /// udp, dns, ownReject?}`; `ownReject: true` = the own reject rules alone explain the unpaired look-ups
  /// (not dead; said once per such period).
  final void Function(Map<String, dynamic> data)? onDead;

  /// `tunTcpBack`'s data: `{stack, accepted, deadMs}`.
  final void Function(Map<String, dynamic> data)? onBack;

  bool _active = false;
  String _stack = '';
  List<String> _ownRejects = const [];
  int _ownInWindow = 0, _ownTotal = 0;
  bool _ownLatch = false;
  final _byId = <String, _Orphan>{}; // the latest orphans by connection id, to mark them rejected by us
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _line = 0;
  final _seen = <String>{}; // ids that have an inbound line, in insertion order
  final _reals = Queue<_Real>(); // lines of the last [pairLines] with capacity left
  final _pending = Queue<_Orphan>(); // orphans still within reach of a real line
  final _unpaired = Queue<_Orphan>(); // orphans that nobody took, within [window]
  final _tcp = Queue<DateTime>(); // TCP connections within [window]

  // the session's totals, for the report
  int _tcpTotal = 0, _udpTotal = 0, _dnsTotal = 0, _orphanTotal = 0, _unpairedTotal = 0;
  bool _dead = false;
  DateTime? _deadAt;
  int _deadEvents = 0;

  bool get active => _active;
  bool get dead => _dead;

  /// The tunnel is up with [stack] (`mixed` / `system` / `gvisor`): counting begins. [ownRejects]: the plan's
  /// own reject rules that are in the config (`ipv6Off`): named in the dead event's data.
  void start(String stack, {List<String> ownRejects = const []}) {
    stop();
    _active = true;
    _stack = stack;
    _ownRejects = ownRejects;
    _startedAt = _now();
    _line = 0;
    _tcpTotal = _udpTotal = _dnsTotal = _orphanTotal = _unpairedTotal = _ownTotal = 0;
    _dead = false;
    _deadAt = null;
    _deadEvents = 0;
  }

  void stop() {
    _active = false;
    _seen.clear();
    _reals.clear();
    _pending.clear();
    _unpaired.clear();
    _tcp.clear();
    _byId.clear();
    _ownInWindow = 0;
    _ownLatch = false;
  }

  // `inbound/tun[tun-in]: inbound connection from …` | `… inbound packet connection to …` | `… inbound DNS packet from …`
  static final _tunRe = RegExp(r'^inbound/tun\[[^\]]*\]: inbound (DNS packet|packet connection|connection)\b');
  // any other inbound's line: mixed / socks / http; its id is a real connection, not an orphan
  static final _inRe = RegExp(r'^inbound/\w+\[[^\]]*\]: .*?\binbound (?:DNS packet|packet connection|connection)\b');
  // `router: found package name: org.telegram.messenger` / `router: found process path: C:\…`
  static final _foundRe = RegExp(r'^router: found (?:package name|process path): (.+)$');
  // debug level only: `router: pre-match[3] inbound=tun-in ip_version=6 => reject(no_drop)`; the id is the connection's
  static final _rejectRe = RegExp(r'^router: pre-match\[\d+\] .*=> reject\b');

  /// A line of sing-box's log.
  void onLine(String raw) {
    if (!_active) return;
    _line++;
    final now = _now();
    // the flood is mostly lines of no interest: the words the patterns need, before any regex
    if (raw.contains('inbound') || raw.contains('found p') || raw.contains('pre-match')) {
      final l = SbLine.parse(raw);
      final id = l.id;
      if (id != null) {
        final t = _tunRe.firstMatch(l.body);
        if (t != null) {
          if (_remember(id)) _real(t[1]!, now);
        } else if (_inRe.hasMatch(l.body)) {
          _remember(id);
        } else if (_rejectRe.hasMatch(l.body)) {
          _rejected(id);
        } else {
          final f = _foundRe.firstMatch(l.body);
          if (f != null && !_seen.contains(id)) _orphan(id, f[1]!.trim(), now);
        }
      }
    }
    _judge(now);
  }

  // The look-up of connection [id] ended in one of our reject rules: not a stack that takes nothing.
  void _rejected(String id) {
    final o = _byId[id];
    if (o == null || o.own) return;
    o.own = true;
    _ownTotal++;
    if (o.counted) _ownInWindow++;
  }

  // the first inbound line of an id; false = a second line of it (`from`, then `to`)
  bool _remember(String id) {
    if (!_seen.add(id)) return false;
    while (_seen.length > _seenCap) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  void _real(String type, DateTime now) {
    final tcp = type == 'connection';
    if (tcp) {
      _tcpTotal++;
      _tcp.add(now);
      if (_dead) _back(now);
    } else if (type == 'packet connection') {
      _udpTotal++;
    } else {
      _dnsTotal++;
    }
    var room = tcp ? tcpCapacity : otherCapacity;
    _forget();
    // orphans just before it that nobody took
    for (final o in _pending.toList().reversed) {
      if (room == 0 || _line - o.line > pairLines) break;
      _pending.remove(o);
      room--;
    }
    if (room > 0) _reals.add(_Real(_line, room));
  }

  void _orphan(String id, String who, DateTime now) {
    _orphanTotal++;
    _forget();
    // a real line just before it with capacity left takes it
    for (final r in _reals.toList().reversed) {
      if (_line - r.line > pairLines) break;
      if (r.room > 0) {
        r.room--;
        return;
      }
    }
    final o = _Orphan(_line, now, who);
    _pending.add(o);
    _byId[id] = o;
    while (_byId.length > _seenCap) {
      _byId.remove(_byId.keys.first);
    }
  }

  // what is out of reach: reals that can no longer take an orphan, orphans no later real can take
  void _forget() {
    while (_reals.isNotEmpty && _line - _reals.first.line > pairLines) {
      _reals.removeFirst();
    }
    while (_pending.isNotEmpty && _line - _pending.first.line > pairLines) {
      final o = _pending.removeFirst();
      o.counted = true;
      _unpaired.add(o);
      _unpairedTotal++;
      if (o.own) _ownInWindow++;
    }
  }

  void _judge(DateTime now) {
    _forget();
    final from = now.subtract(window);
    while (_unpaired.isNotEmpty && _unpaired.first.at.isBefore(from)) {
      final o = _unpaired.removeFirst();
      o.counted = false;
      if (o.own) _ownInWindow--;
    }
    while (_tcp.isNotEmpty && _tcp.first.isBefore(from)) {
      _tcp.removeFirst();
    }
    if (_dead || now.difference(_startedAt) < grace) return;
    if (_tcp.isNotEmpty || _unpaired.length < minUnpaired) {
      _ownLatch = false;
      return;
    }
    // what our own reject rules took does not count: a stack is dead when it ignores the rest
    final dead = _unpaired.length - _ownInWindow >= minUnpaired;
    if (!dead) {
      if (_ownLatch) return;
      _ownLatch = true;
      onDead?.call({..._deadData(), 'ownReject': true});
      return;
    }
    _ownLatch = false;
    _dead = true;
    _deadAt = now;
    _deadEvents++;
    onDead?.call(_deadData());
  }

  Map<String, dynamic> _deadData() => {
        'stack': _stack,
        'synSeen': _unpaired.length,
        'accepted': _tcp.length,
        'windowMs': window.inMilliseconds,
        'apps': _topApps(),
        'appCounts': _appCounts(),
        'firstSeen': _unpaired.first.at.millisecondsSinceEpoch,
        if (_ownRejects.isNotEmpty) 'ownRejects': _ownRejects,
        'ownRejected': _ownInWindow,
        'udp': _udpTotal,
        'dns': _dnsTotal,
      };

  void _back(DateTime now) {
    final at = _deadAt;
    _dead = false;
    _deadAt = null;
    for (final o in _unpaired) {
      o.counted = false;
    }
    _unpaired.clear();
    _ownInWindow = 0;
    _ownLatch = false;
    onBack?.call({
      'stack': _stack,
      'accepted': _tcpTotal,
      'deadMs': at == null ? 0 : now.difference(at).inMilliseconds,
    });
  }

  // the unpaired look-ups per app, those with most first
  List<MapEntry<String, int>> _perApp() {
    final n = <String, int>{};
    for (final o in _unpaired) {
      if (o.own) continue;
      n[o.who] = (n[o.who] ?? 0) + 1;
    }
    return n.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  List<String> _topApps() => [for (final e in _perApp().take(maxApps)) e.key];

  Map<String, int> _appCounts() => {for (final e in _perApp().take(maxApps)) e.key: e.value};

  /// The numbers for the report.
  Map<String, dynamic> toJson() {
    final now = _now();
    if (_active) _judge(now);
    return {
      'active': _active,
      'stack': _stack,
      'state': !_active ? 'off' : (_dead ? 'dead' : 'ok'),
      'sinceMs': _active ? now.difference(_startedAt).inMilliseconds : 0,
      'windowMs': window.inMilliseconds,
      'tcpInWindow': _tcp.length,
      'unpairedInWindow': _unpaired.length,
      'tcp': _tcpTotal,
      'udp': _udpTotal,
      'dns': _dnsTotal,
      'lookedAt': _orphanTotal,
      'unpaired': _unpairedTotal,
      'ownRejected': _ownTotal,
      'deadEvents': _deadEvents,
      if (_dead && _deadAt != null) 'deadForMs': now.difference(_deadAt!).inMilliseconds,
      if (_dead) 'apps': _topApps(),
      'thresholds': {'minUnpaired': minUnpaired, 'windowMs': window.inMilliseconds, 'pairLines': pairLines, 'graceMs': grace.inMilliseconds},
    };
  }
}

class _Real {
  _Real(this.line, this.room);
  final int line;
  int room;
}

class _Orphan {
  _Orphan(this.line, this.at, this.who);
  final int line;
  final DateTime at;
  final String who;

  /// Ended in one of our reject rules (a debug line said so).
  bool own = false;

  /// In the unpaired queue (the window counts it).
  bool counted = false;
}
