import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One server as the app sees it (Flutter: the model behind NodeRow).
///
/// [outbound] is the sing-box outbound without a tag. [id] stays the same across
/// subscription updates: it hashes what makes the server itself — protocol, address,
/// port and credentials, never the name (docs/subscription-parsing.md → Дедупликация).
/// [unsupported] names what sing-box cannot do for this server (e.g. `xhttp`): the node
/// is listed but never put into a config.
class Node {
  Node({
    required this.id,
    required this.name,
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
    final key = '$protocol|${address.toLowerCase()}|$port|$identity';
    final id = 'n${sha256.convert(utf8.encode(key)).toString().substring(0, 12)}';
    final (flag, clean) = splitFlag(name);
    return Node(
      id: id,
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
        name: (j['name'] ?? '') as String,
        flag: (j['flag'] ?? '🌐') as String,
        protocol: (j['protocol'] ?? '') as String,
        address: (j['address'] ?? '') as String,
        port: int.tryParse('${j['port']}') ?? 0,
        outbound: Map<String, dynamic>.from((j['outbound'] ?? const {}) as Map),
        unsupported: j['unsupported'] as String?,
      );

  final String id;
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
        'name': name,
        'flag': flag,
        'protocol': protocol,
        'address': address,
        'port': '$port',
        'outbound': outbound,
        if (unsupported != null) 'unsupported': unsupported,
      };
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
