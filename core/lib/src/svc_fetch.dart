/// The core's own requests (subscriptions, rule lists, app updates, the report) over several paths
/// at once: `direct`, the main flow, every route ([SvcIn], svc_in.dart). One request is the race — no
/// separate probe — and the first path that brings the start of the answer carries the rest.
///
/// - [SvcPolicy.race]: every available path at once; [SvcPolicy.strict]: one path by id.
/// - Every path reads only the first [sample] bytes (~64 KiB); the winner then goes on with the same
///   response, the others are cut. When two answer within the grace the tunnel wins ([SvcPrefer.tunnel]);
///   [SvcPrefer.direct] (app updates: the traffic of the VPN is not wasted) waits [preferGrace] for the
///   direct path and takes it even when the tunnel was faster.
/// - A transfer that goes quiet ([stall]: no bytes for 3 s, the shared rule of stall.dart) or breaks is
///   resumed with `Range` on the next path that works; the paths that failed are not asked again in that call.
/// - The winner is remembered per host, preference, network epoch and core epoch (the Sentinel context):
///   the next request to that host goes to it alone first, and the whole race starts over after a failure,
///   a change of the network or a reconnect.
/// - Nothing answered on any path → a [SvcFailure] with a reason code per path, and a [Suspicion] to hand to
///   the gate ([SvcFailure.suspicion]); [SvcFailure.advice] says when to try again ([RetryPolicy]).
/// - sing-box not running → one plain direct socket, no race.
///
/// Codes only, no prose: the callers and the journal turn them into words.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'sentinel/context.dart';
import 'sentinel/model.dart';
import 'sentinel/retry.dart';
import 'stall_guard.dart';
import 'svc_in.dart';

/// Which paths a call uses.
class SvcPolicy {
  /// All available paths at once ([kinds]: only these kinds).
  const SvcPolicy.race({this.kinds}) : only = null;

  /// The path with this id (`direct`, `main`, `route0`) alone.
  const SvcPolicy.strict(String this.only) : kinds = null;

  final String? only;
  final Set<SvcKind>? kinds;
}

/// Who wins when two paths bring their first bytes close together.
enum SvcPrefer { tunnel, direct }

/// A part of the file: bytes [start]..[end] (inclusive; null = to the end).
class SvcRange {
  const SvcRange(this.start, [this.end]);

  final int start;
  final int? end;
}

/// The path taken without sing-box: a plain socket of the core's own process.
const svcPlainId = 'plain';

/// The same request answered whole by a path of the other side (direct vs tunnel) within the grace after the
/// winner finished ([ServiceFetch.get] with `collect`): lets the caller compare what the two ways return.
class SvcPeer {
  const SvcPeer(this.via, this.kind, this.status, this.headers, this.body, [this.ms = 0]);

  final String via;
  final SvcKind kind;
  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  /// When its body ended, ms from the start of this path's request.
  final int ms;

  /// SHA-256 of the body, hex.
  String get hash => sha256.convert(body).toString();
}

class SvcResponse {
  SvcResponse({
    required this.status,
    required this.headers,
    required this.body,
    required this.bytes,
    required this.via,
    required this.kind,
    this.resumes = 0,
    this.took = Duration.zero,
    this.finishedMs = 0,
    this.peers = const [],
  });

  /// With `collect`: good answers of the other side that arrived whole in time (empty otherwise).
  final List<SvcPeer> peers;

  /// SHA-256 of the body, hex (a body that went to `onData` is empty).
  String get hash => sha256.convert(body).toString();

  final int status;

  /// Lower-case names, values joined by `, `.
  final Map<String, String> headers;

  /// Empty when the body went to `onData`.
  final Uint8List body;

  /// The body's length (also when it went to `onData`).
  final int bytes;

  /// The id of the path that finished the transfer (`plain` without sing-box).
  final String via;
  final SvcKind kind;

  /// How many times the transfer went on from where it stopped on another path.
  final int resumes;
  final Duration took;

  /// When the body of the path that finished it ended, ms from the start of that path's request (not the wait for
  /// the peers; 0 when unknown).
  final int finishedMs;

  /// 2xx or 304: the thing asked for. Anything else is the server's own answer, not a failure of the way.
  bool get ok => (status >= 200 && status < 300) || status == 304;
}

/// What one path ran into: [code] is `timeout` (no answer), `stall`, `connect`, `refused`, `reset`, `dns`,
/// `tls`, `tunnel` (the proxy could not open the way on), `auth`, `closed`, `range`, `changed`, `empty` (a 200 with no
/// body, only when the call asked `rejectEmpty`), `http`, `error`.
class SvcPathFailure {
  const SvcPathFailure(this.id, this.kind, this.code, this.ms, [this.detail = '']);

  final String id;
  final SvcKind kind;
  final String code;
  final int ms;

  /// The raw text of the error, cut: for the log, not for a screen.
  final String detail;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'code': code, 'ms': ms, if (detail.isNotEmpty) 'detail': detail};
}

/// No path brought an answer. [code]: `allFailed`, `noPath` (the policy names no path that exists),
/// `tooBig` (more than `maxBytes`), `cancelled`.
class SvcFailure {
  SvcFailure(this.code, this.host, this.paths, {this.received = 0, this.advice, this.purpose = 'misc', this.tunnelTried = false, String? retryKey})
      : retryKey = retryKey ?? purpose;

  final String code;
  final String host;
  final String purpose;

  /// The retry rules this failure was counted in ([ServiceFetch.retryFor]); the purpose unless the call named one.
  final String retryKey;
  final List<SvcPathFailure> paths;

  /// Bytes of the body delivered before it broke.
  final int received;

  /// When to try again; only for `allFailed`.
  final RetryAdvice? advice;
  final bool tunnelTried;

  /// The suspicion to hand to `Sentinel.suspect` (kind `svc.fetch`, subject `{host, purpose}`, the evidence
  /// per path); null unless every path failed (the other codes are the caller's own doing).
  Suspicion? suspicion({Duration window = Duration.zero, List<Check> checks = const [], SuspicionEvent? event, Why? why}) {
    if (code != 'allFailed') return null;
    return Suspicion(
      kind: 'svc.fetch',
      subject: {'host': host, 'purpose': purpose},
      evidence: {'paths': [for (final p in paths) p.toJson()], 'received': received},
      checks: checks,
      window: window,
      viaCore: tunnelTried,
      event: event,
      why: why,
    );
  }

  @override
  String toString() => 'SvcFailure($code, $host, ${[for (final p in paths) '${p.id}:${p.code}'].join(' ')})';
}

class SvcResult {
  const SvcResult.answer(SvcResponse this.response) : failure = null;
  const SvcResult.failed(SvcFailure this.failure) : response = null;

  final SvcResponse? response;
  final SvcFailure? failure;

  /// An answer that is the thing asked for.
  bool get ok => response?.ok ?? false;
}

class ServiceFetch {
  ServiceFetch({
    required SvcIn? Function() endpoint,
    this.context,
    this.sample = 64 * 1024,
    this.tieGrace = const Duration(milliseconds: 300),
    this.preferGrace = const Duration(seconds: 2),
    this.collectGrace = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 10),
    this.headerTimeout = const Duration(seconds: 15),
    this.stall = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 30),
    this.defaultMaxBytes = 32 * 1024 * 1024,
  }) : _endpoint = endpoint;

  final SvcIn? Function() _endpoint;

  /// The Sentinel's context: the epochs the winner memory is kept by, and what the retry waits for.
  final ContextTracker? context;

  /// How much of the answer every path reads before one is chosen.
  final int sample;

  /// The tunnel's grace when the direct path answered first (and the tunnel is preferred).
  final Duration tieGrace;

  /// The direct path's grace when the tunnel answered first and [SvcPrefer.direct] is asked.
  final Duration preferGrace;

  /// `collect`: how long after the winner finished a path of the other side may still bring its whole answer.
  final Duration collectGrace;

  /// Connecting to the inbound (or, without sing-box, to the server).
  final Duration connectTimeout;

  /// The whole opening of a path: connecting, the proxy's tunnel, TLS, the response's head.
  final Duration headerTimeout;

  /// No body bytes for this long = the way is dead (stall.dart).
  final Duration stall;

  /// The cap of the race: the first bytes of some path within this, else all failed with `timeout`.
  final Duration timeout;

  /// The body's cap when a call names none and has no `onData`.
  final int defaultMaxBytes;

  final _memo = <String, _Memo>{};
  final _retry = <String, RetryPolicy>{};

  /// The retry rules of [purpose] (a count of its own, so one failing list does not slow the updates).
  /// Needs the [context]; without it a failure advises a first-step wait every time.
  RetryPolicy retryFor(String purpose) => _retry.putIfAbsent(purpose, () => RetryPolicy(context ?? ContextTracker()));

  /// Waits as a [SvcFailure.advice] says. Null advice: at once.
  Future<void> waitRetry(SvcFailure f) => f.advice == null ? Future.value() : retryFor(f.retryKey).wait(f.advice!);

  /// The path last remembered as the winner for [uri]'s host (tests, diagnostics); null = none valid.
  String? remembered(Uri uri, {SvcPrefer prefer = SvcPrefer.tunnel}) => _recall(_memoKey(uri, prefer))?.pathId;

  /// Forgets every winner.
  void forget() => _memo.clear();

  /// GETs [uri]. [purpose]: what it is for (`ruleset`, `subscription`, `update`, `report`, …): the key of
  /// the retry count and the subject of the suspicion. [range]: a part of the file. [maxBytes]: more than
  /// this is a failure `tooBig` (default [defaultMaxBytes]; unlimited with [onData]). [onData]: the body
  /// is handed over in pieces instead of being collected (downloads to a file); [cancel] ends the call.
  /// [retryKey]: the key of the retry count when it must be finer than the purpose (a subscription, a list).
  /// [collect] (small answers, not with [onData] or a range): the remembered winner is not used (the whole race
  /// runs), and after the winner finished the paths of the other side (direct vs tunnel) get [collectGrace] to
  /// bring their whole answer too — it comes back in [SvcResponse.peers] to be compared with the winner's.
  /// [rejectEmpty] (same limits): a 200 with no body at all is that path's failure (`empty`), never an answer, so
  /// the race goes on with the other paths; a 304 is not touched.
  Future<SvcResult> get(
    Uri uri, {
    String purpose = 'misc',
    String? retryKey,
    bool collect = false,
    bool rejectEmpty = false,
    SvcPolicy policy = const SvcPolicy.race(),
    SvcPrefer prefer = SvcPrefer.tunnel,
    SvcRange? range,
    int? maxBytes,
    Map<String, String>? headers,
    void Function(List<int> chunk)? onData,
    Future<void>? cancel,
  }) =>
      _Call(this, uri, purpose, policy, prefer, range, maxBytes ?? (onData == null ? defaultMaxBytes : null), headers ?? const {}, onData, cancel,
              retryKey: retryKey ?? purpose,
              collect: collect && onData == null && range == null,
              rejectEmpty: rejectEmpty && onData == null && range == null)
          .run();

  String _memoKey(Uri uri, SvcPrefer prefer) => '${prefer.name}|${uri.host.toLowerCase()}:${uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80)}';

  int get _net => context?.netEpoch ?? 0;
  int get _core => context?.coreEpoch ?? 0;

  _Memo? _recall(String key) {
    final m = _memo[key];
    if (m == null) return null;
    if (m.net != _net || m.core != _core) {
      _memo.remove(key);
      return null;
    }
    return m;
  }
}

class _Memo {
  _Memo(this.pathId, this.net, this.core);

  final String pathId;
  final int net, core;
}

enum _St { running, ready, answered, failed, killed }

/// One request on one path: opens, reads the first [ServiceFetch.sample] bytes, then waits (paused) to be
/// chosen or cut.
class _Attempt {
  _Attempt(this.f, this.path, this.proxy, this.sw);

  final ServiceFetch f;
  final SvcPath path;

  /// The `findProxy` answer.
  final String proxy;
  final Stopwatch sw;

  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  _St st = _St.running;
  int status = 0;
  final headers = <String, String>{};
  final head = BytesBuilder(copy: false);

  /// Bytes of the body to throw away at its start (a server that answered 200 to a Range request) and
  /// how many to take after that (null = all).
  int skip = 0;
  int? limit;
  int _taken = 0;
  bool bodyDone = false;
  void Function(List<int>)? sink;
  String? code;
  String detail = '';
  int ms = 0;

  /// The body ended at (ms of [sw]); 0 until then.
  int doneMs = 0;

  /// A 200 with no body at all fails with `empty` (see [ServiceFetch.get]).
  bool rejectEmpty = false;

  /// Told on every change of [st] (the race looks again).
  void Function()? onChange;

  /// The body ended or broke, or the attempt was cut (the drain).
  final finished = Completer<void>();

  bool get tunnel => path.tunnel;
  bool get plain => path.id == svcPlainId;

  void _set(_St s) {
    if (st != _St.running && st != _St.ready) return;
    st = s;
    ms = sw.elapsedMilliseconds;
    onChange?.call();
  }

  void fail(String c, Object? e) {
    if (st != _St.running && st != _St.ready) return;
    code = c;
    final text = e == null ? '' : '$e';
    detail = text.length > 160 ? text.substring(0, 160) : text;
    _release();
    _set(_St.failed);
    if (!finished.isCompleted) finished.complete();
  }

  /// Cut by the race (it lost) or by the call.
  void kill() {
    _release();
    if (st == _St.running || st == _St.ready) _set(_St.killed);
    if (!finished.isCompleted) finished.complete();
  }

  void _release() {
    unawaited(_sub?.cancel());
    _sub = null;
    _client?.close(force: true);
  }

  /// [position]: where in the file the body should start (0 = from the beginning); [rangeEnd]: the last
  /// byte wanted; [validator]: the ETag / Last-Modified of an earlier part (a resume must be of the same file).
  Future<void> open(Uri uri, Map<String, String> extra, {required int position, required int? rangeEnd, required bool ranged, String? validator, int? maxBytes}) async {
    final client = _client = HttpClient()
      ..connectionTimeout = f.connectTimeout
      ..findProxy = ((_) => proxy)
      ..userAgent = null;
    try {
      final HttpClientResponse res = await (() async {
        final req = await client.getUrl(uri);
        req.followRedirects = true;
        req.maxRedirects = 5;
        for (final e in extra.entries) {
          req.headers.set(e.key, e.value);
        }
        if (ranged || position > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$position-${rangeEnd ?? ''}');
          if (position > 0 && validator != null) req.headers.set(HttpHeaders.ifRangeHeader, validator);
        }
        return req.close();
      }())
          .timeout(f.headerTimeout, onTimeout: () => throw TimeoutException('head'));
      status = res.statusCode;
      res.headers.forEach((n, v) => headers[n.toLowerCase()] = v.join(', '));
      final ok = (status >= 200 && status < 300) || status == 304;
      if (!plain && status == 407) return fail('auth', 'HTTP 407');
      if (ok && maxBytes != null && res.contentLength > maxBytes) return fail('tooBig', 'length ${res.contentLength}');
      if (ok && (ranged || position > 0)) {
        if (status == 206) {
          final m = RegExp(r'bytes\s+(\d+)-').firstMatch(headers['content-range'] ?? '');
          if (m == null || int.parse(m.group(1)!) != position) return fail('range', headers['content-range'] ?? 'no Content-Range');
        } else if (status == 200) {
          // the server ignored the Range: the part wanted is cut out of the whole; a resume of a file whose
          // validator we know is not safe then (If-Range sent: a 200 means it changed)
          if (position > 0 && validator != null) return fail('changed', 'HTTP 200 to If-Range');
          skip = position;
          if (rangeEnd != null) limit = rangeEnd + 1 - position;
        }
      }
      _sub = stallGuard(res, f.stall, 'no body bytes for ${spanText(f.stall)}').listen(
        _onChunk,
        onError: (Object e) => fail(e is TimeoutException ? 'stall' : classify(e), e),
        onDone: _onDone,
        cancelOnError: true,
      );
      // (a status that is not `ok` is an answer of the server: what comes is read up to the sample, then `answered`)
    } catch (e) {
      fail(e is TimeoutException ? 'timeout' : classify(e), e);
    }
  }

  void _onChunk(List<int> c) {
    var data = c;
    if (skip > 0) {
      if (c.length <= skip) {
        skip -= c.length;
        return;
      }
      data = c.sublist(skip);
      skip = 0;
    }
    var atLimit = false;
    final lim = limit;
    if (lim != null) {
      final left = lim - _taken;
      if (data.length >= left) {
        data = data.sublist(0, left);
        atLimit = true;
      }
    }
    _taken += data.length;
    if (data.isNotEmpty) {
      final s = sink;
      if (s != null) {
        s(data);
      } else {
        head.add(data);
      }
    }
    if (atLimit) {
      _onDone();
      return;
    }
    if (sink == null && head.length >= f.sample && st == _St.running) {
      _sub?.pause();
      _reach();
    }
  }

  void _onDone() {
    if (bodyDone) return;
    bodyDone = true;
    doneMs = sw.elapsedMilliseconds;
    if (rejectEmpty && status == 200 && sink == null && _taken == 0) return fail('empty', 'empty body');
    unawaited(_sub?.cancel());
    _sub = null;
    _client?.close(force: true);
    _reach();
    if (!finished.isCompleted) finished.complete();
  }

  /// The sample is read (or the body ended): a good answer is `ready`, another one `answered`.
  void _reach() {
    final ok = (status >= 200 && status < 300) || status == 304;
    _set(ok ? _St.ready : _St.answered);
  }

  /// The chosen one: the body goes on to [to].
  void promote(void Function(List<int>) to) {
    sink = to;
    final first = head.takeBytes();
    if (first.isNotEmpty) to(first);
    if (!bodyDone) _sub?.resume();
  }

  static String classify(Object e) {
    if (e is HandshakeException || e is TlsException) return 'tls';
    if (e is TimeoutException) return 'timeout';
    if (e is SocketException) {
      final m = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      if (m.contains('lookup') || m.contains('resolve') || m.contains('no address')) return 'dns';
      if (m.contains('refused')) return 'refused';
      if (m.contains('reset') || m.contains('aborted') || m.contains('broken pipe')) return 'reset';
      return 'connect';
    }
    if (e is HttpException) {
      final m = e.message.toLowerCase();
      if (m.contains('proxy')) return 'tunnel';
      if (m.contains('closed')) return 'closed';
      return 'http';
    }
    return 'error';
  }
}

class _Call {
  _Call(this.f, this.uri, this.purpose, this.policy, this.prefer, this.range, this.maxBytes, this.extra, this.onData, this.cancel,
      {required this.retryKey, required this.collect, required this.rejectEmpty})
      : key = f._memoKey(uri, prefer),
        net0 = f._net,
        core0 = f._core;

  final ServiceFetch f;
  final Uri uri;
  final String purpose;
  final SvcPolicy policy;
  final SvcPrefer prefer;
  final SvcRange? range;
  final int? maxBytes;
  final Map<String, String> extra;
  final void Function(List<int>)? onData;
  final Future<void>? cancel;
  final String retryKey;
  final bool collect;
  final bool rejectEmpty;
  final String key;
  final int net0, core0;

  /// Attempts of the other side kept alive past the race for [_collectPeers].
  final _peers = <_Attempt>[];

  final sw = Stopwatch()..start();
  final failures = <SvcPathFailure>[];
  final excluded = <String>{};
  final out = BytesBuilder(copy: false);
  int got = 0;
  int resumes = 0;
  bool cancelled = false, tooBig = false, tunnelTried = false;
  String? validator;
  final _live = <_Attempt>[];

  /// The first path that carried the body: its status and headers are the answer's, whoever finishes it.
  _Attempt? _first;

  int get _base => range?.start ?? 0;

  Future<SvcResult> run() async {
    final c = cancel;
    if (c != null) {
      unawaited(c.then((_) {
        cancelled = true;
        for (final a in List.of(_live)) {
          a.kill();
        }
      }));
    }
    try {
      var round = 0;
      while (!cancelled && !tooBig) {
        final ep = f._endpoint();
        var cands = _candidates(ep);
        if (cands.isEmpty) break;
        // the first round: the remembered winner alone, when it is still a path
        var memoOnly = false;
        if (round++ == 0 && !collect) {
          final m = f._recall(key);
          final one = m == null ? const <SvcPath>[] : [for (final p in cands) if (p.id == m.pathId) p];
          if (one.isNotEmpty) {
            cands = one;
            memoOnly = true;
          }
        }
        final won = await _race(ep, cands);
        if (cancelled || tooBig) break;
        if (won == null) {
          // the remembered path gave nothing (it is in [excluded] now): forget it, the whole race is next
          if (memoOnly) {
            f._memo.remove(key);
            continue;
          }
          break; // every path of the round failed, and the round had all that were left
        }
        if (won.st == _St.answered) return SvcResult.answer(_response(won, won.head.takeBytes()));
        _first ??= won;
        final err = await _drain(won);
        if (cancelled || tooBig) break;
        if (err == null) {
          if (won.path.id != svcPlainId) f._memo[key] = _Memo(won.path.id, net0, core0);
          f.retryFor(retryKey).reset();
          final peers = await _collectPeers();
          return SvcResult.answer(_response(won, out.takeBytes(), peers));
        }
        _dropPeers();
        // the transfer broke on this path: on from where it stopped, on the next one
        failures.add(SvcPathFailure(won.path.id, won.path.kind, err, won.sw.elapsedMilliseconds, won.detail));
        excluded.add(won.path.id);
        f._memo.remove(key);
        resumes++;
      }
    } finally {
      for (final a in List.of(_live)) {
        a.kill();
      }
    }
    return SvcResult.failed(_failure());
  }

  SvcFailure _failure() {
    final String code;
    RetryAdvice? advice;
    if (cancelled) {
      code = 'cancelled';
    } else if (tooBig) {
      code = 'tooBig';
    } else if (failures.isEmpty) {
      code = 'noPath';
    } else {
      code = 'allFailed';
      final ctx = f.context;
      final restart = ctx != null &&
          (ctx.coreEpoch != core0 || const {CorePhase.starting, CorePhase.settling, CorePhase.recovering}.contains(ctx.phase));
      advice = f.retryFor(retryKey).advise(restart ? RetryKind.ownRestart : RetryKind.network);
    }
    return SvcFailure(code, uri.host.toLowerCase(), failures,
        received: got, advice: advice, purpose: purpose, tunnelTried: tunnelTried, retryKey: retryKey);
  }

  void _dropPeers() {
    for (final a in _peers) {
      a.kill();
      _live.remove(a);
    }
    _peers.clear();
  }

  /// The winner is done: the attempts of the other side still alive get [ServiceFetch.collectGrace] (from now) to
  /// bring their whole good answer. Whatever is not whole by then is cut (the call's `finally`).
  Future<List<SvcPeer>> _collectPeers() async {
    final peers = List.of(_peers);
    _peers.clear();
    if (peers.isEmpty) return const [];
    final until = DateTime.now().add(f.collectGrace);
    Duration left() => until.difference(DateTime.now());
    Future<SvcPeer?> one(_Attempt a) async {
      if (a.st == _St.running) {
        final changed = Completer<void>();
        a.onChange = () {
          if (!changed.isCompleted) changed.complete();
        };
        await changed.future.timeout(left(), onTimeout: () {});
        a.onChange = null;
      }
      if (a.st != _St.ready) return null;
      final b = BytesBuilder(copy: false);
      final m = maxBytes;
      a.promote((c) {
        b.add(c);
        if (m != null && b.length > m) a.kill();
      });
      await a.finished.future.timeout(left(), onTimeout: () {});
      if (a.st != _St.ready || !a.bodyDone) return null;
      return SvcPeer(a.path.id, a.path.kind, a.status, a.headers, b.takeBytes(), a.doneMs);
    }

    final done = await Future.wait(peers.map(one));
    return [
      for (final p in done)
        if (p != null) p,
    ];
  }

  SvcResponse _response(_Attempt a, Uint8List body, [List<SvcPeer> peers = const []]) => SvcResponse(
        peers: peers,
        finishedMs: a.doneMs,
        status: (_first ?? a).status,
        headers: (_first ?? a).headers,
        body: body,
        bytes: a.st == _St.answered ? body.length : got,
        via: a.path.id,
        kind: a.path.kind,
        resumes: resumes,
        took: sw.elapsed,
      );

  /// The paths this round may use. Without sing-box: the plain socket.
  List<SvcPath> _candidates(SvcIn? ep) {
    if (ep == null) {
      final only = policy.only, kinds = policy.kinds;
      if (only != null && only != 'direct' && only != svcPlainId) return const [];
      if (kinds != null && !kinds.contains(SvcKind.direct)) return const [];
      return excluded.contains(svcPlainId) ? const [] : const [SvcPath(svcPlainId, SvcKind.direct, svcPlainId, '')];
    }
    return [
      for (final p in ep.paths)
        if (!excluded.contains(p.id) &&
            (policy.only == null || policy.only == p.id) &&
            (policy.kinds == null || policy.kinds!.contains(p.kind)))
          p,
    ];
  }

  Future<_Attempt?> _race(SvcIn? ep, List<SvcPath> cands) async {
    final attempts = <_Attempt>[];
    final base = _base + got;
    final ranged = range != null || got > 0;
    final rangeEnd = range?.end;
    for (final p in cands) {
      final a = _Attempt(f, p, p.id == svcPlainId || ep == null ? 'DIRECT' : ep.proxyFor(p), Stopwatch()..start())
        ..rejectEmpty = rejectEmpty && !ranged;
      attempts.add(a);
      _live.add(a);
      if (p.tunnel) tunnelTried = true;
    }
    // every change of an attempt, and the timers, wake the loop below (a poke between its look and its wait
    // is not lost: the completer stays until the loop has woken)
    var wake = Completer<void>();
    void poke() {
      if (!wake.isCompleted) wake.complete();
    }

    for (final a in attempts) {
      a.onChange = poke;
    }
    final timers = <Timer>[];
    final order = <_Attempt>[]; // good answers, in the order they came
    final answers = <_Attempt>[];
    final seen = <_Attempt>{};
    DateTime? firstAt;
    var deadlineHit = false, graceSet = false;
    timers.add(Timer(f.timeout, () {
      deadlineHit = true;
      poke();
    }));
    for (final a in attempts) {
      unawaited(a.open(uri, extra, position: base, rangeEnd: rangeEnd, ranged: ranged, validator: validator, maxBytes: maxBytes));
    }
    // the chosen one has to be promoted before the others are cut
    _Attempt? winner;
    try {
      while (true) {
        if (cancelled || tooBig) break;
        for (final a in attempts) {
          if (seen.contains(a) || a.st == _St.running) continue;
          if (a.st == _St.ready) {
            seen.add(a);
            order.add(a);
            firstAt ??= DateTime.now();
          } else if (a.st == _St.answered) {
            seen.add(a);
            answers.add(a);
          } else if (a.st == _St.failed) {
            seen.add(a);
            if (a.code == 'tooBig') tooBig = true;
            failures.add(SvcPathFailure(a.path.id, a.path.kind, a.code ?? 'error', a.ms, a.detail));
            excluded.add(a.path.id);
          } else {
            seen.add(a);
          }
        }
        if (deadlineHit) {
          for (final a in attempts) {
            if (a.st == _St.running) a.fail('timeout', 'no answer in ${spanText(f.timeout)}');
          }
          if (attempts.any((a) => a.st == _St.failed && !seen.contains(a))) continue;
        }
        final running = attempts.where((a) => a.st == _St.running).toList();
        if (order.isNotEmpty) {
          bool wantedKind(_Attempt a) => prefer == SvcPrefer.tunnel ? a.tunnel : !a.tunnel;
          final liked = order.where(wantedKind).toList();
          if (liked.isNotEmpty) {
            winner = liked.first;
          } else if (!running.any(wantedKind)) {
            winner = order.first;
          } else {
            final grace = prefer == SvcPrefer.tunnel ? f.tieGrace : f.preferGrace;
            final left = grace - DateTime.now().difference(firstAt!);
            if (left <= Duration.zero) {
              winner = order.first;
            } else if (!graceSet) {
              graceSet = true;
              timers.add(Timer(left, poke));
            }
          }
          if (winner != null) break;
        } else if (running.isEmpty) {
          if (answers.isNotEmpty) {
            winner = answers.firstWhere((a) => prefer == SvcPrefer.tunnel ? a.tunnel : !a.tunnel, orElse: () => answers.first);
          }
          break;
        }
        await wake.future;
        wake = Completer<void>();
      }
    } finally {
      for (final t in timers) {
        t.cancel();
      }
      for (final a in attempts) {
        a.onChange = null;
        if (a != winner) {
          // collect: the other side's paths that may still bring a whole answer stay for [_collectPeers]
          if (collect && winner != null && got == 0 && a.tunnel != winner.tunnel && (a.st == _St.running || a.st == _St.ready)) {
            _peers.add(a);
            continue;
          }
          a.kill();
          _live.remove(a);
        }
      }
    }
    if (winner == null) return null;
    // a failure of this round's other paths stays in [failures] (they were asked and gave nothing)
    // what a resume proves it continues the same file by (a weak ETag cannot go into If-Range)
    final etag = winner.headers['etag'];
    validator ??= etag != null && !etag.startsWith('W/') ? etag : winner.headers['last-modified'];
    return winner;
  }

  /// The chosen path carries the rest of the body into [out] / [onData]. null = done; else the code of what broke.
  Future<String?> _drain(_Attempt a) async {
    void emit(List<int> c) {
      if (tooBig) return;
      final m = maxBytes;
      if (m != null && got + c.length > m) {
        tooBig = true;
        a.kill();
        return;
      }
      got += c.length;
      final cb = onData;
      if (cb != null) {
        cb(c);
      } else {
        out.add(c);
      }
    }

    a.promote(emit);
    await a.finished.future;
    _live.remove(a);
    if (cancelled || tooBig) return null;
    return a.st == _St.failed ? (a.code ?? 'error') : null;
  }
}
