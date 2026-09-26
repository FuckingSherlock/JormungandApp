import 'package:yaml/yaml.dart';

import '../node.dart';
import 'build.dart';

/// Clash / mihomo YAML: every entry of `proxies:` sing-box can run.
List<Node> parseClash(String body) {
  final doc = loadYaml(body);
  final proxies = doc is YamlMap ? doc['proxies'] : null;
  if (proxies is! YamlList) return [];
  final out = <Node>[];
  for (final p in proxies) {
    if (p is! YamlMap) continue;
    try {
      final n = clashProxy(_plain(p) as Map<String, dynamic>);
      if (n != null) out.add(n);
    } catch (_) {
      // one broken entry must not cost the rest
    }
  }
  return out;
}

Object? _plain(Object? v) => switch (v) {
      YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
      YamlList l => [for (final x in l) _plain(x)],
      _ => v,
    };

Node? clashProxy(Map<String, dynamic> p) {
  String s(String k) => p[k]?.toString() ?? '';
  bool b(String k) => p[k] == true || p[k] == 'true';
  Map<String, dynamic> m(String k) => (p[k] as Map?)?.cast<String, dynamic>() ?? const {};

  final type = s('type').toLowerCase();
  final name = s('name');
  final host = s('server');
  final port = int.tryParse(s('port')) ?? 443;

  final q = <String, String>{};
  final reality = m('reality-opts');
  if (reality.isNotEmpty) {
    q['security'] = 'reality';
    q['pbk'] = '${reality['public-key'] ?? ''}';
    if (reality['short-id'] != null) q['sid'] = '${reality['short-id']}';
  } else if (b('tls') || const {'trojan', 'hysteria2', 'tuic', 'anytls'}.contains(type)) {
    q['security'] = 'tls';
  }
  final sni = s('servername').isNotEmpty ? s('servername') : s('sni');
  if (sni.isNotEmpty) q['sni'] = sni;
  if (b('skip-cert-verify')) q['insecure'] = '1';
  if (s('client-fingerprint').isNotEmpty) q['fp'] = s('client-fingerprint');
  if (p['alpn'] is List) q['alpn'] = (p['alpn'] as List).join(',');

  final network = s('network');
  q['type'] = network.isEmpty ? 'tcp' : network;
  switch (network) {
    case 'ws':
      final ws = m('ws-opts');
      var path = '${ws['path'] ?? '/'}';
      final ed = ws['max-early-data'];
      if (ed != null) path += '${path.contains('?') ? '&' : '?'}ed=$ed';
      q['path'] = path;
      final hs = (ws['headers'] as Map?) ?? const {};
      if (hs['Host'] != null) q['host'] = '${hs['Host']}';
    case 'grpc':
      q['serviceName'] = '${m('grpc-opts')['grpc-service-name'] ?? ''}';
    case 'h2' || 'http':
      final h2 = m(network == 'h2' ? 'h2-opts' : 'http-opts');
      final hosts = h2['host'];
      if (hosts is List && hosts.isNotEmpty) q['host'] = hosts.join(',');
      final path = h2['path'];
      if (path != null) q['path'] = path is List ? '${path.first}' : '$path';
      if (network == 'http' && q['security'] != 'tls') q['type'] = 'tcp'; // HTTP header obfs, not a transport
  }

  switch (type) {
    case 'vless':
      if (s('flow').isNotEmpty) q['flow'] = s('flow');
      return buildVless(name: name, host: host, port: port, uuid: s('uuid'), q: q);
    case 'vmess':
      return buildVmess(
        name: name,
        host: host,
        port: port,
        uuid: s('uuid'),
        alterId: int.tryParse(s('alterId')) ?? 0,
        cipher: s('cipher').isEmpty ? 'auto' : s('cipher'),
        q: q,
      );
    case 'trojan':
      return buildTrojan(name: name, host: host, port: port, password: s('password'), q: q);
    case 'ss':
      String? plugin, opts;
      final po = m('plugin-opts');
      if (s('plugin') == 'obfs') {
        plugin = 'obfs-local';
        opts = 'obfs=${po['mode'] ?? 'http'}${po['host'] != null ? ';obfs-host=${po['host']}' : ''}';
      } else if (s('plugin') == 'v2ray-plugin') {
        plugin = 'v2ray-plugin';
        opts = [
          'mode=${po['mode'] ?? 'websocket'}',
          if (po['host'] != null) 'host=${po['host']}',
          if (po['path'] != null) 'path=${po['path']}',
          if (po['tls'] == true) 'tls',
        ].join(';');
      } else if (s('plugin').isNotEmpty) {
        plugin = s('plugin');
      }
      return buildSs(name: name, host: host, port: port, method: s('cipher'), password: s('password'), plugin: plugin, pluginOpts: opts);
    case 'hysteria2':
      if (s('obfs').isNotEmpty) q['obfs'] = s('obfs');
      if (s('obfs-password').isNotEmpty) q['obfs-password'] = s('obfs-password');
      if (s('up').isNotEmpty) q['up'] = s('up');
      if (s('down').isNotEmpty) q['down'] = s('down');
      return buildHy2(name: name, host: host, port: port, password: s('password'), ports: [if (s('ports').isNotEmpty) s('ports')], q: q);
    case 'tuic':
      if (s('congestion-controller').isNotEmpty) q['congestion_control'] = s('congestion-controller');
      if (s('udp-relay-mode').isNotEmpty) q['udp_relay_mode'] = s('udp-relay-mode');
      return buildTuic(name: name, host: host, port: port, uuid: s('uuid'), password: s('password'), q: q);
    case 'anytls':
      return buildAnytls(name: name, host: host, port: port, password: s('password'), q: q);
  }
  return null;
}
