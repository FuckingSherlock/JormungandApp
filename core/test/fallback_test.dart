// FallbackService ("If unavailable" live, fallback.dart) against the fake sing-box of
// auto_test.dart, built from the real config: the selectors [target, fallback] the routing
// makes are the ones the service flips.
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, chain, unit;

LiveConnection _conn(String id, List<String> chain, {int up = 0, int down = 0}) =>
    LiveConnection(Connection(id: id, chainList: chain, uplinkTotal: Int64(up), downlinkTotal: Int64(down)));

Map<String, dynamic> _rule(String id, String target, String fallback, {String name = ''}) => {
      'id': id,
      'name': name,
      'on': true,
      'action': 'proxy',
      'target': target,
      'fallback': fallback,
      'dns': 'auto',
      'groups': {
        'domain': {'not': false, 'v': {'domain_suffix': ['$id.test']}},
      },
    };

Map<String, dynamic> _plan(List<Map<String, dynamic>> rules, {Map<String, Map<String, dynamic>>? targets}) => {
      'routes': [unit('A', ['s::a'])],
      'current': 0,
      'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
      'routing': {
        'fallback': 'main',
        'targets': targets ??
            {
              'src:x': unit('src:x', ['s::x1', 's::x2']),
              'src:p': unit('src:p', ['s::p1', 's::p2'], pick: 'priority', chosen: 's::p1'),
              'chain:c': chain('chain:c', ['s::e'], ['s::t']),
            },
        'rules': rules,
      },
    };

class _Rig {
  _Rig(Map<String, dynamic> plan, Map<String, int> alive,
      {AutoSettings? settings,
      bool uncertain = false,
      int Function()? clock,
      void Function(String groupTag, String key)? onDown,
      void Function(TargetFallback s, bool on)? setFlag,
      List<Duration> steps = const [Duration.zero]}) {
    // a zero ladder: a dead target is asked every round (the ladder itself: ladder_test.dart and the test of its own below)
    pool = ProbePool.solo(clock: clock, ladder: DeadLadder(steps: steps));
    final info = RoutingInfo();
    fake = FakeBox(buildConfig(plan, info: info), alive);
    this.uncertain = uncertain;
    svc = FallbackService(fake, info.fallbacks,
        delay: fake.delayTest,
        settings: settings ?? const AutoSettings(failAfter: 2, flapGuard: false, stallAfter: Duration(milliseconds: 30)),
        pool: pool,
        clock: clock,
        onDown: onDown,
        setFlag: setFlag);
    svc.changes.listen(changes.add);
  }

  late final FakeBox fake;
  late final FallbackService svc;
  late final ProbePool pool; // the network status Auto would write: a doubt / the OS offline
  set uncertain(bool v) => pool.doubt(v);
  set offline(bool v) => pool.offline(v);
  final changes = <FallbackChange>[];

  String on(String selector) => fake.groups[selector]!.now!;
}

void main() {
  test('config: a selector per (target, fallback), the target is its default, sing-box never interrupts', () {
    final info = RoutingInfo();
    final c = buildConfig(_plan([_rule('r1', 'src:x', 'block'), _rule('r2', 'src:x', 'direct'), _rule('r3', 'chain:c', 'default')]), info: info);
    expect([for (final f in info.fallbacks) f.tag], ['src:x~block', 'src:x~direct', 'chain:c~proxy']);
    final outs = {for (final o in (c['outbounds'] as List).cast<Map>()) o['tag']: o};
    expect(outs['src:x~block'], containsPair('default', 'src:x'));
    expect(outs['src:x~block'], containsPair('interrupt_exist_connections', false));
    expect(outs['block'], {'type': 'block', 'tag': 'block'});
  });

  test('a target that misses failAfter times in a row goes to its fallback, all its selectors at once', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block', name: 'Video'), _rule('r2', 'src:x', 'direct')]), {'s::x1': 40, 's::x2': 60});
    await r.svc.check();
    expect([r.on('src:x~block'), r.on('src:x~direct')], ['src:x', 'src:x']);
    r.fake.alive.clear();
    await r.svc.check();
    expect(r.on('src:x~block'), 'src:x', reason: 'one miss is not enough with failAfter 2');
    expect(r.svc.isDown('src:x'), isFalse);
    await r.svc.check();
    expect([r.on('src:x~block'), r.on('src:x~direct')], ['block', 'direct']);
    expect(r.svc.isDown('src:x'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in r.changes) '${c.target}>${c.to} ${c.rules.join('/')} ${c.back}'], ['src:x>block Video false', 'src:x>direct rule r2 false']);
  });

  test('the Direct flag: on before the selector moves to direct, off after it is back; block selectors have none', () async {
    late _Rig r;
    final log = <String>[];
    r = _Rig(_plan([_rule('r1', 'src:x', 'block'), _rule('r2', 'src:x', 'direct')]), {'s::x1': 40, 's::x2': 60},
        setFlag: (s, on) => log.add('${s.tag} ${on ? 'on' : 'off'} while on ${r.fake.groups[s.tag]!.now}'));
    await r.svc.check();
    expect(log, ['src:x~direct off while on src:x'], reason: 'the first look writes what sing-box says; only the Direct selector has a flag');
    await r.svc.check();
    expect(log, hasLength(1), reason: 'nothing changed: nothing written');
    r.fake.alive.clear();
    await r.svc.check();
    expect(log, hasLength(1), reason: 'one miss');
    await r.svc.check();
    expect(r.on('src:x~direct'), 'direct');
    expect(log.last, 'src:x~direct on while on src:x', reason: 'the flag is up while the selector still sits on the target');
    expect(log, hasLength(2));
    r.fake.alive.addAll({'s::x1': 40, 's::x2': 60});
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:x~direct'), 'src:x');
    expect(log.last, 'src:x~direct off while on src:x', reason: 'the flag goes down after the selector is back');
    expect(log, hasLength(3));
  });

  test('onDown: a target whose current server missed failAfter times names that server (a chain: the entry and the exit)', () async {
    final down = <String>[];
    final r = _Rig(_plan([_rule('r1', 'src:p', 'block'), _rule('r2', 'chain:c', 'block')]), {'s::p1': 40, 's::p2': 60, 's::e': 30, 's::t': 30},
        onDown: (tag, key) => down.add('$tag/$key'));
    await r.svc.check();
    expect(down, isEmpty);
    r.fake.alive.clear();
    await r.svc.check();
    expect(down, isEmpty, reason: 'one miss is not enough with failAfter 2');
    await r.svc.check();
    expect(down, containsAll(['src:p/s::p1', 'chain:c>entry/s::e', 'chain:c/s::t']));
  });

  test('a Fastest group whose server missed failAfter times moves to the fastest answering one: the target stays', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {'s::x1': 40, 's::x2': 60});
    await r.svc.check();
    r.fake.alive.remove('s::x1');
    await r.svc.check();
    expect(r.fake.groups['src:x']!.now, 'src:x/s::x1', reason: 'one miss is not enough with failAfter 2');
    await r.svc.check();
    expect(r.fake.groups['src:x']!.now, 'src:x/s::x2', reason: 'the second miss: the core picks the fastest answering one');
    expect(r.on('src:x~block'), 'src:x');
    expect(r.svc.isDown('src:x'), isFalse);
    expect(r.changes, isEmpty);
  });

  test('a Priority group is never moved; its server missing takes the target down', () async {
    final r = _Rig(_plan([_rule('r1', 'src:p', 'block')]), {'s::p1': 40, 's::p2': 60});
    await r.svc.check();
    r.fake.alive.remove('s::p1');
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:p~block'), 'block');
    expect(r.fake.groups['src:p']!.now, 'src:p/s::p1', reason: 'the user\'s choice stays');
  });

  test('back after failAfter answers in a row, the open connections are kept', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {});
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:x~block'), 'block');
    r.fake.alive.addAll({'s::x1': 40, 's::x2': 60});
    await r.svc.check();
    expect(r.on('src:x~block'), 'block', reason: 'one answer is not enough');
    await r.svc.check();
    expect(r.on('src:x~block'), 'src:x');
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in r.changes) '${c.to} ${c.back}'], ['block false', 'block true']);
    expect(r.fake.closed, isEmpty);
  });

  test('flap guard: a target that dropped waits the hold, 1 minute the first time, with no miss', () async {
    var now = 1000000;
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {},
        settings: const AutoSettings(failAfter: 2, flapGuard: true, stallAfter: Duration(milliseconds: 30)), clock: () => now);
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:x~block'), 'block');
    r.fake.alive.addAll({'s::x1': 40, 's::x2': 60});
    for (var i = 0; i < 3; i++) {
      now += 5000;
      await r.svc.check();
    }
    expect(r.on('src:x~block'), 'block', reason: 'answers, but the hold is not served');
    now += 61000;
    await r.svc.check();
    expect(r.on('src:x~block'), 'src:x');
    // it dropped again: the hold doubles
    r.fake.alive.clear();
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:x~block'), 'block');
    r.fake.alive.addAll({'s::x1': 40});
    now += 1000;
    await r.svc.check();
    now += 70000;
    await r.svc.check();
    expect(r.on('src:x~block'), 'block', reason: 'the second hold is 2 minutes');
    now += 60000;
    await r.svc.check();
    expect(r.on('src:x~block'), 'src:x');
  });

  test('nothing is judged while the network may be down', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {}, uncertain: true);
    for (var i = 0; i < 4; i++) {
      await r.svc.check();
    }
    expect(r.on('src:x~block'), 'src:x');
    expect(r.fake.tested, isEmpty);
    r.uncertain = false;
    await r.svc.check();
    await r.svc.check();
    expect(r.on('src:x~block'), 'block');
  });

  test('starts from what sing-box says (cache_file kept a fallback across a restart): back when it answers', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'direct')]), {'s::x1': 40});
    r.fake.groups['src:x~direct']!.now = 'direct';
    await r.svc.check();
    expect(r.svc.isDown('src:x'), isTrue);
    await r.svc.check();
    expect(r.on('src:x~direct'), 'src:x');
    expect(r.svc.isDown('src:x'), isFalse);
  });

  test('a chain target is tested at its exit through its entry: a dead entry takes it down', () async {
    final r = _Rig(_plan([_rule('r1', 'chain:c', 'default')]), {'s::e': 30, 's::t': 50});
    await r.svc.check();
    expect(r.on('chain:c~proxy'), 'chain:c');
    r.fake.alive.remove('s::e');
    await r.svc.check();
    await r.svc.check();
    expect(r.on('chain:c~proxy'), 'proxy', reason: 'the main flow');
    final j = r.svc.toJson()['targets'] as List;
    expect(j.single, containsPair('down', true));
  });

  test('after a switch to the fallback only the stalled connections through the target are closed', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {'s::x1': 40, 's::x2': 60});
    r.fake.conns.addAll([
      _conn('moving', ['src:x/s::x1', 'src:x', 'src:x~block'], up: 1, down: 10),
      _conn('stuck', ['src:x/s::x1', 'src:x', 'src:x~block'], up: 1, down: 10),
      _conn('other', ['direct']),
    ]);
    r.fake.onConnections = () => r.fake.conns.firstWhere((c) => c.id == 'moving').down += 1;
    await r.svc.check();
    r.fake.alive.clear();
    await r.svc.check();
    await r.svc.check();
    expect(r.fake.closed, isEmpty, reason: 'not at the switch: after stallAfter');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(r.fake.closed, ['stuck']);
    r.svc.stop();
  });

  test('a config with no target to fall back from has nothing to watch', () {
    final info = RoutingInfo();
    buildConfig(_plan([_rule('r1', '', 'default')]), info: info);
    expect(info.fallbacks, isEmpty);
    final svc = FallbackService(FakeBox(buildConfig(_plan([])), {}), info.fallbacks, delay: (a, b, c) async => 0, settings: const AutoSettings());
    expect(svc.isEmpty, isTrue);
  });

  group('a target as the fallback', () {
    Map<String, dynamic> two(List<Map<String, dynamic>> rules) => _plan(rules, targets: {
          'src:a': unit('src:a', ['s::a1']),
          'src:b': unit('src:b', ['s::b1']),
        });
    Map<String, int> alive() => {'s::a1': 20, 's::b1': 30};
    String sel(_Rig r) => r.on('src:a~src:b');

    test('config: [target, fallback target, main flow]; the fallback target is watched too', () async {
      final r = _Rig(two([_rule('r1', 'src:a', 'src:b', name: 'Video')]), alive());
      expect(r.fake.groups['src:a~src:b']!.all, ['src:a', 'src:b', 'proxy']);
      await r.svc.check();
      expect(r.fake.tested, containsAll(['src:a/s::a1', 'src:b/s::b1']));
      expect([for (final t in r.svc.toJson()['targets'] as List) (t as Map)['target']], ['src:a', 'src:b']);
    });

    test('a dead target is asked on the ladder: one light request per step, not every round; it answers: back', () async {
      var t = 0;
      final r = _Rig(two([_rule('r1', 'src:a', 'src:b')]), alive(), clock: () => t, steps: deadLadderSteps);
      int asked() => r.fake.tested.where((x) => x.contains('s::a1')).length;
      await r.svc.check();
      r.fake.alive.remove('s::a1');
      t = 1000;
      await r.svc.check();
      t = 2000;
      await r.svc.check();
      expect(sel(r), 'src:b');
      final before = asked();
      t = 30 * 1000;
      await r.svc.check();
      expect(asked(), before, reason: 'the first step (1 min) is not over');
      t = 2000 + 60 * 1000;
      await r.svc.check();
      expect(asked(), before + 1, reason: 'one request on its turn');
      r.fake.alive['s::a1'] = 20;
      t += 60 * 1000;
      await r.svc.check();
      expect(asked(), before + 1, reason: 'the second step is 2 min');
      t += 60 * 1000;
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'src:a', reason: 'it answered on its turn and goes back');
      expect(r.pool.ladder.length, 0);
    });

    test('the target down: the fallback target; both down: the main flow; back step by step, journalled', () async {
      final r = _Rig(two([_rule('r1', 'src:a', 'src:b', name: 'Video')]), alive());
      await r.svc.check();
      r.fake.alive.remove('s::a1');
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'src:b');
      r.fake.alive.remove('s::b1');
      await r.svc.check();
      expect(sel(r), 'src:b', reason: 'one miss is not enough');
      await r.svc.check();
      expect(sel(r), 'proxy', reason: 'both down: the main flow');
      expect([r.svc.isDown('src:a'), r.svc.isDown('src:b')], [true, true]);
      // the fallback target answers again: it takes the traffic from the main flow
      r.fake.alive['s::b1'] = 30;
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'src:b');
      // the target answers again: back to it
      r.fake.alive['s::a1'] = 20;
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'src:a');
      await Future<void>.delayed(Duration.zero);
      expect([for (final c in r.changes) '${c.target}>${c.to} ${c.rules.join('/')} ${c.back}'],
          ['src:a>src:b Video false', 'src:a>main Video false', 'src:a>src:b Video true']);
    });

    test('both die in one round: one move, straight to the main flow', () async {
      final r = _Rig(two([_rule('r1', 'src:a', 'src:b')]), alive());
      await r.svc.check();
      r.fake.alive.clear();
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'proxy');
      await Future<void>.delayed(Duration.zero);
      expect([for (final c in r.changes) '${c.to} ${c.back}'], ['main false']);
    });

    test('the target answers again while the fallback target is down: straight back, from the main flow', () async {
      final r = _Rig(two([_rule('r1', 'src:a', 'src:b')]), {});
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'proxy');
      r.fake.alive['s::a1'] = 20;
      await r.svc.check();
      await r.svc.check();
      expect(sel(r), 'src:a');
      await Future<void>.delayed(Duration.zero);
      expect([for (final c in r.changes) '${c.to} ${c.back}'], ['main false', 'main true']);
    });

    test('a chain as the fallback target is tested at its exit through its entry', () async {
      final r = _Rig(
          _plan([_rule('r1', 'src:a', 'chain:c')], targets: {
            'src:a': unit('src:a', ['s::a1']),
            'chain:c': chain('chain:c', ['s::e'], ['s::t']),
          }),
          {'s::a1': 20, 's::e': 10, 's::t': 15});
      await r.svc.check();
      expect(r.fake.tested, contains('chain:c/s::t'));
      r.fake.alive.remove('s::a1');
      await r.svc.check();
      await r.svc.check();
      expect(r.on('src:a~chain:c'), 'chain:c');
    });
  });

  group('the main flow as the target', () {
    Map<String, dynamic> app(String fallback) => {
          'routes': [unit('A', ['s::a'])],
          'current': 0,
          'auto': {'failAfter': 2, 'checkEvery': 60, 'flapGuard': false},
          'routing': {
            'fallback': 'main',
            'targets': {'src:b': unit('src:b', ['s::b1'])},
            'apps': [
              {'id': 'com.x', 'kind': 'package', 'name': 'X', 'act': 'default', 'fallback': fallback},
            ],
          },
        };
    Map<String, int> alive() => {'s::a': 20, 's::b1': 30, 'direct': 5};

    test('config: the selector [proxy, fallback target], the main flow its default; the fallback target is watched', () async {
      final r = _Rig(app('src:b'), alive());
      expect(r.fake.groups['proxy~src:b']!.all, ['proxy', 'src:b']);
      expect(r.on('proxy~src:b'), 'proxy');
      await r.svc.check();
      expect(r.fake.tested.where((t) => t.endsWith('s::a')), isNotEmpty, reason: 'the main flow is tested at its server');
      expect(r.fake.tested, contains('src:b/s::b1'));
    });

    test('the main flow dies while the network is up (direct answers): the fallback; Auto doubting the network does not stop it', () async {
      final r = _Rig(app('block'), alive(), uncertain: true);
      await r.svc.check();
      r.fake.alive.remove('s::a');
      await r.svc.check();
      expect(r.on('proxy~block'), 'proxy', reason: 'one miss is not enough');
      await r.svc.check();
      expect(r.on('proxy~block'), 'block');
      expect(r.svc.isDown('proxy'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect([for (final c in r.changes) '${c.target}>${c.to} ${c.rules}|${c.apps} ${c.back}'], ['proxy>block []|[X] false']);
      r.fake.alive['s::a'] = 20;
      await r.svc.check();
      await r.svc.check();
      expect(r.on('proxy~block'), 'proxy');
      await Future<void>.delayed(Duration.zero);
      expect(r.changes.last.back, isTrue);
    });

    test('a dead network is not a dead main flow: nothing answers, nothing is judged; neither is an offline OS', () async {
      final r = _Rig(app('block'), alive(), uncertain: true);
      await r.svc.check();
      r.fake.alive.clear();
      for (var i = 0; i < 4; i++) {
        await r.svc.check();
      }
      expect(r.on('proxy~block'), 'proxy');
      expect(r.svc.isDown('proxy'), isFalse);
      r.fake.alive['direct'] = 5;
      r.offline = true;
      for (var i = 0; i < 4; i++) {
        await r.svc.check();
      }
      expect(r.on('proxy~block'), 'proxy', reason: 'offline');
      r.offline = false;
      await r.svc.check();
      await r.svc.check();
      expect(r.on('proxy~block'), 'block', reason: 'online again, only the main flow is dead');
    });

    test('a fallback target answering tells a dead main flow from a dead network even with direct down', () async {
      final r = _Rig(app('src:b'), {'s::a': 20, 's::b1': 30});
      await r.svc.check();
      r.fake.alive.remove('s::a');
      await r.svc.check();
      await r.svc.check();
      expect(r.on('proxy~src:b'), 'src:b');
    });

    test('with the fallback target down too the selector stays on it (nothing is better)', () async {
      final r = _Rig(app('src:b'), alive());
      await r.svc.check();
      r.fake.alive.remove('s::a');
      await r.svc.check();
      await r.svc.check();
      expect(r.on('proxy~src:b'), 'src:b');
      r.fake.alive.remove('s::b1');
      for (var i = 0; i < 3; i++) {
        await r.svc.check();
      }
      expect(r.on('proxy~src:b'), 'src:b');
    });
  });
}
