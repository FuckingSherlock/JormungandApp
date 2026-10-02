// Helper process of killjob_test.dart (not a test itself): starts a loopback sing-box
// through SingBoxProcess, prints "ready <own pid> <sing-box pid>" and sleeps until killed.
//   dart test/killjob_helper.dart <sing-box> <work dir>
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';

Future<void> main(List<String> args) async {
  final sb = SingBoxProcess(args[0], args[1]);
  await sb.start({
    'log': {'level': 'warn'},
    'inbounds': [
      {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': await freePort(), 'method': 'aes-128-gcm', 'password': 'loopback'},
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
  });
  stdout.writeln('ready $pid ${sb.pid}');
  await stdout.flush();
  await Future<void>.delayed(const Duration(minutes: 5));
}
