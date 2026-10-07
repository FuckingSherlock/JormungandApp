// A chain's UDP-based exit (HY2, TUIC) measured through its entry, with the real sing-box on
// loopback: the exit dials through the entry's UDP (VLESS xudp, plain and with the vision flow);
// an entry that cannot carry UDP (http) gives a miss for that pair only. Nothing leaves the
// machine. Skipped when the binary is missing.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

const _uuid = '11111111-1111-1111-1111-111111111111';

void main() {
  test('exit over UDP through an entry: xudp carries it, http cannot', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hi')
      ..close());
    final tmp = await Directory.systemTemp.createTemp('jorm-pair-udp');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    try {
      final kp = (await Process.run(_bin, ['generate', 'tls-keypair', 'localhost'])).stdout as String;
      File(p.join(tmp.path, 'k.pem')).writeAsStringSync(RegExp(r'-----BEGIN PRIVATE KEY-----[\s\S]*?-----END PRIVATE KEY-----').firstMatch(kp)!.group(0)!);
      File(p.join(tmp.path, 'c.pem')).writeAsStringSync(RegExp(r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----').firstMatch(kp)!.group(0)!);
      final tls = {'enabled': true, 'server_name': 'localhost', 'key_path': p.join(tmp.path, 'k.pem'), 'certificate_path': p.join(tmp.path, 'c.pem')};
      final httpP = await freePort(), plainP = await freePort(), visionP = await freePort(), hy2P = await freePort(), tuicP = await freePort();
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'http', 'tag': 'http', 'listen': '127.0.0.1', 'listen_port': httpP},
          {'type': 'vless', 'tag': 'plain', 'listen': '127.0.0.1', 'listen_port': plainP, 'users': [{'uuid': _uuid}]},
          {'type': 'vless', 'tag': 'vision', 'listen': '127.0.0.1', 'listen_port': visionP, 'users': [{'uuid': _uuid, 'flow': 'xtls-rprx-vision'}], 'tls': tls},
          {'type': 'hysteria2', 'tag': 'hy2', 'listen': '127.0.0.1', 'listen_port': hy2P, 'users': [{'password': 'pw'}], 'tls': tls},
          {'type': 'tuic', 'tag': 'tuic', 'listen': '127.0.0.1', 'listen_port': tuicP, 'users': [{'uuid': _uuid, 'password': 'pw'}], 'tls': {...tls, 'alpn': ['h3']}},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      final ctls = {'enabled': true, 'server_name': 'localhost', 'insecure': true};
      final entries = {
        'vless xudp': {'type': 'vless', 'server': '127.0.0.1', 'server_port': plainP, 'uuid': _uuid, 'packet_encoding': 'xudp'},
        'vless vision': {'type': 'vless', 'server': '127.0.0.1', 'server_port': visionP, 'uuid': _uuid, 'flow': 'xtls-rprx-vision', 'tls': ctls, 'packet_encoding': 'xudp'},
        'http': {'type': 'http', 'server': '127.0.0.1', 'server_port': httpP},
      };
      final exits = {
        'hy2': {'type': 'hysteria2', 'server': 'localhost', 'server_port': hy2P, 'password': 'pw', 'tls': ctls},
        'tuic': {'type': 'tuic', 'server': '127.0.0.1', 'server_port': tuicP, 'uuid': _uuid, 'password': 'pw', 'tls': {...ctls, 'alpn': ['h3']}},
      };
      final url = 'http://127.0.0.1:${target.port}/';
      for (final MapEntry(key: en, value: entry) in entries.entries) {
        final r = await measureLatency(
          binary: _bin,
          workDir: p.join(tmp.path, 'ping-${en.replaceAll(' ', '')}'),
          nodes: [
            {'key': 'e', 'outbound': entry},
            for (final x in exits.entries) {'key': x.key, 'outbound': x.value},
          ],
          pairs: [
            for (final x in exits.entries) {'key': x.key, 'entry': {'outbound': entry}, 'exit': {'outbound': x.value}},
          ],
          url: url,
          timeoutMs: 3000,
        );
        expect([r.nodes['e'], r.nodes['hy2'], r.nodes['tuic']], everyElement(greaterThanOrEqualTo(0)), reason: '$en: servers alone answer');
        for (final x in exits.keys) {
          if (en == 'http') {
            expect(r.pairs[x], -1, reason: '$en → $x: an entry without UDP cannot carry the exit');
          } else {
            expect(r.pairs[x], greaterThanOrEqualTo(0), reason: '$en → $x');
          }
        }
      }
    } finally {
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
}
