import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'eventbook.dart';
import 'exitip.dart';
import 'logbook.dart';
import 'pool.dart';
import 'report_upload.dart';
import 'rulesets.dart';
import 'runtime.dart';
import 'service.dart';
import 'state.dart';
import 'sysproxy.dart';
import 'updater.dart';

/// jormd: the core behind a local HTTP API, so the HTML mockup can drive it as the
/// app's UI while there is no Flutter app. The mockup keeps its own state (sources,
/// profiles, chains, order) and stores it as one snapshot; the core ([CoreService]) fetches
/// and parses subscriptions, builds sing-box configs, runs sing-box and measures latency.
///
/// This class is only the HTTP adapter over a [CoreService]: routing, JSON, headers, the
/// mockup file. Every /api call must carry `X-Jorm: 1` (a custom header forces a CORS
/// preflight, which this server never grants, so other web pages cannot drive it) and a
/// loopback Host (against DNS rebinding); with `--lan` the machine's own LAN addresses count too.
class Daemon {
  /// A daemon over its own [CoreService]. [exitCheck], [sysProxy], [process], [timer], [now]
  /// and [isElevated] are for tests (no probes past loopback; a fake system proxy, so a test
  /// never touches the real registry; a fake sing-box process; the restart waits and the clock
  /// under the test's control; whether the process counts as elevated, which TUN needs).
  /// [reportUploader]: where "Send report" goes; none = `not-configured` (bin/jormd.dart plugs the
  /// [HttpReportUploader]).
  Daemon({
    required String singBox,
    required String dataDir,
    required this.uiFile,
    this.lanHosts = const {},
    Future<Map<String, dynamic>> Function(int? proxyPort) exitCheck = checkExitIp,
    SystemProxyBackend? sysProxy,
    BoxRunner? process,
    Timer Function(Duration, void Function())? timer,
    DateTime Function()? now,
    bool Function()? isElevated,
    ReportUploader? reportUploader,
  }) : service = CoreService(
          singBox: singBox,
          dataDir: dataDir,
          runner: process,
          sysProxy: sysProxy,
          exitCheck: exitCheck,
          timer: timer,
          now: now,
          isElevated: isElevated,
          reportUploader: reportUploader,
        );

  /// A daemon over a [CoreService] made elsewhere (its platform parts injected).
  Daemon.over(this.service, {required this.uiFile, this.lanHosts = const {}});

  final CoreService service;
  final String uiFile;
  final Set<String> lanHosts;

  String get singBox => service.singBox;
  String get dataDir => service.dataDir;

  /// The core's parts, as the CLI and the tests reach for them.
  BoxRunner get main => service.runner;
  LogBook get log => service.logBook;
  EventBook get events => service.eventBook;
  SnapshotStore get store => service.store;
  SubscriptionUpdater get updater => service.updater;
  ProbePool get pool => service.pool;
  RuleSetCache get ruleSets => service.ruleSets;

  Future<void> init() => service.init();

  Future<void> shutdown() => service.dispose();

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
          ? await _readBody(req)
          : const <String, dynamic>{};
      if (req.method == 'POST' && path == '/api/ping') return await _ndjson(res, service.ping(body));
      if (req.method == 'POST' && path == '/api/speedtest') return await _ndjson(res, service.speedTest(body));
      if (req.method == 'DELETE' && (path == '/api/connections' || path.startsWith('/api/connections/'))) {
        return await _send(res, 200, await service.closeConnections(path.length > 17 ? Uri.decodeComponent(path.substring(17)) : null));
      }
      final since = int.tryParse(req.uri.queryParameters['since'] ?? '');
      // `conns=0`: the log answer leaves the flood of connection lines out (and counts them in `hidden`)
      final conns = req.uri.queryParameters['conns'] != '0';
      final out = await switch ('${req.method} $path') {
        'GET /api/state' => service.state(),
        'PUT /api/state' => service.saveState((body['snapshot'] as Map?)?.cast<String, dynamic>()),
        'GET /api/status' => service.status(),
        'POST /api/network' => Future(() => service.setNetwork(body)),
        'GET /api/traffic' => service.traffic(),
        'GET /api/log' => Future.value(service.log(since: since, conns: conns)),
        'DELETE /api/log' => Future(() {
            service.clearLog();
            return {'ok': true};
          }),
        'GET /api/events' => Future.value(service.events(since: since)),
        'POST /api/events' => Future(() => service.postEvent(body)),
        'DELETE /api/events' => Future(() {
            service.clearEvents();
            return {'ok': true};
          }),
        'POST /api/site-check' => service.siteCheck(body),
        'POST /api/check-now' => service.checkNow(_eventId(body)),
        'POST /api/rule-sets/retry' => service.retryRuleSets(_eventId(body)),
        'GET /api/version' => service.version(),
        // the support report (report.dart); POST may carry {appInfo} (what only the page knows)
        'GET /api/report' => service.report(),
        'POST /api/report' => service.report(appInfo: ((body['appInfo'] as Map?) ?? const {}).cast<String, dynamic>()),
        'POST /api/report/send' => service.sendReport(
            note: '${body['note'] ?? ''}', appInfo: ((body['appInfo'] as Map?) ?? const {}).cast<String, dynamic>()),
        'POST /api/report/cancel' => service.cancelReport(),
        'POST /api/node' => Future(() => {'node': service.manualNode(body).toJson()}),
        'POST /api/share' => Future.value({'link': service.share(body)}),
        'POST /api/sources/fetch' => service.fetchSource(body),
        'POST /api/sources/import' => Future(() => service.addSourceFromText(body)),
        'POST /api/parse' => Future.value(service.parse(body)),
        'POST /api/connect' => service.connect(body),
        'POST /api/disconnect' => service.disconnect(
            error: body['error'] is Map ? (body['error'] as Map).cast<String, dynamic>() : null,
            op: body['op'] is Map ? (body['op'] as Map).cast<String, dynamic>() : null),
        'POST /api/sysproxy/release' => service.releaseSysProxy(),
        'POST /api/retry' => service.retry(),
        'POST /api/killswitch' => service.killSwitchSettings(body),
        'POST /api/auto' => service.autoSettings(body),
        'POST /api/dns/auto' => service.dnsAutoSetting(body),
        'POST /api/dns/ping' => service.pingDnsSides(body),
        'POST /api/exit' => service.recheckExit(),
        _ => null,
      };
      if (out == null) return await _send(res, 404, {'error': 'no route ${req.method} $path'});
      return await _send(res, 200, out);
    } on FormatException catch (e) {
      return await _send(res, 400, {'error': e.message}); // a message for the user (manual server form)
    } catch (e, st) {
      service.logBook.note('error', '${req.method} ${req.uri.path}: $e');
      stderr.writeln('[jormd] ${req.method} ${req.uri.path}: $e\n$st');
      return await _send(res, 500, {'error': '$e'});
    }
  }

  // An empty body is `{}` (release / retry / disconnect carry nothing).
  Future<Map<String, dynamic>> _readBody(HttpRequest req) async {
    final text = await utf8.decodeStream(req);
    return text.trim().isEmpty ? const {} : (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  Future<void> _send(HttpResponse res, int code, Object body) async {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    res.write(jsonEncode(body));
    await res.close();
  }

  // One JSON object per line, each sent at once (ping results, speed test progress). The
  // page going away cancels the stream (a speed test stops; a ping goes on, see CoreApi.ping).
  Future<void> _ndjson(HttpResponse res, Stream<Map<String, dynamic>> lines) async {
    res.headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    res.bufferOutput = false;
    final done = Completer<void>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    void end() {
      if (!done.isCompleted) done.complete();
    }

    sub = lines.listen((m) {
      try {
        res.write('${jsonEncode(m)}\n');
      } catch (_) {
        unawaited(sub.cancel());
        end();
      }
    }, onDone: end, onError: (Object _) => end());
    unawaited(res.done.then((_) {}, onError: (_) {}).whenComplete(() {
      unawaited(sub.cancel());
      end();
    }));
    await done.future;
    try {
      await res.close();
    } catch (_) {}
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
}

// The `event` of a command body (an id of the journal); a body without one is a bad request.
int _eventId(Map<String, dynamic> body) {
  final id = body['event'];
  if (id is! int) throw const FormatException('No such event');
  return id;
}
