// SingBoxApi (sbapi.dart) against the real sing-box, on loopback only: a second sing-box
// as a VLESS server that rejects one domain, our client config with a selector, a request
// through the mixed inbound. Nothing leaves the machine. Skipped when the binary is missing.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

const _uuid = 'd290f1ee-6c54-4b01-90e6-d701748f0851'; // made up, loopback only

Map<String, dynamic> _server(int listenPort) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {
          'type': 'vless',
          'tag': 'vless-in',
          'listen': '127.0.0.1',
          'listen_port': listenPort,
          'users': [
            {'uuid': _uuid},
          ],
        },
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      // no DNS needed: a VLESS client sends the domain itself, so the domain rule below
      // matches (and rejects) before any resolution would happen.
      'route': {
        'rules': [
          {
            'domain': ['blocked.example'],
            'action': 'reject',
          },
        ],
        'final': 'direct',
      },
    };

Map<String, dynamic> _client(int mixedPort, int serverPort) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': mixedPort},
      ],
      'outbounds': [
        {'type': 'vless', 'tag': 'route0/nodeA', 'server': '127.0.0.1', 'server_port': serverPort, 'uuid': _uuid, 'packet_encoding': 'xudp'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['route0/nodeA'], 'default': 'route0/nodeA'},
      ],
      'route': {'final': 'proxy'},
    };

// A request through the mixed inbound as a plain HTTP proxy: the whole request (method,
// absolute-form URI, headers) reaches sing-box's inbound in one read, before it dials the
// outbound at all — so it counts as `up` even when the outbound then rejects at once and
// nothing at all comes back (`down` stays 0). A SOCKS5 CONNECT would not: the destination
// is negotiated separately from the payload, and a `reject` closes the tunnel before the
// payload the client queues right after ever reaches sing-box's copy loop.
Future<void> _get(int mixedPort, String url) async {
  final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
  try {
    final req = await http.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 3));
    await req.close().timeout(const Duration(seconds: 3));
  } catch (_) {
    // rejected / refused: the point of the test is the ClosedConnection sing-box's API
    // reports, not this request's own outcome
  } finally {
    http.close(force: true);
  }
}

void main() {
  test('closedConnections: up>0/down==0 when the server rejects the domain; up==0/down==0 when it is stopped', () async {
    final tmp = await Directory.systemTemp.createTemp('jorm-sbapi');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      final serverPort = await freePort();
      final mixed = await freePort();

      await server.start(_server(serverPort));
      await client.start(_client(mixed, serverPort));
      expect(client.api, isNotNull);

      final closed = <ClosedConnection>[];
      // an error surfaces on this stream once the gRPC channel is torn down at teardown
      // (client.stop() closing it out from under the subscription) — expected, not a test
      // failure; daemon.dart's own consumer handles it the same way (an onError callback).
      final sub = client.api!.closedConnections().listen(closed.add, onError: (Object _) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300)); // let the subscription settle

      await _get(mixed, 'http://blocked.example/');
      final c = await _waitFor(closed, (c) => c.destination.startsWith('blocked.example'));
      expect(c.outbound, 'route0/nodeA');
      expect(c.chain, contains('proxy'));
      expect(c.up, greaterThan(0));
      expect(c.down, 0);

      closed.clear();
      await server.stop();
      await _get(mixed, 'http://blocked.example/');
      final c2 = await _waitFor(closed, (c) => c.destination.startsWith('blocked.example'));
      expect(c2.up, 0);
      expect(c2.down, 0);
    } finally {
      await client.stop();
      await server.stop();
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 30)));

  test('trafficOf: an open connection shows its outbound; status totals move after it closes', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => Future<void>.delayed(const Duration(milliseconds: 400), () => r.response
      ..write('ok')
      ..close()));
    final tmp = await Directory.systemTemp.createTemp('jorm-sbapi-traffic');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      final serverPort = await freePort(), mixed = await freePort();
      await server.start(_server(serverPort));
      await client.start(_client(mixed, serverPort));

      final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
      final pending = http.getUrl(Uri.parse('http://127.0.0.1:${target.port}/')).then((q) => q.close());
      pending.ignore();
      await Future<void>.delayed(const Duration(milliseconds: 150)); // still open: the target holds the response

      var t = trafficOf(client.api!);
      final mine = (t['conns'] as List).cast<Map>().where((c) => c['port'] == '${target.port}').firstOrNull;
      expect(mine, isNotNull, reason: 'the open connection is listed');
      expect(mine!['out'], contains('route0/nodeA'));
      expect(mine['net'], 'tcp');

      final res = await pending;
      await res.transform(utf8.decoder).join();
      http.close(force: true);
      await Future<void>.delayed(const Duration(seconds: 2)); // the status stream pushes every second

      t = trafficOf(client.api!);
      expect((t['conns'] as List).cast<Map>().where((c) => c['port'] == '${target.port}'), isEmpty, reason: 'closed now');
      expect(t['downTotal'], greaterThan(0));
      expect(t['upTotal'], greaterThan(0));
    } finally {
      await client.stop();
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 30)));

  test('logLines: sing-box\'s log comes through the API (the way libbox, with no process output, gets it)', () async {
    final tmp = await Directory.systemTemp.createTemp('jorm-sbapi-log');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      final serverPort = await freePort(), mixed = await freePort();
      await server.start(_server(serverPort));
      await client.start({..._client(mixed, serverPort), 'log': {'level': 'debug'}});

      final lines = <String>[];
      final sub = client.api!.logLines().listen(lines.add, onError: (Object _) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _get(mixed, 'http://blocked.example/');
      final hit = await _waitFor(lines, (l) => l.contains('blocked.example'));
      expect(hit, isNotEmpty);
    } finally {
      await client.stop();
      await server.stop();
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 30)));

  test('withApiService keeps the config\'s own services and adds the API one', () {
    final c = withApiService({
      'services': [
        {'type': 'x', 'tag': 'x'},
      ],
      'log': {'level': 'warn'},
    }, 's3cret', 4242);
    final s = (c['services'] as List).cast<Map>();
    expect(s.map((e) => e['tag']), ['x', 'api']);
    expect(s.last, containsPair('listen_port', 4242));
    expect(s.last, containsPair('secret', 's3cret'));
    expect(c['log'], {'level': 'warn'});
    expect(newApiSecret(), isNot(newApiSecret()));
    expect(newApiSecret(), hasLength(32));
  });

  test('withCacheFile gives the instance its own cache file and keeps the rest of experimental', () {
    final tester = withCacheFile({'log': {'level': 'warn'}}, '/cache/box1.db');
    expect((tester['experimental'] as Map)['cache_file'], {'enabled': true, 'path': '/cache/box1.db'});
    expect(tester['log'], {'level': 'warn'});
    final tunnel = withCacheFile({
      'experimental': {
        'clash_api': {'x': 1},
        'cache_file': {'enabled': true, 'cache_id': 'abc'},
      },
    }, '/run/main/cache.db');
    final e = tunnel['experimental'] as Map;
    expect(e['clash_api'], {'x': 1});
    expect(e['cache_file'], {'enabled': true, 'cache_id': 'abc', 'path': '/run/main/cache.db'});
    // two instances, two paths: never the shared default
    expect(((withCacheFile({}, 'a.db')['experimental'] as Map)['cache_file'] as Map)['path'],
        isNot(((withCacheFile({}, 'b.db')['experimental'] as Map)['cache_file'] as Map)['path']));
  });
}

Future<T> _waitFor<T>(List<T> list, bool Function(T) test, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final hit = list.where(test);
    if (hit.isNotEmpty) return hit.first;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('no matching ClosedConnection within $timeout');
}
