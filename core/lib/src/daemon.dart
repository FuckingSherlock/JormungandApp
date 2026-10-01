import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'auto.dart';
import 'config.dart';
import 'device.dart';
import 'dns_failover.dart';
import 'eventbook.dart';
import 'exitip.dart';
import 'fallback.dart';
import 'logbook.dart';
import 'manual.dart';
import 'node.dart';
import 'parse/links.dart';
import 'plan.dart';
import 'pool.dart';
import 'probe.dart';
import 'routing.dart';
import 'rulenames.dart';
import 'rulesets.dart';
import 'runtime.dart';
import 'sbapi.dart';
import 'share.dart';
import 'state.dart';
import 'sysproxy.dart';
import 'traffic.dart';
import 'updater.dart';

/// jormd: the core behind a local HTTP API, so the HTML mockup can drive it as the
/// app's UI while there is no Flutter app. The mockup keeps its own state (sources,
/// profiles, chains, order) and stores it here as one snapshot; the core fetches and
/// parses subscriptions, builds sing-box configs, runs sing-box and measures latency.
///
/// Every /api call must carry `X-Jorm: 1` (a custom header forces a CORS preflight,
/// which this server never grants, so other web pages cannot drive it) and a loopback
/// Host (against DNS rebinding); with `--lan` the machine's own LAN addresses count too.
class Daemon {
  /// [exitCheck], [sysProxy], [process], [timer] and [now] are for tests (no probes past
  /// loopback; a fake system proxy, so a test never touches the real registry; a fake
  /// sing-box process; the restart waits and the clock under the test's control).
  Daemon({
    required this.singBox,
    required this.dataDir,
    required this.uiFile,
    this.lanHosts = const {},
    this.exitCheck = checkExitIp,
    SystemProxy? sysProxy,
    SingBoxProcess? process,
    Timer Function(Duration, void Function())? timer,
    DateTime Function()? now,
  })
      : main = process ?? SingBoxProcess(singBox, p.join(dataDir, 'run', 'main')),
        _timer = timer ?? Timer.new,
        _now = now ?? DateTime.now,
        sysProxy = sysProxy ?? SystemProxy(File(p.join(dataDir, 'sysproxy.saved.json'))),
        ruleSets = RuleSetCache(p.join(dataDir, 'rulesets')) {
    main.onExit = _crashed;
    main.onLog = (line) {
      log.singBox(line);
      _auto?.onLog(line);
    };
    ruleSets.onFailed = (tag, url, error) => _event('rules', 'ruleSetFailed', 'warn', {'tag': tag, 'url': url, 'error': error},
        note: 'Rule set $tag not downloaded ($url): $error');
    ruleSets.onUpdated = (tag) => _event('rules', 'ruleSetUpdated', 'info', {'tag': tag}, note: 'Rule set $tag updated');
  }

  final String singBox;
  final String dataDir;
  final String uiFile;
  final Set<String> lanHosts;
  final SingBoxProcess main;
  final SystemProxy sysProxy;
  final RuleSetCache ruleSets;
  final Future<Map<String, dynamic>> Function(int? proxyPort) exitCheck;

  /// sing-box output and the core's own notes (the Logs tab).
  final log = LogBook();

  /// What happened, structured (eventbook.dart): the Events tab and the notifications.
  late final events = EventBook(File(p.join(dataDir, 'events.jsonl')), log: log);

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  late final store = SnapshotStore(_snapshot);
  // Subscriptions update themselves on their periods, also with the UI closed.
  late final updater = SubscriptionUpdater(
    store: store,
    hwid: () => _hwid,
    proxyPort: () => _innerPort,
    onEvent: (type, data) => _event('sub', type, type == 'failed' ? 'error' : 'info', data,
        note: type == 'failed'
            ? 'Subscription ${data['name']} not updated: ${data['error']}'
            : 'Subscription ${data['name']} updated: +${data['added']} -${data['removed']}, ${data['total']} servers'),
  );
  late final Future<Map<String, String>> _hwid = deviceHeaders(dataDir);
  String? _error;
  String? _warning;
  int _pingSeq = 0;
  int _mixedPort = 2080;
  int? _tunnelPort; // tunnel-in: always through the tunnel (exit check, lists via VPN)
  int? _sysPort; // sys-in: the system proxy's own open inbound; null = it points at the user port
  // The core's own requests (subscriptions "via proxy") go in through tunnel-in, never the user
  // port: it may ask for a password.
  int? get _innerPort => main.running ? _tunnelPort ?? _mixedPort : null;
  Probe? _probe; // probe-in: Auto's latency tests (probe.dart)

  /// Every server test of the core's modules and of the UI's pings (pool.dart), and the
  /// network status they share. `direct` = the direct path through the main sing-box's probe
  /// inbound (only asked while Auto runs, so while it is up).
  late final pool = ProbePool(direct: (url, t) async => _probe == null ? -1 : _probe!.delay('direct', url, timeoutMs: t));
  StreamSubscription<ClosedConnection>? _closed; // sing-box API: closed connections → Auto
  int _connectSeq = 0;
  final _deprecatedSeen = <String>{}; // the journal says each once per run; the raw log every time
  // Where traffic leaves: the tunnel's exit, or the machine's own IP while disconnected
  // (direct: true). null while checking, {ip, country…, direct} or {error, direct}.
  Map<String, dynamic>? _exit;
  int _exitSeq = 0;

  // What is connected, for the AutoService and a restart after a crash: the plan, the
  // system proxy asked for. null = not connected (or given up).
  Map<String, dynamic>? _plan;
  bool _sysWanted = false;
  AutoService? _auto;
  // Beside Auto while connected: rule targets' "If unavailable" (fallback.dart) and the DNS
  // servers' failover (dns_failover.dart); what the config holds for them comes from _startSingBox.
  FallbackService? _fallback;
  DnsFailover? _dns;
  List<TargetFallback> _fallbacks = const [];
  RuleNames? _ruleNames; // the running config's rules by name (Live connections)
  List<DnsEntry> _dnsServers = const [];
  bool _dnsAuto = true; // Settings → DNS → Switch automatically (connect body `dnsAuto`, POST /api/dns/auto)
  final Timer Function(Duration, void Function()) _timer;
  final DateTime Function() _now;
  // sing-box stopped on its own: {attempt, code, next} while restarting it (endless, until
  // the user disconnects)
  Map<String, dynamic>? _recovering;
  int _restarts = 0, _attempt = 0;
  late DateTime _upSince = _now();
  static const _backoff = [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 15)];
  static const _slowRetry = Duration(seconds: 30); // after the third
  static const _downAfter = Duration(seconds: 30); // since the crash: "down"
  // While restarting: when it went down (null = not yet, invisible to the user), what the
  // system proxy was then, and whether the user pressed "Disable sys proxy" (_released).
  DateTime? _downSince;
  String _downProxy = 'kept';
  bool _released = false;
  Completer<bool>? _wake; // the restart's wait; completed early by a retry / connect / disconnect
  // Kill switch: the fields arrive with connect (_applyKill)
  bool _killSwitch = false, _killOnDisconnect = false, _killWhileClosed = false;
  String _downProxyMode = 'remove'; // 'remove' | 'keep', only when the kill switch is off
  // Not connected, and the system proxy is deliberately left on: {since, reason, proxy}
  Map<String, dynamic>? _blocking;
  // starts and stops of sing-box one at a time (a user's connect vs a crash restart)
  Future<void> _serial = Future.value();

  Future<T> _locked<T>(Future<T> Function() f) {
    final r = _serial.then((_) => f());
    _serial = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  Future<void> init() async {
    await Directory(dataDir).create(recursive: true);
    events.load(); // trims an old journal at start
    final m = _readKillMarker();
    if (m != null && m['keepWhileClosed'] == true && sysProxy.isSet) {
      // left on purpose (kill switch while the app is closed): internet stays blocked
      _blocking = {'since': (m['since'] as num?)?.toInt() ?? _now().millisecondsSinceEpoch, 'reason': 'closed', 'proxy': 'kept'};
      log.note('warn', 'System proxy kept from the last run (kill switch): no internet until connect or Remove');
    } else {
      await _sysOff(); // left set by a crash
    }
    _recheckExit(); // the direct IP, shown on Home before any connect
    updater.start();
  }

  Future<void> shutdown() async {
    _connectSeq++;
    _wakeUp();
    _stopAuto();
    updater.stop();
    await main.stop();
    if (_killSwitch && _killWhileClosed && sysProxy.isSet) {
      _writeKillMarker(); // left set: the next start reports it as blocking
    } else {
      await _sysOff();
    }
  }

  // The kill switch's "also while the app is closed" has to outlive the process: the next
  // start tells a proxy left on purpose from one a crash left behind by this file.
  File get _killFile => File(p.join(dataDir, 'kill.json'));

  Map<String, dynamic>? _readKillMarker() {
    try {
      final f = _killFile;
      if (!f.existsSync()) return null;
      return (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  void _writeKillMarker() {
    try {
      final f = _killFile;
      if (_killSwitch && _killWhileClosed) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(jsonEncode({'keepWhileClosed': true, 'since': _now().millisecondsSinceEpoch}));
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  /// The kill switch fields of a connect body (a missing one stays as it was): killSwitch,
  /// killOnDisconnect (only with killSwitch), killWhileClosed (only with killSwitch),
  /// downProxy 'remove' | 'keep' (only without killSwitch).
  void _applyKill(Map<String, dynamic> body) {
    if (body['killSwitch'] is bool) _killSwitch = body['killSwitch'] as bool;
    if (body['killOnDisconnect'] is bool) _killOnDisconnect = body['killOnDisconnect'] as bool;
    if (body['killWhileClosed'] is bool) _killWhileClosed = body['killWhileClosed'] as bool;
    if (body['downProxy'] is String) _downProxyMode = body['downProxy'] == 'keep' ? 'keep' : 'remove';
    _writeKillMarker();
  }

  /// One journal entry; [note] also goes to the raw log first, so the event links to it.
  int _event(String cat, String type, String level, Map<String, dynamic> data, {bool own = false, String? note}) {
    if (note != null) log.note(level, note);
    return events.add(cat, type, level, data: data, own: own);
  }

  /// The system proxy on / back off, each one written to the journal (`core/sysProxy`,
  /// `on` = what was asked for; `error` = it did not work). Returns [SystemProxy.enable]'s
  /// warning; errors go on to the caller.
  Future<String?> _sysOn({required bool own}) async {
    try {
      final port = _sysPort ?? _mixedPort; // with a password on the user port: the open sys-in
      final w = await sysProxy.enable(port);
      _event('core', 'sysProxy', 'info', {'on': true}, own: own, note: 'System proxy on 127.0.0.1:$port');
      return w;
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': true, 'error': '$e'}, own: own, note: 'System proxy not set: $e');
      rethrow;
    }
  }

  Future<void> _sysOff({bool own = false, String? by}) async {
    final was = sysProxy.isSet;
    try {
      await sysProxy.restore();
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': false, 'by': ?by, 'error': '$e'}, own: own, note: 'System proxy not restored: $e');
      rethrow;
    }
    if (was) _event('core', 'sysProxy', 'info', {'on': false, 'by': ?by}, own: own, note: 'System proxy back off');
  }

  /// Auto in the core while connected (auto.dart). A move to another route or server
  /// changes where traffic leaves: the exit is checked again.
  void _startAuto(Map<String, dynamic> plan) {
    _stopAuto();
    final api = main.api;
    if (api == null) return; // no API service (a test's fake process)
    pool.resetNetwork(); // a new sing-box: the network is presumed up again
    final auto = _auto = AutoService(api, plan,
        pool: pool,
        delay: (tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t),
        reach: (tag, dest) async => _probe == null ? null : probeReach(_probe!, tag, dest),
        note: main.note);
    // requests that failed: sing-box's API service streams every closed connection
    _closed = api.closedConnections().listen(auto.onClosed, onError: (Object e) => main.note('auto: connection events stopped: $e'));
    auto.switches.listen((s) {
      main.note(s.isRoute ? 'auto: ${s.from} → ${s.to} (${s.reason})' : 'auto: ${s.route}: server ${s.from} → ${s.to} (${s.reason})');
      if (s.reason == 'fastest') {
        events.add('auto', 'fastest', 'info', data: {'route': s.route, 'from': s.from, 'to': s.to});
      } else {
        events.add('auto', 'switched', 'info', data: {'route': ?s.route, 'from': s.from, 'to': s.to, 'reason': s.reason});
      }
      _recheckExit();
    });
    auto.unstable.listen((u) {
      main.note('auto: ${u.id} is unstable (${u.strikes} drops), back to it after ${u.holdMs ~/ 60000} min of answers');
      events.add('auto', 'unstable', 'warn', data: {'id': u.id, 'strikes': u.strikes, 'holdMs': u.holdMs});
    });
    auto.blocked.listen((b) {
      final at = b.dest.lastIndexOf(':'), port = at < 0 ? null : int.tryParse(b.dest.substring(at + 1));
      events.add('site', 'blocked', 'warn', data: {
        'host': port == null ? b.dest : b.dest.substring(0, at),
        'port': ?port,
        'entry': b.route,
        'server': b.server,
        'dest': b.dest,
        'via': b.via,
        'viaServer': b.viaServer,
        'rule': ruleEventData(_ruleNames, b.rule),
        'process': ?processEventData(b.process),
      });
    });
    auto.unreachable.listen((u) {
      final at = u.dest.lastIndexOf(':'), port = at < 0 ? null : int.tryParse(u.dest.substring(at + 1));
      events.add('site', 'unreachable', 'warn', data: {
        'host': port == null ? u.dest : u.dest.substring(0, at),
        'port': ?port,
        'entry': u.route,
        'server': u.server,
        'dest': u.dest,
        'tried': [for (final t in u.tried) {'entry': t.route, 'server': t.server}],
        if (u.retriesOff) 'retries': 'off',
        'rule': ruleEventData(_ruleNames, u.rule),
        'process': ?processEventData(u.process),
      });
    });
    auto.net.listen((n) {
      final (type, level) = switch (n.kind) {
        'lost' => ('lost', 'warn'),
        'restored' => ('restored', 'info'),
        'offline' => ('offline', 'warn'),
        _ => ('online', 'info'),
      };
      events.add('conn', type, level, data: {'downMs': ?n.downMs});
    });
    auto.start();
    _startFallback(api, auto);
    _startDnsFailover(api, auto);
  }

  /// "If unavailable" live: a target that stops answering has its rules' selectors flipped to
  /// the fallback, and back (fallback.dart). Not while Auto doubts the network.
  void _startFallback(SingBoxApi api, AutoService auto) {
    if (_fallbacks.isEmpty) return;
    final fb = _fallback = FallbackService(api, _fallbacks,
        delay: (tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t),
        settings: auto.settings,
        pool: pool,
        mainIdentity: auto.identityOf,
        note: main.note);
    fb.changes.listen((c) {
      // the journal names the first rule (else the first app) and counts the rest
      final total = c.rules.length + c.apps.length;
      final data = {
        if (c.rules.isNotEmpty) 'rule': c.rules.first else 'app': c.apps.first,
        if (total > 1) 'more': total - 1,
        'target': c.target,
      };
      if (c.back) {
        events.add('rules', 'targetBack', 'info', data: data);
      } else {
        events.add('rules', 'fallback', 'warn', data: {...data, 'to': c.to});
      }
    });
    fb.start();
  }

  /// DNS failover: the servers in use are checked and the clash mode set to the best one
  /// that answers (dns_failover.dart). A new sing-box starts on the mode `Rule` = the first
  /// server in use (`dns.final`), which is where the service starts too.
  void _startDnsFailover(SingBoxApi api, AutoService auto) {
    if (_dnsServers.isEmpty) return;
    final probe = _probe;
    if (probe == null) return;
    final dns = _dns = DnsFailover(_dnsServers,
        setMode: api.setClashMode,
        query: (tag, name, t) => probeDns(probe, tag, name, timeoutMs: t),
        settings: auto.settings,
        auto: _dnsAuto,
        pool: pool,
        note: main.note);
    dns.switches.listen((s) => _event('dns', 'switched', 'info', {'from': s.from, 'to': s.to, 'reason': s.reason}, own: s.reason == 'off'));
    dns.start();
  }

  void _stopAuto() {
    unawaited(_closed?.cancel());
    _closed = null;
    _auto?.stop();
    _auto = null;
    _fallback?.stop();
    _fallback = null;
    _dns?.stop();
    _dns = null;
    pool.resetNetwork(); // no sing-box, no status to hold on to
  }

  /// sing-box stopped on its own. The system proxy is NOT touched: sing-box is started
  /// again in the background with the same plan on the route Auto was on, invisibly to the
  /// user (`connected` stays true), after 1, 4, 15 s and then every 30 s, for as long as the
  /// user stays connected. The count of tries starts over once it ran for a minute.
  /// 30 s after the crash the connection is "down" ([_goDown]).
  void _crashed(int code) {
    final plan = _plan;
    if (plan == null) return;
    final seq = _connectSeq, at = _auto?.index;
    _stopAuto();
    main.note('sing-box stopped on its own (exit code $code)');
    events.add('core', 'crashed', 'error', data: {'code': code});
    if (_now().difference(_upSince) > const Duration(minutes: 1)) _attempt = 0;
    _downSince = null;
    _released = false;
    _recover(seq, at == null ? plan : {...plan, 'current': at}, code);
  }

  Future<void> _recover(int seq, Map<String, dynamic> plan, int code) async {
    final crashed = _now();
    _recovering = {'attempt': _attempt + 1, 'code': code};
    while (seq == _connectSeq) {
      final wait = _attempt < _backoff.length ? _backoff[_attempt] : _slowRetry;
      _attempt++;
      _recovering = {'attempt': _attempt, 'code': code, 'next': _now().add(wait).millisecondsSinceEpoch};
      var woke = false;
      var left = wait;
      if (_downSince == null) {
        final toDown = crashed.add(_downAfter).difference(_now());
        if (toDown <= wait) {
          // "down" comes before the next try
          if (toDown > Duration.zero) woke = await _pause(toDown);
          if (seq != _connectSeq) return;
          if (woke) {
            left = Duration.zero;
          } else {
            await _goDown(seq);
            if (seq != _connectSeq) return;
            if (toDown > Duration.zero) left = wait - toDown;
          }
        }
      }
      if (!woke && left > Duration.zero) woke = await _pause(left);
      if (seq != _connectSeq) return;
      final ok = await _locked(() async {
        if (seq != _connectSeq) return true; // connected or disconnected meanwhile
        final RuleSetFetch lists;
        final warnings = ['sing-box stopped (exit code $code) and was started again'];
        try {
          final (l, w) = await _startSingBox(plan, sys: _sysWanted); // the same path as a connect
          lists = l;
          warnings.addAll(w);
        } catch (e) {
          main.note('restart $_attempt failed: $e');
          // the journal gets the first ones only: a dead server retried every 30 s would fill it
          if (_attempt <= _backoff.length) events.add('core', 'restartFailed', 'error', data: {'attempt': _attempt, 'error': '$e'});
          return false;
        }
        _plan = plan;
        _upSince = _now();
        _recovering = null;
        _restarts++;
        final wasDown = _downSince != null;
        final downMs = _now().difference(crashed).inMilliseconds;
        _downSince = null;
        _released = false;
        _event('core', 'restarted', 'info', {'attempt': _attempt, if (wasDown) 'downMs': downMs},
            note: 'sing-box started again (attempt $_attempt)');
        if (_sysWanted && !sysProxy.isSet) {
          // it was taken off while down (or released by the user): the connection is back in full
          try {
            warnings.add(await _sysOn(own: false) ?? '');
          } catch (e) {
            warnings.add('System proxy not set again: $e');
          }
        }
        _warning = joinWarnings(warnings);
        _startAuto(plan);
        _recheckExit();
        _refreshLists(seq, plan, lists);
        return true;
      });
      if (ok) return;
    }
  }

  /// Waits [d]; true = cut short ([_wakeUp]: a retry, or a connect / disconnect / shutdown).
  Future<bool> _pause(Duration d) async {
    final c = _wake = Completer<bool>();
    final t = _timer(d, () {
      if (!c.isCompleted) c.complete(false);
    });
    final woke = await c.future;
    t.cancel();
    if (identical(_wake, c)) _wake = null;
    return woke;
  }

  void _wakeUp() {
    final c = _wake;
    if (c != null && !c.isCompleted) c.complete(true);
  }

  /// 30 s of restarting without success: `status.down`, the event. The system proxy stays
  /// with the kill switch on and with downProxy 'keep' (traffic is blocked for programs that
  /// obey it); otherwise it goes back (traffic is direct). Tries go on either way.
  Future<void> _goDown(int seq) async {
    if (!_killSwitch && _downProxyMode == 'remove' && !_released && sysProxy.isSet) {
      try {
        await _sysOff();
      } catch (e) {
        main.note('system proxy not restored: $e');
      }
      if (seq == _connectSeq) _recheckExit(); // traffic goes direct now
    }
    if (seq != _connectSeq) return;
    _downSince = _now();
    _downProxy = _released ? 'released' : (sysProxy.isSet ? 'kept' : 'removed');
    _event('core', 'down', 'error', {'proxy': _downProxy}, note: 'Connection down: sing-box does not start (system proxy $_downProxy)');
  }

  /// POST /api/killswitch: the same four fields as a connect's, changed while connected (or
  /// blocked), no restart of sing-box. They count for the next down / disconnect / shutdown;
  /// what already happened is re-decided at once: while down, the system proxy is set
  /// again (kill switch on, or downProxy 'keep') or taken off (both off, 'remove'), unless the
  /// user released it; while blocking, the proxy goes back when the setting that justified the
  /// block (killOnDisconnect / killWhileClosed, with killSwitch) is off now.
  Future<Map<String, dynamic>> _killSwitchSettings(Map<String, dynamic> body) async {
    _applyKill(body);
    try {
      if (_downSince != null && !_released) {
        final keep = _killSwitch || _downProxyMode == 'keep';
        if (keep && !sysProxy.isSet && _sysWanted) {
          await _sysOn(own: true);
        } else if (!keep && sysProxy.isSet) {
          await _sysOff(own: true);
          _recheckExit(); // traffic goes direct now
        }
        _downProxy = sysProxy.isSet ? 'kept' : 'removed';
      }
      final b = _blocking;
      if (b != null && b['proxy'] == 'kept') {
        final holds = _killSwitch && (b['reason'] == 'closed' ? _killWhileClosed : _killOnDisconnect);
        if (!holds) {
          await _sysOff(own: true);
          _blocking = null;
        }
      }
    } catch (e) {
      main.note('kill switch settings: the system proxy was not changed: $e'); // the event has it
    }
    return _status();
  }

  /// POST /api/sysproxy/release: the user takes the system proxy off now ("Disable sys proxy"
  /// in the down alert, "Remove" on the blocked plaque). Tries to restart go on.
  Future<Map<String, dynamic>> _release() async {
    if (_recovering != null || _downSince != null) {
      _released = true;
      await _sysOff(own: true, by: 'user');
      if (_downSince != null) _downProxy = 'released';
    } else if (_blocking != null && _blocking!['proxy'] == 'kept') {
      await _sysOff(own: true, by: 'user');
      _blocking = {..._blocking!, 'proxy': 'released'};
    }
    return _status();
  }

  /// POST /api/retry: a restart now, instead of waiting out the pause (the next pause
  /// starts over). Nothing to do unless sing-box is being restarted.
  Future<Map<String, dynamic>> _retry() async {
    if (_recovering != null) _wakeUp();
    return _status();
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      final host = (req.headers.host ?? '').toLowerCase();
      if (host != '127.0.0.1' && host != 'localhost' && !lanHosts.contains(host)) return await _send(res, 403, {'error': 'bad host'});
      final path = req.uri.path;
      if (req.method == 'GET' && (path == '/' || path == '/index.html')) return await _serveUi(res);
      if (!path.startsWith('/api/')) return await _send(res, 404, {'error': 'not found'});
      if (req.headers.value('x-jorm') != '1') return await _send(res, 403, {'error': 'missing X-Jorm header'});
      final body = req.method == 'POST' || req.method == 'PUT'
          ? await _readBody(req)
          : const <String, dynamic>{};
      if (req.method == 'POST' && path == '/api/ping') return await _ping(body, res);
      if (req.method == 'POST' && path == '/api/speedtest') return await _speedTest(body, res);
      if (req.method == 'DELETE' && (path == '/api/connections' || path.startsWith('/api/connections/'))) {
        return await _send(res, 200, await _closeConnections(path.length > 17 ? Uri.decodeComponent(path.substring(17)) : null));
      }
      final out = await switch ('${req.method} $path') {
        'GET /api/state' => _state(),
        'PUT /api/state' => _saveState(body),
        'GET /api/status' => _status(),
        'GET /api/traffic' => _traffic(),
        'GET /api/log' => Future.value(log.since(int.tryParse(req.uri.queryParameters['since'] ?? ''))),
        'DELETE /api/log' => Future(() {
            log.clear();
            return {'ok': true};
          }),
        'GET /api/events' => Future.value(events.since(int.tryParse(req.uri.queryParameters['since'] ?? ''))),
        'POST /api/events' => Future(() => _postEvent(body)),
        'DELETE /api/events' => Future(() {
            events.clear();
            return {'ok': true};
          }),
        'GET /api/version' => _version(),
        'POST /api/node' => Future(() => {'node': _manualNode(body).toJson()}),
        'POST /api/share' => Future.value({'link': _share(body)}),
        'POST /api/sources/fetch' => _fetch(body),
        'POST /api/parse' => Future.value(_parse(body)),
        'POST /api/connect' => _connect(body),
        'POST /api/disconnect' => _disconnect(),
        'POST /api/sysproxy/release' => _release(),
        'POST /api/retry' => _retry(),
        'POST /api/killswitch' => _killSwitchSettings(body),
        'POST /api/auto' => _autoSettings(body),
        'POST /api/dns/auto' => _dnsAutoSetting(body),
        'POST /api/exit' => Future(() {
            _recheckExit();
            return _status();
          }),
        _ => null,
      };
      if (out == null) return await _send(res, 404, {'error': 'no route ${req.method} $path'});
      return await _send(res, 200, out);
    } on FormatException catch (e) {
      return await _send(res, 400, {'error': e.message}); // a message for the user (manual server form)
    } catch (e, st) {
      log.note('error', '${req.method} ${req.uri.path}: $e');
      stderr.writeln('[jormd] ${req.method} ${req.uri.path}: $e\n$st');
      return await _send(res, 500, {'error': '$e'});
    }
  }

  // An empty body is `{}` (release / retry / disconnect carry nothing).
  Future<Map<String, dynamic>> _readBody(HttpRequest req) async {
    final text = await utf8.decodeStream(req);
    return text.trim().isEmpty ? const {} : (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  Future<void> _send(HttpResponse res, int code, Object body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    res.write(jsonEncode(body));
    await res.close();
  }

  // The mockup, read on every request so a rebuild shows on reload. The flag tells it
  // to use the core instead of its mock data before its first line runs.
  Future<void> _serveUi(HttpResponse res) async {
    final html = await File(uiFile).readAsString();
    res.headers.contentType = ContentType.html;
    res.headers.set('Cache-Control', 'no-store');
    res.write(html.replaceFirst('<script>', '<script>window.JORMD = true;</script>\n<script>'));
    await res.close();
  }

  Future<Map<String, dynamic>> _state() async => {
        'snapshot': await store.read(),
        'status': await _status(),
      };

  // A source the timer updated after the UI last looked keeps the core's server fields
  // (state.dart).
  Future<Map<String, dynamic>> _saveState(Map<String, dynamic> body) async {
    await store.save((body['snapshot'] as Map?)?.cast<String, dynamic>());
    return {'ok': true};
  }

  /// Speed, session totals and open connections (see traffic.dart); `running: false`
  /// with zeros when sing-box is not up.
  Future<Map<String, dynamic>> _traffic() async {
    final api = main.api;
    if (!main.running || api == null) {
      return {'running': false, 'down': 0, 'up': 0, 'downTotal': 0, 'upTotal': 0, 'tcp': 0, 'udp': 0, 'conns': []};
    }
    return {'running': true, ...trafficOf(api, names: _ruleNames)};
  }

  /// `connected` stays true while a crashed sing-box is being started again
  /// (`recovering`, then `down` after 30 s); `blocking` = not connected and the system proxy
  /// left on by the kill switch; `auto` = what Auto really uses and measured (auto.dart → toJson).
  Future<Map<String, dynamic>> _status() async => {
        'connected': main.running || _recovering != null,
        'systemProxy': sysProxy.isSet,
        'sysPort': main.running || _recovering != null ? _sysPort : null,
        'error': _error,
        'warning': _warning,
        'exit': _exit,
        'recovering': _recovering,
        'down': _downSince == null
            ? null
            : {'since': _downSince!.millisecondsSinceEpoch, 'attempt': _attempt, 'proxy': _downProxy},
        'blocking': _blocking,
        'restarts': _restarts,
        'auto': await _autoState(),
        'network': pool.toJson(),
        'dns': main.running ? _dns?.toJson() : null,
        'sourcesRev': store.rev, // moves when the timer updated a subscription: the UI reloads them
      };

  Future<Map<String, dynamic>?> _autoState() async {
    final auto = _auto;
    if (auto == null || !main.running) return null;
    return identical(auto, _auto) ? auto.toJson() : null;
  }

  /// Asks where traffic leaves: through the tunnel after every (re)connect, directly at
  /// start and after a disconnect, and on demand. A check that finishes after a newer one
  /// started is dropped.
  /// Every service failing at once, fast, means the tunnel itself is not carrying yet (a
  /// urltest group still on an untested dead server right after connect): ask again in a
  /// couple of seconds, for up to 15 s, before reporting the error.
  void _recheckExit() {
    final seq = ++_exitSeq;
    _exit = null;
    final direct = !main.running;
    final since = Stopwatch()..start();
    Future<void> attempt() async {
      final sw = Stopwatch()..start();
      try {
        final e = await exitCheck(direct ? null : _tunnelPort ?? _mixedPort);
        if (seq == _exitSeq) _exit = {...e, 'direct': direct, 'at': DateTime.now().millisecondsSinceEpoch};
      } catch (e) {
        if (seq != _exitSeq) return;
        if (!direct && sw.elapsed < const Duration(seconds: 3) && since.elapsed < const Duration(seconds: 15) && main.running) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (seq == _exitSeq) return attempt();
          return;
        }
        _exit = {'error': '$e', 'direct': direct};
      }
    }

    attempt();
  }

  /// body: {sid, source: {url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid,
  /// filter, channel}, rediscover} → {patch, title, notModified, via} (updater.dart).
  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> body) async {
    final s = ((body['source'] as Map?) ?? const {}).cast<String, dynamic>();
    return updater.guard(
      body['sid'] as String?,
      () async => updateSubscription(
        s,
        hwid: s['hwid'] == true ? await _hwid : null,
        proxyPort: _innerPort,
        rediscover: body['rediscover'] == true,
      ),
    );
  }

  Map<String, dynamic> _parse(Map<String, dynamic> body) =>
      {'nodes': [for (final n in parseLinks('${body['text'] ?? ''}')) n.toJson()]};

  /// The one way sing-box is started, by a connect and by a restart after a crash: the
  /// rule lists on disk first (ones via VPN that are missing wait for the tunnel — the
  /// old one, if it still runs), a fresh tunnel-in port, the config. The lists used and
  /// the config's warnings. [sys]: the system proxy is asked for; with a password on the
  /// user port it needs its own open inbound (`sys-in`, [_sysInPort]).
  Future<(RuleSetFetch, List<String>)> _startSingBox(Map<String, dynamic> plan, {required bool sys}) async {
    final lists = await ruleSets.ensureFor(plan, proxyPort: main.running ? _tunnelPort : null);
    final warnings = <String>[];
    final mixed = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    final tunnelPort = await freePort(exclude: {mixed});
    final probePort = await freePort(exclude: {mixed, tunnelPort});
    final sysPort = sys && plan['mixedAuth'] != null ? await _sysInPort({mixed, tunnelPort, probePort}) : null;
    final probe = Probe(probePort);
    final info = RoutingInfo();
    await main.start(buildConfig(plan,
        tunnelPort: tunnelPort, sysPort: sysPort, probe: probe, ruleSetFiles: lists.files, warnings: warnings, info: info));
    _sysPort = sysPort;
    // what a later sing-box will no longer take in this config
    try {
      for (final w in await main.api!.deprecatedWarnings()) {
        log.note('warn', 'sing-box: $w');
        if (_deprecatedSeen.add(w)) events.add('core', 'deprecated', 'warn', data: {'text': w});
      }
    } catch (_) {}
    _probe = probe;
    _fallbacks = info.fallbacks;
    _ruleNames = info.ruleNames;
    _dnsServers = info.dnsServers;
    _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    _tunnelPort = tunnelPort;
    return (lists, warnings);
  }

  /// The loopback port of `sys-in`, the open inbound the system proxy points at while the user
  /// port has a password. Picked once and kept in `<dataDir>/sys-in.json`: a proxy left in the
  /// registry (kill switch) must still hit it after a restart of sing-box or of jormd. Reused
  /// while free (or held by our own running sing-box); a busy one is replaced by a new pick.
  Future<int> _sysInPort(Set<int> taken) async {
    final f = File(p.join(dataDir, 'sys-in.json'));
    int? saved;
    try {
      saved = ((jsonDecode(f.readAsStringSync()) as Map)['port'] as num?)?.toInt();
    } catch (_) {}
    if (saved != null && !taken.contains(saved) && ((main.running && saved == _sysPort) || await portIsFree(saved))) return saved;
    final port = await freePort(exclude: taken);
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'port': port}));
    } catch (_) {} // not kept: the next connect picks again
    return port;
  }

  /// Through the tunnel now: missing lists (then a restart picks them up, on the route
  /// Auto is on), stale ones (replaced in place, sing-box reloads a local rule set itself).
  void _refreshLists(int seq, Map<String, dynamic> plan, RuleSetFetch lists) {
    ruleSets.ensureFor(plan, proxyPort: _tunnelPort, refresh: true).then((now) {
      if (seq == _connectSeq && main.running && now.files.keys.any((t) => !lists.files.containsKey(t))) {
        final at = _auto?.index;
        _connect({'plan': at == null ? plan : {...plan, 'current': at}, 'systemProxy': _sysWanted}, own: false).then((_) {}, onError: (_) {});
      }
    }, onError: (_) {});
  }

  /// body: {plan (see config.dart), systemProxy: bool}. [own]: the user asked (the journal
  /// marks it so no notification comes of it); the reconnect that picks up lists is not.
  Future<Map<String, dynamic>> _connect(Map<String, dynamic> body, {bool own = true}) async {
    final plan = (body['plan'] as Map).cast<String, dynamic>();
    final seq = ++_connectSeq;
    _wakeUp();
    _recovering = null;
    _downSince = null;
    _released = false;
    final wasBlocking = _blocking;
    _blocking = null; // a connect ends the blocking
    _applyKill(body);
    if (body['dnsAuto'] is bool) _dnsAuto = body['dnsAuto'] as bool;
    _stopAuto();
    _error = null;
    _warning = null;
    await _locked(() async {
      if (seq != _connectSeq) return; // a newer connect / disconnect came in
      try {
        _plan = null;
        final sys = body['systemProxy'] == true;
        final (lists, warnings) = await _startSingBox(plan, sys: sys);
        _plan = plan;
        _sysWanted = sys;
        _upSince = _now();
        _attempt = 0;
        _startAuto(plan);
        _recheckExit();
        if (_sysWanted) {
          warnings.add(await _sysOn(own: own) ?? '');
        } else {
          await _sysOff(own: own);
        }
        _warning = joinWarnings(warnings);
        log.note('info', 'Connected: ${plan['kind']}, proxy on 127.0.0.1:$_mixedPort${_sysWanted ? ', system proxy on' : ''}');
        if (_warning != null) log.note('warn', _warning!);
        _refreshLists(seq, plan, lists);
        events.add('conn', 'connected', 'info', own: own, data: _connectedData(plan));
      } catch (e) {
        _error = '$e';
        log.note('error', 'Connect failed: $e');
        events.add('conn', 'connectFailed', 'error', own: own, data: {'reason': '$e'});
        if (wasBlocking != null && _killSwitch && sysProxy.isSet) {
          _blocking = wasBlocking; // still blocked: only a connect that works, or Remove, ends it
        } else {
          await _sysOff(own: own);
        }
        rethrow;
      }
    });
    return _status();
  }

  // conn/connected: the entry Auto starts on and its server when known (a Fastest group
  // has none until urltest picked), the mode (TUN is not built yet) and the routing.
  Map<String, dynamic> _connectedData(Map<String, dynamic> plan) {
    final routes = planRoutes(plan);
    final i = planCurrent(plan, routes.length);
    final server = _auto?.toJson()['server'];
    return {
      'entry': '${routes[i]['id'] ?? routeTag(i)}',
      'server': ?server,
      'mode': plan['mode'] == 'tun' ? 'tun' : 'proxy',
      'route': plan['global'] == true ? 'global' : 'rules',
    };
  }

  /// body: {auto} — Settings → Auto mode changed while connected: the running AutoService
  /// takes it at its next round, no reconnect (none of it is in the sing-box config).
  Future<Map<String, dynamic>> _autoSettings(Map<String, dynamic> body) async {
    final plan = _plan, auto = body['auto'];
    if (plan != null && auto is Map) {
      _plan = {...plan, 'auto': auto};
      final s = _auto?.settings = AutoSettings.fromPlan(_plan!);
      if (s != null) {
        _fallback?.settings = s;
        _dns?.settings = s;
      }
    }
    return _status();
  }

  /// body: {auto: bool} — Settings → DNS → Switch automatically, live (no reconnect). Off puts
  /// the first server in use back at once.
  Future<Map<String, dynamic>> _dnsAutoSetting(Map<String, dynamic> body) async {
    if (body['auto'] is bool) {
      _dnsAuto = body['auto'] as bool;
      await _dns?.setAuto(_dnsAuto);
    }
    return _status();
  }

  Future<Map<String, dynamic>> _disconnect() async {
    final seq = ++_connectSeq;
    _wakeUp(); // ends the restart's retries
    final was = main.running || _plan != null || _recovering != null;
    _plan = null;
    _recovering = null;
    _downSince = null;
    _released = false;
    _stopAuto();
    await _locked(() async {
      if (seq == _connectSeq) await main.stop();
    });
    _tunnelPort = null;
    log.note('info', 'Disconnected');
    if (was) events.add('conn', 'disconnected', 'info', own: true, data: {'by': 'user'});
    if (_killSwitch && _killOnDisconnect && sysProxy.isSet && (was || _blocking != null)) {
      // kill switch, "also after I disconnect": the proxy stays, nothing gets out
      _blocking ??= {'since': _now().millisecondsSinceEpoch, 'reason': 'disconnect', 'proxy': 'kept'};
    } else {
      _blocking = null;
      await _sysOff(own: true);
    }
    _recheckExit(); // now the direct IP
    _error = null;
    _warning = null;
    return _status();
  }

  static final _eventType = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');
  static const _eventDataMax = 4096; // JSON characters

  /// body: {cat, type, level, own?, data?} → {id}: an event the UI knows first (the
  /// subscription updates it ran itself, the user's own actions). Not linked to a raw line.
  /// A bad shape is a 400 with the reason.
  Map<String, dynamic> _postEvent(Map<String, dynamic> body) {
    final cat = body['cat'], type = body['type'], level = body['level'], own = body['own'], data = body['data'] ?? const {};
    if (cat is! String || !EventBook.cats.contains(cat)) throw const FormatException('bad event cat');
    if (type is! String || !_eventType.hasMatch(type)) throw const FormatException('bad event type');
    if (level is! String || !EventBook.levels.contains(level)) throw const FormatException('bad event level');
    if (own != null && own is! bool) throw const FormatException('bad event own');
    if (data is! Map) throw const FormatException('event data must be an object');
    if (jsonEncode(data).length > _eventDataMax) throw const FormatException('event data too large');
    return {'id': events.add(cat, type, level, data: data.cast<String, dynamic>(), own: own == true, link: false)};
  }

  String? _singBoxVer;
  Future<Map<String, dynamic>> _version() async => {
        'core': coreVersion,
        'singBox': _singBoxVer ??= await singBoxVersion(singBox),
        'dataDir': dataDir,
        'dart': Platform.version.split(' ').first,
        'os': Platform.operatingSystem,
      };

  /// body: {protocol, address, port, secret, name, outbound?, unsupported?} — see manual.dart.
  Node _manualNode(Map<String, dynamic> body) => manualNode(
        protocol: '${body['protocol'] ?? ''}',
        address: '${body['address'] ?? ''}',
        port: int.tryParse('${body['port'] ?? ''}') ?? 0,
        secret: '${body['secret'] ?? ''}',
        name: '${body['name'] ?? ''}',
        outbound: (body['outbound'] as Map?)?.cast<String, dynamic>(),
        unsupported: body['unsupported'] as String?,
      );

  /// body: {outbound, name, flag, unsupported?} → the share link, or null (see share.dart).
  String? _share(Map<String, dynamic> body) => shareLink(
        ((body['outbound'] as Map?) ?? const {}).cast<String, dynamic>(),
        name: '${body['name'] ?? ''}',
        flag: '${body['flag'] ?? ''}',
        unsupported: body['unsupported'] as String?,
      );

  /// Closes one open connection ([id] from /api/traffic) or all of them, through sing-box's
  /// API service (with its secret, runtime.dart). Not connected: nothing to close.
  Future<Map<String, dynamic>> _closeConnections(String? id) async {
    final api = main.api;
    if (!main.running || api == null) return {'ok': false};
    if (!await (id == null ? api.closeAllConnections() : api.closeConnection(id))) throw SingBoxError('sing-box did not answer');
    log.note('info', id == null ? 'Closed all connections' : 'Closed connection $id');
    return {'ok': true};
  }

  /// body: {nodes: [{key, outbound}], pairs: [{key, entry: {outbound}, exit: {outbound}}], url?}
  /// Streams one NDJSON line per result as soon as it is measured —
  /// `{"kind":"n"|"p","key":…,"ms":…}` (-1 = no answer) — then `{"done":true}`,
  /// or `{"error":…}` if the tester could not start.
  /// body: {node: {key, outbound}} or {pair: {key, entry: {outbound}, exit: {outbound}}},
  /// configUrl? Streams NDJSON as the test goes — `{phase (0 latency, 1 download,
  /// 2 upload, 3 done), down, up (bit/s), downRpm, upRpm, latency (ms), elapsed (ms),
  /// final}` — the last with `final: true` (and `error` when it failed); `{"error":…}`
  /// when the tester could not start. Stops when the page goes away.
  Future<void> _speedTest(Map<String, dynamic> body, HttpResponse res) async {
    res.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    res.bufferOutput = false;
    final gone = Completer<void>();
    void line(Object o) {
      if (gone.isCompleted) return;
      try {
        res.write('${jsonEncode(o)}\n');
      } catch (_) {
        gone.complete();
      }
    }

    unawaited(res.done.then((_) {}, onError: (_) {}).whenComplete(() {
      if (!gone.isCompleted) gone.complete();
    }));
    try {
      await speedTest(
        binary: singBox,
        workDir: p.join(dataDir, 'run', 'speed'),
        node: body['node'] as Map?,
        pair: body['pair'] as Map?,
        configUrl: '${body['configUrl'] ?? ''}',
        cancel: gone.future,
        onProgress: (x) => line({
          'phase': x.phase,
          'down': x.downloadCapacity.toInt(),
          'up': x.uploadCapacity.toInt(),
          'downRpm': x.downloadRPM,
          'upRpm': x.uploadRPM,
          'latency': x.idleLatencyMs,
          'elapsed': x.elapsedMs.toInt(),
          'final': x.isFinal,
          if (x.error.isNotEmpty) 'error': x.error,
        }),
      );
    } catch (e) {
      line({'error': '$e', 'final': true});
    }
    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _ping(Map<String, dynamic> body, HttpResponse res) async {
    final nodes = (body['nodes'] as List? ?? const []).cast<Map>();
    final pairs = (body['pairs'] as List? ?? const []).cast<Map>();
    res.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    res.bufferOutput = false;
    void line(Object o) => res.write('${jsonEncode(o)}\n');
    try {
      var network = pool.status;
      if (nodes.isNotEmpty || pairs.isNotEmpty) {
        final r = await measureLatency(
          binary: singBox,
          workDir: p.join(dataDir, 'run', 'ping-${_pingSeq++ % 8}'),
          nodes: nodes,
          pairs: pairs,
          url: (body['url'] as String?) ?? defaultTestUrl,
          checkers: planCheckers({'urlTest': body}),
          pool: pool,
          maxAge: Duration(milliseconds: (body['maxAgeMs'] as num?)?.toInt() ?? 0),
          // bufferOutput is off: every line leaves at once.
          onResult: (kind, key, ms) => line({'kind': kind, 'key': key, 'ms': ms}),
        );
        network = r.network;
      }
      line({'done': true, 'network': network.name});
    } catch (e) {
      line({'error': '$e'});
    }
    await res.close();
  }
}
