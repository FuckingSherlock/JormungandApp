// How the DNS sides are built on the real sing-box (docs/rules.md §6, .claude_states/dns_spike.md): flag rule-sets
// (a local file per server, rewritten to move the answers) by hand and in a config built by buildConfig. Loopback
// only: mock DNS servers answer A queries with 127.0.K.K (K tells the server), a second sing-box stands in for the
// VPN, queries come in through a `direct` inbound with a hijack-dns rule (what TUN does). Skipped without the binary.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

/// A DNS server on loopback: every A query is answered 127.0.[k].[k] (TTL 30 s), the rest empty.
class _MockDns {
  _MockDns(this._sock, this.k) {
    _sock.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = _sock.receive();
      if (d == null || d.data.length < 17) return;
      queries++;
      final q = d.data;
      var i = 12;
      while (q[i] != 0) {
        i += q[i] + 1;
      }
      final qtype = (q[i + 1] << 8) | q[i + 2];
      final end = i + 5;
      final b = BytesBuilder()
        ..add([q[0], q[1], 0x81, 0x80, q[4], q[5], 0, qtype == 1 ? 1 : 0, 0, 0, 0, 0])
        ..add(q.sublist(12, end));
      if (qtype == 1) b.add([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 127, 0, k, k]);
      _sock.send(b.toBytes(), d.address, d.port);
    });
  }

  final RawDatagramSocket _sock;
  final int k;
  int queries = 0;

  static Future<_MockDns> start(String ip, int port, int k) async => _MockDns(await RawDatagramSocket.bind(InternetAddress(ip), port), k);
  void close() => _sock.close();
}

/// One A query to the hijacking inbound; the answer's address as `127.0.K.K`, null = no answer.
Future<String?> _ask(int port, String name) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final q = BytesBuilder()..add([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final l in name.split('.')) {
      q.add([l.length, ...ascii.encode(l)]);
    }
    q.add([0, 0, 1, 0, 1]);
    s.send(q.toBytes(), InternetAddress.loopbackIPv4, port);
    final got = Completer<Datagram?>();
    s.listen((e) {
      if (e == RawSocketEvent.read && !got.isCompleted) got.complete(s.receive());
    });
    final d = await got.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (d == null || d.data.length < 4 || d.data[7] == 0) return null;
    final r = d.data;
    return r.sublist(r.length - 4).join('.');
  } finally {
    s.close();
  }
}

const _nD = 3, _nV = 3;
int _kD(int i) => 10 + i;
int _kV(int j) => 100 + j;
Map<String, dynamic> _and(List<Map<String, dynamic>> items) => {'type': 'logical', 'mode': 'and', 'rules': items};

/// The client config around [dnsRules]: servers d0..d2 direct (loopback ports [dp]), v0..v2 through the
/// proxy stand-in (127.0.0.2, ports [vp]); queries in through `dns-in`, everything else answered by v0.
Map<String, dynamic> _client({
  required List<int> dp,
  required List<int> vp,
  required int dnsIn,
  required int ssPort,
  required List<Map<String, dynamic>> dnsRules,
  List<Map<String, dynamic>> ruleSets = const [],
  List<Map<String, dynamic>> extraOutbounds = const [],
  List<Map<String, dynamic>> extraRoutes = const [],
  int? mixed,
}) =>
    {
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'type': 'local', 'tag': 'local'},
          for (var i = 0; i < _nD; i++) {'type': 'udp', 'tag': 'd$i', 'server': '127.0.0.1', 'server_port': dp[i]},
          for (var j = 0; j < _nV; j++) {'type': 'udp', 'tag': 'v$j', 'server': '127.0.0.2', 'server_port': vp[j], 'detour': 'proxy'},
        ],
        'rules': dnsRules,
        'final': 'v0',
      },
      'inbounds': [
        {'type': 'direct', 'tag': 'dns-in', 'listen': '127.0.0.1', 'listen_port': dnsIn, 'network': 'udp', 'override_address': '1.1.1.1', 'override_port': 53},
        if (mixed != null) {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': mixed},
      ],
      'outbounds': [
        {'type': 'shadowsocks', 'tag': 'ss0', 'server': '127.0.0.1', 'server_port': ssPort, 'method': 'aes-128-gcm', 'password': 'loopback'},
        {'type': 'selector', 'tag': 'proxy', 'outbounds': ['ss0'], 'default': 'ss0'},
        {'type': 'direct', 'tag': 'direct'},
        ...extraOutbounds,
      ],
      'route': {
        'rules': [
          {'inbound': ['dns-in'], 'action': 'hijack-dns'},
          ...extraRoutes,
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
        'default_domain_resolver': 'local',
        if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      },
    };

Map<String, dynamic> _ssServer(int port) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {'type': 'shadowsocks', 'tag': 'ss-in', 'listen': '127.0.0.1', 'listen_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
    };

/// The lab: mock DNS servers on both sides, the VPN stand-in, the client under test.
class _Lab {
  final dns = <String, _MockDns>{}; // d0.., v0..
  final dp = <int>[], vp = <int>[];
  late final int dnsIn, ssPort;
  late final Directory tmp;
  late final SingBoxProcess server, client;

  Future<void> up() async {
    tmp = await Directory.systemTemp.createTemp('jorm-dns-sides');
    var taken = <int>{};
    Future<int> port() async => (await freePort(exclude: taken)).also(taken.add);
    for (var i = 0; i < _nD; i++) {
      final pt = await port();
      dp.add(pt);
      dns['d$i'] = await _MockDns.start('127.0.0.1', pt, _kD(i));
    }
    for (var j = 0; j < _nV; j++) {
      final pt = await port();
      vp.add(pt);
      dns['v$j'] = await _MockDns.start('127.0.0.2', pt, _kV(j));
    }
    dnsIn = await port();
    ssPort = await port();
    server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
    await server.start(_ssServer(ssPort));
  }

  /// "d1" / "v2" / null: which server answered [name].
  Future<String?> who(String name) async {
    final a = await _ask(dnsIn, name);
    if (a == null) return null;
    final k = int.parse(a.split('.')[2]);
    return k < 100 ? 'd${k - 10}' : 'v${k - 100}';
  }

  int asked(String tag) => dns[tag]!.queries;

  Future<void> down() async {
    await client.stop();
    await server.stop();
    for (final d in dns.values) {
      d.close();
    }
    await tmp.delete(recursive: true);
  }
}

extension on int {
  int also(void Function(int) f) {
    f(this);
    return this;
  }
}

void main() {
  test('flag rule-sets: a local file per server (enabled = match-all), the first enabled by priority is used, no restart', () async {
    final lab = _Lab();
    await lab.up();
    try {
      Future<void> flag(String tag, bool on) async {
        final f = File(p.join(lab.tmp.path, 'flag-$tag.json'));
        final tmp = File('${f.path}.tmp')
          ..writeAsStringSync(jsonEncode({
            'version': 3,
            'rules': [on ? {'domain_regex': ['.*']} : {'domain': ['never.invalid']}],
          }));
        await tmp.rename(f.path);
      }

      for (var i = 0; i < _nD; i++) {
        await flag('d$i', true);
      }
      for (var j = 0; j < _nV; j++) {
        await flag('v$j', true);
      }
      String path(String t) => p.join(lab.tmp.path, 'flag-$t.json');
      final rules = <Map<String, dynamic>>[
        for (var i = 0; i < _nD; i++)
          {
            ..._and([
              {'domain_suffix': ['dir.test']},
              {'rule_set': ['fd$i']},
            ]),
            'action': 'route',
            'server': 'd$i',
          },
        for (var j = 0; j < _nV; j++) {'rule_set': ['fv$j'], 'action': 'route', 'server': 'v$j'},
      ];
      final sets = <Map<String, dynamic>>[
        for (var i = 0; i < _nD; i++) {'type': 'local', 'tag': 'fd$i', 'format': 'source', 'path': path('d$i')},
        for (var j = 0; j < _nV; j++) {'type': 'local', 'tag': 'fv$j', 'format': 'source', 'path': path('v$j')},
      ];
      await lab.client.start(_client(dp: lab.dp, vp: lab.vp, dnsIn: lab.dnsIn, ssPort: lab.ssPort, dnsRules: rules, ruleSets: sets));

      Future<void> until(String name, String want) async {
        final t = Stopwatch()..start();
        var n = 0;
        while (t.elapsed < const Duration(seconds: 5)) {
          // a fresh name every time: no cache hides the rule's decision
          if (await lab.who('f${n++}.$name') == want) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('$name was not answered by $want within 5 s');
      }

      expect([await lab.who('a.dir.test'), await lab.who('a.other.test')], ['d0', 'v0']);
      await flag('d0', false); // server d0 judged dead: the next by priority takes over
      await until('dir.test', 'd1');
      expect(await lab.who('b.other.test'), 'v0', reason: 'the other side did not move');
      await flag('v0', false);
      await flag('v1', false);
      await until('other.test', 'v2');
      await flag('d0', true); // back
      await until('dir.test', 'd0');
      // no cache clear on a switch, but the cache is keyed by server: the name asked of d1 earlier is not answered from d0
      expect(await lab.who('a.dir.test'), 'd0');
    } finally {
      await lab.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('a built config: the flags pass sing-box check, the route resolve step follows the DNS rules, one flag file moves the answers', () async {
    final lab = _Lab();
    await lab.up();
    final web = <HttpServer>[];
    final sb = SingBoxProcess(_bin, p.join(lab.tmp.path, 'built'));
    try {
      final taken = {lab.dnsIn, lab.ssPort, ...lab.dp, ...lab.vp};
      final mixed = await freePort(exclude: taken);
      final httpPort = await freePort(exclude: {...taken, mixed});
      // one HTTP server per answer address: the body tells which DNS answer the connection used
      for (var i = 0; i < 2; i++) {
        final s = await HttpServer.bind(InternetAddress('127.0.${_kD(i)}.${_kD(i)}'), httpPort);
        s.listen((r) => r.response
          ..write('d$i')
          ..close());
        web.add(s);
      }
      Map<String, dynamic> prov(String id, int i) => {
            'id': id,
            'on': true,
            'sides': ['direct'],
            'use': ['udp'],
            'transports': [{'kind': 'udp', 'addr': 'udp://127.0.0.1:${lab.dp[i]}'}],
          };
      final info = RoutingInfo();
      final flags = p.join(lab.tmp.path, 'flags');
      final plan = {
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': 'm::0',
          'nodes': [{'key': 'm::0', 'outbound': {'type': 'direct'}}],
        },
        'mixedPort': mixed,
        'routing': {
          'dns': {'servers': [prov('a', 0), prov('b', 1)], 'directPolicy': 'priority'},
          'rules': <Map>[],
          'quick': {'lan': false, 'final': 'direct'},
        },
      };
      final cfg = buildConfig(plan, info: info, dnsFlagDir: flags);
      expect(info.dnsSides['direct']!.map((c) => c.id), ['a-udp1', 'b-udp1']);
      expect(info.dnsSides['vpn'], isEmpty);
      writeDnsFlags(info.dnsCandidates);
      // a built config with flag rule sets is valid for the real binary (all the files exist)
      await sb.start(cfg);
      final rs = (((cfg['route'] as Map)['rules']) as List).cast<Map>();
      expect(rs.where((r) => r['action'] == 'resolve' && !r.containsKey('server')), isNotEmpty, reason: 'the resolve step before direct');

      Future<String> get(String host) async {
        final h = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        try {
          final res = await (await h.getUrl(Uri.parse('http://$host:$httpPort/'))).close().timeout(const Duration(seconds: 4));
          return await res.transform(utf8.decoder).join();
        } catch (_) {
          return '';
        } finally {
          h.close(force: true);
        }
      }

      Future<void> until(String want) async {
        final t = Stopwatch()..start();
        var n = 0;
        while (t.elapsed < const Duration(seconds: 6)) {
          if (await get('n${n++}.test') == want) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('$want did not answer within 6 s');
      }

      expect(await get('first.test'), 'd0', reason: 'all flags on: the top candidate answers');
      expect(lab.asked('d1'), 0);
      final a = info.dnsCandidates.firstWhere((c) => c.id == 'a-udp1');
      setDnsFlag(a, false);
      await until('d1');
      setDnsFlag(a, true);
      await until('d0');
    } finally {
      await sb.stop();
      for (final s in web) {
        await s.close(force: true);
      }
      await lab.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
}
