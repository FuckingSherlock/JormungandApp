// The events journal: the book itself (append, since, clear, pruning by age and count,
// the file, a corrupt line, ids after a restart), /api/events, and what the daemon writes
// into it without a sing-box (rule-set downloads, the timer's subscription updates). The
// Auto switch, connect and crash events are in auto_singbox_test.dart (real sing-box,
// loopback only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const _day = Duration(days: 1);

class _NoSysProxy extends SystemProxy {
  _NoSysProxy() : super(File('never-written'));
  @override
  bool get isSet => false;
  @override
  Future<void> restore() async {}
}

void main() {
  group('EventBook', () {
    late Directory tmp;
    late File file;
    var now = DateTime(2026, 9, 29, 12);

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-ev');
      file = File(p.join(tmp.path, 'sub', 'events.jsonl')); // the directory does not exist yet
      now = DateTime(2026, 9, 29, 12);
    });
    final books = <EventBook>[];
    tearDown(() async {
      await Future.wait(books.map((b) => b.flush())); // no timer of a book writes into a deleted directory
      books.clear();
      await tmp.delete(recursive: true);
    });

    EventBook book({LogBook? log, int cap = 1000, int pruneChunk = 100}) {
      final b = EventBook(file, log: log, cap: cap, pruneChunk: pruneChunk, clock: () => now);
      books.add(b);
      return b;
    }

    List<String> lines() => file.existsSync() ? file.readAsLinesSync() : [];
    List<Object?> ids() => [for (final l in lines()) (jsonDecode(l) as Map)['id'] ?? 'seq'];

    test('update: the event changes where it is (rev, data laid over, id and place kept), is pushed again, rides in updated, and is rewritten to the file', () async {
      final b = book();
      final pushed = <Map<String, dynamic>>[];
      b.stream.listen(pushed.add);
      final id = b.add('site', 'unreachable', 'warn', data: {'host': 'a.com', 'check': {'state': 'pending'}});
      b.add('conn', 'lost', 'warn');
      expect(b.since(null)['updated'], isNull);
      expect(b.update(id, data: {'check': {'state': 'opens'}}), isTrue);
      expect(b.update(99, data: {'x': 1}), isFalse);
      final r = b.since(null);
      final e = (r['events'] as List).cast<Map>();
      expect(e.map((x) => x['id']), [0, 1], reason: 'same place');
      expect([e.first['rev'], e.first['level'], e.first['data']], [1, 'warn', {'host': 'a.com', 'check': {'state': 'opens'}}]);
      expect(e.last.containsKey('rev'), isFalse);
      expect((r['updated'] as List).single['id'], id);
      expect(((b.since(5)['updated']) as List).single['id'], id, reason: 'whatever the cursor');
      await Future<void>.delayed(Duration.zero);
      expect(pushed.map((x) => x['id']), [0, 1, 0], reason: 'the change is pushed as the event itself');
      now = now.add(const Duration(minutes: 11));
      expect(b.since(null)['updated'], isNull, reason: 'a change leaves the list after 10 minutes');
      await b.flush();
      expect([for (final l in lines()) (jsonDecode(l) as Map)['rev']], [null, 1, null], reason: 'seq line, the changed event, the other');
      final again = book()..load();
      expect((again.since(null)['events'] as List).first['data'], {'host': 'a.com', 'check': {'state': 'opens'}});
    });

    test('append: id, at, the shape; since = ids from N, none = the last 200; next and first', () {
      final b = book();
      expect(b.since(null), {'events': [], 'next': 0, 'first': 0});
      final id = b.add('auto', 'switched', 'info', data: {'from': 'A', 'to': 'B', 'reason': 'failover'});
      b.add('conn', 'lost', 'warn', own: true);
      expect(id, 0);
      var r = b.since(null);
      expect(r['next'], 2);
      expect(r['first'], 0);
      final e = (r['events'] as List).cast<Map>();
      expect(e.first, {
        'id': 0,
        'at': now.millisecondsSinceEpoch,
        'cat': 'auto',
        'type': 'switched',
        'level': 'info',
        'own': false,
        'data': {'from': 'A', 'to': 'B', 'reason': 'failover'},
      });
      expect([e.last['id'], e.last['own'], e.last['data']], [1, true, {}]);
      expect(((b.since(1)['events']) as List).map((x) => (x as Map)['id']), [1]);
      expect(((b.since(5)['events']) as List), isEmpty);

      for (var i = 0; i < 250; i++) {
        b.add('core', 'deprecated', 'warn', data: {'text': '$i'});
      }
      r = b.since(null);
      expect((r['events'] as List).length, 200);
      expect((r['events'] as List).first['id'], 52);
      expect([r['next'], r['first']], [252, 0], reason: '`first` is the oldest kept, not the first of the answer');
    });

    test('log: the LogBook number of the line written last; none while the book is empty', () {
      final log = LogBook();
      final b = book(log: log);
      b.add('core', 'crashed', 'error', data: {'code': 1});
      log.note('error', 'a');
      log.note('error', 'b');
      b.add('core', 'crashed', 'error', data: {'code': 2});
      b.add('user', 'pin', 'info', link: false);
      final e = (b.since(null)['events'] as List).cast<Map>();
      expect(e[0].containsKey('log'), isFalse);
      expect(e[1]['log'], 1);
      expect(e[2].containsKey('log'), isFalse);
    });

    test('clear: empty, ids go on, `first` = next', () {
      final b = book();
      b.add('core', 'restarted', 'info');
      b.add('core', 'restarted', 'info');
      b.clear();
      var r = b.since(null);
      expect([r['events'], r['next'], r['first']], [isEmpty, 2, 2]);
      expect(b.add('core', 'restarted', 'info'), 2);
      r = b.since(null);
      expect([r['next'], r['first']], [3, 2]);
    });

    test('pruned by count: the oldest go from memory at once, the file is rewritten once enough are stale', () async {
      final b = book(cap: 5, pruneChunk: 3);
      for (var i = 0; i < 7; i++) {
        b.add('core', 'restarted', 'info', data: {'attempt': i});
      }
      final r = b.since(null);
      expect([for (final e in r['events'] as List) (e as Map)['id']], [2, 3, 4, 5, 6]);
      expect(r['first'], 2);
      await b.flush();
      expect(ids(), [0, 1, 2, 3, 4, 5, 6], reason: '2 stale, under the chunk: appended, nothing rewritten');

      b.add('core', 'restarted', 'info', data: {'attempt': 7}); // 3 stale: the chunk is full
      await b.flush();
      expect(ids(), ['seq', 3, 4, 5, 6, 7], reason: 'the marker line and the five kept');
      expect(book(cap: 5).since(null)['first'], 3);
    });

    test('writes are buffered: one append per burst, after flushEvery or on flush; a rewrite never doubles a pending line', () async {
      final b = EventBook(file, flushEvery: const Duration(milliseconds: 150), clock: () => now);
      books.add(b);
      b.add('core', 'restarted', 'info');
      b.add('core', 'restarted', 'info');
      expect(file.existsSync(), isFalse, reason: 'nothing is written inside the call');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(ids(), [0, 1], reason: 'the timer wrote both');

      b.add('core', 'restarted', 'info');
      await b.flush();
      expect(ids(), [0, 1, 2], reason: 'flush does not wait for the timer');
      await b.flush();
      expect(ids(), [0, 1, 2], reason: 'nothing pending: nothing written');

      b.add('core', 'restarted', 'info');
      b.clear(); // the pending line is dropped with the rest, the file is rewritten
      b.add('core', 'restarted', 'info');
      await b.flush();
      expect(ids(), ['seq', 4]);
      expect((jsonDecode(lines().first) as Map)['seq'], 4, reason: 'the marker is what the clear saw; the next event follows it');
    });

    test('pruned by age: on append and on start', () async {
      final b = book(pruneChunk: 1);
      b.add('core', 'restarted', 'info');
      now = now.add(_day * 3);
      b.add('core', 'restarted', 'info');
      now = now.add(_day * 5); // the first is 8 days old, the second 5
      b.add('core', 'restarted', 'info');
      expect([for (final e in b.since(null)['events'] as List) (e as Map)['id']], [1, 2]);
      await b.flush();
      expect(lines().length, 3);

      now = now.add(_day * 3); // on start: 8 and 3 days old
      final again = book();
      expect(again.length, 1);
      expect(again.since(null)['first'], 2);
      expect(lines().length, 2, reason: 'the old line is gone from the file at once');
    });

    test('since: by id, whatever was pruned or cleared; ids older than the oldest kept give all, ahead give none', () {
      final b = book(cap: 50);
      List<int> got(int? from, {int tail = 200}) => [for (final e in b.since(from, tail: tail)['events'] as List) (e as Map)['id'] as int];
      for (var i = 0; i < 120; i++) {
        b.add('core', 'restarted', 'info');
      }
      expect(got(null), [for (var i = 70; i < 120; i++) i]);
      expect(got(null, tail: 10), [for (var i = 110; i < 120; i++) i]);
      expect(got(0), got(null));
      expect(got(70), got(null));
      expect(got(71).length, 49);
      expect(got(119), [119]);
      expect(got(120), isEmpty);
      expect(got(5000), isEmpty);
      b.clear();
      expect(got(0), isEmpty);
      b.add('core', 'restarted', 'info');
      expect(got(0), [120]);
      expect(got(120), [120]);
      expect(got(121), isEmpty);
    });

    test('persisted: a new book on the same file has the same events; ids go on', () async {
      final b = book();
      b.add('auto', 'switched', 'info', data: {'from': 'A', 'to': 'B'});
      b.add('site', 'blocked', 'warn', data: {'host': 'x.example'}, bg: true);
      await b.flush();
      final again = book();
      expect(again.since(null), b.since(null));
      expect((again.since(null)['events'] as List).map((e) => (e as Map)['bg']), [null, true], reason: 'bg only when true, kept in the file');
      expect(again.add('core', 'restarted', 'info'), 2);
      await again.flush();
      expect(book().length, 3);
    });

    test('ids never go back: after a clear, and when every event was pruned by age', () async {
      final b = book();
      b.add('core', 'restarted', 'info');
      b.add('core', 'restarted', 'info');
      b.clear();
      await b.flush();
      final next = book();
      expect(next.add('core', 'restarted', 'info'), 2);
      await next.flush();

      now = now.add(_day * 30); // all old
      final old = book();
      expect(old.length, 0);
      expect(old.since(null)['next'], 3);
      expect(old.add('core', 'restarted', 'info'), 3);
    });

    test('a corrupt line (garbage, a write cut off by a crash) is dropped; the rest stays and appends work', () async {
      final b = book();
      b.add('core', 'restarted', 'info', data: {'attempt': 1});
      b.add('core', 'restarted', 'info', data: {'attempt': 2});
      await b.flush();
      final good = lines();
      file.writeAsStringSync('${good[0]}\nnot json at all\n{"id": "x"}\n[1,2]\n${good[1]}\n{"id": 2, "at": 1, "ca', flush: true);
      final again = book();
      expect([for (final e in again.since(null)['events'] as List) (e as Map)['id']], [0, 1]);
      expect(again.add('core', 'restarted', 'info'), 2);
      await again.flush();
      expect(lines().every((l) => jsonDecode(l) is Map), isTrue, reason: 'the file was cleaned and ends on a whole line');
      expect(book().length, 3);
    });

    test('a file that cannot be written does not break the book; once it can, the journal is written whole', () async {
      final dir = Directory(p.join(tmp.path, 'a-file'));
      File(dir.path).writeAsStringSync('in the way of the directory');
      final b = EventBook(File(p.join(dir.path, 'events.jsonl')), clock: () => now);
      expect(b.add('core', 'restarted', 'info'), 0);
      expect(b.length, 1);
      await b.flush(); // fails quietly
      File(dir.path).deleteSync();
      dir.createSync();
      b.add('core', 'restarted', 'info');
      await b.flush();
      expect(EventBook(File(p.join(dir.path, 'events.jsonl')), clock: () => now).length, 2, reason: 'the first event came back with the rewrite');
    });
  });

  group('jormd /api/events', () {
    late HttpServer server;
    late Daemon d;
    late Directory tmp;
    late HttpServer origin;
    var hit = 200;
    var subBody = '';
    final client = HttpClient();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jormd-ev');
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
      hit = 200;
      origin.listen((r) {
        // /sub = a subscription, /bad = a provider that fails, else a rule set answered with [hit]
        final path = r.uri.path;
        r.response.statusCode = path == '/bad' ? 500 : (path == '/sub' ? 200 : hit);
        if (path == '/sub') r.response.write(subBody);
        if (path != '/sub' && path != '/bad' && hit == 200) r.response.add([0x53, 0x52, 0x53, 1, 2]);
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

    List<Map> types(dynamic r) => (r['events'] as List).cast<Map>();

    test('POST, GET since, DELETE: ids go on', () async {
      var (code, r) = await call('POST', '/api/events', {
        'cat': 'sub',
        'type': 'updated',
        'level': 'info',
        'data': {'source': 's1', 'name': 'Sub', 'added': 2, 'removed': 0, 'total': 9},
      });
      expect([code, r], [200, {'id': 0}]);
      (code, r) = await call('POST', '/api/events', {'cat': 'user', 'type': 'pin', 'level': 'info', 'own': true, 'data': {'action': 'pin'}});
      expect(r, {'id': 1});

      (code, r) = await call('GET', '/api/events');
      expect(code, 200);
      expect([r['next'], r['first']], [2, 0]);
      expect(types(r).map((e) => '${e['cat']}/${e['type']}'), ['sub/updated', 'user/pin']);
      expect(types(r)[1]['own'], isTrue);
      expect(types(r)[0]['own'], isFalse);
      expect(types(r)[0].containsKey('log'), isFalse, reason: 'the UI\'s events have no raw line');
      expect(types(r)[0]['data'], {'source': 's1', 'name': 'Sub', 'added': 2, 'removed': 0, 'total': 9});

      (_, r) = await call('GET', '/api/events?since=1');
      expect(types(r).map((e) => e['id']), [1]);
      (_, r) = await call('GET', '/api/events?since=2');
      expect([types(r), r['next']], [isEmpty, 2]);

      expect((await call('DELETE', '/api/events')).$2, {'ok': true});
      (_, r) = await call('GET', '/api/events');
      expect([types(r), r['next'], r['first']], [isEmpty, 2, 2]);
      expect((await call('POST', '/api/events', {'cat': 'user', 'type': 'mode', 'level': 'info'})).$2, {'id': 2});
      await d.events.flush();
      expect(File(p.join(tmp.path, 'events.jsonl')).existsSync(), isTrue);
    });

    test('POST validates the shape: a 400 with the reason, nothing stored', () async {
      final ok = {'cat': 'user', 'type': 'pin', 'level': 'info', 'data': <String, dynamic>{}};
      for (final (bad, why) in <(Map<String, dynamic>, String)>[
        ({...ok, 'cat': 'nope'}, 'cat'),
        ({...ok, 'cat': 5}, 'cat'),
        ({...ok, 'type': 'has space'}, 'type'),
        ({...ok, 'type': ''}, 'type'),
        ({...ok, 'type': 'x' * 60}, 'type'),
        ({...ok, 'level': 'debug'}, 'level'),
        ({...ok, 'own': 'yes'}, 'own'),
        ({...ok, 'data': 'text'}, 'object'),
        ({...ok, 'data': [1]}, 'object'),
        ({...ok, 'data': {'blob': 'x' * 5000}}, 'large'),
      ]) {
        final (code, r) = await call('POST', '/api/events', bad);
        expect(code, 400, reason: '$bad');
        expect(r['error'], contains(why));
      }
      expect((await call('GET', '/api/events')).$2['events'], isEmpty);
    });

    test('a rule-set download that failed is an event (tag, url, error) with its raw line; told once per try', () async {
      String url(String path) => 'http://127.0.0.1:${origin.port}$path';
      final s = RuleSetSource('geosite-x', [url('/x.srs')], viaVpn: false, every: Duration.zero);
      hit = 404;
      final r = await d.ruleSets.ensure([s]);
      expect(r.errors, hasLength(1));
      final ev = (await call('GET', '/api/events')).$2;
      final e = types(ev).single;
      expect(['${e['cat']}/${e['type']}', e['level'], e['own']], ['rules/ruleSetFailed', 'warn', false]);
      expect(e['data'], {'tag': 'geosite-x', 'url': url('/x.srs'), 'error': contains('not found'), 'hasCopy': false});
      final raw = (d.log.since(null)['lines'] as List).cast<Map>();
      expect(raw[e['log'] as int]['msg'], contains('geosite-x'), reason: 'the event links to its raw line');

      // back-off: a second ask right away does not try (or report) again
      await d.ruleSets.ensure([s]);
      expect(types((await call('GET', '/api/events')).$2), hasLength(1));
    });

    test('a list that failed and then came, and a stale one that was replaced, are ruleSetUpdated; the first download of a missing one is not', () async {
      final s = RuleSetSource('geosite-y', ['http://127.0.0.1:${origin.port}/y.srs'], viaVpn: false, every: Duration.zero);
      final got = <String>[];
      final ctx = ContextTracker();
      final cache = RuleSetCache(p.join(tmp.path, 'rulesets2'), fetch: ServiceFetch(endpoint: () => null, context: ctx))
        ..onFailed = ((f) => got.add('failed ${f.tag}'))
        ..onUpdated = ((tag) => got.add('updated $tag'));
      hit = 404;
      await cache.ensure([s]);
      hit = 200;
      ctx.interfaceChanged(); // the retry wait of the failed list ends with a change of the network
      await Future<void>.delayed(Duration.zero);
      await cache.ensure([s]);
      await cache.ensure([s], refresh: true);
      expect(got, ['failed geosite-y', 'updated geosite-y', 'updated geosite-y']);

      // the daemon's own cache is wired to the journal
      await d.ruleSets.ensure([s]);
      expect(d.events.length, 0);
      await d.ruleSets.ensure([s], refresh: true);
      final e = types((await call('GET', '/api/events')).$2).single;
      expect(['${e['cat']}/${e['type']}', e['level'], e['data']], ['rules/ruleSetUpdated', 'info', {'tag': 'geosite-y'}]);
    });

    test('the timer\'s updates: the servers that changed are told, a failure too', () async {
      subBody = [vlessWs, trojanGrpc].join('\n');
      Map<String, dynamic> src(String id, String path) => {
            'id': id,
            'kind': 'sub',
            'name': id.toUpperCase(),
            'enabled': true,
            'url': 'http://127.0.0.1:${origin.port}$path',
            'userAgent': 'Auto',
            'updateInterval': 3600,
            'updatedAt': 0,
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': <Object>[],
            'gone': <Object>[],
          };
      await d.store.save({
        'sourcesData': {'s1': src('s1', '/sub'), 's2': src('s2', '/bad')},
        'sourceOrder': ['s1', 's2'],
      });
      await d.updater.runDue();
      final ev = types((await call('GET', '/api/events')).$2);
      expect([for (final e in ev) '${e['cat']}/${e['type']}/${e['level']}'], ['sub/updated/info', 'sub/failed/error']);
      expect(ev[0]['data'], {'source': 's1', 'name': 'S1', 'added': 2, 'removed': 0, 'total': 2});
      expect(ev[1]['data'], {'source': 's2', 'name': 'S2', 'error': isA<String>()});
      expect(ev.every((e) => e['own'] == false && e['log'] != null), isTrue);
    });

    test('the timer tells a change of the servers, not the same list; every failure of a subscription is told, the same error folds into its event (×N), another error is a new one', () async {
      final got = <String>[];
      var runs = 0; // a store of its own each time: a save over a newer timer result keeps the timer's servers
      Map<String, dynamic> src({List<String> keys = const ['a', 'b']}) => {
            'id': 's1',
            'kind': 'sub',
            'name': 'Sub',
            'enabled': true,
            'url': 'u',
            'userAgent': 'Auto',
            'updateInterval': 3600,
            'updatedAt': 0,
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': [for (final k in keys) {'id': k, 'key': k}],
            'gone': <Object>[],
          };
      Future<void> run(Map<String, dynamic> s) async {
        final store = SnapshotStore(File(p.join(tmp.path, 'other-state${runs++}.json')));
        await store.save({'sourcesData': {'s1': s}, 'sourceOrder': ['s1']});
        await SubscriptionUpdater(
          store: store,
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000 * 3600 * 1000),
          update: (s, {hwid, svc, sid, rediscover = false, now, onDiverged}) async {
            return {
              'patch': {
                'nodes': [for (final k in ['b', 'c']) {'id': k, 'key': k}],
                'updatedAt': now!.millisecondsSinceEpoch,
              },
            };
          },
          onEvent: (type, data) => got.add('$type ${data['added']}'),
        ).runDue();
      }

      await run(src(keys: ['b', 'c'])); // the same servers
      expect(got, isEmpty);
      await run(src()); // a, b -> b, c
      expect(got, ['updated 1']);

      // a failing subscription in the daemon (the Sentinel's and the journal's path): the sink folds, see Service._subEvent
      Map<String, dynamic> failing(String path) => {
            'id': 's2',
            'kind': 'sub',
            'name': 'S2',
            'enabled': true,
            'url': 'http://127.0.0.1:${origin.port}$path',
            'userAgent': 'Auto',
            'updateInterval': 3600,
            'updatedAt': 0,
            'hwid': false,
            'filter': '',
            'offNodes': <String>[],
            'nodes': <Object>[],
            'gone': <Object>[],
          };
      await d.store.save({
        'sourcesData': {'s2': failing('/bad')},
        'sourceOrder': ['s2'],
      });
      await d.updater.runDue(); // the timer: the first failure is told
      var ev = types((await call('GET', '/api/events')).$2);
      expect([for (final e in ev) '${e['cat']}/${e['type']}/${e['level']}'], ['sub/failed/error']);

      // the app's own try, the same error: a repeat on that event (×2)
      expect((await call('POST', '/api/sources/fetch', {'sid': 's2', 'source': failing('/bad')})).$1, 500);
      ev = types((await call('GET', '/api/events')).$2);
      expect(ev, hasLength(1), reason: 'the same error folds into one event');
      expect(((ev.single['data'] as Map)['repeat'] as Map)['count'], 2);

      // another error of the same source: a new event, no repeat
      hit = 404;
      expect((await call('POST', '/api/sources/fetch', {'sid': 's2', 'source': failing('/gone')})).$1, 500);
      ev = types((await call('GET', '/api/events')).$2);
      expect([for (final e in ev) '${e['cat']}/${e['type']}'], ['sub/failed', 'sub/failed']);
      expect(ev[1]['data'] as Map, isNot(contains('repeat')));
    });
  });
}
