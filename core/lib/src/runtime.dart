import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

class SingBoxError implements Exception {
  SingBoxError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One sing-box process (Flutter on mobile: libbox instead of a process).
class SingBoxProcess {
  SingBoxProcess(this.binary, this.workDir);

  final String binary;
  final String workDir;
  final logs = ListQueue<String>();
  Process? _proc;
  int? clashPort;

  bool get running => _proc != null;

  void _log(String line) {
    logs.add(line);
    while (logs.length > 500) {
      logs.removeFirst();
    }
  }

  /// Writes [config], has sing-box check it, runs it and waits for the clash API.
  Future<void> start(Map<String, dynamic> config, {required int clashPort}) async {
    await stop();
    await Directory(workDir).create(recursive: true);
    final file = File(p.join(workDir, 'config.json'));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(config));

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
      if (identical(_proc, proc)) _proc = null;
    });

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (!identical(_proc, proc)) {
        throw SingBoxError('sing-box stopped on start:\n${logs.toList().reversed.take(8).toList().reversed.join('\n')}');
      }
      if (await clashGet('/version') != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await stop();
    throw SingBoxError('sing-box did not come up in 8 s');
  }

  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) return;
    _proc = null;
    proc.kill();
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
  }

  /// GET on the clash API; null when it does not answer.
  Future<Map<String, dynamic>?> clashGet(String path, {Duration timeout = const Duration(seconds: 2)}) async {
    final c = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:$clashPort$path')).timeout(timeout);
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join();
      final j = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
      return {'_status': res.statusCode, ...j};
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }
}

/// A free loopback port (for a clash API that must not clash with another instance).
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Measures latency through each node (and each entry → exit pair) with a throwaway
/// sing-box and its clash API `/proxies/{tag}/delay`. Results: ms, or -1 = no answer.
Future<({Map<String, int> nodes, Map<String, int> pairs})> measureLatency({
  required String binary,
  required String workDir,
  required List<Map> nodes,
  List<Map> pairs = const [],
  String url = defaultTestUrl,
  int timeoutMs = 5000,
  int parallel = 16,
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
