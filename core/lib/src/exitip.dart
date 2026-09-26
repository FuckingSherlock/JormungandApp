import 'dart:convert';
import 'dart:io';

/// Where traffic leaves the tunnel: asked through the running proxy itself (the mixed
/// inbound on [proxyPort]), so it is the exit of whatever node sing-box uses right now.
/// ipwho.is first (IP, country, city, provider); if it does not answer, Cloudflare's
/// trace (IP and country only, but no limits and hardly ever blocked).
/// Returns {ip, country (ISO code), city?, org?, source}; throws when neither answers.
Future<Map<String, dynamic>> checkExitIp(int proxyPort, {Duration timeout = const Duration(seconds: 8)}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'PROXY 127.0.0.1:$proxyPort')
    ..connectionTimeout = timeout;
  Future<String> get(String url) async {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    return utf8.decodeStream(res).timeout(timeout);
  }

  try {
    try {
      final j = jsonDecode(await get('https://ipwho.is/')) as Map;
      if (j['success'] == false || j['ip'] == null) throw FormatException('ipwho.is: ${j['message'] ?? 'no ip'}');
      return {
        'ip': j['ip'],
        'country': j['country_code'],
        if (j['city'] != null) 'city': j['city'],
        if ((j['connection'] as Map?)?['org'] != null) 'org': (j['connection'] as Map)['org'],
        'source': 'ipwho.is',
      };
    } catch (_) {
      final kv = {
        for (final l in const LineSplitter().convert(await get('https://www.cloudflare.com/cdn-cgi/trace')))
          if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
      };
      if (kv['ip'] == null) throw const FormatException('cloudflare trace: no ip');
      return {'ip': kv['ip'], 'country': kv['loc'], 'source': 'cloudflare'};
    }
  } finally {
    client.close(force: true);
  }
}
