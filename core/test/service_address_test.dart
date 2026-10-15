// The service side of the node address pre-resolve (docs/rules.md §6 → «Адреса серверов»): what a connect waits
// for (cache first, missing hosts of the starting servers ≤ ~1.5 s, all DNS servers at once, the rest in the
// background), and what a server that stopped answering does (serverDown: next cached address, a new lookup,
// one restart `reresolve` only when the IP set changed, once per host per 5 min, never offline / unsettled).
// A fake BoxRunner (no sing-box); the DoH server is a loopback mock.
import 'dart:async';
import 'dart:convert';
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

/// A throwaway tester box that is not sing-box: keeps its config and answers every check on the probe inbound (a
/// SOCKS5 server that says yes and then a 204), so the connect's checks run to their end.
class _ProbeBox implements BoxRunner {
  final configs = <Map<String, dynamic>>[];
  ServerSocket? _srv;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => _srv != null;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) {}

  @override
  Future<void> start(Map<String, dynamic> config) async {
    configs.add(config);
    final inbound = (config['inbounds'] as List).cast<Map>().firstWhere((i) => i['tag'] == probeInboundTag);
    final srv = _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, inbound['listen_port'] as int);
    srv.listen((s) {
      final buf = <int>[];
      var stage = 0;
      s.listen((d) {
        buf.addAll(d);
        while (true) {
          if (stage == 0 && buf.length >= 3) {
            buf.removeRange(0, 3);
            s.add([5, 2]);
          } else if (stage == 1 && buf.length > 2 && buf.length > 2 + buf[1] && buf.length >= 3 + buf[1] + buf[2 + buf[1]]) {
            buf.clear();
            s.add([1, 0]);
          } else if (stage == 2 && buf.length >= 5 && buf.length >= 7 + buf[4]) {
            buf.clear();
            s.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
          } else if (stage == 3 && String.fromCharCodes(buf).contains('\r\n\r\n')) {
            buf.clear();
            s.add('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.codeUnits);
            s.close();
            return;
          } else {
            return;
          }
          stage++;
        }
      }, onError: (_) {}, cancelOnError: true);
    });
  }

  @override
  Future<void> stop() async {
    final s = _srv;
    _srv = null;
    await s?.close();
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

  Future<void> boot({bool useFake = false, List<DnsCandidate> Function()? servers, Completer<void>? testerGate, BoxFactory? boxes}) async {
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
      boxFactory: boxes ?? (_) => _Runner(failStart: true, gate: testerGate),
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
      expect(await svc.connectPicks(multi, held: {'route0': 's::a'}), isEmpty);
      expect(checks(), isEmpty, reason: 'the core\'s chosen stands');
      expect(await svc.connectPicks(multi, held: const {}), isEmpty);
      expect(checks(), hasLength(1), reason: 'a group the core has no server for: the plan\'s chosen is only the app\'s hint, checked');
      final noChosen = {
        ...multi,
        'routes': [
          for (final r in multi['routes'] as List) {...(r as Map), 'main': {...(r['main'] as Map), 'chosen': null}},
        ],
      };
      expect(await svc.connectPicks(noChosen, held: {'route0': 's::a'}), isEmpty);
      expect(checks(), hasLength(2), reason: 'no chosen: checked (the tester cannot start here: the plan is used as it is)');
      expect(await svc.connectPicks(multi), isEmpty);
      expect(checks(), hasLength(3), reason: 'a fresh connect checks the group even with the app\'s chosen');
    });

    test('a plan change while running: the server the core has a group on is kept (a member, not pinned), else the plan\'s own chosen', () async {
      await boot(useFake: true);
      Map<String, dynamic> plan2({bool pinned = false, String chosen = 's::a'}) {
        final r = _route('A', {'s::a': 'a.example', 's::b': 'b.example', 's::c': 'c.example'});
        return {
          ...(_body([r])['plan'] as Map<String, dynamic>),
          'routes': [{...r, 'main': {...(r['main'] as Map), 'chosen': chosen, 'pinned': pinned}}],
        };
      }

      String? chosenOf(Map<String, dynamic> p) => ((p['routes'] as List).first['main'] as Map)['chosen'] as String?;
      List<String> checks() => [
            for (final l in svc.log(since: null)['lines'] as List)
              if ('${(l as Map)['msg']}'.contains('connect: the servers of route0')) '${l['msg']}',
          ];
      final kept = planKeepingServers(plan2(), {'route0': 's::b'});
      expect(chosenOf(kept), 's::b', reason: 'the core moved the group to b: the app\'s chosen a is only a hint');
      expect(await svc.connectPicks(kept, held: {'route0': 's::b'}), isEmpty);
      expect(checks(), isEmpty, reason: 'no check of the main group on a plan change');
      expect(chosenOf(planKeepingServers(plan2(pinned: true), {'route0': 's::b'})), 's::a', reason: 'a pinned group follows its pin');
      expect(chosenOf(planKeepingServers(plan2(), {'route0': 's::gone'})), 's::a', reason: 'not a member of the new plan: no choice');
      expect(chosenOf(planKeepingServers(plan2(), const {})), 's::a');
    });

    test('planWithChosen / planKeepingServers know the rule targets\' groups (t, t>entry); connectPicks checks a target with only the app\'s hint', () async {
      await boot(useFake: true);
      Map<String, dynamic> grp(List<String> keys, {String? chosen, bool pinned = false}) =>
          {'pick': 'priority', 'chosen': chosen, 'pinned': pinned, 'nodes': [for (final k in keys) _node(k, '$k.example')]};
      final plan = {
        ...(_body([_route('A', {'s::a': 'a.example'})])['plan'] as Map<String, dynamic>),
        'global': false,
        'routing': {
          'targets': {
            'src:x': {'kind': 'unit', 'main': grp(['x1', 'x2'], chosen: 'x1')},
            'chain:c': {'kind': 'chain', 'entry': grp(['e1', 'e2'], chosen: 'e1'), 'main': grp(['t1', 't2'], chosen: 't1', pinned: true)},
          },
        },
      };
      String? chosenOf(Map<String, dynamic> p, String t, [String field = 'main']) => (((p['routing'] as Map)['targets'] as Map)[t] as Map)[field]['chosen'] as String?;
      final moved = planWithChosen(plan, {'src:x': 'x2', 'chain:c>entry': 'e2', 'chain:c': 't2'});
      expect([chosenOf(moved, 'src:x'), chosenOf(moved, 'chain:c', 'entry'), chosenOf(moved, 'chain:c')], ['x2', 'e2', 't2']);
      expect([chosenOf(plan, 'src:x'), chosenOf(plan, 'chain:c')], ['x1', 't1'], reason: 'the plan itself is not changed');
      final kept = planKeepingServers(plan, {'src:x': 'x2', 'chain:c>entry': 'e2', 'chain:c': 't2'});
      expect([chosenOf(kept, 'src:x'), chosenOf(kept, 'chain:c', 'entry'), chosenOf(kept, 'chain:c')], ['x2', 'e2', 't1'], reason: 'a pinned group follows its pin');
      expect(chosenOf(planKeepingServers(plan, {'src:x': 'gone'}), 'src:x'), 'x1', reason: 'not a member: no choice');
      expect(planTargetGroups(plan).map((e) => e.$1), ['src:x', 'chain:c>entry', 'chain:c']);

      List<String> checks() => [
            for (final l in svc.log(since: null)['lines'] as List)
              if ('${(l as Map)['msg']}'.contains('connect: the servers of')) '${l['msg']}',
          ];
      // the core holds src:x on x2 (nothing to check there); the main route is one server; only the chain target's entry
      // (the app's hint e1, the core has none) is checked
      await svc.connectPicks(kept, held: {'src:x': 'x2'});
      expect(checks(), hasLength(1));
      expect(checks().single, contains('the rule targets'), reason: 'the tester cannot start here: the plan as it is; the log names the targets');
    });

    test('connectPicks: a tester that starts after the connect stopped waiting (a late chain target\'s exits) takes the address settings of the plan being started', () async {
      final boxes = <_ProbeBox>[];
      await boot(useFake: true, boxes: (_) {
        final b = _ProbeBox();
        boxes.add(b);
        return b;
      });
      svc.targetGrace = Duration.zero; // the target is always late
      // the entry host has an IPv6 address only: pinned when the plan being started has IPv6 on, else left as a name
      svc.addressBook.put('e1.example', AddressEntry(v4: const [], v6: const ['fd00::1'], at: time.t.millisecondsSinceEpoch, ttl: 300, via: 'seed'));
      Map<String, dynamic> grp(List<String> keys) => {'pick': 'priority', 'chosen': null, 'nodes': [for (final k in keys) _node(k, '$k.example')]};
      final plan = {
        ...(_body([_route('A', {'s::a': 'a.example'})])['plan'] as Map<String, dynamic>),
        'global': false,
        'ipv6': true,
        'urlTest': {'url': 'http://probe.test/'},
        'routing': {
          'targets': {
            'chain:c': {'kind': 'chain', 'entry': grp(['e1', 'e2']), 'main': grp(['t1', 't2'])},
          },
        },
      };
      expect(await svc.connectPicks(plan), isEmpty, reason: 'the connect did not wait for the target');
      List<String> log() => [for (final l in svc.log(since: null)['lines'] as List) '${(l as Map)['msg']}'];
      for (var i = 0; i < 100 && !log().any((l) => l.startsWith('connect: chain:c priority')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(log().where((l) => l.startsWith('connect: chain:c')), hasLength(2), reason: log().where((l) => l.contains('connect:')).join('\n'));
      final pairs = [for (final b in boxes) for (final c in b.configs) jsonEncode(c)].where((c) => c.contains('"p/'));
      expect(pairs, hasLength(1), reason: 'the exits are tested by pairs on a tester of their own');
      expect(pairs.single, contains('fd00::1'), reason: 'IPv6 of the plan being started, not of the saved settings read after it');
      expect(pairs.single, isNot(contains('"e1.example"')));
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
