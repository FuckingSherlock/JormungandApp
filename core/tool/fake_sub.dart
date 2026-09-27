// A subscription that works with no outside servers: a sing-box shadowsocks server on
// loopback and an HTTP server that hands out a base64 list with it (plus one dead
// server and one XHTTP server sing-box cannot use). Run from core/:
//   dart run tool/fake_sub.dart          → subscription URL http://127.0.0.1:18080/sub
// The loopback server goes out directly, so through it you reach the real internet.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
  final ss = SingBoxProcess(bin, p.join(Directory.systemTemp.path, 'jorm-fake-sub'));
  await ss.start({
    'log': {'level': 'warn'},
    'inbounds': [
      {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': 18388, 'method': 'aes-128-gcm', 'password': 'loopback'},
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
  });

  String b64(String s) => base64.encode(utf8.encode(s));
  final list = [
    'ss://${b64('aes-128-gcm:loopback')}@127.0.0.1:18388#${Uri.encodeComponent('🇩🇪 Loopback SS')}',
    'ss://${b64('aes-128-gcm:loopback')}@127.0.0.1:18399#${Uri.encodeComponent('🇳🇱 Dead SS')}',
    'vless://11111111-2222-3333-4444-555555555555@127.0.0.1:18400?type=xhttp&security=none#${Uri.encodeComponent('🇫🇮 XHTTP only')}',
  ].join('\n');

  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 18080);
  stdout.writeln('subscription: http://127.0.0.1:18080/sub   (Ctrl+C to stop)');
  ProcessSignal.sigint.watch().listen((_) async {
    await ss.stop();
    exit(0);
  });
  await for (final req in http) {
    stdout.writeln('${req.method} ${req.uri}  UA: ${req.headers.value('user-agent')}');
    req.response
      ..headers.set('subscription-userinfo', 'upload=1000000000; download=2500000000; total=50000000000; expire=1798761600')
      ..headers.set('profile-title', 'base64:${b64('Loopback test')}')
      ..write(b64(list));
    await req.response.close();
  }
}
