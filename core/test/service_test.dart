// CoreService without HTTP: the app's direct line to the core (docs/core.md → "CoreService").
// A fake BoxRunner (the platform seam, no sing-box binary) and the system proxy seams; the
// HTTP adapter over the same logic is covered by killswitch_test / events_test / tun_test.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A runner that is not sing-box: starts when told to, has no API service.
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

/// A throwaway box (latency test) that comes up and complains once.
class _NoisyRunner extends _Runner {
  @override
  Future<void> start(Map<String, dynamic> config) async {
    up = true;
    onLog?.call('WARN[0000] boom');
  }
}

Map<String, dynamic> _body({bool sys = false}) => {
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
      'systemProxy': sys,
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;

  Future<void> start({SystemProxyBackend? sys}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc');
    runner = _Runner();
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _NoisyRunner(),
      sysProxy: sys ?? NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  test('connect / disconnect push the status, the journal and the log on their streams', () async {
    await start();
    final statuses = <Map<String, dynamic>>[], events = <Map<String, dynamic>>[], lines = <Map<String, dynamic>>[];
    final subs = [
      svc.statusChanges.listen(statuses.add),
      svc.eventStream.listen(events.add),
      svc.logStream.listen(lines.add),
    ];
    final s = await svc.connect(_body());
    expect(s['connected'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses.any((s) => s['connected'] == true), isTrue);
    expect(events.map((e) => '${e['cat']}/${e['type']}'), contains('conn/connected'));
    expect(lines.any((l) => '${l['msg']}'.startsWith('Connected:')), isTrue);

    await svc.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses.last['connected'], isFalse);
    // an unchanged status is not sent twice in a row
    for (var i = 1; i < statuses.length; i++) {
      expect(statuses[i], isNot(statuses[i - 1]));
    }
    for (final s in subs) {
      await s.cancel();
    }
  });

  test('polling and streams agree: log / events since the last number', () async {
    await start();
    await svc.connect(_body());
    final log = svc.log(since: null), ev = svc.events(since: null);
    expect((log['lines'] as List).isNotEmpty, isTrue);
    expect((ev['events'] as List).map((e) => (e as Map)['type']), contains('connected'));
    expect((svc.log(since: log['next'] as int)['lines'] as List), isEmpty);
    final id = svc.postEvent({'cat': 'user', 'type': 'hello', 'level': 'info'})['id'] as int;
    expect((svc.events(since: id)['events'] as List).single['type'], 'hello');
    expect(() => svc.postEvent({'cat': 'nope', 'type': 'x', 'level': 'info'}), throwsFormatException);
    svc.clearEvents();
    expect(svc.events(since: null)['events'], isEmpty);
  });

  test('NoSystemProxy: systemProxy asked, nothing set, the warning says so', () async {
    await start();
    final s = await svc.connect(_body(sys: true));
    expect([s['connected'], s['systemProxy']], [true, false]);
    expect('${s['warning']}', contains('not available'));
    expect((svc.events(since: null)['events'] as List).any((e) => (e as Map)['type'] == 'sysProxy'), isFalse);
  });

  test('ping without servers answers done at once, as a stream', () async {
    await start();
    final lines = await svc.ping({'nodes': [], 'pairs': []}).toList();
    expect(lines, [
      {'done': true, 'network': 'up'}
    ]);
  });

  test('a ping that gets no answer says why in the raw log, with the throwaway box\'s own lines', () async {
    await start();
    final lines = await svc.ping({
      'nodes': [
        {
          'key': 's::a',
          'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
        },
      ],
      'url': 'http://127.0.0.1:9/', // nothing listens on the test inbound either
    }).toList();
    expect(lines.where((l) => l['kind'] == 'n').single['ms'], -1);
    final log = (svc.log()['lines'] as List).cast<Map>();
    expect(log.map((l) => l['msg']), contains(matches(r'^\[ping\] boom$')));
    expect(log.firstWhere((l) => '${l['msg']}'.startsWith('[ping]'))['lvl'], 'warn');
    final why = log.firstWhere((l) => '${l['msg']}'.startsWith('Ping:'));
    expect([why['src'], why['lvl']], ['core', 'warn']);
    expect('${why['msg']}', allOf(contains('1 of 1 did not answer'), contains('x connect to the test inbound')));
  });

  test('dispose stops the box and ends the streams', () async {
    await start();
    await svc.connect(_body());
    final status = svc.statusChanges.toList(), events = svc.eventStream.toList(), log = svc.logStream.toList();
    await svc.dispose();
    expect(runner.running, isFalse);
    await status;
    await events;
    await log; // all three completed: the streams are closed
  });
}
