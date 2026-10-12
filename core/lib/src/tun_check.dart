/// The active test of the TUN (docs/failures.md → «TUN»): does a TCP connection made from here, through the
/// tunnel, reach sing-box's routing? The detector ([TunIngressDetector]) only reads the log and cannot tell a
/// stack that takes no TCP from one app whose look-ups end without a connection (its ICMP echoes, a UDP flow
/// our own reject rule took); this settles it.
///
/// How: the config carries one route rule ahead of every other (config.dart [tunCheckRule]): a TCP connection
/// that enters the TUN to [tunCheckAddress]:[tunCheckPort] (a documentation address, RFC 5737: it exists
/// nowhere) is routed by `direct` to 127.0.0.1:`our responder` (`override_address` / `override_port`, the way
/// the DNS flag checks reach theirs). The check connects to that address from this process, so the packets
/// enter the TUN like any app's, go through the whole path of the real stack (mixed, system or gVisor: the
/// platform's own stack accepts the connection, sing-box's inbound makes a connection of it, the router matches
/// the rule) and arrive at the responder with a one-time token. Only the token arriving proves the path; a
/// connect that is accepted by the stack but whose token never arrives is a stack that does not reach routing.
/// Nothing leaves the machine: the rule takes the connection before the self rule and the user's rules, and
/// even without it the address is unroutable (TEST-NET-1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sentinel/model.dart';

/// Where the test connection is aimed: the documentation address and a port nobody uses. In the TUN's routes
/// (everything but the local networks, config.dart `tunBypass`), so the packets enter it.
const tunCheckAddress = '192.0.2.251';
const tunCheckPort = 44251;

/// The code of the check in the Sentinel's trail.
const tunCheckCode = 'tun.test';

const _magic = 'jorm-tun-check';

/// Opens the test connection (a seam: tests have no TUN).
typedef TunCheckConnect = Future<Socket> Function(String host, int port, Duration timeout);

class TunCheck {
  TunCheck._(this._server, this._connect, this.connectTimeout, this.answerTimeout) {
    _server.listen(_serve, onError: (_) {});
  }

  /// Starts the responder on a free loopback port ([port] 0) or on [port] (a sing-box taken over keeps the
  /// port its config names). Throws when the port is taken.
  static Future<TunCheck> bind({
    int port = 0,
    TunCheckConnect? connect,
    Duration connectTimeout = const Duration(seconds: 3),
    Duration answerTimeout = const Duration(seconds: 3),
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return TunCheck._(server, connect ?? _plainConnect, connectTimeout, answerTimeout);
  }

  static Future<Socket> _plainConnect(String host, int port, Duration timeout) => Socket.connect(host, port, timeout: timeout);

  final ServerSocket _server;
  final TunCheckConnect _connect;
  final Duration connectTimeout, answerTimeout;
  final _waiting = <String, Completer<void>>{};
  final _random = Random.secure();

  /// The responder's loopback port: what the route rule sends the test connection to.
  int get port => _server.port;

  /// Total time one run can take (the Sentinel's timeout for the check).
  Duration get limit => connectTimeout + answerTimeout + const Duration(seconds: 2);

  void _serve(Socket s) {
    final buf = StringBuffer();
    s.listen((data) {
      buf.write(latin1.decode(data, allowInvalid: true));
      final text = buf.toString();
      final nl = text.indexOf('\n');
      if (nl >= 0 || text.length > 128) {
        final line = nl >= 0 ? text.substring(0, nl).trim() : text.trim();
        if (line.startsWith('$_magic ')) _waiting.remove(line.substring(_magic.length + 1))?.complete();
        s.add(utf8.encode('ok\n'));
        s.destroy();
      }
    }, onError: (_) => s.destroy(), onDone: s.destroy, cancelOnError: true);
  }

  /// One test: pass = the token came out of the tunnel. A failure says where it stopped: `silent` (the
  /// connection was not answered), `refused` (reset / unreachable: [error]), `unrouted` (the stack accepted the
  /// connection, nothing reached the routing and the responder).
  Future<CheckResult> run(Cancel cancel) async {
    final token = List.generate(12, (_) => _random.nextInt(16).toRadixString(16)).join();
    final seen = Completer<void>();
    _waiting[token] = seen;
    final sw = Stopwatch()..start();
    Socket? s;
    try {
      final aborted = cancel.done.then((_) => 'aborted');
      try {
        s = await Future.any([_connect(tunCheckAddress, tunCheckPort, connectTimeout), aborted.then((_) => throw const _Aborted())]);
      } on _Aborted {
        return CheckResult(tunCheckCode, Outcome.inconclusive, {'reason': 'aborted'});
      } on TimeoutException {
        return CheckResult(tunCheckCode, Outcome.fail, {'reason': 'silent', 'ms': sw.elapsedMilliseconds});
      } on SocketException catch (e) {
        return CheckResult(tunCheckCode, Outcome.fail, {'reason': 'refused', 'error': e.message, 'ms': sw.elapsedMilliseconds});
      }
      final connectMs = sw.elapsedMilliseconds;
      final conn = s!;
      conn.add(utf8.encode('$_magic $token\n'));
      unawaited(conn.flush().catchError((Object _) {}));
      try {
        await Future.any([seen.future.timeout(answerTimeout), aborted.then((_) => throw const _Aborted())]);
      } on _Aborted {
        return CheckResult(tunCheckCode, Outcome.inconclusive, {'reason': 'aborted'});
      } on TimeoutException {
        return CheckResult(tunCheckCode, Outcome.fail, {'reason': 'unrouted', 'connectMs': connectMs, 'ms': sw.elapsedMilliseconds});
      }
      return CheckResult(tunCheckCode, Outcome.pass, {'ms': sw.elapsedMilliseconds, 'connectMs': connectMs});
    } finally {
      _waiting.remove(token);
      s?.destroy();
    }
  }

  Future<void> close() async {
    try {
      await _server.close();
    } catch (_) {}
  }
}

class _Aborted implements Exception {
  const _Aborted();
}
