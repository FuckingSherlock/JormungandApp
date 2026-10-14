// probeDnsVia (probe.dart): a DNS server asked through a chosen node, against a fake SOCKS5 inbound on loopback that,
// after the CONNECT, plays a DNS server speaking length-prefixed messages (DNS over TCP). Covered: an answer, silence
// (a `tcp://` server: a miss; a plain UDP server: unknown), a wrong answer, bytes >= 0x80 in the message, DoQ / the OS
// resolver, the inbound being absent or refusing. NOT covered: DoH and DoT -- both are TLS inside the SOCKS connection
// and the probe trusts only the system roots, so a fake needs a certificate the machine trusts (not worth a global
// trust change in a test); their framing is the same `dnsStream` / `getBytes` pieces tested here and in probe_get_test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// What the fake DNS server does with one query (without its 2 byte length): the message to answer with, null = stay silent.
typedef _Reply = List<int>? Function(List<int> query);

/// A SOCKS5 server (user name / password) that accepts every CONNECT and then plays a DNS server over the stream.
/// [seen] gets the user name and the requested host:port. [closeOnQuery]: close the connection at the first query.
Future<ServerSocket> _server(_Reply reply, {List<String>? seen, bool closeOnQuery = false}) async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    final buf = <int>[];
    var stage = 0;
    c.listen((d) {
      buf.addAll(d);
      if (stage == 0 && buf.length >= 3) {
        buf.clear();
        stage = 1;
        c.add([5, 2]);
      } else if (stage == 1 && buf.length >= 2) {
        final n = buf[1];
        if (buf.length < 3 + n) return;
        final m = buf[2 + n];
        if (buf.length < 3 + n + m) return;
        seen?.add(utf8.decode(buf.sublist(2, 2 + n)));
        buf.clear();
        stage = 2;
        c.add([1, 0]);
      } else if (stage == 2 && buf.length >= 5 && buf.length >= 5 + buf[4] + 2) {
        final h = buf[4];
        seen?.add('${utf8.decode(buf.sublist(5, 5 + h))}:${buf[5 + h] << 8 | buf[6 + h]}');
        buf.clear();
        stage = 3;
        c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      } else if (stage == 3 && buf.length >= 2 && buf.length >= 2 + (buf[0] << 8 | buf[1])) {
        final q = buf.sublist(2, 2 + (buf[0] << 8 | buf[1]));
        stage = 4;
        if (closeOnQuery) {
          c.close();
          return;
        }
        final r = reply(q);
        if (r != null) c.add([r.length >> 8, r.length & 255, ...r]);
      }
    }, onError: (Object _) {}, onDone: () => c.destroy());
  });
  return s;
}

/// The answer to [q]: QR set, RCODE [rcode], [ips] as A records (name by pointer, TTL [ttl]).
List<int> _answer(List<int> q, {int rcode = 0, List<List<int>> ips = const [], int ttl = 300}) => [
      ...q.sublist(0, 2), 0x81, 0x80 | rcode, ...q.sublist(4, 6), 0, ips.length, 0, 0, 0, 0,
      ...q.sublist(12),
      for (final ip in ips) ...[0xC0, 0x0C, 0, 1, 0, 1, ttl >> 24 & 255, ttl >> 16 & 255, ttl >> 8 & 255, ttl & 255, 0, 4, ...ip],
    ];

DnsCandidate _cand(String addr, {String kind = 'udp'}) => DnsCandidate(
      side: 'vpn', provider: 'p', kind: kind, n: 1, tag: 'dns-p-$kind-v', addr: addr,
      flagTag: 'flag-dns-p', flagPath: 'flags/dns-p.json', inUse: true,
    );

void main() {
  test('tcp://: an answer with an address is ms, asked as the node\'s user for the server\'s host and port', () async {
    final seen = <String>[];
    final queries = <List<int>>[];
    final s = await _server((q) {
      queries.add(q);
      return _answer(q, ips: [[203, 0, 113, 7]]);
    }, seen: seen);
    addTearDown(() => s.close());
    final ms = await probeDnsVia(Probe(s.port, 'pw'), 'route0/s::a', _cand('tcp://dns.test:5353', kind: 'udp'), 'check.example');
    expect(ms, greaterThanOrEqualTo(0));
    expect(seen, ['route0/s::a', 'dns.test:5353']);
    expect(queries.single.sublist(2, 4), [1, 0], reason: 'a standard recursive query');
    expect(queries.single.sublist(12), [5, ...ascii.encode('check'), 7, ...ascii.encode('example'), 0, 0, 1, 0, 1]);
  });

  test('a plain UDP server (bare host:port) is asked over TCP too: an answer is ms, default port 53', () async {
    final seen = <String>[];
    final s = await _server((q) => _answer(q, ips: [[198, 51, 100, 9]]), seen: seen);
    addTearDown(() => s.close());
    expect(await probeDnsVia(Probe(s.port), 'n1', _cand('9.9.9.9'), 'a.example'), greaterThanOrEqualTo(0));
    expect(seen, ['n1', '9.9.9.9:53']);
  });

  test('bytes >= 0x80 in the message survive (addresses, TTL)', () async {
    // the id of the query is random: a damaged high byte of any field fails the id check or the address check
    final s = await _server((q) => _answer(q, ips: [[255, 254, 129, 200], [128, 128, 128, 128]], ttl: 0x80C0FFEE & 0x7FFFFFFF));
    addTearDown(() => s.close());
    for (var i = 0; i < 20; i++) {
      expect(await probeDnsVia(Probe(s.port), 'n1', _cand('tcp://dns.test'), 'a.example'), greaterThanOrEqualTo(0), reason: 'try $i');
    }
  });

  test('tcp://: silence is a miss (-1), so is a closed connection, NXDOMAIN, an empty answer and a bad id', () async {
    final silent = await _server((_) => null);
    addTearDown(() => silent.close());
    expect(await probeDnsVia(Probe(silent.port), 'n1', _cand('tcp://dns.test'), 'a.example', timeoutMs: 300), -1);

    final closed = await _server((_) => null, closeOnQuery: true);
    addTearDown(() => closed.close());
    expect(await probeDnsVia(Probe(closed.port), 'n1', _cand('tcp://dns.test'), 'a.example'), -1);

    final nx = await _server((q) => _answer(q, rcode: 3));
    addTearDown(() => nx.close());
    expect(await probeDnsVia(Probe(nx.port), 'n1', _cand('tcp://dns.test'), 'a.example'), -1);

    final empty = await _server((q) => _answer(q));
    addTearDown(() => empty.close());
    expect(await probeDnsVia(Probe(empty.port), 'n1', _cand('tcp://dns.test'), 'a.example'), -1);

    final other = await _server((q) => _answer([q[0] ^ 1, ...q.sublist(1)], ips: [[1, 2, 3, 4]]));
    addTearDown(() => other.close());
    expect(await probeDnsVia(Probe(other.port), 'n1', _cand('tcp://dns.test'), 'a.example'), -1);
  });

  test('a plain UDP server: no answer over TCP is null (UDP is not carried through SOCKS), any answer is judged', () async {
    final silent = await _server((_) => null);
    addTearDown(() => silent.close());
    expect(await probeDnsVia(Probe(silent.port), 'n1', _cand('udp://dns.test'), 'a.example', timeoutMs: 300), isNull);

    final closed = await _server((_) => null, closeOnQuery: true);
    addTearDown(() => closed.close());
    expect(await probeDnsVia(Probe(closed.port), 'n1', _cand('1.1.1.1'), 'a.example'), isNull);

    final nx = await _server((q) => _answer(q, rcode: 3));
    addTearDown(() => nx.close());
    expect(await probeDnsVia(Probe(nx.port), 'n1', _cand('udp://dns.test'), 'a.example'), -1, reason: 'an answer over TCP is an answer, even a bad one');
  });

  test('DoQ and the OS resolver cannot be asked: null, nothing is connected to', () async {
    final seen = <String>[];
    final s = await _server((q) => _answer(q, ips: [[1, 2, 3, 4]]), seen: seen);
    addTearDown(() => s.close());
    expect(await probeDnsVia(Probe(s.port), 'n1', _cand('quic://dns.test', kind: 'doq'), 'a.example'), isNull);
    expect(await probeDnsVia(Probe(s.port), 'n1', _cand('local', kind: 'system'), 'a.example'), isNull);
    expect(seen, isEmpty);
  });

  test('the test inbound is not there, or refuses the user: null for every transport', () async {
    final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = gone.port;
    await gone.close();
    expect(await probeDnsVia(Probe(port), 'n1', _cand('tcp://dns.test'), 'a.example', timeoutMs: 500), isNull);
    expect(await probeDnsVia(Probe(port), 'n1', _cand('https://dns.test/dns-query', kind: 'doh'), 'a.example', timeoutMs: 500), isNull);

    final refusing = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => refusing.close());
    refusing.listen((c) {
      c.listen((_) {
        c.add([5, 0xff]); // no acceptable method
        c.close();
      }, onError: (Object _) {});
    });
    expect(await probeDnsVia(Probe(refusing.port), 'n1', _cand('tcp://dns.test'), 'a.example'), isNull);
  });

  test('a name that is no name is null; a server that cannot be reached through the node is -1 (tcp://) or null (udp)', () async {
    final s = await _server((q) => _answer(q, ips: [[1, 2, 3, 4]]));
    addTearDown(() => s.close());
    expect(await probeDnsVia(Probe(s.port), 'n1', _cand('tcp://dns.test'), 'a..example'), isNull);

    // a SOCKS server that fails the CONNECT (reply 4: host unreachable)
    final deny = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => deny.close());
    deny.listen((c) {
      var stage = 0;
      final buf = <int>[];
      c.listen((d) {
        buf.addAll(d);
        if (stage == 0 && buf.length >= 3) {
          buf.clear();
          stage = 1;
          c.add([5, 2]);
        } else if (stage == 1 && buf.length >= 2 && buf.length >= 3 + buf[1] + buf[2 + buf[1]]) {
          buf.clear();
          stage = 2;
          c.add([1, 0]);
        } else if (stage == 2 && buf.length >= 5) {
          stage = 3;
          c.add([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]);
        }
      }, onError: (Object _) {}, onDone: () => c.destroy());
    });
    expect(await probeDnsVia(Probe(deny.port), 'n1', _cand('tcp://dns.test'), 'a.example'), -1);
    expect(await probeDnsVia(Probe(deny.port), 'n1', _cand('udp://dns.test'), 'a.example'), isNull);
  });
}
