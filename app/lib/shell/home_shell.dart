import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../pages/nodes_page.dart';
import '../pages/settings_page.dart';
import '../theme/app_colors.g.dart';

/// The bottom-nav tabs, in the mockup's order (markup/40-bottomnav.html).
enum AppTab {
  home(Icons.home_outlined),
  nodes(Icons.wifi_tethering),
  logs(Icons.show_chart),
  settings(Icons.person_outline);

  const AppTab(this.icon);

  final IconData icon;

  String label(AppLocalizations l10n) => switch (this) {
    AppTab.home => l10n.home,
    AppTab.nodes => l10n.nodes,
    AppTab.logs => l10n.logs,
    AppTab.settings => l10n.settings,
  };
}

/// Scaffold with the four tabs. Pages stay alive (IndexedStack); Back from any tab goes to Home,
/// Back on Home leaves the app (the mockup: "Back closes the top sheet, then goes Home").
// TODO(ui): sheets (Add, Route, Rules, ...) as a stack that Back closes one by one, and the
// unseen error / warning dots on the Logs item (mockup .nav-dot).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppTab _tab = AppTab.home;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return PopScope(
      canPop: _tab == AppTab.home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _tab = AppTab.home);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: c.surface,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: Scaffold(
          body: IndexedStack(
            index: _tab.index,
            children: const [
              HomePage(),
              NodesPage(),
              LogsPage(),
              SettingsPage(),
            ],
          ),
          bottomNavigationBar: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: NavigationBar(
              selectedIndex: _tab.index,
              onDestinationSelected: (i) =>
                  setState(() => _tab = AppTab.values[i]),
              destinations: [
                for (final t in AppTab.values)
                  NavigationDestination(
                    icon: Icon(t.icon),
                    label: t.label(l10n),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
