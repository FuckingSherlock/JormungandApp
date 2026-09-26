import 'dart:convert';

import '../node.dart';
import 'build.dart';

/// Parses one share link (vless://, vmess://, trojan://, ss://, hy2:// / hysteria2://,
/// tuic://, anytls://, socks://, hysteria://). Proxy schemes sing-box cannot run (ssr://,
/// wireguard://…) come back as unsupported nodes. Null for other schemes and malformed links.
Node? parseLink(String raw) {
  raw = raw.trim();
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(raw);
  if (m == null) return null;
  try {
    switch (m[1]!.toLowerCase()) {
      case 'vless':
        final l = _Link.parse(raw);
        return buildVless(name: l.name, host: l.host, port: l.port, uuid: l.user, q: l.query);
      case 'vmess':
        return _vmess(raw);
      case 'trojan' || 'trojan-go':
        final l = _Link.parse(raw);
        return buildTrojan(name: l.name, host: l.host, port: l.port, password: l.user, q: l.query);
      case 'ss':
        return _ss(raw);
      case 'hy2' || 'hysteria2':
        final l = _Link.parse(raw);
        return buildHy2(
          name: l.name,
          host: l.host,
          port: l.port,
          password: l.user.isNotEmpty ? l.user : (l.query['auth'] ?? ''),
          ports: [...l.extraPorts, if ((l.query['mport'] ?? '').isNotEmpty) l.query['mport']!],
          q: l.query,
        );
      case 'tuic':
        final l = _Link.parse(raw);
        final i = l.user.indexOf(':');
        return buildTuic(
          name: l.name,
          host: l.host,
          port: l.port,
          uuid: i < 0 ? l.user : l.user.substring(0, i),
          password: i < 0 ? (l.query['password'] ?? '') : l.user.substring(i + 1),
          q: l.query,
        );
      case 'anytls':
        final l = _Link.parse(raw);
        return buildAnytls(name: l.name, host: l.host, port: l.port, password: l.user, q: l.query);
      case 'socks' || 'socks5' || 'socks5h' || 'socks4' || 'socks4a':
        final l = _Link.parse(raw);
        var cred = l.user;
        // v2rayN: socks://base64(user:pass)@host:port
        if (cred.isNotEmpty && !cred.contains(':')) {
          final b = tryBase64(cred);
          if (b != null && b.contains(':')) cred = b;
        }
        final i = cred.indexOf(':');
        final scheme = m[1]!.toLowerCase();
        return buildSocks(
          name: l.name,
          host: l.host,
          port: l.port,
          user: i < 0 ? cred : cred.substring(0, i),
          password: i < 0 ? '' : cred.substring(i + 1),
          version: scheme.startsWith('socks4') ? scheme.substring(5) : '5',
        );
      case 'hysteria':
        final l = _Link.parse(raw);
        final q = {...l.query};
        // hysteria://host:port?auth=…&peer=sni&obfs=xplus&obfsParam=secret
        q.remove('obfs');
        final obfs = q['obfsParam'] ?? q['obfs-password'];
        if (obfs != null && obfs.isNotEmpty) q['obfs'] = obfs;
        return buildHysteria(name: l.name, host: l.host, port: l.port, auth: l.user.isNotEmpty ? l.user : (l.query['auth'] ?? ''), q: q);
      case 'ssr':
        return _ssr(raw);
      case final s when _unsupportedSchemes.contains(s):
        final l = _Link.parse(raw);
        final proto = s == 'wg' ? 'wireguard' : s;
        return unsupportedNode(name: l.name, protocol: proto, host: l.host, port: l.port, identity: '${l.user}|${l.query['publickey'] ?? ''}');
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Proxy links sing-box cannot run as an outbound: listed as unsupported, so the user sees
/// the provider gave them (any other scheme — a web link in the list — is not a server).
const _unsupportedSchemes = {'wireguard', 'wg', 'juicity', 'mieru', 'naive+https', 'naive+quic', 'brook', 'snell'};

/// ssr://base64(host:port:protocol:method:obfs:base64(password)/?remarks=base64(name)&…)
Node? _ssr(String raw) {
  final txt = tryBase64(raw.substring(raw.indexOf('://') + 3).split('#').first);
  if (txt == null) return null;
  final q = txt.indexOf('/?');
  final main = q < 0 ? txt : txt.substring(0, q);
  final params = q < 0 ? const <String, String>{} : _query(txt.substring(q + 2));
  final parts = main.split(':');
  if (parts.length < 6) return null;
  // host may be IPv6 (colons): the last five fields are fixed
  final host = parts.sublist(0, parts.length - 5).join(':');
  final port = int.tryParse(parts[parts.length - 5]) ?? 0;
  final remarks = params['remarks'];
  return unsupportedNode(
    name: remarks == null ? '' : (tryBase64(remarks) ?? ''),
    protocol: 'ssr',
    host: host,
    port: port,
    identity: parts.last,
  );
}

/// Every link found in a block of text, one per line; unknown lines are skipped.
List<Node> parseLinks(String text) =>
    const LineSplitter().convert(text).map(parseLink).whereType<Node>().toList();

String _dec(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

Params _query(String q) {
  final out = <String, String>{};
  for (final part in q.split('&')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    if (i < 0) {
      out[_dec(part)] = '';
    } else {
      out[_dec(part.substring(0, i))] = _dec(part.substring(i + 1));
    }
  }
  return out;
}

/// host:port / [v6]:port / host:443,20000-30000 → (host, [port specs]).
(String, List<String>) _hostPort(String s) {
  final slash = s.indexOf('/');
  if (slash >= 0) s = s.substring(0, slash);
  if (s.startsWith('[')) {
    final e = s.indexOf(']');
    final host = s.substring(1, e);
    final rest = s.length > e + 2 && s[e + 1] == ':' ? s.substring(e + 2) : '';
    return (host, rest.isEmpty ? [] : rest.split(','));
  }
  final c = s.lastIndexOf(':');
  if (c < 0) return (s, []);
  return (s.substring(0, c), s.substring(c + 1).split(','));
}

int _portOf(List<String> specs) => specs.isEmpty ? 443 : int.tryParse(specs.first.split('-').first.trim()) ?? 443;

/// scheme://user@host:port/path?query#name, split by hand: Uri.parse rejects the
/// multi-port authorities and unescaped names real links carry.
class _Link {
  _Link(this.user, this.host, this.port, this.extraPorts, this.query, this.name);

  factory _Link.parse(String raw) {
    var rest = raw.substring(raw.indexOf('://') + 3);
    var name = '';
    final h = rest.indexOf('#');
    if (h >= 0) {
      name = _dec(rest.substring(h + 1));
      rest = rest.substring(0, h);
    }
    var query = <String, String>{};
    final qi = rest.indexOf('?');
    if (qi >= 0) {
      query = _query(rest.substring(qi + 1));
      rest = rest.substring(0, qi);
    }
    var user = '';
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      user = _dec(rest.substring(0, at));
      rest = rest.substring(at + 1);
    }
    final (host, ports) = _hostPort(rest);
    if (host.isEmpty) throw const FormatException('no host');
    return _Link(user, host, _portOf(ports), ports.skip(1).toList(), query, name);
  }

  final String user;
  final String host;
  final int port;
  final List<String> extraPorts;
  final Params query;
  final String name;
}

Node? _vmess(String raw) {
  var body = raw.substring(raw.indexOf('://') + 3);
  var name = '';
  final h = body.indexOf('#');
  if (h >= 0) {
    name = _dec(body.substring(h + 1));
    body = body.substring(0, h);
  }
  final txt = tryBase64(body);
  if (txt == null || !txt.trimLeft().startsWith('{')) {
    // vmess://uuid@host:port?… — the link style some panels export.
    final l = _Link.parse(raw);
    return buildVmess(name: l.name, host: l.host, port: l.port, uuid: l.user, cipher: l.query['encryption'] ?? 'auto', q: l.query);
  }
  // v2rayN JSON: {add, port, id, aid, scy, net, type, host, path, tls, sni, alpn, fp, ps}
  final j = jsonDecode(txt) as Map<String, dynamic>;
  String s(String k) => (j[k] ?? '').toString();
  final net = s('net').isEmpty ? 'tcp' : (s('net') == 'h2' ? 'http' : s('net'));
  final q = <String, String>{
    'type': net,
    'host': s('host'),
    'path': s('path'),
    'security': s('tls').isEmpty ? 'none' : s('tls'),
    'sni': s('sni'),
    'alpn': s('alpn'),
    'fp': s('fp'),
    if (net == 'grpc') 'serviceName': s('path'),
  }..removeWhere((k, v) => v.isEmpty);
  return buildVmess(
    name: name.isNotEmpty ? name : s('ps'),
    host: s('add'),
    port: int.tryParse(s('port')) ?? 443,
    uuid: s('id'),
    alterId: int.tryParse(s('aid')) ?? 0,
    cipher: s('scy').isEmpty ? 'auto' : s('scy'),
    q: q,
  );
}

Node? _ss(String raw) {
  var body = raw.substring(raw.indexOf('://') + 3);
  var name = '';
  final h = body.indexOf('#');
  if (h >= 0) {
    name = _dec(body.substring(h + 1));
    body = body.substring(0, h);
  }
  var q = <String, String>{};
  final qi = body.indexOf('?');
  if (qi >= 0) {
    q = _query(body.substring(qi + 1));
    body = body.substring(0, qi);
  }
  if (body.endsWith('/')) body = body.substring(0, body.length - 1);

  String cred, hostPart;
  final at = body.lastIndexOf('@');
  if (at >= 0) {
    // SIP002: base64(method:password)@host:port, or plain method:password (2022 ciphers).
    final ui = _dec(body.substring(0, at));
    final b = tryBase64(ui);
    cred = b != null && b.contains(':') ? b : ui;
    hostPart = body.substring(at + 1);
  } else {
    // Legacy: base64(method:password@host:port)
    final b = tryBase64(body);
    if (b == null) return null;
    final a = b.lastIndexOf('@');
    if (a < 0) return null;
    cred = b.substring(0, a);
    hostPart = b.substring(a + 1);
  }
  final c = cred.indexOf(':');
  if (c < 0) return null;
  final (host, ports) = _hostPort(hostPart);
  final plugin = q['plugin'];
  String? pName, pOpts;
  if (plugin != null && plugin.isNotEmpty) {
    final i = plugin.indexOf(';');
    pName = i < 0 ? plugin : plugin.substring(0, i);
    pOpts = i < 0 ? null : plugin.substring(i + 1);
  }
  return buildSs(
    name: name,
    host: host,
    port: _portOf(ports),
    method: cred.substring(0, c),
    password: cred.substring(c + 1),
    plugin: pName,
    pluginOpts: pOpts,
  );
}
