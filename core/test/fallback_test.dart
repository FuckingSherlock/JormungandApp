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
  _Rig(Map<String, dynamic> plan, Map<String, int> alive, {AutoSettings? settings, this.uncertain = false, int Function()? clock}) {
    final info = RoutingInfo();
    fake = FakeBox(buildConfig(plan, info: info), alive);
    svc = FallbackService(fake, info.fallbacks,
        delay: fake.delayTest,
        settings: settings ?? const AutoSettings(failAfter: 2, flapGuard: false, stallAfter: Duration(milliseconds: 30)),
        networkUncertain: () => uncertain,
        clock: clock);
    svc.changes.listen(changes.add);
  }

  late final FakeBox fake;
  late final FallbackService svc;
  bool uncertain;
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

  test('a Fastest group whose server missed is tested again first: another server answering keeps the target', () async {
    final r = _Rig(_plan([_rule('r1', 'src:x', 'block')]), {'s::x1': 40, 's::x2': 60});
    await r.svc.check();
    r.fake.alive.remove('s::x1');
    await r.svc.check();
    await r.svc.check();
    expect(r.fake.tested, contains('group:src:x'));
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
    expect(r.fake.tested.where((t) => t.startsWith('group:')), isEmpty);
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
    buildConfig(_plan([_rule('r1', '', 'block')]), info: info);
    expect(info.fallbacks, isEmpty);
    final svc = FallbackService(FakeBox(buildConfig(_plan([])), {}), info.fallbacks, delay: (a, b, c) async => 0, settings: const AutoSettings());
    expect(svc.isEmpty, isTrue);
  });
}
