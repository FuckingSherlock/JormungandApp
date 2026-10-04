import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One server as the app sees it (Flutter: the model behind NodeRow).
///
/// [outbound] is the sing-box outbound without a tag. [key] hashes the server itself
/// (protocol, address, port, credentials — that is [base]) plus the connection variant
/// (SNI, fingerprint, ALPN, transport…: providers list one server several times with
/// these changed, and each is a working option of its own), never the name
/// (docs/subscription-parsing.md → Дедупликация). [id] is [key] when the node is first
/// seen; an update may keep an older id on a server whose variant changed (see merge.dart),
/// so settings naming it survive. [seq] tells apart servers of one source with the same
/// name ("VK-1", "VK-2"); it sticks to the server across updates.
/// [unsupported] names what sing-box cannot do for this server (e.g. `xhttp`): the node
/// is listed but never put into a config.
class Node {
  Node({
    required this.id,
    required this.key,
    required this.base,
    required this.name,
    this.seq,
    required this.flag,
    required this.protocol,
    required this.address,
    required this.port,
    required this.outbound,
    this.unsupported,
  });

  factory Node.make({
    required String name,
    required String protocol,
    required String address,
    required int port,
    required String identity,
    required Map<String, dynamic> outbound,
    String? unsupported,
  }) {
    String h(String s) => 'n${sha256.convert(utf8.encode(s)).toString().substring(0, 12)}';
    final server = '$protocol|${address.toLowerCase()}|$port|$identity';
    final key = h('$server|${variantOf(outbound)}');
    final (flag, clean) = splitFlag(stripProtocol(name));
    return Node(
      id: key,
      key: key,
      base: h(server),
      name: clean.isEmpty ? '$address:$port' : clean,
      flag: flag,
      protocol: protocol,
      address: address,
      port: port,
      outbound: outbound,
      unsupported: unsupported,
    );
  }

  factory Node.fromJson(Map<String, dynamic> j) => Node(
        id: j['id'] as String,
        key: (j['key'] ?? j['id']) as String,
        base: (j['base'] ?? j['id']) as String, // ids before variants were the base
        seq: (j['num'] as num?)?.toInt(),
        name: (j['name'] ?? '') as String,
        flag: (j['flag'] ?? '🌐') as String,
        protocol: (j['protocol'] ?? '') as String,
        address: (j['address'] ?? '') as String,
        port: int.tryParse('${j['port']}') ?? 0,
        outbound: Map<String, dynamic>.from((j['outbound'] ?? const {}) as Map),
        unsupported: j['unsupported'] as String?,
      );

  final String id;
  final String key;
  final String base;
  final int? seq;
  final String name;
  final String flag;

  /// Short name as the UI shows it: vless, vmess, trojan, ss, hy2, tuic, anytls…
  final String protocol;
  final String address;
  final int port;
  final Map<String, dynamic> outbound;
  final String? unsupported;

  // port is a string in the UI model (mockup NodeRow), kept that way on the wire.
  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'base': base,
        if (seq != null) 'num': seq,
        'name': name,
        'flag': flag,
        'protocol': protocol,
        'address': address,
        'port': '$port',
        'outbound': outbound,
        if (unsupported != null) 'unsupported': unsupported,
      };

  Node copyWith({String? id, int? seq, String? name}) => Node(
        id: id ?? this.id,
        key: key,
        base: base,
        seq: seq ?? this.seq,
        name: name ?? this.name,
        flag: flag,
        protocol: protocol,
        address: address,
        port: port,
        outbound: outbound,
        unsupported: unsupported,
      );
}

/// The connection variant of an outbound: only fields that change how it connects,
/// read the same way whatever format the node came from (defaults a format fills in,
/// like a tag or domain_strategy, stay out, so one server in three formats is one node).
String variantOf(Map<String, dynamic> ob) {
  Map? m(Object? x) => x is Map ? x : null;
  final tls = m(ob['tls']), utls = m(tls?['utls']), reality = m(tls?['reality']);
  final tr = m(ob['transport']), headers = m(tr?['headers']), obfs = m(ob['obfs']);
  final alpn = tls?['alpn'] is List ? ([...(tls!['alpn'] as List).map((e) => '$e')]..sort()).join(',') : null;
  final host = headers?['Host'] ?? headers?['host'] ?? tr?['host'];
  // hysteria2 speaks h3 whether or not a format says so (Clash adds `alpn: [h3]` itself).
  final defaultAlpn = ob['type'] == 'hysteria2' && alpn == 'h3';
  final v = <String, Object?>{
    'tls': tls?['enabled'] == true ? 1 : null,
    'sni': tls?['server_name'],
    'nosni': tls?['disable_sni'] == true ? 1 : null,
    'insecure': tls?['insecure'] == true ? 1 : null,
    'alpn': defaultAlpn ? null : alpn,
    'fp': utls?['enabled'] == true ? utls!['fingerprint'] : null,
    'pbk': reality?['public_key'],
    'sid': reality?['short_id'],
    'flow': ob['flow'],
    'net': tr?['type'],
    'path': tr?['path'],
    'host': host is List ? host.join(',') : host,
    'svc': tr?['service_name'],
    'obfs': obfs == null ? null : '${obfs['type']}:${obfs['password']}',
    'ports': ob['server_ports'] is List ? (ob['server_ports'] as List).join(',') : null,
    'plugin': ob['plugin'] == null ? null : '${ob['plugin']}:${ob['plugin_opts']}',
  }..removeWhere((_, x) => x == null || x == '');
  return jsonEncode(v);
}

/// What the UI's protocol badge says: `reality` for VLESS over Reality (a different thing
/// to block than plain VLESS + TLS), else [Node.protocol].
String protoLabel(String protocol, Map<String, dynamic>? outbound) {
  final tls = outbound?['tls'];
  return tls is Map && tls['reality'] is Map ? 'reality' : protocol;
}

/// Protocol words providers put into server names ("VLESS RU-SPB", "NL | Hysteria2 |
/// Reality"): the protocol has its own badge, so they go. Whole words only; separators
/// left with nothing on one side go too. A name that would end up empty stays as it was.
final _protoWords = RegExp(
  r'(?<![\p{L}\p{N}])(?:vless|vmess|trojan|shadowsocksr?|ssr?|hysteria\s?2|hysteria|hy2|tuic(?:\s?v?5)?|anytls|wireguard|reality)(?![\p{L}\p{N}])',
  caseSensitive: false,
  unicode: true,
);
const _sep = r'[|/\\·•,\-–—+_:;]';
String stripProtocol(String name) {
  var s = name.replaceAll(_protoWords, ' ').replaceAll(RegExp(r'\(\s*\)|\[\s*\]|\{\s*\}'), ' ');
  s = s.replaceAllMapped(RegExp('($_sep)(?:\\s*$_sep)+'), (m) => m[1]!);
  s = s.replaceAll(RegExp('^(?:\\s|$_sep)+|(?:\\s|$_sep)+\$'), '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return s.isEmpty ? name.trim() : s;
}

/// Pulls the first flag emoji (a pair of regional indicators) out of a server name:
/// ('🇩🇪', 'Frankfurt 01') for '🇩🇪 Frankfurt 01'. No flag → ('🌐', name).
(String, String) splitFlag(String name) {
  final r = name.runes.toList();
  bool ri(int c) => c >= 0x1F1E6 && c <= 0x1F1FF;
  for (var i = 0; i + 1 < r.length; i++) {
    if (ri(r[i]) && ri(r[i + 1])) {
      final rest = String.fromCharCodes([...r.sublist(0, i), ...r.sublist(i + 2)]);
      return (String.fromCharCodes([r[i], r[i + 1]]), rest.replaceAll(RegExp(r'\s{2,}'), ' ').trim());
    }
  }
  return ('🌐', name.trim());
}
