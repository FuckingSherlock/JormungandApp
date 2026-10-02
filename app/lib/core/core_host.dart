import 'package:flutter/widgets.dart';

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
/// source name, error), `subAdded`, `reconnectFailed`; [text] is the English fallback.
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
  });

  static const zero = TrafficInfo();

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
enum DockKind { chain, profile, sub, set, simple, profiles }

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

  // ── catalog actions ──

  /// Nodes -> + -> Subscription: adds the source, fetches it. Completes after the fetch; a failed
  /// fetch leaves the source with its error (and a [HostNotice] `subFailed`).
  Future<AddSourceResult> addSubscription(String url, {String name = ''});

  // ── streams ──

  /// Every journal event of the core (`{id, at, cat, type, level, own, data}`), as written.
  Stream<Map<String, dynamic>> get events;

  /// Short messages for toasts.
  Stream<HostNotice> get notices;
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
