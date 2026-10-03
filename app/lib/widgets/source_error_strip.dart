import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show Source;

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'nodes_text.dart';

/// SourceErrorStrip on a subscription card (mockup 33-source-error.js): its last fetch or update
/// failed. `lastError` `{msg, at}` stays on the source, the servers of the last good fetch keep
/// working; Retry is Update (a source that never loaded fetches again). Nothing while it is
/// [updating] or when there is no error.
class SourceErrorStrip extends StatelessWidget {
  const SourceErrorStrip({
    super.key,
    required this.source,
    required this.updating,
    required this.onRetry,
  });

  final Source source;
  final bool updating;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = source.unknown['lastError'];
    if (e is! Map || source.kind != 'sub' || updating) {
      return const SizedBox.shrink();
    }
    final c = context.colors;
    final l10n = context.l10n;
    final at = e['at'];
    final title = source.nodes.isNotEmpty
        ? l10n.updateFailed
        : l10n.couldNotLoad;
    return Container(
      margin: const EdgeInsets.only(right: 14, bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.muted.tint(.08),
        border: Border.all(color: c.muted.tint(.25)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: c.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  at is num ? '$title · ${timeAgo(l10n, at)}' : title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.muted,
                  ),
                ),
                Text(
                  '${e['msg'] ?? ''}',
                  style: TextStyle(fontSize: 12, color: c.t2),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: c.cardHi,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: c.borderHi),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  l10n.retry,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.t1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
