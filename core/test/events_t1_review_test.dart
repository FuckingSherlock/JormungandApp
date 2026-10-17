// Events t1, review findings: a body with a non-map `error` on disconnect, every `sub/removed` closable by a
// `sub/back` (also a second one while the first is open), a manual update of a fresh source cut by our own restart
// is asked again after `settled`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const _h = 3600 * 1000;

class _NoSysProxy extends SystemProxy {
  _NoSysProxy() : super(File('never-written'));
  @override
  bool get isSet => false;
  @override
  Future<void> restore() async {}
}

void main() {
  group('jormd', () {
    late HttpServer server;
    late Daemon d;
    late Directory tmp;
    late HttpServer origin;
    var subBody = '';
    final client = HttpClient();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jormd-t1r');
      d = Daemon(
        singBox: 'no-sing-box',
        dataDir: tmp.path,
        uiFile: 'none',
        exitCheck: (_) async => throw StateError('no exit probes in tests'),
        sysProxy: _NoSysProxy(),
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(d.handle);
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) {
        r.response.write(subBody);
        r.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await origin.close(force: true);
      await d.events.flush();
      await tmp.delete(recursive: true);
    });

    Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      req.headers.set('X-Jorm', '1');
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    }

    test('disconnect with a non-map `error` in the body: treated as absent, no 500', () async {
      for (final bad in <Object?>['text', 5, [1], true]) {
        final (code, _) = await call('POST', '/api/disconnect', {'error': bad});
        expect(code, 200, reason: '$bad');
      }
    });

    test('a second sub/removed while the first is open: both stay closable, each sub/back closes one (the one naming its servers)', () async {
      Map<String, dynamic> src(Map<String, dynamic> patch) => {
            'id': 's1',
            'kind': 'sub',
            'name': 'S1',
            'enabled': true,
            'url': 'http://127.0.0.1:${origin.port}/sub',
            'userAgent': 'Auto',
            'updateInterval': 3600,
            'updatedAt': 0,
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': <Object>[],
            'gone': <Object>[],
            ...patch,
          };
      var state = src({});
      Future<void> fetch(List<String> links) async {
        subBody = links.join('\n');
        final (code, r) = await call('POST', '/api/sources/fetch', {'sid': 's1', 'source': state});
        expect(code, 200);
        state = src({...state, ...(r['patch'] as Map).cast<String, dynamic>()});
      }

      await fetch([vlessWs, trojanGrpc, ss2022]);
      await fetch([vlessWs, ss2022]); // SE dropped
      await fetch([vlessWs]); // SS2022 dropped while the first removal is open
      await fetch([vlessWs, ss2022]); // SS2022 back
      await fetch([vlessWs, ss2022, trojanGrpc]); // SE back

      final ev = ((await call('GET', '/api/events')).$2['events'] as List).cast<Map>();
      final removed = [for (final e in ev) if (e['type'] == 'removed') e];
      final back = [for (final e in ev) if (e['type'] == 'back') e];
      expect(removed, hasLength(2));
      expect(back, hasLength(2));
      expect([for (final e in removed) (e['data'] as Map)['names']], [['SE'], ['SS2022']]);
      expect([for (final e in back) e['opens']], [removed[1]['id'], removed[0]['id']], reason: 'by the names, not the order');
    });
  });

  group('updater askAgain', () {
    late Directory dir;
    late SnapshotStore store;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('jorm-t1r-upd');
      store = SnapshotStore(File(p.join(dir.path, 'ui-state.json')));
    });
    tearDown(() => dir.delete(recursive: true));

    test('a manual update of a fresh source cut by our own restart is retried after settled, not after its period', () async {
      const now = 100 * _h;
      await store.save({
        'sourcesData': {
          'src1': <String, dynamic>{
            'id': 'src1',
            'kind': 'sub',
            'name': 'Sub',
            'enabled': true,
            'url': 'u',
            'userAgent': 'Auto',
            'updateInterval': 12 * 3600,
            'updatedAt': now - _h, // fresh: not due by its period
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': <Object>[],
            'gone': <Object>[],
          },
        },
        'sourceOrder': ['src1'],
      });
      var cut = true, calls = 0;
      final u = SubscriptionUpdater(
        store: store,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        update: (s, {hwid, svc, sid, rediscover = false, now, onDiverged}) async {
          calls++;
          if (cut) {
            throw SubscriptionFetchException(
                SvcFailure('allFailed', 'sub.example', [SvcPathFailure('direct', SvcKind.direct, 'connect', 0)],
                    advice: const RetryAdvice(RetryWait.settled), purpose: 'subscription'),
                'https://sub.example/x');
          }
          return {
            'patch': {'nodes': [{'id': 'nA', 'name': 'A'}], 'count': 1, 'updatedAt': now!.millisecondsSinceEpoch},
          };
        },
      );

      expect(await u.runDue(), isEmpty);
      expect(calls, 0, reason: 'fresh and nobody asked: not due');

      u.askAgain('src1');
      expect(await u.runDue(), isEmpty);
      expect(calls, 1);
      expect(await u.runDue(), isEmpty, reason: 'still cut by our restart: asked again at the next tick');
      expect(calls, 2);

      cut = false; // settled
      expect(await u.runDue(), ['src1']);
      expect(calls, 3);
      expect(await u.runDue(), isEmpty, reason: 'done: back to its period');
      expect(calls, 3);
    });
  });
}
