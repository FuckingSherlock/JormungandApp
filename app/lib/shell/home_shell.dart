import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../core/logs_controller.dart';
import '../pages/nodes_page.dart';
import '../pages/route_page.dart';
import '../pages/rules_page.dart';
import '../pages/settings_page.dart';
import '../theme/app_colors.g.dart';
import '../widgets/apps_sheet.dart';
import '../widgets/rule_form.dart';
import '../widgets/rules_extras.dart';
import '../widgets/settings_dns.dart';
import 'app_links.dart';

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
  StreamSubscription<HostNotice>? _notices;
  final _nodesKey = GlobalKey<NodesPageState>();

  LogsController? _logs;

  /// A context under the [AppLinksScope] of [build]: the sheets the links open carry it over.
  final _inner = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the host's short messages (a connect that failed, a subscription that did not load...)
    // are toasts on whatever tab is open
    final host = CoreHostScope.read(context);
    _notices ??= host.notices.listen(_toast);
    // one journal for the app: it runs on every tab (the dots on the Logs item come from it)
    _logs ??= LogsController(host)
      ..l10n = context.l10n
      ..start();
  }

  @override
  void dispose() {
    _notices?.cancel();
    _logs?.dispose();
    super.dispose();
  }

  void _setTab(AppTab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    _logs?.setOnScreen(t == AppTab.logs);
    if (t == AppTab.logs) _logs?.open();
  }

  BuildContext get _ctx => _inner.currentContext ?? context;

  void _afterTab(void Function() f) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) f();
    });
  }

  late final AppLinks _links = AppLinks(
    openNodesEntry: (id) {
      _setTab(AppTab.nodes);
      _afterTab(() => _nodesKey.currentState?.openEntry(id));
    },
    openRules: ([at]) => showRulesPage(_ctx, at: at),
    openRuleForm: (id) => showRuleForm(_ctx, id: id),
    openAppAct: (pkg) => showAppAct(_ctx, pkg),
    openDns: () => showDnsSheet(_ctx),
    openRuleSets: () => showRuleSets(_ctx),
    newRuleFor: ({host, app, via}) =>
        showRuleForm(_ctx, host: host, app: app, via: via),
    openRoute: ({edit = false}) => showRouteSheet(_ctx, edit: edit),
    openLogsEvent: (id) {
      _setTab(AppTab.logs);
      _logs?.showEvent(id);
    },
  );

  void _toast(HostNotice n) {
    if (!mounted) return;
    final l10n = context.l10n;
    final text = switch (n.code) {
      'subFailed' when n.args.length == 2 => l10n.couldNotLoad2(
        n.args[0],
        n.args[1],
      ),
      'updateFailed' when n.args.length == 2 => l10n.updateOfFailed(
        n.args[0],
        n.args[1],
      ),
      'initFailed' => l10n.coreNotReachable(n.text),
      'vpnDenied' => l10n.vpnPermissionWasNotGranted,
      'notSaved' => l10n.couldNotSaveTheState(n.text),
      _ => n.text,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Home with nothing to connect through (mockup `dockTap`): Nodes, and its "+".
  void _openNodesAdd() {
    final empty = CoreHostScope.read(context).catalog.sourceOrder.isEmpty;
    setState(() => _tab = AppTab.nodes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _nodesKey.currentState?.openAdd(tab: empty ? 'simple' : null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return PopScope(
      canPop: _tab == AppTab.home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _setTab(AppTab.home);
      },
      child: AppLinksScope(
        links: _links,
        child: Builder(
          key: _inner,
          builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              systemNavigationBarColor: c.surface,
              systemNavigationBarIconBrightness: Brightness.light,
            ),
            child: Scaffold(
              body: IndexedStack(
                index: _tab.index,
                children: [
                  HomePage(onOpenNodes: _openNodesAdd),
                  NodesPage(key: _nodesKey),
                  LogsPage(controller: _logs!),
                  const SettingsPage(),
                ],
              ),
              bottomNavigationBar: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: ListenableBuilder(
                  listenable: _logs!,
                  builder: (context, _) {
                    final unseen = _logs!.unseen;
                    return NavigationBar(
                      selectedIndex: _tab.index,
                      onDestinationSelected: (i) => _setTab(AppTab.values[i]),
                      destinations: [
                        for (final t in AppTab.values)
                          NavigationDestination(
                            icon:
                                t == AppTab.logs &&
                                    (unseen.error || unseen.warn)
                                ? Badge(
                                    smallSize: 8,
                                    backgroundColor: unseen.error
                                        ? c.danger
                                        : c.warn,
                                    child: Icon(t.icon),
                                  )
                                : Icon(t.icon),
                            label: t.label(l10n),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
