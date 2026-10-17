import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'killjob.dart';
import 'pool.dart';
import 'probe.dart';
import 'routing.dart' show DnsCandidate;
import 'sbapi.dart';

class SingBoxError implements Exception {
  SingBoxError(this.message, {this.fix});
  final String message;

  /// Where the user fixes it, when the core knows (`conn/connectFailed` `data.fix`, docs/logs.md): `settings` — the
  /// proxy port of Settings → Connection is taken, `pick` — the Manual pick is not usable. Null: not a setting.
  final String? fix;
  @override
  String toString() => message;
}

/// Whether sing-box's start error is its user inbound (`mixed-in` on 127.0.0.1:[port], the proxy port of Settings →
/// Connection) failing to listen — the port is taken: a setting to change, not a fault of the server.
bool userPortRefused(String error, int port) =>
    RegExp(r'\b(listen|bind)\b', caseSensitive: false).hasMatch(error) &&
    (error.contains('[mixed-in]') || RegExp('127\\.0\\.0\\.1:$port(?!\\d)').hasMatch(error));

/// One running sing-box, as the core sees it: the seam where a platform plugs in its own way
/// to run it (a process on desktop, [SingBoxProcess]; libbox inside the app on Android).
/// The core starts it with a finished config, listens to its lines and its exit, and talks
/// to it only through [api] (sbapi.dart).
abstract interface class BoxRunner {
  bool get running;

  /// The process id, null when there is none (libbox runs in the app's own process).
  int? get pid;

  /// sing-box's API service while it runs, its streams open.
  SingBoxApi? get api;

  /// Every line sing-box writes, as it comes.
  void Function(String line)? onLog;

  /// sing-box stopped on its own after it had come up (not called for [stop] or a failed start).
  void Function(int code)? onExit;

  /// A line of the core's own in the log, next to sing-box's.
  void note(String line);

  /// Starts it with [config] (the runner adds the API service) and waits until it is up;
  /// throws [SingBoxError] with the reason when it is not.
  Future<void> start(Map<String, dynamic> config);

  Future<void> stop();
}

/// A [BoxRunner] whose sing-box can outlive the core that started it (libbox in Android's
/// VpnService when the app's Flutter engine is destroyed and made again, the process and the
/// service staying). The platform keeps a record next to the running sing-box for as long as it
/// runs; a new core finds it and takes the sing-box over instead of starting another one
/// ([CoreService.adopt]).
abstract interface class AdoptableRunner implements BoxRunner {
  /// Keeps [record] (the core's JSON-able description of what this sing-box runs) with it. Call
  /// after every successful [start]; the platform drops it when sing-box stops.
  Future<void> keep(Map<String, dynamic> record);

  /// Takes over a sing-box that runs already: connects its API, attaches the log, sets [running].
  /// Returns what [keep] was given, null when nothing runs. Throws [SingBoxError] when
  /// something runs that cannot be taken over (no record, the API does not answer); [stop]
  /// then closes it.
  Future<Map<String, dynamic>?> adopt();
}

/// Makes a runner for a throwaway sing-box (latency tests, Speed Test) working in [workDir].
typedef BoxFactory = BoxRunner Function(String workDir);

/// One sing-box process: the desktop [BoxRunner].
class SingBoxProcess implements BoxRunner {
  SingBoxProcess(this.binary, this.workDir);

  final String binary;
  final String workDir;
  final logs = ListQueue<String>();
  Process? _proc;
  Process? _up; // the process that came up (start() returned), until it stops

  /// sing-box's API service (sbapi.dart, the core's only line to it) while it runs, its
  /// streams open.
  @override
  SingBoxApi? api;

  /// Every line sing-box writes, as it comes (jormd's Logs tab).
  @override
  void Function(String line)? onLog;

  /// The API service's secret: new and random on every start, put into the config and
  /// sent by every call, so no other program can steer the tunnel.
  String? secret;

  /// sing-box stopped on its own (crash, killed from outside) after it had come up;
  /// never called for stop() or for a start that failed.
  @override
  void Function(int code)? onExit;

  @override
  bool get running => _proc != null;
  @override
  int? get pid => _proc?.pid;

  void _log(String line) {
    logs.add(line);
    onLog?.call(line);
    while (logs.length > 500) {
      logs.removeFirst();
    }
  }

  /// A line of the core's own in the log (`[jormd] …`), next to sing-box's.
  @override
  void note(String line) => _log('[jormd] $line');

  /// Writes [config] (plus the API service on a free port), has sing-box check it, runs it
  /// and waits until the service says it started — or failed, with its reason.
  @override
  Future<void> start(Map<String, dynamic> config) async {
    await stop();
    await Directory(workDir).create(recursive: true);
    final secret = this.secret = _newSecret();
    final apiPort = await freePort();
    final file = File(p.join(workDir, 'config.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(_withApi(config, secret, apiPort)));

    final check = await Process.run(binary, ['check', '-c', file.path, '--disable-color']);
    if (check.exitCode != 0) {
      throw SingBoxError('sing-box rejected the config: ${'${check.stderr}${check.stdout}'.trim()}');
    }

    final proc = await Process.start(binary, ['run', '-c', file.path, '-D', workDir, '--disable-color']);
    _proc = proc;
    final unbound = bindToUs(proc.pid); // dies with us, however we die
    if (unbound != null) _log('[jormd] sing-box is not tied to the core ($unbound)');
    for (final s in [proc.stdout, proc.stderr]) {
      s.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_log);
    }
    proc.exitCode.then((code) {
      _log('[jormd] sing-box exited with code $code');
      final wasUp = identical(_up, proc);
      if (identical(_proc, proc)) _proc = null;
      if (wasUp) {
        _up = null;
        onExit?.call(code);
      }
    });

    final a = SingBoxApi(apiPort, secret);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (!identical(_proc, proc)) {
        await a.close();
        throw SingBoxError('sing-box stopped on start:\n${logs.toList().reversed.take(8).toList().reversed.join('\n')}');
      }
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
      _up = proc;
      api = a..watch();
      return;
    }
    await a.close();
    await stop();
    throw SingBoxError('sing-box did not come up in 8 s');
  }

  @override
  Future<void> stop() async {
    final proc = _proc;
    _up = null;
    final a = api;
    api = null;
    unawaited(a?.close());
    if (proc == null) return;
    _proc = null;
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }

  static String _newSecret() => newApiSecret();

  static Map<String, dynamic> _withApi(Map<String, dynamic> config, String secret, int apiPort) =>
      withApiService(config, secret, apiPort);
}

/// A new random secret for sing-box's API service (see [withApiService]).
String newApiSecret() {
  final r = Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// [config] plus sing-box's API service on loopback [apiPort] with [secret] (the core's line to
/// a running sing-box, sbapi.dart). A [BoxRunner] that does not start a process (libbox on
/// Android) puts the same service into the config, so [SingBoxApi] works on it unchanged.
Map<String, dynamic> withApiService(Map<String, dynamic> config, String secret, int apiPort) => {
      ...config,
      'services': [
        ...?(config['services'] as List?),
        {'type': 'api', 'tag': 'api', 'listen': '127.0.0.1', 'listen_port': apiPort, 'secret': secret},
      ],
    };

/// [config] with its own cache file at [path] (`experimental.cache_file`, the rest of it kept: the
/// tunnel's `cache_id`). libbox keeps one bbolt file per instance and forces it on, and the file
/// is locked, so every instance of the Android app (the tunnel, each throwaway latency / Speed
/// Test one) must have a file of its own: a second one on the shared default `cache.db` dies
/// after 10 s with `initialize cache-file: timeout`. Desktop sing-box processes have a working
/// directory each and need none.
Map<String, dynamic> withCacheFile(Map<String, dynamic> config, String path) {
  final exp = (config['experimental'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final cache = (exp['cache_file'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  return {
    ...config,
    'experimental': {
      ...exp,
      'cache_file': {...cache, 'enabled': true, 'path': path},
    },
  };
}

/// A free loopback port (for an inbound or the API service of a second sing-box), free
/// for UDP and TCP both: an inbound listens on both. A random port below the dynamic range,
/// not a port 0: Windows hands those out one after another, straight into its reserved
/// ranges (Hyper-V / WinNAT, blocks of hundreds, TCP and UDP apart). UDP is bound without
/// SO_REUSEADDR, as sing-box does, so a port another process holds on 0.0.0.0 counts as taken.
/// [exclude]: ports not to hand out (ones chosen for this config already).
Future<int> freePort({Set<int> exclude = const {}}) async {
  for (var i = 0;; i++) {
    final port = 20000 + _ports.nextInt(29000);
    if (exclude.contains(port)) continue;
    if (await portIsFree(port, throwOnFail: i >= 200)) return port;
  }
}

/// Whether [port] is free on loopback for UDP and TCP (see [freePort]).
Future<bool> portIsFree(int port, {bool throwOnFail = false}) async {
  RawDatagramSocket? u;
  try {
    u = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, port, reuseAddress: false);
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
    return true;
  } on SocketException {
    if (throwOnFail) rethrow;
    return false;
  } finally {
    u?.close();
  }
}

final _ports = Random();

/// Measures latency through each node (and each entry → exit pair) with a throwaway
/// sing-box, one round trip on an open connection each (probe.dart). Results: ms, or -1 = no answer.
///
/// Through the probe pool ([pool], pool.dart; without one, a private pool that reuses
/// nothing): every result is written into it, under the server's identity, so Auto and the
/// fallback service start from it; [maxAge] > 0 serves a pool answer younger than that
/// instead of measuring (the launch ping), a server being measured elsewhere is joined. The
/// throwaway sing-box starts only when something has to be measured.
///
/// `network`: when no server answered (and there were some), the direct path is tested too
/// through the same sing-box: it answers → `up` (the servers are dead, the network is not),
/// it does not → `down` (no network; also written to the pool as a silent network, any
/// answer anywhere takes it back); otherwise (something answered, or nothing was asked)
/// the pool's status as it is.
Future<({Map<String, int> nodes, Map<String, int> pairs, NetStatus network})> measureLatency({
  required String binary,
  required String workDir,
  required List<Map> nodes,
  List<Map> pairs = const [],
  String url = defaultTestUrl,
  List<String> checkers = const [],
  int timeoutMs = 5000,
  int parallel = 16,
  ProbePool? pool,
  Duration maxAge = Duration.zero,
  void Function(String kind, String key, int ms, bool byChecker)? onResult,
  void Function(String tag, String reason)? onFail,
  void Function(String line)? onWarn,
  BoxFactory? boxFactory,
  Map<String, String> pins = const {},
  DnsCandidate? nodeResolver,
}) async {
  final pl = pool ?? ProbePool.solo();
  final session = TesterSession(
      binary: binary,
      workDir: workDir,
      nodes: nodes,
      pairs: pairs,
      pool: pl,
      url: url,
      checkers: checkers,
      timeoutMs: timeoutMs,
      boxFactory: boxFactory,
      pins: pins,
      nodeResolver: nodeResolver,
      onFail: onFail,
      onWarn: onWarn);
  final requested = <(String, String, String)>[ // kind, key, pool identity
    for (final n in nodes) ('n', '${n['key']}', serverIdentity(n['outbound'] as Map)),
    for (final pr in pairs)
      (
        'p',
        '${pr['key']}',
        pairIdentity(serverIdentity((pr['entry'] as Map)['outbound'] as Map), serverIdentity((pr['exit'] as Map)['outbound'] as Map))
      ),
  ];
  // the ones that answered before go first, the rest after them; each group in the order asked (the caller puts Auto's top first)
  bool answeredBefore((String, String, String) j) => pl.peek(j.$3, url: url, checkers: checkers)?.answered == true;
  final jobs = [...requested.where(answeredBefore), ...requested.where((j) => !answeredBefore(j))];
  try {
    // a sing-box that cannot start is an error of the call, not a pool full of misses
    if (jobs.any((j) => !pl.fresh(j.$3, url: url, checkers: checkers, maxAge: maxAge))) await session.ensure();
    final res = (nodes: <String, int>{}, pairs: <String, int>{});
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final (kind, key, id) = jobs[next++];
        final r = await session.probe(kind, key, id, maxAge: maxAge);
        (kind == 'n' ? res.nodes : res.pairs)[key] = r.ms;
        onResult?.call(kind, key, r.ms, r.byChecker);
      }
    }

    await Future.wait(List.generate(parallel, (_) => worker()));
    var network = pl.status;
    final all = [...res.nodes.values, ...res.pairs.values];
    if (all.isNotEmpty && all.every((ms) => ms < 0)) {
      await session.directAnswers();
      network = pl.status;
    }
    return (nodes: res.nodes, pairs: res.pairs, network: network);
  } finally {
    await session.stop();
  }
}

/// A throwaway sing-box that tests servers one at a time through the probe pool ([measureLatency]'s tester, and the
/// connect's pick, service.dart `connectPicks`): [nodes] as `t/<key>`, [pairs] as `p/<key>`, started on the first test
/// ([ensure]). Every result goes into [pool] under the server's identity ([serverIdentity]); a node that cannot be
/// dialled (the SOCKS stage fails) is dead at once, backup checks only for a reached node.
///
/// [finish] ends it without cutting a test short: it stops when the tests already started have ended (their results
/// go to the pool for Auto and the background ping); [stop] stops it now.
class TesterSession {
  TesterSession({
    required this.binary,
    required this.workDir,
    required this.nodes,
    this.pairs = const [],
    required this.pool,
    this.url = defaultTestUrl,
    this.checkers = const [],
    this.timeoutMs = 5000,
    this.boxFactory,
    this.pins = const {},
    this.nodeResolver,
    this.onFail,
    this.onWarn,
  });

  final String binary, workDir, url;
  final List<Map> nodes, pairs;
  final ProbePool pool;
  final List<String> checkers;
  final int timeoutMs;
  final BoxFactory? boxFactory;
  final Map<String, String> pins;
  final DnsCandidate? nodeResolver;
  final void Function(String tag, String reason)? onFail;

  /// A line for the journal (a warn) when the throwaway sing-box could not be stopped.
  final void Function(String line)? onWarn;

  BoxRunner? _sb;
  Future<Probe>? _starting;
  var _active = 0;
  var _finishing = false;
  var _stopped = false;

  /// Starts the throwaway sing-box (once); a start that fails throws.
  Future<Probe> ensure() => _starting ??= () async {
        final pr = Probe(await freePort())..onFail = onFail;
        final box = boxFactory != null ? boxFactory!(workDir) : SingBoxProcess(binary, workDir);
        _sb = box;
        await box.start(buildTesterConfig(nodes: nodes, pairs: pairs, probe: pr, pins: pins, nodeResolver: nodeResolver));
        return pr;
      }();

  /// One test of a node (`kind` `n`, tag `t/<key>`) or a pair (`p`) of pool identity [id]; the answer joins the pool.
  /// [maxAge]: a pool answer younger than that stands for the test.
  Future<PoolResult> probe(String kind, String key, String id, {Duration maxAge = Duration.zero}) async {
    final tag = '${kind == 'n' ? 't' : 'p'}/$key';
    _active++;
    try {
      final r = await pool.probeResult(id, (u) async => (await ensure()).delay(tag, u, timeoutMs: timeoutMs, unreachedThrows: true),
          url: url, checkers: checkers, maxAge: maxAge, checkerFanOut: 2);
      pool.ladder.observe(id, r.ms, pool.now); // a check of the user's: an unavailable node that answers is back (ladder.dart)
      return r;
    } finally {
      _active--;
      if (_finishing && _active == 0) unawaited(stop());
    }
  }

  /// The direct path tested through this sing-box (pool.dart): not answering writes a silent network into the pool
  /// (any answer anywhere takes it back). null = it could not be tested.
  Future<bool?> directAnswers() async {
    final up = await pool.directAnswers(
      url: url,
      checkers: checkers,
      timeoutMs: timeoutMs,
      runner: (u) async => (await ensure()).delay('direct', u, timeoutMs: timeoutMs),
    );
    if (up == false) pool.silent(true);
    return up;
  }

  /// Ends the session once the tests already started have ended (now, when none is running).
  void finish() {
    _finishing = true;
    if (_active == 0) unawaited(stop());
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _sb?.stop();
    } catch (e) {
      onWarn?.call('the throwaway test sing-box ($workDir) could not be stopped: $e');
    }
  }
}

/// Speed Test of one node (or one entry → exit pair) with a throwaway sing-box: its network
/// quality test (sbapi.dart; Apple's servers unless [configUrl]) through that outbound.
/// Every progress step goes to [onProgress]; ends with the final one. [cancel] completing
/// stops it early.
Future<void> speedTest({
  required String binary,
  required String workDir,
  Map? node,
  Map? pair,
  String configUrl = '',
  required void Function(NetworkQualityTestProgress p) onProgress,
  Future<void>? cancel,
  BoxFactory? boxFactory,
  Map<String, String> pins = const {},
  DnsCandidate? nodeResolver,
}) async {
  final sb = boxFactory != null ? boxFactory(workDir) : SingBoxProcess(binary, workDir);
  await sb.start(buildTesterConfig(nodes: [?node], pairs: [?pair], pins: pins, nodeResolver: nodeResolver));
  try {
    final tag = node != null ? 't/${node['key']}' : 'p/${pair!['key']}';
    final stream = sb.api!.speedTest(tag, configUrl: configUrl);
    final done = Completer<void>();
    final sub = stream.listen((p) {
      onProgress(p);
      if (p.isFinal && !done.isCompleted) done.complete();
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });
    cancel?.then((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      await sub.cancel();
    }
  } finally {
    await sb.stop();
  }
}
