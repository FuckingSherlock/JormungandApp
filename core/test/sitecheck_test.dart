// The external checker (sitecheck.dart): check-host.net's answers parsed and judged, with no network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// check-host.net as the tests need it: `check-http` / `check-tcp` start a check, `check-result` answers
/// from [rounds] one by one (the last repeats).
class _Checker {
  _Checker(this.nodes, this.rounds);
  final Map<String, List<String>> nodes; // node -> [cc, country, city]
  final List<Map<String, Object?>> rounds;
  final calls = <Uri>[];
  final ports = <int?>[];
  int polls = 0;
  bool tunnelDown = false;
  int status = 200;

  Future<({int status, String body})> call(Uri url, {int? proxyPort, Duration timeout = Duration.zero}) async {
    calls.add(url);
    ports.add(proxyPort);
    if (proxyPort != null && tunnelDown) throw const SocketException('tunnel does not reach it');
    if (status != 200) return (status: status, body: '');
    final last = url.pathSegments.last;
    if (last == 'check-http' || last == 'check-tcp') return (status: 200, body: jsonEncode({'ok': 1, 'request_id': 'r1', 'nodes': nodes}));
    final r = rounds[polls < rounds.length ? polls : rounds.length - 1];
    polls++;
    return (status: 200, body: jsonEncode(r));
  }
}

const _nodes = {
  'de1': ['de', 'Germany', 'Frankfurt'],
  'fr1': ['fr', 'France', 'Paris'],
  'nl1': ['nl', 'Netherlands', 'Amsterdam'],
  'us1': ['us', 'USA', 'New York'],
};

Object _okHttp(double s, [String code = '200']) => [[1, s, 'OK', code, '1.2.3.4']];
Object _badHttp([String err = 'Connection timed out']) => [[0, 5.0, err]];

SiteChecker _make(_Checker c, {int? Function()? proxy, int perMinute = 4, DateTime Function()? now}) =>
    SiteChecker(get: c.call, proxyPort: proxy, delay: (_) async {}, perMinute: perMinute, now: now);

void main() {
  group('parseCheckNode', () {
    test('http: null is pending, [[1,…]] ok with code and time, [[0,…]] / [[null]] / [] / junk failed', () {
      expect(parseCheckNode(null, tcp: false).pending, isTrue);
      final ok = parseCheckNode(_okHttp(0.25, '403'), tcp: false);
      expect([ok.pending, ok.ok, ok.code, ok.ms], [false, true, 403, 250]);
      final bad = parseCheckNode(_badHttp('Connection refused'), tcp: false);
      expect([bad.pending, bad.ok, bad.error], [false, false, 'Connection refused']);
      for (final v in [<Object>[], [[null]], [null], 'x', 5, [[]]]) {
        final p = parseCheckNode(v, tcp: false);
        expect([p.pending, p.ok], [false, false], reason: '$v');
      }
    });
    test('tcp: [{time}] ok, [{error}] failed', () {
      expect(parseCheckNode([{'time': 0.05, 'address': '1.1.1.1'}], tcp: true).ok, isTrue);
      final e = parseCheckNode([{'error': 'Connection timed out'}], tcp: true);
      expect([e.ok, e.error], [false, 'Connection timed out']);
    });
  });

  group('SiteChecker', () {
    test('opens: pending nodes wait for the next poll; two ok nodes are enough; the nodes carry country, code, time', () async {
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': null, 'nl1': null, 'us1': _badHttp()},
        {'de1': _okHttp(0.2), 'fr1': _okHttp(0.3, '301'), 'nl1': _badHttp(), 'us1': _badHttp()},
      ]);
      final r = await _make(c).check('example.com', 443);
      expect([r.state, r.kind, r.via, r.ok], ['opens', 'http', 'direct', 2]);
      expect(c.polls, 2);
      expect(c.calls.first.queryParameters, {'host': 'https://example.com', 'max_nodes': '8'});
      final j = r.toJson();
      expect(j['total'], 4);
      expect((j['nodes'] as List).first, {'cc': 'DE', 'country': 'Germany', 'city': 'Frankfurt', 'ok': true, 'code': 200, 'ms': 200});
      expect((j['nodes'] as List)[1]['code'], 301);
      expect((j['nodes'] as List).last, containsPair('error', 'Connection timed out'));
    });

    test('down: nodes answered and fewer than two reach it', () async {
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': _badHttp(), 'nl1': _badHttp(), 'us1': _badHttp()},
      ]);
      final r = await _make(c).check('dead.example', 443);
      expect([r.state, r.ok], ['down', 1]);
    });

    test('nodes that never answer say nothing: too few answers is failed, not down', () async {
      final c = _Checker(_nodes, [
        {'de1': _badHttp(), 'fr1': null, 'nl1': null, 'us1': null},
      ]);
      final r = await _make(c).check('slow.example', 443);
      expect(r.state, 'failed');
      expect(r.error, contains('1 of 4'));
    });

    test('a checker that does not answer: HTTP error, no network, junk — failed with the reason, never an exception', () async {
      final c = _Checker(_nodes, const [{}])..status = 503;
      final r = await _make(c).check('example.com', 443);
      expect([r.state, r.error], ['failed', contains('503')]);
      final r2 = await SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => (status: 200, body: '<html>'), delay: (_) async {}).check('example.com', 443);
      expect(r2.state, 'failed');
    });

    test('through the tunnel; when it does not reach the checker, direct, and the result says so', () async {
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': _okHttp(0.2), 'nl1': _okHttp(0.2), 'us1': _okHttp(0.2)},
      ]);
      var r = await _make(c, proxy: () => 7000).check('example.com', 443);
      expect([r.state, r.via, c.ports.toSet()], ['opens', 'tunnel', {7000}]);
      c.tunnelDown = true;
      r = await _make(c, proxy: () => 7000).check('other.example', 443);
      expect([r.state, r.via], ['opens', 'direct']);
      expect(c.ports.last, isNull);
    });

    test('an address or a non-web port is asked as TCP', () async {
      final c = _Checker(_nodes, [
        {'de1': [{'time': 0.1}], 'fr1': [{'time': 0.1}], 'nl1': [{'error': 'x'}], 'us1': [{'error': 'x'}]},
      ]);
      final ch = _make(c);
      expect((await ch.check('1.2.3.4', 443)).kind, 'tcp');
      expect(c.calls.first.pathSegments.last, 'check-tcp');
      expect(c.calls.first.queryParameters['host'], '1.2.3.4:443');
      final r = await ch.check('game.example', 25565);
      expect([r.kind, r.state], ['tcp', 'opens']);
      expect(c.calls.where((u) => u.pathSegments.last == 'check-tcp').last.queryParameters['host'], 'game.example:25565');
      await ch.check('web.example', 80);
      expect(c.calls.where((u) => u.pathSegments.last == 'check-http').last.queryParameters['host'], 'http://web.example');
    });

    test('cache: the same site again within 10 minutes costs no request; manual asks again; a failure is not cached', () async {
      var t = DateTime(2026, 1, 1);
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': _okHttp(0.2), 'nl1': _okHttp(0.2), 'us1': _okHttp(0.2)},
      ]);
      final ch = _make(c, now: () => t);
      await ch.check('example.com', 443);
      final n = c.calls.length;
      expect((await ch.check('example.com', 443)).state, 'opens');
      expect(c.calls.length, n, reason: 'cached');
      await ch.check('example.com', 443, manual: true);
      expect(c.calls.length, greaterThan(n), reason: 'manual ignores the cache');
      t = t.add(const Duration(minutes: 11));
      final n2 = c.calls.length;
      await ch.check('example.com', 443);
      expect(c.calls.length, greaterThan(n2), reason: 'cache expired');
      c.status = 500;
      await ch.check('bad.example', 443);
      final n3 = c.calls.length;
      await ch.check('bad.example', 443);
      expect(c.calls.length, greaterThan(n3), reason: 'a failed run is asked again');
    });

    test('at most a few automatic checks per minute; manual is not counted; a minute later it goes on', () async {
      var t = DateTime(2026, 1, 1);
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': _okHttp(0.2), 'nl1': _okHttp(0.2), 'us1': _okHttp(0.2)},
      ]);
      final ch = _make(c, perMinute: 2, now: () => t);
      expect((await ch.check('a.example', 443)).state, 'opens');
      expect((await ch.check('b.example', 443)).state, 'opens');
      final third = await ch.check('c.example', 443);
      expect([third.state, third.error], ['failed', 'too many checks']);
      expect((await ch.check('c.example', 443, manual: true)).state, 'opens');
      t = t.add(const Duration(seconds: 61));
      expect((await ch.check('d.example', 443)).state, 'opens');
    });

    group('cancel', () {
      final allOk = {'de1': _okHttp(0.2), 'fr1': _okHttp(0.2), 'nl1': _okHttp(0.2), 'us1': _okHttp(0.2)};
      final pending = {'de1': null, 'fr1': null, 'nl1': null, 'us1': null};

      test('cancelled before the ask: no request at all', () async {
        final c = _Checker(_nodes, [allOk]);
        final cancel = Cancel()..cancel('x');
        final r = await _make(c).check('example.com', 443, cancel: cancel);
        expect(r.state, 'cancelled');
        expect(c.calls, isEmpty);
      });

      test('cancelled while it polls: the ask completes at once, no further poll, nothing cached', () async {
        final cancel = Cancel();
        late _Checker c;
        c = _Checker(_nodes, [pending]);
        final ch = SiteChecker(
          get: (url, {proxyPort, timeout = Duration.zero}) {
            // the second poll is the one that finds the asker gone
            if (url.pathSegments.contains('check-result') && c.polls == 1) cancel.cancel('opened');
            return c.call(url, proxyPort: proxyPort, timeout: timeout);
          },
          delay: (_) async {},
        );
        final r = await ch.check('example.com', 443, cancel: cancel);
        expect(r.state, 'cancelled');
        final n = c.calls.length;
        expect(c.polls, 2);
        await pumpEventQueue();
        expect(c.calls.length, n, reason: 'no request after the cancel');
        // not cached: a new ask starts a new run
        c.rounds
          ..clear()
          ..add(allOk);
        c.polls = 0;
        final again = await ch.check('example.com', 443);
        expect(again.state, 'opens');
        expect(c.calls.length, greaterThan(n));
      });

      test('a request that hangs is not waited for', () async {
        final cancel = Cancel();
        final hang = Completer<({int status, String body})>();
        var calls = 0;
        final ch = SiteChecker(get: (url, {proxyPort, timeout = Duration.zero}) {
          calls++;
          return hang.future;
        }, delay: (_) async {});
        final f = ch.check('example.com', 443, cancel: cancel);
        await pumpEventQueue();
        cancel.cancel('opened');
        expect((await f).state, 'cancelled');
        hang.complete((status: 200, body: jsonEncode({'ok': 1, 'request_id': 'r', 'nodes': _nodes})));
        await pumpEventQueue();
        expect(calls, 1, reason: 'the answer that comes late starts nothing');
      });

      test('a run shared with an ask that cannot be cancelled goes on; the run is dropped only when every asker has cancelled', () async {
        final c = _Checker(_nodes, [pending, allOk]);
        final ch = _make(c);
        final cancelA = Cancel(), cancelB = Cancel();
        final a = ch.check('example.com', 443, cancel: cancelA);
        final plain = ch.check('example.com', 443, manual: true);
        cancelA.cancel('opened');
        expect((await a).state, 'cancelled');
        expect((await plain).state, 'opens', reason: 'the other asker still wants it');

        final c2 = _Checker(_nodes, [pending]);
        final ch2 = _make(c2);
        final x = ch2.check('other.example', 443, cancel: cancelB);
        final cancelC = Cancel();
        final y = ch2.check('other.example', 443, cancel: cancelC);
        cancelB.cancel('opened');
        cancelC.cancel('opened');
        expect([(await x).state, (await y).state], ['cancelled', 'cancelled']);
        final n = c2.calls.length;
        await pumpEventQueue();
        expect(c2.calls.length, n);
      });
    });

    test('two asks for one site at once share one run', () async {
      final c = _Checker(_nodes, [
        {'de1': _okHttp(0.2), 'fr1': _okHttp(0.2), 'nl1': _okHttp(0.2), 'us1': _okHttp(0.2)},
      ]);
      final ch = _make(c);
      final rs = await Future.wait([ch.check('example.com', 443), ch.check('example.com', 443, manual: true)]);
      expect(identical(rs[0], rs[1]), isTrue);
      expect(c.calls.where((u) => u.pathSegments.last == 'check-http').length, 1);
    });
  });
}
