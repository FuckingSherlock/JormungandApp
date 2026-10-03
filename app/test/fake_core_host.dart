import 'dart:async';

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
  TrafficInfo _traffic = TrafficInfo.zero;
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
    _traffic = t;
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
    notifyListeners();
  }

  @override
  DockSummary get dock => dockSummary;

  @override
  bool get catalogEmpty => catalogIsEmpty;

  @override
  ExitState get exit => _exit;

  @override
  TrafficInfo get traffic => _traffic;

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

  @override
  String? saveChain(ChainDraft d) {
    calls.add('saveChain');
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

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Stream<HostNotice> get notices => _notices.stream;

  @override
  void dispose() {
    _notices.close();
    super.dispose();
  }
}
