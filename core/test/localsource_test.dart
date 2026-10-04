// Local sources (localsource.dart, docs/connect-model.md → «Локальный источник»): a picked
// file (sing-box JSON, Clash YAML, a link list) becomes a source with no URL. What is read,
// the errors, that no refresh path touches it, and that the snapshot / backup carries it.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

class _NoSysProxy extends SystemProxy {
  _NoSysProxy() : super(File('never-written'));
  @override
  bool get isSet => false;
  @override
  Future<void> restore() async {}
}

Map<String, dynamic> _import(String name, String text) =>
    localSourceFromText(name, text, now: DateTime.utc(2026, 10, 4));

List<Map> _nodes(Map<String, dynamic> s) => (s['nodes'] as List).cast<Map>();

Map<String, dynamic> _snap(Map<String, dynamic> local) => {
  'sourcesData': {
    'src1': {
      'id': 'src1',
      'kind': 'sub',
      'name': 'Sub',
      'enabled': true,
      'inAuto': true,
      'url': 'https://sub.example/x',
      'nodes': <Object>[],
    },
    'src2': {'id': 'src2', ...local},
  },
  'sourceOrder': ['src1', 'src2'],
  'sourceSeq': 3,
  'connectMode': 'simple',
  'connectOrder': ['src2'],
  'activeConnectId': 'src2',
  'catalogOrder': {
    'simple': ['src1', 'src2'],
    'profiles': ['p'],
  },
  'profilesData': {
    'p': {
      'id': 'p',
      'name': 'Files',
      'sources': ['src2'],
      'nodes': <String>[],
      'inAuto': true,
    },
  },
  'modeState': {
    'profiles': {
      'order': ['p'],
      'active': 'p',
      'auto': true,
    },
  },
};

void main() {
  group('what a file gives', () {
    test(
      'sing-box JSON: server outbounds only, as a local source with no URL',
      () {
        final s = _import('my-config.json', singboxJson);
        expect(s['kind'], 'file');
        expect(s['name'], 'my-config');
        expect(s['format'], 'sing-box');
        expect(s.containsKey('url'), isFalse);
        expect(
          s['updatedAt'],
          DateTime.utc(2026, 10, 4).millisecondsSinceEpoch,
        );
        // the selector / the detour'ed / the direct outbound are not servers
        expect(_nodes(s).map((n) => n['protocol']), ['vless']);
        expect(s['count'], 1);
        expect(_nodes(s).single['id'], startsWith('n'));
        expect(_nodes(s).single['outbound'], isA<Map>());
        expect(s['enabled'], isTrue);
        expect(s['inAuto'], isTrue);
        expect(s['offNodes'], isEmpty);
        expect(s['gone'], isEmpty);
      },
    );

    test('Clash YAML: proxies, unsupported types stay in the list flagged', () {
      final s = _import('clash.yaml', clashYaml);
      expect(s['format'], 'clash');
      expect(s['name'], 'clash');
      expect(_nodes(s), isNotEmpty);
      expect(
        _nodes(s).any((n) => n['unsupported'] != null),
        isTrue,
        reason: 'the unknown type is shown, not dropped',
      );
      expect(s['count'], _nodes(s).length);
    });

    test(
      'a link list: plain, and base64-wrapped; the same server twice is one node',
      () {
        final plain = _import(
          'servers.txt',
          [...allLinks, vlessReality].join('\n'),
        );
        expect(plain['format'], 'links');
        expect(
          _nodes(plain).length,
          allLinks.length,
          reason: 'one node per distinct server',
        );
        final ids = _nodes(plain).map((n) => n['id']).toList();
        expect(ids.toSet().length, ids.length);

        final wrapped = _import(
          'servers',
          base64.encode(utf8.encode(allLinks.join('\n'))),
        );
        expect(wrapped['format'], 'base64');
        expect(
          _nodes(wrapped).map((n) => n['id']),
          _nodes(plain).map((n) => n['id']),
        );
      },
    );

    test(
      'ids are the subscription ids, equal names are numbered the same way',
      () {
        final s = _import(
          'f',
          [
            vlessReality,
            vlessReality.replaceFirst('de1.example', 'de2.example'),
          ].join('\n'),
        );
        final n = _nodes(s);
        expect(n.map((x) => x['name']), ['Frankfurt 01-1', 'Frankfurt 01-2']);
        final sub = parseSubscription(vlessReality).$2.single;
        expect(
          n.first['id'],
          sub.id,
          reason: 'one server is one id in any source',
        );
      },
    );

    test(
      'name: the file extension goes, other dots stay, an empty name is "Local file"',
      () {
        expect(localSourceName('work.yaml'), 'work');
        expect(localSourceName('My VPN.JSON'), 'My VPN');
        expect(localSourceName('a.b.c.conf'), 'a.b.c');
        expect(localSourceName('my.vpn'), 'my.vpn');
        expect(localSourceName('.json'), 'Local file');
        expect(localSourceName('  '), 'Local file');
      },
    );

    test('nothing recognised is an error with a message', () {
      for (final bad in [
        '',
        '   \n',
        'hello world',
        '{"not": "singbox"}',
        '[1,2,3]',
        'proxies:\n',
        'proxies: []\n',
        '<html>no</html>',
        '{"outbounds":[{"type":"direct","tag":"d"}]}',
      ]) {
        expect(
          () => _import('x.txt', bad),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'No servers found in the file',
            ),
          ),
          reason: bad,
        );
      }
    });
  });

  group('through CoreService and jormd', () {
    late Directory tmp;
    late CoreService svc;
    late HttpServer server;
    late Daemon d;
    final client = HttpClient();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-local');
      d = Daemon(
        singBox: 'no-sing-box',
        dataDir: p.join(tmp.path, 'data'),
        uiFile: 'none',
        exitCheck: (_) async => throw StateError('no exit probes in tests'),
        sysProxy: _NoSysProxy(),
      );
      await d.init();
      svc = d.service;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(d.handle);
    });
    tearDown(() async {
      await server.close(force: true);
      await d.shutdown();
      await tmp.delete(recursive: true);
    });

    Future<(int, dynamic)> post(String path, Object body) async {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      req.headers.set('X-Jorm', '1');
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    }

    test(
      'addSourceFromText returns the source; garbage throws and nothing is stored',
      () async {
        final r = svc.addSourceFromText({
          'name': 'office.yml',
          'text': clashYaml,
        });
        final s = r['source'] as Map<String, dynamic>;
        expect(s['kind'], 'file');
        expect(s['name'], 'office');
        expect(
          s.containsKey('id'),
          isFalse,
          reason: 'the catalog owner allocates the id',
        );
        expect(
          () => svc.addSourceFromText({'name': 'x.txt', 'text': 'garbage'}),
          throwsFormatException,
        );
        expect(() => svc.addSourceFromText({}), throwsFormatException);
        expect(
          (await svc.state())['snapshot'],
          isNull,
          reason:
              'the core stores nothing by itself: the catalog owner saves the state',
        );
      },
    );

    test(
      'POST /api/sources/import: 200 with the source, 400 with the reason',
      () async {
        var (code, r) = await post('/api/sources/import', {
          'name': 'sb.json',
          'text': singboxJson,
        });
        expect(code, 200);
        expect(r['source']['name'], 'sb');
        expect(r['source']['format'], 'sing-box');
        (code, r) = await post('/api/sources/import', {
          'name': 'sb.json',
          'text': 'nothing here',
        });
        expect(
          [code, r],
          [
            400,
            {'error': 'No servers found in the file'},
          ],
        );
      },
    );

    test('no refresh path takes it: timer, due list, manual fetch', () async {
      final s = {'id': 'src2', ..._import('f.txt', allLinks.join('\n'))};
      expect(autoUpdatePeriod(s, 3600), isNull);
      expect(
        autoUpdatePeriod({...s, 'updateInterval': 60}, 3600),
        isNull,
        reason: 'not even with a period of its own',
      );
      final snap = _snap(s);
      final year = 365 * 24 * 3600 * 1000;
      // a subscription is due after a year, the file never is
      expect(dueSubscriptions(snap, year), ['src1']);
      (snap['sourcesData'] as Map).remove('src1');
      snap['sourceOrder'] = ['src2'];
      expect(dueSubscriptions(snap, year), isEmpty);

      await expectLater(
        svc.fetchSource({'sid': 'src2', 'source': s}),
        throwsFormatException,
      );
      final (code, r) = await post('/api/sources/fetch', {
        'sid': 'src2',
        'source': s,
      });
      expect(code, 400);
      expect(r['error'], contains('import the file again'));
    });

    test(
      'a UI save keeps it as it is, a rename too (the conflict merge of saves is for subscriptions only)',
      () async {
        final s = _import('f.txt', allLinks.join('\n'));
        await svc.saveState(_snap(s));
        final back = (await svc.state())['snapshot'] as Map<String, dynamic>;
        final saved = (back['sourcesData'] as Map)['src2'] as Map;
        expect(saved['kind'], 'file');
        saved['name'] = 'Renamed';
        await svc.saveState(back);
        final again =
            ((await svc.state())['snapshot'] as Map)['sourcesData']['src2']
                as Map;
        expect(
          [again['name'], again['kind'], (again['nodes'] as List).length],
          ['Renamed', 'file', allLinks.length],
        );
      },
    );
  });

  group('snapshot and backup', () {
    test(
      'the catalog round-trips it; a backup file is the snapshot, so it carries the source, and restore gets it back',
      () {
        final s = _import('office.json', singboxJson);
        final snap = _snap(s);
        final c = Catalog.fromJson(
          jsonDecode(jsonEncode(snap)) as Map<String, dynamic>,
        );
        final src = c.sourcesData['src2']!;
        expect(src.kind, 'file');
        expect(src.url, isNull);
        expect(src.nodes.map((n) => n.protocol), ['vless']);
        // everything the import wrote is still there after a pass through the model
        final out = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
        final got = (out['sourcesData'] as Map)['src2'] as Map;
        for (final e in s.entries) {
          expect(got[e.key], e.value, reason: e.key);
        }
        // Settings → Data → Export backup: {app, backup: 1, at, snapshot}; Restore reads the snapshot back
        final file = jsonEncode({
          'app': 'Jormungand',
          'backup': 1,
          'at': 0,
          'snapshot': out,
        });
        final restored = Catalog.fromJson(
          ((jsonDecode(file) as Map)['snapshot'] as Map)
              .cast<String, dynamic>(),
        );
        expect(restored.sourcesData['src2']!.kind, 'file');
        expect(
          restored.sourcesData['src2']!.nodes.single.id,
          src.nodes.single.id,
        );
        expect(jsonEncode(restored.toJson()), jsonEncode(c.toJson()));
      },
    );

    test(
      'the state on disk (SnapshotStore) keeps it across a restart',
      () async {
        final tmp = await Directory.systemTemp.createTemp('jorm-local-store');
        try {
          final f = File(p.join(tmp.path, 'ui-state.json'));
          await SnapshotStore(
            f,
          ).save(_snap(_import('f.txt', allLinks.join('\n'))));
          final back = await SnapshotStore(f).read();
          final s = (back!['sourcesData'] as Map)['src2'] as Map;
          expect(
            [s['kind'], s['format'], (s['nodes'] as List).length],
            ['file', 'links', allLinks.length],
          );
          expect(s.containsKey('url'), isFalse);
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );

    test(
      'delete impact is the same as for any source: a profile left with no servers, the connection',
      () {
        final c = Catalog.fromJson(
          jsonDecode(jsonEncode(_snap(_import('f.json', singboxJson))))
              as Map<String, dynamic>,
        );
        final lines = c
            .deleteSourceImpact('src2')
            .map((l) => '${l.name}|${l.kind}|${l.level}')
            .toList();
        expect(lines, contains('Files|profile|bad'), reason: lines.join(', '));
        c.deleteSource('src2');
        expect(c.sourcesData.keys, ['src1']);
        expect(c.profilesData['p']!.sources, isEmpty);
      },
    );
  });
}
