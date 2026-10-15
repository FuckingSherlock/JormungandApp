// DnsFailover (dns_failover.dart) executing the Sentinel's verdicts on the DNS flags: fake flag writes (a map standing for
// the files and sing-box reading them), fake DNS queries, the Sentinel judging the misses (time by hand). A miss is
// evidence for `dns.down`; a confirmed root turns the candidate's flag off, a closed one that answered again turns it on.
import 'dart:async';
import 'dart:io';

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
      addr: 'udp://127.0.0.1:1/$id', // the verdict is about the address: one per candidate
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
    Map<String, String> kinds = const {},
    AutoSettings? settings,
    bool auto = true,
    bool uncertain = false,
    Set<String> off = const {},
    Set<String> reserve = const {},
    this.refuseMode = false,
    this.flagNull = false,
    this.neverApplied = false,
    DnsVerdictBook? verdicts,
    this.nodeId,
    bool withNodes = false,
  }) {
    this.verdicts = verdicts ?? DnsVerdictBook();
    this.uncertain = uncertain;
    DnsCandidate make(String id, String side, {bool inUse = true}) => _c(id, side: side, provider: providers[id], kind: kinds[id] ?? 'udp', inUse: inUse);
    final d = [for (final id in direct) make(id, 'direct')], v = [for (final id in vpn) make(id, 'vpn')];
    final x = [for (final id in extra) make(id, 'direct', inUse: false)];
    members = {for (final c in [...d, ...v]) c.id: c};
    cands = [...d, ...v, ...x];
    alive = {for (final c in cands) c.tag: 20, if (system) 'local': 20};
    for (final c in cands) {
      fileOn[c.id] = !off.contains(c.id) && !reserve.contains(c.id);
    }
    book = EventBook(null, clock: () => time.t);
    sentinel = Sentinel(clock: time.clock, book: book);
    sides = {'direct': d, 'vpn': v};
    svc = DnsFailover(
      sides: sides,
      candidates: cands,
      watch: [for (final c in x) c.entry, if (system) (id: systemDnsId, tag: 'local')],
      off: off,
      reserve: reserve,
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
        final g = gate, h = hold[tag];
        if (g != null) await g.future;
        if (h != null) await h.future; // the answer of this server arrives when the test says (the order of a race)
        return alive[tag] ?? -1;
      },
      settings: settings ?? const AutoSettings(failAfter: 2, flapGuard: false),
      sentinel: sentinel,
      window: window,
      auto: auto,
      pool: pool,
      clock: () => time.t.millisecondsSinceEpoch,
      book: this.verdicts,
      node: () => nodeId,
      nodes: !withNodes
          ? null
          : DnsNodes(
              spare: () => spareTag == null ? null : (key: 'sub::spare', tag: spareTag!),
              exitKey: () => 'sub::exit',
              exitAlive: () async => exitAlive,
              ask: (c, tag, name, t) async {
                viaAsked.add('${c.id} via $tag');
                return viaAnswers.containsKey(c.id) ? viaAnswers[c.id] : -1;
              },
            ),
      note: (level, line) => notes.add('$level $line'),
      flagWait: const Duration(milliseconds: 30),
      flagPoll: Duration.zero,
    );
    svc.switches.listen(switches.add);
  }

  final time = FakeTime();

  /// The other nodes ([withNodes]): the spare node's outbound tag (null = no working node), whether the exit node carries
  /// traffic, and what the same server answers through the spare node (candidate id → ms; -1 = silent, null = cannot be asked).
  String? spareTag = 'spare';
  bool? exitAlive = true;
  final viaAnswers = <String, int?>{};
  final viaAsked = <String>[];
  late final DnsVerdictBook verdicts;
  String? nodeId;
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
  final hold = <String, Completer<void>>{};
  bool refuseMode;
  final bool flagNull, neverApplied;
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
  test('the first round runs `firstCheck` after start, not after the regular interval (all candidates, in parallel)', () async {
    // report 20261014-phmbw7: the first dns-check lines looked late (+30 s); the round itself began at firstCheck, the
    // verdict came after the round's own misses and the Sentinel's re-asks
    final rig = _Rig(
        direct: ['a', 'b'],
        vpn: ['a-v'],
        settings: const AutoSettings(failAfter: 2, flapGuard: false, checkEvery: Duration(hours: 1), firstCheck: Duration(milliseconds: 20)));
    expect(rig.asked, isEmpty);
    rig.svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect({for (final q in rig.asked) q.split(' ').first}, {'dns-a', 'dns-b', 'dns-a-v'}, reason: 'every candidate asked by the first round');
    rig.svc.stop();
  });

  test('a miss streak is judged by the Sentinel: dns/failed, the flag goes off, the side moves to the highest candidate that answers', () async {
    final r = _Rig(direct: ['a', 'b', 'c']);
    await r.settle();
    await r.round();
    expect(r.svc.active, 'a');
    r.alive['dns-a'] = -1;
    await r.round(); // a miss: evidence, the window (1 s) has not passed; the traffic moves at once, in parallel
    expect(r.svc.active, 'b', reason: 'b is higher than c; no waiting for the verdict');
    expect(r.events('failed'), isEmpty);
    expect(r.writes, ['a off miss']);
    await r.round(2);
    expect(r.svc.active, 'b');
    expect(r.writes, ['a off miss'], reason: 'the verdict only confirms what was done (the flap guard\'s strike)');
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
    expect(r.notes.any((n) => n.startsWith('debug dns direct: answers b; flags on [b 20ms, c 20ms]; off [a]')), isTrue, reason: 'one summary line per side per round: ${r.notes}');
    expect(r.notes.where((n) => n.startsWith('warn')), isEmpty);
    await r.dispose();
  });

  test('a miss that goes by inside the window is a blip: the traffic moved at once, no event, no root; it returns after failAfter answers', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round();
    expect(r.svc.active, 'b');
    r.alive['dns-a'] = 30;
    await r.round(3);
    await r.round(3);
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.open, isEmpty);
    expect(r.svc.active, 'a');
    expect(r.writes, ['a off miss', 'a on back']);
    expect(await r.log(), ['direct a>b failover', 'direct b>a back']);
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
    expect(r.writes, ['a off miss', 'a on back']);
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
    expect(r.writes, ['b off miss']);
    r.alive['dns-a'] = -1;
    for (var i = 0; i < 3; i++) {
      await r.round(2);
    }
    expect(r.writes, ['b off miss', 'a off miss']);
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
    expect(r.writes, ['v1 off miss']);
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
    expect(r.writes, ['a off miss', 'a on back']);
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
      {'id': 'a', 'ok': false, 'rechecking': false, 'ms': -1, 'provider': 'a', 'side': 'direct', 'kind': 'udp', 'flag': false},
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

  test('a dead candidate is asked again on the ladder 30 s, 1 min, 2 min; the answer closes its root', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2); // the miss, then the window passes: the root opens
    expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
    int askedA() => r.asked.where((q) => q.startsWith('dns-a ')).length;
    r.asked.clear();
    await r.svc.checkDue();
    expect(askedA(), 0, reason: 'its time has not come');
    await r.time.advanceSeconds(31);
    await r.svc.checkDue();
    expect(askedA(), greaterThan(0), reason: '30 s after the root opened');
    r.asked.clear();
    await r.time.advanceSeconds(31);
    await r.svc.checkDue();
    expect(askedA(), 0, reason: 'the next step is 1 min');
    await r.time.advanceSeconds(30);
    await r.svc.checkDue();
    expect(askedA(), greaterThan(0), reason: '1 min after the last ask');
    r.asked.clear();
    r.alive['dns-a'] = 30;
    await r.time.advanceSeconds(121);
    await r.svc.checkDue();
    expect(askedA(), greaterThan(0), reason: '2 min after the last ask');
    expect(r.sentinel.roots.byKey('dns|a'), isNull, reason: 'it answered: the root is closed');
    await r.dispose();
  });

  test('the ladder asks nothing while the network is not up; the dead candidate is asked once it is', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(2);
    expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
    r.uncertain = true;
    r.asked.clear();
    await r.time.advanceSeconds(40);
    await r.svc.checkDue();
    expect(r.asked, isEmpty);
    r.uncertain = false;
    await r.svc.checkDue();
    expect(r.asked.where((q) => q.startsWith('dns-a ')), isNotEmpty, reason: 'due since 30 s');
    await r.dispose();
  });

  test('alive: a dead candidate (flag off, root open) is not asked for look-ups, back when it answers again; an unknown id is not judged', () async {
    final r = _Rig(direct: ['a', 'b'], system: true);
    await r.settle();
    expect([r.svc.alive('a'), r.svc.alive('b'), r.svc.alive(systemDnsId), r.svc.alive('nope')], [true, true, true, true]);
    r.alive['dns-a'] = -1;
    await r.round(2);
    await r.round(2);
    expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
    expect(r.svc.alive('a'), isFalse);
    expect(r.svc.alive('b'), isTrue);
    expect(r.svc.alive(systemDnsId), isTrue, reason: 'the OS resolver has no flag');
    r.alive['dns-a'] = 30;
    await r.round();
    await r.round();
    expect(r.svc.alive('a'), isTrue, reason: 'the root closed and the flag is back');
    await r.dispose();
  });

  test('a transport that missed while the Sentinel still confirms it reads suspect (ms -1), then miss', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(); // the round's miss opens the suspicion; its checks are still running
    var t = (r.svc.providersJson('a').single['transports'] as List).single as Map;
    expect([t['state'], t['ms']], ['suspect', -1], reason: 'no answer is known, the verdict is not');
    await r.time.advanceSeconds(5);
    t = (r.svc.providersJson('a').single['transports'] as List).single as Map;
    expect(t['state'], 'miss');
    await r.dispose();
  });

  test('lookupMissed: a lookup that got no answer opens the server\'s suspicion (its own check decides), never a verdict by itself', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    await r.round();
    final key = dnsVerdictKey(r.members['a'], null);
    expect(r.verdicts.deadOf(key), isFalse);

    // the server really is down: the suspicion runs its checks and confirms after the window
    r.alive['dns-a'] = -1;
    r.svc.lookupMissed('a');
    await r.time.advanceSeconds(0);
    expect((r.svc.toJson()['servers'] as List).first, containsPair('rechecking', true), reason: 'a suspicion is open');
    expect(r.events('failed'), isEmpty);
    expect(r.writes, isEmpty);
    expect(r.verdicts.deadOf(key), isFalse, reason: 'the miss alone changed nothing');
    await r.time.advanceSeconds(3);
    expect(r.events('failed'), hasLength(1));
    expect(r.writes, ['a off verdict']);
    expect(r.verdicts.deadOf(key), isTrue);

    // an unknown id, a server this config does not watch: left alone
    r.svc.lookupMissed('nope');
    await r.dispose();
  });

  test('lookupMissed: the server answers its own check: a blip, nothing written, no verdict', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    await r.round();
    final key = dnsVerdictKey(r.members['a'], null);
    r.svc.lookupMissed('a'); // the lookup missed, the server is fine
    await r.time.advanceSeconds(3);
    expect(r.events('failed'), isEmpty);
    expect(r.writes, isEmpty);
    expect(r.verdicts.deadOf(key), isFalse);
    expect(r.svc.active, 'a');
    await r.dispose();
  });

  group('pingProvider', () {
    test('the network is up: the answer closes the root of a dead candidate and the ladder starts over', () async {
      final r = _Rig(direct: ['a', 'a2', 'b'], providers: {'a2': 'a'});
      await r.settle();
      r.alive['dns-a'] = -1;
      r.alive['dns-a2'] = -1;
      await r.round(2);
      expect(r.sentinel.roots.byKey('dns|a'), isNotNull);
      r.alive['dns-a'] = 25;
      r.asked.clear();
      final got = await r.svc.pingProvider('a');
      expect([for (final g in got) '${g.id} ${g.side} ${g.kind} ${g.ms}'], ['a direct udp 25', 'a2 direct udp -1']);
      expect(r.asked.where((q) => q.startsWith('dns-b ')), isEmpty, reason: 'only the provider is asked');
      expect(r.sentinel.roots.byKey('dns|a'), isNull, reason: 'it answered: not dead any more');
      expect(r.sentinel.roots.byKey('dns|a2'), isNotNull, reason: 'a2 still misses');
      await r.dispose();
    });

    test('the network is up: a miss is evidence like a round\'s (the second one after the window confirms it)', () async {
      final r = _Rig(direct: ['a', 'b']);
      await r.settle();
      r.alive['dns-b'] = -1;
      expect((await r.svc.pingProvider('b')).single.ms, -1);
      expect(r.sentinel.roots.byKey('dns|b'), isNull, reason: 'one miss is a suspicion only');
      await r.time.advanceSeconds(2);
      await r.svc.pingProvider('b');
      await r.time.advanceSeconds(2);
      expect(r.sentinel.roots.byKey('dns|b'), isNotNull);
      expect(r.writes, ['b off miss']);
      await r.dispose();
    });

    test('the network is not up: it only measures, nothing reaches the Sentinel and no flag moves', () async {
      final r = _Rig(direct: ['a', 'b'], uncertain: true);
      await r.settle();
      r.alive['dns-a'] = -1;
      for (var i = 0; i < 3; i++) {
        expect((await r.svc.pingProvider('a')).single.ms, -1);
        await r.time.advanceSeconds(2);
      }
      expect(r.asked, isNotEmpty);
      expect(r.sentinel.roots.open, isEmpty);
      expect(r.writes, isEmpty);
      r.alive['dns-a'] = 40;
      expect((await r.svc.pingProvider('a')).single.ms, 40);
      await r.dispose();
    });

    test('startPing does not wait: the answers land one by one, the slow one reads testing, a second ask joins the run', () async {
      final r = _Rig(direct: ['a', 'a2', 'b'], providers: {'a2': 'a'});
      await r.settle();
      r.alive['dns-a'] = 25;
      r.alive['dns-a2'] = 60;
      r.hold['dns-a2'] = Completer<void>();
      r.asked.clear();
      final run = r.svc.startPing('a')!;
      expect(identical(r.svc.startPing('a'), run), isTrue, reason: 'a ping of the provider in flight is joined');
      await pumpEventQueue();
      expect(r.svc.pinging('a'), isTrue);
      expect(r.asked.where((q) => q.startsWith('dns-a ')), hasLength(1), reason: 'asked once');
      final mid = [for (final t in (r.svc.providersJson('a').single['transports'] as List)) '${t['ids']} ${t['ms']} ${t['state']}'];
      expect(r.svc.pingResults('a').firstWhere((g) => g.id == 'a').ms, 25, reason: 'the fast one is in before the slow one ends');
      expect(r.svc.pingResults('a').firstWhere((g) => g.id == 'a2').ms, anyOf(-2, -1), reason: 'the slow one has no answer yet');
      expect(mid.any((s) => s.endsWith('testing')), isTrue, reason: 'the slow transport reads testing');
      r.hold['dns-a2']!.complete();
      await run;
      expect(r.svc.pinging('a'), isFalse);
      expect([for (final g in r.svc.pingResults('a')) '${g.id} ${g.ms}'], ['a 25', 'a2 60']);
      expect(r.svc.providersJson('a').single['transports'], everyElement(containsPair('state', 'ok')));
      await r.dispose();
    });

    test('a provider this config does not hold, or a stopped failover: nothing', () async {
      final r = _Rig(direct: ['a']);
      await r.settle();
      expect(await r.svc.pingProvider('zzz'), isEmpty);
      expect(r.asked, isEmpty);
      r.svc.stop();
      expect(await r.svc.pingProvider('a'), isEmpty);
      await r.dispose();
    });
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
      'providers': [
        for (final p in ['a', 'b'])
          {
            'provider': p,
            'side': 'direct',
            'racing': false,
            'winner': null,
            'transports': [
              {'kind': 'udp', 'ids': [p], 'ms': -2, 'state': 'untested'},
            ],
          },
      ],
      'servers': [
        {'id': 'a', 'ok': null, 'rechecking': false, 'ms': -2, 'provider': 'a', 'side': 'direct', 'kind': 'udp', 'flag': true},
        {'id': 'b', 'ok': null, 'rechecking': false, 'ms': -2, 'provider': 'b', 'side': 'direct', 'kind': 'udp', 'flag': true},
      ],
    });
    r.uncertain = false;
    await r.round(2);
    await r.round(2);
    expect(r.svc.active, 'b');
    await r.dispose();
  });

  test('a side with no candidate (every provider off): no active server, a null answer in the status, nothing probed or written', () async {
    final r = _Rig();
    await r.settle();
    await r.round(2);
    expect(r.svc.active, isNull);
    expect(r.asked, isEmpty);
    expect(r.writes, isEmpty);
    expect(r.svc.toJson(), {
      'active': null,
      'auto': true,
      'sides': {
        'direct': {'active': null, 'provider': null},
        'vpn': {'active': null, 'provider': null},
      },
      'providers': <Object>[],
      'servers': <Object>[],
    });
    await r.dispose();
    // one side empty, the other works: the empty one stays null
    final d = _Rig(vpn: ['v']);
    await d.settle();
    d.alive['dns-v'] = -1;
    await d.round(2);
    await d.round(2);
    expect((d.svc.toJson()['sides'] as Map)['direct'], {'active': null, 'provider': null});
    expect(d.svc.active, 'v');
    await d.dispose();
  });

  test('the network goes down while a miss is being judged: parked behind net.offline, nothing confirmed, no further flag written', () async {
    final r = _Rig(direct: ['a', 'b']);
    await r.settle();
    r.alive['dns-a'] = -1;
    await r.round(); // the miss: a suspicion; the traffic moved at once (the network was up)
    r.sentinel.context.platform(connected: false);
    await r.time.advanceSeconds(5);
    expect(r.events('failed'), isEmpty);
    expect(r.sentinel.roots.byKey('dns|a'), isNull);
    await r.round(5); // the network is down: no round
    expect(r.svc.active, 'b');
    expect(r.writes, ['a off miss'], reason: 'nothing more while the network is down');
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
    expect(r.writes, ['x off miss'], reason: 'a rule\'s chain of several transports follows its flag');
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
    expect(r.writes, ['x off miss'], reason: 'the OS resolver has no flag');
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
    expect(r.writes, ['p-doh off miss'], reason: 'the flag follows the transport');
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
    expect(r.writes, ['a off miss']);
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
    expect(n.writes, ['a off miss']);
    final w = n.notes.where((l) => l.startsWith('warn dns flag not applied after')).single;
    expect(w, contains('(direct): expected b, no candidate answers the flagcheck'));
    await n.dispose();

    final u = _Rig(direct: ['a', 'b'], flagNull: true);
    await u.settle();
    u.alive['dns-a'] = -1;
    await u.round(2);
    await u.round(2);
    expect(u.writes, ['a off miss']);
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

  group('DNS on the node (docs/failures.md → DNS на ноде)', () {
    Future<_Rig> vpnRig({bool withNodes = true}) async {
      final r = _Rig(vpn: ['v1', 'v2'], withNodes: withNodes, nodeId: 'N1');
      await r.settle();
      await r.round();
      return r;
    }

    String vkey(_Rig r, String id, String? node) => dnsVerdictKey(r.members[id], node);

    test('a VPN-side miss moves the traffic to the next server at once, while the check still runs', () async {
      final r = await vpnRig();
      r.alive['dns-v1'] = -1;
      await r.round();
      expect(r.svc.active, 'v2');
      expect(r.writes, ['v1 off miss']);
      expect(r.events('failed'), isEmpty);
      expect(r.events('failedOnNode'), isEmpty);
      expect((r.svc.toJson()['servers'] as List).first, containsPair('rechecking', true));
      await r.dispose();
    });

    test('it answers through another node: dns/failedOnNode, dead on this node only', () async {
      final r = await vpnRig();
      r.viaAnswers['v1'] = 30;
      r.alive['dns-v1'] = -1;
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.events('failed'), isEmpty);
      final e = r.events('failedOnNode').single;
      expect(e['data'], containsPair('server', 'v1'));
      expect(e['data'], containsPair('node', 'sub::exit'));
      expect(e['data'], containsPair('via', 'sub::spare'));
      expect(r.verdicts[vkey(r, 'v1', 'N1')]!.node, isTrue);
      expect(r.verdicts.deadOf(dnsServerKey(r.members['v1'])!), isNull, reason: 'the server itself is not dead');
      expect(r.viaAsked.first, 'v1 via spare');
      expect((r.svc.toJson()['servers'] as List).first, containsPair('deadOn', 'node'));
      // another node: the verdict of this one does not apply
      r.nodeId = 'N2';
      expect(dnsDeadOf(r.verdicts, r.members['v1'], 'N2'), isNull);
      await r.dispose();
    });

    test('silent through the other node too: the server itself is dead, its verdict holds for every node', () async {
      final r = await vpnRig();
      r.alive['dns-v1'] = -1; // viaAnswers: silent
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.events('failedOnNode'), isEmpty);
      expect(r.events('failed').single['data'], containsPair('server', 'v1'));
      expect(r.verdicts.deadOf(dnsServerKey(r.members['v1'])!), isTrue);
      expect(r.verdicts[vkey(r, 'v1', 'N1')]!.node, isFalse);
      expect(dnsDeadOf(r.verdicts, r.members['v1'], 'N2'), isTrue, reason: 'dead through every node');
      await r.dispose();
    });

    test('the exit node carries nothing: not the server\'s doing, no event, no verdict', () async {
      final r = await vpnRig();
      r.exitAlive = false;
      r.alive['dns-v1'] = -1;
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.events('failed'), isEmpty);
      expect(r.events('failedOnNode'), isEmpty);
      expect(r.sentinel.roots.byKey('dns|v1'), isNull);
      expect(r.verdicts.deadOf(vkey(r, 'v1', 'N1')), isNot(isTrue));
      expect(r.viaAsked, isEmpty, reason: 'the other node is not asked about a dead exit node');
      await r.dispose();
    });

    test('no spare node (or the transport cannot be asked): the old way, dns/failed on this node\'s key only', () async {
      final r = await vpnRig();
      r.spareTag = null;
      r.alive['dns-v1'] = -1;
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.events('failed').single['data'], containsPair('server', 'v1'));
      expect(r.verdicts.deadOf(vkey(r, 'v1', 'N1')), isTrue);
      expect(r.verdicts.deadOf(dnsServerKey(r.members['v1'])!), isNull);
      await r.dispose();

      final q = await vpnRig();
      q.viaAnswers['v1'] = null; // cannot be asked that way
      q.alive['dns-v1'] = -1;
      await q.round();
      await q.time.advanceSeconds(3);
      expect(q.events('failed'), hasLength(1));
      expect(q.verdicts.deadOf(dnsServerKey(q.members['v1'])!), isNull, reason: 'a silence that proves nothing is no verdict of the server');
      await q.dispose();
    });

    test('an open root of the route explains the miss: nothing switched, no verdict', () async {
      final r = await vpnRig();
      r.sentinel.openRoot(
        kind: 'route.dead',
        key: 'route|proxy',
        subject: {'route': 'proxy', 'path': 'proxy'},
        scope: Scope.of({'route': 'proxy'}),
        level: Level.route,
      );
      r.viaAnswers['v1'] = 30;
      r.alive['dns-v1'] = -1;
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.writes, isEmpty);
      expect(r.svc.active, 'v1');
      expect(r.events('failed'), isEmpty);
      expect(r.events('failedOnNode'), isEmpty);
      expect(r.verdicts.deadOf(vkey(r, 'v1', 'N1')), isNot(isTrue));
      await r.dispose();
    });

    test('a dead VPN-side server is asked again every 20 minutes, a repeat miss is counted on the same event', () async {
      final r = await vpnRig();
      r.alive['dns-v1'] = -1;
      await r.round();
      await r.time.advanceSeconds(3);
      expect(r.sentinel.roots.byKey('dns|v1'), isNotNull);
      int askedV1() => r.asked.where((q) => q.startsWith('dns-v1 ')).length;
      r.asked.clear();
      await r.time.advanceSeconds(10 * 60);
      await r.svc.checkDue();
      expect(askedV1(), 0, reason: 'not before 20 min (the direct side\'s ladder would have asked)');
      await r.time.advanceSeconds(10 * 60);
      await r.svc.checkDue();
      expect(askedV1(), greaterThan(0));
      expect(r.events('failed'), hasLength(1), reason: 'one event; the repeat is counted on it');
      r.alive['dns-v1'] = 20;
      r.asked.clear();
      await r.time.advanceSeconds(20 * 60 + 1);
      await r.svc.checkDue();
      expect(r.sentinel.roots.byKey('dns|v1'), isNull, reason: 'it answered');
      await r.dispose();
    });
  });

  group('verdicts that outlive a failover (dns_verdicts.dart)', () {
    String key(String id, {String side = 'direct', String? node}) => dnsVerdictKey(_c(id, side: side), node);

    test('a server stored as dead that misses again after a reconnect: the verdict stands, no new dns/failed', () async {
      final book = DnsVerdictBook()..record(key('a'), dead: true, at: 1);
      final r = _Rig(direct: ['a', 'b'], verdicts: book);
      await r.settle();
      r.alive['dns-a'] = -1;
      await r.round(2);
      await r.round(2);
      await r.round(2);
      expect(r.events('failed'), isEmpty);
      expect(book.deadOf(key('a')), isTrue);
      expect(r.svc.toJson()['servers'][0]['ok'], isFalse);
      expect(r.svc.active, 'b');
      // an answer after a re-check changes it
      r.alive['dns-a'] = 20;
      await r.svc.check();
      expect(book.deadOf(key('a')), isFalse);
      await r.dispose();
    });

    test('a fresh miss of a round is the confirmation: the server is not asked a second time', () async {
      final r = _Rig(direct: ['a', 'b']);
      await r.settle();
      r.alive['dns-a'] = -1;
      await r.round();
      final asked = r.asked.where((s) => s.startsWith('dns-a ')).length;
      await r.time.advanceSeconds(5);
      expect(r.asked.where((s) => s.startsWith('dns-a ')).length, asked, reason: 'the round was the ask');
      expect(r.events('failed'), hasLength(1));
      expect(r.verdicts.deadOf(key('a')), isTrue);
      await r.dispose();
    });

    test('start: the best that worked answers, the ones above it that never did are off; the stored dead is checked at once', () async {
      final book = DnsVerdictBook()
        ..record(key('b'), dead: false, at: 1)
        ..record(key('c'), dead: true, at: 1);
      final r = _Rig(direct: ['a', 'b', 'c'], verdicts: book);
      expect(r.svc.flags, {'a': false, 'b': true, 'c': false});
      expect(r.svc.active, 'b');
      await r.settle();
      r.svc.start();
      await pumpEventQueue();
      expect(r.asked.map((s) => s.split(' ').first).toSet(), {'dns-c'}, reason: 'only the stored dead one, before firstCheck');
      await r.dispose();
    });

    test('the VPN side is bound to the exit node: the verdict of one node is not the other\'s; a move applies the new node\'s', () async {
      final book = DnsVerdictBook()
        ..record(key('v1', side: 'vpn', node: 'N1'), dead: true, at: 1)
        ..record(key('v2', side: 'vpn', node: 'N1'), dead: false, at: 1);
      final r = _Rig(vpn: ['v1', 'v2'], verdicts: book, nodeId: 'N1');
      expect(r.svc.active, 'v2', reason: 'N1: v1 is dead');
      await r.settle();
      r.nodeId = 'N2';
      await r.svc.nodeChanged();
      expect(r.svc.active, 'v1', reason: 'N2 has no verdict about v1: it answers until proven otherwise');
      await r.dispose();
    });

    test('one check per server at a time: a ping and a round at once ask it once; a network change asks the active server only', () async {
      final r = _Rig(direct: ['a', 'b']);
      await r.settle();
      r.gate = Completer<void>();
      final round = r.svc.check();
      final ping = r.svc.pingProvider('a');
      await pumpEventQueue();
      expect(r.asked.where((s) => s.startsWith('dns-a ')), hasLength(1));
      expect(r.svc.toJson()['servers'][0]['rechecking'], isTrue);
      r.gate!.complete();
      await Future.wait([round, ping]);
      expect(r.svc.toJson()['servers'][0]['rechecking'], isFalse);

      r.svc.start();
      await pumpEventQueue();
      r.asked.clear();
      await r.svc.networkChanged();
      expect(r.asked.map((s) => s.split(' ').first).toSet(), {'dns-a'});
      await r.dispose();
    });

    test('the book survives a restart: written to the file, read back', () async {
      final dir = Directory('.data-dev/dns-verdicts-test')..createSync(recursive: true);
      final file = File('${dir.path}/dns-verdicts.json');
      if (file.existsSync()) file.deleteSync();
      final book = DnsVerdictBook();
      final store = DnsVerdictStore(file, book, debounce: Duration.zero);
      book.record('x|doh|direct', dead: true, at: DateTime.now().millisecondsSinceEpoch);
      book.record('y|doh|vpn|N1', dead: false, at: DateTime.now().millisecondsSinceEpoch);
      await store.close();
      final back = DnsVerdictBook();
      expect(DnsVerdictStore(file, back).load(), 2);
      expect(back.deadOf('x|doh|direct'), isTrue);
      expect(back.deadOf('y|doh|vpn|N1'), isFalse);
      expect(back.deadOf('z|doh|direct'), isNull);
      dir.deleteSync(recursive: true);
    });
  });

  group('protocol race (docs/rules.md §6 → Гонка протоколов)', () {
    _Rig rig({bool vpn = false, String? nodeId, bool auto = true, Set<String> reserve = const {}}) {
      final ids = vpn ? ['v-doh', 'v-dot', 'v-udp'] : ['p-doh', 'p-dot', 'p-udp', 'q-doh'];
      final prov = {for (final i in ids) i: i.startsWith('q') ? 'q' : i.split('-').first};
      final kind = {for (final i in ids) i: i.split('-').last};
      return vpn
          ? _Rig(vpn: ids, providers: prov, kinds: kind, nodeId: nodeId, auto: auto, reserve: reserve)
          : _Rig(direct: ids, providers: prov, kinds: kind, auto: auto, reserve: reserve);
    }

    // The answers of the servers [tags] arrive in this order.
    Future<void> arrive(_Rig r, List<String> tags) async {
      for (final t in tags) {
        r.hold[t]!.complete();
        await pumpEventQueue();
      }
    }

    void held(_Rig r, List<String> tags) {
      r.hold.clear();
      for (final t in tags) {
        r.hold[t] = Completer<void>();
      }
    }

    Future<_Rig> raced() async {
      final r = rig();
      await r.settle();
      r.alive.addAll({'dns-p-doh': 40, 'dns-p-dot': 20, 'dns-p-udp': 5});
      held(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-p-udp', 'dns-p-dot', 'dns-p-doh']); // the winner was chosen at the dot's answer, the doh arrives later
      r.hold.clear();
      return r;
    }

    test('the first encrypted answer wins (plain UDP answered earlier); the others go to reserve; the status says so', () async {
      final r = await raced();
      expect(r.svc.activeOf('direct'), 'p-dot');
      expect(r.writes.toSet(), {'p-doh off reserve', 'p-udp off reserve'});
      expect(await r.log(), isEmpty, reason: 'the winner of a race is an ordinary choice: no switch event');
      expect(r.notes.any((n) => n.contains('dns race (p, direct; start): doh 40ms, dot 20ms, udp 5ms; winner p-dot')), isTrue, reason: '${r.notes}');
      final p = (r.svc.toJson()['providers'] as List).cast<Map>().firstWhere((x) => x['provider'] == 'p');
      expect(p['winner'], {'id': 'p-dot', 'kind': 'dot', 'ms': 20});
      expect(p['racing'], isFalse);
      expect([for (final t in (p['transports'] as List).cast<Map>()) '${t['kind']} ${t['ms']} ${t['state']} ${t['reserve'] ?? false}'],
          ['doh 40 ok true', 'dot 20 ok false', 'udp 5 ok true']);
      await r.dispose();
    });

    test('plain UDP wins only when every encrypted transport is silent', () async {
      final r = rig();
      await r.settle();
      r.alive.addAll({'dns-p-doh': -1, 'dns-p-dot': -1, 'dns-p-udp': 5});
      held(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-p-udp']);
      expect(r.writes, isEmpty, reason: 'UDP answered, but the encrypted ones are not silent yet');
      expect(((r.svc.toJson()['providers'] as List).first as Map)['winner'], isNull);
      await arrive(r, ['dns-p-doh', 'dns-p-dot']);
      expect(r.svc.activeOf('direct'), 'p-udp');
      expect(r.writes.where((w) => w.startsWith('p-udp')), isEmpty);
      await r.dispose();
    });

    test('a ping asks every transport but does not choose again', () async {
      final r = await raced();
      r.alive['dns-p-doh'] = 3; // now the fastest
      r.asked.clear();
      final got = await r.svc.pingProvider('p');
      expect({for (final q in r.asked) q.split(' ').first}, {'dns-p-doh', 'dns-p-dot', 'dns-p-udp'});
      expect([for (final g in got) '${g.kind} ${g.ms}'], ['doh 3', 'dot 20', 'udp 5']);
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'p-dot', reason: 'no flapping over a few ms');
      expect(r.writes, hasLength(2));
      await r.dispose();
    });

    test('a network change races again: the fastest now is put to work', () async {
      final r = await raced();
      r.alive.addAll({'dns-p-doh': 10, 'dns-p-dot': 50});
      held(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      final done = r.svc.networkChanged();
      await pumpEventQueue();
      await arrive(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      await done;
      expect(r.svc.activeOf('direct'), 'p-doh');
      expect(r.writes, containsAll(['p-doh on race', 'p-dot off reserve']));
      expect(await r.log(), isEmpty);
      await r.dispose();
    });

    test('another exit node races the VPN side again', () async {
      final r = rig(vpn: true, nodeId: 'N1');
      await r.settle();
      r.alive.addAll({'dns-v-doh': 40, 'dns-v-dot': 20, 'dns-v-udp': 5});
      held(r, ['dns-v-doh', 'dns-v-dot', 'dns-v-udp']);
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-v-dot', 'dns-v-doh', 'dns-v-udp']);
      expect(r.svc.activeOf('vpn'), 'v-dot');
      r.alive.addAll({'dns-v-doh': 8, 'dns-v-dot': 30});
      held(r, ['dns-v-doh', 'dns-v-dot', 'dns-v-udp']);
      r.nodeId = 'N2';
      await r.svc.nodeChanged();
      await pumpEventQueue();
      await arrive(r, ['dns-v-doh', 'dns-v-dot', 'dns-v-udp']);
      expect(r.svc.activeOf('vpn'), 'v-doh');
      await r.dispose();
    });

    test('the winner fails: another protocol of the same provider, then plain UDP, then the next provider', () async {
      final r = await raced();
      r.alive['dns-p-dot'] = -1;
      await r.round();
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'p-doh', reason: 'known to work, same provider: not q');
      expect(r.writes, containsAllInOrder(['p-dot off miss', 'p-doh on failover']));
      r.alive['dns-p-doh'] = -1;
      await r.round();
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'p-udp', reason: 'every encrypted one is silent now');
      r.alive['dns-p-udp'] = -1;
      await r.round();
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'q-doh', reason: 'the provider is out: the next one by priority');
      await r.dispose();
    });

    test('a restart keeps the reserve: not off, not dead; it stays quiet and is the fallback of its provider when the winner fails', () async {
      // p-dot was at work, p-doh and p-udp in reserve when sing-box was restarted
      final r = rig(reserve: {'p-doh', 'p-udp'});
      await r.settle();
      expect(r.svc.reserve, {'p-doh', 'p-udp'});
      expect(r.svc.flags, containsPair('p-doh', false));
      expect(r.svc.alive('p-doh'), isTrue, reason: 'a reserve works: it may be asked');
      expect(r.svc.activeOf('direct'), 'p-dot');
      await r.round();
      await pumpEventQueue();
      expect(r.writes, isEmpty, reason: 'a reserve does not return on its own over the winner');
      expect(r.svc.reserve, {'p-doh', 'p-udp'});
      r.alive['dns-p-dot'] = -1;
      await r.round();
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'p-doh', reason: 'the reserve took over: same provider, not q');
      expect(r.writes, containsAllInOrder(['p-dot off miss', 'p-doh on failover']));
      expect(await r.log(), ['direct p-dot>p-doh failover']);
      await r.dispose();
    });

    test('Switch automatically off with a race: the winner is tracked, every flag stays on; turning it on applies the choice', () async {
      final r = rig(auto: false);
      await r.settle();
      r.alive.addAll({'dns-p-doh': 40, 'dns-p-dot': 20, 'dns-p-udp': 5});
      held(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-p-udp', 'dns-p-dot', 'dns-p-doh']);
      r.hold.clear();
      expect(r.writes, isEmpty, reason: 'auto off: no flag is turned off');
      expect(r.svc.flags.values.every((on) => on), isTrue);
      expect(r.svc.activeOf('direct'), 'p-doh', reason: 'the top candidate answers while every flag is on');
      expect(r.svc.reserve, isEmpty);
      await r.svc.setAuto(true);
      await pumpEventQueue();
      expect(r.svc.activeOf('direct'), 'p-dot');
      expect(r.writes.toSet(), {'p-doh off reserve', 'p-udp off reserve'});
      expect(await r.log(), isEmpty, reason: 'the winner of a race is a plain choice');
      await r.dispose();
    });

    test('a failed flag write during a race is visible and written again at the next round', () async {
      final r = rig();
      await r.settle();
      r.alive.addAll({'dns-p-doh': 40, 'dns-p-dot': 20, 'dns-p-udp': 5});
      held(r, ['dns-p-doh', 'dns-p-dot', 'dns-p-udp']);
      r.refuseMode = true;
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-p-udp', 'dns-p-dot', 'dns-p-doh']);
      r.hold.clear();
      expect(r.writes, isEmpty);
      expect(r.notes.any((n) => n.startsWith('warn dns flag: p-doh stays on (reserve): the write failed')), isTrue, reason: '${r.notes}');
      expect(r.svc.activeOf('direct'), 'p-doh', reason: 'the flags did not change: the old one answers');
      r.refuseMode = false;
      await r.round();
      await pumpEventQueue();
      expect(r.writes.toSet(), {'p-doh off reserve', 'p-udp off reserve'});
      expect(r.svc.activeOf('direct'), 'p-dot');
      await r.dispose();
    });

    test('a dead transport is not asked by the race and cannot win', () async {
      final r = rig();
      r.verdicts.record(dnsVerdictKey(r.members['p-dot'], null), dead: true, at: 1);
      await r.settle();
      r.alive.addAll({'dns-p-doh': 40, 'dns-p-dot': -1, 'dns-p-udp': 5});
      held(r, ['dns-p-doh', 'dns-p-udp']);
      r.svc.start();
      await pumpEventQueue();
      await arrive(r, ['dns-p-udp', 'dns-p-doh']);
      expect(r.svc.activeOf('direct'), 'p-doh', reason: 'dot is dead; plain UDP does not win while doh answers');
      expect(r.notes.any((n) => n.contains('dns race (p, direct; start): asking p-doh, p-udp')), isTrue, reason: '${r.notes}');
      expect(r.notes.any((n) => n.contains('dot dead') && n.contains('winner p-doh')), isTrue, reason: '${r.notes}');
      await r.dispose();
    });

    test('a race owed while the network is down runs when it is up', () async {
      final r = rig();
      r.uncertain = true;
      await r.settle();
      r.svc.start();
      await pumpEventQueue();
      expect(r.asked.where((q) => q.startsWith('dns-p-')), isEmpty);
      r.uncertain = false;
      await r.round();
      await pumpEventQueue();
      expect(r.notes.any((n) => n.contains('dns race (p, direct; start)')), isTrue, reason: '${r.notes}');
      await r.dispose();
    });
  });
}
