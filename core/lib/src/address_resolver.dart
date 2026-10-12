import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'address_book.dart';
import 'dns_wire.dart';
import 'routing.dart' show DnsCandidate;
import 'svc_fetch.dart';
import 'svc_in.dart';

// The core resolves the hostnames of its servers itself (docs/rules.md §6 → «Адреса серверов»): sing-box's own
// `domain_resolver` is fixed per outbound and cannot follow the DNS switching, so the config holds an address
// (address_pin.dart) and this resolver keeps the addresses fresh in the [AddressBook].
//
// A lookup goes through the direct side's DNS servers of Settings → DNS (what is reached without the
// tunnel): the encrypted ones first (DoH, then DoT, each in the side's order), then the plain ones (UDP /
// TCP), the OS resolver last. A server the failover judged dead is skipped. DoQ has no Dart client: skipped.
// A and AAAA go together (AAAA only with IPv6 on). DoH goes through the service fetcher's direct path
// ([ServiceFetch], with or without sing-box); DoT, UDP and the OS resolver are the core's own connections
// (outside_tunnel.dart → address-resolve).

/// What a lookup reads from the settings: the direct side's candidates in the DNS rules' order and the IPv6 setting.
class AddressSettings {
  const AddressSettings({this.candidates = const [], this.ipv6 = false});

  final List<DnsCandidate> candidates;
  final bool ipv6;
}

class _Got {
  _Got(this.v4, this.v6, this.ttl, this.with6);
  final List<String> v4, v6;
  final int ttl;
  final bool with6;
}

class _Fail implements Exception {
  _Fail(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class _Resp {
  const _Resp(this.data, [this.err]);
  final Uint8List? data;
  final String? err;
}

class _Try {
  _Try(this.id, this.label, this.run);
  final String id, label;
  final Future<_Got> Function() run;
}

final _rnd = Random();

class AddressResolver {
  AddressResolver({
    required this.book,
    required this.fetch,
    required this.settings,
    this.alive,
    this.log,
    this.attempt = const Duration(seconds: 3),
    this.budget = const Duration(seconds: 8),
    this.parallel = 8,
    this.negativeFor = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AddressBook book;

  /// The service fetcher DoH goes through (its `direct` path).
  final ServiceFetch Function() fetch;
  final Future<AddressSettings> Function() settings;

  /// A candidate (by id) the Sentinel judged dead is not asked; null = all are.
  final bool Function(String candidateId)? alive;

  /// `(level, text)` into the log (logs.md).
  final void Function(String level, String text)? log;

  /// One server's answer; all the servers of one lookup together; how many lookups run at once; how long a
  /// name that nobody answered is left alone (a lookup asked for explicitly ignores it).
  final Duration attempt, budget, negativeFor;
  final int parallel;
  final DateTime Function() _now;

  final _inflight = <String, Future<AddressEntry?>>{};
  final _failedAt = <String, int>{};
  final _skippedKinds = <String>{};
  int _active = 0;
  final _queue = <Completer<void>>[];

  void _note(String level, String text) => log?.call(level, text);

  /// Resolves [host] now (the cache is not asked) and puts the answer in the book; null = nobody answered, the
  /// old entry (if any) stays. A lookup already running for the name is joined. [why] goes into the log
  /// (`subscription`, `connect`, `node down`, …). Never throws.
  Future<AddressEntry?> lookup(String host, {required String why}) {
    final k = AddressBook.key(host);
    // a block body: `remove` returns this very future, which whenComplete would then wait for forever
    return _inflight.putIfAbsent(k, () => _limited(() => _run(k, why)).whenComplete(() {
          _inflight.remove(k);
        }));
  }

  Future<T> _limited<T>(Future<T> Function() f) async {
    if (_active >= parallel) {
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    }
    _active++;
    try {
      return await f();
    } finally {
      _active--;
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }

  /// Makes sure every host of [hosts] has an entry: the ones with none are resolved, all at once ([parallel] at a
  /// time), and waited for up to [wait]; what is not done then goes on in the background (the next config has
  /// it). Entries past their TTL (or without IPv6 knowledge while IPv6 is on) are refreshed in the background
  /// and not waited for. The hosts of [first] (DNS servers named by a host: a lookup may use them) go before the
  /// rest. A name nobody answered a short time ago is not asked again. Never throws.
  /// [refreshAll]: the fresh ones are refreshed too (a new server list: an address may have moved).
  Future<void> ensure(Iterable<String> hosts,
      {required String why, Duration wait = const Duration(seconds: 8), Iterable<String> first = const [], bool refreshAll = false}) async {
    final st = await settings();
    final all = {for (final h in [...first, ...hosts]) AddressBook.key(h)};
    final firstKeys = {for (final h in first) AddressBook.key(h)};
    final missing = <String>[], stale = <String>[];
    var cached = 0;
    for (final h in all) {
      final e = book.get(h);
      if (e == null) {
        if (!_recentlyFailed(h)) missing.add(h);
      } else if (refreshAll || !book.fresh(h) || (st.ipv6 && !e.with6)) {
        stale.add(h);
      } else {
        cached++;
      }
    }
    if (all.isNotEmpty) {
      _note('info', 'address: ${all.length} host${all.length == 1 ? '' : 's'} for $why: $cached from the cache, ${stale.length} stale (refreshed in the background), '
          '${missing.length} to resolve${missing.isEmpty ? '' : ' (waiting up to ${wait.inSeconds} s)'}');
    }
    for (final h in stale) {
      if (!_recentlyFailed(h)) unawaited(lookup(h, why: '$why, refresh'));
    }
    if (missing.isEmpty) return;
    final work = (() async {
      final a = [for (final h in missing) if (firstKeys.contains(h)) h];
      if (a.isNotEmpty) await Future.wait([for (final h in a) lookup(h, why: why)]);
      await Future.wait([for (final h in missing) if (!firstKeys.contains(h)) lookup(h, why: why)]);
    })();
    await work.timeout(wait, onTimeout: () {
      _note('warn', 'address: not everything resolved within ${wait.inSeconds} s for $why; the config keeps the names that are still unresolved');
    });
  }

  bool _recentlyFailed(String h) {
    final t = _failedAt[h];
    return t != null && _now().millisecondsSinceEpoch - t < negativeFor.inMilliseconds;
  }

  Future<AddressEntry?> _run(String host, String why) async {
    final sw = Stopwatch()..start();
    try {
      final st = await settings();
      final tries = _tries(host, st);
      var n = 0;
      for (final t in tries) {
        final left = budget - sw.elapsed;
        if (left <= Duration.zero) {
          _note('warn', 'address: $host: out of time (${budget.inMilliseconds} ms), ${tries.length - n} server${tries.length - n == 1 ? '' : 's'} not tried');
          break;
        }
        n++;
        final ts = Stopwatch()..start();
        try {
          final g = await t.run().timeout(left < attempt ? left : attempt, onTimeout: () => throw _Fail('timeout'));
          final e = _store(host, g, t.id);
          _failedAt.remove(host);
          final ips = e.ips(st.ipv6);
          _note('info', 'address: $host → ${ips.join(', ')} via ${t.id} (${t.label}) in ${ts.elapsedMilliseconds} ms [fresh, $why]'
              '${n > 1 ? ', after $n tries' : ''}');
          return e;
        } on _Fail catch (f) {
          _note('info', 'address: $host via ${t.id} (${t.label}) failed: ${f.reason} (${ts.elapsedMilliseconds} ms)${n < tries.length ? ', next' : ''}');
        } catch (e) {
          _note('info', 'address: $host via ${t.id} (${t.label}) failed: $e (${ts.elapsedMilliseconds} ms)${n < tries.length ? ', next' : ''}');
        }
      }
      _failedAt[host] = _now().millisecondsSinceEpoch;
      _note('warn', 'address: $host not resolved by any server in ${sw.elapsedMilliseconds} ms [$why]${book.get(host) == null ? '' : ': the cached address stays'}');
    } catch (e) {
      _note('warn', 'address: $host: lookup failed: $e [$why]');
    }
    return null;
  }

  /// The answer in the book. The same set of addresses as before keeps the old order and the cursor.
  AddressEntry _store(String host, _Got g, String via) {
    final old = book.get(host);
    final fresh = AddressEntry(v4: g.v4, v6: g.v6, at: _now().millisecondsSinceEpoch, ttl: g.ttl, via: via, with6: g.with6);
    final e = old != null && old.sameSet(fresh)
        ? AddressEntry(v4: old.v4, v6: old.v6, at: fresh.at, ttl: fresh.ttl, via: via, with6: g.with6 || old.with6, cursor: old.cursor)
        : fresh;
    book.put(host, e);
    return e;
  }

  /// The servers to ask, in order: encrypted, plain, the OS resolver.
  List<_Try> _tries(String host, AddressSettings st) {
    final enc = <_Try>[], plain = <_Try>[];
    for (final c in st.candidates) {
      if (c.side != 'direct' || c.kind == 'system') continue; // the OS resolver is always the last try
      if (c.kind == 'doq') {
        if (_skippedKinds.add('doq')) _note('info', 'address: DoQ servers are not used for lookups (no client for it)');
        continue;
      }
      if (alive != null && !alive!(c.id)) {
        _note('info', 'address: $host: ${c.id} skipped (judged dead)');
        continue;
      }
      switch (c.kind) {
        case 'doh':
          enc.add(_Try(c.id, 'DoH', () => _viaDoh(c, host, st.ipv6)));
        case 'dot':
          enc.add(_Try(c.id, 'DoT', () => _viaStream(c, host, st.ipv6, tls: true)));
        default:
          plain.add(_Try(c.id, c.addr.startsWith('tcp://') ? 'TCP' : 'UDP', () => c.addr.startsWith('tcp://') ? _viaStream(c, host, st.ipv6, tls: false) : _viaUdp(c, host, st.ipv6)));
      }
    }
    return [...enc, ...plain, _Try('system', 'OS resolver', () => _viaSystem(host, st.ipv6))];
  }

  // ── transports ──

  /// Reads [r] (A first, AAAA second when asked) into one result. Failure if there is no usable answer.
  _Got _read(String host, List<_Resp> r, List<int> ids, bool ipv6) {
    final v4 = <String>[], v6 = <String>[];
    var ttl = -1, with6 = false;
    String? why;
    for (var i = 0; i < r.length; i++) {
      final data = r[i].data;
      if (data == null) {
        why ??= r[i].err ?? 'no answer';
        continue;
      }
      final a = parseDnsAnswer(data, ids[i]);
      if (a == null) {
        why ??= 'malformed answer';
        continue;
      }
      if (a.rcode != 0) {
        why ??= a.rcode == 3 ? 'NXDOMAIN' : 'rcode ${a.rcode}';
        continue;
      }
      if (i == 1) with6 = true;
      v4.addAll(a.v4);
      v6.addAll(a.v6);
      if (!a.empty) ttl = ttl < 0 ? a.ttl : min(ttl, a.ttl);
    }
    if (v4.isEmpty && (v6.isEmpty || !ipv6)) throw _Fail(why ?? 'no addresses in the answer');
    return _Got(v4, ipv6 ? v6 : const [], ttl < 0 ? 0 : ttl, with6 && ipv6);
  }

  (List<Uint8List>, List<int>) _queries(String host, bool ipv6) {
    final qs = <Uint8List>[], ids = <int>[];
    for (final t in [dnsTypeA, if (ipv6) dnsTypeAaaa]) {
      final id = _rnd.nextInt(65536);
      final q = dnsQueryOf(host, t, id);
      if (q == null) throw _Fail('not a valid name');
      qs.add(q);
      ids.add(id);
    }
    return (qs, ids);
  }

  Future<_Got> _viaDoh(DnsCandidate c, String host, bool ipv6) async {
    final u = Uri.tryParse(c.addr);
    if (u == null || u.host.isEmpty) throw _Fail('bad address ${c.addr}');
    if (AddressBook.key(u.host) == host) throw _Fail('the server is the name itself');
    final (qs, ids) = _queries(host, ipv6);
    final path = u.path.isEmpty || u.path == '/' ? '/dns-query' : u.path;
    Future<_Resp> one(Uint8List q) async {
      final cancel = Completer<void>();
      final timer = Timer(attempt, () => cancel.isCompleted ? null : cancel.complete());
      try {
        final r = await fetch().get(
          u.replace(path: path, queryParameters: {...u.queryParameters, 'dns': dohParam(q)}),
          purpose: 'address',
          policy: const SvcPolicy.race(kinds: {SvcKind.direct}),
          headers: const {'accept': 'application/dns-message'},
          maxBytes: 16 * 1024,
          cancel: cancel.future,
        );
        final resp = r.response;
        if (resp == null) {
          final f = r.failure!;
          return _Resp(null, f.paths.isEmpty ? f.code : f.paths.map((p) => p.code).join('/'));
        }
        return resp.ok ? _Resp(resp.body) : _Resp(null, 'http ${resp.status}');
      } finally {
        timer.cancel();
      }
    }

    return _read(host, await Future.wait([for (final q in qs) one(q)]), ids, ipv6);
  }

  /// The address a hostname-named server is reached at: the book's. Throws when there is none.
  String _serverIp(String serverHost) {
    if (InternetAddress.tryParse(serverHost) != null) return serverHost;
    final ip = book.get(serverHost)?.pick(false);
    if (ip == null) throw _Fail('the server\'s own name $serverHost has no address yet');
    return ip;
  }

  Future<_Got> _viaStream(DnsCandidate c, String host, bool ipv6, {required bool tls}) async {
    final u = Uri.tryParse(c.addr);
    if (u == null || u.host.isEmpty) throw _Fail('bad address ${c.addr}');
    if (AddressBook.key(u.host) == host) throw _Fail('the server is the name itself');
    final ip = _serverIp(u.host);
    final port = u.hasPort ? u.port : (tls ? 853 : 53);
    final (qs, ids) = _queries(host, ipv6);
    Socket s;
    try {
      final raw = await Socket.connect(ip, port, timeout: attempt);
      // the certificate is checked against the server's name (an address literal: against the address)
      s = tls ? await SecureSocket.secure(raw, host: u.host) : raw;
    } on HandshakeException catch (e) {
      throw _Fail('tls: ${e.message}');
    } on SocketException catch (e) {
      throw _Fail('connect: ${e.message}');
    } on TlsException catch (e) {
      throw _Fail('tls: ${e.message}');
    }
    try {
      for (final q in qs) {
        s.add([q.length >> 8, q.length & 255, ...q]);
      }
      await s.flush();
      final got = <int>[];
      final out = List<Uint8List?>.filled(qs.length, null);
      final done = Completer<void>();
      final sub = s.listen((d) {
        got.addAll(d);
        while (got.length >= 2) {
          final len = got[0] << 8 | got[1];
          if (got.length < 2 + len) break;
          final msg = Uint8List.fromList(got.sublist(2, 2 + len));
          got.removeRange(0, 2 + len);
          for (var i = 0; i < ids.length; i++) {
            if (msg.length >= 2 && msg[0] == ids[i] >> 8 && msg[1] == (ids[i] & 255)) out[i] = msg;
          }
        }
        if (out.every((m) => m != null) && !done.isCompleted) done.complete();
      }, onDone: () => done.isCompleted ? null : done.complete(), onError: (_) => done.isCompleted ? null : done.complete());
      await done.future.timeout(attempt, onTimeout: () {});
      await sub.cancel();
      return _read(host, [for (final m in out) _Resp(m, 'no answer')], ids, ipv6);
    } finally {
      s.destroy();
    }
  }

  Future<_Got> _viaUdp(DnsCandidate c, String host, bool ipv6) async {
    var addr = c.addr;
    if (!addr.contains('://')) addr = 'udp://$addr';
    final u = Uri.tryParse(addr);
    if (u == null || u.host.isEmpty) throw _Fail('bad address ${c.addr}');
    if (AddressBook.key(u.host) == host) throw _Fail('the server is the name itself');
    final ip = InternetAddress(_serverIp(u.host));
    final port = u.hasPort ? u.port : 53;
    final (qs, ids) = _queries(host, ipv6);
    final sock = await RawDatagramSocket.bind(ip.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
    try {
      final out = List<Uint8List?>.filled(qs.length, null);
      final done = Completer<void>();
      final sub = sock.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = sock.receive();
        if (d == null || d.data.length < 2) return;
        for (var i = 0; i < ids.length; i++) {
          if (d.data[0] == ids[i] >> 8 && d.data[1] == (ids[i] & 255)) out[i] = d.data;
        }
        if (out.every((m) => m != null) && !done.isCompleted) done.complete();
      });
      for (final q in qs) {
        sock.send(q, ip, port);
      }
      await done.future.timeout(attempt, onTimeout: () {});
      await sub.cancel();
      return _read(host, [for (final m in out) _Resp(m, 'no answer')], ids, ipv6);
    } finally {
      sock.close();
    }
  }

  Future<_Got> _viaSystem(String host, bool ipv6) async {
    try {
      final r = await InternetAddress.lookup(host, type: ipv6 ? InternetAddressType.any : InternetAddressType.IPv4);
      final v4 = [for (final a in r) if (a.type == InternetAddressType.IPv4) a.address];
      final v6 = [for (final a in r) if (a.type == InternetAddressType.IPv6) a.address];
      if (v4.isEmpty && v6.isEmpty) throw _Fail('no addresses');
      return _Got(v4, v6, 0, ipv6);
    } on SocketException catch (e) {
      throw _Fail(e.message);
    }
  }
}
