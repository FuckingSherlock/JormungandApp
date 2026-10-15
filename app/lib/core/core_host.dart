import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show Catalog, CatalogNode, Chain, LiveConn, dnsLatency;

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

/// The last finished Speed Test of the connection (`status.speed` of the core).
class SpeedResult {
  const SpeedResult({
    required this.downMbps,
    required this.upMbps,
    required this.latencyMs,
    required this.rpm,
    required this.at,
  });

  final double downMbps;
  final double upMbps;

  /// Latency without load, ms; 0 = not measured.
  final int latencyMs;

  /// Round trips per minute under load (responsiveness), 0 = not measured.
  final int rpm;
  final DateTime at;

  /// `status.speed` (bit/s, `at` in ms since the epoch); null when it is none or malformed.
  static SpeedResult? fromJson(Object? j) {
    if (j is! Map || j['down'] is! num || j['at'] is! num) return null;
    return SpeedResult(
      downMbps: (j['down'] as num) / 1e6,
      upMbps: ((j['up'] as num?) ?? 0) / 1e6,
      latencyMs: (j['latency'] as num?)?.toInt() ?? 0,
      rpm: (j['rpm'] as num?)?.toInt() ?? 0,
      at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
    );
  }
}

/// What [CoreHost.resumeAfterUpdate] did (docs/updates.md, "Подключение после обновления").
enum ResumeOutcome {
  /// This start follows no update (or the platform does not remember): nothing to do.
  none,

  /// The VPN was off, or the user switched it off: left as it is.
  notWanted,

  /// The record is older than the window, or the version did not change: ignored.
  stale,

  /// The VPN is already on (taken over) or a connect is running: left alone.
  alreadyOn,

  /// Connected again through the remembered entry.
  resumed,

  /// The VPN consent is missing: "Updated - tap to connect" was posted instead.
  needsConsent,

  /// The connect did not work (the usual failure notice was sent).
  failed,
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
  const ExitState.found({
    required String ip,
    String? country,
    String? city,
    bool rechecking = false,
    bool error = false,
    DateTime? at,
  }) : this._(
         ip: ip,
         country: country,
         city: city,
         rechecking: rechecking,
         error: error,
         at: at,
       );
  const ExitState._({
    this.checking = false,
    this.error = false,
    this.rechecking = false,
    this.ip,
    this.country,
    this.city,
    this.at,
  });

  final bool checking;

  /// The last check failed: shown instead of the answer ([ip] may still be set, it is kept only for the next check).
  final bool error;

  /// A check runs while the last answer is kept (no blanking).
  final bool rechecking;

  /// The same answer, a check running.
  ExitState get asRechecking => ip == null
      ? const ExitState.checking()
      : ExitState.found(ip: ip!, country: country, city: city, rechecking: true, at: at);

  /// The same answer, the check failed.
  ExitState get asFailed => ip == null
      ? const ExitState.error()
      : ExitState.found(ip: ip!, country: country, city: city, error: true, at: at);

  final String? ip;

  /// ISO 3166 alpha-2.
  final String? country;
  final String? city;

  /// When the last completed check finished (null: unknown).
  final DateTime? at;
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

/// Holds the live [TrafficInfo]; [update] says whether the listeners hear of it (a poll that
/// changed nothing the cards show keeps the newest data without a rebuild).
class TrafficNotifier extends ChangeNotifier implements ValueListenable<TrafficInfo> {
  TrafficInfo _value = TrafficInfo.zero;

  @override
  TrafficInfo get value => _value;

  void update(TrafficInfo next, {bool notify = true}) {
    _value = next;
    if (notify) notifyListeners();
  }
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

  /// Live speed / totals / connections. Kept apart from the host's own notifications: it moves
  /// every second while connected, and only the stat cards and the live-connections sheet listen
  /// to [trafficNotifier] — [notifyListeners] is not called for it.
  TrafficInfo get traffic => trafficNotifier.value;

  /// The listenable of [traffic].
  final TrafficNotifier trafficNotifier = TrafficNotifier();

  @override
  void dispose() {
    trafficNotifier.dispose();
    super.dispose();
  }

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
  /// `-1` = no answer (also for a server with no usable outbound). An EMPTY list = the call itself
  /// failed (the tester could not run): no verdict on any pair, the caller writes nothing. Nothing
  /// goes to the pair book (the caller writes what it keeps: `catalog.pairs`).
  Future<List<int>> pingPairs(CatalogNode entry, List<CatalogNode> exits);

  /// A chain measured the way it connects: its entries directly (always with [entries], else only
  /// when none is in use yet), then [exits] (default: all of the chain's) through the entry in
  /// use (`catalog.chainEntryNode`) — the pair results land in `catalog.pairs`, what the chain's
  /// exits live by. A chain exit is never pinged directly for the chain.
  Future<void> pingChain(Chain c, {Iterable<CatalogNode>? exits, bool entries = true});

  /// A tap on the latency in the dock (`pingDockTop`): starts the dock ping (`Catalog.dockPingBatches`:
  /// batches until [dockPingEnough] servers answered or all are measured) or, while it runs, stops it
  /// (the batch in flight finishes). [dockPinging] drives the light round the latency frame.
  bool get dockPinging;
  Future<void> toggleDockPing();

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
  /// `{lines, next, hidden?}`, from [since]); the raw lines also arrive on [logLines]. With
  /// `conns: false` the core leaves the connection flood out (connection and found-package lines)
  /// and says how many it left in `hidden`; numbering stays whole.
  Map<String, dynamic> eventsPage({int? since});
  Map<String, dynamic> logPage({int? since, bool conns = true});
  Stream<Map<String, dynamic>> get logLines;
  void clearEvents();

  /// «Check with checker» on a site event: the core asks check-host.net about its site and changes that
  /// event in place (`data.check`, shown pending at once). Completes with the result; never throws.
  Future<void> checkSite(int eventId);
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

  /// Latency of the DNS provider [providerId] per side by the core's own dns-check (the sing-box in use, so the side
  /// chip's colour and the ping agree): `direct` / `vpn` = best ms of the side's transports, -1 no answer, null =
  /// "—" (side not configured, or nothing could measure it). Without a running core the direct side is measured in
  /// process (`dnsLatency`, one query per transport, the best counts) and the VPN side is null.
  Future<DnsSidePing> pingDnsSides(String providerId) async {
    final p = catalog.dnsServers[providerId];
    if (p == null || !p.activeSides.contains('direct')) return const DnsSidePing();
    final ms = await Future.wait([for (final t in p.usedTransports) dnsLatency(t.addr).catchError((_) => -1)]);
    final known = ms.whereType<int>();
    final ok = known.where((m) => m >= 0);
    return DnsSidePing(direct: known.isEmpty ? null : (ok.isEmpty ? -1 : ok.reduce((a, b) => a < b ? a : b)));
  }

  // App updates (docs/updates.md). The core checks and downloads; the platform installs.

  /// The running app's version (`0.1.0`), empty when the host does not know it.
  String get appVersion => '';

  /// The running app's build number, 0 when the host does not know it.
  int get appBuild => 0;

  /// The commit the build was made from (`--dart-define=JORM_COMMIT=<short sha>`), empty if not given.
  String get appCommit => const String.fromEnvironment('JORM_COMMIT');

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

  /// The install dialog is up / the file is on its way to the installer: the card shows «Installing…».
  bool get updateInstalling => false;

  /// «Download & install» was pressed and the file has not reached the installer yet (an automatic
  /// download never sets it). [UpdateFlow] hands the file over the moment it is ready and the app is in
  /// front, else when the app comes back.
  bool get updateInstallWanted => false;

  /// Reads and clears [updateInstallWanted].
  bool takeUpdateInstallWanted() => false;

  /// The first thing after the core is up: when this start follows the app's own update that
  /// replaced a running VPN, connects again through the entry it used (once). The platform keeps
  /// the record; none = nothing happens.
  Future<ResumeOutcome> resumeAfterUpdate() async => ResumeOutcome.none;

  /// Core / sing-box versions and the data folder (`CoreApi.version`).
  Future<Map<String, dynamic>> version() async => const {};

  /// The support report (docs/logs.md → Отчёт) with this app's own account of itself filled in
  /// (`report_info.dart`): the core's one structured map — events, raw log, state — as «Download
  /// log» writes it. Empty in a host without a core.
  Future<Map<String, dynamic>> report() async => const {};

  /// «Send report»: the same report with the user's [note] (≤ 500 characters), masked more strictly,
  /// to the developers. → `{ok: true, id, bytes}` or `{ok: false, error, message?}`; `error` is
  /// `not-configured` (no receiver is built yet), `network`, `rejected`, `server`, `cancelled`,
  /// `timeout` or `failed`. Never throws. Goes direct first and through the tunnel when that fails.
  Future<Map<String, dynamic>> sendReport({String note = ''}) async => const {'ok': false, 'error': 'not-configured'};

  /// Stops the send under way: its `sendReport` then answers `cancelled`.
  Future<void> cancelSendReport() async {}

  /// Backup: the whole state as one snapshot, and the reverse (replaces everything; a running
  /// connection restarts with the restored state).
  Map<String, dynamic> exportState() => catalog.toJson();
  Future<void> importState(Map<String, dynamic> snapshot) async {}

  /// Last Speed Test of the connection (Home → Speed Test card; kept by the core across
  /// restarts), null = none yet.
  SpeedResult? get lastSpeed => null;

  /// Its download in Mbps, null = none yet.
  double? get lastSpeedMbps => lastSpeed?.downMbps;

  /// The Home card's test of the running connection is in progress, and its latest progress map
  /// (`phase`, `down`, `up`, `elapsed`, …; empty before the first step).
  bool get speedTesting => false;
  Map<String, dynamic> get speedProgress => const {};

  /// A failed last test (the text), null when the last one finished or none ran; cleared by the next run.
  String? get speedError => null;

  /// A tap on the Home Speed Test card: starts sing-box's network quality test through the running
  /// connection (the main flow, chains included) or, while it runs, stops it (nothing is kept).
  /// Not connected: does nothing (the page says «Connect first»).
  Future<void> toggleSpeedTest() async {}

  // ── Rules ──

  /// The installed apps for Rules -> Per-app routing, by name; empty where the platform cannot
  /// list them (the desktop: apps are not picked by package there yet). Cached after the first
  /// call ([refresh] asks the platform again: an app installed since); also tells the catalog the
  /// names of apps (`catalog.appInfo`).
  Future<List<InstalledApp>> installedApps({bool refresh = false}) async =>
      const [];

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

/// One candidate of `status.dns.servers`: a provider's transport on one side.
class DnsServerStatus {
  const DnsServerStatus({
    required this.id,
    required this.provider,
    required this.side,
    this.ok,
    this.watched = false,
    this.rechecking = false,
    this.deadOnNode = false,
  });

  final String id;
  final String provider;

  /// A check of this server runs; [ok] stays the stored verdict.
  final bool rechecking;

  /// Dead on the exit node in use only (`deadOn: 'node'`): it answers through another node.
  final bool deadOnNode;

  /// `direct` | `vpn`.
  final String side;

  /// false = it does not answer; null = not checked yet.
  final bool? ok;

  /// Only observed, never switched to.
  final bool watched;
}

/// `status.dns` while connected: who answers each side and which candidates fail.
/// A provider's latency per side ([CoreHost.pingDnsSides]): ms, -1 no answer, null = not configured / not measurable
/// (the UI shows "—"). [servers]: ms per candidate id when the core measured them.
class DnsSidePing {
  const DnsSidePing({this.direct, this.vpn, this.servers = const {}, this.races = const []});

  final int? direct, vpn;
  final Map<String, int> servers;

  /// The protocol race per provider and side (`providers` of the ping answer); empty without a core.
  final List<DnsRace> races;

  /// The race of [provider] on [side], null = none.
  DnsRace? race(String provider, String side) => dnsRaceOf(races, provider, side);
}

/// One transport of a provider in the protocol race (`status.dns.providers[].transports[]`).
class DnsRaceTransport {
  const DnsRaceTransport({
    required this.kind,
    this.ms = -2,
    this.state = 'untested',
    this.dead = false,
    this.reserve = false,
  });

  /// `doh` | `dot` | `doq` | `udp`.
  final String kind;

  /// Best last answer: -1 no answer, -2 not asked.
  final int ms;

  /// `testing` | `ok` | `miss` | `untested`.
  final String state;
  final bool dead, reserve;

  bool get testing => state == 'testing';
}

/// A provider's protocol race on one side: the [winner] kind answering it and every transport's result.
class DnsRace {
  const DnsRace({
    required this.provider,
    required this.side,
    this.winnerKind,
    this.winnerMs,
    this.transports = const [],
  });

  final String provider, side;
  final String? winnerKind;
  final int? winnerMs;
  final List<DnsRaceTransport> transports;

  DnsRaceTransport? transport(String kind) {
    for (final t in transports) {
      if (t.kind == kind) return t;
    }
    return null;
  }

  /// `providers` of `status.dns` / the ping answer; malformed entries are skipped.
  static List<DnsRace> parseAll(Object? json) => [
    for (final p in (json is List ? json : const []))
      if (p is Map && p['provider'] != null && p['side'] != null)
        DnsRace(
          provider: '${p['provider']}',
          side: '${p['side']}',
          winnerKind: p['winner'] is Map ? '${(p['winner'] as Map)['kind']}' : null,
          winnerMs: p['winner'] is Map && (p['winner'] as Map)['ms'] is int
              ? (p['winner'] as Map)['ms'] as int
              : null,
          transports: [
            for (final t in (p['transports'] as List? ?? const []))
              if (t is Map && t['kind'] != null)
                DnsRaceTransport(
                  kind: '${t['kind']}',
                  ms: t['ms'] is int ? t['ms'] as int : -2,
                  state: '${t['state'] ?? 'untested'}',
                  dead: t['dead'] == true,
                  reserve: t['reserve'] == true,
                ),
          ],
        ),
  ];
}

DnsRace? dnsRaceOf(List<DnsRace> races, String provider, String side) {
  for (final r in races) {
    if (r.provider == provider && r.side == side) return r;
  }
  return null;
}

class DnsHealth {
  const DnsHealth({
    this.active,
    this.answering = const {},
    this.servers = const [],
    this.races = const [],
  });

  final String? active;

  /// The protocol race per provider and side.
  final List<DnsRace> races;

  DnsRace? race(String provider, String side) => dnsRaceOf(races, provider, side);

  /// side (`direct` / `vpn`) -> the provider answering it now; a side with nobody is absent.
  final Map<String, String> answering;
  final List<DnsServerStatus> servers;

  /// [provider] is the one answering [side] now.
  bool answers(String provider, String side) => answering[side] == provider;

  /// Every candidate of [provider] on [side] fails (and there is at least one).
  bool dead(String provider, String side) {
    var any = false;
    for (final s in servers) {
      if (s.watched || s.provider != provider || s.side != side) continue;
      if (s.ok != false) return false;
      any = true;
    }
    return any;
  }

  /// [provider] is [dead] on [side] and only on the exit node in use (every failing candidate says so).
  bool deadOnNode(String provider, String side) =>
      dead(provider, side) &&
      servers.every((s) => s.watched || s.provider != provider || s.side != side || s.deadOnNode);

  /// What of it the page shows: a change rebuilds the page at once.
  String get sig => '$active|${answering.entries.map((e) => '${e.key}=${e.value}').join(',')}|'
      '${servers.where((s) => s.ok == false).map((s) => '${s.id}${s.deadOnNode ? '@' : ''}').join(',')}|'
      '${servers.where((s) => s.rechecking).map((s) => s.id).join(',')}|'
      '${races.map((r) => '${r.provider}/${r.side}=${r.winnerKind}:${r.winnerMs}').join(',')}';
}

/// The host for the widgets below. [listenTo] (default: the host itself) is what rebuilds the
/// dependents: the shell gives each tab a [HostGate], so a tab that is not on screen is not
/// rebuilt by the host's notifications.
class CoreHostScope extends InheritedNotifier<Listenable> {
  const CoreHostScope({
    super.key,
    required this.host,
    Listenable? listenTo,
    required super.child,
  }) : super(notifier: listenTo ?? host);

  final CoreHost host;

  /// Listens: rebuilds when the host notifies.
  static CoreHost of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CoreHostScope>();
    assert(scope != null, 'No CoreHostScope above this context');
    return scope!.host;
  }

  /// For event handlers: no rebuild dependency.
  static CoreHost read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<CoreHostScope>();
    assert(scope != null, 'No CoreHostScope above this context');
    return scope!.host;
  }
}

/// Passes the host's notifications on while [active]; one that came meanwhile is delivered once
/// when it turns active again (a hidden tab catches up in a single rebuild).
class HostGate extends ChangeNotifier {
  HostGate(this._source, {bool active = true}) : _active = active {
    _source.addListener(_onSource);
  }

  final Listenable _source;
  bool _active;
  bool _stale = false;

  bool get active => _active;

  set active(bool on) {
    if (on == _active) return;
    _active = on;
    if (on && _stale) {
      _stale = false;
      notifyListeners();
    }
  }

  void _onSource() {
    if (_active) {
      notifyListeners();
    } else {
      _stale = true;
    }
  }

  @override
  void dispose() {
    _source.removeListener(_onSource);
    super.dispose();
  }
}
