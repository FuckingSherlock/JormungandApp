// The level of `conn/vpnDown` follows its causes (docs/logs.md → «„VPN не работает“», Ожидание): `warn` while the
// causes are exactly ['network'] (the VPN waits for the network), `error` otherwise (core, or core + network); the
// level changes IN PLACE (same id, rev bumped) when a cause comes or leaves. A fake sing-box runner, time by hand.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Runner implements BoxRunner {
  bool up = false;
  int failStarts = 0;
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
    if (failStarts > 0) {
      failStarts--;
      throw SingBoxError('boom');
    }
    up = true;
  }

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
  late FakeTime time;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-vpnwait');
    runner = _Runner();
    time = FakeTime();
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false,
      directProbe: (_, _) async => 5,
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    await svc.connect(_body());
    await time.advanceSeconds(6);
  });

  tearDown(() async {
    await svc.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  Map down() => events('conn', 'vpnDown').single;
  List causes(Map e) => (e['data'] as Map)['causes'] as List;
  int rev(Map e) => (e['rev'] as int?) ?? 0;

  Future<void> untilEvent(String cat, String type) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type');
  }

  Future<void> networkGone() async {
    svc.setNetwork({'connected': false});
    await time.advanceSeconds(11);
  }

  Future<void> networkBack() async {
    svc.setNetwork({'connected': true, 'validated': true});
    await time.advanceSeconds(2);
  }

  Future<void> coreCrash() async {
    runner.failStarts = 1 << 20;
    runner.up = false;
    runner.onExit!(9);
    for (var i = 0; i < 40; i++) {
      await time.advanceSeconds(1);
    }
  }

  Future<void> coreBack() async {
    runner.failStarts = 0;
    await untilEvent('core', 'restarted');
    await time.advanceSeconds(1);
  }

  test('network only: the vpnDown is warn (waiting for the network); vpnUp stays info', () async {
    await networkGone();
    final d = down();
    expect(causes(d), ['network']);
    expect(d['level'], 'warn');
    await networkBack();
    expect(events('conn', 'vpnUp').single['level'], 'info');
    expect(down()['id'], d['id']);
  });

  test('core only: the vpnDown is error', () async {
    await coreCrash();
    final d = down();
    expect(causes(d), ['core']);
    expect(d['level'], 'error');
  });

  test('network first, then the core joins: warn turns error in place (same id, rev up); the core leaving turns it warn again', () async {
    await networkGone();
    final first = down();
    expect(first['level'], 'warn');
    final id = first['id'];
    final rev0 = rev(first);

    await coreCrash();
    final both = down();
    expect(both['id'], id, reason: 'in place, no second event');
    expect(causes(both), unorderedEquals(['network', 'core']));
    expect(both['level'], 'error');
    expect(rev(both), greaterThan(rev0));
    final revBoth = rev(both); // a number: the map itself may be the live record

    await coreBack();
    final waiting = down();
    expect(waiting['id'], id);
    expect(causes(waiting), ['network']);
    expect(waiting['level'], 'warn', reason: 'back to waiting for the network');
    expect(rev(waiting), greaterThan(revBoth));
    expect(events('conn', 'vpnUp'), isEmpty);
    expect(events('conn', 'vpnDown'), hasLength(1));
  });

  test('core first, the network joins: stays error; the network leaving keeps error while the core stands', () async {
    await coreCrash();
    final id = down()['id'];
    await networkGone();
    expect(down()['level'], 'error');
    expect(causes(down()), unorderedEquals(['core', 'network']));
    await networkBack();
    final d = down();
    expect(d['id'], id);
    expect(causes(d), ['core']);
    expect(d['level'], 'error');
  });

  test('the level survives a reload of the journal (it is written, not derived)', () async {
    await networkGone();
    await coreCrash();
    await svc.eventBook.flush();
    final again = EventBook(File(p.join(tmp.path, 'data', 'events.jsonl')), clock: () => DateTime(2026, 10, 18));
    final rec = again.byId(down()['id'] as int)!;
    expect(rec['level'], 'error');
    await again.flush();
  });

  group('EventBook.update takes a level', () {
    test('a level given changes it in place and bumps rev; an update without a level keeps it', () async {
      final b = EventBook(File(p.join(tmp.path, 'level.jsonl')), clock: () => DateTime(2026, 10, 18));
      final id = b.add('conn', 'vpnDown', 'warn', data: {'causes': ['network']});
      expect(b.update(id, level: 'error', data: {'causes': ['network', 'core']}), isTrue);
      expect(b.byId(id)!['level'], 'error');
      expect(b.byId(id)!['rev'], 1);
      expect(b.update(id, data: {'causes': ['network', 'core', 'x']}), isTrue);
      expect(b.byId(id)!['level'], 'error', reason: 'no level in the update: kept');
      await b.flush();
    });
  });
}
