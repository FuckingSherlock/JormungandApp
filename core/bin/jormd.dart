// jormd — the Jormungand core as a local web app: serves the mockup with the real core
// behind it. Run from core/:  dart run bin/jormd.dart   then open http://127.0.0.1:7788
//
//   --port 7788         API + UI port (loopback only)
//   --lan               also listen on the LAN (to open the UI from a phone); no auth,
//                       anyone on the network can drive it, so only on a trusted network
//   --ui <file>         the mockup (default ../design/main_screen.html)
//   --sing-box <exe>    sing-box binary (default tool/bin/sing-box[.exe], else PATH)
//   --data <dir>        state, configs, logs (default %APPDATA%\Jormungand)
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final root = p.dirname(p.dirname(p.fromUri(Platform.script)));
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final bundled = p.join(root, 'tool', 'bin', exe);
  final home = Platform.environment['APPDATA'] ?? p.join(Platform.environment['HOME'] ?? '.', '.config');

  final lan = args.contains('--lan');
  final lanIps = !lan
      ? <String>[]
      : [
          for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
            for (final a in i.addresses) a.address,
        ];
  final daemon = Daemon(
    singBox: opt('sing-box') ?? (File(bundled).existsSync() ? bundled : exe),
    dataDir: opt('data') ?? p.join(home, 'Jormungand'),
    uiFile: opt('ui') ?? p.normalize(p.join(root, '..', 'design', 'main_screen.html')),
    lanHosts: lanIps.toSet(),
  );
  await daemon.init();

  final port = int.parse(opt('port') ?? '7788');
  final server = await HttpServer.bind(lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port);
  stdout.writeln('jormd  http://127.0.0.1:$port   (data: ${daemon.dataDir}, sing-box: ${daemon.singBox})');
  for (final ip in lanIps) {
    stdout.writeln('jormd  LAN: http://$ip:$port');
  }

  Future<void> quit() async {
    stdout.writeln('jormd: stopping');
    await daemon.shutdown();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => quit());
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen((_) => quit());

  await for (final req in server) {
    daemon.handle(req);
  }
}
