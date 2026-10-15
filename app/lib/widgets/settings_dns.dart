import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show DnsServerCfg, DnsTransport, PickState, dnsKindOf, dnsKinds;

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
/// `dnsCfg`; a ping is per side (`pingDnsSides`): under each side chip its own latency.
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

/// Short protocol label of a race kind (`doh` -> DoH).
String dnsKindName(String kind) => switch (kind) {
  'doh' => 'DoH',
  'dot' => 'DoT',
  'doq' => 'DoQ',
  _ => 'UDP',
};

/// The polls a provider's ping may take (one per second): a dead transport costs the core ~10 s and more per
/// check name, so a full ping of a provider with several of them is long.
const dnsPingPollEvery = Duration(seconds: 1);
const dnsPingPollCap = 60;

/// Starts the core's check of provider [id] and asks again (`poll`: only reads) until it says `testing: false`;
/// [onAnswer] sees every answer as it comes. Returns the last one: its `testing` still true = [cap] polls passed.
/// [alive] false (the page is gone) ends the loop. A poll that reads nothing (the core went away, the in-process
/// fallback has no run) ends it with the earlier answer, its transports no longer `testing`.
Future<DnsSidePing> pingDnsUntilDone(
  CoreHost host,
  String id, {
  void Function(DnsSidePing r)? onAnswer,
  bool Function()? alive,
  Duration every = dnsPingPollEvery,
  int cap = dnsPingPollCap,
}) async {
  var r = await host.pingDnsSides(id);
  for (var i = 0;; i++) {
    if (alive != null && !alive()) return r;
    onAnswer?.call(r);
    if (!r.testing || i >= cap) return r;
    await Future<void>.delayed(every);
    if (alive != null && !alive()) return r;
    final next = await host.pingDnsSides(id, poll: true);
    if (next.races.isEmpty && next.direct == null && next.vpn == null && !next.testing) {
      r = DnsSidePing(
        direct: r.direct,
        vpn: r.vpn,
        servers: r.servers,
        races: [
          for (final race in r.races)
            DnsRace(
              provider: race.provider,
              side: race.side,
              winnerKind: race.winnerKind,
              winnerMs: race.winnerMs,
              transports: [
                for (final t in race.transports)
                  t.testing
                      ? DnsRaceTransport(kind: t.kind, ms: t.ms, state: 'untested', dead: t.dead, reserve: t.reserve)
                      : t,
              ],
            ),
        ],
      );
      onAnswer?.call(r);
      return r;
    }
    r = next;
  }
}

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
  /// id -> the last per-side result (ms per side: negative = no answer, null = cannot be measured)
  final Map<String, DnsSidePing> _res = {};
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

  /// The last known ms of a side: the status the core reports while connected (the transports it has an answer
  /// of), else the last ping's.
  int? _sideMs(String id, String side) {
    final r = _res[id];
    final own = r == null ? null : (side == 'vpn' ? r.vpn : r.direct);
    return CoreHostScope.read(context).dnsHealth?.race(id, side)?.bestMs ?? own;
  }

  /// The race of the provider on a side: the status the core reports while connected, else the last ping's.
  DnsRace? raceOf(String id, String side) =>
      CoreHostScope.read(context).dnsHealth?.race(id, side) ?? _res[id]?.race(id, side);

  /// The protocol to name under a side's ping: the one the core uses, else the fastest that answered.
  String? kindOf(String id, String side) {
    final r = raceOf(id, side);
    return r?.winnerKind ?? r?.bestKind;
  }

  Future<void> _ping(String id) async {
    final host = CoreHostScope.read(context);
    final s = host.catalog.dnsServers[id];
    if (s == null || _testing.contains(id)) return;
    setState(() => _testing.add(id));
    DnsSidePing r;
    try {
      r = await pingDnsUntilDone(host, id, alive: () => mounted);
    } catch (_) {
      r = DnsSidePing(
        direct: s.activeSides.contains('direct') ? -1 : null,
        vpn: s.activeSides.contains('vpn') ? -1 : null,
      );
    }
    if (!mounted) return;
    setState(() {
      _testing.remove(id);
      _res[id] = r;
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
                    last: _res[id],
                    onPinged: (r) {
                      if (mounted) setState(() => _res[id] = r);
                    },
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
                      // dead on the exit node in use only: it answers through another one
                      if (s.on &&
                          s.activeSides.contains('vpn') &&
                          (health?.deadOnNode(id, 'vpn') ?? false))
                        Text(
                          l10n.deadOnThisNode,
                          key: ValueKey('dns-dead-on-node-$id'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.danger),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              for (final side in s.system
                  ? const ['direct']
                  : const ['direct', 'vpn'])
                Padding(
                  padding: EdgeInsets.only(left: side == 'direct' ? 0 : 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SideChip(
                        key: ValueKey('dns-$id-$side'),
                        label: side == 'vpn' ? 'VPN' : 'Direct',
                        on: s.activeSides.contains(side),
                        dead:
                            s.on &&
                            s.activeSides.contains(side) &&
                            (health?.dead(id, side) ?? false),
                        answering: s.on && (health?.answers(id, side) ?? false),
                        onTap: s.system ? null : () => toggleSide(s, side),
                      ),
                      const SizedBox(height: 3),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _ping(id),
                        child: LatencyView(
                          key: ValueKey('dns-ping-$id-$side'),
                          minWidth: 0,
                          ms: s.activeSides.contains(side)
                              ? _sideMs(id, side)
                              : null,
                          // the VPN side is measured by the core only: no spinner without a tunnel
                          testing:
                              _testing.contains(id) &&
                              s.activeSides.contains(side) &&
                              (side == 'direct' || health != null),
                        ),
                      ),
                      // the protocol the side answers with, a second line so the ms never truncates
                      if (s.activeSides.contains(side) &&
                          !s.system &&
                          kindOf(id, side) != null)
                        Text(
                          dnsKindName(kindOf(id, side)!),
                          key: ValueKey('dns-race-$id-$side'),
                          maxLines: 1,
                          style: TextStyle(fontSize: 10, color: c.t3),
                        ),
                    ],
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
        Text(
          sides.length > 1
              ? l10n.dnsWillGoThroughTheSystem
              : sides.first == 'vpn'
              ? l10n.dnsForTrafficThroughTheVpn
              : l10n.dnsForDirectTrafficWillGo,
          style: TextStyle(fontSize: 14, color: c.t2),
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

class _SideChipState extends State<SideChip> {
  /// The pulse is stepped by a timer (not a vsync ticker): a ticker repainted the whole sheet
  /// at the display rate; here the chip sits in its own [RepaintBoundary] and steps at ~20 fps.
  static const _step = Duration(milliseconds: 50);
  static const _half = 2400; // ms, one way of the pulse

  final ValueNotifier<double> _phase = ValueNotifier(0);
  ValueListenable<TickerModeData>? _tickerMode;
  Timer? _timer;
  int _elapsed = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_sync);
      _tickerMode = mode..addListener(_sync);
    }
    _sync();
  }

  @override
  void didUpdateWidget(SideChip old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run =
        widget.answering && widget.on && !widget.dead && (_tickerMode?.value.enabled ?? true);
    if (run && _timer == null) {
      _timer = Timer.periodic(_step, (_) {
        _elapsed = (_elapsed + _step.inMilliseconds) % (2 * _half);
        // 0 -> 1 -> 0 over two halves, eased in/out
        _phase.value = 0.5 - 0.5 * math.cos(_elapsed / _half * math.pi);
      });
      setState(() {});
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _elapsed = 0;
      _phase.value = 0;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_sync);
    _timer?.cancel();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final w = widget;
    final tone = w.dead ? c.danger : c.accent;
    final run = _timer != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: w.onTap,
      child: RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: _phase,
          child: Text(
            w.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: w.on ? tone.tint(w.dead ? .85 : 1) : c.t3,
            ),
          ),
          builder: (_, v, child) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: w.on ? tone.tint(w.dead ? .08 : .14) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                width: run ? 1.5 : 1,
                color: run
                    ? Color.lerp(c.accent.tint(.3), c.accent, v)!
                    : w.on
                    ? tone.tint(w.dead ? .45 : .4)
                    : c.border,
              ),
            ),
            child: child,
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

/// The form over the DNS sheet. [id] null = a new server; [last] = the list's last ping of it, [onPinged] gets every
/// finished ping the form makes (the list shows it too).
Future<void> showDnsForm(
  BuildContext context, {
  String? id,
  DnsSidePing? last,
  ValueChanged<DnsSidePing>? onPinged,
}) => showAppSheet<void>(
  context,
  builder: (_) => DnsForm(id: id, last: last, onPinged: onPinged),
);

class DnsForm extends StatefulWidget {
  const DnsForm({super.key, this.id, this.last, this.onPinged});

  final String? id;
  final DnsSidePing? last;
  final ValueChanged<DnsSidePing>? onPinged;

  @override
  State<DnsForm> createState() => _DnsFormState();
}

class _DnsFormState extends State<DnsForm> {
  late final TextEditingController _name;

  /// The address fields of an own server, in the try order.
  final List<TextEditingController> _rows = [];
  late Set<String> _sides;

  /// The enabled kinds; always a subset of [_present], never empty while there is an address.
  Set<String> _use = {};

  /// [_present] at the last [_sync]: tells a kind that just appeared (turned on) from one that was
  /// switched off by hand.
  Set<String> _seen = {};
  DnsServerCfg? _cfg;

  /// The last ping answer of a saved provider (the list's, then this form's own): its races are the rows' values
  /// unless the status of a connected core has newer ones.
  DnsSidePing? _last;
  bool _raceRunning = false;

  /// The first ask of a run is out and has not answered (the in-process measure takes seconds): the rows spin.
  bool _asking = false;

  /// The cap was reached with checks still `testing`: they show "No answer", never a spinner for ever.
  bool _raceGaveUp = false;

  /// An unsaved draft's Ping: the best ms of each enabled kind's address, measured in this process (direct path).
  final Map<String, int?> _draft = {};
  bool _draftTesting = false;
  bool _draftPinged = false;

  /// An own server: its addresses are a list of fields. The built-in ones and Local show theirs.
  bool get _own => _cfg == null || (!_cfg!.system && !_cfg!.builtin);

  static bool _validAddr(String a) => a != 'system' && dnsAddrRe.hasMatch(a);

  /// The kinds the provider has an address for (own server: a valid address in a field).
  Set<String> get _present => _own
      ? {
          for (final c in _rows)
            if (_validAddr(c.text.trim())) dnsKindOf(c.text.trim()),
        }
      : {for (final t in _cfg!.transports) t.kind};

  @override
  void initState() {
    super.initState();
    final s = widget.id == null
        ? null
        : CoreHostScope.read(context).catalog.dnsServers[widget.id];
    _cfg = s;
    _name = TextEditingController(text: s?.name ?? '');
    _sides = {...(s?.activeSides ?? const ['vpn'])};
    _last = widget.last;
    if (_own) {
      for (final t in s?.transports ?? const <DnsTransport>[]) {
        _rows.add(TextEditingController(text: t.addr));
      }
      if (_rows.isEmpty) _rows.add(TextEditingController());
    }
    _seen = _present;
    _use = {...?s?.use.where(_seen.contains)};
    if (_use.isEmpty) _use = {..._seen};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _raceLoop();
    });
  }

  /// Whether a core is running (its status carries `dns`): only then the VPN side can be measured.
  bool get _viaCore => CoreHostScope.read(context).dnsHealth != null;

  /// The (side, kind) rows of a saved provider: every enabled side x enabled kind, whether or not anything is known.
  List<(String, String)> get _slots {
    if (widget.id == null || _cfg?.system == true) return const [];
    return [
      for (final side in const ['vpn', 'direct'])
        if (_sides.contains(side))
          for (final kind in dnsKinds)
            if (_use.contains(kind) && _seen.contains(kind)) (side, kind),
    ];
  }

  /// The race of the provider on a side: this form's own run while it goes, else the status of a connected core,
  /// else the last ping (this form's, or the list's).
  DnsRace? _raceOn(String side) {
    final id = widget.id!;
    final own = _last?.race(id, side);
    final live = CoreHostScope.read(context).dnsHealth?.race(id, side);
    return _raceRunning ? (own ?? live) : (live ?? own);
  }

  /// A row's value: ms (null = unknown, -1 = no answer) and whether it still spins.
  ({int? ms, bool testing}) _valueOf(String side, String kind) {
    final t = _raceOn(side)?.transport(kind);
    final testing = !_raceGaveUp && ((t?.testing ?? false) || (_asking && (side == 'direct' || _viaCore)));
    if (testing || t == null) return (ms: null, testing: testing);
    if (t.dead || (t.testing && _raceGaveUp)) return (ms: -1, testing: false);
    return (ms: t.ms == -2 ? null : t.ms, testing: false);
  }

  /// The Ping summary: the best answer of any transport on any side; "no answer" only when none answered.
  ({int? ms, bool testing}) get _summary {
    if (widget.id == null) {
      final ms = _draft.values.fold<int?>(null, dnsBetterMs);
      return (ms: ms, testing: _draftTesting);
    }
    int? best;
    var testing = false;
    for (final (side, kind) in _slots) {
      final v = _valueOf(side, kind);
      testing = testing || v.testing;
      best = dnsBetterMs(best, v.ms);
    }
    // no rows (Local) or nothing per transport (a core that gave only sides): the sides' own ms
    best ??= dnsBetterMs(
      _sides.contains('direct') || _cfg?.system == true ? _last?.direct : null,
      _sides.contains('vpn') ? _last?.vpn : null,
    );
    return (ms: best, testing: testing || _asking);
  }

  /// Starts the core's check (or joins the one under way) and follows it by polling until it says `testing: false`;
  /// at the cap the transports still `testing` read "No answer".
  Future<void> _raceLoop() async {
    final id = widget.id;
    if (id == null || _raceRunning) return;
    _raceRunning = true;
    final host = CoreHostScope.read(context);
    try {
      setState(() {
        _raceGaveUp = false;
        _asking = true;
      });
      final DnsSidePing r;
      try {
        r = await pingDnsUntilDone(
          host,
          id,
          alive: () => mounted,
          onAnswer: (a) {
            if (mounted) {
              setState(() {
                _asking = false;
                _last = a;
              });
            }
          },
        );
      } catch (_) {
        if (mounted) setState(() => _asking = false);
        return;
      }
      if (!mounted) return;
      setState(() => _raceGaveUp = r.testing);
      if (!r.testing) widget.onPinged?.call(r);
    } finally {
      _raceRunning = false;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _rows) {
      c.dispose();
    }
    super.dispose();
  }

  /// After the address fields changed: a kind that appeared is turned on, one that is gone is
  /// dropped, and at least one stays on.
  void _sync() {
    final now = _present;
    _use = {..._use.where(now.contains), ...now.difference(_seen)};
    if (_use.isEmpty) _use = {...now};
    _seen = now;
  }

  void _toggleKind(String kind) => setState(() {
    if (!_use.contains(kind)) {
      _use.add(kind);
    } else if (_use.length > 1) {
      _use.remove(kind);
    }
  });

  static String _kindName(String kind) => switch (kind) {
    'doh' => 'DoH',
    'dot' => 'DoT',
    'doq' => 'DoQ',
    _ => 'UDP',
  };

  /// The addresses an unsaved draft's ping tries: every valid one of an enabled kind.
  List<String> get _draftAddrs => [
    for (final c in _rows)
      if (_validAddr(c.text.trim()) && _use.contains(dnsKindOf(c.text.trim()))) c.text.trim(),
  ];

  /// The Ping of an unsaved draft (nothing for the core to race yet): each enabled kind's address is measured in
  /// this process, on the direct path; two addresses of a kind count as the better one.
  Future<void> _pingDraft() async {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final addrs = _draftAddrs;
    if (addrs.isEmpty) {
      showToast(context, l10n.enterAValidAddressFirst);
      return;
    }
    setState(() {
      _draftTesting = true;
      _draftPinged = true;
    });
    final ms = await Future.wait([
      for (final a in addrs) host.pingDns(a).then<int?>((v) => v, onError: (Object _) => -1),
    ]);
    if (!mounted) return;
    setState(() {
      _draftTesting = false;
      _draft.clear();
      for (var i = 0; i < addrs.length; i++) {
        final k = dnsKindOf(addrs[i]);
        _draft[k] = dnsBetterMs(_draft[k], ms[i]);
      }
    });
  }

  void _save() {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    List<DnsTransport>? transports;
    if (_own) {
      // empty fields are skipped, a filled invalid one stops the save; the same address twice counts once
      final addrs = <String>[];
      for (final c in _rows) {
        final a = c.text.trim();
        if (a.isEmpty) continue;
        if (!_validAddr(a)) {
          showToast(context, l10n.addressHttpsTlsQuicUdpAn);
          return;
        }
        if (!addrs.contains(a)) addrs.add(a);
      }
      if (addrs.isEmpty) {
        showToast(context, l10n.addressHttpsTlsQuicUdpAn);
        return;
      }
      transports = [for (final a in addrs) DnsTransport(dnsKindOf(a), a)];
    }
    host.catalog.dnsSave(
      widget.id,
      name: _name.text,
      transports: transports,
      use: _cfg?.system == true ? null : _use,
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

  /// One transport on one side: its result (spinner while the core still asks), "In use" for the
  /// winner, "Reserve" for a transport that answers but is not the one working.
  Widget _raceRow(String side, String kind) {
    final l10n = context.l10n;
    final c = context.colors;
    final draft = widget.id == null;
    final race = draft ? null : _raceOn(side);
    final t = race?.transport(kind);
    final v = draft ? (ms: _draft[kind], testing: _draftTesting) : _valueOf(side, kind);
    final Widget result;
    if (v.testing) {
      result = const LatencyView(testing: true, minWidth: 0);
    } else if (v.ms != null && v.ms! < 0) {
      result = Text(l10n.noAnswer2, style: TextStyle(fontSize: 12, color: c.muted));
    } else {
      result = LatencyView(ms: v.ms, minWidth: 0);
    }
    final tag = race?.winnerKind == kind
        ? l10n.inUse
        : (t?.reserve ?? false)
        ? l10n.reserve
        : null;
    return Padding(
      key: ValueKey('dns-race-$side-$kind'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${side == 'vpn' ? 'VPN' : 'Direct'} · ${_kindName(kind)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: c.t2),
            ),
          ),
          if (tag != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: c.accent.tint(.14),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                tag,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: c.accent),
              ),
            ),
          result,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    CoreHostScope.of(context); // the status of a connected core refreshes the rows
    final summary = _summary;
    // a saved provider's rows always exist; a draft's appear after its Ping (direct, per enabled kind)
    final rows = widget.id == null
        ? [
            if (_draftPinged)
              for (final k in dnsKinds)
                if (_use.contains(k) && _seen.contains(k)) ('direct', k),
          ]
        : _slots;
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
            child: !_own
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in _cfg!.transports)
                        Opacity(
                          opacity: _cfg!.system || _use.contains(t.kind) ? 1 : .5,
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
                      for (final c in _rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: AppTextField(
                                  controller: c,
                                  mono: true,
                                  hint: 'https://1.1.1.1/dns-query',
                                  keyboardType: TextInputType.url,
                                  onChanged: (_) => setState(_sync),
                                ),
                              ),
                              if (_validAddr(c.text.trim())) ...[
                                const SizedBox(width: 8),
                                Text(
                                  _kindName(dnsKindOf(c.text.trim())),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: context.colors.t2,
                                  ),
                                ),
                              ],
                              if (_rows.length > 1)
                                IconBtn(
                                  tooltip: l10n.remove,
                                  kind: IconBtnKind.ghost,
                                  onTap: () => setState(() {
                                    _rows.remove(c);
                                    c.dispose();
                                    _sync();
                                  }),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                            ],
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SecondaryButton(
                          label: l10n.address2,
                          onPressed: () => setState(
                            () => _rows.add(TextEditingController()),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      HintText(
                        l10n.httpsDohTlsDotQuicDoq,
                      ),
                    ],
                  ),
          ),
          if (_cfg?.system != true && _seen.isNotEmpty)
            FormGroup(
              label: l10n.transports,
              child: ChipRow(
                padding: EdgeInsets.zero,
                children: [
                  for (final kind in dnsKinds)
                    if (_seen.contains(kind))
                      AppChip(
                        label: _kindName(kind),
                        active: _use.contains(kind),
                        onTap: () => _toggleKind(kind),
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
                        if (_sides.isEmpty) {
                          _sides.add(side == 'vpn' ? 'direct' : 'vpn');
                        }
                      }),
                    ),
                ],
              ),
            ),
          FormGroup(
            child: Row(
              children: [
                SecondaryButton(
                  label: l10n.ping,
                  onPressed: widget.id == null ? _pingDraft : _raceLoop,
                ),
                const SizedBox(width: 12),
                if (summary.testing)
                  const LatencyView(testing: true, minWidth: 0)
                else if (summary.ms != null && summary.ms! < 0)
                  Text(
                    l10n.noAnswer2,
                    key: const ValueKey('dns-ping-summary'),
                    style: TextStyle(fontSize: 12, color: context.colors.muted),
                  )
                else
                  LatencyView(key: const ValueKey('dns-ping-summary'), ms: summary.ms, minWidth: 0),
              ],
            ),
          ),
          if (rows.isNotEmpty)
            FormGroup(
              child: Column(
                key: const ValueKey('dns-race'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (side, kind) in rows) _raceRow(side, kind),
                  // the VPN side is measured by the running core only
                  if (widget.id != null && rows.any((r) => r.$1 == 'vpn') && !_viaCore)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: HintText(l10n.theVpnSideIsMeasuredOnly),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
