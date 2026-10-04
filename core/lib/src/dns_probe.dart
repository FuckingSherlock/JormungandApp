import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Settings → DNS: the latency of one DNS server by one real query, straight from this machine (not
// through the tunnel: a server "via VPN" is measured on the direct path, which says whether the
// address answers at all). The address forms are the ones the DNS form takes: system, a bare IP
// (with :port), udp:// tcp:// tls:// https:// quic://.

final _rnd = Random();

/// A DNS query for the A record of [name]: 12 byte header + the question. [id] is its 16 bit id.
Uint8List dnsQuery(String name, int id) {
  final b = BytesBuilder();
  b.add([id >> 8, id & 255, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]); // RD set, one question
  for (final label in name.split('.')) {
    final l = utf8.encode(label);
    b.addByte(l.length);
    b.add(l);
  }
  b.add([0, 0, 1, 0, 1]); // end of name, type A, class IN
  return b.toBytes();
}

/// Is [data] an answer to the query with [id] (the QR bit set and the same id)?
bool isDnsAnswer(List<int> data, int id) => data.length >= 12 && data[0] == id >> 8 && data[1] == (id & 255) && (data[2] & 0x80) != 0;

/// Milliseconds the server at [addr] took to answer, -1 when it did not (an error, a timeout), null
/// when the address kind cannot be measured here (quic://).
Future<int?> dnsLatency(String addr, {Duration timeout = const Duration(seconds: 4), String name = 'www.gstatic.com'}) async {
  final a = addr.trim();
  final sw = Stopwatch()..start();
  try {
    final id = _rnd.nextInt(65536);
    if (a == 'system') {
      await InternetAddress.lookup(name).timeout(timeout);
      return sw.elapsedMilliseconds;
    }
    final m = RegExp(r'^(\w+)://(.+)$').firstMatch(a);
    final scheme = m?.group(1) ?? 'udp';
    final rest = m?.group(2) ?? a;
    switch (scheme) {
      case 'quic':
        return null;
      case 'https':
        final uri = Uri.parse(a);
        final path = uri.path.isEmpty ? '/dns-query' : uri.path;
        final c = HttpClient()..connectionTimeout = timeout;
        try {
          final req = await c.postUrl(uri.replace(path: path)).timeout(timeout);
          req.headers
            ..set('content-type', 'application/dns-message')
            ..set('accept', 'application/dns-message');
          req.add(dnsQuery(name, id));
          final res = await req.close().timeout(timeout);
          final body = await res.fold<List<int>>([], (p, e) => p..addAll(e)).timeout(timeout);
          return res.statusCode == 200 && isDnsAnswer(body, id) ? sw.elapsedMilliseconds : -1;
        } finally {
          c.close(force: true);
        }
      case 'tcp' || 'tls':
        final (host, port) = _hostPort(rest, scheme == 'tls' ? 853 : 53);
        final Socket s = scheme == 'tls' ? await SecureSocket.connect(host, port, timeout: timeout) : await Socket.connect(host, port, timeout: timeout);
        try {
          final q = dnsQuery(name, id);
          s.add([q.length >> 8, q.length & 255, ...q]);
          await s.flush();
          final got = <int>[];
          final done = Completer<bool>();
          final sub = s.listen((d) {
            got.addAll(d);
            if (got.length >= 2 && got.length >= 2 + ((got[0] << 8) | got[1]) && !done.isCompleted) done.complete(true);
          }, onDone: () => done.isCompleted ? null : done.complete(false), onError: (_) => done.isCompleted ? null : done.complete(false));
          final ok = await done.future.timeout(timeout, onTimeout: () => false);
          await sub.cancel();
          return ok && isDnsAnswer(got.sublist(2), id) ? sw.elapsedMilliseconds : -1;
        } finally {
          s.destroy();
        }
      case 'udp':
        final (host, port) = _hostPort(rest, 53);
        final ip = (await InternetAddress.lookup(host).timeout(timeout)).first;
        final sock = await RawDatagramSocket.bind(ip.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
        try {
          final done = Completer<bool>();
          final sub = sock.listen((e) {
            if (e != RawSocketEvent.read) return;
            final d = sock.receive();
            if (d != null && isDnsAnswer(d.data, id) && !done.isCompleted) done.complete(true);
          });
          sock.send(dnsQuery(name, id), ip, port);
          final ok = await done.future.timeout(timeout, onTimeout: () => false);
          await sub.cancel();
          return ok ? sw.elapsedMilliseconds : -1;
        } finally {
          sock.close();
        }
    }
    return null;
  } catch (_) {
    return -1;
  }
}

/// `host`, `host:port`, `[v6]`, `[v6]:port`, a path after the first `/` dropped.
(String, int) _hostPort(String s, int def) {
  final hp = s.split('/').first;
  if (hp.startsWith('[')) {
    final end = hp.indexOf(']');
    final port = end >= 0 && hp.length > end + 2 && hp[end + 1] == ':' ? int.tryParse(hp.substring(end + 2)) : null;
    return (hp.substring(1, end < 0 ? hp.length : end), port ?? def);
  }
  final i = hp.lastIndexOf(':');
  if (i > 0 && hp.indexOf(':') == i) return (hp.substring(0, i), int.tryParse(hp.substring(i + 1)) ?? def);
  return (hp, def);
}
