// Asks every exit-IP service through a running mixed proxy and prints what each says and
// how fast, then what checkExitIp would report. Handy on a node whose country blocks some
// of them:  dart run tool/exit_check.dart [proxyPort=2080 | direct] [user:pass]
// (direct = no proxy; user:pass = the port has a password: Settings → Connection → Password)
import 'package:jormungand_core/jormungand_core.dart';

Future<void> main(List<String> args) async {
  final int? port = args.isEmpty ? 2080 : args.first == 'direct' ? null : int.parse(args.first);
  final auth = args.length > 1 ? args[1] : null;
  await Future.wait([
    for (final p in exitProbes)
      () async {
        final sw = Stopwatch()..start();
        try {
          final r = await checkExitIp(port, probes: [p], grace: Duration.zero, proxyAuth: auth);
          print('${p.name.padRight(12)} ${sw.elapsedMilliseconds.toString().padLeft(5)} ms  $r');
        } catch (e) {
          print('${p.name.padRight(12)} ${sw.elapsedMilliseconds.toString().padLeft(5)} ms  FAIL $e');
        }
      }(),
  ]);
  final sw = Stopwatch()..start();
  try {
    final r = await checkExitIp(port, proxyAuth: auth);
    print('\ncheckExitIp  ${sw.elapsedMilliseconds} ms  $r');
  } catch (e) {
    print('\ncheckExitIp  FAIL after ${sw.elapsedMilliseconds} ms  $e');
  }
}
