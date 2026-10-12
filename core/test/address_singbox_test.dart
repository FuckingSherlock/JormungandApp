// Pinned configs against the real sing-box on loopback (docs/rules.md §6 → «Адреса серверов»): the node's
// `server` is an address, the TLS name comes from the pin (the plan's `tls.server_name` is empty) and the
// servers' certificates are made for the NAME only, so a request that passes proves the SNI was filled. QUIC
// (Hysteria2, TUIC) and TCP (Trojan over TLS) nodes. Nothing leaves the machine. Skipped without the binary.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

const _uuid = '11111111-1111-1111-1111-111111111111';

void main() {
  test('pinned QUIC and TCP nodes pass traffic: the pin fills the TLS name, the server is the address', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hi')
      ..close());
    final tmp = await Directory.systemTemp.createTemp('jorm-pinned');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    try {
      // a certificate made for the name only (no IP SAN): what the client verifies against the SNI
      Future<Map<String, dynamic>> cert(String name) async {
        final kp = (await Process.run(_bin, ['generate', 'tls-keypair', name])).stdout as String;
        final k = File(p.join(tmp.path, '$name.key.pem')), c = File(p.join(tmp.path, '$name.pem'));
        k.writeAsStringSync(RegExp(r'-----BEGIN PRIVATE KEY-----[\s\S]*?-----END PRIVATE KEY-----').firstMatch(kp)!.group(0)!);
        c.writeAsStringSync(RegExp(r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----').firstMatch(kp)!.group(0)!);
        return {'key_path': k.path, 'certificate_path': c.path};
      }

      final hy = await cert('hy.test'), tu = await cert('tu.test'), tj = await cert('tj.test');
      final hyP = await freePort(), tuP = await freePort(), tjP = await freePort();
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'hysteria2', 'tag': 'hy', 'listen': '127.0.0.1', 'listen_port': hyP, 'users': [{'password': 'pw'}], 'tls': {'enabled': true, 'server_name': 'hy.test', ...hy}},
          {'type': 'tuic', 'tag': 'tu', 'listen': '127.0.0.1', 'listen_port': tuP, 'users': [{'uuid': _uuid, 'password': 'pw'}], 'tls': {'enabled': true, 'server_name': 'tu.test', 'alpn': ['h3'], ...tu}},
          {'type': 'trojan', 'tag': 'tj', 'listen': '127.0.0.1', 'listen_port': tjP, 'users': [{'password': 'pw'}], 'tls': {'enabled': true, 'server_name': 'tj.test', ...tj}},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      // the client trusts the server's certificate and names nothing: server_name is empty in the plan
      Map<String, dynamic> trust(Map<String, dynamic> c, {List<String>? alpn}) => {'enabled': true, 'certificate_path': c['certificate_path'], 'alpn': ?alpn};
      final nodes = [
        {'key': 'hy', 'outbound': {'type': 'hysteria2', 'server': 'hy.test', 'server_port': hyP, 'password': 'pw', 'tls': trust(hy)}},
        {'key': 'tu', 'outbound': {'type': 'tuic', 'server': 'tu.test', 'server_port': tuP, 'uuid': _uuid, 'password': 'pw', 'tls': trust(tu, alpn: ['h3'])}},
        {'key': 'tj', 'outbound': {'type': 'trojan', 'server': 'tj.test', 'server_port': tjP, 'password': 'pw', 'tls': trust(tj)}},
        // the control: the same server addressed by its IP without a name — the SNI would be the IP, the certificate does not match
        {'key': 'hy-ip', 'outbound': {'type': 'hysteria2', 'server': '127.0.0.1', 'server_port': hyP, 'password': 'pw', 'tls': trust(hy)}},
      ];
      final pins = {'hy.test': '127.0.0.1', 'tu.test': '127.0.0.1', 'tj.test': '127.0.0.1'};
      final r = await measureLatency(
        binary: _bin,
        workDir: p.join(tmp.path, 'ping'),
        nodes: nodes,
        url: 'http://127.0.0.1:${target.port}/',
        timeoutMs: 4000,
        pins: pins,
      );
      expect(r.nodes['hy'], greaterThanOrEqualTo(0), reason: 'Hysteria2 pinned to 127.0.0.1');
      expect(r.nodes['tu'], greaterThanOrEqualTo(0), reason: 'TUIC pinned to 127.0.0.1');
      expect(r.nodes['tj'], greaterThanOrEqualTo(0), reason: 'Trojan over TLS pinned to 127.0.0.1');
      expect(r.nodes['hy-ip'], -1, reason: 'without the name the certificate does not match');
    } finally {
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
}
