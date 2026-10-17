// Events t1, the parts the core stage left without a check (docs/logs.md → Каталог типов, По типам, Уровни и атрибуция):
// `conn/reconnected` instead of `conn/connected` on a live plan change and on the user's quick reconnect, the shared
// `op` of "update all" (`subUpdateAll`) and of the app update (`appUpdate`), `copyAt` of `rules/ruleSetFailed`, and the
// `opens` of the closing `rules/targetFound`.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/appupdate_release.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'appupdate_test.dart' show Host, Net, publish, release;
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

Map<String, dynamic> _node() => {
  'key': 's::a',
  'outbound': {
    'type': 'shadowsocks',
    'server': '127.0.0.1',
    'server_port': 1,
    'method': 'aes-128-gcm',
    'password': 'x',
  },
};

Map<String, dynamic> _body({
  bool global = true,
  Map<String, dynamic>? routing,
}) => {
  'plan': {
    'routes': [
      {
        'id': 'A',
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': 's::a',
          'nodes': [_node()],
        },
      },
    ],
    'mixedPort': 2080,
    'global': global,
    'routing': ?routing,
  },
};

Future<void> _rm(Directory d) async {
  for (var i = 0; i < 10 && d.existsSync(); i++) {
    try {
      d.deleteSync(recursive: true);
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  group('with a fake core', () {
    late Directory tmp;
    late CoreService svc;
    late FakeTime time;
    late _Runner runner;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-t1-gaps');
      time = FakeTime();
      runner = _Runner();
      svc = CoreService(
        directProbe: (_, _) async => 5,
        sentinelClock: time.clock,
        now: () => time.t,
        isElevated: () => true,
        singBox: 'none',
        resolveAddresses: false, // hermetic: no real DoH
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
      await _rm(tmp);
    });

    List<Map> events(String cat) => [
      for (final e in (svc.eventBook.since(null)['events'] as List).cast<Map>())
        if (e['cat'] == cat) e,
    ];
    List<String> types(String cat) => [
      for (final e in events(cat)) '${e['type']}',
    ];

    group('conn/reconnected', () {
      test(
        'a live plan change writes reconnected {reason settings, changed, tookMs} with an op, own, and no second connected',
        () async {
          await svc.connect(_body());
          await time.advanceSeconds(6);
          expect(types('conn'), ['connected']);

          await svc.connect(_body(global: false));
          expect(
            types('conn'),
            ['connected', 'reconnected'],
            reason:
                'the live connection restarted by a plan change is one reconnect, not a new connect',
          );
          final e = events('conn').last;
          final d = e['data'] as Map;
          expect(d['reason'], 'settings');
          expect(
            d['changed'],
            containsPair('route', {'from': 'global', 'to': 'rules'}),
          );
          expect(d['tookMs'], isA<int>());
          expect(d['tookMs'] as int, greaterThanOrEqualTo(0));
          expect((e['op'] as Map)['kind'], 'reconnect');
          expect((e['op'] as Map)['id'], isA<String>());
          expect(e['own'], true, reason: 'the user changed the settings');
          expect(e['level'], 'info');
        },
      );

      test(
        'a plan change that changes nothing in the plan has no `changed`; each reconnect is its own op',
        () async {
          await svc.connect(_body());
          await time.advanceSeconds(6);
          await svc.connect(_body());
          await svc.connect(_body());
          final r = events(
            'conn',
          ).where((e) => e['type'] == 'reconnected').toList();
          expect(r, hasLength(2));
          for (final e in r) {
            expect(
              (e['data'] as Map).containsKey('changed'),
              isFalse,
              reason: 'absent when nothing changed (or only the unlisted)',
            );
          }
          expect({for (final e in r) (e['op'] as Map)['id']}, hasLength(2));
        },
      );

      test(
        'the user\'s disconnect and connect within 7 s: one op shared by conn/disconnected and conn/reconnected {reason user}',
        () async {
          await svc.connect(_body());
          await time.advanceSeconds(6);
          await svc.disconnect();
          await time.advanceSeconds(3);
          await svc.connect(_body());
          expect(types('conn'), ['connected', 'disconnected', 'reconnected']);
          final ev = events('conn');
          final dis = ev[1], re = ev[2];
          expect((re['data'] as Map)['reason'], 'user');
          expect(re['own'], true);
          expect(re['op'], isNotNull);
          expect(
            re['op'],
            dis['op'],
            reason: 'one line in the app: the two halves of the operation',
          );
          expect((dis['op'] as Map)['kind'], 'connection');
        },
      );

      test(
        'a connect after more than 7 s of the disconnect is a plain new connection',
        () async {
          await svc.connect(_body());
          await time.advanceSeconds(6);
          await svc.disconnect();
          await time.advanceSeconds(8);
          await svc.connect(_body());
          expect(types('conn'), ['connected', 'disconnected', 'connected']);
        },
      );
    });

    test(
      'rules/targetFound carries opens = the id of the rules/targetLost it closes (and the ids follow a repeated loss)',
      () async {
        Map<String, dynamic> withTarget({
          required bool lost,
          String fallback = 'block',
        }) => _body(
          global: false,
          routing: {
            'fallback': 'main',
            'targets': {
              'src:x': lost
                  ? null
                  : {
                      'id': 'src:x',
                      'kind': 'unit',
                      'main': {
                        'pick': 'priority',
                        'chosen': 's::a',
                        'nodes': [_node()],
                      },
                    },
            },
            'rules': [
              {
                'id': 'r1',
                'name': 'Video',
                'on': true,
                'action': 'proxy',
                'target': 'src:x',
                'fallback': fallback,
                if (lost) 'targetLost': 'deleted',
                'dns': 'auto',
                'groups': {
                  'domain': {
                    'not': false,
                    'v': {
                      'domain_suffix': ['video.test'],
                    },
                  },
                },
              },
            ],
          },
        );
        List<Map> told() => [
          for (final e in events('rules'))
            if ('${e['type']}'.startsWith('target')) e,
        ];

        await svc.connect(withTarget(lost: true));
        await svc.connect(
          withTarget(lost: true, fallback: 'direct'),
        ); // told again: a second targetLost
        final lost = told();
        expect(lost.map((e) => e['type']), ['targetLost', 'targetLost']);
        await svc.connect(withTarget(lost: false));
        final found = told().last;
        expect(found['type'], 'targetFound');
        expect(
          found['opens'],
          isIn([for (final e in lost) e['id']]),
          reason: 'it closes a targetLost of the same target',
        );
        expect(
          found['opens'],
          lost.last['id'],
          reason: 'the latest one: that is the line standing in the app',
        );
        expect(lost.first.containsKey('opens'), isFalse);
      },
    );

    for (final hasCopy in [true, false]) {
      test(
        'rules/ruleSetFailed ${hasCopy ? 'carries copyAt (the mtime of the previous copy, ms) with hasCopy' : 'without a copy: hasCopy false and no copyAt'}',
        () async {
          final gone = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final port = gone.port;
          await gone.close(force: true);
          final plain = ServiceFetch(
            endpoint: () => null,
            context: svc.sentinel.context,
          );
          svc.ruleSets.fetchSource = () => plain;
          final ctx = svc.sentinel.context;
          ctx.starting('userConnect');
          ctx.started();
          await time.advance(
            const Duration(minutes: 5),
          ); // settled: a failure is judged, not held back
          RuleSetSource dead(String tag) => RuleSetSource(
            tag,
            ['http://127.0.0.1:$port/$tag.srs'],
            viaVpn: false,
            every: Duration.zero,
          );

          final copy = File(
            p.join(tmp.path, 'data', 'rulesets', 'set-mine.srs'),
          );
          final mtime = DateTime.now().subtract(const Duration(days: 1));
          if (hasCopy) {
            copy.createSync(recursive: true);
            copy.writeAsBytesSync([0x53, 0x52, 0x53, 0x01, 0]);
            copy.setLastModifiedSync(mtime);
          }

          await svc.ruleSets.ensure([dead('set-mine')], refresh: true);
          await time.advance(const Duration(seconds: 1));
          final failed = [
            for (final e in events('rules'))
              if (e['type'] == 'ruleSetFailed') e['data'] as Map,
          ];
          expect(failed, hasLength(1));
          expect(failed.single['hasCopy'], hasCopy);
          if (hasCopy) {
            expect(
              failed.single['copyAt'],
              copy.lastModifiedSync().millisecondsSinceEpoch,
            );
            expect(
              (failed.single['copyAt'] as int) ~/ 1000,
              mtime.millisecondsSinceEpoch ~/ 1000,
            );
          } else {
            expect(
              failed.single.containsKey('copyAt'),
              isFalse,
              reason: 'no copy, no date',
            );
          }
        },
      );
    }

    group('subscription updates by the timer', () {
      late HttpServer origin;
      setUp(() async {
        origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        origin.listen((r) {
          r.response
            ..write('ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.20:8388#one')
            ..close();
        });
      });
      tearDown(() => origin.close(force: true));

      Map<String, dynamic> source(String id) => {
        'id': id,
        'kind': 'sub',
        'name': 'Sub $id',
        'enabled': true,
        'url': 'http://127.0.0.1:${origin.port}/$id',
        'userAgent': 'Auto',
        'updateInterval': 3600,
        'updatedAt': 0, // due
        'hwid': false,
        'filter': '',
        'offNodes': <String>[],
        'nodes': <Object>[],
        'gone': <Object>[],
      };

      Future<void> store(List<String> ids) => svc.store.save({
        'sourcesData': {for (final id in ids) id: source(id)},
        'sourceOrder': ids,
      });

      List<Map> subs() => [
        for (final e in events('sub'))
          if (e['type'] == 'updated') e,
      ];

      test(
        'several subscriptions due at one tick ("update all") share one op {kind subUpdateAll}',
        () async {
          await store(['s1', 's2', 's3']);
          expect(
            await svc.updater.runDue(),
            unorderedEquals(['s1', 's2', 's3']),
          );
          final ev = subs();
          expect(ev, hasLength(3));
          final ops = {for (final e in ev) '${(e['op'] as Map)['id']}'};
          expect(
            ops,
            hasLength(1),
            reason: 'one operation: the app folds them into one line',
          );
          expect(
            {for (final e in ev) (e['op'] as Map)['kind']},
            {'subUpdateAll'},
          );
        },
      );

      test(
        'a single due subscription is its own op {kind subUpdate}, and the next tick\'s is another op',
        () async {
          await store(['s1']);
          expect(await svc.updater.runDue(), ['s1']);
          await store(['s2']);
          expect(await svc.updater.runDue(), ['s2']);
          final ev = subs();
          expect(ev, hasLength(2));
          expect({for (final e in ev) (e['op'] as Map)['kind']}, {'subUpdate'});
          expect({for (final e in ev) (e['op'] as Map)['id']}, hasLength(2));
        },
      );
    });
  });

  group('app update events', () {
    late Directory tmp;
    late Host feed;
    late ReleaseKeys keys;
    CoreService? svc;

    setUpAll(() async => keys = await generateReleaseKeys());
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-t1-appupd');
      feed = await Host.start();
    });
    tearDown(() async {
      await svc?.dispose();
      svc = null;
      await feed.close();
      await _rm(tmp);
    });

    test(
      'offer and download of one cycle share an op {kind appUpdate}; a failure ends the cycle, the next event opens a new op',
      () async {
        publish(feed, await release(keys, version: '0.2.0', build: 2));
        final s = svc = CoreService(
          singBox: 'none',
          resolveAddresses: false,
          dataDir: p.join(tmp.path, 'data'),
          runner: _Runner(),
          sysProxy: NoSystemProxy(),
          exitCheck: (_) async => {'ip': '127.0.0.1'},
          appVersion: AppVersion.parse('0.1.0', build: 1),
          updatePlatformKeys: const ['android-arm64-v8a'],
          updateFeeds: [feed.base],
          updatePublicKeys: [keys.publicBase64],
          updateGet: Net(() => false).get,
          updateFirstDelay: const Duration(hours: 1),
        );
        await s.init();
        await s.updateCheck({'channel': 'stable', 'manual': true});
        await s.updateDownload();
        List<Map> app() => [
          for (final e
              in (s.eventBook.since(null)['events'] as List).cast<Map>())
            if (e['cat'] == 'core' && '${e['type']}'.startsWith('update')) e,
        ];
        var ev = app();
        expect(
          ev.map((e) => e['type']),
          containsAllInOrder(['updateAvailable', 'updateDownloaded']),
        );
        expect({for (final e in ev) (e['op'] as Map)['kind']}, {'appUpdate'});
        expect(
          {for (final e in ev) (e['op'] as Map)['id']},
          hasLength(1),
          reason: 'one operation, one line',
        );
        final first = (ev.first['op'] as Map)['id'];

        feed.fail['manifest-stable.json'] = 500;
        await s.updateCheck({'manual': true});
        ev = app();
        final failed = ev.where((e) => e['type'] == 'updateFailed').toList();
        expect(failed, isNotEmpty);
        expect((failed.last['op'] as Map)['kind'], 'appUpdate');
        expect(
          (failed.last['op'] as Map)['id'],
          first,
          reason: 'the failure closes the cycle it belongs to',
        );
        expect(failed.last['level'], 'warn');

        feed.fail.clear();
        await s.updateCheck({'channel': 'stable', 'manual': true});
        final next = app().last;
        expect(next['type'], 'updateAvailable');
        expect(
          (next['op'] as Map)['id'],
          isNot(first),
          reason: 'after the end of a cycle the next event opens a new op',
        );
      },
    );
  });
}
