import 'dart:convert';

import '../node.dart';
import 'build.dart';
import 'clash.dart';
import 'links.dart';

enum SubFormat { singbox, clash, uriList, unknown }

/// Detects the format by the body, never by the User-Agent that was sent
/// (docs/subscription-parsing.md → Детектирование формата), and parses it.
(SubFormat, List<Node>) parseSubscription(String body) {
  final t = body.trim();
  if (t.startsWith('{')) {
    try {
      final j = jsonDecode(t);
      if (j is Map && j['outbounds'] is List) return (SubFormat.singbox, parseSingboxJson(j));
    } catch (_) {}
    return (SubFormat.unknown, const []);
  }
  if (RegExp(r'^proxies:', multiLine: true).hasMatch(t)) {
    try {
      return (SubFormat.clash, parseClash(t));
    } catch (_) {
      return (SubFormat.unknown, const []);
    }
  }
  final decoded = tryBase64(t);
  final text = decoded != null && decoded.contains('://') ? decoded : t;
  final nodes = parseLinks(text);
  return (nodes.isEmpty ? SubFormat.unknown : SubFormat.uriList, nodes);
}

const _protoOf = {
  'vless': 'vless',
  'vmess': 'vmess',
  'trojan': 'trojan',
  'shadowsocks': 'ss',
  'hysteria2': 'hy2',
  'hysteria': 'hy',
  'tuic': 'tuic',
  'anytls': 'anytls',
  'socks': 'socks',
  'http': 'http',
};

/// Server outbounds of a sing-box config, copied as they are. Groups, direct/block and
/// outbounds that dial through another one (detour, e.g. over shadowtls) are skipped.
List<Node> parseSingboxJson(Map j) {
  final out = <Node>[];
  for (final o in (j['outbounds'] as List).whereType<Map>()) {
    final proto = _protoOf[o['type']];
    if (proto == null || o['detour'] != null || o['server'] == null) continue;
    final ob = Map<String, dynamic>.from(o)
      ..remove('tag')
      ..remove('detour');
    final identity = switch (proto) {
      'ss' => '${o['method']}:${o['password']}',
      _ => '${o['uuid'] ?? o['password'] ?? ''}',
    };
    out.add(Node.make(
      name: '${o['tag'] ?? ''}',
      protocol: proto,
      address: '${o['server']}',
      port: int.tryParse('${o['server_port']}') ?? 0,
      identity: identity,
      outbound: ob,
    ));
  }
  return out;
}
