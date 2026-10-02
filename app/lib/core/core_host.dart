import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What the power button / connection badge on Home show (mockup: on / busy / off / down).
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  disconnecting,
  down,
}

/// Owner of the core service inside the app process: starts the core (package `jormungand_core`),
/// hands the UI its API, and ties the core to the platform tunnel (Android VpnService +
/// libbox, Windows TUN / system proxy by the core itself).
///
/// INTERFACE ONLY for now. Not implemented yet, on purpose:
/// - TODO(core-api): expose the core API (`CoreApi` / `CoreService`, being extracted from
///   core/lib/src/daemon.dart): `CoreApi get api;` + the live streams (traffic, connections,
///   events, logs) the pages subscribe to.
/// - TODO(android): [connect] on Android = `VpnChannel.prepare()` (system consent) -> core builds the
///   sing-box config -> `VpnChannel.start(config)` -> libbox runs inside `JormungandVpnService`.
/// - TODO(windows): the core spawns sing-box itself (core/lib/src/runtime.dart); TUN needs admin.
///
/// A [ChangeNotifier]: widgets listen through [CoreHostScope].
abstract class CoreHost extends ChangeNotifier {
  ConnectionPhase get phase;

  /// Last failure to show (VPN is down / start failed), or null.
  String? get error;

  /// Start the core service (state, subscriptions, API). Idempotent.
  Future<void> init();

  /// Bring the tunnel / proxy up with the current profile.
  Future<void> connect();

  /// Take it down.
  Future<void> disconnect();

  bool get isConnected => phase == ConnectionPhase.connected;
}

/// Stand-in until the real host exists: no core, [connect] only flips the phase so the shell
/// (power button, badge) can be seen working. Also what widget tests use.
class IdleCoreHost extends CoreHost {
  ConnectionPhase _phase = ConnectionPhase.disconnected;

  @override
  ConnectionPhase get phase => _phase;

  @override
  String? get error => null;

  @override
  Future<void> init() async {}

  @override
  Future<void> connect() async {
    _phase = ConnectionPhase.connected;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _phase = ConnectionPhase.disconnected;
    notifyListeners();
  }
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
