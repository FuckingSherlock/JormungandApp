import 'dart:convert';

import '../node.dart';

/// Share-link style parameters (`security`, `sni`, `fp`, `pbk`, `sid`, `type`, `path`,
/// `host`, `serviceName`, `alpn`, `insecure`…). Links pass their query as is; the
/// Clash parser translates its fields into the same keys, so both share the builders.
typedef Params = Map<String, String>;

String? _first(Iterable<String?> xs) {
  for (final x in xs) {
    if (x != null && x.isNotEmpty) return x;
  }
  return null;
}

bool _truthy(String? v) => v == '1' || v == 'true';

/// sing-box `tls` block, or null when the server runs without TLS.
Map<String, dynamic>? buildTls(Params q, {required bool defaultOn}) {
  final sec = (q['security'] ?? (defaultOn ? 'tls' : 'none')).toLowerCase();
  if (sec != 'tls' && sec != 'reality' && sec != 'xtls') return null;
  final tls = <String, dynamic>{'enabled': true};
  final sni = _first([q['sni'], q['peer'], q['servername']]);
  // `sni=off` (some hy2 links): send no SNI at all.
  if (const {'off', 'none', 'false', '0'}.contains(sni?.toLowerCase())) {
    tls['disable_sni'] = true;
  } else if (sni != null) {
    tls['server_name'] = sni;
  }
  if (_truthy(q['allowInsecure']) || _truthy(q['insecure']) || _truthy(q['allow_insecure'])) {
    tls['insecure'] = true;
  }
  final alpn = q['alpn'];
  if (alpn != null && alpn.isNotEmpty) {
    tls['alpn'] = alpn.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  var fp = q['fp'];
  if (sec == 'reality') {
    tls['reality'] = {
      'enabled': true,
      'public_key': q['pbk'] ?? '',
      if ((q['sid'] ?? '').isNotEmpty) 'short_id': q['sid'],
    };
    // sing-box needs uTLS for Reality.
    if (fp == null || fp.isEmpty || fp == 'none') fp = 'chrome';
  }
  if (fp != null && fp.isNotEmpty && fp != 'none') {
    tls['utls'] = {'enabled': true, 'fingerprint': fp};
  }
  return tls;
}

/// sing-box `transport` block, or the name of a transport sing-box lacks
/// (xhttp, kcp, quic…) as the second value.
(Map<String, dynamic>?, String?) buildTransport(Params q) {
  final type = (q['type'] ?? 'tcp').toLowerCase();
  final host = q['host'];
  final path = q['path'];
  switch (type) {
    case 'tcp' || 'raw' || 'none' || '':
      return (null, null);
    case 'ws' || 'websocket':
      final t = <String, dynamic>{'type': 'ws'};
      var p = path == null || path.isEmpty ? '/' : path;
      // Xray-style early data in the path: /ws?ed=2048
      final ed = RegExp(r'[?&]ed=(\d+)').firstMatch(p);
      if (ed != null) {
        p = p.replaceFirst(RegExp(r'[?&]ed=\d+'), '');
        t['max_early_data'] = int.parse(ed[1]!);
        t['early_data_header_name'] = 'Sec-WebSocket-Protocol';
      }
      t['path'] = p.isEmpty ? '/' : p;
      if (host != null && host.isNotEmpty) t['headers'] = {'Host': host};
      return (t, null);
    case 'grpc':
      return ({'type': 'grpc', 'service_name': _first([q['serviceName'], q['service_name'], path]) ?? ''}, null);
    case 'http' || 'h2':
      return (
        {
          'type': 'http',
          if (host != null && host.isNotEmpty) 'host': host.split(',').map((s) => s.trim()).toList(),
          if (path != null && path.isNotEmpty) 'path': path,
        },
        null
      );
    case 'httpupgrade':
      return (
        {
          'type': 'httpupgrade',
          if (host != null && host.isNotEmpty) 'host': host,
          if (path != null && path.isNotEmpty) 'path': path,
        },
        null
      );
    case 'xhttp' || 'splithttp':
      return (null, 'xhttp');
    default:
      return (null, type);
  }
}

void _addTransport(Map<String, dynamic> ob, Params q, void Function(String) unsupported) {
  final (tr, bad) = buildTransport(q);
  if (tr != null) ob['transport'] = tr;
  if (bad != null) unsupported(bad);
}

Node buildVless({required String name, required String host, required int port, required String uuid, required Params q}) {
  final ob = <String, dynamic>{'type': 'vless', 'server': host, 'server_port': port, 'uuid': uuid};
  final flow = q['flow'];
  // sing-box knows only plain vision (…-udp443 is an Xray variant of the same flow).
  if (flow != null && flow.startsWith('xtls-rprx-vision')) ob['flow'] = 'xtls-rprx-vision';
  final tls = buildTls(q, defaultOn: false);
  if (tls != null) ob['tls'] = tls;
  String? bad;
  _addTransport(ob, q, (b) => bad = b);
  ob['packet_encoding'] = 'xudp';
  return Node.make(name: name, protocol: 'vless', address: host, port: port, identity: uuid, outbound: ob, unsupported: bad);
}

Node buildVmess({
  required String name,
  required String host,
  required int port,
  required String uuid,
  int alterId = 0,
  String cipher = 'auto',
  required Params q,
}) {
  final ob = <String, dynamic>{
    'type': 'vmess',
    'server': host,
    'server_port': port,
    'uuid': uuid,
    'security': cipher.isEmpty ? 'auto' : cipher,
    if (alterId > 0) 'alter_id': alterId,
  };
  final tls = buildTls(q, defaultOn: false);
  if (tls != null) ob['tls'] = tls;
  String? bad;
  _addTransport(ob, q, (b) => bad = b);
  ob['packet_encoding'] = 'xudp';
  return Node.make(name: name, protocol: 'vmess', address: host, port: port, identity: uuid, outbound: ob, unsupported: bad);
}

Node buildTrojan({required String name, required String host, required int port, required String password, required Params q}) {
  final ob = <String, dynamic>{'type': 'trojan', 'server': host, 'server_port': port, 'password': password};
  final tls = buildTls(q, defaultOn: true);
  if (tls != null) ob['tls'] = tls;
  String? bad;
  _addTransport(ob, q, (b) => bad = b);
  return Node.make(name: name, protocol: 'trojan', address: host, port: port, identity: password, outbound: ob, unsupported: bad);
}

/// [plugin] as in SIP002: `obfs-local` / `simple-obfs` / `v2ray-plugin`, [pluginOpts]
/// the `k=v;k=v` string after it.
Node buildSs({
  required String name,
  required String host,
  required int port,
  required String method,
  required String password,
  String? plugin,
  String? pluginOpts,
}) {
  final ob = <String, dynamic>{'type': 'shadowsocks', 'server': host, 'server_port': port, 'method': method, 'password': password};
  String? bad;
  if (plugin != null && plugin.isNotEmpty) {
    final p = plugin == 'simple-obfs' ? 'obfs-local' : plugin;
    if (p == 'obfs-local' || p == 'v2ray-plugin') {
      ob['plugin'] = p;
      if (pluginOpts != null && pluginOpts.isNotEmpty) ob['plugin_opts'] = pluginOpts;
    } else {
      bad = 'plugin $plugin';
    }
  }
  return Node.make(name: name, protocol: 'ss', address: host, port: port, identity: '$method:$password', outbound: ob, unsupported: bad);
}

/// [ports] = extra port ranges for port hopping, as `20000-30000` or `443`.
Node buildHy2({
  required String name,
  required String host,
  required int port,
  required String password,
  List<String> ports = const [],
  required Params q,
}) {
  final ob = <String, dynamic>{'type': 'hysteria2', 'server': host, 'server_port': port, 'password': password};
  final ranges = ports
      .expand((p) => p.split(','))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .map((p) => p.contains('-') ? p.replaceFirst('-', ':') : '$p:$p')
      .toList();
  if (ranges.isNotEmpty) ob['server_ports'] = ranges;
  final up = int.tryParse(RegExp(r'\d+').stringMatch(q['upmbps'] ?? q['up'] ?? '') ?? '');
  final down = int.tryParse(RegExp(r'\d+').stringMatch(q['downmbps'] ?? q['down'] ?? '') ?? '');
  if (up != null) ob['up_mbps'] = up;
  if (down != null) ob['down_mbps'] = down;
  final obfs = q['obfs'];
  if (obfs != null && obfs.isNotEmpty && obfs != 'none') {
    ob['obfs'] = {'type': obfs, 'password': q['obfs-password'] ?? ''};
  }
  ob['tls'] = buildTls({...q, 'security': 'tls'}, defaultOn: true);
  return Node.make(name: name, protocol: 'hy2', address: host, port: port, identity: password, outbound: ob);
}

Node buildTuic({required String name, required String host, required int port, required String uuid, required String password, required Params q}) {
  final tls = buildTls({...q, 'security': 'tls'}, defaultOn: true)!;
  tls.putIfAbsent('alpn', () => ['h3']);
  final ob = <String, dynamic>{
    'type': 'tuic',
    'server': host,
    'server_port': port,
    'uuid': uuid,
    'password': password,
    'congestion_control': q['congestion_control'] ?? 'bbr',
    if ((q['udp_relay_mode'] ?? '').isNotEmpty) 'udp_relay_mode': q['udp_relay_mode'],
    'tls': tls,
  };
  return Node.make(name: name, protocol: 'tuic', address: host, port: port, identity: uuid, outbound: ob);
}

Node buildAnytls({required String name, required String host, required int port, required String password, required Params q}) {
  final ob = <String, dynamic>{
    'type': 'anytls',
    'server': host,
    'server_port': port,
    'password': password,
    'tls': buildTls({...q, 'security': 'tls'}, defaultOn: true),
  };
  return Node.make(name: name, protocol: 'anytls', address: host, port: port, identity: password, outbound: ob);
}

/// Lenient base64 (standard or url-safe, with or without padding / line breaks).
/// Null when [s] is not base64 or does not decode to UTF-8 text.
String? tryBase64(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  if (t.isEmpty || !RegExp(r'^[A-Za-z0-9+/]*=*$').hasMatch(t)) return null;
  t = t.replaceAll('=', '');
  if (t.length % 4 == 1) return null;
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  try {
    return utf8.decode(base64.decode(t));
  } catch (_) {
    return null;
  }
}
