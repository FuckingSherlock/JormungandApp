// probeReach against a fake SOCKS5 inbound on loopback: only a request that really went
// through the tag may say "does not open" (false); a test that never ran says null.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// A one-shot SOCKS5 server with the password method. [authOk] false = it refuses the user
/// name (as sing-box does for a user that is not in the inbound's list); [reply] is the
/// code of the reply to the CONNECT.
Future<ServerSocket> _server({required bool authOk, int reply = 4}) async {
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
        if (buf.length < 2 + n + 1) return;
        final m = buf[2 + n];
        if (buf.length < 3 + n + m) return;
        buf.clear();
        stage = 2;
        c.add([1, authOk ? 0 : 1]);
        if (!authOk) c.close();
      } else if (stage == 2 && buf.length >= 5) {
        stage = 3;
        c.add([5, reply, 0, 1, 0, 0, 0, 0, 0, 0]);
        c.close();
      }
    }, onError: (Object _) {}, onDone: () => c.destroy());
  });
  return s;
}

void main() {
  group('probeReach', () {
    test('the inbound refuses the user name (no such outbound): null, not false', () async {
      final s = await _server(authOk: false);
      addTearDown(() => s.close());
      expect(await probeReach(Probe(s.port, 'x'), 'route0', 'example.com:443'), isNull);
      expect(await probeReach(Probe(s.port, 'x'), 'route0', 'example.com:80'), isNull);
    });

    test('the probe inbound is not there: null', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      expect(await probeReach(Probe(port, 'x'), 'route0/s::a', 'example.com:443', timeoutMs: 1500), isNull);
    });

    test('the request went through the tag and the proxy could not connect (reply 4): false', () async {
      final s = await _server(authOk: true, reply: 4);
      addTearDown(() => s.close());
      expect(await probeReach(Probe(s.port, 'x'), 'route0/s::a', 'example.com:443'), isFalse);
    });

    test('a destination that cannot be tested (other port, IP on 443): null before any connection', () async {
      final p = Probe(1, 'x');
      expect(await probeReach(p, 'route0/s::a', 'example.com:8443'), isNull);
      expect(await probeReach(p, 'route0/s::a', '1.2.3.4:443'), isNull);
    });
  });
}
