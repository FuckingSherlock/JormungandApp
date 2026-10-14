// The site-failure check scheme as CoreService runs it (docs/failures.md → Проверки сайтов): the order of the checks
// (the same node, the scout beside the external checker, the other subscriptions), the micro-failure, «dead
// everywhere» and the ignoring of failures by the ladder, the memo shared by both reporters. A fake sing-box (runner
// and API service, so Auto exists and names routes by entry id), time by hand (FakeTime); the probes are the service's
// seams. The limits of `siteRetry` themselves are Auto's (auto_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

/// An API service that is not sing-box's: no groups, no connections.
class _Api extends SingBoxApi {
  _Api() : super(0, '');
  final _closed = StreamController<ClosedConnection>.broadcast();
  @override
  Map<String, String> get selected => const {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => true;
  @override
  Future<Map<String, int>?> testGroup(String group, {String? leaving, required Duration timeout}) async => null;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<bool> closeAllConnections() async => true;
  @override
  Stream<ClosedConnection> closedConnections() => _closed.stream;
  @override
  void watch() {}
  @override
  Future<void> close() async {}
}

class _Runner implements BoxRunner {
  bool up = false;
  final _api = _Api();
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;

  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => up ? _api : null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
  @override
  Future<void> stop() async => up = false;
}

Map<String, dynamic> _body() => {
      'plan': {
        'routes': [
          {
            'id': 'A',
            'kind': 'unit',
            'main': {
              'pick': 'priority',
              'chosen': 's::a',
              'nodes': [
                {
                  'key': 's::a',
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
              ],
            },
          },
        ],
        'mixedPort': 2080,
        'global': true,
      },
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late FakeTime time;

  // what the probes and the checker were asked, in order
  late List<String> calls;
  // the answers: the same node, the scout, the other subscriptions; whether the external checker finds the site open
  late bool? sameOpens;
  late AltReach scoutSays, elsewhereSays;
  late bool checkerOpens;
  AltReach? scoutGiven;

  int count(String what) => calls.where((c) => c == what).length;

  Future<void> start() async {
    tmp = await Directory.systemTemp.createTemp('jorm-scheme');
    time = FakeTime();
    calls = [];
    sameOpens = false;
    scoutSays = const AltReach(unsure: true);
    elsewhereSays = const AltReach();
    checkerOpens = true;
    scoutGiven = null;
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      sentinelClock: time.clock,
      siteChecker: SiteChecker(
        now: () => time.t, // its cache of 10 min runs on the same clock
        delay: (_) async {},
        get: (url, {proxyPort, timeout = Duration.zero}) async {
          const nodes = {'a': ['de', 'Germany', 'Frankfurt'], 'b': ['fr', 'France', 'Paris']};
          if (url.pathSegments.last == 'check-http') {
            calls.add('checker');
            return (status: 200, body: jsonEncode({'ok': 1, 'request_id': 'r', 'nodes': nodes}));
          }
          final one = checkerOpens ? [[1, 0.2, 'OK', '200', '1.1.1.1']] : [[0, 5.0, 'Connection timed out']];
          return (status: 200, body: jsonEncode({for (final k in nodes.keys) k: one}));
        },
      ),
    );
    await svc.init();
    svc.probeSame = (o, d, c) async {
      calls.add('same');
      return sameOpens;
    };
    svc.probeScout = (o, d, c) async {
      calls.add('scout');
      return scoutSays;
    };
    svc.probeElsewhere = (o, d, s, c) async {
      calls.add('elsewhere');
      scoutGiven = s;
      return elsewhereSays;
    };
    await svc.connect(_body());
    await time.advanceSeconds(6); // settled
    calls.clear();
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  /// Auto's notice: the entry id as the route, the server's own outbound tag.
  Future<void> autoFail(String dest) async {
    svc.siteFailed(AutoSiteFail(route: 'A', server: 's::a', tag: 'route0/s::a', dest: dest, at: 1));
    await time.advance(Duration.zero);
  }

  /// The connection book's streak: the tag prefix as the route.
  Future<void> bookFail(String host) async {
    final r = FailureReport(
      key: FailureBook.siteKey(host, 443),
      subject: {'host': host, 'port': 443, 'outbound': 'route0/s::a', 'route': 'route0', 'path': 'proxy'},
      data: {'host': host, 'port': 443, 'outbound': 'route0/s::a', 'route': 'route0', 'kind': 'refused', 'count': 3, 'windowMs': 60000, 'source': 'closed'},
      bg: false,
      firstSeen: time.t,
      kind: ConnKind.refused,
    );
    unawaited(svc.failures.report!(r));
    await time.advanceSeconds(11); // the connection book's window
  }

  List<Map> siteEvents() => [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') e];
  List<Map> conn() => [for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'conn' && e['type'] == 'failing') e];
  bool notifies(Map e) => eventNotifies(null, EventRecord.fromJson(e));
  int repeats(Map e) => ((e['data'] as Map)['repeat'] as Map?)?['count'] as int? ?? 1;
  List<String> rawLines(String host) => [for (final l in (svc.log()['lines'] as List).cast<Map>()) if ('${l['msg']}'.contains(host)) '${l['msg']}'];

  group('the order of the checks', () {
    test('the same node first, then the scout beside the checker, then the other subscriptions (with the scout\'s answer)', () async {
      await start();
      scoutSays = const AltReach(tried: [(route: 'B', server: 'y::b')], subs: ['y']);
      await autoFail('order.example:443');
      expect(calls.first, 'same');
      expect(calls.toSet(), {'same', 'scout', 'checker', 'elsewhere'});
      expect(calls.last, 'elsewhere', reason: 'the other subscriptions are the last step');
      expect(calls.indexOf('scout'), lessThan(calls.indexOf('elsewhere')));
      expect(calls.indexOf('checker'), lessThan(calls.indexOf('elsewhere')));
      expect(scoutGiven?.subs, ['y'], reason: 'elsewhere gets the scout\'s answer: its subscription is not repeated');
      final e = siteEvents().single;
      expect([e['type'], e['verdict']], ['unreachable', 'confirmed']);
    });

    test('the scout opens the site: site/blocked, the other subscriptions are not asked (the checker still is, beside the scout)', () async {
      await start();
      scoutSays = const AltReach(via: 'B', viaServer: 'y::b');
      await autoFail('scout.example:443');
      expect(calls, isNot(contains('elsewhere')));
      expect(count('checker'), 1);
      expect(siteEvents().single['type'], 'blocked');
    });

    test('the checker says it does not open: the other subscriptions are skipped, the verdict is «dead», quiet', () async {
      await start();
      checkerOpens = false;
      scoutSays = const AltReach(tried: [(route: 'B', server: 'y::b')]);
      await autoFail('skip.example:443');
      expect(calls, isNot(contains('elsewhere')));
      final e = siteEvents().single;
      expect([e['type'], e['verdict']], ['unreachable', 'unexplained']);
      expect(((e['data'] as Map)['check'] as Map)['state'], 'down');
      expect(notifies(e), isFalse);
    });

    test('a micro-failure (the same node opens the site again): the raw log only, no event, no scout, no checker', () async {
      await start();
      sameOpens = true;
      await autoFail('blip.example:443');
      expect(calls, ['same']);
      expect(siteEvents(), isEmpty);
      expect(conn(), isEmpty);
      expect(rawLines('blip.example').any((l) => l.contains('micro-failure')), isTrue);
    });

    test('the scout is a node of the failing entry: site/blocked carries viaTarget node:<server> (a rule for the entry would not help); another entry has none', () async {
      await start();
      scoutSays = const AltReach(via: 'A', viaServer: 's::b');
      await autoFail('node.example:443');
      scoutSays = const AltReach(via: 'B', viaServer: 'y::b');
      await autoFail('entry.example:443');
      final byHost = {for (final e in siteEvents()) '${(e['data'] as Map)['host']}': e['data'] as Map};
      expect([byHost['node.example']!['via'], byHost['node.example']!['viaTarget']], ['A', 'node:s::b']);
      expect(byHost['entry.example']!['via'], 'B');
      expect(byHost['entry.example']!.containsKey('viaTarget'), isFalse);
    });
  });

  group('dead everywhere', () {
    test('no notification; 90 min of failures are counted on the event with no probes and no checker; then the checker alone looks; a connection that gets data back clears it', () async {
      await start();
      checkerOpens = false;
      await autoFail('dead.example:443');
      final e = siteEvents().single;
      final id = e['id'];
      expect(notifies(e), isFalse);
      final probes = [count('same'), count('scout'), count('checker')];
      expect(probes.every((n) => n > 0), isTrue);

      for (var i = 0; i < 3; i++) {
        await time.advanceSeconds(25 * 60);
        await autoFail('dead.example:443'); // 25, 50, 75 min
      }
      expect([count('same'), count('scout'), count('checker')], probes, reason: 'counted on the event, nothing is asked');
      expect(repeats(siteEvents().single), 4);
      expect(siteEvents().single['id'], id);
      expect(rawLines('dead.example').where((l) => l.contains('again, ')).length, 3);

      // after the 90 min the first failure runs the checker alone: still down for it — 90 min more
      await time.advanceSeconds(16 * 60);
      await autoFail('dead.example:443');
      expect([count('same'), count('scout'), count('checker')], [probes[0], probes[1], probes[2] + 1], reason: 'only the checker looks again');
      expect(repeats(siteEvents().single), 5);
      await time.advanceSeconds(60 * 60);
      await autoFail('dead.example:443');
      expect(count('checker'), probes[2] + 1, reason: 'the new 90 min are on');

      // the site opens through that route: the memo is gone, the next failure is judged anew
      svc.failures.worked!('dead.example', 443, 'route0/s::a');
      await autoFail('dead.example:443');
      expect(count('same'), probes[0] + 1);
      expect(siteEvents().length, 2, reason: 'a new episode of the site: its own event');
      expect(siteEvents().map((e) => e['id']), contains(id));
    });

    test('the checker opens it after the 90 min: the whole check runs again from the first step', () async {
      await start();
      checkerOpens = false;
      await autoFail('revive.example:443');
      final same = count('same');
      await time.advanceSeconds(91 * 60);
      checkerOpens = true;
      await autoFail('revive.example:443');
      expect(count('same'), same + 1);
      expect(count('scout'), 2);
      expect(siteEvents().single['verdict'], 'confirmed');
    });
  });

  group('the ladder of a site the checker opens', () {
    test('failures are only counted for 5, 15, 30, 60, 60 min after each full check', () async {
      await start();
      await autoFail('ladder.example:443');
      expect(notifies(siteEvents().single), isTrue);
      final id = siteEvents().single['id'];
      for (final wait in [5, 15, 30, 60, 60]) {
        final before = count('same');
        await time.advanceSeconds(wait * 60 - 30);
        await autoFail('ladder.example:443');
        expect(count('same'), before, reason: 'inside the $wait min step');
        await time.advanceSeconds(60);
        await autoFail('ladder.example:443');
        expect(count('same'), before + 1, reason: 'the step of $wait min is over: the whole check runs');
      }
      expect(siteEvents().map((e) => e['id']), [id]);
    });

    test('a connection that gets data back through the route clears the verdict, the ladder starts over', () async {
      await start();
      await autoFail('clear.example:443');
      await time.advanceSeconds(6 * 60);
      await autoFail('clear.example:443'); // step 1 (15 min)
      final before = count('same');
      await time.advanceSeconds(60);
      await autoFail('clear.example:443');
      expect(count('same'), before, reason: 'inside the 15 min');
      svc.failures.worked!('clear.example', 443, 'route0/s::a');
      await autoFail('clear.example:443');
      expect(count('same'), before + 1);
      await time.advanceSeconds(4 * 60);
      await autoFail('clear.example:443');
      expect(count('same'), before + 1, reason: 'the ladder is on its first step (5 min) again');
    });

    test('another network voids the ladder\'s verdict: the next failure is judged anew', () async {
      await start();
      svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'net1'});
      await autoFail('net.example:443');
      final before = count('same');
      await time.advanceSeconds(60);
      await autoFail('net.example:443');
      expect(count('same'), before, reason: 'under the timer');
      svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'net2'});
      await time.advance(Duration.zero);
      await autoFail('net.example:443');
      expect(count('same'), before + 1);
    });
  });

  group('one memo per site for both reporters', () {
    test('Auto\'s notice (entry id) and the connection book\'s streak (route0) are one verdict: the streak is a repeat; a connection that worked clears both', () async {
      await start();
      await autoFail('both.example:443');
      final e = siteEvents().single;
      expect((e['data'] as Map)['entry'], 'A');
      final before = [count('same'), count('scout'), count('checker')];
      await bookFail('both.example');
      expect([count('same'), count('scout'), count('checker')], before, reason: 'the book\'s report is a repeat of the remembered verdict');
      expect(siteEvents().length, 1);
      expect(conn(), isEmpty);
      expect(repeats(siteEvents().single), 2);
      svc.failures.worked!('both.example', 443, 'route0/s::a');
      await bookFail('both.example');
      expect(count('same'), before[0] + 1, reason: 'the memo is gone: judged anew');
    });

    test('the other way round: the book\'s verdict first, Auto\'s notice is its repeat', () async {
      await start();
      await bookFail('rev.example');
      final e = siteEvents().single;
      expect((e['data'] as Map)['entry'], 'A', reason: 'the entry id for both reporters');
      final same = count('same');
      await autoFail('rev.example:443');
      expect(count('same'), same);
      expect(repeats(siteEvents().single), 2);
    });
  });
}
