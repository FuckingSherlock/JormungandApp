// The connection and core detectors as CoreService runs them through the Sentinel (docs/failures.md →
// Перенос детекторов): `conn/failing`, `conn/offline` / `online`, `conn/lost` / `restored`, `auto/unstable`
// and the core events (`crashed`, `restartFailed`, `down`). A fake sing-box runner (no process, no API), time
// by hand (FakeTime): the Sentinel's clock, the service's clock and its waits are one.
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

ClosedConnection _closed({String dest = 'example.org:443', int down = 0, int? ms = 5000, String outbound = 'route0/s::a', String inbound = 'tun-in'}) =>
    ClosedConnection(
      outbound: outbound,
      chain: [outbound, 'route0', 'proxy'],
      destination: dest,
      up: 0,
      down: down,
      pkg: 'org.example.app',
      process: '',
      network: 'tcp',
      inbound: inbound,
      durationMs: ms,
    );

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;

  Future<void> start({FailureWindows windows = const FailureWindows(), bool connected = true}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-sfail');
    runner = _Runner();
    time = FakeTime();
    svc = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      windows: windows,
    );
    await svc.init();
    if (connected) {
      await svc.connect(_body());
      await time.advanceSeconds(6); // settled: 5 s after the start
    }
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  List<String> types() => [for (final e in (svc.events()['events'] as List).cast<Map>()) '${e['cat']}/${e['type']}'];
  List<String> trailCodes(Map e) => [for (final s in (e['trail'] as List).cast<Map>()) '${s['code']}'];
  /// The restart goes through real file I/O: time moves by [step] while the event is awaited, the loop waits for real.
  Future<void> untilEvent(String cat, String type, {Duration step = Duration.zero}) async {
    for (var i = 0; i < 600; i++) {
      if (events(cat, type).isNotEmpty) return;
      await time.advance(step);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TestFailure('timed out waiting for $cat/$type, got: ${types()}');
  }

  bool quiet(Map e) => EventBook.isQuiet(e.cast<String, dynamic>());
  void fail(int n, {String dest = 'example.org:443'}) {
    for (var i = 0; i < n; i++) {
      svc.failures.onClosed(_closed(dest: dest));
    }
  }

  void ok({String dest = 'example.org:443'}) => svc.failures.onClosed(_closed(dest: dest, down: 2000, ms: 300));

  group('conn/failing', () {
    test('a failure that goes on is confirmed after the window, with the old data and the trail of the checks', () async {
      await start();
      fail(3);
      await time.advanceSeconds(5);
      expect(events('conn', 'failing'), isEmpty, reason: 'the window (10 s) has not passed');
      await time.advanceSeconds(6);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect(e.containsKey('cause'), isFalse);
      expect((e['why'] as Map)['code'], 'conn.timeout');
      expect(e['data'], containsPair('host', 'example.org'));
      expect(e['data'], containsPair('count', 3));
      expect(e['data'], containsPair('source', 'closed'));
      expect(trailCodes(e), containsAllInOrder(['suspect', 'persist.window', 'conn.recovered', 'conn.otherRoute', 'probe.same', 'probe.alt']));
      expect(quiet(e), isFalse);
      expect(svc.sentinel.roots.byKey('conn.failing|org.example.app|example.org:443|route0/s::a|tun-in'), isNotNull);
    });

    test('it worked again inside the window: a blip that says what failed and when it recovered', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      ok();
      await time.advanceSeconds(1);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect((e['why'] as Map)['code'], 'recovered');
      expect(trailCodes(e), containsAllInOrder(['suspect', 'blip.recovered']));
      final suspect = (e['trail'] as List).cast<Map>().first;
      expect(((suspect['params'] as Map)['facts'] as Map)['host'], 'example.org');
      expect(((suspect['params'] as Map)['subject'] as Map)['outbound'], 'route0/s::a');
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('it opens through another outbound already (live traffic): a workaround, quiet', () async {
      await start();
      fail(3);
      await time.advanceSeconds(1);
      // the same destination works through the other outbound
      svc.failures.onClosed(_closed(down: 2000, ms: 300, outbound: 'route1/s::b'));
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect(e['verdict'], 'workaround');
      expect(trailCodes(e), contains('conn.otherRoute'));
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('the probe inbound (Auto\'s checks of the spare routes) never makes a suspicion', () async {
      await start();
      for (var i = 0; i < 6; i++) {
        svc.failures.onClosed(_closed(inbound: 'probe-in', outbound: 'route1/s::b'));
      }
      await time.advanceSeconds(30);
      expect(events('conn', 'failing'), isEmpty);
      expect(svc.failuresSnapshot()['failed'], 0, reason: 'not even counted');
    });

    test('no network: nothing is confirmed; after the blip window the failure is a consequence of conn/offline', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(11);
      final offline = events('conn', 'offline').single;
      expect([offline['level'], offline['verdict']], ['warn', 'confirmed']);
      fail(3);
      await time.advanceSeconds(1);
      final e = events('conn', 'failing').single;
      expect([e['level'], e['verdict']], ['info', 'consequence']);
      expect(e['cause'], offline['id']);
      expect((e['why'] as Map)['code'], 'net.offline');
      expect(quiet(e), isTrue);
      expect(svc.sentinel.roots.byKey('conn.failing|org.example.app|example.org:443|route0/s::a|tun-in'), isNull, reason: 'a consequence opens no root');
      expect(types().where((t) => t == 'conn/failing').length, 1);
      // the network is back: conn/online with the time
      svc.setNetwork({'connected': true, 'validated': true});
      await time.advanceSeconds(1);
      final online = events('conn', 'online').single;
      expect(online['data'], containsPair('downMs', greaterThan(10000)));
    });

    test('the network gone for a moment: conn/offline is a blip with how long, no conn/online', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(3);
      expect(events('conn', 'offline'), isEmpty, reason: 'not before the blip window');
      svc.setNetwork({'connected': true, 'validated': true});
      await time.advanceSeconds(1);
      final e = events('conn', 'offline').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect(e['data'], containsPair('downMs', greaterThanOrEqualTo(3000)));
      expect(trailCodes(e), ['ctx.net', 'blip.recovered']);
      expect(events('conn', 'online'), isEmpty);
      expect(quiet(e), isTrue);
    });

    test('a failure suspected while the core is stopped or stops meanwhile is let go: no event, no root', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      await svc.disconnect();
      await time.advanceSeconds(60);
      expect(events('conn', 'failing'), isEmpty);
      expect(svc.sentinel.roots.open, isEmpty);
    });

    test('our own start: a failure seen while the core settles is judged by the window that begins at the settle', () async {
      await start(connected: false);
      await svc.connect(_body());
      fail(3); // right after the start
      await time.advanceSeconds(3);
      expect(events('conn', 'failing'), isEmpty);
      await time.advanceSeconds(20);
      final e = events('conn', 'failing').single;
      expect(e['verdict'], 'confirmed');
      expect(trailCodes(e), contains('ctx.core'));
    });

    test('after a suspicion that did not stand, the same entry is suspected again only after a pause', () async {
      await start();
      fail(3);
      await time.advanceSeconds(3);
      ok();
      await time.advanceSeconds(1);
      expect(events('conn', 'failing').length, 1);
      fail(3);
      await time.advanceSeconds(12);
      expect(events('conn', 'failing').length, 1, reason: 'held for ${FailureBook.recheckAfter.inSeconds} s: a flapping destination is not written every time');
      await time.advance(FailureBook.recheckAfter);
      fail(3);
      await time.advanceSeconds(12);
      expect(events('conn', 'failing').length, 2);
    });
  });

  group('the core', () {
    test('crash: core/crashed is the root; the restart that fails is its consequence (cause = the crash), the one that works closes the root', () async {
      await start();
      runner.failStarts = 1;
      runner.up = false;
      runner.onExit!(9);
      await time.advance(Duration.zero);
      final crashed = events('core', 'crashed').single;
      expect([crashed['level'], crashed['verdict']], ['error', 'confirmed']);
      expect((crashed['why'] as Map)['code'], 'core.exit');
      expect(svc.sentinel.roots.byKind('core.crashed'), isNotNull);
      await time.advanceSeconds(1); // the first try fails
      await untilEvent('core', 'restartFailed');
      final failed = events('core', 'restartFailed').single;
      expect([failed['level'], failed['verdict'], failed['cause']], ['info', 'consequence', crashed['id']]);
      expect(quiet(failed), isTrue);
      await untilEvent('core', 'restarted', step: const Duration(seconds: 1)); // the second works
      expect(types(), containsAllInOrder(['core/crashed', 'core/restartFailed', 'core/restarted']));
      expect(svc.sentinel.roots.byKind('core.crashed'), isNull, reason: 'closed when sing-box is back');
      expect(events('core', 'restarted').single.containsKey('verdict'), isFalse, reason: 'a recovery, not a failure');
    });

    test('down: core/down is the event of the core.down root; a failure through the core meanwhile is its consequence', () async {
      await start();
      runner.failStarts = 99;
      runner.up = false;
      runner.onExit!(9);
      await untilEvent('core', 'down', step: const Duration(seconds: 1));
      final down = events('core', 'down').single;
      expect([down['level'], down['verdict']], ['error', 'confirmed']);
      expect(svc.sentinel.roots.byKind(rootCoreDown)!.eventId, down['id']);
      // the failure book is not fed by a dead core, but a late record still is judged against the root
      fail(3);
      await time.advanceSeconds(1);
      expect(events('conn', 'failing'), isEmpty, reason: 'the book is off while the core is down');
      final id = svc.sentinel.suspect(Suspicion(
          kind: 'conn.failing',
          key: 'conn.failing|test',
          subject: const {'host': 'example.org', 'outbound': 'route0/s::a', 'path': 'proxy'},
          window: Duration.zero,
          event: const SuspicionEvent('conn', 'failing', level: 'warn')));
      final v = await id;
      expect(v.kind, VerdictKind.consequence);
      expect(v.cause, down['id']);
      final e = events('conn', 'failing').single;
      expect([e['verdict'], e['cause']], ['consequence', down['id']]);
    });
  });

  group('conn/lost and auto/unstable', () {
    int at() => time.t.millisecondsSinceEpoch;
    AutoNet lost() => AutoNet(kind: 'lost', at: at());

    test('auto/unstable: judged and written with a verdict, and every new announcement for the route is written again', () async {
      await start();
      final u = AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: at());
      await svc.routeUnstable(u);
      var e = events('auto', 'unstable').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect((e['why'] as Map)['code'], 'route.unstable');
      expect(e['data'], containsPair('strikes', 3));
      expect(svc.sentinel.roots.open, isEmpty, reason: 'an announcement: Auto itself keeps the route on hold');
      await svc.routeUnstable(u);
      expect(events('auto', 'unstable').length, 2);
    });

    test('auto/unstable with no network is a consequence of it, not an error', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(1);
      await svc.routeUnstable(AutoUnstable(id: 'A', strikes: 3, holdMs: 60000, at: at()));
      final e = events('auto', 'unstable').single;
      expect([e['level'], e['verdict']], ['info', 'consequence']);
    });

    test('conn/lost that stands for the window: confirmed, a root over the proxy path; conn/restored closes it with the time', () async {
      await start();
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(5);
      expect(events('conn', 'lost'), isEmpty, reason: 'a route may answer again inside the window');
      await time.advanceSeconds(8);
      final e = events('conn', 'lost').single;
      expect([e['level'], e['verdict']], ['warn', 'confirmed']);
      expect(e['data'], containsPair('routes', 2));
      expect(svc.sentinel.roots.byKey('conn.lost'), isNotNull);
      // while it stands the proxy path's failures are its consequences
      fail(3);
      await time.advanceSeconds(1);
      final f = events('conn', 'failing').single;
      expect([f['verdict'], f['cause']], ['consequence', e['id']]);
      svc.routesRestored(AutoNet(kind: 'restored', at: at(), downMs: 13000));
      final r = events('conn', 'restored').single;
      expect(r['data'], {'downMs': 13000});
      expect(svc.sentinel.roots.byKey('conn.lost'), isNull);
    });

    test('conn/lost that ends inside the window: a blip, and no conn/restored', () async {
      await start();
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(4);
      svc.routesRestored(AutoNet(kind: 'restored', at: at(), downMs: 4000));
      await time.advanceSeconds(1);
      final e = events('conn', 'lost').single;
      expect([e['level'], e['verdict']], ['info', 'blip']);
      expect(events('conn', 'restored'), isEmpty);
    });

    test('conn/lost with the network gone is a consequence of conn/offline', () async {
      await start();
      svc.setNetwork({'connected': false});
      await time.advanceSeconds(11);
      final offline = events('conn', 'offline').single;
      svc.routesLost(lost(), 2);
      await time.advanceSeconds(1);
      final e = events('conn', 'lost').single;
      expect([e['verdict'], e['cause']], ['consequence', offline['id']]);
      expect(quiet(e), isTrue);
    });
  });
}
