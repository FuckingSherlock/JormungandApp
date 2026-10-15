// Where a failing latency test fails, per protocol, with the real sing-box on loopback (nothing leaves the machine):
// sing-box answers the SOCKS CONNECT of the tester inbound only after its outbound dialled the server, so a failure
// at the `socks` stage means the node was not reached ([NodeUnreachable]: no backup checks, probe.dart). The table:
//   server closed        -> the stage `socks` (unreached), every protocol here
//   server up, test host closed -> after `socks` (a miss, backup checks run)
//   server up, wrong credentials -> see _expectedWrong (QUIC protocols authenticate while dialling: unreached)
// Skipped when the binary is missing.
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

const _uuid = '11111111-1111-1111-1111-111111111111';
const _otherUuid = '22222222-2222-2222-2222-222222222222';

/// How one test ended: an answer (ms >= 0), a miss after the SOCKS stage, or unreached at it.
enum _How { answered, missed, unreached }

typedef _Outcome = ({_How how, String? why, int ms, int took});

String _pem(String all, String kind) => RegExp('-----BEGIN $kind-----[\\s\\S]*?-----END $kind-----').firstMatch(all)!.group(0)!;

void main() {
  test('where a latency test fails: server closed / test host closed / wrong credentials', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hi')
      ..close());
    final tmp = await Directory.systemTemp.createTemp('jorm-unreached');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    final tester = SingBoxProcess(_bin, p.join(tmp.path, 'tester'));
    try {
      final kp = (await Process.run(_bin, ['generate', 'tls-keypair', 'localhost'])).stdout as String;
      File(p.join(tmp.path, 'k.pem')).writeAsStringSync(_pem(kp, 'PRIVATE KEY'));
      File(p.join(tmp.path, 'c.pem')).writeAsStringSync(_pem(kp, 'CERTIFICATE'));
      final rk = (await Process.run(_bin, ['generate', 'reality-keypair'])).stdout as String;
      final realityPriv = RegExp(r'PrivateKey:\s*(\S+)').firstMatch(rk)!.group(1)!;
      final realityPub = RegExp(r'PublicKey:\s*(\S+)').firstMatch(rk)!.group(1)!;
      final tls = {'enabled': true, 'server_name': 'localhost', 'key_path': p.join(tmp.path, 'k.pem'), 'certificate_path': p.join(tmp.path, 'c.pem')};
      final ctls = {'enabled': true, 'server_name': 'localhost', 'insecure': true};
      final ports = <String, int>{for (final n in ['ss', 'vless', 'vlessTls', 'reality', 'trojan', 'vmess', 'hy2', 'tuic', 'handshake', 'http', 'socks', 'anytls', 'hy1']) n: await freePort()};
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'shadowsocks', 'tag': 'ss', 'listen': '127.0.0.1', 'listen_port': ports['ss'], 'method': 'chacha20-ietf-poly1305', 'password': 'pw'},
          {'type': 'vless', 'tag': 'vless', 'listen': '127.0.0.1', 'listen_port': ports['vless'], 'users': [{'uuid': _uuid}]},
          {'type': 'vless', 'tag': 'vlessTls', 'listen': '127.0.0.1', 'listen_port': ports['vlessTls'], 'users': [{'uuid': _uuid}], 'tls': tls},
          {'type': 'vless', 'tag': 'reality', 'listen': '127.0.0.1', 'listen_port': ports['reality'], 'users': [{'uuid': _uuid}], 'tls': {
            'enabled': true,
            'server_name': 'localhost',
            'reality': {'enabled': true, 'handshake': {'server': '127.0.0.1', 'server_port': ports['handshake']}, 'private_key': realityPriv, 'short_id': ['0123456789abcdef']},
          }},
          {'type': 'trojan', 'tag': 'handshake', 'listen': '127.0.0.1', 'listen_port': ports['handshake'], 'users': [{'password': 'x'}], 'tls': tls},
          {'type': 'trojan', 'tag': 'trojan', 'listen': '127.0.0.1', 'listen_port': ports['trojan'], 'users': [{'password': 'pw'}], 'tls': tls},
          {'type': 'vmess', 'tag': 'vmess', 'listen': '127.0.0.1', 'listen_port': ports['vmess'], 'users': [{'uuid': _uuid}]},
          {'type': 'hysteria2', 'tag': 'hy2', 'listen': '127.0.0.1', 'listen_port': ports['hy2'], 'users': [{'password': 'pw'}], 'tls': tls},
          {'type': 'tuic', 'tag': 'tuic', 'listen': '127.0.0.1', 'listen_port': ports['tuic'], 'users': [{'uuid': _uuid, 'password': 'pw'}], 'tls': {...tls, 'alpn': ['h3']}},
          {'type': 'http', 'tag': 'http', 'listen': '127.0.0.1', 'listen_port': ports['http'], 'users': [{'username': 'u', 'password': 'pw'}]},
          {'type': 'socks', 'tag': 'socks', 'listen': '127.0.0.1', 'listen_port': ports['socks'], 'users': [{'username': 'u', 'password': 'pw'}]},
          {'type': 'anytls', 'tag': 'anytls', 'listen': '127.0.0.1', 'listen_port': ports['anytls'], 'users': [{'password': 'pw'}], 'tls': tls},
          {'type': 'hysteria', 'tag': 'hy1', 'listen': '127.0.0.1', 'listen_port': ports['hy1'], 'up_mbps': 100, 'down_mbps': 100, 'users': [{'auth_str': 'pw'}], 'tls': {...tls, 'alpn': ['h3']}},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });

      Map<String, dynamic> out(String proto, int port, {bool wrong = false}) => switch (proto) {
            'ss' => {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'chacha20-ietf-poly1305', 'password': wrong ? 'bad' : 'pw'},
            'vless' => {'type': 'vless', 'server': '127.0.0.1', 'server_port': port, 'uuid': wrong ? _otherUuid : _uuid},
            'vlessTls' => {'type': 'vless', 'server': '127.0.0.1', 'server_port': port, 'uuid': wrong ? _otherUuid : _uuid, 'tls': ctls},
            'reality' => {
                'type': 'vless',
                'server': '127.0.0.1',
                'server_port': port,
                'uuid': wrong ? _otherUuid : _uuid,
                'tls': {
                  'enabled': true,
                  'server_name': 'localhost',
                  'utls': {'enabled': true, 'fingerprint': 'chrome'},
                  'reality': {'enabled': true, 'public_key': realityPub, 'short_id': '0123456789abcdef'},
                },
              },
            'trojan' => {'type': 'trojan', 'server': '127.0.0.1', 'server_port': port, 'password': wrong ? 'bad' : 'pw', 'tls': ctls},
            'vmess' => {'type': 'vmess', 'server': '127.0.0.1', 'server_port': port, 'uuid': wrong ? _otherUuid : _uuid, 'security': 'auto'},
            'hy2' => {'type': 'hysteria2', 'server': '127.0.0.1', 'server_port': port, 'password': wrong ? 'bad' : 'pw', 'tls': ctls},
            'tuic' => {'type': 'tuic', 'server': '127.0.0.1', 'server_port': port, 'uuid': _uuid, 'password': wrong ? 'bad' : 'pw', 'tls': {...ctls, 'alpn': ['h3']}},
            'http' => {'type': 'http', 'server': '127.0.0.1', 'server_port': port, 'username': 'u', 'password': wrong ? 'bad' : 'pw'},
            'socks' => {'type': 'socks', 'server': '127.0.0.1', 'server_port': port, 'username': 'u', 'password': wrong ? 'bad' : 'pw'},
            'anytls' => {'type': 'anytls', 'server': '127.0.0.1', 'server_port': port, 'password': wrong ? 'bad' : 'pw', 'tls': ctls},
            'hy1' => {'type': 'hysteria', 'server': '127.0.0.1', 'server_port': port, 'up_mbps': 10, 'down_mbps': 10, 'auth_str': wrong ? 'bad' : 'pw', 'tls': {...ctls, 'alpn': ['h3']}},
            _ => throw ArgumentError(proto),
          };

      final relays = {'socks', 'http'}; // Probe.relayTypes among these
      final protos = ['ss', 'vless', 'vlessTls', 'reality', 'trojan', 'vmess', 'hy2', 'tuic', 'http', 'socks', 'anytls', 'hy1'];
      final nodes = <Map<String, dynamic>>[];
      for (final pr in protos) {
        nodes.add({'key': '$pr.live', 'outbound': out(pr, ports[pr]!)});
        nodes.add({'key': '$pr.closed', 'outbound': out(pr, await freePort())});
        nodes.add({'key': '$pr.wrong', 'outbound': out(pr, ports[pr]!, wrong: true)});
      }
      nodes.add({
        'key': 'name.unresolved',
        'outbound': {'type': 'shadowsocks', 'server': 'no-such-host.invalid', 'server_port': 8388, 'method': 'chacha20-ietf-poly1305', 'password': 'pw'},
      });
      final reasons = <String, String>{};
      final probe = Probe(await freePort())..onFail = (tag, why) => reasons[tag] = why;
      await tester.start(buildTesterConfig(nodes: nodes, probe: probe));

      final liveUrl = 'http://127.0.0.1:${target.port}/';
      final closedHost = await freePort();
      final deadUrl = 'http://127.0.0.1:$closedHost/'; // nothing listens there

      Future<_Outcome> run(String key, String url) async {
        final sw = Stopwatch()..start();
        try {
          final ms = await probe.delay('t/$key', url, timeoutMs: 4000, unreachedThrows: true);
          return (how: ms >= 0 ? _How.answered : _How.missed, why: reasons['t/$key'], ms: ms, took: sw.elapsedMilliseconds);
        } on NodeUnreachable catch (e) {
          return (how: _How.unreached, why: e.reason, ms: -1, took: sw.elapsedMilliseconds);
        }
      }

      final results = <String, _Outcome>{};
      // the tests of one tag share the reason slot: one tag, one test at a time
      await Future.wait([
        for (final n in nodes)
          () async {
            final key = n['key'] as String;
            results['$key/live'] = await run(key, liveUrl);
            reasons.remove('t/$key');
            results['$key/deadUrl'] = await run(key, deadUrl);
          }(),
      ]);

      for (final pr in protos) {
        final relay = relays.contains(pr);
        expect(results['$pr.live/live']!.how, _How.answered, reason: '$pr: a live node answers');
        // a closed server: sing-box answers the CONNECT with a failure (TCP: at once; QUIC: no answer within the test's
        // time) = unreached; a relay type cannot tell it from the test host's failure: an ordinary miss at `socks`
        expect(results['$pr.closed/live']!.how, relay ? _How.missed : _How.unreached, reason: '$pr: a closed server');
        expect(results['$pr.closed/live']!.why, startsWith('socks'), reason: pr);
        if (!const {'hy2', 'tuic', 'hy1'}.contains(pr)) expect(results['$pr.closed/live']!.took, lessThan(2000), reason: '$pr: a refused TCP port is told at once');
        // server up, the test host closed: the node was reached, the miss comes after the SOCKS stage (backup checks run)
        expect(results['$pr.live/deadUrl']!.how, _How.missed, reason: '$pr: a closed test host is a miss, not unreached');
        // (sing-box's own http inbound answers the CONNECT before it dials, so here http fails later; a real HTTP proxy
        // relays the connect failure like socks does, which is why http is a relay type)
        expect(results['$pr.live/deadUrl']!.why, pr == 'socks' ? startsWith('socks') : startsWith('request'), reason: pr);
        // wrong credentials: the QUIC protocols that authenticate while dialling (hy2, hysteria) fail at once at `socks`;
        // the others open the connection and are shut down after it (a miss after `socks`, the backup checks run)
        expect(results['$pr.wrong/live']!.how, switch (pr) { 'hy2' || 'hy1' => _How.unreached, _ => _How.missed }, reason: '$pr: wrong credentials');
      }
      // a server named by a host that does not resolve inside sing-box: told at once at the SOCKS stage = unreached
      expect(results['name.unresolved/live']!.how, _How.unreached);
      expect(results['name.unresolved/live']!.took, lessThan(2000));
    } finally {
      await tester.stop();
      await server.stop();
      await target.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 120)));

  test('measureLatency: a dead node asks no checker, a reached one does; byChecker; the answered-before go first', () async {
    final hits = <String, int>{};
    HttpServer? checker, test;
    final tmp = await Directory.systemTemp.createTemp('jorm-ping-order');
    final server = SingBoxProcess(_bin, p.join(tmp.path, 'server'));
    try {
      Future<HttpServer> web(String name) async {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        s.listen((r) {
          hits[name] = (hits[name] ?? 0) + 1;
          r.response
            ..write('hi')
            ..close();
        });
        return s;
      }

      checker = await web('checker');
      test = await web('test');
      final ssPort = await freePort();
      await server.start({
        'log': {'level': 'warn'},
        'inbounds': [
          {'type': 'shadowsocks', 'tag': 'ss', 'listen': '127.0.0.1', 'listen_port': ssPort, 'method': 'chacha20-ietf-poly1305', 'password': 'pw'},
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      Map<String, dynamic> ss(int port, String pw) => {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'chacha20-ietf-poly1305', 'password': pw};
      final nodes = [
        {'key': 'dead', 'outbound': ss(await freePort(), 'pw')},
        {'key': 'live', 'outbound': ss(ssPort, 'pw')},
        {'key': 'live2', 'outbound': ss(ssPort, 'pw2')}, // another identity, wrong password: reached, never answers
      ];
      final closedUrl = 'http://127.0.0.1:${await freePort()}/'; // the test URL nobody answers
      final checkerUrl = 'http://127.0.0.1:${checker.port}/';
      final pool = ProbePool.solo();
      // `live2` answered before: it goes first, the others after it in the order asked
      pool.record(serverIdentity(nodes[2]['outbound'] as Map), 30, url: closedUrl, checkers: [checkerUrl]);
      final order = <String>[];
      final bys = <String, bool>{};
      final fails = <String, List<String>>{};
      final r = await measureLatency(
        binary: _bin,
        workDir: p.join(tmp.path, 'ping'),
        nodes: nodes,
        url: closedUrl,
        checkers: [checkerUrl],
        timeoutMs: 3000,
        parallel: 1,
        pool: pool,
        onFail: (tag, why) => (fails[tag] ??= []).add(why),
        onResult: (kind, key, ms, byChecker) {
          order.add(key);
          bys[key] = byChecker;
        },
      );
      expect(order, ['live2', 'dead', 'live'], reason: 'answered before first, then the request order');
      expect(r.nodes['dead'], -1);
      expect(r.nodes['live'], greaterThanOrEqualTo(0), reason: 'the test URL missed, the checker answered through a reached node');
      expect(bys['live'], isTrue);
      expect(bys['dead'], isFalse);
      expect(pool.peek(serverIdentity(nodes[1]['outbound'] as Map), url: closedUrl, checkers: [checkerUrl])!.byChecker, isTrue, reason: 'the pool remembers it');
      expect(pool.peek(serverIdentity(nodes[0]['outbound'] as Map), url: closedUrl, checkers: [checkerUrl])!.byChecker, isFalse);
      // what failed, per node: a dead node was tried once (its backup checks skipped); a reached node whose test URL
      // missed was tried again with the checker
      expect(fails['t/dead'], hasLength(1));
      expect(fails['t/dead']!.single, allOf(startsWith('socks'), contains('backup checks skipped')));
      expect(fails['t/live2'], hasLength(2), reason: 'reached (wrong password): the URL and the checker both missed after the SOCKS stage');
      expect(fails['t/live2']!.every((w) => w.startsWith('request')), isTrue);
      expect(hits['checker'], greaterThan(0));
      expect(hits['test'], isNull);
    } finally {
      await server.stop();
      await checker?.close(force: true);
      await test?.close(force: true);
      await tmp.delete(recursive: true);
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
}
