import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'auto.dart';
import 'config.dart';
import 'exitip.dart';
import 'fetch.dart';
import 'merge.dart';
import 'parse/links.dart';
import 'runtime.dart';
import 'sysproxy.dart';
import 'traffic.dart';

/// jormd: the core behind a local HTTP API, so the HTML mockup can drive it as the
/// app's UI while there is no Flutter app. The mockup keeps its own state (sources,
/// profiles, chains, order) and stores it here as one snapshot; the core fetches and
/// parses subscriptions, builds sing-box configs, runs sing-box and measures latency.
///
/// Every /api call must carry `X-Jorm: 1` (a custom header forces a CORS preflight,
/// which this server never grants, so other web pages cannot drive it) and a loopback
/// Host (against DNS rebinding); with `--lan` the machine's own LAN addresses count too.
class Daemon {
  /// [clashPort], [exitCheck] and [sysProxy] are for tests (a free port; no probes past
  /// loopback; a fake system proxy, so a test never touches the real registry).
  Daemon({
    required this.singBox,
    required this.dataDir,
    required this.uiFile,
    this.lanHosts = const {},
    this.clashPort = 9090,
    this.exitCheck = checkExitIp,
    SystemProxy? sysProxy,
  })
      : main = SingBoxProcess(singBox, p.join(dataDir, 'run', 'main')),
        sysProxy = sysProxy ?? SystemProxy(File(p.join(dataDir, 'sysproxy.saved.json'))) {
    main.onExit = _crashed;
  }

  final String singBox;
  final String dataDir;
  final String uiFile;
  final Set<String> lanHosts;
  final SingBoxProcess main;
  final SystemProxy sysProxy;
  final int clashPort;
  final Future<Map<String, dynamic>> Function(int? proxyPort) exitCheck;

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  String? _error;
  String? _warning;
  int _pingSeq = 0;
  int _mixedPort = 2080;
  // Where traffic leaves: the tunnel's exit, or the machine's own IP while disconnected
  // (direct: true). null while checking, {ip, country…, direct} or {error, direct}.
  Map<String, dynamic>? _exit;
  int _exitSeq = 0;

  // What is connected, for the AutoService and a restart after a crash: the plan, the
  // system proxy asked for. null = not connected (or given up).
  Map<String, dynamic>? _plan;
  bool _sysWanted = false;
  AutoService? _auto;
  // sing-box stopped on its own: {attempt, of, code, next} while restarting it
  Map<String, dynamic>? _recovering;
  int _restarts = 0, _attempt = 0, _runSeq = 0;
  DateTime _upSince = DateTime.now();
  static const _backoff = [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 15)];
  // starts and stops of sing-box one at a time (a user's connect vs a crash restart)
  Future<void> _serial = Future.value();

  Future<T> _locked<T>(Future<T> Function() f) {
    final r = _serial.then((_) => f());
    _serial = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  Future<void> init() async {
    await Directory(dataDir).create(recursive: true);
    await sysProxy.restore(); // left set by a crash
    _recheckExit(); // the direct IP, shown on Home before any connect
  }

  Future<void> shutdown() async {
    _runSeq++;
    _stopAuto();
    await main.stop();
    await sysProxy.restore();
  }

  /// Auto in the core while connected (auto.dart). A move to another route or server
  /// changes where traffic leaves: the exit is checked again.
  void _startAuto(Map<String, dynamic> plan) {
    _stopAuto();
    final auto = _auto = AutoService(main, plan);
    auto.switches.listen((s) {
      main.note(s.isRoute ? 'auto: ${s.from} → ${s.to} (${s.reason})' : 'auto: ${s.route}: server ${s.from} → ${s.to} (${s.reason})');
      _recheckExit();
    });
    auto.start();
  }

  void _stopAuto() {
    _auto?.stop();
    _auto = null;
  }

  /// sing-box stopped on its own. The system proxy goes back at once (browsers would
  /// otherwise point at a dead port), then sing-box is started again with the same plan
  /// on the route Auto was on, up to [_backoff] tries; the count starts over once it ran
  /// for a minute.
  void _crashed(int code) {
    final plan = _plan;
    if (plan == null) return;
    final seq = _runSeq, at = _auto?.index;
    _stopAuto();
    main.note('sing-box stopped on its own (exit code $code)');
    if (DateTime.now().difference(_upSince) > const Duration(minutes: 1)) _attempt = 0;
    _recover(seq, at == null ? plan : {...plan, 'current': at}, code);
  }

  Future<void> _recover(int seq, Map<String, dynamic> plan, int code) async {
    _recovering = {'attempt': _attempt + 1, 'of': _backoff.length, 'code': code};
    try {
      await sysProxy.restore();
    } catch (e) {
      main.note('system proxy not restored: $e');
    }
    while (seq == _runSeq) {
      if (_attempt >= _backoff.length) {
        _recovering = null;
        _plan = null;
        _error = 'sing-box stopped (exit code $code) and did not start again after ${_backoff.length} tries';
        _recheckExit(); // traffic goes direct now
        return;
      }
      final wait = _backoff[_attempt++];
      _recovering = {'attempt': _attempt, 'of': _backoff.length, 'code': code, 'next': DateTime.now().add(wait).millisecondsSinceEpoch};
      await Future<void>.delayed(wait);
      final ok = await _locked(() async {
        if (seq != _runSeq) return true; // connected or disconnected meanwhile
        try {
          await main.start(buildConfig(plan, clashPort: clashPort), clashPort: clashPort);
        } catch (e) {
          main.note('restart $_attempt of ${_backoff.length} failed: $e');
          return false;
        }
        _plan = plan;
        _upSince = DateTime.now();
        _recovering = null;
        _restarts++;
        _warning = 'sing-box stopped (exit code $code) and was started again';
        if (_sysWanted) {
          try {
            _warning = await sysProxy.enable(_mixedPort) ?? _warning;
          } catch (e) {
            _warning = 'System proxy not set again: $e';
          }
        }
        _startAuto(plan);
        _recheckExit();
        return true;
      });
      if (ok) return;
    }
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
        'GET /api/traffic' => _traffic(),
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

  final _meter = TrafficMeter();

  /// Speed, session totals and open connections (see traffic.dart); `running: false`
  /// with zeros when sing-box is not up.
  Future<Map<String, dynamic>> _traffic() async {
    final conns = main.running ? await main.clashGet('/connections') : null;
    if (conns == null) {
      _meter.reset();
      return {'running': false, 'down': 0, 'up': 0, 'downTotal': 0, 'upTotal': 0, 'tcp': 0, 'udp': 0, 'conns': []};
    }
    final proxies = await main.clashGet('/proxies');
    return {'running': true, ..._meter.sample(conns, proxies, DateTime.now().millisecondsSinceEpoch)};
  }

  /// `connected` stays true while a crashed sing-box is being started again
  /// (`recovering`); `auto` = what Auto really uses and measured (auto.dart → toJson).
  Future<Map<String, dynamic>> _status() async => {
        'connected': main.running || _recovering != null,
        'systemProxy': sysProxy.isSet,
        'error': _error,
        'warning': _warning,
        'exit': _exit,
        'recovering': _recovering,
        'restarts': _restarts,
        'auto': await _autoState(),
      };

  Future<Map<String, dynamic>?> _autoState() async {
    final auto = _auto;
    if (auto == null || !main.running) return null;
    // the groups' `now` can change between checks (urltest re-picks on its own)
    if (DateTime.now().millisecondsSinceEpoch - (auto.refreshedAt ?? 0) > 1000) await auto.refresh();
    return identical(auto, _auto) ? auto.toJson() : null;
  }

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
        final e = await exitCheck(direct ? null : _mixedPort);
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
    final seq = ++_runSeq;
    _recovering = null;
    _stopAuto();
    _error = null;
    _warning = null;
    await _locked(() async {
      if (seq != _runSeq) return; // a newer connect / disconnect came in
      try {
        _plan = null;
        await main.start(buildConfig(plan, clashPort: clashPort), clashPort: clashPort);
        _plan = plan;
        _sysWanted = body['systemProxy'] == true;
        _upSince = DateTime.now();
        _attempt = 0;
        _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
        _startAuto(plan);
        _recheckExit();
        if (_sysWanted) {
          _warning = await sysProxy.enable(_mixedPort);
        } else {
          await sysProxy.restore();
        }
      } catch (e) {
        _error = '$e';
        await sysProxy.restore();
        rethrow;
      }
    });
    return _status();
  }

  Future<Map<String, dynamic>> _disconnect() async {
    final seq = ++_runSeq;
    _plan = null;
    _recovering = null;
    _stopAuto();
    await _locked(() async {
      if (seq == _runSeq) await main.stop();
    });
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
