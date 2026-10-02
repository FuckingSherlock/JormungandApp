import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';

/// One node (server) row of a SourceCard / profile: flag + name, protocol badge, latency.
/// Stub: name and latency text only.
// TODO(ui): flag (Flags font fallback), proto badge, ping colour, off-switch, drag handle.
class NodeRow extends StatelessWidget {
  const NodeRow({super.key, required this.name, this.latencyMs});

  final String name;
  final int? latencyMs;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.t1),
            ),
          ),
          Text(
            latencyMs == null ? '-' : '$latencyMs',
            style: TextStyle(fontSize: 12, color: c.t2),
          ),
        ],
      ),
    );
  }
}
