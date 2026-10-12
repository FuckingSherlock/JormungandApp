// DnsFailover (dns_failover.dart) with a fake clash mode and fake DNS queries, the Sentinel judging the misses
// (time by hand): a miss is evidence for `dns.down`, the failover acts on the verdicts.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Rig {
  _Rig(
    List<String> ids, {
    AutoSettings? settings,
    bool auto = true,
    bool uncertain = false,
    Set<String> vpn = const {},
    List<String> watch = const [],
    this.refuseMode = false,
  }) {
    this.uncertain = uncertain;
    alive = {for (final id in [...ids, ...watch]) 'dns-$id': 20};
    book = EventBook(null, clock: () => time.t);
    sentinel = Sentinel(clock: time.clock, book: book);
    svc = DnsFailover(
      [for (final id in ids) (id: id, tag: 'dns-$id')],
      watch: [for (final id in watch) (id: id, tag: 'dns-$id')],
      vpn: vpn,
      setMode: (m) async {
        if (refuseMode) return false;
        modes.add(m);
        return true;
      },
      query: (tag, name, t) async {
        asked.add('$tag $name');
        return alive[tag] ?? -1;
      },
      settings: settings ?? const AutoSettings(failAfter: 2, flapGuard: false),
      sentinel: sentinel,
      window: window,
      auto: auto,
      pool: pool,
      clock: () => time.t.millisecondsSinceEpoch,
    );
    svc.switches.listen(switches.add);
  }

  final time = FakeTime();
  late final Sentinel sentinel;
  late final EventBook book;
  late final DnsFailover svc;
  late final Map<String, int> alive;
  final window = const Duration(seconds: 1);
  final modes = <String>[];
  final asked = <String>[];
  final switches = <DnsSwitch>[];
  bool refuseMode;
  final pool = ProbePool.solo();
  set uncertain(bool v) => pool.doubt(v); // Auto doubting the network: the status is `unknown`

  /// The core is up and settled (the failover switches only then).
  Future<void> settle() async {
    sentinel.context.starting('test');
    sentinel.context.started();
    await time.advanceSeconds(6);
  }

  /// A round, and the Sentinel's and the failover's reactions to it.
  Future<void> round([int seconds = 0]) async {
    await svc.check();
    await time.advanceSeconds(seconds);
  }

  List<Map> events(String type) => [
        for (final e in (book.since(null)['events'] as List).cast<Map>())
          if (e['cat'] == 'dns' && e['type'] == type) e,
      ];

  Future<List<String>> log() async {
    await Future<void>.delayed(Duration.zero);
    return [for (final s in switches) '${s.from}>${s.to} ${s.reason}'];
  }

  Future<void> dispose() async {
    svc.stop();
    sentinel.dispose();
  }
}

void main() {
  test('a miss streak is judged by the Sentinel: dns/failed, then the failover moves to the highest server that answers', () async {
    final r = _Rig(['a', 'b', 'c']);
    await r.settle();
    await r.round();
    expect(r.svc.active, 'a');
    r.alive['dns-a'] = -1;
    await r.round(); // a miss: evidence, the window (1 s) has not passed
    expect(r.svc.active, 'a');
    expect(r.events('failed'), isEmpty);
    await r.round(2);
    expect(r.svc.active, 'b', reason: 'b is higher than c');
    expect(r.modes, ['dns-b']);
    expect(await r.log(), ['a>b failover']);
    final e = r.events('failed').single;
    expect([e['level'], e['verdict']], ['warn', 'confirmed']);
    expect(e['data'], containsPair('server', 'a'));
    expect(e['data'], containsPair('path', 'direct'));
    expect(e['data'], containsPair('since', isA<int>()));
    final codes = [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];
    expect(codes, containsAllInOrder(['suspect', 'persist.window', 'dns.answers', 'dns.path']));
    expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
    expect(r.sentinel.roots.byKey('dns|a')!.level, Level.dns);
    expect((r.svc.toJson()['servers'] as List).first, containsPair('ok', false));
    await r.dispose();
  });

  test('a miss that goes by inside the window is a blip: nothing written, nothing switched', () async {
    final r = _Rig(['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round();
    r.alive['dns-a'] = 30;
    await r.round(3);
    expect(r.svc.active, 'a');
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.open, isEmpty);
    expect(r.modes, isEmpty);
    await r.dispose();
  });

  test('a higher server whose root closed takes the mode back after failAfter answers', () async {
    final r = _Rig(['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    r.alive['dns-a'] = 30;
    await r.round(); // the answer closes the root, one answer is not enough
    expect(r.sentinel.roots.byKey('dns|a'), isNull);
    expect(r.svc.active, 'b');
    await r.round();
    expect(r.svc.active, 'a');
    expect(r.modes, ['dns-b', 'dns-a']);
    expect(await r.log(), ['a>b failover', 'b>a back']);
    await r.dispose();
  });

  test('a lower server failing is no reason to move; nothing answers: stays', () async {
    final r = _Rig(['a', 'b']);
    await r.settle();
    r.alive['dns-b'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.svc.active, 'a');
    expect(r.events('failed'), hasLength(1), reason: 'b is down, written once');
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.svc.active, 'a', reason: 'no server answers: nothing to move to');
    expect(r.modes, isEmpty);
    await r.dispose();
  });

  test('the flap guard holds a server that dropped: 1 minute with no miss', () async {
    final r = _Rig(['a', 'b'], settings: const AutoSettings(failAfter: 2, flapGuard: true));
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    r.alive['dns-a'] = 30;
    for (var i = 0; i < 4; i++) {
      await r.round(5);
    }
    expect(r.svc.active, 'b');
    await r.time.advanceSeconds(61);
    await r.round();
    expect(r.svc.active, 'a');
    await r.dispose();
  });

  test('one server: nothing to fail over to, but it is still checked and judged', () async {
    final r = _Rig(['a']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect(r.modes, isEmpty);
    expect(r.events('failed'), hasLength(1));
    expect(r.svc.toJson()['servers'], [
      {'id': 'a', 'ok': false, 'ms': -1},
    ]);
    await r.dispose();
  });

  test('Switch automatically off: checked and judged but not switched; turning it off puts the first server back', () async {
    final r = _Rig(['a', 'b'], auto: false);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect((r.svc.toJson()['servers'] as List).first, containsPair('ok', false));
    await r.svc.setAuto(true);
    await r.round();
    expect(r.svc.active, 'b');
    await r.svc.setAuto(false);
    expect(r.svc.active, 'a');
    expect(r.modes, ['dns-b', 'dns-a']);
    expect(await r.log(), ['a>b failover', 'b>a off']);
    await r.round(2);
    expect(r.svc.active, 'a', reason: 'off: stays on the first even though it fails');
    await r.dispose();
  });

  test('nothing is probed while the network may be down; status has every server', () async {
    final r = _Rig(['a', 'b'], uncertain: true);
    await r.settle();
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.svc.active, 'a');
    expect(r.asked, isEmpty);
    expect(r.svc.toJson(), {
      'active': 'a',
      'auto': true,
      'servers': [
        {'id': 'a', 'ok': null, 'ms': -2},
        {'id': 'b', 'ok': null, 'ms': -2},
      ],
    });
    r.uncertain = false;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    await r.dispose();
  });

  test('the network goes down while a miss is being judged: parked behind net.offline, nothing confirmed, nothing switched', () async {
    final r = _Rig(['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(); // the miss: a suspicion
    r.sentinel.context.platform(connected: false);
    await r.time.advanceSeconds(5);
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.byKey('dns|a'), isNull);
    await r.round(5); // the network is down: no round
    expect(r.svc.active, 'a');
    expect(r.modes, isEmpty);
    await r.dispose();
  });

  test('the core not settled: a root that opens waits, nothing is switched', () async {
    final r = _Rig(['a', 'b']);
    // no settle: the core is stopped
    r.alive['dns-a'] = -1;
    await r.round(3);
    await r.round(3);
    expect(r.svc.active, 'a');
    expect(r.modes, isEmpty);
    await r.dispose();
  });

  test('a server via VPN that misses under a dead route is the route\'s consequence: no dns/failed', () async {
    final r = _Rig(['a', 'v'], vpn: {'v'});
    await r.settle();
    r.sentinel.openRoot(
      kind: 'route.dead',
      key: 'route|proxy',
      subject: {'route': 'proxy', 'path': 'proxy'},
      scope: Scope.of({'route': 'proxy'}),
      level: Level.route,
    );
    r.alive['dns-v'] = -1;
    await r.round();
    await r.time.advanceSeconds(3);
    await r.round(3);
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.byKey('dns|v'), isNull, reason: 'a consequence opens no root');
    expect(r.modes, isEmpty);
    // the same server direct would be the server's own failure
    r.alive['dns-a'] = -1;
    await r.round(3);
    await r.round(3);
    expect(r.events('failed').single['data'], containsPair('server', 'a'));
    await r.dispose();
  });

  test('a server that is watched but not switched (a rule\'s own) is judged the same: a root, dns/failed, no switch', () async {
    final r = _Rig(['a', 'b'], watch: ['x']);
    await r.settle();
    r.alive['dns-x'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.events('failed').single['data'], containsPair('server', 'x'));
    expect(r.sentinel.roots.byKey('dns|x'), isNotNull);
    expect(r.svc.active, 'a');
    expect(r.modes, isEmpty);
    final listed = (r.svc.toJson()['servers'] as List).cast<Map>();
    expect(listed.map((s) => s['id']), ['a', 'b', 'x'], reason: 'status.dns lists the watched-only servers after the ones in use');
    expect(listed.map((s) => s['watched']), [null, null, true]);
    expect(listed.last, containsPair('ok', false));
    r.alive['dns-x'] = 10;
    await r.round();
    expect(r.sentinel.roots.byKey('dns|x'), isNull);
    await r.dispose();
  });

  test('a backup name is tried when the first does not resolve: one answering name keeps the server up', () async {
    final tried = <String>[];
    final time = FakeTime();
    final sentinel = Sentinel(clock: time.clock);
    final svc = DnsFailover(
      [(id: 'a', tag: 'dns-a'), (id: 'b', tag: 'dns-b')],
      setMode: (m) async => true,
      query: (tag, name, t) async {
        tried.add('$tag $name');
        return name == dnsCheckNames.last ? 10 : -1;
      },
      settings: const AutoSettings(failAfter: 1, flapGuard: false),
      sentinel: sentinel,
    );
    await svc.check();
    expect(tried.where((t) => t.startsWith('dns-a ')), hasLength(dnsCheckNames.length));
    expect(svc.toJson()['servers'], [
      {'id': 'a', 'ok': true, 'ms': 10},
      {'id': 'b', 'ok': true, 'ms': 10},
    ]);
    svc.stop();
    sentinel.dispose();
  });

  test('the OS resolver has the id system and is watched only when no `system` server is set', () {
    List<String> extra(List<Map<String, dynamic>> servers) {
      final info = RoutingInfo();
      buildConfig({
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': 'k::0',
          'nodes': [
            {'key': 'k::0', 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'}},
          ],
        },
        'routing': {'dns': {'servers': servers}},
      }, info: info);
      return [for (final s in info.dnsExtra) '${s.id}=${s.tag}'];
    }

    expect(extra([{'id': 'g', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true}]), ['$systemDnsId=local']);
    expect(extra([{'id': 's', 'addr': 'system', 'via': 'direct', 'on': true}]), isEmpty, reason: 'a server of its own is watched as any other');
  });

  test('a mode sing-box refuses is no switch', () async {
    final r = _Rig(['a', 'b'], refuseMode: true);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect(await r.log(), isEmpty);
    await r.dispose();
  });
}
