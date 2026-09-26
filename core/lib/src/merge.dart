import 'node.dart';

/// How long a server the provider dropped keeps its settings (docs/connect-model.md →
/// «Пропавшие ноды»).
const goneKeep = Duration(days: 15);

/// Applies a subscription update to a source: servers missing from [fresh] move to
/// `gone` with `goneAt` (settings naming them are kept by the UI), servers that came
/// back leave `gone`, and gone ones older than [goneKeep] are dropped.
///
/// Ids: a fresh node takes the id of the previous node with the same [Node.key]. A node
/// whose variant changed (the provider swapped its SNI or fingerprint) keeps the old id
/// when that is unambiguous — exactly one unmatched old node and one unmatched new node
/// of the same server ([Node.base]). Otherwise it is a new node and the old one is gone.
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
  final freshByBase = <String, List<int>>{}, oldByBase = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < fresh.length; i++) {
    if (!match.containsKey(i)) freshByBase.putIfAbsent(fresh[i].base, () => []).add(i);
  }
  for (final n in old) {
    if (!claimed.contains(n)) oldByBase.putIfAbsent(baseOf(n), () => []).add(n);
  }
  freshByBase.forEach((base, f) {
    final o = oldByBase[base];
    if (f.length == 1 && o != null && o.length == 1) {
      match[f.first] = o.first;
      claimed.add(o.first);
    }
  });

  // Ids: kept from the match, else the key; never two nodes with one id.
  final used = <String>{}, ids = <String>[];
  for (var i = 0; i < fresh.length; i++) {
    final kept = match[i]?['id'] as String?;
    ids.add(kept != null && used.add(kept) ? kept : fresh[i].key);
    used.add(ids.last);
  }

  // Numbers for same-named servers.
  final groups = <String, List<int>>{};
  for (var i = 0; i < fresh.length; i++) {
    groups.putIfAbsent('${fresh[i].flag}${fresh[i].name}', () => []).add(i);
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
