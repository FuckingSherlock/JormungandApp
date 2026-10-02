import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../widgets/app_view.dart';
import '../widgets/conn_badge.dart';
import '../widgets/connect_dock.dart';

/// Home tab: header with the connection badge, stat cards / mode segments (TODO), ConnectDock.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const double dockClearance =
      60; // the power tab overhangs the page (see ConnectDock)

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        AppView(
          // The app name is a brand, not a translated string.
          title: 'Jormungand',
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ConnBadge(
                phase: host.phase,
                onTap: () =>
                    host.isConnected ? host.disconnect() : host.connect(),
              ),
            ),
          ],
          // TODO(ui): StatCards (speed, session, exit IP, connections), mode / route / sys-proxy
          // segments, quick links (mockup markup/10-home.html), VpnAlert.
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, dockClearance + 12),
            children: [
              SizedBox(
                height: 120,
                child: PlaceholderBody(
                  icon: Icons.home_outlined,
                  label: context.l10n.home,
                ),
              ),
            ],
          ),
        ),
        const Align(alignment: Alignment.bottomCenter, child: ConnectDock()),
      ],
    );
  }
}
