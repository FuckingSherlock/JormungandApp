import 'node.dart';

/// How long a server the provider dropped keeps its settings (docs/connect-model.md →
/// «Пропавшие ноды»).
const goneKeep = Duration(days: 15);

/// Applies a subscription update to a source: servers missing from [fresh] move to
/// `gone` with `goneAt` (settings naming them are kept by the UI), servers that came
/// back leave `gone`, and gone ones older than [goneKeep] are dropped.
/// Nodes are plain JSON maps, as the UI holds them.
({List<Map<String, dynamic>> nodes, List<Map<String, dynamic>> gone}) mergeUpdate(
  List<Map<String, dynamic>> prevNodes,
  List<Map<String, dynamic>> prevGone,
  List<Node> fresh, {
  DateTime? now,
}) {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final ids = {for (final n in fresh) n.id};
  final gone = <Map<String, dynamic>>[
    for (final n in prevNodes)
      if (!ids.contains(n['id'])) {...n, 'goneAt': nowMs},
    for (final g in prevGone)
      if (!ids.contains(g['id']) && nowMs - ((g['goneAt'] as num?)?.toInt() ?? nowMs) < goneKeep.inMilliseconds) g,
  ];
  return (nodes: [for (final n in fresh) n.toJson()], gone: gone);
}
