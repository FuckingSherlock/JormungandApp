import 'dart:io';

import 'address_book.dart';
import 'plan.dart';
import 'routing.dart' show dnsServerJson;

// A hostname-named server in a config is replaced by an address the core resolved itself
// (address_resolver.dart): `server` holds the IP, and the name stays where the protocol needs it — TLS SNI,
// the Host of WebSocket / HTTP upgrade / HTTP transports, the Host of a DoH request. The table of what each
// outbound type gets is docs/rules.md §6 → «Адреса серверов»; this file is the code of it. Nothing here
// touches the network or the disk.

/// `host`: the name when [server] is a hostname, null for an IP, an empty value or a non-string.
String? hostnameOf(Object? server) {
  if (server is! String) return null;
  final s = server.trim();
  if (s.isEmpty || InternetAddress.tryParse(s) != null) return null;
  return AddressBook.key(s);
}

const _notServers = {'selector', 'urltest', 'direct', 'block', 'dns', 'local'};

/// Is a name in the lookup table spelt so (lower case, no brackets)? Pins are keyed by the lower-cased host.
typedef Pins = Map<String, String>;

/// [ob] (a plan node's outbound) with the address of its hostname from [pins], or [ob] itself when it must
/// keep the name:
/// - no pin for it (nothing cached and resolving failed: the old behaviour, sing-box resolves with its
///   `default_domain_resolver`);
/// - it dials through another outbound (`detour`: a chain's exit; that outbound resolves the name on its far
///   side and the other dial fields are ignored);
/// - Shadowsocks with a plugin (obfs / v2ray-plugin build their own request from the server name);
/// - a plain (no TLS) gRPC transport, whose authority comes from the dial target.
Map<String, dynamic> pinOutbound(Map<String, dynamic> ob, Pins pins) {
  if (pins.isEmpty || _notServers.contains(ob['type'])) return ob;
  final host = hostnameOf(ob['server']);
  final ip = host == null ? null : pins[host];
  if (host == null || ip == null) return ob;
  if (ob['detour'] != null) return ob;
  if (ob['type'] == 'shadowsocks' && ob['plugin'] != null) return ob;
  final tls = ob['tls'] is Map ? (ob['tls'] as Map).cast<String, dynamic>() : null;
  final tlsOn = tls != null && tls['enabled'] == true;
  final tr = ob['transport'] is Map ? (ob['transport'] as Map).cast<String, dynamic>() : null;
  if (tr?['type'] == 'grpc' && !tlsOn) return ob;
  final name = '${ob['server']}'.trim(); // the name as the node has it (case kept for the wire)
  final out = {...ob, 'server': ip};
  if (tlsOn && tls['disable_sni'] != true && '${tls['server_name'] ?? ''}'.isEmpty) {
    out['tls'] = {...tls, 'server_name': name}; // an own server_name (Reality's included) is never touched
  }
  if (tr != null) {
    // sing-box sends `domain:port` as the Host of a domain-named server whatever the port (measured on 1.14.2,
    // docs: .claude_states/d2_handover.md): the same value, so a server that matches it still does
    final port = (ob['server_port'] as num?)?.toInt() ?? 443;
    switch (tr['type']) {
      case 'ws':
        final h = (tr['headers'] is Map ? (tr['headers'] as Map).cast<String, dynamic>() : <String, dynamic>{});
        if (!h.keys.any((k) => k.toLowerCase() == 'host')) out['transport'] = {...tr, 'headers': {...h, 'Host': '$name:$port'}};
      case 'httpupgrade':
        if ('${tr['host'] ?? ''}'.isEmpty) out['transport'] = {...tr, 'host': '$name:$port'};
      case 'http':
        final h = tr['host'];
        if (h == null || (h is List && h.isEmpty) || h == '') out['transport'] = {...tr, 'host': [name]};
    }
  }
  return out;
}

/// A DNS server of the config (`dnsServerJson`) named by a host, with the address from [pins]: `server` is
/// the IP, a TLS-based one (https / tls / quic) keeps the name as `tls.server_name`, a DoH server as the
/// `Host` header too, and the bootstrap `domain_resolver` goes (nothing is left to resolve). A server on the
/// VPN side (`detour`) is pinned as well: an address is valid on either side. Others as they are.
Map<String, dynamic> pinDnsServer(Map<String, dynamic> s, Pins pins) {
  final host = hostnameOf(s['server']);
  final ip = host == null ? null : pins[host];
  if (host == null || ip == null) return s;
  final name = '${s['server']}'.trim();
  final out = {...s, 'server': ip}..remove('domain_resolver');
  final type = s['type'];
  if (type == 'https' || type == 'tls' || type == 'quic') {
    final tls = s['tls'] is Map ? (s['tls'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    out['tls'] = {...tls, if ('${tls['server_name'] ?? ''}'.isEmpty) 'server_name': name};
  }
  if (type == 'https') {
    final port = s['server_port'];
    final h = s['headers'] is Map ? (s['headers'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    if (!h.keys.any((k) => k.toLowerCase() == 'host')) {
      out['headers'] = {...h, 'Host': port == null || port == 443 ? name : '$name:$port'};
    }
  }
  return out;
}

/// The hostnames a plan needs an address for, lower case: the servers of its routes' groups and of the rule
/// targets' groups (not a chain exit: it dials through its entry, which resolves the name on the far side), and
/// the DNS servers of Settings → DNS that are named by a host.
Set<String> planHostnames(Map<String, dynamic> plan) {
  final out = <String>{};
  void group(Object? g) {
    if (g is! Map) return;
    for (final n in (g['nodes'] as List? ?? const [])) {
      final ob = n is Map ? n['outbound'] : null;
      if (ob is! Map || ob['detour'] != null || _notServers.contains(ob['type'])) continue;
      final h = hostnameOf(ob['server']);
      if (h != null) out.add(h);
    }
  }

  for (final r in planRoutes(plan)) {
    group(r['entry']);
    if (r['kind'] != 'chain') group(r['main']);
  }
  final routing = plan['routing'];
  if (routing is Map) {
    final targets = routing['targets'];
    if (targets is Map) {
      for (final t in targets.values) {
        if (t is! Map) continue;
        group(t['entry']);
        if (t['kind'] != 'chain') group(t['main']);
      }
    }
    out.addAll(dnsHostnames(routing['dns']));
  }
  return out;
}

/// The hostnames of the servers in [nodes] (nodes as the catalog keeps them: `outbound`, `unsupported`).
Set<String> nodesHostnames(Iterable<Object?> nodes) {
  final out = <String>{};
  for (final n in nodes) {
    if (n is! Map || n['unsupported'] != null) continue;
    final ob = n['outbound'];
    if (ob is! Map || _notServers.contains(ob['type'])) continue;
    final h = hostnameOf(ob['server']);
    if (h != null) out.add(h);
  }
  return out;
}

/// The hostname of the server behind the group member `<groupTag>/<key>` of the plan's routes (the tags of
/// config.dart: `route<i>` and a chain's `route<i>-entry`), when the config pins it: null for an IP, a chain's
/// exit (it dials through its entry) and a member that is not in the plan.
String? memberHostname(Map<String, dynamic> plan, String groupTag, String key) {
  final rs = planRoutes(plan);
  for (var i = 0; i < rs.length; i++) {
    final r = rs[i];
    final chain = r['kind'] == 'chain';
    final Object? g;
    if (groupTag == routeEntryTag(i)) {
      g = chain ? r['entry'] : null;
    } else if (groupTag == routeTag(i)) {
      g = chain ? null : r['main'];
    } else {
      continue;
    }
    if (g is! Map) return null;
    for (final n in (g['nodes'] as List? ?? const [])) {
      if (n is Map && '${n['key']}' == key) {
        final ob = n['outbound'];
        return ob is Map && ob['detour'] == null && !_notServers.contains(ob['type']) ? hostnameOf(ob['server']) : null;
      }
    }
    return null;
  }
  return null;
}

/// The DNS servers of a `routing.dns` plan named by a host (lower case).
Set<String> dnsHostnames(Object? dns) {
  final out = <String>{};
  if (dns is! Map) return out;
  for (final s in (dns['servers'] as List? ?? const [])) {
    if (s is! Map) continue;
    final addrs = s['transports'] is List ? [for (final t in s['transports'] as List) if (t is Map) '${t['addr'] ?? ''}'] : ['${s['addr'] ?? ''}'];
    for (final a in addrs) {
      final j = dnsServerJson('x', a);
      final h = j == null ? null : hostnameOf(j['server']);
      if (h != null) out.add(h);
    }
  }
  return out;
}

/// The address each of [hosts] has in [book] now (the entry's cursor), for [ipv6] on / off. A host with no entry,
/// or none for this IPv6 setting, has no pin.
Pins pinsFor(Iterable<String> hosts, AddressBook book, {required bool ipv6}) {
  final out = <String, String>{};
  for (final h in hosts) {
    final ip = book.get(h)?.pick(ipv6);
    if (ip != null) out[AddressBook.key(h)] = ip;
  }
  return out;
}
