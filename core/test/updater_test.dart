// Automatic subscription updates: periods, what is due, and how a timer update meets the
// UI's own saves in the stored snapshot. The e2e case fetches from a loopback provider.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const _h = 3600 * 1000;

Map<String, dynamic> _sub(String url, {Object interval = 'auto', int updatedAt = 0, Object? provider}) => {
      'id': 'src1',
      'kind': 'sub',
      'name': 'Sub',
      'enabled': true,
      'url': url,
      'userAgent': 'Auto',
      'updateInterval': interval,
      'updatedAt': updatedAt,
      'hwid': false,
      'filter': '',
      'offNodes': <String>[],
      'nodes': <Object>[],
      'gone': <Object>[],
      'providerInterval': ?provider,
    };

Map<String, dynamic> _snap(Map<String, dynamic> s, {num subsEvery = 12 * 3600}) => {
      'sourcesData': {'src1': s},
      'sourceOrder': ['src1'],
      'autoCfg': {'subsEvery': subsEvery},
    };

void main() {
  group('period', () {
    test('own hours, auto = provider (min 1 h) else global, 0 = never', () {
      expect(autoUpdatePeriod(_sub('u', interval: 6 * 3600), 3600), const Duration(hours: 6));
      expect(autoUpdatePeriod(_sub('u', interval: 0), 3600), isNull);
      expect(autoUpdatePeriod(_sub('u', interval: 90), 3600), const Duration(seconds: 90));
      expect(autoUpdatePeriod(_sub('u', interval: 3), 3600), const Duration(seconds: 10));
      expect(autoUpdatePeriod(_sub('u'), 3600), const Duration(hours: 1));
      expect(autoUpdatePeriod(_sub('u'), null), const Duration(hours: 12));
      expect(autoUpdatePeriod(_sub('u', provider: 24), 3600), const Duration(hours: 24));
      expect(autoUpdatePeriod(_sub('u', provider: 0.1), 3600), const Duration(hours: 1));
      expect(autoUpdatePeriod(_sub('u', provider: 24), 0), isNull); // global off = all off
      expect(autoUpdatePeriod(_sub('u', interval: 6 * 3600, provider: 24), 3600), const Duration(hours: 6));
      expect(autoUpdatePeriod({..._sub('u'), 'enabled': false}, 3600), isNull);
      expect(autoUpdatePeriod({'kind': 'node', 'enabled': true}, 3600), isNull);
    });

    test('due when the period passed; a failed try waits', () {
      final now = 100 * _h;
      expect(dueSubscriptions(_snap(_sub('u', updatedAt: now - 13 * _h)), now), ['src1']);
      expect(dueSubscriptions(_snap(_sub('u', updatedAt: now - 11 * _h)), now), isEmpty);
      expect(dueSubscriptions(_snap(_sub('u', updatedAt: now - 13 * _h)), now, triedAt: {'src1': now - 10 * 60000}), isEmpty);
      expect(dueSubscriptions(_snap(_sub('u', updatedAt: now - 13 * _h)), now, triedAt: {'src1': now - 31 * 60000}), ['src1']);
      expect(dueSubscriptions(null, now), isEmpty);
    });
  });

  group('store and timer', () {
    late Directory dir;
    late SnapshotStore store;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('jorm-upd');
      store = SnapshotStore(File(p.join(dir.path, 'ui-state.json')));
    });
    tearDown(() => dir.delete(recursive: true));

    // The update the timer runs, held until [release] completes.
    SubscriptionUpdater updater(Completer<void>? release, {int now = 100 * _h}) => SubscriptionUpdater(
          store: store,
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
          update: (s, {hwid, svc, sid, rediscover = false, now, onDiverged}) async {
            await release?.future;
            return {
              'patch': {
                'nodes': [{'id': 'nA', 'name': 'A'}],
                'count': 1,
                'announce': 'new',
                'updatedAt': now!.millisecondsSinceEpoch,
              },
            };
          },
        );

    test('a due source is patched on disk; rev moves; user fields stay', () async {
      await store.save(_snap(_sub('u', updatedAt: 80 * _h)));
      final done = await updater(null).runDue();
      expect(done, ['src1']);
      expect(store.rev, 1);
      final s = jsonDecode(await store.file.readAsString())['sourcesData']['src1'];
      expect([s['count'], s['announce'], s['updatedAt'], s['name']], [1, 'new', 100 * _h, 'Sub']);
    });

    test('a UI save with an older copy keeps the timer\'s server fields, takes the user\'s', () async {
      await store.save(_snap(_sub('u', updatedAt: 80 * _h)));
      await updater(null).runDue();
      // the UI never saw the update: its copy is the old one, with a server switched off
      final ui = _snap({..._sub('u', updatedAt: 80 * _h), 'offNodes': ['nA'], 'name': 'Renamed'});
      await store.save(ui);
      final s = (await store.read())!['sourcesData']['src1'];
      expect([s['count'], s['announce'], s['updatedAt']], [1, 'new', 100 * _h]);
      expect([s['offNodes'], s['name']], [['nA'], 'Renamed']);
      // a newer copy from the UI (its own update) wins as a whole
      await store.save(_snap({..._sub('u', updatedAt: 101 * _h), 'count': 7}));
      expect((await store.read())!['sourcesData']['src1']['count'], 7);
    });

    test('edited, updated or deleted during the fetch: the result is dropped', () async {
      for (final change in <Map<String, dynamic>? Function(Map<String, dynamic>)>[
        (s) => {...s, 'url': 'other'},
        (s) => {...s, 'filter': 'DE'},
        (s) => {...s, 'updatedAt': 99 * _h},
        (s) => null,
      ]) {
        await store.save(_snap(_sub('u', updatedAt: 80 * _h)));
        final release = Completer<void>();
        final run = updater(release).runDue();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final changed = change(_sub('u', updatedAt: 80 * _h));
        await store.save(changed == null ? {'sourcesData': {}, 'sourceOrder': []} : _snap(changed));
        release.complete();
        expect(await run, isEmpty);
      }
      expect(store.rev, 0);
    });

    test('a failed update notes lastError on the source; the next good one clears it', () async {
      await store.save(_snap(_sub('u', updatedAt: 80 * _h)));
      final failing = SubscriptionUpdater(
        store: store,
        clock: () => DateTime.fromMillisecondsSinceEpoch(100 * _h),
        update: (s, {hwid, svc, sid, rediscover = false, now, onDiverged}) async => throw const SocketException('refused'),
      );
      expect(await failing.runDue(), isEmpty);
      var s = (await store.read())!['sourcesData']['src1'];
      expect([s['lastError']['at'], s['updatedAt'], store.rev], [100 * _h, 80 * _h, 1]);
      expect('${s['lastError']['msg']}', contains('refused'));
      expect(await updater(null, now: 101 * _h).runDue(), ['src1']);
      s = (await store.read())!['sourcesData']['src1'];
      expect([s['lastError'], s['count']], [null, 1]);
    });

    test('a source the UI is updating is skipped', () async {
      await store.save(_snap(_sub('u', updatedAt: 80 * _h)));
      final u = updater(null);
      final hold = Completer<void>();
      final manual = u.guard('src1', () => hold.future);
      expect(await u.runDue(), isEmpty);
      hold.complete();
      await manual;
    });

    test('end to end: the real fetch fills the source from a loopback provider', () async {
      final pr = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => pr.close(force: true));
      pr.listen((req) async {
        req.response.headers.set('profile-update-interval', '3');
        req.response.write(req.headers.value('user-agent')!.startsWith('sing-box') ? singboxJson : clashYaml);
        await req.response.close();
      });
      await store.save(_snap(_sub('http://127.0.0.1:${pr.port}/sub', updatedAt: 0)));
      final u = SubscriptionUpdater(store: store);
      expect(await u.runDue(), ['src1']);
      final s = (await store.read())!['sourcesData']['src1'];
      expect([s['count'], s['format'], s['providerInterval'], (s['uaStrategy'] as List).length], [4, 'sing-box', 3.0, 2]);
    });
  });
}
