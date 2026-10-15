// The service side of the node address pre-resolve (docs/rules.md §6 → «Адреса серверов»): what a connect waits
// for (cache first, missing hosts of the starting servers ≤ ~1.5 s, all DNS servers at once, the rest in the
// background), and what a server that stopped answering does (serverDown: next cached address, a new lookup,
// one restart `reresolve` only when the IP set changed, once per host per 5 min, never offline / unsettled).
// A fake BoxRunner (no sing-box); the DoH server is a loopback mock.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'address_test.dart' show MockDoh, doh;
import 'sentinel_fakes.dart';

class _Runner implements BoxRunner {
  _Runner({this.failStart = false, this.gate});
  final bool failStart;
  final Completer<void>? gate; // start waits for it
  final configs = <Map<String, dynamic>>[];
  bool up = false;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async {
    await gate?.future;
    if (failStart) throw StateError('no sing-box in this test');
    configs.add(config);
    up = true;
  }

  @override
  Future<void> stop() async => up = false;

  String? serverOf(String tag, [int? at]) {
    final c = configs[at ?? configs.length - 1];
    for (final o in (c['outbounds'] as List).cast<Map>()) {
      if (o['tag'] == tag) return o['server'] as String?;
    }
    return null;
  }
}

/// A resolver that answers from a table; `ensure` only records why it was asked.
class _Fake extends AddressResolver {
  _Fake(AddressBook book, this.clock)
      : super(book: book, fetch: () => ServiceFetch(endpoint: () => null), settings: () async => const AddressSettings());
  final DateTime Function() clock;
  final answers = <String, List<String>>{};
  final looked = <String>[];
  final whys = <String>[];

  @override
  Future<void> ensure(Iterable<String> hosts,
      {required String why, Duration wait = const Duration(seconds: 8), Iterable<String> first = const [], bool refreshAll = false, Iterable<String>? need, bool race = false}) async {
    whys.add(why);
  }

  @override
  Future<AddressEntry?> lookup(String host, {required String why, Duration? race}) async {
    looked.add(host);
    final a = answers[host];
    if (a == null) return null;
    final old = book.get(host);
    final fresh = AddressEntry(v4: a, v6: const [], at: clock().millisecondsSinceEpoch, ttl: 300, via: 'fake');
    final e = old != null && old.sameSet(fresh) ? AddressEntry(v4: old.v4, v6: old.v6, at: fresh.at, ttl: 300, via: 'fake', cursor: old.cursor) : fresh;
    book.put(host, e);
    return e;
  }
}

Map<String, dynamic> _node(String key, String server) => {
      'key': key,
      'outbound': {'type': 'shadowsocks', 'server': server, 'server_port': 8388, 'method': 'aes-128-gcm', 'password': 'x'},
    };

Map<String, dynamic> _route(String id, Map<String, String> keyToServer) => {
      'id': id,
      'kind': 'unit',
      'main': {'pick': 'priority', 'chosen': keyToServer.keys.first, 'nodes': [for (final e in keyToServer.entries) _node(e.key, e.value)]},
    };

Map<String, dynamic> _body(List<Map<String, dynamic>> routes, {int current = 0}) => {
      'plan': {'routes': routes, 'current': current, 'mixedPort': 2080, 'global': true},
      'systemProxy': false,
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;
  _Fake? fake;
  MockDoh? fast, slow;

  Future<void> boot({bool useFake = false, List<DnsCandidate> Function()? servers, Completer<void>? testerGate}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc-addr');
    runner = _Runner();
    time = FakeTime();
    fake = null;
    svc = CoreService(
      sentinelClock: time.clock,
      timer: time.clock.timer,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      // the connect's check of servers (TesterSession) cannot start its sing-box here: "tester did not start" → the plan as it is.
      // A tester that ran would find no network in a test (nobody answers) and put the core's network down, and wait the test timeout.
      boxFactory: (_) => _Runner(failStart: true, gate: testerGate),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
      addressResolverFor: (book) => useFake
          ? fake = _Fake(book, () => time.t)
          : AddressResolver(
              book: book,
              fetch: () => ServiceFetch(endpoint: () => null),
              settings: () async => AddressSettings(candidates: servers!()),
              attempt: const Duration(seconds: 3),
              budget: const Duration(seconds: 6),
            ),
    );
    await svc.init();
    if (useFake) fake = svc.addresses as _Fake; // the resolver is made on first use
  }

  /// The 2 s debounce of a restart, then the real I/O of the connect (ports, rule lists) it runs.
  Future<void> restartWait() async {
    await time.advanceSeconds(3);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await time.advanceSeconds(1);
  }

  AddressEntry seeded(List<String> ips) => AddressEntry(v4: ips, v6: const [], at: time.t.millisecondsSinceEpoch, ttl: 300, via: 'seed');

  tearDown(() async {
    await svc.dispose();
    await fast?.stop();
    await slow?.stop();
    fast = slow = null;
    await tmp.delete(recursive: true);
  });

  group('connect wait', () {
    test('everything cached: no wait, no query, the config holds the addresses', () async {
      fast = await MockDoh({'a.example': ['10.0.0.1']}).start();
      await boot(servers: () => [doh('f', fast!.url)]);
      svc.addressBook.put('a.example', seeded(['10.0.0.1', '10.0.0.2']));
      final sw = Stopwatch()..start();
      await svc.connect(_body([_route('A', {'s::a': 'a.example'})]));
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(runner.serverOf('route0/s::a'), '10.0.0.1');
      expect(fast!.asked, isEmpty);
      // the report shows what the config holds for the host and who answered the lookup
      final msgs = [for (final l in svc.log(since: null)['lines'] as List) '${(l as Map)['msg']}'];
      expect(msgs.any((m) => m.contains('address: config for connect: a.example → 10.0.0.1 (via seed, ')), isTrue, reason: msgs.join('\n'));
    });

    test('missing and slow: waits about 1.5 s, then starts with the name; the answer lands in the book without a restart', () async {
      slow = await MockDoh({'a.example': ['10.0.0.1']}, delay: const Duration(milliseconds: 2800)).start();
      await boot(servers: () => [doh('s', slow!.url)]);
      final sw = Stopwatch()..start();
      await svc.connect(_body([_route('A', {'s::a': 'a.example'})]));
      expect(sw.elapsedMilliseconds, inInclusiveRange(1400, 2300));
      expect(runner.serverOf('route0/s::a'), 'a.example', reason: 'not resolved in time: the old way (domain + domain_resolver)');
      expect(runner.configs, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(svc.addressBook.get('a.example')!.v4, ['10.0.0.1'], reason: 'resolved in the background');
      expect(runner.configs, hasLength(1), reason: 'never a restart just to pin');
      expect((svc.log(since: null)['lines'] as List).any((l) => '${(l as Map)['msg']}'.contains('connect waited')), isTrue);
    });

    test('all DNS servers are asked at once: the higher-priority answer within the window wins, no waiting one after another', () async {
      slow = await MockDoh({'a.example': ['10.0.0.1']}, delay: const Duration(milliseconds: 500)).start();
      fast = await MockDoh({'a.example': ['10.0.0.2']}).start();
      await boot(servers: () => [doh('s', slow!.url), doh('f', fast!.url)]);
      final sw = Stopwatch()..start();
      await svc.connect(_body([_route('A', {'s::a': 'a.example'})]));
      expect(sw.elapsedMilliseconds, lessThan(1300));
      expect(runner.serverOf('route0/s::a'), '10.0.0.1');
      expect(fast!.count('a.example', 1), 1);
    });

    test('only the servers the selected route starts with are waited for; the other routes keep their names', () async {
      slow = MockDoh({'a.example': ['10.0.0.1'], 'b.example': ['10.0.0.9']})..delays['b.example'] = const Duration(milliseconds: 2500);
      await slow!.start();
      await boot(servers: () => [doh('s', slow!.url)]);
      final sw = Stopwatch()..start();
      await svc.connect(_body([_route('A', {'s::a': 'a.example'}), _route('B', {'s::b': 'b.example'})]));
      expect(sw.elapsedMilliseconds, lessThan(1300));
      expect(runner.serverOf('route0/s::a'), '10.0.0.1');
      expect(runner.serverOf('route1/s::b'), 'b.example');
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(svc.addressBook.get('b.example')!.v4, ['10.0.0.9']);
      expect(runner.configs, hasLength(1));
    });
  });

  group('serverDown', () {
    final plan = _body([_route('A', {'s::a': 'a.example', 's::ip': '192.0.2.5'})]);

    Future<void> up() async {
      await boot(useFake: true);
      svc.addressBook.put('a.example', seeded(['10.0.0.1', '10.0.0.2']));
      fake!.answers['a.example'] = ['10.0.0.1', '10.0.0.2'];
      await svc.connect(plan);
      await time.advanceSeconds(6); // settled
    }

    test('not pinned (an IP, an unknown member): nothing happens', () async {
      await up();
      svc.reresolveEvery = Duration.zero;
      svc.serverDown('route0', 's::ip');
      svc.serverDown('route0', 'nope');
      svc.serverDown('route7', 's::a');
      await time.advanceSeconds(5);
      expect(runner.configs, hasLength(1));
      expect(fake!.looked, isEmpty);
    });

    test('the next cached address first: one restart (reason reresolve) on it; then rate limited for 5 min', () async {
      await up();
      expect(runner.serverOf('route0/s::a'), '10.0.0.1');
      svc.serverDown('route0', 's::a');
      await restartWait();
      expect(runner.configs, hasLength(2));
      expect(runner.serverOf('route0/s::a'), '10.0.0.2');
      expect(fake!.whys.last, 'reresolve');
      expect(fake!.looked, isEmpty, reason: 'a cached address was left to try: no lookup');
      await time.advanceSeconds(6);
      svc.serverDown('route0', 's::a'); // within 5 min of the last time
      await time.advanceSeconds(5);
      expect(runner.configs, hasLength(2));
      expect(fake!.looked, isEmpty);
    });

    test('every cached address tried: the name is looked up; the same set = no restart, a changed set = one restart', () async {
      await up();
      svc.reresolveEvery = Duration.zero;
      svc.serverDown('route0', 's::a');
      await restartWait();
      await time.advanceSeconds(6);
      expect(runner.serverOf('route0/s::a'), '10.0.0.2');
      svc.serverDown('route0', 's::a'); // both tried now
      await restartWait();
      expect(fake!.looked, ['a.example']);
      expect(runner.configs, hasLength(2), reason: 'the IP set did not change');

      fake!.answers['a.example'] = ['10.0.0.9'];
      svc.serverDown('route0', 's::a');
      await restartWait();
      expect(fake!.looked, ['a.example', 'a.example']);
      expect(runner.configs, hasLength(3));
      expect(runner.serverOf('route0/s::a'), '10.0.0.9');
      expect(fake!.whys.last, 'reresolve');
    });

    test('startHostnames: a group that starts on its chosen server waits for that server\'s host only', () async {
      await boot(useFake: true); // the group's tearDown expects a booted service
      Map<String, dynamic> two(String? chosen) => {
            'routes': [
              {
                'id': 'A',
                'kind': 'unit',
                'main': {'pick': 'fastest', 'chosen': chosen, 'nodes': [_node('s::a', 'a.example'), _node('s::b', 'b.example'), _node('s::c', 'c.example')]},
              },
            ],
          };
      expect(startHostnames(two('s::b')), {'b.example'});
      expect(startHostnames(two(null)), {'a.example', 'b.example', 'c.example'}, reason: 'no chosen: the group starts on its first, any of them may be needed');
      expect(startHostnames(two('s::gone')), {'a.example', 'b.example', 'c.example'}, reason: 'a chosen that is not a member is no choice');
    });

    test('connectPicks: a continuation keeps a valid chosen (no check); a group without one is checked', () async {
      await boot(useFake: true);
      List<String> checks() => [
            for (final l in svc.log(since: null)['lines'] as List)
              if ('${(l as Map)['msg']}'.contains('connect: the servers of route0')) '${l['msg']}',
          ];
      final multi = _body([_route('A', {'s::a': 'a.example', 's::b': 'b.example'})])['plan'] as Map<String, dynamic>;
      expect(await svc.connectPicks(multi, continuation: true), isEmpty);
      expect(checks(), isEmpty, reason: 'the core\'s chosen stands');
      final noChosen = {
        ...multi,
        'routes': [
          for (final r in multi['routes'] as List) {...(r as Map), 'main': {...(r['main'] as Map), 'chosen': null}},
        ],
      };
      expect(await svc.connectPicks(noChosen, continuation: true), isEmpty);
      expect(checks(), hasLength(1), reason: 'no chosen: checked (the tester cannot start here: the plan is used as it is)');
      expect(await svc.connectPicks(multi), isEmpty);
      expect(checks(), hasLength(2), reason: 'a fresh connect checks the group even with the app\'s chosen');
    });

    test('a disconnect while the servers are checked: no sing-box is started', () async {
      final gate = Completer<void>();
      await boot(useFake: true, testerGate: gate);
      svc.addressBook.put('a.example', seeded(['10.0.0.1']));
      svc.addressBook.put('b.example', seeded(['10.0.0.2']));
      final c = svc.connect(_body([_route('A', {'s::a': 'a.example', 's::b': 'b.example'})]));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(gate.isCompleted, isFalse);
      final d = svc.disconnect(); // cancels the pick; waits for the connect's lock
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete();
      await Future.wait([c, d]);
      expect(runner.configs, isEmpty, reason: 'the cancelled connect never started sing-box');
      expect(runner.up, isFalse);
    });

    test('not while the core is not settled, the network is not up, or sing-box is down', () async {
      await boot(useFake: true);
      svc.addressBook.put('a.example', seeded(['10.0.0.1', '10.0.0.2']));
      svc.reresolveEvery = Duration.zero;
      await svc.connect(plan); // just started: not settled
      svc.serverDown('route0', 's::a');
      await time.advanceSeconds(1);
      expect(runner.configs, hasLength(1), reason: 'unsettled');

      await time.advanceSeconds(6);
      svc.sentinel.context.pool(NetStatus.down, osOffline: true);
      svc.serverDown('route0', 's::a');
      await restartWait();
      expect(runner.configs, hasLength(1), reason: 'offline');
      svc.sentinel.context.pool(NetStatus.up, osOffline: false);

      // the restart's own gates are checked again when its timer fires
      svc.serverDown('route0', 's::a');
      svc.sentinel.context.pool(NetStatus.down, osOffline: true);
      await restartWait();
      expect(runner.configs, hasLength(1), reason: 'went offline before the restart');
      svc.sentinel.context.pool(NetStatus.up, osOffline: false);

      await svc.disconnect();
      svc.serverDown('route0', 's::a');
      await restartWait();
      expect(runner.configs, hasLength(1), reason: 'nothing running');
    });
  });
}
