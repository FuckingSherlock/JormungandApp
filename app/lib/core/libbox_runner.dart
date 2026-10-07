import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// Keeps [record] next to the running sing-box on the platform side: it lives exactly as long
  /// as sing-box does (a stop, a revoke or the process ending drop it). Ports whose sing-box
  /// cannot outlive the app do nothing.
  Future<void> remember(String record);

  /// Whether the platform runs a sing-box now and what [remember] was given for it (null: none).
  /// Asked by a freshly started core to take over a tunnel the previous engine left running.
  Future<({bool running, String? record})> recall();
}

/// Android's [BoxRunner]: sing-box as libbox inside the app (behind the VpnService for the
/// tunnel, a plain in-process one for throwaway latency / Speed Test instances).
///
/// The core talks to it the way it does to the desktop process: the config gets sing-box's `api`
/// service on a loopback port with a random secret ([withApiService]), and [api] is a
/// [SingBoxApi] on it (Auto, traffic, connections, Speed Test unchanged). sing-box's log lines
/// come through the same API ([SingBoxApi.logLines]) since there is no process output.
///
/// [cacheFile]: this instance's own sing-box cache file ([withCacheFile]); every libbox in the
/// app process wants one and locks it, so two instances must never share a path. [temporaryCache]:
/// the file is deleted when the instance stops (the throwaway ones); the tunnel's stays.
///
/// [watchApi]: open the API's connections / groups / status streams ([SingBoxApi.watch]). Only
/// the tunnel needs them (Auto, the dock, Live connections); a throwaway latency / Speed Test
/// box says nothing anyone reads there, and three gRPC streams per box, each pushing every
/// second, only cost the UI isolate time during a ping run. Its log stays on: [CoreService]
/// keeps the failure lines of the test boxes in the raw log.
class LibboxRunner implements AdoptableRunner {
  LibboxRunner(
    this._port, {
    this.upTimeout = const Duration(seconds: 8),
    this.cacheFile,
    this.temporaryCache = false,
    this.watchApi = true,
  });

  final LibboxPort _port;
  final String? cacheFile;
  final bool temporaryCache;
  final bool watchApi;

  /// How long the API service may take to answer after the platform said "up".
  final Duration upTimeout;

  SingBoxApi? _api;
  StreamSubscription<String>? _logSub, _goneSub;
  bool _native = false; // the platform may hold a running sing-box
  bool _up = false;
  int _apiPort = 0; // of the running sing-box: what [keep] hands to a later core
  String _secret = '', _level = 'INFO';

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
    final want = _rank('${(config['log'] as Map?)?['level'] ?? 'info'}'.toUpperCase());
    final cache = cacheFile;
    if (cache != null) await File(cache).parent.create(recursive: true);
    _native = true;
    try {
      final full = withApiService(config, secret, apiPort);
      await _port.start(jsonEncode(cache == null ? full : withCacheFile(full, cache)));
    } catch (_) {
      _native = false; // the platform cleans up after a failed start
      await _dropCache();
      rethrow;
    }

    final a = SingBoxApi(apiPort, secret);
    final deadline = DateTime.now().add(upTimeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      String? fatal;
      try {
        fatal = await a.serviceState();
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      if (fatal != null) {
        await a.close();
        await stop();
        throw SingBoxError('sing-box failed to start: $fatal');
      }
      _apiPort = apiPort;
      _secret = secret;
      _level = '${(config['log'] as Map?)?['level'] ?? 'info'}'.toUpperCase();
      _attach(a, want);
      return;
    }
    await a.close();
    await stop();
    throw SingBoxError(
      'sing-box did not come up in ${upTimeout.inSeconds} s: its API on 127.0.0.1:$apiPort answered with $lastError',
    );
  }

  /// The API of the running sing-box [a]: [running], its streams, its log (cut to [want]), its end.
  void _attach(SingBoxApi a, int want) {
    _up = true;
    _api = a;
    if (watchApi) a.watch();
    _logSub = a.logLines().listen((l) {
      // libbox sends every line, whatever the config's level says
      if (want >= 6 || _rankOfLine(l) <= want) onLog?.call(l);
    }, onError: (Object _) {});
    _goneSub = _port.stoppedOnItsOwn.listen(_gone, onError: (Object _) {});
  }

  @override
  Future<void> keep(Map<String, dynamic> record) async {
    if (!_up) return;
    await _port.remember(
      jsonEncode({
        'apiPort': _apiPort,
        'secret': _secret,
        'level': _level,
        'core': record,
      }),
    );
  }

  @override
  Future<Map<String, dynamic>?> adopt() async {
    if (_up) return null;
    final s = await _port.recall();
    if (!s.running) return null;
    _native = true; // it is there: a stop closes it, also when it cannot be taken over
    final Map<String, dynamic> rec;
    final SingBoxApi a;
    try {
      rec = (jsonDecode(s.record ?? '') as Map).cast<String, dynamic>();
      a = SingBoxApi((rec['apiPort'] as num).toInt(), rec['secret'] as String);
    } catch (e) {
      throw SingBoxError('the tunnel left by the previous run has no usable record ($e)');
    }
    try {
      final fatal = await a.serviceState().timeout(upTimeout);
      if (fatal != null) throw SingBoxError('sing-box reports: $fatal');
    } catch (e) {
      await a.close().catchError((Object _) {});
      throw SingBoxError('the tunnel left by the previous run does not answer on its API: $e');
    }
    _apiPort = (rec['apiPort'] as num).toInt();
    _secret = rec['secret'] as String;
    _level = '${rec['level'] ?? 'INFO'}';
    final core = rec['core'];
    if (core is! Map) {
      await a.close().catchError((Object _) {});
      throw SingBoxError('the tunnel left by the previous run has no core record');
    }
    _attach(a, _rank(_level));
    return core.cast<String, dynamic>();
  }

  // The level of a line ("WARN[0003] …", coloured by libbox: "\x1b[33mWARN\x1b[0m[0003] …"); a line
  // with none passes (rank 0). No regex: this runs for every line sing-box writes, the most common
  // levels are asked first.
  static int _rankOfLine(String l) {
    var i = 0;
    if (l.startsWith('\x1B[')) {
      i = l.indexOf('m');
      if (i < 0) return 0;
      i++;
    }
    bool at(String w) => l.startsWith(w, i);
    if (at('INFO')) return 4;
    if (at('WARN')) return 3;
    if (at('ERROR')) return 2;
    if (at('DEBUG')) return 5;
    if (at('TRACE')) return 6;
    if (at('FATAL')) return 1;
    return 0; // PANIC, or not a level at all
  }

  static int _rank(String level) => switch (level) {
    'PANIC' => 0,
    'FATAL' => 1,
    'ERROR' => 2,
    'WARN' => 3,
    'DEBUG' => 5,
    'TRACE' => 6,
    _ => 4,
  };

  void _gone(String reason) {
    if (!_up) return;
    _up = false;
    _native = false;
    note('sing-box stopped: $reason');
    unawaited(_closeLocal());
    unawaited(_dropCache());
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
    await _dropCache();
  }

  Future<void> _dropCache() async {
    final cache = cacheFile;
    if (cache == null || !temporaryCache) return;
    try {
      await File(cache).delete();
    } catch (_) {} // not there, or still held: the next start of the app sweeps the leftovers
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
