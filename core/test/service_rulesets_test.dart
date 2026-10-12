// Rule sets while connected (docs/rules.md → Внешние rule-sets, docs/failures.md → Перенос детекторов): a
// refresh of a list sing-box already has replaces the file in place and never restarts it; only a list that
// is new to the config does. The timer's refresh starts after the Sentinel's context is settled. A download
// that failed is judged by the Sentinel; one cut by our own restart is not told at all.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';
import 'sentinel_fakes.dart';

class _Runner implements BoxRunner {
  final configs = <Map<String, dynamic>>[];
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
  Future<void> start(Map<String, dynamic> config) async {
    configs.add(config);
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}

final _srs = [0x53, 0x52, 0x53, 0x01];
const _tag = 'set-mine';

Map<String, dynamic> _body(String url, {String via = 'direct'}) => {
      'plan': {
        'kind': 'unit',
        'main': {
          'pick': 'fastest',
          'nodes': [
            {'key': 's::0', 'outbound': parseLink(ssSip002)!.outbound},
          ],
        },
        'global': false,
        'mixedPort': 2080,
        'routing': {
          'ruleSets': [
            {'name': 'mine', 'url': url, 'format': 'srs', 'via': via, 'every': 1},
          ],
          'rules': [
            {
              'id': 'r1',
              'name': '',
              'action': 'direct',
              'target': '',
              'fallback': 'default',
              'block': 'drop',
              'dns': 'auto',
              'groups': {
                'domain': {
                  'not': false,
                  'v': {
                    'rule_set': ['mine'],
                  },
                },
              },
            },
          ],
        },
      },
    };

void main() {
  late Directory tmp;
  late HttpServer origin;
  late _Runner runner;
  late CoreService svc;
  late FakeTime time;
  late List<void Function()> timers;
  var served = 1;
  late List<String> hits;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-svcrs');
    hits = [];
    served = 1;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((r) {
      hits.add(r.uri.path);
      r.response.add([..._srs, served]);
      r.response.close();
    });
    time = FakeTime();
    timers = [];
    runner = _Runner();
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sentinelClock: time.clock,
      windows: FailureWindows.instant(),
      timer: (d, f) {
        timers.add(f);
        return _Idle();
      },
    );
    await svc.init();
  });

  tearDown(() async {
    await svc.dispose();
    await origin.close(force: true);
    await tmp.delete(recursive: true);
  });

  String url() => 'http://127.0.0.1:${origin.port}/mine.srs';
  File listFile() => File(p.join(tmp.path, 'data', 'rulesets', '$_tag.srs'));
  Future<void> staleCopy() async {
    listFile().createSync(recursive: true);
    listFile().writeAsBytesSync([..._srs, 0]);
    listFile().setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
  }

  /// Fires the timers set so far (the list tick) and lets what they started run.
  Future<void> tick() async {
    final now = List.of(timers);
    timers.clear();
    for (final f in now) {
      f();
    }
    await pumpEventQueue();
  }

  void plainFetch() {
    final f = ServiceFetch(endpoint: () => null, context: svc.sentinel.context);
    svc.ruleSets.fetchSource = () => f;
  }

  bool configHasList(Map<String, dynamic> c) => jsonEncode(c).contains('"$_tag"');
  List ruleFailed() => (svc.eventBook.since(null)['events'] as List).where((e) => (e as Map)['type'] == 'ruleSetFailed').toList();

  test('a refresh of a list the config already has replaces the file in place: no restart; and only once the core is settled', () async {
    await staleCopy();
    plainFetch(); // (the fake runner has no svc-in to race over)
    await svc.connect(_body(url()));
    expect(runner.configs, hasLength(1));
    expect(configHasList(runner.configs.single), isTrue);
    expect(hits, isEmpty, reason: 'a stale copy is used at connect, not fetched');

    await tick();
    expect(hits, isEmpty, reason: 'just started: the context is not settled');
    expect(timers, isNotEmpty, reason: 'it looks again later');

    served = 7;
    time.t = time.t.add(const Duration(minutes: 5)); // the settle passes
    await tick();
    for (var i = 0; i < 60 && (timers.isEmpty || hits.isEmpty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50)); // (a real download)
    }
    expect(hits, ['/mine.srs']);
    expect(listFile().readAsBytesSync().last, 7);
    expect(runner.configs, hasLength(1), reason: 'sing-box reloads a local rule set by itself');
    expect(timers, isNotEmpty, reason: 'the timer goes on');
  });

  test('a list that is new to the config (via VPN, no tunnel at the start) is fetched through the tunnel and restarts sing-box once', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    proxy.listen((r) {
      r.response.add([..._srs, 5]);
      r.response.close();
    });
    svc.ruleSets.fetchSource = () => ServiceFetch(
          endpoint: () => SvcIn(proxy.port, 'pw', [const SvcPath('main', SvcKind.main, 'proxy', 'u1')]),
          context: svc.sentinel.context,
        );
    await svc.connect(_body(url(), via: 'vpn'));
    await pumpEventQueue();
    for (var i = 0; i < 20 && runner.configs.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(runner.configs, hasLength(2));
    expect(configHasList(runner.configs.first), isFalse, reason: 'left out: no tunnel yet');
    expect(configHasList(runner.configs.last), isTrue);
    expect(hits, isEmpty, reason: 'never direct');
  });

  RuleSetSource dead(int port) => RuleSetSource(_tag, ['http://127.0.0.1:$port/mine.srs'], viaVpn: false, every: Duration.zero);

  test('a download cut by our own restart is neither told nor held back; a confirmed failure is told, with whether a copy exists', () async {
    final gone = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = gone.port;
    await gone.close(force: true);
    await staleCopy();
    plainFetch();
    final ctx = svc.sentinel.context;

    ctx.starting('refreshLists');
    await svc.ruleSets.ensure([dead(port)], refresh: true);
    await pumpEventQueue();
    expect(ruleFailed(), isEmpty, reason: 'our own restart: the settle brings the retry, nothing is told');

    ctx.started();
    await time.advance(const Duration(minutes: 5)); // settled: the hold of the own restart is over
    expect(ctx.settled, isTrue);
    await svc.ruleSets.ensure([dead(port)], refresh: true);
    await time.advance(const Duration(seconds: 1));
    final e = ruleFailed();
    expect(e, hasLength(1));
    expect((e.single as Map)['data'], containsPair('hasCopy', true));
    expect((e.single as Map)['verdict'], 'confirmed');
  });
}

class _Idle implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}
