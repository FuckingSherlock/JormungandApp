/// Latency through one outbound, measured by the core itself the way other clients show
/// it (Karing, mihomo's "unified delay"): two HEAD requests to the test URL on one
/// connection, the time of the second — one round trip over the whole path, without the
/// handshakes of opening a connection. sing-box's own delay test (Clash API
/// `/proxies/<tag>/delay`) times the first request, handshakes and all: through a bridge
/// (RU → EU, the bridge opening its own connection onward) that reads 3–4 times higher.
///
/// The requests go through a loopback SOCKS5 inbound of the config (`probe-in`, see
/// [Probe.inbound]): the SOCKS user name is the outbound's tag, a route rule per tag sends
/// it there, past every other rule; the password is random per start, so no other program
/// on the machine can use the inbound.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const probeInboundTag = 'probe-in';

class Probe {
  Probe(this.port, [String? secret]) : secret = secret ?? _newSecret();

  final int port;
  final String secret;

  /// The inbound and its route rules (to go first) for [tags].
  ({Map<String, dynamic> inbound, List<Map<String, dynamic>> rules}) inbound(Iterable<String> tags) {
    final ts = tags.toSet().toList();
    return (
      inbound: {
        'type': 'socks',
        'tag': probeInboundTag,
        'listen': '127.0.0.1',
        'listen_port': port,
        'users': [for (final t in ts) {'username': t, 'password': secret}],
      },
      rules: [
        for (final t in ts)
          {'inbound': [probeInboundTag], 'auth_user': [t], 'action': 'route', 'outbound': t},
      ],
    );
  }

  /// ms of one round trip through [tag] to [url] on an open connection; the first
  /// request's time when the server will not keep the connection; -1 = no answer.
  Future<int> delay(String tag, String url, {int timeoutMs = 5000}) => probeDelay(this, tag, url, timeoutMs: timeoutMs);

  /// [delay] as AutoService takes it.
  Future<int> Function(String tag, String url, int timeoutMs) get delayTest => (tag, url, t) => delay(tag, url, timeoutMs: t);

  static String _newSecret() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}

/// One test of a node with backup checks: [test] of [url] first; when it does not answer,
/// every one of [checkers] at once. The node passes traffic when any answers: the ms of
/// [url], else of the first checker that answered; -1 = none did. (One blocked service
/// must not make a working node look dead; the extra requests go only to a node that
/// already missed.)
Future<int> withCheckers(Future<int> Function(String url) test, String url, List<String> checkers) async {
  final ms = await test(url).catchError((_) => -1);
  final rest = [for (final c in checkers) if (c != url) c];
  if (ms >= 0 || rest.isEmpty) return ms;
  final done = Completer<int>();
  var left = rest.length;
  for (final c in rest) {
    test(c).catchError((_) => -1).then((v) {
      if (done.isCompleted) return;
      if (v >= 0) {
        done.complete(v);
      } else if (--left == 0) {
        done.complete(-1);
      }
    });
  }
  return done.future;
}

Future<int> probeDelay(Probe probe, String tag, String url, {int timeoutMs = 5000}) async {
  final Uri u;
  try {
    u = Uri.parse(url);
  } on FormatException {
    return -1;
  }
  final https = u.scheme == 'https';
  final port = u.hasPort ? u.port : (https ? 443 : 80);
  final path = '${u.path.isEmpty ? '/' : u.path}${u.hasQuery ? '?${u.query}' : ''}';
  final req = utf8.encode('HEAD $path HTTP/1.1\r\nHost: ${u.host}\r\nUser-Agent: Jormungand\r\nAccept: */*\r\n\r\n');
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    final sw = Stopwatch()..start();
    final int cold;
    final bool keep;
    try {
      w = await _Wire.connect(probe.port).timeout(left());
      await w.socks(tag, probe.secret, u.host, port).timeout(left());
      if (https) await w.secure(u.host).timeout(left());
      keep = await w.request(req).timeout(left());
      cold = sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
    if (!keep) return cold;
    sw.reset();
    try {
      await w.request(req).timeout(left());
      return sw.elapsedMilliseconds;
    } catch (_) {
      return cold; // the first one answered: the server is there
    }
  } finally {
    w?.close();
  }
}

/// Whether the site [dest] (`host:port`) opens through [tag]: port 443 — a TLS handshake
/// with it (its certificate valid for the host), port 80 — an answer to HEAD /. null when
/// it cannot be told (another port, an IP address on 443).
Future<bool?> probeReach(Probe probe, String tag, String dest, {int timeoutMs = 5000}) async {
  final i = dest.lastIndexOf(':');
  final host = i > 0 ? dest.substring(0, i).replaceAll(RegExp(r'^\[|\]$'), '') : dest;
  final port = int.tryParse(i > 0 ? dest.substring(i + 1) : '');
  if (port != 443 && port != 80) return null;
  if (port == 443 && InternetAddress.tryParse(host) != null) return null;
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    w = await _Wire.connect(probe.port).timeout(left());
    await w.socks(tag, probe.secret, host, port!).timeout(left());
    if (port == 443) {
      await w.secure(host).timeout(left());
    } else {
      await w.request(utf8.encode('HEAD / HTTP/1.1\r\nHost: $host\r\nUser-Agent: Jormungand\r\nAccept: */*\r\n\r\n')).timeout(left());
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    w?.close();
  }
}

/// A loopback connection read by hand: SOCKS5, then TLS over it, then HTTP/1.1.
class _Wire {
  _Wire._(this._raw) {
    _listen();
  }

  static Future<_Wire> connect(int port) async => _Wire._(await RawSocket.connect(InternetAddress.loopbackIPv4, port));

  RawSocket _raw;
  StreamSubscription<RawSocketEvent>? _sub;
  final _buf = <int>[];
  Completer<void>? _more;
  bool _closed = false;

  void _listen() {
    _sub = _raw.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = _raw.read();
        if (d != null) _buf.addAll(d);
      } else if (e == RawSocketEvent.readClosed || e == RawSocketEvent.closed) {
        _closed = true;
      }
      _wake();
    }, onError: (Object _) {
      _closed = true;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    });
  }

  void _wake() {
    final c = _more;
    _more = null;
    c?.complete();
  }

  Future<void> _wait() {
    if (_closed) throw const SocketException('closed');
    return (_more ??= Completer<void>()).future;
  }

  Future<List<int>> _take(int n) async {
    while (_buf.length < n) {
      await _wait();
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> _write(List<int> b) async {
    var off = 0;
    while (off < b.length) {
      if (_closed) throw const SocketException('closed');
      final n = _raw.write(b, off);
      off += n;
      if (n == 0) await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> socks(String user, String pass, String host, int port) async {
    await _write([5, 1, 2]); // one method: user name / password
    final m = await _take(2);
    if (m[0] != 5 || m[1] != 2) throw const SocketException('socks: no auth');
    final u = utf8.encode(user), pw = utf8.encode(pass);
    await _write([1, u.length, ...u, pw.length, ...pw]);
    if ((await _take(2))[1] != 0) throw const SocketException('socks: auth refused');
    final h = utf8.encode(host);
    await _write([5, 1, 0, 3, h.length, ...h, port >> 8, port & 0xff]);
    final r = await _take(4);
    if (r[1] != 0) throw SocketException('socks: reply ${r[1]}');
    await _take(switch (r[3]) { 1 => 4, 4 => 16, _ => (await _take(1))[0] } + 2);
  }

  Future<void> secure(String host) async {
    final sub = _sub!;
    _sub = null;
    _raw = await RawSecureSocket.secure(_raw, subscription: sub, host: host);
    _listen();
  }

  /// Sends a request, reads the response head (HEAD: no body); true when the server
  /// keeps the connection for the next one.
  Future<bool> request(List<int> req) async {
    await _write(req);
    int end;
    while ((end = _headEnd()) < 0) {
      await _wait();
    }
    final head = latin1.decode(_buf.sublist(0, end)).toLowerCase();
    _buf.removeRange(0, end + 4);
    if (!head.startsWith('http/1.')) throw const SocketException('not http');
    final close = RegExp(r'^connection:\s*close', multiLine: true).hasMatch(head);
    final keep = RegExp(r'^connection:\s*keep-alive', multiLine: true).hasMatch(head);
    return head.startsWith('http/1.1') ? !close : keep;
  }

  int _headEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) return i;
    }
    return -1;
  }

  void close() {
    _closed = true;
    _sub?.cancel();
    _raw.close();
    _wake();
  }
}
