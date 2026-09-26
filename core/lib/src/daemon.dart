import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'exitip.dart';
import 'fetch.dart';
import 'merge.dart';
import 'parse/links.dart';
import 'runtime.dart';
import 'sysproxy.dart';

/// jormd: the core behind a local HTTP API, so the HTML mockup can drive it as the
/// app's UI while there is no Flutter app. The mockup keeps its own state (sources,
/// profiles, chains, order) and stores it here as one snapshot; the core fetches and
/// parses subscriptions, builds sing-box configs, runs sing-box and measures latency.
///
/// Every /api call must carry `X-Jorm: 1` (a custom header forces a CORS preflight,
/// which this server never grants, so other web pages cannot drive it) and a loopback
/// Host (against DNS rebinding); with `--lan` the machine's own LAN addresses count too.
class Daemon {
  Daemon({required this.singBox, required this.dataDir, required this.uiFile, this.lanHosts = const {}})
      : main = SingBoxProcess(singBox, p.join(dataDir, 'run', 'main')),
        sysProxy = SystemProxy(File(p.join(dataDir, 'sysproxy.saved.json')));

  final String singBox;
  final String dataDir;
  final String uiFile;
  final Set<String> lanHosts;
  final SingBoxProcess main;
  final SystemProxy sysProxy;
  static const clashPort = 9090;

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  String? _error;
  String? _warning;
  int _pingSeq = 0;
  int _mixedPort = 2080;
  // Where traffic leaves: the tunnel's exit, or the machine's own IP while disconnected
  // (direct: true). null while checking, {ip, country…, direct} or {error, direct}.
  Map<String, dynamic>? _exit;
  int _exitSeq = 0;

  Future<void> init() async {
    await Directory(dataDir).create(recursive: true);
    await sysProxy.restore(); // left set by a crash
    _recheckExit(); // the direct IP, shown on Home before any connect
  }

  Future<void> shutdown() async {
    await main.stop();
    await sysProxy.restore();
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      final host = (req.headers.host ?? '').toLowerCase();
      if (host != '127.0.0.1' && host != 'localhost' && !lanHosts.contains(host)) return await _send(res, 403, {'error': 'bad host'});
      final path = req.uri.path;
      if (req.method == 'GET' && (path == '/' || path == '/index.html')) return await _serveUi(res);
      if (!path.startsWith('/api/')) return await _send(res, 404, {'error': 'not found'});
      if (req.headers.value('x-jorm') != '1') return await _send(res, 403, {'error': 'missing X-Jorm header'});
      final body = req.method == 'POST' || req.method == 'PUT'
          ? (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      if (req.method == 'POST' && path == '/api/ping') return await _ping(body, res);
      final out = await switch ('${req.method} $path') {
        'GET /api/state' => _state(),
        'PUT /api/state' => _saveState(body),
        'GET /api/status' => _status(),
        'GET /api/log' => Future.value({'lines': main.logs.toList()}),
        'POST /api/sources/fetch' => _fetch(body),
        'POST /api/parse' => Future.value(_parse(body)),
        'POST /api/connect' => _connect(body),
        'POST /api/disconnect' => _disconnect(),
        'POST /api/exit' => Future(() {
            _recheckExit();
            return _status();
          }),
        _ => null,
      };
      if (out == null) return await _send(res, 404, {'error': 'no route ${req.method} $path'});
      return await _send(res, 200, out);
    } catch (e, st) {
      stderr.writeln('[jormd] ${req.method} ${req.uri.path}: $e\n$st');
      return await _send(res, 500, {'error': '$e'});
    }
  }

  Future<void> _send(HttpResponse res, int code, Object body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    res.write(jsonEncode(body));
    await res.close();
  }

  // The mockup, read on every request so a rebuild shows on reload. The flag tells it
  // to use the core instead of its mock data before its first line runs.
  Future<void> _serveUi(HttpResponse res) async {
    final html = await File(uiFile).readAsString();
    res.headers.contentType = ContentType.html;
    res.headers.set('Cache-Control', 'no-store');
    res.write(html.replaceFirst('<script>', '<script>window.JORMD = true;</script>\n<script>'));
    await res.close();
  }

  Future<Map<String, dynamic>> _state() async => {
        'snapshot': _snapshot.existsSync() ? jsonDecode(await _snapshot.readAsString()) : null,
        'status': await _status(),
      };

  Future<Map<String, dynamic>> _saveState(Map<String, dynamic> body) async {
    final tmp = File('${_snapshot.path}.tmp');
    await tmp.writeAsString(jsonEncode(body['snapshot']));
    await tmp.rename(_snapshot.path);
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _status() async => {
        'connected': main.running,
        'systemProxy': sysProxy.isSet,
        'error': _error,
        'warning': _warning,
        'exit': _exit,
      };

  /// Asks where traffic leaves: through the tunnel after every (re)connect, directly at
  /// start and after a disconnect, and on demand. A check that finishes after a newer one
  /// started is dropped.
  /// Every service failing at once, fast, means the tunnel itself is not carrying yet (a
  /// urltest group still on an untested dead server right after connect): ask again in a
  /// couple of seconds, for up to 15 s, before reporting the error.
  void _recheckExit() {
    final seq = ++_exitSeq;
    _exit = null;
    final direct = !main.running;
    final since = Stopwatch()..start();
    Future<void> attempt() async {
      final sw = Stopwatch()..start();
      try {
        final e = await checkExitIp(direct ? null : _mixedPort);
        if (seq == _exitSeq) _exit = {...e, 'direct': direct, 'at': DateTime.now().millisecondsSinceEpoch};
      } catch (e) {
        if (seq != _exitSeq) return;
        if (!direct && sw.elapsed < const Duration(seconds: 3) && since.elapsed < const Duration(seconds: 15) && main.running) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (seq == _exitSeq) return attempt();
          return;
        }
        _exit = {'error': '$e', 'direct': direct};
      }
    }

    attempt();
  }

  /// body: {url, userAgent, strategy, discoveredAt, prev: {nodes, gone}}
  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> body) async {
    final prev = (body['prev'] as Map?) ?? const {};
    List<Map<String, dynamic>> maps(Object? l) => [for (final x in (l as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    final prevNodes = maps(prev['nodes']);
    final r = await fetchSubscription(
      body['url'] as String,
      userAgent: (body['userAgent'] as String?) ?? 'Auto',
      strategy: maps(body['strategy']),
      discoveredAt: (body['discoveredAt'] as num?)?.toInt() ?? 0,
      prevCount: prevNodes.length,
    );
    if (r.notModified) return r.toJson();
    final m = mergeUpdate(prevNodes, maps(prev['gone']), r.nodes);
    return {...r.toJson(), 'nodes': m.nodes, 'gone': m.gone};
  }

  Map<String, dynamic> _parse(Map<String, dynamic> body) =>
      {'nodes': [for (final n in parseLinks('${body['text'] ?? ''}')) n.toJson()]};

  /// body: {plan (see config.dart), systemProxy: bool}
  Future<Map<String, dynamic>> _connect(Map<String, dynamic> body) async {
    final plan = (body['plan'] as Map).cast<String, dynamic>();
    _error = null;
    _warning = null;
    try {
      await main.start(buildConfig(plan, clashPort: clashPort), clashPort: clashPort);
      _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
      _recheckExit();
      if (body['systemProxy'] == true) {
        _warning = await sysProxy.enable((plan['mixedPort'] as num?)?.toInt() ?? 2080);
      } else {
        await sysProxy.restore();
      }
    } catch (e) {
      _error = '$e';
      await sysProxy.restore();
      rethrow;
    }
    return _status();
  }

  Future<Map<String, dynamic>> _disconnect() async {
    await main.stop();
    await sysProxy.restore();
    _recheckExit(); // now the direct IP
    _error = null;
    _warning = null;
    return _status();
  }

  /// body: {nodes: [{key, outbound}], pairs: [{key, entry: {outbound}, exit: {outbound}}], url?}
  /// Streams one NDJSON line per result as soon as it is measured —
  /// `{"kind":"n"|"p","key":…,"ms":…}` (-1 = no answer) — then `{"done":true}`,
  /// or `{"error":…}` if the tester could not start.
  Future<void> _ping(Map<String, dynamic> body, HttpResponse res) async {
    final nodes = (body['nodes'] as List? ?? const []).cast<Map>();
    final pairs = (body['pairs'] as List? ?? const []).cast<Map>();
    res.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    res.bufferOutput = false;
    void line(Object o) => res.write('${jsonEncode(o)}\n');
    try {
      if (nodes.isNotEmpty || pairs.isNotEmpty) {
        await measureLatency(
          binary: singBox,
          workDir: p.join(dataDir, 'run', 'ping-${_pingSeq++ % 8}'),
          nodes: nodes,
          pairs: pairs,
          url: (body['url'] as String?) ?? defaultTestUrl,
          // bufferOutput is off: every line leaves at once.
          onResult: (kind, key, ms) => line({'kind': kind, 'key': key, 'ms': ms}),
        );
      }
      line({'done': true});
    } catch (e) {
      line({'error': '$e'});
    }
    await res.close();
  }
}
