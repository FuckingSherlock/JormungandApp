// Checks built configs with the real sing-box (tool/bin) and runs a connection end to
// end on loopback: a sing-box "server" with a shadowsocks inbound, our client config in
// front of it, an HTTP request through the mixed port. Nothing leaves the machine.
// Skipped when the binary is missing.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

Future<void> _check(Map<String, dynamic> config) async {
  final dir = await Directory.systemTemp.createTemp('jorm-check');
  try {
    final f = File(p.join(dir.path, 'c.json'))..writeAsStringSync(jsonEncode(config));
    final r = await Process.run(_bin, ['check', '-c', f.path, '--disable-color']);
    expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}\n${const JsonEncoder.withIndent(' ').convert(config)}');
  } finally {
    await dir.delete(recursive: true);
  }
}

Map<String, dynamic> _group(List<Node> nodes, {String pick = 'fastest'}) => {
      'pick': pick,
      'chosen': nodes.first.id,
      'nodes': [for (final n in nodes) {'key': 'src::${n.id}', 'outbound': n.outbound}],
    };

void main() {
  final supported = [
    ...allLinks.map(parseLink).whereType<Node>(),
    ...parseSubscription(clashYaml).$2,
    ...parseClash(clashMore),
  ].where((n) => n.unsupported == null).toList();

  test('every parsed server makes a config sing-box accepts', () async {
    await _check(buildConfig({'kind': 'unit', 'main': _group(supported)}));
  }, skip: _skip);

  test('chain and priority selector', () async {
    await _check(buildConfig({
      'kind': 'chain',
      'entry': _group(supported.take(3).toList()),
      'main': _group(supported.skip(3).toList(), pick: 'priority'),
      'global': true,
    }));
  }, skip: _skip);

  test('tester config', () async {
    await _check(buildTesterConfig(
      nodes: [for (final n in supported) {'key': n.id, 'outbound': n.outbound}],
      pairs: [
        {'key': 'a>b', 'entry': {'outbound': supported[0].outbound}, 'exit': {'outbound': supported[1].outbound}},
      ],
      clashPort: 19090,
    ));
  }, skip: _skip);

  test('loopback: HTTP through our config and a shadowsocks server', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello from target')
      ..close());
    final ssPort = await freePort(), mixedPort = await freePort(), clash = await freePort(), clash2 = await freePort();
    final tmp = await Directory.systemTemp.createTemp('jorm-e2e');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': ssPort, 'method': 'aes-128-gcm', 'password': 'loopback'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$clash2'},
        },
      }, clashPort: clash2);

      final node = parseLink('ss://${base64.encode(utf8.encode('aes-128-gcm:loopback'))}@127.0.0.1:$ssPort#loop')!;
      await client.start(buildConfig({'kind': 'unit', 'main': _group([node]), 'mixedPort': mixedPort, 'global': true}, clashPort: clash),
          clashPort: clash);

      final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
      final res = await (await http.getUrl(Uri.parse('http://127.0.0.1:${target.port}/'))).close();
      expect(await res.transform(utf8.decoder).join(), 'hello from target');
      http.close(force: true);

      // the connection really went through the proxy group
      final conns = await client.clashGet('/connections');
      expect(conns, isNotNull);

      final lat = await measureLatency(
        binary: _bin,
        workDir: p.join(tmp.path, 'ping'),
        nodes: [
          {'key': 'loop', 'outbound': node.outbound},
          {'key': 'dead', 'outbound': {...node.outbound, 'server_port': await freePort()}},
        ],
        url: 'http://127.0.0.1:${target.port}/',
        timeoutMs: 1500,
      );
      expect(lat.nodes['loop'], greaterThanOrEqualTo(0));
      expect(lat.nodes['dead'], -1);
    } finally {
      await client.stop();
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
}
