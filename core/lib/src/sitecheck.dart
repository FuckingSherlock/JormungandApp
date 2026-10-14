import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'sentinel/model.dart' show Cancel;

/// One GET of the checker's API: the status and the text of the answer. Fails (throws) when
/// the host cannot be reached; an HTTP error status is an answer. The tests give their own.
typedef CheckGet = Future<({int status, String body})> Function(Uri url, {int? proxyPort, Duration timeout});

/// The real [CheckGet]: `Accept: application/json`, through the local proxy [proxyPort]
/// (null = direct).
Future<({int status, String body})> httpCheckGet(Uri url, {int? proxyPort, Duration timeout = const Duration(seconds: 12)}) async {
  final c = HttpClient()
    ..findProxy = ((_) => proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort')
    ..connectionTimeout = timeout
    ..userAgent = 'Jormungand';
  try {
    return await Future<({int status, String body})>(() async {
      final req = await c.getUrl(url);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
        if (bytes.length > 1 << 20) break;
      }
      return (status: res.statusCode, body: utf8.decode(bytes, allowMalformed: true));
    }).timeout(timeout);
  } finally {
    c.close(force: true);
  }
}

/// What the checker's nodes said about one site (`event.data.check`):
/// `{state, at, kind: 'http' | 'tcp', via: 'tunnel' | 'direct', ok, total, nodes: [{cc, country, city, ok, code?, ms?, error?}], error?}`.
/// [state]: `opens` (at least [SiteChecker.needOk] nodes reach it: it is down only for the user's
/// routes), `down` (the checker's nodes do not reach it either), `failed` (no answer from the
/// checker: [error] says why), `cancelled` (the asker withdrew: nobody records it, it is never cached).
/// The events add `pending` / `off` themselves.
class SiteCheckResult {
  SiteCheckResult({required this.state, required this.at, required this.kind, required this.via, this.nodes = const [], this.error});

  final String state, kind, via;
  final int at;
  final List<Map<String, dynamic>> nodes;
  final String? error;

  int get ok => [for (final n in nodes) if (n['ok'] == true) n].length;

  Map<String, dynamic> toJson() => {
        'state': state,
        'at': at,
        'kind': kind,
        'via': via,
        'ok': ok,
        'total': nodes.length,
        'nodes': nodes,
        'error': ?error,
      };
}

/// The one node of a `check-http` / `check-tcp` result: still running ([pending]), reached the
/// site ([ok]) or not, with what it says. Defensive about the shape: anything unrecognised is a
/// failed node, `null` alone is a node that has not answered yet.
({bool pending, bool ok, int? code, int? ms, String? error}) parseCheckNode(Object? v, {required bool tcp}) {
  if (v == null) return (pending: true, ok: false, code: null, ms: null, error: null);
  if (v is! List || v.isEmpty) return (pending: false, ok: false, code: null, ms: null, error: 'no answer');
  final first = v.first;
  int? ms(Object? s) => s is num ? (s * 1000).round() : null;
  if (tcp || first is Map) {
    // [{"time": 0.05, "address": "1.2.3.4"}] or [{"error": "Connection timed out"}]
    for (final e in v) {
      if (e is Map && e['time'] is num) return (pending: false, ok: true, code: null, ms: ms(e['time']), error: null);
    }
    final err = first is Map && first['error'] != null ? '${first['error']}' : 'no answer';
    return (pending: false, ok: false, code: null, ms: null, error: err);
  }
  // [[1, 0.12, "OK", "200", "1.2.3.4"]] or [[0, 5.0, "Connection timed out"]] or [[null]]
  final r = first is List && first.isNotEmpty ? first : null;
  if (r == null || r[0] == null) return (pending: false, ok: false, code: null, ms: null, error: 'no answer');
  final ok = r[0] == 1 || r[0] == true || r[0] == '1';
  if (ok) {
    return (pending: false, ok: true, code: r.length > 3 ? int.tryParse('${r[3]}') : null, ms: ms(r.length > 1 ? r[1] : null), error: null);
  }
  return (pending: false, ok: false, code: null, ms: null, error: r.length > 2 && r[2] != null && '${r[2]}'.isNotEmpty ? '${r[2]}' : 'failed');
}

/// One run of the checker for one site, shared by every ask that came while it lasts; [abort] stops it
/// (when [waiters] that can cancel have all done so).
class _Run {
  late Future<SiteCheckResult> future;
  final abort = Cancel();
  int waiters = 0;
}

class _Aborted implements Exception {}

/// Asks check-host.net whether a site opens from its nodes around the world (docs/connect-model.md →
/// «Фоновые ошибки», «Внешний чекер»): a site that fails through every route of the user is either down
/// or blocked from where they are; this tells which. The request goes through [proxyPort] (the
/// running tunnel: the checker may itself be blocked on the direct path), direct when no tunnel is up
/// or the tunnel does not reach it.
///
/// A result is cached per site for [cacheFor] (an automatic check reuses it); at most [perMinute]
/// automatic checks start per minute (a manual check is not counted and ignores the cache); two asks
/// for one site at once share one run.
class SiteChecker {
  SiteChecker({
    CheckGet? get,
    this.proxyPort,
    this.pollEvery = const Duration(seconds: 2),
    this.pollFor = const Duration(seconds: 20),
    this.cacheFor = const Duration(minutes: 10),
    this.perMinute = 4,
    this.needOk = 2,
    this.maxNodes = 8,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  })  : _get = get ?? httpCheckGet,
        _delay = delay ?? Future<void>.delayed,
        _now = now ?? DateTime.now;

  static const base = 'https://check-host.net';

  final CheckGet _get;
  final int? Function()? proxyPort;
  final Duration pollEvery, pollFor, cacheFor;
  final int perMinute, needOk, maxNodes;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  final _cache = <String, SiteCheckResult>{};
  final _running = <String, _Run>{};
  final _starts = Queue<int>();

  /// The checker asked about [host] (and [port], default 443): the cached answer, a run in progress, or a
  /// new run. [manual]: a new run at once, not counted against the limit. Never throws: a trouble is a
  /// `failed` result.
  ///
  /// [cancel]: the asker no longer needs the answer. The ask then completes at once with state `cancelled`;
  /// the run itself is dropped when every asker sharing it has cancelled (no further request is sent, the
  /// polling stops), and a dropped run is never cached. An ask without [cancel] keeps the run alive.
  Future<SiteCheckResult> check(String host, int? port, {bool manual = false, Cancel? cancel}) {
    if (cancel != null && cancel.cancelled) return Future.value(_cancelled());
    final key = '$host:${port ?? 443}';
    final run = _running[key];
    if (run != null && !run.abort.cancelled) return _wait(run, cancel);
    final cached = _cache[key];
    if (!manual && cached != null && _now().millisecondsSinceEpoch - cached.at < cacheFor.inMilliseconds) return Future.value(cached);
    if (!manual) {
      final t = _now().millisecondsSinceEpoch;
      while (_starts.isNotEmpty && t - _starts.first >= 60000) {
        _starts.removeFirst();
      }
      if (_starts.length >= perMinute) {
        return Future.value(SiteCheckResult(state: 'failed', at: t, kind: 'http', via: 'tunnel', error: 'too many checks'));
      }
      _starts.add(t);
    }
    final r = _Run();
    r.future = _run(host, port, r.abort).then((res) {
      if (res.state == 'opens' || res.state == 'down') _cache[key] = res; // never a failed or a cancelled one
      return res;
    }).whenComplete(() {
      if (identical(_running[key], r)) _running.remove(key); // (a block: the removed future must not be returned, it would wait for itself)
    });
    _running[key] = r;
    return _wait(r, cancel);
  }

  Future<SiteCheckResult> _wait(_Run run, Cancel? cancel) {
    if (cancel == null) {
      run.waiters++; // never released: this asker keeps the run alive
      return run.future;
    }
    run.waiters++;
    cancel.done.then((_) {
      if (--run.waiters <= 0) run.abort.cancel('cancelled');
    });
    return Future.any([run.future, cancel.done.then((_) => _cancelled())]);
  }

  SiteCheckResult _cancelled() => SiteCheckResult(state: 'cancelled', at: _now().millisecondsSinceEpoch, kind: 'http', via: 'direct', error: 'cancelled');

  Future<SiteCheckResult> _run(String host, int? port, Cancel abort) async {
    final tcp = _tcpWanted(host, port);
    final kind = tcp ? 'tcp' : 'http';
    var via = proxyPort?.call() == null ? 'direct' : 'tunnel';
    SiteCheckResult failed(Object e) => SiteCheckResult(state: 'failed', at: _now().millisecondsSinceEpoch, kind: kind, via: via, error: '$e');
    try {
      final target = tcp ? '$host:${port ?? 443}' : _httpTarget(host, port);
      final start = Uri.parse('$base/${tcp ? 'check-tcp' : 'check-http'}').replace(queryParameters: {'host': target, 'max_nodes': '$maxNodes'});
      Map? first;
      try {
        first = await _json(start, via == 'tunnel' ? proxyPort!() : null, abort);
      } catch (e) {
        if (via == 'direct' || e is _Aborted) rethrow;
        via = 'direct'; // the tunnel does not reach the checker: the machine's own path
        first = await _json(start, null, abort);
      }
      final id = first['request_id'];
      final meta = first['nodes'];
      if (first['ok'] != 1 && first['ok'] != true || id == null || meta is! Map || meta.isEmpty) return failed('the checker did not start the check');
      final port0 = via == 'tunnel' ? proxyPort?.call() : null;
      final result = Uri.parse('$base/check-result/$id');
      final done = <String, ({bool pending, bool ok, int? code, int? ms, String? error})>{};
      final deadline = _now().millisecondsSinceEpoch + pollFor.inMilliseconds;
      var elapsed = Duration.zero;
      while (true) {
        await _guard(_delay(pollEvery), abort);
        elapsed += pollEvery;
        Map? r;
        try {
          r = await _json(result, port0, abort);
        } catch (e) {
          if (e is _Aborted) rethrow;
          r = null; // a poll that fails is asked again
        }
        if (r != null) {
          for (final n in meta.keys) {
            final p = parseCheckNode(r[n], tcp: tcp);
            if (!p.pending) done['$n'] = p;
          }
        }
        if (done.length >= meta.length) break;
        if (_now().millisecondsSinceEpoch >= deadline || elapsed >= pollFor) break;
      }
      final nodes = <Map<String, dynamic>>[];
      for (final n in meta.keys) {
        final m = meta[n], p = done['$n'];
        if (p == null) continue; // never answered: it says nothing
        String? text(int i) => m is List && m.length > i && m[i] != null && '${m[i]}'.isNotEmpty ? '${m[i]}' : null;
        nodes.add({
          'cc': text(0)?.toUpperCase(),
          'country': text(1),
          'city': text(2),
          'ok': p.ok,
          'code': ?p.code,
          'ms': ?p.ms,
          'error': ?p.error,
        }..removeWhere((k, v) => v == null && k != 'ok'));
      }
      final ok = [for (final n in nodes) if (n['ok'] == true) n].length;
      // "down for everyone" needs a few nodes to say so: one stray answer proves nothing
      if (nodes.isEmpty || (ok < needOk && nodes.length < needOk)) return failed('${nodes.length} of ${meta.length} nodes answered in ${pollFor.inSeconds} s');
      return SiteCheckResult(state: ok >= needOk ? 'opens' : 'down', at: _now().millisecondsSinceEpoch, kind: kind, via: via, nodes: nodes);
    } catch (e) {
      if (e is _Aborted) return _cancelled();
      return failed(e is TimeoutException ? 'timeout' : e);
    }
  }

  /// [f], or [_Aborted] as soon as [abort] is cancelled (a request in flight is not waited for).
  static Future<T> _guard<T>(Future<T> f, Cancel abort) =>
      Future.any([f, abort.done.then<T>((_) => throw _Aborted())]);

  Future<Map> _json(Uri url, int? proxy, Cancel abort) async {
    if (abort.cancelled) throw _Aborted(); // no further request after the cancel
    final r = await _guard(_get(url, proxyPort: proxy, timeout: const Duration(seconds: 12)), abort);
    if (r.status != 200) throw HttpException('HTTP ${r.status}', uri: url);
    final j = jsonDecode(r.body);
    if (j is! Map) throw const FormatException('not an object');
    return j;
  }

  /// An address or a port that is not a web port: a TCP check instead of an HTTP one.
  static bool _tcpWanted(String host, int? port) =>
      InternetAddress.tryParse(host) != null || !(port == null || const {80, 443, 8443, 8080, 8000, 8008, 8888}.contains(port));

  static String _httpTarget(String host, int? port) => switch (port) {
        null || 443 => 'https://$host',
        80 => 'http://$host',
        8443 => 'https://$host:8443',
        _ => 'http://$host:$port',
      };
}
