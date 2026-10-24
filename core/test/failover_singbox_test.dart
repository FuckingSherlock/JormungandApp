// "If unavailable" live (fallback.dart) and the DNS failover (dns_failover.dart) with the
// real sing-box, on loopback only: a shadowsocks "server" (a second sing-box) in front of a
// local HTTP target, two fake UDP DNS servers, our client config with the selectors and the
// DNS flag rule sets, the checks through the probe inbound. Nothing leaves the machine.
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

/// A UDP DNS server answering every A query with 127.0.0.1 while [answering]; silent otherwise. [names]: the A queries
/// it answered, [seen]: every A query that reached it, answered or not.
class _FakeDns {
  final names = <String>[];
  final seen = <String>[];
  bool answering = true;
  late RawDatagramSocket sock;
  int get port => sock.port;

  static Future<_FakeDns> start() async {
    final d = _FakeDns();
    d.sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    d.sock.listen((e) {
      final dg = e == RawSocketEvent.read ? d.sock.receive() : null;
      if (dg == null) return;
      final q = dg.data;
      var i = 12;
      final labels = <String>[];
      while (q[i] != 0) {
        labels.add(String.fromCharCodes(q.sublist(i + 1, i + 1 + q[i])));
        i += q[i] + 1;
      }
      final qtype = (q[i + 1] << 8) | q[i + 2];
      if (qtype == 1) d.seen.add(labels.join('.'));
      if (!d.answering) return;
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

/// Fresh `[stem]N.test` names through the proxy until [dns] was asked one of them (a rewritten flag file reaches
/// sing-box a moment later); false after 6 s.
Future<bool> _reached(int mixed, String stem, int port, _FakeDns dns) async {
  final t = Stopwatch()..start();
  for (var n = 0; t.elapsed < const Duration(seconds: 6); n++) {
    await _get(mixed, '$stem$n.test', port);
    if (dns.names.any((s) => s.startsWith(stem))) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

Future<void> _untilSelected(SingBoxApi api) async {
  for (var i = 0; i < 60 && api.selected.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(api.selected, isNotEmpty, reason: 'sing-box never told its groups');
}

/// One sing-box "server" with a shadowsocks inbound per port.
Map<String, dynamic> _ssServers(List<int> ports) => {
      ..._ssServer(ports.first),
      'inbounds': [
        for (final port in ports) {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      ],
    };

/// The client sing-box that keeps the configs it was started with.
class _Spy extends SingBoxProcess {
  _Spy(super.binary, super.workDir);
  final configs = <Map<String, dynamic>>[];

  @override
  Future<void> start(Map<String, dynamic> config) {
    configs.add(config);
    return super.start(config);
  }

  /// The server the last config starts the selector [tag] on.
  String? defaultOf(String tag) {
    for (final o in (configs.last['outbounds'] as List).cast<Map>()) {
      if (o['tag'] == tag) return o['default'] as String?;
    }
    return null;
  }
}

/// A runner over a [SingBoxProcess] that a second core can take over (Android's way): [leave] keeps the process
/// alive when this core stops; [attached] false = adopt() has not found it yet.
class _Handover implements AdoptableRunner {
  _Handover(this.inner, this.shared, {required this.attached});
  final SingBoxProcess inner;
  final Map<String, dynamic> shared; // the record
  bool attached, leave = false;

  @override
  bool get running => attached && inner.running;
  @override
  int? get pid => inner.pid;
  @override
  SingBoxApi? get api => attached ? inner.api : null;
  @override
  void Function(String line)? get onLog => inner.onLog;
  @override
  set onLog(void Function(String line)? f) => inner.onLog = f;
  @override
  void Function(int code)? get onExit => inner.onExit;
  @override
  set onExit(void Function(int code)? f) => inner.onExit = f;
  @override
  void note(String line) => inner.note(line);
  @override
  Future<void> start(Map<String, dynamic> config) => inner.start(config);
  @override
  Future<void> stop() => leave ? Future<void>.value() : inner.stop();
  @override
  Future<void> keep(Map<String, dynamic> record) async => shared['record'] = record;
  @override
  Future<Map<String, dynamic>?> adopt() async {
    if (!inner.running) return null;
    attached = true;
    return shared['record'] as Map<String, dynamic>?;
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-failover'));
  tearDown(() => tmp.delete(recursive: true));

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
      final cfg = buildConfig(plan, probe: probe, info: info, dnsFlagDir: p.join(tmp.path, 'flags'));
      writeDnsFlags(info.dnsCandidates);
      for (final f in info.fallbacks) {
        if (f.flagPath != null) setFallbackFlag(f, false);
      }
      await client.start(cfg);
      final api = client.api!;
      await _untilSelected(api);
      expect((await api.deprecatedWarnings()).where((w) => w.contains('block')), isEmpty, reason: 'block in a selector is not deprecated');
      expect(info.fallbacks.map((f) => f.tag), ['src:x~block', 'src:x~direct']);
      final url = 'http://127.0.0.1:${target.port}/';
      svc = FallbackService(api, info.fallbacks,
          delay: probe.delayTest,
          pool: ProbePool.solo(ladder: DeadLadder(steps: const [Duration.zero])), // the dead target is asked every round (the ladder: ladder_test.dart)
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

  test('the Direct fallback flag: on = the rule\'s names are resolved by the DNS ladder, off = nothing of the rule is resolved locally', () async {
    final dns = await _FakeDns.start();
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final ssPort = await freePort(), mixed = await freePort();
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server')), client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    try {
      await server.start(_ssServer(ssPort));
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
          'rules': [_rule('r1', {'domain_suffix': ['fb.test']}, target: 'src:x', fallback: 'direct')],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      final cfg = buildConfig(plan, probe: Probe(await freePort()), info: info, dnsFlagDir: p.join(tmp.path, 'flags'));
      writeDnsFlags(info.dnsCandidates);
      final fb = info.fallbacks.single;
      expect(fb.tag, 'src:x~direct');
      setFallbackFlag(fb, false);
      await client.start(cfg);

      bool asked(String stem) => dns.seen.any((s) => s.startsWith(stem));
      // off: the selector sits on the target, the names go to the server as they are
      for (var n = 0; n < 4; n++) {
        await _get(mixed, 'off$n.fb.test', 1);
      }
      expect(asked('off'), isFalse, reason: 'flag off: no local resolve of the rule\'s names; seen ${dns.seen}');
      // on: the ladder answers them (the flag file is read by sing-box a moment after the rewrite)
      setFallbackFlag(fb, true);
      var on = false;
      for (var n = 0; n < 100 && !on; n++) {
        await _get(mixed, 'on$n.fb.test', 1);
        on = asked('on');
        if (!on) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(on, isTrue, reason: 'flag on: the ladder resolves the names; seen ${dns.seen}');
      // off again: back to nothing
      setFallbackFlag(fb, false);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      dns.seen.clear();
      for (var n = 0; n < 4; n++) {
        await _get(mixed, 'back$n.fb.test', 1);
      }
      expect(asked('back'), isFalse, reason: 'flag off again; seen ${dns.seen}');
    } finally {
      await client.stop();
      await server.stop();
      await target.close(force: true);
      dns.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('daemon: rules/fallback and dns/failed events, status.dns, POST /api/dns/auto', () async {
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
      expect((st['dns'] as Map)['active'], 'a-udp1');
      expect((st['network'] as Map)['status'], 'up', reason: 'the probe pool\'s network status is in /api/status');
      List<Map> fell = [], moved = [];
      for (var i = 0; i < 100 && (fell.isEmpty || moved.length < 2); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        fell = await events('rules');
        moved = await events('dns');
      }
      expect(fell, hasLength(1));
      expect([fell.single['type'], fell.single['level']], ['fallback', 'warn']);
      expect(fell.single['data'], {'rule': 'Dead rule', 'target': 'src:dead', 'to': 'block'});
      // the miss turns the flag off and the side moves to the other at once: one dns/switched (the Sentinel's verdict
      // adds no dns/failed any more)
      expect(moved.map((e) => e['type']), ['switched']);
      final md = moved.single['data'] as Map;
      expect(md['reason'], 'failover');
      final ms = (md['sides'] as List).cast<Map>().single;
      expect([ms['side'], (ms['from'] as Map)['provider'], (ms['to'] as Map)['provider']], ['direct', 'a', 'b']);
      expect(md.containsKey('fromProvider') || md.containsKey('server'), isFalse, reason: 'the old flat fields are gone');
      var dns = (await call('/api/status'))['dns'] as Map;
      expect([dns['active'], dns['auto']], ['b-udp1', true]);
      expect((dns['sides'] as Map)['direct'], {'active': 'b-udp1', 'provider': 'b'});
      // the servers in use; the watched-only ones (the system resolver) follow with `watched: true`
      final inUse = [for (final s in dns['servers'] as List) if ((s as Map)['watched'] != true) s];
      expect(inUse.map((s) => s['ok']), [false, true]);
      expect((dns['servers'] as List).where((s) => (s as Map)['watched'] == true).map((s) => (s as Map)['id']), contains('system'));
      expect(await _get(mixed, 'dead.test', target.port), isNull, reason: 'Block');

      // Switch automatically off
      await call('/api/dns/auto', {'auto': false});
      dns = (await call('/api/status'))['dns'] as Map;
      expect([dns['active'], dns['auto']], ['a-udp1', false], reason: 'off: every flag on again, the first one answers');
      final off = await events('dns');
      expect(off.last['type'], 'switched');
      expect(off.last['data'], containsPair('reason', 'off'));
    } finally {
      await daemon.shutdown();
      await api.close(force: true);
      await target.close(force: true);
      a.close();
      b.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('the DNS failover: a check per server through the probe, the flags move the answers to the one that answers and back', () async {
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
      final flags = p.join(tmp.path, 'flags');
      final cfg = buildConfig(plan, probe: probe, info: info, dnsFlagDir: flags);
      writeDnsFlags(info.dnsCandidates); // sing-box does not start with a flag file missing
      await sb.start(cfg);
      final ta = info.dnsServers[0].tag, tb = info.dnsServers[1].tag;
      expect(info.dnsServers.map((s) => s.id), ['a-udp1', 'b-udp1']);

      // the check goes through one server alone
      expect(await probeDns(probe, ta, 'cp.cloudflare.com', timeoutMs: 2000), greaterThanOrEqualTo(0));
      expect(a.names, ['cp.cloudflare.com']);
      expect(b.names, isEmpty, reason: 'the other server was not asked');
      expect(await probeDns(probe, tb, 'www.gstatic.com', timeoutMs: 2000), greaterThanOrEqualTo(0));
      expect(b.names, ['www.gstatic.com']);
      // a server that is silent is a miss, a name that does not resolve too
      a.answering = false;
      expect(await probeDns(probe, ta, 'cp.cloudflare.com', timeoutMs: 1500), -1);
      a.answering = true;
      a.names.clear();
      b.names.clear();

      // the Sentinel judges the misses (no window here: its own check confirms), the failover acts on its verdicts
      // and writes the flags; sing-box is asked back which candidate answers the side (the flagcheck name)
      final notes = <String>[];
      fo = DnsFailover(
          sides: info.dnsSides,
          candidates: info.dnsCandidates,
          watch: info.dnsExtra,
          setFlag: (c, on, reason) async {
            setDnsFlag(c, on, reason: reason);
            return true;
          },
          flagCheck: (c) => probeFlag(probe, c.tag, dnsFlagcheckName(c.side)),
          query: (tag, name, t) => probeDns(probe, tag, name, timeoutMs: t),
          sentinel: sentinel,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, timeoutMs: 1500),
          note: (level, line) => notes.add('$level $line'));
      final moves = <DnsSwitch>[];
      fo.switches.listen(moves.add);
      final ca = info.dnsCandidates.firstWhere((c) => c.id == 'a-udp1'), cb = info.dnsCandidates.firstWhere((c) => c.id == 'b-udp1');
      Future<bool?> flagOf(DnsCandidate c) => probeFlag(probe, c.tag, dnsFlagcheckName(c.side));
      expect([await flagOf(ca), await flagOf(cb)], [true, false], reason: 'every flag on: the top candidate answers the flagcheck');

      await fo.check();
      expect(fo.active, 'a-udp1');
      expect((fo.toJson()['servers'] as List).map((s) => (s as Map)['ok']), [true, true, true], reason: 'the two in use, then the watched OS resolver');
      expect(await _getOk(mixed, 'viaip1.test', target.port), 'hello');
      expect(a.names, contains('viaip1.test'));

      a.answering = false;
      await fo.check();
      for (var i = 0; i < 400 && fo.active != 'b-udp1'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50)); // the Sentinel's checks take their time
      }
      expect(fo.active, 'b-udp1');
      // `active` moves with the write; sing-box applies the file a moment later (the flagcheck says when): a look-up
      // before that still goes to a
      for (var i = 0; i < 100 && !notes.any((n) => n.contains('dns flag check (direct): b-udp1 answers after')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(sentinel.roots.byKey('dns|a-udp1'), isNotNull);
      expect((fo.toJson()['servers'] as List).first, containsPair('ok', false));
      expect(await _reached(mixed, 'viaip2', target.port, b), isTrue, reason: 'the flag file moved the DNS list to b (sing-box watches it)');
      expect(a.seen.where((s) => s.startsWith('viaip2')), isEmpty, reason: 'a candidate that is off gets no real look-ups');
      expect([await flagOf(ca), await flagOf(cb)], [false, true], reason: 'the flagcheck names the effective candidate');
      expect(notes.where((n) => n.contains('dns flag check (direct): b-udp1 answers after')), isNotEmpty, reason: 'the write was verified and the delay logged');

      a.answering = true;
      await fo.check();
      expect(fo.active, 'b-udp1');
      await fo.check();
      expect(fo.active, 'a-udp1');
      expect(await _reached(mixed, 'viaip3', target.port, a), isTrue, reason: 'and back to a');
      await Future<void>.delayed(Duration.zero);
      expect(
        [for (final m in moves) for (final s in m.sides) '${s.side} ${s.from.provider}>${s.to.provider}/${s.to.kind} ${m.reason}'],
        ['direct a>b/udp failover', 'direct b>a/udp back'],
      );
      expect(notes.where((n) => n.startsWith('warn')), isEmpty, reason: notes.join('\n'));
    } finally {
      fo?.stop();
      sentinel.dispose();
      await sb.stop();
      await target.close(force: true);
      a.close();
      b.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  for (final pick in ['fastest', 'priority']) {
    test('connect: $pick group whose first server is dead — right after connect the traffic goes through the live one', () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((r) => r.response
        ..write('hello')
        ..close());
      final ssPort = await freePort(), deadPort = await freePort(), mixed = await freePort();
      final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
      final daemon = Daemon(
        singBox: _bin,
        dataDir: p.join(tmp.path, 'data'),
        uiFile: p.join(tmp.path, 'none.html'),
        exitCheck: (_) async => {'ip': '127.0.0.1'},
        sysProxy: _FakeSysProxy(),
      );
      final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api.listen(daemon.handle);
      try {
        await server.start(_ssServer(ssPort));
        final c = HttpClient()..findProxy = (_) => 'DIRECT';
        final req = await c.openUrl('POST', Uri.parse('http://127.0.0.1:${api.port}/api/connect'));
        req.headers.set('X-Jorm', '1');
        req.write(jsonEncode({
          'plan': {
            'routes': [
              {
                'id': 'A',
                'kind': 'unit',
                'main': {
                  'pick': pick,
                  'chosen': 'a::0', // the app's hint: the dead one
                  'nodes': [
                    {'key': 'a::0', 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': deadPort, 'method': 'aes-128-gcm', 'password': 'x'}},
                    {'key': 'a::1', 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': ssPort, 'method': 'aes-128-gcm', 'password': 'loopback'}},
                  ],
                },
              },
            ],
            'mixedPort': mixed,
            'global': true,
            'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
            'auto': {'checkers': <String>[], 'flapGuard': false},
          },
          'systemProxy': false,
        }));
        final res = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as Map;
        c.close(force: true);
        expect(res['connected'], isTrue, reason: '$res');
        // no waiting for Auto's first round: the connect itself found the live server
        expect(await _getOk(mixed, 'target.test', target.port), 'hello', reason: 'traffic through the live server right after connect');
      } finally {
        await daemon.shutdown();
        await api.close(force: true);
        await server.stop();
        await target.close(force: true);
      }
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
  }

  Map<String, dynamic> ss(int port) => {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'};
  List<String> lines(Daemon d) => [for (final l in d.service.log(since: null)['lines'] as List) '${(l as Map)['msg']}'];

  test('connect: a chain whose first exit is dead — the exit is chosen through the chosen entry, traffic goes through the live one at once', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final entryPort = await freePort(), exitPort = await freePort(), deadPort = await freePort(), mixed = await freePort();
    final entry = SingBoxProcess(_bin, p.join(tmp.path, 'entry')), exit = SingBoxProcess(_bin, p.join(tmp.path, 'exit'));
    final daemon = Daemon(singBox: _bin, dataDir: p.join(tmp.path, 'data'), uiFile: p.join(tmp.path, 'none.html'), exitCheck: (_) async => {'ip': '127.0.0.1'}, sysProxy: _FakeSysProxy());
    try {
      await entry.start(_ssServer(entryPort));
      await exit.start(_ssServer(exitPort));
      final res = await daemon.service.connect({
        'plan': {
          'routes': [
            {
              'id': 'A',
              'kind': 'chain',
              'entry': _group([ss(entryPort)], 'e'),
              'main': _group([ss(deadPort), ss(exitPort)], 'x'), // priority; the app's hint: the dead one
            },
          ],
          'mixedPort': mixed,
          'global': true,
          'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
          'auto': {'checkers': <String>[], 'flapGuard': false},
        },
        'systemProxy': false,
      });
      expect(res['connected'], isTrue, reason: '$res');
      expect(await _getOk(mixed, 'target.test', target.port), 'hello', reason: 'through the live exit right after connect; ${lines(daemon).where((l) => l.contains('connect:')).join(' | ')}');
      expect(lines(daemon).where((l) => l.contains('connect: route0 priority')), isNotEmpty, reason: 'the exit group was checked');
    } finally {
      await daemon.shutdown();
      await entry.stop();
      await exit.stop();
      await target.close(force: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  // grace: how long the connect waits for the rule target after the route's own pick (null = the default); zero = the
  // target's pick is late and goes by `select` once sing-box runs
  for (final grace in [null, Duration.zero]) {
    test('connect: a rule target whose first server is dead ${grace == null ? 'is decided within the grace: the config starts it on the live one' : 'is picked late: `select` after the start, kept by the first look at the groups'}', () async {
      final dns = await _FakeDns.start();
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((r) => r.response
        ..write('hello')
        ..close());
      final ssPort = await freePort(), deadPort = await freePort(), mixed = await freePort();
      final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
      final daemon = Daemon(singBox: _bin, dataDir: p.join(tmp.path, 'data'), uiFile: p.join(tmp.path, 'none.html'), exitCheck: (_) async => {'ip': '127.0.0.1'}, sysProxy: _FakeSysProxy());
      if (grace != null) daemon.service.targetGrace = grace;
      try {
        await server.start(_ssServer(ssPort));
        final res = await daemon.service.connect({
          'plan': {
            'routes': [
              {'id': 'A', 'kind': 'unit', 'main': _group([{'type': 'direct'}], 'a')},
            ],
            'mixedPort': mixed,
            'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
            'auto': {'checkers': <String>[], 'flapGuard': false},
            'routing': {
              'dns': {
                'servers': [
                  {'id': 'a', 'addr': 'udp://127.0.0.1:${dns.port}', 'via': 'direct', 'on': true},
                ],
              },
              'targets': {
                'src:x': {'kind': 'unit', 'main': _group([ss(deadPort), ss(ssPort)], 'x')}, // the app's hint: the dead one
              },
              'rules': [_rule('r1', {'domain_suffix': ['target.test']}, target: 'src:x', fallback: 'block')],
              'quick': {'lan': false, 'final': 'proxy'},
            },
          },
          'systemProxy': false,
        });
        expect(res['connected'], isTrue, reason: '$res');
        final api = daemon.service.runner.api!;
        String? body;
        for (var i = 0; i < 100 && body == null; i++) {
          body = await _get(mixed, 'target.test', target.port);
          if (body == null) await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final log = lines(daemon);
        expect(body, 'hello', reason: log.where((l) => l.contains('connect:')).join(' | '));
        if (grace == null) {
          expect(await _getOk(mixed, 'target.test', target.port), 'hello', reason: 'at once, no waiting for a later move');
          expect(log.where((l) => l.contains('(late:')), isEmpty);
        } else {
          expect(log.where((l) => l.contains('connect: src:x') && l.contains('(late: applied after the start)')), isNotEmpty, reason: log.join('\n'));
        }
        // the first look at the groups (and later rounds) leave the pick alone
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(api.selected['src:x'], 'src:x/x::1');
        expect(await _getOk(mixed, 'target.test', target.port), 'hello');
      } finally {
        await daemon.shutdown();
        await server.stop();
        await target.close(force: true);
        dns.close();
      }
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
  }

  List<String> svcLines(CoreService s) => [for (final l in s.log(since: null)['lines'] as List) '${(l as Map)['msg']}'];

  test('a plan change over a running tunnel: the chain exit and the rule target stay on the servers the core moved them to, a target with only the app\'s hint is checked', () async {
    final dns = await _FakeDns.start();
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    final pe = await freePort(), pa = await freePort(), pb = await freePort(), pc = await freePort(), pd = await freePort();
    final py1 = await freePort(), py2 = await freePort(), mixed = await freePort();
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final spy = _Spy(_bin, p.join(tmp.path, 'client'));
    final svc = CoreService(singBox: _bin, dataDir: p.join(tmp.path, 'data'), runner: spy, sysProxy: _FakeSysProxy(), exitCheck: (_) async => {'ip': '127.0.0.1'});
    Map<String, dynamic> body({bool withY = false}) => {
          'plan': {
            'routes': [
              {'id': 'A', 'kind': 'chain', 'entry': _group([ss(pe)], 'e'), 'main': _group([ss(pa), ss(pb)], 'x')}, // the app's hint: the first exit
            ],
            'mixedPort': mixed,
            'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
            'auto': {'checkers': <String>[], 'flapGuard': false},
            'routing': {
              'dns': {
                'servers': [
                  {'id': 'a', 'addr': 'udp://127.0.0.1:${dns.port}', 'via': 'direct', 'on': true},
                ],
              },
              'targets': {
                'src:x': {'kind': 'unit', 'main': _group([ss(pc), ss(pd)], 'u')},
                if (withY) 'src:y': {'kind': 'unit', 'main': _group([ss(py1), ss(py2)], 'v')},
              },
              'rules': [
                _rule('r1', {'domain_suffix': ['target.test']}, target: 'src:x', fallback: 'block'),
                if (withY) _rule('r2', {'domain_suffix': ['y.test']}, target: 'src:y', fallback: 'block'),
              ],
              'quick': {'lan': false, 'final': 'proxy'},
            },
          },
          'systemProxy': false,
        };
    try {
      await server.start(_ssServers([pe, pb, pd, py1, py2])); // pa, pc: nothing listens (dead)
      await svc.init();
      var res = await svc.connect(body());
      expect(res['connected'], isTrue, reason: '$res');
      final api = spy.api!;
      await _untilSelected(api);
      // the connect's checks put the exit and the target on the live servers (the app's hint is the dead first one)
      for (var i = 0; i < 100 && (api.selected['route0'] != 'route0/x::1' || api.selected['src:x'] != 'src:x/u::1'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect([api.selected['route0'], api.selected['src:x']], ['route0/x::1', 'src:x/u::1']);
      await Future<void>.delayed(const Duration(seconds: 2));
      final checked = svcLines(svc).where((l) => l.startsWith('connect: route0 ') || l.startsWith('connect: src:x ')).length;
      expect(checked, greaterThan(0), reason: 'the first connect checked them');

      res = await svc.connect(body(withY: true)); // the plan change: a continuation, the app's chosen is x::0 / u::0 again
      expect(res['connected'], isTrue, reason: '$res');
      expect(spy.configs, hasLength(2));
      expect(spy.defaultOf('route0'), 'route0/x::1', reason: 'the exit the core is on');
      expect(spy.defaultOf('src:x'), 'src:x/u::1', reason: 'the target the core is on');
      expect(spy.defaultOf('route0-entry'), 'route0-entry/e::0');
      // the new target has no server of the core's: the app's hint is checked
      for (var i = 0; i < 100 && !svcLines(svc).any((l) => l.startsWith('connect: src:y ')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final log = svcLines(svc);
      expect(log.where((l) => l.startsWith('connect: src:y ')), isNotEmpty, reason: log.where((l) => l.contains('connect:')).join('\n'));
      expect(log.where((l) => l.startsWith('connect: route0 ') || l.startsWith('connect: src:x ')), hasLength(checked), reason: 'no new check of what the core holds');
    } finally {
      await svc.dispose();
      await server.stop();
      await target.close(force: true);
      dns.close();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('adopt: the groups and the route a taken-over sing-box stands on are not put back to the recorded plan', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response.close());
    final p1 = await freePort(), p2 = await freePort(), p3 = await freePort(), mixed = await freePort();
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final inner = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    final shared = <String, dynamic>{};
    final first = _Handover(inner, shared, attached: true), second = _Handover(inner, shared, attached: false);
    CoreService make(BoxRunner r) => CoreService(singBox: _bin, dataDir: p.join(tmp.path, 'data'), runner: r, sysProxy: _FakeSysProxy(), exitCheck: (_) async => {'ip': '127.0.0.1'});
    final a = make(first), b = make(second);
    try {
      await server.start(_ssServers([p1, p2, p3]));
      await a.init();
      final res = await a.connect({
        'plan': {
          'routes': [
            {'id': 'A', 'kind': 'unit', 'main': _group([ss(p1), ss(p2)], 'a')},
            {'id': 'B', 'kind': 'unit', 'main': _group([ss(p3)], 'b')},
          ],
          'mixedPort': mixed,
          'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
          'auto': {'checkers': <String>[], 'flapGuard': false},
        },
        'systemProxy': false,
      });
      expect(res['connected'], isTrue, reason: '$res');
      expect(shared['record'], isNotNull);
      final api = inner.api!;
      await _untilSelected(api);
      first.leave = true; // the app's engine goes, the tunnel stays
      await a.dispose();
      expect(inner.running, isTrue);
      // what the core before this one left behind (a heal): the second server of the group, the second route
      expect(await api.select('route0', 'route0/a::1'), isTrue);
      expect(await api.select('proxy', 'route1'), isTrue);
      for (var i = 0; i < 50 && (api.selected['route0'] != 'route0/a::1' || api.selected['proxy'] != 'route1'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect([api.selected['route0'], api.selected['proxy']], ['route0/a::1', 'route1']);

      final adopted = await b.adopt({});
      expect(adopted['adopted'], isTrue, reason: '$adopted');
      await Future<void>.delayed(const Duration(seconds: 3)); // the first look at the groups, and rounds after it
      expect([api.selected['route0'], api.selected['proxy']], ['route0/a::1', 'route1'], reason: svcLines(b).where((l) => l.contains('auto:')).join('\n'));
    } finally {
      await b.dispose();
      await inner.stop();
      await server.stop();
      await target.close(force: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
}
