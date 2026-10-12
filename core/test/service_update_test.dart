// CoreService's app-update API (updateStatus / updateCheck / updateDownload / updateSettings) over
// the AppUpdater of appupdate.dart, with a loopback feed and a signed release.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/appupdate_release.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'appupdate_test.dart' show Host, Net, publish, release;

class _Runner implements BoxRunner {
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => false;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) {}
  @override
  Future<void> start(Map<String, dynamic> config) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  late Directory tmp;
  late Host feed;
  late ReleaseKeys keys;
  CoreService? svc;

  setUpAll(() async => keys = await generateReleaseKeys());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-svc-upd');
    feed = await Host.start();
  });

  tearDown(() async {
    await svc?.dispose();
    svc = null;
    await feed.close();
    for (var i = 0; i < 5 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<CoreService> start({AppVersion? version}) async {
    final s = CoreService(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      appVersion: version,
      updatePlatformKeys: const ['android-arm64-v8a'],
      updateFeeds: [feed.base],
      updatePublicKeys: [keys.publicBase64],
      updateGet: Net(() => false).get,
      updateFirstDelay: const Duration(hours: 1),
    );
    await s.init();
    return svc = s;
  }

  test('without an app version there is no updater: unavailable, a check is refused', () async {
    final s = await start();
    expect(s.updateStatus()['phase'], 'unavailable');
    await expectLater(s.updateCheck({}), throwsFormatException);
  });

  test('check -> available, download -> ready, the changes stream tells each step', () async {
    publish(feed, await release(keys, version: '0.2.0', build: 2));
    final s = await start(version: AppVersion.parse('0.1.0', build: 1));
    expect(s.updateStatus()['phase'], 'idle');
    final phases = <String>[];
    final sub = s.updateChanges.listen((st) => phases.add('${st['phase']}'));
    final found = await s.updateCheck({'channel': 'stable', 'manual': true});
    expect(found['phase'], 'available');
    expect((found['offer'] as Map)['version'], '0.2.0');
    final done = await s.updateDownload();
    expect(done['phase'], 'ready');
    expect(File(done['file'] as String).existsSync(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(phases, containsAllInOrder(['checking', 'available', 'downloading', 'ready']));
    await s.updateBeginInstall(); // the platform's step before the installer
  });

  test('a manual check that finds nothing newer is upToDate (also an empty channel); a broken feed answer is failed', () async {
    publish(feed, await release(keys, version: '0.1.0', build: 1));
    final s = await start(version: AppVersion.parse('0.1.0', build: 1));
    expect((await s.updateCheck({'manual': true}))['phase'], 'upToDate');
    feed.files.clear(); // 404: nothing published in the channel
    final empty = await s.updateCheck({'manual': true});
    expect(empty['phase'], 'upToDate');
    expect(empty['error'], isNull);
    feed.fail['manifest-stable.json'] = 500;
    final failed = await s.updateCheck({'manual': true});
    expect(failed['phase'], 'failed');
    expect((failed['error'] as Map)['code'], 'network');
  });
}
