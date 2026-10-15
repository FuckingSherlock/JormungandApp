/// Latency through one outbound, measured by the core itself the way other clients show
/// it (Karing, mihomo's "unified delay"): two HEAD requests to the test URL on one
/// connection, the time of the second — one round trip over the whole path, without the
/// handshakes of opening a connection. sing-box's own delay test (Clash API
/// `/proxies/<tag>/delay`) times the first request, handshakes and all: through a bridge
/// (RU → EU, the bridge opening its own connection onward) that reads 3–4 times higher.
///
/// The requests go through a loopback SOCKS5 inbound of the config (`probe-in`, see
/// [Probe.inbound]): the SOCKS user name is the outbound's tag, a route rule per tag sends
/// it there, past every other rule; the password is random per start, so no other program
/// on the machine can use the inbound.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'dns_wire.dart';
import 'routing.dart' show DnsCandidate;

const probeInboundTag = 'probe-in';

class Probe {
  Probe(this.port, [String? secret]) : secret = secret ?? _newSecret();

  final int port;
  final String secret;

  /// Told why a latency test of [Probe.delay] got no answer ("socks: reply 4", "request: timeout");
  /// set by the caller that wants the reasons in the log (a UI ping), not by Auto.
  void Function(String tag, String reason)? onFail;

  /// The outbound types whose dial waits for the destination's own connect (the upstream relays it: a SOCKS5 reply, an
  /// HTTP CONNECT status, an SSH channel-open answer): a failure at the SOCKS stage through them may be the test
  /// host's, not the node's, so it never counts as "node not reached" (the old way: the backup checks run).
  static const relayTypes = {'socks', 'http', 'ssh'};

  /// The tags of the outbounds of a [relayTypes] type (set by the config builders, config.dart); see [probeDelay]
  /// `unreachedThrows`.
  final relays = <String>{};

  /// The user name that has a name resolved through the DNS server [tag] and nothing else.
  static String dnsUser(String tag) => 'dns-check/$tag';

  /// The user name that asks whether the DNS flags make the candidate [tag] the one that answers its side
  /// ([flagChecks] of [inbound], [probeFlag]).
  static String flagUser(String tag) => 'flag-check/$tag';

  /// The inbound and its route rules (to go first) for [tags]; [dnsServers] (DNS server
  /// tags): per server a rule resolving the requested name through it alone (`resolve`
  /// with its own `server`, no cache) and then ending the connection at the inbound
  /// itself: the SOCKS reply is a success exactly when the name resolved ([probeDns]).
  /// [flagChecks] (candidate tag → the address the DNS rules answer the side's flagcheck name with, routing.dart
  /// [DnsFlagCheck]): the name is resolved by the DNS rules as any query is (no `server`, no cache) and the
  /// connection ends at the inbound only when the answer is that candidate's address, else it is refused:
  /// the reply is a success exactly when the candidate is the side's effective one ([probeFlag]).
  ({Map<String, dynamic> inbound, List<Map<String, dynamic>> rules}) inbound(Iterable<String> tags,
      {Iterable<String> dnsServers = const [], Map<String, String> flagChecks = const {}}) {
    final ts = tags.toSet().toList(), ds = dnsServers.toSet().toList();
    final fs = flagChecks.keys.map(flagUser).toList();
    return (
      inbound: {
        'type': 'socks',
        'tag': probeInboundTag,
        'listen': '127.0.0.1',
        'listen_port': port,
        'users': [for (final t in [...ts, ...ds.map(dnsUser), ...fs]) {'username': t, 'password': secret}],
      },
      rules: [
        for (final t in ts)
          {'inbound': [probeInboundTag], 'auth_user': [t], 'action': 'route', 'outbound': t},
        for (final s in ds) ...[
          {'inbound': [probeInboundTag], 'auth_user': [dnsUser(s)], 'action': 'resolve', 'server': s, 'strategy': 'ipv4_only', 'disable_cache': true},
          {'inbound': [probeInboundTag], 'auth_user': [dnsUser(s)], 'action': 'route', 'outbound': 'direct', 'override_address': '127.0.0.1', 'override_port': port},
        ],
        if (fs.isNotEmpty) ...[
          {'inbound': [probeInboundTag], 'auth_user': fs, 'action': 'resolve', 'strategy': 'ipv4_only', 'disable_cache': true},
          for (final e in flagChecks.entries)
            {'inbound': [probeInboundTag], 'auth_user': [flagUser(e.key)], 'ip_cidr': ['${e.value}/32'], 'action': 'route', 'outbound': 'direct', 'override_address': '127.0.0.1', 'override_port': port},
          {'inbound': [probeInboundTag], 'auth_user': fs, 'action': 'reject'},
        ],
      ],
    );
  }

  /// ms of one round trip through [tag] to [url] on an open connection; the first
  /// request's time when the server will not keep the connection; -1 = no answer.
  ///
  /// [unreachedThrows]: a node that could not be dialled throws [NodeUnreachable] (see [probeDelay]) instead of -1, so
  /// [withCheckers] skips the backup checks of a dead node; the tests that want that (the pool's) set it.
  Future<int> delay(String tag, String url, {int timeoutMs = 5000, bool unreachedThrows = false}) =>
      probeDelay(this, tag, url, timeoutMs: timeoutMs, unreachedThrows: unreachedThrows);

  /// [delay] as AutoService takes it.
  Future<int> Function(String tag, String url, int timeoutMs) get delayTest => (tag, url, t) => delay(tag, url, timeoutMs: t);

  static String _newSecret() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}

/// One test of a node with backup checks: [test] of [url] first; when it does not answer,
/// every one of [checkers] at once. The node passes traffic when any answers: the ms of
/// [url], else of the first checker that answered; -1 = none did. (One blocked service
/// must not make a working node look dead; the extra requests go only to a node that
/// already missed.) [fanOut] > 0 asks the checkers [fanOut] at a time (the next group only when
/// the one before did not answer): a ping run over hundreds of servers keeps fewer connections
/// open; 0 = all at once (Auto's way, where the answer must come at the fastest).
///
/// The checkers are for a node that was reached and did not answer for the test URL (one blocked host must not make a
/// working node look dead). A [test] that throws [NodeUnreachable] (the node itself could not be dialled: [Probe.delay]
/// with `unreachedThrows`) makes the node dead at once: no checkers, -1.
Future<int> withCheckers(Future<int> Function(String url) test, String url, List<String> checkers, {int fanOut = 0}) async =>
    (await checkWithBackups(test, url, checkers, fanOut: fanOut)).ms;

/// [withCheckers] with how it was answered: [byChecker] = the test URL missed and a backup checker answered (the node
/// passes traffic, but a test of the URL asked for is not proven).
Future<({int ms, bool byChecker})> checkWithBackups(Future<int> Function(String url) test, String url, List<String> checkers, {int fanOut = 0}) async {
  int ms;
  try {
    ms = await test(url);
  } on NodeUnreachable {
    return (ms: -1, byChecker: false);
  } catch (_) {
    ms = -1;
  }
  final rest = [for (final c in checkers) if (c != url) c];
  if (ms >= 0) return (ms: ms, byChecker: false);
  if (rest.isEmpty) return (ms: -1, byChecker: false);
  final size = fanOut <= 0 ? rest.length : fanOut;
  for (var i = 0; i < rest.length; i += size) {
    final group = rest.sublist(i, i + size > rest.length ? rest.length : i + size);
    final v = await _firstAnswer(test, group);
    if (v >= 0) return (ms: v, byChecker: true);
  }
  return (ms: -1, byChecker: false);
}

/// The node itself could not be reached: its test failed at the SOCKS stage of [probeDelay] (sing-box answers the SOCKS
/// CONNECT only after its outbound dialled the server: no reply in time or a failure reply = the server did not take
/// the connection). Thrown by [Probe.delay] with `unreachedThrows`; [withCheckers] reads it as a dead node.
class NodeUnreachable implements Exception {
  const NodeUnreachable(this.reason);
  final String reason;

  @override
  String toString() => 'NodeUnreachable: $reason';
}

/// The ms of the first of [urls] that answers, all asked at once; -1 when none did.
Future<int> _firstAnswer(Future<int> Function(String url) test, List<String> urls) {
  final done = Completer<int>();
  var left = urls.length;
  for (final c in urls) {
    test(c).catchError((_) => -1).then((v) {
      if (done.isCompleted) return;
      if (v >= 0) {
        done.complete(v);
      } else if (--left == 0) {
        done.complete(-1);
      }
    });
  }
  return done.future;
}

/// [unreachedThrows]: a failure at the SOCKS stage that says the node was not reached (no reply in time, a failure
/// reply of sing-box) throws [NodeUnreachable] instead of returning -1 (after [Probe.onFail] heard of it). Not for a
/// tag in [Probe.relays] (socks / ssh servers pass the test host's own connect failure back as the same reply).
Future<int> probeDelay(Probe probe, String tag, String url, {int timeoutMs = 5000, bool unreachedThrows = false}) async {
  final Uri u;
  try {
    u = Uri.parse(url);
  } on FormatException {
    return -1;
  }
  final https = u.scheme == 'https';
  final port = u.hasPort ? u.port : (https ? 443 : 80);
  final path = '${u.path.isEmpty ? '/' : u.path}${u.hasQuery ? '?${u.query}' : ''}';
  final req = utf8.encode('HEAD $path HTTP/1.1\r\nHost: ${u.host}\r\nUser-Agent: Jormungand\r\nAccept: */*\r\n\r\n');
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    final sw = Stopwatch()..start();
    final int cold;
    final bool keep;
    var stage = 'connect to the test inbound';
    try {
      w = await _Wire.connect(probe.port).timeout(left());
      stage = 'socks to ${u.host}:$port';
      await w.socks(tag, probe.secret, u.host, port).timeout(left());
      if (https) {
        stage = 'tls with ${u.host}';
        await w.secure(u.host).timeout(left());
      }
      stage = 'request';
      keep = await w.request(req).timeout(left());
      cold = sw.elapsedMilliseconds;
    } catch (e) {
      final unreached = stage.startsWith('socks') && !probe.relays.contains(tag) && (e is TimeoutException || (e is SocketException && e is! ProbeRefused && e.message.startsWith('socks: reply')));
      final why = '$stage: ${e is TimeoutException ? 'no answer in ${timeoutMs ~/ 1000} s' : _why(e)}';
      probe.onFail?.call(tag, unreached && unreachedThrows ? '$why (the node was not reached, backup checks skipped)' : why);
      if (unreached && unreachedThrows) throw NodeUnreachable(why);
      return -1;
    }
    if (!keep) return cold;
    sw.reset();
    try {
      await w.request(req).timeout(left());
      return sw.elapsedMilliseconds;
    } catch (_) {
      return cold; // the first one answered: the server is there
    }
  } finally {
    w?.close();
  }
}

/// The direct path tested from this process, no sing-box (nothing runs: a disconnected core): one HEAD request to
/// [url] outside every proxy (the system proxy a kill switch leaves set is not used). ms until the answer (any
/// HTTP status: the server is there); -1 = no answer in [timeoutMs] or the connection failed.
Future<int> directDelay(String url, int timeoutMs) async {
  final Uri u;
  try {
    u = Uri.parse(url);
  } on FormatException {
    return -1;
  }
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = Duration(milliseconds: timeoutMs);
  try {
    final sw = Stopwatch()..start();
    final res = await (await client.openUrl('HEAD', u)).close().timeout(Duration(milliseconds: timeoutMs));
    await res.drain<void>().timeout(Duration(milliseconds: timeoutMs));
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    client.close(force: true);
  }
}

/// The probe inbound turned the test down before any request was made (no such SOCKS user =
/// no such outbound to test, or no password method): says nothing about the path under test.
class ProbeRefused extends SocketException {
  const ProbeRefused(super.message);
}

/// An error as one short phrase for the log ("SocketException: socks: reply 4" -> "socks: reply 4").
String _why(Object e) => e is SocketException ? (e.message.isEmpty ? '${e.osError ?? e}' : e.message) : '$e';

/// Whether a site test ([probeReach]) can be aimed at [dest] (`host:port`) at all: port 443 (a name, not an
/// IP address) or 80.
bool canProbeDest(String dest) {
  final i = dest.lastIndexOf(':');
  final host = i > 0 ? dest.substring(0, i).replaceAll(RegExp(r'^\[|\]$'), '') : dest;
  final port = int.tryParse(i > 0 ? dest.substring(i + 1) : '');
  if (port != 443 && port != 80) return false;
  return !(port == 443 && InternetAddress.tryParse(host) != null);
}

/// Whether the site [dest] (`host:port`) opens through [tag]: port 443 — a TLS handshake
/// with it (its certificate valid for the host), port 80 — an answer to HEAD /. null when
/// it cannot be told: another port, an IP address on 443, or the test never ran (the
/// inbound is not there, or it refused the user name [tag] — no such outbound to test);
/// false only when the request really went through [tag] and failed.
Future<bool?> probeReach(Probe probe, String tag, String dest, {int timeoutMs = 5000}) async {
  if (!canProbeDest(dest)) return null;
  final i = dest.lastIndexOf(':');
  final host = i > 0 ? dest.substring(0, i).replaceAll(RegExp(r'^\[|\]$'), '') : dest;
  final port = int.tryParse(i > 0 ? dest.substring(i + 1) : '');
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    try {
      w = await _Wire.connect(probe.port).timeout(left());
    } catch (_) {
      return null; // the test inbound is not there: nothing was tested
    }
    await w.socks(tag, probe.secret, host, port!).timeout(left());
    if (port == 443) {
      await w.secure(host).timeout(left());
    } else {
      await w.request(utf8.encode('HEAD / HTTP/1.1\r\nHost: $host\r\nUser-Agent: Jormungand\r\nAccept: */*\r\n\r\n')).timeout(left());
    }
    return true;
  } on ProbeRefused {
    return null; // the inbound did not take the user name: the request never ran
  } catch (_) {
    return false;
  } finally {
    w?.close();
  }
}

/// The body (text) of a GET of [url] made through the outbound [tag] (the exit check, exitip.dart): the request
/// leaves the probe inbound on the rule of [tag], past every user rule. Throws when nothing answers within [timeout] or
/// the answer is not 200. [abort] completing closes the connection (the check has its answer already).
Future<String> probeGet(Probe probe, String tag, String url, {Duration timeout = const Duration(seconds: 7), Future<void>? abort}) async {
  final u = Uri.parse(url);
  final https = u.scheme == 'https';
  final port = u.hasPort ? u.port : (https ? 443 : 80);
  final path = '${u.path.isEmpty ? '/' : u.path}${u.hasQuery ? '?${u.query}' : ''}';
  final req = utf8.encode('GET $path HTTP/1.1\r\nHost: ${u.host}\r\nUser-Agent: Jormungand\r\nAccept: */*\r\nConnection: close\r\n\r\n');
  final deadline = DateTime.now().add(timeout);
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    w = await _Wire.connect(probe.port).timeout(left());
    final wire = w;
    if (abort != null) unawaited(abort.then((_) => wire.close()));
    await wire.socks(tag, probe.secret, u.host, port).timeout(left());
    if (https) await wire.secure(u.host).timeout(left());
    final (status, body) = await wire.get(req).timeout(left());
    if (status != 200) throw HttpException('HTTP $status', uri: u);
    return body;
  } finally {
    w?.close();
  }
}

/// ms until the DNS server [server] (its tag in the config) has resolved [name] — a real
/// query on the server's own path, direct or through the VPN as the server is set (see
/// [Probe.inbound]); -1 = no answer with an address (so [name] must be one that exists).
Future<int> probeDns(Probe probe, String server, String name, {int timeoutMs = 5000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    final sw = Stopwatch()..start();
    w = await _Wire.connect(probe.port).timeout(left());
    await w.socks(Probe.dnsUser(server), probe.secret, name, 80).timeout(left());
    return sw.elapsedMilliseconds;
  } catch (_) {
    return -1;
  } finally {
    w?.close();
  }
}

/// ms until the DNS server [c] answered a query for [name] sent through the outbound [nodeTag] (the probe inbound, user
/// = the tag: the request leaves from that node, past every user rule): DoH (GET), DoT, DNS over TCP. -1 = no usable answer;
/// null = cannot be told: DoQ and the OS resolver have no client here, and a plain UDP server that stays silent over TCP
/// says nothing (UDP is not carried through a SOCKS connection); an answer over TCP is an answer. A `tcp://` server is
/// asked the same way and its silence is a miss. The test inbound being absent (nothing was asked) is null too.
Future<int?> probeDnsVia(Probe probe, String nodeTag, DnsCandidate c, String name, {int timeoutMs = 5000}) async {
  if (c.kind == 'doq' || c.kind == 'system') return null;
  var addr = c.addr.trim();
  if (!addr.contains('://')) addr = 'udp://$addr';
  final u = Uri.tryParse(addr);
  if (u == null || u.host.isEmpty) return null;
  final id = Random().nextInt(65536);
  final q = dnsQueryOf(name, dnsTypeA, id);
  if (q == null) return null;
  final tls = c.kind == 'dot', doh = c.kind == 'doh';
  final port = u.hasPort ? u.port : (doh ? 443 : tls ? 853 : 53);
  final plainUdp = !doh && !tls && u.scheme != 'tcp';
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    try {
      w = await _Wire.connect(probe.port).timeout(left());
    } catch (_) {
      return null; // the test inbound is not there: nothing was asked
    }
    final sw = Stopwatch()..start();
    await w.socks(nodeTag, probe.secret, u.host, port).timeout(left());
    final List<int> data;
    if (doh) {
      await w.secure(u.host).timeout(left());
      final path = u.path.isEmpty || u.path == '/' ? '/dns-query' : u.path;
      final qs = {...u.queryParameters, 'dns': dohParam(q)};
      final target = '$path?${qs.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
      final req = utf8.encode('GET $target HTTP/1.1\r\nHost: ${u.host}\r\nUser-Agent: Jormungand\r\nAccept: application/dns-message\r\nConnection: close\r\n\r\n');
      final (status, body) = await w.getBytes(req).timeout(left());
      if (status != 200) return -1;
      data = body;
    } else {
      if (tls) await w.secure(u.host).timeout(left());
      data = await w.dnsStream(q).timeout(left());
    }
    final a = parseDnsAnswer(data, id);
    return a != null && a.rcode == 0 && !a.empty ? sw.elapsedMilliseconds : -1;
  } on ProbeRefused {
    return null; // the inbound did not take the user name: the request never ran
  } catch (_) {
    return plainUdp ? null : -1;
  } finally {
    w?.close();
  }
}

/// Whether the DNS flags make the candidate [tag] the one that answers [name] (the side's flagcheck name,
/// routing.dart `dnsFlagcheckName`) right now: true = it does, false = another one answers, or nothing did;
/// null = it cannot be told (the probe inbound is not there, or it has no flagcheck user: a sing-box started
/// by an older core). See [Probe.inbound] `flagChecks`.
Future<bool?> probeFlag(Probe probe, String tag, String name, {int timeoutMs = 1500}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  Duration left() => deadline.difference(DateTime.now());
  _Wire? w;
  try {
    try {
      w = await _Wire.connect(probe.port).timeout(left());
    } catch (_) {
      return null;
    }
    await w.socks(Probe.flagUser(tag), probe.secret, name, 80).timeout(left());
    return true;
  } on ProbeRefused {
    return null;
  } catch (_) {
    return false;
  } finally {
    w?.close();
  }
}

/// A loopback connection read by hand: SOCKS5, then TLS over it, then HTTP/1.1.
class _Wire {
  _Wire._(this._raw) {
    _listen();
  }

  static Future<_Wire> connect(int port) async => _Wire._(await RawSocket.connect(InternetAddress.loopbackIPv4, port));

  RawSocket _raw;
  StreamSubscription<RawSocketEvent>? _sub;
  final _buf = <int>[];
  Completer<void>? _more;
  bool _closed = false;

  void _listen() {
    _sub = _raw.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = _raw.read();
        if (d != null) _buf.addAll(d);
      } else if (e == RawSocketEvent.readClosed || e == RawSocketEvent.closed) {
        _closed = true;
      }
      _wake();
    }, onError: (Object _) {
      _closed = true;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    });
  }

  void _wake() {
    final c = _more;
    _more = null;
    c?.complete();
  }

  Future<void> _wait() {
    if (_closed) throw const SocketException('closed');
    return (_more ??= Completer<void>()).future;
  }

  Future<List<int>> _take(int n) async {
    while (_buf.length < n) {
      await _wait();
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> _write(List<int> b) async {
    var off = 0;
    while (off < b.length) {
      if (_closed) throw const SocketException('closed');
      final n = _raw.write(b, off);
      off += n;
      if (n == 0) await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> socks(String user, String pass, String host, int port) async {
    await _write([5, 1, 2]); // one method: user name / password
    final m = await _take(2);
    if (m[0] != 5 || m[1] != 2) throw const ProbeRefused('socks: no auth');
    final u = utf8.encode(user), pw = utf8.encode(pass);
    await _write([1, u.length, ...u, pw.length, ...pw]);
    if ((await _take(2))[1] != 0) throw const ProbeRefused('socks: auth refused');
    final h = utf8.encode(host);
    await _write([5, 1, 0, 3, h.length, ...h, port >> 8, port & 0xff]);
    final r = await _take(4);
    if (r[1] != 0) {
      const names = ['', 'general failure', 'not allowed', 'network unreachable', 'host unreachable', 'connection refused', 'TTL expired'];
      throw SocketException('socks: reply ${r[1]}${r[1] < names.length ? ' (${names[r[1]]})' : ''}');
    }
    await _take(switch (r[3]) { 1 => 4, 4 => 16, _ => (await _take(1))[0] } + 2);
  }

  Future<void> secure(String host) async {
    final sub = _sub!;
    _sub = null;
    _raw = await RawSecureSocket.secure(_raw, subscription: sub, host: host);
    _listen();
  }

  /// Sends a request, reads the response head (HEAD: no body); true when the server
  /// keeps the connection for the next one.
  Future<bool> request(List<int> req) async {
    await _write(req);
    int end;
    while ((end = _headEnd()) < 0) {
      await _wait();
    }
    final head = latin1.decode(_buf.sublist(0, end)).toLowerCase();
    _buf.removeRange(0, end + 4);
    if (!head.startsWith('http/1.')) throw const SocketException('not http');
    final close = RegExp(r'^connection:\s*close', multiLine: true).hasMatch(head);
    final keep = RegExp(r'^connection:\s*keep-alive', multiLine: true).hasMatch(head);
    return head.startsWith('http/1.1') ? !close : keep;
  }

  /// Sends a GET, reads the whole answer (a body over 256 KiB is an error): the status and the body as text.
  Future<(int, String)> get(List<int> req) async {
    final (status, body) = await getBytes(req);
    return (status, utf8.decode(body, allowMalformed: true));
  }

  /// [get] with the body as it came (a DNS message is binary).
  Future<(int, List<int>)> getBytes(List<int> req) async {
    await _write(req);
    int end;
    while ((end = _headEnd()) < 0) {
      await _wait();
    }
    final head = latin1.decode(_buf.sublist(0, end)).toLowerCase();
    _buf.removeRange(0, end + 4);
    final status = int.tryParse(RegExp(r'^http/1\.\d (\d{3})').firstMatch(head)?[1] ?? '');
    if (status == null) throw const SocketException('not http');
    const cap = 256 * 1024;
    final body = <int>[];
    if (RegExp(r'^transfer-encoding:.*chunked', multiLine: true).hasMatch(head)) {
      for (;;) {
        final size = int.tryParse((await _line()).split(';').first.trim(), radix: 16);
        if (size == null) throw const SocketException('bad chunk');
        if (size == 0) break;
        if (body.length + size > cap) throw const SocketException('answer too long');
        body.addAll(await _take(size));
        await _take(2);
      }
    } else {
      final len = int.tryParse(RegExp(r'^content-length:\s*(\d+)', multiLine: true).firstMatch(head)?[1] ?? '');
      if (len != null) {
        if (len > cap) throw const SocketException('answer too long');
        body.addAll(await _take(len));
      } else {
        // no length: the body ends where the server closes
        while (!_closed) {
          await _wait();
          if (_buf.length > cap) throw const SocketException('answer too long');
        }
        body.addAll(_buf);
        _buf.clear();
      }
    }
    return (status, body);
  }

  /// Sends a DNS message over a stream (DoT, DNS over TCP: a 2 byte length first) and reads one answer message.
  Future<List<int>> dnsStream(List<int> query) async {
    await _write([query.length >> 8, query.length & 255, ...query]);
    final len = await _take(2);
    return _take(len[0] << 8 | len[1]);
  }

  Future<String> _line() async {
    for (;;) {
      final i = _buf.indexOf(10);
      if (i >= 0) {
        final line = latin1.decode(_buf.sublist(0, i));
        _buf.removeRange(0, i + 1);
        return line.trim();
      }
      await _wait();
    }
  }

  int _headEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) return i;
    }
    return -1;
  }

  void close() {
    _closed = true;
    _sub?.cancel();
    _raw.close();
    _wake();
  }
}
