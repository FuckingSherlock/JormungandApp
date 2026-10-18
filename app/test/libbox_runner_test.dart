// LibboxRunner (the Android BoxRunner) with a desktop sing-box behind the port instead of libbox:
// the config gets the API service, `api` talks to it, the log lines come through the API, a
// restart replaces, "stopped on its own" reaches onExit. Loopback only; skipped when
// core/tool/bin has no sing-box. Run from app/.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/libbox_runner.dart';
import 'package:jormungand_core/jormungand_core.dart';

final _bin =
    '../core/tool/bin/${Platform.isWindows ? 'sing-box.exe' : 'sing-box'}';
final _skip = File(_bin).existsSync() ? false : 'no sing-box in core/tool/bin';

/// What the Kotlin side does, with a sing-box process: runs the config it is given.
class ProcessPort implements LibboxPort {
  ProcessPort(this.dir);
  final String dir;
  Process? _proc;
  int starts = 0, stops = 0;
  Object? failWith;
  final gone = StreamController<String>.broadcast();

  @override
  Future<void> start(String config) async {
    starts++;
    if (failWith != null) throw failWith!;
    _proc?.kill();
    final file = File('$dir/config$starts.json')..writeAsStringSync(config);
    _proc = await Process.start(_bin, [
      'run',
      '-c',
      file.path,
      '-D',
      dir,
      '--disable-color',
    ]);
    _proc!.stdout.drain<void>();
    _proc!.stderr.drain<void>();
  }

  @override
  Future<void> stop() async {
    stops++;
    _proc?.kill();
    _proc = null;
    _record = null;
  }

  String? _record;

  // the service keeps the record for as long as the tunnel runs
  @override
  Future<void> remember(String record) async {
    if (_proc != null) _record = record;
  }

  @override
  Future<({bool running, String? record})> recall() async =>
      (running: _proc != null, record: _proc == null ? null : _record);

  @override
  Stream<String> get stoppedOnItsOwn => gone.stream;

  /// sing-box is gone on its own; the platform says why ('revoked' = the system took the VPN away).
  void stopOn(String reason) {
    _proc?.kill();
    _proc = null;
    gone.add(reason);
  }

  /// The system takes the VPN away: sing-box is gone, the platform says so.
  void revoke() => stopOn('revoked');
}

Map<String, dynamic> _config(int mixed) => {
  'log': {'level': 'debug'},
  'inbounds': [
    {
      'type': 'mixed',
      'tag': 'mixed-in',
      'listen': '127.0.0.1',
      'listen_port': mixed,
    },
  ],
  'outbounds': [
    {'type': 'direct', 'tag': 'direct'},
  ],
  'route': {'final': 'direct'},
};

Future<void> _get(int mixed, int target) async {
  final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
  try {
    final req = await http
        .getUrl(Uri.parse('http://127.0.0.1:$target/'))
        .timeout(const Duration(seconds: 3));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
  } finally {
    http.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late ProcessPort port;
  late LibboxRunner runner;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-libbox-runner');
    port = ProcessPort(tmp.path);
    runner = LibboxRunner(port, upTimeout: const Duration(seconds: 10));
  });
  tearDown(() async {
    await port.stop();
    await runner.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tmp.delete(recursive: true);
  });

  test(
    'start: the port gets the config plus the API service; api and log lines work',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen(
        (r) => r.response
          ..write('ok')
          ..close(),
      );
      addTearDown(() => target.close(force: true));
      final mixed = await freePort();
      final lines = <String>[];
      runner.onLog = lines.add;

      await runner.start(_config(mixed));

      expect(runner.running, isTrue);
      expect(runner.pid, isNull);
      expect(runner.api, isNotNull);
      final sent =
          jsonDecode(File('${tmp.path}/config1.json').readAsStringSync())
              as Map;
      final api = (sent['services'] as List).cast<Map>().singleWhere(
        (s) => s['type'] == 'api',
      );
      expect(api['listen'], '127.0.0.1');
      expect(api['secret'], isNotEmpty);
      expect(await runner.api!.serviceState(), isNull);

      await _get(mixed, target.port);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!lines.any((l) => l.contains('${target.port}')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        lines.any((l) => l.contains('${target.port}')),
        isTrue,
        reason: 'sing-box log through the API',
      );
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'cacheFile: the port gets that instance\'s own cache path next to the API service',
    () async {
      final cache = '${tmp.path}/sub/c1.db';
      runner = LibboxRunner(
        port,
        upTimeout: const Duration(seconds: 10),
        cacheFile: cache,
      );
      await runner.start(_config(await freePort()));
      final sent =
          jsonDecode(File('${tmp.path}/config1.json').readAsStringSync())
              as Map;
      expect((sent['experimental'] as Map)['cache_file'], {
        'enabled': true,
        'path': cache,
      });
      expect((sent['services'] as List).cast<Map>().any((s) => s['type'] == 'api'), isTrue);
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'watchApi: the tunnel opens the status / connections / groups streams, a throwaway box does not (its log still comes)',
    () async {
      await runner.start(_config(await freePort()));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (runner.api!.status == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(runner.api!.status, isNotNull, reason: 'watch() runs on the tunnel');
      await runner.stop();

      final box = LibboxRunner(port, upTimeout: const Duration(seconds: 10), watchApi: false);
      final lines = <String>[];
      box.onLog = lines.add;
      await box.start(_config(await freePort()));
      addTearDown(box.stop);
      await Future<void>.delayed(const Duration(milliseconds: 2500)); // longer than the streams' 1 s push
      expect(box.api!.status, isNull);
      expect(await box.api!.serviceState(), isNull, reason: 'the commands work');
      expect(lines, isNotEmpty, reason: 'sing-box\'s log (debug here) still comes through');
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test('temporaryCache: a throwaway instance deletes its cache file on stop and on a failed start; the tunnel keeps its own', () async {
    final temp = File('${tmp.path}/box1.db')..writeAsStringSync('x');
    final kept = File('${tmp.path}/main.db')..writeAsStringSync('x');
    final box = LibboxRunner(port, cacheFile: temp.path, temporaryCache: true);
    final tunnel = LibboxRunner(port, cacheFile: kept.path);
    await tunnel.stop();
    expect(kept.existsSync(), isTrue);
    port.failWith = SingBoxError('bad config');
    await expectLater(
      box.start(_config(1)),
      throwsA(isA<SingBoxError>()),
    );
    expect(temp.existsSync(), isFalse);
    temp.writeAsStringSync('x');
    await box.stop();
    expect(temp.existsSync(), isFalse);
  });

  test(
    'a second start replaces the first (new API service, no stop in between)',
    () async {
      await runner.start(_config(await freePort()));
      final first = runner.api;
      await runner.start(_config(await freePort()));
      expect(port.starts, 2);
      expect(port.stops, 0);
      expect(runner.api, isNot(same(first)));
      expect(runner.running, isTrue);
      expect(await runner.api!.serviceState(), isNull);
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  for (final reason in ['error', 'stopped', 'crash', '']) {
    test(
      'stopped on its own ("$reason", not revoked): onExit(0) fires once, onRevoked does not; running turns false, the api is dropped',
      () async {
        final codes = <int>[];
        var revoked = 0;
        runner.onExit = codes.add;
        runner.onRevoked = () => revoked++;
        await runner.start(_config(await freePort()));
        port.stopOn(reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(codes, [0]);
        expect(revoked, 0);
        expect(runner.running, isFalse);
        expect(runner.api, isNull);
        await runner.stop(); // nothing left on the platform side: no native stop
        expect(port.stops, 0);
      },
      skip: _skip,
      timeout: const Timeout(Duration(seconds: 40)),
    );
  }

  test(
    'revoked by the system: onRevoked fires once, onExit does not; running turns false, the api is dropped',
    () async {
      final codes = <int>[];
      var revoked = 0;
      runner.onExit = codes.add;
      runner.onRevoked = () => revoked++;
      await runner.start(_config(await freePort()));
      port.revoke();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(revoked, 1);
      expect(codes, isEmpty);
      expect(runner.running, isFalse);
      expect(runner.api, isNull);
      await runner.stop(); // nothing left on the platform side: no native stop
      expect(port.stops, 0);
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'adopt: a second runner (a new engine) takes the running sing-box over — API, log lines, stop — with no start',
    () async {
      final mixed = await freePort();
      await runner.start(_config(mixed));
      await runner.keep({'plan': 'the core\'s record'});
      expect(port.starts, 1);

      // the first engine is gone (its runner is just dropped, not stopped); another one starts
      final lines = <String>[];
      final second = LibboxRunner(port, upTimeout: const Duration(seconds: 10))
        ..onLog = lines.add;
      final rec = await second.adopt();
      expect(rec, {'plan': 'the core\'s record'});
      expect(port.starts, 1, reason: 'no start');
      expect(port.stops, 0, reason: 'no stop');
      expect(second.running, isTrue);
      expect(await second.api!.serviceState(), isNull);

      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen(
        (r) => r.response
          ..write('ok')
          ..close(),
      );
      addTearDown(() => target.close(force: true));
      await _get(mixed, target.port);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!lines.any((l) => l.contains('${target.port}')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(lines.any((l) => l.contains('${target.port}')), isTrue, reason: 'log attached');

      await second.stop();
      expect(port.stops, 1);
      expect(await port.recall(), (running: false, record: null));
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test('adopt: nothing running -> null; a tunnel with no usable record -> SingBoxError, and stop closes it', () async {
    expect(await runner.adopt(), isNull);

    await runner.start(_config(await freePort()));
    port._record = null; // the platform lost the record
    final second = LibboxRunner(port, upTimeout: const Duration(seconds: 2));
    await expectLater(second.adopt(), throwsA(isA<SingBoxError>()));
    expect(second.running, isFalse);
    await second.stop(); // it IS running on the platform: closed
    expect(port.stops, 1);
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 40)));

  test(
    'stop: closes the platform side once; a failed start leaves nothing to stop',
    () async {
      await runner.start(_config(await freePort()));
      await runner.stop();
      await runner.stop();
      expect(port.stops, 1);
      expect(runner.running, isFalse);

      port.failWith = SingBoxError('bad config');
      await expectLater(
        runner.start(_config(await freePort())),
        throwsA(isA<SingBoxError>()),
      );
      expect(runner.running, isFalse);
      await runner.stop();
      expect(port.stops, 1);
    },
    skip: _skip,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
