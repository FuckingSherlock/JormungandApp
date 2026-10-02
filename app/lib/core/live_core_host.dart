import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';

import '../platform/vpn_channel.dart';
import 'core_host.dart';

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

  final Duration saveDelay;
  final Duration reconnectDelay;
  final Duration trafficEvery;
  final DateTime Function() _now;

  /// The app's state. Public for the pages that edit it (Nodes, Route, ...): they call
  /// [changed] after an edit.
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
    _statusSub = _eventSub = null;
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
      );
      final same =
          next.down == _traffic.down &&
          next.up == _traffic.up &&
          next.downTotal == _traffic.downTotal &&
          next.tcp == _traffic.tcp &&
          next.udp == _traffic.udp;
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

  /// Call after any edit of [catalog]: keeps it in step, saves it, tells the core what moved
  /// (Auto settings, kill switch) or reconnects when the plan is another one, and rebuilds
  /// the listeners.
  void changed() {
    if (_disposed) return;
    catalog.syncCatalog();
    _scheduleSave();
    _syncAuto();
    _syncKill();
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
  Future<AddSourceResult> addSubscription(
    String url, {
    String name = '',
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
        'updateInterval': 'auto',
        'reloadAfterUpdate': true,
        'testAfterUpdate': true,
        'userAgent': 'Auto',
        'channel': 'Direct first',
        'hwid': false,
        'keepRules': false,
        'filter': '',
        'password': '',
        'website': '',
      }),
    );
    changed();
    _updating.add(id);
    try {
      await _fetchInto(id);
      final s = catalog.sourcesData[id];
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
    }
  }

  /// Asks the core to fetch source [sid] with its own settings and applies the patch of the
  /// fields the core owns (`liveFetch`). Throws what the fetch threw.
  Future<void> _fetchInto(String sid) async {
    final s = catalog.sourcesData[sid]!;
    final j = s.toJson();
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
          k: j[k],
      },
      'rediscover': false,
    });
    final patch = r['patch'];
    final next = Source.fromJson({
      ...j,
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
    if (next.unknown['testAfterUpdate'] != false) {
      unawaited(_pingNodes(catalog.liveNodes(next)));
    }
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
