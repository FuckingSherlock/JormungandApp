// ServiceFetch (svc_fetch.dart) on loopback: a fake "svc-in" (one HTTP proxy server; the user name of
// Proxy-Authorization picks the path's behaviour, as sing-box's auth_user does) and local servers. One test
// with the real sing-box for the svc-in inbound itself. Nothing leaves the machine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _data = Uint8List.fromList([for (var i = 0; i < 100 * 1024; i++) (i * 7 + 3) % 251]);

class _Hit {
  _Hit(this.login, this.range, this.uri);
  final String login;
  final String? range;
  final Uri uri;
}

typedef _Behave = Future<void> Function(HttpRequest r);

/// One HTTP proxy that answers by the login of the request.
class _Fake {
  late HttpServer server;
  final behave = <String, _Behave>{};
  final hits = <_Hit>[];
  static const secret = 'sec';

  static Future<_Fake> start() async {
    final f = _Fake();
    f.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    f.server.listen((r) {
      final auth = r.headers.value('proxy-authorization') ?? '';
      final cred = auth.startsWith('Basic ') ? utf8.decode(base64.decode(auth.substring(6))).split(':') : <String>[];
      if (cred.length != 2 || cred[1] != secret) {
        r.response
          ..statusCode = 407
          ..headers.set('proxy-authenticate', 'Basic realm="x"')
          ..close();
        return;
      }
      f.hits.add(_Hit(cred[0], r.headers.value('range'), r.uri));
      final b = f.behave[cred[0]];
      if (b == null) {
        r.response.detachSocket().then((s) => s.destroy());
      } else {
        b(r);
      }
    });
    return f;
  }

  SvcIn svc(List<String> ids) => SvcIn(server.port, secret, [
        for (final id in ids) SvcPath(id, id == 'direct' ? SvcKind.direct : (id == 'main' ? SvcKind.main : SvcKind.route), 'tag-$id', id),
      ]);

  List<String> get logins => [for (final h in hits) h.login];

  Future<void> close() => server.close(force: true);
}

/// A body of [_data] (or [status]); [delay] before it starts, [stallAfter] bytes and then silence,
/// [ranges]: honours `Range: bytes=N-`.
_Behave _serve({Duration delay = Duration.zero, int? stallAfter, bool ranges = true, int status = 200, Uint8List? body, String? etag}) => (r) async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final data = body ?? _data;
      final res = r.response;
      var start = 0;
      var code = status;
      final range = r.headers.value('range');
      if (ranges && range != null && status == 200) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        start = int.parse(m[1]!);
        final end = m[2]!.isEmpty ? data.length - 1 : int.parse(m[2]!);
        code = 206;
        res.headers.set('content-range', 'bytes $start-$end/${data.length}');
        res.statusCode = code;
        res.contentLength = end + 1 - start;
        if (etag != null) res.headers.set('etag', etag);
        final part = Uint8List.sublistView(data, start, end + 1);
        await _send(res, part, stallAfter);
        return;
      }
      res.statusCode = code;
      res.contentLength = data.length;
      if (etag != null) res.headers.set('etag', etag);
      await _send(res, data, stallAfter);
    };

Future<void> _send(HttpResponse res, Uint8List part, int? stallAfter) async {
  if (stallAfter == null) {
    res.add(part);
    await res.close();
    return;
  }
  res.add(Uint8List.sublistView(part, 0, stallAfter));
  await res.flush();
  await Completer<void>().future; // silence, until the server is closed
}

final Uri _url = Uri.parse('http://origin.test/file.bin');

ServiceFetch _fetch(_Fake f, List<String> ids, {ContextTracker? ctx, Duration? tie, Duration? prefer, Duration? stall}) => ServiceFetch(
      endpoint: () => f.svc(ids),
      context: ctx,
      sample: 16 * 1024,
      tieGrace: tie ?? const Duration(milliseconds: 400),
      preferGrace: prefer ?? const Duration(milliseconds: 1500),
      stall: stall ?? const Duration(milliseconds: 600),
      timeout: const Duration(seconds: 8),
    );

void main() {
  group('the race', () {
    late _Fake f;
    setUp(() async => f = await _Fake.start());
    tearDown(() => f.close());

    test('the first path that answers carries the body; the others are cut', () async {
      f.behave['direct'] = _serve(delay: const Duration(milliseconds: 1200));
      f.behave['main'] = _serve();
      final r = await _fetch(f, ['direct', 'main']).get(_url);
      expect(r.ok, isTrue);
      expect(r.response!.via, 'main');
      expect(r.response!.kind, SvcKind.main);
      expect(r.response!.body, _data);
      expect(r.response!.bytes, _data.length);
      expect(r.response!.resumes, 0);
    });

    test('a tie goes to the tunnel; a direct answer far ahead of it is taken', () async {
      f.behave['direct'] = _serve();
      f.behave['main'] = _serve(delay: const Duration(milliseconds: 120));
      var r = await _fetch(f, ['direct', 'main']).get(_url);
      expect(r.response!.via, 'main', reason: 'within the grace');

      f.behave['main'] = _serve(delay: const Duration(milliseconds: 1500));
      r = await _fetch(f, ['direct', 'main']).get(_url);
      expect(r.response!.via, 'direct', reason: 'the tunnel missed the grace');
      expect(r.response!.body, _data);
    });

    test('prefer direct: the direct path is taken even when the tunnel was faster', () async {
      f.behave['direct'] = _serve(delay: const Duration(milliseconds: 500));
      f.behave['main'] = _serve();
      final r = await _fetch(f, ['direct', 'main']).get(_url, prefer: SvcPrefer.direct);
      expect(r.response!.via, 'direct');
      expect(r.response!.body, _data);
    });

    test('prefer direct: a direct path that fails does not hold the tunnel back', () async {
      f.behave['main'] = _serve();
      final sw = Stopwatch()..start();
      final r = await _fetch(f, ['direct', 'main']).get(_url, prefer: SvcPrefer.direct); // no behaviour for direct: connection destroyed
      expect(r.response!.via, 'main');
      expect(sw.elapsedMilliseconds, lessThan(1400));
    });

    test('strict: only that path is asked', () async {
      f.behave['direct'] = _serve();
      f.behave['main'] = _serve();
      f.behave['route0'] = _serve();
      final r = await _fetch(f, ['direct', 'main', 'route0']).get(_url, policy: const SvcPolicy.strict('route0'));
      expect(r.response!.via, 'route0');
      expect(f.logins, ['route0']);
      final none = await _fetch(f, ['direct', 'main']).get(_url, policy: const SvcPolicy.strict('route9'));
      expect(none.failure!.code, 'noPath');
    });

    test('the login and the secret are what the proxy is given; a wrong secret is `auth`', () async {
      f.behave['main'] = _serve();
      final bad = ServiceFetch(endpoint: () => SvcIn(f.server.port, 'other', [const SvcPath('main', SvcKind.main, 'proxy', 'main')]));
      final r = await bad.get(_url);
      expect(r.failure!.paths.single.code, 'auth');
    });

    test('a non-ok answer of the server is an answer, not a failure', () async {
      f.behave['direct'] = _serve(status: 404, body: Uint8List.fromList(utf8.encode('nope')));
      f.behave['main'] = _serve(status: 404, body: Uint8List.fromList(utf8.encode('nope')));
      final r = await _fetch(f, ['direct', 'main']).get(_url);
      expect(r.ok, isFalse);
      expect(r.failure, isNull);
      expect(r.response!.status, 404);
      expect(utf8.decode(r.response!.body), 'nope');
    });

    test('a good answer wins over a quicker 403 of another path', () async {
      f.behave['direct'] = _serve(status: 403, body: Uint8List.fromList(utf8.encode('blocked')));
      f.behave['main'] = _serve(delay: const Duration(milliseconds: 300));
      final r = await _fetch(f, ['direct', 'main']).get(_url);
      expect(r.ok, isTrue);
      expect(r.response!.via, 'main');
    });
  });

  group('range, size, streaming', () {
    late _Fake f;
    setUp(() async => f = await _Fake.start());
    tearDown(() => f.close());

    test('a range asked for comes back as that part', () async {
      f.behave['main'] = _serve();
      final r = await _fetch(f, ['main']).get(_url, range: const SvcRange(10, 29));
      expect(r.response!.status, 206);
      expect(r.response!.body, _data.sublist(10, 30));
      expect(f.hits.single.range, 'bytes=10-29');
    });

    test('a server that ignores Range: the part is cut out of the whole', () async {
      f.behave['main'] = _serve(ranges: false);
      final r = await _fetch(f, ['main']).get(_url, range: const SvcRange(100, 199));
      expect(r.response!.body, _data.sublist(100, 200));
    });

    test('more than maxBytes is `tooBig`, not a failure of the paths', () async {
      f.behave['main'] = _serve();
      final r = await _fetch(f, ['main']).get(_url, maxBytes: 1000);
      expect(r.failure!.code, 'tooBig');
      expect(r.failure!.suspicion(), isNull);
    });

    test('onData: the body goes in pieces, none is kept', () async {
      f.behave['main'] = _serve();
      final got = BytesBuilder();
      final r = await _fetch(f, ['main']).get(_url, onData: got.add);
      expect(got.takeBytes(), _data);
      expect(r.response!.body, isEmpty);
      expect(r.response!.bytes, _data.length);
    });

    test('cancel ends the call', () async {
      f.behave['main'] = _serve(delay: const Duration(seconds: 5));
      final c = Completer<void>();
      Timer(const Duration(milliseconds: 200), c.complete);
      final r = await _fetch(f, ['main']).get(_url, cancel: c.future);
      expect(r.failure!.code, 'cancelled');
    });
  });

  group('a transfer that stalls', () {
    late _Fake f;
    setUp(() async => f = await _Fake.start());
    tearDown(() => f.close());

    test('goes on from where it stopped on another path, with Range', () async {
      f.behave['main'] = _serve(stallAfter: 30 * 1024, etag: '"v1"');
      f.behave['route0'] = _serve(delay: const Duration(milliseconds: 1500), etag: '"v1"');
      final r = await _fetch(f, ['main', 'route0']).get(_url);
      expect(r.ok, isTrue);
      expect(r.response!.body, _data, reason: 'the two parts make the whole');
      expect(r.response!.via, 'route0');
      expect(r.response!.resumes, 1);
      expect(r.response!.status, 200, reason: 'the first answer is the answer');
      final resume = f.hits.lastWhere((h) => h.login == 'route0');
      expect(resume.range, startsWith('bytes='));
      final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(resume.range!)!.group(1)!);
      expect(from, inInclusiveRange(16 * 1024, 30 * 1024));
    });

    test('with no other path it is a failure that says how far it got', () async {
      f.behave['main'] = _serve(stallAfter: 30 * 1024);
      final r = await _fetch(f, ['main']).get(_url);
      expect(r.failure!.code, 'allFailed');
      expect(r.failure!.paths.single.code, 'stall');
      expect(r.failure!.received, greaterThan(16 * 1024));
    });

    test('a resume needs the same file: a changed one (200 to If-Range) is `changed`', () async {
      f.behave['main'] = _serve(stallAfter: 30 * 1024, etag: '"v1"');
      f.behave['route0'] = (r) async {
        // an origin that says the file changed: the full body, 200, whatever the range
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        r.response
          ..statusCode = 200
          ..contentLength = _data.length
          ..add(_data);
        await r.response.close();
      };
      final r = await _fetch(f, ['main', 'route0']).get(_url);
      expect(r.failure!.code, 'allFailed');
      expect(r.failure!.paths.map((x) => x.code), containsAll(['stall', 'changed']));
    });
  });

  group('everything fails', () {
    late _Fake f;
    setUp(() async => f = await _Fake.start());
    tearDown(() => f.close());

    test('a structured failure with a reason per path, a suspicion and a retry advice', () async {
      final ctx = ContextTracker();
      final fetch = _fetch(f, ['direct', 'main', 'route0'], ctx: ctx); // no behaviours: every connection is destroyed
      final r = await fetch.get(_url, purpose: 'ruleset');
      final fail = r.failure!;
      expect(r.ok, isFalse);
      expect(fail.code, 'allFailed');
      expect(fail.host, 'origin.test');
      expect(fail.paths.map((x) => x.id), unorderedEquals(['direct', 'main', 'route0']));
      expect(fail.paths.every((x) => x.code.isNotEmpty), isTrue);
      expect(fail.advice!.waitFor, RetryWait.time);
      expect(fail.advice!.after, const Duration(minutes: 1));
      final s = fail.suspicion()!;
      expect(s.kind, 'svc.fetch');
      expect(s.subject, {'host': 'origin.test', 'purpose': 'ruleset'});
      expect((s.evidence['paths'] as List).length, 3);
      expect(s.viaCore, isTrue);
      // the second failure of the same purpose steps the wait up
      final again = await fetch.get(_url, purpose: 'ruleset');
      expect(again.failure!.advice!.after, const Duration(minutes: 2));
      // another purpose has its own count
      final other = await fetch.get(_url, purpose: 'update');
      expect(other.failure!.advice!.after, const Duration(minutes: 1));
      ctx.dispose();
    });

    test('a failure while our own restart is under way is retried after the settle', () async {
      final ctx = ContextTracker();
      ctx.starting('refreshLists');
      final r = await _fetch(f, ['main'], ctx: ctx).get(_url);
      expect(r.failure!.advice!.waitFor, RetryWait.settled);
      ctx.dispose();
    });

    test('no network is waited out', () async {
      final ctx = ContextTracker();
      ctx.platform(connected: false);
      final r = await _fetch(f, ['main'], ctx: ctx).get(_url);
      expect(r.failure!.advice!.waitFor, RetryWait.networkUp);
      ctx.dispose();
    });
  });

  group('the winner is remembered', () {
    late _Fake f;
    setUp(() async => f = await _Fake.start());
    tearDown(() => f.close());

    test('per host: the next request goes to it alone, until the network changes', () async {
      final ctx = ContextTracker();
      f.behave['direct'] = _serve(delay: const Duration(milliseconds: 1500));
      f.behave['main'] = _serve();
      f.behave['route0'] = _serve(delay: const Duration(milliseconds: 1500));
      final fetch = _fetch(f, ['direct', 'main', 'route0'], ctx: ctx);
      expect((await fetch.get(_url)).response!.via, 'main');
      expect(fetch.remembered(_url), 'main');
      expect(f.logins.toSet(), {'direct', 'main', 'route0'});

      f.hits.clear();
      expect((await fetch.get(_url)).response!.via, 'main');
      expect(f.logins, ['main'], reason: 'the remembered path alone');
      // another host has no memory
      f.hits.clear();
      await fetch.get(Uri.parse('http://other.test/x'));
      expect(f.logins.toSet(), {'direct', 'main', 'route0'});

      // the network moved: the memory is gone, the race is whole again
      ctx.interfaceChanged();
      expect(fetch.remembered(_url), isNull);
      f.hits.clear();
      await fetch.get(_url);
      expect(f.logins.toSet(), {'direct', 'main', 'route0'});
      expect(fetch.remembered(_url), 'main');

      // a reconnect (the core's epoch) too
      ctx.starting('userConnect');
      expect(fetch.remembered(_url), isNull);
      ctx.dispose();
    });

    test('a failure of the remembered path forgets it, the whole race follows', () async {
      f.behave['main'] = _serve();
      f.behave['route0'] = _serve(delay: const Duration(milliseconds: 1500));
      final fetch = _fetch(f, ['main', 'route0']);
      await fetch.get(_url);
      expect(fetch.remembered(_url), 'main');
      f.behave.remove('main'); // dead now
      f.behave['route0'] = _serve();
      f.hits.clear();
      final r = await fetch.get(_url);
      expect(r.response!.via, 'route0');
      expect(f.logins, ['main', 'route0']);
      expect(fetch.remembered(_url), 'route0');
    });

    test('the preference is part of the key', () async {
      f.behave['direct'] = _serve(delay: const Duration(milliseconds: 300));
      f.behave['main'] = _serve();
      final fetch = _fetch(f, ['direct', 'main']);
      await fetch.get(_url);
      expect(fetch.remembered(_url), 'main');
      expect(fetch.remembered(_url, prefer: SvcPrefer.direct), isNull);
      await fetch.get(_url, prefer: SvcPrefer.direct);
      expect(fetch.remembered(_url, prefer: SvcPrefer.direct), 'direct');
    });
  });

  group('sing-box not running', () {
    test('one plain direct socket; the other paths do not exist', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) {
        r.response
          ..write('plain')
          ..close();
      });
      try {
        final fetch = ServiceFetch(endpoint: () => null);
        final u = Uri.parse('http://127.0.0.1:${origin.port}/');
        final r = await fetch.get(u);
        expect(utf8.decode(r.response!.body), 'plain');
        expect(r.response!.via, svcPlainId);
        expect((await fetch.get(u, policy: const SvcPolicy.strict('main'))).failure!.code, 'noPath');
        expect((await fetch.get(u, policy: const SvcPolicy.race(kinds: {SvcKind.main}))).failure!.code, 'noPath');
      } finally {
        await origin.close(force: true);
      }
    });
  });

  group('SvcIn', () {
    test('users, rules and the table of the paths; a record that brings them back', () {
      final s = SvcIn(4000, 'pw');
      final b = s.inbound(direct: 'direct', main: 'proxy', routes: ['route0', 'route1']);
      expect(b.inbound['tag'], 'svc-in');
      expect(b.inbound['type'], 'mixed');
      expect(b.inbound['listen'], '127.0.0.1');
      expect((b.inbound['users'] as List).map((u) => (u as Map)['username']), ['u0', 'u1', 'u2', 'u3']);
      expect(b.rules.first, {'inbound': ['svc-in'], 'auth_user': ['u0'], 'action': 'route', 'outbound': 'direct'});
      expect(s.paths.map((x) => '${x.id}:${x.kind.name}:${x.tag}'), ['direct:direct:direct', 'main:main:proxy', 'route0:route:route0', 'route1:route:route1']);
      final back = SvcIn.fromJson(s.toJson())!;
      expect((back.port, back.secret), (4000, 'pw'));
      expect(back.paths.map((x) => x.login), ['u0', 'u1', 'u2', 'u3']);
      expect(back.proxyFor(back.path('route1')!), 'PROXY u3:pw@127.0.0.1:4000');
      expect(SvcIn.fromJson(null), isNull);
      expect(SvcIn.fromJson({'port': 1}), isNull);
    });

    test('buildConfig puts the inbound and its rules first', () {
      final svc = SvcIn(4001, 'pw');
      final cfg = buildConfig({
        'routes': [
          {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [{'key': 's::a', 'outbound': {'type': 'direct'}}]}},
        ],
        'current': 0,
        'mixedPort': 2080,
        'global': true,
      }, svc: svc);
      expect((cfg['inbounds'] as List).any((i) => (i as Map)['tag'] == 'svc-in'), isTrue);
      final rules = (cfg['route'] as Map)['rules'] as List;
      expect((rules.first as Map)['auth_user'], ['u0']);
      expect(svc.paths.map((x) => x.id), ['direct', 'main', 'route0']);
    });
  });

  group('with the real sing-box', () {
    final bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
    final skip = File(bin).existsSync() ? false : 'no sing-box in tool/bin';

    test('each user of svc-in leaves by its own outbound (auth_user over HTTP proxy)', () async {
      final tmp = await Directory.systemTemp.createTemp('jorm-svc');
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((r) => r.response
        ..write('hello from target')
        ..close());
      final serverPorts = [await freePort(), await freePort()];
      final servers = <SingBoxProcess>[];
      final client = SingBoxProcess(bin, p.join(tmp.path, 'client'));
      try {
        for (var i = 0; i < 2; i++) {
          final sb = SingBoxProcess(bin, p.join(tmp.path, 's$i'));
          servers.add(sb);
          await sb.start({
            'log': {'level': 'warn'},
            'inbounds': [
              {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': serverPorts[i], 'method': 'aes-128-gcm', 'password': 'loopback'},
            ],
            'outbounds': [
              {'type': 'direct', 'tag': 'direct'},
            ],
            // `target.test` is the loopback for the servers only: a client that resolves it on its own finds nothing
            'dns': {
              'servers': [
                {'type': 'hosts', 'tag': 'hosts', 'predefined': {'target.test': '127.0.0.1'}},
              ],
            },
            'route': {'default_domain_resolver': 'hosts'},
          });
        }
        Map<String, dynamic> node(String key, int port) => {
              'key': key,
              'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
            };
        final plan = {
          'routes': [
            {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [node('s::a', serverPorts[0])]}},
            {'id': 'B', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [node('s::b', serverPorts[1])]}},
          ],
          'current': 0,
          'mixedPort': await freePort(),
          'global': true,
          'urlTest': {'url': 'http://127.0.0.1:${target.port}/', 'interval': 60},
        };
        final svc = SvcIn(await freePort());
        await client.start(buildConfig(plan, svc: svc));
        expect(svc.paths.map((x) => x.id), ['direct', 'main', 'route0', 'route1']);

        final fetch = ServiceFetch(endpoint: () => svc, headerTimeout: const Duration(seconds: 6), timeout: const Duration(seconds: 10));
        final hostUrl = Uri.parse('http://target.test:${target.port}/');
        final direct = Uri.parse('http://127.0.0.1:${target.port}/');

        Future<SvcResult> via(String id, Uri u) => fetch.get(u, policy: SvcPolicy.strict(id));
        // direct leaves from sing-box without a server: the loopback is reachable, `target.test` is not
        expect((await via('direct', direct)).response!.body, utf8.encode('hello from target'));
        final noName = await via('direct', hostUrl);
        expect(noName.failure ?? noName.response, isNotNull);
        expect(noName.ok, isFalse, reason: 'direct cannot resolve target.test');
        // the main flow and each route leave through a server, which knows the name
        for (final id in ['main', 'route0', 'route1']) {
          final r = await via(id, hostUrl);
          expect(r.ok, isTrue, reason: id);
          expect(utf8.decode(r.response!.body), 'hello from target', reason: id);
        }
        // HTTP CONNECT (what an https request does) picks the outbound by the user as well
        Future<String> connect(SvcPath path) async {
          final s = await Socket.connect('127.0.0.1', svc.port);
          try {
            final auth = base64.encode(utf8.encode('${path.login}:${svc.secret}'));
            s.write('CONNECT target.test:${target.port} HTTP/1.1\r\nHost: target.test:${target.port}\r\nProxy-Authorization: Basic $auth\r\n\r\n');
            final buf = StringBuffer();
            final done = Completer<void>();
            var sent = false;
            s.listen((d) {
              buf.write(latin1.decode(d));
              final text = buf.toString();
              if (!sent && text.startsWith('HTTP/1.1 200') && text.contains('\r\n\r\n')) {
                sent = true; // the tunnel is open: the request itself
                s.write('GET / HTTP/1.1\r\nHost: target.test\r\nConnection: close\r\n\r\n');
              }
              if (text.contains('hello from target') && !done.isCompleted) done.complete();
            }, onDone: () {
              if (!done.isCompleted) done.complete();
            }, onError: (_) {
              if (!done.isCompleted) done.complete();
            });
            await done.future.timeout(const Duration(seconds: 6), onTimeout: () {});
            return buf.toString();
          } finally {
            s.destroy();
          }
        }

        expect(await connect(svc.path('route0')!), contains('hello from target'));
        expect(await connect(svc.path('direct')!), isNot(contains('hello from target')), reason: 'direct cannot resolve target.test');
        // a server down: its route fails, the others do not
        await servers[1].stop();
        expect((await via('route1', hostUrl)).ok, isFalse);
        expect((await via('route0', hostUrl)).ok, isTrue);
        // and the race finds the way that works
        final raced = await fetch.get(hostUrl);
        expect(raced.ok, isTrue);
        expect(raced.response!.kind, isNot(SvcKind.direct));
        expect(raced.response!.via, anyOf('main', 'route0'));
        // a wrong secret does not get in
        final bad = await ServiceFetch(endpoint: () => SvcIn(svc.port, 'wrong', svc.paths)).get(hostUrl, policy: const SvcPolicy.strict('main'));
        expect(bad.ok, isFalse);
      } finally {
        await client.stop();
        for (final s in servers) {
          await s.stop();
        }
        await target.close(force: true);
        await tmp.delete(recursive: true);
      }
    }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
  });
}
