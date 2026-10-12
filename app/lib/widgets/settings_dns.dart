import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show DnsServerCfg, PickState;

import '../core/core_host.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../platform/platform_caps.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'catalog_card.dart' show GripHandle;
import 'form_parts.dart';
import 'latency_text.dart';
import 'pick_parts.dart' show RankText;
import 'rules_parts.dart' show showAppDialog;
import 'settings_parts.dart';

/// Settings -> DNS (mockup 56-dns.js `renderDns`, `openDnsForm`); the Home card opens the same
/// sheet. The servers, their order and the options are `catalog.dnsServers` / `dnsOrder` /
/// `dnsCfg`; a ping is one real query by the core's `dnsLatency` (direct, even for a server the
/// connection would reach via the VPN).
///
/// [focus] = `dnsResolve` scrolls to the Resolve for IP rules row and flashes it (the rule
/// form's link to it).
Future<void> showDnsSheet(BuildContext context, {String? focus}) =>
    showAppSheet<void>(context, builder: (_) => DnsSheet(focus: focus));

String dnsKindLabel(AppLocalizations l10n, String addr) =>
    switch (dnsKind(addr)) {
      'system' => l10n.system,
      'doh' => 'DoH',
      'dot' => 'DoT',
      'doq' => 'DoQ',
      'tcp' => 'TCP',
      _ => 'UDP',
    };

/// Settings row: `2 on · hijack`.
String dnsSettingsSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cat = host.catalog;
  return '${l10n.onText2(cat.dnsActive.length)} · '
      '${cat.dnsCfg.hijack ? l10n.hijack : l10n.noHijack}';
}

/// Home card: `Cloudflare · DoH`.
String dnsCardSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cat = host.catalog;
  final first = cat.dnsActive.isEmpty ? null : cat.dnsActive.first;
  if (first == null) return '—';
  return '${first.name} · ${dnsKindLabel(l10n, first.addr)}';
}

class DnsSheet extends StatefulWidget {
  const DnsSheet({super.key, this.focus});

  final String? focus;

  @override
  State<DnsSheet> createState() => _DnsSheetState();
}

class _DnsSheetState extends State<DnsSheet> {
  /// id -> ms (negative = no answer, null = cannot be measured)
  final Map<String, int?> _ms = {};
  final Set<String> _testing = {};
  final GlobalKey _resolveKey = GlobalKey();
  bool _hit = false;
  Timer? _hitTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cat = CoreHostScope.read(context).catalog;
      // servers never measured get a ping at once
      for (final id in cat.dnsActive.map((s) => s.id)) {
        _ping(id);
      }
      if (widget.focus == 'dnsResolve') _flash();
    });
  }

  @override
  void dispose() {
    _hitTimer?.cancel();
    super.dispose();
  }

  void _flash() {
    final ctx = _resolveKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: .5);
    setState(() => _hit = true);
    _hitTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _hit = false);
    });
  }

  Future<void> _ping(String id) async {
    final host = CoreHostScope.read(context);
    final s = host.catalog.dnsServers[id];
    if (s == null || _testing.contains(id)) return;
    setState(() => _testing.add(id));
    int? ms;
    try {
      ms = await host.pingDns(s.addr);
    } catch (_) {
      ms = -1;
    }
    if (!mounted) return;
    setState(() {
      _testing.remove(id);
      _ms[id] = ms;
    });
  }

  void _pingAll() {
    final cat = CoreHostScope.read(context).catalog;
    for (final id in cat.dnsOrder) {
      _ping(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final host = CoreHostScope.of(context);
    final cat = host.catalog;
    final cfg = cat.dnsCfg;
    final caps = host.caps;
    final health = host.dnsHealth;
    void save() => host.changed();

    final order = cat.dnsDisplayOrder;
    bool deadAll(DnsServerCfg s) =>
        health != null &&
        s.on &&
        s.activeSides.isNotEmpty &&
        s.activeSides.every((side) => health.dead(s.id, side));
    final visible = [
      for (final id in order)
        if (!deadAll(cat.dnsServers[id]!)) id,
    ];
    final dead = [
      for (final id in order)
        if (deadAll(cat.dnsServers[id]!)) id,
    ];
    final onIds = [
      for (final id in order)
        if (cat.dnsServers[id]!.on) id,
    ];

    Future<void> toggleOn(String id) async {
      final sole = cat.dnsSolePathSides(id);
      if (sole.isNotEmpty &&
          !await _confirmNoDns(context, sole, l10n.switchOff)) {
        return;
      }
      cat.dnsToggle(id);
      save();
    }

    Future<void> toggleSide(DnsServerCfg s, String side) async {
      if (s.system) return;
      if (s.on &&
          s.activeSides.contains(side) &&
          cat.dnsSolePathSides(s.id).contains(side) &&
          !await _confirmNoDns(context, [side], l10n.switchOff)) {
        return;
      }
      cat.dnsToggleSide(s.id, side);
      save();
    }

    /// [i] = the place in the draggable list; null = a row of the "Unavailable" block.
    Widget row(String id, int? i) {
      final s = cat.dnsServers[id]!;
      final rank = s.on ? onIds.indexOf(id) + 1 : null;
      return Opacity(
        key: ValueKey(id),
        opacity: s.on ? 1 : .55,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              if (i != null && !s.system)
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(0, 6, 4, 6),
                    child: GripHandle(),
                  ),
                )
              else
                const SizedBox(width: 22),
              RankText(rank == 0 ? null : rank),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => toggleOn(id),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: SubCheckbox(
                    state: s.on ? PickState.all : PickState.none,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showDnsForm(
                    context,
                    id: id,
                    ping: _ms[id],
                    testing: _testing.contains(id),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: c.t1,
                        ),
                      ),
                      Text(
                        s.addr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoText.copyWith(fontSize: 12, color: c.t3),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final side in s.system
                              ? const ['direct']
                              : const ['direct', 'vpn'])
                            SideChip(
                              key: ValueKey('dns-$id-$side'),
                              label: side == 'vpn' ? 'VPN' : 'Direct',
                              on: s.activeSides.contains(side),
                              dead:
                                  s.on &&
                                  s.activeSides.contains(side) &&
                                  (health?.dead(id, side) ?? false),
                              answering:
                                  s.on && (health?.answers(id, side) ?? false),
                              onTap: s.system ? null : () => toggleSide(s, side),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _ping(id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: LatencyView(
                    ms: _ms[id],
                    testing: _testing.contains(id),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final auto = cat.dnsAutoFor('vpn');
    final eff = cat.dnsResolveEff;
    final resolveOpts = <(String, String)>[
      ('off', l10n.off),
      (
        'auto',
        'Auto · ${auto != null ? auto.name : l10n.noVpnServer}',
      ),
      for (final s in cat.dnsActive)
        (s.id, s.name + (s.via == 'vpn' ? '' : ' · ${'Direct'}')),
    ];
    final resolveWarn = eff == 'off'
        ? false
        : eff == 'auto'
        ? auto == null
        : cat.dnsServers[eff]?.via != 'vpn';
    final resolveHint = eff == 'off'
        ? l10n.ipConditionsIpCidrLocalNetworks
        : resolveWarn
        ? (eff == 'auto'
              ? '${l10n.thisQueryLeavesOutsideTheTunnel}${l10n.noDnsServerViaVpnIs}'
              : l10n.thisQueryLeavesOutsideTheTunnel2)
        : l10n.sitesOpenedByNameAreResolved2;
    final tunOff = !host.tun;

    return SheetFrame(
      title: 'DNS',
      titleBadge: const HelpButton(HelpTopic.dns),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AmLabel(
            l10n.globalDns,
            help: HelpTopic.dns,
            action: AmLink(l10n.pingAll, onTap: _pingAll),
          ),
          SetGroup(
            card: true,
            children: [
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: visible.length,
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                onReorderItem: (from, to) {
                  // the dragged order of the shown rows goes back into their places of the
                  // full order; the rows in "Unavailable" keep theirs
                  final shown = [...visible];
                  shown.insert(to, shown.removeAt(from));
                  final full = [...order];
                  var k = 0;
                  for (var j = 0; j < full.length; j++) {
                    if (visible.contains(full[j])) full[j] = shown[k++];
                  }
                  cat.dnsReorder(full);
                  save();
                },
                itemBuilder: (context, i) => row(visible[i], i),
              ),
              if (dead.isNotEmpty)
                DnsDeadBlock(
                  key: const ValueKey('dns-dead'),
                  rows: [for (final id in dead) row(id, null)],
                ),
              InkWell(
                onTap: () => showDnsForm(context),
                splashFactory: NoSplash.splashFactory,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, size: 16, color: c.accent),
                      const SizedBox(width: 6),
                      Text(
                        l10n.addDnsServer,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          SetGroup(
            card: true,
            children: [
              SetRow(
                labelWidget: Row(
                  children: [
                    Flexible(
                      child: Text(
                        l10n.switchAutomatically,
                        style: TextStyle(fontSize: 15, color: c.t1),
                      ),
                    ),
                    const HelpButton(HelpTopic.dnsAuto),
                  ],
                ),
                trailing: MiniToggle(
                  on: cfg.auto,
                  onChanged: (v) {
                    cfg.auto = v;
                    save();
                  },
                ),
              ),
              DimWhen(
                dim: !cat.dnsLocalOn,
                child: SetRow(
                  label: l10n.localForDirectTraffic,
                  hintWidget: HintText(
                    cat.dnsLocalOn
                        ? l10n.whereLocalTheOsResolverStands
                        : l10n.switchLocalOnToChooseIts,
                  ),
                  trailing: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * .3,
                    ),
                    child: SetSelect<String>(
                      value: cfg.directPolicy,
                      maxWidth: 400,
                      options: [
                        ('localFirst', l10n.first),
                        ('priority', l10n.last2),
                      ],
                      onChanged: (v) {
                        cat.dnsSetDirectPolicy(v);
                        save();
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (caps.dnsResolveForIp) ...[
            AmLabel(l10n.withoutTun),
            SetGroup(
              card: true,
              children: [
                AnimatedContainer(
                  key: _resolveKey,
                  duration: const Duration(milliseconds: 300),
                  color: _hit ? c.accent.tint(.18) : Colors.transparent,
                  child: SetRow(
                    label: l10n.resolveForIpRules,
                    hintWidget: HintText(resolveHint, warn: resolveWarn),
                    trailing: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .4,
                      ),
                      child: SetSelect<String>(
                        value: resolveOpts.any((o) => o.$1 == eff) ? eff : 'auto',
                        maxWidth: 400,
                        options: resolveOpts,
                        onChanged: (v) {
                          cfg.resolve = v;
                          save();
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
          AmLabel(l10n.inTunMode),
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: l10n.hijackDns,
                hintWidget: HintText(
                  tunOff
                      ? l10n.worksOnlyInTunTunIs
                      : l10n.allDnsQueriesGoToThe,
                  warn: tunOff && cfg.hijack,
                ),
                trailing: MiniToggle(
                  on: cfg.hijack,
                  onChanged: (v) {
                    cfg.hijack = v;
                    save();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── list parts ─────────────────────────────

/// Asks before [sides] are left without any enabled DNS provider; true = go on.
Future<bool> _confirmNoDns(
  BuildContext context,
  List<String> sides,
  String action,
) async {
  final l10n = context.l10n;
  final c = context.colors;
  final ok = await showAppDialog<bool>(
    context,
    title: l10n.leaveASideWithoutDns,
    builder: (_) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final side in sides)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              side == 'vpn'
                  ? l10n.noDnsServerWillBeLeft2
                  : l10n.noDnsServerWillBeLeft,
              style: TextStyle(fontSize: 14, color: c.t2),
            ),
          ),
      ],
    ),
    actions: (ctx) => [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(false),
        child: Text(l10n.cancel),
      ),
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(true),
        child: Text(action, style: TextStyle(color: c.danger)),
      ),
    ],
  );
  return ok == true;
}

/// A side of a DNS provider (Direct / VPN): lit when the provider is asked on that side, muted
/// red when it is lit and does not answer there, a slow accent border while it answers the side.
class SideChip extends StatefulWidget {
  const SideChip({
    super.key,
    required this.label,
    required this.on,
    this.dead = false,
    this.answering = false,
    this.onTap,
  });

  final String label;
  final bool on;
  final bool dead;
  final bool answering;
  final VoidCallback? onTap;

  @override
  State<SideChip> createState() => _SideChipState();
}

class _SideChipState extends State<SideChip> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SideChip old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.answering && widget.on && !widget.dead;
    if (run && !_ctl.isAnimating) {
      _ctl.repeat(reverse: true);
    } else if (!run && _ctl.isAnimating) {
      _ctl
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final w = widget;
    final tone = w.dead ? c.danger : c.accent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: w.onTap,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (_, child) {
          final run = _ctl.isAnimating;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: w.on ? tone.tint(w.dead ? .08 : .14) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                width: run ? 1.5 : 1,
                color: run
                    ? Color.lerp(c.accent.tint(.3), c.accent, _ctl.value)!
                    : w.on
                    ? tone.tint(w.dead ? .45 : .4)
                    : c.border,
              ),
            ),
            child: child,
          );
        },
        child: Text(
          w.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: w.on ? tone.tint(w.dead ? .85 : 1) : c.t3,
          ),
        ),
      ),
    );
  }
}

/// "Unavailable · N": the enabled providers that do not answer on any of their sides, folded
/// under the list like the dropped servers of Nodes ([rows] are built by the sheet).
class DnsDeadBlock extends StatefulWidget {
  const DnsDeadBlock({super.key, required this.rows});

  final List<Widget> rows;

  @override
  State<DnsDeadBlock> createState() => _DnsDeadBlockState();
}

class _DnsDeadBlockState extends State<DnsDeadBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          splashFactory: NoSplash.splashFactory,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _open ? 0 : -.25,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more, size: 16, color: c.t3),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.unavailable3('${widget.rows.length}'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.t2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.noAnswerOnAnyOfTheir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.t3),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) ...widget.rows,
      ],
    );
  }
}

// ───────────────────────────── add / edit a server ─────────────────────────────

/// The form over the DNS sheet. [id] null = a new server; [ping] = what the list already knows.
Future<void> showDnsForm(
  BuildContext context, {
  String? id,
  int? ping,
  bool testing = false,
}) => showAppSheet<void>(
  context,
  builder: (_) => DnsForm(id: id, ping: ping, testing: testing),
);

class DnsForm extends StatefulWidget {
  const DnsForm({super.key, this.id, this.ping, this.testing = false});

  final String? id;
  final int? ping;
  final bool testing;

  @override
  State<DnsForm> createState() => _DnsFormState();
}

class _DnsFormState extends State<DnsForm> {
  late final TextEditingController _name;
  late final TextEditingController _addr;
  late Set<String> _sides;
  DnsServerCfg? _cfg;
  int? _ping;
  bool _testing = false;

  /// A provider with several addresses (the built-in ones, Local) is shown, not edited as one.
  bool get _fixedAddr =>
      _cfg != null && (_cfg!.system || _cfg!.transports.length != 1);

  @override
  void initState() {
    super.initState();
    final s = widget.id == null
        ? null
        : CoreHostScope.read(context).catalog.dnsServers[widget.id];
    _cfg = s;
    _name = TextEditingController(text: s?.name ?? '');
    _addr = TextEditingController(text: s?.addr ?? '');
    _sides = {...(s?.activeSides ?? const ['vpn'])};
    _ping = widget.ping;
  }

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    super.dispose();
  }

  Future<void> _pingDraft() async {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final addr = _fixedAddr ? _cfg!.addr : _addr.text.trim();
    if (!dnsAddrRe.hasMatch(addr)) {
      showToast(context, l10n.enterAValidAddressFirst);
      return;
    }
    setState(() => _testing = true);
    int? ms;
    try {
      ms = await host.pingDns(addr);
    } catch (_) {
      ms = -1;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ping = ms;
    });
  }

  void _save() {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final addr = _addr.text.trim();
    if (!_fixedAddr && !dnsAddrRe.hasMatch(addr)) {
      showToast(
        context,
        l10n.addressHttpsTlsQuicUdpAn,
      );
      return;
    }
    host.catalog.dnsSave(
      widget.id,
      name: _name.text,
      addr: _fixedAddr ? null : addr,
      sides: _cfg?.system == true ? null : _sides,
    );
    host.changed();
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final id = widget.id;
    if (id == null) return;
    final sole = host.catalog.dnsSolePathSides(id);
    if (sole.isNotEmpty && !await _confirmNoDns(context, sole, l10n.deleteServer)) {
      return;
    }
    if (!mounted) return;
    if (!host.catalog.dnsDelete(id)) return;
    host.changed();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SheetFrame(
      title: widget.id == null ? l10n.addDnsServer : l10n.editDnsServer,
      footer: [
        PrimaryButton(label: l10n.save, onPressed: _save),
        if (widget.id != null && _cfg?.builtin != true)
          DangerTextButton(label: l10n.deleteServer, onPressed: _delete),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            label: l10n.name,
            child: AppTextField(controller: _name, hint: l10n.optional),
          ),
          FormGroup(
            label: l10n.address,
            child: _fixedAddr
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in _cfg!.transports)
                        Opacity(
                          opacity: _cfg!.usedTransports.contains(t) ? 1 : .5,
                          child: Text(
                            '${dnsKindLabel(l10n, t.addr)}  ${t.addr}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoText.copyWith(
                              fontSize: 12,
                              color: context.colors.t2,
                            ),
                          ),
                        ),
                      if (_cfg!.builtin) ...[
                        const SizedBox(height: 6),
                        HintText(l10n.builtInServersCannotBeDeleted),
                      ],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppTextField(
                        controller: _addr,
                        mono: true,
                        hint: 'https://1.1.1.1/dns-query',
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 6),
                      HintText(
                        l10n.httpsDohTlsDotQuicDoq,
                      ),
                    ],
                  ),
          ),
          if (_cfg?.system != true)
            FormGroup(
              label: l10n.via,
              child: ChipRow(
                padding: EdgeInsets.zero,
                children: [
                  for (final side in const ['vpn', 'direct'])
                    AppChip(
                      label: side == 'vpn' ? 'VPN' : 'Direct',
                      active: _sides.contains(side),
                      onTap: () => setState(() {
                        if (!_sides.remove(side)) _sides.add(side);
                      }),
                    ),
                ],
              ),
            ),
          FormGroup(
            child: Row(
              children: [
                SecondaryButton(label: l10n.ping, onPressed: _pingDraft),
                const SizedBox(width: 12),
                LatencyView(
                  ms: _ping,
                  testing: _testing,
                  minWidth: 0,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
