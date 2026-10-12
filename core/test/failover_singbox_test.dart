// "If unavailable" live (fallback.dart) and the DNS failover (dns_failover.dart) with the
// real sing-box, on loopback only: a shadowsocks "server" (a second sing-box) in front of a
// local HTTP target, two fake UDP DNS servers, our client config with the selectors and the
// clash-mode DNS rules, the checks through the probe inbound. Nothing leaves the machine.
// Skipped when the binary is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

/// A UDP DNS server answering every A query with 127.0.0.1 while [answering]; silent otherwise.
class _FakeDns {
  final names = <String>[];
  bool answering = true;
  late RawDatagramSocket sock;
  int get port => sock.port;

  static Future<_FakeDns> start() async {
    final d = _FakeDns();
    d.sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    d.sock.listen((e) {
      final dg = e == RawSocketEvent.read ? d.sock.receive() : null;
      if (dg == null || !d.answering) return;
      final q = dg.data;
      var i = 12;
      final labels = <String>[];
      while (q[i] != 0) {
        labels.add(String.fromCharCodes(q.sublist(i + 1, i + 1 + q[i])));
        i += q[i] + 1;
      }
      final qtype = (q[i + 1] << 8) | q[i + 2];
      if (qtype == 1) d.names.add(labels.join('.'));
      final r = BytesBuilder()
        ..add(q.sublist(0, 2))
        ..add([0x81, 0x80, 0, 1, 0, qtype == 1 ? 1 : 0, 0, 0, 0, 0])
        ..add(q.sublist(12, i + 5));
      if (qtype == 1) r.add([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1]);
      d.sock.send(r.toBytes(), dg.address, dg.port);
    });
    return d;
  }

  void close() => sock.close();
}

Map<String, dynamic> _ssServer(int port) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'dns': {
        'servers': [
          {'type': 'hosts', 'tag': 'hosts', 'predefined': {'target.test': '127.0.0.1', 'direct.test': '127.0.0.1'}},
        ],
      },
      'route': {'default_domain_resolver': 'hosts'},
    };

Map<String, dynamic> _group(List<Map<String, dynamic>> outbounds, String prefix) => {
      'pick': 'priority',
      'chosen': '$prefix::0',
      'nodes': [for (var i = 0; i < outbounds.length; i++) {'key': '$prefix::$i', 'outbound': outbounds[i]}],
    };

Map<String, dynamic> _rule(String id, Map<String, List<String>> v, {String target = '', String fallback = 'default', Map<String, List<String>>? ip}) => {
      'id': id,
      'name': id,
      'action': 'proxy',
      'target': target,
      'fallback': fallback,
      'dns': 'auto',
      'groups': {
        'domain': {'not': false, 'v': v},
        if (ip != null) 'ip': {'not': false, 'v': ip},
      },
    };

/// The system proxy as the daemon sees it, without the registry.
class _FakeSysProxy extends SystemProxy {
  _FakeSysProxy() : super(File('never-written'));

  @override
  bool get isSet => false;

  @override
  Future<String?> enable(int port) async => null;

  @override
  Future<void> restore() async {}
}

/// GET [host]:[port] through the mixed inbound as a plain HTTP proxy; null = no answer.
Future<String?> _get(int mixed, String host, int port) async {
  final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
  try {
    final res = await (await http.getUrl(Uri.parse('http://$host:$port/'))).close().timeout(const Duration(seconds: 4));
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode == 200 ? body : null;
  } catch (_) {
    return null;
  } finally {
    http.close(force: true);
  }
}

/// [_get] for a request that must open: a busy machine (the whole suite runs in parallel) may
/// drop the first one, so it is tried up to three times.
Future<String?> _getOk(int mixed, String host, int port) async {
  String? body;
  for (var i = 0; i < 3 && body == null; i++) {
    body = await _get(mixed, host, port);
  }
  return body;
}

Future<void> _untilSelected(SingBoxApi api) async {
  for (var i = 0; i < 60 && api.selected.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(api.selected, isNotEmpty, reason: 'sing-box never told its groups');
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-failover'));
  tearDown(() => tmp.delete(recursive: true));

  test('SetClashMode works with no clash_api block: the DNS rule of the mode picks the server', () async {
    final a = await _FakeDns.start(), b = await _FakeDns.start();
    final sb = SingBoxProcess(_bin, p.join(tmp.path, 'sb'));
    try {
      final mixed = await freePort();
      await sb.start({
        'log': {'level': 'warn'},
        'dns': {
          'servers': [
            {'type': 'udp', 'tag': 'dns-a', 'server': '127.0.0.1', 'server_port': a.port},
            {'type': 'udp', 'tag': 'dns-b', 'server': '127.0.0.1', 'server_port': b.port},
          ],
          'rules': [
            {'clash_mode': 'dns-a', 'action': 'route', 'server': 'dns-a'},
            {'clash_mode': 'dns-b', 'action': 'route', 'server': 'dns-b'},
          ],
          'final': 'dns-a',
        },
        'inbounds': [
          {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': mixed},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {'action': 'resolve'},
          ],
          'final': 'direct',
          'default_domain_resolver': 'dns-a',
        },
      });
      final api = sb.api!;
      expect((await api.clashMode())?.modes, containsAll(['dns-a', 'dns-b']));
      await _get(mixed, 'one.test', 9);
      expect(a.names, ['one.test'], reason: 'the first server is the default');
      expect(b.names, isEmpty);
      expect(await api.setClashMode('dns-b'), isTrue);
      expect((await api.clashMode())?.current, 'dns-b');
      await _get(mixed, 'two.test', 9);
      expect(b.names, ['two.test']);
      expect(await api.setClashMode('dns-a'), isTrue);
      await _get(mixed, 'three.test', 9);
      expect(a.names, ['one.test', 'three.test']);
    } finally {
      await sb.stop();
      a.close();
      b.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('a rule\'s target that dies goes to its fallback and back, live', () async {
    final dns = await _FakeDns.start();
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final ssPort = await freePort(), mixed = await freePort();
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server')), client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    FallbackService? svc;
    try {
      await server.start(_ssServer(ssPort));
      final probe = Probe(await freePort());
      final info = RoutingInfo();
      final plan = {
        'kind': 'unit',
        'main': _group([{'type': 'direct'}], 'main'),
        'mixedPort': mixed,
        'routing': {
          'dns': {
            'servers': [
              {'id': 'a', 'addr': 'udp://127.0.0.1:${dns.port}', 'via': 'direct', 'on': true},
            ],
          },
          'targets': {
            'src:x': {
              'kind': 'unit',
              'main': _group([
                {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': ssPort, 'method': 'aes-128-gcm', 'password': 'loopback'},
              ], 'x'),
            },
          },
          'rules': [
            _rule('r1', {'domain_suffix': ['target.test']}, target: 'src:x', fallback: 'block'),
            _rule('r2', {'domain_suffix': ['direct.test']}, target: 'src:x', fallback: 'direct'),
          ],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      await client.start(buildConfig(plan, probe: probe, info: info));
      final api = client.api!;
      await _untilSelected(api);
      expect((await api.deprecatedWarnings()).where((w) => w.contains('block')), isEmpty, reason: 'block in a selector is not deprecated');
      expect(info.fallbacks.map((f) => f.tag), ['src:x~block', 'src:x~direct']);
      final url = 'http://127.0.0.1:${target.port}/';
      svc = FallbackService(api, info.fallbacks,
          delay: probe.delayTest,
          settings: AutoSettings(failAfter: 2, flapGuard: false, url: url, timeoutMs: 2000, stallAfter: const Duration(milliseconds: 200)));
      final changes = <FallbackChange>[];
      svc.changes.listen(changes.add);

      await svc.check();
      expect(svc.isDown('src:x'), isFalse);
      expect(await _getOk(mixed, 'target.test', target.port), 'hello');
      expect(await _getOk(mixed, 'direct.test', target.port), 'hello');

      await server.stop();
      await svc.check();
      expect(svc.isDown('src:x'), isFalse, reason: 'one miss');
      await svc.check();
      expect(svc.isDown('src:x'), isTrue);
      expect([api.selected['src:x~block'], api.selected['src:x~direct']], ['block', 'direct']);
      expect(await _get(mixed, 'target.test', target.port), isNull, reason: 'Block');
      expect(await _getOk(mixed, 'direct.test', target.port), 'hello', reason: 'Direct: the dead target no longer matters');
      await Future<void>.delayed(Duration.zero);
      expect([for (final c in changes) '${c.to} ${c.back}'], ['block false', 'direct false']);

      await server.start(_ssServer(ssPort));
      await svc.check();
      expect(svc.isDown('src:x'), isTrue, reason: 'one answer is not enough');
      await svc.check();
      expect(svc.isDown('src:x'), isFalse);
      expect([api.selected['src:x~block'], api.selected['src:x~direct']], ['src:x', 'src:x']);
      expect(await _getOk(mixed, 'target.test', target.port), 'hello');
      await Future<void>.delayed(Duration.zero);
      expect(changes.map((c) => c.back), [false, false, true, true]);
    } finally {
      svc?.stop();
      await client.stop();
      await server.stop();
      await target.close(force: true);
      dns.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('daemon: rules/fallback and dns/switched events, status.dns, POST /api/dns/auto puts the first server back', () async {
    final a = await _FakeDns.start(), b = await _FakeDns.start();
    a.answering = false;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final deadPort = await freePort(), mixed = await freePort();
    final daemon = Daemon(
      singBox: _bin,
      dataDir: p.join(tmp.path, 'data'),
      uiFile: p.join(tmp.path, 'none.html'),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sysProxy: _FakeSysProxy(),
    );
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen(daemon.handle);
    Future<Map<String, dynamic>> call(String path, [Map<String, dynamic>? body]) async {
      final c = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final req = await c.openUrl(body == null ? 'GET' : 'POST', Uri.parse('http://127.0.0.1:${api.port}$path'));
        req.headers.set('X-Jorm', '1');
        if (body != null) req.write(jsonEncode(body));
        final res = await req.close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>();
      } finally {
        c.close(force: true);
      }
    }

    Future<List<Map>> events(String cat) async => [
          for (final e in (await call('/api/events'))['events'] as List)
            if ((e as Map)['cat'] == cat) e,
        ];
    try {
      final st = await call('/api/connect', {
        'plan': {
          'routes': [
            {'id': 'A', 'kind': 'unit', 'main': _group([{'type': 'direct'}], 'a')},
          ],
          'mixedPort': mixed,
          'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
          'auto': {'failAfter': 1, 'checkers': <String>[], 'retryPause': 0.1, 'flapGuard': false},
          'routing': {
            'dns': {
              'servers': [
                {'id': 'a', 'addr': 'udp://127.0.0.1:${a.port}', 'via': 'direct', 'on': true},
                {'id': 'b', 'addr': 'udp://127.0.0.1:${b.port}', 'via': 'direct', 'on': true},
              ],
            },
            'targets': {
              // its only server is a shadowsocks server nobody listens on
              'src:dead': {
                'kind': 'unit',
                'main': _group([
                  {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': deadPort, 'method': 'aes-128-gcm', 'password': 'x'},
                ], 'd'),
              },
            },
            'rules': [
              _rule('r1', {'domain_suffix': ['dead.test']}, target: 'src:dead', fallback: 'block')..['name'] = 'Dead rule',
            ],
            'quick': {'lan': false, 'final': 'proxy'},
          },
        },
        'systemProxy': false,
        'dnsAuto': true,
      });
      expect(st['connected'], isTrue);
      expect((st['dns'] as Map)['active'], 'a');
      expect((st['network'] as Map)['status'], 'up', reason: 'the probe pool\'s network status is in /api/status');
      List<Map> fell = [], moved = [];
      for (var i = 0; i < 100 && (fell.isEmpty || moved.isEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        fell = await events('rules');
        moved = await events('dns');
      }
      expect(fell, hasLength(1));
      expect([fell.single['type'], fell.single['level']], ['fallback', 'warn']);
      expect(fell.single['data'], {'rule': 'Dead rule', 'target': 'src:dead', 'to': 'block'});
      // the Sentinel confirms the server down (dns/failed), then the failover moves on its verdict
      expect(moved.map((e) => e['type']), ['failed', 'switched']);
      expect(moved.first['data'], containsPair('server', 'a'));
      final sw = moved.last;
      expect([sw['type'], sw['level'], sw['own']], ['switched', 'info', false]);
      expect(sw['data'], {'from': 'a', 'to': 'b', 'reason': 'failover'});
      var dns = (await call('/api/status'))['dns'] as Map;
      expect([dns['active'], dns['auto']], ['b', true]);
      // the servers in use; the watched-only ones (the system resolver) follow with `watched: true`
      final inUse = [for (final s in dns['servers'] as List) if ((s as Map)['watched'] != true) s];
      expect(inUse.map((s) => (s as Map)['ok']), [false, true]);
      expect((dns['servers'] as List).where((s) => (s as Map)['watched'] == true).map((s) => (s as Map)['id']), contains('system'));
      expect(await _get(mixed, 'dead.test', target.port), isNull, reason: 'Block');

      // Switch automatically off: the first server is back at once
      await call('/api/dns/auto', {'auto': false});
      dns = (await call('/api/status'))['dns'] as Map;
      expect([dns['active'], dns['auto']], ['a', false]);
      moved = await events('dns');
      expect(moved.last['data'], {'from': 'b', 'to': 'a', 'reason': 'off'});
      expect(moved.last['own'], isTrue);
    } finally {
      await daemon.shutdown();
      await api.close(force: true);
      await target.close(force: true);
      a.close();
      b.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('the DNS failover: a check per server through the probe, the mode moves to the one that answers and back', () async {
    final a = await _FakeDns.start(), b = await _FakeDns.start();
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final mixed = await freePort();
    final sb = SingBoxProcess(_bin, p.join(tmp.path, 'sb'));
    DnsFailover? fo;
    final sentinel = Sentinel(settle: Duration.zero)..context.started();
    try {
      final probe = Probe(await freePort());
      final info = RoutingInfo();
      final plan = {
        'kind': 'unit',
        'main': _group([{'type': 'direct'}], 'main'),
        'mixedPort': mixed,
        'routing': {
          'dns': {
            'servers': [
              {'id': 'a', 'addr': 'udp://127.0.0.1:${a.port}', 'via': 'direct', 'on': true},
              {'id': 'b', 'addr': 'udp://127.0.0.1:${b.port}', 'via': 'direct', 'on': true},
            ],
          },
          'targets': {
            'src:x': {'kind': 'unit', 'main': _group([{'type': 'direct'}], 'x')},
          },
          // a name that needs a DNS answer before the IP rule (the DNS list decides which server)
          'rules': [
            _rule('r1', {'domain_keyword': ['viaip']}, target: 'src:x', ip: {'ip_cidr': ['127.0.0.0/8']}),
          ],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      await sb.start(buildConfig(plan, probe: probe, info: info));
      final api = sb.api!;
      expect(info.dnsServers.map((s) => s.tag), ['dns-a', 'dns-b']);
      expect((await api.clashMode())?.modes, containsAll(['dns-a', 'dns-b']));

      // the check goes through one server alone
      expect(await probeDns(probe, 'dns-a', 'cp.cloudflare.com', timeoutMs: 2000), greaterThanOrEqualTo(0));
      expect(a.names, ['cp.cloudflare.com']);
      expect(b.names, isEmpty, reason: 'the other server was not asked');
      expect(await probeDns(probe, 'dns-b', 'www.gstatic.com', timeoutMs: 2000), greaterThanOrEqualTo(0));
      expect(b.names, ['www.gstatic.com']);
      // a server that is silent is a miss, a name that does not resolve too
      a.answering = false;
      expect(await probeDns(probe, 'dns-a', 'cp.cloudflare.com', timeoutMs: 1500), -1);
      a.answering = true;
      a.names.clear();
      b.names.clear();

      // the Sentinel judges the misses (no window here: its own check confirms), the failover acts on its verdicts
      fo = DnsFailover(info.dnsServers,
          setMode: api.setClashMode,
          query: (tag, name, t) => probeDns(probe, tag, name, timeoutMs: t),
          sentinel: sentinel,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, timeoutMs: 1500));
      final moves = <DnsSwitch>[];
      fo.switches.listen(moves.add);

      await fo.check();
      expect(fo.active, 'a');
      expect((fo.toJson()['servers'] as List).map((s) => (s as Map)['ok']), [true, true]);
      expect(await _getOk(mixed, 'viaip1.test', target.port), 'hello');
      expect(a.names, contains('viaip1.test'));

      a.answering = false;
      await fo.check();
      for (var i = 0; i < 400 && fo.active != 'b'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50)); // the Sentinel's checks take their time
      }
      expect(fo.active, 'b');
      expect(sentinel.roots.byKey('dns|a'), isNotNull);
      expect((await api.clashMode())?.current, 'dns-b');
      expect((fo.toJson()['servers'] as List).first, containsPair('ok', false));
      expect(await _getOk(mixed, 'viaip2.test', target.port), 'hello');
      expect(b.names, contains('viaip2.test'), reason: 'the DNS list now goes through b');
      expect(a.names, isNot(contains('viaip2.test')));

      a.answering = true;
      await fo.check();
      expect(fo.active, 'b');
      await fo.check();
      expect(fo.active, 'a');
      expect((await api.clashMode())?.current, 'dns-a');
      expect(await _getOk(mixed, 'viaip3.test', target.port), 'hello');
      expect(a.names, contains('viaip3.test'));
      await Future<void>.delayed(Duration.zero);
      expect([for (final m in moves) '${m.from}>${m.to} ${m.reason}'], ['a>b failover', 'b>a back']);
    } finally {
      fo?.stop();
      sentinel.dispose();
      await sb.stop();
      await target.close(force: true);
      a.close();
      b.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
}
