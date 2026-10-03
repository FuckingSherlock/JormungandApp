import 'dart:async';
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';

/// What [LibboxRunner] needs from the platform: start / stop sing-box with a JSON config. On
/// Android that is the MethodChannel to the VpnService / libbox ([ChannelLibboxPort] in
/// platform_seams.dart); tests put a desktop sing-box behind it.
abstract interface class LibboxPort {
  /// Starts (restarts, when it runs) and returns when sing-box is up; throws [SingBoxError]
  /// with the reason when it is not.
  Future<void> start(String config);

  Future<void> stop();

  /// Reasons of sing-box stopping on its own (the system took the VPN away). Empty for ports
  /// that have no such thing.
  Stream<String> get stoppedOnItsOwn;
}

/// Android's [BoxRunner]: sing-box as libbox inside the app (behind the VpnService for the
/// tunnel, a plain in-process one for throwaway latency / Speed Test instances).
///
/// The core talks to it the way it does to the desktop process: the config gets sing-box's `api`
/// service on a loopback port with a random secret ([withApiService]), and [api] is a
/// [SingBoxApi] on it (Auto, traffic, connections, Speed Test unchanged). sing-box's log lines
/// come through the same API ([SingBoxApi.logLines]) since there is no process output.
class LibboxRunner implements BoxRunner {
  LibboxRunner(this._port, {this.upTimeout = const Duration(seconds: 8)});

  final LibboxPort _port;

  /// How long the API service may take to answer after the platform said "up".
  final Duration upTimeout;

  SingBoxApi? _api;
  StreamSubscription<String>? _logSub, _goneSub;
  bool _native = false; // the platform may hold a running sing-box
  bool _up = false;

  @override
  bool get running => _up;

  @override
  int? get pid => null; // libbox runs in the app's own process

  @override
  SingBoxApi? get api => _api;

  @override
  void Function(String line)? onLog;

  @override
  void Function(int code)? onExit;

  @override
  void note(String line) => onLog?.call('[jormd] $line');

  @override
  Future<void> start(Map<String, dynamic> config) async {
    _up = false;
    await _closeLocal(); // a restart: the platform side replaces its sing-box itself
    final secret = newApiSecret();
    final apiPort = await freePort();
    _native = true;
    try {
      await _port.start(jsonEncode(withApiService(config, secret, apiPort)));
    } catch (_) {
      _native = false; // the platform cleans up after a failed start
      rethrow;
    }

    final a = SingBoxApi(apiPort, secret);
    final deadline = DateTime.now().add(upTimeout);
    while (DateTime.now().isBefore(deadline)) {
      String? fatal;
      try {
        fatal = await a.serviceState();
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      if (fatal != null) {
        await a.close();
        await stop();
        throw SingBoxError('sing-box failed to start: $fatal');
      }
      _up = true;
      _api = a..watch();
      _logSub = a.logLines().listen(
        (l) => onLog?.call(l),
        onError: (Object _) {},
      );
      _goneSub = _port.stoppedOnItsOwn.listen(_gone, onError: (Object _) {});
      return;
    }
    await a.close();
    await stop();
    throw SingBoxError('sing-box did not come up in ${upTimeout.inSeconds} s');
  }

  void _gone(String reason) {
    if (!_up) return;
    _up = false;
    _native = false;
    note('sing-box stopped: $reason');
    unawaited(_closeLocal());
    onExit?.call(0);
  }

  @override
  Future<void> stop() async {
    _up = false;
    await _closeLocal();
    if (_native) {
      _native = false;
      await _port.stop();
    }
  }

  Future<void> _closeLocal() async {
    final logs = _logSub, gone = _goneSub, a = _api;
    _logSub = _goneSub = null;
    _api = null;
    // closing a gRPC stream on a sing-box that is already gone may complain; nobody cares
    unawaited(logs?.cancel().catchError((Object _) {}));
    unawaited(gone?.cancel().catchError((Object _) {}));
    unawaited(a?.close().catchError((Object _) {}));
  }
}
