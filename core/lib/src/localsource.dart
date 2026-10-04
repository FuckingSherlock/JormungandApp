import 'fetch.dart' show maxSubscriptionBytes;
import 'merge.dart';
import 'node.dart';
import 'parse/subscription.dart';

/// `kind` of a local source: servers read once from a file the user picked
/// (docs/connect-model.md → «Локальный источник»). It has no URL, never updates by itself
/// and has no Update action; importing the file again is how it changes.
const localSourceKind = 'file';

/// A source's name from the picked file's name: a trailing `.json` / `.yaml` / `.yml` /
/// `.txt` / `.conf` / `.list` is dropped (other dots are part of the name); nothing left —
/// "Local file".
String localSourceName(String fileName) {
  final n = fileName.replaceFirst(RegExp(r'\.(json|ya?ml|txt|conf|list)$', caseSensitive: false), '').trim();
  return n.isEmpty ? 'Local file' : n;
}

/// Reads [text] (sing-box JSON, Clash YAML, or a plain / base64 link list — detected by
/// the content, like a subscription body) into a new local source: the source as the
/// catalog keeps it, without an `id` (the catalog owner allocates it). Servers are
/// deduplicated by node id and named exactly like a subscription's (numbers for equal
/// names, `mergeUpdate`). A [FormatException] with the message for the user when nothing
/// was recognised or the file is too big.
Map<String, dynamic> localSourceFromText(String name, String text, {DateTime? now}) {
  if (text.length > maxSubscriptionBytes) {
    throw FormatException('The file is over ${maxSubscriptionBytes ~/ 1048576} MB');
  }
  final (format, parsed) = parseSubscription(text);
  final unique = <String, Node>{};
  for (final n in parsed) {
    unique.putIfAbsent(n.id, () => n); // the first of equal servers stays
  }
  if (unique.isEmpty) throw const FormatException('No servers found in the file');
  final at = now ?? DateTime.now();
  final m = mergeUpdate(const [], const [], unique.values.toList(), now: at);
  return {
    'kind': localSourceKind,
    'name': localSourceName(name),
    'enabled': true,
    'inAuto': true,
    'offNodes': <String>[],
    'disabledNodes': <String>[],
    'nodes': m.nodes,
    'gone': <Object>[],
    'count': m.nodes.length,
    'format': format.label,
    'updatedAt': at.millisecondsSinceEpoch,
  };
}
