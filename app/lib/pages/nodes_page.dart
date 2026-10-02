import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../widgets/app_view.dart';

/// Nodes tab: the catalog (tabs Simple / Profiles; sources, profiles, chains).
// TODO(ui): header actions (search, latency test, more, add), Simple / Profiles swipeable tabs,
// SourceCard / NodeRow lists, edit mode - mockup markup/20-nodes.html, docs/connect-model.md.
class NodesPage extends StatelessWidget {
  const NodesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppView(
      title: l10n.nodes,
      child: PlaceholderBody(icon: Icons.wifi_tethering, label: l10n.nodes),
    );
  }
}
