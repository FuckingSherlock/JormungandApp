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
      if (d == null || d.data.length < 17 || !answering) return;
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

  /// Silent while false: the server is dead.
  bool answering = true;

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

  test('both sides live: the flagcheck names each side\'s candidate, the resolve step and a direct rule follow the flags, a dead server moves only its side', () async {
    final lab = _Lab();
    await lab.up();
    final web = <HttpServer>[];
    final sb = SingBoxProcess(_bin, p.join(lab.tmp.path, 'built'));
    final sentinel = Sentinel(settle: Duration.zero)..context.started();
    DnsFailover? fo;
    try {
      final taken = {lab.dnsIn, lab.ssPort, ...lab.dp, ...lab.vp};
      final mixed = await freePort(exclude: taken);
      final httpPort = await freePort(exclude: {...taken, mixed});
      final probe = Probe(await freePort(exclude: {...taken, mixed, httpPort}));
      // one HTTP server per answer address: the body tells which DNS server's answer the connection used
      for (final (name, ip) in [('d0', '127.0.10.10'), ('d1', '127.0.11.11'), ('v0', '127.0.100.100'), ('v1', '127.0.101.101')]) {
        final s = await HttpServer.bind(InternetAddress(ip), httpPort);
        s.listen((r) => r.response
          ..write(name)
          ..close());
        web.add(s);
      }
      Map<String, dynamic> prov(String id, String host, int port, String side) => {
            'id': id,
            'on': true,
            'sides': [side],
            'use': ['udp'],
            'transports': [{'kind': 'udp', 'addr': 'udp://$host:$port'}],
          };
      Map<String, dynamic> rule(String id, String action, String group, Map<String, List<String>> v) => {
            'id': id,
            'name': id,
            'action': action,
            'target': '',
            'fallback': 'default',
            'dns': 'auto',
            'groups': {group: {'not': false, 'v': v}},
          };
      final info = RoutingInfo();
      final plan = {
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': 'm::0',
          'nodes': [{'key': 'm::0', 'outbound': {'type': 'direct'}}],
        },
        'mixedPort': mixed,
        'routing': {
          'dns': {
            'servers': [
              prov('a', '127.0.0.1', lab.dp[0], 'direct'),
              prov('b', '127.0.0.1', lab.dp[1], 'direct'),
              prov('c', '127.0.0.2', lab.vp[0], 'vpn'),
              prov('d', '127.0.0.2', lab.vp[1], 'vpn'),
            ],
            'directPolicy': 'priority',
          },
          // a direct rule by name (the DNS rules of the direct side answer it), then an IP rule (the resolve step
          // in front of it asks the VPN side)
          'rules': [
            rule('rd', 'direct', 'domain', {'domain_suffix': ['dir.test']}),
            rule('ri', 'proxy', 'ip', {'ip_cidr': ['127.0.0.0/8']}),
          ],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      final cfg = buildConfig(plan, probe: probe, info: info, dnsFlagDir: p.join(lab.tmp.path, 'flags'));
      expect(info.dnsSides['direct']!.map((c) => c.id), ['a-udp1', 'b-udp1']);
      expect(info.dnsSides['vpn']!.map((c) => c.id), ['c-udp1-v', 'd-udp1-v']);
      writeDnsFlags(info.dnsCandidates);
      await sb.start(cfg);
      DnsCandidate cand(String id) => info.dnsCandidates.firstWhere((c) => c.id == id);
      final ca = cand('a-udp1'), cb = cand('b-udp1'), cc = cand('c-udp1-v'), cd = cand('d-udp1-v');
      Future<String> flagged(String side) async {
        // the effective candidate of a side as the flagcheck tells it
        final on = [for (final c in info.dnsSides[side]!) if (await probeFlag(probe, c.tag, dnsFlagcheckName(side)) == true) c.id];
        return on.join(',');
      }

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

      var n = 0;
      // [suffix]: `dir.test` is the direct rule's (the direct side answers), anything else goes to the IP rule (the VPN side)
      Future<void> until(String suffix, String want) async {
        final t = Stopwatch()..start();
        while (t.elapsed < const Duration(seconds: 6)) {
          if (await get('n${n++}.$suffix') == want) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('$suffix was not answered by $want within 6 s');
      }

      expect([await get('x0.dir.test'), await get('x0.other.test')], ['d0', 'v0'], reason: 'all flags on: each side\'s top candidate');
      expect([await flagged('direct'), await flagged('vpn')], ['a-udp1', 'c-udp1-v']);

      setDnsFlag(cc, false);
      await until('other.test', 'v1'); // the resolve step moved to the next VPN candidate
      expect(await get('y0.dir.test'), 'd0', reason: 'the direct side did not move');
      expect([await flagged('direct'), await flagged('vpn')], ['a-udp1', 'd-udp1-v']);
      setDnsFlag(cc, true);
      await until('other.test', 'v0');
      setDnsFlag(ca, false);
      await until('dir.test', 'd1');
      expect(await get('y1.other.test'), 'v0', reason: 'the VPN side did not move');
      expect([await flagged('direct'), await flagged('vpn')], ['b-udp1', 'c-udp1-v']);
      // every flag of a side off: its top candidate answers (the config's last rule has no flag)
      setDnsFlag(cb, false);
      await until('dir.test', 'd0');
      expect(await flagged('direct'), 'a-udp1');
      setDnsFlag(cc, false);
      setDnsFlag(cd, false);
      await until('other.test', 'v0');
      expect(await flagged('vpn'), 'c-udp1-v');
      for (final c in [ca, cb, cc, cd]) {
        setDnsFlag(c, true);
      }

      // the failover on the same sing-box: a server that dies turns its flag off, only its side moves
      final notes = <String>[];
      fo = DnsFailover(
          sides: info.dnsSides,
          candidates: info.dnsCandidates,
          watch: info.dnsExtra,
          setFlag: (c, on, reason) async {
            setDnsFlag(c, on, reason: reason, log: (l, t) => notes.add('$l $t'));
            return true;
          },
          flagCheck: (c) => probeFlag(probe, c.tag, dnsFlagcheckName(c.side)),
          query: (tag, name, t) => probeDns(probe, tag, name, timeoutMs: t),
          sentinel: sentinel,
          settings: const AutoSettings(failAfter: 2, flapGuard: false, timeoutMs: 1500),
          note: (l, t) => notes.add('$l $t'));
      final moves = <DnsSwitch>[];
      fo.switches.listen(moves.add);
      await fo.check();
      expect([fo.activeOf('direct'), fo.activeOf('vpn')], ['a-udp1', 'c-udp1-v']);
      lab.dns['d0']!.answering = false;
      await fo.check();
      for (var i = 0; i < 400 && fo.activeOf('direct') != 'b-udp1'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50)); // the Sentinel's checks take their time
      }
      expect([fo.activeOf('direct'), fo.activeOf('vpn')], ['b-udp1', 'c-udp1-v']);
      expect(fo.flags, {'a-udp1': false, 'b-udp1': true, 'c-udp1-v': true, 'd-udp1-v': true});
      await until('dir.test', 'd1');
      expect(await get('z0.other.test'), 'v0', reason: 'the VPN side did not notice');
      expect([await flagged('direct'), await flagged('vpn')], ['b-udp1', 'c-udp1-v']);
      expect(notes.where((l) => l.contains('dns flag: a-udp1 (direct) off (verdict)')), hasLength(1));
      expect(notes.where((l) => l.contains('dns flag check (direct): b-udp1 answers after')), hasLength(1), reason: notes.join('\n'));
      expect(notes.where((l) => l.startsWith('warn')), isEmpty, reason: notes.join('\n'));
      final st = fo.toJson();
      expect((st['sides'] as Map)['direct'], {'active': 'b-udp1', 'provider': 'b'});
      expect((st['sides'] as Map)['vpn'], {'active': 'c-udp1-v', 'provider': 'c'});
      final a = (st['servers'] as List).cast<Map>().firstWhere((s) => s['id'] == 'a-udp1');
      expect(a, containsPair('flag', false));
      expect([a['provider'], a['side'], a['kind']], ['a', 'direct', 'udp']);

      lab.dns['d0']!.answering = true; // it answers again: back after failAfter answers
      await fo.check();
      expect(fo.activeOf('direct'), 'b-udp1');
      await fo.check();
      expect(fo.activeOf('direct'), 'a-udp1');
      await until('dir.test', 'd0');
      await Future<void>.delayed(Duration.zero);
      expect([for (final m in moves) '${m.side} ${m.from}>${m.to} ${m.reason}'], ['direct a-udp1>b-udp1 failover', 'direct b-udp1>a-udp1 back']);
      expect([moves.first.fromProvider, moves.first.toProvider], ['a', 'b']);
    } finally {
      fo?.stop();
      sentinel.dispose();
      await sb.stop();
      for (final s in web) {
        await s.close(force: true);
      }
      await lab.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 120)));

  test('a direct app: one plain resolve in front, the DNS rules over the connection\'s process choose the server by the flags (no ladder per app)', () async {
    final lab = _Lab();
    await lab.up();
    final web = <HttpServer>[];
    final sb = SingBoxProcess(_bin, p.join(lab.tmp.path, 'app'));
    try {
      final taken = {lab.dnsIn, lab.ssPort, ...lab.dp, ...lab.vp};
      final mixed = await freePort(exclude: taken);
      final httpPort = await freePort(exclude: {...taken, mixed});
      for (final (name, ip) in [('d0', '127.0.10.10'), ('d1', '127.0.11.11')]) {
        final s = await HttpServer.bind(InternetAddress(ip), httpPort);
        s.listen((r) => r.response
          ..write(name)
          ..close());
        web.add(s);
      }
      Map<String, dynamic> prov(String id, String host, int port, String side) => {
            'id': id,
            'on': true,
            'sides': [side],
            'use': ['udp'],
            'transports': [{'kind': 'udp', 'addr': 'udp://$host:$port'}],
          };
      // this very process is the app: its connections to the mixed inbound carry its name
      final exe = p.basename(Platform.resolvedExecutable);
      final self = Platform.isWindows ? 'dartvm.exe' : exe;
      final info = RoutingInfo();
      final plan = {
        'kind': 'unit',
        'main': {
          'pick': 'priority',
          'chosen': 'm::0',
          'nodes': [{'key': 'm::0', 'outbound': {'type': 'direct'}}],
        },
        'mixedPort': mixed,
        'routing': {
          'dns': {
            'servers': [
              prov('a', '127.0.0.1', lab.dp[0], 'direct'),
              prov('b', '127.0.0.1', lab.dp[1], 'direct'),
              prov('c', '127.0.0.2', lab.vp[0], 'vpn'),
            ],
            'directPolicy': 'priority',
          },
          'apps': [{'id': self, 'kind': 'process', 'act': 'direct'}],
          'quick': {'lan': false, 'final': 'proxy'},
        },
      };
      final cfg = buildConfig(plan, info: info, dnsFlagDir: p.join(lab.tmp.path, 'flags'));
      final resolves = ((cfg['route'] as Map)['rules'] as List).cast<Map>().where((r) => r['action'] == 'resolve').toList();
      expect(resolves, [{'process_name': [self], 'action': 'resolve'}]);
      writeDnsFlags(info.dnsCandidates);
      await sb.start(cfg);
      DnsCandidate cand(String id) => info.dnsCandidates.firstWhere((c) => c.id == id);
      var n = 0;
      Future<String> get() async {
        final h = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        try {
          final res = await (await h.getUrl(Uri.parse('http://n${n++}.app.test:$httpPort/'))).close().timeout(const Duration(seconds: 4));
          return await res.transform(utf8.decoder).join();
        } catch (_) {
          return '';
        } finally {
          h.close(force: true);
        }
      }

      Future<void> until(String want) async {
        final t = Stopwatch()..start();
        while (t.elapsed < const Duration(seconds: 6)) {
          if (await get() == want) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('the app was not answered by $want within 6 s');
      }

      expect(await get(), 'd0', reason: 'all flags on: the top candidate');
      setDnsFlag(cand('a-udp1'), false);
      await until('d1');
      setDnsFlag(cand('a-udp1'), true);
      await until('d0');
      setDnsFlag(cand('a-udp1'), false);
      setDnsFlag(cand('b-udp1'), false);
      await until('d0'); // every flag off: the top candidate
    } finally {
      await sb.stop();
      for (final s in web) {
        await s.close(force: true);
      }
      await lab.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 120)));
}
