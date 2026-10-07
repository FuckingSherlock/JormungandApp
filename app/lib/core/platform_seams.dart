import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/files_channel.dart';
import '../platform/network_channel.dart';
import '../platform/screen_channel.dart';
import '../platform/resume_channel.dart';
import '../platform/vpn_channel.dart';
import 'core_host.dart';
import 'libbox_runner.dart';
import 'live_core_host.dart';

/// [LibboxPort] over the Android MethodChannel (`VpnChannel`): [boxId] null = the tunnel (the
/// VpnService with a `tun` inbound), else a throwaway libbox with no tunnel under that id.
class ChannelLibboxPort implements LibboxPort {
  ChannelLibboxPort(this._vpn, {this.boxId});

  final VpnChannel _vpn;
  final String? boxId;

  /// libbox starts the tunnel before it answers; a hang is cut here.
  static const startTimeout = Duration(seconds: 60);

  @override
  Future<void> start(String config) async {
    final id = boxId;
    try {
      await (id == null
              ? _vpn.start(config: config)
              : _vpn.startBox(id, config))
          .timeout(startTimeout);
    } on PlatformException catch (e) {
      throw SingBoxError(e.message ?? e.code);
    } on TimeoutException {
      unawaited(stop());
      throw SingBoxError(
        'sing-box did not start in ${startTimeout.inSeconds} s',
      );
    }
  }

  @override
  Future<void> stop() {
    final id = boxId;
    return id == null ? _vpn.stop() : _vpn.stopBox(id);
  }

  @override
  Stream<String> get stoppedOnItsOwn => boxId == null
      ? _vpn.stopped.map((e) => e.reason)
      : const Stream<String>.empty();

  // only the tunnel outlives the engine (it is the VpnService's); throwaway boxes die with it
  @override
  Future<void> remember(String record) async {
    if (boxId == null) await _vpn.remember(record);
  }

  @override
  Future<({bool running, String? record})> recall() async =>
      boxId == null ? _vpn.recall() : (running: false, record: null);
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
/// Windows system proxy. Android: [LibboxRunner] (libbox in the app, the tunnel through the
/// VpnService; throwaway instances for latency tests and Speed Test), no system proxy, always TUN.
Future<CoreHost> openCoreHost() async {
  final support = await getApplicationSupportDirectory();
  final dataDir = '${support.path}${Platform.pathSeparator}core';
  await Directory(dataDir).create(recursive: true);
  if (Platform.isAndroid) {
    const vpn = VpnChannel();
    var boxes = 0;
    // Every libbox of the process locks its own cache file (withCacheFile): the tunnel's stays
    // under the data dir, the throwaway ones live in the cache dir and go with their instance.
    final boxCache = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}boxes',
    );
    try {
      await boxCache.delete(recursive: true); // what a killed app left
    } catch (_) {}
    final ver = await vpn.appVersion();
    final version = ver?.name ?? fallbackAppVersion;
    final core = CoreService(
      singBox: '',
      dataDir: dataDir,
      appVersion: AppVersion.tryParse(version, build: ver?.code ?? 1),
      updatePlatformKeys: updatePlatforms(os: 'android', abis: await vpn.abis()),
      installedPackage: await installedApkPath(), // delta updates are applied to it
      runner: LibboxRunner(
        ChannelLibboxPort(vpn),
        cacheFile: '$dataDir${Platform.pathSeparator}run${Platform.pathSeparator}main${Platform.pathSeparator}cache.db',
      ),
      boxFactory: (_) {
        final id = 'box${boxes++}';
        return LibboxRunner(
          ChannelLibboxPort(vpn, boxId: id),
          cacheFile: '${boxCache.path}${Platform.pathSeparator}$id.db',
          temporaryCache: true,
          watchApi: false, // nobody reads a test box's connections / groups / status
        );
      },
      sysProxy: NoSystemProxy(),
      isElevated: () => true, // TUN is the VpnService here, not an admin matter
    );
    // the Kotlin side's own lines (libbox start / stop, networks, DNS) into the raw log
    vpn.logs.listen(
      (l) => core.logBook.note(l.level, '[android] ${l.text}'),
      onError: (Object _) {},
    );
    return LiveCoreHost(
      api: core,
      ruleSetTimesOf: core.ruleSets.updatedTimes,
      isAndroid: true,
      vpn: vpn,
      appVersion: version,
      installer: installApk,
      resume: const ResumeChannel(),
      logNote: core.logBook.note,
      network: const NetworkChannel(),
      screen: const ScreenChannel(),
    );
  }
  final singBox = desktopSingBoxPath();
  // a sing-box left by an app that was killed would hold the ports
  await killOrphans(singBox);
  final core = CoreService(
    singBox: singBox,
    dataDir: dataDir,
    appVersion: AppVersion.tryParse(fallbackAppVersion, build: 1),
    updatePlatformKeys: updatePlatforms(os: 'windows'),
  );
  return LiveCoreHost(
    api: core,
    ruleSetTimesOf: core.ruleSets.updatedTimes,
    isAndroid: false,
    appVersion: fallbackAppVersion,
  );
}

/// The version of a build that has no platform to ask (desktop); keep in step with pubspec.yaml.
const fallbackAppVersion = '0.1.0';
