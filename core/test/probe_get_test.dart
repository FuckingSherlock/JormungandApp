// probeGet / checkExitVia (probe.dart, exitip.dart) against a fake SOCKS5 inbound on loopback that, after the
// CONNECT, answers the request with canned bytes: the three ways an HTTP body ends (content-length, chunked, until
// the server closes), a refusal, an answer over the cap, abort. The same functions against a real sing-box:
// exit_via_singbox_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// A SOCKS5 server (user name / password method) that accepts every CONNECT, then writes [answer] to the first
/// request and closes when [closeAfter]. [seen] gets the user name and the requested host:port.
Future<ServerSocket> _server(List<int> answer, {List<String>? seen, bool closeAfter = true, bool silent = false, void Function()? onClosed}) async {
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
      } else if (stage == 3 && utf8.decode(buf, allowMalformed: true).contains('\r\n\r\n')) {
        stage = 4;
        seen?.add(utf8.decode(buf, allowMalformed: true).split('\r\n').first); // the request line
        if (!silent) c.add(answer);
        if (closeAfter && !silent) c.close();
      }
    }, onError: (Object _) {}, onDone: () {
      onClosed?.call();
      c.destroy();
    });
  });
  return s;
}

List<int> _http(String head, String body, {bool length = true, bool chunked = false}) {
  final b = utf8.encode(body);
  if (chunked) {
    // two chunks, the second split by a chunk extension
    final half = b.length ~/ 2;
    return [
      ...ascii.encode('$head\r\nTransfer-Encoding: chunked\r\n\r\n'),
      ...ascii.encode('${half.toRadixString(16)}\r\n'), ...b.sublist(0, half), 13, 10,
      ...ascii.encode('${(b.length - half).toRadixString(16)};ext=1\r\n'), ...b.sublist(half), 13, 10,
      ...ascii.encode('0\r\n\r\n'),
    ];
  }
  return [...ascii.encode('$head\r\n${length ? 'Content-Length: ${b.length}\r\n' : ''}\r\n'), ...b];
}

const _json = '{"ip":"203.0.113.5","country":"DE"}';

void main() {
  group('probeGet', () {
    test('content-length: the body, asked as the tag\'s user for the url\'s host and port', () async {
      final seen = <String>[];
      final s = await _server(_http('HTTP/1.1 200 OK', _json), seen: seen);
      addTearDown(() => s.close());
      final probe = Probe(s.port, 'pw');
      expect(await probeGet(probe, 'route0/s::a', 'http://exit.test:8080/ip?x=1'), _json);
      expect(seen, ['route0/s::a', 'exit.test:8080', 'GET /ip?x=1 HTTP/1.1']);
    });

    test('chunked, with a chunk extension and a multi-byte body', () async {
      const body = '{"ip":"203.0.113.5","city":"Zürich — Ω"}';
      final s = await _server(_http('HTTP/1.1 200 OK', body, chunked: true), closeAfter: false);
      addTearDown(() => s.close());
      expect(await probeGet(Probe(s.port), 'route0', 'http://exit.test/'), body);
    });

    test('no length, no chunks: the body ends where the server closes', () async {
      final s = await _server(_http('HTTP/1.0 200 OK', _json, length: false));
      addTearDown(() => s.close());
      expect(await probeGet(Probe(s.port), 'route0', 'http://exit.test/'), _json);
    });

    test('not 200: HttpException with the status', () async {
      final s = await _server(_http('HTTP/1.1 503 Service Unavailable', 'busy'));
      addTearDown(() => s.close());
      await expectLater(probeGet(Probe(s.port), 'route0', 'http://exit.test/'), throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('503'))));
    });

    test('an answer over 256 KiB is an error, not memory', () async {
      final s = await _server(_http('HTTP/1.1 200 OK', 'x' * (300 * 1024)));
      addTearDown(() => s.close());
      await expectLater(probeGet(Probe(s.port), 'route0', 'http://exit.test/'), throwsA(isA<SocketException>()));
    });

    test('not http: an error', () async {
      final s = await _server(ascii.encode('SSH-2.0-nope\r\n\r\n'));
      addTearDown(() => s.close());
      await expectLater(probeGet(Probe(s.port), 'route0', 'http://exit.test/'), throwsA(isA<SocketException>()));
    });

    test('a server that never answers: TimeoutException at the timeout', () async {
      final closed = Completer<void>();
      final s = await _server(const [], silent: true, onClosed: closed.complete);
      addTearDown(() => s.close());
      await expectLater(probeGet(Probe(s.port), 'route0', 'http://exit.test/', timeout: const Duration(milliseconds: 300)), throwsA(isA<TimeoutException>()));
      await closed.future.timeout(const Duration(seconds: 2), onTimeout: () => fail('the connection stays open after the timeout'));
    });

    test('abort closes the connection', () async {
      final closed = Completer<void>(), abort = Completer<void>();
      final s = await _server(const [], silent: true, onClosed: closed.complete);
      addTearDown(() => s.close());
      final r = probeGet(Probe(s.port), 'route0', 'http://exit.test/', abort: abort.future).then<Object?>((b) => b, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      abort.complete();
      await closed.future.timeout(const Duration(seconds: 2), onTimeout: () => fail('abort did not close the connection'));
      expect(await r, isA<Exception>());
    });

    test('the inbound refuses the user: ProbeRefused', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => s.close());
      s.listen((c) {
        c.listen((_) {
          c.add([5, 0xff]); // no acceptable method
          c.close();
        }, onError: (Object _) {});
      });
      await expectLater(probeGet(Probe(s.port), 'route0', 'http://exit.test/'), throwsA(isA<ProbeRefused>()));
    });
  });

  group('checkExitVia', () {
    ExitProbe svc(String name, String path) => (name: name, url: 'http://exit.test$path', read: (b) => jsonDecode(b) as Map<String, dynamic>);

    test('asks every service through the tag; the first complete answer (ip, country, city) wins', () async {
      final seen = <String>[];
      final s = await _server(_http('HTTP/1.1 200 OK', '{"ip":"203.0.113.5","country":"DE","city":"Berlin"}'), seen: seen);
      addTearDown(() => s.close());
      final r = await checkExitVia(Probe(s.port), 'route1/s::b', probes: [svc('a', '/a'), svc('b', '/b')], timeout: const Duration(seconds: 3));
      expect(r, containsPair('ip', '203.0.113.5'));
      expect(r, containsPair('country', 'DE'));
      expect(r['source'], anyOf('a', 'b'));
      expect(seen.where((x) => x == 'route1/s::b'), isNotEmpty, reason: 'pinned: the user is the node\'s outbound tag');
    });

    test('nothing answers: throws with the reasons', () async {
      final s = await _server(_http('HTTP/1.1 500 Oops', 'no'));
      addTearDown(() => s.close());
      await expectLater(
        checkExitVia(Probe(s.port), 'route0', probes: [svc('a', '/a')], timeout: const Duration(seconds: 2)),
        throwsA(isA<Exception>().having((e) => '$e', 'text', allOf(contains('no answer through the tunnel'), contains('a:')))),
      );
    });
  });
}
