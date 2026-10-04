import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show PickState;

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

/// Settings row: `2 on · hijack · FakeIP`.
String dnsSettingsSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cat = host.catalog;
  return '${l10n.onText2(cat.dnsActive.length)} · '
      '${cat.dnsCfg.hijack ? l10n.hijack : l10n.noHijack}'
      '${cat.dnsCfg.fakeip ? ' · FakeIP' : ''}';
}

/// Home card: `Cloudflare · DoH · FakeIP`.
String dnsCardSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cat = host.catalog;
  final first = cat.dnsActive.isEmpty ? null : cat.dnsActive.first;
  if (first == null) return '—';
  return '${first.name} · ${dnsKindLabel(l10n, first.addr)}${cat.dnsCfg.fakeip ? ' · FakeIP' : ''}';
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

    Widget row(int i) {
      final id = cat.dnsOrder[i];
      final s = cat.dnsServers[id]!;
      final rank = s.on ? cat.dnsActive.indexWhere((x) => x.id == id) + 1 : null;
      final failed = health != null && s.on && health.failed.contains(id);
      final inUse = health != null && s.on && !failed && health.active == id;
      return Opacity(
        key: ValueKey(id),
        opacity: s.on ? 1 : .55,
        child: Container(
          color: failed
              ? c.muted.tint(.06)
              : inUse
              ? c.active.tint(.06)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(0, 6, 4, 6),
                  child: GripHandle(),
                ),
              ),
              RankText(rank == 0 ? null : rank),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!cat.dnsToggle(id)) {
                    showToast(
                      context,
                      l10n.atLeastOneDnsServerMust,
                    );
                    return;
                  }
                  save();
                },
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
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            s.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: c.t1,
                            ),
                          ),
                          ConnTag(
                            s.via == 'vpn' ? 'VPN' : 'Direct',
                            tone: s.via == 'vpn' ? TagTone.accent : TagTone.muted,
                          ),
                          if (failed)
                            ConnTag(l10n.noAnswer2, tone: TagTone.off)
                          else if (inUse)
                            ConnTag(l10n.inUse, tone: TagTone.accent),
                        ],
                      ),
                      Text(
                        s.addr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoText.copyWith(fontSize: 12, color: c.t3),
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
                itemCount: cat.dnsOrder.length,
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                onReorderItem: (from, to) {
                  final order = [...cat.dnsOrder];
                  order.insert(to, order.removeAt(from));
                  cat.dnsReorder(order);
                  save();
                },
                itemBuilder: (context, i) => row(i),
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
              SetRow(
                label: 'FakeIP',
                hint: l10n.fasterNoDnsLeaksSomeApps,
                trailing: MiniToggle(
                  on: cfg.fakeip,
                  onChanged: (v) {
                    cfg.fakeip = v;
                    save();
                  },
                ),
                below: cfg.fakeip
                    ? _FakeipExclude(
                        values: cfg.fakeipExclude,
                        onChanged: save,
                      )
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Real answers for": the names FakeIP leaves alone, as removable chips and a field.
class _FakeipExclude extends StatefulWidget {
  const _FakeipExclude({required this.values, required this.onChanged});

  final List<String> values;
  final VoidCallback onChanged;

  @override
  State<_FakeipExclude> createState() => _FakeipExcludeState();
}

class _FakeipExcludeState extends State<_FakeipExclude> {
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add(String raw) {
    final v = raw.trim();
    if (v.isNotEmpty && !widget.values.contains(v)) widget.values.add(v);
    _ctl.clear();
    widget.onChanged();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HintText(l10n.realAnswersFor),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: c.t1.tint(.035),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < widget.values.length; i++)
                _ValueChip(
                  widget.values[i],
                  onRemove: () {
                    widget.values.removeAt(i);
                    widget.onChanged();
                  },
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
                child: IntrinsicWidth(
                  child: TextField(
                    controller: _ctl,
                    focusNode: _focus,
                    autocorrect: false,
                    enableSuggestions: false,
                    cursorColor: c.accent,
                    onSubmitted: _add,
                    style: monoText.copyWith(fontSize: 13, color: c.t1),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '*.example.com',
                      hintStyle: TextStyle(color: c.t3, fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `.vchip`: a value with a small x.
class _ValueChip extends StatelessWidget {
  const _ValueChip(this.text, {required this.onRemove});

  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.accent.tint(.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: monoText.copyWith(fontSize: 12, color: c.t1)),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.close, size: 13, color: c.t3),
              ),
            ),
          ],
        ),
      ),
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
  late String _via;
  int? _ping;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = widget.id == null
        ? null
        : CoreHostScope.read(context).catalog.dnsServers[widget.id];
    _name = TextEditingController(text: s?.name ?? '');
    _addr = TextEditingController(text: s?.addr ?? '');
    _via = s?.via ?? 'vpn';
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
    final addr = _addr.text.trim();
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
    if (!dnsAddrRe.hasMatch(addr)) {
      showToast(
        context,
        l10n.addressHttpsTlsQuicUdpAn,
      );
      return;
    }
    host.catalog.dnsSave(widget.id, name: _name.text, addr: addr, via: _via);
    host.changed();
    Navigator.of(context).pop();
  }

  void _delete() {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final id = widget.id;
    if (id == null) return;
    if (!host.catalog.dnsDelete(id)) {
      showToast(context, l10n.atLeastOneDnsServerMust);
      return;
    }
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
        if (widget.id != null)
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
            child: Column(
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
          FormGroup(
            label: l10n.via,
            child: ChipRow(
              padding: EdgeInsets.zero,
              children: [
                AppChip(
                  label: 'VPN',
                  active: _via == 'vpn',
                  onTap: () => setState(() => _via = 'vpn'),
                ),
                AppChip(
                  label: 'Direct',
                  active: _via == 'direct',
                  onTap: () => setState(() => _via = 'direct'),
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
