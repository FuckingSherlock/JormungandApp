// LiveCoreHost.report / sendReport over a real CoreService: the host's appInfo reaches the report,
// the core's uploader gets the gzipped, masked report with the note.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand/platform/network_channel.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot;

class _Net implements NetworkPort {
  @override
  Future<bool> metered() async => true;

  @override
  Stream<bool> get meteredChanges => const Stream<bool>.empty();

  @override
  Future<String> type() async => 'mobile';
}

class _Up implements ReportUploader {
  _Up({this.fail});

  final ReportUploadException? fail;
  List<int>? bytes;
  Map<String, dynamic>? meta;

  @override
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta, int? proxyPort, ReportCancel? cancel}) async {
    if (fail != null) throw fail!;
    bytes = gzipped;
    this.meta = meta;
    return const ReportReceipt(id: 'abc-42');
  }
}

void main() {
  late Directory dir;
  late LiveCoreHost host;

  Future<void> start({ReportUploader? up}) async {
    dir = Directory.systemTemp.createTempSync('jorm_report_');
    File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(snapshot()));
    host = LiveCoreHost(
      api: CoreService(
        singBox: '',
        dataDir: dir.path,
        runner: FakeRunner(),
        boxFactory: (_) => FakeRunner(),
        sysProxy: NoSystemProxy(),
        isElevated: () => true,
        resolveAddresses: false, // hermetic: no real DoH
        reportUploader: up,
      ),
      isAndroid: true,
      appVersion: '1.2.3',
      appBuild: 45,
      network: _Net(),
      saveDelay: const Duration(milliseconds: 20),
      reconnectDelay: const Duration(milliseconds: 20),
      trafficEvery: const Duration(milliseconds: 50),
    );
    await host.init();
  }

  tearDown(() async {
    await host.shutdown();
    host.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('report(): the core\'s report with this app\'s account of itself', () async {
    await start();
    final r = await host.report();
    expect(r['format'], 1);
    final app = r['app'] as Map;
    expect([app['version'], app['versionCode'], app['platform']], ['1.2.3', 45, 'android']);
    expect(app.containsKey('names'), isFalse, reason: 'reserved keys have their own place');
    final net = (r['network'] as Map)['host'] as Map;
    expect([net['type'], net['metered']], ['mobile', true]);
    final conn = r['connection'] as Map;
    expect(conn['planSig'], matches(RegExp(r'^[0-9a-f]{12}$')), reason: 'the long signature is digested');
    expect(((r['settings'] as Map)['app'] as Map)['language'], 'system');
    expect(jsonEncode(r), isNot(contains('11111111-1111-1111-1111-111111111111')));
  });

  test('sendReport(): note and app info go through the core to the uploader, gzipped', () async {
    final up = _Up();
    await start(up: up);
    final res = await host.sendReport(note: 'no TCP in Telegram');
    expect(res, {'ok': true, 'id': 'abc-42', 'bytes': up.bytes!.length, 'via': 'direct'});
    final rep = jsonDecode(utf8.decode(gzip.decode(up.bytes!))) as Map<String, dynamic>;
    expect(rep['note'], 'no TCP in Telegram');
    expect((rep['app'] as Map)['version'], '1.2.3');
    expect(up.meta, containsPair('versionCode', 45));
  });

  test('sendReport(): no receiver configured is a result, not an exception', () async {
    await start();
    expect(await host.sendReport(note: 'x'), {'ok': false, 'error': 'not-configured'});
  });

  test('sendReport(): a refused delivery keeps its code and message', () async {
    await start(up: _Up(fail: const ReportUploadException('rejected', 'too large')));
    expect(await host.sendReport(), {'ok': false, 'error': 'rejected', 'message': 'too large'});
  });
}
