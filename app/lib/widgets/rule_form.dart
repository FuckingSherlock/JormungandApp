import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../platform/platform_caps.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'chip_input.dart';
import 'form_parts.dart';
import 'rules_parts.dart';
import 'settings_parts.dart';
import 'target_picker.dart';

/// The rule form (mockup 75-rule-form.js): Form | JSON tabs over one draft. Form: condition cards
/// (Domains, IP, Ports, Source, Network, Process) with chip inputs, "except", "+ Condition"; Then:
/// Proxy / Direct / Block with Via, Fallback and its own Via, How (block), DNS; JSON: the sing-box
/// route rule. [id] edits a rule; otherwise a new one, which may start from a [host] (a domain or an
/// address seen in the app), an [app] (a package) and a [via]: a catalog entry id, or a rule target taken as it is
/// (`node:<key>`: the node that opened the site when it is a node of the failing entry itself, the event's
/// `viaTarget`); the rule is then named "`host` via `entry or node name`".
Future<void> showRuleForm(
  BuildContext context, {
  String? id,
  String? host,
  String? app,
  String? via,
}) {
  final core = CoreHostScope.read(context);
  final cat = core.catalog;
  UserRule draft;
  if (id != null && cat.rulesData[id] != null) {
    draft = cloneRule(cat.rulesData[id]!);
  } else {
    id = null;
    draft = newRuleDraft();
    if (host != null && host.isNotEmpty) {
      draft.groups = hostGroup(host);
      draft.name = host;
    } else if (app != null && app.isNotEmpty) {
      draft.groups = {
        'process': {
          'not': false,
          'v': {
            'process': [app],
          },
        },
      };
      draft.name = cat.appLabel(app);
    }
    if (via != null && via.startsWith('node:')) {
      // a rule target as it is (a node of the failing entry that opened the site)
      draft.target = via;
      final n = cat.nodeOfKey(via.substring(5));
      if (host != null && n != null) draft.name = '$host via ${n.name}';
    } else if (via != null && via.isNotEmpty) {
      draft.target = entryTarget(cat, via);
      final e = cat.connectEntry(via);
      if (host != null && e != null) draft.name = '$host via ${e.name}';
    }
  }
  return showAppSheet<void>(
    context,
    builder: (_) => _RuleForm(host: core, editing: id, draft: draft),
  );
}

/// A catalog entry's own id (a profile, chain or source id) -> the rule target of it.
String entryTarget(Catalog c, String id) => c.profilesData.containsKey(id)
    ? 'profile:$id'
    : c.chainsData.containsKey(id)
    ? 'chain:$id'
    : c.sourcesData.containsKey(id)
    ? 'src:$id'
    : '';

/// The one condition card a rule gets from a host seen in the app: an IP is an IP / CIDR (/32,
/// /128), a name is the exact Domain, never the whole Suffix.
Map<String, dynamic> hostGroup(String host) {
  final h = host.replaceAll(RegExp(r'^\[|\]$'), '');
  final v6 = h.contains(':');
  if (v6 || RegExp(r'^\d+(\.\d+){3}$').hasMatch(h)) {
    return {
      'ip': {
        'not': false,
        'v': {
          'ip_cidr': [h.contains('/') ? h : '$h${v6 ? '/128' : '/32'}'],
        },
      },
    };
  }
  return {
    'domain': {
      'not': false,
      'v': {
        'domain': [h],
      },
    },
  };
}

class _RuleForm extends StatefulWidget {
  const _RuleForm({
    required this.host,
    required this.editing,
    required this.draft,
  });

  final CoreHost host;
  final String? editing;
  final UserRule draft;

  @override
  State<_RuleForm> createState() => _RuleFormState();
}

class _RuleFormState extends State<_RuleForm> {
  late UserRule _d = widget.draft;
  late final TextEditingController _name = TextEditingController(text: _d.name);
  final _jsonCtl = TextEditingController();
  bool _json = false;
  bool _addOpen = false;
  String? _jsonErr;
  String? _err;

  Catalog get _cat => widget.host.catalog;

  @override
  void initState() {
    super.initState();
    widget.host.holdPlan(); // one plan for the whole editing, sent when the form is closed
  }

  @override
  void dispose() {
    widget.host.releasePlan();
    _name.dispose();
    _jsonCtl.dispose();
    super.dispose();
  }

  // ── tabs ──

  void _setTab(bool json) {
    if (json == _json) return;
    if (json) {
      _jsonCtl.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(ruleJson(_cat, _d));
      setState(() {
        _json = true;
        _jsonErr = null;
        _err = null;
      });
    } else if (_applyJson()) {
      setState(() {
        _json = false;
        _err = null;
      });
    }
  }

  /// The JSON tab -> the draft (keeps name, Fallback, DNS, enabled). false when it is invalid.
  bool _applyJson() {
    if (!_json) return true;
    try {
      final parsed = ruleFromJsonText(_cat, _jsonCtl.text);
      _d = applyJsonToDraft(parsed, _d);
      _jsonErr = null;
      return true;
    } catch (e) {
      setState(() {
        _jsonErr = ioErrorText(context.l10n, e);
        _err = context.l10n.fixTheJsonFirst;
      });
      return false;
    }
  }

  void _checkJson(String text) {
    String? msg;
    try {
      ruleFromJsonText(_cat, text);
    } catch (e) {
      msg = ioErrorText(context.l10n, e);
    }
    setState(() {
      _jsonErr = msg;
      _err = null;
    });
  }

  // ── save / delete ──

  void _save() {
    if (!_applyJson()) return;
    final problem = _cat.saveRule(_d, editing: widget.editing);
    if (problem != null) {
      setState(() {
        _err = problem == RuleProblem.invalidValues
            ? context.l10n.fixTheValuesInRed
            : context.l10n.addAtLeastOneCondition;
      });
      return;
    }
    widget.host.changed();
    Navigator.of(context).pop();
  }

  void _delete() {
    final id = widget.editing;
    if (id == null) return;
    _cat.deleteRule(id);
    widget.host.changed();
    Navigator.of(context).pop();
  }

  void _help() {
    final l10n = context.l10n;
    showTermsSheet(context, l10n.rule, [
      (l10n.conditions, l10n.aRuleMatchesWhenEveryBlock),
      (l10n.values, l10n.typeAndPressEnterOrComma),
      (l10n.except, l10n.turnsABlockAroundEverythingBut),
      (l10n.via, l10n.whereMatchingTrafficGoesTheMain),
      (l10n.strict, l10n.ifThatTargetIsDownThe),
      ('Block', l10n.dropIsSilentRejectAnswersAt),
      ('JSON', l10n.theSameRuleInSingBox),
    ]);
  }

  void _ipHelp() {
    final l10n = context.l10n;
    final on = _d.ipTunOnly;
    final eff = _cat.dnsResolveEff;
    final off = eff == 'off';
    final server = eff == 'auto'
        ? _cat.dnsAutoFor('vpn')
        : _cat.dnsServers[eff] ?? _cat.dnsAutoFor('vpn');
    final resolve = off
        ? l10n.off2
        : l10n.via2(server?.name ?? _cat.dnsActive.firstOrNull?.name ?? '—');
    final state = on ? l10n.ticked2 : l10n.notTicked;
    showTermsSheet(context, l10n.ipConditionsOnlyInTun, [
      (l10n.why, l10n.throughTheProxyPortAnApp),
      (l10n.ticked, l10n.thisRuleNeverMakesTheCore),
      (l10n.notTicked2, l10n.theCoreResolvesNamesForThis),
      (
        l10n.now,
        off && !on
            ? l10n.thisRuleIsResolveForIp2(state, resolve)
            : l10n.thisRuleIsResolveForIp(state, resolve),
      ),
    ]);
  }

  // ── the draft ──

  Map<String, dynamic>? _card(String key) =>
      _d.groups?[key] as Map<String, dynamic>?;

  void _update(VoidCallback f) => setState(() {
    f();
    _err = null;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final editing = widget.editing;
    final index = editing == null ? 0 : _cat.ruleOrder.indexOf(editing) + 1;
    return SheetFrame(
      title: editing != null ? l10n.rule4(index) : l10n.newRule,
      titleBadge: RoundHelp(onTap: _help),
      full: true,
      subHeader: SheetTabs(
        tabs: [('form', l10n.form), ('json', 'JSON')],
        value: _json ? 'json' : 'form',
        onChanged: (t) => _setTab(t == 'json'),
      ),
      footer: [
        if (_err != null) WarnNote(_err!),
        PrimaryButton(label: l10n.save, onPressed: _save),
        if (editing != null)
          DangerTextButton(label: l10n.deleteRule, onPressed: _delete),
      ],
      child: _json ? _jsonBody(context) : _formBody(context),
    );
  }

  Widget _jsonBody(BuildContext context) {
    final l10n = context.l10n;
    return FormGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            controller: _jsonCtl,
            lines: 16,
            mono: true,
            onChanged: _checkJson,
          ),
          if (_jsonErr != null) HintText(_jsonErr!, warn: true),
          HintText(l10n.theSingBoxRouteRuleName),
        ],
      ),
    );
  }

  Widget _formBody(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final d = _d;
    final comp = d.composite;
    final plaque = comp != null
        ? l10n.compositeRuleOfEditItIn(
            '${comp['mode'] ?? ''}',
            ((comp['rules'] as List?) ?? const []).length,
          )
        : (d.extra?.isNotEmpty ?? false)
        ? l10n.extraFieldsEditThemInJson(d.extra!.keys.join(', '))
        : null;
    final proxy = d.action == 'proxy';
    final dnsOpts = <(String, String)>[
      (
        'auto',
        l10n.auto3(
          _cat.dnsAutoFor(d.action == 'direct' ? 'direct' : 'vpn')?.name ?? '—',
        ),
      ),
      for (final id in _cat.dnsOrder)
        if (_cat.dnsServers[id] != null) (id, _cat.dnsServers[id]!.name),
    ];
    final dnsValue = dnsOpts.any((o) => o.$1 == (d.dns ?? 'auto'))
        ? d.dns ?? 'auto'
        : 'auto';
    final caps = widget.host.caps;
    final canIpBlock = ruleHasIpCondition(d) && caps.dnsResolveForIp;
    final openDns = AppLinksScope.of(context).openDns;
    final Widget hint;
    if (!proxy) {
      hint = Text(l10n.fallbackAppliesToProxyOnly);
    } else if (d.fallback == 'default') {
      hint = Text(
        l10n.defaultRulesTargetUnavailable(
          fallbackName(l10n, _cat.quickCfg.fallback),
        ),
      );
    } else {
      hint = Text(
        d.target.isNotEmpty
            ? l10n.ifTheViaTargetIsUnavailable
            : l10n.ifTheMainFlowIsDown,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: l10n.name,
          child: AppTextField(
            controller: _name,
            hint: l10n.optional,
            onChanged: (v) => _d.name = v,
          ),
        ),
        if (plaque != null)
          Container(
            margin: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.warn.tint(.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(plaque, style: TextStyle(fontSize: 13, color: c.warn)),
          ),
        if (comp == null) ...[
          RulesLabel(l10n.ifText, note: l10n.valuesInAFieldAnyGroups),
          for (final g in ruleGroups)
            if (_card(g.key) != null) _groupCard(context, g),
          _addRow(context),
        ],
        if (canIpBlock) _ipBlock(context, openDns),
        RulesLabel(l10n.then),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: Seg3(
            wide: true,
            options: const [
              ('proxy', 'Proxy'),
              ('direct', 'Direct'),
              ('block', 'Block'),
            ],
            value: d.action,
            onChanged: (v) => _update(() => d.action = v),
          ),
        ),
        SetGroup(
          children: [
            TargetRow(
              label: l10n.via,
              target: d.target,
              mode: proxy ? TargetRowMode.normal : TargetRowMode.inert,
              lostFallback: proxy ? _cat.planRuleFallback(d) : null,
              onPick: (t) => _update(() => d.target = t),
            ),
            FallbackRows(
              fallback: d.fallback,
              fallbackTarget: d.fallbackTarget ?? '',
              on: proxy,
              own: d.target,
              onFallback: (v) => _update(() => d.fallback = v),
              onTarget: (t) => _update(() => d.fallbackTarget = t),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: DefaultTextStyle(
              style: TextStyle(fontSize: 12, height: 1.4, color: c.t2),
              child: hint,
            ),
          ),
        ),
        SetGroup(
          children: [
            if (d.action == 'block')
              SetRow(
                label: l10n.how,
                trailing: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    AppChip(
                      label: l10n.dropSilently,
                      active: (d.block ?? 'drop') == 'drop',
                      onTap: () => _update(() => d.block = 'drop'),
                    ),
                    AppChip(
                      label: l10n.reject,
                      active: d.block == 'reject',
                      onTap: () => _update(() => d.block = 'reject'),
                    ),
                  ],
                ),
              ),
            if (d.action != 'block')
              SetRow(
                label: 'DNS',
                trailing: SetSelect<String>(
                  value: dnsValue,
                  maxWidth: 220,
                  options: dnsOpts,
                  onChanged: (v) => _update(() => d.dns = v),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── condition cards ──

  Widget _xButton(VoidCallback onTap, {double size = 17}) => Tooltip(
    message: context.l10n.removeThisField,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          '×',
          style: TextStyle(
            fontSize: size + 3,
            height: 1,
            color: context.colors.t3,
          ),
        ),
      ),
    ),
  );

  Widget _groupCard(BuildContext context, RuleGroupDef g) {
    final c = context.colors;
    final l10n = context.l10n;
    final card = _card(g.key)!;
    final not = card['not'] == true;
    final names = _cat.ruleSetNames;
    final rows = <Widget>[];
    for (final f in g.fields) {
      if (!groupHasField(card, g, f.key)) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      fieldLabel(l10n, f.key),
                      style: TextStyle(fontSize: 12, color: c.t2),
                    ),
                  ),
                  _xButton(
                    () => _update(() => removeRuleField(_d, g.key, f.key)),
                  ),
                ],
              ),
              ChipInput(
                key: ValueKey('${g.key}/${f.key}'),
                values: ruleFieldValues(_d, g.key, f.key),
                placeholder: f.placeholder,
                kind: f.kind,
                ruleSetNames: names,
                autofocus: _focusField == '${g.key}/${f.key}',
                onAdd: (t) => _update(() => addRuleValues(_d, g.key, f.key, t)),
                onRemove: (i) => _update(() {
                  final list = ruleFieldValues(_d, g.key, f.key)..removeAt(i);
                  setRuleFieldValues(_d, g.key, f.key, list);
                }),
                onEdit: (i, t) =>
                    _update(() => replaceRuleValue(_d, g.key, f.key, i, t)),
              ),
            ],
          ),
        ),
      );
    }
    for (final ch in g.choices) {
      if (!groupHasField(card, g, ch.key)) continue;
      final chosen = ruleFieldValues(_d, g.key, ch.key);
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      fieldLabel(l10n, ch.key),
                      style: TextStyle(fontSize: 12, color: c.t2),
                    ),
                  ),
                  _xButton(
                    () => _update(() => removeRuleField(_d, g.key, ch.key)),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final o in ch.options)
                    AppChip(
                      label: o.toUpperCase(),
                      active: chosen.contains(o),
                      onTap: () => _update(() {
                        final list = ruleFieldValues(_d, g.key, ch.key);
                        list.contains(o) ? list.remove(o) : list.add(o);
                        setRuleFieldValues(_d, g.key, ch.key, list);
                      }),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (g.flag != null && groupHasField(card, g, g.flag!)) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  fieldLabel(l10n, g.flag!),
                  style: TextStyle(fontSize: 12, color: c.t2),
                ),
              ),
              MiniToggle(
                on: card['flag'] == true,
                onChanged: (v) => _update(() => card['flag'] = v),
              ),
              _xButton(
                () => _update(() => removeRuleField(_d, g.key, g.flag!)),
              ),
            ],
          ),
        ),
      );
    }
    final title = groupTitle(l10n, g.key);
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 6, 18, 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: c.t1.tint(.035),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: not ? c.warn.tint(.45) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        not ? '${l10n.not} $title' : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: not ? c.warn : c.t1,
                        ),
                      ),
                    ),
                    if (g.desktop) ...[
                      const SizedBox(width: 6),
                      ConnTag(l10n.desktop2, tone: TagTone.muted),
                    ],
                  ],
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _update(() => card['not'] = !not),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: not ? c.warn.tint(.15) : null,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: not ? c.warn : c.borderHi),
                  ),
                  child: Text(
                    l10n.except.toLowerCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: not ? c.warn : c.t2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: l10n.remove,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _update(() => _d.groups?.remove(g.key)),
                  child: Text(
                    '×',
                    style: TextStyle(fontSize: 20, height: 1, color: c.t3),
                  ),
                ),
              ),
            ],
          ),
          ...rows,
        ],
      ),
    );
  }

  String? _focusField;

  /// "+ Condition" offers every field not on the form yet, under its card's title.
  Widget _addRow(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final avail = <(RuleGroupDef, List<String>)>[];
    for (final g in ruleGroups) {
      final fs = [
        for (final f in g.fieldKeys)
          if (!groupHasField(_card(g.key), g, f)) f,
      ];
      if (fs.isNotEmpty) avail.add((g, fs));
    }
    if (avail.isEmpty) return const SizedBox.shrink();
    if (!_addOpen) {
      return DashedAddButton(
        l10n.condition,
        onTap: () => setState(() => _addOpen = true),
      );
    }
    final small = TextStyle(fontSize: 12, color: c.t3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.addACondition.toUpperCase(),
                  style: small.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: .6,
                  ),
                ),
              ),
              AmLink(
                l10n.cancel,
                onTap: () => setState(() => _addOpen = false),
              ),
            ],
          ),
          for (final (g, fs) in avail) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                '${groupTitle(l10n, g.key)}${g.desktop ? ' ${l10n.desktop}' : ''}',
                style: small,
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in fs)
                  AppChip(
                    label: fieldLabel(l10n, f),
                    active: false,
                    small: true,
                    onTap: () => setState(() {
                      addRuleField(_d, g.key, f);
                      _addOpen = false;
                      _err = null;
                      _focusField = '${g.key}/$f';
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "IP conditions only in TUN": for a rule with an IP condition, where the proxy port sees a site
  /// by name; its (?) explains it and shows the state of Settings -> DNS -> Resolve for IP rules.
  Widget _ipBlock(BuildContext context, VoidCallback? openDns) {
    final l10n = context.l10n;
    final c = context.colors;
    return DashedBox(
      margin: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _update(() => _d.ipTunOnly = !_d.ipTunOnly),
            child: Row(
              children: [
                SubCheckbox(
                  state: _d.ipTunOnly ? PickState.all : PickState.none,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    l10n.ipConditionsOnlyInTun,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.t1,
                    ),
                  ),
                ),
                RoundHelp(onTap: _ipHelp, tight: true),
              ],
            ),
          ),
          if (openDns != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: AmLink(l10n.openDnsSettings, onTap: openDns),
            ),
        ],
      ),
    );
  }
}
