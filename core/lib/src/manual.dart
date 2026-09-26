import 'dart:convert';

import 'node.dart';
import 'parse/build.dart';

/// A server typed in by hand (Nodes → Add server without a link, Edit server): the form's
/// protocol, address, port and secret. [protocol] is the UI's short name (vless, vmess,
/// trojan, ss, hy2, tuic, anytls, socks). [secret] is the UUID or password; `method:password`
/// for ss, `uuid:password` for tuic, optional `user:password` for socks.
///
/// With [outbound] of the same protocol (an edit) the rest of the old outbound — TLS,
/// transport, flow, obfs… — stays and only what the form shows changes; an empty
/// [secret] keeps the old one. Otherwise a plain outbound is built with the builders the
/// link parser uses. Throws [FormatException] with a message for the user.
Node manualNode({
  required String protocol,
  required String address,
  required int port,
  String secret = '',
  String name = '',
  Map<String, dynamic>? outbound,
  String? unsupported,
}) {
  final type = _types[protocol];
  if (type == null) throw FormatException('Unknown protocol "$protocol"');
  address = address.trim();
  if (address.startsWith('[') && address.endsWith(']')) address = address.substring(1, address.length - 1);
  if (address.isEmpty) throw const FormatException('Address is required');
  if (port < 1 || port > 65535) throw const FormatException('Port must be 1–65535');
  secret = secret.trim();
  (String, String)? pair() {
    final i = secret.indexOf(':');
    return i < 0 ? null : (secret.substring(0, i), secret.substring(i + 1));
  }

  if (outbound != null && outbound['type'] == type) {
    final ob = (jsonDecode(jsonEncode(outbound)) as Map).cast<String, dynamic>()
      ..['server'] = address
      ..['server_port'] = port;
    if (secret.isNotEmpty) {
      switch (protocol) {
        case 'vless' || 'vmess':
          ob['uuid'] = secret;
        case 'ss':
          final p = pair();
          if (p != null) ob['method'] = p.$1;
          ob['password'] = p?.$2 ?? secret;
        case 'tuic':
          final p = pair();
          if (p == null) throw const FormatException('TUIC needs uuid:password');
          ob['uuid'] = p.$1;
          ob['password'] = p.$2;
        case 'socks':
          final p = pair();
          ob['username'] = p?.$1 ?? secret;
          if (p != null) ob['password'] = p.$2;
        default:
          ob['password'] = secret;
      }
    }
    return Node.make(
      name: name,
      protocol: protocol,
      address: address,
      port: port,
      identity: identityOf(ob),
      outbound: ob,
      unsupported: unsupported,
    );
  }

  if (secret.isEmpty && protocol != 'socks') {
    throw FormatException(switch (protocol) {
      'vless' || 'vmess' => 'UUID is required',
      'ss' => 'Enter method:password, e.g. aes-256-gcm:secret',
      'tuic' => 'Enter uuid:password',
      _ => 'Password is required',
    });
  }
  const q = <String, String>{};
  switch (protocol) {
    case 'vless':
      return buildVless(name: name, host: address, port: port, uuid: secret, q: q);
    case 'vmess':
      return buildVmess(name: name, host: address, port: port, uuid: secret, q: q);
    case 'trojan':
      return buildTrojan(name: name, host: address, port: port, password: secret, q: q);
    case 'ss':
      final p = pair();
      if (p == null || p.$1.isEmpty) throw const FormatException('Enter method:password, e.g. aes-256-gcm:secret');
      return buildSs(name: name, host: address, port: port, method: p.$1, password: p.$2);
    case 'hy2':
      return buildHy2(name: name, host: address, port: port, password: secret, q: q);
    case 'tuic':
      final p = pair();
      if (p == null) throw const FormatException('Enter uuid:password');
      return buildTuic(name: name, host: address, port: port, uuid: p.$1, password: p.$2, q: q);
    case 'anytls':
      return buildAnytls(name: name, host: address, port: port, password: secret, q: q);
  }
  // socks: no link form, no builder
  final p = pair();
  final ob = <String, dynamic>{
    'type': 'socks',
    'server': address,
    'server_port': port,
    'version': '5',
    if (secret.isNotEmpty) 'username': p?.$1 ?? secret,
    if (p != null) 'password': p.$2,
  };
  return Node.make(name: name, protocol: 'socks', address: address, port: port, identity: identityOf(ob), outbound: ob);
}

const _types = {
  'vless': 'vless',
  'vmess': 'vmess',
  'trojan': 'trojan',
  'ss': 'shadowsocks',
  'hy2': 'hysteria2',
  'tuic': 'tuic',
  'anytls': 'anytls',
  'socks': 'socks',
};

/// The credential part of a node's identity, as the parsers count it (see [Node.key]).
String identityOf(Map<String, dynamic> ob) =>
    ob['type'] == 'shadowsocks' ? '${ob['method']}:${ob['password']}' : '${ob['uuid'] ?? ob['password'] ?? ''}';
