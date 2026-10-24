// The DNS events the service writes from the streams of DnsFailover (docs/logs.md «DNS-события», plan
// .claude_states/stages/dns-site-events.md «Контракт данных»): dns/switched {reason, sides, same, route?, cause},
// dns/transport, dns/down, dns/up (`opens` = the down), `cause` as a structure, the DNS changes of a network change
// inside `net/switched`.data.dns (no events of their own), nothing written as dns/failed / dns/failedOnNode.
// Same harness as check_now_test.dart: a fake sing-box runner whose probe inbound is a loopback SOCKS5 server that
// answers or refuses each `dns-check/<tag>` probe; time by hand (FakeTime); no network, no real sing-box.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

class _Socks {
  ServerSocket? _server;
  final asked = <String>[];
  final refuse = <bool Function(String user)>[];
  final _open = <Socket>[];

  Future<void> bind(int port) async {
    await close();
    final s = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    s.listen(_serve);
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    for (final c in _open.toList()) {
      c.destroy();
    }
    _open.clear();
    await s?.close();
  }

  Future<void> _serve(Socket c) async {
    _open.add(c);
    final buf = <int>[];
    Completer<void>? more;
    var closed = false;
    void wake() {
      more?.complete();
      more = null;
    }

    c.listen((d) {
      buf.addAll(d);
      wake();
    }, onDone: () {
      closed = true;
      wake();
    }, onError: (Object _) {
      closed = true;
      wake();
    });
    Future<List<int>> take(int n) async {
      while (buf.length < n) {
        if (closed) throw const SocketException('closed');
        await (more ??= Completer<void>()).future;
      }
      final out = buf.sublist(0, n);
      buf.removeRange(0, n);
      return out;
    }

    try {
      await take(3);
      c.add([5, 2]);
      await take(1);
      final ulen = (await take(1))[0];
      final user = utf8.decode(await take(ulen));
      final plen = (await take(1))[0];
      await take(plen);
      c.add([1, 0]);
      await take(4);
      final hlen = (await take(1))[0];
      await take(hlen + 2);
      asked.add(user);
      if (refuse.any((f) => f(user))) {
        c.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
        await c.flush();
        c.destroy();
        return;
      }
      c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      if (user.startsWith('dns-check/') || user.startsWith('flag-check/')) {
        await c.flush();
        c.destroy();
        return;
      }
      for (;;) {
        while (_headEnd(buf) < 0) {
          if (closed) return;
          await (more ??= Completer<void>()).future;
        }
        buf.removeRange(0, _headEnd(buf) + 4);
        c.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'));
      }
    } catch (_) {
      c.destroy();
    } finally {
      _open.remove(c);
    }
  }

  static int _headEnd(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }
}

class _Api extends SingBoxApi {
  _Api() : super(0, '');
  @override
  final Map<String, String> selected = {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async {
    selected[group] = outbound;
    return true;
  }

  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<bool> closeAllConnections() async => true;
  @override
  Stream<ClosedConnection> closedConnections() => const Stream.empty();
  @override
  void watch() {}
  @override
  Future<void> close() async {}
}

class _Runner implements BoxRunner {
  bool up = false;
  bool withApi = false;
  final _api = _Api();
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => up && withApi ? _api : null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  final socks = _Socks();
  @override
  Future<void> start(Map<String, dynamic> config) async {
    up = true;
    final outs = (config['outbounds'] as List?)?.cast<Map>() ?? const [];
    for (final o in outs) {
      if (o['type'] == 'selector') _api.selected['${o['tag']}'] = '${o['default'] ?? (o['outbounds'] as List).first}';
    }
    for (final i in (config['inbounds'] as List?)?.cast<Map>() ?? const []) {
      if (i['tag'] == 'probe-in') await socks.bind(i['listen_port'] as int);
    }
  }

  @override
  Future<void> stop() async {
    up = false;
    await socks.close();
  }
}

/// Two direct DNS servers with display names (Settings → DNS): g "AdGuard" (first), h "Quad" (the spare).
Map<String, dynamic> _plan({bool spare = true}) => {
      'plan': {
        'routes': [
          {
            'id': 'A',
            'kind': 'unit',
            'main': {
              'pick': 'priority',
              'chosen': 's::a',
              'nodes': [
                {
                  'key': 's::a',
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
              ],
            },
          },
        ],
        'mixedPort': 2080,
        'urlTest': {'url': 'http://probe.test/'},
        'auto': {'flapGuard': false},
        'global': false,
        'routing': {
          'fallback': 'main',
          'dns': {
            'servers': [
              {'id': 'g', 'name': 'AdGuard', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true},
              if (spare) {'id': 'h', 'name': 'Quad', 'addr': 'udp://127.0.0.1:5354', 'via': 'direct', 'on': true},
            ],
          },
          'rules': <Object>[],
        },
      },
    };

Future<void> _until(bool Function() cond, FakeTime time, String what) async {
  for (var i = 0; i < 1000; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (i % 20 == 19) await time.advanceSeconds(2);
  }
  fail('timed out waiting for $what');
}

void main() {
  late Directory tmp;
  late CoreService svc;
  late FakeTime time;
  late _Runner box;
  var disposed = false;

  Future<void> start({bool spare = true}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-dnsev');
    time = FakeTime();
    disposed = false;
    box = _Runner()..withApi = true;
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false,
      directProbe: (_, _) async => 5,
      dataDir: p.join(tmp.path, 'data'),
      runner: box,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      windows: FailureWindows.instant(),
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    await svc.connect(_plan(spare: spare));
    await time.advanceSeconds(6);
  }

  tearDown(() async {
    if (!disposed) await svc.dispose();
    await tmp.delete(recursive: true);
  });

  List<Map> all() => (svc.events()['events'] as List).cast<Map>();
  List<Map> dns(String type) => [for (final e in all()) if (e['cat'] == 'dns' && e['type'] == type) e];
  Map dataOf(Map e) => e['data'] as Map;
  Map firstSide(Map e) => (dataOf(e)['sides'] as List).first as Map;
  void refuse(String id, bool on) {
    box.socks.refuse.removeWhere((f) => f('dns-check/dns-$id-udp1') && !on);
    if (on) box.socks.refuse.add((u) => u == 'dns-check/dns-$id-udp1');
  }

  test('a failure with a spare: one dns/switched (warn) with names, silent transports and the structured cause "itself"; the answer back is info and opens it', () async {
    await start();
    refuse('g', true);
    await _until(() => dns('switched').isNotEmpty, time, 'the failover switch');
    final e = dns('switched').first;
    expect(e['level'], 'warn');
    final d = dataOf(e);
    expect(d['reason'], 'failover');
    expect(d['same'], isA<bool>());
    final s = firstSide(e);
    expect(s['side'], 'direct');
    expect(s['from'], containsPair('name', 'AdGuard'));
    expect((s['from'] as Map)['silent'], isNotEmpty);
    expect(s['to'], containsPair('name', 'Quad'));
    expect(s['to'], containsPair('ms', isA<int>()));
    expect(d.containsKey('route'), isFalse, reason: 'no VPN side involved: no Route');
    expect(d['cause'], containsPair('kind', 'itself'));
    expect(d['cause'], containsPair('a', 'AdGuard'));
    expect(d['cause'], containsPair('b', 'Quad'));
    expect(jsonEncode(d), isNot(contains('dns1')), reason: 'a name from the settings, never the id');
    expect(dns('failed'), isEmpty);
    expect(dns('failedOnNode'), isEmpty);
    expect(dns('down'), isEmpty, reason: 'there was a spare');

    refuse('g', false);
    await _until(() => dns('switched').any((x) => dataOf(x)['reason'] == 'back'), time, 'the switch back');
    final back = dns('switched').firstWhere((x) => dataOf(x)['reason'] == 'back');
    expect(back['level'], 'info');
    expect(back['opens'], e['id']);
  });

  test('nothing to switch to: dns/down (error) keeps the selection, no dns/switched; the answer is dns/up (info) that opens the down with afterMs', () async {
    await start();
    refuse('g', true);
    refuse('h', true);
    await _until(() => dns('down').isNotEmpty, time, 'dns/down');
    final down = dns('down').first;
    expect(down['level'], 'error');
    final s = firstSide(down);
    expect(s['side'], 'direct');
    expect(s['selected'], isNotEmpty);
    expect([for (final x in (s['servers'] as List).cast<Map>()) x['name']], containsAll(['AdGuard', 'Quad']));
    expect(dataOf(down)['noSpare'], isA<bool>());
    expect(dataOf(down).containsKey('cause'), isTrue, reason: 'every DNS event has a cause; without an external one: none');
    expect(dns('switched'), isEmpty, reason: 'silent servers are not switched between');
    expect(dns('failed'), isEmpty);
    // the same outage later is the same event (counted), not a second dns/down
    await time.advanceSeconds(120);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(dns('down'), hasLength(1));

    refuse('h', false);
    await _until(() => dns('up').isNotEmpty, time, 'dns/up');
    final up = dns('up').first;
    expect(up['level'], 'info');
    expect(up['opens'], down['id']);
    expect(dataOf(up)['afterMs'], allOf(isA<int>(), greaterThan(0)));
    expect(firstSide(up), containsPair('name', 'Quad'));
  });

  test('the only server silent: dns/down says noSpare, nothing is switched', () async {
    await start(spare: false);
    refuse('g', true);
    await _until(() => dns('down').isNotEmpty, time, 'dns/down');
    expect(dataOf(dns('down').first)['noSpare'], isTrue);
    expect(dns('switched'), isEmpty);
  });

  test('a network change window: the DNS switch is a block of net/switched (data.dns), not an event of its own; none lost', () async {
    await start();
    final t = DateTime.now().millisecondsSinceEpoch;
    svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'n1', 'at': t});
    await time.advanceSeconds(10);
    // the network moves, and in the same window the server answers no more
    svc.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': 'n2', 'at': t + 1});
    refuse('g', true);
    await _until(() => dns('switched').isNotEmpty || all().any((e) => e['type'] == 'switched' && e['cat'] == 'net' && dataOf(e).containsKey('dns')), time,
        'the DNS change told somewhere');
    await time.advanceSeconds(30);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final nets = all().where((e) => e['cat'] == 'net' && e['type'] == 'switched').toList();
    final inNet = nets.where((e) => dataOf(e).containsKey('dns')).toList();
    if (nets.isNotEmpty) {
      // the network switched: the DNS change belongs to it and is not an event of its own
      expect(inNet, hasLength(1), reason: 'the DNS change is in net/switched');
      final blk = dataOf(inNet.single)['dns'] as Map;
      expect(blk['switches'], isNotEmpty);
      expect(blk['same'], isA<bool>());
      expect(blk['transports'], isA<List>());
      expect(dns('switched'), isEmpty, reason: 'no own event for what the network change caused');
    } else {
      // no net/switched resulted: nothing may be lost, the change is written on its own
      expect(dns('switched'), hasLength(1));
    }
  });
}
