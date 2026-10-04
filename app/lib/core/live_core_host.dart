import 'dart:async';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';

import '../platform/vpn_channel.dart';
import 'app_update.dart';
import 'core_host.dart';
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
    this.installer,
    this.ruleSetTimesOf,
    this.saveDelay = const Duration(milliseconds: 400),
    this.reconnectDelay = const Duration(milliseconds: 600),
    this.trafficEvery = const Duration(seconds: 1),
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

  /// Hands a downloaded update file to the platform's installer (Android: PackageInstaller);
  /// null where that side is not written, then [canInstallUpdate] is false.
  final Future<bool> Function(String file)? installer;

  /// When the rule-set lists were downloaded (the core's rule-set cache), by name; null = unknown.
  final Future<Map<String, int>> Function()? ruleSetTimesOf;

  final Duration saveDelay;
  final Duration reconnectDelay;
  final Duration trafficEvery;
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
  TrafficInfo _traffic = TrafficInfo.zero;
  DnsHealth? _dnsHealth;
  double? _lastSpeedMbps;
  AppUpdate _upd = const AppUpdate();
  StreamSubscription<Map<String, dynamic>>? _updSub;
  String? _updSettingsSig;
  Object? _sourcesRev;

  // the plan the core runs (null = none): what a reconnect is compared with
  String? _planSig;
  String? _autoSig;
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
      }
      final st = r['status'];
      if (st is Map) {
        _sourcesRev = st['sourcesRev'];
        _applyStatus(Map<String, dynamic>.from(st), notify: false);
      }
      _killSig = _killSigNow();
      _statusSub = api.statusChanges.listen(_onStatus, onError: (_) {});
      _eventSub = api.eventStream.listen(_events.add, onError: (_) {});
      _upd = AppUpdate.fromJson(api.updateStatus());
      _updSub = api.updateChanges.listen((s) {
        _upd = AppUpdate.fromJson(s);
        _notify();
      }, onError: (_) {});
      _syncUpdateSettings();
      _ready = true;
    } catch (e) {
      _initError = '$e';
      _notice(HostNotice('initFailed', '$e', args: ['$e']));
    }
    _notify();
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
    _statusSub = _eventSub = _updSub = null;
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
    _statusSub?.cancel();
    _eventSub?.cancel();
    _updSub?.cancel();
    _events.close();
    _notices.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
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
    _connected = st['connected'] == true;
    final auto = _connected && st['auto'] is Map ? st['auto'] as Map : null;
    catalog.coreRoute = auto == null || auto['now'] == null
        ? null
        : CoreRoute(
            id: '${auto['now']}',
            server: auto['server'] as String?,
            entryServer: auto['entryServer'] as String?,
          );
    final members = auto?['members'];
    if (members is List) {
      catalog.pings.mergeCore(members.whereType<Map>(), catalog.nodeOfKey);
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
    } else if (e['error'] != null) {
      _exit = const ExitState.error();
    } else {
      _exit = ExitState.found(
        ip: '${e['ip'] ?? ''}',
        country: e['country'] as String?,
        city: e['city'] as String?,
      );
    }
    if (st['error'] != null) _error = '${st['error']}';
    final dns = st['dns'];
    _dnsHealth = _connected && dns is Map && dns['active'] != null
        ? DnsHealth(
            active: '${dns['active']}',
            failed: {
              for (final s in (dns['servers'] as List? ?? const []))
                if (s is Map && s['ok'] == false) '${s['id']}',
            },
          )
        : null;
    _syncTrafficTimer();
    if (notify) _notify();
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
      _traffic = TrafficInfo(
        downTotal: _traffic.downTotal,
        upTotal: _traffic.upTotal,
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
      // moved total, which is exactly what the speed cards already notify on
      final same =
          next.down == _traffic.down &&
          next.up == _traffic.up &&
          next.downTotal == _traffic.downTotal &&
          next.tcp == _traffic.tcp &&
          next.udp == _traffic.udp &&
          next.conns.length == _traffic.conns.length;
      _traffic = next;
      if (!same) _notify();
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
  TrafficInfo get traffic => _traffic;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<HostNotice> get notices => _notices.stream;

  /// What the dock row shows (mockup `updateMainConnectCard`).
  @override
  DockSummary get dock {
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
      final ma = ms(a), mb = ms(b);
      return DockSummary(
        kind: DockKind.chain,
        name: e.name,
        simpleMode: simple,
        auto: auto,
        entryNode: _dockNode(a),
        node: _dockNode(b),
        latencyMs: ma != null && mb != null ? ma + mb : null,
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

  @override
  Future<ConnectResult> connect() async {
    if (!_ready || _connecting || _disconnecting) {
      return const ConnectResult(ConnectOutcome.busy);
    }
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
    _notify();
    try {
      final st = await _sendPlan();
      _journal('connect', {
        'action': 'connect',
        'entry': catalog.effectiveConnectId(),
      });
      final w = st['warning'];
      if (w is String && w.isNotEmpty) _notice(HostNotice('warning', w));
      return const ConnectResult(ConnectOutcome.started);
    } catch (e) {
      final (msg, code) = _explain(e);
      _error = msg;
      await _refreshStatus();
      return _failed(msg, code);
    } finally {
      _connecting = false;
      _notify();
    }
  }

  /// Builds the plan and gives it to the core (a first connect and a reconnect alike); the
  /// plan the core now runs becomes the one a later change is compared with.
  Future<Map<String, dynamic>> _sendPlan() async {
    final plan = catalog.livePlan();
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
    _reconnectTimer?.cancel();
    _error = null;
    _notify();
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
      _notify();
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
    _exit = const ExitState.checking();
    _notify();
    try {
      _applyStatus(Map<String, dynamic>.from(await api.recheckExit()));
    } catch (_) {
      _exit = const ExitState.error();
      _notify();
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
  Map<String, dynamic> logPage({int? since}) => api.log(since: since);

  @override
  Stream<Map<String, dynamic>> get logLines => api.logStream;

  @override
  void clearEvents() => api.clearEvents();

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
    final left = id == null
        ? <LiveConn>[]
        : [
            for (final c in _traffic.conns)
              if (c.id != id) c,
          ];
    _traffic = TrafficInfo(
      down: _traffic.down,
      up: _traffic.up,
      downTotal: _traffic.downTotal,
      upTotal: _traffic.upTotal,
      tcp: _traffic.tcp,
      udp: _traffic.udp,
      conns: left,
    );
    _notify();
  }

  /// Call after any edit of [catalog]: keeps it in step, saves it, tells the core what moved
  /// (Auto settings, kill switch) or reconnects when the plan is another one, and rebuilds
  /// the listeners.
  @override
  void changed() {
    if (_disposed) return;
    catalog.syncCatalog();
    _scheduleSave();
    _syncAuto();
    _syncKill();
    _syncUpdateSettings();
    _scheduleReconnect();
    _notify();
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
  double? get lastSpeedMbps => _lastSpeedMbps;

  @override
  Future<Map<String, dynamic>> version() => api.version();

  // ── Rules ──

  List<InstalledApp>? _apps;
  Map<String, InstalledApp> _appsByPkg = const {};
  final Map<String, Uint8List?> _icons = {};

  /// The names of installed apps for the catalog (the plan, the delete dialog, Rules).
  AppInfo? _appInfo(String pkg) {
    final a = _appsByPkg[pkg];
    return a == null ? null : (name: a.name, kind: 'package');
  }

  @override
  Future<List<InstalledApp>> installedApps() async {
    final cached = _apps;
    if (cached != null) return cached;
    final v = vpn;
    final list = v == null
        ? const <InstalledApp>[]
        : [
            for (final a in await v.apps())
              InstalledApp(pkg: a.pkg, name: a.name, system: a.system),
          ]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _apps = list;
    _appsByPkg = {for (final a in list) a.pkg: a};
    catalog.appInfo = _appInfo;
    _notify();
    return list;
  }

  @override
  Future<Uint8List?> appIcon(String pkg) async {
    if (_icons.containsKey(pkg)) return _icons[pkg];
    return _icons[pkg] = await vpn?.appIcon(pkg);
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

  /// The app's update options (auto-check, channel) go to the core's scheduled check.
  void _syncUpdateSettings() {
    if (_disposed) return;
    final g = gen;
    final sig = '${g.updates}|${g.updChannel}';
    if (sig == _updSettingsSig) return;
    _updSettingsSig = sig;
    try {
      api.updateSettings({'autoCheck': g.updates, 'channel': g.updChannel});
    } catch (_) {}
  }

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
    _notify();
  }

  @override
  Future<void> downloadUpdate() async {
    if (!_ready || _upd.phase == UpdPhase.downloading) return;
    try {
      _upd = AppUpdate.fromJson(await api.updateDownload());
    } catch (e) {
      _notice(HostNotice('updateCheckFailed', '$e', args: ['$e']));
    }
    _notify();
  }

  @override
  void cancelUpdate() {
    if (_ready) api.updateCancel();
  }

  @override
  Future<bool> installUpdate() async {
    final file = _upd.file, install = installer;
    if (!_ready || file == null || install == null) return false;
    await api.updateBeginInstall();
    final ok = await install(file);
    if (!ok) await api.updateInstallFailed('the installer did not start');
    return ok;
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
    }
  }

  List<CatalogNode> _launchPingNodes() {
    final c = catalog;
    final top = [
      for (final id in c.visibleOrder())
        if (c.connectEntry(id)?.inAuto == true) id,
    ].take(1 + c.autoCfg.standby.toInt());
    final ids = <String>{
      if (!c.autoConnect) ?c.effectiveConnectId(),
      ...top,
    };
    final refs = <NodeRef>[
      for (final id in ids) ..._entryRefs(id),
      for (final t in _ruleTargets()) ..._targetRefs(t),
    ];
    final seen = <String>{};
    return [
      for (final r in refs)
        if (seen.add(r.node.id)) r.node,
    ];
  }

  List<NodeRef> _entryRefs(String id) {
    final chain = catalog.chainsData[id];
    return chain != null
        ? [...catalog.chainEntryRefs(chain), ...catalog.chainExitRefs(chain)]
        : catalog.unitRefs(id);
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
  /// (`liveMaybeReconnect`).
  void _scheduleReconnect() {
    if (!_ready || !_connected || _connecting || _planSig == null) return;
    final sig = catalog.planSig();
    _reconnectTimer?.cancel();
    if (sig == null || sig == _planSig) return;
    _reconnectTimer = Timer(reconnectDelay, _reconnect);
  }

  Future<void> _reconnect() async {
    if (_reconnecting || !_connected || _connecting || _planSig == null) return;
    if (catalog.planSig() == _planSig) return;
    _reconnecting = true;
    try {
      await _sendPlan();
      _notify();
    } catch (e) {
      final (msg, _) = _explain(e);
      _notice(HostNotice('reconnectFailed', msg));
      await _refreshStatus();
      _notify();
    } finally {
      _reconnecting = false;
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
    _notify();
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
  Future<void> updateSource(String sid, {bool rediscover = false}) async {
    final s = catalog.sourcesData[sid];
    if (s == null || s.kind != 'sub' || _updating.contains(sid) || !_ready) {
      return;
    }
    _updating.add(sid);
    _notify();
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
    final refs = c != null
        ? [...catalog.chainEntryRefs(c), ...catalog.chainExitRefs(c)]
        : catalog.unitRefs(id);
    return _pingNodes([for (final r in refs) r.node]);
  }

  @override
  Future<List<int>> pingPairs(CatalogNode entry, List<CatalogNode> exits) async {
    final res = List<int>.filled(exits.length, -1);
    final at = [
      for (var i = 0; i < exits.length; i++)
        if (exits[i].outbound != null && exits[i].usable) i,
    ];
    if (entry.outbound == null || !entry.usable || at.isEmpty) return res;
    try {
      await for (final l in api.ping({
        'pairs': [
          for (final i in at)
            {
              'key': '$i',
              'entry': {'outbound': entry.outbound},
              'exit': {'outbound': exits[i].outbound},
            },
        ],
        if (catalog.connCfg.testUrl.isNotEmpty) 'url': catalog.connCfg.testUrl,
        'checkers': catalog.connCfg.checkers,
      })) {
        final i = int.tryParse('${l['key']}'), ms = l['ms'];
        if (l['kind'] != 'p' || i == null || i < 0 || i >= res.length || ms is! num) continue;
        res[i] = ms.round();
      }
    } catch (_) {
      // the tester could not run: no pair answered
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
    }).map((p) {
      // the Home card's "Last: N Mbps": the download of the last test that finished
      final down = p['down'];
      if (p['final'] == true && p['error'] == null && down is num && down > 0) {
        _lastSpeedMbps = down / 1e6;
        _notify();
      }
      return p;
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
    final ok = nodes.where((n) => n.outbound != null && n.usable).toList();
    for (final n in nodes.where((n) => !ok.contains(n))) {
      catalog.pings.set(n, -1);
    }
    if (ok.isEmpty) return;
    catalog.pings.markTesting(ok);
    final left = {...ok};
    var error = false;
    try {
      final byId = {for (final n in ok) n.id: n};
      await for (final l in api.ping({
        'nodes': [
          for (final n in byId.values) {'key': n.id, 'outbound': n.outbound},
        ],
        if (catalog.connCfg.testUrl.isNotEmpty) 'url': catalog.connCfg.testUrl,
        'checkers': catalog.connCfg.checkers,
      })) {
        if (l['error'] != null) error = true;
        if (l['kind'] != 'n') continue;
        final ms = l['ms'];
        if (ms is! num) continue;
        for (final n in ok.where((n) => n.id == l['key'])) {
          if (left.remove(n)) catalog.pings.set(n, ms);
        }
        _notify();
      }
    } catch (_) {
      error = true;
    }
    for (final n in left) {
      // the tester could not run (no sing-box): nothing was measured, so nothing is known
      error ? catalog.pings.remove(n) : catalog.pings.set(n, -1);
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
