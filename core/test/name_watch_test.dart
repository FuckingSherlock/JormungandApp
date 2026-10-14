// A node's server name that does not exist (docs/failures.md → «Имя сервера узла не существует», docs/rules.md §6):
// one «no such name» is only an observation; the re-check one minute later makes the verdict (event `node/addressMissing`,
// the nodes of that name on the dead ladder). The watch itself with time by hand, then the service with a fake resolver.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/name_watch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

void main() {
  group('NameMissingWatch', () {
    late FakeTime time;
    late NameMissingWatch w;
    late List<String> calls, logs;
    Object? answer; // what the re-check finds (null = nothing)
    bool saysMissing = true; // the re-check's own lookup reports «no such name»
    Completer<void>? hold; // the re-check waits for it
    bool stands = true;

    setUp(() {
      time = FakeTime();
      calls = [];
      logs = [];
      answer = null;
      saysMissing = true;
      hold = null;
      stands = true;
      w = NameMissingWatch(
        timer: time.clock.timer,
        recheck: (h) async {
          calls.add('recheck $h');
          if (hold != null) await hold!.future;
          if (saysMissing) w.missing(h);
          return answer;
        },
        confirm: (h) async {
          calls.add('confirm $h');
          return stands;
        },
        repeat: (h) async => calls.add('repeat $h'),
        cleared: (h, why) => calls.add('cleared $h $why'),
        log: (l, t) => logs.add('$l $t'),
      );
    });

    tearDown(() => w.dispose());

    test('a report is only a suspicion: nothing before the minute, then the re-check and the verdict', () async {
      w.missing('Gone.Example');
      expect(w.isPending('gone.example'), isTrue);
      await time.advanceSeconds(59);
      expect(calls, isEmpty);
      await time.advanceSeconds(2);
      expect(calls, ['recheck Gone.Example', 'confirm Gone.Example']);
      expect(w.isOpen('gone.example'), isTrue);
      expect(w.isPending('gone.example'), isFalse);
    });

    test('found on the re-check: no verdict', () async {
      answer = Object();
      saysMissing = false;
      w.missing('gone.example');
      await time.advanceSeconds(61);
      expect(calls, ['recheck gone.example']);
      expect(w.isOpen('gone.example'), isFalse);
      expect(w.isPending('gone.example'), isFalse);
    });

    test('one re-check in flight per host: more reports meanwhile start nothing', () async {
      hold = Completer<void>();
      w.missing('gone.example');
      w.missing('GONE.example');
      await time.advanceSeconds(61);
      w.missing('gone.example'); // while the re-check runs
      await time.advanceSeconds(120);
      expect(calls, ['recheck gone.example']);
      hold!.complete();
      await time.advanceSeconds(1);
      expect(calls, ['recheck gone.example', 'confirm gone.example']);
    });

    test('unclear answers (the DNS was silent): asked again every minute, at most 5 times, no verdict', () async {
      saysMissing = false;
      w.missing('gone.example');
      await time.advanceSeconds(61);
      expect(calls.length, 1);
      await time.advanceSeconds(60);
      expect(calls.length, 2);
      await time.advanceSeconds(60 * 10);
      expect(calls, List.filled(5, 'recheck gone.example'));
      expect(w.isPending('gone.example'), isFalse);
      expect(w.isOpen('gone.example'), isFalse);
      expect(logs.where((l) => l.startsWith('warn') && l.contains('could not tell')), hasLength(1));
    });

    test('unclear first, clear later: the verdict comes from the clear answer', () async {
      saysMissing = false;
      w.missing('gone.example');
      await time.advanceSeconds(61);
      saysMissing = true;
      await time.advanceSeconds(60);
      expect(calls, ['recheck gone.example', 'recheck gone.example', 'confirm gone.example']);
      expect(w.isOpen('gone.example'), isTrue);
    });

    test('a verdict that does not stand is not kept open', () async {
      stands = false;
      w.missing('gone.example');
      await time.advanceSeconds(61);
      expect(w.isOpen('gone.example'), isFalse);
    });

    test('an open verdict: a repeat is only reported, a resolved name closes it', () async {
      w.missing('gone.example');
      await time.advanceSeconds(61);
      calls.clear();
      w.missing('gone.example');
      w.missing('gone.example');
      await time.advanceSeconds(1);
      expect(calls, ['repeat gone.example', 'repeat gone.example']);
      w.resolved('gone.example');
      expect(calls.last, 'cleared gone.example resolved');
      expect(w.isOpen('gone.example'), isFalse);
      calls.clear();
      w.resolved('gone.example'); // nothing is open any more
      expect(calls, isEmpty);
    });

    test('a name that resolves before the minute is over cancels the check', () async {
      w.missing('gone.example');
      await time.advanceSeconds(30);
      w.resolved('gone.example');
      await time.advanceSeconds(120);
      expect(calls, isEmpty);
      expect(w.isPending('gone.example'), isFalse);
    });

    test('the name resolving while the verdict is being made undoes it', () async {
      final gate = Completer<bool>();
      w = NameMissingWatch(
        timer: time.clock.timer,
        recheck: (h) async {
          w.missing(h);
          return null;
        },
        confirm: (h) => gate.future,
        repeat: (h) async {},
        cleared: (h, why) => calls.add('cleared $h $why'),
        log: (l, t) {},
      );
      w.missing('gone.example');
      await time.advanceSeconds(61);
      w.resolved('gone.example');
      gate.complete(true);
      await time.advanceSeconds(1);
      expect(calls, ['cleared gone.example resolved']);
      expect(w.isOpen('gone.example'), isFalse);
    });
  });

  group('the service', () {
    late Directory tmp;
    late CoreService svc;
    late FakeTime time;
    late _Fake fake;

    Map<String, dynamic> ob(String server) => {'type': 'shadowsocks', 'server': server, 'server_port': 8388, 'method': 'aes-128-gcm', 'password': 'x'};

    Map<String, dynamic> node(String id, String server, {Map<String, dynamic>? extra}) => {
          'id': id,
          'name': 'Node $id',
          'flag': '',
          'protocol': 'shadowsocks',
          'address': server,
          'port': 8388,
          'outbound': ob(server),
          ...?extra,
        };

    Future<void> boot(List<Map<String, dynamic>> nodes, {String? inUse}) async {
      tmp = await Directory.systemTemp.createTemp('jorm-name');
      time = FakeTime();
      svc = CoreService(
        sentinelClock: time.clock,
        timer: time.clock.timer,
        now: () => time.t,
        isElevated: () => true,
        singBox: 'none',
        dataDir: p.join(tmp.path, 'data'),
        runner: _Runner(),
        boxFactory: (_) => _Runner(),
        sysProxy: NoSystemProxy(),
        exitCheck: (_) async => {'ip': '127.0.0.1'},
        siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
        addressResolverFor: (book) => fake = _Fake(book, time),
      );
      await svc.init();
      fake = svc.addresses as _Fake;
      fake.svc = svc;
      await svc.store.save({
        'sourcesData': {
          's1': {
            'id': 's1',
            'kind': 'sub',
            'name': 'Provider',
            'enabled': true,
            'inAuto': true,
            'offNodes': <String>[],
            'disabledNodes': <String>[],
            'gone': <dynamic>[],
            'nodes': nodes,
          },
        },
        'sourceOrder': ['s1'],
      });
      if (inUse != null) {
        await svc.connect({
          'plan': {
            'routes': [
              {
                'id': 'A',
                'kind': 'unit',
                'main': {
                  'pick': 'priority',
                  'chosen': 's1::a',
                  'nodes': [
                    {'key': 's1::a', 'outbound': ob(inUse)},
                  ],
                },
              },
            ],
            'current': 0,
            'mixedPort': 2080,
            'global': true,
          },
          'systemProxy': false,
        });
        await time.advanceSeconds(6);
      }
    }

    tearDown(() async {
      await svc.dispose();
      await tmp.delete(recursive: true);
    });

    List<Map> events() => [
          for (final e in (svc.events()['events'] as List).cast<Map>())
            if (e['cat'] == 'node' && e['type'] == 'addressMissing') e,
        ];
    int roots() => (svc.sentinel.contextJson()['roots'] as List).length;
    String idOf(String server) => serverIdentity(ob(server));

    test('missing, then the same a minute later: the event and the ladder; before the minute nothing', () async {
      await boot([node('a', 'gone.example'), node('b', 'fine.example')]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(59);
      expect(events(), isEmpty);
      expect(svc.pool.ladder.length, 0);
      expect(fake.looked, isEmpty);
      await time.advanceSeconds(3);
      expect(fake.looked, ['gone.example']);
      expect(events(), hasLength(1));
      final e = events().single;
      expect(e['level'], 'warn');
      expect(e['data'], containsPair('host', 'gone.example'));
      expect(e['data'], containsPair('node', 'Node a'));
      expect(e['data'], containsPair('source', 'Provider'));
      expect(e['data'], containsPair('nodes', 1));
      expect(e['data'], containsPair('inUse', false));
      expect(svc.pool.ladder.has(idOf('gone.example')), isTrue);
      expect(svc.pool.ladder.has(idOf('fine.example')), isFalse);
    });

    test('found on the re-check: no event, no ladder', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.found;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(fake.looked, ['gone.example']);
      expect(events(), isEmpty);
      expect(svc.pool.ladder.length, 0);
      expect(roots(), 0);
    });

    test('one re-check in flight per host, however many reports', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.missing;
      for (var i = 0; i < 4; i++) {
        svc.nameMissing('gone.example');
        svc.nameMissing('GONE.example');
        await time.advanceSeconds(10);
      }
      await time.advanceSeconds(30);
      expect(fake.looked, ['gone.example']);
      expect(events(), hasLength(1));
    });

    test('a host shared by nodes: one event for the name, all its nodes on the ladder', () async {
      await boot([node('a', 'gone.example'), node('b', 'gone.example', extra: {'outbound': {...ob('gone.example'), 'server_port': 9}})]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(events(), hasLength(1));
      expect(events().single['data'], containsPair('nodes', 2));
      expect(svc.pool.ladder.length, 2);
    });

    test('unclear answers: asked again up to 5 times, then left alone, no event', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.silent;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(60 * 12);
      expect(fake.looked, hasLength(5));
      expect(events(), isEmpty);
      expect(svc.pool.ladder.length, 0);
    });

    test('a name of no node of the catalog (a DNS server): no event', () async {
      await boot([node('a', 'fine.example')]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('dns.nobody.example');
      await time.advanceSeconds(62);
      expect(fake.looked, ['dns.nobody.example']);
      expect(events(), isEmpty);
      expect(roots(), 0);
    });

    test('repeats while the verdict stands are counted on the event, not new events', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(events(), hasLength(1));
      expect(events().single['data']['repeat'], isNull);
      svc.nameMissing('gone.example');
      svc.nameMissing('gone.example');
      await time.advanceSeconds(120);
      expect(events(), hasLength(1));
      expect(fake.looked, hasLength(1), reason: 'no new check while the verdict stands');
      expect((events().single['data']['repeat'] as Map)['count'], 3);
    });

    test('the name resolving closes the verdict; the next «missing» is a new event', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(roots(), 1);
      svc.nameResolved('gone.example');
      await time.advanceSeconds(1);
      expect(roots(), 0);
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(events(), hasLength(2));
    });

    test('the node answering on the ladder closes the verdict', () async {
      await boot([node('a', 'gone.example')]);
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(roots(), 1);
      final id = idOf('gone.example');
      svc.pool.ladder.observe(id, -1, time.t.millisecondsSinceEpoch); // a miss changes nothing
      expect(roots(), 1);
      expect(svc.pool.ladder.observe(id, 50, time.t.millisecondsSinceEpoch), isTrue);
      await time.advanceSeconds(1);
      expect(roots(), 0);
      expect(svc.pool.ladder.has(id), isFalse);
    });

    test('the node in use is marked inUse (the app notifies only then)', () async {
      await boot([node('a', 'gone.example')], inUse: 'gone.example');
      fake.script = (_) => _Answer.missing;
      svc.nameMissing('gone.example');
      await time.advanceSeconds(62);
      expect(events().single['data'], containsPair('inUse', true));
    });
  });
}

enum _Answer { found, missing, silent }

class _Runner implements BoxRunner {
  bool up = false;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
  @override
  Future<void> stop() async => up = false;
}

/// A resolver that answers the re-check by [script] and reports like the real one: «missing» through the service's
/// `nameMissing`, an address through `nameResolved`; silent = nobody answered.
class _Fake extends AddressResolver {
  _Fake(AddressBook book, this.time)
      : super(book: book, fetch: () => ServiceFetch(endpoint: () => null), settings: () async => const AddressSettings());
  final FakeTime time;
  late CoreService svc;
  _Answer Function(String host) script = (_) => _Answer.silent;
  final looked = <String>[];

  @override
  Future<void> ensure(Iterable<String> hosts,
      {required String why, Duration wait = const Duration(seconds: 8), Iterable<String> first = const [], bool refreshAll = false, Iterable<String>? need, bool race = false}) async {}

  @override
  Future<AddressEntry?> lookup(String host, {required String why, Duration? race}) async {
    looked.add(host);
    switch (script(host)) {
      case _Answer.found:
        svc.nameResolved(host);
        return AddressEntry(v4: const ['192.0.2.7'], v6: const [], at: time.t.millisecondsSinceEpoch, ttl: 300, via: 'fake');
      case _Answer.missing:
        svc.nameMissing(host);
        return null;
      case _Answer.silent:
        return null;
    }
  }
}
