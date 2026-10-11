import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'api.dart';
import 'appupdate.dart';
import 'auto.dart';
import 'config.dart';
import 'device.dart';
import 'dns_failover.dart';
import 'durable.dart';
import 'elevation.dart';
import 'eventbook.dart';
import 'exitip.dart';
import 'failures.dart';
import 'fallback.dart';
import 'ignored_sites.dart';
import 'localsource.dart';
import 'logbook.dart';
import 'manual.dart' as manual;
import 'node.dart';
import 'parse/links.dart';
import 'plan.dart';
import 'pool.dart';
import 'probe.dart';
import 'redact.dart';
import 'report.dart';
import 'report_upload.dart';
import 'routing.dart';
import 'rulenames.dart';
import 'rulesets.dart';
import 'runtime.dart' hide speedTest;
import 'runtime.dart' as core_speed show speedTest;
import 'sbapi.dart';
import 'share.dart';
import 'sitecheck.dart';
import 'state.dart';
import 'sysproxy.dart';
import 'traffic.dart';
import 'tun_ingress.dart';
import 'updater.dart';

/// The core as an object: everything jormd's HTTP API does, without HTTP (daemon.dart is
/// only the adapter over it). Pure Dart, one instance per process: the Flutter app creates
/// it and calls it directly; the platform parts are injected (see below).
///
/// It holds the state of the connection (sing-box, Auto, the system proxy and the kill
/// switch, the restarts after a crash), the journal and the log, the snapshot of the UI,
/// the subscription timer. Payloads are the maps of the HTTP API (see [CoreApi]); what the
/// app would otherwise poll arrives on [statusChanges], [eventStream] and [logStream].
///
/// Platform seams, each with the desktop implementation as the default:
/// - [runner] / [boxFactory]: how sing-box runs ([BoxRunner]; a process, later libbox);
/// - [sysProxy]: the OS system proxy ([SystemProxyBackend]; [NoSystemProxy] on mobile);
/// - [isElevated]: whether the process may bring TUN up;
/// - [exitCheck], [timer], [now]: probes past loopback, the restart waits, the clock
///   (replaced by tests).
class CoreService implements CoreApi {
  CoreService({
    required this.singBox,
    required this.dataDir,
    BoxRunner? runner,
    BoxFactory? boxFactory,
    SystemProxyBackend? sysProxy,
    this.exitCheck = checkExitIp,
    Timer Function(Duration, void Function())? timer,
    DateTime Function()? now,
    bool Function()? isElevated,
    this.appVersion,
    String? knownSingBoxVersion,
    this.updatePlatformKeys = const [],
    this.installedPackage,
    String? ownPackage,
    this.updateFeeds,
    this.updatePublicKeys,
    this.updateGet,
    this.updateFirstDelay = const Duration(seconds: 10),
    SiteChecker? siteChecker,
    Stream<NetworkQualityTestProgress> Function(String outbound)? currentSpeedSource,
    ReportUploader? reportUploader,
    this.reportDeadline = reportSendDeadline,
  })  : _singBoxVer = knownSingBoxVersion,
        reportUploader = reportUploader ?? const NotConfiguredUploader(),
        _ownPackage = ownPackage,
        _siteCheckerArg = siteChecker,
        _currentSpeedSource = currentSpeedSource,
        boxFactory = boxFactory ?? ((dir) => SingBoxProcess(singBox, dir)),
        _isElevated = isElevated ?? processIsElevated,
        _timer = timer ?? Timer.new,
        _now = now ?? DateTime.now,
        sysProxy = sysProxy ??
            (Platform.isAndroid || Platform.isIOS ? NoSystemProxy() : SystemProxy(File(p.join(dataDir, 'sysproxy.saved.json')))),
        ruleSets = RuleSetCache(p.join(dataDir, 'rulesets')) {
    runner ??= this.boxFactory(p.join(dataDir, 'run', 'main'));
    this.runner = runner;
    runner.onExit = _crashed;
    runner.onLog = (line) {
      logBook.singBox(line);
      _auto?.onLog(line);
      failures.onLog(line);
      tunIngress.onLine(line);
    };
    ruleSets.onFailed = (tag, url, error) => _event('rules', 'ruleSetFailed', 'warn', {'tag': tag, 'url': url, 'error': error},
        note: 'Rule set $tag not downloaded ($url): $error');
    ruleSets.onUpdated = (tag) => _event('rules', 'ruleSetUpdated', 'info', {'tag': tag}, note: 'Rule set $tag updated');
  }

  /// The sing-box binary (desktop): its version, the programs TUN lets go direct, the
  /// throwaway sing-boxes of the tests.
  final String singBox;
  final String dataDir;

  /// The running app's version (semver + build) and the update asset keys of this device
  /// (`updatePlatforms`): with a version the core checks the feeds for a newer one (appupdate.dart).
  /// [updateFeeds] / [updateGet] / [updateFirstDelay] are the tests' seams.
  final AppVersion? appVersion;
  final List<String> updatePlatformKeys;

  /// The file the running app was installed from (Android `sourceDir`), if the platform can read it:
  /// updates then download a delta against it instead of the whole file ([AppUpdater.installedPackage]).
  final String? installedPackage;
  final List<String>? updateFeeds;
  final List<String>? updatePublicKeys;
  final UpdateGet? updateGet;
  final Duration updateFirstDelay;

  /// The external checker that tells a site down for everyone from one blocked only for the user
  /// (sitecheck.dart); asks through the tunnel. [siteChecker] is the tests' seam.
  final SiteChecker? _siteCheckerArg;
  late final SiteChecker siteChecker = _siteCheckerArg ?? SiteChecker(proxyPort: () => _innerPort);

  /// The network quality test of the running connection ([speedTest] with `current`): by default
  /// the main sing-box's API service; the tests' seam.
  final Stream<NetworkQualityTestProgress> Function(String outbound)? _currentSpeedSource;
  Map<String, dynamic>? _lastSpeed; // the last finished test of the connection (`last-speed.json`)
  File get _speedFile => File(p.join(dataDir, 'last-speed.json'));

  /// Where "Send report" delivers the gzipped report (report_upload.dart); by default nowhere.
  final ReportUploader reportUploader;

  /// The main sing-box (the connection).
  late final BoxRunner runner;

  /// Makes the throwaway sing-boxes (latency tests, Speed Test).
  final BoxFactory boxFactory;
  final SystemProxyBackend sysProxy;
  final bool Function() _isElevated;
  // the programs that go direct in TUN: this process and the sing-box binary (desktop), the
  // app's package (Android; the constructor's `ownPackage`, else the process's own name) —
  // config.dart, outside_tunnel.dart
  late final List<String> _selfPaths = selfProcessPaths(singBox);
  final String? _ownPackage;
  late final List<String> _selfPackages = selfPackageNames(package: _ownPackage);
  final RuleSetCache ruleSets;
  final Future<Map<String, dynamic>> Function(int? proxyPort) exitCheck;

  /// sing-box output and the core's own notes (the Logs tab).
  /// Warnings and errors also live in `problems.jsonl` (they survive a restart and the flood of connection lines).
  late final logBook = LogBook(file: File(p.join(dataDir, 'problems.jsonl')));

  /// What happened, structured (eventbook.dart): the Events tab and the notifications.
  late final eventBook = EventBook(File(p.join(dataDir, 'events.jsonl')), log: logBook);

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  // A damaged ui-state.json is replaced by its backup (or the state starts empty): the journal says so.
  late final store = SnapshotStore(_snapshot, onRecovery: (type, level, data, note) => _event('core', type, level, data, note: note));
  // Subscriptions update themselves on their periods, also with the UI closed.
  late final updater = SubscriptionUpdater(
    store: store,
    hwid: () => _hwid,
    proxyPort: () => _innerPort,
    onEvent: (type, data) {
      _event('sub', type, type == 'failed' ? 'error' : 'info', data,
          note: type == 'failed'
              ? 'Subscription ${data['name']} not updated: ${data['error']}'
              : 'Subscription ${data['name']} updated: +${data['added']} -${data['removed']}, ${data['total']} servers');
      _changed(); // sourcesRev moved
    },
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
  int? get _innerPort => runner.running ? _tunnelPort ?? _mixedPort : null;
  Probe? _probe; // probe-in: Auto's latency tests (probe.dart)

  /// Every server test of the core's modules and of the UI's pings (pool.dart), and the
  /// network status they share. `direct` = the direct path through the main sing-box's probe
  /// inbound (only asked while Auto runs, so while it is up).
  late final pool = ProbePool(direct: (url, t) async => _probe == null ? -1 : _probe!.delay('direct', url, timeoutMs: t));
  StreamSubscription<ClosedConnection>? _closed; // sing-box API: closed connections → Auto and the failure book

  /// Failed connections of the running sing-box (failures.dart): `conn/failing` and the report's numbers.
  late final failures = FailureBook(
    now: _now,
    ignored: (host) => ignoredSites.matches(host),
    background: () => !screenOn,
    emit: (data, {required bg}) {
      final app = data['app'] ?? (data['process'] as Map?)?['name'];
      logBook.note('warn',
          '${app == null ? 'Requests' : 'Requests of $app'} to ${data['host']}${data['port'] == null ? '' : ':${data['port']}'} through ${data['outbound']} failed ${data['count']} times in a row (${data['kind']})');
      return eventBook.add('conn', 'failing', 'warn', data: data, bg: bg);
    },
    update: (id, data) => eventBook.update(id, data: data),
  );

  /// Does TCP from the TUN reach sing-box (tun_ingress.dart): `core/tunTcpDead` and `core/tunTcpBack`.
  late final tunIngress = TunIngressDetector(
    now: _now,
    onDead: (d) => _event('core', 'tunTcpDead', 'error', d,
        note: 'TUN (${d['stack']}): TCP does not reach sing-box: ${d['synSeen']} connection attempts in ${(d['windowMs'] as int) ~/ 1000} s, none accepted'
            '${(d['apps'] as List).isEmpty ? '' : ' (${(d['apps'] as List).join(', ')})'}'),
    onBack: (d) => _event('core', 'tunTcpBack', 'info', d,
        note: 'TUN (${d['stack']}): TCP reaches sing-box again after ${((d['deadMs'] as int) / 1000).round()} s'),
  );
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

  /// Sites the user wants no events / notifications / raw failed-connection lines about
  /// (`updateSettings {ignoredSites}`); routing never reads it.
  IgnoredSites ignoredSites = IgnoredSites.empty;

  /// The phone's screen is on (`updateSettings {screenOn}`; the platform pushes every change). Always
  /// true where there is no such report (the desktop). A `site/*` event written while it is false is
  /// marked `bg` (a background failure: the journal keeps it, Settings → Notifications decides on a
  /// notification); read at the moment the failure is found, never later.
  bool screenOn = true;

  /// Settings → Connection → Close connections on route switch (`updateSettings {closeOnSwitch}`,
  /// default on): a live route move made by the user (Manual) closes the main flow's connections of
  /// the route left. Auto's own moves keep their stalled-connection sweep.
  bool closeOnSwitch = true;
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

  // ---- status stream ----
  // While someone listens: every [_changed] and a tick every few seconds (Auto's measurements
  // move without any event) re-read the status; an unchanged one is not sent again.
  static const _statusTick = Duration(seconds: 4);
  late final _statusCtl = StreamController<Map<String, dynamic>>.broadcast(onListen: _statusListened, onCancel: _statusLeft);
  Timer? _statusTimer;
  String? _lastStatus;
  bool _statusQueued = false, _disposed = false;

  @override
  Stream<Map<String, dynamic>> get statusChanges => _statusCtl.stream;

  void _statusListened() {
    _statusTimer ??= Timer.periodic(_statusTick, (_) => _emitStatus());
  }

  void _statusLeft() {
    if (_statusCtl.hasListener) return;
    _statusTimer?.cancel();
    _statusTimer = null;
    _lastStatus = null;
  }

  /// Something the status shows may have changed: read it at the end of this turn of the
  /// event loop (a burst of changes makes one status) and send it when it differs.
  void _changed() {
    if (_disposed || _statusQueued || !_statusCtl.hasListener) return;
    _statusQueued = true;
    scheduleMicrotask(() {
      _statusQueued = false;
      _emitStatus();
    });
  }

  void _emitStatus() {
    if (_disposed || !_statusCtl.hasListener) return;
    final s = _statusMap();
    final text = jsonEncode(s);
    if (text == _lastStatus) return;
    _lastStatus = text;
    _statusCtl.add(s);
  }

  @override
  Stream<Map<String, dynamic>> get logStream => logBook.stream;

  @override
  Stream<Map<String, dynamic>> get eventStream => eventBook.stream;

  @override
  Future<void> init() async {
    await Directory(dataDir).create(recursive: true);
    logBook.load(); // last run's warnings and errors
    eventBook.load(); // trims an old journal at start
    eventBook.stream.listen((_) => _changed()); // most changes of the status are written to the journal
    await store.read(); // a damaged snapshot is recovered (and journaled) now, not at the UI's first request
    try {
      final j = jsonDecode(await _speedFile.readAsString());
      if (j is Map && j['down'] is num && j['at'] is num) _lastSpeed = Map<String, dynamic>.from(j);
    } catch (_) {} // none yet / unreadable: the Home card says "No test yet"
    final m = _readKillMarker();
    if (m != null && m['keepWhileClosed'] == true && sysProxy.isSet) {
      // left on purpose (kill switch while the app is closed): internet stays blocked
      _blocking = {'since': (m['since'] as num?)?.toInt() ?? _now().millisecondsSinceEpoch, 'reason': 'closed', 'proxy': 'kept'};
      logBook.note('warn', 'System proxy kept from the last run (kill switch): no internet until connect or Remove');
    } else {
      await _sysOff(); // left set by a crash
    }
    _recheckExit(); // the direct IP, shown on Home before any connect
    updater.start();
    await _startAppUpdater();
  }

  @override
  Future<void> dispose() async {
    _connectSeq++;
    _wakeUp();
    _stopAuto();
    updater.stop();
    await appUpdater?.dispose();
    await runner.stop();
    try {
      if (_killSwitch && _killWhileClosed && sysProxy.isSet) {
        _writeKillMarker(); // left set: the next start reports it as blocking
      } else {
        await _sysOff();
      }
    } finally {
      _disposed = true;
      _statusTimer?.cancel();
      _statusTimer = null;
      unawaited(_statusCtl.close());
      logBook.close();
      eventBook.close();
      await logBook.flush();
      await eventBook.flush(); // the journal is written behind the memory: what waits goes to the file now
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
        writeFileDurableSync(f, jsonEncode({'keepWhileClosed': true, 'since': _now().millisecondsSinceEpoch}));
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
    if (note != null) logBook.note(level, note);
    return eventBook.add(cat, type, level, data: data, own: own);
  }

  /// The system proxy on / back off, each one written to the journal (`core/sysProxy`,
  /// `on` = what was asked for; `error` = it did not work). Returns [SystemProxy.enable]'s
  /// warning; errors go on to the caller.
  Future<String?> _sysOn({required bool own}) async {
    try {
      final port = _sysPort ?? _mixedPort; // with a password on the user port: the open sys-in
      final w = await sysProxy.enable(port);
      if (sysProxy.isSet) _event('core', 'sysProxy', 'info', {'on': true}, own: own, note: 'System proxy on 127.0.0.1:$port');
      return w; // not set (no system proxy on this platform): the warning says so
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
    // what a sing-box that just started does is counted from its first line, with or without the API
    failures.start();
    if (planTun(plan)) tunIngress.start(planTunStack(plan));
    final api = runner.api;
    if (api == null) return; // no API service (a test's fake process)
    pool.resetNetwork(); // a new sing-box: the network is presumed up again
    final auto = _auto = AutoService(api, plan,
        pool: pool,
        delay: (tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t),
        reach: (tag, dest) async => _probe == null ? null : probeReach(_probe!, tag, dest),
        note: runner.note);
    // requests that failed: sing-box's API service streams every closed connection
    _closed = api.closedConnections().listen((c) {
      failures.onClosed(c);
      auto.onClosed(c);
    }, onError: (Object e) => runner.note('auto: connection events stopped: $e'));
    auto.switches.listen((s) {
      runner.note(s.isRoute ? 'auto: ${s.from} → ${s.to} (${s.reason})' : 'auto: ${s.route}: server ${s.from} → ${s.to} (${s.reason})');
      if (s.reason == 'fastest') {
        eventBook.add('auto', 'fastest', 'info', data: {'route': s.route, 'from': s.from, 'to': s.to});
      } else {
        eventBook.add('auto', 'switched', 'info', data: {'route': ?s.route, 'from': s.from, 'to': s.to, 'reason': s.reason});
      }
      _recheckExit();
    });
    auto.unstable.listen((u) {
      runner.note('auto: ${u.id} is unstable (${u.strikes} drops), back to it after ${u.holdMs ~/ 60000} min of answers');
      eventBook.add('auto', 'unstable', 'warn', data: {'id': u.id, 'strikes': u.strikes, 'holdMs': u.holdMs});
    });
    auto.blocked.listen(siteBlocked);
    auto.unreachable.listen(siteUnreachable);
    auto.net.listen((n) {
      final (type, level) = switch (n.kind) {
        'lost' => ('lost', 'warn'),
        'restored' => ('restored', 'info'),
        'offline' => ('offline', 'warn'),
        _ => ('online', 'info'),
      };
      eventBook.add('conn', type, level, data: {'downMs': ?n.downMs});
    });
    auto.start();
    _startFallback(api, auto);
    _startDnsFailover(api, auto);
    _changed();
  }

  /// Auto found a site that does not open through the route but opens through another one: the
  /// journal says so (`site/blocked`), unless the site is ignored. Public for the tests.
  void siteBlocked(AutoBlocked b) {
    final (host, port) = _hostPort(b.dest);
    if (ignoredSites.matches(host)) return;
    failures.noteSite(host); // this is the event of the site: no `conn/failing` besides it
    eventBook.add('site', 'blocked', 'warn', bg: !screenOn, data: {
      'host': host,
      'port': ?port,
      'entry': b.route,
      'server': b.server,
      'dest': b.dest,
      'via': b.via,
      'viaServer': b.viaServer,
      'rule': ruleEventData(_ruleNames, b.rule),
      'process': ?processEventData(b.process),
      if (b.pkg.isNotEmpty) 'app': b.pkg,
    });
  }

  /// Settings → Auto mode → «Check with an external checker» (`plan.auto.siteCheck`, default on).
  bool get siteCheckOn => (_plan?['auto'] is Map ? (_plan!['auto'] as Map)['siteCheck'] : null) != false;

  /// A site that opens through no route (`site/unreachable`), unless it is ignored. When every route
  /// failed (not [AutoUnreachable.retriesOff]) the event carries `check` and is quiet (no toast, no
  /// notification) until the external checker says the site opens elsewhere (sitecheck.dart): `pending`
  /// while it asks, the result after (the same event, changed in place); `off` when the switch is off.
  void siteUnreachable(AutoUnreachable u) {
    final (host, port) = _hostPort(u.dest);
    if (ignoredSites.matches(host)) return;
    failures.noteSite(host);
    final checks = !u.retriesOff;
    final on = checks && siteCheckOn;
    final id = eventBook.add('site', 'unreachable', 'warn', bg: !screenOn, data: {
      'host': host,
      'port': ?port,
      'entry': u.route,
      'server': u.server,
      'dest': u.dest,
      'tried': [for (final t in u.tried) {'entry': t.route, 'server': t.server}],
      if (u.retriesOff) 'retries': 'off',
      'rule': ruleEventData(_ruleNames, u.rule),
      'process': ?processEventData(u.process),
      if (u.pkg.isNotEmpty) 'app': u.pkg,
      if (checks) 'check': on ? {'state': 'pending', 'at': _now().millisecondsSinceEpoch} : {'state': 'off'},
    });
    if (on) unawaited(_checkSiteEvent(id, host, port, manual: false));
  }

  // Asks the checker and writes the answer into the event [id].
  Future<void> _checkSiteEvent(int id, String host, int? port, {required bool manual}) async {
    final r = await siteChecker.check(host, port, manual: manual);
    if (_disposed) return;
    eventBook.update(id, data: {'check': {...r.toJson(), if (manual) 'manual': true}});
  }

  /// body: `{event}` — the id of a `site/*` event: «Check with checker» on it. The event shows
  /// `check.state: 'pending'` at once and is changed in place with the result (`manual: true`: the
  /// user is looking, no notification for it); a check already running for the event is not
  /// started twice. → `{check}`. An event that is not there or is not about a site is a [FormatException].
  @override
  Future<Map<String, dynamic>> siteCheck(Map<String, dynamic> body) async {
    final id = body['event'];
    final ev = id is int ? eventBook.byId(id) : null;
    final data = ev?['data'];
    if (ev == null || ev['cat'] != 'site' || data is! Map || data['host'] is! String) throw const FormatException('No such site event');
    if (_checking.contains(id)) return {'check': data['check']};
    if (ignoredSites.matches('${data['host']}')) throw const FormatException('The site is ignored');
    _checking.add(id as int);
    try {
      eventBook.update(id, data: {'check': {'state': 'pending', 'at': _now().millisecondsSinceEpoch, 'manual': true}});
      await _checkSiteEvent(id, '${data['host']}', (data['port'] as num?)?.toInt(), manual: true);
    } finally {
      _checking.remove(id);
    }
    return {'check': (eventBook.byId(id)?['data'] as Map?)?['check']};
  }

  final _checking = <int>{};

  static (String, int?) _hostPort(String dest) {
    final at = dest.lastIndexOf(':'), port = at < 0 ? null : int.tryParse(dest.substring(at + 1));
    return (port == null ? dest : dest.substring(0, at), port);
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
        note: runner.note);
    fb.changes.listen((c) {
      // the journal names the first rule (else the first app) and counts the rest
      final total = c.rules.length + c.apps.length;
      final data = {
        if (c.rules.isNotEmpty) 'rule': c.rules.first else 'app': c.apps.first,
        if (total > 1) 'more': total - 1,
        'target': c.target,
      };
      if (c.back) {
        eventBook.add('rules', 'targetBack', 'info', data: data);
      } else {
        eventBook.add('rules', 'fallback', 'warn', data: {...data, 'to': c.to});
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
        note: runner.note);
    dns.switches.listen((s) => _event('dns', 'switched', 'info', {'from': s.from, 'to': s.to, 'reason': s.reason}, own: s.reason == 'off'));
    dns.start();
  }

  void _stopAuto() {
    unawaited(_closed?.cancel());
    _closed = null;
    failures.stop();
    tunIngress.stop();
    _auto?.stop();
    _auto = null;
    _fallback?.stop();
    _fallback = null;
    _dns?.stop();
    _dns = null;
    pool.resetNetwork(); // no sing-box, no status to hold on to
    _changed();
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
    runner.note('sing-box stopped on its own (exit code $code)');
    eventBook.add('core', 'crashed', 'error', data: {'code': code});
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
      _changed();
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
          runner.note('restart $_attempt failed: $e');
          // the journal gets the first ones only: a dead server retried every 30 s would fill it
          if (_attempt <= _backoff.length) eventBook.add('core', 'restartFailed', 'error', data: {'attempt': _attempt, 'error': '$e'});
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
        runner.note('system proxy not restored: $e');
      }
      if (seq == _connectSeq) _recheckExit(); // traffic goes direct now
    }
    if (seq != _connectSeq) return;
    _downSince = _now();
    _downProxy = _released ? 'released' : (sysProxy.isSet ? 'kept' : 'removed');
    _event('core', 'down', 'error', {'proxy': _downProxy}, note: 'Connection down: sing-box does not start (system proxy $_downProxy)');
  }

  /// The kill switch's same four fields as a connect's, changed while connected (or
  /// blocked), no restart of sing-box. They count for the next down / disconnect / shutdown;
  /// what already happened is re-decided at once: while down, the system proxy is set
  /// again (kill switch on, or downProxy 'keep') or taken off (both off, 'remove'), unless the
  /// user released it; while blocking, the proxy goes back when the setting that justified the
  /// block (killOnDisconnect / killWhileClosed, with killSwitch) is off now.
  @override
  Future<Map<String, dynamic>> killSwitchSettings(Map<String, dynamic> body) async {
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
      runner.note('kill switch settings: the system proxy was not changed: $e'); // the event has it
    }
    _changed();
    return status();
  }

  /// The user takes the system proxy off now ("Disable sys proxy"
  /// in the down alert, "Remove" on the blocked plaque). Tries to restart go on.
  @override
  Future<Map<String, dynamic>> releaseSysProxy() async {
    if (_recovering != null || _downSince != null) {
      _released = true;
      await _sysOff(own: true, by: 'user');
      if (_downSince != null) _downProxy = 'released';
    } else if (_blocking != null && _blocking!['proxy'] == 'kept') {
      await _sysOff(own: true, by: 'user');
      _blocking = {..._blocking!, 'proxy': 'released'};
    }
    _changed();
    return status();
  }

  /// A restart now, instead of waiting out the pause (the next pause
  /// starts over). Nothing to do unless sing-box is being restarted.
  @override
  Future<Map<String, dynamic>> retry() async {
    if (_recovering != null) _wakeUp();
    return status();
  }

  @override
  Future<Map<String, dynamic>> state() async => {
        'snapshot': await store.read(),
        'status': _statusMap(),
      };

  // A source the timer updated after the UI last looked keeps the core's server fields
  // (state.dart).
  @override
  Future<Map<String, dynamic>> saveState(Map<String, dynamic>? snapshot) async {
    await store.save(snapshot);
    return {'ok': true};
  }

  @override
  Map<String, dynamic> log({int? since, bool conns = true}) => logBook.since(since, conns: conns);

  @override
  void clearLog() => logBook.clear();

  @override
  Map<String, dynamic> events({int? since}) => eventBook.since(since);

  @override
  void clearEvents() => eventBook.clear();

  /// Speed, session totals and open connections (see traffic.dart); `running: false`
  /// with zeros when sing-box is not up.
  @override
  Future<Map<String, dynamic>> traffic() async {
    final api = runner.api;
    if (!runner.running || api == null) {
      return {'running': false, 'down': 0, 'up': 0, 'downTotal': 0, 'upTotal': 0, 'tcp': 0, 'udp': 0, 'conns': []};
    }
    return {'running': true, ...trafficOf(api, names: _ruleNames)};
  }

  /// `connected` stays true while a crashed sing-box is being started again
  /// (`recovering`, then `down` after 30 s); `blocking` = not connected and the system proxy
  /// left on by the kill switch; `auto` = what Auto really uses and measured (auto.dart → toJson).
  @override
  Future<Map<String, dynamic>> status() async => _statusMap();

  Map<String, dynamic> _statusMap() => {
        'connected': runner.running || _recovering != null,
        // what the connection runs as: 'tun' | 'proxy'; null = not connected
        'mode': runner.running || _recovering != null ? (_plan != null && planTun(_plan!) ? 'tun' : 'proxy') : null,
        'systemProxy': sysProxy.isSet,
        'sysPort': runner.running || _recovering != null ? _sysPort : null,
        'error': _error,
        'warning': _warning,
        'exit': _exit,
        'recovering': _recovering,
        'down': _downSince == null
            ? null
            : {'since': _downSince!.millisecondsSinceEpoch, 'attempt': _attempt, 'proxy': _downProxy},
        'blocking': _blocking,
        'restarts': _restarts,
        'auto': _autoState(),
        'network': pool.toJson(),
        'dns': runner.running ? _dns?.toJson() : null,
        'sourcesRev': store.rev, // moves when the timer updated a subscription: the UI reloads them
        'speed': _lastSpeed, // last Speed Test of the connection: {down, up (bit/s), latency (ms), rpm, at (ms)}
      };

  Map<String, dynamic>? _autoState() {
    final auto = _auto;
    if (auto == null || !runner.running) return null;
    return auto.toJson();
  }

  /// The failed-connection book of the running sing-box: what fails, for which app, through
  /// which outbound, since when (FailureBook.toJson). Empty and `active: false` when not connected.
  Map<String, dynamic> failuresSnapshot({int top = 20}) => failures.toJson(top: top);

  /// Whether TCP from the TUN reaches sing-box (TunIngressDetector.toJson): `state` off | ok | dead.
  Map<String, dynamic> tunIngressSnapshot() => tunIngress.toJson();

  /// Asks where traffic leaves: through the tunnel after every (re)connect, directly at
  /// start and after a disconnect, and on demand. A check that finishes after a newer one
  /// started is dropped.
  /// Every service failing at once, fast, means the tunnel itself is not carrying yet (a
  /// urltest group still on an untested dead server right after connect): ask again in a
  /// couple of seconds, for up to 15 s, before reporting the error.
  void _recheckExit() {
    final seq = ++_exitSeq;
    _exit = null;
    _changed();
    final direct = !runner.running;
    final since = Stopwatch()..start();
    Future<void> attempt() async {
      final sw = Stopwatch()..start();
      try {
        final e = await exitCheck(direct ? null : _tunnelPort ?? _mixedPort);
        if (seq == _exitSeq) _exit = {...e, 'direct': direct, 'at': DateTime.now().millisecondsSinceEpoch};
      } catch (e) {
        if (seq != _exitSeq) return;
        if (!direct && sw.elapsed < const Duration(seconds: 3) && since.elapsed < const Duration(seconds: 15) && runner.running) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (seq == _exitSeq) return attempt();
          return;
        }
        _exit = {'error': '$e', 'direct': direct};
      }
      _changed();
    }

    attempt();
  }

  @override
  Future<Map<String, dynamic>> recheckExit() {
    _recheckExit();
    return status();
  }

  /// body: {sid, source: {url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid,
  /// filter, channel}, rediscover} → {patch, title, notModified, via} (updater.dart).
  @override
  Future<Map<String, dynamic>> fetchSource(Map<String, dynamic> body) async {
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

  @override
  Map<String, dynamic> parse(Map<String, dynamic> body) =>
      {'nodes': [for (final n in parseLinks('${body['text'] ?? ''}')) n.toJson()]};

  @override
  Map<String, dynamic> addSourceFromText(Map<String, dynamic> body) =>
      {'source': localSourceFromText('${body['name'] ?? ''}', '${body['text'] ?? ''}')};

  /// The one way sing-box is started, by a connect and by a restart after a crash: the
  /// rule lists on disk first (ones via VPN that are missing wait for the tunnel — the
  /// old one, if it still runs), a fresh tunnel-in port, the config. The lists used and
  /// the config's warnings. [sys]: the system proxy is asked for; with a password on the
  /// user port it needs its own open inbound (`sys-in`, [_sysInPort]).
  Future<(RuleSetFetch, List<String>)> _startSingBox(Map<String, dynamic> plan, {required bool sys}) async {
    // TUN needs administrator rights: said before anything starts (a connect and a restart alike)
    if (planTun(plan) && !_isElevated()) throw TunNeedsAdmin();
    final lists = await ruleSets.ensureFor(plan, proxyPort: runner.running ? _tunnelPort : null);
    final warnings = <String>[];
    final mixed = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    final tunnelPort = await freePort(exclude: {mixed});
    final probePort = await freePort(exclude: {mixed, tunnelPort});
    final sysPort = sys && plan['mixedAuth'] != null ? await _sysInPort({mixed, tunnelPort, probePort}) : null;
    if (Platform.isAndroid && _selfPackages.isEmpty) {
      logBook.note('warn', "The app's own package is unknown: its own connections are routed like any app's, not direct");
    }
    final probe = Probe(probePort);
    final info = RoutingInfo();
    try {
      await runner.start(buildConfig(plan,
          tunnelPort: tunnelPort,
          sysPort: sysPort,
          probe: probe,
          ruleSetFiles: lists.files,
          warnings: warnings,
          info: info,
          selfPaths: _selfPaths,
          selfPackages: _selfPackages));
    } on SingBoxError catch (e) {
      // sing-box refused the TUN for a missing permission: the same advice as not being elevated
      if (planTun(plan) && tunAccessDenied(e.message)) throw TunNeedsAdmin(e.message);
      rethrow;
    }
    _sysPort = sysPort;
    // what a later sing-box will no longer take in this config
    try {
      for (final w in await runner.api!.deprecatedWarnings()) {
        logBook.note('warn', 'sing-box: $w');
        if (_deprecatedSeen.add(w)) eventBook.add('core', 'deprecated', 'warn', data: {'text': w});
      }
    } catch (_) {}
    _probe = probe;
    _fallbacks = info.fallbacks;
    _ruleNames = info.ruleNames;
    _dnsServers = info.dnsServers;
    _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    _tunnelPort = tunnelPort;
    // what a core made later needs to take this sing-box over (see [adopt])
    final r = runner;
    if (r is AdoptableRunner) {
      try {
        await r.keep({
          'plan': plan,
          'tunnelPort': tunnelPort,
          'probePort': probePort,
          'probeSecret': probe.secret,
          'sysPort': sysPort,
          'sysWanted': sys,
          'ruleSetFiles': lists.files,
          'upSince': _now().millisecondsSinceEpoch,
        });
      } catch (e) {
        runner.note('the record for taking this sing-box over was not kept: $e');
      }
    }
    return (lists, warnings);
  }

  /// A sing-box that outlived the core that started it (Android: the app's engine was destroyed,
  /// the VpnService kept the tunnel) is taken over instead of started again: no stop, no start,
  /// the API and the Auto / fallback / DNS services attach to it as after a connect. [body]: what
  /// a connect body holds for the running state — `dnsAuto`, the kill switch fields and `auto`
  /// (the Auto settings the app has NOW, the kept plan has the ones of the connect).
  /// → `{adopted: false}` (nothing runs, or this runner cannot adopt), `{adopted: false, stopped: true}`
  /// (something ran that could not be taken over; it was stopped so that the state is true), or
  /// `{adopted: true, plan, status}` — the plan it runs, for the caller to compare with what its
  /// catalog builds now (a difference is a plan change like any other).
  @override
  Future<Map<String, dynamic>> adopt(Map<String, dynamic> body) async {
    final r = runner;
    if (r is! AdoptableRunner || r.running || _plan != null) return {'adopted': false};
    return _locked(() async {
      if (r.running || _plan != null) return {'adopted': false};
      final Map<String, dynamic>? rec;
      try {
        rec = await r.adopt();
      } catch (e) {
        logBook.note('warn', 'A running tunnel could not be taken over ($e): stopped');
        await r.stop();
        return {'adopted': false, 'stopped': true};
      }
      if (rec == null) return {'adopted': false};
      final Map<String, dynamic> plan;
      final Probe probe;
      final RoutingInfo info = RoutingInfo();
      final int tunnelPort;
      final int? sysPort;
      try {
        plan = (rec['plan'] as Map).cast<String, dynamic>();
        tunnelPort = (rec['tunnelPort'] as num).toInt();
        sysPort = (rec['sysPort'] as num?)?.toInt();
        probe = Probe((rec['probePort'] as num).toInt(), rec['probeSecret'] as String);
        // the config again with the same inputs, for what it says about itself (rules by name,
        // fallbacks, DNS servers); the config itself is not used
        buildConfig(plan,
            tunnelPort: tunnelPort,
            sysPort: sysPort,
            probe: probe,
            ruleSetFiles: ((rec['ruleSetFiles'] as Map?) ?? const {}).cast<String, String>(),
            warnings: <String>[],
            info: info,
            selfPaths: _selfPaths,
            selfPackages: _selfPackages);
      } catch (e) {
        logBook.note('warn', 'A running tunnel could not be taken over (its record: $e): stopped');
        await r.stop();
        return {'adopted': false, 'stopped': true};
      }
      _connectSeq++;
      _applyKill(body);
      if (body['dnsAuto'] is bool) _dnsAuto = body['dnsAuto'] as bool;
      final auto = body['auto'];
      _plan = auto is Map ? {...plan, 'auto': auto} : plan;
      _sysWanted = rec['sysWanted'] == true;
      _upSince = DateTime.fromMillisecondsSinceEpoch((rec['upSince'] as num?)?.toInt() ?? _now().millisecondsSinceEpoch);
      _attempt = 0;
      _probe = probe;
      _fallbacks = info.fallbacks;
      _ruleNames = info.ruleNames;
      _dnsServers = info.dnsServers;
      _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
      _tunnelPort = tunnelPort;
      _sysPort = sysPort;
      _error = null;
      _startAuto(_plan!);
      _recheckExit();
      logBook.note('info', 'Took over the running tunnel (${plan['kind']}, up since $_upSince)');
      _changed();
      return {'adopted': true, 'plan': plan, 'status': _statusMap()};
    });
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
    if (saved != null && !taken.contains(saved) && ((runner.running && saved == _sysPort) || await portIsFree(saved))) return saved;
    final port = await freePort(exclude: taken);
    try {
      f.parent.createSync(recursive: true);
      writeFileDurableSync(f, jsonEncode({'port': port}));
    } catch (_) {} // not kept: the next connect picks again
    return port;
  }

  /// Through the tunnel now: missing lists (then a restart picks them up, on the route
  /// Auto is on), stale ones (replaced in place, sing-box reloads a local rule set itself).
  void _refreshLists(int seq, Map<String, dynamic> plan, RuleSetFetch lists) {
    ruleSets.ensureFor(plan, proxyPort: _tunnelPort, refresh: true).then((now) {
      if (seq == _connectSeq && runner.running && now.files.keys.any((t) => !lists.files.containsKey(t))) {
        final at = _auto?.index;
        _connect({'plan': at == null ? plan : {...plan, 'current': at}, 'systemProxy': _sysWanted}, own: false).then((_) {}, onError: (_) {});
      }
    }, onError: (_) {});
  }

  @override
  Future<Map<String, dynamic>> connect(Map<String, dynamic> body) => _connect(body);

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
    _changed();
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
        logBook.note('info', 'Connected: ${plan['kind']}, ${planTun(plan) ? 'TUN (${planTunStack(plan)}), ' : ''}proxy on 127.0.0.1:$_mixedPort${_sysWanted ? ', system proxy on' : ''}');
        if (_warning != null) logBook.note('warn', _warning!);
        _refreshLists(seq, plan, lists);
        eventBook.add('conn', 'connected', 'info', own: own, data: _connectedData(plan));
      } catch (e) {
        _error = '$e';
        logBook.note('error', 'Connect failed: $e');
        if (e is TunNeedsAdmin) {
          await runner.stop(); // refused before the old sing-box (a connect that switches modes) was stopped: a failed connect = not connected
          // stage: `check` = the core is not elevated (nothing started), `start` = sing-box refused
          eventBook.add('core', 'tunNeedsAdmin', 'error', own: own, data: {'stage': e.detail == null ? 'check' : 'start', 'error': ?e.detail});
        } else {
          eventBook.add('conn', 'connectFailed', 'error', own: own, data: {'reason': '$e'});
        }
        if (wasBlocking != null && _killSwitch && sysProxy.isSet) {
          _blocking = wasBlocking; // still blocked: only a connect that works, or Remove, ends it
        } else {
          await _sysOff(own: own);
        }
        rethrow;
      } finally {
        _changed();
      }
    });
    return status();
  }

  // conn/connected: the entry Auto starts on and its server when known (a Fastest group
  // has none until urltest picked), the mode (tun / proxy) and the routing.
  Map<String, dynamic> _connectedData(Map<String, dynamic> plan) {
    final routes = planRoutes(plan);
    final i = planCurrent(plan, routes.length);
    final server = _auto?.toJson()['server'];
    return {
      'entry': '${routes[i]['id'] ?? routeTag(i)}',
      'server': ?server,
      'mode': planTun(plan) ? 'tun' : 'proxy',
      'route': plan['global'] == true ? 'global' : 'rules',
    };
  }

  /// body: {auto?, manual?, entry?} — Settings → Auto mode changed while connected: the running
  /// AutoService takes it at its next round, no reconnect (none of it is in the sing-box config).
  /// `manual` (bool) is the Auto ↔ Manual switch, live as well: the plan already holds every Auto
  /// route, the controller only stops moving between them; `entry` (a route id) is the route Manual
  /// stands on, the selector `proxy` goes there with no restart. The plan kept for a restart after a
  /// crash follows (`manual`, `current`).
  @override
  Future<Map<String, dynamic>> autoSettings(Map<String, dynamic> body) async {
    final plan = _plan, auto = body['auto'], manual = body['manual'], entry = body['entry'];
    if (plan != null && auto is Map) {
      _plan = {...plan, 'auto': auto};
      final s = _auto?.settings = AutoSettings.fromPlan(_plan!);
      if (s != null) {
        _fallback?.settings = s;
        _dns?.settings = s;
      }
    }
    final a = _auto;
    if (_plan != null && manual is bool) {
      final was = a?.index;
      final ok = a == null || await a.setManual(manual, entry: entry is String ? entry : null, closeOld: closeOnSwitch);
      _plan = {..._plan!, 'manual': manual, if (a != null) 'current': a.index};
      if (a != null && a.index != was) _recheckExit(); // another route = another exit
      if (!ok) runner.note('auto: manual on ${entry ?? '?'}: not a route of this plan, a new plan is needed');
    }
    _changed();
    return status();
  }

  /// body: {auto: bool} — Settings → DNS → Switch automatically, live (no reconnect). Off puts
  /// the first server in use back at once.
  @override
  Future<Map<String, dynamic>> dnsAutoSetting(Map<String, dynamic> body) async {
    if (body['auto'] is bool) {
      _dnsAuto = body['auto'] as bool;
      await _dns?.setAuto(_dnsAuto);
    }
    _changed();
    return status();
  }

  @override
  Future<Map<String, dynamic>> disconnect() async {
    final seq = ++_connectSeq;
    _wakeUp(); // ends the restart's retries
    final was = runner.running || _plan != null || _recovering != null;
    _plan = null;
    _recovering = null;
    _downSince = null;
    _released = false;
    _stopAuto();
    await _locked(() async {
      if (seq == _connectSeq) await runner.stop();
    });
    _tunnelPort = null;
    logBook.note('info', 'Disconnected');
    if (was) eventBook.add('conn', 'disconnected', 'info', own: true, data: {'by': 'user'});
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
    _changed();
    return status();
  }

  static final _eventType = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');
  static const _eventDataMax = 4096; // JSON characters

  /// body: {cat, type, level, own?, data?} → {id}: an event the UI knows first (the
  /// subscription updates it ran itself, the user's own actions). Not linked to a raw line.
  /// A bad shape is a [FormatException] with the reason.
  @override
  Map<String, dynamic> postEvent(Map<String, dynamic> body) {
    final cat = body['cat'], type = body['type'], level = body['level'], own = body['own'], data = body['data'] ?? const {};
    if (cat is! String || !EventBook.cats.contains(cat)) throw const FormatException('bad event cat');
    if (type is! String || !_eventType.hasMatch(type)) throw const FormatException('bad event type');
    if (level is! String || !EventBook.levels.contains(level)) throw const FormatException('bad event level');
    if (own != null && own is! bool) throw const FormatException('bad event own');
    if (data is! Map) throw const FormatException('event data must be an object');
    if (jsonEncode(data).length > _eventDataMax) throw const FormatException('event data too large');
    return {'id': eventBook.add(cat, type, level, data: data.cast<String, dynamic>(), own: own == true, link: false)};
  }

  /// The sing-box version when there is no binary to ask (Android: libbox in the process).
  String? _singBoxVer;

  @override
  Future<Map<String, dynamic>> version() async => {
        'core': coreVersion,
        'singBox': _singBoxVer ??= await singBoxVersion(singBox),
        'dataDir': dataDir,
        'dart': Platform.version.split(' ').first,
        'os': Platform.operatingSystem,
      };

  // the keys of the snapshot's settings objects the report carries (the rest of the snapshot is the
  // user's sources and nodes); `connCfg` loses the local proxy's login
  static const _reportCfgKeys = ['segState', 'connCfg', 'autoCfg', 'genCfg', 'notifCfg', 'logCfg'];

  /// The support report (report.dart, docs/logs.md → Отчёт): everything the core keeps in memory,
  /// gathered in one pass. [appInfo] is the host's own account of itself, taken as given.
  @override
  Future<Map<String, dynamic>> report({Map<String, dynamic> appInfo = const {}}) => _report(appInfo, Redactor());

  /// The report for the developers: built in the strict masking mode (e-mail addresses and the
  /// user name of home paths go too), with the user's [note] (also masked), gzipped and handed to
  /// the [reportUploader]. Never throws for a failed delivery: `{ok: true, id, bytes}` or
  /// `{ok: false, error, message?}` (`error` is a [ReportUploadException] code, docs/logs.md → Отправка).
  @override
  Future<Map<String, dynamic>> sendReport({String note = '', Map<String, dynamic> appInfo = const {}}) {
    final going = _sendingReport; // one send at a time: asking again joins the one under way
    if (going != null && !(_reportCancel?.isCancelled ?? false)) return going;
    final cancel = _reportCancel = ReportCancel();
    late final Future<Map<String, dynamic>> mine;
    mine = _sendReport(note, appInfo, cancel).whenComplete(() {
      if (identical(_sendingReport, mine)) {
        _sendingReport = null;
        _reportCancel = null;
      }
    });
    return _sendingReport = mine;
  }

  Future<Map<String, dynamic>>? _sendingReport;
  ReportCancel? _reportCancel;

  /// Stops the send under way (the user's Cancel): it ends with `{ok: false, error: 'cancelled'}`.
  /// → `{ok: true, cancelled: <whether there was a send>}`.
  @override
  Future<Map<String, dynamic>> cancelReport() async {
    final c = _reportCancel;
    c?.cancel();
    return {'ok': true, 'cancelled': c != null};
  }

  /// How long a whole send may take (tests shorten it).
  final Duration reportDeadline;

  Future<Map<String, dynamic>> _sendReport(String note, Map<String, dynamic> appInfo, ReportCancel cancel) {
    var stage = 'building the report';
    final sw = Stopwatch()..start();

    Future<Map<String, dynamic>> run() async {
      final redactor = Redactor(strict: true);
      final PackedReport packed;
      try {
        packed = packReport(await _report(appInfo, redactor), note: note, redactor: redactor);
      } catch (e) {
        return {'ok': false, 'error': 'failed', 'message': 'the report could not be built: $e'};
      }
      final built = sw.elapsedMilliseconds;
      stage = 'uploading';
      try {
        // the race is ours too: an uploader that does not know the token still ends at the cancel
        final receipt = await Future.any([
          reportUploader.upload(packed.gzipped, meta: packed.meta, proxyPort: _innerPort, cancel: cancel),
          cancel.whenCancelled.then<ReportReceipt>((_) => throw const ReportUploadException('cancelled')),
        ]);
        final via = receipt.via == 'vpn' ? ' via VPN (direct failed: ${receipt.directError})' : '';
        logBook.note('info',
            'Report sent: ${receipt.id} (${packed.gzipped.length} bytes, built in $built ms, sent in ${sw.elapsedMilliseconds - built} ms)$via');
        return {'ok': true, 'id': receipt.id, 'bytes': packed.gzipped.length, 'via': receipt.via};
      } on ReportUploadException catch (e) {
        if (e.code == 'cancelled') {
          logBook.note('info', 'Report sending cancelled');
        } else if (e.code != 'not-configured') {
          logBook.note('warn', 'Report not sent (${e.code}): ${e.message}');
        }
        return {'ok': false, 'error': e.code, if (e.message.isNotEmpty) 'message': e.message};
      } catch (e) {
        logBook.note('warn', 'Report not sent: $e');
        return {'ok': false, 'error': 'failed', 'message': '$e'};
      }
    }

    // The last word: whatever hangs (a stuck read, a connection nobody times out), the send ends.
    return run().timeout(reportDeadline, onTimeout: () {
      cancel.cancel();
      final msg = 'no result in ${reportDeadline.inSeconds} s, stuck while $stage';
      logBook.note('warn', 'Report not sent (timeout): $msg');
      return {'ok': false, 'error': 'timeout', 'message': msg};
    });
  }

  Future<Map<String, dynamic>> _report(Map<String, dynamic> appInfo, Redactor redactor) async {
    final snap = await store.read().catchError((Object _) => null);
    final cfg = <String, dynamic>{};
    for (final k in _reportCfgKeys) {
      final v = snap?[k];
      if (v is! Map) continue;
      final copy = Map<Object?, Object?>.of(v);
      if (k == 'connCfg') copy.removeWhere((key, _) => key == 'proxyUser' || key == 'proxyPass');
      cfg[k] = copy;
    }
    List<String> interfaces;
    try {
      interfaces = [
        for (final i in await NetworkInterface.list(includeLoopback: true).timeout(const Duration(seconds: 2))) i.name,
      ];
    } catch (_) {
      interfaces = const [];
    }
    final plan = _plan;
    final events = [
      for (final e in (eventBook.since(null, tail: 1 << 30)['events'] as List)) (e as Map).cast<String, dynamic>(),
    ];
    final lines = [
      for (final l in (logBook.since(null)['lines'] as List)) (l as Map).cast<String, dynamic>(),
    ];
    return buildReport(
      now: DateTime.now(),
      appInfo: appInfo,
      version: await version(),
      status: _statusMap(),
      plan: plan,
      upSince: runner.running || _recovering != null ? _upSince : null,
      settings: {
        ...cfg,
        'systemProxy': sysProxy.isSet,
        'killSwitch': _killSwitch,
        'killOnDisconnect': _killOnDisconnect,
        'killWhileClosed': _killWhileClosed,
        'downProxy': _downProxyMode,
        'closeOnSwitch': closeOnSwitch,
        'dnsAuto': _dnsAuto,
        'ignoredSites': ignoredSites.hosts.length,
        'screenOn': screenOn,
      },
      network: {
        'interfaces': interfaces,
        'tunUp': runner.running && plan != null && planTun(plan),
      },
      events: events,
      lines: lines,
      failures: failuresSnapshot(),
      tunIngress: tunIngressSnapshot(),
      redactor: redactor,
    );
  }

  /// body: {protocol, address, port, secret, name, outbound?, unsupported?} — see manual.dart.
  @override
  Node manualNode(Map<String, dynamic> body) => manual.manualNode(
        protocol: '${body['protocol'] ?? ''}',
        address: '${body['address'] ?? ''}',
        port: int.tryParse('${body['port'] ?? ''}') ?? 0,
        secret: '${body['secret'] ?? ''}',
        name: '${body['name'] ?? ''}',
        outbound: (body['outbound'] as Map?)?.cast<String, dynamic>(),
        unsupported: body['unsupported'] as String?,
      );

  /// body: {outbound, name, flag, unsupported?} → the share link, or null (see share.dart).
  @override
  String? share(Map<String, dynamic> body) => shareLink(
        ((body['outbound'] as Map?) ?? const {}).cast<String, dynamic>(),
        name: '${body['name'] ?? ''}',
        flag: '${body['flag'] ?? ''}',
        unsupported: body['unsupported'] as String?,
      );

  /// Closes one open connection ([id] from [traffic]) or all of them, through sing-box's
  /// API service (with its secret, runtime.dart). Not connected: nothing to close.
  @override
  Future<Map<String, dynamic>> closeConnections([String? id]) async {
    final api = runner.api;
    if (!runner.running || api == null) return {'ok': false};
    if (!await (id == null ? api.closeAllConnections() : api.closeConnection(id))) throw SingBoxError('sing-box did not answer');
    logBook.note('info', id == null ? 'Closed all connections' : 'Closed connection $id');
    return {'ok': true};
  }

  /// body: {nodes: [{key, outbound}], pairs: [{key, entry: {outbound}, exit: {outbound}}], url?,
  /// maxAgeMs?, …checkers}. One `{kind: 'n' | 'p', key, ms}` per result as soon as it is
  /// measured (-1 = no answer), then `{done: true, network}`, or `{error}` if the tester could
  /// not start. Measuring goes on when the listener leaves: the pool keeps the results.
  @override
  Stream<Map<String, dynamic>> ping(Map<String, dynamic> body) {
    final out = StreamController<Map<String, dynamic>>();
    void line(Map<String, dynamic> m) {
      if (!out.isClosed) out.add(m);
    }

    () async {
      try {
        final nodes = (body['nodes'] as List? ?? const []).cast<Map>();
        final pairs = (body['pairs'] as List? ?? const []).cast<Map>();
        var network = pool.status;
        if (nodes.isNotEmpty || pairs.isNotEmpty) {
          final why = <String, int>{}; // reason -> how many servers missed with it
          final r = await measureLatency(
            binary: singBox,
            workDir: p.join(dataDir, 'run', 'ping-${_pingSeq++ % 8}'),
            nodes: nodes,
            pairs: pairs,
            url: (body['url'] as String?) ?? defaultTestUrl,
            checkers: planCheckers({'urlTest': body}),
            pool: pool,
            maxAge: Duration(milliseconds: (body['maxAgeMs'] as num?)?.toInt() ?? 0),
            boxFactory: _loggedBoxes('ping'),
            onResult: (kind, key, ms) => line({'kind': kind, 'key': key, 'ms': ms}),
            onFail: (tag, reason) => why[reason] = (why[reason] ?? 0) + 1,
          );
          network = r.network;
          final missed = [...r.nodes.values, ...r.pairs.values].where((ms) => ms < 0).length;
          if (missed > 0) {
            final reasons = (why.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(4).map((e) => '${e.value}x ${e.key}').join('; ');
            logBook.note('warn',
                'Ping: $missed of ${r.nodes.length + r.pairs.length} did not answer${reasons.isEmpty ? '' : ' (failed tests: $reasons)'}; network ${network.name}');
          }
        }
        line({'done': true, 'network': network.name});
      } catch (e) {
        logBook.note('error', 'Ping failed: $e');
        line({'error': '$e'});
      }
      unawaited(out.close());
    }();
    return out.stream;
  }

  /// The factory of the throwaway sing-boxes of one kind of test ([what]: "ping", "speed"): their
  /// own lines go to the raw log under that tag, next to the core's.
  BoxFactory _loggedBoxes(String what) => (dir) {
        final b = boxFactory(dir);
        b.onLog = (l) => logBook.singBox(l, tag: what);
        return b;
      };

  /// body: {node: {key, outbound}} or {pair: {key, entry: {outbound}, exit: {outbound}}},
  /// configUrl?; or {current: true}: the running connection itself ([_currentSpeed]). Progress as the test goes — `{phase (0 latency, 1 download, 2 upload,
  /// 3 done), down, up (bit/s), downRpm, upRpm, latency (ms), elapsed (ms), final}` — the
  /// last with `final: true` (and `error` when it failed). Cancelling the subscription stops
  /// the test.
  @override
  Stream<Map<String, dynamic>> speedTest(Map<String, dynamic> body) {
    if (body['current'] == true) return _currentSpeed();
    final gone = Completer<void>();
    final out = StreamController<Map<String, dynamic>>(onCancel: () {
      if (!gone.isCompleted) gone.complete();
    });
    void line(Map<String, dynamic> m) {
      if (!gone.isCompleted && !out.isClosed) out.add(m);
    }

    () async {
      try {
        await core_speed.speedTest(
          binary: singBox,
          workDir: p.join(dataDir, 'run', 'speed'),
          node: body['node'] as Map?,
          pair: body['pair'] as Map?,
          configUrl: '${body['configUrl'] ?? ''}',
          cancel: gone.future,
          boxFactory: _loggedBoxes('speed'),
          onProgress: (x) => line(_speedMap(x)),
        );
      } catch (e) {
        logBook.note('error', 'Speed test failed: $e');
        line({'error': '$e', 'final': true});
      }
      unawaited(out.close());
    }();
    return out.stream;
  }

  static Map<String, dynamic> _speedMap(NetworkQualityTestProgress x) => {
        'phase': x.phase,
        'down': x.downloadCapacity.toInt(),
        'up': x.uploadCapacity.toInt(),
        'downRpm': x.downloadRPM,
        'upRpm': x.uploadRPM,
        'latency': x.idleLatencyMs,
        'elapsed': x.elapsedMs.toInt(),
        'final': x.isFinal,
        if (x.error.isNotEmpty) 'error': x.error,
      };

  /// Speed Test of the running connection (`speedTest({current: true})`): sing-box's network
  /// quality test through the main flow's own outbound ([topTag], the group the whole route goes
  /// through, chains included) on the running sing-box — no throwaway one. Same progress maps; not
  /// connected → one `{error, final}`. A finished test is kept (`status.speed`, `last-speed.json`)
  /// and written to the journal (`speed/done`, `speed/failed`); one cancelled by the listener
  /// leaves nothing.
  Stream<Map<String, dynamic>> _currentSpeed() {
    StreamSubscription<NetworkQualityTestProgress>? sub;
    final out = StreamController<Map<String, dynamic>>(onCancel: () async {
      final s = sub;
      sub = null;
      await s?.cancel();
    });
    var finished = false;
    void finish(Map<String, dynamic> m) {
      if (finished) return;
      finished = true;
      final error = '${m['error'] ?? ''}';
      if (error.isEmpty && m['down'] is num && (m['down'] as num) > 0) {
        final r = <String, dynamic>{
          'down': m['down'],
          'up': m['up'],
          'latency': m['latency'],
          'rpm': m['downRpm'],
          'at': _now().millisecondsSinceEpoch,
        };
        _lastSpeed = r;
        unawaited(_speedFile.writeAsString(jsonEncode(r)).catchError((Object _) => _speedFile));
        _event('speed', 'done', 'info', r,
            note: 'Speed test of the connection: down ${((m['down'] as num) / 1e6).toStringAsFixed(1)} Mbps, up ${(((m['up'] as num?) ?? 0) / 1e6).toStringAsFixed(1)} Mbps, latency ${m['latency']} ms');
        _changed();
      } else {
        final why = error.isNotEmpty ? error : 'the test ended without a result';
        _event('speed', 'failed', 'warn', {'error': why}, note: 'Speed test of the connection failed: $why');
        m = {...m, 'error': why};
      }
      if (!out.isClosed) {
        out.add(m);
        unawaited(out.close());
      }
    }

    final api = runner.api;
    final Stream<NetworkQualityTestProgress> Function(String)? source =
        _currentSpeedSource ?? (api == null ? null : (tag) => api.speedTest(tag));
    if (!runner.running || source == null) {
      out.add({'error': 'Not connected', 'final': true});
      unawaited(out.close());
      return out.stream;
    }
    sub = source(topTag).listen((x) {
      final m = _speedMap(x);
      if (x.isFinal) {
        finish(m);
      } else if (!out.isClosed) {
        out.add(m);
      }
    }, onError: (Object e) => finish({'error': '$e', 'final': true}), onDone: () => finish({'final': true}));
    return out.stream;
  }

  // ───────────────────────────── the app's own update ─────────────────────────────

  /// The updater of [appVersion]; null when the host did not say which version runs (tests, jormd).
  late final AppUpdater? appUpdater = appVersion == null
      ? null
      : AppUpdater(
          dir: Directory(p.join(dataDir, 'updates')),
          current: appVersion!,
          platforms: updatePlatformKeys,
          installedPackage: installedPackage,
          feeds: updateFeeds,
          publicKeys: updatePublicKeys,
          get: updateGet ?? httpUpdateGet(proxyPort: () => _innerPort),
          tunnelUp: () => _innerPort != null,
          onEvent: (type, level, data) => _event('core', type, level, data),
        );
  bool _updAuto = true;
  UpdateChannel _updChannel = UpdateChannel.stable;
  UpdateAutoDownload _updAutoDownload = UpdateAutoDownload.wifi;

  Future<void> _startAppUpdater() async {
    final u = appUpdater;
    if (u == null) return;
    try {
      await u.reconcile(); // did the install of the last run work?
      await u.restore(); // a file downloaded earlier
    } catch (_) {
      // the update state is a convenience: a broken updates folder must not stop the core
    }
    u.changes.listen((_) => _changed());
    u.setAutoDownload(auto: _updAutoDownload);
    u.startSchedule(autoCheck: () => _updAuto, channel: () => _updChannel, firstDelay: updateFirstDelay);
  }

  @override
  Map<String, dynamic> updateStatus() => appUpdater?.status.toJson() ?? {'phase': 'unavailable'};

  @override
  Stream<Map<String, dynamic>> get updateChanges => appUpdater?.changes.map((s) => s.toJson()) ?? const Stream.empty();

  UpdateChannel _channelOf(Object? c) => c == 'beta' ? UpdateChannel.beta : UpdateChannel.stable;

  @override
  Future<Map<String, dynamic>> updateCheck(Map<String, dynamic> body) async {
    final u = appUpdater;
    if (u == null) throw const FormatException('Update checks are not available in this build');
    final st = await u.check(channel: _channelOf(body['channel'] ?? _updChannel.name), manual: body['manual'] != false);
    return st.toJson();
  }

  @override
  Future<Map<String, dynamic>> updateDownload() async {
    final u = appUpdater;
    if (u == null) throw const FormatException('Update checks are not available in this build');
    try {
      return (await u.download()).toJson();
    } on UpdateException catch (e) {
      throw FormatException(e.message);
    }
  }

  @override
  void updateCancel() => appUpdater?.cancelDownload();

  @override
  void updateSettings(Map<String, dynamic> body) {
    if (body.containsKey('ignoredSites')) {
      final v = body['ignoredSites'];
      ignoredSites = IgnoredSites([if (v is List) for (final h in v) '$h']);
      logBook.ignored = ignoredSites;
    }
    if (body['screenOn'] is bool) screenOn = body['screenOn'] as bool;
    if (body['closeOnSwitch'] is bool) closeOnSwitch = body['closeOnSwitch'] as bool;
    if (body.containsKey('autoCheck')) _updAuto = body['autoCheck'] != false;
    if (body.containsKey('channel')) _updChannel = _channelOf(body['channel']);
    if (body.containsKey('autoDownload')) _updAutoDownload = _autoDownloadOf(body['autoDownload']);
    appUpdater?.setAutoDownload(auto: _updAutoDownload, metered: body['metered'] is bool ? body['metered'] as bool : null);
  }

  UpdateAutoDownload _autoDownloadOf(Object? v) => switch (v) {
        'off' => UpdateAutoDownload.off,
        'always' => UpdateAutoDownload.always,
        _ => UpdateAutoDownload.wifi,
      };

  @override
  Future<void> updateBeginInstall() async {
    final u = appUpdater;
    if (u == null) throw const FormatException('No updater');
    await u.beginInstall();
  }

  @override
  Future<void> updateInstallFailed(String reason) async => appUpdater?.installFailed(reason);
}
