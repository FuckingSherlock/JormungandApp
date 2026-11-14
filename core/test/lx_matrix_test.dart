// Interop harness: the fork sing-box-lx (tool/bin) against Xray-core (tool/bin/xray) on
// loopback — the gate before the repo migrates its core to the fork. Covers what the
// migration depends on: REALITY with the post-quantum ClientHello key share (xray >= 26.9.8
// rejects a hello without X25519MLKEM768 and falls back to the dest), the xhttp transport
// (every client mode, xmux) and VLESS post-quantum `encryption`. Every sing-box / Xray config
// here is hand-written JSON — the repo's own builder is validated by golden tests elsewhere.
// Nothing leaves the machine; skipped when either binary is missing.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart'; // freePort, SingBoxProcess
import 'package:jormungand_core/src/killjob.dart' show bindToUs;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _xrayBin = p.join('tool', 'bin', 'xray', Platform.isWindows ? 'xray.exe' : 'xray');
final _skip = File(_bin).existsSync() && File(_xrayBin).existsSync() ? false : 'no sing-box and/or xray in tool/bin';

// The repo's made-up test uuid (fixtures.dart), never a real credential.
const _uuid = '11111111-2222-3333-4444-555555555555';
const _body = 'lx-matrix-ok';
const _sni = 'lx-reality.test';
const _shortId = 'abcdef01';
final _certPem = File(p.join('test', 'fixtures', 'reality_dest_cert.pem')).absolute.path;
final _keyPem = File(p.join('test', 'fixtures', 'reality_dest_key.pem')).absolute.path;

/// Per-request budget: a failure must never hang the suite.
const _requestTimeout = Duration(seconds: 8);

/// One matrix case. `mode: null` = omit the xhttp mode (the fork's auto); [keyShare] null =
/// omit `reality.key_share` ("" = follow the uTLS fingerprint); [pqPair] 1/2 = the X25519 /
/// ML-KEM-768 vlessenc pair, 0 = `decryption: none`; [mustFail] = the request must be rejected.
class _Case {
  const _Case(this.name, {this.mode, this.xmux, this.keyShare, this.reality = true, this.pqPair = 0, this.mustFail = false});
  final String name;
  final String? mode;
  final Map<String, dynamic>? xmux;
  final String? keyShare;
  final bool reality;
  final int pqPair;
  final bool mustFail;
}

const _xmux = {'max_concurrency': '4-8', 'h_max_request_times': '600-900', 'h_max_reusable_secs': '1800-3000'};

const _cases = [
  // THE fix case: the chrome uTLS hello must carry X25519MLKEM768 for xray >= 26.9.8 to accept it.
  _Case('REALITY + xhttp mode auto, default key_share (chrome hello carries X25519MLKEM768)', mode: 'auto'),
  _Case('REALITY + xhttp mode packet-up', mode: 'packet-up'),
  _Case('REALITY + xhttp mode stream-up', mode: 'stream-up'),
  _Case('REALITY + xhttp mode stream-one', mode: 'stream-one'),
  _Case('REALITY + xhttp mode packet-up + xmux', mode: 'packet-up', xmux: _xmux),
  _Case('plain TLS + xhttp, mode omitted (fork auto without REALITY)', reality: false),
  _Case('REALITY + xhttp mode auto + key_share hybrid', mode: 'auto', keyShare: 'hybrid'),
  _Case('REALITY + xhttp mode auto + VLESS encryption (X25519 vlessenc pair)', mode: 'auto', pqPair: 1),
  _Case('REALITY + xhttp mode auto + VLESS encryption (ML-KEM-768 vlessenc pair)', mode: 'auto', pqPair: 2),
  _Case('REALITY + xhttp mode auto + key_share classical: xray rejects and falls back to the dest', mode: 'auto', keyShare: 'classical', mustFail: true),
];

/// The exit the request lands on: any GET answers [_body].
HttpServer _exitHandler(HttpServer server) {
  server.listen((r) => r.response
    ..write(_body)
    ..close());
  return server;
}

/// The REALITY dest: a TLS server on loopback that accepts handshakes and then stalls. Xray
/// dials it on every connection before auth (it needs the dest's certificate for the client's
/// verification) and relays rejected (fallback) ClientHellos to it. [seen] counts TLS
/// handshakes that completed, [attempts] adds the ones the peer aborted mid-handshake (a
/// fallback ClientHello the client rejects on the dest's self-signed certificate never
/// completes at the dest).
class _Dest {
  final SecureServerSocket socket;
  int seen = 0;
  int attempts = 0;
  final _open = <Socket>{};
  _Dest(this.socket);

  int get connections => seen + attempts;

  static Future<_Dest> start(int port) async {
    final ctx = SecurityContext()
      ..useCertificateChain(_certPem)
      ..usePrivateKey(_keyPem);
    final socket = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, port, ctx);
    final dest = _Dest(socket);
    socket.listen(
      (sock) {
        dest.seen++;
        dest._open.add(sock);
        // stall: the handshake completes, nothing is ever answered
        sock.listen((_) {}, onDone: () => dest._open.remove(sock), onError: (_) => dest._open.remove(sock));
      },
      onError: (_) => dest.attempts++,
    );
    return dest;
  }

  Future<void> stop() async {
    await socket.close();
    for (final s in _open.toList()) {
      s.destroy();
    }
  }
}

/// The Xray server under test: a config file in [dir], `run -c` with cwd = [dir], stderr and
/// stdout captured for diagnostics. Tied to the test process's job object (killjob.dart), so
/// no child outlives the suite however it dies.
class _XrayProc {
  final _logs = ListQueue<String>();
  Process? _proc;

  List<String> get logs => _logs.toList();
  bool get running => _proc != null;

  void _log(String line) {
    _logs.add(line);
    while (_logs.length > 200) {
      _logs.removeFirst();
    }
  }

  Future<void> start(Map<String, dynamic> config, Directory dir) async {
    final file = File(p.join(dir.path, 'xray.json'))..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
    final proc = await Process.start(_xrayBin, ['run', '-c', file.path], workingDirectory: dir.path);
    _proc = proc;
    bindToUs(proc.pid);
    for (final s in [proc.stdout, proc.stderr]) {
      s.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_log);
    }
    proc.exitCode.then((code) {
      _log('xray exited with code $code');
      if (identical(_proc, proc)) _proc = null;
    });
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    if (proc == null) return;
    proc.kill();
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // bound to our job object anyway (bindToUs)
    }
  }
}

class _PqPair {
  const _PqPair(this.encryption, this.decryption);
  final String encryption; // the client's `encryption`
  final String decryption; // the server's `settings.decryption`
}

/// A fresh X25519 REALITY key pair per case: `xray x25519` prints `PrivateKey:` and
/// `Password (PublicKey):` (base64url). Never hardcode keys.
Future<(String, String)> _x25519() async {
  final r = await Process.run(_xrayBin, ['x25519']).timeout(const Duration(seconds: 15));
  final out = '${r.stdout}';
  final priv = RegExp(r'^PrivateKey:\s*(\S+)\s*$', multiLine: true).firstMatch(out)?.group(1);
  final pub = RegExp(r'^Password \(PublicKey\):\s*(\S+)\s*$', multiLine: true).firstMatch(out)?.group(1);
  if (r.exitCode != 0 || priv == null || pub == null) {
    fail('xray x25519 gave no key pair (exit ${r.exitCode}):\n${r.stderr}$out');
  }
  return (priv, pub);
}

/// The two vlessenc authentication pairs, in output order: first "X25519, not
/// Post-Quantum", then "ML-KEM-768, Post-Quantum". The quoted `"decryption"` / `"encryption"`
/// lines are used verbatim (case-sensitive).
Future<List<_PqPair>> _vlessenc() async {
  final r = await Process.run(_xrayBin, ['vlessenc']).timeout(const Duration(seconds: 15));
  final out = '${r.stdout}';
  final dec = <String>[], enc = <String>[];
  for (final line in out.split('\n')) {
    final d = RegExp(r'"decryption":\s*"([^"]+)"').firstMatch(line);
    final e = RegExp(r'"encryption":\s*"([^"]+)"').firstMatch(line);
    if (d != null) dec.add(d.group(1)!);
    if (e != null) enc.add(e.group(1)!);
  }
  if (r.exitCode != 0 || dec.length != 2 || enc.length != 2) {
    fail('xray vlessenc gave no two authentication pairs (exit ${r.exitCode}, ${dec.length} decryptions, ${enc.length} encryptions):\n${r.stderr}$out');
  }
  expect(enc[1].length, greaterThan(1000),
      reason: 'the second pair must be the ML-KEM-768 one: its encryption string carries the 1184-byte key (~1.5 KB), got ${enc[1].length} chars');
  expect(dec[1].length, greaterThan(dec[0].length), reason: "the ML-KEM-768 decryption key is a 64-byte seed, longer than X25519's 32 bytes");
  for (final s in [...dec, ...enc]) {
    expect(s.startsWith('mlkem768x25519plus.native.'), isTrue, reason: 'unexpected vlessenc value: $s');
  }
  return [_PqPair(enc[0], dec[0]), _PqPair(enc[1], dec[1])];
}

/// The Xray server config, the shape that actually works against Xray 26.11.9. Three deltas
/// from the plan's sketch, each proven by a live failure: the server xhttp settings must carry
/// the same `path` as the client (without it the server misparses every upload: ParseUint on
/// the session id, HTTP 500/409); freedom needs a finalRule to allow loopback (Xray >= 26.x
/// blackholes private targets by default); there is no `flow` (vision needs a raw TCP
/// connection and xray rejects it on non-raw transports anyway). The server xhttp mode stays
/// unset (= auto: every client mode is accepted). `target` is dialed on every connection
/// before auth — the dest must listen before the client runs.
Map<String, dynamic> _xrayConfig({required bool reality, required int port, required int destPort, required String privateKey, required String decryption}) => {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': port,
          'protocol': 'vless',
          'settings': {
            'clients': [
              {'id': _uuid},
            ],
            'decryption': decryption,
          },
          'streamSettings': {
            'network': 'xhttp',
            if (reality) ...{
              'security': 'reality',
              'realitySettings': {
                'target': '127.0.0.1:$destPort',
                'serverNames': [_sni],
                'privateKey': privateKey,
                'shortIds': [_shortId],
              },
              'xhttpSettings': {'path': '/xhttp'},
            } else ...{
              'security': 'tls',
              'tlsSettings': {
                'certificates': [
                  {'certificateFile': _certPem, 'keyFile': _keyPem},
                ],
              },
              'xhttpSettings': {'path': '/xhttp'},
            },
          },
        },
      ],
      'outbounds': [
        {
          'protocol': 'freedom',
          'tag': 'direct',
          // Xray >= 26.x blackholes loopback/private targets by default (finalRules);
          // every dialled address here is loopback, so let freedom through.
          'settings': {
            'finalRules': [
              {'action': 'allow', 'ip': ['127.0.0.0/8', '::1/128']},
            ],
          },
        },
      ],
      'routing': {
        'rules': [
          {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'},
        ],
      },
    };

/// The sing-box-lx client config, hand-written (no buildConfig): a mixed inbound, the vless
/// outbound with the xhttp transport, `route.final` = proxy (traffic to 127.0.0.1 must go
/// through the tunnel — no bypass rules; every dialled address is an IP literal).
Map<String, dynamic> _clientConfig({
  required bool reality,
  required int mixedPort,
  required int serverPort,
  required String publicKey,
  String? mode,
  Map<String, dynamic>? xmux,
  String? keyShare,
  String? encryption,
}) =>
    {
      'log': {'level': 'info'},
      'inbounds': [
        {'type': 'mixed', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': mixedPort},
      ],
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'proxy',
          'server': '127.0.0.1',
          'server_port': serverPort,
          'uuid': _uuid,
          'tls': {
            'enabled': true,
            'server_name': _sni,
            'insecure': true,
            'utls': {'enabled': true, 'fingerprint': 'chrome'},
            if (reality)
              'reality': {
                'enabled': true,
                'public_key': publicKey,
                'short_id': _shortId,
                'key_share': ?keyShare,
              },
          },
          'transport': {
            'type': 'xhttp',
            'path': '/xhttp',
            'host': _sni,
            'mode': ?mode,
            'xmux': ?xmux,
          },
          'encryption': ?encryption,
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'proxy'},
    };

/// TCP-connects to [port] on loopback until it accepts (<= 5 s). Fails early when the owner
/// ([alive], [logs]) died instead of listening.
Future<void> _waitPort(int port, String label, {required bool Function() alive, required List<String> Function() logs}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 500));
      s.destroy();
      return;
    } catch (_) {
      if (!alive()) fail('$label died before it listened on $port:\n${logs().join('\n')}');
      if (DateTime.now().isAfter(deadline)) fail('$label did not listen on $port within 5 s:\n${logs().join('\n')}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// GET http://127.0.0.1:[exitPort]/ through the mixed inbound at [mixed] as a plain HTTP
/// proxy. null = no answer in time (the tunnel errored or stalled).
Future<String?> _request(int mixed, int exitPort) async {
  final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
  try {
    final res = await (await http.getUrl(Uri.parse('http://127.0.0.1:$exitPort/'))).close().timeout(_requestTimeout);
    final body = await res.transform(utf8.decoder).join().timeout(_requestTimeout);
    return res.statusCode == 200 ? body : null;
  } catch (_) {
    return null;
  } finally {
    http.close(force: true);
  }
}

String _diag(_XrayProc xray, SingBoxProcess client) => 'xray log:\n${xray.logs.join('\n')}\n--- sing-box log:\n${client.logs.join('\n')}';

/// One case: fresh exit, dest, keys, Xray and sing-box processes and temp dir, then one
/// end-to-end GET through the tunnel. Teardown in try/finally: nothing outlives the case.
Future<void> _runCase(_Case c) async {
  final exit = _exitHandler(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final destPort = await freePort();
  final xrayPort = await freePort(exclude: {destPort});
  final mixed = await freePort(exclude: {destPort, xrayPort});
  final tmp = await Directory.systemTemp.createTemp('lx-matrix');
  final dest = await _Dest.start(destPort);
  final xray = _XrayProc();
  final client = SingBoxProcess(_bin, p.join(tmp.path, 'client'));
  try {
    // Fresh keys per case, straight from the xray that is being tested against.
    final (privateKey, publicKey) = await _x25519();
    var decryption = 'none';
    String? encryption;
    if (c.pqPair != 0) {
      final pair = (await _vlessenc())[c.pqPair - 1];
      decryption = pair.decryption;
      encryption = pair.encryption;
    }

    await xray.start(_xrayConfig(reality: c.reality, port: xrayPort, destPort: destPort, privateKey: privateKey, decryption: decryption), tmp);
    await _waitPort(xrayPort, 'xray inbound', alive: () => xray.running, logs: () => xray.logs);

    await client.start(_clientConfig(
      reality: c.reality,
      mixedPort: mixed,
      serverPort: xrayPort,
      publicKey: publicKey,
      mode: c.mode,
      xmux: c.xmux,
      keyShare: c.keyShare,
      encryption: encryption,
    ));
    await _waitPort(mixed, 'sing-box mixed inbound', alive: () => client.running, logs: () => client.logs.toList());

    final watch = Stopwatch()..start();
    if (c.mustFail) {
      final body = await _request(mixed, exit.port); // one attempt: any answer is a finding
      watch.stop();
      expect(body, isNull,
          reason: 'xray >= 26.9.8 must reject a ClientHello without X25519MLKEM768 (key_share "classical" strips it) and fall back to the dest, '
              'but the request answered ${body == null ? '' : '"$body"'} in ${watch.elapsedMilliseconds} ms\n${_diag(xray, client)}');
      expect(watch.elapsedMilliseconds, lessThan(15000), reason: 'the rejection must fail within the request timeout, not hang\n${_diag(xray, client)}');
      expect(xray.running, isTrue, reason: 'xray must survive the rejected hello\n${_diag(xray, client)}');
      expect(client.running, isTrue, reason: 'sing-box must survive the rejected tunnel\n${_diag(xray, client)}');
      expect(dest.connections, greaterThanOrEqualTo(1),
          reason: 'xray dials the dest on every connection before auth; a fallback also relays the hello to it — the request never reached xray (dest handshakes: ${dest.seen}, aborted: ${dest.attempts})\n${_diag(xray, client)}');
    } else {
      String? body;
      for (var i = 0; i < 3 && body == null; i++) {
        // a busy machine may drop the first one (the suite's convention, see failover_singbox_test)
        body = await _request(mixed, exit.port);
      }
      expect(body, _body, reason: 'through ${c.name}: got ${body == null ? 'no answer' : '"$body"'}\n${_diag(xray, client)}');
      expect(xray.running, isTrue, reason: 'xray must survive the case\n${_diag(xray, client)}');
      expect(client.running, isTrue, reason: 'sing-box must survive the case\n${_diag(xray, client)}');
    }
  } finally {
    await client.stop();
    await xray.stop();
    await dest.stop();
    await exit.close(force: true);
    await tmp.delete(recursive: true);
  }
}

void main() {
  for (final c in _cases) {
    test(c.name, () => _runCase(c), skip: _skip, timeout: const Timeout(Duration(seconds: 60)));
  }
}
