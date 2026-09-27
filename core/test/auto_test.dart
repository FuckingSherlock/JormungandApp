// AutoService against a fake Clash API. The fake is built from the real config
// (buildConfig), so the tags the service switches are the ones sing-box would get; it acts
// like sing-box: a delay test goes through a group to the server it uses now, a chain's
// exit through its entry group, a group delay has a urltest pick again.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

class FakeGroup {
  FakeGroup(this.type, this.all, this.now);
  final String type;
  final List<String> all;
  String? now;
}

class FakeClash implements ClashApi {
  FakeClash(Map<String, dynamic> config, this.alive) {
    for (final o in (config['outbounds'] as List).cast<Map>()) {
      final tag = o['tag'] as String;
      if (o['type'] == 'selector' || o['type'] == 'urltest') {
        final all = (o['outbounds'] as List).cast<String>();
        groups[tag] = FakeGroup(o['type'] as String, all, o['type'] == 'selector' ? (o['default'] as String? ?? all.first) : null);
      } else if (o['type'] != 'direct') {
        detours[tag] = o['detour'] as String?;
      }
    }
    // sing-box's urltest tests its servers once on start and picks the fastest
    for (final g in groups.values) {
      if (g.type == 'urltest') _repick(g);
    }
  }

  final Map<String, int> alive; // node key -> ms; missing or -1 = no answer
  final groups = <String, FakeGroup>{};
  final detours = <String, String?>{};
  final tested = <String>[]; // servers / groups a delay test was asked for
  // open connections as /connections lists them: {id, chains, upload, download}
  final conns = <Map<String, dynamic>>[];
  final closed = <String>[];
  void Function()? onConnections; // before each /connections answer (traffic moves)

  String _leaf(String tag) {
    for (var g = groups[tag]; g != null; g = groups[tag]) {
      tag = g.now ?? g.all.first;
    }
    return tag;
  }

  int delay(String tag) {
    final leaf = _leaf(tag);
    final ms = alive[leaf.substring(leaf.indexOf('/') + 1)] ?? -1;
    final via = detours[leaf];
    if (ms < 0 || via == null) return ms;
    final d = delay(via);
    return d < 0 ? -1 : ms + d;
  }

  void _repick(FakeGroup g) {
    String? best;
    for (final m in g.all) {
      final d = delay(m);
      if (d >= 0 && (best == null || d < delay(best))) best = m;
    }
    if (best != null) g.now = best;
  }

  Map<String, dynamic> _info(String tag) {
    final g = groups[tag];
    return g == null ? {'type': 'Shadowsocks'} : {'type': g.type, 'now': g.now ?? '', 'all': g.all};
  }

  @override
  Future<Map<String, dynamic>?> clashGet(String path, {Duration timeout = const Duration(seconds: 2)}) async {
    final s = Uri.parse(path).pathSegments;
    if (s.length == 1 && s[0] == 'connections') {
      onConnections?.call();
      return {'_status': 200, 'connections': [for (final c in conns) {...c}]};
    }
    if (s.length == 1 && s[0] == 'proxies') {
      return {
        '_status': 200,
        'proxies': {for (final t in [...groups.keys, ...detours.keys]) t: _info(t)},
      };
    }
    if (s.length == 2 && s[0] == 'proxies') return {'_status': 200, ..._info(s[1])};
    if (s.length == 3 && s[0] == 'proxies' && s[2] == 'delay') {
      tested.add(s[1]);
      final d = delay(s[1]);
      return d < 0 ? {'_status': 503, 'message': 'An error occurred in the delay test'} : {'_status': 200, 'delay': d};
    }
    if (s.length == 3 && s[0] == 'group' && s[2] == 'delay') {
      final g = groups[s[1]]!;
      tested.add('group:${s[1]}');
      final res = <String, dynamic>{};
      for (final m in g.all) {
        final d = delay(m);
        if (d >= 0) res[m] = d;
      }
      if (g.type == 'urltest') _repick(g);
      return {'_status': 200, ...res};
    }
    return {'_status': 404};
  }

  @override
  Future<int?> clashPut(String path, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 2)}) async {
    final s = Uri.parse(path).pathSegments;
    final g = groups[s[1]];
    if (g == null || g.type != 'selector' || !g.all.contains(body['name'])) return 400;
    g.now = body['name'] as String;
    return 204;
  }

  @override
  Future<int?> clashDelete(String path, {Duration timeout = const Duration(seconds: 2)}) async {
    final id = Uri.parse(path).pathSegments.last;
    closed.add(id);
    conns.removeWhere((c) => c['id'] == id);
    return 204;
  }
}

Map<String, dynamic> _node(String key) => {
      'key': key,
      'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
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

(AutoService, FakeClash) setup(Map<String, dynamic> p, Map<String, int> alive) {
  final fake = FakeClash(buildConfig(p, clashPort: 1), alive);
  return (AutoService(fake, p), fake);
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
  });

  test('Fastest: a silent server is replaced inside the route at once, no route switch', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2', 's::a3']), unit('B', ['s::b1'])]), {'s::a1': 40, 's::a2': 80, 's::b1': 30});
    await auto.check();
    expect(auto.toJson()['server'], 's::a1');
    fake.alive.remove('s::a1');
    await auto.check();
    final j = auto.toJson();
    expect([j['now'], j['server'], j['switches'], j['noNet']], ['A', 's::a2', 0, false]);
    expect((j['routes'] as List).first['fails'], 0);
    expect(fake.tested, contains('group:route0'));
    // the group test's silent servers are misses too (the app's ping cache learns them), one each
    final m = {for (final e in (j['members'] as List).cast<Map>()) e['key']: [e['ms'], e['fails']]};
    expect([m['s::a1'], m['s::a2'], m['s::a3']], [[-1, 1], [80, 0], [-1, 1]]);
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
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::a': 40, 's::b': 60});
    final auto = AutoService(fake, p, clock: () => t);
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
    j = auto.toJson();
    expect([j['entryServer'], (j['routes'] as List).first['fails'], (j['routes'] as List).first['ms']], ['s::e2', 0, 70]);
    final keys = [for (final m in (j['members'] as List).cast<Map>()) m['key']];
    expect(keys, containsAll(['s::e1', 's::e2']));
    expect(keys, isNot(contains('s::x')));
    final e1 = (j['members'] as List).cast<Map>().firstWhere((m) => m['key'] == 's::e1');
    expect([e1['ms'], e1['fails']], [-1, 1]);
  });

  test('sing-box not answering: the check judges nothing', () async {
    final auto = AutoService(_Dead(), plan([unit('A', ['s::a']), unit('B', ['s::b'])]));
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
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::b': 30});
    final auto = AutoService(fake, p,
        settings: const AutoSettings(checkEvery: Duration(hours: 1), firstCheck: Duration(milliseconds: 1), retryPause: Duration(milliseconds: 20)));
    auto.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    auto.stop();
    expect(auto.toJson()['now'], 'B');
    expect(fake.tested.where((t) => t == 'route0/s::a').length, 2, reason: 'failAfter 2: the first round and one retry');
  });

  test('failover: batches of 10 by priority; the whole first batch silent = no network, nobody struck', () async {
    final routes = [for (var i = 0; i < 13; i++) unit('R$i', ['s::r$i'])];
    final p = plan(routes, auto: {'standby': 0, 'flapGuard': true});
    var t = 0;
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::r0': 30, 's::r12': 30});
    final auto = AutoService(fake, p, clock: () => t);
    await auto.check();
    fake.alive.remove('s::r0');
    await auto.check();
    await auto.check();
    var j = auto.toJson();
    expect([j['now'], j['noNet'], j['switches'], fake.groups['proxy']!.now], ['R0', true, 0, 'route0']);
    expect(fake.tested.where((x) => x.contains('r11') || x.contains('r12')), isEmpty, reason: 'only the first batch (R1…R10)');
    expect((j['routes'] as List).cast<Map>().skip(1).every((r) => r['fails'] == 0 && r['strikes'] == 0), isTrue);
    expect((j['routes'] as List).cast<Map>().first['strikes'], 0, reason: 'no network: the current one is not struck either');
    // the network is back, R0 is still dead: R7 and R3 answer — R3 is first by priority
    fake.alive['s::r7'] = 10;
    fake.alive['s::r3'] = 90;
    t += 10000;
    await auto.check();
    j = auto.toJson();
    expect([j['now'], j['noNet']], ['R3', false]);
    expect((j['routes'] as List).cast<Map>().first['strikes'], 1, reason: 'R0 dropped while another route answered');
  });

  test('flap guard: a strike only when another route answered; the hold doubles up to flapMax, stable work forgets it', () async {
    var t = 0;
    final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])], auto: {'flapGuard': true, 'flapMax': 3, 'flapReset': 5, 'failAfter': 1});
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p, clock: () => t);
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
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p, clock: () => t);
    await auto.check();
    fake.alive.remove('s::a');
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    fake.alive['s::a'] = 30;
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
    final fake = FakeClash(buildConfig(p, clashPort: 1), {'s::a': 30, 's::b': 60});
    final auto = AutoService(fake, p, settings: const AutoSettings(failAfter: 1, flapGuard: false, stallAfter: Duration(milliseconds: 30)));
    fake.conns.addAll([
      {'id': 'moving', 'chains': ['route0/s::a', 'route0', 'proxy'], 'upload': 10, 'download': 100},
      {'id': 'stuck', 'chains': ['route0/s::a', 'route0', 'proxy'], 'upload': 10, 'download': 100},
      {'id': 'other', 'chains': ['direct'], 'upload': 0, 'download': 0},
    ]);
    fake.onConnections = () => fake.conns.firstWhere((c) => c['id'] == 'moving')['download'] += 1;
    await auto.check();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fake.closed, isEmpty, reason: 'no switch: nothing is closed');
    fake.alive.remove('s::a');
    await auto.check();
    expect(auto.toJson()['now'], 'B');
    expect(fake.closed, isEmpty, reason: 'not at the switch: after stallAfter');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fake.closed, ['stuck']);
    expect([for (final c in fake.conns) c['id']], ['moving', 'other']);
    expect(auto.toJson()['stalledClosed'], 1);
    auto.stop();
  });
}


class _Dead implements ClashApi {
  @override
  Future<Map<String, dynamic>?> clashGet(String path, {Duration timeout = const Duration(seconds: 2)}) async => null;
  @override
  Future<int?> clashPut(String path, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 2)}) async => null;
  @override
  Future<int?> clashDelete(String path, {Duration timeout = const Duration(seconds: 2)}) async => null;
}
