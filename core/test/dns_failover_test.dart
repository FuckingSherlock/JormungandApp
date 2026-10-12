// DnsFailover (dns_failover.dart) executing the Sentinel's verdicts on the DNS flags: fake flag writes (a map standing for
// the files and sing-box reading them), fake DNS queries, the Sentinel judging the misses (time by hand). A miss is
// evidence for `dns.down`; a confirmed root turns the candidate's flag off, a closed one that answered again turns it on.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

/// A candidate with the id [id] (the tag is `dns-<id>`), of [provider] (default: its own) on [side].
DnsCandidate _c(String id, {String side = 'direct', String? provider, String kind = 'udp', bool inUse = true}) => DnsCandidate(
      side: side,
      provider: provider ?? id,
      kind: kind,
      n: 1,
      tag: 'dns-$id',
      addr: 'udp://127.0.0.1:1',
      flagTag: 'flag-dns-$id',
      flagPath: 'flags/dns-$id.json',
      inUse: inUse,
    );

class _Rig {
  _Rig({
    List<String> direct = const [],
    List<String> vpn = const [],
    List<String> extra = const [],
    bool system = false,
    Map<String, String> providers = const {},
    AutoSettings? settings,
    bool auto = true,
    bool uncertain = false,
    Set<String> off = const {},
    this.refuseMode = false,
    this.flagNull = false,
    this.neverApplied = false,
  }) {
    this.uncertain = uncertain;
    DnsCandidate make(String id, String side, {bool inUse = true}) => _c(id, side: side, provider: providers[id], inUse: inUse);
    final d = [for (final id in direct) make(id, 'direct')], v = [for (final id in vpn) make(id, 'vpn')];
    final x = [for (final id in extra) make(id, 'direct', inUse: false)];
    members = {for (final c in [...d, ...v]) c.id: c};
    cands = [...d, ...v, ...x];
    alive = {for (final c in cands) c.tag: 20, if (system) 'local': 20};
    for (final c in cands) {
      fileOn[c.id] = !off.contains(c.id);
    }
    book = EventBook(null, clock: () => time.t);
    sentinel = Sentinel(clock: time.clock, book: book);
    sides = {'direct': d, 'vpn': v};
    svc = DnsFailover(
      sides: sides,
      candidates: cands,
      watch: [for (final c in x) c.entry, if (system) (id: systemDnsId, tag: 'local')],
      off: off,
      setFlag: (c, on, reason) async {
        if (refuseMode) return false;
        writes.add('${c.id} ${on ? 'on' : 'off'} $reason');
        fileOn[c.id] = on;
        return true;
      },
      flagCheck: (c) async {
        checks.add(c.id);
        if (flagNull) return null;
        if (neverApplied) return false;
        return effectiveFile(c.side) == c.id;
      },
      query: (tag, name, t) async {
        asked.add('$tag $name');
        final g = gate;
        if (g != null) await g.future;
        return alive[tag] ?? -1;
      },
      settings: settings ?? const AutoSettings(failAfter: 2, flapGuard: false),
      sentinel: sentinel,
      window: window,
      auto: auto,
      pool: pool,
      clock: () => time.t.millisecondsSinceEpoch,
      note: (level, line) => notes.add('$level $line'),
      flagWait: const Duration(milliseconds: 30),
      flagPoll: Duration.zero,
    );
    svc.switches.listen(switches.add);
  }

  final time = FakeTime();
  late final Sentinel sentinel;
  late final EventBook book;
  late final DnsFailover svc;
  late final Map<String, int> alive;
  late final Map<String, DnsCandidate> members;
  late final List<DnsCandidate> cands;
  late final Map<String, List<DnsCandidate>> sides;
  final window = const Duration(seconds: 1);

  /// The flag files as sing-box would read them (candidate id → on) and the writes the failover made.
  final fileOn = <String, bool>{};
  final writes = <String>[];
  final checks = <String>[];
  final notes = <String>[];
  final asked = <String>[];
  final switches = <DnsSwitch>[];
  Completer<void>? gate;
  final bool refuseMode, flagNull, neverApplied;
  final pool = ProbePool.solo();
  set uncertain(bool v) => pool.doubt(v); // Auto doubting the network: the status is `unknown`

  /// The candidate the files make the answering one of [side]: the first that is on, else the top one.
  String? effectiveFile(String side) {
    final l = sides[side]!;
    return l.where((c) => fileOn[c.id] == true).firstOrNull?.id ?? l.firstOrNull?.id;
  }

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
    return [for (final s in switches) '${s.side} ${s.from}>${s.to} ${s.reason}'];
  }

  Future<void> dispose() async {
    svc.stop();
    sentinel.dispose();
  }
}

void main() {
  test('a miss streak is judged by the Sentinel: dns/failed, the flag goes off, the side moves to the highest candidate that answers', () async {
    final r = _Rig(direct: ['a', 'b', 'c']);
    await r.settle();
    await r.round();
    expect(r.svc.active, 'a');
    r.alive['dns-a'] = -1;
    await r.round(); // a miss: evidence, the window (1 s) has not passed
    expect(r.svc.active, 'a');
    expect(r.events('failed'), isEmpty);
    expect(r.writes, isEmpty);
    await r.round(2);
    expect(r.svc.active, 'b', reason: 'b is higher than c');
    expect(r.writes, ['a off verdict']);
    expect(await r.log(), ['direct a>b failover']);
    expect([r.switches.single.fromProvider, r.switches.single.toProvider], ['a', 'b']);
    final e = r.events('failed').single;
    expect([e['level'], e['verdict']], ['warn', 'confirmed']);
    expect(e['data'], containsPair('server', 'a'));
    expect(e['data'], containsPair('path', 'direct'));
    expect(e['data'], containsPair('since', isA<int>()));
    expect(e['data'], containsPair('provider', 'a'));
    expect(e['data'], containsPair('side', 'direct'));
    final codes = [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];
    expect(codes, containsAllInOrder(['suspect', 'persist.window', 'dns.answers', 'dns.path']));
    expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
    expect(r.sentinel.roots.byKey('dns|a')!.level, Level.dns);
    expect((r.svc.toJson()['servers'] as List).first, containsPair('ok', false));
    expect(r.notes.any((n) => n.startsWith('info dns flag check (direct): b answers after')), isTrue, reason: 'the write was verified: ${r.notes}');
    expect(r.notes.any((n) => n.startsWith('debug dns direct: answers a; flags on [a, b 20 ms, c 20 ms]; off []')), isTrue, reason: 'one summary line per side per round: ${r.notes}');
    expect(r.notes.where((n) => n.startsWith('warn')), isEmpty);
    await r.dispose();
  });

  test('a miss that goes by inside the window is a blip: nothing written, nothing switched', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round();
    r.alive['dns-a'] = 30;
    await r.round(3);
    expect(r.svc.active, 'a');
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.open, isEmpty);
    expect(r.writes, isEmpty);
    await r.dispose();
  });

  test('a candidate whose root closed gets its flag back after failAfter answers in a row', () async {
    final r = _Rig(direct: ['a', 'b']);
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
    expect(r.writes, ['a off verdict', 'a on back']);
    expect(await r.log(), ['direct a>b failover', 'direct b>a back']);
    await r.dispose();
  });

  test('a lower candidate failing turns its flag off and moves nobody; every flag off: the top one answers, nothing flips', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-b'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.svc.active, 'a');
    expect(r.events('failed'), hasLength(1), reason: 'b is down, written once');
    expect(r.writes, ['b off verdict']);
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.writes, ['b off verdict', 'a off verdict']);
    expect(r.svc.active, 'a', reason: 'every flag off: the top candidate answers');
    expect(r.effectiveFile('direct'), 'a');
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.writes, hasLength(2), reason: 'a dead side is not flipped again');
    expect(await r.log(), isEmpty, reason: 'the answering server did not change');
    await r.dispose();
  });

  test('the sides are independent: a dead VPN candidate moves the VPN side only', () async {
    final r = _Rig(direct: ['a', 'b'], vpn: ['v1', 'v2']);
    await r.settle();
    r.alive['dns-v1'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.activeOf('vpn'), 'v2');
    expect(r.svc.activeOf('direct'), 'a');
    expect(r.svc.active, 'v2', reason: '`active` is the VPN side\'s');
    expect(r.writes, ['v1 off verdict']);
    expect(r.checks.where((c) => c == 'v2'), isNotEmpty);
    expect(r.checks.where((c) => c == 'a' || c == 'b'), isEmpty, reason: 'only the side that changed is verified');
    expect(await r.log(), ['vpn v1>v2 failover']);
    expect(r.events('failed').single['data'], containsPair('side', 'vpn'));
    await r.dispose();
  });

  test('the flap guard holds a candidate that dropped: 1 minute with no miss', () async {
    final r = _Rig(direct: ['a', 'b'], settings: const AutoSettings(failAfter: 2, flapGuard: true));
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
    expect(r.writes, ['a off verdict', 'a on back']);
    await r.dispose();
  });

  test('one candidate: nothing to fail over to, but it is still checked and judged; no flag check', () async {
    final r = _Rig(direct: ['a']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect(r.events('failed'), hasLength(1));
    expect(r.checks, isEmpty, reason: 'a single candidate has no flag rule in the config to look at');
    expect(r.svc.toJson()['servers'], [
      {'id': 'a', 'ok': false, 'ms': -1, 'provider': 'a', 'side': 'direct', 'kind': 'udp', 'flag': false},
    ]);
    await r.dispose();
  });

  test('Switch automatically off: checked and judged, every flag on; turning it on applies the verdicts, off puts them all on again', () async {
    final r = _Rig(direct: ['a', 'b'], auto: false);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect(r.writes, isEmpty);
    expect((r.svc.toJson()['servers'] as List).first, containsPair('ok', false));
    expect(r.events('failed'), hasLength(1), reason: 'the checks and the labels go on');
    await r.svc.setAuto(true); // the current verdicts apply at once
    expect(r.svc.active, 'b');
    expect(r.writes, ['a off verdict']);
    await r.svc.setAuto(false);
    expect(r.svc.active, 'a');
    expect(r.writes, ['a off verdict', 'a on auto off']);
    expect(await r.log(), ['direct a>b failover', 'direct b>a off']);
    await r.round(2);
    expect(r.svc.active, 'a', reason: 'off: stays on the first even though it fails');
    expect(r.writes, hasLength(2));
    await r.dispose();
  });

  test('nothing is probed while the network may be down; status has every server', () async {
    final r = _Rig(direct: ['a', 'b'], uncertain: true);
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
      'sides': {
        'direct': {'active': 'a', 'provider': 'a'},
        'vpn': {'active': null, 'provider': null},
      },
      'servers': [
        {'id': 'a', 'ok': null, 'ms': -2, 'provider': 'a', 'side': 'direct', 'kind': 'udp', 'flag': true},
        {'id': 'b', 'ok': null, 'ms': -2, 'provider': 'b', 'side': 'direct', 'kind': 'udp', 'flag': true},
      ],
    });
    r.uncertain = false;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    await r.dispose();
  });

  test('the network goes down while a miss is being judged: parked behind net.offline, nothing confirmed, no flag written', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(); // the miss: a suspicion
    r.sentinel.context.platform(connected: false);
    await r.time.advanceSeconds(5);
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.byKey('dns|a'), isNull);
    await r.round(5); // the network is down: no round
    expect(r.svc.active, 'a');
    expect(r.writes, isEmpty);
    await r.dispose();
  });

  test('the core not settled: a root that opens waits, no flag is written', () async {
    final r = _Rig(direct: ['a', 'b']);
    // no settle: the core is stopped
    r.alive['dns-a'] = -1;
    await r.round(3);
    await r.round(3);
    expect(r.svc.active, 'a');
    expect(r.writes, isEmpty);
    await r.dispose();
  });

  test('a candidate via VPN that misses under a dead route is the route\'s consequence: no dns/failed, no flag', () async {
    final r = _Rig(direct: ['a'], vpn: ['v', 'w']);
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
    expect(r.writes, isEmpty);
    // the same server direct would be the server's own failure
    r.alive['dns-a'] = -1;
    await r.round(3);
    await r.round(3);
    expect(r.events('failed').single['data'], containsPair('server', 'a'));
    await r.dispose();
  });

  test('a candidate that is watched but in no side list (a rule\'s own) is judged the same and its flag follows; the OS resolver has none', () async {
    final r = _Rig(direct: ['a', 'b'], extra: ['x'], system: true);
    await r.settle();
    r.alive['dns-x'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.events('failed').single['data'], containsPair('server', 'x'));
    expect(r.sentinel.roots.byKey('dns|x'), isNotNull);
    expect(r.svc.active, 'a');
    expect(r.writes, ['x off verdict'], reason: 'a rule\'s chain of several transports follows its flag');
    expect(await r.log(), isEmpty);
    final listed = (r.svc.toJson()['servers'] as List).cast<Map>();
    expect(listed.map((s) => s['id']), ['a', 'b', 'x', 'system'], reason: 'status.dns lists the watched-only servers after the ones in use');
    expect(listed.map((s) => s['watched']), [null, null, true, true]);
    expect(listed[2], containsPair('ok', false));
    expect(listed[3].containsKey('flag'), isFalse);
    r.alive['local'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.events('failed').map((e) => (e['data'] as Map)['server']), containsAll(['x', 'system']));
    expect(r.writes, ['x off verdict'], reason: 'the OS resolver has no flag');
    r.alive['dns-x'] = 10;
    await r.round();
    expect(r.sentinel.roots.byKey('dns|x'), isNull);
    await r.dispose();
  });

  test('the event is per provider and side: a dead transport whose provider still answers is a log line, the last one makes dns/failed', () async {
    final r = _Rig(direct: ['p-doh', 'p-dot', 'q'], providers: {'p-doh': 'p', 'p-dot': 'p'});
    await r.settle();
    r.alive['dns-p-doh'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.writes, ['p-doh off verdict'], reason: 'the flag follows the transport');
    expect(r.svc.active, 'p-dot');
    expect(r.events('failed'), isEmpty, reason: 'the provider still answers through p-dot');
    expect(r.notes.any((n) => n.contains('p-doh (p, direct) does not answer, its provider still does through p-dot')), isTrue, reason: '${r.notes}');
    r.alive['dns-p-dot'] = -1;
    await r.round(2);
    await r.round(2);
    final e = r.events('failed').single;
    expect(e['data'], containsPair('server', 'p-dot'));
    expect(e['data'], containsPair('provider', 'p'));
    expect(e['data'], containsPair('side', 'direct'));
    expect(e['data'], containsPair('servers', ['p-dot', 'p-doh']));
    expect(r.svc.active, 'q');
    expect(await r.log(), ['direct p-doh>p-dot failover', 'direct p-dot>q failover']);
    expect([r.switches.last.fromProvider, r.switches.last.toProvider], ['p', 'q']);
    await r.dispose();
  });

  test('a restart gives the flags of the run before: the restored-off candidate returns on a single answer, a dead one stays off', () async {
    final r = _Rig(direct: ['a', 'b'], off: {'a'});
    await r.settle();
    expect(r.svc.active, 'b', reason: 'a is off in the new sing-box too');
    expect(r.svc.flags, {'a': false, 'b': true});
    expect(r.writes, isEmpty, reason: 'the service wrote them before sing-box started');
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    expect(r.writes, isEmpty, reason: 'dead and off: nothing to flip');
    expect(r.events('failed'), hasLength(1));
    r.alive['dns-a'] = 20;
    await r.round(); // the answer closes the root and a single answer returns it
    expect(r.writes, ['a on back']);
    expect(r.svc.active, 'a');
    expect(await r.log(), ['direct b>a back']);
    await r.dispose();
  });

  test('a connect: every candidate is asked in parallel in the first round', () async {
    final r = _Rig(direct: ['a', 'b'], vpn: ['v1', 'v2'], extra: ['x']);
    await r.settle();
    r.gate = Completer<void>();
    final round = r.svc.check();
    await pumpEventQueue();
    expect(r.asked.map((s) => s.split(' ').first).toSet(), {'dns-a', 'dns-b', 'dns-v1', 'dns-v2', 'dns-x'}, reason: 'all asked before any answered');
    r.gate!.complete();
    await round;
    await r.dispose();
  });

  test('a dead candidate found by the first round goes off through the normal verdict path', () async {
    final r = _Rig(direct: ['a', 'b']);
    r.alive['dns-a'] = -1; // dead from the start
    await r.settle();
    await r.round();
    await r.round(2);
    await r.round(2);
    expect(r.writes, ['a off verdict']);
    expect(r.svc.active, 'b');
    await r.dispose();
  });

  test('a flag write that fails changes nothing and says so; a flag sing-box does not apply is a warning', () async {
    final r = _Rig(direct: ['a', 'b'], refuseMode: true);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'a');
    expect(await r.log(), isEmpty);
    expect(r.notes.any((n) => n.startsWith('warn dns flag: a stays on (verdict): the write failed')), isTrue);
    await r.dispose();

    final n = _Rig(direct: ['a', 'b'], neverApplied: true);
    await n.settle();
    n.alive['dns-a'] = -1;
    await n.round(2);
    await n.round(2);
    expect(n.writes, ['a off verdict']);
    final w = n.notes.where((l) => l.startsWith('warn dns flag not applied after')).single;
    expect(w, contains('(direct): expected b, no candidate answers the flagcheck'));
    await n.dispose();

    final u = _Rig(direct: ['a', 'b'], flagNull: true);
    await u.settle();
    u.alive['dns-a'] = -1;
    await u.round(2);
    await u.round(2);
    expect(u.writes, ['a off verdict']);
    expect(u.notes.any((l) => l.startsWith('debug dns flag check (direct): cannot be told')), isTrue);
    expect(u.notes.where((l) => l.startsWith('warn')), isEmpty, reason: 'an old sing-box without flagcheck is no failure');
    await u.dispose();
  });

  test('after start both sides are checked once', () async {
    final r = _Rig(direct: ['a', 'b'], vpn: ['v1', 'v2']);
    r.svc.start();
    await pumpEventQueue();
    expect(r.notes.any((n) => n.startsWith('info dns flag check (direct): a answers after') && n.endsWith('(start)')), isTrue, reason: '${r.notes}');
    expect(r.notes.any((n) => n.startsWith('info dns flag check (vpn): v1 answers after') && n.endsWith('(start)')), isTrue);
    await r.dispose();
  });

  test('a backup name is tried when the first does not resolve: one answering name keeps the server up', () async {
    final tried = <String>[];
    final time = FakeTime();
    final sentinel = Sentinel(clock: time.clock);
    final svc = DnsFailover(
      sides: {
        'direct': [_c('a'), _c('b')],
      },
      setFlag: (c, on, reason) async => true,
      query: (tag, name, t) async {
        tried.add('$tag $name');
        return name == dnsCheckNames.last ? 10 : -1;
      },
      settings: const AutoSettings(failAfter: 1, flapGuard: false),
      sentinel: sentinel,
    );
    await svc.check();
    expect(tried.where((t) => t.startsWith('dns-a ')), hasLength(dnsCheckNames.length));
    expect((svc.toJson()['servers'] as List).map((s) => [(s as Map)['id'], s['ok'], s['ms']]), [
      ['a', true, 10],
      ['b', true, 10],
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
}
