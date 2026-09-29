// A password on the user port (plan.mixedAuth) with the real sing-box (tool/bin), loopback only:
// a shadowsocks "server" and a target HTTP server, our config in front. With users set the user
// port refuses a client with no login and takes the right one, over SOCKS5 and over HTTP; the
// open sys-in (the system proxy's port) and tunnel-in take anyone; with no password the user port
// is open as before. Random ports only: nothing of the user's is touched.
// Skipped when the binary is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

/// One TCP connection read in pieces: [take] n bytes, [rest] until the peer closes.
class _Conn {
  _Conn(this.sock) {
    sock.listen((d) {
      buf.addAll(d);
      _wake();
    }, onDone: () {
      closed = true;
      _wake();
    }, onError: (Object _) {
      closed = true;
      _wake();
    });
  }

  final Socket sock;
  final buf = <int>[];
  bool closed = false;
  Completer<void>? _w;

  void _wake() {
    final w = _w;
    _w = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  static Future<_Conn> open(int port) async => _Conn(await Socket.connect(InternetAddress.loopbackIPv4, port));

  void send(List<int> b) => sock.add(b);

  Future<List<int>> take(int n) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (buf.length < n && !closed) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('read $n bytes, have ${buf.length}');
      _w = Completer<void>();
      await _w!.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    final k = buf.length < n ? buf.length : n;
    final out = buf.sublist(0, k);
    buf.removeRange(0, k);
    return out;
  }

  /// Everything until the peer closes.
  Future<String> rest() async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!closed && DateTime.now().isBefore(end)) {
      _w = Completer<void>();
      await _w!.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    return utf8.decode(buf, allowMalformed: true);
  }

  Future<void> close() async {
    sock.destroy();
  }
}

/// SOCKS5 to the target through [port]. [creds] null = offer "no authentication". Returns the
/// page the target sent, or null when the proxy refused (method or login).
Future<String?> _socksGet(int port, int target, {(String, String)? creds}) async {
  final c = await _Conn.open(port);
  try {
    c.send(creds == null ? [5, 1, 0] : [5, 1, 2]);
    final m = await c.take(2);
    if (m.length < 2 || m[1] == 0xFF) return null; // no acceptable method
    if (creds != null) {
      final u = utf8.encode(creds.$1), pw = utf8.encode(creds.$2);
      c.send([1, u.length, ...u, pw.length, ...pw]);
      final a = await c.take(2);
      if (a.length < 2 || a[1] != 0) return null; // login refused
    }
    c.send([5, 1, 0, 1, 127, 0, 0, 1, target >> 8, target & 0xFF]);
    final r = await c.take(10);
    if (r.length < 10 || r[1] != 0) return null;
    c.send(utf8.encode('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
    return await c.rest();
  } finally {
    await c.close();
  }
}

/// HTTP proxying (absolute-URI GET) through [port], with a Proxy-Authorization when [creds].
Future<String> _httpGet(int port, int target, {(String, String)? creds}) async {
  final c = await _Conn.open(port);
  try {
    final auth = creds == null ? '' : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${creds.$1}:${creds.$2}'))}\r\n';
    c.send(utf8.encode('GET http://127.0.0.1:$target/ HTTP/1.1\r\nHost: 127.0.0.1:$target\r\n${auth}Connection: close\r\n\r\n'));
    return await c.rest();
  } finally {
    await c.close();
  }
}

void main() {
  test('user port with a password: refuses no / wrong login, takes the right one (SOCKS5 and HTTP); sys-in and tunnel-in stay open', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello from target')
      ..close());
    final ssPort = await freePort(), tmp = await Directory.systemTemp.createTemp('jorm-auth');
    final mixed = await freePort(exclude: {ssPort});
    final tunnel = await freePort(exclude: {ssPort, mixed}), sys = await freePort(exclude: {ssPort, mixed, tunnel});
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': ssPort, 'method': 'aes-128-gcm', 'password': 'loopback'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      final node = parseLink('ss://${base64.encode(utf8.encode('aes-128-gcm:loopback'))}@127.0.0.1:$ssPort#loop')!;
      final plan = {
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': node.id,
          'nodes': [
            {'key': 'src::${node.id}', 'outbound': node.outbound},
          ],
        },
        'mixedPort': mixed,
        'global': true,
      };
      const good = ('jorm', 'p@ss:w0rd');

      // with a password
      await client.start(buildConfig({...plan, 'mixedAuth': {'user': good.$1, 'pass': good.$2}}, tunnelPort: tunnel, sysPort: sys));
      expect(await _socksGet(mixed, target.port), isNull, reason: 'SOCKS5, no login');
      expect(await _socksGet(mixed, target.port, creds: (good.$1, 'wrong')), isNull, reason: 'SOCKS5, wrong password');
      expect(await _socksGet(mixed, target.port, creds: ('other', good.$2)), isNull, reason: 'SOCKS5, wrong login');
      expect(await _socksGet(mixed, target.port, creds: good), contains('hello from target'), reason: 'SOCKS5, right login');
      expect(await _httpGet(mixed, target.port), contains(' 407 '), reason: 'HTTP, no login');
      expect(await _httpGet(mixed, target.port, creds: (good.$1, 'wrong')), contains(' 407 '), reason: 'HTTP, wrong password');
      final ok = await _httpGet(mixed, target.port, creds: good);
      expect(ok, contains(' 200 '), reason: 'HTTP, right login');
      expect(ok, contains('hello from target'));

      // the two open inbounds
      for (final open in [sys, tunnel]) {
        expect(await _socksGet(open, target.port), contains('hello from target'), reason: 'SOCKS5 on $open, no login');
        expect(await _httpGet(open, target.port), contains('hello from target'), reason: 'HTTP on $open, no login');
      }
      // ... and the exit check the daemon does through tunnel-in
      final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$tunnel';
      final res = await (await http.getUrl(Uri.parse('http://127.0.0.1:${target.port}/'))).close();
      expect(await res.transform(utf8.decoder).join(), 'hello from target');
      http.close(force: true);

      // no password: open as before
      await client.start(buildConfig(plan, tunnelPort: tunnel));
      expect(await _socksGet(mixed, target.port), contains('hello from target'), reason: 'open SOCKS5');
      expect(await _httpGet(mixed, target.port), contains('hello from target'), reason: 'open HTTP');
    } finally {
      await client.stop();
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('sing-box accepts the config with users and sys-in', () async {
    final node = parseLink('ss://${base64.encode(utf8.encode('aes-128-gcm:x'))}@127.0.0.1:1#n')!;
    final cfg = buildConfig({
      'kind': 'unit',
      'main': {
        'pick': 'priority',
        'chosen': node.id,
        'nodes': [
          {'key': 'src::${node.id}', 'outbound': node.outbound},
        ],
      },
      'mixedAuth': {'user': 'u', 'pass': 'p'},
    }, tunnelPort: 30001, sysPort: 30002);
    final dir = await Directory.systemTemp.createTemp('jorm-check');
    try {
      final f = File(p.join(dir.path, 'c.json'))..writeAsStringSync(jsonEncode(cfg));
      final r = await Process.run(_bin, ['check', '-c', f.path, '--disable-color']);
      expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}');
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: _skip);
}
