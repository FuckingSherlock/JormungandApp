import 'dart:convert';
import 'dart:typed_data';

// DNS messages on the wire (RFC 1035; the same bytes are the body of a DoH request, RFC 8484, and the payload
// of DoT / DoQ after a 2 byte length): a query for A / AAAA and the reading of an answer, name compression
// included. The address resolver (address_resolver.dart) is the user; dns_probe.dart keeps its own small
// A-only helper for the latency check.

const dnsTypeA = 1, dnsTypeAaaa = 28;

/// A query for [name] of record [type] (A / AAAA), class IN, with `RD` set and a 16 bit [id].
/// null: [name] has a label that is empty or longer than 63 bytes (it is not a name).
Uint8List? dnsQueryOf(String name, int type, int id) {
  final b = BytesBuilder();
  b.add([id >> 8 & 255, id & 255, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  final n = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
  if (n.isEmpty) return null;
  for (final label in n.split('.')) {
    final l = utf8.encode(label);
    if (l.isEmpty || l.length > 63) return null;
    b.addByte(l.length);
    b.add(l);
  }
  b.add([0, type >> 8 & 255, type & 255, 0, 1]);
  return b.toBytes();
}

/// What an answer holds: the response code, the addresses of its A / AAAA records (a CNAME chain is followed
/// by the records themselves: the owner name is not compared) and the smallest TTL (seconds) among them.
class DnsAnswer {
  const DnsAnswer({required this.rcode, required this.v4, required this.v6, required this.ttl, required this.truncated});

  /// 0 = NOERROR, 3 = NXDOMAIN, 2 = SERVFAIL, …
  final int rcode;
  final List<String> v4, v6;
  final int ttl;
  final bool truncated;

  bool get empty => v4.isEmpty && v6.isEmpty;
}

/// Reads the answer [data] to the query with [id]. null: not a well-formed answer to that query (too short, QR
/// not set, another id, a pointer out of range).
DnsAnswer? parseDnsAnswer(List<int> data, int id) {
  if (data.length < 12 || data[0] != (id >> 8 & 255) || data[1] != (id & 255) || (data[2] & 0x80) == 0) return null;
  final rcode = data[3] & 15, truncated = (data[2] & 0x02) != 0;
  final qd = data[4] << 8 | data[5], an = data[6] << 8 | data[7];
  var p = 12;
  // a name: labels up to a zero byte or a pointer (2 bytes); the position after it. -1 = malformed.
  int skipName(int at) {
    var i = at;
    while (true) {
      if (i >= data.length) return -1;
      final l = data[i];
      if (l == 0) return i + 1;
      if (l & 0xC0 == 0xC0) return i + 2 <= data.length ? i + 2 : -1;
      if (l & 0xC0 != 0) return -1;
      i += 1 + l;
    }
  }

  for (var i = 0; i < qd; i++) {
    p = skipName(p);
    if (p < 0 || p + 4 > data.length) return null;
    p += 4;
  }
  final v4 = <String>[], v6 = <String>[];
  var ttl = -1;
  for (var i = 0; i < an; i++) {
    p = skipName(p);
    if (p < 0 || p + 10 > data.length) return null;
    final type = data[p] << 8 | data[p + 1];
    final t = (data[p + 4] << 24 | data[p + 5] << 16 | data[p + 6] << 8 | data[p + 7]) & 0x7FFFFFFF;
    final len = data[p + 8] << 8 | data[p + 9];
    p += 10;
    if (p + len > data.length) return null;
    if (type == dnsTypeA && len == 4) {
      v4.add(data.sublist(p, p + 4).join('.'));
      ttl = ttl < 0 ? t : (t < ttl ? t : ttl);
    } else if (type == dnsTypeAaaa && len == 16) {
      v6.add(_ip6(data.sublist(p, p + 16)));
      ttl = ttl < 0 ? t : (t < ttl ? t : ttl);
    }
    p += len;
  }
  return DnsAnswer(rcode: rcode, v4: v4, v6: v6, ttl: ttl < 0 ? 0 : ttl, truncated: truncated);
}

/// 16 bytes → the canonical text of an IPv6 address (the longest run of zero groups as `::`).
String _ip6(List<int> b) {
  final g = [for (var i = 0; i < 16; i += 2) b[i] << 8 | b[i + 1]];
  var bestAt = -1, bestLen = 0;
  for (var i = 0; i < 8;) {
    if (g[i] != 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < 8 && g[j] == 0) {
      j++;
    }
    if (j - i > bestLen) (bestAt, bestLen) = (i, j - i);
    i = j;
  }
  if (bestLen < 2) bestAt = -1;
  final out = StringBuffer();
  for (var i = 0; i < 8; i++) {
    if (i == bestAt) {
      out.write('::');
      i += bestLen - 1;
      continue;
    }
    if (out.isNotEmpty && !out.toString().endsWith(':')) out.write(':');
    out.write(g[i].toRadixString(16));
  }
  return out.toString();
}

/// The query in the form a DoH GET carries it: base64url without padding (RFC 8484 §4.1).
String dohParam(List<int> query) => base64Url.encode(query).replaceAll('=', '');
