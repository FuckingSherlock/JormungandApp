// POST /api/check-now and POST /api/rule-sets/retry through the daemon router (docs/core.md, jormd HTTP API):
// 200 with the service's answer, 400 for an unknown event, a type without a check, a non-int `event`.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

void main() {
  late Directory tmp;
  late CoreService svc;
  late HttpServer server;
  final client = HttpClient();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-chkhttp');
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sentinelClock: FakeTime().clock,
      windows: FailureWindows.instant(),
    );
    await svc.init();
    final d = Daemon.over(svc, uiFile: 'none');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(d.handle);
  });

  tearDown(() async {
    await server.close(force: true);
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  Future<(int, dynamic)> post(String path, Object? body) async {
    final req = await client.openUrl('POST', Uri.parse('http://127.0.0.1:${server.port}$path'));
    req.headers.set('X-Jorm', '1');
    if (body != null) req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
  }

  int add(String cat, String type, Map<String, dynamic> data) => svc.eventBook.add(cat, type, 'warn', data: data, link: false);

  test('check-now: 200 with the answer (not connected here), 400 for unknown / unsupported / non-int event', () async {
    final lost = add('conn', 'lost', {'routes': 1});
    final (c0, j0) = await post('/api/check-now', {'event': lost});
    expect(c0, 200);
    expect(j0, {'ok': false, 'error': 'notConnected'});
    final offline = add('conn', 'offline', {});
    for (final b in <Object?>[
      {'event': 987654},
      {'event': offline},
      {'event': '$lost'},
      {'event': 1.5},
      {'event': null},
      <String, dynamic>{},
    ]) {
      final (code, json) = await post('/api/check-now', b);
      expect(code, 400, reason: '$b');
      expect(json, containsPair('error', isA<String>()));
    }
  });

  test('rule-sets/retry: 200 {updated, failed} (not connected: every tag failed), 400 for unknown / other type / non-int event', () async {
    final f = add('rules', 'ruleSetFailed', {'tag': 'set-a', 'url': 'http://x.example/a', 'error': 'e', 'hasCopy': true});
    final (c0, j0) = await post('/api/rule-sets/retry', {'event': f});
    expect(c0, 200);
    expect(j0, {'updated': <String>[], 'failed': ['set-a']});
    final other = add('rules', 'ruleSetUpdated', {'tag': 'set-a'});
    for (final b in <Object?>[
      {'event': 987654},
      {'event': other},
      {'event': '$f'},
      {'event': 2.5},
      <String, dynamic>{},
    ]) {
      final (code, json) = await post('/api/rule-sets/retry', b);
      expect(code, 400, reason: '$b');
      expect(json, containsPair('error', isA<String>()));
    }
  });
}
