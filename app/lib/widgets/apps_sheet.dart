import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'app_view.dart';
import 'form_parts.dart';
import 'rules_parts.dart';
import 'target_picker.dart';

/// Rules -> Per-app routing (mockup 42-apps.js). Each app gets its own action, no switch on top:
/// Default (goes by the rules), Proxy (through a target, with a Fallback like a rule's), Direct or
/// Block; "Split TCP / UDP" gives TCP and UDP an action each. Apps come first in the engine's order.
/// The list is the installed apps (Android: through the platform channel; the desktop gives none, so
/// there it shows the apps that already have a rule). A tap opens [showAppAct].
Future<void> showApps(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _AppsSheet());

void _appsHelp(BuildContext context) {
  final l10n = context.l10n;
  showTermsSheet(context, l10n.perAppRouting, [
    ('Default', l10n.theAppGoesByTheRules),
    (l10n.directProxyBlock, l10n.theAppAlwaysGoesThisWay),
    (l10n.splitTcpUdp, l10n.twoRoutesForOneAppE),
  ]);
}

class _AppRow {
  const _AppRow(this.pkg, this.name, this.system);

  final String pkg;
  final String name;
  final bool system;
}

class _AppsSheet extends StatefulWidget {
  const _AppsSheet();

  @override
  State<_AppsSheet> createState() => _AppsSheetState();
}

class _AppsSheetState extends State<_AppsSheet> {
  final _search = TextEditingController();
  String _filter = 'user';
  List<InstalledApp>? _installed;
  bool _started = false;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final host = CoreHostScope.read(context);
    // what the host already knows shows at once; the platform is asked again for an app installed since
    host.installedApps().then(_got);
    host.installedApps(refresh: true).then(_got).whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  void _got(List<InstalledApp> list) {
    if (mounted) setState(() => _installed = list);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final cat = CoreHostScope.of(context).catalog;
    final installed = _installed ?? const <InstalledApp>[];
    final rows = <_AppRow>[
      for (final a in installed) _AppRow(a.pkg, a.name, a.system),
      // an app with a rule that this device does not list (the desktop, an uninstalled app)
      for (final pkg in cat.appRules.keys)
        if (!installed.any((a) => a.pkg == pkg))
          _AppRow(pkg, cat.appLabel(pkg), false),
    ];
    final q = _search.text.trim().toLowerCase();
    final shown =
        [
          for (final a in rows)
            if ((_filter == 'set'
                    ? cat.appRules.containsKey(a.pkg)
                    : _filter == 'sys'
                    ? a.system
                    : !a.system) &&
                (q.isEmpty ||
                    a.name.toLowerCase().contains(q) ||
                    a.pkg.contains(q)))
              a,
        ]..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    return SheetFrame(
      title: l10n.perAppRouting,
      titleBadge: RoundHelp(onTap: () => _appsHelp(context)),
      full: true,
      scrolls: false,
      subHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            child: SearchBox(
              controller: _search,
              hint: l10n.searchApps,
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (f, label) in [
                  ('user', l10n.user),
                  ('sys', l10n.system),
                  ('set', l10n.configured),
                ])
                  AppChip(
                    label: label,
                    active: _filter == f,
                    onTap: () => setState(() => _filter = f),
                  ),
              ],
            ),
          ),
        ],
      ),
      // a lazy list: a phone has hundreds of apps, and every row on screen asks for its icon
      child: CustomScrollView(
        slivers: [
          if (shown.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Center(
                  child: Text(
                    _loading ? '…' : l10n.noApps,
                    style: TextStyle(fontSize: 14, color: c.t3),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: c.t1.tint(.035),
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                sliver: SliverList.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, thickness: 1, color: c.border),
                  itemBuilder: (context, i) => _AppListRow(
                    key: ValueKey(shown[i].pkg),
                    app: shown[i],
                    onTap: () =>
                        showAppAct(context, shown[i].pkg, name: shown[i].name),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AppListRow extends StatelessWidget {
  const _AppListRow({super.key, required this.app, required this.onTap});

  final _AppRow app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.t1.tint(.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            AppIcon(pkg: app.pkg, name: app.name),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: c.t1),
                  ),
                  Text(
                    app.pkg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoText.copyWith(fontSize: 11, color: c.t3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: _AppState(pkg: app.pkg),
            ),
          ],
        ),
      ),
    );
  }
}

/// The right column of an app row: its own route (a line per protocol when split); else the service
/// that covers it ("VPN · service"); else a dash.
class _AppState extends StatelessWidget {
  const _AppState({required this.pkg});

  final String pkg;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final cat = CoreHostScope.of(context).catalog;
    final r = cat.appRules[pkg];
    TextStyle style(String act) => TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: actColor(c, act),
    );
    if (r != null) {
      // A lost target (deleted / off / no servers) is an error under the state, with where its traffic goes.
      final lost = [
        for (final (p, h) in r.halves)
          if (h.act == 'proxy')
            if (targetLostTag(l10n, cat, h.target, cat.planAppFallback(h)) case final tag?)
              r.split ? '$p $tag' : tag,
      ];
      final state = r.split
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (p, h) in r.halves)
                  Text(
                    '$p ${appHalfText(l10n, cat, h)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style(h.act),
                  ),
              ],
            )
          : Text(
              appActText(l10n, cat, r),
              textAlign: TextAlign.right,
              style: style(appStateAct(r)),
            );
      if (lost.isEmpty) return state;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          state,
          for (final t in lost) ...[
            const SizedBox(height: 3),
            ConnTag(t, tone: TagTone.error),
          ],
        ],
      );
    }
    final svc = serviceOfApp(pkg);
    final sv = svc == null ? null : cat.quickCfg.services[svc];
    if (sv != null && sv != 'default') {
      return Opacity(
        opacity: .75,
        child: Text(
          l10n.service3(serviceState(sv)),
          textAlign: TextAlign.right,
          style: style(sv == 'vpn' ? 'proxy' : 'direct'),
        ),
      );
    }
    return Text('—', textAlign: TextAlign.right, style: style('default'));
  }
}

// ───────────────────────────── one app's route (dialog) ─────────────────────────────

/// One app's route in a small dialog: Route (Default | Proxy | Direct | Block), Via and Fallback
/// for TCP and UDP together or each (Split). [name] is the app's name when the caller knows it.
Future<void> showAppAct(BuildContext context, String pkg, {String? name}) {
  final host = CoreHostScope.read(context);
  final label = name ?? host.catalog.appLabel(pkg);
  return showDialog<void>(
    context: context,
    builder: (_) => _AppActDialog(host: host, pkg: pkg, name: label),
  );
}

class _AppActDialog extends StatefulWidget {
  const _AppActDialog({
    required this.host,
    required this.pkg,
    required this.name,
  });

  final CoreHost host;
  final String pkg;
  final String name;

  @override
  State<_AppActDialog> createState() => _AppActDialogState();
}

class _AppActDialogState extends State<_AppActDialog> {
  late final AppRule _d = cloneApp(widget.host.catalog.appRules[widget.pkg]);
  bool _udp = false;

  Catalog get _cat => widget.host.catalog;

  @override
  void initState() {
    super.initState();
    widget.host.holdPlan(); // one plan for the whole editing, sent when the dialog is closed
  }

  @override
  void dispose() {
    widget.host.releasePlan();
    super.dispose();
  }

  void _save() {
    _cat.saveApp(widget.pkg, _d, label: widget.name);
    widget.host.changed();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    if (!_d.split) _udp = false;
    final h = _udp ? _d.udp : _d.tcp;
    final proto = _d.split ? (_udp ? 'UDP' : 'TCP') : '';
    final svcKey = serviceOfApp(widget.pkg);
    final act = appIsDefault(_d) ? 'default' : 'own';
    return Dialog(
      backgroundColor: c.sheet,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.borderHi),
      ),
      child: ContentScale(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.t1,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: GestureDetector(
                    onHorizontalDragEnd: (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (!_d.split || v.abs() < 200) return;
                      setState(() => _udp = v < 0);
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _splitRow(context),
                        if (_d.split) _tabs(context),
                        _half(context, h, proto),
                        if (svcKey != null) _svcNote(context, svcKey, act),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: Text(l10n.save)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _splitRow(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SetRow(
        labelWidget: Row(
          children: [
            Icon(Icons.link, size: 18, color: c.t3),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                l10n.splitTcpUdp,
                style: TextStyle(fontSize: 15, color: c.t1),
              ),
            ),
            RoundHelp(onTap: () => _appsHelp(context), tight: false),
          ],
        ),
        trailing: MiniToggle(
          on: _d.split,
          onChanged: (v) => setState(() => _d.split = v),
        ),
      ),
    );
  }

  /// `.nodes-tabs`: TCP | UDP with the ink that slides under the chosen one.
  Widget _tabs(BuildContext context) {
    final c = context.colors;
    Widget tab(String label, bool udp) => Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _udp = udp),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _udp == udp ? c.t1 : c.t3,
              ),
            ),
          ),
        ),
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Stack(
        children: [
          Row(children: [tab('TCP', false), tab('UDP', true)]),
          Positioned.fill(
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              alignment: _udp ? Alignment.bottomRight : Alignment.bottomLeft,
              child: FractionallySizedBox(
                widthFactor: .5,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _half(BuildContext context, AppHalf h, String proto) {
    final c = context.colors;
    final l10n = context.l10n;
    final own = h.act == 'proxy';
    final fbOn = own || h.act == 'default';
    final hint = switch (h.act) {
      'default' =>
        proto.isNotEmpty
            ? l10n.byTheRulesFallbackIfThe(proto)
            : l10n.goesByTheRulesFallbackIf,
      'proxy' => l10n.throughTheViaTargetFallbackIf,
      'direct' => l10n.alwaysBypassesTheVpn,
      _ =>
        proto.isNotEmpty
            ? l10n.isBlockedWhileConnected(proto)
            : l10n.noNetworkAtAllWhileConnected,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegRow(
                label: l10n.route,
                options: const [
                  ('default', 'Default'),
                  ('proxy', 'Proxy'),
                  ('direct', 'Direct'),
                  ('block', 'Block'),
                ],
                value: h.act,
                onChanged: (v) => setState(() => h.act = v),
              ),
              Divider(height: 1, thickness: 1, color: c.border),
              TargetRow(
                label: l10n.via,
                target: h.target,
                mode: own
                    ? TargetRowMode.normal
                    : h.act == 'default'
                    ? TargetRowMode.fixed
                    : TargetRowMode.inert,
                lostFallback: own ? _cat.planAppFallback(h) : null,
                onPick: (t) => setState(() => h.target = t),
              ),
              Divider(height: 1, thickness: 1, color: c.border),
              FallbackRows(
                fallback: h.fallback,
                fallbackTarget: h.fallbackTarget,
                on: fbOn,
                own: own ? h.target : '',
                onFallback: (v) => setState(() => h.fallback = v),
                onTarget: (t) => setState(() => h.fallbackTarget = t),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Text(
              hint,
              style: TextStyle(fontSize: 12, height: 1.4, color: c.t2),
            ),
          ),
        ),
      ],
    );
  }

  /// The service with the same app: what it does, and who wins.
  Widget _svcNote(BuildContext context, String key, String act) {
    final c = context.colors;
    final l10n = context.l10n;
    final title = serviceTitles[key] ?? key;
    final sv = _cat.quickCfg.services[key];
    final added = sv != null && sv != 'default';
    final state = added
        ? l10n.service4(title, serviceState(sv))
        : l10n.serviceNotAdded(title);
    final who = act == 'default'
        ? (added
              ? '${l10n.soThisAppGoes} ${serviceState(sv)} ${l10n.byTheService}'
              : l10n.addItInRulesServicesTo)
        : l10n.thisAppSOwnRouteWins;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
      child: Text(
        '$state — $who',
        style: TextStyle(fontSize: 12, height: 1.4, color: c.t2),
      ),
    );
  }
}
