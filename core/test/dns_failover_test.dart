// DnsFailover (dns_failover.dart) with a fake clash mode and fake DNS queries.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

class _Rig {
  _Rig(List<String> ids, {AutoSettings? settings, bool auto = true, this.uncertain = false, int Function()? clock, this.refuseMode = false}) {
    alive = {for (final id in ids) 'dns-$id': 20};
    svc = DnsFailover(
      [for (final id in ids) (id: id, tag: 'dns-$id')],
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
      auto: auto,
      networkUncertain: () => uncertain,
      clock: clock,
    );
    svc.switches.listen(switches.add);
  }

  late final DnsFailover svc;
  late final Map<String, int> alive;
  final modes = <String>[];
  final asked = <String>[];
  final switches = <DnsSwitch>[];
  bool uncertain, refuseMode;

  Future<List<String>> log() async {
    await Future<void>.delayed(Duration.zero);
    return [for (final s in switches) '${s.from}>${s.to} ${s.reason}'];
  }
}

void main() {
  test('starts on the first server; the one in use missing failAfter times goes to the highest one that answers', () async {
    final r = _Rig(['a', 'b', 'c']);
    await r.svc.check();
    expect(r.svc.active, 'a');
    r.alive['dns-a'] = -1;
    await r.svc.check();
    expect(r.svc.active, 'a', reason: 'one miss is not enough with failAfter 2');
    await r.svc.check();
    expect(r.svc.active, 'b', reason: 'b is higher than c');
    expect(r.modes, ['dns-b']);
    expect(await r.log(), ['a>b failover']);
  });

  test('a higher server that answers again takes the mode back after failAfter answers', () async {
    final r = _Rig(['a', 'b']);
    r.alive['dns-a'] = -1;
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'b');
    r.alive['dns-a'] = 30;
    await r.svc.check();
    expect(r.svc.active, 'b');
    await r.svc.check();
    expect(r.svc.active, 'a');
    expect(r.modes, ['dns-b', 'dns-a']);
    expect(await r.log(), ['a>b failover', 'b>a back']);
  });

  test('a lower server failing is no reason to move; nothing answers: stays', () async {
    final r = _Rig(['a', 'b']);
    r.alive['dns-b'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.svc.check();
    }
    expect(r.svc.active, 'a');
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.svc.check();
    }
    expect(r.svc.active, 'a', reason: 'no server answers: nothing to move to');
    expect(r.modes, isEmpty);
  });

  test('the flap guard holds a server that dropped: 1 minute with no miss', () async {
    var now = 1000000;
    final r = _Rig(['a', 'b'], settings: const AutoSettings(failAfter: 2, flapGuard: true), clock: () => now);
    r.alive['dns-a'] = -1;
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'b');
    r.alive['dns-a'] = 30;
    for (var i = 0; i < 3; i++) {
      now += 5000;
      await r.svc.check();
    }
    expect(r.svc.active, 'b');
    now += 61000;
    await r.svc.check();
    expect(r.svc.active, 'a');
  });

  test('one server: nothing to fail over to, but it is still checked', () async {
    final r = _Rig(['a']);
    r.alive['dns-a'] = -1;
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'a');
    expect(r.modes, isEmpty);
    expect(r.svc.toJson()['servers'], [
      {'id': 'a', 'ok': false, 'ms': -1},
    ]);
  });

  test('Switch automatically off: checked but not switched; turning it off puts the first server back', () async {
    final r = _Rig(['a', 'b'], auto: false);
    r.alive['dns-a'] = -1;
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'a');
    expect((r.svc.toJson()['servers'] as List).first, containsPair('ok', false));
    await r.svc.setAuto(true);
    await r.svc.check();
    expect(r.svc.active, 'b');
    await r.svc.setAuto(false);
    expect(r.svc.active, 'a');
    expect(r.modes, ['dns-b', 'dns-a']);
    expect(await r.log(), ['a>b failover', 'b>a off']);
    await r.svc.check();
    expect(r.svc.active, 'a', reason: 'off: stays on the first even though it fails');
  });

  test('nothing is judged while the network may be down; status has every server', () async {
    final r = _Rig(['a', 'b'], uncertain: true);
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.svc.check();
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
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'b');
  });

  test('a backup name is tried when the first does not resolve: one answering name keeps the server up', () async {
    final tried = <String>[];
    final svc = DnsFailover(
      [(id: 'a', tag: 'dns-a'), (id: 'b', tag: 'dns-b')],
      setMode: (m) async => true,
      query: (tag, name, t) async {
        tried.add('$tag $name');
        return name == dnsCheckNames.last ? 10 : -1;
      },
      settings: const AutoSettings(failAfter: 1, flapGuard: false),
    );
    await svc.check();
    expect(tried.where((t) => t.startsWith('dns-a ')), hasLength(dnsCheckNames.length));
    expect(svc.toJson()['servers'], [
      {'id': 'a', 'ok': true, 'ms': 10},
      {'id': 'b', 'ok': true, 'ms': 10},
    ]);
    svc.stop();
  });

  test('a mode sing-box refuses is no switch', () async {
    final r = _Rig(['a', 'b'], refuseMode: true);
    r.alive['dns-a'] = -1;
    await r.svc.check();
    await r.svc.check();
    expect(r.svc.active, 'a');
    expect(await r.log(), isEmpty);
  });
}
