// checkExitVia / probeGet (exitip.dart, probe.dart) against the real sing-box, on loopback only: a client config with
// the probe inbound, two shadowsocks "servers" (sing-box processes), a local HTTP target that answers plain
// (content-length) and chunked. The check is pinned to a node's outbound: it goes through that node whatever the
// main flow does (the main flow here stands on a dead server). Skipped when the binary is missing. TLS is not
// covered: probeGet verifies certificates against the system roots, a loopback server has none to offer.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

Map<String, dynamic> _ssServer(int port) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      // `target.test` = the loopback, known only to the servers: the request is resolved at the node, as for a real exit
      'dns': {
        'servers': [
          {'type': 'hosts', 'tag': 'hosts', 'predefined': {'target.test': '127.0.0.1'}},
        ],
      },
      'route': {'default_domain_resolver': 'hosts'},
    };

Map<String, dynamic> _node(String key, int port) => {
      'key': key,
      'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
    };

void main() {
  test('pinned to a node: plain and chunked answers come through it; a dead node fails while the main flow\'s choice does not matter', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const json = '{"ip":"203.0.113.77","country":"NL","city":"Amsterdam"}';
    target.listen((r) async {
      final res = r.response;
      if (r.uri.path == '/plain') {
        res
          ..contentLength = json.length
          ..write(json);
      } else if (r.uri.path == '/chunked') {
        res
          ..headers.chunkedTransferEncoding = true
          ..write(json.substring(0, 20));
        await res.flush(); // two chunks on the wire
        res.write(json.substring(20));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    final tmp = await Directory.systemTemp.createTemp('jorm-exitvia');
    final a = SingBoxProcess(_bin, p.join(tmp.path, 'a')), b = SingBoxProcess(_bin, p.join(tmp.path, 'b'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      final pa = await freePort(), pb = await freePort(exclude: {pa});
      await a.start(_ssServer(pa)); // b is never started: its port refuses
      final plan = {
        'routes': [
          {'id': 'A', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::a', 'nodes': [_node('s::a', pa)]}},
          {'id': 'B', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [_node('s::b', pb)]}},
        ],
        'current': 1, // the main flow stands on the dead node
        'mixedPort': await freePort(),
        'global': true,
        'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
      };
      final probe = Probe(await freePort());
      await client.start(buildConfig(plan, probe: probe));

      ExitProbe svc(String name, String path) => (
            name: name,
            url: 'http://target.test:${target.port}$path',
            read: (b) => {for (final m in RegExp(r'"(\w+)":"([^"]*)"').allMatches(b)) m[1]!: m[2]},
          );
      for (final path in ['/plain', '/chunked']) {
        final r = await checkExitVia(probe, 'route0/s::a', probes: [svc(path, path)], timeout: const Duration(seconds: 5));
        expect(r, containsPair('ip', '203.0.113.77'), reason: path);
        expect(r, containsPair('country', 'NL'), reason: path);
        expect(r, containsPair('city', 'Amsterdam'), reason: path);
      }
      expect(await probeGet(probe, 'route0/s::a', 'http://target.test:${target.port}/plain'), json);

      // the dead node: no answer, whatever else works
      await expectLater(
        checkExitVia(probe, 'route1/s::b', probes: [svc('plain', '/plain')], timeout: const Duration(seconds: 3)),
        throwsA(isA<Exception>().having((e) => '$e', 'text', contains('no answer through the tunnel'))),
      );
      // a status that is not 200 is an error too
      await expectLater(probeGet(probe, 'route0/s::a', 'http://target.test:${target.port}/missing'), throwsA(isA<HttpException>()));
      // a tag the config does not have: the inbound refuses the user
      await expectLater(probeGet(probe, 'route9/s::none', 'http://target.test:${target.port}/plain'), throwsA(isA<ProbeRefused>()));
    } finally {
      await client.stop();
      await a.stop();
      await b.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
}
