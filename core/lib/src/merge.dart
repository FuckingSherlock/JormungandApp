import 'node.dart';

/// How long a server the provider dropped keeps its settings (docs/connect-model.md →
/// «Пропавшие ноды»).
const goneKeep = Duration(days: 15);

/// Applies a subscription update to a source: servers missing from [fresh] move to
/// `gone` with `goneAt` (settings naming them are kept by the UI), servers that came
/// back leave `gone`, and gone ones older than [goneKeep] are dropped.
///
/// Ids: a fresh node takes the id of the previous node it continues. Matching goes in tiers,
/// each seeing only the nodes the tiers before left unmatched (docs/connect-model.md):
/// 1. same [Node.key] — the same node;
/// 2. same [Node.base] (protocol, address, port, credentials) — the variant changed (SNI, fingerprint);
/// 3. same protocol, address, port and variant — the credentials changed (another account of the provider);
/// 4. same protocol, address and port — both changed.
/// In tiers 2–4 a pair is taken only when it is unambiguous: one unmatched old and one unmatched
/// new node in the tier's group, or in a bigger group the same name (without its «-N» number)
/// that occurs once among the old and once among the new. Otherwise the new node is a new one
/// and the old one is gone.
///
/// Names: servers with the same name get a number ("VK-1", "VK-2"). A server keeps its
/// number across updates; a new one takes the smallest free number of its name.
/// Nodes are plain JSON maps, as the UI holds them.
({List<Map<String, dynamic>> nodes, List<Map<String, dynamic>> gone}) mergeUpdate(
  List<Map<String, dynamic>> prevNodes,
  List<Map<String, dynamic>> prevGone,
  List<Node> fresh, {
  DateTime? now,
}) {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final old = [...prevNodes, ...prevGone];
  String keyOf(Map<String, dynamic> n) => (n['key'] ?? n['id']) as String;
  String baseOf(Map<String, dynamic> n) => (n['base'] ?? n['id']) as String;

  // fresh index -> previous node it continues
  final match = <int, Map<String, dynamic>>{};
  final claimed = <Map<String, dynamic>>{};
  final byKey = <String, Map<String, dynamic>>{};
  for (final n in old) {
    byKey.putIfAbsent(keyOf(n), () => n);
  }
  for (var i = 0; i < fresh.length; i++) {
    final p = byKey[fresh[i].key];
    if (p != null && claimed.add(p)) match[i] = p;
  }
  String variantSig(Map<String, dynamic>? ob) => ob == null ? '' : variantOf(ob);
  String oldVariant(Map<String, dynamic> n) =>
      variantSig(n['outbound'] is Map ? Map<String, dynamic>.from(n['outbound'] as Map) : null);
  String hostSig(Object? protocol, Object? address, Object? port) => '$protocol|${'$address'.toLowerCase()}|$port';
  // the provider's name: our «-N» number off (only ours: a provider's own «Name-2» stays as is)
  String oldName(Map<String, dynamic> n) {
    final raw = n['rawName'];
    if (raw is String) return raw;
    final name = '${n['name'] ?? ''}', num = n['num'];
    return num != null && name.endsWith('-$num') ? name.substring(0, name.length - '-$num'.length) : name;
  }
  // Pairs the unmatched of one tier by signature: a group with one old and one fresh node pairs;
  // a bigger group pairs by name, only names that occur once among the old and once among the fresh.
  void tier(String Function(Node) freshSig, String Function(Map<String, dynamic>) oldSig) {
    final freshBy = <String, List<int>>{}, oldBy = <String, List<Map<String, dynamic>>>{};
    for (var i = 0; i < fresh.length; i++) {
      if (!match.containsKey(i)) freshBy.putIfAbsent(freshSig(fresh[i]), () => []).add(i);
    }
    for (final n in old) {
      if (!claimed.contains(n)) oldBy.putIfAbsent(oldSig(n), () => []).add(n);
    }
    freshBy.forEach((sig, f) {
      final o = oldBy[sig];
      if (o == null) return;
      if (f.length == 1 && o.length == 1) {
        match[f.first] = o.first;
        claimed.add(o.first);
        return;
      }
      final oldByName = <String, List<Map<String, dynamic>>>{}, freshByName = <String, List<int>>{};
      for (final n in o) {
        oldByName.putIfAbsent(oldName(n), () => []).add(n);
      }
      for (final i in f) {
        freshByName.putIfAbsent(fresh[i].name, () => []).add(i);
      }
      freshByName.forEach((name, fs) {
        final os = oldByName[name];
        if (fs.length == 1 && os != null && os.length == 1) {
          match[fs.first] = os.first;
          claimed.add(os.first);
        }
      });
    });
  }

  tier((f) => f.base, baseOf); // 2: the variant changed
  tier((f) => '${hostSig(f.protocol, f.address, f.port)}|${variantSig(f.outbound)}',
      (n) => '${hostSig(n['protocol'], n['address'], n['port'])}|${oldVariant(n)}'); // 3: the credentials changed
  tier((f) => hostSig(f.protocol, f.address, f.port),
      (n) => hostSig(n['protocol'], n['address'], n['port'])); // 4: both changed

  // Ids: kept from the match, else the key; never two nodes with one id.
  final used = <String>{}, ids = <String>[];
  for (var i = 0; i < fresh.length; i++) {
    final kept = match[i]?['id'] as String?;
    ids.add(kept != null && used.add(kept) ? kept : fresh[i].key);
    used.add(ids.last);
  }

  // Numbers for same-named servers; the protocol badge tells apart ones that differ by it
  // (a provider's "VLESS X" and "HY2 X" both become "X").
  final groups = <String, List<int>>{};
  for (var i = 0; i < fresh.length; i++) {
    final f = fresh[i];
    groups.putIfAbsent('${f.flag}${f.name}|${protoLabel(f.protocol, f.outbound)}', () => []).add(i);
  }
  final nums = List<int?>.filled(fresh.length, null);
  for (final g in groups.values) {
    if (g.length < 2) continue;
    final taken = <int>{};
    for (final i in g) {
      final p = match[i], was = (p?['num'] as num?)?.toInt();
      if (was != null && p!['rawName'] == fresh[i].name && taken.add(was)) nums[i] = was;
    }
    var next = 1;
    for (final i in g) {
      if (nums[i] != null) continue;
      while (taken.contains(next)) {
        next++;
      }
      taken.add(next);
      nums[i] = next;
    }
  }

  final nodes = [
    for (var i = 0; i < fresh.length; i++)
      {
        ...fresh[i].copyWith(id: ids[i], seq: nums[i], name: nums[i] == null ? null : '${fresh[i].name}-${nums[i]}').toJson(),
        if (nums[i] != null) 'rawName': fresh[i].name,
      },
  ];
  final gone = <Map<String, dynamic>>[
    for (final n in prevNodes)
      if (!claimed.contains(n)) {...n, 'goneAt': nowMs},
    for (final g in prevGone)
      if (!claimed.contains(g) && nowMs - ((g['goneAt'] as num?)?.toInt() ?? nowMs) < goneKeep.inMilliseconds) g,
  ];
  return (nodes: nodes, gone: gone);
}
