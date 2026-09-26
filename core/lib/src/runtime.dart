import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'config.dart';

class SingBoxError implements Exception {
  SingBoxError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// sing-box's Clash API as the core uses it (auto.dart; a fake in tests).
abstract interface class ClashApi {
  /// GET; the JSON body plus `_status`, or null when it does not answer.
  Future<Map<String, dynamic>?> clashGet(String path, {Duration timeout});

  /// PUT with a JSON body; the HTTP status (204 = done), or null when it does not answer.
  Future<int?> clashPut(String path, Map<String, dynamic> body, {Duration timeout});
}

/// One sing-box process (Flutter on mobile: libbox instead of a process).
class SingBoxProcess implements ClashApi {
  SingBoxProcess(this.binary, this.workDir);

  final String binary;
  final String workDir;
  final logs = ListQueue<String>();
  Process? _proc;
  Process? _up; // the process that came up (start() returned), until it stops
  int? clashPort;

  /// The Clash API secret: new and random on every start, put into the config's
  /// clash_api and sent by every call here, so no other program can steer the tunnel.
  String? clashSecret;

  /// sing-box stopped on its own (crash, killed from outside) after it had come up;
  /// never called for stop() or for a start that failed.
  void Function(int code)? onExit;

  bool get running => _proc != null;
  int? get pid => _proc?.pid;

  void _log(String line) {
    logs.add(line);
    while (logs.length > 500) {
      logs.removeFirst();
    }
  }

  /// A line of the core's own in the log (`[jormd] …`), next to sing-box's.
  void note(String line) => _log('[jormd] $line');

  /// Writes [config], has sing-box check it, runs it and waits for the clash API.
  Future<void> start(Map<String, dynamic> config, {required int clashPort}) async {
    await stop();
    await Directory(workDir).create(recursive: true);
    final secret = clashSecret = _newSecret();
    final file = File(p.join(workDir, 'config.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(_withSecret(config, secret)));

    final check = await Process.run(binary, ['check', '-c', file.path, '--disable-color']);
    if (check.exitCode != 0) {
      throw SingBoxError('sing-box rejected the config: ${'${check.stderr}${check.stdout}'.trim()}');
    }

    final proc = await Process.start(binary, ['run', '-c', file.path, '-D', workDir, '--disable-color']);
    _proc = proc;
    this.clashPort = clashPort;
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

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (!identical(_proc, proc)) {
        throw SingBoxError('sing-box stopped on start:\n${logs.toList().reversed.take(8).toList().reversed.join('\n')}');
      }
      if (await clashGet('/version') != null) {
        _up = proc;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await stop();
    throw SingBoxError('sing-box did not come up in 8 s');
  }

  Future<void> stop() async {
    final proc = _proc;
    _up = null;
    if (proc == null) return;
    _proc = null;
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }

  static String _newSecret() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  static Map<String, dynamic> _withSecret(Map<String, dynamic> config, String secret) {
    final exp = (config['experimental'] as Map?)?.cast<String, dynamic>();
    final api = (exp?['clash_api'] as Map?)?.cast<String, dynamic>();
    if (exp == null || api == null) return config;
    return {
      ...config,
      'experimental': {
        ...exp,
        'clash_api': {...api, 'secret': secret},
      },
    };
  }

  Future<HttpClientRequest> _open(HttpClient c, String method, String path, Duration timeout) async {
    final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:$clashPort$path')).timeout(timeout);
    if (clashSecret != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $clashSecret');
    return req;
  }

  /// GET on the clash API; null when it does not answer.
  @override
  Future<Map<String, dynamic>?> clashGet(String path, {Duration timeout = const Duration(seconds: 2)}) async {
    final c = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await _open(c, 'GET', path, timeout);
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final j = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
      return {'_status': res.statusCode, ...j};
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// PUT on the clash API (`/proxies/<selector>` with `{name}` switches it); the status.
  @override
  Future<int?> clashPut(String path, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 2)}) async {
    final c = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await _open(c, 'PUT', path, timeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(timeout);
      await res.drain<void>().timeout(timeout);
      return res.statusCode;
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }
}

/// A free loopback port (for a clash API that must not clash with another instance), free
/// for UDP and TCP both: an inbound listens on both. A random port below the dynamic range,
/// not a port 0: Windows hands those out one after another, straight into its reserved
/// ranges (Hyper-V / WinNAT, blocks of hundreds, TCP and UDP apart). UDP is bound without
/// SO_REUSEADDR, as sing-box does, so a port another process holds on 0.0.0.0 counts as taken.
Future<int> freePort() async {
  for (var i = 0;; i++) {
    final port = 20000 + _ports.nextInt(29000);
    RawDatagramSocket? u;
    try {
      u = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, port, reuseAddress: false);
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return port;
    } on SocketException {
      if (i >= 200) rethrow;
    } finally {
      u?.close();
    }
  }
}

final _ports = Random();

/// Measures latency through each node (and each entry → exit pair) with a throwaway
/// sing-box and its clash API `/proxies/{tag}/delay`. Results: ms, or -1 = no answer.
Future<({Map<String, int> nodes, Map<String, int> pairs})> measureLatency({
  required String binary,
  required String workDir,
  required List<Map> nodes,
  List<Map> pairs = const [],
  String url = defaultTestUrl,
  int timeoutMs = 5000,
  int parallel = 32,
  void Function(String kind, String key, int ms)? onResult,
}) async {
  final port = await freePort();
  final sb = SingBoxProcess(binary, workDir);
  await sb.start(buildTesterConfig(nodes: nodes, pairs: pairs, clashPort: port), clashPort: port);
  try {
    final jobs = <(String, String)>[
      for (final n in nodes) ('n', '${n['key']}'),
      for (final pr in pairs) ('p', '${pr['key']}'),
    ];
    final res = (nodes: <String, int>{}, pairs: <String, int>{});
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final (kind, key) = jobs[next++];
        final tag = Uri.encodeComponent('${kind == 'n' ? 't' : 'p'}/$key');
        final r = await sb.clashGet('/proxies/$tag/delay?timeout=$timeoutMs&url=${Uri.encodeQueryComponent(url)}',
            timeout: Duration(milliseconds: timeoutMs + 2000));
        final ms = r != null && r['_status'] == 200 && r['delay'] is int ? r['delay'] as int : -1;
        (kind == 'n' ? res.nodes : res.pairs)[key] = ms;
        onResult?.call(kind, key, ms);
      }
    }

    await Future.wait(List.generate(parallel, (_) => worker()));
    return res;
  } finally {
    await sb.stop();
  }
}
