import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One "what is my IP" service: where to ask and how to read the answer.
/// [read] returns {ip, country?, city?, org?} or null when the body has no IP.
typedef ExitProbe = ({String name, String url, Map<String, dynamic>? Function(String body) read});

/// Services asked in parallel. They sit on different networks on purpose: a country
/// that blocks one host or one CDN (Russia throttles Cloudflare, China blocks others)
/// still leaves some answering. Geo ones first; the IP-only ones are the fallback.
final List<ExitProbe> exitProbes = [
  (
    name: 'ipwho.is', // Cloudflare
    url: 'https://ipwho.is/',
    read: (b) {
      final j = jsonDecode(b) as Map;
      if (j['success'] == false) return null;
      return {'ip': j['ip'], 'country': j['country_code'], 'city': j['city'], 'org': (j['connection'] as Map?)?['org']};
    },
  ),
  (
    name: 'ipinfo.io', // Google Cloud
    url: 'https://ipinfo.io/json',
    read: (b) {
      final j = jsonDecode(b) as Map;
      return {'ip': j['ip'], 'country': j['country'], 'city': j['city'], 'org': '${j['org'] ?? ''}'.replaceFirst(RegExp(r'^AS\d+\s+'), '')};
    },
  ),
  (
    name: 'ip-api.com', // own hosting, plain HTTP only on the free plan
    url: 'http://ip-api.com/json/?fields=status,countryCode,city,org,isp,query',
    read: (b) {
      final j = jsonDecode(b) as Map;
      if (j['status'] != 'success') return null;
      final org = '${j['org'] ?? ''}';
      return {'ip': j['query'], 'country': j['countryCode'], 'city': j['city'], 'org': org.isEmpty ? j['isp'] : org};
    },
  ),
  (
    name: 'cloudflare', // IP and country only
    url: 'https://www.cloudflare.com/cdn-cgi/trace',
    read: (b) {
      final kv = {
        for (final l in const LineSplitter().convert(b))
          if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
      };
      return {'ip': kv['ip'], 'country': kv['loc']};
    },
  ),
  (name: 'yandex', url: 'https://ipv4-internet.yandex.net/api/v0/ip', read: _plainIp), // reachable from Russia
  (name: 'amazon', url: 'https://checkip.amazonaws.com/', read: _plainIp),
  (name: 'ipip.net', url: 'https://myip.ipip.net/', read: _plainIp), // reachable from China
];

/// Where traffic leaves the tunnel: asked through the running proxy itself (the mixed
/// inbound on [proxyPort]), so it is the exit of whatever node sing-box uses right now.
/// All [probes] go at once. The first answer with IP, country and city wins right away;
/// with only an IP so far it waits [grace] for a service that knows the place, then
/// takes what it has. Answers about the same IP fill each other's gaps.
/// Returns {ip, country? (ISO code), city?, org?, source}; throws when no service answers
/// within [timeout].
Future<Map<String, dynamic>> checkExitIp(
  int proxyPort, {
  List<ExitProbe>? probes,
  Duration timeout = const Duration(seconds: 7),
  Duration grace = const Duration(milliseconds: 1500),
}) async {
  probes ??= exitProbes;
  final client = HttpClient()
    ..findProxy = ((_) => 'PROXY 127.0.0.1:$proxyPort')
    ..connectionTimeout = timeout;
  final done = Completer<Map<String, dynamic>>();
  final errors = <String>[];
  Map<String, dynamic>? best;
  Timer? graceTimer;
  var left = probes.length;

  void finish() {
    if (done.isCompleted) return;
    if (best != null) {
      done.complete(best);
    } else {
      done.completeError(Exception('no answer through the tunnel (${errors.isEmpty ? 'timeout' : errors.join('; ')})'));
    }
  }

  final deadline = Timer(timeout, finish);
  for (final p in probes) {
    _ask(client, p, timeout).then((r) {
      best = _better(best, r);
      if (best!['country'] != null && best!['city'] != null) finish();
      graceTimer ??= Timer(grace, finish);
    }, onError: (Object e) {
      errors.add('${p.name}: ${e is TimeoutException ? 'timeout' : e}');
    }).whenComplete(() {
      if (--left == 0) finish();
    });
  }
  try {
    return await done.future;
  } finally {
    deadline.cancel();
    graceTimer?.cancel();
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _ask(HttpClient client, ExitProbe p, Duration timeout) => Future(() async {
      final uri = Uri.parse(p.url);
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final r = _clean(p.read(await const Utf8Decoder(allowMalformed: true).bind(res).join()));
      if (r == null) throw const FormatException('no ip in the answer');
      return {...r, 'source': p.name};
    }).timeout(timeout);

/// Keeps only valid, non-empty fields; null when there is no valid IP.
Map<String, dynamic>? _clean(Map<String, dynamic>? r) {
  final ip = '${r?['ip'] ?? ''}'.trim();
  if (InternetAddress.tryParse(ip) == null) return null;
  final country = '${r!['country'] ?? ''}'.trim().toUpperCase();
  String? text(Object? v) => v == null || '$v'.trim().isEmpty ? null : '$v'.trim();
  return {
    'ip': ip,
    // Cloudflare says XX when it does not know and T1 for Tor
    if (RegExp(r'^[A-Z]{2}$').hasMatch(country) && country != 'XX' && country != 'T1') 'country': country,
    'city': ?text(r['city']),
    'org': ?text(r['org']),
  };
}

/// The answer that says more wins; answers about the same IP are merged.
Map<String, dynamic> _better(Map<String, dynamic>? a, Map<String, dynamic> b) {
  if (a == null) return b;
  int score(Map<String, dynamic> m) =>
      (m['country'] != null ? 4 : 0) + (m['city'] != null ? 2 : 0) + (m['org'] != null ? 1 : 0);
  final (top, other) = score(b) > score(a) ? (b, a) : (a, b);
  if (top['ip'] != other['ip']) return top;
  return {...top, for (final e in other.entries) if (!top.containsKey(e.key)) e.key: e.value};
}

Map<String, dynamic>? _plainIp(String body) {
  final t = body.trim().replaceAll('"', '');
  if (InternetAddress.tryParse(t) != null) return {'ip': t};
  final m = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b').firstMatch(body);
  return m == null ? null : {'ip': m[0]};
}
