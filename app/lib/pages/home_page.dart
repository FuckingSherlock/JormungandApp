import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import 'route_page.dart';
import '../widgets/app_view.dart';
import '../widgets/conn_badge.dart';
import '../widgets/connect_dock.dart';
import '../widgets/nav_cards.dart';
import '../widgets/segments.dart';
import '../widgets/stat_cards.dart';
import '../widgets/vpn_alert.dart';

/// Home tab: header with the connection badge, VpnAlert, the stat cards, the mode / route /
/// system-proxy segments, and the ConnectDock under them (mockup markup/10-home.html).
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onOpenNodes});

  /// Nothing to connect through yet: lead to Nodes and its "+" (mockup `dockTap`).
  final VoidCallback? onOpenNodes;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // The dock is laid out over the list (its tab overhangs the page), so the list keeps the
  // dock's measured height as bottom padding.
  final GlobalKey _dockKey = GlobalKey();
  double _dockHeight = ConnectDock.tabOverhang + 62;

  void _measureDock() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final h = _dockKey.currentContext?.size?.height;
      if (h != null && h != _dockHeight && mounted) {
        setState(() => _dockHeight = h);
      }
    });
  }

  /// The power button / the badge (mockup `toggleMain`): the checks that need the user's eye
  /// are answered here, failures arrive as notices.
  Future<void> _toggle() async {
    final host = CoreHostScope.read(context);
    final result = await host.toggleConnection();
    if (!mounted) return;
    switch (result.outcome) {
      case ConnectOutcome.nothingInAuto:
        await _alertNothingInAuto();
      case ConnectOutcome.catalogEmpty:
        // the other mode has something: Route, where it can be switched to (never a silent switch)
        final other = _usableOtherMode(host);
        if (other != null) {
          await showRouteSheet(context, mode: other);
          return;
        }
        final l10n = context.l10n;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              host.dock.simpleMode
                  ? l10n.addASubscriptionOrAServer
                  : l10n.createAProfileFirst,
            ),
          ),
        );
        widget.onOpenNodes?.call();
      case ConnectOutcome.started ||
          ConnectOutcome.stopped ||
          ConnectOutcome.busy ||
          ConnectOutcome.vpnPermissionDenied ||
          ConnectOutcome.failed:
        break;
    }
  }

  /// `alertNothingInAuto`: every Route entry is off Auto.
  Future<void> _alertNothingInAuto() {
    final l10n = context.l10n;
    final c = Theme.of(context);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.nothingInAuto),
        content: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${l10n.everyEntryInRouteIsSwitched} '),
              TextSpan(
                text: l10n.useInAuto,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: ' ${l10n.onForAtLeastOneEntry}'),
            ],
            style: c.textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              showRouteSheet(context, edit: true);
            },
            child: Text(l10n.openRoute),
          ),
        ],
      ),
    );
  }

  /// The mode the route does not use, when it has something to connect through (the current
  /// one is empty): where Route leads the user instead of a dead end.
  String? _usableOtherMode(CoreHost host) {
    final cat = host.catalog;
    final other = cat.simpleMode ? 'profiles' : 'simple';
    return cat.modeEmpty(other) ? null : other;
  }

  /// A tap on the dock row: Route when there is something to connect (an empty mode with a
  /// usable other one: Route on that, to switch), else Nodes -> +.
  void _rowTap() {
    final host = CoreHostScope.read(context);
    if (host.catalogEmpty) {
      final other = _usableOtherMode(host);
      if (other != null) {
        showRouteSheet(context, mode: other);
      } else {
        widget.onOpenNodes?.call();
      }
    } else {
      showRouteSheet(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.of(context);
    _measureDock();
    return Stack(
      fit: StackFit.expand,
      children: [
        AppView(
          // The app name is a brand, not a translated string.
          title: 'Jormungand',
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ConnBadge(phase: host.phase, onTap: _toggle),
            ),
          ],
          child: ListView(
            padding: EdgeInsets.fromLTRB(12, 8, 12, _dockHeight + 12),
            children: [
              VpnAlert(host: host),
              StatCards(host: host),
              const SizedBox(height: 10),
              SegmentsCard(host: host),
              const SizedBox(height: 10),
              NavCards(host: host),
            ],
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: KeyedSubtree(
            key: _dockKey,
            child: ConnectDock(onPower: _toggle, onRowTap: _rowTap),
          ),
        ),
      ],
    );
  }
}
