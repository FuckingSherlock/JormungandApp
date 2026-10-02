import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import '../widgets/add_subscription_dialog.dart';
import '../widgets/app_view.dart';

/// Nodes tab: the catalog (tabs Simple / Profiles; sources, profiles, chains).
// TODO(ui): header actions (search, latency test, more), Simple / Profiles swipeable tabs,
// SourceCard / NodeRow lists, edit mode - mockup markup/20-nodes.html, docs/connect-model.md.
// The "+" is the minimal Add subscription form until the Add sheet is ported.
class NodesPage extends StatelessWidget {
  const NodesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppView(
      title: l10n.nodes,
      actions: [
        IconButton(
          tooltip: l10n.addSubscription,
          color: context.colors.t2,
          icon: const Icon(Icons.add),
          onPressed: () => showAddSubscriptionDialog(context),
        ),
      ],
      child: PlaceholderBody(icon: Icons.wifi_tethering, label: l10n.nodes),
    );
  }
}
