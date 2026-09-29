import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'auto.dart';
import 'config.dart';
import 'device.dart';
import 'eventbook.dart';
import 'exitip.dart';
import 'logbook.dart';
import 'manual.dart';
import 'node.dart';
import 'parse/links.dart';
import 'plan.dart';
import 'probe.dart';
import 'rulesets.dart';
import 'runtime.dart';
import 'sbapi.dart';
import 'share.dart';
import 'state.dart';
import 'sysproxy.dart';
import 'traffic.dart';
import 'updater.dart';

/// jormd: the core behind a local HTTP API, so the HTML mockup can drive it as the
/// app's UI while there is no Flutter app. The mockup keeps its own state (sources,
/// profiles, chains, order) and stores it here as one snapshot; the core fetches and
/// parses subscriptions, builds sing-box configs, runs sing-box and measures latency.
///
/// Every /api call must carry `X-Jorm: 1` (a custom header forces a CORS preflight,
/// which this server never grants, so other web pages cannot drive it) and a loopback
/// Host (against DNS rebinding); with `--lan` the machine's own LAN addresses count too.
class Daemon {
  /// [exitCheck] and [sysProxy] are for tests (no probes past loopback; a fake system
  /// proxy, so a test never touches the real registry).
  Daemon({
    required this.singBox,
    required this.dataDir,
    required this.uiFile,
    this.lanHosts = const {},
    this.exitCheck = checkExitIp,
    SystemProxy? sysProxy,
  })
      : main = SingBoxProcess(singBox, p.join(dataDir, 'run', 'main')),
        sysProxy = sysProxy ?? SystemProxy(File(p.join(dataDir, 'sysproxy.saved.json'))),
        ruleSets = RuleSetCache(p.join(dataDir, 'rulesets')) {
    main.onExit = _crashed;
    main.onLog = (line) {
      log.singBox(line);
      _auto?.onLog(line);
    };
    ruleSets.onFailed = (tag, url, error) => _event('rules', 'ruleSetFailed', 'warn', {'tag': tag, 'url': url, 'error': error},
        note: 'Rule set $tag not downloaded ($url): $error');
    ruleSets.onUpdated = (tag) => _event('rules', 'ruleSetUpdated', 'info', {'tag': tag}, note: 'Rule set $tag updated');
  }

  final String singBox;
  final String dataDir;
  final String uiFile;
  final Set<String> lanHosts;
  final SingBoxProcess main;
  final SystemProxy sysProxy;
  final RuleSetCache ruleSets;
  final Future<Map<String, dynamic>> Function(int? proxyPort) exitCheck;

  /// sing-box output and the core's own notes (the Logs tab).
  final log = LogBook();

  /// What happened, structured (eventbook.dart): the Events tab and the notifications.
  late final events = EventBook(File(p.join(dataDir, 'events.jsonl')), log: log);

  File get _snapshot => File(p.join(dataDir, 'ui-state.json'));
  late final store = SnapshotStore(_snapshot);
  // Subscriptions update themselves on their periods, also with the UI closed.
  late final updater = SubscriptionUpdater(
    store: store,
    hwid: () => _hwid,
    proxyPort: () => main.running ? _mixedPort : null,
    onEvent: (type, data) => _event('sub', type, type == 'failed' ? 'error' : 'info', data,
        note: type == 'failed'
            ? 'Subscription ${data['name']} not updated: ${data['error']}'
            : 'Subscription ${data['name']} updated: +${data['added']} -${data['removed']}, ${data['total']} servers'),
  );
  late final Future<Map<String, String>> _hwid = deviceHeaders(dataDir);
  String? _error;
  String? _warning;
  int _pingSeq = 0;
  int _mixedPort = 2080;
  int? _tunnelPort; // tunnel-in: always through the tunnel (exit check, lists via VPN)
  Probe? _probe; // probe-in: Auto's latency tests (probe.dart)
  StreamSubscription<ClosedConnection>? _closed; // sing-box API: closed connections → Auto
  int _connectSeq = 0;
  final _deprecatedSeen = <String>{}; // the journal says each once per run; the raw log every time
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
  int _restarts = 0, _attempt = 0;
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
    events.load(); // trims an old journal at start
    await _sysOff(); // left set by a crash
    _recheckExit(); // the direct IP, shown on Home before any connect
    updater.start();
  }

  Future<void> shutdown() async {
    _connectSeq++;
    _stopAuto();
    updater.stop();
    await main.stop();
    await sysProxy.restore();
  }

  /// One journal entry; [note] also goes to the raw log first, so the event links to it.
  int _event(String cat, String type, String level, Map<String, dynamic> data, {bool own = false, String? note}) {
    if (note != null) log.note(level, note);
    return events.add(cat, type, level, data: data, own: own);
  }

  /// The system proxy on / back off, each one written to the journal (`core/sysProxy`,
  /// `on` = what was asked for; `error` = it did not work). Returns [SystemProxy.enable]'s
  /// warning; errors go on to the caller.
  Future<String?> _sysOn({required bool own}) async {
    try {
      final w = await sysProxy.enable(_mixedPort);
      _event('core', 'sysProxy', 'info', {'on': true}, own: own, note: 'System proxy on 127.0.0.1:$_mixedPort');
      return w;
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': true, 'error': '$e'}, own: own, note: 'System proxy not set: $e');
      rethrow;
    }
  }

  Future<void> _sysOff({bool own = false}) async {
    final was = sysProxy.isSet;
    try {
      await sysProxy.restore();
    } catch (e) {
      _event('core', 'sysProxy', 'warn', {'on': false, 'error': '$e'}, own: own, note: 'System proxy not restored: $e');
      rethrow;
    }
    if (was) _event('core', 'sysProxy', 'info', {'on': false}, own: own, note: 'System proxy back off');
  }

  /// Auto in the core while connected (auto.dart). A move to another route or server
  /// changes where traffic leaves: the exit is checked again.
  void _startAuto(Map<String, dynamic> plan) {
    _stopAuto();
    final auto = _auto = AutoService(main.api!, plan,
        delay: (tag, url, t) async => _probe == null ? -1 : _probe!.delay(tag, url, timeoutMs: t),
        reach: (tag, dest) async => _probe == null ? null : probeReach(_probe!, tag, dest),
        note: main.note);
    // requests that failed: sing-box's API service streams every closed connection
    _closed = main.api!.closedConnections().listen(auto.onClosed, onError: (Object e) => main.note('auto: connection events stopped: $e'));
    auto.switches.listen((s) {
      main.note(s.isRoute ? 'auto: ${s.from} → ${s.to} (${s.reason})' : 'auto: ${s.route}: server ${s.from} → ${s.to} (${s.reason})');
      if (s.reason == 'fastest') {
        events.add('auto', 'fastest', 'info', data: {'route': s.route, 'from': s.from, 'to': s.to});
      } else {
        events.add('auto', 'switched', 'info', data: {'route': ?s.route, 'from': s.from, 'to': s.to, 'reason': s.reason});
      }
      _recheckExit();
    });
    auto.unstable.listen((u) {
      main.note('auto: ${u.id} is unstable (${u.strikes} drops), back to it after ${u.holdMs ~/ 60000} min of answers');
      events.add('auto', 'unstable', 'warn', data: {'id': u.id, 'strikes': u.strikes, 'holdMs': u.holdMs});
    });
    auto.blocked.listen((b) {
      final at = b.dest.lastIndexOf(':'), port = at < 0 ? null : int.tryParse(b.dest.substring(at + 1));
      events.add('site', 'blocked', 'warn', data: {
        'host': port == null ? b.dest : b.dest.substring(0, at),
        'port': ?port,
        'entry': b.route,
        'server': b.server,
        'dest': b.dest,
        'via': b.via,
      });
    });
    auto.net.listen((n) {
      final (type, level) = switch (n.kind) {
        'lost' => ('lost', 'warn'),
        'restored' => ('restored', 'info'),
        'offline' => ('offline', 'warn'),
        _ => ('online', 'info'),
      };
      events.add('conn', type, level, data: {'downMs': ?n.downMs});
    });
    auto.start();
  }

  void _stopAuto() {
    unawaited(_closed?.cancel());
    _closed = null;
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
    final seq = _connectSeq, at = _auto?.index;
    _stopAuto();
    main.note('sing-box stopped on its own (exit code $code)');
    events.add('core', 'crashed', 'error', data: {'code': code});
    if (DateTime.now().difference(_upSince) > const Duration(minutes: 1)) _attempt = 0;
    _recover(seq, at == null ? plan : {...plan, 'current': at}, code);
  }

  Future<void> _recover(int seq, Map<String, dynamic> plan, int code) async {
    _recovering = {'attempt': _attempt + 1, 'of': _backoff.length, 'code': code};
    try {
      await _sysOff();
    } catch (e) {
      main.note('system proxy not restored: $e');
    }
    while (seq == _connectSeq) {
      if (_attempt >= _backoff.length) {
        _recovering = null;
        _plan = null;
        _tunnelPort = null;
        _error = 'sing-box stopped (exit code $code) and did not start again after ${_backoff.length} tries';
        _event('conn', 'disconnected', 'error', {'by': 'error', 'reason': _error}, note: 'Disconnected: $_error');
        _recheckExit(); // traffic goes direct now
        return;
      }
      final wait = _backoff[_attempt++];
      _recovering = {'attempt': _attempt, 'of': _backoff.length, 'code': code, 'next': DateTime.now().add(wait).millisecondsSinceEpoch};
      await Future<void>.delayed(wait);
      final ok = await _locked(() async {
        if (seq != _connectSeq) return true; // connected or disconnected meanwhile
        final RuleSetFetch lists;
        final warnings = ['sing-box stopped (exit code $code) and was started again'];
        try {
          final (l, w) = await _startSingBox(plan); // the same path as a connect
          lists = l;
          warnings.addAll(w);
        } catch (e) {
          main.note('restart $_attempt of ${_backoff.length} failed: $e');
          events.add('core', 'restartFailed', 'error', data: {'attempt': _attempt, 'error': '$e'});
          return false;
        }
        _plan = plan;
        _upSince = DateTime.now();
        _recovering = null;
        _restarts++;
        _event('core', 'restarted', 'info', {'attempt': _attempt}, note: 'sing-box started again (attempt $_attempt)');
        if (_sysWanted) {
          try {
            warnings.add(await _sysOn(own: false) ?? '');
          } catch (e) {
            warnings.add('System proxy not set again: $e');
          }
        }
        _warning = joinWarnings(warnings);
        _startAuto(plan);
        _recheckExit();
        _refreshLists(seq, plan, lists);
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
      if (req.method == 'POST' && path == '/api/speedtest') return await _speedTest(body, res);
      if (req.method == 'DELETE' && (path == '/api/connections' || path.startsWith('/api/connections/'))) {
        return await _send(res, 200, await _closeConnections(path.length > 17 ? Uri.decodeComponent(path.substring(17)) : null));
      }
      final out = await switch ('${req.method} $path') {
        'GET /api/state' => _state(),
        'PUT /api/state' => _saveState(body),
        'GET /api/status' => _status(),
        'GET /api/traffic' => _traffic(),
        'GET /api/log' => Future.value(log.since(int.tryParse(req.uri.queryParameters['since'] ?? ''))),
        'DELETE /api/log' => Future(() {
            log.clear();
            return {'ok': true};
          }),
        'GET /api/events' => Future.value(events.since(int.tryParse(req.uri.queryParameters['since'] ?? ''))),
        'POST /api/events' => Future(() => _postEvent(body)),
        'DELETE /api/events' => Future(() {
            events.clear();
            return {'ok': true};
          }),
        'GET /api/version' => _version(),
        'POST /api/node' => Future(() => {'node': _manualNode(body).toJson()}),
        'POST /api/share' => Future.value({'link': _share(body)}),
        'POST /api/sources/fetch' => _fetch(body),
        'POST /api/parse' => Future.value(_parse(body)),
        'POST /api/connect' => _connect(body),
        'POST /api/disconnect' => _disconnect(),
        'POST /api/auto' => _autoSettings(body),
        'POST /api/exit' => Future(() {
            _recheckExit();
            return _status();
          }),
        _ => null,
      };
      if (out == null) return await _send(res, 404, {'error': 'no route ${req.method} $path'});
      return await _send(res, 200, out);
    } on FormatException catch (e) {
      return await _send(res, 400, {'error': e.message}); // a message for the user (manual server form)
    } catch (e, st) {
      log.note('error', '${req.method} ${req.uri.path}: $e');
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
        'snapshot': await store.read(),
        'status': await _status(),
      };

  // A source the timer updated after the UI last looked keeps the core's server fields
  // (state.dart).
  Future<Map<String, dynamic>> _saveState(Map<String, dynamic> body) async {
    await store.save((body['snapshot'] as Map?)?.cast<String, dynamic>());
    return {'ok': true};
  }

  /// Speed, session totals and open connections (see traffic.dart); `running: false`
  /// with zeros when sing-box is not up.
  Future<Map<String, dynamic>> _traffic() async {
    final api = main.api;
    if (!main.running || api == null) {
      return {'running': false, 'down': 0, 'up': 0, 'downTotal': 0, 'upTotal': 0, 'tcp': 0, 'udp': 0, 'conns': []};
    }
    return {'running': true, ...trafficOf(api)};
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
        'sourcesRev': store.rev, // moves when the timer updated a subscription: the UI reloads them
      };

  Future<Map<String, dynamic>?> _autoState() async {
    final auto = _auto;
    if (auto == null || !main.running) return null;
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
        final e = await exitCheck(direct ? null : _tunnelPort ?? _mixedPort);
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

  /// body: {sid, source: {url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid,
  /// filter, channel}, rediscover} → {patch, title, notModified, via} (updater.dart).
  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> body) async {
    final s = ((body['source'] as Map?) ?? const {}).cast<String, dynamic>();
    return updater.guard(
      body['sid'] as String?,
      () async => updateSubscription(
        s,
        hwid: s['hwid'] == true ? await _hwid : null,
        proxyPort: main.running ? _mixedPort : null,
        rediscover: body['rediscover'] == true,
      ),
    );
  }

  Map<String, dynamic> _parse(Map<String, dynamic> body) =>
      {'nodes': [for (final n in parseLinks('${body['text'] ?? ''}')) n.toJson()]};

  /// The one way sing-box is started, by a connect and by a restart after a crash: the
  /// rule lists on disk first (ones via VPN that are missing wait for the tunnel — the
  /// old one, if it still runs), a fresh tunnel-in port, the config. The lists used and
  /// the config's warnings.
  Future<(RuleSetFetch, List<String>)> _startSingBox(Map<String, dynamic> plan) async {
    final lists = await ruleSets.ensureFor(plan, proxyPort: main.running ? _tunnelPort : null);
    final warnings = <String>[];
    final tunnelPort = await freePort();
    final probe = Probe(await freePort());
    await main.start(
        buildConfig(plan, tunnelPort: tunnelPort, probe: probe, ruleSetFiles: lists.files, warnings: warnings));
    // what a later sing-box will no longer take in this config
    try {
      for (final w in await main.api!.deprecatedWarnings()) {
        log.note('warn', 'sing-box: $w');
        if (_deprecatedSeen.add(w)) events.add('core', 'deprecated', 'warn', data: {'text': w});
      }
    } catch (_) {}
    _probe = probe;
    _mixedPort = (plan['mixedPort'] as num?)?.toInt() ?? 2080;
    _tunnelPort = tunnelPort;
    return (lists, warnings);
  }

  /// Through the tunnel now: missing lists (then a restart picks them up, on the route
  /// Auto is on), stale ones (replaced in place, sing-box reloads a local rule set itself).
  void _refreshLists(int seq, Map<String, dynamic> plan, RuleSetFetch lists) {
    ruleSets.ensureFor(plan, proxyPort: _tunnelPort, refresh: true).then((now) {
      if (seq == _connectSeq && main.running && now.files.keys.any((t) => !lists.files.containsKey(t))) {
        final at = _auto?.index;
        _connect({'plan': at == null ? plan : {...plan, 'current': at}, 'systemProxy': _sysWanted}, own: false).then((_) {}, onError: (_) {});
      }
    }, onError: (_) {});
  }

  /// body: {plan (see config.dart), systemProxy: bool}. [own]: the user asked (the journal
  /// marks it so no notification comes of it); the reconnect that picks up lists is not.
  Future<Map<String, dynamic>> _connect(Map<String, dynamic> body, {bool own = true}) async {
    final plan = (body['plan'] as Map).cast<String, dynamic>();
    final seq = ++_connectSeq;
    _recovering = null;
    _stopAuto();
    _error = null;
    _warning = null;
    await _locked(() async {
      if (seq != _connectSeq) return; // a newer connect / disconnect came in
      try {
        _plan = null;
        final (lists, warnings) = await _startSingBox(plan);
        _plan = plan;
        _sysWanted = body['systemProxy'] == true;
        _upSince = DateTime.now();
        _attempt = 0;
        _startAuto(plan);
        _recheckExit();
        if (_sysWanted) {
          warnings.add(await _sysOn(own: own) ?? '');
        } else {
          await _sysOff(own: own);
        }
        _warning = joinWarnings(warnings);
        log.note('info', 'Connected: ${plan['kind']}, proxy on 127.0.0.1:$_mixedPort${_sysWanted ? ', system proxy on' : ''}');
        if (_warning != null) log.note('warn', _warning!);
        _refreshLists(seq, plan, lists);
        events.add('conn', 'connected', 'info', own: own, data: _connectedData(plan));
      } catch (e) {
        _error = '$e';
        log.note('error', 'Connect failed: $e');
        events.add('conn', 'connectFailed', 'error', own: own, data: {'reason': '$e'});
        await _sysOff(own: own);
        rethrow;
      }
    });
    return _status();
  }

  // conn/connected: the entry Auto starts on and its server when known (a Fastest group
  // has none until urltest picked), the mode (TUN is not built yet) and the routing.
  Map<String, dynamic> _connectedData(Map<String, dynamic> plan) {
    final routes = planRoutes(plan);
    final i = planCurrent(plan, routes.length);
    final server = _auto?.toJson()['server'];
    return {
      'entry': '${routes[i]['id'] ?? routeTag(i)}',
      'server': ?server,
      'mode': plan['mode'] == 'tun' ? 'tun' : 'proxy',
      'route': plan['global'] == true ? 'global' : 'rules',
    };
  }

  /// body: {auto} — Settings → Auto mode changed while connected: the running AutoService
  /// takes it at its next round, no reconnect (none of it is in the sing-box config).
  Future<Map<String, dynamic>> _autoSettings(Map<String, dynamic> body) async {
    final plan = _plan, auto = body['auto'];
    if (plan != null && auto is Map) {
      _plan = {...plan, 'auto': auto};
      _auto?.settings = AutoSettings.fromPlan(_plan!);
    }
    return _status();
  }

  Future<Map<String, dynamic>> _disconnect() async {
    final seq = ++_connectSeq;
    final was = main.running || _plan != null || _recovering != null;
    _plan = null;
    _recovering = null;
    _stopAuto();
    await _locked(() async {
      if (seq == _connectSeq) await main.stop();
    });
    _tunnelPort = null;
    log.note('info', 'Disconnected');
    if (was) events.add('conn', 'disconnected', 'info', own: true, data: {'by': 'user'});
    await _sysOff(own: true);
    _recheckExit(); // now the direct IP
    _error = null;
    _warning = null;
    return _status();
  }

  static final _eventType = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');
  static const _eventDataMax = 4096; // JSON characters

  /// body: {cat, type, level, own?, data?} → {id}: an event the UI knows first (the
  /// subscription updates it ran itself, the user's own actions). Not linked to a raw line.
  /// A bad shape is a 400 with the reason.
  Map<String, dynamic> _postEvent(Map<String, dynamic> body) {
    final cat = body['cat'], type = body['type'], level = body['level'], own = body['own'], data = body['data'] ?? const {};
    if (cat is! String || !EventBook.cats.contains(cat)) throw const FormatException('bad event cat');
    if (type is! String || !_eventType.hasMatch(type)) throw const FormatException('bad event type');
    if (level is! String || !EventBook.levels.contains(level)) throw const FormatException('bad event level');
    if (own != null && own is! bool) throw const FormatException('bad event own');
    if (data is! Map) throw const FormatException('event data must be an object');
    if (jsonEncode(data).length > _eventDataMax) throw const FormatException('event data too large');
    return {'id': events.add(cat, type, level, data: data.cast<String, dynamic>(), own: own == true, link: false)};
  }

  String? _singBoxVer;
  Future<Map<String, dynamic>> _version() async => {
        'core': coreVersion,
        'singBox': _singBoxVer ??= await singBoxVersion(singBox),
        'dataDir': dataDir,
        'dart': Platform.version.split(' ').first,
        'os': Platform.operatingSystem,
      };

  /// body: {protocol, address, port, secret, name, outbound?, unsupported?} — see manual.dart.
  Node _manualNode(Map<String, dynamic> body) => manualNode(
        protocol: '${body['protocol'] ?? ''}',
        address: '${body['address'] ?? ''}',
        port: int.tryParse('${body['port'] ?? ''}') ?? 0,
        secret: '${body['secret'] ?? ''}',
        name: '${body['name'] ?? ''}',
        outbound: (body['outbound'] as Map?)?.cast<String, dynamic>(),
        unsupported: body['unsupported'] as String?,
      );

  /// body: {outbound, name, flag, unsupported?} → the share link, or null (see share.dart).
  String? _share(Map<String, dynamic> body) => shareLink(
        ((body['outbound'] as Map?) ?? const {}).cast<String, dynamic>(),
        name: '${body['name'] ?? ''}',
        flag: '${body['flag'] ?? ''}',
        unsupported: body['unsupported'] as String?,
      );

  /// Closes one open connection ([id] from /api/traffic) or all of them, through sing-box's
  /// API service (with its secret, runtime.dart). Not connected: nothing to close.
  Future<Map<String, dynamic>> _closeConnections(String? id) async {
    final api = main.api;
    if (!main.running || api == null) return {'ok': false};
    if (!await (id == null ? api.closeAllConnections() : api.closeConnection(id))) throw SingBoxError('sing-box did not answer');
    log.note('info', id == null ? 'Closed all connections' : 'Closed connection $id');
    return {'ok': true};
  }

  /// body: {nodes: [{key, outbound}], pairs: [{key, entry: {outbound}, exit: {outbound}}], url?}
  /// Streams one NDJSON line per result as soon as it is measured —
  /// `{"kind":"n"|"p","key":…,"ms":…}` (-1 = no answer) — then `{"done":true}`,
  /// or `{"error":…}` if the tester could not start.
  /// body: {node: {key, outbound}} or {pair: {key, entry: {outbound}, exit: {outbound}}},
  /// configUrl? Streams NDJSON as the test goes — `{phase (0 latency, 1 download,
  /// 2 upload, 3 done), down, up (bit/s), downRpm, upRpm, latency (ms), elapsed (ms),
  /// final}` — the last with `final: true` (and `error` when it failed); `{"error":…}`
  /// when the tester could not start. Stops when the page goes away.
  Future<void> _speedTest(Map<String, dynamic> body, HttpResponse res) async {
    res.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    res.bufferOutput = false;
    final gone = Completer<void>();
    void line(Object o) {
      if (gone.isCompleted) return;
      try {
        res.write('${jsonEncode(o)}\n');
      } catch (_) {
        gone.complete();
      }
    }

    unawaited(res.done.then((_) {}, onError: (_) {}).whenComplete(() {
      if (!gone.isCompleted) gone.complete();
    }));
    try {
      await speedTest(
        binary: singBox,
        workDir: p.join(dataDir, 'run', 'speed'),
        node: body['node'] as Map?,
        pair: body['pair'] as Map?,
        configUrl: '${body['configUrl'] ?? ''}',
        cancel: gone.future,
        onProgress: (x) => line({
          'phase': x.phase,
          'down': x.downloadCapacity.toInt(),
          'up': x.uploadCapacity.toInt(),
          'downRpm': x.downloadRPM,
          'upRpm': x.uploadRPM,
          'latency': x.idleLatencyMs,
          'elapsed': x.elapsedMs.toInt(),
          'final': x.isFinal,
          if (x.error.isNotEmpty) 'error': x.error,
        }),
      );
    } catch (e) {
      line({'error': '$e', 'final': true});
    }
    try {
      await res.close();
    } catch (_) {}
  }

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
          checkers: planCheckers({'urlTest': body}),
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
