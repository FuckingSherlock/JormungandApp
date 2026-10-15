// The status' `exit` while connected with the controller: the latest exit answer of the node in use (null while it is
// being checked), asked pinned to the node's outbound (docs/core.md → Проверка выхода). A fake sing-box API service
// (auto_test.dart's FakeBox), the pinned check replaced by gates the test opens.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'auto_test.dart' show FakeBox;
import 'sentinel_fakes.dart';

/// [SingBoxApi] over a [FakeBox]: what the service reads of the API service, no gRPC.
class _Api extends SingBoxApi {
  _Api(this.box) : super(1, 'x');
  final FakeBox box;

  @override
  Map<String, String> get selected => box.selected;
  @override
  Stream<void> get groupsChanged => box.groupsChanged;
  @override
  Future<bool> select(String group, String outbound) => box.select(group, outbound);
  @override
  Iterable<LiveConnection> get connections => box.connections;
  @override
  Future<bool> closeConnection(String id) => box.closeConnection(id);
  @override
  Future<List<String>> deprecatedWarnings() async => const [];
}

class _Runner implements BoxRunner {
  bool up = false;
  _Api? _api;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => _api;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async {
    _api = _Api(FakeBox(config, {'s::a': 10, 's::b': 10}));
    up = true;
  }

  @override
  Future<void> stop() async {
    up = false;
    await _api?.close();
    _api = null;
  }
}

Map<String, dynamic> _route(String id, String key) => {
      'id': id,
      'kind': 'unit',
      'main': {
        'pick': 'priority',
        'chosen': key,
        'nodes': [
          {'key': key, 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': key}},
        ],
      },
    };

Map<String, dynamic> _body() => {
      'plan': {
        'routes': [_route('A', 's::a'), _route('B', 's::b')],
        'mixedPort': 2080,
        'global': true,
      },
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late FakeTime time;
  final gates = <String, Completer<Map<String, dynamic>>>{};
  final asked = <String>[];
  var direct = 0;
  Completer<Map<String, dynamic>>? directGate; // when set, the direct check waits for it

  setUp(() async {
    direct = 0;
    directGate = null;
    tmp = await Directory.systemTemp.createTemp('jorm-svc-exit');
    time = FakeTime();
    gates.clear();
    asked.clear();
    svc = CoreService(
      directProbe: (_, _) async => 5, // hermetic: the direct path answers
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async {
        direct++;
        final g = directGate;
        if (g != null) return g.future;
        return {'ip': '198.51.100.7', 'country': 'RU'}; // the direct check (not connected)
      },
      exitVia: (probe, tag) {
        asked.add(tag);
        return (gates[tag] ??= Completer()).future;
      },
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
  });

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>?> exit() async => (await svc.status())['exit'] as Map<String, dynamic>?;

  test('status exit is the node in use\'s: null while it is checked, a switch asks the new node, the old answer is not shown for it', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    expect(asked, ['route0/s::a'], reason: 'pinned to the node in use\'s own outbound');
    expect(await exit(), isNull, reason: 'being checked');

    gates['route0/s::a']!.complete({'ip': '203.0.113.1', 'country': 'DE'});
    await time.advance(Duration.zero);
    expect(await exit(), allOf(containsPair('ip', '203.0.113.1'), containsPair('direct', false)));

    await svc.autoSettings({'manual': true, 'entry': 'B'});
    await time.advance(Duration.zero);
    expect(asked, ['route0/s::a', 'route1/s::b']);
    expect(await exit(), isNull, reason: 'B has no answer yet: A\'s is not shown for it');

    gates['route1/s::b']!.complete({'ip': '203.0.113.2', 'country': 'FR'});
    await time.advance(Duration.zero);
    expect(await exit(), containsPair('ip', '203.0.113.2'));

    // back to A: its answer is kept, no new check needed
    await svc.autoSettings({'manual': true, 'entry': 'A'});
    await time.advance(Duration.zero);
    expect(await exit(), containsPair('ip', '203.0.113.1'));
  });

  test('a reconnect shows the node\'s stored exit at once and asks nothing within the hour; the user\'s re-check asks', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    gates['route0/s::a']!.complete({'ip': '203.0.113.1', 'country': 'DE'});
    await time.advance(Duration.zero);
    expect(asked, ['route0/s::a']);

    await svc.disconnect();
    await time.advance(Duration.zero);
    await svc.connect(_body());
    await time.advanceSeconds(6);
    expect(asked, ['route0/s::a'], reason: 'checked a moment ago: no new check');
    expect(await exit(), allOf(containsPair('ip', '203.0.113.1'), containsPair('country', 'DE'), containsPair('direct', false)));

    gates.remove('route0/s::a'); // a new gate for the user's check
    await svc.recheckExit();
    expect(asked,['route0/s::a', 'route0/s::a'], reason: 'the user\'s request ignores the timer');
    final re = await exit();
    expect(re, allOf(containsPair('ip', '203.0.113.1'), containsPair('rechecking', true)), reason: 'the old answer stays until the new one');
  });

  test('the direct check is not repeated on the same network (disconnect, restart); another network or the user asks again', () async {
    svc.setNetwork({'connected': true, 'type': 'wifi', 'id': 'net1'});
    await time.advance(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final base = direct;
    expect(base, greaterThan(0));
    // the first check after the network was said (or the one at init) is stored; the next ones come from the store
    svc.recheckExit(); // the user's: always asks
    await Future<void>.delayed(Duration.zero);
    expect(direct, base + 1);

    await svc.connect(_body());
    await time.advanceSeconds(6);
    await svc.disconnect();
    await time.advance(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(direct, base + 1, reason: 'same network: the stored direct result is shown');
    expect(await exit(), allOf(containsPair('ip', '198.51.100.7'), containsPair('direct', true)));

    // a new core over the same data directory (a restart) on the same network id
    await svc.dispose();
    svc = CoreService(
      directProbe: (_, _) async => 5, // hermetic: the direct path answers
      sentinelClock: time.clock,
      now: () => time.t,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      runner: _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async {
        direct++;
        return {'ip': '198.51.100.8'};
      },
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    svc.setNetwork({'connected': true, 'type': 'wifi', 'id': 'net1'});
    await Future<void>.delayed(Duration.zero);
    expect(direct, base + 1, reason: 'a restart on the same network asks nothing');
    expect(await exit(), containsPair('ip', '198.51.100.7'));

    // another network: asked again
    svc.setNetwork({'connected': true, 'type': 'wifi', 'id': 'net2'});
    await svc.connect(_body());
    await svc.disconnect();
    await time.advance(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(direct, greaterThan(base + 1), reason: 'another network: asked again (the connect\'s own tunnel check counts too)');
    expect(await exit(), containsPair('ip', '198.51.100.8'));
  });

  test('the user\'s direct re-check keeps the last answer as rechecking; a failure shows the error next to it', () async {
    await time.advance(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(await exit(), containsPair('ip', '198.51.100.7'));

    directGate = Completer();
    svc.recheckExit();
    await Future<void>.delayed(Duration.zero);
    expect(await exit(), allOf(containsPair('ip', '198.51.100.7'), containsPair('rechecking', true), containsPair('direct', true)));

    directGate!.complete({'ip': '198.51.100.9', 'country': 'RU'});
    await Future<void>.delayed(Duration.zero);
    var e = await exit();
    expect(e, containsPair('ip', '198.51.100.9'));
    expect(e!.containsKey('rechecking'), isFalse);

    directGate = Completer();
    svc.recheckExit();
    await Future<void>.delayed(Duration.zero);
    directGate!.completeError(Exception('offline'));
    await Future<void>.delayed(Duration.zero);
    e = await exit();
    expect(e, allOf(containsPair('ip', '198.51.100.9'), containsPair('direct', true)));
    expect('${e!['error']}', contains('offline'));
    expect(e.containsKey('rechecking'), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200)); // the store's write ends before the directory goes
  });

  test('a subscription refresh while no controller runs marks its nodes in the exit book', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((rq) {
      rq.response
        ..write('ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.20:8388#one\n')
        ..close();
    });
    final src = {'url': 'http://127.0.0.1:${server.port}/sub', 'name': 'T'};
    var r = await svc.fetchSource({'sid': 'S', 'source': src});
    final nodes = (r['patch'] as Map)['nodes'] as List;
    expect(nodes, isNotEmpty);
    final id = serverIdentity((nodes.first as Map)['outbound'] as Map);
    svc.exitBook.record(id, ip: '203.0.113.1', country: 'DE', at: time.t.millisecondsSinceEpoch);
    expect(svc.exitBook[id]!.refresh, isFalse);

    r = await svc.fetchSource({'sid': 'S', 'source': {...src, 'nodes': nodes}});
    expect(svc.exitBook[id]!.refresh, isTrue, reason: 'the next check of the node ignores the hourly timer, whenever it comes');
  });

  test('a failed check is the status\' error for that node; disconnected: the direct check', () async {
    await svc.connect(_body());
    await time.advanceSeconds(6);
    // an error after 3 s or more is final (a quick one is retried while the node is in use: auto_exit_test.dart)
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    gates['route0/s::a']!.completeError(Exception('no answer through the tunnel (timeout)'));
    await time.advance(Duration.zero);
    final e = await exit();
    expect(e, isNotNull);
    expect('${e!['error']}', contains('no answer through the tunnel'));

    await svc.disconnect();
    await time.advance(Duration.zero);
    expect(await exit(), allOf(containsPair('ip', '198.51.100.7'), containsPair('direct', true)));
  });
}
