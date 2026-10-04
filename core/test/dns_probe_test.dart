// dnsLatency (dns_probe.dart) against loopback DNS servers that answer, stay silent or answer wrongly.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

void main() {
  test('dnsQuery / isDnsAnswer: the id and the QR bit decide', () {
    final q = dnsQuery('a.bc', 0x1234);
    expect(q.sublist(0, 2), [0x12, 0x34]);
    expect(q.sublist(12), [1, 97, 2, 98, 99, 0, 0, 1, 0, 1]);
    expect(isDnsAnswer(q, 0x1234), isFalse); // a query is no answer
    final a = [...q]..[2] = 0x81;
    expect(isDnsAnswer(a, 0x1234), isTrue);
    expect(isDnsAnswer(a, 0x1235), isFalse);
  });

  test('udp: a bare IP:port and udp:// are timed, a silent server is -1', () async {
    final srv = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    var answer = true;
    srv.listen((e) {
      final d = e == RawSocketEvent.read ? srv.receive() : null;
      if (d == null || !answer) return;
      final r = [...d.data]..[2] = 0x81;
      srv.send(r, d.address, d.port);
    });
    addTearDown(srv.close);
    expect(await dnsLatency('127.0.0.1:${srv.port}'), greaterThanOrEqualTo(0));
    expect(await dnsLatency('udp://127.0.0.1:${srv.port}'), greaterThanOrEqualTo(0));
    answer = false;
    expect(await dnsLatency('127.0.0.1:${srv.port}', timeout: const Duration(milliseconds: 300)), -1);
  });

  test('tcp: the length-prefixed answer is timed, a closed port is -1', () async {
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((s) {
      final got = <int>[];
      s.listen((d) {
        got.addAll(d);
        if (got.length < 2 || got.length < 2 + ((got[0] << 8) | got[1])) return;
        final r = [...got.sublist(2)]..[2] = 0x81;
        s.add([r.length >> 8, r.length & 255, ...r]);
      });
    });
    final port = srv.port;
    expect(await dnsLatency('tcp://127.0.0.1:$port'), greaterThanOrEqualTo(0));
    await srv.close();
    expect(await dnsLatency('tcp://127.0.0.1:$port', timeout: const Duration(milliseconds: 500)), -1);
  });

  test('quic cannot be measured here, an unreachable name is -1', () async {
    expect(await dnsLatency('quic://dns.example'), isNull);
    expect(await dnsLatency('udp://no-such-host.invalid', timeout: const Duration(seconds: 2)), -1);
  });
}
