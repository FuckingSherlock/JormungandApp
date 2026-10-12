// The probe pool (pool.dart): identity, coalescing, freshness, the network status; and what
// Auto / the fallback service / the UI's ping do with it.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, plan, unit;

const _url = 'https://t.example/';

void main() {
  late int now;
  late ProbePool pool;
  late List<String> asked;
  setUp(() {
    now = 1000000;
    pool = ProbePool(clock: () => now);
    asked = [];
  });

  // A test that answers [ms] after a moment; every call is written down.
  Future<int> Function(String) one(int ms, {Completer<void>? gate}) => (url) async {
        asked.add(url);
        if (gate != null) await gate.future;
        return ms;
      };

  group('identity', () {
    final ss = {'type': 'shadowsocks', 'server': 'a.example', 'server_port': 1, 'method': 'm', 'password': 'p'};

    test('the same server is one identity whatever it is called, the key order and the detour do not matter', () {
      final a = serverIdentity({...ss, 'tag': 'route0/s::1'});
      final b = serverIdentity({'password': 'p', 'method': 'm', 'server_port': 1, 'server': 'a.example', 'type': 'shadowsocks', 'tag': 't/x', 'detour': 'e'});
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('another server, port or password is another identity; a pair is its own', () {
      final ids = {
        serverIdentity(ss),
        serverIdentity({...ss, 'server': 'b.example'}),
        serverIdentity({...ss, 'server_port': 2}),
        serverIdentity({...ss, 'password': 'q'}),
      };
      expect(ids, hasLength(4));
      expect(pairIdentity('e', 'x'), isNot(pairIdentity('x', 'e')));
      expect(pairIdentity('e', 'x'), isNot('x'));
    });
  });

  group('probe', () {
    test('a measurement in flight is joined: one test for any number of askers', () async {
      final gate = Completer<void>();
      final a = pool.probe('s1', one(40, gate: gate), url: _url);
      final b = pool.probe('s1', one(99), url: _url);
      gate.complete();
      expect(await Future.wait([a, b]), [40, 40]);
      expect(asked, [_url], reason: 'the second asker took the first one\'s result');
    });

    test('another server, URL or set of checkers is another key', () async {
      final gate = Completer<void>();
      final all = [
        pool.probe('s1', one(1, gate: gate), url: _url),
        pool.probe('s2', one(2, gate: gate), url: _url),
        pool.probe('s1', one(3, gate: gate), url: 'https://other.example/'),
        pool.probe('s1', one(4, gate: gate), url: _url, checkers: ['https://c.example/']),
      ];
      gate.complete();
      expect(await Future.wait(all), [1, 2, 3, 4]);
      expect(asked, hasLength(4));
    });

    test('the URL among the checkers and their order are not a different set', () {
      expect(ProbePool.keyOf('s', _url, ['https://b/', 'https://a/', _url]), ProbePool.keyOf('s', _url, ['https://a/', 'https://b/']));
    });

    test('maxAge: an answer young enough is the result, an older one (or no maxAge) is measured again', () async {
      await pool.probe('s1', one(40), url: _url);
      now += 5000;
      expect(await pool.probe('s1', one(60), url: _url, maxAge: const Duration(seconds: 10)), 40, reason: 'answered 5 s ago, 10 s allowed');
      expect(asked, hasLength(1));
      expect(await pool.probe('s1', one(60), url: _url, maxAge: const Duration(seconds: 4)), 60, reason: 'the caller wants it fresher');
      expect(await pool.probe('s1', one(70), url: _url), 70, reason: 'no maxAge: always measured');
      expect(asked, hasLength(3));
    });

    test('a pool of a module run alone reuses nothing', () async {
      final solo = ProbePool.solo(clock: () => now);
      await solo.probe('s1', one(40), url: _url);
      expect(await solo.probe('s1', one(60), url: _url, maxAge: const Duration(hours: 1)), 60);
    });

    test('the backup checkers: the test URL missing, a checker answering is an answer', () async {
      final ms = await pool.probe('s1', (u) async {
        asked.add(u);
        return u == 'https://c.example/' ? 30 : -1;
      }, url: _url, checkers: ['https://c.example/']);
      expect(ms, 30);
    });

    test('a miss is never served by default: whether it is back is a real test', () async {
      await pool.probe('s1', one(-1), url: _url);
      expect(await pool.probe('s1', one(25), url: _url, maxAge: const Duration(minutes: 5)), 25, reason: 'maxAge is for answers');
      expect(asked, hasLength(2));
    });

    test('missAge: a miss is served that long only (a burst of askers), and never longer than missCap', () async {
      await pool.probe('s1', one(-1), url: _url);
      now += 1000;
      expect(await pool.probe('s1', one(25), url: _url, missAge: const Duration(seconds: 2)), -1);
      expect(asked, hasLength(1));
      now += 1500; // 2.5 s after the miss
      expect(await pool.probe('s1', one(25), url: _url, missAge: const Duration(seconds: 2)), 25, reason: 'the miss expired');
      await pool.probe('s2', one(-1), url: _url);
      now += 3500;
      expect(await pool.probe('s2', one(30), url: _url, missAge: const Duration(minutes: 1)), 30, reason: 'capped at 3 s');
    });

    test('record: a result measured elsewhere (the UI\'s ping) is in the pool', () async {
      pool.record('s1', 55, url: _url);
      expect(pool.peek('s1', url: _url)?.ms, 55);
      expect(await pool.probe('s1', one(1), url: _url, maxAge: const Duration(seconds: 5)), 55);
      expect(asked, isEmpty);
      expect(pool.fresh('s1', url: _url, maxAge: const Duration(seconds: 5)), isTrue);
      now += 6000;
      expect(pool.fresh('s1', url: _url, maxAge: const Duration(seconds: 5)), isFalse);
    });
  });

  group('network status', () {
    test('presumed up; the route in use missing is a doubt: unknown; any answer anywhere is up at once', () async {
      expect(pool.status, NetStatus.up);
      pool.doubt(true);
      expect(pool.status, NetStatus.unknown);
      await pool.probe('s1', one(40), url: _url);
      expect(pool.status, NetStatus.up, reason: 'any answered probe clears the doubt');
    });

    test('a miss changes nothing by itself', () async {
      await pool.probe('s1', one(-1), url: _url);
      expect(pool.status, NetStatus.up);
    });

    test('guaranteed down: the OS offline, or the routes and the direct path silent; an answer takes it back', () async {
      pool.offline(true);
      expect(pool.status, NetStatus.down);
      pool.offline(false);
      expect(pool.status, NetStatus.up);
      pool.silent(true);
      expect(pool.status, NetStatus.down);
      pool.record(directIdentity, 5, url: _url);
      expect(pool.status, NetStatus.up, reason: 'the direct path answered');
      pool.offline(true);
      await pool.probe('s1', one(40), url: _url);
      expect(pool.status, NetStatus.up, reason: 'an answer proves the network, whatever the OS said');
    });

    test('onChange is pushed by the call that changes a flag, nobody has to read the status', () async {
      final seen = <NetStatus>[];
      pool.onChange = seen.add;
      pool.offline(true);
      expect(seen, [NetStatus.down]);
      pool.silent(true);
      expect(seen, [NetStatus.down, NetStatus.down], reason: 'a flag moved (os vs probes) although the status did not');
      pool.silent(true);
      expect(seen.length, 2, reason: 'nothing changed: nothing pushed');
      await pool.probe('s1', one(40), url: _url); // an answer anywhere
      expect(seen.last, NetStatus.up);
      expect(seen.length, 3);
      pool.answered();
      pool.resetNetwork();
      expect(seen.length, 3, reason: 'already clean');
      pool.doubt(true);
      expect(seen.last, NetStatus.unknown);
      pool.resetNetwork();
      expect(seen.last, NetStatus.up);
    });

    test('toJson: status and the signs behind it', () {
      pool.doubt(true);
      final j = pool.toJson();
      expect([j['status'], j['doubt'], j['offline'], j['silent']], ['unknown', true, false, false]);
      expect(j['since'], isNotNull);
    });

    test('directAnswers: asks through direct (an answer is up); no way to ask = null', () async {
      expect(await pool.directAnswers(url: _url), isNull);
      pool.direct = (url, t) async => -1;
      expect(await pool.directAnswers(url: _url), isFalse);
      pool.direct = (url, t) async => 9;
      pool.doubt(true);
      expect(await pool.directAnswers(url: _url), isTrue);
      expect(pool.status, NetStatus.up);
    });
  });

  group('Auto and the pool', () {
    Map<String, dynamic> p0() => plan([unit('A', ['s::a'])]);
    String idOf(Map<String, dynamic> p) =>
        serverIdentity((((p['routes'] as List).first as Map)['main']['nodes'] as List).first['outbound'] as Map);

    test('a UI ping result is Auto\'s first test of that server: it is not tested again', () async {
      final p = p0();
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: pool);
      pool.record(idOf(p), 31, url: auto.settings.url, checkers: auto.settings.checkers); // the UI's ping, same kind of test
      await auto.check();
      expect(fake.tested, isNot(contains('route0/s::a')), reason: 'the ping 0 s ago stands for the test');
      expect(auto.toJson()['now'], 'A');
    });

    test('Auto\'s result is the pool\'s: the UI ping of the same server joins / reuses it', () async {
      final p = p0();
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: pool);
      await auto.check();
      final r = pool.peek(idOf(p), url: auto.settings.url, checkers: auto.settings.checkers);
      expect(r?.ms, 30);
      expect(auto.identityOf('route0/s::a'), idOf(p), reason: 'the other modules name a server the same way');
    });

    test('status: no route answers and the direct path is silent → down; it answers → up; it cannot be asked → unknown', () async {
      final p = p0();
      final fake = FakeBox(buildConfig(p), {});
      var directMs = -1;
      pool.direct = (url, t) async => directMs;
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: pool);
      for (var i = 0; i < 3; i++) {
        await auto.check();
      }
      expect(auto.toJson()['noNet'], isTrue);
      expect(pool.status, NetStatus.down);
      directMs = 8;
      await auto.check();
      expect(pool.status, NetStatus.up, reason: 'the direct path answers: the routes are at fault, not the network');

      final pool2 = ProbePool(clock: () => now);
      final auto2 = AutoService(FakeBox(buildConfig(p), {}), p, delay: fake.delayTest, pool: pool2);
      for (var i = 0; i < 3; i++) {
        await auto2.check();
      }
      expect(pool2.status, NetStatus.unknown, reason: 'nothing proves it down');
    });

    test('a route answering again is up at once, the OS offline is down', () async {
      final p = p0();
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: pool);
      await auto.check();
      auto.onLog('missing default interface');
      expect(pool.status, NetStatus.down);
      auto.onLog('updated default interface');
      expect(pool.status, NetStatus.up);
    });
  });

  group('the fallback service and the pool', () {
    test('nothing is judged unless the status is up; the main flow also while unknown', () async {
      final p = {
        'routes': [unit('A', ['s::a'])],
        'current': 0,
        'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
        'routing': {
          'fallback': 'main',
          'targets': {'src:x': unit('src:x', ['s::x1'])},
          'rules': [
            {
              'id': 'r1',
              'name': '',
              'on': true,
              'action': 'proxy',
              'target': 'src:x',
              'fallback': 'block',
              'dns': 'auto',
              'groups': {
                'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}},
              },
            },
          ],
        },
      };
      final info = RoutingInfo();
      final fake = FakeBox(buildConfig(p, info: info), {'s::x1': 40});
      final svc = FallbackService(fake, info.fallbacks, delay: fake.delayTest, settings: const AutoSettings(failAfter: 2, flapGuard: false), pool: pool);
      pool.doubt(true);
      await svc.check();
      expect(fake.tested, isEmpty, reason: 'unknown');
      pool.offline(true);
      await svc.check();
      expect(fake.tested, isEmpty, reason: 'down');
      pool.offline(false);
      await svc.check();
      expect(fake.tested, isEmpty, reason: 'the doubt is still there');
      pool.doubt(false);
      await svc.check();
      expect(fake.tested, ['src:x/s::x1']);
    });

    test('a server a UI ping just measured is not tested again', () async {
      final p = {
        'routes': [unit('A', ['s::a'])],
        'current': 0,
        'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
        'routing': {
          'fallback': 'main',
          'targets': {'src:x': unit('src:x', ['s::x1'])},
          'rules': [
            {
              'id': 'r1',
              'name': '',
              'on': true,
              'action': 'proxy',
              'target': 'src:x',
              'fallback': 'block',
              'dns': 'auto',
              'groups': {
                'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}},
              },
            },
          ],
        },
      };
      final info = RoutingInfo();
      final fake = FakeBox(buildConfig(p, info: info), {'s::x1': 40});
      const settings = AutoSettings(failAfter: 2, flapGuard: false);
      final id = serverIdentity((((p['routing'] as Map)['targets'] as Map)['src:x']['main']['nodes'] as List).first['outbound'] as Map);
      pool.record(id, 42, url: settings.url);
      final svc = FallbackService(fake, info.fallbacks, delay: fake.delayTest, settings: settings, pool: pool);
      await svc.check();
      expect(fake.tested, isEmpty);
      now += 60000; // older than the reuse window: measured again
      await svc.check();
      expect(fake.tested, ['src:x/s::x1']);
    });
  });
}
