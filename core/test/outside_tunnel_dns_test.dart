// The app's own DNS lookups with the real sing-box (tool/bin), loopback only: the DNS rule that
// selfDnsRules makes from the self rule (the same text buildConfig puts into a TUN config) is
// matched by the asking process, so a lookup of this process is answered by the server meant for it
// and not by `dns.final`, which in the app is the VPN server. The TUN's DNS hijack is stood in for by
// a hijack rule on the mixed inbound (a DNS query over SOCKS5 to port 53): hijacked queries reach the
// DNS router with the connection's metadata, process included, the same way as from the TUN.
// Android matches by `package_name` through the platform's connection owner — its config shape is
// checked by `sing-box check` (tun_test.dart), the matching itself is on the device.
// Skipped when the binary is missing.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

/// A DNS query for [name] over SOCKS5 to [port] (CONNECT 9.9.9.9:53, DNS over TCP): the A record's address.
Future<String> _lookup(int port, String name) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final buf = <int>[];
  final wake = StreamController<void>.broadcast();
  s.listen((d) {
    buf.addAll(d);
    wake.add(null);
  }, onDone: () => wake.add(null), onError: (Object _) => wake.add(null));
  Future<List<int>> take(int n) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (buf.length < n) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('read $n bytes, have ${buf.length}');
      await wake.stream.first.timeout(const Duration(milliseconds: 100), onTimeout: () {});
    }
    final out = buf.sublist(0, n);
    buf.removeRange(0, n);
    return out;
  }

  try {
    s.add([5, 1, 0]);
    expect(await take(2), [5, 0]);
    s.add([5, 1, 0, 1, 9, 9, 9, 9, 0, 53]);
    final reply = await take(10);
    expect(reply[1], 0, reason: 'SOCKS5 CONNECT refused: $reply');
    final q = dnsQuery(name, 0x1234);
    s.add([q.length >> 8, q.length & 255, ...q]);
    final head = await take(2);
    final answer = Uint8List.fromList(await take((head[0] << 8) | head[1]));
    expect(isDnsAnswer(answer, 0x1234), isTrue);
    return answer.sublist(answer.length - 4).join('.'); // the single A record's address ends the message
  } finally {
    s.destroy();
    await wake.close();
  }
}

Map<String, dynamic> _config(int port, List<Map<String, dynamic>> dnsRules) => {
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'type': 'hosts', 'tag': 'direct-dns', 'predefined': {'x.test': ['10.1.1.1']}},
          {'type': 'hosts', 'tag': 'vpn-dns', 'predefined': {'x.test': ['10.2.2.2']}},
        ],
        'rules': dnsRules,
        'final': 'vpn-dns',
      },
      'inbounds': [
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': port},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {'inbound': ['mixed-in'], 'port': [53], 'action': 'hijack-dns'},
        ],
        'final': 'direct',
        'default_domain_resolver': 'direct-dns',
        'find_process': true,
      },
    };

void main() {
  test('a lookup of this process is answered by the own-DNS server, one of another program by dns.final', () async {
    final tmp = await Directory.systemTemp.createTemp('jorm-owndns');
    final box = SingBoxProcess(_bin, p.join(tmp.path, 'run'));
    try {
      // this process: the dart VM running the test. A recent SDK's dart.exe is a launcher that starts
      // dartvm.exe, and `resolvedExecutable` names the launcher, not the process sing-box finds.
      final vm = p.join(p.dirname(Platform.resolvedExecutable), Platform.isWindows ? 'dartvm.exe' : 'dartvm');
      final self = [File(vm).existsSync() ? vm : Platform.resolvedExecutable];
      final port = await freePort();
      // the rule exactly as buildConfig makes it for a TUN, the inbound being the one the test has
      final own = selfDnsRules(selfRules(paths: self), server: 'direct-dns', inbound: 'mixed-in');
      await box.start(_config(port, own));
      expect(await _lookup(port, 'x.test'), '10.1.1.1', reason: 'this process matches the self rule: the direct server answers');
      await box.stop();

      // control: the same rule for a program that is not us leaves the answer to final
      final other = selfDnsRules(selfRules(paths: [p.join(tmp.path, 'not-us.exe')]), server: 'direct-dns', inbound: 'mixed-in');
      await box.start(_config(port, other));
      expect(await _lookup(port, 'x.test'), '10.2.2.2', reason: 'another program: dns.final answers');
      await box.stop();

      // control: the rule is limited to its inbound (the TUN's in the app): from another inbound it does not apply
      final tunOnly = selfDnsRules(selfRules(paths: self), server: 'direct-dns'); // inbound tun-in
      await box.start(_config(port, tunOnly));
      expect(await _lookup(port, 'x.test'), '10.2.2.2', reason: 'queries of the proxy ports are not the TUN\'s');
    } finally {
      await box.stop();
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 1)));
}
