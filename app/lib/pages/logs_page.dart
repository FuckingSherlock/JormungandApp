import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../widgets/app_view.dart';

/// Logs tab: Events journal and Raw (sing-box + core lines).
// TODO(ui): Events / Raw tabs, filter, search, follow, export, unseen error / warning dots on the
// nav item - mockup markup/35-logs.html, js/46-logs.js, js/47-events.js.
class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppView(
      title: l10n.logs,
      child: PlaceholderBody(icon: Icons.show_chart, label: l10n.logs),
    );
  }
}
