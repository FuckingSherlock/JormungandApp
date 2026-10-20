// The user's own `op: {id, kind}` in the body of connect / disconnect / postEvent (docs/logs.md → «Операция» item 3):
// the core uses it for the events of the user's action; without it the core makes its own op as before.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

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

Map<String, dynamic> _body({bool global = true, Map<String, Object?>? op}) => {
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
    'global': global,
  },
  'op': ?op,
};

Map<String, Object?> _op(String id, [String kind = 'connection']) => {'id': id, 'kind': kind};

void main() {
  late Directory tmp;
  late CoreService svc;
  late FakeTime time;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-userop');
    time = FakeTime();
    svc = CoreService(
      directProbe: (_, _) async => 5,
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
  });
  tearDown(() async {
    await svc.dispose();
    for (var i = 0; i < 10 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  List<Map> events(String cat) => [
    for (final e in (svc.eventBook.since(null)['events'] as List).cast<Map>())
      if (e['cat'] == cat) e,
  ];
  List<String> types() => [for (final e in events('conn')) '${e['type']}'];

  test('disconnect(op) then connect within 7 s: disconnected and reconnected {user} carry the disconnect\'s op, not the connect\'s', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    await svc.disconnect(op: _op('D1'));
    await time.advanceSeconds(3);
    await svc.connect(_body(op: _op('C1')));
    expect(types(), ['connected', 'disconnected', 'reconnected']);
    final dis = events('conn')[1], re = events('conn')[2];
    expect(dis['op'], _op('D1'));
    expect((dis['data'] as Map)['by'], 'user');
    expect(re['op'], _op('D1'), reason: 'the user reconnect keeps the disconnect\'s op even when the connect names its own');
    expect((re['data'] as Map)['reason'], 'user');
    expect((re['data'] as Map)['tookMs'], isA<int>());
    expect((re['data'] as Map)['downMs'], isA<int>());
  });

  test('connect beyond 7 s of the disconnect: a plain conn/connected carrying the new op', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    await svc.disconnect(op: _op('D1'));
    await time.advanceSeconds(8);
    await svc.connect(_body(op: _op('C1')));
    expect(types(), ['connected', 'disconnected', 'connected']);
    expect(events('conn').last['op'], _op('C1'));
  });

  test('a fresh connect with op: conn/connected carries it', () async {
    await svc.connect(_body(op: _op('C1')));
    expect(events('conn').single['type'], 'connected');
    expect(events('conn').single['op'], _op('C1'));
  });

  test('a live plan change with op: conn/reconnected {settings} carries it', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    await svc.connect(_body(global: false, op: _op('R1', 'reconnect')));
    expect(types(), ['connected', 'reconnected']);
    final e = events('conn').last;
    expect((e['data'] as Map)['reason'], 'settings');
    expect(e['op'], _op('R1', 'reconnect'));
  });

  test('postEvent with op: the event has it', () {
    final id = svc.postEvent({'cat': 'user', 'type': 'route', 'level': 'info', 'own': true, 'op': _op('R1', 'reconnect')})['id'];
    final e = events('user').singleWhere((e) => e['id'] == id);
    expect(e['op'], _op('R1', 'reconnect'));
  });

  for (final bad in <Object?>['x', 5, <String, Object?>{'id': 'a'}, {'id': 1, 'kind': 'connection'}, {'kind': 'k'}]) {
    test('postEvent with a malformed op $bad: FormatException, nothing written', () {
      expect(
        () => svc.postEvent({'cat': 'user', 'type': 'route', 'level': 'info', 'op': bad}),
        throwsFormatException,
      );
      expect(events('user'), isEmpty);
    });
  }

  test('no op anywhere: the core makes its own, the disconnect has an op of kind connection; reconnect shares it', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    await svc.disconnect();
    await time.advanceSeconds(3);
    await svc.connect(_body());
    final c = events('conn');
    expect((c[1]['op'] as Map)['kind'], 'connection');
    expect(c[2]['op'], c[1]['op']);
  });
}
