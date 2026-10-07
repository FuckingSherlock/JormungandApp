// Speed Test of the running connection (`CoreService.speedTest({current: true})`): through the
// main flow's outbound on the running sing-box, with a fake source instead of its API service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
  void note(String line) {}
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
  @override
  Future<void> stop() async => up = false;
}

NetworkQualityTestProgress _p(int phase, int down, int up, {bool fin = false, String error = ''}) => NetworkQualityTestProgress(
      phase: phase,
      downloadCapacity: Int64(down),
      uploadCapacity: Int64(up),
      downloadRPM: 900,
      idleLatencyMs: 34,
      elapsedMs: Int64(5000),
      isFinal: fin,
      error: error,
    );

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
  late StreamController<NetworkQualityTestProgress> src;
  final asked = <String>[];
  var cancelled = false;

  Future<void> start({String? dir}) async {
    tmp = Directory(dir ?? (await Directory.systemTemp.createTemp('jorm-speed')).path);
    asked.clear();
    cancelled = false;
    src = StreamController<NetworkQualityTestProgress>(onCancel: () => cancelled = true);
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      currentSpeedSource: (tag) {
        asked.add(tag);
        return src.stream;
      },
    );
    await svc.init();
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  test('not connected: one error, nothing journaled or kept', () async {
    await start();
    final out = await svc.speedTest({'current': true}).toList();
    expect(out, hasLength(1));
    expect(out.single['final'], isTrue);
    expect(out.single['error'], 'Not connected');
    expect(asked, isEmpty);
    expect((await svc.status())['speed'], isNull);
  });

  test('connected: the test goes through the main flow outbound; the result is kept, journaled and restored', () async {
    await start();
    await svc.connect(_body());
    final events = <Map<String, dynamic>>[];
    final evSub = svc.eventStream.listen(events.add);
    final got = <Map<String, dynamic>>[];
    final done = Completer<void>();
    svc.speedTest({'current': true}).listen(got.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    expect(asked, ['proxy']); // topTag: the group the whole route goes through
    src.add(_p(0, 0, 0));
    src.add(_p(1, 40000000, 8000000));
    src.add(_p(2, 90000000, 20000000, fin: true));
    await done.future;
    expect(got.map((m) => m['phase']), [0, 1, 2]);
    expect(got.last['final'], isTrue);
    expect(got.last.containsKey('error'), isFalse);

    final st = await svc.status();
    final speed = st['speed'] as Map;
    expect(speed['down'], 90000000);
    expect(speed['up'], 20000000);
    expect(speed['latency'], 34);
    expect(speed['at'], isA<int>());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.where((e) => e['cat'] == 'speed' && e['type'] == 'done' && (e['data'] as Map)['down'] == 90000000), hasLength(1));
    await evSub.cancel();
    expect(jsonDecode(File(p.join(tmp.path, 'data', 'last-speed.json')).readAsStringSync())['down'], 90000000);

    // a new core on the same data folder starts with the last result
    await svc.dispose();
    svc = CoreService(singBox: 'none', dataDir: p.join(tmp.path, 'data'), runner: _Runner(), sysProxy: NoSystemProxy());
    await svc.init();
    expect(((await svc.status())['speed'] as Map)['down'], 90000000);
  });

  test('a failed test is a warn event and leaves the last result alone', () async {
    await start();
    await svc.connect(_body());
    final events = <Map<String, dynamic>>[];
    final sub = svc.eventStream.listen(events.add);
    final done = Completer<void>();
    final got = <Map<String, dynamic>>[];
    svc.speedTest({'current': true}).listen(got.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    src.add(_p(0, 0, 0, fin: true, error: 'connection reset'));
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(got.single['error'], 'connection reset');
    expect(events.map((e) => '${e['cat']}/${e['type']}/${e['level']}'), contains('speed/failed/warn'));
    expect((await svc.status())['speed'], isNull);
    await sub.cancel();
  });

  test('cancelling the subscription stops the test and keeps nothing', () async {
    await start();
    await svc.connect(_body());
    final events = <Map<String, dynamic>>[];
    final sub = svc.eventStream.listen(events.add);
    final listen = svc.speedTest({'current': true}).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    src.add(_p(1, 10000000, 1000000));
    await Future<void>.delayed(Duration.zero);
    await listen.cancel();
    expect(cancelled, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.where((e) => e['cat'] == 'speed'), isEmpty);
    expect((await svc.status())['speed'], isNull);
    await sub.cancel();
  });

  test('a stream that ends without a final progress is a failed test', () async {
    await start();
    await svc.connect(_body());
    final done = Completer<void>();
    final got = <Map<String, dynamic>>[];
    svc.speedTest({'current': true}).listen(got.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    await src.close();
    await done.future;
    expect(got.single['final'], isTrue);
    expect('${got.single['error']}', isNotEmpty);
  });
}
