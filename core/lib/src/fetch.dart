import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'node.dart';
import 'parse/build.dart';
import 'parse/subscription.dart';
import 'svc_fetch.dart';
import 'svc_in.dart';

/// User-Agents of the first fetch (discovery): each may get a different format and a
/// different set of servers from the provider (docs/subscription-parsing.md).
const discoveryAgents = ['sing-box/1.14.2', 'mihomo/1.19.28', 'ClashMeta'];

/// Bumped when parsing changes what a node looks like (names, outbounds): an ETag /
/// Last-Modified stored by an older parser is not sent, so the next update reads the
/// subscription in full instead of getting 304 and keeping the old nodes.
/// 2: protocol words leave names. 3: socks / http / ssh / hysteria / quic parsed, servers
/// sing-box cannot run listed as unsupported, VLESS encryption flagged.
/// 4: no uTLS on QUIC protocols, hysteria2 `pinSHA256` -> insecure, hysteria2 alpn h3 is the default.
const parserVersion = 4;

/// The UA chip of the subscription form → the header sent.
String userAgentFor(String chip) => switch (chip) {
      'sing-box' => 'sing-box/1.14.2',
      'mihomo' => 'mihomo/1.19.28',
      'v2ray' || 'v2rayN' => 'v2rayN/7.0',
      _ => chip,
    };

/// "Download via" of the subscription form (docs/subscription-parsing.md). [auto]: one request over direct and
/// the tunnel's paths at once, a tie goes to the tunnel; [proxy]: the tunnel's paths only (main flow and routes),
/// never direct — with no tunnel up it fails (`noPath`); [direct]: direct only. The old `Direct first` /
/// `Proxy first` and a missing value are [auto].
enum Channel {
  auto,
  proxy,
  direct;

  static Channel of(String? chip) => switch (chip) {
        'Proxy' => proxy,
        'Direct' => direct,
        _ => auto,
      };

  SvcPolicy get policy => switch (this) {
        auto => const SvcPolicy.race(),
        proxy => const SvcPolicy.race(kinds: {SvcKind.main, SvcKind.route}),
        direct => const SvcPolicy.strict('direct'),
      };
}

/// No path brought the subscription ([failure]: the codes per path; the Sentinel's suspicion comes from it).
class SubscriptionFetchException extends HttpException {
  SubscriptionFetchException(this.failure, String url)
      : super('Subscription did not answer: ${failure.code}${failure.paths.isEmpty ? '' : ' (${[for (final p in failure.paths) '${p.id}:${p.code}'].join(' ')})'}',
            uri: Uri.tryParse(url));

  final SvcFailure failure;
}

const _rediscoverAfter = Duration(days: 7);

/// A subscription bigger than this is refused (a real one is well under 1 MB).
const maxSubscriptionBytes = 16 * 1024 * 1024;

/// One request, headers to the last byte of the body.
const subscriptionTimeout = Duration(seconds: 40);

class SubscriptionResult {
  SubscriptionResult({
    required this.nodes,
    required this.strategy,
    required this.discoveredAt,
    this.total = 0,
    this.notModified = false,
    this.hasUserInfo = false,
    this.usedGb,
    this.totalGb,
    this.expire,
    this.title,
    this.format,
    this.updateHours,
    this.webPage,
    this.supportUrl,
    this.announce,
    this.via = 'direct',
  });

  /// After the filter.
  final List<Node> nodes;

  /// Servers the provider gave (before the filter): the >20% shrink check counts these.
  final int total;

  /// UAs worth asking next time: `{ua, unique, parser, filter?, etag?, lastModified?}`,
  /// only those that brought servers no earlier UA had.
  final List<Map<String, dynamic>> strategy;
  final int discoveredAt;
  final bool notModified;

  /// `subscription-userinfo` was sent: [usedGb], [totalGb] (0 = unlimited) and [expire]
  /// (null = none) are the provider's current word, also on a 304.
  final bool hasUserInfo;
  final double? usedGb;
  final double? totalGb;

  /// yyyy-mm-dd, from `subscription-userinfo`.
  final String? expire;

  /// `profile-title` header, else the `content-disposition` file name — a name
  /// suggestion for a new subscription.
  final String? title;

  /// What the body was: `sing-box`, `clash`, `base64`, `links` (the first UA that brought
  /// servers); null on a 304.
  final String? format;

  /// `profile-update-interval`: the provider's update period, hours.
  final double? updateHours;

  /// `profile-web-page-url` and `support-url` (http(s) / tg links only).
  final String? webPage;
  final String? supportUrl;

  /// `announce` header (`base64:` prefix decoded): the provider's message for the card.
  final String? announce;

  /// How it came: `direct` or `proxy` (through the running tunnel).
  final String via;

  SubscriptionResult _via(String v) => SubscriptionResult(
        nodes: nodes,
        total: total,
        strategy: strategy,
        discoveredAt: discoveredAt,
        notModified: notModified,
        hasUserInfo: hasUserInfo,
        usedGb: usedGb,
        totalGb: totalGb,
        expire: expire,
        title: title,
        format: format,
        updateHours: updateHours,
        webPage: webPage,
        supportUrl: supportUrl,
        announce: announce,
        via: v,
      );

  Map<String, dynamic> toJson() => {
        'nodes': [for (final n in nodes) n.toJson()],
        'strategy': strategy,
        'discoveredAt': discoveredAt,
        'notModified': notModified,
        if (hasUserInfo) 'usage': {'used': usedGb ?? 0, 'total': totalGb ?? 0},
        if (hasUserInfo) 'expire': expire,
        'title': title,
        'format': format,
        'updateHours': updateHours,
        'webPage': webPage,
        'supportUrl': supportUrl,
        'announce': announce,
        'via': via,
      };
}

class _Resp {
  _Resp(this.ua, this.status, this.body, this.headers);
  final String ua;
  final int status;
  final String body;

  /// Lower-case names.
  final Map<String, String> headers;
}

/// How the requests of one [fetchSubscription] go: the service traffic, the paths [policy] allows, whether a second
/// whole answer of the other side is compared ([compare], Auto only), and what came out of it.
class _Way {
  _Way(this.svc, this.policy, {required this.compare, this.retryKey, this.onDiverged});

  final ServiceFetch svc;
  final SvcPolicy policy;
  final bool compare;
  final String? retryKey;
  final void Function(Map<String, dynamic> data)? onDiverged;

  /// A tunnel path carried at least one of the answers (`via` of the result).
  bool tunnel = false;
}

Future<_Resp> _get(
  _Way w,
  String url,
  String ua, {
  Map<String, String> headers = const {},
  String? etag,
  String? lastModified,
  required Duration timeout,
  required int maxBytes,
}) async {
  final uri = Uri.parse(url);
  final cancel = Completer<void>();
  final SvcResult res = await w.svc
      .get(
        uri,
        purpose: 'subscription',
        retryKey: w.retryKey,
        policy: w.policy,
        maxBytes: maxBytes,
        collect: w.compare,
        cancel: cancel.future,
        headers: {
          HttpHeaders.userAgentHeader: ua,
          ...headers,
          HttpHeaders.ifNoneMatchHeader: ?etag,
          HttpHeaders.ifModifiedSinceHeader: ?lastModified,
        },
      )
      .timeout(timeout, onTimeout: () {
    cancel.complete();
    throw TimeoutException('Subscription did not answer in ${timeout.inSeconds} s');
  });
  final fail = res.failure;
  if (fail != null) {
    if (fail.code == 'tooBig') throw HttpException('Subscription is over ${maxBytes ~/ 1048576} MB', uri: uri);
    throw SubscriptionFetchException(fail, url);
  }
  final r = res.response!;
  if (!r.ok) throw HttpException('HTTP ${r.status} for UA $ua', uri: uri);
  var status = r.status, body = r.body, hdrs = r.headers, kind = r.kind;
  // Auto: both sides answered whole. When they differ the tunnel's is the one used (the provider may serve
  // another list to the visible address of the machine, or something in the way may alter it).
  final peer = r.peers.isEmpty ? null : r.peers.first;
  if (peer != null && peer.hash != r.hash) {
    final tunnelWon = r.kind != SvcKind.direct;
    final (dVia, dLen, dHash) = tunnelWon ? (peer.via, peer.body.length, peer.hash) : (r.via, r.bytes, r.hash);
    final (tVia, tLen, tHash) = tunnelWon ? (r.via, r.bytes, r.hash) : (peer.via, peer.body.length, peer.hash);
    w.onDiverged?.call({
      'host': uri.host.toLowerCase(),
      'ua': ua,
      'directBytes': dLen,
      'tunnelBytes': tLen,
      'directHash': dHash.substring(0, 12),
      'tunnelHash': tHash.substring(0, 12),
      'tunnelPath': tVia,
      'directPath': dVia,
    });
    if (!tunnelWon) {
      status = peer.status;
      body = peer.body;
      hdrs = peer.headers;
      kind = peer.kind;
    }
  }
  if (kind != SvcKind.direct) w.tunnel = true;
  return _Resp(ua, status, utf8.decode(body, allowMalformed: true), hdrs);
}

/// Fetches a subscription the way docs/subscription-parsing.md describes: discovery with
/// several UAs on the first fetch (or every 7 days, or when the list shrank by >20%, or
/// on [rediscover]), otherwise only the UAs of [strategy], with ETag / Last-Modified. A
/// chosen UA ([userAgent] other than `Auto`) is the only one asked.
///
/// [headers] go with every request (the HWID set, see device.dart). [filter] (a regex on
/// the server name, flag included) keeps only the matching servers; it is part of a
/// cached answer, so a changed filter reads the subscription in full. [channel] says how to
/// reach the provider ([Channel]); every request goes through [svc] (the service traffic of
/// the core, svc_fetch.dart; without one a plain direct socket, so [Channel.proxy] has no way).
/// [retryKey] (the source id) keeps the retry count of this subscription apart. [onDiverged]:
/// in Auto both sides answered whole and the bodies differ (the tunnel's is used), told once per
/// request with codes and hashes.
Future<SubscriptionResult> fetchSubscription(
  String url, {
  String userAgent = 'Auto',
  List<Map<String, dynamic>> strategy = const [],
  int discoveredAt = 0,
  int prevCount = 0,
  bool rediscover = false,
  String filter = '',
  Map<String, String> headers = const {},
  Channel channel = Channel.auto,
  ServiceFetch? svc,
  String? retryKey,
  void Function(Map<String, dynamic> data)? onDiverged,
  Duration timeout = subscriptionTimeout,
  int maxBytes = maxSubscriptionBytes,
}) async {
  final re = filterRegExp(filter);
  final way = _Way(svc ?? ServiceFetch(endpoint: () => null), channel.policy,
      compare: channel == Channel.auto, retryKey: retryKey == null ? null : 'subscription:$retryKey', onDiverged: onDiverged);
  final r = await _fetch(way, url,
      userAgent: userAgent,
      strategy: strategy,
      discoveredAt: discoveredAt,
      prevCount: prevCount,
      rediscover: rediscover,
      filter: filter,
      re: re,
      headers: headers,
      timeout: timeout,
      maxBytes: maxBytes);
  return r._via(way.tunnel ? 'proxy' : 'direct');
}

/// The subscription filter as a RegExp; null when empty. Throws a FormatException the UI
/// can show when it is not a valid expression.
RegExp? filterRegExp(String filter) {
  if (filter.trim().isEmpty) return null;
  try {
    return RegExp(filter, unicode: true);
  } on FormatException {
    throw FormatException('Filter is not a valid regular expression: $filter');
  }
}

bool _keep(RegExp re, Node n) => filterKeeps(re, n.name, n.flag);

/// The filter's test on a server name (and the name with its flag in front).
bool filterKeeps(RegExp re, String name, String flag) => re.hasMatch(name) || re.hasMatch('$flag $name');

Future<SubscriptionResult> _fetch(
  _Way c,
  String url, {
  required String userAgent,
  required List<Map<String, dynamic>> strategy,
  required int discoveredAt,
  required int prevCount,
  required bool rediscover,
  required String filter,
  required RegExp? re,
  required Map<String, String> headers,
  required Duration timeout,
  required int maxBytes,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  Future<SubscriptionResult> run(List<Map<String, dynamic>> plan, {required bool discovery, required int discoveredAt, bool keepAll = false}) =>
      _run(c, url, plan,
          discovery: discovery,
          discoveredAt: discoveredAt,
          keepAll: keepAll,
          filter: filter,
          re: re,
          headers: headers,
          timeout: timeout,
          maxBytes: maxBytes);
  final discover = [for (final ua in discoveryAgents) <String, dynamic>{'ua': ua}];

  final explicit = userAgent != 'Auto' && userAgent.isNotEmpty;
  if (explicit) {
    final ua = userAgentFor(userAgent);
    final cached = rediscover ? const <Map<String, dynamic>>[] : strategy.where((e) => e['ua'] == ua).toList();
    return run(cached.isNotEmpty ? cached : [{'ua': ua}], discovery: false, keepAll: true, discoveredAt: discoveredAt);
  }
  final stale = now - discoveredAt > _rediscoverAfter.inMilliseconds;
  if (rediscover || strategy.isEmpty || stale) return run(discover, discovery: true, discoveredAt: now);
  final r = await run(strategy, discovery: false, discoveredAt: discoveredAt);
  // The provider's list before the filter: the strategy's unique counts add up to it.
  final before = strategy.fold<int>(0, (a, e) => a + ((e['unique'] as num?)?.toInt() ?? 0));
  final prev = before > 0 ? before : prevCount;
  if (!r.notModified && prev > 0 && r.total < prev * 0.8) return run(discover, discovery: true, discoveredAt: now);
  return r;
}

Future<SubscriptionResult> _run(
  _Way c,
  String url,
  List<Map<String, dynamic>> plan, {
  required bool discovery,
  required int discoveredAt,
  required String filter,
  required RegExp? re,
  required Map<String, String> headers,
  required Duration timeout,
  required int maxBytes,
  bool keepAll = false,
}) async {
  Object? firstError;
  Future<_Resp?> one(Map<String, dynamic> e, {bool conditional = true}) async {
    try {
      // A cached answer only stands for the same parser and the same filter.
      conditional = conditional && e['parser'] == parserVersion && (e['filter'] ?? '') == filter;
      return await _get(c, url, e['ua'] as String,
          headers: headers,
          etag: conditional ? e['etag'] as String? : null,
          lastModified: conditional ? e['lastModified'] as String? : null,
          timeout: timeout,
          maxBytes: maxBytes);
    } catch (err) {
      if (!discovery) rethrow;
      firstError ??= err;
      return null; // one UA failing during discovery is fine
    }
  }

  var resps = await Future.wait(plan.map((e) => one(e, conditional: !discovery)));
  if (resps.every((r) => r == null)) throw firstError ?? HttpException('Subscription did not answer', uri: Uri.parse(url));
  if (!discovery && resps.every((r) => r!.status == 304)) {
    // Nothing new in the list, but usage and expiry move on: read them from the 304.
    return _withMeta(resps.cast<_Resp>(), (m) => SubscriptionResult(
          nodes: const [],
          strategy: plan,
          discoveredAt: discoveredAt,
          notModified: true,
          hasUserInfo: m.info != null,
          usedGb: m.info?.used,
          totalGb: m.info?.total,
          expire: m.info?.expire,
          title: m.title,
          updateHours: m.updateHours,
          webPage: m.webPage,
          supportUrl: m.supportUrl,
          announce: m.announce,
        ));
  }
  // Some UAs said 304, others did not: their servers are unknown now, ask them again in full.
  if (!discovery && resps.any((r) => r!.status == 304)) {
    resps = await Future.wait([
      for (var i = 0; i < plan.length; i++) resps[i]!.status == 304 ? one(plan[i], conditional: false) : Future.value(resps[i]),
    ]);
  }

  final merged = <String, Node>{};
  final strategy = <Map<String, dynamic>>[];
  final used = <_Resp>[];
  String? format;
  for (final r in resps) {
    if (r == null) continue;
    final (fmt, nodes) = parseSubscription(r.body, contentType: r.headers[HttpHeaders.contentTypeHeader]);
    var unique = 0;
    for (final n in nodes) {
      // First UA wins a conflict: sing-box is asked first, its outbounds are the fullest.
      if (merged.putIfAbsent(n.id, () => n) == n) unique++;
    }
    if (unique > 0 || keepAll) {
      used.add(r);
      if (nodes.isNotEmpty) format ??= fmt.label;
      strategy.add({
        'ua': r.ua,
        'unique': unique,
        'parser': parserVersion,
        if (filter.isNotEmpty) 'filter': filter,
        if (r.headers[HttpHeaders.etagHeader] != null) 'etag': r.headers[HttpHeaders.etagHeader],
        if (r.headers[HttpHeaders.lastModifiedHeader] != null) 'lastModified': r.headers[HttpHeaders.lastModifiedHeader],
      });
    }
  }
  if (merged.isEmpty) throw const FormatException('No servers found in the subscription');
  final kept = re == null ? merged.values.toList() : merged.values.where((n) => _keep(re, n)).toList();
  if (kept.isEmpty) throw FormatException('No servers match the filter $filter');

  return _withMeta([...used, ...resps.whereType<_Resp>().where((r) => !used.contains(r))], (m) => SubscriptionResult(
        nodes: kept,
        total: merged.length,
        strategy: strategy,
        discoveredAt: discoveredAt,
        hasUserInfo: m.info != null,
        usedGb: m.info?.used,
        totalGb: m.info?.total,
        expire: m.info?.expire,
        title: m.title,
        format: format,
        updateHours: m.updateHours,
        webPage: m.webPage,
        supportUrl: m.supportUrl,
        announce: m.announce,
      ));
}

typedef _Meta = ({
  ({double used, double total, String? expire})? info,
  String? title,
  double? updateHours,
  String? webPage,
  String? supportUrl,
  String? announce,
});

/// The provider's headers: from the first response that has each one ([resps] in order
/// of preference — the UA whose servers were taken first).
SubscriptionResult _withMeta(List<_Resp> resps, SubscriptionResult Function(_Meta) make) {
  String? h(String name) {
    for (final r in resps) {
      final v = r.headers[name];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  final hours = double.tryParse(h('profile-update-interval') ?? '');
  return make((
    info: userInfo(h('subscription-userinfo')),
    title: _text(h('profile-title')) ?? _fileName(h('content-disposition')),
    updateHours: hours != null && hours.isFinite && hours > 0 ? hours : null,
    webPage: _link(h('profile-web-page-url')),
    supportUrl: _link(h('support-url')),
    announce: _text(h('announce')),
  ));
}

/// `upload=1; download=2.5e9; total=3; expire=1700000000` → (used GB, total GB,
/// yyyy-mm-dd or null). Numbers may be decimal or e-notation; unknown parts are skipped.
({double used, double total, String? expire})? userInfo(String? h) {
  if (h == null || h.trim().isEmpty) return null;
  final v = <String, double>{};
  for (final part in h.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    final x = double.tryParse(part.substring(i + 1).trim());
    if (x != null && x.isFinite && x >= 0) v[part.substring(0, i).trim().toLowerCase()] = x;
  }
  if (v.isEmpty) return null;
  double gb(double b) => (b / 1e9 * 10).round() / 10;
  var exp = v['expire'] ?? 0;
  if (exp > 1e11) exp /= 1000; // milliseconds from some panels
  return (
    used: gb((v['upload'] ?? 0) + (v['download'] ?? 0)),
    total: gb(v['total'] ?? 0),
    expire: exp > 0 ? DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true).toIso8601String().substring(0, 10) : null,
  );
}

/// dart:io reads header bytes as Latin-1; providers send UTF-8 (a Cyrillic title).
String _utf8(String s) {
  if (s.codeUnits.every((c) => c < 0x100) && s.codeUnits.any((c) => c >= 0x80)) {
    try {
      return utf8.decode(latin1.encode(s));
    } catch (_) {}
  }
  return s;
}

/// A text header, maybe `base64:`-prefixed; capped so a card stays a card.
String? _text(String? h) {
  if (h == null || h.isEmpty) return null;
  var t = h.startsWith('base64:') ? (tryBase64(h.substring(7)) ?? h) : _utf8(h);
  t = t.trim();
  if (t.isEmpty) return null;
  return t.length > 500 ? '${t.substring(0, 500)}…' : t;
}

String? _link(String? h) {
  final t = h == null ? null : _utf8(h).trim();
  // no quotes, brackets or backslashes: the UI puts it in a link
  return t != null && RegExp(r'''^(https?|tg)://[^\s"'<>\\`]+$''', caseSensitive: false).hasMatch(t) ? t : null;
}

/// `attachment; filename*=UTF-8''My%20VPN.yaml` or `filename="My VPN.yaml"` → `My VPN`.
String? _fileName(String? h) {
  if (h == null) return null;
  String? name;
  final star = RegExp(r"filename\*\s*=\s*[^']*'[^']*'([^;]+)", caseSensitive: false).firstMatch(h);
  if (star != null) {
    try {
      name = Uri.decodeComponent(star[1]!.trim());
    } catch (_) {}
  }
  if (name == null) {
    final m = RegExp(r'filename\s*=\s*(?:"([^"]*)"|([^;]+))', caseSensitive: false).firstMatch(h);
    if (m != null) name = _utf8((m[1] ?? m[2]!).trim());
  }
  name = name?.replaceFirst(RegExp(r'\.(ya?ml|json|txt|conf)$', caseSensitive: false), '').trim();
  return name == null || name.isEmpty ? null : name;
}
