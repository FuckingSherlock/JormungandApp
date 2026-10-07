// AutoService against a fake sing-box API service (BoxControl, sbapi.dart). The fake is
// built from the real config (buildConfig), so the tags the service switches are the ones
// sing-box would get; it acts like sing-box: a delay test goes through a group to the
// server it uses now, a chain's exit through its entry group, a group test (testGroup) has
// a urltest pick again.
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
  final tested = <String>[]; // servers a delay test was asked for, and 'group:<tag>' for a group test
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

  void _repick(FakeGroup g) {
    String? best;
    for (final m in g.all) {
      final d = _delayOf(m);
      if (d >= 0 && (best == null || d < _delayOf(best))) best = m;
    }
    if (best != null) g.now = best;
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
  Future<Map<String, int>?> testGroup(String group, {String? leaving, required Duration timeout}) async {
    final g = groups[group];
    if (g == null) return null;
    tested.add('group:$group');
    final res = <String, int>{};
    for (final m in g.all) {
      final d = _delayOf(m);
      if (d >= 0) res[m] = d;
    }
    if (g.type == 'urltest') _repick(g);
    _changedCtl.add(null);
    return res;
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

(AutoService, FakeBox) setup(Map<String, dynamic> p, Map<String, int> alive) {
  final fake = FakeBox(buildConfig(p), alive);
  return (AutoService(fake, p, delay: fake.delayTest), fake);
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

  test('Fastest: a silent server is replaced inside the route at once, no route switch', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2', 's::a3']), unit('B', ['s::b1'])]), {'s::a1': 40, 's::a2': 80, 's::b1': 30});
    await auto.check();
    expect(auto.toJson()['server'], 's::a1');
    fake.alive.remove('s::a1');
    await auto.check();
    final j = auto.toJson();
    // no route switch (still A), but the heal's own refresh() sees the group moved and
    // counts it as a switch too — refresh() cannot tell a heal's own pick from sing-box
    // re-picking on its own (the 'refresh(): a Fastest group…' test below)
    expect([j['now'], j['server'], j['switches'], j['noNet']], ['A', 's::a2', 1, false]);
    expect((j['lastSwitch'] as Map)['reason'], 'fastest');
    expect((j['routes'] as List).first['fails'], 0);
    expect(fake.tested, contains('group:route0'));
    // the group test's silent servers are misses too (the app's ping cache learns them), one each
    final m = {for (final e in (j['members'] as List).cast<Map>()) e['key']: [e['ms'], e['fails']]};
    expect([m['s::a1'], m['s::a2'], m['s::a3']], [[-1, 1], [80, 0], [-1, 1]]);
  });

  test('refresh(): a Fastest group that moved on its own (urltest re-pick) is a switch, reason fastest', () async {
    final (auto, fake) = setup(plan([unit('A', ['s::a1', 's::a2'])]), {'s::a1': 40, 's::a2': 80});
    await auto.check();
    expect(auto.toJson()['server'], 's::a1');
    final events = <AutoSwitch>[];
    auto.switches.listen(events.add);
    fake.groups['route0']!.now = 'route0/s::a2'; // sing-box re-picked on its own (not through AutoService)
    final again = await auto.refresh();
    expect(again, isTrue);
    expect(auto.toJson()['server'], 's::a2');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect([events.single.route, events.single.from, events.single.to, events.single.reason], ['A', 's::a1', 's::a2', 'fastest']);
    expect(events.single.isRoute, isFalse);
  });

  test('refresh(): false before sing-box first answers (selected empty)', () async {
    final auto = AutoService(_Dead(), plan([unit('A', ['s::a'])]), delay: (tag, url, t) async => -1);
    expect(await auto.refresh(), isFalse);
  });

  test('BoxControl.testGroup: only the members that answered are in the result, picks the fastest of them, notifies groupsChanged', () async {
    final (_, fake) = setup(plan([unit('A', ['s::a1', 's::a2', 's::a3'])]), {'s::a1': 40, 's::a2': 20});
    final changed = <void>[];
    fake.groupsChanged.listen(changed.add);
    final res = await fake.testGroup('route0', leaving: 'route0/s::a1', timeout: const Duration(seconds: 1));
    expect(res, {'route0/s::a1': 40, 'route0/s::a2': 20});
    expect(fake.groups['route0']!.now, 'route0/s::a2', reason: 'the fastest among the ones that answered');
    await Future<void>.delayed(Duration.zero);
    expect(changed, hasLength(1));
    expect(await fake.testGroup('no-such-group', timeout: const Duration(seconds: 1)), isNull);
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
    j = auto.toJson();
    expect([j['entryServer'], (j['routes'] as List).first['fails'], (j['routes'] as List).first['ms']], ['s::e2', 0, 70]);
    final keys = [for (final m in (j['members'] as List).cast<Map>()) m['key']];
    expect(keys, containsAll(['s::e1', 's::e2']));
    expect(keys, isNot(contains('s::x')));
    final e1 = (j['members'] as List).cast<Map>().firstWhere((m) => m['key'] == 's::e1');
    expect([e1['ms'], e1['fails']], [-1, 1]);
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
    ClosedConnection cc({String outbound = 'route0/s::a', List<String> chain = const ['route0/s::a', 'route0', 'proxy'], String dest = 'blocked.example:443', int up = 120, int down = 0, String rule = '', String process = ''}) =>
        ClosedConnection(outbound: outbound, chain: chain, destination: dest, up: up, down: down, rule: rule, process: process);

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

    test('a node that answers again: the failed site is reachable through it now — no AutoBlocked', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      var t = 0;
      final reached = <(String, String)>[];
      Future<bool?> reach(String tag, String dest) async {
        reached.add((tag, dest));
        return true; // the site opens through A again: a one-off, nothing to report
      }

      final events = <AutoBlocked>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, reach: reach, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.blocked.listen(events.add);
      await auto.check();
      auto.onClosed(cc());
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reached, [('route0/s::a', 'blocked.example:443')]);
      expect(auto.blockedCount, 0);
      expect(events, isEmpty);
    });

    test('a node that answers again: the site stays unreachable through it, opens through another route — AutoBlocked, once an hour', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      var t = 0;
      Future<bool?> reach(String tag, String dest) async => tag == 'route0/s::a' ? false : true;
      final events = <AutoBlocked>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => t, reach: reach, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.blocked.listen(events.add);
      await auto.check();
      auto.onClosed(cc());
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(auto.blockedCount, 1);
      expect(auto.lastBlocked?.toJson(), {'route': 'A', 'server': 's::a', 'dest': 'blocked.example:443', 'via': 'B', 'viaServer': 's::b', 'rule': '', 'process': '', 'at': 0});
      expect(events.length, 1);

      // the same route + site again, still within the hour: not reported again
      t += 5000;
      auto.onClosed(cc());
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(auto.blockedCount, 1);
      expect(events.length, 1);
    });

    // Right after a start sing-box tells no member of a urltest yet, so a failed connection
    // names the GROUP (`route0`): the probe inbound has no user for a group — the site test
    // must go to the member in use, or not run at all, never "fail" on a refusal.
    test('the failed connection names the route group: the site test goes to the member in use', () async {
      final p = plan([unit('A', ['s::a', 's::a2']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 50, 's::a2': 20, 's::b': 60});
      final asked = <String>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) async {
        asked.add(tag);
        return true;
      }, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      await auto.check();
      auto.onClosed(cc(outbound: 'route0', chain: const ['route0', 'proxy']));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, ['route0/s::a2']);
    });

    test('the failed connection names the route group, the member in use is unknown: no site test, no claim', () async {
      final p = plan([unit('A', ['s::a', 's::a2']), unit('B', ['s::b'])]);
      final fake = _NoUrltestNow(buildConfig(p), {'s::a': 30, 's::a2': 40, 's::b': 60}); // urltest.Now() = ""
      final asked = <String>[];
      final events = <Object>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) async {
        asked.add(tag);
        return false; // would be taken for "does not open" were it asked
      }, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.blocked.listen(events.add);
      auto.unreachable.listen(events.add);
      await auto.check();
      auto.onClosed(cc(outbound: 'route0', chain: const ['route0', 'proxy']));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, isEmpty);
      expect(events, isEmpty);
      expect(auto.blockedCount + auto.unreachableCount, 0);
    });

    test('the failed connection names something that is no server of the route (a stranger tag): skipped', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60});
      final asked = <String>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, clock: () => 0, reach: (tag, dest) async {
        asked.add(tag);
        return true;
      }, settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      await auto.check();
      auto.onClosed(cc(outbound: 'route0/nope', chain: const ['route0/nope', 'route0', 'proxy']));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, isEmpty);
    });

    // A current; B, C, D, E answer, so any of them may be tried
    (AutoService, FakeBox, List<(String, String)>, List<AutoBlocked>, List<AutoUnreachable>, List<String>) five(Future<bool?> Function(String, String) reach,
        {String? siteRetry, int Function()? clock}) {
      final p = plan([for (final k in ['a', 'b', 'c', 'd', 'e']) unit(k.toUpperCase(), ['s::$k'])], auto: {'standby': 5, 'siteRetry': ?siteRetry});
      final fake = FakeBox(buildConfig(p), {'s::a': 30, 's::b': 60, 's::c': 70, 's::d': 80, 's::e': 90});
      final asked = <(String, String)>[], notes = <String>[];
      final blocked = <AutoBlocked>[], gone = <AutoUnreachable>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          clock: clock ?? () => 0,
          reach: (tag, dest) {
            asked.add((tag, dest));
            return reach(tag, dest);
          },
          note: notes.add,
          settings: AutoSettings.fromPlan(p));
      auto.blocked.listen(blocked.add);
      auto.unreachable.listen(gone.add);
      return (auto, fake, asked, blocked, gone, notes);
    }

    Future<void> fail(AutoService auto) async {
      auto.onClosed(cc());
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('the site opens on the 2nd other route: AutoBlocked with that route, the ones after it are not tried', () async {
      final (auto, _, asked, blocked, gone, _) = five((tag, dest) async => tag == 'route2/s::c');
      await auto.check();
      await fail(auto);
      expect(asked.map((a) => a.$1), ['route0/s::a', 'route1/s::b', 'route2/s::c']);
      expect(blocked.length, 1);
      expect(blocked.single.toJson(), {'route': 'A', 'server': 's::a', 'dest': 'blocked.example:443', 'via': 'C', 'viaServer': 's::c', 'rule': '', 'process': '', 'at': 0});
      expect(gone, isEmpty);
    });

    test('opens through no other route: AutoUnreachable lists the routes tried (the first 3), once an hour', () async {
      var t = 0;
      final (auto, _, asked, blocked, gone, notes) = five((tag, dest) async => false, clock: () => t);
      await auto.check();
      await fail(auto);
      expect(asked.map((a) => a.$1), ['route0/s::a', 'route1/s::b', 'route2/s::c', 'route3/s::d'], reason: 'at most 3 other routes');
      expect(blocked, isEmpty);
      expect(gone.length, 1);
      expect(auto.unreachableCount, 1);
      expect(gone.single.toJson(), {
        'route': 'A',
        'server': 's::a',
        'dest': 'blocked.example:443',
        'tried': [
          {'route': 'B', 'server': 's::b'},
          {'route': 'C', 'server': 's::c'},
          {'route': 'D', 'server': 's::d'},
        ],
        'retriesOff': false,
        'rule': '',
        'process': '',
        'at': 0,
      });
      expect(notes.any((n) => n.contains('down or blocked everywhere')), isTrue);

      t += 20000; // the same route + site within the hour: the note again, no second event
      await fail(auto);
      expect(gone.length, 1);
      t += 3600000; // after the hour: reported again
      await fail(auto);
      expect(gone.length, 2);
      expect(auto.toJson()['unreachable'], 2);
    });

    test('no other route answers: AutoUnreachable with an empty tried list', () async {
      final p = plan([unit('A', ['s::a']), unit('B', ['s::b'])]);
      final fake = FakeBox(buildConfig(p), {'s::a': 30}); // B is dead
      final gone = <AutoUnreachable>[];
      final asked = <String>[];
      final auto = AutoService(fake, p,
          delay: fake.delayTest,
          reach: (tag, dest) async {
            asked.add(tag);
            return false;
          },
          settings: const AutoSettings(failWindow: Duration(seconds: 10)));
      auto.unreachable.listen(gone.add);
      await auto.check();
      await fail(auto);
      expect(asked, ['route0/s::a']);
      expect(gone.length, 1);
      expect(gone.single.tried, isEmpty);
      expect(gone.single.retriesOff, isFalse);
    });

    test('both events carry the rule sing-box matched and the app of the failed request; no rule = ""', () async {
      // blocked: the site opens through B only
      final (auto, _, _, blocked, _, _) = five((tag, dest) async => tag == 'route1/s::b');
      await auto.check();
      auto.onClosed(cc(rule: 'domain_suffix=blocked.example', process: r'C:\Apps\Discord\Discord.exe'));
      await auto.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(blocked.single.rule, 'domain_suffix=blocked.example');
      expect(blocked.single.process, r'C:\Apps\Discord\Discord.exe');
      expect(auto.lastBlocked!.toJson()['rule'], 'domain_suffix=blocked.example');

      // unreachable: two sites in one window, each keeps its own rule / app (the second has none)
      final (auto2, _, _, _, gone, _) = five((tag, dest) async => false);
      await auto2.check();
      auto2.onClosed(cc(dest: 'a.example:443', rule: 'process_name=tg.exe', process: '/usr/bin/tg.exe'));
      auto2.onClosed(cc(dest: 'a.example:443', rule: 'process_name=tg.exe', process: '/usr/bin/tg.exe'));
      await auto2.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gone.single.dest, 'a.example:443');
      expect(gone.single.rule, 'process_name=tg.exe');
      expect(gone.single.process, '/usr/bin/tg.exe');
      expect(gone.single.toJson()['process'], '/usr/bin/tg.exe');

      final (auto3, _, _, _, gone3, _) = five((tag, dest) async => false);
      await auto3.check();
      await fail(auto3);
      expect(gone3.single.rule, '');
      expect(gone3.single.process, '');
    });

    test('siteRetry: off — no request through other routes, AutoUnreachable says the retries are off; all — every route up to the first that opens', () async {
      final (off, _, askedOff, blockedOff, goneOff, notesOff) = five((tag, dest) async => tag != 'route0/s::a', siteRetry: 'off');
      await off.check();
      await fail(off);
      expect(askedOff.map((a) => a.$1), ['route0/s::a']);
      expect(blockedOff, isEmpty);
      expect(goneOff.single.tried, isEmpty);
      expect(goneOff.single.retriesOff, isTrue);
      expect(notesOff.any((n) => n.contains('retries through other routes are off')), isTrue);

      final (all, _, askedAll, blockedAll, goneAll, _) = five((tag, dest) async => tag == 'route4/s::e', siteRetry: 'all');
      await all.check();
      await fail(all);
      expect(askedAll.map((a) => a.$1), ['route0/s::a', 'route1/s::b', 'route2/s::c', 'route3/s::d', 'route4/s::e']);
      expect(blockedAll.single.via, 'E');
      expect(goneAll, isEmpty);
    });

    test('an alternate that cannot be tried (null) is not a claim: nothing tried for sure — no event, a note only', () async {
      final (auto, _, asked, blocked, gone, _) = five((tag, dest) async => tag == 'route0/s::a' ? false : null);
      await auto.check();
      await fail(auto);
      expect(asked.length, 4);
      expect(blocked, isEmpty);
      expect(gone, isEmpty);
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
}

/// sing-box 1.14 before the first urltest round: `Now()` is "", so no member is reported.
class _NoUrltestNow extends FakeBox {
  _NoUrltestNow(super.config, super.alive);

  @override
  Map<String, String> get selected => {
        for (final e in super.selected.entries)
          if (groups[e.key]?.type != 'urltest') e.key: e.value,
      };
}

class _Dead implements BoxControl {
  @override
  Map<String, String> get selected => {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => false;
  @override
  Future<Map<String, int>?> testGroup(String group, {String? leaving, required Duration timeout}) async => null;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => false;
}
