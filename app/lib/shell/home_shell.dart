import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventRecord;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../core/logs_controller.dart';
import '../core/system_notifier.dart';
import '../pages/nodes_page.dart';
import '../pages/route_page.dart';
import '../pages/rules_page.dart';
import '../pages/settings_page.dart';
import '../platform/notify_channel.dart';
import '../theme/app_colors.g.dart';
import '../platform/tile_channel.dart';
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

/// Scaffold with the four tabs. Pages stay alive (IndexedStack); Back from any tab goes to Home;
/// on Home the desktop leaves the app, Android sends it behind (docs/platforms.md, "Работа в фоне").
// TODO(ui): sheets (Add, Route, Rules, ...) as a stack that Back closes one by one, and the
// unseen error / warning dots on the Logs item (mockup .nav-dot).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  AppTab _tab = AppTab.home;
  StreamSubscription<HostNotice>? _notices;
  final _nodesKey = GlobalKey<NodesPageState>();

  LogsController? _logs;
  StreamSubscription<EventRecord>? _notifs;

  /// Android system notifications: events while the app is behind, the permission, the VPN
  /// notification's text; a tap on one comes back through [NotifyIo.eventTaps].
  SystemNotifier? _sys;
  StreamSubscription<int>? _taps;
  Timer? _flyTimer;
  final _navKey = GlobalKey();

  /// A context under the [AppLinksScope] of [build]: the sheets the links open carry it over.
  final _inner = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sys?.onResumed();
  }

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
    _notifs ??= _logs!.notifications.listen(_notify);
    if (_sys == null) {
      final io = NotifyIo.current;
      _sys = SystemNotifier(host, io: io)..start();
      _taps = io.eventTaps.listen(_openFromShade);
      io.takeLaunchEvent().then((id) {
        if (id != null) _openFromShade(id);
      });
    }
  }

  /// A tap on an event notification: Logs -> Events at it (once the journal is loaded).
  void _openFromShade(int id) {
    if (!mounted) return;
    final host = CoreHostScope.read(context);
    if (host.ready) {
      _links.openLogsEvent?.call(id);
      return;
    }
    void whenReady() {
      if (!host.ready) return;
      host.removeListener(whenReady);
      if (mounted) _links.openLogsEvent?.call(id);
    }

    host.addListener(whenReady);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _taps?.cancel();
    _sys?.dispose();
    _notices?.cancel();
    _notifs?.cancel();
    _flyTimer?.cancel();
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
    _flyTimer?.cancel();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// A background journal event as a toast (mockup `notify` + `toast(msg, act, onTap)`): a tap
  /// opens Logs -> Events at it; when it goes by itself it flies into the Logs item of the nav.
  void _notify(EventRecord e) {
    if (!mounted || _logs == null) return;
    // the app is behind: the shade (Android) instead of a toast nobody sees
    if (_sys?.systemNotifies == true) {
      _sys!.postEvent(e, _logs!.words);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final text = _logs!.words.text(e);
    final textKey = GlobalKey();
    _flyTimer?.cancel();
    messenger.hideCurrentSnackBar();
    // same offer as the Logs row: a site that opens through another entry -> a rule for it
    final d = e.data;
    final canRule =
        e.cat == 'site' &&
        e.type == 'blocked' &&
        d['via'] != null &&
        _links.newRuleFor != null;
    final ctl = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        action: canRule
            ? SnackBarAction(
                label: context.l10n.createRule,
                onPressed: () {
                  _flyTimer?.cancel();
                  _links.newRuleFor!(
                    host: _logs!.words.host(d),
                    via: '${d['via']}',
                  );
                },
              )
            : null,
        // stays until the timer below (it needs the rect for the flight) or a tap
        duration: const Duration(hours: 1),
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _flyTimer?.cancel();
            messenger.hideCurrentSnackBar();
            _links.openLogsEvent?.call(e.id);
          },
          child: SizedBox(
            width: double.infinity,
            child: Text(text, key: textKey),
          ),
        ),
      ),
    );
    _flyTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      final from = _rectOf(textKey);
      final to = _rectOf(_navKey);
      final reduce = MediaQuery.disableAnimationsOf(context);
      if (from != null && to != null && !reduce) {
        // Logs is the third of the four equal items of the bar
        final target = Offset(to.left + to.width * 2.5 / 4, to.center.dy - 8);
        ctl.close();
        messenger.removeCurrentSnackBar();
        _fly(text, from, target);
      } else {
        ctl.close();
      }
    });
  }

  Rect? _rectOf(GlobalKey k) {
    final o = k.currentContext?.findRenderObject();
    if (o is! RenderBox || !o.attached || !o.hasSize) return null;
    return o.localToGlobal(Offset.zero) & o.size;
  }

  /// The toast's text shrinks and fades towards [target] (transform and opacity only, 0.4 s).
  void _fly(String text, Rect from, Offset target) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final theme = Theme.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned.fromRect(
        rect: from.inflate(14), // the snackbar's padding around the text
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeIn,
            onEnd: () => entry.remove(),
            builder: (_, t, child) => Transform.translate(
              offset: (target - from.center) * t,
              child: Transform.scale(
                scale: 1 - 0.9 * t,
                child: Opacity(opacity: 1 - t, child: child),
              ),
            ),
            child: Material(
              color: theme.colorScheme.inverseSurface,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.onInverseSurface),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
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
    final android = CoreHostScope.read(context).isAndroid;
    return PopScope(
      // Android: Back on Home sends the task behind instead of finishing the activity (the
      // engine, the core and the tunnel stay either way; this keeps the window state too)
      canPop: _tab == AppTab.home && !android,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_tab != AppTab.home) {
          _setTab(AppTab.home);
        } else {
          unawaited(const TileChannel().moveToBack());
        }
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
                key: _navKey,
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
