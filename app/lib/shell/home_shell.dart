import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventRecord, IgnoredSites;

import '../core/core_host.dart';
import '../core/event_text.dart' show EventWords;
import '../l10n/l10n.dart';
import '../pages/home_page.dart';
import '../pages/logs_page.dart';
import '../core/logs_controller.dart';
import '../core/system_notifier.dart';
import '../core/update_flow.dart';
import '../pages/nodes_page.dart';
import '../pages/route_page.dart';
import '../pages/rules_page.dart';
import '../pages/settings_page.dart';
import '../platform/notify_channel.dart';
import '../theme/app_colors.g.dart';
import '../platform/tile_channel.dart';
import '../widgets/apps_sheet.dart';
import '../widgets/event_rows.dart' show eventOpenTarget, openTargetAction;
import '../widgets/ignored_sites.dart';
import '../widgets/rule_form.dart';
import '../widgets/rules_extras.dart';
import '../widgets/settings_conn.dart' show showConnSheet;
import '../widgets/settings_data.dart';
import '../widgets/report_actions.dart';
import '../widgets/settings_dns.dart';
import '../widgets/sub_wait_popup.dart';
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
  const HomeShell({super.key, this.homeRequests});

  /// "Show Home with the dock" (long-press on the Android Quick Settings tile): Home tab, no sheet open.
  final Stream<void>? homeRequests;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  AppTab _tab = AppTab.home;
  StreamSubscription<HostNotice>? _notices;
  final _nodesKey = GlobalKey<NodesPageState>();

  LogsController? _logs;
  StreamSubscription<EventRecord>? _notifs;
  StreamSubscription<int>? _reopenedSub;

  /// Android system notifications: events while the app is behind, the permission, the VPN
  /// notification's text; a tap on one comes back through [NotifyIo.eventTaps].
  SystemNotifier? _sys;

  /// The app's own update: the install dialog right after «Download & install», the update
  /// notifications (docs/updates.md, section 6).
  UpdateFlow? _flow;
  StreamSubscription<bool>? _updTaps;
  StreamSubscription<int>? _taps;
  StreamSubscription<NoteActionTap>? _actTaps;
  StreamSubscription<void>? _homeSub;
  Timer? _flyTimer;
  final _navKey = GlobalKey();

  /// Per tab: lets the host's notifications through only while the tab is shown.
  final Map<AppTab, HostGate> _gates = {};

  /// A context under the [AppLinksScope] of [build]: the sheets the links open carry it over.
  final _inner = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _homeSub = widget.homeRequests?.listen((_) => _showHome());
  }

  /// Home tab with the dock visible: close sheets and dialogs on top.
  void _showHome() {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    _setTab(AppTab.home);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sys?.onResumed();
      _flow?.onResumed();
    }
    // behind the app the Logs page is not fed, and the unread raw lines go to the state
    _logs?.setForeground(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the host's short messages (a connect that failed, a subscription that did not load...)
    // are toasts on whatever tab is open
    final host = CoreHostScope.read(context);
    for (final t in AppTab.values) {
      _gates.putIfAbsent(t, () => HostGate(host, active: t == _tab));
    }
    _notices ??= host.notices.listen(_toast);
    // one journal for the app: it runs on every tab (the dots on the Logs item come from it)
    _logs ??= LogsController(host)
      ..l10n = context.l10n
      ..start();
    _notifs ??= _logs!.notifications.listen(_notify);
    _reopenedSub ??= _logs!.reopened.listen((id) => _sys?.dropEvent(id));
    if (_sys == null) {
      final io = NotifyIo.current;
      _sys = SystemNotifier(host, io: io, onIgnoreOp: _ignoreFromShade)..start();
      _taps = io.eventTaps.listen(_openFromShade);
      _actTaps = io.actionTaps.listen(_actFromShade);
      io.takeLaunchEvent().then((id) {
        if (id != null) _openFromShade(id);
      });
      io.takeLaunchAction().then((a) {
        if (a != null) _actFromShade(a);
      });
      _flow = UpdateFlow(
        host,
        io: io,
        l10n: () => context.l10n,
        inBackground: () => SystemNotifier.inBackground,
      )..start();
      _updTaps = io.updateTaps.listen(_openUpdate);
      io.takeLaunchUpdate().then((install) {
        if (install != null) _openUpdate(install);
      });
    }
  }

  /// A tap on the update notification: the Data sheet (the update card), and the install dialog when the
  /// notification said «Install». A sheet or a dialog left open is closed first.
  void _openUpdate(bool install) => _whenReady(() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    showDataSheet(_ctx);
    unawaited(_flow?.openedFromShade(install: install));
  });

  /// A tap on an event notification: Logs -> Events at it (once the journal is loaded). A sheet or a
  /// dialog the user left open is closed first, or the tab would change behind it.
  void _openFromShade(int id) => _whenReady(() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    _links.openLogsEvent?.call(id);
  });

  /// «Ignore site» / «Undo» pressed on a notification: done natively without the app, applied here
  /// ([SystemNotifier.drainIgnoreOps]). No toast: the notification itself said it.
  void _ignoreFromShade(SiteIgnoreOp op) {
    final logs = _logs;
    if (logs == null) return;
    if (op.ignore) {
      logs.ignoreSite(op.site);
    } else {
      logs.unignoreSite(IgnoredSites.clean(op.site));
    }
  }

  /// A button of an event notification (ids: `SystemNotifier.eventActions`): Create rule (the editor,
  /// prefilled), or the row's own button done by the same host calls (`connect`, `retry`, `checkNow`,
  /// `retrySub`, `retryRuleSets`, `networkSettings`, `removeProxy`, `reconnect`, `report`, `open`). `ignore`
  /// only comes from a notification posted by an older build (its button opened the app); the current ones
  /// never get here. [NoteActionTap.id] is the id of the notification: the event the row stands for.
  void _actFromShade(NoteActionTap t) {
    _whenReady(() {
      final host = CoreHostScope.read(context);
      final e = _logs?.feed.list.where((x) => x.id == t.id).firstOrNull;
      switch (t.action) {
        case 'rule' when t.site.isNotEmpty:
          _links.newRuleFor?.call(host: t.site, via: t.via.isEmpty ? null : t.via);
        case 'ignore' when t.site.isNotEmpty:
          ignoreSiteWithUndo(
            ScaffoldMessenger.of(context),
            context.l10n,
            _logs!,
            t.site,
          );
        case 'connect':
          unawaited(host.connect());
        case 'retry':
          // the same call as the Retry of the row of that event: a failed connect connects again, a failed system proxy
          // is switched on again, the core is restarted
          switch (e?.key) {
            case 'conn/connectFailed':
              unawaited(host.connect());
            case 'core/sysProxy':
              host.setSysProxy(true);
            default:
              unawaited(host.retry());
          }
        case 'checkNow':
          unawaited(host.checkNow(t.id));
        case 'retryRuleSets':
          unawaited(host.retryRuleSets(t.id));
        case 'networkSettings':
          unawaited(host.openNetworkSettings());
        case 'removeProxy':
          unawaited(host.releaseSysProxy());
        case 'reconnect':
          unawaited(() async {
            await host.disconnect();
            await host.connect();
          }());
        case 'retrySub':
          final sid = '${e?.data['source'] ?? ''}';
          if (sid.isNotEmpty) unawaited(host.updateSource(sid));
        case 'report':
          if (_logs != null) unawaited(showSendReport(_ctx, _logs!));
        case 'open':
          Navigator.of(context).popUntil((r) => r.isFirst);
          _openSubject(e, t.id);
      }
    });
  }

  /// «Open» of a notification: the event's subject (the entry, the rules, the rule sets, DNS), else the event
  /// in Logs.
  void _openSubject(EventRecord? e, int id) {
    // the row's own "Open" (eventOpenTarget), so the button of the shade leads where the one of the row does
    final target = e == null ? null : eventOpenTarget(e, CoreHostScope.read(context));
    final go = target == null ? null : openTargetAction(_links, target);
    if (go != null) {
      go();
      return;
    }
    _links.openLogsEvent?.call(id);
  }

  /// Runs [then] once the host has loaded its state (now, when it has).
  void _whenReady(VoidCallback then) {
    if (!mounted) return;
    final host = CoreHostScope.read(context);
    if (host.ready) {
      then();
      return;
    }
    void whenReady() {
      if (!host.ready) return;
      host.removeListener(whenReady);
      if (mounted) then();
    }

    host.addListener(whenReady);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _taps?.cancel();
    _updTaps?.cancel();
    _flow?.dispose();
    _actTaps?.cancel();
    _homeSub?.cancel();
    _sys?.dispose();
    _notices?.cancel();
    _notifs?.cancel();
    _reopenedSub?.cancel();
    _flyTimer?.cancel();
    _logs?.dispose();
    for (final g in _gates.values) {
      g.dispose();
    }
    super.dispose();
  }

  /// One tab of the stack. Pages stay alive, but a tab that is not shown is not laid out, its
  /// tickers stop and the host's notifications do not rebuild it (its [HostGate] is closed; it
  /// catches up in one rebuild when the tab is shown again).
  Widget _tabBody(AppTab t, Widget page) {
    final on = t == _tab;
    return Offstage(
      offstage: !on,
      child: TickerMode(
        enabled: on,
        child: ExcludeFocus(
          excluding: !on,
          child: CoreHostScope(
            host: CoreHostScope.read(context),
            listenTo: _gates[t],
            child: page,
          ),
        ),
      ),
    );
  }

  void _setTab(AppTab t) {
    if (t == _tab) return;
    _gates[_tab]?.active = false;
    _gates[t]?.active = true;
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
    openNodesAdd: ({tab}) => _openNodesAdd(tab: tab),
    openRules: ([at]) => showRulesPage(_ctx, at: at),
    openRuleForm: (id) => showRuleForm(_ctx, id: id),
    openAppAct: (pkg) => showAppAct(_ctx, pkg),
    openDns: () => showDnsSheet(_ctx),
    openConn: () => showConnSheet(_ctx),
    openRuleSets: () => showRuleSets(_ctx),
    newRuleFor: ({host, app, via}) =>
        showRuleForm(_ctx, host: host, app: app, via: via),
    // the sheet of the app, the form over it (Back of the form lands on the sheet)
    openAppRule: ({required app, ruleId, host, via}) {
      unawaited(showAppAct(_ctx, app));
      if (ruleId == null && host == null) return; // just the dialog of the app
      _afterTab(() => showRuleForm(_ctx, id: ruleId, host: host, appRuleOf: app, fallbackVia: via));
    },
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
    final words = _logs!.words;
    final desc = words.describe(e);
    // a detail of several lines (a site event: rule, app, the routes that failed, the checker) is shown as lines, not
    // as one run of text; a one-line detail stays "title — detail"
    final lines = words.detailLines(desc.detail);
    final text = lines.length > 1 ? desc.title : words.text(e);
    final textKey = GlobalKey();
    _flyTimer?.cancel();
    messenger.hideCurrentSnackBar();
    // same offer as the Logs row: a site that opens through another entry -> a rule for it
    final d = e.data;
    final l10n = context.l10n;
    final site = e.cat == 'site' ? _logs!.words.host(d) : '';
    final canRule =
        e.cat == 'site' &&
        e.type == 'blocked' &&
        d['via'] != null &&
        _logs!.words.appPkg(d).isEmpty && // an event with an app has its Rule row in the card instead
        _links.newRuleFor != null;
    // a snackbar has room for one action: the two of a site event sit under its text
    // the toast sits on inverseSurface: its own text colour is the one that reads there
    final onToast = Theme.of(context).colorScheme.onInverseSurface;
    Widget act(String label, VoidCallback onTap) => TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: onToast,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
    // ⚠️ of a failed route is an icon here: the toast's font has no glyph for it on every device
    Widget line(String s) {
      final warn = s.startsWith(EventWords.warnMark);
      final t = warn ? s.substring(EventWords.warnMark.length).trimLeft() : s;
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (warn) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.warning_amber_rounded, size: 14, color: onToast),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(child: Text(t, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
    }
    final ctl = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        // stays until the timer below (it needs the rect for the flight) or a tap
        duration: const Duration(hours: 1),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _flyTimer?.cancel();
                messenger.hideCurrentSnackBar();
                _links.openLogsEvent?.call(e.id);
              },
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, key: textKey),
                    if (lines.length > 1) for (final s in lines.take(5)) line(s),
                  ],
                ),
              ),
            ),
            if (site.isNotEmpty)
              Wrap(
                spacing: 4,
                children: [
                  if (canRule)
                    act(l10n.createRule, () {
                      _flyTimer?.cancel();
                      messenger.hideCurrentSnackBar();
                      _links.newRuleFor!(host: site, via: '${d['viaTarget'] ?? d['via']}');
                    }),
                  act(l10n.ignoreSite, () {
                    _flyTimer?.cancel();
                    ignoreSiteWithUndo(messenger, l10n, _logs!, site);
                  }),
                ],
              ),
          ],
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

  /// Home with nothing to connect through in any mode (mockup `dockTap`), or Route's empty mode:
  /// Nodes, and its "+". Without sources a profile has nothing to be made of: Simple; otherwise
  /// [tab], or the mode the route is in.
  void _openNodesAdd({String? tab}) {
    final catalog = CoreHostScope.read(context).catalog;
    final empty = catalog.sourceOrder.isEmpty;
    final at = empty ? 'simple' : tab ?? catalog.connectMode;
    _setTab(AppTab.nodes);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodesKey.currentState?.openAdd(tab: at);
    });
  }

  /// Back on Home (Android): with the VPN on, ask whether to keep it running behind the window
  /// or disconnect first; with it off, just send the window behind.
  Future<void> _closeWindow() async {
    final host = CoreHostScope.read(context);
    if (host.isOn) {
      final l10n = context.l10n;
      final disconnect = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.closeTheApp),
          content: Text(l10n.theVpnIsOnClosingThe),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.disconnectAndClose),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.closeWindow),
            ),
          ],
        ),
      );
      if (disconnect == null || !mounted) return; // dismissed: stay
      if (disconnect) await host.disconnect();
    }
    await const TileChannel().moveToBack();
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
          unawaited(_closeWindow());
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
              body: Stack(
                fit: StackFit.expand,
                children: [
                  _tabBody(AppTab.home, HomePage(onOpenNodes: _openNodesAdd)),
                  _tabBody(AppTab.nodes, NodesPage(key: _nodesKey)),
                  _tabBody(AppTab.logs, LogsPage(controller: _logs!)),
                  _tabBody(AppTab.settings, const SettingsPage()),
                  const SubWaitPopup(),
                ],
              ),
              bottomNavigationBar: DecoratedBox(
                key: _navKey,
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: ListenableBuilder(
                  listenable: _logs!.unseenNotifier,
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
