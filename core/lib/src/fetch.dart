import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'node.dart';
import 'parse/build.dart';
import 'parse/subscription.dart';

/// User-Agents of the first fetch (discovery): each may get a different format and a
/// different set of servers from the provider (docs/subscription-parsing.md).
const discoveryAgents = ['sing-box/1.14.2', 'mihomo/1.19.28', 'ClashMeta'];

/// The UA chip of the subscription form → the header sent.
String userAgentFor(String chip) => switch (chip) {
      'sing-box' => 'sing-box/1.14.2',
      'mihomo' => 'mihomo/1.19.28',
      'v2rayN' => 'v2rayN/7.0',
      _ => chip,
    };

const _rediscoverAfter = Duration(days: 7);

class SubscriptionResult {
  SubscriptionResult({
    required this.nodes,
    required this.strategy,
    required this.discoveredAt,
    this.notModified = false,
    this.usedGb,
    this.totalGb,
    this.expire,
    this.title,
  });

  final List<Node> nodes;

  /// UAs worth asking next time: `{ua, unique, etag?, lastModified?}`, only those that
  /// brought servers no earlier UA had.
  final List<Map<String, dynamic>> strategy;
  final int discoveredAt;
  final bool notModified;
  final double? usedGb;
  final double? totalGb;

  /// yyyy-mm-dd, from `subscription-userinfo`.
  final String? expire;

  /// `profile-title` header — a name suggestion for a new subscription.
  final String? title;

  Map<String, dynamic> toJson() => {
        'nodes': [for (final n in nodes) n.toJson()],
        'strategy': strategy,
        'discoveredAt': discoveredAt,
        'notModified': notModified,
        if (usedGb != null) 'usage': {'used': usedGb, 'total': totalGb ?? 0},
        'expire': expire,
        'title': title,
      };
}

class _Resp {
  _Resp(this.ua, this.status, this.body, this.headers);
  final String ua;
  final int status;
  final String body;
  final HttpHeaders headers;
}

HttpClient _client() => HttpClient()
  ..findProxy = HttpClient.findProxyFromEnvironment
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = null;

Future<_Resp> _get(HttpClient c, String url, String ua, {String? etag, String? lastModified}) async {
  final req = await c.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
  if (lastModified != null) req.headers.set(HttpHeaders.ifModifiedSinceHeader, lastModified);
  final res = await req.close().timeout(const Duration(seconds: 25));
  final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
  if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode} for UA $ua', uri: Uri.parse(url));
  return _Resp(ua, res.statusCode, body, res.headers);
}

/// Fetches a subscription the way docs/subscription-parsing.md describes: discovery with
/// several UAs on the first fetch (or every 7 days, or when the list shrank by >20%),
/// otherwise only the UAs of [strategy], with ETag / Last-Modified. A chosen UA
/// ([userAgent] other than `Auto`) is the only one asked.
Future<SubscriptionResult> fetchSubscription(
  String url, {
  String userAgent = 'Auto',
  List<Map<String, dynamic>> strategy = const [],
  int discoveredAt = 0,
  int prevCount = 0,
  HttpClient? client,
}) async {
  final c = client ?? _client();
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final explicit = userAgent != 'Auto' && userAgent.isNotEmpty;
    final stale = now - discoveredAt > _rediscoverAfter.inMilliseconds;
    if (explicit) {
      final ua = userAgentFor(userAgent);
      final cached = strategy.where((e) => e['ua'] == ua).toList();
      return await _run(c, url, cached.isNotEmpty ? cached : [{'ua': ua}], discovery: false, keepAll: true, discoveredAt: discoveredAt, prevCount: prevCount);
    }
    if (strategy.isEmpty || stale) {
      return await _run(c, url, [for (final ua in discoveryAgents) {'ua': ua}], discovery: true, discoveredAt: now);
    }
    final r = await _run(c, url, strategy, discovery: false, discoveredAt: discoveredAt, prevCount: prevCount);
    if (!r.notModified && prevCount > 0 && r.nodes.length < prevCount * 0.8) {
      return await _run(c, url, [for (final ua in discoveryAgents) {'ua': ua}], discovery: true, discoveredAt: now);
    }
    return r;
  } finally {
    if (client == null) c.close(force: true);
  }
}

Future<SubscriptionResult> _run(
  HttpClient c,
  String url,
  List<Map<String, dynamic>> plan, {
  required bool discovery,
  required int discoveredAt,
  bool keepAll = false,
  int prevCount = 0,
}) async {
  Future<_Resp?> one(Map<String, dynamic> e, {bool conditional = true}) async {
    try {
      return await _get(c, url, e['ua'] as String,
          etag: conditional ? e['etag'] as String? : null, lastModified: conditional ? e['lastModified'] as String? : null);
    } catch (err) {
      if (!discovery) rethrow;
      return null; // one UA failing during discovery is fine
    }
  }

  var resps = await Future.wait(plan.map((e) => one(e, conditional: !discovery)));
  if (resps.every((r) => r == null)) {
    throw HttpException('Subscription did not answer', uri: Uri.parse(url));
  }
  if (!discovery && resps.every((r) => r!.status == 304)) {
    return SubscriptionResult(nodes: const [], strategy: plan, discoveredAt: discoveredAt, notModified: true);
  }
  // Some UAs said 304, others did not: their servers are unknown now, ask them again in full.
  if (!discovery && resps.any((r) => r!.status == 304)) {
    resps = await Future.wait([
      for (var i = 0; i < plan.length; i++) resps[i]!.status == 304 ? one(plan[i], conditional: false) : Future.value(resps[i]),
    ]);
  }

  final merged = <String, Node>{};
  final strategy = <Map<String, dynamic>>[];
  _Resp? meta;
  for (final r in resps) {
    if (r == null) continue;
    final (_, nodes) = parseSubscription(r.body);
    var unique = 0;
    for (final n in nodes) {
      // First UA wins a conflict: sing-box is asked first, its outbounds are the fullest.
      if (merged.putIfAbsent(n.id, () => n) == n) unique++;
    }
    if (unique > 0 || keepAll) {
      meta ??= r;
      strategy.add({
        'ua': r.ua,
        'unique': unique,
        if (r.headers.value(HttpHeaders.etagHeader) != null) 'etag': r.headers.value(HttpHeaders.etagHeader),
        if (r.headers.value(HttpHeaders.lastModifiedHeader) != null) 'lastModified': r.headers.value(HttpHeaders.lastModifiedHeader),
      });
    }
  }
  if (merged.isEmpty) throw const FormatException('No servers found in the subscription');

  final info = _userInfo(meta?.headers.value('subscription-userinfo'));
  return SubscriptionResult(
    nodes: merged.values.toList(),
    strategy: strategy,
    discoveredAt: discoveredAt,
    usedGb: info.$1,
    totalGb: info.$2,
    expire: info.$3,
    title: _title(meta?.headers.value('profile-title')),
  );
}

/// `upload=1; download=2; total=3; expire=1700000000` → (used GB, total GB, yyyy-mm-dd).
(double?, double?, String?) _userInfo(String? h) {
  if (h == null) return (null, null, null);
  final v = <String, int>{};
  for (final part in h.split(';')) {
    final kv = part.split('=');
    if (kv.length == 2) v[kv[0].trim()] = int.tryParse(kv[1].trim()) ?? 0;
  }
  double gb(int b) => (b / 1e9 * 10).round() / 10;
  final exp = v['expire'] ?? 0;
  return (
    gb((v['upload'] ?? 0) + (v['download'] ?? 0)),
    gb(v['total'] ?? 0),
    exp > 0 ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true).toIso8601String().substring(0, 10) : null,
  );
}

String? _title(String? h) {
  if (h == null || h.isEmpty) return null;
  if (h.startsWith('base64:')) return tryBase64(h.substring(7)) ?? h;
  return h;
}
