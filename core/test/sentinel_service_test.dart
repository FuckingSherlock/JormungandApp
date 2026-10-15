// The Sentinel's context as CoreService feeds it (docs/failures.md → Контекст): the core phase follows
// connect / disconnect, the network follows the pool and `setNetwork`, and /api/status shows both.
import 'dart:io';

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
  late _Runner runner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-sctx');
    runner = _Runner();
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      directProbe: (_, _) async => 5, // hermetic: the direct path answers
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
  });

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> ctx() async => (await svc.status())['context'] as Map<String, dynamic>;

  test('status carries the context: stopped and presumed up before a connection', () async {
    final c = await ctx();
    expect((c['core'] as Map)['phase'], 'stopped');
    expect((c['network'] as Map)['state'], 'up');
    expect(c['roots'], isEmpty);
  });

  test('connect: settling with the reason userConnect; disconnect: stopped', () async {
    await svc.connect(_body());
    var core = (await ctx())['core'] as Map;
    expect((core['phase'], core['restartReason']), ('settling', 'userConnect'));
    await svc.disconnect();
    core = (await ctx())['core'] as Map;
    expect(core['phase'], 'stopped');
  });

  test('setNetwork: captive, no connection, back; the type and id are kept; the answer is the context', () async {
    var c = svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'net1'});
    expect((c['network'] as Map)['state'], 'up');
    expect(((c['network'] as Map)['type'], (c['network'] as Map)['id']), ('wifi', 'net1'));
    c = svc.setNetwork({'connected': true, 'validated': false, 'captive': true, 'type': 'wifi', 'id': 'net1'});
    expect((c['network'] as Map)['state'], 'captive');
    expect(((await ctx())['roots'] as List).map((r) => (r as Map)['kind']), contains('net.captive'));
    c = svc.setNetwork({'connected': false});
    expect((c['network'] as Map)['state'], 'none');
    c = svc.setNetwork({'connected': true, 'validated': true});
    expect((c['network'] as Map)['state'], 'up');
    expect((await ctx())['roots'], isEmpty, reason: 'the roots close when the network is back');
  });

  test('the pool: the OS has no network → none, from the OS', () async {
    svc.pool.offline(true);
    svc.pool.status; // (the pool reports a change when its status is read)
    final n = (await ctx())['network'] as Map;
    expect((n['state'], n['source']), ('none', 'os'));
    svc.pool.offline(false);
    svc.pool.status;
    expect(((await ctx())['network'] as Map)['state'], 'up');
  });

  test('sing-box\'s "updated default interface" moves the network (changedAt)', () async {
    final at = ((await ctx())['network'] as Map)['changedAt'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    runner.onLog!('INFO[0010] updated default interface Wi-Fi, index 4');
    expect(((await ctx())['network'] as Map)['changedAt'] as int, greaterThan(at));
  });
}
