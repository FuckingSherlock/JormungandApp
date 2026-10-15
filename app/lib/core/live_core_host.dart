import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:jormungand_core/jormungand_core.dart';

import '../platform/apps_io.dart';
import '../platform/network_channel.dart';
import '../platform/resume_channel.dart';
import '../platform/screen_channel.dart';
import '../platform/update_job_channel.dart';
import '../platform/vpn_channel.dart';
import 'app_update.dart';
import 'core_host.dart';
import 'report_info.dart';
import 'settings_model.dart';

/// The real [CoreHost]: the in-process core ([CoreApi], normally `CoreService`) plus the
/// [Catalog] (the mockup's catalog logic in Dart), the way the mockup's `95-live.js` drives
/// the core.
///
/// The catalog is the app's state: loaded from the core's snapshot at start, saved back
/// (debounced) after every change. What to connect through is decided here (`livePlan`), the
/// core only runs it and tells how it goes (`status`): the connect flow is
/// `checkBeforeConnect` -> (Android: VPN consent) -> `livePlan` -> `api.connect(plan + kill
/// switch + system proxy)` -> status. While connected, a change that makes another plan
/// (`planSig`) reconnects after 600 ms; a change of the Auto settings only goes to the core.
class LiveCoreHost extends CoreHost {
  LiveCoreHost({
    required this.api,
    required this.isAndroid,
    this.vpn,
    this.appVersion = '',
    this.appBuild = 0,
    this.installer,
    this.resume,
    this.network,
    this.screen,
    this.updateJob,
    this.resumeWindow = const Duration(minutes: 10),
    this.logNote,
    this.ruleSetTimesOf,
    this.saveDelay = const Duration(milliseconds: 400),
    this.reconnectDelay = const Duration(milliseconds: 600),
    this.trafficEvery = const Duration(seconds: 1),
    this.notifyEvery = const Duration(milliseconds: 120),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CoreApi api;

  /// Android: always TUN (the VpnService), no system proxy, the consent dialog before a connect.
  @override
  final bool isAndroid;

  /// Android's VpnService bridge; null elsewhere.
  final VpnChannel? vpn;

  /// The running app's version (`0.1.0`), shown in Settings -> Data.
  @override
  final String appVersion;

  /// The running app's build number (Android versionCode); 0 when unknown.
  @override
  final int appBuild;

  /// Hands a downloaded update file to the platform's installer (Android: PackageInstaller);
  /// null where that side is not written, then [canInstallUpdate] is false.
  final Future<bool> Function(String file)? installer;

  /// Where "the VPN was on" is kept across the app's own update (Android: native store); null =
  /// not remembered, nothing is resumed.
  final ResumePort? resume;

  /// Whether the real network is metered (Android); null = never metered (the desktop). Goes to the
  /// core with the update settings: «Auto-download: Wi-Fi only» waits for an unmetered network.
  final NetworkPort? network;

  /// The phone's screen (Android); null = always on (the desktop). Every change goes to the core at
  /// once (`updateSettings {screenOn}`), which marks a site failure found while it is off as background.
  final ScreenPort? screen;

  /// The native side of the background update check (Android WorkManager, lib/core/update_job.dart); null
  /// = none (the desktop). Gets the update options and the notification switches on every change.
  final UpdateJobPort? updateJob;

  /// How long after the package replacement a resume still counts; a later start leaves the VPN off.
  final Duration resumeWindow;

  /// A line into the app's raw log (`level`: debug, info, warn, error); the core's `logBook.note`.
  final void Function(String level, String text)? logNote;

  /// When the rule-set lists were downloaded (the core's rule-set cache), by name; null = unknown.
  final Future<Map<String, int>> Function()? ruleSetTimesOf;

  final Duration saveDelay;
  final Duration reconnectDelay;
  final Duration trafficEvery;

  /// The pause that joins the notifications of a ping run (one answer per server) and of the
  /// core's status ticks into one: see [_notify]. Zero = every one goes out at once.
  final Duration notifyEvery;
  final DateTime Function() _now;

  /// The app's state. Public for the pages that edit it (Route, ...): they call [changed] after
  /// an edit; Nodes edits only through the methods below.
  @override
  Catalog catalog = Catalog();

  Future<void>? _init;
  bool _ready = false;
  bool _disposed = false;
  String? _initError;

  bool _connected = false;
  bool _connecting = false;
  bool _disconnecting = false;
  String? _error;
  VpnDown? _down;
  KillBlock? _blocking;
  ExitState _exit = const ExitState.checking();
  DnsHealth? _dnsHealth;
  SpeedResult? _lastSpeed;
  StreamSubscription<Map<String, dynamic>>? _speedSub;
  Map<String, dynamic> _speedProgress = const {};
  String? _speedError;
  AppUpdate _upd = const AppUpdate();
  StreamSubscription<Map<String, dynamic>>? _updSub;
  StreamSubscription<bool>? _meteredSub, _screenSub;
  StreamSubscription<Map<String, dynamic>>? _netStateSub;
  String? _updSettingsSig;
  bool _metered = false;
  Object? _sourcesRev;

  // the plan the core runs (null = none): what a reconnect is compared with
  String? _planSig;
  String? _autoSig;
  String? _modeSig; // Auto / Manual (+ the entry) the core was last told: switched live, no reconnect
  String? _killSig;
  Timer? _reconnectTimer;
  Timer? _saveTimer;
  Timer? _trafficTimer;
  bool _trafficBusy = false;
  bool _reconnecting = false;
  bool _syncingSources = false;
  final Set<String> _updating = {};

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _notices = StreamController<HostNotice>.broadcast();

  // ───────────────────────────── start / stop ─────────────────────────────

  @override
  Future<void> init() => _init ??= _start();

  Future<void> _start() async {
    try {
      await api.init();
      // the identity of the real network goes to the Sentinel before anything runs on it (the stream says the
      // current one at once on listen), then on every change: a Wi-Fi switch is a move, not a route failure
      _netStateSub = network?.states.listen((s) {
        try {
          api.setNetwork(s);
        } catch (_) {}
      }, onError: (_) {});
      final r = await api.state();
      final snap = r['snapshot'];
      catalog = Catalog.fromJson(
        snap is Map ? Map<String, dynamic>.from(snap) : null,
      );
      catalog.appInfo = _appInfo;
      catalog.syncCatalog();
      catalog.purgeExpiredGone();
      if (isAndroid) {
        catalog.segState
          ..mode = 'tun'
          ..sys = 'off';
        // the names of installed apps for logs, the plan and the delete dialog, before Rules is opened
        unawaited(installedApps());
      }
      final st = r['status'];
      if (st is Map) {
        _sourcesRev = st['sourcesRev'];
        _applyStatus(Map<String, dynamic>.from(st), notify: false);
      }
      _killSig = _killSigNow();
      await _adoptRunning();
      _statusSub = api.statusChanges.listen(_onStatus, onError: (_) {});
      _eventSub = api.eventStream.listen(_events.add, onError: (_) {});
      _upd = AppUpdate.fromJson(api.updateStatus());
      _updSub = api.updateChanges.listen((s) {
        _upd = AppUpdate.fromJson(s);
        _notify();
      }, onError: (_) {});
      try {
        _metered = await network?.metered() ?? false;
      } catch (_) {}
      _syncUpdateSettings();
      _syncUpdateJob();
      _meteredSub =network?.meteredChanges.listen((m) {
        _metered = m;
        _syncUpdateSettings();
      }, onError: (_) {});
      // the screen: the current state, then every change (the stream says it at once on listen too)
      void screenOn(bool on) {
        try {
          api.updateSettings({'screenOn': on});
        } catch (_) {}
      }
      try {
        final on = await screen?.on();
        if (on != null) screenOn(on);
      } catch (_) {}
      _screenSub = screen?.changes.listen(screenOn, onError: (_) {});
      _ready = true;
      // a tunnel taken over with another plan than the catalog makes now: the same path as after
      // any change of settings (a reconnect after the usual pause), never a silent restart
      _scheduleReconnect();
    } catch (e) {
      _initError = '$e';
      _notice(HostNotice('initFailed', '$e', args: ['$e']));
    }
    _notifyNow();
  }

  /// The engine of the app was made again while the tunnel (the VpnService) kept running: the
  /// core takes it over — connected, the API / Auto / traffic attached, nothing stopped or
  /// started. The plan it runs becomes the one a later change is compared with (so a catalog
  /// that builds another plan now is an ordinary plan change, see [_scheduleReconnect]).
  Future<void> _adoptRunning() async {
    try {
      final kill = _killPlan();
      final r = await api.adopt({
        'dnsAuto': catalog.dnsCfg.auto,
        'auto': catalog.planAuto(),
        ...kill,
      });
      final raw = r['plan'];
      if (r['adopted'] != true || raw is! Map) return;
      final plan = Map<String, dynamic>.from(raw);
      final routes = plan['routes'] as List;
      final current = (plan['current'] as num?)?.toInt() ?? 0;
      catalog.liveAnchor =
          (routes[current < 0 ? 0 : current] as Map)['id'] as String?;
      _planSig = catalog.planSigOf(plan);
      _autoSig = _autoSigOf();
      _modeSig = null; // the next change tells the core the mode the catalog is in now
      _killSig = _killSigOf(kill);
      _applyStatus(
        Map<String, dynamic>.from(r['status'] as Map),
        notify: false,
      );
    } catch (e) {
      // not taken over: the core stopped what it could not take, the state stays "disconnected"
      _notice(HostNotice('connectFailed', '$e'));
    }
  }

  @override
  Future<void> shutdown() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _trafficTimer?.cancel();
    await _flushSave();
    await _statusSub?.cancel();
    await _eventSub?.cancel();
    await _updSub?.cancel();
    await _meteredSub?.cancel();
    await _screenSub?.cancel();
    await _netStateSub?.cancel();
    _statusSub = _eventSub = _updSub = null;
    _meteredSub = _screenSub = _netStateSub = null;
    if (_ready) {
      try {
        await api.dispose();
      } catch (_) {}
    }
    _ready = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _saveTimer?.cancel();
    _trafficTimer?.cancel();
    _notifyTimer?.cancel();
    _statusSub?.cancel();
    _eventSub?.cancel();
    _speedSub?.cancel();
    _updSub?.cancel();
    _meteredSub?.cancel();
    _screenSub?.cancel();
    _netStateSub?.cancel();
    _events.close();
    _notices.close();
    super.dispose();
  }

  Timer? _notifyTimer;
  bool _notifyDirty = false;
  DockSummary? _dockCache;

  /// Tells the listeners, joined: the first call opens a [notifyEvery] window, the ones inside it
  /// add nothing, one notification goes out when it closes. For what comes in bursts (a ping's
  /// answers, the core's status ticks, the update's progress). A user's action or a change of
  /// phase uses [_notifyNow].
  void _notify() {
    if (_disposed) return;
    _dockCache = null;
    if (notifyEvery == Duration.zero) return _notifyNow();
    _notifyDirty = true;
    _notifyTimer ??= Timer(notifyEvery, () {
      _notifyTimer = null;
      if (_notifyDirty) _notifyNow();
    });
  }

  /// Notifies at once and drops what [_notify] still held.
  void _notifyNow() {
    if (_disposed) return;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _notifyDirty = false;
    _dockCache = null;
    notifyListeners();
  }

  /// Delivers a held [_notify] now (tests; the app needs no call).
  @visibleForTesting
  void flushNotify() {
    if (_notifyDirty) _notifyNow();
  }

  void _notice(HostNotice n) {
    if (!_disposed) _notices.add(n);
  }

  // ───────────────────────────── status ─────────────────────────────

  void _onStatus(Map<String, dynamic> st) {
    final rev = st['sourcesRev'];
    _applyStatus(st);
    if (rev != null && rev != _sourcesRev) unawaited(_syncSources());
  }

  /// `status` -> what the UI shows: the phase, the exit, the down / blocking plaques, where the
  /// core's Auto stands (for the dock) and the pings it measured (`liveAutoStatus`).
  void _applyStatus(Map<String, dynamic> st, {bool notify = true}) {
    final before = _statusSig();
    _dockCache = null;
    _connected = st['connected'] == true;
    _lastSpeed = SpeedResult.fromJson(st['speed']) ?? _lastSpeed;
    if (!_connected) _endSpeedTest(); // the tunnel is gone: so is the test through it
    final auto = _connected && st['auto'] is Map ? st['auto'] as Map : null;
    // the one lookup of this status: a member key `sid::nid` -> its server, by a map per source
    final byKey = _keyLookup();
    catalog.coreRoute = auto == null || auto['now'] == null
        ? null
        : CoreRoute(
            id: '${auto['now']}',
            server: auto['server'] as String?,
            entryServer: auto['entryServer'] as String?,
          );
    // where every route's groups stand, standby routes too: a new plan starts them there
    final groups = auto?['routes'];
    catalog.coreGroups = {
      if (groups is List)
        for (final g in groups.whereType<Map>())
          if (g['id'] != null && (g['server'] != null || g['entryServer'] != null))
            '${g['id']}': CoreRoute(
              id: '${g['id']}',
              server: g['server'] as String?,
              entryServer: g['entryServer'] as String?,
            ),
    };
    final members = auto?['members'];
    if (members is List) {
      catalog.pings.mergeCore(members.whereType<Map>(), byKey);
    }
    final pairs = auto?['pairs'];
    if (pairs is List) {
      catalog.pairs.mergeCore(pairs.whereType<Map>(), byKey);
    }
    final d = st['down'];
    _down = d is Map
        ? VpnDown(
            since: (d['since'] as num?)?.toInt() ?? 0,
            proxy: '${d['proxy'] ?? 'removed'}',
          )
        : null;
    final b = st['blocking'];
    _blocking = b is Map
        ? KillBlock(
            since: (b['since'] as num?)?.toInt() ?? 0,
            reason: '${b['reason'] ?? 'disconnect'}',
            proxy: '${b['proxy'] ?? 'kept'}',
          )
        : null;
    final e = st['exit'];
    if (e is! Map) {
      _exit = const ExitState.checking();
    } else if (e['ip'] == null && e['error'] != null) {
      _exit = const ExitState.error();
    } else if (e['ip'] == null && e['rechecking'] == true) {
      _exit = const ExitState.checking();
    } else {
      _exit = ExitState.found(
        ip: '${e['ip'] ?? ''}',
        country: e['country'] as String?,
        city: e['city'] as String?,
        rechecking: e['rechecking'] == true,
        error: e['error'] != null,
        at: e['at'] is num
            ? DateTime.fromMillisecondsSinceEpoch((e['at'] as num).toInt())
            : null,
      );
    }
    if (st['error'] != null) _error = '${st['error']}';
    final dns = st['dns'];
    _dnsHealth = _connected && dns is Map
        ? DnsHealth(
            active: dns['active'] == null ? null : '${dns['active']}',
            answering: {
              for (final side in const ['direct', 'vpn'])
                if (dns['sides'] is Map &&
                    (dns['sides'] as Map)[side] is Map &&
                    ((dns['sides'] as Map)[side] as Map)['provider'] != null)
                  side: '${((dns['sides'] as Map)[side] as Map)['provider']}',
            },
            servers: [
              for (final s in (dns['servers'] as List? ?? const []))
                if (s is Map && s['provider'] != null && s['side'] != null)
                  DnsServerStatus(
                    id: '${s['id']}',
                    provider: '${s['provider']}',
                    side: '${s['side']}',
                    ok: s['ok'] is bool ? s['ok'] as bool : null,
                    watched: s['watched'] == true,
                    rechecking: s['rechecking'] == true,
                    deadOnNode: s['deadOn'] == 'node',
                  ),
            ],
            races: DnsRace.parseAll(dns['providers']),
          )
        : null;
    _syncTrafficTimer();
    if (!notify) return;
    // a change of phase, exit, plaques or Auto's route shows at once; a status that only brings
    // pings joins the other bursts
    if (_statusSig() != before) {
      _notifyNow();
    } else {
      _notify();
    }
  }

  /// What of the status the user sees at a glance: if it moved, the page is told without the
  /// pause of [_notify].
  String _statusSig() {
    final e = _exit, d = _down, b = _blocking, r = catalog.coreRoute, h = _dnsHealth;
    return '$_connected|${d?.since}|${d?.proxy}|${b?.since}|${b?.proxy}|${b?.reason}|'
        '${e.checking}|${e.error}|${e.rechecking}|${e.ip}|${e.country}|${e.city}|${e.at?.millisecondsSinceEpoch}|$_error|'
        '${r?.id}|${r?.server}|${r?.entryServer}|${h?.sig}';
  }

  /// `sid::nid` -> the server, like `catalog.nodeOfKey` but one map per source, built when the
  /// first key of that source asks (a status carries a key per Auto member).
  CatalogNode? Function(String key) _keyLookup() {
    final bySource = <String, Map<String, CatalogNode>>{};
    return (key) {
      final i = key.indexOf('::');
      if (i <= 0) return null;
      final sid = key.substring(0, i);
      final nodes = bySource.putIfAbsent(sid, () {
        final s = catalog.sourcesData[sid];
        final m = <String, CatalogNode>{};
        if (s != null) {
          for (final n in s.nodes) {
            m.putIfAbsent(n.id, () => n); // the first with an id, as nodeOfKey finds it
          }
        }
        return m;
      });
      return nodes[key.substring(i + 2)];
    };
  }

  /// The core's own subscription timer updated a source (`status.sourcesRev` moved): the
  /// sources it updated after us (same URL, newer `updatedAt`) take its server fields,
  /// everything the user set stays (`liveSyncSources`).
  Future<void> _syncSources() async {
    if (_syncingSources || !_ready) return;
    _syncingSources = true;
    try {
      final r = await api.state();
      final st = r['status'];
      if (st is Map) _sourcesRev = st['sourcesRev'];
      final snap = r['snapshot'];
      final theirs = snap is Map && snap['sourcesData'] is Map
          ? snap['sourcesData'] as Map
          : const {};
      var updated = false, failedOnly = false;
      for (final e in theirs.entries) {
        final sid = '${e.key}';
        final s = catalog.sourcesData[sid];
        if (s == null || e.value is! Map) continue;
        final t = Map<String, dynamic>.from(e.value as Map);
        if (s.kind != 'sub' || _updating.contains(sid) || s.url != t['url']) {
          continue;
        }
        final mine = _num(s.unknown['updatedAt']);
        final theirsAt = _num(t['updatedAt']);
        final lastErr = t['lastError'];
        final myErr = s.unknown['lastError'];
        if (lastErr is Map &&
            theirsAt == mine &&
            _num(lastErr['at']) > (myErr is Map ? _num(myErr['at']) : 0)) {
          s.unknown['lastError'] = lastErr;
          failedOnly = true;
        }
        if (theirsAt <= mine) continue;
        catalog.sourcesData[sid] = _withServerFields(s, t);
        updated = true;
      }
      if (updated) {
        catalog.purgeExpiredGone();
        catalog.syncCatalog();
        _keepRunningIfNoReload();
        changed();
      } else if (failedOnly) {
        _notify();
      }
    } catch (_) {
      // the next status tick tries again (sourcesRev stays unseen)
      _sourcesRev = null;
    } finally {
      _syncingSources = false;
    }
  }

  static num _num(Object? v) => v is num ? v : 0;

  /// [s] with the core-owned fields of [t] (the snapshot's copy of the same source);
  /// a field [t] does not have is dropped, the way the mockup deletes it.
  static Source _withServerFields(Source s, Map<String, dynamic> t) {
    final j = s.toJson();
    for (final f in sourceServerFields) {
      if (t.containsKey(f)) {
        j[f] = t[f];
      } else if (f != 'nodes') {
        j.remove(f);
      }
    }
    return Source.fromJson(j);
  }

  // ───────────────────────────── traffic ─────────────────────────────

  void _syncTrafficTimer() {
    if (_connected) {
      _trafficTimer ??= Timer.periodic(trafficEvery, (_) => _pollTraffic());
    } else if (_trafficTimer != null) {
      _trafficTimer!.cancel();
      _trafficTimer = null;
      // not connected: speed and connections are zero, the last session's totals stay
      trafficNotifier.update(
        TrafficInfo(
          downTotal: traffic.downTotal,
          upTotal: traffic.upTotal,
        ),
      );
    }
  }

  Future<void> _pollTraffic() async {
    if (_trafficBusy || !_connected || _disposed) return;
    _trafficBusy = true;
    try {
      final t = await api.traffic();
      if (!_connected) return;
      final next = TrafficInfo(
        down: _num(t['down']),
        up: _num(t['up']),
        downTotal: _num(t['downTotal']),
        upTotal: _num(t['upTotal']),
        tcp: _num(t['tcp']).toInt(),
        udp: _num(t['udp']).toInt(),
        conns: [
          for (final m in (t['conns'] as List? ?? const []))
            if (m is Map) LiveConn.fromJson(m),
        ],
      );
      // the list changes with every byte; the pages only need to know of a new / gone one or a
      // moved total, which is exactly what the speed cards already notify on. Only
      // [trafficNotifier] hears of it: the host (and so every page) does not rebuild per tick.
      final was = traffic;
      final same =
          next.down == was.down &&
          next.up == was.up &&
          next.downTotal == was.downTotal &&
          next.tcp == was.tcp &&
          next.udp == was.udp &&
          next.conns.length == was.conns.length;
      trafficNotifier.update(next, notify: !same);
    } catch (_) {
      // the next tick tries again
    } finally {
      _trafficBusy = false;
    }
  }

  // ───────────────────────────── reads ─────────────────────────────

  @override
  bool get ready => _ready;

  @override
  String? get initError => _initError;

  @override
  ConnectionPhase get phase {
    if (_connecting) return ConnectionPhase.connecting;
    if (_disconnecting) return ConnectionPhase.disconnecting;
    if (_connected) {
      return _down != null ? ConnectionPhase.down : ConnectionPhase.connected;
    }
    return ConnectionPhase.disconnected;
  }

  @override
  String? get error => _error;

  @override
  VpnDown? get down => _connected && !_connecting ? _down : null;

  @override
  KillBlock? get blocking =>
      !_connected &&
          !_connecting &&
          _blocking != null &&
          _blocking!.proxy != 'released'
      ? _blocking
      : null;

  @override
  bool get tun => isAndroid || catalog.segState.tun;

  @override
  bool get global => catalog.segState.global;

  @override
  bool get sysProxy => !isAndroid && catalog.segState.systemProxy;

  @override
  bool get autoMode => catalog.autoConnect;

  @override
  bool get catalogEmpty => catalog.catalogEmpty();

  @override
  ExitState get exit => _connecting ? const ExitState.checking() : _exit;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<HostNotice> get notices => _notices.stream;

  /// What the dock row shows (mockup `updateMainConnectCard`). Kept until the next notification
  /// ([_notify] / [_notifyNow] drop it): the tile, the system notifier and the pages all read
  /// it once per change.
  @override
  DockSummary get dock => _dockCache ??= _buildDock();

  DockSummary _buildDock() {
    final id = catalog.effectiveConnectId();
    final e = catalog.connectEntry(id);
    final simple = catalog.simpleMode;
    final auto = catalog.autoConnect;
    if (e == null) {
      final none = catalog.nothingInAuto();
      final empty = catalog.catalogEmpty();
      return DockSummary(
        kind: simple ? DockKind.simple : DockKind.profiles,
        none: none
            ? DockNone.nothingInAuto
            : empty
            ? DockNone.empty
            : null,
        simpleMode: simple,
        auto: auto,
      );
    }
    int? ms(CatalogNode? n) {
      if (n == null || !catalog.pings.isAlive(n)) return null;
      return catalog.pings.ping(n)!.round();
    }

    final chain = catalog.chainsData[id];
    if (chain != null) {
      final a = catalog.chainEntryNode(chain), b = catalog.chainExitNode(chain);
      return DockSummary(
        kind: DockKind.chain,
        name: e.name,
        simpleMode: simple,
        auto: auto,
        entryNode: _dockNode(a),
        node: _dockNode(b),
        latencyMs: catalog.chainLatency(chain),
      );
    }
    final profile = catalog.profilesData[id];
    final source = catalog.sourcesData[id];
    final n = catalog.unitNode(id);
    String? sourceName;
    if (profile != null && n != null) {
      for (final r in catalog.unitRefs(id)) {
        if (identical(r.node, n)) {
          sourceName = catalog.sourcesData[r.sid]?.name;
          break;
        }
      }
    }
    return DockSummary(
      kind: profile != null
          ? DockKind.profile
          : source != null && source.kind == 'sub'
          ? DockKind.sub
          : source != null && source.kind == 'file'
          ? DockKind.file
          : DockKind.set,
      name: e.name,
      simpleMode: simple,
      auto: auto,
      node: _dockNode(n),
      sourceName: sourceName,
      latencyMs: ms(n),
    );
  }

  static DockNode? _dockNode(CatalogNode? n) {
    if (n == null) return null;
    final tls = n.outbound?['tls'];
    final reality =
        _truthy(n.unknown['reality']) ||
        (tls is Map && _truthy(tls['reality']));
    return DockNode(
      flag: n.flag,
      name: n.name,
      protocol: reality ? 'reality' : n.protocol,
    );
  }

  static bool _truthy(Object? v) =>
      v != null && v != false && v != 0 && v != '';

  // ───────────────────────────── connect / disconnect ─────────────────────────────

  @override
  Future<ConnectResult> toggleConnection() async {
    if (_connecting || _disconnecting) {
      return const ConnectResult(ConnectOutcome.busy);
    }
    if (isOn) {
      await disconnect();
      return const ConnectResult(ConnectOutcome.stopped);
    }
    return connect();
  }

  /// The connect in flight, from its first step (the VPN consent included) to its end.
  Future<ConnectResult>? _connectFlight;

  /// Idempotent (docs/core.md, "Подключение идемпотентно"): a call while a connect is in flight joins
  /// it (same result, one start of the core); a call while the VPN is on with the plan the catalog
  /// makes now does nothing. Several places ask for a connect at the app's start (the resume after
  /// an update, "Connect on launch", the tile) and none of them may restart the tunnel the other
  /// one is bringing up.
  @override
  Future<ConnectResult> connect() {
    if (!_ready || _disconnecting) {
      return Future.value(const ConnectResult(ConnectOutcome.busy));
    }
    return _connectFlight ??= _connectOnce().whenComplete(
      () => _connectFlight = null,
    );
  }

  /// The connect that is already on, with the plan the catalog makes now (`_planSig` is the one the
  /// core runs): nothing to send.
  bool get _alreadyConnected =>
      phase == ConnectionPhase.connected &&
      _planSig != null &&
      catalog.planSig() == _planSig;

  Future<ConnectResult> _connectOnce() async {
    if (_alreadyConnected) return const ConnectResult(ConnectOutcome.started);
    final check = catalog.checkBeforeConnect();
    if (check != null) {
      switch (check.code) {
        case 'nothingInAuto':
          return const ConnectResult(ConnectOutcome.nothingInAuto);
        case 'catalogEmpty':
          return const ConnectResult(ConnectOutcome.catalogEmpty);
        default:
          return _failed(check.message, check.code);
      }
    }
    if (isAndroid && vpn != null && !await vpn!.prepare()) {
      _notice(const HostNotice('vpnDenied', 'VPN permission was not granted'));
      return const ConnectResult(
        ConnectOutcome.vpnPermissionDenied,
        message: 'VPN permission was not granted',
      );
    }
    _connecting = true;
    _error = null;
    _notifyNow();
    try {
      final st = await _sendPlan();
      _journal('connect', {
        'action': 'connect',
        'entry': catalog.effectiveConnectId(),
      });
      final w = st['warning'];
      if (w is String && w.isNotEmpty) _notice(HostNotice('warning', w));
      if (_connected) unawaited(_pingRoute(catalog.liveAnchor));
      return const ConnectResult(ConnectOutcome.started);
    } catch (e) {
      final (msg, code) = _explain(e);
      _error = msg;
      await _refreshStatus();
      return _failed(msg, code);
    } finally {
      _connecting = false;
      _syncMode(); // a switch made while the plan was going over
      _notifyNow();
    }
  }

  /// Builds the plan and gives it to the core (a first connect and a reconnect alike); the
  /// plan the core now runs becomes the one a later change is compared with.
  Future<Map<String, dynamic>> _sendPlan() async {
    final plan = catalog.livePlan();
    final mode = _modeSigNow(); // as the plan was built: a switch during the await is told after it
    final kill = _killPlan();
    final st = await api.connect({
      'plan': plan,
      'systemProxy': !isAndroid && catalog.segState.systemProxy,
      'dnsAuto': catalog.dnsCfg.auto,
      ...kill,
    });
    _killSig = _killSigOf(kill);
    final routes = plan['routes'] as List;
    final current = (plan['current'] as num?)?.toInt() ?? 0;
    catalog.liveAnchor =
        (routes[current < 0 ? 0 : current] as Map)['id'] as String?;
    _planSig = catalog.planSigOf(plan);
    _autoSig = _autoSigOf();
    _modeSig = mode;
    _applyStatus(Map<String, dynamic>.from(st), notify: false);
    return st;
  }

  ConnectResult _failed(String msg, String? code) {
    _notice(HostNotice('connectFailed', msg));
    return ConnectResult(ConnectOutcome.failed, message: msg, code: code);
  }

  (String, String?) _explain(Object e) => switch (e) {
    TunNeedsAdmin() => (TunNeedsAdmin.message, 'tunNeedsAdmin'),
    CatalogException(:final message, :final code) => (message, code),
    SingBoxError(:final message) => (message, null),
    FormatException(:final message) => (message, null),
    _ => ('$e', null),
  };

  @override
  Future<void> disconnect() async {
    if (_disconnecting || !_ready) return;
    _disconnecting = true;
    _planSig = null;
    _autoSig = null;
    _modeSig = null;
    _reconnectTimer?.cancel();
    _error = null;
    _notifyNow();
    _journal('disconnect', {'action': 'disconnect'});
    try {
      _applyStatus(
        Map<String, dynamic>.from(await api.disconnect()),
        notify: false,
      );
      // the dock shows the answer of the direct check the core starts itself
      catalog.coreRoute = null;
    } catch (e) {
      _notice(HostNotice('connectFailed', '$e'));
      await _refreshStatus();
    } finally {
      _disconnecting = false;
      _notifyNow();
    }
  }

  @override
  Future<void> retry() async {
    try {
      _applyStatus(Map<String, dynamic>.from(await api.retry()));
    } catch (e) {
      _notice(HostNotice('connectFailed', '$e'));
    }
  }

  @override
  Future<void> releaseSysProxy() async {
    try {
      _applyStatus(Map<String, dynamic>.from(await api.releaseSysProxy()));
    } catch (e) {
      _notice(HostNotice('connectFailed', '$e'));
    }
  }

  @override
  Future<void> refreshExit() async {
    if (_connecting || !_ready) return;
    _exit = _exit.asRechecking;
    _notifyNow();
    try {
      _applyStatus(Map<String, dynamic>.from(await api.recheckExit()));
    } catch (_) {
      _exit = _exit.asFailed;
      _notifyNow();
    }
  }

  Future<void> _refreshStatus() async {
    try {
      _applyStatus(
        Map<String, dynamic>.from(await api.status()),
        notify: false,
      );
    } catch (_) {}
  }

  // ───────────────────────────── changes of the state ─────────────────────────────

  @override
  void setTun(bool on) {
    if (isAndroid || catalog.segState.tun == on) return;
    catalog.segState.mode = on ? 'tun' : 'proxy';
    _journal('mode', {'action': 'mode', 'value': catalog.segState.mode});
    changed();
  }

  @override
  void setGlobal(bool on) {
    if (catalog.segState.global == on) return;
    catalog.segState.route = on ? 'global' : 'rules';
    _journal('route', {'action': 'route', 'value': catalog.segState.route});
    changed();
  }

  @override
  void setSysProxy(bool on) {
    if (isAndroid || catalog.segState.systemProxy == on) return;
    catalog.segState.sys = on ? 'on' : 'off';
    catalog.connCfg.sysProxy = on;
    _journal('sysProxy', {'action': 'sysProxy', 'on': on});
    changed();
  }

  @override
  void setAutoMode(bool on) {
    if (catalog.autoConnect == on) return;
    catalog.setAutoConnect(on);
    changed();
  }

  // ── Route ──

  @override
  void selectConnect(String id) {
    catalog.selectConnect(id);
    changed();
  }

  @override
  void pinRouteNode(String id, String key) {
    final again =
        !catalog.autoConnect &&
        catalog.activeConnectId == id &&
        catalog.pinnedNode == key;
    catalog.pinRouteNode(id, key);
    _journal('pin', {
      'action': 'pin',
      'entry': id,
      'server': again ? null : key,
    });
    changed();
  }

  @override
  void setConnectMode(String mode) {
    if (mode == catalog.connectMode) return;
    catalog.setConnectMode(mode);
    changed();
  }

  @override
  void reorderRoute(List<String> shown) {
    catalog.reorderRoute(shown);
    changed();
  }

  @override
  void resetRouteOrder() {
    catalog.resetRouteOrder();
    changed();
  }

  @override
  void reorderPick(String id, List<String> shownKeys) {
    catalog.reorderUnitPick(id, shownKeys);
    changed();
  }

  // ── Logs and connections ──

  @override
  Map<String, dynamic> eventsPage({int? since}) => api.events(since: since);

  @override
  Map<String, dynamic> logPage({int? since, bool conns = true}) => api.log(since: since, conns: conns);

  @override
  Stream<Map<String, dynamic>> get logLines => api.logStream;

  @override
  void clearEvents() => api.clearEvents();

  @override
  Future<void> checkSite(int eventId) async {
    try {
      await api.siteCheck({'event': eventId});
    } catch (_) {
      // the event itself says it did not get an answer (or the core has no such event any more)
    }
  }

  @override
  void clearLog() => api.clearLog();

  @override
  void postEvent(
    String cat,
    String type,
    Map<String, dynamic> data, {
    String level = 'info',
    bool own = true,
  }) {
    if (!_ready) return;
    try {
      api.postEvent({
        'cat': cat,
        'type': type,
        'level': level,
        'own': own,
        'data': data,
      });
    } catch (_) {
      // a journal line must never fail an action
    }
  }

  @override
  void saveSoon() => _scheduleSave();

  @override
  Future<void> closeConnection([String? id]) async {
    await api.closeConnections(id);
    final was = traffic;
    final left = id == null
        ? <LiveConn>[]
        : [
            for (final c in was.conns)
              if (c.id != id) c,
          ];
    trafficNotifier.update(
      TrafficInfo(
        down: was.down,
        up: was.up,
        downTotal: was.downTotal,
        upTotal: was.upTotal,
        tcp: was.tcp,
        udp: was.udp,
        conns: left,
      ),
    );
  }

  /// Call after any edit of [catalog]: keeps it in step, saves it, tells the core what moved
  /// (Auto settings, kill switch) or reconnects when the plan is another one, and rebuilds
  /// the listeners.
  @override
  void changed() {
    if (_disposed) return;
    _dockCache = null;
    catalog.syncCatalog();
    _scheduleSave();
    _syncAuto();
    _syncUpdateSettings(); // before the mode: a route move reads closeOnSwitch
    _syncUpdateJob();
    _syncMode();
    _syncKill();
    _scheduleReconnect();
    _notifyNow();
  }

  // ── save ──

  bool _dirty = false;

  void _scheduleSave() {
    if (!_ready) return; // never write a state that was not loaded yet
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(_flushSave()));
  }

  Future<void> _flushSave() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_ready || !_dirty) return;
    _dirty = false;
    try {
      await api.saveState(catalog.toJson());
    } catch (e) {
      _dirty = true;
      _notice(HostNotice('notSaved', '$e', args: ['$e']));
    }
  }

  // ── live settings of a running connection ──

  String _autoSigOf() => '${catalog.planAuto()}';

  /// Settings -> Auto mode changed while connected: the core's Auto takes it at its next
  /// check, no reconnect (`liveSyncAuto`).
  void _syncAuto() {
    if (!_connected || _connecting || _planSig == null) return;
    final sig = _autoSigOf();
    if (sig == _autoSig) return;
    _autoSig = sig;
    api.autoSettings({'auto': catalog.planAuto()}).catchError((Object e) {
      _notice(HostNotice('connectFailed', '$e'));
      return <String, dynamic>{};
    });
  }

  /// What the core's Auto must be told of the mode: Manual and the entry it stands on, or Auto.
  String _modeSigNow() => catalog.autoConnect ? 'auto' : 'manual:${catalog.effectiveConnectId() ?? ''}';

  /// Auto <-> Manual (the badge, MANUAL on a row) while connected: the plan holds every Auto route
  /// in either mode, so it is the same plan and sing-box stays as it is; the core's Auto only
  /// stops / resumes moving between the routes, and in Manual goes to the entry picked (a switch of
  /// the selector `proxy`). An entry the plan has no route for is another plan: the reconnect
  /// ([_scheduleReconnect]) brings it.
  void _syncMode() {
    if (!_connected || _connecting || _reconnecting || _planSig == null) return;
    final sig = _modeSigNow();
    if (sig == _modeSig) return;
    _modeSig = sig;
    final manual = !catalog.autoConnect;
    api
        .autoSettings({
          'auto': catalog.planAuto(),
          'manual': manual,
          if (manual) 'entry': catalog.effectiveConnectId(),
        })
        .then(
          (st) => _applyStatus(Map<String, dynamic>.from(st)),
          onError: (Object e) => _notice(HostNotice('connectFailed', '$e')),
        );
  }

  // `genCfg` is a UI setting the catalog keeps untouched; the kill switch "while closed" counts
  // only with autostart + connect on launch (the mockup's `killClosedOk`)
  Map<String, dynamic> _killPlan() {
    final gen = catalog.unknown['genCfg'];
    final closedOk =
        gen is Map &&
        gen['launchAtStartup'] == true &&
        gen['connectOnLaunch'] == true;
    final c = catalog.connCfg;
    final kill = c.killSwitch;
    return {
      'killSwitch': kill,
      'killOnDisconnect': kill && c.killOnDisconnect,
      'killWhileClosed': kill && c.killWhileClosed && closedOk,
      'downProxy': c.downProxy,
    };
  }

  String _killSigOf(Map<String, dynamic> k) =>
      '${k['killSwitch']}|${k['killOnDisconnect']}|${k['killWhileClosed']}|${k['downProxy']}';
  String _killSigNow() => _killSigOf(_killPlan());

  void _syncKill() {
    final plan = _killPlan();
    final sig = _killSigOf(plan);
    if (sig == _killSig) return;
    _killSig = sig;
    if (_connected || _blocking != null) {
      api.killSwitchSettings(plan).catchError((Object e) {
        _notice(HostNotice('connectFailed', '$e'));
        return <String, dynamic>{};
      });
    }
  }

  // ── Settings tab ──

  @override
  DnsHealth? get dnsHealth => _dnsHealth;

  @override
  Future<DnsSidePing> pingDnsSides(String providerId, {bool poll = false}) async {
    if (_connected) {
      try {
        final r = await api.pingDnsSides({'provider': providerId, if (poll) 'poll': true});
        if (r['live'] == true) {
          return DnsSidePing(
            testing: r['testing'] == true,
            direct: r['direct'] as int?,
            vpn: r['vpn'] as int?,
            servers: {
              for (final s in (r['servers'] as List? ?? const []))
                if (s is Map && s['ms'] is int) '${s['id']}': s['ms'] as int,
            },
            races: DnsRace.parseAll(r['providers']),
          );
        }
      } catch (_) {
        // the core could not measure: the in-process direct ping below
      }
    }
    return super.pingDnsSides(providerId, poll: poll);
  }

  @override
  SpeedResult? get lastSpeed => _lastSpeed;

  @override
  bool get speedTesting => _speedSub != null;

  @override
  Map<String, dynamic> get speedProgress => _speedProgress;

  @override
  String? get speedError => _speedError;

  @override
  Future<void> toggleSpeedTest() async {
    if (_speedSub != null) {
      _endSpeedTest(); // a second tap: stops, nothing is kept
      return;
    }
    if (phase != ConnectionPhase.connected) return;
    _speedError = null;
    _speedProgress = const {'phase': 0};
    void fail(String why) {
      if (_speedSub == null) return;
      _speedSub = null;
      _speedError = why;
      _notifyNow();
    }

    _speedSub = api
        .speedTest({'current': true})
        .listen(
          (p) {
            if (_speedSub == null) return;
            _speedProgress = p;
            if (p['final'] != true) {
              _notify();
              return;
            }
            final err = p['error'];
            final down = p['down'];
            if (err != null || down is! num || down <= 0) {
              fail('${err ?? 'no result'}');
              return;
            }
            _speedSub = null;
            _lastSpeed = SpeedResult(
              downMbps: down / 1e6,
              upMbps: ((p['up'] as num?) ?? 0) / 1e6,
              latencyMs: (p['latency'] as num?)?.toInt() ?? 0,
              rpm: (p['downRpm'] as num?)?.toInt() ?? 0,
              at: DateTime.now(),
            );
            _notifyNow();
          },
          onError: (Object e) => fail('$e'),
          onDone: () => fail('the test ended without a result'),
        );
    _notifyNow();
  }

  void _endSpeedTest() {
    final s = _speedSub;
    if (s == null) return;
    _speedSub = null;
    unawaited(s.cancel());
    _notifyNow();
  }

  @override
  Future<Map<String, dynamic>> version() => api.version();

  // what the report knows only from the app and the phone (report_info.dart)
  Future<Map<String, dynamic>> _reportInfo() => ReportInfo(
        device: vpn?.deviceInfo,
        abis: vpn?.abis,
        libbox: vpn?.libboxVersion,
        vpnUp: vpn?.running,
        networkType: network?.type,
        metered: network?.metered,
      ).build(this, planSig: _planSig);

  @override
  Future<Map<String, dynamic>> report() async => api.report(appInfo: await _reportInfo());

  @override
  Future<Map<String, dynamic>> sendReport({String note = ''}) async {
    try {
      return await api.sendReport(note: note, appInfo: await _reportInfo());
    } catch (e) {
      return {'ok': false, 'error': 'failed', 'message': '$e'};
    }
  }

  @override
  Future<void> cancelSendReport() async {
    try {
      await api.cancelReport();
    } catch (_) {
      // nothing to stop, or the core is gone: the sheet has let go of the send anyway
    }
  }

  // ── Rules ──

  List<InstalledApp>? _apps;
  Map<String, InstalledApp> _appsByPkg = const {};
  final Map<String, Uint8List?> _icons = {};

  /// The names of installed apps for the catalog (the plan, the delete dialog, Rules).
  AppInfo? _appInfo(String pkg) {
    final a = _appsByPkg[pkg];
    return a == null ? null : (name: a.name, kind: 'package');
  }

  Future<List<InstalledApp>>? _appsLoad;

  @override
  Future<List<InstalledApp>> installedApps({bool refresh = false}) {
    final cached = _apps;
    if (cached != null && !refresh) return Future.value(cached);
    return _appsLoad ??= _loadApps().whenComplete(() => _appsLoad = null);
  }

  Future<List<InstalledApp>> _loadApps() async {
    if (!isAndroid) {
      // the desktop cannot list apps by package: nothing to show, nothing to cache for long
      return _apps = const <InstalledApp>[];
    }
    final List<AppEntry> got;
    try {
      got = await AppsIo.current.list();
    } catch (_) {
      return _apps ?? const <InstalledApp>[]; // the platform failed: what was known, asked again next time
    }
    final list = [
      for (final a in got)
        InstalledApp(pkg: a.pkg, name: a.name, system: a.system),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _apps = list;
    _appsByPkg = {for (final a in list) a.pkg: a};
    catalog.appInfo = _appInfo;
    _notify();
    return list;
  }

  @override
  Future<Uint8List?> appIcon(String pkg) async {
    if (_icons.containsKey(pkg)) return _icons[pkg];
    return _icons[pkg] = await AppsIo.current.icon(pkg);
  }

  @override
  Future<Map<String, int>> ruleSetTimes() async =>
      await ruleSetTimesOf?.call() ?? const {};

  @override
  Future<void> importState(Map<String, dynamic> snapshot) async {
    _saveTimer?.cancel();
    _dirty = false;
    await api.saveState(snapshot);
    final r = await api.state();
    final snap = r['snapshot'];
    catalog = Catalog.fromJson(
      snap is Map ? Map<String, dynamic>.from(snap) : snapshot,
    );
    catalog.appInfo = _appInfo;
    catalog.syncCatalog();
    catalog.purgeExpiredGone();
    if (isAndroid) {
      catalog.segState
        ..mode = 'tun'
        ..sys = 'off';
    }
    // a running connection takes the restored state (plan, Auto, kill switch)
    changed();
  }

  /// The app's update options (auto-check, channel, auto-download, whether the network is metered)
  /// go to the core's scheduled check; so do the list of ignored sites and Close connections on
  /// route switch (no reconnect for any).
  void _syncUpdateSettings() {
    if (_disposed) return;
    final g = gen;
    final ignored = notif.ignoredSites;
    final closeOnSwitch = catalog.connCfg.closeOnSwitch;
    final sig = '${g.updates}|${g.updChannel}|${g.updAutoDownload}|$_metered|${ignored.join(',')}|$closeOnSwitch';
    if (sig == _updSettingsSig) return;
    _updSettingsSig = sig;
    try {
      api.updateSettings({
        'autoCheck': g.updates,
        'channel': g.updChannel,
        'autoDownload': g.updAutoDownload,
        'metered': _metered,
        'ignoredSites': ignored,
        'closeOnSwitch': closeOnSwitch,
      });
    } catch (_) {}
  }

  /// What the background update check reads with no app running (auto-check, channel, auto-download,
  /// whether the update notifications may show, the language): mirrored natively on every change, which
  /// also schedules / cancels the job. Only a real change is sent.
  void _syncUpdateJob() {
    final job = updateJob;
    if (job == null || _disposed) return;
    final g = gen, n = notif;
    final s = UpdateJobSettings(
      autoCheck: g.updates,
      channel: g.updChannel,
      autoDownload: g.updAutoDownload,
      notify: n.enabled && n.flag('updateAvailable'),
      lang: g.lang,
    );
    if (s == _updJobSent) return;
    _updJobSent = s;
    unawaited(job.sync(s).catchError((_) {}));
  }

  UpdateJobSettings? _updJobSent;

  @override
  AppUpdate get appUpdate => _upd;

  @override
  bool get canInstallUpdate => installer != null;

  @override
  Future<void> checkUpdate() async {
    if (!_ready || _upd.busy || _upd.phase == UpdPhase.unavailable) return;
    try {
      _upd = AppUpdate.fromJson(
        await api.updateCheck({'channel': gen.updChannel, 'manual': true}),
      );
    } catch (e) {
      _notice(HostNotice('updateCheckFailed', '$e', args: ['$e']));
    }
    _notifyNow();
  }

  @override
  Future<void> downloadUpdate() async {
    if (!_ready || _upd.phase == UpdPhase.downloading) return;
    // the button is «Download & install»: the file goes to the installer once it is ready ([UpdateFlow])
    _installWanted = _upd.phase != UpdPhase.ready && installer != null;
    try {
      _upd = AppUpdate.fromJson(await api.updateDownload());
    } catch (e) {
      _notice(HostNotice('updateCheckFailed', '$e', args: ['$e']));
    }
    if (_upd.phase != UpdPhase.ready) _installWanted = false; // failed / cancelled: nothing to hand over
    _notifyNow();
  }

  @override
  void cancelUpdate() {
    _installWanted = false;
    if (_ready) api.updateCancel();
  }

  bool _installWanted = false;
  bool _installing = false;

  @override
  bool get updateInstallWanted => _installWanted;

  @override
  bool takeUpdateInstallWanted() {
    final w = _installWanted;
    _installWanted = false;
    return w;
  }

  @override
  bool get updateInstalling => _installing;

  @override
  Future<bool> installUpdate() async {
    final file = _upd.file, install = installer;
    if (!_ready || file == null || install == null || _installing) return false;
    _installWanted = false;
    _installing = true;
    _notifyNow();
    try {
      // the replacement ends this process: what the next start needs is written before it
      await _flushSave();
      try {
        await resume?.save(connected: isOn, entry: catalog.effectiveConnectId() ?? '');
      } catch (_) {}
      await api.updateBeginInstall();
      final ok = await install(file);
      if (!ok) await api.updateInstallFailed('the installer did not start');
      return ok;
    } finally {
      _installing = false;
      if (!_disposed) _notifyNow();
    }
  }

  @override
  Future<ResumeOutcome> resumeAfterUpdate() async {
    final port = resume;
    if (port == null || !_ready) return ResumeOutcome.none;
    final outcome = await _resumeAfterUpdate(port);
    // No logcat on the phone: the native decisions (and what this start made of them) go into the
    // app's log, so a VPN that did not come back after an update can be explained from there.
    final note = logNote;
    if (note != null) {
      try {
        for (final line in await port.trail()) {
          note('info', '[resume] $line');
        }
        note(outcome == ResumeOutcome.failed ? 'warn' : 'info', '[resume] Dart: ${outcome.name}');
      } catch (_) {}
    }
    return outcome;
  }

  Future<ResumeOutcome> _resumeAfterUpdate(ResumePort port) async {
    try {
      final rec = await port.take(); // consumed: a resume never runs twice
      if (rec == null) return ResumeOutcome.none;
      if (!rec.connected) return ResumeOutcome.notWanted;
      final age = _now().millisecondsSinceEpoch - rec.at;
      if (age < 0 || age > resumeWindow.inMilliseconds || rec.code == rec.fromCode) {
        return ResumeOutcome.stale;
      }
      if (_connected || _connecting || _disconnecting) return ResumeOutcome.alreadyOn;
      final r = await connect(); // the catalog's current entry: the one the record names
      if (r.outcome == ConnectOutcome.vpnPermissionDenied) {
        // the consent needs a window and there is none: the notification opens the app and connects
        await port.promptConnect();
        return ResumeOutcome.needsConsent;
      }
      return r.started ? ResumeOutcome.resumed : ResumeOutcome.failed;
    } catch (_) {
      return ResumeOutcome.failed;
    } finally {
      try {
        await port.done();
      } catch (_) {}
    }
  }

  // ── on launch ──

  /// What the General settings ask for when the app opens: "Connect on launch" and "Check
  /// servers on launch" (the top Auto entries and the targets of the rules).
  @override
  Future<void> runLaunchActions() async {
    if (!_ready) return;
    final g = gen;
    if (g.connectOnLaunch && !_connected && !catalog.catalogEmpty()) {
      unawaited(connect());
    }
    if (g.pingOnLaunch) {
      final nodes = _launchPingNodes();
      if (nodes.isNotEmpty) await pingNodes(nodes);
      // a chain's exits are measured through its entry, once the entries have answered
      await Future.wait([
        for (final ch in _launchChains()) pingChain(ch, entries: false),
      ]);
    }
  }

  /// The entries the launch ping looks at: the top Auto ones (+ the pinned one in Manual).
  Set<String> _launchIds() {
    final c = catalog;
    final top = [
      for (final id in c.visibleOrder())
        if (c.connectEntry(id)?.inAuto == true) id,
    ].take(1 + c.autoCfg.standby.toInt());
    return {if (!c.autoConnect) ?c.effectiveConnectId(), ...top};
  }

  /// The servers pinged directly: units' servers and chains' entries (never a chain's exits).
  List<CatalogNode> _launchPingNodes() {
    final refs = <NodeRef>[
      for (final id in _launchIds()) ..._entryRefs(id),
      for (final t in _ruleTargets()) ..._targetRefs(t),
    ];
    final seen = <String>{};
    return [
      for (final r in refs)
        if (seen.add(r.node.id)) r.node,
    ];
  }

  /// The chains among the launch entries and the rule / app targets: their exits get pair pings.
  List<Chain> _launchChains() {
    final ids = <String>{
      for (final id in _launchIds())
        if (catalog.chainsData.containsKey(id)) id,
      for (final t in _ruleTargets())
        if (t.startsWith('chain:') && catalog.chainsData.containsKey(t.substring(6))) t.substring(6),
    };
    return [for (final id in ids) catalog.chainsData[id]!];
  }

  /// What is pinged directly for an entry: a unit's servers, a chain's entry servers (its exits
  /// are measured through the entry: [pingChain]).
  List<NodeRef> _entryRefs(String id) {
    final chain = catalog.chainsData[id];
    return chain != null ? catalog.chainEntryRefs(chain) : catalog.unitRefs(id);
  }

  /// Targets of the enabled rules and the apps that go through a proxy entry.
  Set<String> _ruleTargets() => {
    for (final r in catalog.rulesData.values)
      if (r.enabled && r.action == 'proxy' && r.target.isNotEmpty) r.target,
    for (final a in catalog.appRules.values)
      for (final (_, h) in a.halves)
        if (h.act == 'proxy' && h.target.isNotEmpty) h.target,
  };

  /// The servers behind a rule target (`src:` / `node:` / `profile:` / `chain:` + id).
  List<NodeRef> _targetRefs(String t) {
    final at = t.indexOf(':');
    if (at < 0) return const [];
    final kind = t.substring(0, at), ref = t.substring(at + 1);
    switch (kind) {
      case 'src':
        final s = catalog.sourcesData[ref];
        return s != null && s.enabled
            ? [for (final n in catalog.liveNodes(s)) NodeRef(ref, n)]
            : const [];
      case 'node':
        final parts = ref.split('::');
        final s = parts.length == 2 ? catalog.sourcesData[parts[0]] : null;
        if (s == null || !s.enabled) return const [];
        return [
          for (final n in s.nodes)
            if (n.id == parts[1] && !catalog.isNodeDisabled(s, n.id))
              NodeRef(s.id, n),
        ];
      case 'profile':
        return catalog.profilesData.containsKey(ref)
            ? catalog.unitRefs(ref)
            : const [];
      default:
        return catalog.chainsData.containsKey(ref)
            ? _entryRefs(ref)
            : const [];
    }
  }

  // ── reconnect when the plan changed ──

  /// Connected and the plan is another one (another entry, a server switched off, Global /
  /// Rules, the system proxy...): the core gets the new config after 600 ms of quiet
  /// (`liveMaybeReconnect`). Building the plan to compare it is the costly part (the whole plan
  /// and its JSON), so it is done once, when the quiet is over ([_reconnect]), not on every
  /// change; a change put back meanwhile finds the same plan and does nothing. (A ping can move a
  /// rule target's Priority pick, so a ping run's end cannot skip the check.)
  void _scheduleReconnect() {
    if (!_ready || !_connected || _connecting || _planSig == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, _reconnect);
  }

  Future<void> _reconnect() async {
    if (_reconnecting || !_connected || _connecting || _planSig == null) return;
    // Manual on a server is strict: the pick was removed / switched off (a subscription update, an edit) — the connection
    // ends in an error naming it, the tunnel is not moved to another server
    final lost = catalog.pinLoss();
    if (lost != null) {
      _reconnecting = true;
      try {
        await disconnect();
        _error = lost;
        _notice(HostNotice('connectFailed', lost));
        _notifyNow();
      } finally {
        _reconnecting = false;
      }
      return;
    }
    final sig = catalog.planSig();
    if (sig == null || sig == _planSig) return;
    _reconnecting = true;
    try {
      await _sendPlan();
      _notifyNow();
    } catch (e) {
      final (msg, _) = _explain(e);
      _notice(HostNotice('reconnectFailed', msg));
      await _refreshStatus();
      _notifyNow();
    } finally {
      _reconnecting = false;
      _syncMode(); // a switch made while the plan was going over
    }
  }

  /// "Reconnect after update" off: servers a source update brought must not restart sing-box.
  /// The plan they make is taken as the running one, so the next reconnect for another reason
  /// brings them in (`liveKeepRunning`).
  void _keepRunningIfNoReload({Iterable<Source> updated = const []}) {
    if (!_connected || _planSig == null) return;
    final reload = updated.any((s) => s.unknown['reloadAfterUpdate'] == true);
    if (reload) return;
    final sig = catalog.planSig();
    if (sig != null) _planSig = sig;
  }

  // ───────────────────────────── catalog actions ─────────────────────────────

  @override
  bool isUpdating(String sid) => _updating.contains(sid);

  @override
  Future<AddSourceResult> addSubscription(
    String url, {
    String name = '',
    SubscriptionSettings? settings,
  }) async {
    final u = url.trim();
    if (u.isEmpty) return const AddSourceResult(AddSourceOutcome.emptyUrl);
    final id = 'src${catalog.sourceSeq++}';
    var host = 'New subscription';
    try {
      final h = Uri.parse(u).host;
      if (h.isNotEmpty) host = h;
    } catch (_) {}
    final given = name.trim();
    final shown = given.isNotEmpty ? given : host;
    final form = settings ?? const SubscriptionSettings();
    catalog.addSource(
      Source.fromJson({
        'id': id,
        'kind': 'sub',
        'name': shown,
        'enabled': true,
        'inAuto': true,
        'offNodes': <String>[],
        'disabledNodes': <String>[],
        'gone': <Object>[],
        'nodes': <Object>[],
        'count': 0,
        'url': u,
        'format': 'sing-box',
        'updatedAt': _now().millisecondsSinceEpoch,
        'usage': {'used': 0, 'total': 0},
        'expire': null,
        ...form.toJson(),
      }),
    );
    changed();
    _updating.add(id);
    _notifyNow();
    var loaded = false;
    try {
      await _fetchInto(id);
      final s = catalog.sourcesData[id];
      loaded = s != null;
      if (s != null) {
        s.unknown.remove('lastError');
        _journal('updated', {
          'source': id,
          'name': s.name,
          'added': s.nodes.length,
          'removed': 0,
          'total': s.nodes.length,
        }, cat: 'sub');
      }
      return AddSourceResult(AddSourceOutcome.added, name: s?.name ?? shown);
    } catch (e) {
      final s = catalog.sourcesData[id];
      final msg = e is FormatException ? e.message : '$e';
      s?.unknown['lastError'] = {
        'msg': msg,
        'at': _now().millisecondsSinceEpoch,
      };
      _notice(
        HostNotice(
          'subFailed',
          'Could not load $shown: $msg',
          args: [shown, msg],
        ),
      );
      _journal(
        'failed',
        {'source': id, 'name': shown, 'error': msg},
        cat: 'sub',
        level: 'error',
      );
      return AddSourceResult(AddSourceOutcome.failed, name: shown, error: msg);
    } finally {
      _updating.remove(id);
      final s = catalog.sourcesData[id];
      if (s != null) s.count = s.nodes.length;
      changed();
      if (loaded && s != null && s.unknown['testAfterUpdate'] != false) {
        unawaited(_pingNodes(catalog.liveNodes(s)));
      }
    }
  }

  /// Asks the core to fetch source [sid] with its own settings and applies the patch of the
  /// fields the core owns onto the source as it is *now* (`liveFetch`): what the user changed
  /// while the fetch ran stays, and a source deleted meanwhile stays deleted. Throws what the
  /// fetch threw. The caller pings the new servers.
  Future<void> _fetchInto(String sid, {bool rediscover = false}) async {
    final before = catalog.sourcesData[sid];
    if (before == null) return;
    final sent = before.toJson();
    final r = await api.fetchSource({
      'sid': sid,
      'source': {
        for (final k in const [
          'url',
          'userAgent',
          'uaStrategy',
          'discoveredAt',
          'nodes',
          'gone',
          'hwid',
          'filter',
          'channel',
        ])
          k: sent[k],
      },
      'rediscover': rediscover,
    });
    final cur = catalog.sourcesData[sid];
    if (cur == null) return;
    final patch = r['patch'];
    final next = Source.fromJson({
      ...cur.toJson(),
      if (patch is Map) ...Map<String, dynamic>.from(patch),
    });
    final title = r['title'];
    var host = '';
    try {
      host = Uri.parse(next.url ?? '').host;
    } catch (_) {}
    if (title is String && title.isNotEmpty && next.name == host) {
      next.name = title;
    }
    catalog.sourcesData[sid] = next;
    catalog.syncCatalog();
    if (r['notModified'] != true) _keepRunningIfNoReload(updated: [next]);
  }

  @override
  Future<ImportFileResult> importConfigFile(
    String fileName,
    String text,
  ) async {
    final Map<String, dynamic> r;
    try {
      r = api.addSourceFromText({'name': fileName, 'text': text});
    } on FormatException catch (e) {
      return ImportFileResult.failed(e.message);
    } catch (e) {
      return ImportFileResult.failed('$e');
    }
    // the core gives the source without an id: the catalog owner allocates it
    final id = 'src${catalog.sourceSeq++}';
    final s = Source.fromJson({
      ...Map<String, dynamic>.from(r['source'] as Map),
      'id': id,
    });
    s.count = s.nodes.length;
    catalog.addSource(s);
    changed();
    return ImportFileResult.added(id, s.name, s.nodes.length);
  }

  @override
  Future<void> updateSource(String sid, {bool rediscover = false}) async {
    final s = catalog.sourcesData[sid];
    if (s == null || s.kind != 'sub' || _updating.contains(sid) || !_ready) {
      return;
    }
    _updating.add(sid);
    _notifyNow();
    final before = {for (final n in s.nodes) n.id};
    final gone0 = s.gone.length;
    var ok = false;
    try {
      await _fetchInto(sid, rediscover: rediscover);
      final cur = catalog.sourcesData[sid];
      if (cur != null) {
        cur.count = cur.nodes.length;
        cur.unknown.remove('lastError');
      }
      ok = cur != null;
    } catch (e) {
      final cur = catalog.sourcesData[sid];
      final msg = e is FormatException ? e.message : '$e';
      final shown = cur?.name ?? s.name;
      cur?.unknown['lastError'] = {
        'msg': msg,
        'at': _now().millisecondsSinceEpoch,
      };
      _notice(
        HostNotice(
          'updateFailed',
          'Update of $shown failed: $msg',
          args: [shown, msg],
        ),
      );
      _journal(
        'failed',
        {'source': sid, 'name': shown, 'error': msg},
        cat: 'sub',
        level: 'error',
      );
    } finally {
      _updating.remove(sid);
      catalog.purgeExpiredGone();
      final cur = catalog.sourcesData[sid];
      if (ok && cur != null) _subResultEvents(cur, before, gone0);
      changed();
      if (ok && cur != null && cur.unknown['testAfterUpdate'] != false) {
        unawaited(_pingNodes(catalog.liveNodes(cur)));
      }
    }
  }

  /// The events of a finished update: updated (new / removed servers, total), and the provider
  /// removing servers or bringing them back (`subResultEvents`).
  void _subResultEvents(Source s, Set<String> before, int gone0) {
    final now = {for (final n in s.nodes) n.id};
    final data = {'source': s.id, 'name': s.name};
    _journal('updated', {
      'added': now.difference(before).length,
      'removed': before.difference(now).length,
      'total': s.nodes.length,
      ...data,
    }, cat: 'sub');
    final g = s.gone.length;
    if (g > gone0) {
      _journal(
        'removed',
        {'count': g - gone0, ...data},
        cat: 'sub',
        level: 'warn',
      );
    } else if (g < gone0) {
      _journal('back', {'count': gone0 - g, ...data}, cat: 'sub');
    }
  }

  @override
  Future<void> updateAll() => Future.wait([
    for (final sid in [...catalog.sourceOrder])
      if (catalog.sourcesData[sid]?.enabled == true) updateSource(sid),
  ]);

  @override
  void saveSource(
    String sid, {
    String name = '',
    String? url,
    SubscriptionSettings? settings,
  }) {
    final s = catalog.sourcesData[sid];
    if (s == null) return;
    final given = name.trim();
    if (given.isNotEmpty) s.name = given;
    var refetch = false, rediscover = false;
    final u = url?.trim() ?? '';
    if (s.kind == 'sub' && settings != null && u.isNotEmpty) {
      // Another address, User-Agent or HWID can mean another server list: forget the UA
      // strategy and its ETags and ask again with every UA. A new filter needs a full read.
      // Either way the list is fetched now (`saveSrcForm`).
      final was = SubscriptionSettings.of(s);
      rediscover =
          s.url != u ||
          was.userAgent != settings.userAgent ||
          was.hwid != settings.hwid;
      refetch = rediscover || was.filter != settings.filter;
      s.url = u;
      s.unknown.addAll(settings.toJson());
      if (rediscover) {
        s.unknown['uaStrategy'] = <Object>[];
        s.unknown['discoveredAt'] = 0;
      }
    }
    changed();
    if (refetch) unawaited(updateSource(sid, rediscover: rediscover));
  }

  @override
  void toggleSourceEnabled(String sid) {
    catalog.toggleSourceEnabled(sid);
    changed();
  }

  @override
  void toggleNodeEnabled(String sid, String nid) {
    catalog.toggleNodeEnabled(sid, nid);
    changed();
  }

  @override
  void reorderCatalog(String tab, List<String> order) {
    catalog.reorderCatalog(tab, order);
    changed();
  }

  @override
  void deleteSource(String sid) {
    catalog.deleteSource(sid);
    _updating.remove(sid);
    changed();
  }

  @override
  void deleteNode(String sid, String nid) {
    catalog.deleteNode(sid, nid);
    changed();
  }

  @override
  void deleteEntry(String id) {
    if (catalog.profilesData.containsKey(id)) {
      catalog.deleteProfile(id);
    } else {
      catalog.deleteChain(id);
    }
    changed();
  }

  @override
  int forgetGone(String sid, [List<String>? only]) {
    final n = catalog.forgetGone(sid, only);
    changed();
    return n;
  }

  @override
  void toggleChainNode(String id, String side, String key) {
    final c = catalog.chainsData[id];
    if (c == null) return;
    catalog.chainToggleNode(c, side, key);
    changed();
  }

  @override
  void setSourceOffNodes(String sid, List<String> off) {
    final s = catalog.sourcesData[sid];
    if (s == null) return;
    s.offNodes = [...off];
    changed();
  }

  @override
  void setPickMode(String id, String mode) {
    catalog.setEntryPickMode(id, mode);
    changed();
  }

  @override
  void setPickOrder(String id, List<String> order) {
    catalog.setEntryPickOrder(id, order);
    changed();
  }

  @override
  void setEntryInAuto(String id, bool on) {
    final e = catalog.connectEntry(id);
    if (e == null || e.inAuto == on) return;
    e.inAuto = on;
    changed();
    // the tunnel is not dropped under the user: it stays on its server until they disconnect
    if (!on && _connected && catalog.nothingInAuto()) {
      _notice(
        const HostNotice(
          'nothingInAuto',
          'Nothing left in Auto — the connection stays until you disconnect',
        ),
      );
    }
  }

  @override
  String? saveProfile(ProfileDraft d) {
    final err = catalog.saveProfile(
      Profile(
        id: d.id ?? 'draft',
        name: d.name,
        sources: [...d.sources],
        nodes: [...d.nodes],
        inAuto: d.inAuto,
        pickMode: d.pickMode,
        pickOrder: [...d.pickOrder],
      ),
      editId: d.id,
    );
    if (err == null) changed();
    return err;
  }

  @override
  String? saveChain(ChainDraft d) {
    final err = catalog.saveChain(
      Chain(
        id: d.id ?? 'draft',
        name: d.name,
        inId: d.inId,
        outId: d.outId,
        inOff: [...d.inOff],
        outOff: [...d.outOff],
        inOn: [...d.inOn],
        outOn: [...d.outOn],
        exitMode: d.exitMode,
        exitOrder: [...d.exitOrder],
        inAuto: d.inAuto,
      ),
      editId: d.id,
      mode: d.mode,
    );
    if (err == null) changed();
    return err;
  }

  @override
  String get nodeSort {
    final g = catalog.unknown['genCfg'];
    final v = g is Map ? g['nodeSort'] : null;
    return v == 'latency' || v == 'name' ? v as String : 'order';
  }

  @override
  void setNodeSort(String sort) {
    final g = catalog.unknown['genCfg'];
    if (g is Map) {
      g['nodeSort'] = sort;
    } else {
      catalog.unknown['genCfg'] = <String, dynamic>{'nodeSort': sort};
    }
    changed();
  }

  // ── ping ──

  @override
  Future<void> pingNodes(Iterable<CatalogNode> nodes) =>
      _pingNodes(nodes.toList());

  @override
  Future<void> pingSource(String sid) {
    final s = catalog.sourcesData[sid];
    return s == null ? Future.value() : _pingNodes(catalog.liveNodes(s));
  }

  /// Every enabled source, servers taken in turn from each (1st of each, 2nd of each ...), so
  /// all the sets fill in together instead of one after another.
  @override
  Future<void> pingAll() {
    final lists = [
      for (final sid in catalog.sourceOrder)
        if (catalog.sourcesData[sid]?.enabled == true)
          catalog.liveNodes(catalog.sourcesData[sid]!),
    ];
    final nodes = <CatalogNode>[];
    for (var i = 0; lists.any((l) => i < l.length); i++) {
      for (final l in lists) {
        if (i < l.length) nodes.add(l[i]);
      }
    }
    return _pingNodes(nodes);
  }

  @override
  Future<void> pingEntry(String id) {
    final c = catalog.chainsData[id];
    if (c != null) return pingChain(c);
    return _pingNodes([for (final r in catalog.unitRefs(id)) r.node]);
  }

  @override
  Future<void> pingChain(
    Chain c, {
    Iterable<CatalogNode>? exits,
    bool entries = true,
  }) async {
    final ins = [for (final r in catalog.chainEntryRefs(c)) r.node];
    final outs = exits?.toList() ?? [for (final r in catalog.chainExitRefs(c)) r.node];
    final known = catalog.chainEntryNode(c);
    if (entries || known == null) {
      if (known == null || ins.isEmpty) {
        await _pingNodes(ins);
      } else {
        // the entry in use is known: the exits go through it while the entries are measured
        await Future.wait([_pingNodes(ins), _pingPairsInto(known, outs)]);
        // the entries' answers may have moved the entry in use: measure through the new one too
        final now = catalog.chainEntryNode(c);
        if (now != null && !identical(now, known)) await _pingPairsInto(now, outs);
        return;
      }
    }
    final entry = catalog.chainEntryNode(c);
    if (entry != null) await _pingPairsInto(entry, outs);
  }

  DockPingRun? _dockRun;

  @override
  bool get dockPinging => _dockRun != null;

  @override
  Future<void> toggleDockPing() async {
    final cur = _dockRun;
    if (cur != null) {
      // the batch in flight still reports; no new one goes out
      cur.stop();
      _dockRun = null;
      _notifyNow();
      return;
    }
    if (!_ready) return;
    final run = _dockRun = DockPingRun(catalog, _measureDock);
    _notifyNow();
    try {
      await run.run();
    } finally {
      if (identical(_dockRun, run)) {
        _dockRun = null;
        _notifyNow();
      }
    }
  }

  /// One batch of the dock ping: servers directly, a chain's exits as pairs through its entry
  /// (after the direct pings when the chain has no entry in use yet: its entries may be among them).
  Future<void> _measureDock(List<DockPingItem> batch) {
    final direct = pingNodes([
      for (final i in batch)
        if (i.chain == null) i.node,
    ]);
    final exits = <String, (Chain, List<CatalogNode>)>{};
    for (final i in batch) {
      final c = i.chain;
      if (c != null) exits.putIfAbsent(c.id, () => (c, <CatalogNode>[])).$2.add(i.node);
    }
    return Future.wait([
      direct,
      for (final (c, xs) in exits.values)
        () async {
          if (catalog.chainEntryNode(c) == null) await direct;
          await pingChain(c, exits: xs, entries: false);
        }(),
    ]);
  }

  /// [exits] through [entry], results into the pair book as they come (`pingChain`).
  Future<void> _pingPairsInto(CatalogNode entry, List<CatalogNode> exits) async {
    // a server never pairs with itself
    final to = [
      for (final x in exits)
        if (PingBook.serverKey(x) != PingBook.serverKey(entry)) x,
    ];
    if (to.isEmpty || entry.outbound == null || !entry.usable) return;
    final pairs = catalog.pairs;
    final book = catalog.pings;
    for (final x in to.where((x) => x.outbound == null || !x.usable)) {
      pairs.set(entry, x, -1, book.now);
    }
    final ok = to.where((x) => x.outbound != null && x.usable).toList();
    if (ok.isEmpty) {
      changed();
      return;
    }
    pairs.markTesting(entry, ok);
    _notifyNow();
    final left = {...ok};
    var error = false;
    try {
      await for (final l in api.ping(_pairRequest(entry, ok))) {
        if (l['error'] != null) error = true;
        final i = int.tryParse('${l['key']}'), ms = l['ms'];
        if (l['kind'] != 'p' || i == null || i < 0 || i >= ok.length || ms is! num) continue;
        if (left.remove(ok[i])) pairs.set(entry, ok[i], ms, book.now, byChecker: l['byChecker'] == true);
        _notify();
      }
    } catch (_) {
      error = true;
    }
    for (final x in left) {
      // the tester could not run: nothing was measured, the old value stays
      error ? pairs.unmarkTesting(entry, [x]) : pairs.set(entry, x, -1, book.now);
    }
    changed();
  }

  Map<String, dynamic> _pairRequest(CatalogNode entry, List<CatalogNode> exits) => {
    'pairs': [
      for (var i = 0; i < exits.length; i++)
        {
          'key': '$i',
          'entry': {'outbound': entry.outbound},
          'exit': {'outbound': exits[i].outbound},
        },
    ],
    if (catalog.connCfg.testUrl.isNotEmpty) 'url': catalog.connCfg.testUrl,
    'checkers': catalog.connCfg.checkers,
  };

  @override
  Future<List<PairAnswer>> pingPairs(CatalogNode entry, List<CatalogNode> exits) async {
    final res = List<PairAnswer>.filled(exits.length, const PairAnswer(-1));
    final at = [
      for (var i = 0; i < exits.length; i++)
        if (exits[i].outbound != null && exits[i].usable) i,
    ];
    if (entry.outbound == null || !entry.usable || at.isEmpty) return res;
    try {
      final req = _pairRequest(entry, [for (final i in at) exits[i]]);
      await for (final l in api.ping(req)) {
        final k = int.tryParse('${l['key']}'), ms = l['ms'];
        if (l['kind'] != 'p' || k == null || k < 0 || k >= at.length || ms is! num) continue;
        res[at[k]] = PairAnswer(ms.round(), weak: ms >= 0 && l['byChecker'] == true);
      }
    } catch (_) {
      // the tester could not run: no verdict, not "every pair is dead" (see [CoreHost.pingPairs])
      return const [];
    }
    return res;
  }

  // ── share, speed test, manual servers ──

  @override
  String? shareLink(CatalogNode n) {
    if (n.outbound == null) return null;
    try {
      return api.share({
        'outbound': n.outbound,
        'name': n.name,
        'flag': n.flag == '🌐' ? '' : n.flag,
        'unsupported': n.unsupported,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<Map<String, dynamic>> speedTest(CatalogNode n) {
    if (n.outbound == null || !n.usable) {
      return Stream.error(
        const FormatException(
          'This server cannot be tested (no sing-box outbound)',
        ),
      );
    }
    return api.speedTest({
      'node': {'key': n.id, 'outbound': n.outbound},
    });
  }

  @override
  List<CatalogNode> parseLinks(String text) {
    try {
      final r = api.parse({'text': text});
      return [
        for (final n in (r['nodes'] as List? ?? const []))
          CatalogNode.fromJson(Map<String, dynamic>.from(n as Map)),
      ];
    } catch (_) {
      return [];
    }
  }

  static const _linkForms =
      'No server link recognised (vless://, vmess://, trojan://, ss://, hy2://, tuic://, anytls://, socks://)';

  /// The servers a manual form makes: the links' (the core's parser), or the one the fields
  /// describe (`backend.manualNodes`). An edit of the same protocol keeps the server's TLS /
  /// transport (manual.dart).
  List<CatalogNode> _formNodes(NodeFormInput f, CatalogNode? edit) {
    final link = f.link.trim();
    if (link.isNotEmpty) {
      final r = api.parse({'text': link});
      final nodes = [
        for (final n in (r['nodes'] as List? ?? const []))
          CatalogNode.fromJson(Map<String, dynamic>.from(n as Map)),
      ];
      if (nodes.isEmpty) throw const FormatException(_linkForms);
      if (nodes.length == 1) nodes[0] = _typedName(nodes[0], f);
      return edit != null ? nodes.sublist(0, 1) : nodes;
    }
    final same = edit != null && edit.protocol == f.protocol;
    final name = f.name.isNotEmpty ? f.name : f.address;
    final node = api.manualNode({
      'protocol': f.protocol,
      'address': f.address,
      'port': f.port,
      'secret': f.secret,
      // no flag typed: an edited server keeps its own
      'name': edit != null && edit.flag != '🌐' && splitFlag(name).$1 == '🌐'
          ? '${edit.flag} $name'
          : name,
      'outbound': same ? edit.outbound : null,
      'unsupported': same ? edit.unsupported : null,
    });
    return [CatalogNode.fromJson(node.toJson())];
  }

  /// The form's name when typed by hand (or with no link to name the server): a flag in it goes
  /// to the server's flag like the core does; without one the server keeps its flag
  /// (`typedName`).
  static CatalogNode _typedName(CatalogNode n, NodeFormInput f) {
    if (f.name.isEmpty || (f.link.trim().isNotEmpty && !f.nameTouched)) {
      return n;
    }
    final (flag, clean) = splitFlag(f.name);
    return CatalogNode.fromJson({
      ...n.toJson(),
      'name': clean,
      if (flag != '🌐') 'flag': flag,
    });
  }

  @override
  Future<SaveNodeResult> saveManualNode(NodeFormInput input) async {
    final f = NodeFormInput(
      link: input.link.trim(),
      protocol: input.protocol,
      address: input.address.trim().replaceAll(RegExp(r'^\[|\]$'), ''),
      port: input.port.trim().isEmpty ? '443' : input.port.trim(),
      secret: input.secret.trim(),
      name: input.name.trim(),
      nameTouched: input.nameTouched,
      editSid: input.editSid,
      editNid: input.editNid,
      group: input.group,
    );
    // a link carries its own address (vmess base64, legacy ss, IPv6: the core reads them)
    if (f.link.isEmpty && f.address.isEmpty) {
      return const SaveNodeResult(
        SaveNodeOutcome.failed,
        error: 'Address is required',
      );
    }
    final editSource = f.editSid == null
        ? null
        : catalog.sourcesData[f.editSid];
    CatalogNode? edit;
    if (editSource != null && f.editNid != null) {
      for (final n in editSource.nodes) {
        if (n.id == f.editNid) edit = n;
      }
    }
    final List<CatalogNode> nodes;
    try {
      nodes = _formNodes(f, edit);
    } catch (e) {
      return SaveNodeResult(
        SaveNodeOutcome.failed,
        error: e is FormatException ? e.message : '$e',
      );
    }
    if (edit != null) {
      // the id stays: profiles, chains and pins that name the server keep it
      final at = editSource!.nodes.indexOf(edit);
      editSource.nodes[at] = CatalogNode.fromJson({
        ...nodes[0].toJson(),
        'id': edit.id,
      });
      changed();
      return const SaveNodeResult(SaveNodeOutcome.edited, added: 1);
    }
    // the same server twice gets the same id: once per group
    var group = catalog.sourcesData[f.group];
    final have = <String>{
      if (group != null && group.kind == 'node')
        ...group.nodes.map((n) => n.id),
    };
    final fresh = [
      for (final n in nodes)
        if (have.add(n.id)) n,
    ];
    final dup = nodes.length - fresh.length;
    if (fresh.isEmpty) {
      return SaveNodeResult(SaveNodeOutcome.duplicate, duplicates: dup);
    }
    if (group == null || group.kind != 'node') {
      final manual = catalog.sourcesData.values
          .where((s) => s.kind == 'node')
          .length;
      group = Source(
        id: 'src${catalog.sourceSeq++}',
        kind: 'node',
        name: 'Manual ${manual + 1}',
      );
      catalog.addSource(group);
    }
    group.nodes.addAll(fresh);
    group.count = group.nodes.length;
    changed();
    return SaveNodeResult(
      SaveNodeOutcome.added,
      added: fresh.length,
      duplicates: dup,
    );
  }

  /// Latency of [nodes] by the core, results into the ping book as they come (`backend.ping`).
  Future<void> _pingNodes(List<CatalogNode> nodes) async {
    // a node the core cannot test (no outbound, unusable) is never probed: it stays "not checked", not dead
    // (dead is a verdict of a probe, docs/connect-model.md → Ping)
    final ok = <CatalogNode>[
      for (final n in nodes)
        if (n.outbound != null && n.usable) n,
    ];
    // a node already being pinged is not pinged a second time at once: the run in flight brings its answer,
    // and this call returns when that run has (so a caller that reads the answers afterwards sees them)
    final fresh = [
      for (final n in ok)
        if (catalog.pings.entry(n)?.testing != true) n,
    ];
    final waitFor = fresh.length == ok.length ? const <Future<void>>[] : _pingRuns.toList();
    if (fresh.isNotEmpty) {
      final run = _pingRun(fresh);
      _pingRuns.add(run);
      try {
        await run;
      } finally {
        _pingRuns.remove(run);
      }
    }
    if (waitFor.isNotEmpty) await Future.wait(waitFor);
  }

  /// The ping runs in flight ([_pingNodes]).
  final _pingRuns = <Future<void>>{};

  /// After a connect: the servers of the subscriptions the route is made of are measured in the
  /// background, the route's own top first (`routePingOrder`); a chain's exits as pairs through the
  /// entry in use. Rows show "pinging" meanwhile, the connection does not wait for it.
  Future<void> _pingRoute(String? routeId) async {
    if (routeId == null || !_ready) return;
    await _pingNodes(catalog.routePingOrder(routeId));
    final c = catalog.chainsData[routeId];
    if (c != null && _connected) await pingChain(c, entries: false);
  }

  Future<void> _pingRun(List<CatalogNode> ok) async {
    catalog.pings.markTesting(ok);
    _notifyNow(); // the rows show "pinging" now, the answers follow joined by [_notify]
    final left = {...ok};
    var error = false;
    try {
      // an answer carries the server's id: the servers with it, by a map (not a scan per answer)
      final byId = <String, List<CatalogNode>>{};
      for (final n in ok) {
        (byId[n.id] ??= []).add(n);
      }
      await for (final l in api.ping({
        'nodes': [
          for (final g in byId.values)
            {'key': g.last.id, 'outbound': g.last.outbound},
        ],
        if (catalog.connCfg.testUrl.isNotEmpty) 'url': catalog.connCfg.testUrl,
        'checkers': catalog.connCfg.checkers,
      })) {
        if (l['error'] != null) error = true;
        if (l['kind'] != 'n') continue;
        final ms = l['ms'];
        if (ms is! num) continue;
        for (final n in byId[l['key']] ?? const <CatalogNode>[]) {
          if (left.remove(n)) catalog.pings.set(n, ms, byChecker: l['byChecker'] == true);
        }
        _notify();
      }
    } catch (_) {
      error = true;
    }
    for (final n in left) {
      // the tester could not run (no sing-box): nothing was measured, the old value stays
      error ? catalog.pings.unmarkTesting([n]) : catalog.pings.set(n, -1);
    }
    changed();
  }

  // ───────────────────────────── journal ─────────────────────────────

  /// The user's own action into the core's Events journal (`journal('user', ...)`).
  void _journal(
    String type,
    Map<String, dynamic> data, {
    String cat = 'user',
    String level = 'info',
  }) {
    if (!_ready) return;
    try {
      api.postEvent({
        'cat': cat,
        'type': type,
        'level': level,
        'own': true,
        'data': data,
      });
    } catch (_) {
      // a journal line must never fail an action
    }
  }
}
