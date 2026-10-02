import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/vpn_channel.dart';
import 'core_host.dart';
import 'live_core_host.dart';

/// Android's [BoxRunner]: sing-box inside the app as libbox, behind the VpnService.
///
/// Not integrated yet: [start] says so, so Connect fails with a clear message instead of doing
/// nothing. The rest of the app (catalog, plan, status, journal) already runs on the same core.
// TODO(libbox): build libbox (gomobile) into the app, see app/README.md. Then: start() passes the
// finished [config] to `VpnChannel().start(config: jsonEncode(config))`, the service hands it to
// libbox with the TUN fd; `api` is a SingBoxApi on the clash API port libbox opens; `onLog` takes
// libbox's log lines; `onExit` fires when libbox stops by itself; `stop()` ends the service.
class LibboxRunner implements BoxRunner {
  static const notIntegrated =
      'libbox is not integrated yet, so the VPN cannot start on Android (see app/README.md)';

  @override
  bool get running => false;

  @override
  int? get pid => null;

  @override
  SingBoxApi? get api => null;

  @override
  void Function(String line)? onLog;

  @override
  void Function(int code)? onExit;

  @override
  void note(String line) => onLog?.call('[jormd] $line');

  @override
  Future<void> start(Map<String, dynamic> config) =>
      Future.error(SingBoxError(notIntegrated));

  @override
  Future<void> stop() async {}
}

/// Where the desktop sing-box is: `JORMUNGAND_SINGBOX`, else next to the app's executable.
String desktopSingBoxPath() {
  final env = Platform.environment['JORMUNGAND_SINGBOX'];
  if (env != null && env.isNotEmpty) return env;
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final dir = File(Platform.resolvedExecutable).parent.path;
  return '$dir${Platform.pathSeparator}$exe';
}

/// Builds the host the app runs on: the in-process core (`CoreService`) with this platform's
/// seams. Desktop: sing-box as a process (the binary bundled next to the executable), the
/// Windows system proxy. Android: [LibboxRunner], no system proxy, always TUN through the
/// VpnService.
Future<CoreHost> openCoreHost() async {
  final support = await getApplicationSupportDirectory();
  final dataDir = '${support.path}${Platform.pathSeparator}core';
  await Directory(dataDir).create(recursive: true);
  if (Platform.isAndroid) {
    return LiveCoreHost(
      api: CoreService(
        singBox: '',
        dataDir: dataDir,
        runner: LibboxRunner(),
        boxFactory: (_) => LibboxRunner(),
        sysProxy: NoSystemProxy(),
        isElevated: () =>
            true, // TUN is the VpnService here, not an admin matter
      ),
      isAndroid: true,
      vpn: const VpnChannel(),
    );
  }
  final singBox = desktopSingBoxPath();
  // a sing-box left by an app that was killed would hold the ports
  await killOrphans(singBox);
  return LiveCoreHost(
    api: CoreService(singBox: singBox, dataDir: dataDir),
    isAndroid: false,
  );
}
