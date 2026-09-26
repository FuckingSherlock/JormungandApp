import 'dart:convert';

import '../node.dart';
import 'build.dart';
import 'clash.dart';
import 'links.dart';

/// [base64] = a link list sent base64-encoded, [uriList] = plain links.
enum SubFormat {
  singbox('sing-box'),
  clash('clash'),
  base64('base64'),
  uriList('links'),
  unknown('unknown');

  const SubFormat(this.label);

  /// What the source card's format chip says.
  final String label;
}

/// Detects the format by the body and the `Content-Type`, never by the User-Agent that
/// was sent (docs/subscription-parsing.md → Детектирование формата), and parses it. A
/// base64 body is decoded and detected again: providers encode sing-box JSON and Clash
/// YAML too, not only link lists.
(SubFormat, List<Node>) parseSubscription(String body, {String? contentType}) {
  final t = body.trim();
  final plain = _detect(t, (contentType ?? '').toLowerCase());
  if (plain != null) return plain;
  final decoded = tryBase64(t);
  if (decoded != null) {
    final inner = _detect(decoded.trim(), '');
    if (inner != null) return (inner.$1 == SubFormat.uriList ? SubFormat.base64 : inner.$1, inner.$2);
  }
  return (SubFormat.unknown, const []);
}

(SubFormat, List<Node>)? _detect(String t, String contentType) {
  if (t.isEmpty) return null;
  if (t.startsWith('{') || contentType.contains('json')) {
    try {
      final j = jsonDecode(t);
      if (j is Map && j['outbounds'] is List) return (SubFormat.singbox, parseSingboxJson(j));
    } catch (_) {}
    if (t.startsWith('{') && !contentType.contains('yaml')) return (SubFormat.unknown, const []); // JSON, not a sing-box config
  }
  if (contentType.contains('yaml') || RegExp(r'^proxies:', multiLine: true).hasMatch(t)) {
    try {
      final nodes = parseClash(t);
      if (nodes.isNotEmpty || RegExp(r'^proxies:', multiLine: true).hasMatch(t)) return (SubFormat.clash, nodes);
    } catch (_) {}
  }
  final nodes = parseLinks(t);
  return nodes.isEmpty ? null : (SubFormat.uriList, nodes);
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
  'ssh': 'ssh',
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
      // same identities as the link / Clash builders, so one server stays one node
      'socks' || 'http' => '${o['username'] ?? ''}:${o['password'] ?? ''}',
      'hy' => '${o['auth_str'] ?? ''}',
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
