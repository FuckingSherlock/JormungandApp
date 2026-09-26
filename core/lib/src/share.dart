import 'dart:convert';

import 'node.dart';

/// The share link of a server (Nodes → ⋮ → Copy share link / Show QR code): the reverse
/// of parse/links.dart, so pasting the link into another client — or back into this one —
/// gives the same server (same outbound, same [Node.key]). vless, trojan, hy2, tuic and
/// anytls as URLs, vmess as v2rayN JSON (URL style when the JSON cannot say it: Reality,
/// insecure), ss as SIP002. The name goes into the #fragment with its flag in front.
///
/// Null when there is no link form: protocols only a sing-box / Clash subscription
/// carries (socks, http, wireguard…) and servers marked [Node.unsupported] — their
/// outbound lacks what sing-box could not take (e.g. the xhttp transport), so a link
/// built from it would name a different server.
String? shareLink(Map<String, dynamic> outbound, {String name = '', String flag = '', String? unsupported}) {
  if (unsupported != null) return null;
  final label = flag.isNotEmpty && flag != '🌐' ? '$flag $name'.trim() : name;
  final host = _host('${outbound['server'] ?? ''}');
  final port = '${outbound['server_port'] ?? ''}';
  if (host.isEmpty || port.isEmpty) return null;
  final tls = outbound['tls'] is Map ? (outbound['tls'] as Map).cast<String, dynamic>() : null;
  final tr = outbound['transport'] is Map ? (outbound['transport'] as Map).cast<String, dynamic>() : null;
  String s(String k) => '${outbound[k] ?? ''}';

  switch (outbound['type']) {
    case 'vless':
      return 'vless://${_enc(s('uuid'))}@$host:$port'
          '${_query({'encryption': 'none', 'flow': outbound['flow'], ..._tlsParams(tls, insecureKey: 'allowInsecure'), ..._transportParams(tr)})}'
          '${_frag(label)}';
    case 'vmess':
      final t = _transportParams(tr);
      final tp = _tlsParams(tls, insecureKey: 'allowInsecure');
      // v2rayN JSON has no Reality and no insecure flag: those go as a URL-style link.
      if (tp['security'] == 'reality' || tp['allowInsecure'] != null) {
        return 'vmess://${_enc(s('uuid'))}@$host:$port'
            '${_query({'encryption': outbound['security'] ?? 'auto', ...tp, ...t})}${_frag(label)}';
      }
      final net = t['type'] == 'http' ? 'h2' : t['type']!;
      final j = <String, String>{
        'v': '2',
        'ps': label,
        'add': '${outbound['server']}',
        'port': port,
        'id': s('uuid'),
        'aid': '${outbound['alter_id'] ?? 0}',
        'scy': outbound['security'] == null ? 'auto' : s('security'),
        'net': net,
        'type': 'none',
        'host': t['host'] ?? '',
        'path': (net == 'grpc' ? t['serviceName'] : t['path']) ?? '',
        'tls': tp['security'] == 'tls' ? 'tls' : '',
        'sni': tp['sni'] ?? '',
        'alpn': tp['alpn'] ?? '',
        'fp': tp['fp'] ?? '',
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    case 'trojan':
      return 'trojan://${_enc(s('password'))}@$host:$port'
          '${_query({..._tlsParams(tls, insecureKey: 'allowInsecure'), ..._transportParams(tr)})}${_frag(label)}';
    case 'shadowsocks':
      final method = s('method'), pw = s('password');
      // SIP002: base64url userinfo, except the 2022 ciphers (their key is base64 already).
      final user = method.startsWith('2022-')
          ? '${_enc(method)}:${_enc(pw)}'
          : base64Url.encode(utf8.encode('$method:$pw')).replaceAll('=', '');
      final plugin = outbound['plugin'] == null
          ? null
          : [outbound['plugin'], if ('${outbound['plugin_opts'] ?? ''}'.isNotEmpty) outbound['plugin_opts']].join(';');
      return 'ss://$user@$host:$port${plugin == null ? '' : '/${_query({'plugin': plugin})}'}${_frag(label)}';
    case 'hysteria2':
      final obfs = outbound['obfs'] is Map ? outbound['obfs'] as Map : null;
      final hop = [
        for (final r in (outbound['server_ports'] as List? ?? const []))
          () {
            final p = '$r'.split(':');
            return p.length == 2 && p[0] == p[1] ? p[0] : p.join('-');
          }(),
      ];
      return 'hysteria2://${_enc(s('password'))}@$host:$port'
          '${_query({
            ..._tlsParams(tls, insecureKey: 'insecure')..remove('security'),
            'obfs': obfs?['type'],
            'obfs-password': obfs?['password'],
            'mport': hop.join(','),
            'upmbps': outbound['up_mbps'],
            'downmbps': outbound['down_mbps'],
          })}${_frag(label)}';
    case 'tuic':
      return 'tuic://${_enc(s('uuid'))}:${_enc(s('password'))}@$host:$port'
          '${_query({
            'congestion_control': outbound['congestion_control'],
            'udp_relay_mode': outbound['udp_relay_mode'],
            ..._tlsParams(tls, insecureKey: 'allowInsecure')..remove('security'),
          })}${_frag(label)}';
    case 'anytls':
      return 'anytls://${_enc(s('password'))}@$host:$port'
          '${_query({..._tlsParams(tls, insecureKey: 'insecure')..remove('security')})}${_frag(label)}';
  }
  return null;
}

/// [shareLink] of a node as the UI keeps it.
String? shareLinkOf(Node n) => shareLink(n.outbound, name: n.name, flag: n.flag, unsupported: n.unsupported);

// Uri.encodeComponent, not encodeQueryComponent: the parser decodes with
// Uri.decodeComponent, which leaves '+' as it is.
String _enc(String s) => Uri.encodeComponent(s);

String _host(String h) => h.contains(':') && !h.startsWith('[') ? '[$h]' : h;

String _frag(String name) => name.isEmpty ? '' : '#${_enc(name)}';

String _query(Map<String, Object?> q) {
  final parts = [
    for (final e in q.entries)
      if (e.value != null && '${e.value}'.isNotEmpty) '${e.key}=${_enc('${e.value}')}',
  ];
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

/// The link parameters of a sing-box `tls` block, as buildTls reads them back.
Map<String, String?> _tlsParams(Map<String, dynamic>? tls, {required String insecureKey}) {
  if (tls == null || tls['enabled'] != true) return {'security': 'none'};
  final reality = tls['reality'] is Map ? tls['reality'] as Map : null;
  final utls = tls['utls'] is Map ? tls['utls'] as Map : null;
  final isReality = reality != null && reality['enabled'] == true;
  return {
    'security': isReality ? 'reality' : 'tls',
    'sni': tls['disable_sni'] == true ? 'off' : tls['server_name'] as String?,
    'alpn': tls['alpn'] is List ? (tls['alpn'] as List).join(',') : null,
    'fp': utls != null && utls['enabled'] == true ? '${utls['fingerprint'] ?? ''}' : null,
    if (isReality) 'pbk': '${reality['public_key'] ?? ''}',
    if (isReality) 'sid': reality['short_id'] as String?,
    insecureKey: tls['insecure'] == true ? '1' : null,
  };
}

/// The link parameters of a sing-box `transport` block, as buildTransport reads them back.
Map<String, String?> _transportParams(Map<String, dynamic>? tr) {
  if (tr == null) return {'type': 'tcp'};
  switch (tr['type']) {
    case 'ws':
      var path = '${tr['path'] ?? '/'}';
      // Xray-style early data rides in the path: /ws?ed=2048
      if (tr['max_early_data'] != null) path = '$path?ed=${tr['max_early_data']}';
      final headers = tr['headers'] is Map ? tr['headers'] as Map : const {};
      final host = headers['Host'] ?? headers['host'];
      return {'type': 'ws', 'path': path, 'host': host is List ? host.join(',') : host as String?};
    case 'grpc':
      return {'type': 'grpc', 'serviceName': tr['service_name'] as String?};
    case 'http':
      return {'type': 'http', 'host': tr['host'] is List ? (tr['host'] as List).join(',') : tr['host'] as String?, 'path': tr['path'] as String?};
    case 'httpupgrade':
      return {'type': 'httpupgrade', 'host': tr['host'] as String?, 'path': tr['path'] as String?};
  }
  return {'type': '${tr['type']}'};
}
