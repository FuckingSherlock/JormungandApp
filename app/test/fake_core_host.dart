import 'dart:async';

import 'package:jormungand/core/app_update.dart';
import 'package:jormungand/core/core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

/// A [CoreHost] for widget tests: nothing runs, the test sets the state and the host notifies.
/// [toggleConnection] flips the phase like the real one does (connecting while [gate] is open,
/// then connected / disconnected), unless [outcomeOverride] says what it should answer.
class FakeCoreHost extends CoreHost {
  FakeCoreHost({
    DockSummary? dock,
    this.catalogIsEmpty = false,
    this.android = false,
    this.emptyFromCatalog = false,
  }) : dockSummary =
           dock ??
           const DockSummary(
             kind: DockKind.sub,
             name: 'Remnawave',
             node: DockNode(
               flag: '\u{1F1E9}\u{1F1EA}',
               name: 'Frankfurt 1',
               protocol: 'reality',
             ),
             latencyMs: 48,
           );

  DockSummary dockSummary;
  bool catalogIsEmpty;
  final bool android;

  /// The empty state (the dock row, the connect check) follows the real [catalog] of the host,
  /// the way the live host does, instead of [catalogIsEmpty] and the fixed [dockSummary].
  final bool emptyFromCatalog;

  /// While set, a connect waits for it (the test sees the "connecting" phase).
  Completer<void>? gate;
  ConnectOutcome? outcomeOverride;
  int toggles = 0;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  VpnDown? _down;
  KillBlock? _blocking;
  ExitState _exit = const ExitState.found(
    ip: '203.0.113.7',
    country: 'DE',
    city: 'Frankfurt',
  );
  bool _tun = false;
  bool _global = false;
  bool _sys = false;
  bool _auto = true;

  final _notices = StreamController<HostNotice>.broadcast();

  void setPhase(ConnectionPhase p, {VpnDown? down}) {
    _phase = p;
    _down = down;
    notifyListeners();
  }

  void setTraffic(TrafficInfo t) {
    trafficNotifier.update(t);
    notifyListeners();
  }

  void setBlocking(KillBlock? b) {
    _blocking = b;
    notifyListeners();
  }

  void setExit(ExitState e) {
    _exit = e;
    notifyListeners();
  }

  void notice(HostNotice n) => _notices.add(n);

  @override
  Future<void> init() async {}

  @override
  Future<void> shutdown() async {}

  @override
  bool get ready => true;

  @override
  String? get initError => null;

  @override
  ConnectionPhase get phase => _phase;

  @override
  String? get error => null;

  @override
  VpnDown? get down => _down;

  @override
  KillBlock? get blocking => _blocking;

  @override
  Future<ConnectResult> toggleConnection() async {
    toggles++;
    if (busy) return const ConnectResult(ConnectOutcome.busy);
    if (isOn) {
      setPhase(ConnectionPhase.disconnected);
      return const ConnectResult(ConnectOutcome.stopped);
    }
    final o = outcomeOverride;
    if (o != null) return ConnectResult(o);
    if (emptyFromCatalog && catalog.catalogEmpty()) {
      return const ConnectResult(ConnectOutcome.catalogEmpty);
    }
    return connect();
  }

  @override
  Future<ConnectResult> connect() async {
    setPhase(ConnectionPhase.connecting);
    if (gate != null) await gate!.future;
    setPhase(ConnectionPhase.connected);
    return const ConnectResult(ConnectOutcome.started);
  }

  @override
  Future<void> disconnect() async => setPhase(ConnectionPhase.disconnected);

  @override
  Future<void> retry() async {}

  @override
  Future<void> releaseSysProxy() async {
    _down = null;
    _blocking = null;
    notifyListeners();
  }

  @override
  bool get isAndroid => android;

  @override
  bool get tun => android || _tun;

  @override
  bool get global => _global;

  @override
  bool get sysProxy => _sys;

  @override
  void setTun(bool on) {
    _tun = on;
    notifyListeners();
  }

  @override
  void setGlobal(bool on) {
    _global = on;
    notifyListeners();
  }

  @override
  void setSysProxy(bool on) {
    _sys = on;
    notifyListeners();
  }

  @override
  bool get autoMode => _auto;

  @override
  void setAutoMode(bool on) {
    _auto = on;
    catalog.setAutoConnect(on);
    notifyListeners();
  }

  @override
  DockSummary get dock => emptyFromCatalog && catalog.catalogEmpty()
      ? DockSummary(
          kind: catalog.simpleMode ? DockKind.simple : DockKind.profiles,
          none: DockNone.empty,
          simpleMode: catalog.simpleMode,
        )
      : dockSummary;

  @override
  bool get catalogEmpty =>
      emptyFromCatalog ? catalog.catalogEmpty() : catalogIsEmpty;

  @override
  ExitState get exit => _exit;

  @override
  Future<void> refreshExit() async {}

  // ── catalog: a real Catalog the test fills in, edited the way the live host does ──

  @override
  Catalog catalog = Catalog();

  /// Sources whose update button spins.
  final Set<String> updating = {};

  /// What the actions were asked, for the test to look at.
  final List<String> calls = [];

  @override
  bool isUpdating(String sid) => updating.contains(sid);

  @override
  Future<AddSourceResult> addSubscription(
    String url, {
    String name = '',
    SubscriptionSettings? settings,
  }) async {
    calls.add('addSubscription $url');
    return const AddSourceResult(AddSourceOutcome.added);
  }

  /// Reads the text with the core's own reader, like the live host (the id is the next `src<N>`).
  @override
  Future<ImportFileResult> importConfigFile(String fileName, String text) async {
    calls.add('importConfigFile $fileName');
    final Map<String, dynamic> r;
    try {
      r = localSourceFromText(fileName, text);
    } on FormatException catch (e) {
      return ImportFileResult.failed(e.message);
    }
    final id = 'src${catalog.sourceSeq++}';
    final s = Source.fromJson({...r, 'id': id});
    catalog.addSource(s);
    _changed();
    return ImportFileResult.added(id, s.name, s.nodes.length);
  }

  @override
  Future<void> updateSource(String sid, {bool rediscover = false}) async =>
      calls.add('updateSource $sid${rediscover ? ' rediscover' : ''}');

  @override
  Future<void> updateAll() async => calls.add('updateAll');

  @override
  void saveSource(
    String sid, {
    String name = '',
    String? url,
    SubscriptionSettings? settings,
  }) {
    calls.add('saveSource $sid');
    final s = catalog.sourcesData[sid];
    if (s != null && name.trim().isNotEmpty) s.name = name.trim();
    notifyListeners();
  }

  void _changed() {
    catalog.syncCatalog();
    notifyListeners();
  }

  @override
  void toggleSourceEnabled(String sid) {
    catalog.toggleSourceEnabled(sid);
    _changed();
  }

  @override
  void toggleNodeEnabled(String sid, String nid) {
    catalog.toggleNodeEnabled(sid, nid);
    _changed();
  }

  @override
  void reorderCatalog(String tab, List<String> order) {
    catalog.reorderCatalog(tab, order);
    _changed();
  }

  @override
  void deleteSource(String sid) {
    catalog.deleteSource(sid);
    _changed();
  }

  @override
  void deleteNode(String sid, String nid) {
    catalog.deleteNode(sid, nid);
    _changed();
  }

  @override
  void deleteEntry(String id) {
    if (catalog.profilesData.containsKey(id)) {
      catalog.deleteProfile(id);
    } else {
      catalog.deleteChain(id);
    }
    _changed();
  }

  @override
  int forgetGone(String sid, [List<String>? only]) {
    final n = catalog.forgetGone(sid, only);
    _changed();
    return n;
  }

  @override
  void toggleChainNode(String id, String side, String key) {
    final c = catalog.chainsData[id];
    if (c != null) catalog.chainToggleNode(c, side, key);
    _changed();
  }

  @override
  void setSourceOffNodes(String sid, List<String> off) {
    catalog.sourcesData[sid]?.offNodes = [...off];
    _changed();
  }

  @override
  void setPickMode(String id, String mode) {
    catalog.setEntryPickMode(id, mode);
    _changed();
  }

  @override
  void setPickOrder(String id, List<String> order) {
    catalog.setEntryPickOrder(id, order);
    _changed();
  }

  @override
  void setEntryInAuto(String id, bool on) {
    catalog.connectEntry(id)?.inAuto = on;
    _changed();
  }

  @override
  String? saveProfile(ProfileDraft d) {
    calls.add('saveProfile');
    return null;
  }

  /// The last chain draft passed to [saveChain].
  ChainDraft? savedChain;

  @override
  String? saveChain(ChainDraft d) {
    calls.add('saveChain');
    savedChain = d;
    return null;
  }

  String _sort = 'order';

  @override
  String get nodeSort => _sort;

  @override
  void setNodeSort(String sort) {
    _sort = sort;
    notifyListeners();
  }

  @override
  Future<void> pingNodes(Iterable<CatalogNode> nodes) async =>
      calls.add('pingNodes ${nodes.length}');

  @override
  Future<void> pingSource(String sid) async => calls.add('pingSource $sid');

  @override
  Future<void> pingAll() async => calls.add('pingAll');

  @override
  Future<void> pingEntry(String id) async => calls.add('pingEntry $id');

  /// The route check's answers: `pairMs[exit.id]` (default: 50 ms); [pairGate], when set, holds
  /// every `pingPairs` call until it completes (a test can cancel meanwhile).
  final Map<String, int> pairMs = {};
  Completer<void>? pairGate;

  /// A `pingPairs` call that fails as a whole (an empty list).
  bool pairCallFails = false;

  @override
  Future<List<int>> pingPairs(CatalogNode entry, List<CatalogNode> exits) async {
    calls.add('pingPairs ${entry.id} ${exits.length}');
    await pairGate?.future;
    if (pairCallFails) return const [];
    return [for (final x in exits) pairMs[x.id] ?? 50];
  }

  @override
  Future<void> pingChain(
    Chain c, {
    Iterable<CatalogNode>? exits,
    bool entries = true,
  }) async => calls.add(
    'pingChain ${c.id} ${exits?.length ?? 'all'}${entries ? '' : ' exits-only'}',
  );

  bool _dockPinging = false;

  @override
  bool get dockPinging => _dockPinging;

  @override
  Future<void> toggleDockPing() async {
    _dockPinging = !_dockPinging;
    calls.add(_dockPinging ? 'dockPing start' : 'dockPing stop');
    notifyListeners();
  }

  @override
  String? shareLink(CatalogNode n) => 'vless://${n.address}#${n.name}';

  @override
  Stream<Map<String, dynamic>> speedTest(CatalogNode n) => const Stream.empty();

  @override
  List<CatalogNode> parseLinks(String text) => [];

  @override
  Future<SaveNodeResult> saveManualNode(NodeFormInput f) async {
    calls.add('saveManualNode');
    return const SaveNodeResult(SaveNodeOutcome.added, added: 1);
  }

  // ── Route, Logs, connections ──

  @override
  void selectConnect(String id) {
    catalog.selectConnect(id);
    _changed();
  }

  @override
  void pinRouteNode(String id, String key) {
    catalog.pinRouteNode(id, key);
    _changed();
  }

  @override
  void setConnectMode(String mode) {
    catalog.setConnectMode(mode);
    _changed();
  }

  @override
  void reorderRoute(List<String> shown) {
    catalog.reorderRoute(shown);
    _changed();
  }

  @override
  void resetRouteOrder() {
    catalog.resetRouteOrder();
    _changed();
  }

  @override
  void reorderPick(String id, List<String> shownKeys) {
    catalog.reorderUnitPick(id, shownKeys);
    _changed();
  }

  /// The journal and the raw log the test fills in ([addEvent] / [addLogLine]); they are served the
  /// way the core serves them (`{events, next, first}`, `{lines, next}`).
  final List<Map<String, dynamic>> journal = [];
  final List<Map<String, dynamic>> logLinesList = [];
  final _eventStream = StreamController<Map<String, dynamic>>.broadcast();
  final _logStream = StreamController<Map<String, dynamic>>.broadcast();
  int _eventSeq = 0;
  int _lineSeq = 0;
  int saves = 0;

  Map<String, dynamic> addEvent(
    String cat,
    String type, {
    String level = 'info',
    bool own = false,
    Map<String, dynamic> data = const {},
    int? at,
    int? log,
    bool bg = false,
  }) {
    final e = {
      'id': _eventSeq++,
      'at': at ?? DateTime.now().millisecondsSinceEpoch,
      'cat': cat,
      'type': type,
      'level': level,
      'own': own,
      if (bg) 'bg': true,
      'data': data,
      'log': ?log,
    };
    journal.add(e);
    _eventStream.add(e);
    return e;
  }

  Map<String, dynamic> addLogLine(
    String msg, {
    String lvl = 'info',
    String src = 'sing-box',
    int? t,
  }) {
    final l = {
      'n': _lineSeq++,
      't': t ?? DateTime.now().millisecondsSinceEpoch,
      'src': src,
      'lvl': lvl,
      'msg': msg,
    };
    logLinesList.add(l);
    _logStream.add(l);
    return l;
  }

  /// «Check with checker» presses, by event id.
  final checkedSites = <int>[];

  /// What the checker says (`data.check` of the event); a test sets it.
  Map<String, dynamic> checkAnswer = {'state': 'opens', 'ok': 2, 'total': 2, 'via': 'tunnel', 'nodes': const []};

  /// Held until the test lets the check finish (null: it finishes at once).
  Completer<void>? checkGate;

  void _changeEvent(Map<String, dynamic> e, Map<String, dynamic> check) {
    e['rev'] = ((e['rev'] as int?) ?? 0) + 1;
    e['data'] = {...(e['data'] as Map<String, dynamic>), 'check': check};
    _eventStream.add(e);
  }

  @override
  Future<void> checkSite(int eventId) async {
    checkedSites.add(eventId);
    final e = journal.where((x) => x['id'] == eventId).firstOrNull;
    if (e == null) return;
    _changeEvent(e, {'state': 'pending', 'at': DateTime.now().millisecondsSinceEpoch, 'manual': true});
    await checkGate?.future;
    _changeEvent(e, {...checkAnswer, 'at': DateTime.now().millisecondsSinceEpoch, 'manual': true});
  }

  @override
  Map<String, dynamic> eventsPage({int? since}) => {
    'events': [
      for (final e in journal)
        if (since == null || (e['id'] as int) >= since) e,
    ],
    if (journal.any((e) => e['rev'] != null)) 'updated': [for (final e in journal) if (e['rev'] != null) e],
    'next': _eventSeq,
    'first': journal.isEmpty ? _eventSeq : journal.first['id'],
  };

  @override
  Map<String, dynamic> logPage({int? since}) => {
    'lines': [
      for (final l in logLinesList)
        if (since == null || (l['n'] as int) >= since) l,
    ],
    'next': _lineSeq,
  };

  @override
  Stream<Map<String, dynamic>> get logLines => _logStream.stream;

  @override
  void clearEvents() {
    journal.clear();
    calls.add('clearEvents');
  }

  @override
  void clearLog() {
    logLinesList.clear();
    calls.add('clearLog');
  }

  @override
  void postEvent(
    String cat,
    String type,
    Map<String, dynamic> data, {
    String level = 'info',
    bool own = true,
  }) {
    addEvent(cat, type, level: level, own: own, data: data);
  }

  @override
  void saveSoon() => saves++;

  @override
  Future<void> closeConnection([String? id]) async {
    calls.add('closeConnection $id');
    final t = traffic;
    setTraffic(
      TrafficInfo(
        down: t.down,
        up: t.up,
        downTotal: t.downTotal,
        upTotal: t.upTotal,
        tcp: t.tcp,
        udp: t.udp,
        conns: [
          if (id != null)
            for (final c in t.conns)
              if (c.id != id) c,
        ],
      ),
    );
  }

  // ── Settings tab ──

  /// How often a page called [changed] (it saves and syncs in the live host).
  int changes = 0;

  @override
  void changed() {
    changes++;
    catalog.syncCatalog();
    notifyListeners();
  }

  DnsHealth? dnsHealthValue;
  AppUpdate update = const AppUpdate(phase: UpdPhase.idle, current: '0.1.0');
  bool installable = false;

  /// When set, installUpdate waits for it (its value is the install result).
  Completer<bool>? installGate;
  Map<String, dynamic> versionInfo = const {};
  SpeedResult? speed;
  bool speedRunning = false;
  Map<String, dynamic> speedStep = const {};
  String? speedFailed;

  @override
  SpeedResult? get lastSpeed => speed;

  @override
  bool get speedTesting => speedRunning;

  @override
  Map<String, dynamic> get speedProgress => speedStep;

  @override
  String? get speedError => speedFailed;

  @override
  Future<void> toggleSpeedTest() async {
    calls.add(speedRunning ? 'speedTest stop' : 'speedTest start');
    if (!speedRunning && _phase != ConnectionPhase.connected) return;
    speedRunning = !speedRunning;
    if (speedRunning) speedStep = const {'phase': 0};
    notifyListeners();
  }

  /// What [pingDns] answers by address (default 24 ms).
  final Map<String, int?> dnsPings = {};

  @override
  DnsHealth? get dnsHealth => dnsHealthValue;

  @override
  Future<int?> pingDns(String addr) async {
    calls.add('pingDns $addr');
    return dnsPings.containsKey(addr) ? dnsPings[addr] : 24;
  }

  @override
  String get appVersion => '0.1.0';

  int build = 7;
  String commit = 'abc1234';

  @override
  int get appBuild => build;

  @override
  String get appCommit => commit;

  @override
  AppUpdate get appUpdate => update;

  @override
  bool get canInstallUpdate => installable;

  @override
  Future<void> checkUpdate() async => calls.add('checkUpdate');

  @override
  Future<void> downloadUpdate() async => calls.add('downloadUpdate');

  @override
  void cancelUpdate() => calls.add('cancelUpdate');

  @override
  Future<bool> installUpdate() async {
    calls.add('installUpdate');
    final gate = installGate;
    if (gate != null) return gate.future;
    return true;
  }

  @override
  Future<Map<String, dynamic>> version() async => versionInfo;

  @override
  Future<void> importState(Map<String, dynamic> snapshot) async {
    calls.add('importState');
    catalog = Catalog.fromJson(snapshot);
    changed();
  }

  /// Rules: what the device "has installed" and when the rule sets were downloaded.
  List<InstalledApp> apps = const [];
  int appRefreshes = 0;
  Map<String, int> ruleSetAt = const {};

  @override
  Future<List<InstalledApp>> installedApps({bool refresh = false}) async {
    appRefreshes += refresh ? 1 : 0;
    catalog.appInfo = (pkg) {
      for (final a in apps) {
        if (a.pkg == pkg) return (name: a.name, kind: 'package');
      }
      return null;
    };
    return apps;
  }

  @override
  Future<Map<String, int>> ruleSetTimes() async => ruleSetAt;

  @override
  Stream<Map<String, dynamic>> get events => _eventStream.stream;

  @override
  Stream<HostNotice> get notices => _notices.stream;

  @override
  void dispose() {
    _notices.close();
    _eventStream.close();
    _logStream.close();
    super.dispose();
  }
}
