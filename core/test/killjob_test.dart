// sing-box must die with the core, however the core dies (killjob.dart): a helper process
// starts a real sing-box on loopback through SingBoxProcess, the test kills the helper hard
// (TerminateProcess, no cleanup runs) and waits for the sing-box to be gone. Windows only;
// skipped when the binary is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = !Platform.isWindows
    ? 'Job Objects are Windows only'
    : File(_bin).existsSync()
        ? false
        : 'no sing-box in tool/bin';

Future<bool> _alive(int pid) async {
  final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
  return '${r.stdout}'.contains('"$pid"');
}

void main() {
  test('killing the core hard takes its sing-box with it', () async {
    final tmp = await Directory.systemTemp.createTemp('jorm-killjob');
    final helper = await Process.start(Platform.resolvedExecutable, [p.join('test', 'killjob_helper.dart'), p.absolute(_bin), p.join(tmp.path, 'run')]);
    int? helperPid, boxPid;
    try {
      final err = StringBuffer();
      helper.stderr.transform(utf8.decoder).listen(err.write);
      final ready = await helper.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.startsWith('ready '))
          .timeout(const Duration(seconds: 60), onTimeout: () => throw StateError('helper did not start: $err'));
      final parts = ready.split(' ');
      helperPid = int.parse(parts[1]);
      boxPid = int.parse(parts[2]);
      expect(await _alive(boxPid), isTrue, reason: 'sing-box is up before the kill');

      Process.killPid(helperPid, ProcessSignal.sigkill);
      helper.kill(ProcessSignal.sigkill); // the `dart` wrapper, if there is one

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (await _alive(boxPid) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(await _alive(boxPid), isFalse, reason: 'sing-box $boxPid outlived the core');
    } finally {
      if (helperPid != null) Process.killPid(helperPid, ProcessSignal.sigkill);
      helper.kill(ProcessSignal.sigkill);
      if (boxPid != null) await Process.run('taskkill', ['/F', '/PID', '$boxPid']); // only if the test failed
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('killOrphans leaves a running sing-box alone (its parent is alive) and other binaries', () async {
    final tmp = await Directory.systemTemp.createTemp('jorm-killjob2');
    final sb = SingBoxProcess(_bin, p.join(tmp.path, 'run'));
    try {
      await sb.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': await freePort(), 'method': 'aes-128-gcm', 'password': 'loopback'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      expect(await killOrphans(_bin), isNot(contains(sb.pid)));
      expect(sb.running, isTrue);
      expect(await _alive(sb.pid!), isTrue);
    } finally {
      await sb.stop();
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
}
