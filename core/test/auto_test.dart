// AutoService against a fake sing-box API service (BoxControl, sbapi.dart). The fake is
// built from the real config (buildConfig), so the tags the service switches are the ones
// sing-box would get; it acts like sing-box: a delay test goes through a group to the
// server it uses now, a chain's exit through its entry group. Every group is a selector:
// the core picks the member (group_pick.dart) and selects it.
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

class FakeGroup {
  FakeGroup(this.type, this.all, this.now);
  final String type;
  final List<String> all;
  String? now;
}

class FakeBox implements BoxControl {
  FakeBox(Map<String, dynamic> config, this.alive) {
    for (final o in (config['outbounds'] as List).cast<Map>()) {
      final tag = o['tag'] as String;
      if (o['type'] == 'selector') {
        final all = (o['outbounds'] as List).cast<String>();
        groups[tag] = FakeGroup(o['type'] as String, all, o['default'] as String? ?? all.first);
      } else if (o['type'] != 'direct') {
        detours[tag] = o['detour'] as String?;
      }
    }
  }

  final Map<String, int> alive; // node key -> ms; missing or -1 = no answer
  final groups = <String, FakeGroup>{};
  final detours = <String, String?>{};
  final tested = <String>[]; // servers a delay test was asked for
  final conns = <LiveConnection>[]; // open connections, as api.connections would list them
  final closed = <String>[];
  void Function()? onConnections; // before each read of connections (traffic moves)
  final _changedCtl = StreamController<void>.broadcast();

  String _leaf(String tag) {
    for (var g = groups[tag]; g != null; g = groups[tag]) {
      tag = g.now ?? g.all.first;
    }
    return tag;
  }

  int _delayOf(String tag) {
    final leaf = _leaf(tag);
    final ms = alive[leaf.substring(leaf.indexOf('/') + 1)] ?? -1;
    final via = detours[leaf];
    if (ms < 0 || via == null) return ms;
    final d = _delayOf(via);
    return d < 0 ? -1 : ms + d;
  }

  /// The [DelayTest] AutoService is given in these tests: one server (or chain exit,
  /// through its entry) by its full outbound tag.
  Future<int> delayTest(String tag, String url, int timeoutMs) async {
    tested.add(tag);
    return _delayOf(tag);
  }

  @override
  Map<String, String> get selected => {
        for (final e in groups.entries)
          if (e.value.now != null) e.key: e.value.now!,
      };

  @override
  Stream<void> get groupsChanged => _changedCtl.stream;

  @override
  Future<bool> select(String group, String outbound) async {
    final g = groups[group];
    if (g == null || g.type != 'selector' || !g.all.contains(outbound)) return false;
    g.now = outbound;
    _changedCtl.add(null);
    return true;
  }

  @override
  Iterable<LiveConnection> get connections {
    onConnections?.call();
    return conns;
  }

  @override
  Future<bool> closeConnection(String id) async {
    closed.add(id);
    conns.removeWhere((c) => c.id == id);
    return true;
  }
}

LiveConnection _conn(String id, List<String> chain, {int up = 0, int down = 0}) =>
    LiveConnection(Connection(id: id, chainList: chain, uplinkTotal: Int64(up), downlinkTotal: Int64(down)));

Map<String, dynamic> _node(String key) => {
      'key': key,
      'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': key}, // the key in it: servers of one test are not one server (pool.dart identity)
    };

Map<String, dynamic> _grp(List<String> keys, {String pick = 'fastest', String? chosen, bool pinned = false}) =>
    {'pick': pick, 'chosen': chosen, 'pinned': pinned, 'nodes': [for (final k in keys) _node(k)]};

Map<String, dynamic> unit(String id, List<String> keys, {String pick = 'fastest', String? chosen, bool pinned = false}) =>
    {'id': id, 'kind': 'unit', 'main': _grp(keys, pick: pick, chosen: chosen, pinned: pinned)};

Map<String, dynamic> chain(String id, List<String> entry, List<String> exit) =>
    {'id': id, 'kind': 'chain', 'entry': _grp(entry), 'main': _grp(exit)};

Map<String, dynamic> plan(List<Map<String, dynamic>> routes, {int current = 0, Map<String, dynamic> auto = const {}}) => {
      'routes': routes,
      'current': current,
      // the flap guard has its own tests (it holds a return on the wall clock)
      'auto': {'failAfter': 2, 'threshold': 50, 'checkEvery': 60, 'standby': 2, 'warmEvery': 60, 'flapGuard': false, ...auto},
    };

/// A pool whose dead nodes are asked every round (a zero ladder): for the tests of failover, return and heal, which
/// re-test a dead route round after round on a clock that hardly moves. The ladder itself is in ladder_test.dart.
ProbePool everyRound() => ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero]));

(AutoService, FakeBox) setup(Map<String, dynamic> p, Map<String, int> alive) {
  final fake = FakeBox(buildConfig(p), alive);
  return (AutoService(fake, p, delay: fake.delayTest, pool: everyRound()), fake);
}

void main() {
  test('config: the routes under the selector proxy, starting on the current one', () {
    final c = buildConfig(plan([unit('A', ['s::a']), chain('X', ['s::e'], ['s::x'])], current: 1));
    final outs = {for (final o in (c['outbounds'] as List).cast<Map>()) o['tag']: o};
    expect(outs['proxy']?['outbounds'], ['route0', 'route1']);
    expect(outs['proxy']?['default'], 'route1');
    expect(outs['route1/s::x']?['detour'], 'route1-entry');
    expect(outs['route1-entry']?['outbounds'], ['route1-entry/s::e']);
    expect((c['route'] as Map)['final'], 'proxy');
    // the old one-route plan still works
    final old = buildConfig({'kind': 'unit', 'main': _grp(['s::a'])});
    expect({for (final o in (old['outbounds'] as List).cast<Map>()) o['tag']}, containsAll(['proxy', 'route0', 'route0/s::a']));
  });

  test('settings from the plan', () {
    final s = AutoSettings.fromPlan({
      'auto': {'failAfter': 3, 'threshold': 20, 'checkEvery': 5, 'standby': 20, 'warmEvery': 300},
      'urlTest': {'url': 'http://127.0.0.1/t'},
    });
    expect([s.failAfter, s.threshold, s.checkEvery, s.standby, s.warmEvery, s.url],
        [3, 20, const Duration(seconds: 10), 20, const Duration(minutes: 5), 'http://127.0.0.1/t']);
    final d = AutoSettings.fromPlan({});
    expect([d.failAfter, d.standby, d.warmEvery, d.retryPause, d.returnTo, d.flapGuard, d.flapMax, d.flapReset],
        [2, 2, const Duration(minutes: 1), const Duration(milliseconds: 500), ReturnTo.always, true, const Duration(minutes: 30), const Duration(minutes: 15)],
        reason: 'an older plan: return always, guard on');
    final o = AutoSettings.fromPlan({'auto': {'retryPause': 2.5, 'returnTo': 'faster', 'flapGuard': false, 'flapMax': 90, 'flapReset': 1}});
    expect([o.retryPause, o.returnTo, o.flapGuard, o.flapMax, o.flapReset],
        [const Duration(milliseconds: 2500), ReturnTo.faster, false, const Duration(minutes: 60), const Duration(minutes: 5)]);
    expect([AutoSettings.fromPlan({'auto': {'retryPause': 0.01}}).retryPause, AutoSettings.fromPlan({'auto': {'retryPause': 60}}).retryPause],
        [const Duration(milliseconds: 100), const Duration(seconds: 10)]);
    expect(AutoSettings.fromPlan({'auto': {'returnTo': 'never'}}).returnTo, ReturnTo.never);
    final big = AutoSettings.fromPlan({'auto': {'failAfter': 9, 'standby': 50}});
    expect([big.failAfter, big.standby], [5, 20]);
    expect(AutoSettings.fromPlan({'auto': {'keepWarm': false, 'standby': 3}}).standby, 0, reason: 'an older plan');
    expect([for (final r in [null, 'off', '3', 'all', 'x']) AutoSettings.fromPlan({'auto': {'siteRetry': ?r}}).siteAlternates],
        [3, 0, 3, AutoSettings.allSiteAlternates, 3]);
  });

  test('Fastest: leaves a silent server only after failAfter misses, for the fastest answering one; no route switch', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2', 's::a3']), unit('B', ['s::b1'])]), {'s::a1': 40, 's::a2': 80, 's::a3': 60, 's::b1': 30});
    await auto.check();
    expect(auto.toJson()['server'], 's::a1');
    fake.alive.remove('s::a1');
    await auto.check();
    expect(auto.toJson()['server'], 's::a1', reason: 'one miss is not enough with failAfter 2');
    await auto.check();
    final j = auto.toJson();
    expect([j['now'], j['server'], j['switches'], j['noNet']], ['A', 's::a3', 1, false], reason: 'the fastest of the answering ones');
    expect((j['lastSwitch'] as Map)['reason'], 'fastest');
    expect(fake.groups['route0']!.now, 'route0/s::a3');
  });

  test('Fastest: a faster server is moved to only by more than the threshold, and a weak answer is never faster', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2'])], auto: {'checkEvery': 10}), {'s::a1': 100, 's::a2': 70});
    await auto.check();
    expect(auto.toJson()['server'], 's::a1', reason: '70 + 50 > 100: not enough');
    fake.alive['s::a2'] = 40;
    await auto.check();
    expect(auto.toJson()['server'], 's::a1', reason: 'looked at once per checkEvery');
  });

  group('Fastest: improvement step and weak answers', () {
    const url = 'https://test.example/', checker = 'https://checker.example/';

    // [weak]: the servers the test URL misses through while the backup checker answers (a weak answer)
    (AutoService, FakeBox, void Function(int)) rig(Map<String, dynamic> p, Map<String, int> alive, {Set<String> weak = const {}}) {
      final fake = FakeBox(buildConfig(p), alive);
      var now = 1000000;
      Future<int> delay(String tag, String u, int t) async {
        final ms = await fake.delayTest(tag, u, t);
        return u == url && weak.any((k) => tag.endsWith('/$k')) ? -1 : ms;
      }

      final auto = AutoService(fake, p,
          delay: delay, clock: () => now, settings: const AutoSettings(url: url, checkers: [checker], checkEvery: Duration(seconds: 60), threshold: 50, failAfter: 2));
      return (auto, fake, (s) => now += s * 1000);
    }

    test('a move only on ms + threshold <= the current one\'s ms, only in the route in use', () async {
      final p = plan([unit('A', ['s::a1', 's::a2']), unit('B', ['s::b1', 's::b2'])]);
      final (auto, fake, _) = rig(p, {'s::a1': 100, 's::a2': 51, 's::b1': 300, 's::b2': 10});
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a1', reason: '51 + 50 > 100');
      expect(fake.groups['route1']!.now, 'route1/s::b1', reason: 'a route not in use is not improved, however much faster');
      final (auto2, fake2, _) = rig(p, {'s::a1': 100, 's::a2': 50, 's::b1': 300, 's::b2': 10});
      await auto2.check();
      expect(fake2.groups['route0']!.now, 'route0/s::a2', reason: '50 + 50 <= 100');
      expect(fake2.groups['route1']!.now, 'route1/s::b1');
    });

    test('looked at once per checkEvery; a network change looks out of turn', () async {
      final p = plan([unit('A', ['s::a1', 's::a2'])]);
      final (auto, fake, advance) = rig(p, {'s::a1': 100, 's::a2': 90});
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a1');
      fake.alive['s::a2'] = 10;
      advance(5);
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a1', reason: '5 s after the last look: not yet');
      advance(60);
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a2', reason: 'a checkEvery later');
      fake.alive.addAll({'s::a2': 100, 's::a1': 10});
      advance(5);
      auto.networkChanged();
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a1', reason: 'the network moved: the look is out of turn');
    });

    test('a weak answer is never faster than a strong server in use', () async {
      final p = plan([unit('A', ['s::a1', 's::a2'])]);
      final (auto, fake, _) = rig(p, {'s::a1': 200, 's::a2': 10}, weak: {'s::a2'});
      await auto.check();
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a1');
      expect(auto.toJson()['switches'], 0);
    });

    test('a dead current server goes to a strong one before a weak one; to a weak one only when nothing else answers', () async {
      final p = plan([unit('A', ['s::a1', 's::a2', 's::a3'])]);
      final (auto, fake, _) = rig(p, {'s::a1': 20, 's::a2': 20, 's::a3': 150}, weak: {'s::a2'});
      await auto.check();
      fake.alive.remove('s::a1');
      await auto.check();
      await auto.check();
      expect(fake.groups['route0']!.now, 'route0/s::a3', reason: 'a3 is slower, but a2 only passed by the checker');
      final (auto2, fake2, _) = rig(p, {'s::a1': 20, 's::a2': 20}, weak: {'s::a2'});
      await auto2.check();
      fake2.alive.remove('s::a1');
      await auto2.check();
      await auto2.check();
      expect(fake2.groups['route0']!.now, 'route0/s::a2', reason: 'nothing else answers: the weak one beats a dead one');
    });
  });

  test('refresh(): a move seen in the groups stream is not a switch (only a pick of the core is)', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2'])]), {'s::a1': 40, 's::a2': 80});
    await auto.check();
    final events = <AutoSwitch>[];
    auto.switches.listen(events.add);
    fake.groups['route0']!.now = 'route0/s::a2';
    expect(await auto.refresh(), isTrue);
    expect(auto.toJson()['server'], 's::a2');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test('refresh(): the first read puts the groups and the route selector back on the plan\'s start (sing-box\'s cache_file may restore older picks)', () async {
    final p = plan([unit('A', ['s::a1', 's::a2', 's::a3'], chosen: 's::a2'), unit('B', ['s::b1'])], current: 0);
    final (auto, fake) = setup(p, {'s::a1': 40, 's::a2': 80, 's::a3': 60, 's::b1': 30});
    final notes = <String>[];
    final a = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), note: notes.add);
    expect(fake.groups['route0']!.now, 'route0/s::a2');
    fake.groups['route0']!.now = 'route0/s::a1'; // restored by cache_file
    fake.groups['proxy']!.now = 'route1';
    expect(await a.refresh(), isTrue);
    expect([fake.groups['route0']!.now, fake.groups['proxy']!.now], ['route0/s::a2', 'route0']);
    expect(a.toJson()['server'], 's::a2');
    expect(notes.where((n) => n.contains('restored')), hasLength(2));
    fake.groups['route0']!.now = 'route0/s::a3'; // a later move is the core's own business: not undone
    await a.refresh();
    expect(fake.groups['route0']!.now, 'route0/s::a3');
    expect(auto.index, 0);
  });

  test('refresh() on an adopted sing-box (reconcileStart off): what runs is the truth, a heal of the previous core stays', () async {
    final p = plan([unit('A', ['s::a1', 's::a2', 's::a3'], chosen: 's::a2'), unit('B', ['s::b1'])], current: 0);
    final (_, fake) = setup(p, {'s::a1': 40, 's::a2': 80, 's::a3': 60, 's::b1': 30});
    final notes = <String>[];
    final a = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), note: notes.add)..reconcileStart = false;
    fake.groups['route0']!.now = 'route0/s::a3'; // the previous core healed the group (the record still says a2)
    fake.groups['proxy']!.now = 'route1'; // and moved the route
    expect(await a.refresh(), isTrue);
    expect([fake.groups['route0']!.now, fake.groups['proxy']!.now], ['route0/s::a3', 'route1'], reason: 'nothing put back');
    expect(notes.where((n) => n.contains('restored')), isEmpty);
    expect(a.index, 1, reason: 'the route in use is the running one');
    expect(a.groupServers()['route0'], 's::a3');
  });

  test('refresh(): a pinned group (Manual on a server) is put back on its pin whatever moved it, an adopted sing-box and later reads included', () async {
    final p = plan([unit('A', ['s::a1', 's::a2', 's::a3'], pick: 'priority', chosen: 's::a2', pinned: true)], current: 0);
    for (final adopted in [false, true]) {
      final fake = FakeBox(buildConfig(p), {'s::a1': 40, 's::a2': 80, 's::a3': 60});
      final notes = <String>[];
      final a = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), note: notes.add)..reconcileStart = !adopted;
      fake.groups['route0']!.now = 'route0/s::a1'; // restored by cache_file / left there by the previous core
      expect(await a.refresh(), isTrue, reason: 'adopted: $adopted');
      expect(fake.groups['route0']!.now, 'route0/s::a2', reason: 'adopted: $adopted');
      expect(a.groupServers()['route0'], 's::a2');
      expect(notes.where((n) => n.contains('route0') && n.contains('route0/s::a2')), hasLength(1), reason: 'one line, naming the pin');
      fake.groups['route0']!.now = 'route0/s::a3'; // a later stray select: put back too, the core never moves a pin
      await a.refresh();
      expect(fake.groups['route0']!.now, 'route0/s::a2', reason: 'adopted: $adopted');
      expect(a.groupServers()['route0'], 's::a2');
    }
  });

  test('refresh(): false before sing-box first answers (selected empty)', () async {
    final auto = AutoService(_Dead(), plan([unit('A', ['s::a'])]), delay: (tag, url, t) async => -1);
    expect(await auto.refresh(), isFalse);
  });

  test('failover after failAfter misses to the first answering route by priority, back when the top answers again', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b']), unit('C', ['s::c'])]), {'s::a': 40, 's::b': 60, 's::c': 30});
    final events = <AutoSwitch>[];
    auto.switches.listen(events.add);
    await auto.check();
    fake.alive.remove('s::a');
    await auto.check();
    expect(auto.toJson()['now'], 'A', reason: 'one miss is not enough with failAfter 2');
    await auto.check();
    expect(auto.toJson()['now'], 'B', reason: 'B is first by priority, C faster but lower');
    expect(fake.groups['proxy']!.now, 'route1');
    fake.alive['s::a'] = 100; // slower than B, but within B + threshold
    await auto.check();
    expect(auto.toJson()['now'], 'B', reason: 'back only after failAfter answers in a row');
    await auto.check();
    final j = auto.toJson();
    expect([j['now'], j['switches'], (j['lastSwitch'] as Map)['reason']], ['A', 2, 'back']);
    await Future<void>.delayed(Duration.zero);
    expect([for (final e in events) '${e.from}>${e.to} ${e.reason}'], ['A>B failover', 'B>A back']);
    expect(events.every((e) => e.isRoute), isTrue);
  });

  test('back up is held while the higher route is slower than the current by more than threshold', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b'])]), {'s::b': 60});
    fake.alive['s::a'] = -1;
    await auto.check();
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    fake.alive['s::a'] = 200; // 200 > 60 + 50
    for (var i = 0; i < 3; i++) {
      await auto.check();
    }
    expect(auto.toJson()['now'], 'B');
    fake.alive.remove('s::b'); // the current one dies: failover goes to the top first
    await auto.check();
    await auto.check();
    expect(auto.toJson()['now'], 'A');
  });

  test('every route silent: no network — stays, marks no one', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b'])]), {});
    await auto.check();
    await auto.check();
    final j = auto.toJson();
    expect([j['now'], j['noNet'], j['switches'], fake.groups['proxy']!.now], ['A', true, 0, 'route0']);
    final b = (j['routes'] as List).cast<Map>()[1];
    expect([b['ms'], b['fails']], [-2, 0], reason: 'the misses of a round nobody answered are put back');
    expect((j['routes'] as List).cast<Map>()[0]['fails'], 2, reason: 'the current one keeps counting');
  });

  test('Priority: leaves its server after failAfter misses for the first answering one in order, comes back', () async {
    final (auto, fake) = setup(plan([unit('P', ['s::p1', 's::p2', 's::p3'], pick: 'priority', chosen: 's::p1')]), {'s::p1': 50, 's::p2': 90, 's::p3': 20});
    final events = <AutoSwitch>[];
    auto.switches.listen(events.add);
    await auto.check();
    fake.alive.remove('s::p1');
    await auto.check();
    expect(auto.toJson()['server'], 's::p1');
    await auto.check();
    expect(auto.toJson()['server'], 's::p2', reason: 'the next in order, not the fastest');
    expect(fake.groups['route0']!.now, 'route0/s::p2');
    expect(auto.toJson()['noNet'], isFalse);
    fake.alive['s::p1'] = 60;
    await auto.check();
    await auto.check();
    expect(auto.toJson()['server'], 's::p1');
    await Future<void>.delayed(Duration.zero);
    expect([for (final e in events) '${e.route}: ${e.from}>${e.to} ${e.reason}'], ['P: s::p1>s::p2 failover', 'P: s::p2>s::p1 back']);
  });

  test('a pinned server (Manual) is never moved', () async {
    final (auto, fake) = setup(plan([unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p1', pinned: true)]), {'s::p2': 10});
    for (var i = 0; i < 3; i++) {
      await auto.check();
    }
    expect([auto.toJson()['server'], auto.toJson()['noNet']], ['s::p1', true]);
    expect(fake.tested.where((t) => t.contains('p2')), isEmpty);
  });

  test('no spares: the routes below are tested only when the current one fails, as one batch', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b']), unit('C', ['s::c'])], auto: {'standby': 0}),
        {'s::a': 40, 's::b': 60, 's::c': 30});
    await auto.check();
    expect(fake.tested, ['route0/s::a']);
    fake.alive.remove('s::a');
    await auto.check();
    await auto.check();
    expect(auto.toJson()['now'], 'B', reason: 'B and C tested together, B first by priority');
    expect(fake.tested, contains('route2/s::c'));
    fake.tested.clear();
    await auto.check();
    expect(fake.tested, containsAll(['route0/s::a', 'route1/s::b']), reason: 'the route above is tested to come back');
    expect(fake.tested.where((t) => t.contains('s::c')), isEmpty);
  });

  test('spares: the standby routes are tested with the current one', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b']), unit('C', ['s::c']), unit('D', ['s::d'])], auto: {'standby': 2}),
        {'s::a': 40, 's::b': 60, 's::c': 30, 's::d': 30});
    await auto.check();
    expect(fake.tested.toSet(), {'route0/s::a', 'route1/s::b', 'route2/s::c'});
  });

  test('spares: tested every warmEvery, the current route every check', () async {
    var t = 0;
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'standby': 1, 'warmEvery': 120});
    final fake = FakeBox(buildConfig(p), {'s::a': 40, 's::b': 60});
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t);
    final spares = <int>[];
    for (var i = 0; i < 5; i++) {
      t = i * 60000 + (i == 2 ? -500 : 0); // a check a little early still counts
      fake.tested.clear();
      await auto.check();
      expect(fake.tested, contains('route0/s::a'));
      if (fake.tested.contains('route1/s::b')) spares.add(i);
    }
    expect(spares, [0, 2, 4]);
  });

  test('a server move inside a spare route is a log note, not a switch; moves of the route in use and between routes are', () async {
    var t = 0;
    final p = plan([unit('A', ['s::a1', 's::a2'], pick: 'priority', chosen: 's::a1'), unit('B', ['s::b1', 's::b2'], pick: 'priority', chosen: 's::b1')],
        auto: {'standby': 1, 'warmEvery': 10});
    final fake = FakeBox(buildConfig(p), {'s::a1': 40, 's::a2': 50, 's::b1': 60, 's::b2': 70});
    final notes = <String>[];
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, note: notes.add);
    final events = <AutoSwitch>[];
    auto.switches.listen(events.add);
    Future<void> check() async {
      t += 60000;
      await auto.check();
    }

    await check();
    fake.alive.remove('s::b1'); // the spare route's own server dies
    await check();
    await check();
    expect(fake.groups['route1']!.now, 'route1/s::b2');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: 'B carries no traffic: housekeeping');
    expect(notes, contains('auto: standby B: server s::b1 → s::b2 (failover)'));
    expect([auto.toJson()['now'], auto.toJson()['switches']], ['A', 0]);

    fake.alive['s::b1'] = 60; // and comes back
    await check();
    await check();
    expect(fake.groups['route1']!.now, 'route1/s::b1');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(notes, contains('auto: standby B: server s::b2 → s::b1 (back)'));

    fake.alive.remove('s::a1'); // the route in use moves its server: a switch
    await check();
    await check();
    await Future<void>.delayed(Duration.zero);
    expect([for (final e in events) '${e.route}: ${e.from}>${e.to} ${e.reason}'], ['A: s::a1>s::a2 failover']);

    fake.alive.remove('s::a2'); // the whole route dies: a switch to B is reported as always
    await check();
    await check();
    await Future<void>.delayed(Duration.zero);
    expect(auto.toJson()['now'], 'B');
    expect(events.last.isRoute, isTrue);
    expect([events.last.from, events.last.to, events.last.reason], ['A', 'B', 'failover']);
  });

  test('Priority started below a server that never missed: the move up is `preferred`, silent in the first rounds, an event later', () async {
    final p = plan([unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p2')], auto: {'returnTo': 'faster'});
    final pAlways = plan([unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p2')]);

    // started on p2 while p1 answers: the first rounds put it on p1 with a log note only
    final notes = <String>[];
    final box = FakeBox(buildConfig(pAlways), {'s::p1': 40, 's::p2': 60});
    final a1 = AutoService(box, pAlways, delay: box.delayTest, note: notes.add);
    final events = <AutoSwitch>[];
    a1.switches.listen(events.add);
    expect(a1.toJson()['server'], 's::p2');
    await a1.check();
    await a1.check();
    await Future<void>.delayed(Duration.zero);
    expect(a1.toJson()['server'], 's::p1');
    expect(events, isEmpty, reason: 'not news right after the connect');
    expect(notes, contains('auto: P: server s::p2 → s::p1 (preferred, right after the connect)'));

    // later in the session the same move is an event, reason preferred (p1 never missed)
    final box2 = FakeBox(buildConfig(p), {'s::p1': 200, 's::p2': 60});
    final a2 = AutoService(box2, p, delay: box2.delayTest, note: notes.add);
    final ev2 = <AutoSwitch>[];
    a2.switches.listen(ev2.add);
    for (var i = 0; i < 4; i++) {
      await a2.check();
    }
    expect(a2.toJson()['server'], 's::p2', reason: 'p1 is slower than p2 + threshold: held');
    box2.alive['s::p1'] = 10;
    await a2.check();
    await a2.check();
    await Future<void>.delayed(Duration.zero);
    expect(a2.toJson()['server'], 's::p1');
    expect([for (final e in ev2) '${e.route}: ${e.from}>${e.to} ${e.reason}'], ['P: s::p2>s::p1 preferred']);
  });

  test('a start below a route that answers: back up after failAfter answers', () async {
    final (auto, _) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b'])], current: 1), {'s::a': 40, 's::b': 60});
    expect(auto.toJson()['now'], 'B');
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    await auto.check();
    expect(auto.toJson()['now'], 'A');
  });

  test('chain: the entry heals first, the exit is measured through it; exits stay out of members', () async {
    final (auto, fake) = setup(plan([chain('X', ['s::e1', 's::e2'], ['s::x'])]), {'s::e1': 20, 's::e2': 30, 's::x': 40});
    await auto.check();
    var j = auto.toJson();
    expect([j['server'], j['entryServer'], (j['routes'] as List).first['ms']], ['s::x', 's::e1', 60]);
    fake.alive.remove('s::e1');
    await auto.check();
    expect(auto.toJson()['entryServer'], 's::e1', reason: 'one miss is not enough with failAfter 2');
    await auto.check();
    j = auto.toJson();
    expect([j['entryServer'], (j['routes'] as List).first['fails'], (j['routes'] as List).first['ms']], ['s::e2', 0, 70]);
    final keys = [for (final m in (j['members'] as List).cast<Map>()) m['key']];
    expect(keys, containsAll(['s::e1', 's::e2']));
    expect(keys, isNot(contains('s::x')));
    final e1 = (j['members'] as List).cast<Map>().firstWhere((m) => m['key'] == 's::e1');
    expect([e1['ms'], e1['fails']], [-1, 2], reason: 'the two misses that moved the entry');
  });

  test('chain: a result of an exit belongs to its pair; the entry switching starts a count of its own; status.auto.pairs', () async {
    final (auto, fake) = setup(plan([chain('X', ['s::e1', 's::e2'], ['s::x'])]), {'s::e1': 20, 's::e2': 30, 's::x': 40});
    await auto.check();
    List<Map> pairs() => (auto.toJson()['pairs'] as List).cast<Map>();
    Map pair(String e) => pairs().firstWhere((p) => p['entry'] == e && p['key'] == 's::x');
    expect([pair('s::e1')['ms'], pair('s::e1')['fails']], [60, 0]);
    // the exit goes silent through e1: the misses are the pair e1 > x's
    fake.alive.remove('s::x');
    await auto.check();
    expect(pair('s::e1')['fails'], greaterThan(0));
    final missed = pair('s::e1')['fails'];
    // the entry e1 dies: Auto moves the entry to e2; the exit through e2 counts from zero
    fake.alive.remove('s::e1');
    fake.alive['s::x'] = 40;
    await auto.check();
    await auto.check(); // failAfter 2: the second miss of the entry moves it
    expect(auto.toJson()['entryServer'], 's::e2');
    expect([pair('s::e2')['ms'], pair('s::e2')['fails']], [70, 0]);
    expect(pair('s::e1')['fails'], missed, reason: 'the old pair keeps its own count');
  });

  test('sing-box not answering: the check judges nothing', () async {
    final auto = AutoService(_Dead(), plan([unit('A', ['s::a']), unit('B', ['s::b'])]), delay: (tag, url, t) async => -1);
    await auto.check();
    await auto.check();
    expect([auto.toJson()['now'], auto.toJson()['noNet'], (auto.toJson()['routes'] as List).first['fails']], ['A', false, 0]);
  });

  test('config: the groups Auto switches keep open connections', () {
    final c = buildConfig(plan([unit('A', ['s::a']), unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p1'), chain('X', ['s::e'], ['s::x'])]));
    final outs = {for (final o in (c['outbounds'] as List).cast<Map>()) o['tag']: o};
    for (final t in ['proxy', 'route0', 'route1', 'route2', 'route2-entry']) {
      expect(outs[t]?['interrupt_exist_connections'], isFalse, reason: t);
    }
  });

  test('retry pause: after a miss the current one is tested again that soon, not at checkEvery', () async {
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
    final fake = FakeBox(buildConfig(p), {'s::b': 30});
    final auto = AutoService(fake, p,
        delay: fake.delayTest,
        settings: const AutoSettings(checkEvery: Duration(hours: 1), firstCheck: Duration(milliseconds: 1), retryPause: Duration(milliseconds: 20)));
    auto.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    auto.stop();
    expect(auto.toJson()['now'], 'B');
    expect(fake.tested.where((t) => t == 'route0/s::a').length, 2, reason: 'failAfter 2: the first round and one retry');
  });

  test('failover: batches of 10 by priority, scanning every remaining route until one answers', () async {
    final routes = [for (var i = 0; i < 13; i++) unit('R$i', ['s::r$i'])];
    final p = plan(routes, auto: {'standby': 0, 'flapGuard': true});
    var t = 0;
    // only R12 (second batch) still answers: the failover must not stop at the first batch
    final fake = FakeBox(buildConfig(p), {'s::r0': 30, 's::r12': 30});
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t);
    await auto.check();
    fake.alive.remove('s::r0');
    await auto.check(); // one miss: failAfter is 2, still on R0
    await auto.check();
    var j = auto.toJson();
    expect([j['now'], j['noNet'], j['switches']], ['R12', false, 1]);
    expect(fake.tested.any((x) => x.contains('r12')), isTrue, reason: 'the second batch (R11…R12) was tried too');
    expect((j['routes'] as List).cast<Map>().first['strikes'], 1, reason: 'R0 dropped while another route answered');
  });

  test('failover: nothing answers at all = no network, nobody struck; once noNet only the first batch of the rest is retried', () async {
    final routes = [for (var i = 0; i < 13; i++) unit('R$i', ['s::r$i'])];
    final p = plan(routes, auto: {'standby': 0, 'flapGuard': true});
    var t = 0;
    final fake = FakeBox(buildConfig(p), {'s::r0': 30});
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t);
    final net = <AutoNet>[];
    auto.net.listen(net.add);
    await auto.check();
    fake.alive.remove('s::r0');
    await auto.check(); // one miss: failAfter is 2, no failover attempt yet
    await auto.check();
    var j = auto.toJson();
    expect([j['now'], j['noNet'], j['switches'], fake.groups['proxy']!.now], ['R0', true, 0, 'route0']);
    expect(fake.tested.any((x) => x.contains('r12')), isTrue, reason: 'the first noNet round still scans every route once');
    expect((j['routes'] as List).cast<Map>().skip(1).every((r) => r['fails'] == 0 && r['strikes'] == 0), isTrue);
    expect((j['routes'] as List).cast<Map>().first['strikes'], 0, reason: 'no network: the current one is not struck either');

    fake.tested.clear();
    t += 10000;
    await auto.check();
    j = auto.toJson();
    expect([j['now'], j['noNet']], ['R0', true]);
    expect(fake.tested.where((x) => x.contains('r11') || x.contains('r12')), isEmpty,
        reason: 'already noNet: only the first batch (R1…R10) is retried this round');

    // the network is back, R0 is still dead: R7 and R3 answer — R3 is first by priority
    fake.alive['s::r7'] = 10;
    fake.alive['s::r3'] = 90;
    t += 10000;
    await auto.check();
    j = auto.toJson();
    expect([j['now'], j['noNet']], ['R3', false]);
    expect((j['routes'] as List).cast<Map>().first['strikes'], 1, reason: 'R0 dropped while another route answered');
    await Future<void>.delayed(Duration.zero);
    expect([for (final n in net) n.kind], ['lost', 'restored'], reason: 'the lost network is told once, however many rounds it lasted');
    expect(net.last.downMs, 20000);
  });

  test('«no network» outlives the service: a reconnect while offline tells no second lost; only an answer ends it (restored once, for the first)', () async {
    final p = plan([unit('A', ['s::a'])], auto: {'standby': 0});
    var t = 0;
    final mem = AutoMemory();
    final fake = FakeBox(buildConfig(p), {'s::a': -1});
    final first = AutoService(fake, p, delay: fake.delayTest, clock: () => t, memory: mem);
    final net1 = <AutoNet>[];
    first.net.listen(net1.add);
    await first.check();
    await first.check();
    await Future<void>.delayed(Duration.zero);
    expect([first.noNet, [for (final n in net1) n.kind]], [true, ['lost']]);
    first.stop();

    t += 5000;
    final second = AutoService(fake, p, delay: fake.delayTest, clock: () => t, memory: mem);
    final net2 = <AutoNet>[];
    second.net.listen(net2.add);
    expect(second.noNet, isTrue, reason: 'a new service does not presume the network back: nothing answered yet');
    await second.check();
    await Future<void>.delayed(Duration.zero);
    expect([second.noNet, net2], [true, isEmpty], reason: 'still the same outage: no second lost');

    mem.netUnknown(); // another network: unknown, not «no network», not online
    expect(second.noNet, isFalse);
    expect(mem.lostAt, isNotNull, reason: 'the event written for the outage is still owed its end');

    fake.alive['s::a'] = 20;
    t += 5000;
    await second.check();
    await Future<void>.delayed(Duration.zero);
    expect([second.noNet, [for (final n in net2) n.kind], net2.single.downMs], [false, ['restored'], 10000]);
  });

  test('flap guard: a strike only when another route answered; the hold doubles up to flapMax, stable work forgets it', () async {
    var t = 0;
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'flapGuard': true, 'flapMax': 3, 'flapReset': 5, 'failAfter': 1});
    final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t);
    final unstable = <AutoUnstable>[];
    auto.unstable.listen(unstable.add);
    Map route(String id) => (auto.toJson()['routes'] as List).cast<Map>().firstWhere((r) => r['id'] == id);
    Future<void> at(int minutes) async {
      t = minutes * 60000;
      await auto.check();
    }

    await at(0);
    // no network: A and B both silent — nobody struck
    fake.alive.clear();
    await at(1);
    expect([auto.toJson()['now'], auto.toJson()['noNet'], route('A')['strikes']], ['A', true, 0]);
    // B back, A not: a drop of A (strike 1, hold 1 min)
    fake.alive['s::b'] = 60;
    await at(2);
    expect([auto.toJson()['now'], route('A')['strikes']], ['B', 1]);
    fake.alive['s::a'] = 30;
    await at(3); // answers from 3:00
    expect(auto.toJson()['now'], 'B', reason: 'on hold: 1 min of answers first');
    expect(route('A')['holdUntil'], 4 * 60000);
    await at(4);
    expect(auto.toJson()['now'], 'A');
    // drops again: strike 2 (2 min), then 3 (min(4, flapMax 3) = 3 min)
    Future<void> drop(int m) async {
      fake.alive.remove('s::a');
      await at(m);
      expect(auto.toJson()['now'], 'B');
      fake.alive['s::a'] = 30;
    }

    await drop(5);
    expect(route('A')['strikes'], 2);
    await at(6);
    await at(7);
    expect(auto.toJson()['now'], 'B', reason: 'hold 2 min: answers since 6:00');
    await at(8);
    expect(auto.toJson()['now'], 'A');
    await drop(9);
    expect(route('A')['strikes'], 3);
    await at(10);
    expect(route('A')['holdUntil'], 13 * 60000, reason: 'capped at flapMax');
    await at(12);
    expect(auto.toJson()['now'], 'B');
    await at(13);
    expect(auto.toJson()['now'], 'A');
    await Future<void>.delayed(Duration.zero);
    expect([for (final u in unstable) '${u.id} ${u.strikes} ${u.holdMs ~/ 60000}'], ['A 2 2', 'A 3 3']);
    expect(auto.toJson()['unstable'], 2);
    // 5 min of stable work on A forgets the strikes
    await at(17);
    expect(route('A')['strikes'], 3);
    await at(18);
    expect(route('A')['strikes'], 0);
  });

  test('flap guard off: back as soon as the return rule allows', () async {
    var t = 0;
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'failAfter': 1});
    final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t);
    await auto.check();
    fake.alive.remove('s::a');
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    fake.alive['s::a'] = 30;
    t += 60000; // the dead A is asked again after its first step of the ladder (1 min)
    await auto.check();
    expect(auto.toJson()['now'], 'A');
  });

  test('return modes: faster — only when faster by threshold; never — stays until a reconnect', () async {
    Future<String> run(String mode, int aBack) async {
      final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'returnTo': mode, 'failAfter': 1}), {'s::a': 30, 's::b': 100});
      await auto.check();
      fake.alive.remove('s::a');
      await auto.check();
      expect(auto.toJson()['now'], 'B');
      fake.alive['s::a'] = aBack;
      await auto.check();
      await auto.check();
      return auto.toJson()['now'] as String;
    }

    expect(await run('always', 120), 'A', reason: 'within B + threshold');
    expect(await run('faster', 120), 'B', reason: 'slower than B');
    expect(await run('faster', 60), 'B', reason: 'faster, but by less than threshold (50)');
    expect(await run('faster', 40), 'A');
    expect(await run('never', 10), 'B');
  });

  test('return never: Priority servers stay too, and routes above are not tested', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a']), unit('P', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p2')],
        current: 1, auto: {'returnTo': 'never'}), {'s::a': 10, 's::p1': 10, 's::p2': 40});
    await auto.check();
    await auto.check();
    expect([auto.toJson()['now'], auto.toJson()['server']], ['P', 's::p2']);
    expect(fake.tested.where((x) => x.contains('s::a') || x.contains('s::p1')), isEmpty);
  });

  test('after a failover only the stalled connections of the dead route are closed', () async {
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
    final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p,
        delay: fake.delayTest, settings: const AutoSettings(failAfter: 1, flapGuard: false, stallAfter: Duration(milliseconds: 30)));
    fake.conns.addAll([
      _conn('moving', ['route0/s::a', 'route0', 'proxy'], up: 10, down: 100),
      _conn('stuck', ['route0/s::a', 'route0', 'proxy'], up: 10, down: 100),
      _conn('other', ['direct']),
    ]);
    fake.onConnections = () => fake.conns.firstWhere((c) => c.id == 'moving').down += 1;
    await auto.check();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fake.closed, isEmpty, reason: 'no switch: nothing is closed');
    fake.alive.remove('s::a');
    // the "moving" connection stands in for what an old route still moves; a failed request is what makes the route
    // not proven alive by it (live traffic would skip the test)
    auto.onClosed(const ClosedConnection(outbound: 'route0/s::a', chain: ['route0/s::a', 'route0', 'proxy'], destination: 'x.example:443', up: 5, down: 0));
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    expect(fake.closed, isEmpty, reason: 'not at the switch: after stallAfter');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.closed, ['stuck']);
    expect([for (final c in fake.conns) c.id], ['moving', 'other']);
    expect(auto.toJson()['stalledClosed'], 1);
    auto.stop();
  });

  test('a route whose test URL fails but a checker answers is alive (withCheckers via the delay fake)', () async {
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
    final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
    // keyed by url, not by tag: the test url always misses, only the checker answers
    Future<int> delay(String tag, String url, int t) async => url == 'https://checker.example/' ? 20 : -1;
    final auto = AutoService(fake, p,
        delay: delay, settings: const AutoSettings(url: 'https://dead.example/', checkers: ['https://checker.example/']));
    await auto.check();
    final j = auto.toJson();
    expect([j['now'], j['noNet']], ['A', false], reason: 'the checker answering keeps A alive despite the test url failing');
  });

  test('no checkers configured: the test url failing is the final answer (no network)', () async {
    final p = plan([unit('A', ['s::a'])]);
    final fake = FakeBox(buildConfig(p), {'s::a': 30});
    Future<int> delay(String tag, String url, int t) async => -1;
    final auto = AutoService(fake, p, delay: delay, settings: const AutoSettings(url: 'https://dead.example/', checkers: []));
    await auto.check();
    await auto.check();
    final j = auto.toJson();
    expect(j['noNet'], isTrue);
  });

  group('onLog: offline on "missing default interface"', () {
    test('offline suppresses a check round; recovery runs one at once', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      await auto.check();
      fake.alive.remove('s::a'); // would normally start failing A over

      final net = <AutoNet>[];
      auto.net.listen(net.add);
      auto.onLog('some sing-box line, missing default interface, no network');
      auto.onLog('missing default interface again');
      expect(auto.offline, isTrue);
      fake.tested.clear();
      await auto.check();
      var j = auto.toJson();
      expect([j['offline'], j['noNet'], j['now']], [true, true, 'A'], reason: 'offline: nothing tested, marked or moved');
      expect(fake.tested, isEmpty);
      expect((j['routes'] as List).cast<Map>().every((r) => r['fails'] == 0 && r['strikes'] == 0), isTrue);

      auto.onLog('updated default interface');
      expect(auto.offline, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect([for (final n in net) n.kind], ['offline', 'online'], reason: 'offline is no "lost": the OS is at fault; told once');
      expect(net.last.downMs, isNotNull);
    });

    test('an unrelated log line does not toggle offline', () {
      final p = plan([unit('A', ['s::a'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      auto.onLog('some ordinary sing-box line');
      expect(auto.offline, isFalse);
    });
  });

  group('onClosed: requests that got nothing back', () {
    ClosedConnection cc({String outbound = 'route0/s::a', List<String> chain = const ['route0/s::a', 'route0', 'proxy'], String dest = 'blocked.example:443', int up = 120, int down = 0, String rule = '', String process = '', String pkg = ''}) =>
        ClosedConnection(outbound: outbound, chain: chain, destination: dest, up: up, down: down, rule: rule, process: process, pkg: pkg);

    test('ignored: down > 0 (the request did get something back)', () async {
      final p = plan([unit('A', ['s::a'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      await auto.check();
      auto.onClosed(cc(down: 5));
      expect(auto.requestFails, 0);
      expect(auto.lastRequestFail, isNull);
    });

    test('ignored: the chain maps to no route', () async {
      final p = plan([unit('A', ['s::a'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      await auto.check();
      auto.onClosed(cc(outbound: 'direct', chain: ['direct']));
      expect(auto.requestFails, 0);
    });

    test('ignored: the chain maps to a route that is not the current one', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      await auto.check(); // current: A
      auto.onClosed(cc(outbound: 'route1/s::b', chain: ['route1/s::b', 'route1', 'proxy']));
      expect(auto.requestFails, 0);
    });

    test('the current route: counts requestFails, records lastRequestFail, two within failWindow count as one check', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      var t = 0;
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      await auto.check(); // current: A

      auto.onClosed(cc(dest: 'blocked.example:443'));
      expect(auto.requestFails, 1);
      expect(auto.lastRequestFail, {'route': 'A', 'dest': 'blocked.example:443', 'sent': 120, 'at': 0});

      t += 5000; // within failWindow (10s)
      auto.onClosed(cc(dest: 'other.example:443'));
      expect(auto.requestFails, 2, reason: 'every failed request is still counted');
      expect(auto.lastRequestFail!['dest'], 'other.example:443');
    });

    test('a node that answers again: the failed site is told (server, rule, app) — Auto probes nothing itself', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final asked = <String>[];
      final fails = <AutoSiteFail>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 7, reach: (tag, dest) async {
        asked.add(tag);
        return false;
      }, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.siteFails.listen(fails.add);
      await auto.check();
      auto.onClosed(cc(rule: 'domain_suffix=blocked.example', process: r'C:\Apps\Discord\Discord.exe', pkg: 'org.x'));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, isEmpty, reason: 'the probes are the Sentinel\'s checks now');
      expect(fails.single.toJson(), {
        'route': 'A',
        'server': 's::a',
        'tag': 'route0/s::a',
        'dest': 'blocked.example:443',
        'rule': 'domain_suffix=blocked.example',
        'process': r'C:\Apps\Discord\Discord.exe',
        'pkg': 'org.x',
        'firstSeen': 7,
        'at': 7,
      });
      expect(auto.siteFailCount, 1);
      expect(auto.toJson()['siteFails'], 1);
    });

    test('the core\'s own failed connections (probe / svc inbound, the app\'s own) are no request of the user\'s: no count, no site, no check', () async {
      final p = plan([unit('A', ['s::a'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final fails = <AutoSiteFail>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          clock: () => 0,
          reach: (tag, dest) async => false,
          ownConnection: (c) => c.pkg == 'dev.jormungand.app',
          settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.siteFails.listen(fails.add);
      await auto.check();
      for (final inbound in ['probe-in', 'svc-in']) {
        auto.onClosed(ClosedConnection(
            outbound: 'route0/s::a', chain: const ['route0/s::a', 'route0', 'proxy'], destination: 'blocked.example:443', up: 0, down: 0, inbound: inbound, rule: 'Latency check', pkg: 'dev.jormungand.app'));
      }
      auto.onClosed(cc(pkg: 'dev.jormungand.app')); // the app's own request in the TUN
      expect(auto.requestFails, 0);
      expect(auto.lastRequestFail, isNull);
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fails, isEmpty);
      expect(auto.siteFailCount, 0);
    });

    test('a user\'s failure is checked: one site notice with the user\'s rule and app; the check\'s own failed re-test does not make another or take its attribution', () async {
      final p = plan([unit('A', ['s::a'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30});
      final fails = <AutoSiteFail>[];
      late AutoService auto;
      var t = 7;
      auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, reach: (tag, dest) async => false, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.siteFails.listen((f) {
        fails.add(f);
        t += 20000; // past the failure window: a failure that counted would start a new check
        // the Sentinel's re-test of the site through the probe inbound fails: sing-box closes that connection
        auto.onClosed(ClosedConnection(
            outbound: 'route0/s::a', chain: const ['route0/s::a', 'route0', 'proxy'], destination: f.dest, up: 0, down: 0, inbound: 'probe-in', rule: 'Latency check', pkg: 'dev.jormungand.app'));
      });
      await auto.check();
      auto.onClosed(cc(rule: 'domain_suffix=blocked.example', process: r'C:\Apps\Discord\Discord.exe', pkg: 'org.x'));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fails, hasLength(1));
      expect([fails.single.rule, fails.single.process, fails.single.pkg], ['domain_suffix=blocked.example', r'C:\Apps\Discord\Discord.exe', 'org.x']);
      expect(auto.requestFails, 1, reason: 'only the user\'s request');
    });

    test('a site a test cannot be aimed at (another port, an IP on 443) is not told', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final fails = <AutoSiteFail>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) async => false, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.siteFails.listen(fails.add);
      await auto.check();
      auto.onClosed(cc(dest: 'blocked.example:8443'));
      auto.onClosed(cc(dest: '1.2.3.4:443'));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fails, isEmpty);
    });

    // A failed connection names the GROUP (`route0`): the probe inbound has no user for a group — the site test
    // must go to the member in use (the selector's choice: the first member until the core picks another), or not run
    // at all when sing-box tells none, never "fail" on a refusal.
    test('the failed connection names the route group: the notice has the member in use; unknown member / a stranger tag: no notice', () async {
      final reached = <String>[];
      Future<List<AutoSiteFail>> told(FakeBox Function(Map<String, dynamic> p) box, String outbound, List<String> chain) async {
        final p = plan([unit('A', ['s::a', 's::a2']), unit('B', ['s::b'])]);
        final fake = box(p);
        final fails = <AutoSiteFail>[];
        final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) async {
          reached.add(tag);
          return false;
        }, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
        auto.siteFails.listen(fails.add);
        await auto.check();
        auto.onClosed(cc(outbound: outbound, chain: chain));
        await auto.check();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // the Sentinel aims its probe at the notice's tag
        if (fails.isNotEmpty) await auto.reachSame(fails.single.tag, fails.single.dest);
        return fails;
      }

      final known = await told((p) => FakeBox(buildConfig(p), {'s::a': 50, 's::a2': 20, 's::b': 60}), 'route0', const ['route0', 'proxy']);
      expect(known.single.tag, 'route0', reason: 'the failed connection\'s own outbound, as the failure book records it');
      expect(reached, ['route0/s::a'], reason: 'the probe goes to the member in use (a2 is faster, but a is not slower by the threshold)');
      final unknown = await told((p) => _NoMemberNow(buildConfig(p), {'s::a': 30, 's::a2': 40, 's::b': 60}), 'route0', const ['route0', 'proxy']);
      expect(unknown, isEmpty);
      final stranger = await told((p) => FakeBox(buildConfig(p), {'s::a': 30, 's::a2': 40, 's::b': 60}), 'route0/nope', const ['route0/nope', 'route0', 'proxy']);
      expect(stranger, isEmpty);
    });

    // A current; B, C, D, E answer, so any of them may be tried
    (AutoService, List<String>) five(Future<bool?> Function(String) reach, {String? siteRetry}) {
      final p = plan([for (final k in ['a', 'b', 'c', 'd', 'e']) unit(k.toUpperCase(), ['s::$k'])], auto: {'standby': 5, 'siteRetry': ?siteRetry});
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60, 's::c': 70, 's::d': 80, 's::e': 90});
      final asked = <String>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          clock: () => 0,
          reach: (tag, dest) {
            asked.add(tag);
            return reach(tag);
          },
          settings: AutoSettings.fromPlan(p));
      return (auto, asked);
    }

    // Five routes of one server each: A (the failing one) and B of subscription s1 (B of another country), C of s2, D of
    // s3, E of s4. The flags are the plan's knowledge of the country.
    Map<String, dynamic> flagged(String id, String key, String flag) {
      final u = unit(id, [key]);
      ((u['main'] as Map)['nodes'] as List).cast<Map>().single['flag'] = flag;
      return u;
    }

    (AutoService, List<String>) subs(Future<bool?> Function(String) reach, {String? siteRetry, Map<String, int>? alive}) {
      final p = plan([
        flagged('A', 's1::a', 'DE'),
        flagged('B', 's1::b', 'FR'),
        flagged('C', 's2::c', 'FR'),
        flagged('D', 's3::d', 'NL'),
        flagged('E', 's4::e', 'PL'),
      ], auto: {'standby': 5, 'siteRetry': ?siteRetry});
      final fake = FakeBox(buildConfig(p), alive ?? {'s1::a': 30, 's1::b': 60, 's2::c': 70, 's3::d': 80, 's4::e': 90});
      final asked = <String>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) {
        asked.add(tag);
        return reach(tag);
      }, settings: AutoSettings.fromPlan(p));
      return (auto, asked);
    }

    test('workingNodes / routeIdOf: the answering servers in Auto\'s order, with their subscription and flag; a dead one is not listed; the entry id of an outbound', () async {
      final (auto, _) = subs((tag) async => true, alive: {'s1::a': 30, 's1::b': 60, 's3::d': 80, 's4::e': 90});
      await auto.check();
      expect(auto.workingNodes().map((n) => '${n.route}:${n.server}:${n.sub}:${n.country}:${n.tag}'),
          ['A:s1::a:s1:DE:route0/s1::a', 'B:s1::b:s1:FR:route1/s1::b', 'D:s3::d:s3:NL:route3/s3::d', 'E:s4::e:s4:PL:route4/s4::e'],
          reason: 'C does not answer');
      expect([auto.routeIdOf('route1/s1::b'), auto.routeIdOf('route3'), auto.routeIdOf('direct'), auto.routeIdOf('route9/x')], ['B', 'D', null, null]);
    });

    test('scoutFor: the same subscription and another country first, then the same subscription, another country, any; never the failing server; none = null', () async {
      final (auto, _) = subs((tag) async => true);
      await auto.check();
      expect(auto.scoutFor('route0/s1::a')?.server, 's1::b', reason: 'same subscription, another country');
      expect(auto.scoutFor('route2/s2::c')?.server, 's1::a', reason: 'no one else in s2: another country (DE) in the order of Auto');
      final (lone, _) = subs((tag) async => true, alive: {'s1::a': 30});
      await lone.check();
      expect(lone.scoutFor('route0/s1::a'), isNull, reason: 'only the failing server works');
      final (same, _) = subs((tag) async => true, alive: {'s1::a': 30, 's1::b': 60, 's2::c': 70});
      await same.check();
      expect(same.scoutFor('route1/s1::b')?.server, 's1::a', reason: 'the same subscription before another one');
    });

    test('scoutFor country: the provider flag, else the country of the last exit check, else unknown', () async {
      // A (the failing one) and B, C of s1, no flags in the plan except where given; the exit book names countries
      Map<String, dynamic> node(String id, String key, {String? flag}) {
        final u = unit(id, [key]);
        final n = ((u['main'] as Map)['nodes'] as List).cast<Map>().single..remove('flag');
        if (flag != null) n['flag'] = flag;
        return u;
      }

      String idOf(Map<String, dynamic> u) => serverIdentity((((u['main'] as Map)['nodes'] as List).single as Map)['outbound'] as Map);
      final de = flagOfCountry('DE'), fr = flagOfCountry('FR');
      Future<String?> scout(Map<String, dynamic> a, Map<String, dynamic> b, Map<String, dynamic> c, {String? detA, String? detB, String? detC}) async {
        final p = plan([a, b, c], auto: {'standby': 5});
        final fake = FakeBox(buildConfig(p), {'s1::a': 30, 's1::b': 60, 's1::c': 70});
        final book = ExitBook();
        for (final (u, code) in [(a, detA), (b, detB), (c, detC)]) {
          if (code != null) book.record(idOf(u), ip: '203.0.113.1', country: code, at: 1);
        }
        final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (t, d) async => true, settings: AutoSettings.fromPlan(p), exits: book);
        await auto.check();
        return auto.scoutFor('route0/s1::a')?.server;
      }

      // B shares A's country, C does not: C is the scout (the list order alone would pick B)
      var a = node('A', 's1::a', flag: de), b = node('B', 's1::b', flag: de), c = node('C', 's1::c');
      expect(await scout(a, b, c, detC: 'FR'), 's1::c', reason: 'C has no flag: the detected FR is another country than the flag DE');
      expect(await scout(a, b, c), 's1::b', reason: 'C has no flag and was never checked: its country is unknown, B comes first in the order');
      expect(await scout(a, b, c, detC: 'DE'), 's1::b', reason: 'C was detected in the same country as A');
      // the provider flag wins over what the check says
      b = node('B', 's1::b', flag: fr);
      c = node('C', 's1::c', flag: de);
      expect(await scout(a, b, c, detB: 'DE', detC: 'FR'), 's1::b', reason: 'flags FR / DE stand whatever the exit checks named');
      // the failing node itself has no flag: its detected country is the one to differ from
      a = node('A', 's1::a');
      b = node('B', 's1::b', flag: de);
      c = node('C', 's1::c', flag: fr);
      expect(await scout(a, b, c, detA: 'FR'), 's1::b', reason: 'A was detected in FR: B (DE) is another country, C (FR) is not');
    });

    test('elsewhere: one working node per other subscription (the failing one\'s and exceptSubs left out), at most limit; reads nothing for Manual', () async {
      final (auto, _) = subs((tag) async => true);
      await auto.check();
      expect(auto.elsewhere('route0/s1::a').map((n) => n.server), ['s2::c', 's3::d', 's4::e']);
      expect(auto.elsewhere('route0/s1::a', exceptSubs: {'s3'}, limit: 1).map((n) => n.server), ['s2::c']);
      expect(auto.elsewhere('route0/s1::a', exceptSubs: {'s2', 's3', 's4'}), isEmpty);
    });

    test('reachScout: the scout alone is probed — opens: its route and server (and subscription); does not: tried; null: unsure', () async {
      final (auto, asked) = subs((tag) async => tag == 'route1/s1::b');
      await auto.check();
      final a = await auto.reachScout('route0/s1::a', 'blocked.example:443');
      expect(asked, ['route1/s1::b']);
      expect([a.via, a.viaServer, a.subs, a.unsure, a.off], ['B', 's1::b', ['s1'], false, false]);
      final (no, askedNo) = subs((tag) async => false);
      await no.check();
      final n = await no.reachScout('route0/s1::a', 'blocked.example:443');
      expect([askedNo, n.via, n.tried.map((t) => '${t.route}:${t.server}')], [['route1/s1::b'], null, ['B:s1::b']]);
      final (unk, _) = subs((tag) async => null);
      await unk.check();
      final u = await unk.reachScout('route0/s1::a', 'blocked.example:443');
      expect([u.via, u.tried, u.unsure], [null, isEmpty, true]);
    });

    test('siteRetry is the total of scout + elsewhere probes: 3 — the scout and two more; all — every other subscription; off — none, and off is told', () async {
      for (final (retry, expected) in [
        ('3', ['route1/s1::b', 'route2/s2::c', 'route3/s3::d']),
        ('all', ['route1/s1::b', 'route2/s2::c', 'route3/s3::d', 'route4/s4::e']),
        (null, ['route1/s1::b', 'route2/s2::c', 'route3/s3::d']),
      ]) {
        final (auto, asked) = subs((tag) async => false, siteRetry: retry);
        await auto.check();
        final s = await auto.reachScout('route0/s1::a', 'blocked.example:443');
        final e = await auto.reachElsewhere('route0/s1::a', 'blocked.example:443', scout: s);
        expect(asked, expected, reason: 'siteRetry $retry');
        expect([e.via, s.tried.length + e.tried.length, e.off], [null, expected.length, false]);
      }
      final (off, askedOff) = subs((tag) async => true, siteRetry: 'off');
      await off.check();
      final s = await off.reachScout('route0/s1::a', 'blocked.example:443');
      final e = await off.reachElsewhere('route0/s1::a', 'blocked.example:443', scout: s);
      expect([askedOff, s.via, s.off, e.via, e.off], [<String>[], null, true, null, true]);
    });

    test('reachElsewhere: opens on the 2nd other subscription — the rest are not tried; the scout\'s subscription is not repeated; no scout budget left — nothing', () async {
      final (auto, asked) = subs((tag) async => tag == 'route3/s3::d');
      await auto.check();
      final s = await auto.reachScout('route2/s2::c', 'blocked.example:443'); // the scout of s2's server is s1's A
      expect(asked, ['route0/s1::a']);
      final e = await auto.reachElsewhere('route2/s2::c', 'blocked.example:443', scout: s);
      expect(asked.skip(1), ['route3/s3::d'], reason: 's1 was the scout\'s; with 2 probes left D opens on the first of s3 and s4');
      expect([e.via, e.viaServer, e.tried, e.subs], ['D', 's3::d', isEmpty, ['s3', 's4']]);
      const spent = AltReach(tried: [(route: 'X', server: 'x::1'), (route: 'Y', server: 'y::1'), (route: 'Z', server: 'z::1')]);
      final none = await auto.reachElsewhere('route0/s1::a', 'blocked.example:443', scout: spent);
      expect([none.via, none.tried, none.unsure], [null, isEmpty, false]);
      expect(asked.length, 2, reason: 'nothing was probed for the spent budget');
    });

    test('nothing works besides the failing server: the scout and elsewhere probe nothing and tell nothing (not unsure)', () async {
      final (auto, asked) = subs((tag) async => true, alive: {'s1::a': 30});
      await auto.check();
      final s = await auto.reachScout('route0/s1::a', 'blocked.example:443');
      final e = await auto.reachElsewhere('route0/s1::a', 'blocked.example:443', scout: s);
      expect([asked, s.via, s.tried, s.unsure, e.via, e.tried, e.unsure], [<String>[], null, isEmpty, false, null, isEmpty, false]);
    });

    test('reachSame: through the server a failed connection went out of; a stranger tag cannot be told', () async {
      final (auto, asked) = five((tag) async => tag == 'route1/s::b');
      await auto.check();
      expect(await auto.reachSame('route1/s::b', 'blocked.example:443'), isTrue);
      expect(await auto.reachSame('route0/s::a', 'blocked.example:443'), isFalse);
      expect(await auto.reachSame('route0/nope', 'blocked.example:443'), isNull);
      expect(auto.canReachSame('route0/s::a', 'blocked.example:443'), isTrue);
      expect(auto.canReachSame('route0/s::a', 'blocked.example:8443'), isFalse);
      expect(auto.canReachSame('route0/nope', 'blocked.example:443'), isFalse);
      expect(asked, ['route1/s::b', 'route0/s::a']);
    });

    test('a Cancel stops the scout and the elsewhere probes: the probe in flight is given up, the ones after it are not started (unsure)', () async {
      final hang = Completer<bool?>();
      final (auto, asked) = subs((tag) => hang.future);
      await auto.check();
      final cancel = Cancel();
      final f = auto.reachScout('route0/s1::a', 'blocked.example:443', cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.cancel('net.offline');
      final a = await f;
      expect(asked, ['route1/s1::b']);
      expect([a.via, a.tried, a.unsure], [null, isEmpty, true]);
      final e = await auto.reachElsewhere('route0/s1::a', 'blocked.example:443', cancel: cancel);
      expect(asked, ['route1/s1::b'], reason: 'cancelled before the first probe');
      expect([e.via, e.tried, e.unsure], [null, isEmpty, true]);
    });

    test('node does not answer at all: no _sites lookup, just the usual retries', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      var t = 0;
      var reachCalls = 0;
      Future<bool?> reach(String tag, String dest) async {
        reachCalls++;
        return true;
      }

      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, reach: reach, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      await auto.check(); // current: A
      fake.alive.remove('s::a'); // now dead
      auto.onClosed(cc());
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reachCalls, 0, reason: 'the node itself does not answer: sites are not tried');
    });
  });

  group('Manual: the plan holds every route, the controller stays on one', () {
    Map<String, dynamic> three({bool manual = true}) =>
        {...plan([unit('A', ['s::a']), unit('B', ['s::b']), unit('C', ['s::c'])]), if (manual) 'manual': true};

    test('a dead route is not left and no other route is tested; back in Auto (live) it fails over', () async {
      final p = three();
      final fake = FakeBox(buildConfig(p), {'s::b': 40, 's::c': 50}); // A is dead
      final auto = AutoService(fake, p, delay: fake.delayTest);
      expect(auto.manual, isTrue);
      for (var i = 0; i < 4; i++) {
        await auto.check();
      }
      expect(fake.groups['proxy']!.now, 'route0');
      expect(fake.tested.where((t) => t.contains('route1') || t.contains('route2')), isEmpty, reason: 'only the route the user stays on is looked at');
      expect(auto.switchCount, 0);
      expect(auto.toJson()['manual'], isTrue);
      expect(await auto.setManual(false), isTrue); // no restart, no new plan
      for (var i = 0; i < 4; i++) {
        await auto.check();
      }
      expect(fake.groups['proxy']!.now, 'route1', reason: 'Auto again: A is dead, B is the first that answers');
      expect(auto.toJson()['now'], 'B');
    });

    test('a pick of the core before the first look at the groups is not put back (the stream answers while the select is awaited)', () async {
      final p = three(manual: false);
      final fake = _SlowSelectBox(buildConfig(p), {'s::a': 30, 's::b': 40, 's::c': 50});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      auto.start(); // the groups stream is listened to: its first answer is the first look
      expect(await auto.setManual(true, entry: 'C'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect([fake.groups['proxy']!.now, auto.index, auto.toJson()['now']], ['route2', 2, 'C'], reason: 'the first look ran inside the select');
      auto.stop();
    });

    test('setManual(on, entry) moves the selector to that route: no switch event; a stranger entry is refused', () async {
      final p = three(manual: false);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 40, 's::c': 50});
      final auto = AutoService(fake, p, delay: fake.delayTest);
      final events = <AutoSwitch>[];
      auto.switches.listen(events.add);
      expect(await auto.setManual(true, entry: 'C'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect([fake.groups['proxy']!.now, auto.index, auto.manual, auto.toJson()['now']], ['route2', 2, true, 'C']);
      expect(events, isEmpty);
      expect(auto.switchCount, 0);
      // the same route again, and Manual on the one it is on: nothing to move
      expect(await auto.setManual(true, entry: 'C'), isTrue);
      expect(await auto.setManual(true, entry: 'nope'), isFalse);
      expect([auto.index, fake.groups['proxy']!.now], [2, 'route2']);
      // in Manual a route above is not looked at, however good it is
      for (var i = 0; i < 3; i++) {
        await auto.check();
      }
      expect(fake.groups['proxy']!.now, 'route2');
    });

    test('closeOld: a Manual move closes only the main flow connections of the route left; off closes none', () async {
      for (final close in [true, false]) {
        final p = three(manual: false);
        final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 40, 's::c': 50});
        fake.conns.addAll([
          _conn('main', ['route0/s::a', 'route0', 'proxy']),
          _conn('main2', ['route0/s::a', 'route0', 'proxy'], up: 5, down: 9), // moving ones go too: the user asked for it
          _conn('direct', ['direct']),
          _conn('target', ['route0/s::a', 'route0', 'Telegram']), // a rule target's own group, not the main flow
          _conn('other', ['route1/s::b', 'route1', 'proxy']), // another route
        ]);
        final auto = AutoService(fake, p, delay: fake.delayTest);
        expect(await auto.setManual(true, entry: 'C', closeOld: close), isTrue);
        expect(fake.groups['proxy']!.now, 'route2');
        expect(fake.closed, close ? ['main', 'main2'] : isEmpty);
        // Manual on the route it is on, or Manual → Auto: nothing moves, nothing is closed
        fake.closed.clear();
        fake.conns.add(_conn('now', ['route2/s::c', 'route2', 'proxy']));
        expect(await auto.setManual(true, entry: 'C', closeOld: close), isTrue);
        expect(await auto.setManual(false, closeOld: close), isTrue);
        expect(fake.closed, isEmpty);
      }
    });

    test('status.auto reports the server of every route group, standby routes too', () async {
      final p = plan([
        unit('A', ['s::a1', 's::a2'], pick: 'priority', chosen: 's::a1'),
        unit('B', ['s::b1', 's::b2'], pick: 'priority', chosen: 's::b2'),
        {'id': 'X', 'kind': 'chain', 'entry': _grp(['s::e1', 's::e2']), 'main': _grp(['s::x1'], pick: 'priority', chosen: 's::x1')},
      ]);
      final (auto, _) = setup(p, {'s::a1': 40, 's::a2': 50, 's::b1': 40, 's::b2': 50, 's::e1': 20, 's::e2': 30, 's::x1': 10});
      await auto.check(); // sing-box's groups are read
      final routes = {for (final r in (auto.toJson()['routes'] as List).cast<Map>()) r['id']: [r['server'], r['entryServer']]};
      expect(routes['A'], ['s::a1', null]);
      expect(routes['B'], ['s::b2', null], reason: 'a standby route: the server its group is on, not its first');
      expect(routes['X'], ['s::x1', 's::e1']);
    });
  });

  group('live traffic proves the current node alive', () {
    const chainA = ['route0/s::a', 'route0', 'proxy'];
    final notes = <String>[];
    late FakeBox fake;
    late AutoService auto;

    ClosedConnection closed(int down, {int up = 5, String id = ''}) =>
        ClosedConnection(outbound: 'route0/s::a', chain: chainA, destination: 'x.example:443', up: up, down: down, id: id);

    bool aTested() => fake.tested.any((x) => x.contains('s::a'));

    setUp(() async {
      notes.clear();
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), trace: notes.add);
      await auto.check(); // the first look: everything is tested, the connections table is the baseline
      expect(aTested(), isTrue);
      fake.tested.clear();
    });

    Map<String, dynamic> routeA() => (auto.toJson()['routes'] as List).cast<Map<String, dynamic>>().first;

    test('data back through the current server: not tested, counted as an answer, one line in the log', () async {
      fake.conns.add(_conn('c1', chainA, up: 10, down: 100));
      fake.conns.add(_conn('c2', chainA, up: 10, down: 0)); // nothing back on this one, it does not count
      await auto.check();
      expect(aTested(), isFalse);
      expect([routeA()['ms'], routeA()['oks'], routeA()['fails']], [30, 2, 0], reason: 'the last delay stays, the answer is counted');
      expect(notes.where((n) => n.contains('live traffic')), hasLength(1));
      expect(notes.single, allOf(contains('route0/s::a'), contains('1 connection'), contains('100 bytes')));
      expect(auto.toJson()['now'], 'A');
    });

    test('no traffic since the last look: tested as always', () async {
      fake.conns.add(_conn('c1', chainA, down: 100));
      await auto.check(); // skipped
      fake.tested.clear();
      await auto.check(); // the same totals: nothing moved
      expect(aTested(), isTrue);
      expect(notes, hasLength(1));
      fake.tested.clear();
      fake.conns.single.down += 7; // moved again
      await auto.check();
      expect(aTested(), isFalse);
    });

    test('a closed connection that got data back counts; the core\'s own tests and other servers do not', () async {
      fake.conns.add(LiveConnection(Connection(id: 'p', chainList: chainA, downlinkTotal: Int64(50), inbound: 'probe-in')));
      fake.conns.add(_conn('o', ['route1/s::b', 'route1', 'proxy'], down: 90));
      await auto.check();
      expect(aTested(), isTrue, reason: 'a probe and the server below are no evidence');
      fake.tested.clear();
      auto.onClosed(closed(300, id: 'c9'));
      await auto.check();
      expect(aTested(), isFalse);
    });

    test('a failed request through the current route: tested, even with other traffic moving', () async {
      fake.conns.add(_conn('c1', chainA, down: 100));
      auto.onClosed(closed(0));
      await auto.check();
      expect(aTested(), isTrue);
      expect(notes.where((n) => n.contains('live traffic')), isEmpty);
    });

    test('a server that missed before is not cleared by traffic; the spares below are tested as before', () async {
      fake.alive.remove('s::a');
      await auto.check(); // one miss
      expect(routeA()['fails'], 1);
      fake.tested.clear();
      fake.conns.add(_conn('c1', chainA, down: 100));
      await auto.check();
      expect(aTested(), isTrue, reason: 'it missed: the retry test runs');
    });
  });
}

/// sing-box that does not tell the member of a route group (before its groups are read): no member is reported.
class _NoMemberNow extends FakeBox {
  _NoMemberNow(super.config, super.alive);

  @override
  Map<String, String> get selected => {
        for (final e in super.selected.entries)
          if (!e.key.startsWith('route')) e.key: e.value,
      };
}

/// sing-box whose `select` answers a little after the groups stream told the new pick: the owner's code after the
/// await runs when the stream's listeners already did.
class _SlowSelectBox extends FakeBox {
  _SlowSelectBox(super.config, super.alive);

  @override
  Future<bool> select(String group, String outbound) async {
    final ok = await super.select(group, outbound);
    await Future<void>.delayed(Duration.zero);
    return ok;
  }
}

class _Dead implements BoxControl {
  @override
  Map<String, String> get selected => {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => false;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => false;
}
