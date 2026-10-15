// The controller's exit checks (auto.dart): pinned to the node's own outbound, the answer is that node's by
// construction; a switch does not cancel a running check; the status' exit is the node in use's; the stored answer is
// shown at once and a node is asked in the background at most once per AutoService.exitEvery.
import 'dart:async';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox, everyRound, plan, unit;

String _idOf(Map<String, dynamic> p, int route) {
  final main = ((p['routes'] as List)[route] as Map)['main'] as Map;
  return serverIdentity(((main['nodes'] as List).single as Map)['outbound'] as Map);
}

void main() {
  test('pinned checks: the answer is recorded for its node, a switch mid-check cancels nothing, the status follows the node in use', () async {
    final p = plan([unit('A', ['s::a'], pick: 'priority', chosen: 's::a'), unit('B', ['s::b'], pick: 'priority', chosen: 's::b')]);
    final fake = FakeBox(buildConfig(p), {'s::a': 10, 's::b': 10});
    final gates = <String, Completer<Map<String, dynamic>>>{};
    final asked = <String>[];
    var changed = 0;
    final book = ExitBook();
    final auto = AutoService(fake, p,
        delay: fake.delayTest,
        pool: everyRound(),
        exits: book,
        exitCheck: (tag) {
          asked.add(tag);
          return (gates[tag] ??= Completer()).future;
        },
        onExit: () => changed++);
    auto.start();
    expect(asked, ['route0/s::a'], reason: 'the node in use is asked through its own outbound');
    expect(auto.exitInUse(), isNull, reason: 'being checked, nothing known yet');

    // the user moves to B while A's check runs: A's goes on, B gets its own
    expect(await auto.setManual(true, entry: 'B'), isTrue);
    expect(asked, ['route0/s::a', 'route1/s::b']);

    gates['route0/s::a']!.complete({'ip': '203.0.113.1', 'country': 'DE'});
    await Future<void>.delayed(Duration.zero);
    expect([book[_idOf(p, 0)]?.ip, book[_idOf(p, 0)]?.country], ['203.0.113.1', 'DE'], reason: 'recorded for A, not for the node in use');
    expect(book[_idOf(p, 1)], isNull);
    expect(auto.exitInUse(), isNull, reason: 'the status waits for B, A\'s answer is not shown as the node in use\'s');

    gates['route1/s::b']!.complete({'ip': '203.0.113.2', 'country': 'FR', 'city': 'Paris'});
    await Future<void>.delayed(Duration.zero);
    expect(auto.exitInUse(), containsPair('ip', '203.0.113.2'));
    expect(auto.exitInUse(), containsPair('direct', false));
    expect(book[_idOf(p, 1)]!.country, 'FR');
    expect(changed, greaterThan(0));
    auto.stop();
  });

  group('scouts', () {
    // r0 is in use (and has the provider's flag), r1 has a country from an earlier check, r2..r6 are unknown, r7 does not answer.
    // standby 10: every route is tested each round, so every one that answers is a working node
    Map<String, dynamic> scoutPlan() {
      final p = plan([for (var i = 0; i < 8; i++) unit('R$i', ['s::r$i'], pick: 'priority', chosen: 's::r$i')], auto: {'standby': 10});
      ((p['routes'] as List)[0]['main']['nodes'] as List)[0]['flag'] = '🇩🇪';
      return p;
    }

    FakeBox boxOf(Map<String, dynamic> p) => FakeBox(buildConfig(p), {for (var i = 0; i < 7; i++) 's::r$i': 10});

    // the node in use is asked on its own account; the scouts are the others
    List<String> scoutsOf(List<String> asked) => [for (final t in asked) if (!t.endsWith('s::r0')) t];

    Future<void> round(AutoService auto) async {
      await auto.check();
      await Future<void>.delayed(Duration.zero);
    }

    test('working nodes with no flag and no known country: once per interval, at most 3 a round; the network does not matter', () async {
      final p = scoutPlan();
      var now = 1000000000000;
      final book = ExitBook()..record(_idOf(p, 1), ip: '198.51.100.2', country: 'FR', at: 1);
      final asked = <String>[];
      final auto = AutoService(boxOf(p), p, delay: boxOf(p).delayTest, pool: everyRound(), clock: () => now, exits: book, exitCheck: (tag) async {
        asked.add(tag);
        return {'ip': '203.0.113.${asked.length}'}; // names no country: the node stays unknown, only the timer keeps it from being asked again
      });
      await round(auto);
      expect(scoutsOf(asked), hasLength(3), reason: 'at most 3 a round');
      expect(scoutsOf(asked), everyElement(isNot(anyOf(endsWith('s::r1'), endsWith('s::r7')))), reason: 'a known country, a node that does not answer: not asked');

      await round(auto);
      expect(scoutsOf(asked), hasLength(5), reason: 'the rest of the unknown ones');
      expect(scoutsOf(asked).toSet(), hasLength(5), reason: 'the asked are not asked again');
      await round(auto);
      expect(scoutsOf(asked), hasLength(5), reason: 'once per interval');
      expect([for (var i = 2; i <= 6; i++) book[_idOf(p, i)]], everyElement(isNotNull), reason: 'the answers are recorded per node');

      auto.networkChanged(); // a node's exit does not depend on the network
      await round(auto);
      expect(scoutsOf(asked), hasLength(5), reason: 'another network asks nothing');

      now += AutoService.exitEvery.inMilliseconds - const Duration(minutes: 1).inMilliseconds;
      await round(auto);
      expect(scoutsOf(asked), hasLength(5), reason: 'not yet the interval');
      now += const Duration(minutes: 2).inMilliseconds;
      await round(auto);
      expect(scoutsOf(asked), hasLength(8), reason: 'the interval passed: asked again, 3 of them');
      auto.stop();
    });

    test('a failed scout is not asked again within the interval', () async {
      final p = scoutPlan();
      var now = 1000000000000;
      final asked = <String>[];
      final auto = AutoService(boxOf(p), p, delay: boxOf(p).delayTest, pool: everyRound(), clock: () => now, exitCheck: (tag) async {
        asked.add(tag);
        throw Exception('no answer');
      });
      for (var i = 0; i < 4; i++) {
        await round(auto);
      }
      expect(scoutsOf(asked), hasLength(6));
      expect(scoutsOf(asked).toSet(), hasLength(6), reason: 'a failure is no reason to ask a node again');
      now += AutoService.exitEvery.inMilliseconds + const Duration(minutes: 1).inMilliseconds;
      await round(auto);
      expect(scoutsOf(asked), hasLength(9), reason: 'an interval later it is asked again');
      auto.stop();
    });

    test('Manual asks no scouts', () async {
      final p = scoutPlan();
      final asked = <String>[];
      final auto = AutoService(boxOf(p), p, delay: boxOf(p).delayTest, pool: everyRound(), exitCheck: (tag) async {
        asked.add(tag);
        return {'ip': '203.0.113.1'};
      });
      await auto.setManual(true);
      await round(auto);
      expect(scoutsOf(asked), isEmpty, reason: 'Manual uses no other node');
      auto.stop();
    });
  });

  group('retry', () {
    test('a quick failure of the node in use is asked again in 2 s', () async {
      final p = plan([unit('A', ['s::a'], pick: 'priority', chosen: 's::a')]);
      final fake = FakeBox(buildConfig(p), {'s::a': 10});
      var calls = 0;
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), exitCheck: (tag) async {
        if (++calls == 1) throw Exception('tunnel is not carrying yet');
        return {'ip': '203.0.113.3'};
      });
      auto.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls, 1);
      expect(auto.exitInUse(), isNull, reason: 'still being checked, no error shown');
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(calls, 2);
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.3'));
      auto.stop();
    });

    test('a node the user has left is not asked again: its error stands', () async {
      final p = plan([unit('A', ['s::a'], pick: 'priority', chosen: 's::a'), unit('B', ['s::b'], pick: 'priority', chosen: 's::b')]);
      final fake = FakeBox(buildConfig(p), {'s::a': 10, 's::b': 10});
      final asked = <String>[];
      final auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), exitCheck: (tag) async {
        asked.add(tag);
        if (tag.endsWith('s::b')) return {'ip': '203.0.113.4'};
        throw Exception('no answer');
      });
      auto.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await auto.setManual(true, entry: 'B'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(asked.where((t) => t.endsWith('s::a')), hasLength(1), reason: 'A is not in use any more: no second try');
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.4'));
      auto.stop();
    });
  });

  group('schedule', () {
    const hour = AutoService.exitEvery;
    var now = 1000000000000;
    late Map<String, dynamic> p;
    late ExitBook book;
    late List<String> asked;
    late List<Completer<Map<String, dynamic>>> gates;
    late FakeBox fake;
    late AutoService auto;

    String idA() => _idOf(p, 0);

    // [storedAgo]: ms since the stored exit of A (none when negative); the nodes are one route each, A first
    AutoService make({int storedAgo = -1, List<String> keys = const ['s::a', 's::b']}) {
      now = 1000000000000;
      p = plan([for (final k in keys) unit(k.split('::')[1].toUpperCase(), [k], pick: 'priority', chosen: k)]);
      fake = FakeBox(buildConfig(p), {for (final k in keys) k: 10});
      book = ExitBook();
      if (storedAgo >= 0) book.record(idA(), ip: '203.0.113.1', country: 'DE', at: now - storedAgo);
      asked = [];
      gates = [];
      return auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), clock: () => now, exits: book, exitCheck: (tag) {
        asked.add(tag);
        final c = Completer<Map<String, dynamic>>();
        gates.add(c);
        return c.future;
      });
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    tearDown(() => auto.stop());

    test('the stored answer is shown at once, no check within the hour', () async {
      make(storedAgo: const Duration(minutes: 10).inMilliseconds);
      auto.start();
      expect(auto.exitInUse(), allOf(containsPair('ip', '203.0.113.1'), containsPair('country', 'DE'), containsPair('direct', false)));
      expect(asked, isEmpty, reason: 'checked 10 minutes ago');

      // a switch away and back inside the hour asks nothing for A
      await auto.setManual(true, entry: 'B');
      expect(asked, ['route1/s::b'], reason: 'B was never checked');
      await auto.setManual(true, entry: 'A');
      expect(asked, ['route1/s::b']);
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.1'));
    });

    test('an old answer is shown while the check runs; a different result replaces it and the book', () async {
      make(storedAgo: hour.inMilliseconds + 1);
      auto.start();
      expect(asked, ['route0/s::a']);
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.1'), reason: 'the stored answer stays on the status meanwhile');

      gates[0].complete({'ip': '203.0.113.9', 'country': 'FR', 'city': 'Paris'});
      await settle();
      expect(auto.exitInUse(), allOf(containsPair('ip', '203.0.113.9'), containsPair('country', 'FR'), containsPair('city', 'Paris')));
      expect([book[idA()]!.ip, book[idA()]!.country, book[idA()]!.at], ['203.0.113.9', 'FR', now]);
    });

    test('a good check always replaces the shown answer with the fresh one, the same IP or not', () async {
      make();
      auto.start();
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE', 'city': 'Berlin'});
      await settle();
      final first = book[idA()]!.at;
      now += hour.inMilliseconds + 5;
      await auto.setManual(true, entry: 'B');
      await auto.setManual(true, entry: 'A');
      expect(asked, ['route0/s::a', 'route1/s::b', 'route0/s::a'], reason: 'the hour passed');
      gates[2].complete({'ip': '203.0.113.1', 'country': 'DE', 'city': 'Frankfurt', 'org': 'Example'});
      await settle();
      expect(auto.exitInUse(), allOf(containsPair('ip', '203.0.113.1'), containsPair('city', 'Frankfurt'), containsPair('org', 'Example'), containsPair('at', now)));
      expect(book[idA()]!.at, greaterThan(first));
    });

    test('an answer from the book (ip and country only) is replaced whole by the fresh one of the same IP', () async {
      make(storedAgo: hour.inMilliseconds + 1);
      auto.start();
      expect(auto.exitInUse(), isNot(contains('city')), reason: 'the book keeps ip and country only');
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE', 'city': 'Berlin', 'org': 'Example'});
      await settle();
      expect(auto.exitInUse(), allOf(containsPair('city', 'Berlin'), containsPair('org', 'Example')));
    });

    test('nodes of one host: each check is asked through its own tag and its answer stays with its node (Manual picks, rechecks)', () async {
      // three nodes behind one bridge host (as the Remnawave "HY2 NL / HY2 DE / REALITY DE"): different outbounds, one address
      final p = plan([for (final k in ['s::hy2nl', 's::hy2de', 's::realde']) unit(k.split('::')[1], [k], pick: 'priority', chosen: k)]);
      final fake = FakeBox(buildConfig(p), {'s::hy2nl': 10, 's::hy2de': 10, 's::realde': 10});
      final ips = {'route0/s::hy2nl': '185.130.225.66', 'route1/s::hy2de': '37.1.194.233', 'route2/s::realde': '37.1.194.234'};
      final asked = <String>[];
      final lines = <String>[];
      auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), exits: ExitBook(), trace: lines.add, exitCheck: (tag) async {
        asked.add(tag);
        return {'ip': ips[tag]};
      });
      auto.start();
      await settle();
      expect(auto.exitInUse(), containsPair('ip', '185.130.225.66'));
      for (final (entry, ip) in [('hy2de', '37.1.194.233'), ('realde', '37.1.194.234')]) {
        await auto.setManual(true, entry: entry);
        await settle();
        expect(auto.exitInUse(), containsPair('ip', ip), reason: '$entry: its own answer, not the one of the node picked before');
        auto.recheckExit();
        await settle();
        expect(auto.exitInUse(), containsPair('ip', ip), reason: '$entry: a re-check asks through its own tag');
      }
      expect(asked.where((t) => t.startsWith('route2')), hasLength(2), reason: 'the pick and the re-check');
      expect(asked.where((t) => t == 'route0/s::hy2nl'), hasLength(1), reason: 'the first node is not asked again for the others');
      expect(lines.where((l) => l.contains('route2/s::realde') && l.contains('37.1.194.234')), hasLength(2), reason: 'every check leaves a line: tag, node, answer');
    });

    test('the timer runs from the last completed check', () async {
      make();
      auto.start();
      now += AutoService.exitEvery.inMilliseconds * 3 ~/ 4;
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE'}); // answered three quarters of the interval in
      await settle();
      now += AutoService.exitEvery.inMilliseconds ~/ 2; // more than the interval from the start, half of it from the answer
      await auto.setManual(true, entry: 'B');
      await auto.setManual(true, entry: 'A');
      expect(asked.where((t) => t.endsWith('s::a')), hasLength(1));
      now += AutoService.exitEvery.inMilliseconds ~/ 2 + 1000;
      await auto.setManual(true, entry: 'B');
      await auto.setManual(true, entry: 'A');
      expect(asked.where((t) => t.endsWith('s::a')), hasLength(2));
    });

    test('a subscription update forces the check of its nodes and moves the timer', () async {
      make(storedAgo: const Duration(minutes: 5).inMilliseconds, keys: ['s::a', 't::b']);
      auto.start();
      expect(asked, isEmpty);
      auto.exitSourceRefreshed('x'); // no node of it here
      expect(asked, isEmpty);
      auto.exitSourceRefreshed('s');
      expect(asked, ['route0/s::a'], reason: 'regardless of the timer');
      now += 1000;
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE'});
      await settle();
      expect(book[idA()]!.at, now, reason: 'the timer moved to that check');

      // the other subscription's node, updated too, is asked once when it is next in use
      auto.exitSourceRefreshed('t');
      expect(asked, hasLength(1), reason: 'not the node in use');
      await auto.setManual(true, entry: 'B');
      expect(asked, ['route0/s::a', 'route1/t::b']);
      gates[1].complete({'ip': '203.0.113.2', 'country': 'FR'});
      await settle();
      await auto.setManual(true, entry: 'A');
      await auto.setManual(true, entry: 'B');
      expect(asked, hasLength(2), reason: 'the mark is used up, the timer is back');
    });

    test('a subscription update asks the scouts regardless of the timer', () async {
      final sp = plan([unit('R0', ['s::r0'], pick: 'priority', chosen: 's::r0'), unit('R1', ['t::r1'], pick: 'priority', chosen: 't::r1')], auto: {'standby': 10});
      ((sp['routes'] as List)[0]['main']['nodes'] as List)[0]['flag'] = '🇩🇪';
      now = 1000000000000;
      final fb = FakeBox(buildConfig(sp), {'s::r0': 10, 't::r1': 10});
      final bk = ExitBook()..record(_idOf(sp, 1), ip: '198.51.100.2', at: now - 1000); // checked, named no country
      final tags = <String>[];
      final a = AutoService(fb, sp, delay: fb.delayTest, pool: everyRound(), clock: () => now, exits: bk, exitCheck: (tag) async {
        tags.add(tag);
        return {'ip': '198.51.100.2'};
      });
      await a.check();
      await settle();
      expect(tags.where((t) => t.endsWith('t::r1')), isEmpty, reason: 'checked a second ago');
      a.exitSourceRefreshed('t');
      await a.check();
      await settle();
      expect(tags.where((t) => t.endsWith('t::r1')), hasLength(1));
      a.stop();
    });

    test('another network asks no node', () async {
      make();
      auto.start();
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE'});
      await settle();
      auto.networkChanged();
      auto.networkChanged();
      expect(asked, hasLength(1));
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.1'));
    });

    test('the user\'s re-check ignores the timer, keeps the answer shown as rechecking, a failure is shown next to it', () async {
      make(storedAgo: 1000);
      auto.start();
      expect(asked, isEmpty);
      final stored = auto.exitInUse();
      expect(stored, containsPair('ip', '203.0.113.1'));
      expect(stored, isNot(contains('rechecking')));
      auto.recheckExit();
      expect(asked, ['route0/s::a']);
      expect(auto.exitInUse(), allOf(containsPair('ip', '203.0.113.1'), containsPair('rechecking', true)), reason: 'the old answer stays while the new one is awaited');
      auto.recheckExit();
      expect(asked, hasLength(1), reason: 'the one running answers');
      await Future<void>.delayed(const Duration(milliseconds: 3100)); // a quick failure of the node in use is retried (above)
      gates[0].completeError(Exception('no answer'));
      await settle();
      final failed = auto.exitInUse();
      expect(failed, allOf(containsPair('ip', '203.0.113.1'), containsPair('error', 'Exception: no answer')), reason: 'the user asked: the failure is shown next to the kept answer');
      expect(failed, isNot(contains('rechecking')));

      auto.recheckExit();
      expect(auto.exitInUse(), isNot(contains('error')), reason: 'asked again: the old failure is gone');
      gates[asked.lastIndexOf('route0/s::a')].complete({'ip': '203.0.113.5'}); // (a round may have asked the scout B meanwhile)
      await settle();
      final ok = auto.exitInUse();
      expect(ok, containsPair('ip', '203.0.113.5'));
      expect(ok, allOf(isNot(contains('error')), isNot(contains('rechecking'))));
    });

    test('a refresh mark in the book (set while no controller ran) makes the next check ignore the timer, once', () async {
      make(storedAgo: 1000, keys: ['s::a', 't::b']);
      book.markRefresh(idA());
      auto.start();
      expect(asked, ['route0/s::a'], reason: 'checked 1 s ago, but its subscription was updated');
      expect(book[idA()]!.refresh, isFalse, reason: 'taken off by the check that starts');
      gates[0].complete({'ip': '203.0.113.1', 'country': 'DE'});
      await settle();
      await auto.setManual(true, entry: 'B');
      await auto.setManual(true, entry: 'A');
      expect(asked.where((t) => t.endsWith('s::a')), hasLength(1), reason: 'the timer is back');
    });

    test('a failed background check leaves the stored answer on the status', () async {
      make(storedAgo: hour.inMilliseconds + 1);
      final notes = <String>[];
      auto.stop();
      auto = AutoService(fake, p, delay: fake.delayTest, pool: everyRound(), clock: () => now, exits: book, trace: notes.add, exitCheck: (tag) async {
        asked.add(tag);
        await Future<void>.delayed(const Duration(milliseconds: 3100)); // a quick failure of the node in use is retried (above)
        throw Exception('no answer');
      });
      auto.start();
      await Future<void>.delayed(const Duration(milliseconds: 3300));
      expect(asked.where((t) => t.endsWith('s::a')), hasLength(1));
      expect(auto.exitInUse(), allOf(containsPair('ip', '203.0.113.1'), containsPair('error', 'Exception: no answer')), reason: 'any failed check is shown next to the kept answer');
      expect(auto.exitInUse(), isNot(contains('rechecking')));
    });

    test('a switch to a node with a stored answer shows it as rechecking until the check ends', () async {
      make(storedAgo: const Duration(minutes: 10).inMilliseconds);
      book.record(_idOf(p, 1), ip: '198.51.100.7', country: 'FR', at: now - hour.inMilliseconds - 1);
      auto.start();
      expect(asked, isEmpty);
      await auto.setManual(true, entry: 'B');
      expect(asked, ['route1/s::b']);
      expect(auto.exitInUse(), allOf(containsPair('ip', '198.51.100.7'), containsPair('rechecking', true)));
      gates[0].complete({'ip': '198.51.100.8', 'country': 'FR'});
      await settle();
      final done = auto.exitInUse();
      expect(done, containsPair('ip', '198.51.100.8'));
      expect(done, isNot(contains('rechecking')));
    });

    test('an older check never replaces a newer answer', () async {
      make();
      auto.start();
      auto.exitSourceRefreshed('s'); // a second, newer check while the first still runs
      expect(gates, hasLength(2));
      gates[1].complete({'ip': '203.0.113.9'});
      await settle();
      gates[0].complete({'ip': '198.51.100.1'});
      await settle();
      expect(auto.exitInUse(), containsPair('ip', '203.0.113.9'));
      expect(book[idA()]!.ip, '203.0.113.9');
    });
  });

  test('a manual pick the group cannot hold is a connection warning, never a quiet fallback to the first server', () {
    final p = plan([unit('A', ['s::a', 's::b'], pick: 'priority', chosen: 's::gone')]);
    ((p['routes'] as List)[0]['main'] as Map)['pinned'] = true;
    final warnings = <String>[];
    buildConfig(p, warnings: warnings);
    expect(warnings, [contains('s::gone')], reason: 'the pick is named, with the server the tunnel is on instead');
    final ok = plan([unit('A', ['s::a', 's::b'], pick: 'priority', chosen: 's::b')]);
    ((ok['routes'] as List)[0]['main'] as Map)['pinned'] = true;
    final none = <String>[];
    buildConfig(ok, warnings: none);
    expect(none, isEmpty);
    final lost = plan([unit('A', ['s::a', 's::b'])]);
    ((lost['routes'] as List)[0]['main'] as Map)['pinLost'] = 's::x';
    final w2 = <String>[];
    buildConfig(lost, warnings: w2);
    expect(w2, [contains('s::x')]);
  });
}
