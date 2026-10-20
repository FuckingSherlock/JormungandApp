// The previous run ended with the VPN on and no `disconnected` of its own (killed, update install, crash): at core start
// `CoreService.init()` writes `conn/disconnected {by: app, reason: ended, found}` (docs/logs.md → conn/disconnected), first
// a `conn/vpnUp {by: app}` closing an open `vpnDown`; `at` of both = the last journal event of that run. The journal is
// seeded as a file (the dead run), then a new service starts over it.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Runner implements BoxRunner {
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => false;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) {}
  @override
  Future<void> start(Map<String, dynamic> config) async {}
  @override
  Future<void> stop() async {}
}

const _min = 60 * 1000;

void main() {
  late Directory tmp;
  late FakeTime time;
  final live = <CoreService>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-ended');
    time = FakeTime();
  });
  tearDown(() async {
    for (final s in live) {
      await s.dispose();
    }
    live.clear();
    for (var i = 0; i < 10 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  int ago(int minutes) => time.t.millisecondsSinceEpoch - minutes * _min;

  /// One journal line of the dead run.
  Map<String, dynamic> line(int id, String type, int at,
          {Map<String, dynamic> data = const {}, String level = 'info', int? opens, Map<String, Object?>? op}) =>
      {'id': id, 'at': at, 'cat': 'conn', 'type': type, 'level': level, 'own': false, 'data': data, 'opens': ?opens, 'op': ?op};

  void seed(List<Map<String, dynamic>> events) {
    final f = File(p.join(tmp.path, 'data', 'events.jsonl'));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync([for (final e in events) jsonEncode(e)].map((l) => '$l\n').join());
  }

  Future<CoreService> boot() async {
    final svc = CoreService(
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
    live.add(svc);
    await svc.init();
    return svc;
  }

  List<Map> conn(CoreService s) => [
        for (final e in (s.eventBook.since(null)['events'] as List).cast<Map>())
          if (e['cat'] == 'conn') e,
      ];
  List<String> types(CoreService s) => [for (final e in conn(s)) '${e['type']}'];

  group('the previous run ended with the VPN on', () {
    test('an open vpnDown: vpnUp {by app, downMs, causes} opens it, then disconnected {by app, reason ended, found}; both at the last event', () async {
      final start = time.t.millisecondsSinceEpoch;
      seed([
        line(0, 'connected', ago(50)),
        line(1, 'vpnDown', ago(30), level: 'error', data: {'causes': ['core']}),
        line(2, 'vpnDown', ago(20), level: 'error', data: {'causes': ['core']}),
      ]);
      final s = await boot();
      expect(types(s), ['connected', 'vpnDown', 'vpnDown', 'vpnUp', 'disconnected']);
      final up = conn(s)[3], dis = conn(s)[4];
      expect(up['level'], 'info');
      expect(dis['level'], 'info');
      expect(up['at'], ago(20), reason: 'the last event of that run, not now');
      expect(dis['at'], ago(20));
      final d = up['data'] as Map;
      expect(d['by'], 'app');
      expect(d['causes'], ['core']);
      expect(up['opens'], isIn([1, 2]), reason: 'the vpnDown that stood open (the latest one is what the app shows)');
      expect(up['opens'], 2);
      expect(d['downMs'], isA<int>());
      expect(d['downMs'], greaterThanOrEqualTo(0));
      final x = dis['data'] as Map;
      expect([x['by'], x['reason']], ['app', 'ended']);
      expect(x['found'], start, reason: 'found = the start of this run');
      expect(dis['own'], isNot(true));
    });

    for (final (name, journal) in [
      ('connected', [('connected', <String, dynamic>{})]),
      ('reconnected', [('connected', <String, dynamic>{}), ('reconnected', <String, dynamic>{'reason': 'settings'})]),
      (
        'a vpnDown already closed by a recovery',
        [
          ('connected', <String, dynamic>{}),
          ('vpnDown', <String, dynamic>{'causes': ['core']}),
          ('vpnUp', <String, dynamic>{'downMs': 1000, 'causes': ['core'], 'opens': 1}),
        ]
      ),
    ]) {
      test('$name last: disconnected {by app} only, no vpnUp, at the last event', () async {
        seed([
          for (var i = 0; i < journal.length; i++)
            line(i, journal[i].$1, ago(10 - i), data: {...journal[i].$2}..remove('opens'), opens: journal[i].$2['opens'] as int?),
        ]);
        final s = await boot();
        final before = journal.length;
        expect(conn(s), hasLength(before + 1));
        expect(types(s).skip(before), ['disconnected']);
        final dis = conn(s).last;
        expect(dis['at'], ago(10 - (before - 1)));
        expect(dis['data'], containsPair('by', 'app'));
        expect(dis['data'], containsPair('reason', 'ended'));
        expect(dis['level'], 'info');
      });
    }

    test('the user\'s quick reconnect (disconnected op X, vpnUp by user, reconnected user op X) at the end counts as on', () async {
      final op = {'id': 'X', 'kind': 'connection'};
      seed([
        line(0, 'connected', ago(10)),
        line(1, 'vpnDown', ago(9), level: 'error', data: {'causes': ['core']}),
        line(2, 'disconnected', ago(8), data: {'by': 'user'}, op: op),
        line(3, 'vpnUp', ago(8), data: {'downMs': 1000, 'causes': ['core'], 'by': 'user'}, opens: 1),
        line(4, 'reconnected', ago(7), data: {'reason': 'user'}, op: op),
      ]);
      final s = await boot();
      expect(types(s), ['connected', 'vpnDown', 'disconnected', 'vpnUp', 'reconnected', 'disconnected']);
      final dis = conn(s).last;
      expect((dis['data'] as Map)['by'], 'app');
      expect(dis['at'], ago(7));
    });
  });

  group('nothing to write', () {
    for (final by in ['user', 'system', 'error']) {
      test('the journal ends in disconnected by $by', () async {
        seed([
          line(0, 'connected', ago(10)),
          line(1, 'disconnected', ago(5), data: {'by': by}, level: by == 'user' ? 'info' : 'warn'),
        ]);
        final s = await boot();
        expect(types(s), ['connected', 'disconnected']);
      });
    }

    test('an empty journal, and one without VPN-line events', () async {
      final s = await boot();
      expect(conn(s), isEmpty);
      await s.dispose();
      live.clear();
      seed([
        {'id': 0, 'at': ago(5), 'cat': 'net', 'type': 'switched', 'level': 'info', 'own': false, 'data': <String, dynamic>{}},
      ]);
      final s2 = await boot();
      expect(conn(s2), isEmpty);
    });

    test('a second start after the written disconnected writes nothing more', () async {
      seed([
        line(0, 'connected', ago(10)),
        line(1, 'vpnDown', ago(9), level: 'error', data: {'causes': ['core']}),
      ]);
      final s = await boot();
      expect(types(s), ['connected', 'vpnDown', 'vpnUp', 'disconnected']);
      await s.eventBook.flush();
      await s.dispose();
      live.clear();
      time.t = time.t.add(const Duration(minutes: 1));
      final s2 = await boot();
      expect(types(s2), ['connected', 'vpnDown', 'vpnUp', 'disconnected'], reason: 'the written disconnected makes the state off');
    });
  });

  group('the line and the notifications', () {
    EventRecord rec(int id, String type, int at, {Map<String, dynamic> data = const {}, int? opens, String level = 'info'}) =>
        EventRecord.fromJson({'id': id, 'at': at, 'cat': 'conn', 'type': type, 'level': level, 'own': false, 'data': data, 'opens': ?opens});

    test('vpnUp by app: the VPN is off below it, with a dot', () {
      final m = vpnLineMarks([
        rec(1, 'connected', 0),
        rec(2, 'vpnDown', 1000, level: 'error', data: {'causes': ['core']}),
        rec(3, 'vpnUp', 2000, opens: 2, data: {'downMs': 1000, 'causes': ['core'], 'by': 'app'}),
      ]);
      expect([m[3]!.above, m[3]!.below, m[3]!.dot], [VpnLine.down, VpnLine.off, VpnDot.change]);
    });

    test('disconnected by app: off below it, with a dot', () {
      final m = vpnLineMarks([
        rec(1, 'connected', 0),
        rec(2, 'disconnected', 1000, data: {'by': 'app', 'reason': 'ended'}),
      ]);
      expect([m[2]!.above, m[2]!.below, m[2]!.dot], [VpnLine.on, VpnLine.off, VpnDot.change]);
    });

    test('neither of the two written at start notifies', () {
      final up = rec(3, 'vpnUp', 2000, opens: 2, data: {'by': 'app', 'downMs': 1, 'causes': ['core']});
      final dis = rec(4, 'disconnected', 2000, data: {'by': 'app', 'reason': 'ended'});
      expect(eventNotifies(null, up), isFalse);
      expect(eventNotifies(null, dis), isFalse);
    });
  });
}
