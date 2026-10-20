import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_sheet.dart';
import '../widgets/apps_sheet.dart';
import '../widgets/catalog_card.dart' show GripHandle;
import '../widgets/form_parts.dart';
import '../widgets/pick_parts.dart';
import '../widgets/rule_form.dart';
import '../widgets/rules_extras.dart';
import '../widgets/rules_parts.dart';
import '../widgets/settings_parts.dart' show AmLink;

/// Pushes the Rules screen over the shell (mockup `openRules`); [at] is a row to scroll to and
/// flash (`svc:telegram`, `quick:ads`, `quick:region`, `lan`): the journal's "why" link.
Future<void> showRulesPage(BuildContext context, {String? at}) {
  // a sheet like the mockup's: a swipe down on the header / Back closes it
  return showAppSheet<void>(context, builder: (_) => RulesPage(focus: at));
}

/// The Rules screen (mockup markup/55-sheets-rules.html, js/40-rules.js `renderRules`): Apps ->
/// My rules (drag to reorder) -> Quick rules -> Services -> Everything else -> Target unavailable
/// -> Final order / Rule sets / Import / export. The search narrows the rules and services.
///
/// All the logic is the core's (`Catalog` through the [CoreHost]); this is the view.
class RulesPage extends StatefulWidget {
  const RulesPage({super.key, this.focus});

  /// A row to scroll to and flash once the page is up.
  final String? focus;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  final _search = TextEditingController();
  String _q = '';
  bool _svcOpen = false;
  bool _svcAddOpen = false;
  String? _flash;
  Timer? _flashTimer;
  final _keys = <String, GlobalKey>{};
  late final CoreHost _host; // kept: dispose cannot look it up

  GlobalKey _key(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _host = CoreHostScope.read(context)..holdPlan(); // one plan for the whole editing, sent when the sheet is closed
    final at = widget.focus;
    if (at != null) {
      if (at.startsWith('svc:')) _svcOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ctx = _key(at).currentContext;
        if (ctx == null || !mounted) return;
        await Scrollable.ensureVisible(
          ctx,
          alignment: .5,
          duration: const Duration(milliseconds: 250),
        );
        if (!mounted) return;
        setState(() => _flash = at);
        _flashTimer = Timer(const Duration(milliseconds: 2600), () {
          if (mounted) setState(() => _flash = null);
        });
      });
    }
  }

  @override
  void dispose() {
    _host.releasePlan();
    _flashTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  bool _hit(String s) => _q.isEmpty || s.toLowerCase().contains(_q);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final host = CoreHostScope.of(context);
    final cat = host.catalog;
    final q = cat.quickCfg;
    void save() => host.changed();

    // ── My rules ──
    final shown = [
      for (final id in cat.ruleOrder)
        if (cat.rulesData[id] case final r?
            when _hit(
              '${r.name} ${ruleSummaryText(l10n, r)} ${ruleTargetText(l10n, cat, r)}',
            ))
          id,
    ];
    Widget ruleRow(String id, int i) {
      final r = cat.rulesData[id]!;
      final lostTag = r.action == 'proxy'
          ? targetLostTag(l10n, cat, r.target, cat.planRuleFallback(r))
          : null;
      final rank = cat.ruleOrder.indexOf(id) + 1;
      return Container(
        key: ValueKey(id),
        decoration: BoxDecoration(
          border: i > 0 ? Border(top: BorderSide(color: c.border)) : null,
        ),
        child: Opacity(
          opacity: r.enabled ? 1 : .5,
          child: InkWell(
            onTap: () => showRuleForm(context, id: id),
            splashFactory: NoSplash.splashFactory,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  if (_q.isEmpty)
                    ReorderableDragStartListener(
                      index: i,
                      child: const GripHandle(),
                    )
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 4),
                  RankText(rank),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              ruleTitleText(l10n, r),
                              style: TextStyle(fontSize: 15, color: c.t1),
                            ),
                            if (r.composite != null)
                              const ConnTag('JSON', tone: TagTone.muted),
                            if (lostTag != null)
                              ConnTag(lostTag, tone: TagTone.error),
                          ],
                        ),
                        if (r.name.isNotEmpty)
                          HintText(ruleSummaryText(l10n, r)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ActionBadge(
                    act: r.action,
                    text: ruleTargetText(l10n, cat, r),
                  ),
                  const SizedBox(width: 6),
                  MiniToggle(
                    on: r.enabled,
                    onChanged: (v) {
                      r.enabled = v;
                      save();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final Widget rulesList = shown.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(18),
            child: Center(
              child: Text(
                _q.isEmpty ? l10n.noRulesYet : l10n.noRulesMatch,
                style: TextStyle(fontSize: 13, color: c.t3),
              ),
            ),
          )
        : _q.isNotEmpty
        ? Column(
            children: [for (final (i, id) in shown.indexed) ruleRow(id, i)],
          )
        : ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: shown.length,
            proxyDecorator: (child, index, animation) =>
                Material(type: MaterialType.transparency, child: child),
            onReorderItem: (from, to) {
              cat.ruleOrder.insert(to, cat.ruleOrder.removeAt(from));
              save();
            },
            itemBuilder: (_, i) => ruleRow(shown[i], i),
          );

    // ── Services ──
    final svcKeys = services.keys.toList();
    String svcName(String k) => serviceTitles[k] ?? k;
    final added = [
      for (final k in svcKeys)
        if ((q.services[k] ?? 'default') != 'default') k,
    ];
    final shownSvc = [
      for (final k in added)
        if (_hit(svcName(k))) k,
    ];
    final svcOpenNow = _svcOpen || _q.isNotEmpty;
    Widget svcRow(String k) {
      final pkg = cat.appOfService(k);
      return Container(
        key: _key('svc:$k'),
        color: _flash == 'svc:$k' ? c.accent.tint(.15) : null,
        child: SetRow(
          labelWidget: Text(
            svcName(k),
            style: TextStyle(fontSize: 15, color: c.t1),
          ),
          hintWidget: pkg == null
              ? null
              : GestureDetector(
                  onTap: () => showAppAct(context, pkg),
                  child: HintText(
                    l10n.appItsOwnRouteWinsIn(
                      appActText(l10n, cat, cat.appRules[pkg]!),
                    ),
                  ),
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Seg3(
                options: const [('vpn', 'VPN'), ('direct', 'Direct')],
                value: q.services[k] ?? '',
                onChanged: (v) {
                  cat.setService(k, v);
                  save();
                },
              ),
              const SizedBox(width: 4),
              IconBtn(
                tooltip: l10n.remove,
                onTap: () {
                  cat.setService(k, 'default');
                  save();
                },
                icon: Icon(Icons.close, size: 16, color: c.t3),
              ),
            ],
          ),
        ),
      );
    }

    final rest = [
      for (final k in svcKeys)
        if ((q.services[k] ?? 'default') == 'default' && _hit(svcName(k))) k,
    ];
    final Widget svcAdd = _q.isNotEmpty
        ? const SizedBox.shrink()
        : _svcAddOpen
        ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: rest.isEmpty
                ? HintText(l10n.allServicesAdded)
                : ChipRow(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final k in rest)
                        AppChip(
                          label: svcName(k),
                          active: false,
                          onTap: () {
                            cat.setService(k, 'vpn');
                            setState(() => _svcAddOpen = false);
                            save();
                          },
                        ),
                    ],
                  ),
          )
        : DashedAddButton(
            l10n.addService,
            onTap: () => setState(() => _svcAddOpen = true),
          );

    Widget quickRow(
      String id,
      String label,
      String hint,
      Widget trailing, {
      bool flash = true,
    }) => Container(
      key: _key(id),
      color: flash && _flash == id ? c.accent.tint(.15) : null,
      child: SetRow(label: label, hint: hint, trailing: trailing),
    );

    final appsSet = cat.appRules.length;
    return SheetFrame(
      title: l10n.rules,
      full: true,
      titleBadge: RoundHelp(
        onTap: () => showTermsSheet(context, l10n.rules, [
          (l10n.order, l10n.checkedTopToBottomAppsYour),
          (l10n.myRules, l10n.dragToReorderTapOneTo),
          (l10n.quickRules, l10n.readyMadeLocalNetworkAdsYour),
          (l10n.test, l10n.typeASiteAnIpOr),
          (l10n.finalOrder, l10n.theWholeListAsTheEngine),
        ]),
      ),
      subHeader: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
        child: Row(
          children: [
            Expanded(
              child: SearchBox(
                controller: _search,
                hint: l10n.searchRulesAndServices,
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.whichRuleCatchesAnAddress,
              child: OutlinedButton(
                onPressed: () => showRuleTest(context),
                child: Text(l10n.test),
              ),
            ),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RulesLabel(l10n.apps),
          SetGroup(
            children: [
              ChevronRow(
                label: l10n.perAppRouting,
                hint: appsSet > 0
                    ? l10n.appsWithTheirOwnRoute2(appsSet)
                    : l10n.noAppsSet,
                onTap: () => showApps(context),
              ),
            ],
          ),
          RulesLabel(
            l10n.myRules,
            note: l10n.firstMatchWins,
            action: AmLink(l10n.add, onTap: () => showRuleForm(context)),
          ),
          SetGroup(children: [rulesList]),
          RulesLabel(l10n.quickRules),
          SetGroup(
            children: [
              if (_hit('local networks'))
                quickRow(
                  'lan',
                  l10n.localNetworksDirect,
                  l10n.alwaysInGlobalToo192168,
                  Text(
                    l10n.always,
                    style: TextStyle(fontSize: 12, color: c.t3),
                  ),
                ),
              if (_hit('ads block'))
                quickRow(
                  'quick:ads',
                  l10n.blockAds,
                  l10n.knownAdAndTrackerDomains,
                  MiniToggle(
                    on: q.ads,
                    onChanged: (v) {
                      q.ads = v;
                      save();
                    },
                  ),
                ),
              if (_hit('region direct'))
                quickRow(
                  'quick:region',
                  l10n.myRegionDirect,
                  l10n.itsSitesAndIpsSkipThe,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (q.regionOn)
                        DropdownButton<String>(
                          value: regions.containsKey(q.region)
                              ? q.region
                              : null,
                          isDense: true,
                          underline: const SizedBox.shrink(),
                          dropdownColor: c.card,
                          style: TextStyle(fontSize: 13, color: c.t1),
                          items: [
                            for (final code in regions.keys)
                              DropdownMenuItem(
                                value: code,
                                child: Text(regionLabel(l10n, code)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            q.region = v;
                            save();
                          },
                        ),
                      MiniToggle(
                        on: q.regionOn,
                        onChanged: (v) {
                          q.regionOn = v;
                          save();
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (!(_q.isNotEmpty && shownSvc.isEmpty)) ...[
            RulesLabel(l10n.services),
            SetGroup(
              children: [
                SetRow(
                  label: added.isNotEmpty
                      ? l10n.added2(added.length)
                      : l10n.noneAdded,
                  hint: added.isEmpty
                      ? l10n.routeAKnownAppOrSite
                      : added.map(svcName).join(', '),
                  onTap: () => setState(() {
                    _svcOpen = !_svcOpen;
                    _svcAddOpen = false;
                  }),
                  trailing: AnimatedRotation(
                    turns: svcOpenNow ? .5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: c.t3,
                    ),
                  ),
                ),
                if (svcOpenNow) ...[
                  for (final k in shownSvc) svcRow(k),
                  svcAdd,
                ],
              ],
            ),
          ],
          RulesLabel(l10n.everythingElse),
          SetGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Seg3(
                  wide: true,
                  options: const [
                    ('proxy', 'Proxy'),
                    ('direct', 'Direct'),
                    ('block', 'Block'),
                  ],
                  value: q.finalAction,
                  onChanged: (v) {
                    q.finalAction = v;
                    save();
                  },
                ),
              ),
            ],
          ),
          RulesLabel(l10n.targetUnavailable, note: l10n.rulesOnDefaultAndApps),
          SetGroup(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Seg3(
                  wide: true,
                  options: [
                    ('main', l10n.mainFlow2),
                    ('block', 'Block'),
                    ('direct', 'Direct'),
                  ],
                  value: q.fallback,
                  onChanged: (v) {
                    q.fallback = v;
                    save();
                  },
                ),
              ),
              SetRow(hint: l10n.whenARuleSProfileChain),
            ],
          ),
          SetGroup(
            children: [
              ChevronRow(
                label: l10n.finalOrder,
                hint: l10n.theListExactlyAsTheEngine,
                onTap: () => showFinalOrder(context),
              ),
              ChevronRow(
                label: l10n.ruleSets,
                hint: l10n.listsGeositeGeoipYourOwn(cat.ruleSets.length),
                onTap: () => showRuleSets(context),
              ),
              ChevronRow(
                label: l10n.importExport,
                hint: l10n.singBoxJsonClashRules,
                onTap: () => showRuleIO(context),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
