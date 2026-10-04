import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show Catalog, CatalogNode, LiveConn, dnsLatency;

import 'app_update.dart';
import 'catalog_forms.dart';

export 'catalog_forms.dart';

/// What the power button / connection badge on Home show (mockup: on / busy / off / down).
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  down,
}

/// How a [CoreHost.connect] / [CoreHost.toggleConnection] ended, for the page to react to.
/// The failures that only need a toast ([failed], [vpnPermissionDenied]) are also sent on
/// [CoreHost.notices]; the page itself handles [nothingInAuto] (alert) and [catalogEmpty].
enum ConnectOutcome {
  started,
  stopped,

  /// A connect / disconnect is already running: the tap is ignored.
  busy,

  /// Auto with every Route entry switched off Auto (mockup `alertNothingInAuto`).
  nothingInAuto,

  /// Nothing in this mode to connect through: the page leads to Nodes (mockup `dockTap`).
  catalogEmpty,

  /// Android: the user refused the system VPN consent dialog.
  vpnPermissionDenied,
  failed,
}

class ConnectResult {
  const ConnectResult(this.outcome, {this.message, this.code});

  final ConnectOutcome outcome;

  /// The core's English text of a failure (shown as it is, the core does not localise).
  final String? message;

  /// `tunNeedsAdmin`, or a validation code of the catalog (`noUsableServer`, `nothingToConnect`).
  final String? code;

  bool get started => outcome == ConnectOutcome.started;
}

/// A short message from the host for a toast. [code] lets the UI use its own (localised) text:
/// `vpnDenied`, `connectFailed`, `warning`, `initFailed`, `notSaved`, `subFailed` ([args] =
/// source name, error), `updateFailed` (the same, an update of a source that was loaded),
/// `subAdded`, `reconnectFailed`; [text] is the English fallback.
class HostNotice {
  const HostNotice(this.code, this.text, {this.args = const []});

  final String code;
  final String text;
  final List<String> args;
}

/// `status.down`: sing-box did not come back within 30 s (docs/connect-model.md → dock states).
class VpnDown {
  const VpnDown({required this.since, required this.proxy});

  /// Epoch ms.
  final int since;

  /// `kept` (the system proxy blocks the internet) | `removed` | `released`.
  final String proxy;
}

/// `status.blocking`: disconnected, the kill switch still holds the system proxy.
class KillBlock {
  const KillBlock({
    required this.since,
    required this.reason,
    required this.proxy,
  });

  final int since;

  /// `disconnect` | `closed`.
  final String reason;

  /// `kept` | `released`.
  final String proxy;
}

/// Where traffic leaves (mockup `exitInfo`): checking, an answer, or no answer.
class ExitState {
  const ExitState.checking() : this._(checking: true);
  const ExitState.error() : this._(error: true);
  const ExitState.found({required String ip, String? country, String? city})
    : this._(ip: ip, country: country, city: city);
  const ExitState._({
    this.checking = false,
    this.error = false,
    this.ip,
    this.country,
    this.city,
  });

  final bool checking;
  final bool error;
  final String? ip;

  /// ISO 3166 alpha-2.
  final String? country;
  final String? city;
}

/// Speed (bytes / s) and the session totals (bytes), open connections.
class TrafficInfo {
  const TrafficInfo({
    this.down = 0,
    this.up = 0,
    this.downTotal = 0,
    this.upTotal = 0,
    this.tcp = 0,
    this.udp = 0,
    this.conns = const [],
  });

  static const zero = TrafficInfo();

  /// The open connections (Home -> Connections -> Live connections).
  final List<LiveConn> conns;

  final num down;
  final num up;
  final num downTotal;
  final num upTotal;
  final int tcp;
  final int udp;

  int get connections => tcp + udp;
}

/// The small kind label of the dock row; never translated (mockup `profCardLabel`, `data-notr`).
/// [simple] / [profiles] are shown when nothing is connected (the Route mode).
enum DockKind { chain, profile, sub, file, set, simple, profiles }

/// Why the dock has no entry: `nothingInAuto` / `empty` (nothing to connect in this mode).
enum DockNone { nothingInAuto, empty }

/// A server as the dock line shows it.
class DockNode {
  const DockNode({
    required this.flag,
    required this.name,
    required this.protocol,
  });

  final String flag;
  final String name;

  /// `reality` for a Reality server, else the protocol (mockup `protoLabel`).
  final String protocol;
}

/// What the dock row shows (mockup `updateMainConnectCard`): the entry Auto / Manual is on, the
/// server traffic leaves through (a chain: [entryNode] -> [node]), the latency.
class DockSummary {
  const DockSummary({
    required this.kind,
    this.name = '',
    this.none,
    this.simpleMode = true,
    this.auto = true,
    this.node,
    this.entryNode,
    this.sourceName,
    this.latencyMs,
  });

  final DockKind kind;

  /// The entry's name; empty when there is none ([none]).
  final String name;
  final DockNone? none;
  final bool simpleMode;

  /// AUTO / MANUAL badge.
  final bool auto;

  /// The server traffic leaves through (a chain: its exit); null = no working node.
  final DockNode? node;

  /// A chain's entry server.
  final DockNode? entryNode;

  /// A profile's server shows its subscription first (`Profile  Sub > node`).
  final String? sourceName;

  /// ms of the server (a chain: the two hops added up); null = unknown.
  final int? latencyMs;

  bool get isChain => kind == DockKind.chain;
  bool get hasEntry => none == null && name.isNotEmpty;
}

enum AddSourceOutcome { added, emptyUrl, failed }

class AddSourceResult {
  const AddSourceResult(this.outcome, {this.name = '', this.error});

  final AddSourceOutcome outcome;
  final String name;
  final String? error;
}

/// What [CoreHost.importConfigFile] made of a file: a new local source ([sourceId], its [name]
/// and server [count]) or the [error] text (nothing was added).
class ImportFileResult {
  const ImportFileResult.added(
    String this.sourceId,
    this.name,
    this.count,
  ) : error = null;
  const ImportFileResult.failed(String this.error)
    : sourceId = null,
      name = '',
      count = 0;

  final String? sourceId;
  final String name;
  final int count;
  final String? error;

  bool get ok => error == null;
}

/// The UI's one line to the core: state to show, actions to take. The real one is
/// `LiveCoreHost` (live_core_host.dart, over `CoreService` + `Catalog`); widget tests use a fake.
///
/// A [ChangeNotifier]: widgets listen through [CoreHostScope]. Nothing on it blocks: every
/// action is a Future, the page shows what [phase] says meanwhile.
abstract class CoreHost extends ChangeNotifier {
  /// Starts the core and loads the state. Idempotent.
  Future<void> init();

  /// Stops the core the way the app closing does (sing-box stopped, the system proxy back by the
  /// kill switch rules, the state saved). Not called on Android: the process just ends.
  Future<void> shutdown();

  /// The state is loaded (before it, the dock is empty and the actions wait).
  bool get ready;

  /// The core failed to start (the text), or null.
  String? get initError;

  // ── connection ──

  ConnectionPhase get phase;

  /// Connected or down (sing-box is being brought back): a tap on the power button disconnects.
  bool get isOn =>
      phase == ConnectionPhase.connected || phase == ConnectionPhase.down;

  bool get busy =>
      phase == ConnectionPhase.connecting ||
      phase == ConnectionPhase.disconnecting;

  /// Last connect failure to show, or null.
  String? get error;

  VpnDown? get down;

  /// The kill switch plaque on Home (disconnected, the proxy kept), null once released.
  KillBlock? get blocking;

  /// The power button / badge: disconnect when on, else connect (with the checks of the mockup's
  /// `toggleMain`).
  Future<ConnectResult> toggleConnection();

  Future<ConnectResult> connect();

  Future<void> disconnect();

  /// "Retry" of the down alert: a restart of sing-box now.
  Future<void> retry();

  /// "Disable sys proxy" / "Remove": the system proxy off now.
  Future<void> releaseSysProxy();

  // ── Home segments ──

  /// Android: always TUN (the VpnService), no system proxy.
  bool get isAndroid;
  bool get tun;
  bool get global;
  bool get sysProxy;
  void setTun(bool on);
  void setGlobal(bool on);
  void setSysProxy(bool on);

  // ── Route ──

  /// Auto (true) or Manual.
  bool get autoMode;
  void setAutoMode(bool on);

  // ── what is connected, how it goes ──

  DockSummary get dock;

  /// Nothing in this Route mode to connect through at all (the dock leads to Nodes).
  bool get catalogEmpty;

  ExitState get exit;
  TrafficInfo get traffic;

  /// Tap on the Exit IP card: check where traffic leaves again.
  Future<void> refreshExit();

  // ── catalog (Nodes) ──
  //
  // The pages read [catalog] (sources, profiles, chains, the ping book, the query helpers and
  // `delete*Impact` of the core's catalog library) and change it only through the methods below:
  // each one edits the catalog, then saves / reconnects / rebuilds the listeners.

  /// The app's state. Read only: edit through the host.
  Catalog get catalog;

  /// A fetch of source [sid] is running (its update button spins).
  bool isUpdating(String sid);

  /// Nodes -> + -> Subscription: adds the source, fetches it. Completes after the fetch; a failed
  /// fetch leaves the source with its error (and a [HostNotice] `subFailed`).
  Future<AddSourceResult> addSubscription(
    String url, {
    String name = '',
    SubscriptionSettings? settings,
  });

  /// Nodes -> + -> Import config file: the text of a picked file (sing-box JSON, Clash YAML, a list
  /// of links) becomes a local source (kind `file`, named after [fileName]), added at the end of
  /// Simple, on and in Auto. Nothing recognised / too big: [ImportFileResult.error], nothing added.
  Future<ImportFileResult> importConfigFile(String fileName, String text);

  /// Updates a subscription (a never loaded one fetches again); `rediscover` asks with every
  /// User-Agent again. Failure: the source keeps its servers and shows the error strip, a
  /// [HostNotice] `updateFailed` goes out.
  Future<void> updateSource(String sid, {bool rediscover = false});

  /// "Update all subscriptions": every enabled one.
  Future<void> updateAll();

  /// Save of the subscription / group form. A group only takes [name]; a subscription also its
  /// [url] and [settings], and is fetched again when another address / User-Agent / HWID / filter
  /// can mean another list (mockup `saveSrcForm`).
  void saveSource(
    String sid, {
    String name = '',
    String? url,
    SubscriptionSettings? settings,
  });

  void toggleSourceEnabled(String sid);
  void toggleNodeEnabled(String sid, String nid);

  /// A Nodes tab was dragged: the new order of that tab (`simple` | `profiles`), every entry.
  void reorderCatalog(String tab, List<String> order);

  /// Delete (the page asked first: `catalog.delete*Impact`).
  void deleteSource(String sid);
  void deleteNode(String sid, String nid);

  /// A profile or a chain.
  void deleteEntry(String id);

  /// Forgets servers the provider dropped (all of the source, or [only]); how many.
  int forgetGone(String sid, [List<String>? only]);

  /// A chain card in edit mode: server [key] (`sid::nid`) of one end (`in` | `out`) on / off for
  /// this chain only.
  void toggleChainNode(String id, String side, String key);

  /// Source entry sheet / Route settings of a source or profile; they apply at once.
  void setSourceOffNodes(String sid, List<String> off);
  void setPickMode(String id, String mode);
  void setPickOrder(String id, List<String> order);
  void setEntryInAuto(String id, bool on);

  /// Profile / chain editors: null = saved, else the English reason it was not (an end with no
  /// server, the ends equal).
  String? saveProfile(ProfileDraft d);
  String? saveChain(ChainDraft d);

  /// The sort of server lists: `order` | `latency` | `name` (kept with the state).
  String get nodeSort;
  void setNodeSort(String sort);

  // ── ping ──

  /// Latency of [nodes] by the core; results land in the ping book as they come.
  Future<void> pingNodes(Iterable<CatalogNode> nodes);

  /// A source's servers / every enabled source's, in turns / a profile's or chain's.
  Future<void> pingSource(String sid);
  Future<void> pingAll();
  Future<void> pingEntry(String id);

  /// The route check's pair ping (`backend.pingPair`): every one of [exits] through [entry] (the
  /// exit's outbound detoured via the entry's), in one core call. Latency per exit in order,
  /// `-1` = no answer (also for a server with no usable outbound). Nothing goes to the ping book.
  Future<List<int>> pingPairs(CatalogNode entry, List<CatalogNode> exits);

  // ── share, speed test, manual servers ──

  /// The share link of a server, null when it has none (no outbound, unsupported).
  String? shareLink(CatalogNode n);

  /// sing-box's quality test through [n]: progress maps (`phase`, `down`, `up`, `latency`,
  /// `downRpm`, `elapsed`, last one `final: true` with `error` when it failed). Cancelling the
  /// subscription stops it.
  Stream<Map<String, dynamic>> speedTest(CatalogNode n);

  /// The servers of the share links in [text] (one per line), for the manual form's preview.
  List<CatalogNode> parseLinks(String text);

  /// Save of the manual server form (a link, or the fields).
  Future<SaveNodeResult> saveManualNode(NodeFormInput f);

  // ── streams ──

  /// Every journal event of the core (`{id, at, cat, type, level, own, data}`), as written.
  Stream<Map<String, dynamic>> get events;

  /// Short messages for toasts.
  Stream<HostNotice> get notices;

  // ── Route ──
  //
  // The Route list lives in [catalog] (`connectOrder`, `autoConnect`, `activeConnectId`,
  // `pinnedNode`); these apply one tap of the sheet and call [changed].

  /// The AUTO / MANUAL button of a row.
  void selectConnect(String id);

  /// A tap on a server of an unfolded row (`sid::nid`): Manual on it; the pinned one again unpins.
  void pinRouteNode(String id, String key);

  /// The Simple / Profiles switch of Route.
  void setConnectMode(String mode);

  /// Route was dragged: the new order of the shown entries (`catalog.visibleOrder`).
  void reorderRoute(List<String> shown);

  /// "Follow Nodes order".
  void resetRouteOrder();

  /// The servers of a Priority row were dragged: the new order of its shown keys.
  void reorderPick(String id, List<String> shownKeys);

  // ── Logs and connections ──

  /// The events journal / the raw log as the core keeps them (`{events, next, first}` /
  /// `{lines, next}`, from [since]); the raw lines also arrive on [logLines].
  Map<String, dynamic> eventsPage({int? since});
  Map<String, dynamic> logPage({int? since});
  Stream<Map<String, dynamic>> get logLines;
  void clearEvents();
  void clearLog();

  /// An event only the UI knows (a retry's result...) into the journal.
  void postEvent(
    String cat,
    String type,
    Map<String, dynamic> data, {
    String level = 'info',
    bool own = true,
  });

  /// Saves the state soon without the effects of [changed] (the Logs read marks).
  void saveSoon();

  /// Closes one connection, or all of them without an [id].
  Future<void> closeConnection([String? id]);

  // ── Settings tab ──
  //
  // The settings objects live in [catalog] (`autoCfg`, `connCfg`, `dnsCfg`, `dnsServers`...,
  // and `genCfg` / `notifCfg` in its `unknown` map, see settings_model.dart); a page edits them
  // and calls [changed], which saves, tells the running core what moved and reconnects when the
  // plan is another one.

  void changed();

  /// Once, when the app has opened and the host is ready: "Connect on launch", "Check servers on
  /// launch".
  Future<void> runLaunchActions() async {}

  /// The DNS server in use and the ones that do not answer while connected (core `status.dns`);
  /// null when not connected.
  DnsHealth? get dnsHealth => null;

  /// Latency of a DNS server by one real query (core `dnsLatency`): ms, -1 no answer, null = cannot
  /// be measured here (quic://).
  Future<int?> pingDns(String addr) => dnsLatency(addr);

  // App updates (docs/updates.md). The core checks and downloads; the platform installs.

  /// The running app's version (`0.1.0`), empty when the host does not know it.
  String get appVersion => '';

  /// The update as the Data sheet shows it; `unavailable` in a host without an updater.
  AppUpdate get appUpdate => const AppUpdate();

  /// The platform can take a downloaded file and install it (Android PackageInstaller); false
  /// where that side is not written (the Windows updater), then the file is only downloaded.
  bool get canInstallUpdate => false;

  /// "Check now" (a check the user asked for; the failure is shown, not journalled silently).
  Future<void> checkUpdate() async {}
  Future<void> downloadUpdate() async {}
  void cancelUpdate() {}

  /// Hands the downloaded file to the installer; false when the platform refused or cannot.
  Future<bool> installUpdate() async => false;

  /// Core / sing-box versions and the data folder (`CoreApi.version`).
  Future<Map<String, dynamic>> version() async => const {};

  /// Backup: the whole state as one snapshot, and the reverse (replaces everything; a running
  /// connection restarts with the restored state).
  Map<String, dynamic> exportState() => catalog.toJson();
  Future<void> importState(Map<String, dynamic> snapshot) async {}

  /// Last Speed Test result (Mbps), null = none yet.
  double? get lastSpeedMbps => null;

  // ── Rules ──

  /// The installed apps for Rules -> Per-app routing, by name; empty where the platform cannot
  /// list them (the desktop: apps are not picked by package there yet). Cached after the first
  /// call; also tells the catalog the names of apps (`catalog.appInfo`).
  Future<List<InstalledApp>> installedApps() async => const [];

  /// An app's icon (PNG), null when it has none.
  Future<Uint8List?> appIcon(String pkg) async => null;

  /// When each list of Rules -> Rule sets was downloaded (epoch ms) by its name there; a list
  /// that never was is absent.
  Future<Map<String, int>> ruleSetTimes() async => const {};
}

/// An installed app of the device (Android): its package, its label and whether it is a
/// system one.
class InstalledApp {
  const InstalledApp({
    required this.pkg,
    required this.name,
    this.system = false,
  });

  final String pkg;
  final String name;
  final bool system;
}

/// `status.dns` while connected: the server in use and the ones that fail.
class DnsHealth {
  const DnsHealth({this.active, this.failed = const {}});

  final String? active;
  final Set<String> failed;
}

class CoreHostScope extends InheritedNotifier<CoreHost> {
  const CoreHostScope({super.key, required CoreHost host, required super.child})
    : super(notifier: host);

  /// Listens: rebuilds when the host notifies.
  static CoreHost of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CoreHostScope>();
    assert(scope != null, 'No CoreHostScope above this context');
    return scope!.notifier!;
  }

  /// For event handlers: no rebuild dependency.
  static CoreHost read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<CoreHostScope>();
    assert(scope != null, 'No CoreHostScope above this context');
    return scope!.notifier!;
  }
}
