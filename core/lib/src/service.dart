import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'address_book.dart';
import 'address_pin.dart';
import 'address_resolver.dart';
import 'api.dart';
import 'appupdate.dart';
import 'auto.dart';
import 'group_pick.dart';
import 'auto_memory.dart';
import 'catalog/catalog.dart' show Catalog;
import 'catalog/rules_model.dart' show dnsBuiltinIds;
import 'catalog/plan_builder.dart' show CatalogPlan;
import 'config.dart';
import 'device.dart';
import 'dns_failover.dart';
import 'dns_flags.dart';
import 'dns_verdicts.dart';
import 'durable.dart';
import 'elevation.dart';
import 'eventbook.dart';
import 'exitip.dart';
import 'netswitch.dart';
import 'failures.dart';
import 'fallback.dart';
import 'ignored_sites.dart';
import 'localsource.dart';
import 'logbook.dart';
import 'manual.dart' as manual;
import 'name_watch.dart';
import 'node.dart';
import 'parse/links.dart';
import 'plan.dart';
import 'exits.dart';
import 'ladder.dart' show DeadLadderStore;
import 'pool.dart';
import 'probe.dart';
import 'fetch.dart' show Channel, SubscriptionFetchException, fetchErrorText;
import 'svc_fetch.dart';
import 'svc_in.dart';
import 'redact.dart';
import 'report.dart';
import 'report_upload.dart';
import 'routing.dart';
import 'rulenames.dart';
import 'rulesets.dart';
import 'runtime.dart' hide speedTest;
import 'runtime.dart' as core_speed show speedTest;
import 'sbapi.dart';
import 'sentinel/sentinel.dart';
import 'share.dart';
import 'site_memos.dart';
import 'sitecheck.dart';
import 'state.dart';
import 'sysproxy.dart';
import 'traffic.dart';
import 'tun_check.dart';
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
    this.exitVia,
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
    this.windows = const FailureWindows(),
    SentinelClock? sentinelClock,
    this.resolveAddresses = true,
    this.tunCheckConnect,
    this.addressResolverFor,
    this.directProbe = directDelay,
  })  : _singBoxVer = knownSingBoxVersion,
        _sentinelClock = sentinelClock,
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
      if (line.contains('updated default interface')) sentinel.context.interfaceChanged();
      // a DNS answer that came over the network (not a cached one) is data on it
      if (!sentinel.context.stable && _dnsAnswerRe.hasMatch(line)) sentinel.context.proved(since: sentinel.context.clock.now().millisecondsSinceEpoch);
    };
    pool.onChange = (s) => sentinel.context.pool(s, osOffline: pool.osOffline);
    pool.onAnswer = (startedAt) => sentinel.context.proved(since: startedAt); // an answered probe is data on the network
    ruleSets.fetchSource = () => svcFetch;
    ruleSets.onFailed = _ruleSetFailed;
    ruleSets.onUpdated = (tag) => _event('rules', 'ruleSetUpdated', 'info', {'tag': tag}, note: 'Rule set $tag updated', op: _listsOp);
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

  /// The exit check pinned to a node's outbound [tag] through the probe inbound (exitip.dart [checkExitVia]); Auto
  /// runs these while connected. Not given: the real one, unless [exitCheck] was replaced (tests): then that stands in.
  final Future<Map<String, dynamic>> Function(Probe probe, String tag)? exitVia;
  Future<Map<String, dynamic>> Function(Probe probe, String tag) get _pinnedExit =>
      exitVia ?? (identical(exitCheck, checkExitIp) ? checkExitVia : (_, _) => exitCheck(null));

  /// sing-box output and the core's own notes (the Logs tab).
  /// Warnings and errors also live in `problems.jsonl` (they survive a restart and the flood of connection lines).
  late final logBook = LogBook(file: File(p.join(dataDir, 'problems.jsonl')));

  /// What happened, structured (eventbook.dart): the Events tab and the notifications.
  late final eventBook = EventBook(File(p.join(dataDir, 'events.jsonl')), log: logBook, clock: _now);

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  // A damaged ui-state.json is replaced by its backup (or the state starts empty): the journal says so.
  late final store = SnapshotStore(_snapshot, onRecovery: (type, level, data, note) => _event('core', type, level, data, note: note));
  // Subscriptions update themselves on their periods, also with the UI closed.
  late final SubscriptionUpdater updater = SubscriptionUpdater(
    store: store,
    hwid: () => _hwid,
    svc: () => svcFetch,
    onSvcFailed: _subFailed,
    onDiverged: _subDiverged,
    onStale: _subStale,
    onNodes: (sid, nodes) {
      _warmNodes(nodes, 'subscription update');
      _exitSourceRefreshed(sid, nodes);
    },
    onEvent: (type, data) => _subEvent(type, data, op: updater.op),
    onFetched: _subFetched,
    newOp: _newOp,
    nodeInUse: _nodeInUse,
  );

  /// The last `sub/failed` of each source and its error: the same error again is a repeat on that event (×N), another
  /// error is a new event. Ends when the source's fetch comes through. `sub/back` closes the earlier `sub/removed`.
  final _subFailedIds = <String, ({int id, String error})>{};
  final _subRemovedIds = <String, List<int>>{};

  void _subFetched(String sid) => _subFailedIds.remove(sid);

  /// The open `sub/removed` of [sid] a `sub/back` with [back] closes: the one that names a server of it, else the
  /// oldest. The others stay open for the next `back`.
  int? _takeRemoved(String sid, Map<String, dynamic> back) {
    final open = _subRemovedIds[sid];
    if (open == null) return null;
    open.removeWhere((id) => eventBook.byId(id) == null);
    if (open.isEmpty) {
      _subRemovedIds.remove(sid);
      return null;
    }
    final names = {for (final n in (back['names'] as List? ?? const [])) '$n'};
    final id = open.firstWhere(
      (id) => ((eventBook.byId(id)?['data'] as Map?)?['names'] as List? ?? const []).any((n) => names.contains('$n')),
      orElse: () => open.first,
    );
    open.remove(id);
    if (open.isEmpty) _subRemovedIds.remove(sid);
    return id;
  }

  /// Is this server of a subscription the main flow's or a rule target's now.
  bool _nodeInUse(Map<String, dynamic> n) => _coreServers().values.contains('${n['key'] ?? n['id']}');

  /// The one author of `sub/*` (docs/logs.md → «Один автор sub/*»): the timer's updates and the manual one. [own]: the
  /// user asked. The verdict / why / trail / cause are the Sentinel's, for a judged timer failure.
  void _subEvent(String type, Map<String, dynamic> data,
      {bool own = false, Map<String, Object?>? op, String? verdict, Why? why, List<TrailStep>? trail, int? cause}) {
    final sid = '${data['source']}';
    switch (type) {
      case 'failed':
        final note = 'Subscription ${data['name']} not updated: ${data['error']}';
        final error = '${data['error']}';
        final prev = _subFailedIds[sid];
        if (prev != null && prev.error == error && eventBook.byId(prev.id) != null) {
          logBook.note('error', note);
          eventBook.repeated(prev.id,
              data: data,
              level: 'error',
              verdict: verdict,
              why: why?.toJson(),
              trail: trail == null ? null : [for (final t in trail) t.toJson()],
              cause: cause);
        } else {
          final id = _event('sub', 'failed', 'error', data, own: own, note: note, verdict: verdict, why: why, trail: trail, cause: cause, op: op);
          _subFailedIds[sid] = (id: id, error: error);
        }
      case 'removed':
        // every removal stays open (a second one while the first is open does not hide it): each `back` closes one
        (_subRemovedIds[sid] ??= []).add(_event('sub', 'removed', 'warn', data,
            own: own, note: 'Subscription ${data['name']}: ${data['count']} servers removed by the provider', op: op));
      case 'back':
        _event('sub', 'back', 'info', data,
            own: own, note: 'Subscription ${data['name']}: ${data['count']} servers back', op: op, opens: _takeRemoved(sid, data));
      default:
        _event('sub', 'updated', 'info', data,
            own: own, note: 'Subscription ${data['name']} updated: +${data['added']} -${data['removed']}, ${data['total']} servers', op: op);
    }
    _changed(); // sourcesRev moved
  }
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
  SvcIn? _svc; // svc-in: the service traffic's paths (svc_in.dart)

  /// svc-in of the running sing-box: its port, secret and the table of paths; null while sing-box does not run.
  SvcIn? get svcInbound => runner.running ? _svc : null;

  /// The paths a service request can take now (direct, the main flow, each route); empty while sing-box
  /// does not run — then only a plain direct socket is left ([ServiceFetch]).
  List<SvcPath> get svcPaths => svcInbound?.paths ?? const [];

  /// The core's own requests raced over [svcPaths] (svc_fetch.dart, docs/core.md → «Служебный трафик»).
  late final svcFetch = ServiceFetch(endpoint: () => svcInbound, context: sentinel.context);

  /// Every server test of the core's modules and of the UI's pings (pool.dart), and the
  /// network status they share. `direct` = the direct path through the main sing-box's probe
  /// inbound (only asked while Auto runs, so while it is up).
  late final pool = ProbePool(
      clock: () => _nowMs,
      direct: (url, t) async => runner.running && _probe != null ? _probe!.delay('direct', url, timeoutMs: t) : directProbe(url, t));

  /// The direct path with no sing-box running (nothing to ask through; a stopped core's probe inbound is gone): the
  /// process asks itself ([directDelay]); the tests' seam.
  final Future<int> Function(String url, int timeoutMs) directProbe;

  /// The nodes Auto found dead and asks on a ladder (ladder.dart), kept in `<dataDir>/dead-nodes.json`.
  late final deadStore = DeadLadderStore(File(p.join(dataDir, 'dead-nodes.json')), pool.ladder, clock: () => _now().millisecondsSinceEpoch);

  /// What Auto and "If unavailable" know of their servers, routes and targets outside the ladder (health, flap guard,
  /// «already failed»; auto_memory.dart), kept in `<dataDir>/auto-state.json`: a service made anew goes on from it.
  final autoMemory = AutoMemory();
  late final autoStore = AutoMemoryStore(File(p.join(dataDir, 'auto-state.json')), autoMemory, clock: () => _now().millisecondsSinceEpoch);

  /// Where each node leaves to by the exit check through it (exits.dart), kept in `<dataDir>/exit-nodes.json`.
  late final exitBook = ExitBook();
  late final exitStore = ExitBookStore(File(p.join(dataDir, 'exit-nodes.json')), exitBook, clock: () => _now().millisecondsSinceEpoch);

  /// What the last check of each DNS server found (dns_verdicts.dart), kept in `<dataDir>/dns-verdicts.json`: a reconnect,
  /// a restart or a change of the settings does not forget it, only a new check changes a verdict.
  final dnsBook = DnsVerdictBook();
  late final dnsStore = DnsVerdictStore(File(p.join(dataDir, 'dns-verdicts.json')), dnsBook, clock: () => _now().millisecondsSinceEpoch);

  /// Checks a failure against the state of the world before it is reported as one (sentinel/,
  /// docs/failures.md). Its context follows [pool], the platform ([setNetwork]) and this service's own
  /// starts and stops; the detectors move onto [Sentinel.suspect] one by one.
  late final sentinel = Sentinel(clock: _sentinelClock ?? SentinelClock(now: _now), book: eventBook, note: logBook.note, netProbe: _gateProbe);

  /// The Sentinel's own look at the network (the gate, sentinel.dart `networkGate`): the direct path asked through the
  /// probe pool with the connection's test settings. true = it answers, false = silent (the pool then says `down`),
  /// null = it cannot be tested.
  Future<bool?> _gateProbe() async {
    final s = _auto?.settings ?? AutoSettings.fromPlan(_plan ?? const {});
    final up = await pool.directAnswers(url: s.url, checkers: s.checkers, timeoutMs: s.timeoutMs);
    if (up == false && !_disposed) pool.silent(true);
    return up;
  }
  final SentinelClock? _sentinelClock;
  static final _dnsAnswerRe = RegExp(r'\bdns(?:/\S+)?: (?:exchanged|refreshed|lookup succeed for) ');

  /// How long each detector's failure must last before it is called real (sentinel/windows.dart): the
  /// tests use [FailureWindows.instant].
  final FailureWindows windows;
  StreamSubscription<ClosedConnection>? _closed; // sing-box API: closed connections → Auto and the failure book
  StreamSubscription<void>? _netChanged; // the Sentinel's network context: another network → Auto (ladder.dart)

  /// Failed connections of the running sing-box (failures.dart): `conn/failing` (judged by the [sentinel])
  /// and the report's numbers.
  late final failures = FailureBook(
    now: _now,
    ignored: (host) => ignoredSites.matches(host),
    background: () => !screenOn,
    own: _isOwnConnection,
    ownFailed: _ownConnectionFailed,
    report: _reportFailing,
    recovered: (key) => sentinel.recovered(key),
    update: (id, data) => eventBook.update(id, data: data),
    repeated: _failedAgain,
    worked: _siteWorked,
    netSwitch: _failedInSwitchNow,
    netHeld: _failedInSwitch,
    timer: (d, f) => sentinel.clock.timer(d, f),
  );

  /// A connection of this app's own process that entered the TUN: it went by the self rule ("Core and speed tests",
  /// config.dart → selfRules), or its owner is the app's package (Android) / one of [_selfPaths] (desktop). It is not a
  /// failure of an app the user runs: whoever made it reports its result (the ping, the check).
  bool _isOwnConnection(ClosedConnection c) {
    if (c.rule.isNotEmpty) {
      final o = _ruleNames?.of(c.rule);
      if (o != null && o.kind == 'system' && o.id == 'core') return true;
    }
    if (c.pkg.isNotEmpty && _selfPackages.contains(c.pkg)) return true;
    if (c.process.isNotEmpty && _selfPaths.isNotEmpty) {
      String norm(String s) => Platform.isWindows ? s.replaceAll('/', '\\').toLowerCase() : s;
      final p = norm(c.process);
      return _selfPaths.any((s) => norm(s) == p);
    }
    return false;
  }

  /// A connection of the app itself got nothing back: not counted as an app's failure ([FailureBook.own]), but told
  /// in the raw log with everything needed to find who made it.
  void _ownConnectionFailed(ClosedConnection c, ConnOutcome o) {
    final ip = c.address.isEmpty ? '' : ' (dialled ${c.address})';
    final who = c.pkg.isNotEmpty ? c.pkg : (processEventData(c.process)?['name'] ?? 'this app');
    logBook.note(
        'info',
        'Own connection of $who to ${c.destination}$ip got nothing back (${o.kind.name}'
        '${o.durationMs == null ? '' : ', ${o.durationMs}ms'}; ${c.network.isEmpty ? 'tcp' : c.network} from ${c.inbound.isEmpty ? '?' : c.inbound} '
        'through ${c.outbound.isEmpty ? 'direct' : c.outbound}): the app\'s own traffic, skipped from the failing-apps book; '
        'the request that made it reports its result itself');
  }

  /// Whether a failed connection is the network switch's, by its own open / close stamps (sentinel/context.dart `failureInSwitch`).
  bool _failedInSwitchNow(ClosedConnection c) =>
      sentinel.context.failureInSwitch(openedAt: c.openedAt, closedAt: c.closedAt, durationMs: c.durationMs);

  /// A connection got nothing back while the network changed (opened on the old one, or in the window of the new one
  /// settling): the network's, not the app's or the route's ([FailureBook.netSwitch]). No entry, no streak, but counted
  /// and told here, one line each.
  void _failedInSwitch(ClosedConnection c, ConnOutcome o) {
    if (_disposed) return;
    final who = c.pkg.isNotEmpty ? c.pkg : (processEventData(c.process)?['name'] ?? '');
    logBook.note(
        'info',
        '${who.isEmpty ? 'Connection' : 'Connection of $who'} to ${c.destination} got nothing back (${o.kind.name}'
        '${o.durationMs == null ? '' : ', opened ${o.durationMs}ms before'}; through ${c.outbound.isEmpty ? 'direct' : c.outbound}) '
        'while the network changed: counted as the network\'s, not held against the app or the route');
  }

  /// The series of `conn/failing` went on failing (or failed inside the hold after a suspicion that did not stand): the
  /// series' event counts the failures (`data.repeat`), the raw log says so, once per batch (failures.dart →
  /// [FailureBook.repeatEvery]). No notification: the event is the report.
  ///
  /// A series beyond the failure book's limit of `conn/failing` per 10 min ([FailureRepeat.limited]) has no event of
  /// its own: its failures go to the latest `conn/failing` event and the raw line says it was folded because of the
  /// limit.
  void _failedAgain(FailureRepeat r) {
    if (_disposed) return;
    final int? id = r.limited ? (eventBook.recent('conn', 'failing', const {}, const Duration(days: 1))?['id'] as int?) : r.eventId;
    final total = id == null ? 0 : eventBook.tally(id, r.at, r.n - r.at.length);
    final kinds = r.kinds.entries.map((k) => '${k.key.name} ${k.value}').join(', ');
    final what = '${r.app.isEmpty ? 'Requests' : 'Requests of ${r.app}'} to ${r.host}${r.port > 0 ? ':${r.port}' : ''} through ${r.outbound} failed';
    if (r.limited) {
      logBook.note(total > 0 ? '${eventBook.byId(id!)?['level']}' : 'warn',
          '$what: ${r.n} more ($kinds); this series is beyond the limit of ${FailureBook.maxEvents} failing-connection events per ${FailureBook.window.inMinutes} min, '
          '${total > 0 ? 'folded onto the latest conn/failing event ($total in all on it)' : 'there is no conn/failing event to fold it onto'}');
      return;
    }
    logBook.note(total > 0 ? '${eventBook.byId(id!)?['level']}' : 'info',
        '$what again: ${r.n} more ($kinds)'
        '${total > 0 ? ', $total in all on the event' : id == null ? ', no event' : ''}');
  }

  /// Does TCP from the TUN reach sing-box (tun_ingress.dart): `core/tunTcpDead` (judged by the [sentinel],
  /// `tun.tcpDead`) and `core/tunTcpBack`.
  late final tunIngress = TunIngressDetector(now: _now, onDead: _tunDead, onBack: _tunBack);

  /// The responder of the active TUN test (tun_check.dart) while a TUN runs; [tunCheckConnect] opens the test
  /// connection (tests have no TUN).
  TunCheck? _tunCheck;
  final TunCheckConnect? tunCheckConnect;
  bool? _tunCheckPassed; // the last test's outcome
  int _tunStartRun = 0; // changes with every start / stop of Auto: the start test (and its «dead») of an earlier run is void
  Cancel? _tunStartCancel;
  Timer? _tunStartTimer;
  final _tunAppReported = <String, ({int at, int? id})>{}; // apps of a passed test → when and as which event it was written last
  int _connectSeq = 0;

  /// The connect's pick of servers under way ([connectPicks]): a disconnect or a newer connect cancels it.
  Cancel? _pickCancel;

  /// A new connect / disconnect generation: the pick of the one before is cancelled.
  int _nextSeq() {
    _pickCancel?.cancel('superseded');
    return ++_connectSeq;
  }

  /// [plan] to start sing-box again on (an own restart, a reconnect for lists or addresses): the route Auto is on and,
  /// per group, the server it is on now — a server found by a check is not forgotten. Call before [_stopAuto].
  Map<String, dynamic> _continuationPlan(Map<String, dynamic> plan) {
    final a = _auto;
    if (a == null) return plan;
    return planWithChosen({...plan, 'current': a.index}, _coreServers());
  }

  /// The server every group (the routes' and the rule targets') is on now, as the core's services know it.
  Map<String, String> _coreServers() => {...?_auto?.groupServers(), ...?_fallback?.groupServers()};

  /// A plan sent by the app while sing-box runs: each group of it that is not pinned and has the server Auto has it on now
  /// among its members starts on that server (`chosen`), so a plan change does not check the groups again and move the
  /// node (and the exit IP) the traffic is on. A pinned group follows its pin; a group without a valid server of the core's
  /// keeps the plan's own `chosen` and is checked ([connectPicks]). Call before [_stopAuto].
  Map<String, dynamic> _keepCoreChoice(Map<String, dynamic> plan) {
    return _auto == null ? plan : planKeepingServers(plan, _coreServers());
  }

  final _deprecatedIds = <String, int>{}; // the event of each text of this run: the same text again is a repeat on it
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

  // The events a closing event of a pair names in `opens`: the last failover of a route (key `''` = Auto's route move) /
  // of a DNS side, the fallback of a rule target, the lost target of a rule / app (by [LostTarget.id]).
  final _autoFailoverIds = <String, int>{}, _dnsFailoverIds = <String, int>{}, _fallbackIds = <String, int>{}, _lostIds = <String, int>{};

  // What puts the events of one trouble under its first (`cause`): the failovers of a route in a row (key `''` = Auto's
  // route move) up to [_seriesWithin] apart, the failure of one node (key: the server) — its first event is the root of the
  // failover, the fallbacks of the targets on it and the DNS move to another exit node — and the flap guard's `auto/unstable`.
  final _autoSeries = <String, ({int id, int at})>{};
  final _nodeIncidents = <String, ({int id, int at})>{};
  final _unstableIds = <String, ({int id, int until})>{};
  static const _seriesWithin = Duration(minutes: 10), _incidentWithin = Duration(minutes: 10);

  /// The first event of the failure of [node] still going on, or null.
  int? _nodeIncident(String node) {
    final i = _nodeIncidents[node];
    if (i == null || _nowMs - i.at > _incidentWithin.inMilliseconds || eventBook.byId(i.id) == null) return null;
    return _rootOf(i.id);
  }

  /// The `auto/unstable` of route [route] while its hold runs.
  int? _unstableOf(String route) {
    final u = _unstableIds[route];
    return u == null || _nowMs > u.until || eventBook.byId(u.id) == null ? null : _rootOf(u.id);
  }

  /// The rules / apps whose target is lost now, by [LostTarget.id] (told once when it happens, again when it changes or
  /// ends; cleared by a disconnect so the next connect tells them anew). docs/rules.md §0 «Потерянная цель».
  Map<String, LostTarget> _lostTargets = const {};

  void _noteLostTargets(RoutingInfo info, {bool silent = false}) {
    final now = {for (final l in info.lost) l.id: l};
    if (!silent) {
      for (final l in now.values) {
        if (_lostTargets[l.id]?.state == l.state) continue;
        _lostIds[l.id] = eventBook.add('rules', 'targetLost', 'warn', data: l.toJson());
      }
      for (final l in _lostTargets.values) {
        if (now.containsKey(l.id) || !info.reached.contains(l.id)) continue;
        eventBook.add('rules', 'targetFound', 'info',
            data: {if (l.app) 'app': l.label else 'rule': l.label, 'target': l.target}, opens: _lostIds.remove(l.id));
      }
    }
    _lostTargets = now;
  }
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

  /// Settings → Connection → Detect the network provider (`updateSettings {detectNetProvider}`, default on): the Wi-Fi /
  /// Ethernet network a switch lands on is asked for its provider (one direct request, `net/switched` `provider`).
  bool detectNetProvider = true;
  List<DnsEntry> _dnsServers = const [];
  List<DnsEntry> _dnsExtra = const []; // servers a rule names that are not in use: watched, never switched to
  Set<String> _dnsVpn = const {}; // ids of the servers set «via VPN»
  Map<String, String> _ruleDns = const {}; // user rule id → the tag of its DNS server
  Map<String, List<String>> _ruleChains = const {}; // user rule id → the tags of its DNS chain, in priority order
  String _domainResolver = 'local'; // the tag that resolves what goes out directly
  String _nodeResolver = 'local'; // the tag that resolves the names of nodes (the top of the system chain)
  Set<String> _nameRoutes = const {}; // ids of the routes with a server sing-box looks up by name (RoutingInfo.nameRoutes)
  Map<String, List<DnsCandidate>> _dnsSides = const {}; // the candidates of each side, in the order the DNS rules try them
  List<DnsCandidate> _dnsCandidates = const []; // every DNS server of the config with a flag

  /// The DNS flags of the last run as the failover left them (candidate id → on): given again to a sing-box
  /// started by the core itself (a crash, a restart for new lists), so the verdicts are not lost with it. Empty
  /// after a connect the user asked for and after a disconnect: flags start on.
  Map<String, bool> _dnsFlagMemory = const {};

  /// The ones of [_dnsFlagMemory] that were in reserve (off, but working: a transport another of its provider's replaced).
  Set<String> _dnsReserveMemory = const {};

  /// Where the DNS flag files live (dns_flags.dart): the same path for every config of this core, so a sing-box
  /// taken over after the core restarted reads the files the new core writes.
  String get _dnsFlagDir => p.join(dataDir, 'dns-flags');

  void _takeDns(RoutingInfo info) {
    _dnsServers = info.dnsServers;
    _dnsExtra = info.dnsExtra;
    _dnsVpn = info.dnsVpn;
    _ruleDns = info.ruleDns;
    _ruleChains = info.ruleChains;
    _domainResolver = info.domainResolver;
    _nodeResolver = info.nodeResolver ?? info.domainResolver;
    _nameRoutes = {...info.nameRoutes};
    _dnsSides = info.dnsSides;
    _dnsCandidates = info.dnsCandidates;
  }
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
    final dead = deadStore.load(); // the nodes found dead before: the ladder goes on from the step each was on
    if (dead > 0) logBook.note('info', 'auto: $dead unavailable nodes from the last run, each asked once at the first round, then on the ladder as before');
    exitStore.load(); // where the nodes leave to, as the last exit checks found
    dnsStore.load(); // which DNS servers answered / were dead at the last check
    autoStore.load(); // what Auto and "If unavailable" knew of the servers, routes and targets
    await _retainAutoMemory(); // … without the nodes that are gone from the catalog
    _siteStore.load(); // the site verdicts whose events are still in the journal: their failures go on being counted
    eventBook.stream.listen((_) => _changed()); // most changes of the status are written to the journal
    sentinel.changes.listen((_) {
      _syncNetEvents(); // `net.offline` opened / closed: conn/offline, conn/online
      _syncNetSwitch(); // the network settled: net/switched
      _changed(); // the network and the core phase are in the status (`context`)
    });
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
    pool.ladder.onBack = _nameBack;
    updater.start();
    await _startAppUpdater();
  }

  @override
  Future<void> dispose() async {
    _nextSeq();
    _netProbeSeq++; // the direct-path probe stops
    _exitSeq++; // an exit check still in flight is dropped when it ends: nothing is saved after the dispose
    _wakeUp();
    _stopAuto();
    _netTimer?.cancel();
    _listsTimer?.cancel();
    _names.dispose();
    sentinel.dispose();
    updater.stop();
    await appUpdater?.dispose();
    await runner.stop();
    unawaited(_tunCheck?.close());
    _tunCheck = null;
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
      await deadStore.close();
      await exitStore.close();
      await dnsStore.close();
      await autoStore.close();
      await _siteStore.close();
      await _directWrite;
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
  int _event(String cat, String type, String level, Map<String, dynamic> data,
      {bool own = false, String? note, String? verdict, Why? why, List<TrailStep>? trail, int? cause, Map<String, Object?>? op, int? opens}) {
    if (note != null) logBook.note(level, note);
    return eventBook.add(cat, type, level,
        data: data,
        own: own,
        verdict: verdict,
        why: why?.toJson(),
        trail: trail == null ? null : [for (final t in trail) t.toJson()],
        cause: cause,
        op: op,
        opens: opens);
  }

  int _opSeq = 0;

  /// A new operation of [kind] (`reconnect`, `connection`, `subUpdate`, …): the events one operation writes share its
  /// `{id, kind}` (docs/logs.md → «Свёртки»). The id is unique for the life of the journal.
  Map<String, Object?> _newOp(String kind) => {'id': '$kind-$_nowMs-${++_opSeq}', 'kind': kind};

  /// The operation under way that writes events with no argument of their own: a reconnect of the live connection
  /// (its `core/sysProxy`, `core/deprecated`, `rules/ruleSetUpdated`), the lists' round (`ruleSets`).
  Map<String, Object?>? _connectOp, _ruleSetsOp;
  Map<String, Object?>? get _listsOp => _connectOp ?? _ruleSetsOp;

  /// The user's disconnect a connect within [_userReconnectWithin] turns into a `conn/reconnected` (`reason: user`).
  ({Map<String, Object?> op, int at})? _userDisconnect;
  static const _userReconnectWithin = Duration(seconds: 7);

  int get _nowMs => _now().millisecondsSinceEpoch;

  // ---- causes (docs/logs.md → «Свёртки»: an event under a root is its consequence, only the root notifies) ----

  /// The root [id] is under: its own `cause` when it has one, else itself (the journal keeps one level).
  int _rootOf(int id) => (eventBook.byId(id)?['cause'] as num?)?.toInt() ?? id;

  /// The `site/*` event of [dest] (`host:port`) a `conn/failing` of the same address is the consequence of.
  int? _siteEventOf(String dest) {
    final a = eventBook.recent('site', 'unreachable', {'dest': dest}, siteDeadIgnore);
    final b = eventBook.recent('site', 'blocked', {'dest': dest}, siteDeadIgnore);
    final id = [a?['id'], b?['id']].whereType<int>().fold<int?>(null, (m, i) => m == null || i > m ? i : m);
    return id == null ? null : _rootOf(id);
  }

  // ---- net/switched: the network the platform reports settled on another one ----

  late final _netSwitches = NetSwitchTracker(lookup: () => directIsp(), providerEnabled: () => detectNetProvider);
  var _netStable = true;
  var _netBaseline = false; // the first network was told to the tracker as settled (it is not a switch)
  ({int id, int epoch, int at})? _netSwitch;

  /// The `net/switched` event the events of the window after the switch are the consequence of: written less than
  /// [ContextTracker.oldConnTail] ago, and the network has not moved since.
  int? _netCause() {
    final s = _netSwitch;
    if (s == null || s.epoch != sentinel.context.netEpoch || _nowMs - s.at > sentinel.context.oldConnTail.inMilliseconds) return null;
    return eventBook.byId(s.id) == null ? null : s.id;
  }

  /// The Sentinel's context became stable again after a disturbance: the tracker says whether the network switched.
  void _syncNetSwitch() {
    final stable = sentinel.context.stable;
    if (stable == _netStable) return;
    _netStable = stable;
    if (stable) unawaited(_netSettled());
  }

  Future<void> _netSettled() async {
    final epoch = sentinel.context.netEpoch;
    try {
      // told at once (the events of the gap get its cause); the new network's provider joins when the lookup returns
      final sw = _netSwitches.onSettled();
      if (sw == null || _disposed) return;
      final id = eventBook.add('net', 'switched', 'info', data: sw.data);
      _netSwitch = (id: id, epoch: epoch, at: _nowMs);
      final full = await sw.completed;
      if (full != null && !_disposed) eventBook.update(id, data: full);
    } catch (e) {
      logBook.note('warn', 'net: the network switch could not be told: $e');
    }
  }

  // ---- the detectors that go through the Sentinel (docs/failures.md → Перенос детекторов) ----

  /// `conn/failing`: the failure book's streak of one entry becomes a suspicion of its destination ([_judgeSite]).
  /// Completes with the event's id when the failure stands.
  Future<int?> _reportFailing(FailureReport r) async {
    final d = r.data;
    final host = '${d['host']}', port = (d['port'] as num?)?.toInt(), outbound = '${d['outbound']}', route = '${d['route']}';
    final v = await _judgeSite(
      host: host,
      port: port,
      route: route,
      outbound: outbound,
      evidence: d,
      subject: r.subject,
      firstSeen: r.firstSeen,
      bg: r.bg,
      window: windows.connFailing,
      connWhy: Why('conn.${r.kind.name}', {'count': d['count'], 'route': route}),
    );
    return v != null && v.kind == VerdictKind.confirmed ? (v.eventId ?? v.cause) : null;
  }

  /// Auto noticed that requests to a site got nothing back through a node that passes traffic: the same
  /// suspicion as the connection book's `conn/failing` of that site (one key, the evidence merges). Public
  /// for the tests.
  void siteFailed(AutoSiteFail f) {
    final (host, port) = _hostPort(f.dest);
    if (ignoredSites.matches(host)) return;
    unawaited(_judgeSite(
      host: host,
      port: port,
      route: f.route,
      outbound: f.tag,
      evidence: {
        'host': host,
        'port': ?port,
        'outbound': f.tag,
        'route': f.route,
        if (f.pkg.isNotEmpty) 'app': f.pkg,
        'noticed': {'server': f.server, 'rule': f.rule, 'process': f.process},
      },
      firstSeen: DateTime.fromMillisecondsSinceEpoch(f.firstSeen),
      bg: !screenOn,
      window: windows.siteUnreachable,
    ));
  }

  /// Settings → Auto mode → «Check with an external checker» (`plan.auto.siteCheck`, default on).
  bool get siteCheckOn => (_plan?['auto'] is Map ? (_plan!['auto'] as Map)['siteCheck'] : null) != false;

  /// The probes behind the site checks (default: Auto's `reachSame` / `reachScout` / `reachElsewhere`); the tests'
  /// seams. [probeScout]: one working node, preferably of the failing server's subscription and of another country;
  /// [probeElsewhere]: working nodes of the other subscriptions, as many as `siteRetry` allows after the scout's.
  Future<bool?> Function(String outbound, String dest, Cancel cancel)? probeSame;
  Future<AltReach> Function(String outbound, String dest, Cancel cancel)? probeScout;
  Future<AltReach> Function(String outbound, String dest, AltReach? scout, Cancel cancel)? probeElsewhere;

  /// How long failures of a site whose checker said «down for everyone» are only counted on its event.
  static const siteDeadIgnore = Duration(minutes: 90);

  /// How long failures of a site with any other `site/*` verdict are only counted, by the step the verdict was on
  /// (the last repeats): the next failure after it runs the whole check again.
  static const siteLadder = [Duration(minutes: 5), Duration(minutes: 15), Duration(minutes: 30), Duration(minutes: 60)];

  /// What the site checks remember of a verdict (docs/failures.md → Проверки сайтов), by `<dest>|<route>`: until [until]
  /// the failures of the site through that route are only counted on the event ([eventId]); [dead] = the checker did not
  /// open it either (then the next check, after [until], is the checker's alone), else the ladder is on its [step].
  /// Kept in `<dataDir>/site-verdicts.json` (site_memos.dart): a reconnect or a restart does not forget it.
  final _siteMemos = SiteMemoBook();
  late final _siteStore = SiteMemoStore(File(p.join(dataDir, 'site-verdicts.json')), _siteMemos, alive: (id) => eventBook.byId(id) != null);

  /// A verdict of the ladder (not «dead everywhere») taken on another network than the one now is void, also when the
  /// network changed while the core did not run (the listener in [_startAuto] sees only the changes of a running session).
  bool _siteMemoStale(SiteMemo m) {
    if (m.dead || m.net.isEmpty || m.net == '|') return false;
    final now = _directNetKey();
    return now != '|' && now != m.net;
  }

  bool _canAim(String outbound, String dest) => canProbeDest(dest) && (probeSame != null || (_auto?.canReachSame(outbound, dest) ?? false));

  /// A connection to [host]:[port] through [outbound] got data back: the site opens through that route, so its verdict
  /// (and the ignoring of its failures) ends.
  void _siteWorked(String host, int port, String outbound) {
    if (_siteMemos.isEmpty) return;
    final dest = '$host:$port', route = _auto?.routeIdOf(outbound) ?? _routeTagOf(outbound);
    _siteMemos.removeWhere((_, m) => m.dest == dest && m.route == route);
  }

  /// The one identity of the route a failed connection went through, whoever reports it: Auto names it by the entry id,
  /// the connection book by the tag prefix (`route0`); both resolve to the entry id through the plan. [route] as
  /// reported is kept where the outbound is no route's (`direct`, a test's).
  String _siteRoute(String outbound, String route) => _auto?.routeIdOf(outbound) ?? route;

  static String _routeTagOf(String outbound) {
    final at = outbound.indexOf('/');
    return at < 0 ? outbound : outbound.substring(0, at);
  }

  /// One suspicion per destination (`site|host:port`), whoever reports it: the connection book's streak
  /// (`conn/failing`) and Auto's notice (requests through a node that passes traffic got nothing back) join and
  /// their evidence merges. Where a test can be aimed at the site ([_canAim]) the checks, in order:
  /// 1. the site opens again through the same node (live traffic, or a probe through the same server): a micro-failure,
  ///    the raw log only, no event;
  /// 2. the controller's (Auto's) one working node, preferably of the same subscription and of another country
  ///    (`probe.scout`), with the external checker asked beside it (`siteCheckOn`);
  /// 3. the checker says it opens elsewhere (and the scout did not): the working nodes of the other subscriptions
  ///    (`probe.elsewhere`), as many as `siteRetry` allows in all; the checker says it does not open: none.
  /// The event by the verdict: one of our routes opens it -> `site/blocked`; none does and the checker says it opens
  /// -> a confirmed `site/unreachable`; the checker says it does not open (dead everywhere), or is unsure / off -> an
  /// unexplained one. Where no test can be aimed (a port other than 443 / 80, no Auto) it is the plain `conn/failing`
  /// streak. After a `site/*` verdict the site's failures through that route are only counted on its event
  /// ([_siteMemos]): 1.5 h after «dead» (then the checker alone looks again), else on the ladder [siteLadder]; a
  /// connection through the route that gets data back, or (the ladder) another network, ends it. Never dropped.
  /// The direct path is never tried: that would tell the network the user's interest in the site.
  Future<Verdict?> _judgeSite({
    required String host,
    required int? port,
    required String route,
    required String outbound,
    required Map<String, dynamic> evidence,
    Map<String, dynamic>? subject,
    required DateTime firstSeen,
    required bool bg,
    required Duration window,
    Why? connWhy,
  }) async {
    final dest = port == null ? host : '$host:$port';
    final aimable = _canAim(outbound, dest);
    final since = firstSeen.millisecondsSinceEpoch;
    // the site has a verdict of this route that is still remembered ([_siteMemos]): this failure is its repeat, it is on
    // that event and in the raw log; nothing is probed again (no request to the site, no external checker) until the
    // timer of the verdict is over. After a «dead everywhere» one the checker alone looks again first.
    final entry = _siteRoute(outbound, route), memoKey = '${dest.toLowerCase()}|$entry';
    if (aimable) {
      final m = _siteMemos[memoKey];
      if (m != null && eventBook.byId(m.eventId) == null) {
        _siteMemos.remove(memoKey); // its event is gone (the journal was cleared): the site is judged anew
      } else if (m != null && _siteMemoStale(m)) {
        _siteMemos.remove(memoKey); // another network than the one the ladder's verdict was taken on: the ladder starts over
      } else if (m != null && (m.rechecking || _nowMs < m.until)) {
        return _siteAgain(m, FailureBook.siteKey(host, port), dest, entry, evidence);
      } else if (m != null && m.dead && siteCheckOn) {
        m.rechecking = true; // the failures that come meanwhile are counted on the event
        final r = await siteChecker.check(host, port, manual: false);
        m.rechecking = false;
        if (_disposed) return null;
        if (r.state == 'down' && identical(_siteMemos[memoKey], m) && eventBook.byId(m.eventId) != null) {
          m.until = _nowMs + siteDeadIgnore.inMilliseconds;
          _siteMemos.touch();
          eventBook.update(m.eventId, data: {'check': r.toJson()});
          logBook.note('warn', '$dest does not open through $entry: the checker alone looked again, it does not open for it either; failures are counted on the event for ${siteDeadIgnore.inMinutes} min more');
          return _siteAgain(m, FailureBook.siteKey(host, port), dest, entry, evidence, say: false);
        }
        // it opens for the checker now (or it could not tell): the whole check runs, from the first step
      }
    }
    AltReach? alt, scout, elsewhere;
    Future<void>? checkerRun;
    var asked = false;
    Map<String, dynamic>? result;
    (String, String)? wrote;

    // the raw rule text of the evidence becomes the event's rule (as in `site/*`)
    Map<String, dynamic> connData(Map<String, dynamic> e) => {
          for (final x in e.entries)
            if (x.key != 'noticed')
              x.key: x.key == 'rule' && x.value is String ? ruleEventData(_ruleNames, x.value as String) : x.value,
        };
    bool fromConn(Map<String, dynamic> e) => e['count'] != null;
    // the probe opened the site through the same server while the app's own connections went on failing: not a
    // recovery, the site is not the culprit (docs/failures.md → Проверки сайтов)
    var diverged = false;
    // the resolver the connection went through could not resolve the host either: the failure is the resolver's,
    // not the site's (a `dns.down` root of it covers the failure; this is the live check, docs/failures.md → DNS)
    var resolverDown = false;
    // the external checker, asked once per judgement beside the scout (or by its own step when the scout never ran)
    final checkerCancel = Cancel();
    var checkerInFlight = false;
    Future<void> askChecker() => checkerRun ??= () async {
          asked = false;
          result = null;
          if (diverged || resolverDown || checkerCancel.cancelled) return;
          if (!siteCheckOn) {
            result = {'state': 'off'};
            return;
          }
          asked = true;
          checkerInFlight = true;
          final r = await siteChecker.check(host, port, manual: false, cancel: checkerCancel);
          checkerInFlight = false;
          if (r.state == 'cancelled') {
            asked = false; // withdrawn, not asked in vain: nothing of it goes to the event
            return;
          }
          result = r.toJson();
        }();
    // one of our routes opened the site: the checker's answer is not needed, its request is dropped (the polling stops,
    // nothing is cached)
    void dropChecker(String by) {
      if (!checkerInFlight || checkerCancel.cancelled) return;
      checkerCancel.cancel(by);
      logBook.note('info', '$dest opens through $by: the external checker\'s request is cancelled');
    }
    void mergeAlt() {
      final a = scout, b = elsewhere;
      alt = AltReach(
          via: b?.via ?? a?.via,
          viaServer: b?.via != null ? b?.viaServer : a?.viaServer,
          tried: [...?a?.tried, ...?b?.tried],
          unsure: (a?.unsure ?? false) || (b?.unsure ?? false),
          off: (a?.off ?? false) || (b?.off ?? false));
    }
    final resolver =InternetAddress.tryParse(host) != null ? null : _resolverFor(outbound, evidence);
    (String, String)? pick(VerdictKind kind, Map<String, dynamic> e) {
      if (!aimable) return _siteKind('conn', 'failing');
      return switch (kind) {
        VerdictKind.confirmed || VerdictKind.unexplained when diverged || resolverDown => _siteKind('conn', 'failing'),
        VerdictKind.confirmed || VerdictKind.unexplained => _siteKind('site', 'unreachable'),
        VerdictKind.workaround when alt?.via != null => _siteKind('site', 'blocked'),
        VerdictKind.blip => null, // a micro-failure: the same node opens it again — the raw log only (below), no event
        VerdictKind.consequence when !fromConn(e) => _siteKind('site', 'unreachable'),
        _ => _siteKind('conn', 'failing'),
      };
    }

    Map<String, dynamic> siteData(Map<String, dynamic> e, String type) {
      final n = (e['noticed'] as Map?) ?? const {};
      final proc = e['process'] is Map ? e['process'] : processEventData('${n['process'] ?? ''}');
      final tried = alt?.tried ?? const [];
      return {
        'host': host,
        'port': ?port,
        'entry': entry,
        'server': n['server'] ?? outbound,
        'dest': dest,
        if (type == 'blocked') ...{
          'via': alt!.via,
          'viaServer': alt!.viaServer,
          // the scout is another node of the failing route's own entry: a rule for the entry would send the site through
          // the node that fails it, so the rule «Create rule» offers is for the node that opened it
          if (alt!.via == entry && alt!.viaServer != null && '${alt!.viaServer}'.isNotEmpty) 'viaTarget': 'node:${alt!.viaServer}',
        } else ...{
          'tried': [for (final t in tried) {'entry': t.route, 'server': t.server}],
          if (alt?.off == true) 'retries': 'off',
        },
        'rule': ruleEventData(_ruleNames, '${n['rule'] ?? ''}'),
        'process': ?proc,
        if (e['app'] != null) 'app': e['app'],
      };
    }

    String? siteNote(VerdictKind kind, Map<String, dynamic> e, String type) {
      if (type == 'blocked') return '$dest does not open through $entry, opens through ${alt!.via}${alt!.via == entry ? ' (another node)' : ''}';
      final tried = alt?.tried ?? const [];
      final t = tried.isEmpty ? '' : ' nor ${tried.map((x) => x.route).join(', ')}';
      return switch (kind) {
        VerdictKind.confirmed => '$dest does not open through $entry$t: the site is down or blocked everywhere, the checker says it opens elsewhere',
        VerdictKind.unexplained => alt?.off == true
            ? '$dest does not open through $entry: retries through other routes are off'
            : '$dest does not open through $entry$t: the site is down or blocked everywhere',
        _ => '$dest does not open through $entry: because of another failure',
      };
    }

    final onRoute = route.isEmpty ? null : route;
    final v = await sentinel.suspect(Suspicion(
      kind: aimable ? 'site.failing' : 'conn.failing',
      key: FailureBook.siteKey(host, port),
      subject: {...(subject ?? {'host': host, 'port': ?port, 'route': route, 'path': 'proxy'}), if (resolver != null) 'dns': resolver.id},
      evidence: evidence,
      window: window,
      firstSeen: firstSeen,
      // an aimable one is judged by its checks (the checker's word, else nothing says why)
      why: aimable ? null : connWhy,
      whyLate: !aimable ? null : (e) => diverged && e['count'] != null ? Why('conn.${e['kind']}', {'count': e['count'], 'route': e['route']}) : null,
      scope: aimable ? Scope.none : Scope.of({'host': host, 'port': ?port, 'outbound': outbound}),
      checks: [
        Check.recovery('conn.recovered', (_) async {
          final ok = failures.okOutbounds(host, port ?? 0, since).contains(outbound);
          return CheckResult('conn.recovered', ok ? Outcome.pass : Outcome.fail, {'outbound': outbound});
        }, level: Level.destination, via: onRoute),
        Check.alternative('conn.otherRoute', (_) async {
          final others = failures.okOutbounds(host, port ?? 0, since).where((o) => o != outbound).toList();
          return CheckResult('conn.otherRoute', others.isEmpty ? Outcome.inconclusive : Outcome.pass, {'outbounds': others.take(3).toList()});
        }, level: Level.destination, via: onRoute),
        // the first live check: the host resolves through the same server. Fails -> the resolver's failure (why `dns.resolve`).
        if (resolver != null)
          Check.diagnostic('dns.resolve', (cancel) async {
            resolverDown = false; // a parked ladder runs again from the top
            final ms = await Future.any([_dnsAsk(resolver.tag, host, 5000), cancel.done.then((_) => -2)]);
            if (ms == -2) return CheckResult('dns.resolve', Outcome.inconclusive, {'server': resolver.id});
            if (ms >= 0) return CheckResult('dns.resolve', Outcome.pass, {'server': resolver.id});
            resolverDown = true;
            _dns?.suspectServer(resolver.id); // the resolver's own suspicion, with this evidence
            return CheckResult('dns.resolve', Outcome.fail, {'server': resolver.id, 'path': resolver.vpn ? 'proxy' : 'direct'});
          }, timeout: const Duration(seconds: 10), level: Level.dns, via: resolver.vpn ? topTag : null, resolver: resolver.id),
        if (aimable) ...[
          Check.recovery('probe.same', (cancel) async {
            diverged = false; // a parked ladder runs again from the top
            final started = _nowMs;
            final opens = await (probeSame ?? (o, d, c) async => _auto?.reachSame(o, d, cancel: c))(outbound, dest, cancel);
            if (opens == null) return CheckResult('probe.same', Outcome.inconclusive, {'outbound': outbound});
            // the probe opens it, the app's own connections keep failing: evidence, not a recovery
            if (opens && failures.failedSince(host, port ?? 0, started)) {
              diverged = true;
              return CheckResult('probe.same', Outcome.fail, {'outbound': outbound, 'opens': true, 'appFails': true});
            }
            if (opens) dropChecker(entry); // (a parked ladder run again: the last pass's checker may still be asking)
            return CheckResult('probe.same', opens ? Outcome.pass : Outcome.fail, {'outbound': outbound});
          }, timeout: const Duration(seconds: 15), level: Level.destination, via: onRoute, resolver: onRoute == null ? null : _routeResolver(onRoute)),
          // step 2: the controller's one working node (the same subscription, another country first); the checker asks beside it
          Check.alternative('probe.scout', (cancel) async {
            alt = scout = elsewhere = null; // a parked ladder runs again from the top: nothing of the last pass is left
            checkerRun = null;
            if (diverged) return const CheckResult('probe.scout', Outcome.inconclusive, {'reason': 'sameOpens'});
            unawaited(askChecker());
            final auto = _auto;
            if (probeScout == null && auto == null) return const CheckResult('probe.scout', Outcome.inconclusive, {'reason': 'noAuto'});
            final a = await (probeScout ?? (o, d, c) => auto!.reachScout(o, d, cancel: c))(outbound, dest, cancel);
            scout = a;
            mergeAlt();
            if (a.via != null) {
              dropChecker(a.via!);
              return CheckResult('probe.scout', Outcome.pass, {'via': a.via, 'viaServer': a.viaServer});
            }
            final routes = [for (final t in a.tried) t.route];
            if (routes.isEmpty || a.unsure) return CheckResult('probe.scout', Outcome.inconclusive, {'reason': a.off ? 'off' : 'none', 'tried': routes});
            return CheckResult('probe.scout', Outcome.fail, {'tried': routes});
          }, timeout: const Duration(seconds: 20), level: Level.destination, via: onRoute),
          Check.diagnostic('site.checker', (cancel) async {
            if (diverged) return const CheckResult('site.checker', Outcome.inconclusive, {'reason': 'sameOpens'});
            if (resolverDown) return const CheckResult('site.checker', Outcome.inconclusive, {'reason': 'resolverDown'});
            await askChecker();
            final r = result;
            if (r == null || r['state'] == 'off') return const CheckResult('site.checker', Outcome.inconclusive, {'state': 'off'});
            final state = '${r['state']}';
            return CheckResult('site.checker', switch (state) { 'opens' => Outcome.fail, 'down' => Outcome.pass, _ => Outcome.inconclusive }, {'state': state});
          }, timeout: windows.siteChecker, level: Level.destination, via: onRoute),
          // step 3: the checker opens it and the scout did not: the working nodes of the other subscriptions (siteRetry's allowance)
          Check.alternative('probe.elsewhere', (cancel) async {
            if (diverged) return const CheckResult('probe.elsewhere', Outcome.inconclusive, {'reason': 'sameOpens'});
            if (scout == null) return const CheckResult('probe.elsewhere', Outcome.inconclusive, {'reason': 'noScout'});
            if (result?['state'] == 'down') return const CheckResult('probe.elsewhere', Outcome.inconclusive, {'reason': 'checkerDown'});
            final auto = _auto;
            if (probeElsewhere == null && auto == null) return const CheckResult('probe.elsewhere', Outcome.inconclusive, {'reason': 'noAuto'});
            final a = await (probeElsewhere ?? (o, d, s, c) => auto!.reachElsewhere(o, d, scout: s, cancel: c))(outbound, dest, scout, cancel);
            elsewhere = a;
            mergeAlt();
            if (a.via != null) {
              dropChecker(a.via!); // (the checker may still be asking when its step timed out)
              return CheckResult('probe.elsewhere', Outcome.pass, {'via': a.via, 'viaServer': a.viaServer});
            }
            final routes = [for (final t in a.tried) t.route];
            if (routes.isEmpty || a.unsure) return CheckResult('probe.elsewhere', Outcome.inconclusive, {'reason': a.off ? 'off' : 'none', 'tried': routes});
            return CheckResult('probe.elsewhere', Outcome.fail, {'tried': routes});
          }, timeout: const Duration(seconds: 45), level: Level.destination, via: onRoute),
        ],
      ],
      event: SuspicionEvent('conn', 'failing',
          level: 'warn',
          bg: bg,
          // a verdict again after the timer of the last one ran out: the same event, changed in place (a changed kind is its own)
          foldOnto: (cat, type, d) {
            final m = _siteMemos[memoKey];
            return m != null && cat == 'site' && m.kind == type && eventBook.byId(m.eventId) != null ? m.eventId : null;
          },
          kindFor: (kind, e) => wrote = pick(kind, e),
          // a `conn/failing` of an address a `site/*` was written for is its consequence; a confirmed failure is never put
          // under a network switch (net/switched does not notify; the Sentinel already waited for the network to settle)
          causeFor: (cat, type, kind, d) => cat == 'conn' ? _siteEventOf(dest) : null,
          dataFor: (kind, e) {
            final k = pick(kind, e);
            return k == null || k.$1 == 'conn' ? connData(e) : siteData(e, k.$2);
          },
          note: (kind, e) {
            final k = pick(kind, e);
            if (k == null) return null;
            return k.$1 == 'conn' ? _failingNote(kind, connData(e)) : siteNote(kind, e, k.$2);
          }),
    ));
    final w = wrote;
    if (aimable && v.kind == VerdictKind.blip) {
      logBook.note('info', '$dest failed through $entry and opens again through the same node: a micro-failure, no event');
    }
    // this judgement wrote its own non-site verdict (a joined report wrote none: it leaves the memory of the one it joined)
    if (aimable && w != null && !(w.$1 == 'site' && v.eventId != null) && v.kind != VerdictKind.deferred) _siteMemos.remove(memoKey);
    if (w != null && w.$1 == 'site' && v.eventId != null) {
      final id = v.eventId!;
      if (!_disposed) {
        final check = result ?? (asked ? {'state': 'failed', 'at': _nowMs, 'error': 'timeout'} : null);
        if (check != null && w.$2 == 'unreachable') eventBook.update(id, data: {'check': check});
        // the memory of the verdict: «dead everywhere» is ignored for 1.5 h, any other one on the ladder
        final dead = w.$2 == 'unreachable' && check?['state'] == 'down';
        final was = _siteMemos[memoKey];
        final step = !dead && was != null && !was.dead && was.kind == w.$2 && was.eventId == id ? was.step + 1 : 0;
        final wait = dead ? siteDeadIgnore : siteLadder[step < siteLadder.length ? step : siteLadder.length - 1];
        _siteMemos[memoKey] = SiteMemo(
            eventId: id, kind: w.$2, dead: dead, step: step, until: _nowMs + wait.inMilliseconds, dest: dest.toLowerCase(), route: entry, net: _directNetKey());
      }
      // an announcement: the event is the report, a root would swallow the next one (a repeat folds into the event)
      if (v.kind == VerdictKind.confirmed) sentinel.closeRoot(v.key, reason: 'reported');
    }
    return v;
  }

  /// The site failed again while the timer of its verdict runs: the event counts it (`data.repeat`), the raw log says
  /// so, the verdict is the event's own. No probe, no checker: they run again for a failure after the timer. [say]
  /// false: the caller has written its own line (the checker's look-again).
  Verdict _siteAgain(SiteMemo m, String key, String dest, String route, Map<String, dynamic> evidence, {bool say = true}) {
    final id = m.eventId;
    final prev = eventBook.byId(id);
    final n = eventBook.tally(id);
    final noticed = (evidence['noticed'] as Map?) ?? const {};
    final app = '${evidence['app'] ?? (evidence['process'] as Map?)?['name'] ?? noticed['process'] ?? ''}';
    if (say) {
      final left = ((m.until - _nowMs) / 60000).ceil().clamp(1, 1 << 20);
      logBook.note('${prev?['level'] ?? 'info'}',
          '$dest does not open through $route: again, $n times${app.isEmpty ? '' : ' ($app)'}; the verdict of the last check stands, '
          '${m.dead ? 'the checker alone looks again' : 'the site is checked again'} after $left min');
    }
    final kind = VerdictKind.values.asNameMap()['${prev?['verdict']}'] ?? VerdictKind.confirmed;
    return Verdict(kind: kind, key: key, eventId: id, repeat: true);
  }

  // The journal entry a verdict of [_judgeSite] is written as; the plain literals are what the events catalog test reads.
  static (String, String) _siteKind(String cat, String type) => (cat, type);

  static String _failingNote(VerdictKind kind, Map<String, dynamic> e) {
    final app = e['app'] ?? (e['process'] as Map?)?['name'];
    final who = app == null ? 'Requests' : 'Requests of $app';
    final to = '${e['host']}${e['port'] == null ? '' : ':${e['port']}'} through ${e['outbound']}';
    final n = e['count'] == null ? 'repeatedly' : '${e['count']} times in a row (${e['kind']})';
    return switch (kind) {
      VerdictKind.confirmed => '$who to $to failed $n',
      VerdictKind.blip => '$who to $to failed $n, then worked again',
      VerdictKind.consequence => '$who to $to failed $n: because of another failure',
      VerdictKind.workaround => '$who to $to failed $n: it opens another way',
      _ => '$who to $to failed $n: no reason found',
    };
  }

  /// `core/tunTcpDead` from the TUN detector: the first orphaned look-up of the dead window is when it began.
  void _tunDead(Map<String, dynamic> d) {
    final first = (d['firstSeen'] as num?)?.toInt();
    final run = _tunStartRun; // the session this «dead» belongs to
    String? wroteKey; // the apps of the event this suspicion wrote as the 15 min one
    unawaited(sentinel.suspect(Suspicion(
      kind: 'tun.tcpDead',
      key: 'tun.tcpDead',
      subject: const {'ingress': 'tun'},
      evidence: d,
      window: windows.tunTcpDead,
      firstSeen: first == null ? null : DateTime.fromMillisecondsSinceEpoch(first),
      why: Why('tun.tcpDead', {'stack': d['stack']}),
      scope: Scope.none,
      level: Level.core,
      // the active test (tun_check.dart): a TCP connection through the TUN reaches routing → the tunnel is alive,
      // it is one app's failure (a blip: no error, no notification); it does not → the standing failure
      checks: [
        if (_tunCheck case final tc?)
          Check.recovery(tunCheckCode, (c) async {
            final r = await tc.run(c);
            _tunCheckPassed = r.outcome == Outcome.pass;
            return r;
          }, level: Level.core, timeout: tc.limit),
      ],
      event: SuspicionEvent('core', 'tunTcpDead', level: 'error', kindFor: (kind, e) {
        // the test at the start failed, the Sentinel's second test passed: the tunnel was only late, nothing to say
        // in the journal (a blip of the start); the raw log has it
        if (e['probe'] == true && kind == VerdictKind.blip) {
          logBook.note('info', 'TUN (${e['stack']}): the start test failed (${e['probeReason']}), passed on the second test: the tunnel was only late');
          return null;
        }
        // a passed test: one event per 15 min per apps; the repeats within it are counted on that event (its
        // `data.repeat`) and are in the raw log (an app that pings every 5 s must not fill the journal)
        if (kind != VerdictKind.blip || e['accepted'] != 0 || _tunCheckPassed != true) return ('core', 'tunTcpDead');
        final key = ((e['apps'] as List?) ?? const []).join(',');
        final now = _nowMs, last = _tunAppReported[key];
        final id = last?.id;
        if (last != null && id != null && now - last.at < 15 * 60 * 1000) {
          final n = eventBook.tally(id);
          if (n > 0) {
            logBook.note('info', 'TUN (${e['stack']}): TCP passes the tunnel; ${e['synSeen']} look-ups of $key end without a connection (that app only), again, $n times');
            return null;
          }
        }
        _tunAppReported[key] = (at: now, id: null);
        wroteKey = key;
        return ('core', 'tunTcpDead');
      }, note: (kind, e) {
        final apps = (e['apps'] as List?) ?? const [];
        if (e['probe'] == true) {
          return 'TUN (${e['stack']}): TCP does not reach sing-box: a test connection through the tunnel at the start (${e['probeReason']}) and '
              'again after ${windows.tunTcpDead.inSeconds} s did not get through${kind == VerdictKind.confirmed ? '' : ' [${kind.name}]'}';
        }
        return 'TUN (${e['stack']}): TCP does not reach sing-box: ${e['synSeen']} connection attempts in ${(e['windowMs'] as int) ~/ 1000} s, none accepted'
            '${apps.isEmpty ? '' : ' (${apps.join(', ')})'}${kind == VerdictKind.confirmed ? '' : ' [${kind.name}]'}';
      }),
    )).then((v) {
      // the start test's «dead» that turned out a blip (or was let go): the log judges the tunnel again
      if (d['probe'] == true && run == _tunStartRun && (v.kind == VerdictKind.blip || v.kind == VerdictKind.deferred)) tunIngress.probeCleared();
      final k = wroteKey, at = k == null ? null : _tunAppReported[k]?.at;
      if (k != null && at != null && v.eventId != null) _tunAppReported[k] = (at: at, id: v.eventId);
    }));
  }

  /// The waits before the tries of the test at the start: the tunnel comes up a moment after sing-box does.
  static const _tunStartWaits = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 2)];

  /// The active TUN test (tun_check.dart) at the start: a tunnel that came up broken has no traffic for the log
  /// detector to read. A try that passes ends it silently (the raw log says so); every try failing →
  /// [TunIngressDetector.probeDead], and the Sentinel confirms it by the same test after its window (a verdict only
  /// after a recheck). Ends with the run (stop / new start of Auto) or when the log detector found the tunnel dead first.
  void _tunStartCheck(String stack) {
    final tc = _tunCheck;
    if (tc == null || !tunIngress.active) return;
    final run = _tunStartRun;
    bool live() => run == _tunStartRun && _tunCheck == tc && tunIngress.active && !tunIngress.dead;
    unawaited(() async {
      var reason = 'unrouted';
      for (var i = 0; i < _tunStartWaits.length; i++) {
        final wait = Completer<void>();
        _tunStartTimer = sentinel.clock.timer(_tunStartWaits[i], () {
          if (!wait.isCompleted) wait.complete();
        });
        await wait.future;
        if (!live()) return;
        final cancel = _tunStartCancel = Cancel();
        CheckResult r;
        try {
          r = await tc.run(cancel);
        } catch (e) {
          r = CheckResult(tunCheckCode, Outcome.fail, {'reason': 'error', 'error': '$e'});
        }
        if (!live()) return;
        if (r.outcome == Outcome.pass) {
          logBook.note('info', 'TUN ($stack): the start test passed (try ${i + 1}, ${r.params['ms']}ms): TCP goes through the tunnel');
          return;
        }
        reason = '${r.params['reason'] ?? 'unknown'}';
        logBook.note('info', 'TUN ($stack): the start test failed (try ${i + 1} of ${_tunStartWaits.length}): $reason');
      }
      logBook.note('warn', 'TUN ($stack): the start test failed every try ($reason): TCP does not go through the tunnel; the Sentinel tests again after ${windows.tunTcpDead.inSeconds} s');
      tunIngress.probeDead(reason);
    }());
  }

  void _tunStartStop() {
    _tunStartRun++;
    _tunStartTimer?.cancel();
    _tunStartTimer = null;
    _tunStartCancel?.cancel('session.ended');
    _tunStartCancel = null;
  }

  /// A TCP connection arrived through the TUN again: the suspicion under way is a blip; a standing one closes
  /// and `core/tunTcpBack` says so.
  void _tunBack(Map<String, dynamic> d) {
    final root = sentinel.roots.byKey('tun.tcpDead');
    sentinel.recovered('tun.tcpDead');
    if (root != null) {
      _event('core', 'tunTcpBack', 'info', d,
          note: 'TUN (${d['stack']}): TCP reaches sing-box again after ${((d['deadMs'] as int) / 1000).round()} s', opens: root.eventId);
    }
  }

  /// The system proxy on / back off, each one written to the journal (`core/sysProxy`,
  /// `on` = what was asked for; `error` = it did not work). Returns [SystemProxy.enable]'s
  /// warning; errors go on to the caller.
  Future<String?> _sysOn({required bool own}) async {
    try {
      final port = _sysPort ?? _mixedPort; // with a password on the user port: the open sys-in
      final w = await sysProxy.enable(port);
      if (sysProxy.isSet) _event('core', 'sysProxy', 'info', {'on': true}, own: own, note: 'System proxy on 127.0.0.1:$port', op: _connectOp);
      return w; // not set (no system proxy on this platform): the warning says so
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': true, 'error': '$e'}, own: own, note: 'System proxy not set: $e', op: _connectOp);
      rethrow;
    }
  }

  Future<void> _sysOff({bool own = false, String? by}) async {
    final was = sysProxy.isSet;
    try {
      await sysProxy.restore();
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': false, 'by': ?by, 'error': '$e'}, own: own, note: 'System proxy not restored: $e', op: _connectOp);
      rethrow;
    }
    if (was) _event('core', 'sysProxy', 'info', {'on': false, 'by': ?by}, own: own, note: 'System proxy back off', op: _connectOp);
  }

  /// Auto in the core while connected (auto.dart). A move to another route or server
  /// changes where traffic leaves: the exit is checked again.
  void _startAuto(Map<String, dynamic> plan, {bool adopted = false}) {
    _stopAuto(park: true); // a user connect has dropped already (connect)
    // what a sing-box that just started does is counted from its first line, with or without the API
    failures.start();
    if (planTun(plan)) {
      final stack = planTunStack(plan);
      tunIngress.start(stack, ownRejects: [if (!planIpv6(plan)) 'ipv6Off']);
      _tunStartCheck(stack); // the log of a tunnel that came up broken is silent: ask it with a test connection
    }
    final api = runner.api;
    if (api == null) {
      _recheckExit(); // no controller (a test's fake process): the exit is asked of the tunnel port, unattributed
      return;
    }
    // another network since the last look (also while no service ran): the flap guard starts over and Auto's «no
    // network» is void (unknown until a round); the pool's «down» stays until an answer (the move asked the direct
    // path at once, [_probeNetwork]); a new sing-box says nothing of the network
    autoMemory.network(_directNetKey(), sentinel.context.netEpoch);
    pool.resetNetwork();
    // the outage that began in an earlier session goes on (its `conn.lost` root is not a session's, so it is still
    // open); one that never got to be a root (the stop came inside the window) is suspected again from its first moment
    final lostAt = autoMemory.lostAt;
    if (lostAt != null && sentinel.roots.byKey('conn.lost') == null) {
      routesLost(AutoNet(kind: 'lost', at: lostAt), planRoutes(plan).length);
    }
    final auto = _auto = AutoService(api, plan,
        clock: () => _nowMs,
        memory: autoMemory,
        pool: pool,
        exits: exitBook,
        exitCheck: (tag) async {
          final pr = _probe;
          if (pr == null) throw StateError('no probe inbound');
          return _pinnedExit(pr, tag);
        },
        onExit: _changed,
        delay:(tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t, unreachedThrows: true),
        reach: (tag, dest) async => _probe == null ? null : probeReach(_probe!, tag, dest),
        onDown: serverDown,
        ownConnection: _isOwnConnection,
        netSwitch: _failedInSwitchNow,
        netGate: ({bool suspicious = false}) => sentinel.networkGate(suspicious: suspicious),
        netProved: (startedAt) => sentinel.context.proved(since: startedAt),
        note: runner.note,
        trace: (l) => logBook.note('info', l));
    // requests that failed: sing-box's API service streams every closed connection
    _closed = api.closedConnections().listen((c) {
      // any data that came in on the new network (a connection with down > 0 that opened after the move: direct, any
      // outbound, our own probes and service requests too): the network works. Only the network matters, not a route.
      if (c.down > 0 && c.openedAt != null) sentinel.context.proved(since: c.openedAt);
      failures.onClosed(c);
      auto.onClosed(c);
    }, onError: (Object e) => runner.note('auto: connection events stopped: $e'));
    auto.switches.listen((s) {
      runner.note(s.isRoute ? 'auto: ${s.from} → ${s.to} (${s.reason})' : 'auto: ${s.route}: server ${s.from} → ${s.to} (${s.reason})');
      final entry = s.route ?? s.from; // the route (id) the move is about: the one a server moves in, the one left
      if (s.reason == 'fastest') {
        // ×N per route: the later moves are counted on the first (its `from` stays, `to` is where it is now)
        final prev = eventBook.recent('auto', 'fastest', {'route': s.route}, const Duration(hours: 1));
        if (prev != null) {
          final d = prev['data'] as Map<String, dynamic>;
          eventBook.repeated(prev['id'] as int, data: {'route': s.route, 'from': d['from'] ?? s.from, 'to': s.to}, level: 'info', cause: (prev['cause'] as num?)?.toInt());
        } else {
          eventBook.add('auto', 'fastest', 'info', data: {'route': s.route, 'from': s.from, 'to': s.to}, cause: _netCause());
        }
      } else {
        // a move back closes the failover of the same route (or, for a route move, the same Auto)
        final key = s.route ?? '';
        final failover = s.reason == 'failover';
        final series = _autoSeries[key];
        final inSeries = failover && series != null && _nowMs - series.at <= _seriesWithin.inMilliseconds && eventBook.byId(series.id) != null;
        final cause = failover || s.reason == 'back'
            ? ((inSeries ? _rootOf(series.id) : null) ?? _unstableOf(entry) ?? (failover && s.route != null ? _nodeIncident(s.from) : null) ?? _netCause())
            : null;
        final id = eventBook.add('auto', 'switched', 'info',
            data: {'route': ?s.route, 'from': s.from, 'to': s.to, 'reason': s.reason},
            opens: s.reason == 'back' ? _autoFailoverIds.remove(key) : null,
            cause: s.reason == 'back' ? null : cause);
        if (failover) {
          _autoFailoverIds[key] = id;
          _autoSeries[key] = (id: cause ?? id, at: _nowMs);
          if (s.route != null) _nodeIncidents[s.from] = (id: cause ?? id, at: _nowMs);
        } else if (s.reason == 'back') {
          _autoSeries.remove(key); // the trouble is over
        }
      }
      unawaited(_dns?.nodeChanged()); // another node: its stored DNS verdicts apply (no-op when the identity did not change)
    });
    auto.unstable.listen((u) {
      runner.note('auto: ${u.id} is unstable (${u.strikes} drops), back to it after ${u.holdMs ~/ 60000} min of answers');
      unawaited(routeUnstable(u));
    });
    auto.siteFails.listen(siteFailed);
    // another network: the unavailable nodes are asked once out of turn (ladder.dart)
    var netEpoch = sentinel.context.netEpoch;
    _netChanged = sentinel.context.changes.listen((_) {
      if (sentinel.context.netEpoch == netEpoch) return;
      netEpoch = sentinel.context.netEpoch;
      final s = sentinel.context.network.state;
      if (s != NetState.none && s != NetState.captive) {
        auto.networkChanged(); // (also starts the flap guard over)
        _fallback?.networkChanged(); // the rule targets' Fastest groups look for a better server out of turn
        autoMemory.network(_directNetKey(), netEpoch);
        unawaited(_dns?.networkChanged()); // the DNS in use is asked at once, in parallel
      }
      _siteMemos.removeWhere((_, m) => !m.dead); // another network: the verdicts of the ladder are void, it starts over
    });
    // `lost` / `restored` are Auto's (no route answers); `offline` / `online` are the Sentinel's network
    // context (_syncNetEvents): the OS, the platform and the probes all feed one root, no second source
    auto.net.listen((n) {
      if (n.kind == 'lost') {
        routesLost(n, auto.routeIds.length);
      } else if (n.kind == 'restored') {
        routesRestored(n);
      }
    });
    auto.reconcileStart = !adopted; // a taken-over sing-box stands where the core before this one left it
    auto.start();
    _startFallback(api, auto, adopted: adopted);
    _startDnsFailover(api, auto);
    _changed();
  }

  /// `auto/unstable`: Auto's flap guard held a route back. An announcement, not a standing failure: the
  /// root the Sentinel opens for it is closed at once (Auto itself keeps the route on hold), so the next
  /// one for the same route is judged and written again. Public for the tests.
  Future<void> routeUnstable(AutoUnstable u) async {
    final key = 'auto.unstable|${u.id}';
    final v = await sentinel.suspect(Suspicion(
      kind: 'auto.unstable',
      key: key,
      subject: {'route': u.id, 'path': 'proxy', 'dns': ?_routeResolver(u.id)},
      evidence: {'id': u.id, 'strikes': u.strikes, 'holdMs': u.holdMs},
      window: windows.autoUnstable,
      why: Why('route.unstable', {'strikes': u.strikes, 'holdMs': u.holdMs}),
      scope: Scope.none,
      level: Level.route,
      event: SuspicionEvent('auto', 'unstable', level: 'warn'),
    ));
    if (v.kind == VerdictKind.confirmed) {
      sentinel.closeRoot(key, reason: 'reported');
      final id = v.eventId;
      if (id != null) {
        _unstableIds[u.id] = (id: id, until: _nowMs + u.holdMs);
        // the move off the route came first (Auto emits the drop, then moves): it is under the announcement
        final moved = _autoFailoverIds[u.id] ?? _autoFailoverIds[''];
        final e = moved == null ? null : eventBook.byId(moved);
        if (e != null && e['cause'] == null && (e['at'] as int) >= u.at - 5000) eventBook.update(moved!, cause: id);
      }
    }
  }

  /// `conn/lost`: no route answers. A suspicion: it is a consequence of `net.offline` when the direct path is
  /// silent too, a `blip` when a route answers again inside the window; a standing one is a root that
  /// covers every failure through the proxy (`path: proxy`) until [routesRestored]. Public for the tests.
  void routesLost(AutoNet n, int routes) {
    unawaited(sentinel.suspect(Suspicion(
      kind: 'conn.lost',
      key: 'conn.lost',
      subject: {'path': 'proxy', 'dns': ?_routesResolver()},
      evidence: {'routes': routes},
      window: windows.connLost,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(n.at),
      why: const Why('routes.silent'),
      scope: Scope.of(const {'path': 'proxy'}),
      session: false, // the outage is not the connection's: a restart or a reconnect does not end it, a route that answers does
      event: SuspicionEvent('conn', 'lost', level: 'warn', note: (kind, e) => switch (kind) {
            VerdictKind.confirmed => 'No route answers (${e['routes']} tried)',
            VerdictKind.blip => 'No route answered for a moment (${e['routes']} tried), then one did',
            VerdictKind.consequence => 'No route answers (${e['routes']} tried): because of another failure',
            _ => 'No route answers (${e['routes']} tried): no reason found',
          }),
    )));
  }

  void routesRestored(AutoNet n) {
    final root = sentinel.roots.byKey('conn.lost');
    sentinel.recovered('conn.lost');
    if (root != null) eventBook.add('conn', 'restored', 'info', data: {'downMs': ?n.downMs}, opens: root.eventId);
  }

  // `conn/offline` / `conn/online`: written from the Sentinel's `net.offline` root, so the OS, the platform and
  // the probes are one source. The root stands for [FailureWindows.netBlip] before it is an event; gone
  // sooner, the journal gets a `blip` that says how long. Consequences written meanwhile get the event as `cause`.
  Root? _netRoot;
  bool _netStanding = false;
  Timer? _netTimer;

  void _syncNetEvents() {
    final root = sentinel.roots.byKind(rootNetOffline);
    final mine = _netRoot;
    if (root != null && mine == null) {
      _netRoot = root;
      _netStanding = false;
      if (windows.netBlip <= Duration.zero) {
        _netOfflineStands(root);
      } else {
        _netTimer = sentinel.clock.timer(windows.netBlip, () {
          final r = sentinel.roots.byKind(rootNetOffline);
          if (identical(r, root) && !_disposed) _netOfflineStands(root);
        });
      }
    } else if (root == null && mine != null) {
      _netTimer?.cancel();
      _netTimer = null;
      _netRoot = null;
      final downMs = _nowMs - mine.since.millisecondsSinceEpoch;
      if (_netStanding) {
        _event('conn', 'online', 'info', {'downMs': downMs, 'source': mine.subject['source']}, opens: mine.eventId);
      } else {
        final id = _event('conn', 'offline', 'info', {'downMs': downMs, 'source': mine.subject['source']},
            verdict: 'blip',
            why: Why('recovered', {'afterMs': downMs, 'by': 'net.restored'}),
            trail: [
              TrailStep('ctx.net', Outcome.fail, mine.since.millisecondsSinceEpoch, {'state': 'none', 'source': mine.subject['source']}),
              TrailStep('blip.recovered', Outcome.pass, _nowMs, {'afterMs': downMs, 'by': 'net.restored'}),
            ],
            note: 'The network was gone for ${(downMs / 1000).round()} s');
        sentinel.attachEvent(mine, id);
      }
      _netStanding = false;
    }
  }

  void _netOfflineStands(Root root) {
    _netStanding = true;
    final src = root.subject['source'];
    final id = _event('conn', 'offline', 'warn', {'source': src},
        verdict: 'confirmed',
        why: Why('net.offline', {'source': src}),
        trail: [TrailStep('ctx.net', Outcome.fail, root.since.millisecondsSinceEpoch, {'state': 'none', 'source': src})],
        note: 'The network is gone ($src)');
    sentinel.attachEvent(root, id);
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

  // «Check now» runs under way by subject (a second command for it joins): true = it works, false = it does not, null = the
  // subject is not in the live config.
  final _checkRuns = <String, Future<bool?>>{};
  // the events that carry the run's `recheck` (each gets its pending and its result once, however many commands came for it)
  final _checkEvents = <String, Set<int>>{};

  /// «Check now» (api.dart): the event's subject is checked by the code of its scheduled round (auto.dart `roundNow` /
  /// `routeNow`, fallback.dart `checkTarget`, dns_failover.dart `checkServer`), which closes the pair itself. The event
  /// carries `data.recheck` (pending → ok / fail).
  @override
  Future<Map<String, dynamic>> checkNow(int eventId) async {
    final ev = eventBook.byId(eventId);
    final d = ev?['data'];
    if (ev == null || d is! Map) throw const FormatException('No such event');
    final key = switch ('${ev['cat']}/${ev['type']}') {
      'conn/lost' => 'round',
      'auto/unstable' when d['id'] is String => 'route:${d['id']}',
      'rules/fallback' when d['target'] is String => 'target:${d['target']}',
      'dns/failed' || 'dns/failedOnNode' when d['server'] is String => 'dns:${d['server']}',
      _ => null,
    };
    if (key == null) throw const FormatException('Nothing to check for this event');
    final auto = _auto;
    if (!runner.running || _plan == null || auto == null) return {'ok': false, 'error': 'notConnected'};
    // a second command for the event already waiting on the run joins it silently (the first one writes the result)
    final joined = _checkEvents[key]?.contains(eventId) ?? false;
    if (!joined) {
      (_checkEvents[key] ??= {}).add(eventId);
      eventBook.update(eventId, data: {'recheck': {'state': 'pending', 'at': _nowMs}});
    }
    final run = _checkRuns[key] ??= (switch (key.split(':').first) {
      'round' => auto.roundNow(),
      'route' => auto.routeNow(key.substring(6)),
      'target' => _fallback?.checkTarget(key.substring(7)) ?? Future<bool?>.value(null),
      _ => _dns?.checkServer(key.substring(4)) ?? Future<bool?>.value(null),
    }).whenComplete(() {
      _checkRuns.remove(key);
      _checkEvents.remove(key);
    });
    bool? ok;
    try {
      ok = await run;
    } catch (_) {
      ok = false;
    }
    // the service ended or Auto was stopped (a reconnect) under the run: nothing was judged, so the event goes back to no
    // `recheck` (the Check now button returns) instead of staying pending or recording a fail
    if (_disposed || !identical(_auto, auto)) {
      if (!joined) _dropRecheck(eventId);
      return {'ok': false, 'error': 'notConnected'};
    }
    // the subject left the live config: nothing was judged either
    if (ok == null) {
      if (!joined) _dropRecheck(eventId);
      return {'ok': false, 'error': 'gone'};
    }
    if (!joined) eventBook.update(eventId, data: {'recheck': {'state': ok ? 'ok' : 'fail', 'at': _nowMs}});
    return {'ok': true};
  }

  void _dropRecheck(int eventId) {
    final d = eventBook.byId(eventId)?['data'];
    if (d is! Map<String, dynamic> || !d.containsKey('recheck')) return;
    eventBook.update(eventId, data: {...d}..remove('recheck'), replaceData: true);
  }

  /// «Retry» on `rules/ruleSetFailed` (api.dart): the lists of the event's `ruleSets` operation (else its own) are loaded
  /// again, forced, by the path of the automatic update (its events under the lists' operation, the reconnect that picks
  /// a new list up). Not connected: nothing is loaded, every list is `failed`.
  @override
  Future<Map<String, dynamic>> retryRuleSets(int eventId) async {
    final ev = eventBook.byId(eventId);
    final d = ev?['data'];
    if (ev == null || ev['cat'] != 'rules' || ev['type'] != 'ruleSetFailed' || d is! Map || d['tag'] is! String) {
      throw const FormatException('No such rule set event');
    }
    final tags = <String>{'${d['tag']}'};
    final opId = (ev['op'] as Map?)?['id'];
    if (opId != null) {
      for (final e in (eventBook.since(0)['events'] as List).cast<Map<String, dynamic>>()) {
        final t = (e['data'] as Map?)?['tag'];
        if (e['cat'] == 'rules' && (e['type'] == 'ruleSetFailed' || e['type'] == 'ruleSetUpdated') && (e['op'] as Map?)?['id'] == opId && t is String) tags.add(t);
      }
    }
    final plan = _plan;
    if (plan == null || !runner.running) return {'updated': <String>[], 'failed': tags.toList()..sort()};
    final seq = _connectSeq;
    final sources = [for (final s in ruleSetsNeeded(plan)) if (tags.contains(s.tag)) s];
    final r = await _inRuleSetsOp(() => ruleSets.ensure(sources, tunnel: runner.running, force: true));
    final live = _plan;
    if (!_disposed && seq == _connectSeq && live != null && runner.running && r.files.keys.any((t) => !_listTags.contains(t))) {
      // a list new to the config needs the restart that picks it up (as in [_listsRound])
      unawaited(_connect({'plan': _continuationPlan(live), 'systemProxy': _sysWanted}, own: false).then((_) {}, onError: (_) {}));
    }
    final failed = {...r.failedTags, for (final t in tags) if (!sources.any((s) => s.tag == t)) t};
    return {'updated': r.downloaded.toList()..sort(), 'failed': failed.toList()..sort()};
  }

  static (String, int?) _hostPort(String dest) {
    final at = dest.lastIndexOf(':'), port = at < 0 ? null : int.tryParse(dest.substring(at + 1));
    return (port == null ? dest : dest.substring(0, at), port);
  }

  /// "If unavailable" live: a target that stops answering has its rules' selectors flipped to
  /// the fallback, and back (fallback.dart). Not while Auto doubts the network.
  void _startFallback(SingBoxApi api, AutoService auto, {bool adopted = false}) {
    if (_fallbacks.isEmpty) return;
    final fb = _fallback = FallbackService(api, _fallbacks,
        clock: () => _nowMs,
        delay: (tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t, unreachedThrows: true),
        settings: auto.settings,
        pool: pool,
        mainIdentity: auto.identityOf,
        memory: autoMemory,
        onDown: serverDown,
        netGate: ({bool suspicious = false}) => sentinel.networkGate(suspicious: suspicious),
        setFlag: (f, on) => setFallbackFlag(f, on, reason: on ? 'on Direct' : 'back', log: logBook.note),
        note: runner.note)
      ..reconcileStart = !adopted; // a taken-over sing-box's groups stand where the core before this one left them
    fb.changes.listen((c) {
      // the journal names the first rule (else the first app) and counts the rest
      final total = c.rules.length + c.apps.length;
      final data = {
        if (c.rules.isNotEmpty) 'rule': c.rules.first else 'app': c.apps.first,
        if (total > 1) 'more': total - 1,
        'target': c.target,
      };
      if (c.back) {
        eventBook.add('rules', 'targetBack', 'info', data: data, opens: _fallbackIds.remove(c.target));
      } else {
        // under the loss of the same target, else under the failure of the node the target is (an incident); never under a
        // network switch: net/switched does not notify, a failure that stands after the switch must
        final lost = _lostTargets.values.where((l) => l.target == c.target).map((l) => _lostIds[l.id]).whereType<int>().firstOrNull;
        final node = c.target.startsWith('node:') ? c.target.substring(5) : null;
        // an incident whose root is a network switch (its failover was written under it) is not a root for a fallback
        final inc = node == null ? null : _nodeIncident(node);
        final cause = lost ?? (inc == null || eventBook.byId(inc)?['cat'] == 'net' ? null : inc);
        final id = _fallbackIds[c.target] = eventBook.add('rules', 'fallback', 'warn', data: {...data, 'to': c.to}, cause: cause);
        if (cause == null && node != null) _nodeIncidents[node] = (id: id, at: _nowMs);
      }
    });
    fb.start();
  }

  /// DNS failover: the DNS servers of the config are checked and judged (dns_failover.dart) and their flags
  /// (dns_flags.dart) follow the verdicts. The flags of the sing-box before this one ([_dnsFlagMemory]: a crash, an
  /// own restart) were written into the new one by [_startSingBox]; they are the failover's start state.
  void _startDnsFailover(SingBoxApi api, AutoService auto) {
    if (_dnsServers.isEmpty && _dnsExtra.isEmpty) return;
    final probe = _probe;
    if (probe == null) return;
    final byId = {for (final c in _dnsCandidates) c.id: c};
    final reserve = {for (final id in _dnsReserveMemory) if (byId.containsKey(id)) id};
    final off = {for (final e in _dnsFlagMemory.entries) if (!e.value && byId.containsKey(e.key) && !reserve.contains(e.key)) e.key};
    final dns = _dns = DnsFailover(
        clock: () => _nowMs,
        sides: _dnsSides,
        candidates: _dnsCandidates,
        watch: _dnsExtra,
        off: off,
        reserve: reserve,
        book: dnsBook,
        node: _dnsNode,
        nodes: DnsNodes(
          spare: () {
            final n = auto.spareNode();
            return n == null ? null : (key: n.server, tag: n.tag);
          },
          exitKey: auto.exitNodeKey,
          exitAlive: auto.exitAlive,
          ask: _dnsAskVia,
        ),
        setFlag: _setDnsFlag,
        query: _dnsAsk,
        flagCheck: _dnsFlagCheck,
        settings: auto.settings,
        sentinel: sentinel,
        window: windows.dnsDown,
        auto: _dnsAuto,
        pool: pool,
        note: logBook.note,
        flagWait: dnsFlagWait,
        flagPoll: dnsFlagPoll);
    if (off.isNotEmpty) logBook.note('info', 'dns: flags off again after the restart: ${off.join(', ')}');
    dns.switches.listen((s) {
      // a move back closes the failover of the same side
      final id = _event('dns', 'switched', 'info', {
        'side': s.side,
        'from': s.from,
        'to': s.to,
        'fromProvider': s.fromProvider,
        'toProvider': s.toProvider,
        'reason': s.reason,
      },
          own: s.reason == 'off',
          opens: s.reason == 'back' ? _dnsFailoverIds.remove(s.side) : null,
          // another exit node is the failure of the node left (its incident), a failover in the window of a switch is the switch's
          cause: s.reason == 'node'
              ? (_nodeIncidents.values.where((i) => _nowMs - i.at <= 120000).map((i) => i.id).firstOrNull ?? _netCause())
              : s.reason == 'failover' ? _netCause() : null);
      if (s.reason == 'failover') _dnsFailoverIds[s.side] = id;
    });
    dns.start();
  }

  /// The exit node the VPN side of the DNS is checked through: Auto's server in use, else the one the plan starts on.
  String? _dnsNode() => _auto?.exitNodeIdentity() ?? dnsPlanNode(_plan);

  /// How long sing-box may take to apply a flag file before the core warns, and the pause between its questions
  /// (tests shorten them).
  Duration dnsFlagWait = const Duration(seconds: 3), dnsFlagPoll = const Duration(milliseconds: 60);

  /// Writes a flag file for the failover (dns_flags.dart), told to the core log with its reason.
  Future<bool> _setDnsFlag(DnsCandidate c, bool on, String reason) async {
    try {
      setDnsFlag(c, on, reason: reason, log: logBook.note);
      return true;
    } catch (_) {
      return false; // setDnsFlag has told why
    }
  }

  /// The test seam of the flag check ([probeFlag] through the probe inbound by default): whether the candidate is
  /// the one its side answers with; null = cannot be told.
  Future<bool?> Function(DnsCandidate c)? dnsFlagProbe;

  Future<bool?> _dnsFlagCheck(DnsCandidate c) {
    final q = dnsFlagProbe;
    if (q != null) return q(c);
    final probe = _probe;
    return probe == null ? Future.value(null) : probeFlag(probe, c.tag, dnsFlagcheckName(c.side));
  }

  /// The test seam of the DNS queries (`probeDns` through the probe inbound by default): ms until the server [tag] resolved [name].
  Future<int> Function(String tag, String name, int timeoutMs)? dnsQuery;

  Future<int> _dnsAsk(String tag, String name, int timeoutMs) {
    final q = dnsQuery;
    if (q != null) return q(tag, name, timeoutMs);
    final probe = _probe;
    return probe == null ? Future.value(-1) : probeDns(probe, tag, name, timeoutMs: timeoutMs);
  }

  /// The test seam of the DNS queries through another node ([probeDnsVia] by default): ms until the candidate [c] answered
  /// [name] sent through the outbound [tag]; -1 = no answer; null = cannot be asked that way.
  Future<int?> Function(DnsCandidate c, String tag, String name, int timeoutMs)? dnsQueryVia;

  Future<int?> _dnsAskVia(DnsCandidate c, String tag, String name, int timeoutMs) {
    final q = dnsQueryVia;
    if (q != null) return q(c, tag, name, timeoutMs);
    final probe = _probe;
    return probe == null ? Future.value(null) : probeDnsVia(probe, tag, c, name, timeoutMs: timeoutMs);
  }

  /// The DNS server a connection resolved through (docs/rules.md §6): the user rule's own chain, the first
  /// candidate whose flag is on; for a direct outbound the direct side's answering server; else the VPN side's.
  /// The OS resolver (`local`) is the server `system`. Null when there is none.
  ({String id, String tag, bool vpn})? _resolverFor(String outbound, Map<String, dynamic> evidence) {
    final text = evidence['rule'] is String ? evidence['rule'] as String : '${(evidence['noticed'] as Map?)?['rule'] ?? ''}';
    final origin = text.isEmpty ? null : _ruleNames?.of(text);
    final flags = _dns?.flags ?? const <String, bool>{};
    String? tag;
    if (origin != null && origin.kind == 'user') {
      final chain = _ruleChains[origin.id] ?? const <String>[];
      tag = chain.where((t) => flags[t.startsWith('dns-') ? t.substring(4) : t] ?? true).firstOrNull ?? chain.firstOrNull ?? _ruleDns[origin.id];
    }
    final all = [..._dnsServers, ..._dnsExtra];
    DnsEntry? e = tag == null ? null : all.where((s) => s.tag == tag).firstOrNull;
    if (e == null && tag == null) {
      final id = _dns?.activeOf(outbound == 'direct' ? 'direct' : 'vpn');
      e = all.where((s) => s.id == id).firstOrNull;
      if (e == null && outbound == 'direct') e = all.where((s) => s.tag == _domainResolver).firstOrNull;
      e ??= all.where((s) => s.id == _dns?.active).firstOrNull ?? _dnsServers.firstOrNull;
    }
    return e == null ? null : (id: e.id, tag: e.tag, vpn: _dnsVpn.contains(e.id));
  }

  /// The id of the DNS server that resolves the domain-named servers of route [routeId] (the `domain_resolver` of the
  /// node outbounds: the top of the system chain, the OS resolver `system` when it has no server); null when no server
  /// of the route is looked up by name by sing-box (all addresses or pinned to one; a chain's exit is resolved on the
  /// entry's far side) or the plan has no such route. A route depends on it (docs/failures.md → DNS-серверы как узлы).
  String? _routeResolver(String routeId) {
    final plan = _plan;
    if (plan == null) return null;
    final rs = planRoutes(plan);
    for (var i = 0; i < rs.length; i++) {
      if ('${rs[i]['id'] ?? routeTag(i)}' == routeId) return _nameRoutes.contains(routeId) ? _domainResolverId() : null;
    }
    return null;
  }

  /// The resolver every route depends on: set only when each route has a server looked up by name (one reachable
  /// by address would still answer, so the resolver would not explain «no route answers»).
  String? _routesResolver() {
    final plan = _plan;
    if (plan == null) return null;
    final rs = planRoutes(plan);
    return rs.isNotEmpty && [for (var i = 0; i < rs.length; i++) '${rs[i]['id'] ?? routeTag(i)}'].every(_nameRoutes.contains) ? _domainResolverId() : null;
  }

  String? _domainResolverId() => [..._dnsServers, ..._dnsExtra].where((s) => s.tag == _nodeResolver).firstOrNull?.id;

  void _stopAuto({bool park = false}) {
    unawaited(_closed?.cancel());
    _closed = null;
    unawaited(_netChanged?.cancel());
    _netChanged = null;
    sentinel.dropAll(park: park); // a stop or a new connect: what was seen in this session is void, its detectors suspect again in the next; an own restart or a crash-recovery parks
    failures.stop();
    tunIngress.stop();
    _tunStartStop();
    _auto?.stop();
    _auto = null;
    _fallback?.stop();
    _fallback = null;
    final dns = _dns;
    if (dns != null) {
      _dnsFlagMemory = dns.flags; // a sing-box the core starts next is given these flags again
      _dnsReserveMemory = dns.reserve;
    }
    dns?.stop();
    _dns = null;
    pool.resetNetwork(); // a stop does not make the network «up» (only an answer does)
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
    final seq = _connectSeq, next = _continuationPlan(plan);
    _stopAuto(park: true);
    sentinel.context.crashed();
    runner.note('sing-box stopped on its own (exit code $code)');
    // the crash is a root cause until sing-box is back: the restart that fails is its consequence
    final id = _event('core', 'crashed', 'error', {'code': code},
        verdict: 'confirmed', why: Why('core.exit', {'code': code}), trail: [TrailStep('core.exit', Outcome.fail, _nowMs, {'code': code})]);
    _crashRoot = sentinel.openRoot(kind: 'core.crashed', subject: const {'core': 'sing-box'}, scope: Scope.none, eventId: id, session: false);
    _restartFailedId = null; // the tries of this crash are one event
    if (_now().difference(_upSince) > const Duration(minutes: 1)) _attempt = 0;
    _downSince = null;
    _released = false;
    _recover(seq, next, code);
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
          sentinel.context.starting('recover');
          final (l, w) = await _startSingBox(plan, sys: _sysWanted, why: 'recover', waitAddresses: false); // the same path as a connect (cached addresses only)
          lists = l;
          warnings.addAll(w);
          sentinel.context.started();
        } catch (e) {
          runner.note('restart $_attempt failed: $e');
          // every try is told ("Never hide problems"): the first one writes the event, the next ones are repeats on it
          // (`data.repeat`, ×N); our own restart that failed, after the crash, is a consequence of it (cause = the crash event)
          final crash = _crashRoot;
          final why = Why('core.crashed', {'attempt': _attempt});
          final trail = [TrailStep('restart.failed', Outcome.fail, _nowMs, {'attempt': _attempt, 'reason': 'recover'})];
          final prev = _restartFailedId;
          if (prev != null && eventBook.byId(prev) != null) {
            eventBook.repeated(prev,
                data: {'attempt': _attempt, 'error': '$e'},
                level: 'error',
                verdict: 'consequence',
                why: why.toJson(),
                trail: [for (final t in trail) t.toJson()],
                cause: crash?.eventId);
          } else {
            _restartFailedId = _event('core', 'restartFailed', 'error', {'attempt': _attempt, 'error': '$e'},
                verdict: 'consequence', why: why, trail: trail, cause: crash?.eventId);
          }
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
        final crashId = _crashRoot?.eventId;
        _closeCrashRoot('restarted');
        _restartFailedId = null;
        _event('core', 'restarted', 'info', {'attempt': _attempt, if (wasDown) 'downMs': downMs},
            note: 'sing-box started again (attempt $_attempt)', opens: crashId);
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
    sentinel.context.down();
    _downProxy = _released ? 'released' : (sysProxy.isSet ? 'kept' : 'removed');
    // `core.down` (the Sentinel's context root) covers every failure through the core: the event is its event
    final id = _event('core', 'down', 'error', {'proxy': _downProxy},
        verdict: 'confirmed',
        why: const Why('core.down'),
        trail: [TrailStep('ctx.core', Outcome.fail, _nowMs, const {'phase': 'down'})],
        note: 'Connection down: sing-box does not start (system proxy $_downProxy)');
    final root = sentinel.roots.byKind(rootCoreDown);
    if (root != null) sentinel.attachEvent(root, id);
  }

  Root? _crashRoot;
  int? _restartFailedId; // the `core/restartFailed` event of the crash under way: the next tries repeat on it

  void _closeCrashRoot(String reason) {
    final r = _crashRoot;
    if (r == null) return;
    _crashRoot = null;
    sentinel.closeRoot(r.id, reason: reason);
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
        'exit': _exitStatus(),
        'recovering': _recovering,
        'down': _downSince == null
            ? null
            : {'since': _downSince!.millisecondsSinceEpoch, 'attempt': _attempt, 'proxy': _downProxy},
        'blocking': _blocking,
        'restarts': _restarts,
        'auto': _autoState(),
        'network': pool.toJson(),
        'context': sentinel.contextJson(), // the Sentinel's view: network state, core phase, open root causes (docs/failures.md)
        'dns': runner.running && _dns?.isEmpty == false ? _dns!.toJson() : null,
        'sourcesRev': store.rev, // moves when the timer updated a subscription: the UI reloads them
        // manual subscription updates that wait for the network / the connection; absent when none
        if (_subWaits.isNotEmpty) 'subWaits': [for (final w in _subWaits) {...w}],
        'rulesLost': [for (final l in _lostTargets.values) l.toJson()], // rules / apps whose target is lost (docs/rules.md §0)
        'speed': _lastSpeed, // last Speed Test of the connection: {down, up (bit/s), latency (ms), rpm, at (ms)}
      };

  /// The exit shown as «your IP»: while connected with the controller, the latest answer of the node in use, the stored
  /// one at once (null = nothing known yet / the user's re-check is running); else the direct / unattributed check
  /// ([_recheckExit]).
  Map<String, dynamic>? _exitStatus() {
    final auto = _auto;
    return runner.running && auto != null ? auto.exitInUse() : _exit;
  }

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
  /// group still on a server that died since it was chosen, right after connect): ask again in a
  /// couple of seconds, for up to 15 s, before reporting the error.
  ///
  /// The direct check (no tunnel) is not repeated while the network is the one the stored result was taken on
  /// (same type and id, no move or loss since: the Sentinel context's `netEpoch`; the result and its network are kept in
  /// `exit-direct.json`, so a restart keeps it too); [force] (the user's request) asks anyway.
  void _recheckExit({bool force = false}) {
    final auto = _auto;
    if (runner.running && auto != null) {
      // connected: the controller asks, pinned to the node in use (auto.dart); the status' exit is its answer
      auto.recheckExit();
      _changed();
      return;
    }
    final direct0 = !runner.running;
    if (direct0 && !force) {
      _loadDirect();
      final d = _directStored;
      final k = _directNetKey(); // '|' = the platform has not said which network yet (a start): the stored one stands
      if (d != null && (_directNet == k || k == '|') && (_directEpoch == null || _directEpoch == sentinel.context.netEpoch)) {
        if (_exit == null || _exit!['direct'] != true) {
          _exit = d;
          _changed();
        }
        return;
      }
    }
    final seq = ++_exitSeq;
    final direct = !runner.running;
    // the direct check keeps the last answer shown (as the node's re-check does): `rechecking` until the new one
    Map<String, dynamic>? kept;
    if (direct) {
      _loadDirect();
      final cur = _exit;
      final base = cur != null && cur['direct'] == true && cur['error'] == null && cur['ip'] != null ? cur : _directStored;
      if (base != null) kept = {...base, 'direct': true}..remove('error')..remove('rechecking');
    }
    _exit = kept == null ? null : {...kept, 'rechecking': true};
    _changed();
    final since = Stopwatch()..start();
    Future<void> attempt() async {
      final sw = Stopwatch()..start();
      try {
        // direct (no tunnel): the machine's own IP, nothing is kept per node; a connection with no controller (no API
        // service) asks the tunnel port, also unattributed
        final e = await exitCheck(direct ? null : _tunnelPort ?? _mixedPort);
        if (seq == _exitSeq) {
          _exit = {...e, 'direct': direct, 'at': DateTime.now().millisecondsSinceEpoch};
          if (direct) _saveDirect(_exit!);
        }
      } catch (e) {
        if (seq != _exitSeq) return;
        if (!direct && sw.elapsed < const Duration(seconds: 3) && since.elapsed < const Duration(seconds: 15) && runner.running) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (seq == _exitSeq) return attempt();
          return;
        }
        _exit = {...?kept, 'error': '$e', 'direct': direct}; // a kept answer stays, the error next to it
      }
      _changed();
    }

    attempt();
  }

  Map<String, dynamic>? _directStored; // the last completed direct check
  String? _directNet; // the network (type|id) it was taken on
  int? _directEpoch; // the Sentinel's netEpoch at that time; null = read from the file (another run)
  bool _directLoaded = false;
  File get _directFile => File(p.join(dataDir, 'exit-direct.json'));

  String _directNetKey() {
    final n = sentinel.context.network;
    return '${n.type ?? ''}|${n.id ?? ''}';
  }

  void _loadDirect() {
    if (_directLoaded) return;
    _directLoaded = true;
    try {
      final j = jsonDecode(_directFile.readAsStringSync());
      if (j is Map && j['result'] is Map && j['net'] is String) {
        _directStored = (j['result'] as Map).cast<String, dynamic>();
        _directNet = j['net'] as String;
      }
    } catch (_) {}
  }

  void _saveDirect(Map<String, dynamic> result) {
    _directLoaded = true;
    _directStored = result;
    _directNet = _directNetKey();
    _directEpoch = sentinel.context.netEpoch;
    final text = jsonEncode({'v': 1, 'net': _directNet, 'result': result});
    // one write after another, and dispose waits for the last: a file still open would hold the data dir
    _directWrite = _directWrite.then((_) => writeFileDurable(_directFile, text)).catchError((_) {});
  }

  Future<void> _directWrite = Future.value();

  @override
  Future<Map<String, dynamic>> recheckExit() {
    _recheckExit(force: true);
    return status();
  }

  /// body: {sid, source: {url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid,
  /// filter, channel}, rediscover} → {patch, title, notModified, via} (updater.dart). The answer comes after the load (or
  /// the error): no network waits up to 5 s (`sub/failed` `offline`), our own reconnect waits for the core to settle
  /// (the core down: `sub/failed` `core.down`); `status.subWaits` shows the wait.
  @override
  Future<Map<String, dynamic>> fetchSource(Map<String, dynamic> body) async {
    final s = ((body['source'] as Map?) ?? const {}).cast<String, dynamic>();
    final sid = body['sid'] as String?;
    // the app's request carries no name (a fixed set of fields): the stored copy of the source has it
    final given0 = s['name'] ?? body['name'];
    Object? stored;
    if (given0 == null && sid != null) stored = (await store.source(sid))?['name'];
    final name = '${given0 ?? stored ?? sid ?? ''}';
    // the user's operation (the app's "update all" names its own in the body), else this source's own
    final given = body['op'];
    final op = given is Map && given['id'] is String && given['kind'] is String ? {'id': given['id'], 'kind': given['kind']} : _newOp('subUpdate');
    return updater.guard<Map<String, dynamic>>(sid, () async {
      try {
        final ctx = sentinel.context;
        // no network: waited for up to 5 s, whatever the path (a captive portal is no network for this)
        bool offline() => ctx.network.state == NetState.none || ctx.network.state == NetState.captive;
        if (offline()) {
          final back = await _subWaiting(sid, name, 'network', () => ctx.waitFor(() => !offline(), timeout: _subNetWait));
          if (!back && offline()) throw _SubAbort('No network', 'offline');
        }
        // a load that can only go through the VPN waits for our own reconnect / restart to be over
        if (Channel.of(s['channel'] as String?) == Channel.proxy && _coreRestarting) await _subSettle(sid, name);
        Map<String, dynamic> r;
        int? retriedAt;
        while (true) {
          try {
            r = await updateSubscription(
              s,
              hwid: s['hwid'] == true ? await _hwid : null,
              svc: svcFetch,
              sid: sid,
              rediscover: body['rediscover'] == true,
              onDiverged: _subDiverged,
            );
            break;
          } catch (e) {
            if (!isOwnRestartFailure(e)) rethrow;
            // our own restart cut it: once the core has settled, the load is made again (once per settle)
            await _subSettle(sid, name);
            if (retriedAt == ctx.coreEpoch) rethrow;
            retriedAt = ctx.coreEpoch;
          }
        }
        if (r['stale'] case final Map stale) _subStale(stale.cast<String, dynamic>());
        final nodes = (r['patch'] as Map?)?['nodes'];
        if (nodes is List) {
          _warmNodes(nodes, 'subscription update');
          if (sid != null) _exitSourceRefreshed(sid, nodes);
        }
        if (sid != null) {
          _subFetched(sid);
          // the user waits: written at once, whatever changed, no Sentinel
          for (final (type, data) in subUpdateEvents(sid, {...s, 'name': name}, (r['patch'] as Map).cast<String, dynamic>(), always: true, inUse: _nodeInUse)) {
            _subEvent(type, data, own: true, op: op);
          }
        }
        return r;
      } catch (e) {
        if (sid != null) {
          final f = e is SubscriptionFetchException ? e.failure : null;
          final abort = e is _SubAbort ? e : null;
          _subEvent('failed', {
            'source': sid,
            'name': name,
            'error': fetchErrorText(e), // a _SubAbort is an HttpException: its message
            'code': ?(abort?.code ?? f?.code),
            'path': ?(f == null || f.paths.isEmpty ? null : [for (final p in f.paths) '${p.id}:${p.code}'].join(' ')),
          }, own: true, op: op, verdict: abort?.why == null ? null : 'confirmed', why: abort?.why, cause: abort?.cause);
        }
        rethrow;
      }
    });
  }

  static const _subNetWait = Duration(seconds: 5);

  /// Our own start / restart of sing-box is under way (not settled, not down, not stopped).
  bool get _coreRestarting => const {CorePhase.starting, CorePhase.settling, CorePhase.recovering}.contains(sentinel.context.phase);

  /// The manual updates that wait now, for `status.subWaits`.
  final _subWaits = <Map<String, String>>[];

  /// Runs [wait] with the source on the status' `subWaits` ([forWhat]: `network` | `connection`); pushed at both ends.
  Future<T> _subWaiting<T>(String? sid, String name, String forWhat, Future<T> Function() wait) async {
    final w = {'source': sid ?? '', 'name': name, 'for': forWhat};
    _subWaits.add(w);
    _changed();
    try {
      return await wait();
    } finally {
      _subWaits.remove(w);
      _changed();
    }
  }

  /// Waits until the core has settled (or stopped: the load then goes without it). The core down meanwhile (or already)
  /// is a [_SubAbort] with the cause `core.down`.
  Future<void> _subSettle(String? sid, String name) async {
    final ctx = sentinel.context;
    bool over() => ctx.settled || ctx.phase == CorePhase.down || ctx.phase == CorePhase.stopped;
    if (!over()) await _subWaiting(sid, name, 'connection', () => ctx.waitFor(over));
    if (ctx.phase == CorePhase.down) {
      throw _SubAbort('The connection is down', 'core.down', why: const Why('core.down'), cause: sentinel.roots.byKind(rootCoreDown)?.eventId);
    }
  }

  /// A subscription was updated: its nodes are asked where they leave to, whatever the hourly timer says. The mark is
  /// set in the exit book here, running controller or not (the next check of the node, whenever it comes, takes it);
  /// a running controller also asks the node in use at once.
  void _exitSourceRefreshed(String sid, List nodes) {
    for (final n in nodes) {
      final o = n is Map ? n['outbound'] : null;
      if (o is Map && n['unsupported'] == null) exitBook.markRefresh(serverIdentity(o));
    }
    _auto?.exitSourceRefreshed(sid);
  }

  /// `sub/diverged`: in Auto the direct and the tunnel's copies of a subscription have different sets of servers;
  /// `used` (`tunnel` / `direct` / `merged`) and `why` say which copy was applied and on what ground. Counts, the servers
  /// that differ, statuses, times and freshness headers; the journal, no notification.
  void _subDiverged(Map<String, dynamic> data) {
    String fresh(Object? m) => m is Map && m.isNotEmpty ? m.entries.map((e) => '${e.key}: ${e.value}').join(', ') : 'no freshness headers';
    final used = data['used'] == 'merged' ? 'the two merged' : 'the ${data['used']} one';
    _event('sub', 'diverged', 'warn', data,
        note: 'Subscription ${data['name']} (${data['ua']}): the direct (${data['directNodes']} servers) and the tunnel (${data['tunnelNodes']}) '
            'copies have different servers, $used is used (${data['why']}); direct: ${fresh(data['directFresh'])}; tunnel: ${fresh(data['tunnelFresh'])}');
  }

  /// A subscription answered with a copy clearly older than the one applied before (a stale CDN edge): left out, the
  /// list stays, the update counts as done. A Raw line (warn) every time, with both moments and the UA; no event.
  void _subStale(Map<String, dynamic> data) {
    String moments(Object? m) => m is Map && m.isNotEmpty ? m.entries.map((e) => '${e.key} ${e.value}').join(', ') : 'unknown';
    logBook.note(
        'warn',
        'sub: ${data['name']} (${data['ua']}): the received copy (${data['nodes']} servers; ${moments(data['received'])}) is older than the applied one '
        '(${moments(data['applied'])}), ${data['why']}: not applied, the list stays; the next update asks again');
  }

  /// `sub/failed` of the timer's update when no path brought the subscription: the Sentinel judges it and the event
  /// is written only for a `confirmed` verdict (as for the rule sets). A failure of our own restart never gets here.
  void _subFailed(SvcFailure f, Map<String, dynamic> data) {
    final op = updater.op; // taken now: the verdict comes later
    final s = f.suspicion(why: Why('svc.fetch', {'purpose': 'subscription', 'source': data['source']}));
    if (s == null) {
      _subEvent('failed', data, op: op);
      return;
    }
    s.evidence.addAll({'source': data['source'], 'name': data['name']});
    // every confirmed failure is told: the same error of the source is a repeat on the earlier event (×N), a standing root included
    unawaited(sentinel.suspect(s).then((v) {
      if (v.kind != VerdictKind.confirmed) return;
      _subEvent('failed', data, op: op, verdict: 'confirmed', why: v.why, trail: v.trail, cause: v.cause);
    }));
  }

  @override
  Map<String, dynamic> parse(Map<String, dynamic> body) =>
      {'nodes': [for (final n in parseLinks('${body['text'] ?? ''}')) n.toJson()]};

  @override
  Map<String, dynamic> addSourceFromText(Map<String, dynamic> body) =>
      {'source': localSourceFromText('${body['name'] ?? ''}', '${body['text'] ?? ''}')};

  // ── addresses of the servers (address_resolver.dart, docs/rules.md §6) ──

  /// The last known addresses of the hostnames the config needs (`<dataDir>/addresses.json`).
  late final addressBook = AddressBook(File(p.join(dataDir, 'addresses.json')), now: _now);

  /// Resolves the hostnames of the servers through the direct side's DNS servers; an id the DNS failover
  /// switched off is not asked.
  late final AddressResolver addresses = addressResolverFor?.call(addressBook) ??
      AddressResolver(
        book: addressBook,
        fetch: () => svcFetch,
        settings: _addressSettings,
        verdicts: dnsBook, // stored verdicts: dead enabled servers are skipped; attempts through disabled ones are checks
        onNoAnswer: (c) => _dns?.lookupMissed(c.id), // evidence for the server's own check, never a verdict
        onNameMissing: nameMissing,
        onResolved: nameResolved,
        log: logBook.note,
        now: _now,
      );

  // ── a node's server name that does not exist (name_watch.dart, docs/failures.md → «Имя сервера узла не существует») ──

  /// How long after the first report the name is asked again; the verdict comes only from that second answer.
  Duration get nameRecheckAfter => _names.after;
  set nameRecheckAfter(Duration d) => _names.after = d;

  late final _names = NameMissingWatch(
    timer: _timer,
    recheck: (h) => addresses.lookup(h, why: 'name recheck'),
    confirm: _nameConfirm,
    repeat: (h) async {
      await _nameSuspect(h);
    },
    cleared: _nameCleared,
    log: logBook.note,
  );

  /// host (lower case) → the nodes of the catalog on that server name, for the ladder and the event.
  final _nameNodes = <String, List<({String name, String source, String id})>>{};

  static String _nameKey(String host) => 'node.addressMissing|${AddressBook.key(host)}';

  /// The resolver's word that every DNS server that answered says [host] does not exist: one observation, the
  /// verdict is made by [NameMissingWatch] after a re-check. Public for the tests (a fake resolver calls it).
  void nameMissing(String host) {
    logBook.note('warn', 'address: node server name $host does not exist (every DNS server that answered says so): a problem with the node\'s address (provider / subscription), not with DNS');
    _names.missing(host);
  }

  /// A lookup got an address for [host]: the name is not missing (closes a standing verdict). Public for the tests.
  void nameResolved(String host) => _names.resolved(host);

  /// The ladder took a node off (it answered): a missing-name verdict about it is void.
  void _nameBack(String id) {
    for (final e in _nameNodes.entries.toList()) {
      if (e.value.any((n) => n.id == id)) _names.resolved(e.key, reason: 'node answered');
    }
  }

  /// At the start, before a service holds the objects: what Auto's memory (auto_memory.dart) kept of a node that is no
  /// longer in any source of the catalog goes. A catalog that cannot be read or has no nodes at all leaves it as it is
  /// (the entries unseen for a month go anyway).
  Future<void> _retainAutoMemory() async {
    try {
      final c = Catalog.fromJson(await store.read());
      final known = <String>{
        for (final s in c.sourcesData.values)
          for (final n in s.nodes)
            if (n.outbound != null) serverIdentity(n.outbound!),
      };
      if (known.isEmpty) return;
      final n = autoMemory.retainNodes(known);
      if (n > 0) logBook.note('info', 'auto: $n remembered servers of nodes that are gone from the catalog were dropped');
    } catch (e) {
      logBook.note('warn', 'auto: the catalog could not be read to tidy the remembered servers ($e)');
    }
  }

  Set<String> _nodesInUse() => _auto?.nodesInUse() ?? {?dnsPlanNode(_plan)};

  Future<List<({String name, String source, String id})>> _hostNodes(String host) async {
    final k = AddressBook.key(host);
    final out = <({String name, String source, String id})>[];
    try {
      final c = Catalog.fromJson(await store.read());
      for (final sid in c.sourceOrder) {
        final s = c.sourcesData[sid];
        if (s == null) continue;
        for (final n in c.liveNodes(s)) {
          final o = n.outbound;
          if (o == null || n.unsupported != null || n.goneAt != null || hostnameOf(o['server']) != k) continue;
          out.add((name: n.name, source: s.name, id: serverIdentity(o)));
        }
      }
    } catch (e) {
      logBook.note('warn', 'address: the nodes of $host could not be read from the catalog ($e)');
    }
    return out;
  }

  /// The re-check said it again: the nodes of that name are dead — on the ladder of unavailable nodes (the same as any
  /// dead node; it is asked again there and takes itself off when it answers), and the Sentinel writes the event.
  Future<bool> _nameConfirm(String host) async {
    final nodes = await _hostNodes(host);
    if (nodes.isEmpty) {
      logBook.note('info', 'address: $host is the server name of no node of the catalog (a DNS server, or a node that is off / gone): no event');
      return false;
    }
    _nameNodes[AddressBook.key(host)] = nodes;
    final now = _nowMs;
    for (final n in nodes) {
      pool.ladder.enter(n.id, now);
    }
    return _nameSuspect(host);
  }

  /// `node/addressMissing`: a standing verdict about the name; the same one again is a repeat on the root's event
  /// (counted, in the raw log), never a new event. `inUse` (a node of the main flow) is what lets the app notify.
  Future<bool> _nameSuspect(String host) async {
    final k = AddressBook.key(host), nodes = _nameNodes[k];
    if (nodes == null) return false;
    final use = _nodesInUse();
    final shown = nodes.where((n) => use.contains(n.id)).firstOrNull ?? nodes.first;
    final v = await sentinel.suspect(Suspicion(
      kind: 'node.addressMissing',
      key: _nameKey(host),
      subject: {'host': k},
      evidence: {'host': k, 'node': shown.name, 'source': shown.source, 'nodes': nodes.length, 'inUse': nodes.any((n) => use.contains(n.id))},
      viaCore: false,
      session: false,
      why: Why('node.addressMissing', {'host': k}),
      scope: Scope.none,
      level: Level.route,
      event: SuspicionEvent('node', 'addressMissing', level: 'warn', note: (kind, e) {
        final more = (e['nodes'] as int) > 1 ? ' and ${(e['nodes'] as int) - 1} more' : '';
        return switch (kind) {
          VerdictKind.confirmed => 'Server address ${e['host']} of ${e['node']}$more does not exist: the provider\'s subscription has an error',
          _ => null,
        };
      }),
    ));
    final stands = v.kind == VerdictKind.confirmed;
    if (!stands) _nameNodes.remove(k);
    return stands;
  }

  void _nameCleared(String host, String reason) {
    _nameNodes.remove(AddressBook.key(host));
    sentinel.recovered(_nameKey(host));
    logBook.note('info', 'address: node server name $host is no longer missing ($reason)');
  }

  /// The tests' seam: the resolver the service uses instead of the real one (given the service's book).
  final AddressResolver Function(AddressBook book)? addressResolverFor;

  /// The addresses a throwaway test sing-box (ping, speed test) dials: the cache only, never waited for — what
  /// is missing resolves in the background for the next test (a test must not wait for a lookup).
  /// The pins also hold the address of the tester's resolver server ([_testerResolver]) when it is named by a host
  /// and the cache has it.
  /// [settings]: the DNS settings of a plan being started, read once by the caller (default: read now).
  Future<Pins> _testerPins(Iterable<Map> nodes, Iterable<Map> pairs, String why, {AddressSettings? settings}) async {
    if (!resolveAddresses) return const {};
    try {
      final hosts = nodesHostnames([...nodes, for (final p in pairs) p['entry']]);
      if (hosts.isEmpty) return const {};
      unawaited(addresses.ensure(hosts, why: why, wait: const Duration(seconds: 30)));
      final st = settings ?? await _addressSettings();
      final pins = pinsFor(hosts, addressBook, ipv6: st.ipv6);
      _notePins(why, hosts, pins);
      final resolver = await _testerResolver(st);
      final rj = resolver == null ? null : dnsServerJson(resolver.tag, resolver.addr);
      final rh = rj == null ? null : hostnameOf(rj['server']);
      return rh == null ? pins : {...pins, ...pinsFor([rh], addressBook, ipv6: st.ipv6)};
    } catch (e) {
      logBook.note('warn', 'address: the addresses for $why could not be prepared ($e): the test keeps the names');
      return const {};
    }
  }

  /// What a config (or a test) holds for the hostnames it pins: per host the address, who answered the lookup
  /// (`cloudflare-doh1`, `system`, …) and how old the answer is — the first [max] hosts, then a count. A server
  /// whose address came from another resolver than the network's own is the first suspect when a node answers
  /// for other clients and not here. Host names stay readable in a report (redact.dart keeps domains).
  /// [summary]: also the line "k of n hostnames pinned" (the connect's own line says it already).
  void _notePins(String why, Iterable<String> hosts, Pins pins, {bool summary = true, int max = 12}) {
    if (pins.isEmpty) return;
    final unresolved = [for (final h in hosts) if (!pins.containsKey(h)) h];
    if (summary) {
      logBook.note(unresolved.isEmpty ? 'info' : 'warn',
          'address: $why: ${pins.length} of ${pins.length + unresolved.length} hostnames pinned to an address'
          '${unresolved.isEmpty ? '' : ', kept as names (sing-box resolves them): ${unresolved.take(max).join(', ')}${unresolved.length > max ? ' and ${unresolved.length - max} more' : ''}'}');
    }
    final now = _now().millisecondsSinceEpoch;
    final parts = <String>[];
    for (final e in pins.entries.take(max)) {
      final entry = addressBook.get(e.key);
      parts.add(entry == null ? '${e.key} → ${e.value}' : '${e.key} → ${e.value} (via ${entry.via}, ${((now - entry.at) / 1000).round()} s old)');
    }
    logBook.note('info', 'address: $why: ${parts.join('; ')}${pins.length > max ? '; and ${pins.length - max} more' : ''}');
  }

  /// Whether the main config may resolve unpinned node names with [c]: a built-in server whose stored verdict is not dead.
  bool _nodeResolverUsable(DnsCandidate c) => dnsBuiltinIds.contains(c.provider) && dnsBook.deadOf(dnsVerdictKey(c, null)) != true;

  /// The server a throwaway tester resolves the names of nodes not pinned in time with: the same top server of the
  /// system chain as the main config's ([nodeResolverCandidate], the saved or connected plan's DNS settings); null =
  /// the OS resolver.
  Future<DnsCandidate?> _testerResolver([AddressSettings? settings]) async {
    try {
      return nodeResolverCandidate((settings ?? await _addressSettings()).candidates, _nodeResolverUsable);
    } catch (e) {
      logBook.note('warn', 'address: the resolver for the test could not be chosen ($e): the OS resolver is used');
      return null;
    }
  }

  AddressSettings? _addrSettings;
  int _addrSettingsAt = 0;

  /// What a lookup reads: the connected plan's DNS block and IPv6 setting; nothing connected — the saved
  /// snapshot's. A connected plan without a DNS block (tests) has no servers: only the OS resolver answers.
  /// Kept for 10 s (the snapshot is parsed into a catalog).
  Future<AddressSettings> _addressSettings() async {
    final cached = _addrSettings;
    if (cached != null && _now().millisecondsSinceEpoch - _addrSettingsAt < 10000) return cached;
    final plan = _starting ?? _plan;
    Map? dns;
    var ipv6 = false;
    if (plan != null) {
      dns = (plan['routing'] as Map?)?['dns'] as Map?;
      ipv6 = planIpv6(plan);
    } else {
      try {
        final c = Catalog.fromJson(await store.read());
        dns = c.dnsPlan();
        ipv6 = c.connCfg.ipv6;
      } catch (e) {
        logBook.note('warn', 'address: the saved DNS settings could not be read ($e): only the OS resolver is used');
      }
    }
    final st = AddressSettings(
        candidates: dns == null ? const [] : (dnsSidesOf(dns)['direct'] ?? const []),
        disabled: dns == null ? const [] : dnsDisabledOf(dns, dnsBuiltinIds),
        ipv6: ipv6);
    _addrSettings = st;
    _addrSettingsAt = _now().millisecondsSinceEpoch;
    return st;
  }

  /// A server list arrived (a subscription update, timer or UI): its hostnames are resolved in the background,
  /// the fresh ones again too (an address may have moved).
  void _warmNodes(List nodes, String why) {
    final hosts = nodesHostnames(nodes);
    if (hosts.isEmpty) return;
    unawaited(addresses.ensure(hosts, why: why, wait: const Duration(seconds: 30), refreshAll: true));
  }

  /// Off: no hostname is resolved in advance, the configs keep the names (sing-box resolves them itself). The
  /// tests' seam, so that a service test never reaches a real DoH server.
  final bool resolveAddresses;

  /// The plan [_startSingBox] is building a config for (`_plan` is null while connecting): what a lookup reads.
  Map<String, dynamic>? _starting;

  /// hostname → the address the running config holds for it (`pins` of config.dart); kept in the adoption record.
  Pins _pinned = const {};

  /// The addresses of a host a restart already tried since the user's connect, so every cached address is tried
  /// once before the name is looked up again.
  final _triedAddrs = <String, Set<String>>{};
  final _reresolveAt = <String, int>{};
  final _reresolving = <String>{};
  Timer? _addrRestart;

  /// How often a node's address is looked at again after it stopped answering (per host).
  Duration reresolveEvery = const Duration(minutes: 5);
  static const _addrRestartDelay = Duration(seconds: 2);

  /// How long a connect waits for the addresses of the servers it needs to start (missing from the cache).
  Duration connectWait = const Duration(milliseconds: 1500);

  /// The addresses for [plan]'s hostnames: the cache first; when [wait], the hosts of the servers the selected
  /// route starts with ([startHostnames]) that are missing are resolved and waited for, at most [connectWait] in
  /// all (every DNS server of the direct side asked at once, the best answer in time wins). Everything else
  /// missing resolves in the background (the next config has it; never a restart just for that). Without [wait]
  /// only the cache is used (a restart after a crash must not wait for the network).
  /// What stays unresolved keeps its name in the config (sing-box resolves it by `domain_resolver`: the old way).
  Future<Pins> _pinsFor(Map<String, dynamic> plan, {required String why, required bool wait}) async {
    _starting = plan;
    _addrSettings = null; // the lookups read the plan being started
    try {
      if (!resolveAddresses) return const {};
      final hosts = planHostnames(plan);
      if (hosts.isEmpty) return const {};
      final first = dnsHostnames((plan['routing'] as Map?)?['dns']);
      if (wait) {
        final need = startHostnames(plan);
        final missing = [for (final h in {...need, ...first}) if (addressBook.get(h) == null) h];
        final sw = Stopwatch()..start();
        await addresses.ensure(hosts, why: why, first: first, need: need, wait: connectWait, race: true);
        if (missing.isNotEmpty) {
          final left = [for (final h in missing) if (addressBook.get(h) == null) h];
          logBook.note(left.isEmpty ? 'info' : 'warn',
              'address: connect waited ${sw.elapsedMilliseconds}ms (up to ${connectWait.inMilliseconds}ms) for ${missing.length} host${missing.length == 1 ? '' : 's'} '
              'of the servers it starts with: ${missing.length - left.length} resolved'
              '${left.isEmpty ? '' : ', not in time (kept as names, resolved in the background for the next start): ${left.join(', ')}'}');
        }
      } else {
        unawaited(addresses.ensure(hosts, why: why, first: first));
      }
      final pins = pinsFor(hosts, addressBook, ipv6: planIpv6(plan));
      final unresolved = [for (final h in hosts) if (!pins.containsKey(h)) h];
      logBook.note(unresolved.isEmpty ? 'info' : 'warn',
          'address: config for $why: ${pins.length} of ${hosts.length} hostnames pinned to an address'
          '${unresolved.isEmpty ? '' : ', kept as names (sing-box resolves them): ${unresolved.join(', ')}'}');
      _notePins('config for $why', hosts, pins, summary: false);
      return pins;
    } catch (e) {
      logBook.note('warn', 'address: the addresses could not be prepared ($e): the config keeps the names');
      return const {};
    } finally {
      _starting = null;
      _addrSettings = null;
    }
  }

  bool get _addrReady => runner.running && _recovering == null && sentinel.context.settled && sentinel.context.network.state == NetState.up;

  /// Auto's word that a server missed `failAfter` tests in a row: when its name is pinned in the config, another
  /// cached address is tried, then the name is looked up again; a different address needs a restart of sing-box
  /// (the config holds the IP). Per host at most once per [reresolveEvery]; never while the network is not up,
  /// the core is not settled or sing-box is being restarted.
  ///
  /// Public for the tests: Auto and the fallback service need a sing-box API a fake runner has not.
  void serverDown(String groupTag, String key) {
    final plan = _plan;
    if (plan == null || !resolveAddresses) return;
    final host = memberHostname(plan, groupTag, key);
    if (host == null || !_pinned.containsKey(host) || _reresolving.contains(host)) return;
    final last = _reresolveAt[host];
    if (last != null && _now().millisecondsSinceEpoch - last < reresolveEvery.inMilliseconds) return;
    if (!_addrReady) {
      logBook.note('info', 'address: $host ($groupTag/$key is down): not looked at now (network not up, core not settled or restarting)');
      return;
    }
    _reresolveAt[host] = _now().millisecondsSinceEpoch;
    _reresolving.add(host);
    unawaited(_reresolve(host, '$groupTag/$key', _connectSeq).whenComplete(() => _reresolving.remove(host)));
  }

  Future<void> _reresolve(String host, String member, int seq) async {
    try {
      final ipv6 = _plan != null && planIpv6(_plan!);
      final pinned = _pinned[host];
      final entry = addressBook.get(host);
      if (pinned == null || entry == null) return;
      final tried = _triedAddrs.putIfAbsent(host, () => {})..add(pinned);
      final ips = entry.ips(ipv6);
      final next = ips.indexWhere((a) => !tried.contains(a));
      if (next >= 0) {
        addressBook.setCursor(host, next);
        logBook.note('info', 'address: $host ($member is down) on $pinned: another cached address ${ips[next]} is tried (${tried.length} of ${ips.length} tried)');
        _restartForAddresses(seq, '$host → ${ips[next]}');
        return;
      }
      logBook.note('info', 'address: $host ($member is down) on $pinned: every cached address was tried, looked up again');
      final before = entry;
      final after = await addresses.lookup(host, why: 'node down');
      if (seq != _connectSeq) return;
      if (after == null) {
        logBook.note('info', 'address: $host: the lookup gave nothing, the config stays on $pinned');
      } else if (before.sameSet(after)) {
        logBook.note('info', 'address: $host: the same addresses ${after.ips(ipv6).join(', ')} (IP set unchanged): no restart');
      } else {
        addressBook.setCursor(host, 0);
        _triedAddrs.remove(host);
        logBook.note('info', 'address: $host: the addresses changed (${before.ips(ipv6).join(', ')} → ${after.ips(ipv6).join(', ')}): restart');
        _restartForAddresses(seq, '$host changed');
      }
    } catch (e) {
      logBook.note('warn', 'address: $host: looking again failed: $e');
    }
  }

  /// One restart for all the hosts that asked within a moment; the gates are checked again when it runs.
  void _restartForAddresses(int seq, String what) {
    _addrRestart?.cancel();
    _addrRestart = _timer(_addrRestartDelay, () {
      _addrRestart = null;
      final plan = _plan;
      if (seq != _connectSeq || plan == null) return;
      if (!_addrReady) {
        logBook.note('info', 'address: restart for $what skipped (network not up, core not settled or restarting); the next config uses the new address');
        return;
      }
      logBook.note('info', 'address: restarting sing-box for $what');
      unawaited(_connect({'plan': _continuationPlan(plan), 'systemProxy': _sysWanted}, own: false, reason: 'reresolve').then((_) {}, onError: (_) {}));
    });
  }

  /// The one way sing-box is started, by a connect and by a restart after a crash: the
  /// rule lists on disk first (ones via VPN that are missing wait for the tunnel — the
  /// old one, if it still runs), a fresh tunnel-in port, the config. The lists used and
  /// the config's warnings. [sys]: the system proxy is asked for; with a password on the
  /// user port it needs its own open inbound (`sys-in`, [_sysInPort]).
  Future<(RuleSetFetch, List<String>)> _startSingBox(Map<String, dynamic> plan, {required bool sys, String why = 'connect', bool waitAddresses = true}) async {
    // TUN needs administrator rights: said before anything starts (a connect and a restart alike)
    if (planTun(plan) && !_isElevated()) throw TunNeedsAdmin();
    final lists = await _inRuleSetsOp(() => ruleSets.ensureFor(plan, tunnel: runner.running));
    final pins = await _pinsFor(plan, why: why, wait: waitAddresses);
    final warnings = <String>[];
    final mixed = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    final tunnelPort = await freePort(exclude: {mixed});
    final probePort = await freePort(exclude: {mixed, tunnelPort});
    final svcPort = await freePort(exclude: {mixed, tunnelPort, probePort});
    final sysPort = sys && plan['mixedAuth'] != null ? await _sysInPort({mixed, tunnelPort, probePort, svcPort}) : null;
    if (Platform.isAndroid && _selfPackages.isEmpty) {
      logBook.note('warn', "The app's own package is unknown: its own connections are routed like any app's, not direct");
    }
    final probe = Probe(probePort);
    final svc = SvcIn(svcPort);
    final info = RoutingInfo();
    TunCheck? tunCheck;
    if (planTun(plan)) {
      try {
        tunCheck = await TunCheck.bind(connect: tunCheckConnect);
      } catch (e) {
        logBook.note('warn', 'TUN test: the responder did not start ($e); a dead TUN is judged by the log alone');
      }
    }
    try {
      final config = buildConfig(plan,
          tunnelPort: tunnelPort,
          tunCheckPort: tunCheck?.port,
          sysPort: sysPort,
          probe: probe,
          svc: svc,
          ruleSetFiles: lists.files,
          dnsFlagDir: _dnsFlagDir,
          warnings: warnings,
          info: info,
          pins: pins,
          nodeResolverUsable: _nodeResolverUsable,
          selfPaths: _selfPaths,
          selfPackages: _selfPackages);
      // every DNS server's flag file must exist before sing-box reads the config; all on at a connect, the last
      // state again at a restart of ours (the files of the run before hold nothing we rely on)
      // the stored verdicts (dns_verdicts.dart): the dead ones start off, the best that worked answers
      final memory = _dnsFlagMemory;
      final stored = dnsStartFlags(info.dnsSides, dnsBook, node: dnsPlanNode(plan), others: info.dnsCandidates, reserve: _dnsReserveMemory);
      writeDnsFlags(info.dnsCandidates,
          on: (c) => memory[c.id] ?? stored[c.id] ?? true, reason: memory.isEmpty ? 'connect' : 'restart re-apply', log: logBook.note);
      // the files of the "If unavailable → Direct" flags must exist too; off until the fallback service has seen the selectors
      for (final f in info.fallbacks) {
        if (f.flagPath != null) setFallbackFlag(f, false, reason: 'start', log: logBook.note, level: 'debug');
      }
      await runner.start(config);
    } on SingBoxError catch (e) {
      unawaited(tunCheck?.close());
      // the proxy port is taken (before the TUN check: a refused low port says "permission denied" too)
      if (e.fix == null && userPortRefused(e.message, mixed)) throw SingBoxError(e.message, fix: 'settings');
      // sing-box refused the TUN for a missing permission: the same advice as not being elevated
      if (planTun(plan) && tunAccessDenied(e.message)) throw TunNeedsAdmin(e.message);
      rethrow;
    }
    _sysPort = sysPort;
    _pinned = pins;
    unawaited(_tunCheck?.close());
    _tunCheck = tunCheck;
    // what a later sing-box will no longer take in this config
    try {
      for (final w in await runner.api!.deprecatedWarnings()) {
        logBook.note('warn', 'sing-box: $w');
        // the same text again in this run is a repeat on its event (×N), not silence; one connect's texts are one operation
        final seen = _deprecatedIds[w];
        if (seen != null && eventBook.byId(seen) != null) {
          eventBook.repeated(seen, data: {'text': w}, level: 'warn');
        } else {
          _deprecatedIds[w] = eventBook.add('core', 'deprecated', 'warn', data: {'text': w}, op: _connectOp);
        }
      }
    } catch (_) {}
    _probe = probe;
    _svc = svc;
    _fallbacks = info.fallbacks;
    _noteLostTargets(info);
    _ruleNames = info.ruleNames;
    _takeDns(info);
    _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    _tunnelPort = tunnelPort;
    // what a core made later needs to take this sing-box over (see [adopt])
    final r = runner;
    if (r is AdoptableRunner) {
      try {
        await r.keep({
          'plan': plan,
          'tunnelPort': tunnelPort,
          'tunCheckPort': tunCheck?.port,
          'probePort': probePort,
          'probeSecret': probe.secret,
          'svc': svc.toJson(),
          'sysPort': sysPort,
          'sysWanted': sys,
          'pins': pins,
          'ruleSetFiles': lists.files,
          'upSince': _now().millisecondsSinceEpoch,
          'selectorGroups': true, // every group is a selector (a record without it is of a core with urltest groups: not adopted)
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
      if (rec['selectorGroups'] != true) {
        // a sing-box of a core whose Fastest groups were urltest: Auto here could not move them; the app connects anew
        logBook.note('warn', 'A running tunnel of an older core (urltest groups) is not taken over: stopped');
        await r.stop();
        return {'adopted': false, 'stopped': true};
      }
      final Map<String, dynamic> plan;
      final Probe probe;
      final SvcIn? svc;
      final RoutingInfo info = RoutingInfo();
      final int tunnelPort;
      final int? sysPort;
      final int? tunCheckPort;
      final Pins pins;
      try {
        plan = (rec['plan'] as Map).cast<String, dynamic>();
        tunnelPort = (rec['tunnelPort'] as num).toInt();
        tunCheckPort = (rec['tunCheckPort'] as num?)?.toInt();
        sysPort = (rec['sysPort'] as num?)?.toInt();
        probe = Probe((rec['probePort'] as num).toInt(), rec['probeSecret'] as String);
        pins = {for (final e in ((rec['pins'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        svc = SvcIn.fromJson(rec['svc']); // null: a record of a core before svc-in; the old sing-box has no such inbound
        // the config again with the same inputs, for what it says about itself (rules by name,
        // fallbacks, DNS servers); the config itself is not used
        buildConfig(plan,
            tunnelPort: tunnelPort,
            tunCheckPort: tunCheckPort,
            sysPort: sysPort,
            probe: probe,
            svc: svc == null ? null : SvcIn(svc.port, svc.secret),
            ruleSetFiles: ((rec['ruleSetFiles'] as Map?) ?? const {}).cast<String, String>(),
            dnsFlagDir: _dnsFlagDir,
            warnings: <String>[],
            info: info,
            pins: pins,
            selfPaths: _selfPaths,
            selfPackages: _selfPackages);
      } catch (e) {
        logBook.note('warn', 'A running tunnel could not be taken over (its record: $e): stopped');
        await r.stop();
        return {'adopted': false, 'stopped': true};
      }
      // the responder of the active TUN test again, on the port the running config names (none: the test is absent)
      TunCheck? tunCheck;
      if (tunCheckPort != null) {
        try {
          tunCheck = await TunCheck.bind(port: tunCheckPort, connect: tunCheckConnect);
        } catch (e) {
          logBook.note('warn', 'TUN test: the responder could not be restarted on $tunCheckPort ($e); a dead TUN is judged by the log alone');
        }
      }
      unawaited(_tunCheck?.close());
      _tunCheck = tunCheck;
      _connectSeq++;
      _applyKill(body);
      if (body['dnsAuto'] is bool) _dnsAuto = body['dnsAuto'] as bool;
      final auto = body['auto'];
      _plan = auto is Map ? {...plan, 'auto': auto} : plan;
      _sysWanted = rec['sysWanted'] == true;
      _pinned = pins;
      _upSince = DateTime.fromMillisecondsSinceEpoch((rec['upSince'] as num?)?.toInt() ?? _now().millisecondsSinceEpoch);
      _attempt = 0;
      _probe = probe;
      _svc = svc;
      _fallbacks = info.fallbacks;
      _noteLostTargets(info, silent: true); // the core before this one told them
      _ruleNames = info.ruleNames;
      _takeDns(info);
      // the files of the core before this one are not relied on: every flag on, the failover starts from there
      _dnsFlagMemory = const {};
      _dnsReserveMemory = const {};
      try {
        writeDnsFlags(info.dnsCandidates, reason: 'adopt', log: logBook.note);
      } catch (e) {
        logBook.note('warn', 'dns: the flags were not written on taking over ($e)');
      }
      _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
      _tunnelPort = tunnelPort;
      _sysPort = sysPort;
      _error = null;
      sentinel.context.starting('adopt');
      sentinel.context.started(since: _upSince);
      _startAuto(_plan!, adopted: true);
      _refreshLists(_connectSeq, plan, RuleSetFetch(((rec['ruleSetFiles'] as Map?) ?? const {}).cast<String, String>(), [], []));
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

  /// `rules/ruleSetFailed`. No path answered: the Sentinel judges it, and the event is written only for a
  /// `confirmed` verdict (the rest stays in the log; a repeat of a standing root says nothing again). A
  /// server's answer that is no rule set is the list's own failure: told at once. `hasCopy`: the list on
  /// disk, from an earlier download, is the one in use. A failure of an own restart never gets here.
  void _ruleSetFailed(RuleSetFailure f) {
    final data = {'tag': f.tag, 'url': f.url, 'error': f.error, 'hasCopy': f.hasCopy, if (f.hasCopy) 'copyAt': f.copyAt};
    final note = 'Rule set ${f.tag} not downloaded (${f.url}): ${f.error}';
    final op = _listsOp; // taken now: the verdict comes later, when the round may be over
    final s = f.svc?.suspicion(why: Why('svc.fetch', {'purpose': 'ruleset', 'tag': f.tag}));
    if (s == null) {
      _event('rules', 'ruleSetFailed', 'warn', data, note: note, op: op);
      return;
    }
    s.evidence.addAll({'tag': f.tag, 'url': f.url, 'hasCopy': f.hasCopy});
    unawaited(sentinel.suspect(s).then((v) {
      if (v.kind != VerdictKind.confirmed || v.repeat) return;
      _event('rules', 'ruleSetFailed', 'warn', data, note: note, verdict: 'confirmed', why: v.why, trail: v.trail, cause: v.cause, op: op);
    }));
  }

  /// Runs [f] (a round of the lists) as one `ruleSets` operation unless one is under way (or a reconnect, whose op it is).
  Future<T> _inRuleSetsOp<T>(Future<T> Function() f) async {
    final mine = _ruleSetsOp == null;
    if (mine) _ruleSetsOp = _newOp('ruleSets');
    try {
      return await f();
    } finally {
      if (mine) _ruleSetsOp = null;
    }
  }

  Timer? _listsTimer;
  Set<String> _listTags = {}; // the lists the running sing-box's config has
  static const _listsEvery = Duration(minutes: 1); // how often the lists are looked at (each has its own `every`)
  static const _listsWait = Duration(seconds: 10); // the core is not quiet yet

  /// The lists while connected. Missing ones (a list via VPN had no tunnel at the start) are fetched through
  /// the tunnel now, and a restart picks them up, on the route Auto is on. Stale ones are replaced in place on
  /// a timer ([_listsTick]): sing-box reloads a local rule set by itself, so no restart. [lists]: what the
  /// running config has.
  void _refreshLists(int seq, Map<String, dynamic> plan, RuleSetFetch lists) {
    _listTags = lists.files.keys.toSet();
    _listsTimer?.cancel();
    _listsTimer = null;
    if (ruleSetsNeeded(plan).isEmpty) return;
    if (lists.pending.isEmpty) {
      _listsTimer = _timer(_listsEvery, () => _listsTick(seq, plan));
    } else {
      unawaited(_listsRound(seq, plan, refresh: false));
    }
  }

  /// Only when the Sentinel's context is settled (a refresh ~200 ms after Connected would meet our own
  /// start), and never while sing-box is being restarted.
  void _listsTick(int seq, Map<String, dynamic> plan) {
    _listsTimer = null;
    if (seq != _connectSeq || !runner.running) return;
    if (!sentinel.context.settled || _recovering != null) {
      _listsTimer = _timer(_listsWait, () => _listsTick(seq, plan));
      return;
    }
    unawaited(_listsRound(seq, plan, refresh: true));
  }

  Future<void> _listsRound(int seq, Map<String, dynamic> plan, {required bool refresh}) async {
    if (seq != _connectSeq || !runner.running) return;
    try {
      final now = await _inRuleSetsOp(() => ruleSets.ensureFor(plan, tunnel: true, refresh: refresh));
      if (seq != _connectSeq || !runner.running) return;
      if (now.files.keys.any((t) => !_listTags.contains(t))) {
        // only a list that is new to the config needs a restart (its _connect starts the timer again)
        unawaited(_connect({'plan': _continuationPlan(plan), 'systemProxy': _sysWanted}, own: false).then((_) {}, onError: (_) {}));
        return;
      }
    } catch (_) {}
    if (seq == _connectSeq) _listsTimer = _timer(_listsEvery, () => _listsTick(seq, plan));
  }

  @override
  Future<Map<String, dynamic>> connect(Map<String, dynamic> body) => _connect(body);

  /// body: {plan (see config.dart), systemProxy: bool}. [own]: the user asked (the journal
  /// marks it so no notification comes of it); the reconnect that picks up lists is not.
  Future<Map<String, dynamic>> _connect(Map<String, dynamic> body, {bool own = true, String? reason}) async {
    var plan = (body['plan'] as Map).cast<String, dynamic>();
    if (own) _triedAddrs.clear(); // the addresses a node was tried on belong to the run the user started
    // a connect over a running one (a plan change, an own restart): the servers its groups are on stay, only groups with
    // none are checked; a fresh connect checks the group it starts on (the app's `chosen` is a hint, kept only for Manual's pin)
    final continuation = runner.running && _plan != null;
    final oldPlan = _plan;
    final startedAt = _nowMs;
    // a connect within 7 s of the user's own disconnect is the second half of one operation (`conn/reconnected`, `user`)
    // (kept until a connect writes its event: a superseded connect — a double tap — leaves the window to the next one)
    final ud = _userDisconnect;
    final userOp = own && !continuation && ud != null && startedAt - ud.at <= _userReconnectWithin.inMilliseconds ? ud : null;
    // the core's own reconnect of the live connection (a plan change, the lists, the addresses) is `conn/reconnected`
    final reconnect = continuation ? (reason == 'reresolve' ? 'reresolve' : (own ? 'settings' : 'lists')) : null;
    final reconnectOp = reconnect == null ? null : _newOp('reconnect');
    final held = continuation ? _coreServers() : null; // before _stopAuto: the core knows where the groups are
    if (continuation) plan = _keepCoreChoice(plan);
    final seq = _nextSeq();
    _wakeUp();
    _recovering = null;
    _downSince = null;
    _released = false;
    final wasBlocking = _blocking;
    _blocking = null; // a connect ends the blocking
    _applyKill(body);
    if (body['dnsAuto'] is bool) _dnsAuto = body['dnsAuto'] as bool;
    _stopAuto();
    if (own) {
      _dnsFlagMemory = const {}; // a connect the user asked for: every DNS flag starts on; a restart of ours keeps them
      _dnsReserveMemory = const {};
    }
    _closeCrashRoot('reconnected');
    _error = null;
    _warning = null;
    _changed();
    await _locked(() async {
      if (seq != _connectSeq) return; // a newer connect / disconnect came in
      _connectOp = reconnectOp; // the events written while the live connection is started again belong to its operation
      try {
        _plan = null;
        final sys = body['systemProxy'] == true;
        sentinel.context.starting(reason ?? (own ? 'userConnect' : 'refreshLists'));
        // (the cancel stays until the next connect / disconnect: the rule targets' checks that outlast the connect end with it)
        final cancel = _pickCancel = Cancel();
        final picks = await connectPicks(plan, cancel: cancel, held: held);
        if (picks == null || seq != _connectSeq) return; // a disconnect / newer connect came in while the servers were checked
        plan = planWithChosen(plan, picks);
        final (lists, warnings) = await _startSingBox(plan, sys: sys, why: reason ?? 'connect');
        sentinel.context.started();
        _plan = plan;
        _sysWanted = sys;
        _upSince = _now();
        _attempt = 0;
        _startAuto(plan);
        _releaseLate(seq); // the rule targets' groups whose check outlasted the connect
        if (_sysWanted) {
          warnings.add(await _sysOn(own: own) ?? '');
        } else {
          await _sysOff(own: own);
        }
        _warning = joinWarnings(warnings);
        logBook.note('info', 'Connected: ${plan['kind']}, ${planTun(plan) ? 'TUN (${planTunStack(plan)}), ' : ''}proxy on 127.0.0.1:$_mixedPort${_sysWanted ? ', system proxy on' : ''}');
        if (_warning != null) logBook.note('warn', _warning!);
        _refreshLists(seq, plan, lists);
        final tookMs = _nowMs - startedAt;
        if (reconnect != null) {
          // what the plan changed (settings only): the mode, the routing, the entry
          final changed = <String, Object?>{
            if (oldPlan != null && planTun(oldPlan) != planTun(plan)) 'mode': {'from': planTun(oldPlan) ? 'tun' : 'proxy', 'to': planTun(plan) ? 'tun' : 'proxy'},
            if (oldPlan != null && (oldPlan['global'] == true) != (plan['global'] == true))
              'route': {'from': oldPlan['global'] == true ? 'global' : 'rules', 'to': plan['global'] == true ? 'global' : 'rules'},
          };
          eventBook.add('conn', 'reconnected', 'info',
              own: own, op: reconnectOp, cause: _netCause(), data: {'reason': reconnect, if (reconnect == 'settings' && changed.isNotEmpty) 'changed': changed, 'tookMs': tookMs});
        } else if (userOp != null) {
          _userDisconnect = null; // consumed
          eventBook.add('conn', 'reconnected', 'info',
              own: true, op: userOp.op, data: {'reason': 'user', 'tookMs': tookMs, 'downMs': startedAt - userOp.at});
        } else {
          eventBook.add('conn', 'connected', 'info', own: own, data: _connectedData(plan));
        }
      } catch (e) {
        _error = '$e';
        if (!runner.running) sentinel.context.stopped();
        logBook.note('error', 'Connect failed: $e');
        if (e is TunNeedsAdmin) {
          await runner.stop(); // refused before the old sing-box (a connect that switches modes) was stopped: a failed connect = not connected
          // stage: `check` = the core is not elevated (nothing started), `start` = sing-box refused
          eventBook.add('core', 'tunNeedsAdmin', 'error', own: own, data: {'stage': e.detail == null ? 'check' : 'start', 'error': ?e.detail});
        } else {
          // `fix`: where the user changes it (docs/logs.md → `conn/connectFailed`), the app's buttons go by it
          eventBook.add('conn', 'connectFailed', 'error', own: own, data: {'reason': '$e', 'fix': ?(e is SingBoxError ? e.fix : null)});
        }
        if (wasBlocking != null && _killSwitch && sysProxy.isSet) {
          _blocking = wasBlocking; // still blocked: only a connect that works, or Remove, ends it
        } else {
          await _sysOff(own: own);
        }
        rethrow;
      } finally {
        _connectOp = null;
        _changed();
      }
    });
    return status();
  }

  /// The connect's checks of servers decided before sing-box started, for conn/connected: per group
  /// `{group, mode, tried, answered, chosen, ms, weak, tookMs, found}`; the route's own group first.
  List<Map<String, dynamic>> _pickReports = const [];

  /// The check of the route's own group (its main group, or a chain's entry) in [_pickReports]; null when the route
  /// was not checked (pinned, one server, the core's choice kept) — conn/connected `pick` is never a rule target's.
  Map<String, dynamic>? _routePick;

  /// How long after the route's own pick the connect still waits for the rule targets' groups; the ones not decided by
  /// then keep being checked and are put on their server by `select` once sing-box runs ([_applyLate]).
  Duration targetGrace = const Duration(milliseconds: 1500);

  // The picks that ended after the connect stopped waiting: (group tag, key), applied when sing-box and the rule service are up
  bool _lateReady = false;
  final _lateQueue = <(String, String)>[];

  String _connectDir() => p.join(dataDir, 'run', 'connect-${_pingSeq++ % 64}');

  /// Which server each group of the route the connect starts on, and of the rule targets, starts with, by a fresh
  /// check of the group's servers (a throwaway sing-box, [TesterSession]; the results go into the pool):
  /// `{groupTag: key}`. The route's main group (a chain's entry group first, then its exit: the pairs through the chosen
  /// entry on a tester of their own). The groups of the rule targets are checked in parallel on the same tester (a chain
  /// target the same two steps): the connect waits for the route's own pick and then at most [targetGrace] more; a target
  /// not decided by then is put on its server by `select` after the start. Standby routes of Auto are not checked. A
  /// pinned or single-server group is not checked, nor, on a continuation, a group the core has a server for ([held]:
  /// group tag → key of the core's own services, the plan's `chosen` is that server). A group with only the app's
  /// `chosen` (a new route, a new rule target) is checked like on a fresh connect; null = a fresh connect.
  /// Fastest and Priority by their rule (group_pick.dart). Nobody answered: the first by rank; no network (the direct path
  /// does not answer either): the same. null = cancelled ([_pickCancel]). A tester that cannot start is no reason to fail
  /// the connect: no pick, the plan as is.
  Future<Map<String, String>?> connectPicks(Map<String, dynamic> plan, {Cancel? cancel, Map<String, String>? held}) async {
    _pickReports = const [];
    _routePick = null;
    _lateReady = false;
    _lateQueue.clear();
    final seq = _connectSeq;
    final rs = planRoutes(plan);
    final i = planCurrent(plan, rs.length), r = rs[i];
    final route = _PickUnit.of(chain: r['kind'] == 'chain', mainTag: routeTag(i), entryTag: routeEntryTag(i), main: r['main'], entry: r['entry']);
    final targets = <_PickUnit>[];
    final routing = plan['routing'], specs = plan['global'] != true && routing is Map ? routing['targets'] : null;
    if (specs is Map) {
      for (final e in specs.entries) {
        final spec = e.value;
        if (spec is! Map) continue;
        final u = _PickUnit.of(chain: spec['kind'] == 'chain', mainTag: '${e.key}', entryTag: targetEntryTag('${e.key}'), main: spec['main'], entry: spec['entry']);
        if (u != null && u.needsPick(held)) targets.add(u);
      }
    }
    final mine = route != null && route.needsPick(held) ? route : null;
    if (mine == null && targets.isEmpty) return {};
    final settings = AutoSettings.fromPlan(plan);
    _starting = plan; // what the tester's resolver reads: the plan being started
    _addrSettings = null;
    final picks = <String, String>{}, reports = <Map<String, dynamic>>[];
    var gateOpen = false;
    void decided(String tag, String key, Map<String, dynamic> rep) {
      if (!gateOpen) {
        picks[tag] = key;
        reports.add(rep);
      } else if (seq == _connectSeq) {
        if (_lateReady) {
          unawaited(_applyLate(seq, tag, key));
        } else {
          _lateQueue.add((tag, key));
        }
      }
    }

    TesterSession? s1;
    try {
      final nodes = <Map>[
        for (final u in [?mine, ...targets])
          if (u.first.pickable(held)) ...u.first.byKey.values,
      ];
      // what the plan being started gives the testers: read once, here (a late tester starts after `_starting` is cleared)
      final addr = await _addressSettings();
      final resolver = await _testerResolver(addr);
      final s = s1 = TesterSession(
          binary: singBox,
          workDir: _connectDir(),
          nodes: nodes,
          pool: pool,
          url: settings.url,
          checkers: settings.checkers,
          timeoutMs: settings.timeoutMs,
          boxFactory: _loggedBoxes('connect'),
          pins: await _testerPins(nodes, const [], 'connect', settings: addr),
          nodeResolver: resolver,
          onWarn: (l) => logBook.note('warn', 'connect: $l'));
      await s.ensure(); // a tester that cannot start is an error (the catch below), not a pool full of misses
      Future<void> run(_PickUnit u) => _runUnit(u, s, settings, addr, resolver, held, cancel, late: () => gateOpen, decided: decided);
      final main = mine == null ? Future<void>.value() : run(mine);
      final others = [for (final u in targets) run(u)];
      // the tester lives until the last check ends, late ones included (their results go to the pool)
      unawaited(Future.wait([main, ...others]).whenComplete(s.finish));
      await main;
      if (cancel?.cancelled == true) return null;
      if (others.isNotEmpty) await Future.any([Future.wait(others), Future<void>.delayed(targetGrace), if (cancel != null) cancel.done]);
      if (cancel?.cancelled == true) return null;
      gateOpen = true;
      // the route's own groups first (conn/connected `pick`), then the rule targets' in the order they were decided
      final own = {?mine?.first.tag, ?mine?.exit?.tag};
      _pickReports = [...reports.where((x) => own.contains(x['group'])), ...reports.where((x) => !own.contains(x['group']))];
      _routePick = reports.where((x) => x['group'] == mine?.first.tag).firstOrNull;
      return Map.of(picks);
    } catch (e) {
      gateOpen = true;
      s1?.finish();
      logBook.note('warn', 'connect: the servers of ${mine == null ? 'the rule targets' : mine.first.tag} could not be checked ($e): the plan is used as it is');
      return {};
    } finally {
      gateOpen = true;
      _starting = null;
      _addrSettings = null;
    }
  }

  /// One route or rule target: its first group (the main group of a unit, a chain's entry) on [s], then a chain's
  /// exit by pairs through the chosen entry on a tester of its own. Each decided group goes to [decided]. Never throws.
  Future<void> _runUnit(_PickUnit u, TesterSession s, AutoSettings st, AddressSettings addr, DnsCandidate? resolver, Map<String, String>? held, Cancel? cancel,
      {required bool Function() late, required void Function(String tag, String key, Map<String, dynamic> rep) decided}) async {
    try {
      final first = u.first;
      var entryKey = first.startKey, entryFound = true;
      if (first.pickable(held)) {
        final res = await _runPick(first, s, st, cancel, late: late, idOf: first.idOf, probe1: (k) => s.probe('n', k, first.idOf(k)));
        if (res == null) return;
        entryKey = res.chosen;
        entryFound = res.rep['found'] == true;
        decided(first.tag, res.chosen, res.rep);
      }
      final exit = u.exit;
      if (exit == null || !exit.pickable(held) || cancel?.cancelled == true) return;
      if (!entryFound) {
        // nobody answers through the entry: the exits cannot be told apart, the first one starts (Auto heals)
        final chosen = exit.keys.first;
        logBook.note('warn', 'connect: ${exit.tag} ${exit.priority ? 'priority' : 'fastest'}: the entry ${first.tag} answered nobody, the exits are not checked, starts on $chosen');
        decided(exit.tag, chosen, {'group': exit.tag, 'mode': exit.priority ? 'priority' : 'fastest', 'tried': 0, 'answered': 0, 'chosen': chosen, 'ms': -1, 'weak': false, 'tookMs': 0, 'found': false});
        return;
      }
      final entryNode = first.byKey[entryKey]!, entryId = first.idOf(entryKey);
      final pairs = [for (final k in exit.keys) {'key': k, 'entry': entryNode, 'exit': exit.byKey[k]}];
      TesterSession? s2;
      try {
        final t = s2 = TesterSession(
            binary: singBox,
            workDir: _connectDir(),
            nodes: const [],
            pairs: pairs,
            pool: pool,
            url: st.url,
            checkers: st.checkers,
            timeoutMs: st.timeoutMs,
            boxFactory: _loggedBoxes('connect'),
            pins: await _testerPins(const [], pairs, 'connect', settings: addr),
            nodeResolver: resolver,
            onWarn: (l) => logBook.note('warn', 'connect: $l'));
        await t.ensure();
        String pid(String k) => pairIdentity(entryId, exit.idOf(k));
        final res = await _runPick(exit, t, st, cancel, late: late, idOf: pid, probe1: (k) => t.probe('p', k, pid(k)));
        if (res != null) decided(exit.tag, res.chosen, res.rep);
      } catch (e) {
        logBook.note('warn', 'connect: the exits of ${exit.tag} could not be checked ($e): the plan is used as it is');
      } finally {
        s2?.finish();
      }
    } catch (e) {
      logBook.note('warn', 'connect: the servers of ${u.first.tag} could not be checked ($e): the plan is used as it is');
    }
  }

  /// One pick of [g] on [s] by its rule; null = cancelled. [idOf]: the pool identity of a server ([probe1] tests it).
  Future<({String chosen, Map<String, dynamic> rep})?> _runPick(_PickGroup g, TesterSession s, AutoSettings st, Cancel? cancel,
      {required bool Function() late, required String Function(String key) idOf, required Probe1 probe1}) async {
    final keys = g.keys, mode = g.priority ? 'priority' : 'fastest';
    final ranked = g.priority
        ? keys
        : rankCandidates(keys, peek: (k) {
            final p = pool.peek(idOf(k), url: st.url, checkers: st.checkers);
            return p != null && pool.now - p.at <= AutoService.workingAge.inMilliseconds ? p : null;
          }, dead: (k) => pool.ladder.has(idOf(k)));
    var noNet = false;
    Future<bool> afterEmpty() async => noNet = await s.directAnswers() == false;
    final pick = g.priority
        ? await pickPriority(ranked, probe1, cancel: cancel, afterEmpty: afterEmpty)
        : await pickFastest(ranked, probe1, cancel: cancel, afterEmpty: afterEmpty);
    if (pick.cancelled || cancel?.cancelled == true) return null;
    if (!pick.found && !noNet) await s.directAnswers(); // everybody missed: the network is told apart from dead servers
    final chosen = pick.key ?? ranked.first;
    final rep = {'group': g.tag, 'mode': mode, ...pick.toJson(), 'chosen': chosen, 'found': pick.found}..remove('key');
    final isLate = late();
    logBook.note(pick.found ? 'info' : 'warn',
        'connect: ${g.tag} $mode: tried ${pick.tried} of ${keys.length}, ${pick.answered} answered; '
        '${pick.found ? '$chosen ${pick.ms}ms${pick.weak ? ' (a backup check only)' : ''}' : 'nobody answered${noNet ? ' (no network)' : ''}, starts on $chosen'}; ${pick.tookMs}ms'
        '${isLate ? ' (late: applied after the start)' : ''}');
    return (chosen: chosen, rep: rep);
  }

  /// The connect's pick of a rule target's group that ended after the connect stopped waiting is put in place once
  /// sing-box and the rule service run (the service marks it as the core's own, so the first look at the groups does
  /// not put the cache's choice back over it).
  void _releaseLate(int seq) {
    _lateReady = true;
    final queued = List.of(_lateQueue);
    _lateQueue.clear();
    for (final (tag, key) in queued) {
      unawaited(_applyLate(seq, tag, key));
    }
  }

  Future<void> _applyLate(int seq, String tag, String key) async {
    if (seq != _connectSeq || !runner.running) return;
    try {
      final fb = _fallback;
      final ok = fb != null ? await fb.select(tag, key) : await runner.api?.select(tag, '$tag/$key') ?? false;
      logBook.note(ok ? 'info' : 'warn', 'connect: $tag: ${ok ? 'late pick applied' : 'late pick not applied (the group moved since, or sing-box refused)'}: $key');
    } catch (e) {
      logBook.note('warn', 'connect: $tag: late pick $key not applied ($e)');
    }
  }

  // conn/connected: the entry Auto starts on and its server (the group's chosen member),
  // the mode (tun / proxy) and the routing; `pick`: the check of the servers made for this start (connectPicks).
  Map<String, dynamic> _connectedData(Map<String, dynamic> plan) {
    final routes = planRoutes(plan);
    final i = planCurrent(plan, routes.length);
    final server = _auto?.toJson()['server'];
    return {
      'entry': '${routes[i]['id'] ?? routeTag(i)}',
      'server': ?server,
      'pick': ?_routePick, // the route's own group only
      if (_pickReports.length > 1 || (_pickReports.isNotEmpty && _routePick == null))
        'picks': _pickReports, // every group decided before the start: the exit of a chain, the rule targets
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
      if (a != null && a.index != was) {
        unawaited(_dns?.nodeChanged());
      }
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

  /// body: `{provider, poll?}` — the latency of a DNS provider per side by the failover's own check (docs/rules.md §6):
  /// `{provider, live, testing, direct, vpn, servers: [{id, side, kind, ms}], providers}`. It does not wait for the
  /// checks: it starts them (a ping of the provider already under way is joined) and answers at once with what is known,
  /// the transports still asked read `state: testing` in `providers`; the caller asks again (`poll: true` only reads, it
  /// starts nothing) until `testing` is false. `direct` / `vpn`: the best ms of the provider's candidates on that side
  /// that answered, -1 = asked and none answered, null = no candidate there or not asked yet. `servers[].ms`: -2 = not asked
  /// yet. `live: false` (sing-box not running, or the provider is not in its config: off, not named by a rule): nothing was
  /// measured, both sides null.
  @override
  Future<Map<String, dynamic>> pingDnsSides(Map<String, dynamic> body) async {
    final provider = '${body['provider'] ?? ''}';
    final dns = runner.running ? _dns : null;
    if (dns != null && body['poll'] != true) unawaited(dns.startPing(provider) ?? Future<void>.value());
    final got = dns?.pingResults(provider) ?? const <({String id, String side, String kind, int ms})>[];
    int? best(String side) {
      final ms = [for (final g in got) if (g.side == side) g.ms];
      if (ms.isEmpty || ms.every((m) => m == -2)) return null;
      final ok = ms.where((m) => m >= 0);
      return ok.isEmpty ? -1 : ok.reduce((a, b) => a < b ? a : b);
    }

    return {
      'provider': provider,
      'live': got.isNotEmpty,
      'testing': got.isNotEmpty && dns!.pinging(provider),
      'direct': best('direct'),
      'vpn': best('vpn'),
      'servers': [for (final g in got) {'id': g.id, 'side': g.side, 'kind': g.kind, 'ms': g.ms}],
      'providers': got.isEmpty ? const [] : dns!.providersJson(provider), // the protocol race: winner and each transport's last result
    };
  }

  @override
  Future<Map<String, dynamic>> disconnect({Map<String, dynamic>? error}) async {
    final seq = _nextSeq();
    _wakeUp(); // ends the restart's retries
    final was = runner.running || _plan != null || _recovering != null;
    _plan = null;
    _lostTargets = const {};
    _recovering = null;
    _downSince = null;
    _released = false;
    _stopAuto();
    _dnsFlagMemory = const {};
    _dnsReserveMemory = const {};
    _closeCrashRoot('disconnected');
    await _locked(() async {
      if (seq == _connectSeq) {
        await runner.stop();
        sentinel.context.stopped();
      }
    });
    _tunnelPort = null;
    unawaited(_tunCheck?.close());
    _tunCheck = null;
    logBook.note('info', 'Disconnected');
    if (was) {
      if (error != null) {
        // the host ended the connection because of an error (a lost Manual pin: `{reason: 'pinLost', pick?, why?}`): not the user's
        final reason = '${error['reason'] ?? 'down'}';
        eventBook.add('conn', 'disconnected', 'warn', data: {
          'by': 'error',
          'reason': reason,
          'pick': ?error['pick'],
          'why': ?error['why'],
        });
      } else {
        // the second half of the user's "disconnect → connect" within 7 s is one `conn/reconnected` with this op
        final op = _newOp('connection');
        _userDisconnect = (op: op, at: _nowMs);
        eventBook.add('conn', 'disconnected', 'info', own: true, data: {'by': 'user'}, op: op);
      }
    }
    if (_killSwitch && _killOnDisconnect && sysProxy.isSet && (was || _blocking != null)) {
      // kill switch, "also after I disconnect": the proxy stays, nothing gets out
      _blocking ??= {'since': _now().millisecondsSinceEpoch, 'reason': 'disconnect', 'proxy': 'kept'};
    } else {
      _blocking = null;
      await _sysOff(own: true);
    }
    _recheckExit(); // now the direct IP
    // no sing-box and no Auto from here: a «down» (or an outage of the routes) found while connected is asked again on
    // the direct path, or nobody would until the platform reports a change
    if (pool.status == NetStatus.down || autoMemory.lostAt != null) unawaited(_probeNetwork());
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

  /// body: `{connected?, validated?, captive?, type?, id?}` — what the platform says of the network now
  /// (Android: the default network's capabilities and transport), as a whole: a missing field is "not
  /// said". → the Sentinel's context (`status.context`). Never throws.
  @override
  Map<String, dynamic> setNetwork(Map<String, dynamic> body) {
    final id = body['id'];
    final epoch = sentinel.context.netEpoch;
    // the tracker first: the context may settle inside `platform` and ask it whether the network switched
    final at = body['at'] is num ? DateTime.fromMillisecondsSinceEpoch((body['at'] as num).toInt()) : _now();
    final type = body['type'] is String ? (body['type'] == 'cellular' ? 'mobile' : body['type'] as String) : null;
    if (body['connected'] == false) {
      _netSwitches.onNetwork(null, at);
    } else if (type != null) {
      _netSwitches.onNetwork(
          NetInfo(
              type: type,
              id: id is String || id is num ? '$id' : null,
              operator: body['operator'] is String ? body['operator'] as String : null,
              metered: body['metered'] is bool ? body['metered'] as bool : null),
          at);
    }
    sentinel.context.platform(
      connected: body['connected'] is bool ? body['connected'] as bool : null,
      validated: body['validated'] is bool ? body['validated'] as bool : null,
      captive: body['captive'] == true,
      type: body['type'] is String ? body['type'] as String : null,
      id: id is String || id is num ? '$id' : null,
      at: body['at'] is num ? (body['at'] as num).toInt() : null,
    );
    // another network, or the connection back: what was found out on the old one (a «down» of the probes) is not known
    // of this one, so the direct path is asked at once, connected or not. Not while the platform itself says there is
    // no connection or a portal (nothing to ask).
    if (!_netBaseline && sentinel.context.stable && body['connected'] != false && type != null) {
      _netBaseline = true; // the first network of this run: remembered as the one a switch leaves (not itself a switch)
      unawaited(_netSettled());
    }
    final n = sentinel.context.network;
    if (sentinel.context.netEpoch != epoch && n.state != NetState.captive && !(n.state == NetState.none && n.source == 'platform')) {
      unawaited(_probeNetwork());
    }
    return sentinel.contextJson();
  }

  int _netProbeSeq = 0;

  /// Asks the direct path (`AutoSettings` url and checkers of the connection, else the defaults) until it answers: the
  /// answer is `up` (the pool, anything that answers) and ends a `net.offline` of the probes and an outage of Auto's
  /// (`conn/online`, `conn/restored`); silence is `down`. The status stays as it was until then, so a root is closed by
  /// the answer and by nothing else. With a connection Auto's rounds go on asking (every `noNetEvery`): this asks once;
  /// with none, nobody else does, so it repeats every `noNetEvery` while the pool is down. A newer call takes over.
  Future<void> _probeNetwork() async {
    final seq = ++_netProbeSeq;
    while (!_disposed && seq == _netProbeSeq) {
      final s = _auto?.settings ?? AutoSettings.fromPlan(_plan ?? const {});
      final up = await pool.directAnswers(url: s.url, checkers: s.checkers, timeoutMs: s.timeoutMs);
      if (_disposed || seq != _netProbeSeq) return;
      if (up == true) {
        if (_auto == null) {
          // no connection to tell it: the routes' outage that stood is over with the network (a connect asks them again)
          final since = autoMemory.answered();
          if (since != null) routesRestored(AutoNet(kind: 'restored', at: _nowMs, downMs: _nowMs - since));
        }
        return;
      }
      if (up == null) return;
      pool.silent(true);
      if (_auto != null) return;
      final wait = Completer<void>();
      _timer(s.noNetEvery, wait.complete);
      await wait.future;
    }
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
        final first = receipt.firstError;
        final way = receipt.via == 'vpn' ? ' via VPN' : ' direct';
        final via = first == null ? way : '$way, after the first way failed ($first)';
        logBook.note('info',
            'Report sent: ${receipt.id} (${packed.gzipped.length} bytes, built in ${built}ms, sent in ${sw.elapsedMilliseconds - built}ms)$via');
        return {'ok': true, 'id': receipt.id, 'bytes': packed.gzipped.length, 'via': receipt.via, 'firstError': ?first};
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
        'detectNetProvider': detectNetProvider,
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
            pins: await _testerPins(nodes, pairs, 'ping'),
            nodeResolver: await _testerResolver(),
            onResult: (kind, key, ms, byChecker) => line({'kind': kind, 'key': key, 'ms': ms, if (byChecker) 'byChecker': true}),
            onFail: (tag, reason) => why[reason] = (why[reason] ?? 0) + 1,
            onWarn: (l) => logBook.note('warn', 'Ping: $l'),
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
        final node = body['node'] as Map?, pair = body['pair'] as Map?;
        await core_speed.speedTest(
          binary: singBox,
          workDir: p.join(dataDir, 'run', 'speed'),
          node: node,
          pair: pair,
          pins: await _testerPins([?node], [?pair], 'speed test'),
          nodeResolver: await _testerResolver(),
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
            note: 'Speed test of the connection: down ${((m['down'] as num) / 1e6).toStringAsFixed(1)} Mbps, up ${(((m['up'] as num?) ?? 0) / 1e6).toStringAsFixed(1)} Mbps, latency ${m['latency']}ms');
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
          get: updateGet,
          svc: svcFetch,
          onEvent: _appUpdateEvent,
          onSvcFailed: _updateCheckFailed,
        );

  /// The operation of the app update under way (`appUpdate`): the events of one cycle (offer, download, install or
  /// failure) share it. It starts with the first of them and ends with the offer the cycle ended on (a failure,
  /// the install, an empty channel); the next event opens a new one.
  Map<String, Object?>? _appUpdateOp;

  /// An event of the app updater: `core/<type>` with the cycle's `op`. A failure of the update is `warn` however
  /// it was found (a scheduled check too), it is the user's to know that the app does not update.
  void _appUpdateEvent(String type, String level, Map<String, dynamic> data) {
    final op = _appUpdateOp ??= _newOp('appUpdate');
    if (type == 'updateFailed' || type == 'updateInstalled' || type == 'updateChannelEmpty') _appUpdateOp = null;
    _event('core', type, type == 'updateFailed' ? 'warn' : level, data, op: op);
  }

  /// `core/updateFailed` (stage check) of a scheduled check that no path answered: the Sentinel judges it and
  /// the event is written only for a `confirmed` verdict (as `sub/failed`). A failure of our own restart never gets here.
  void _updateCheckFailed(SvcFailure f, Map<String, dynamic> data) {
    final s = f.suspicion(why: Why('svc.fetch', {'purpose': 'appupdate'}));
    if (s == null) {
      _appUpdateEvent('updateFailed', 'warn', data);
      return;
    }
    final op = _appUpdateOp ??= _newOp('appUpdate');
    unawaited(sentinel.suspect(s).then((v) {
      if (v.kind != VerdictKind.confirmed || v.repeat) return;
      if (identical(_appUpdateOp, op)) _appUpdateOp = null;
      _event('core', 'updateFailed', 'warn', data, verdict: 'confirmed', why: v.why, trail: v.trail, cause: v.cause, op: op);
    }));
  }
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
    if (body['detectNetProvider'] is bool) detectNetProvider = body['detectNetProvider'] as bool;
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

/// A manual subscription update the core ends itself, with no load (no network in time, the core down): the user's
/// call fails with [message]; `sub/failed` gets [code] (and the Sentinel's [why] / [cause] when it has them).
class _SubAbort extends HttpException {
  _SubAbort(super.message, this.code, {this.why, this.cause});

  final String code;
  final Why? why;
  final int? cause;
}

/// A group of the plan as the connect's pick sees it (service.dart `connectPicks`).
class _PickGroup {
  _PickGroup._(this.tag, this.group);

  /// null = no group, or no server in it that a tester could dial.
  static _PickGroup? of(String tag, Object? g) {
    if (g is! Map) return null;
    final out = _PickGroup._(tag, g);
    for (final n in (g['nodes'] as List? ?? const []).cast<Map>()) {
      if (n['outbound'] is Map) out.byKey.putIfAbsent('${n['key']}', () => n);
    }
    return out.byKey.isEmpty ? null : out;
  }

  final String tag;
  final Map group;
  final byKey = <String, Map>{};

  List<String> get keys => byKey.keys.toList();
  bool get priority => group['pick'] == 'priority';

  /// The server the config starts the group on: the plan's `chosen` when it is a member, else the first.
  String get startKey => byKey.containsKey(group['chosen']) ? group['chosen'] as String : byKey.keys.first;
  String idOf(String key) => serverIdentity(byKey[key]!['outbound'] as Map);

  /// Whether the connect checks the group: not a pinned one, not a single server, not (on a continuation, [held] given)
  /// one the core has on the server the plan's `chosen` names; the app's own `chosen` is only a hint.
  bool pickable(Map<String, String>? held) =>
      group['pinned'] != true && byKey.length >= 2 && !(held != null && byKey.containsKey(group['chosen']) && held[tag] == group['chosen']);
}

/// What the connect checks together: a route's or a rule target's [first] group (a unit's main group, a chain's entry)
/// and a chain's [exit] group, tested by pairs through the entry chosen.
class _PickUnit {
  _PickUnit._(this.first, this.exit);

  static _PickUnit? of({required bool chain, required String mainTag, required String entryTag, Object? main, Object? entry}) {
    if (!chain) {
      final g = _PickGroup.of(mainTag, main);
      return g == null ? null : _PickUnit._(g, null);
    }
    final e = _PickGroup.of(entryTag, entry);
    return e == null ? null : _PickUnit._(e, _PickGroup.of(mainTag, main));
  }

  final _PickGroup first;
  final _PickGroup? exit;

  bool needsPick(Map<String, String>? held) => first.pickable(held) || (exit?.pickable(held) ?? false);
}
