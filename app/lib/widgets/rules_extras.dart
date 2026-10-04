import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart';

import '../core/core_host.dart';
import '../core/rules_text.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'app_view.dart';
import 'form_parts.dart';
import 'nodes_text.dart';
import 'pick_parts.dart';
import 'rules_parts.dart';
import 'settings_parts.dart';

/// The smaller sheets of Rules (mockup 40-rules.js): the address test, Final order, Import / export
/// and Rule sets with their form.

/// Rule set refresh: 10 minutes to 30 days (mockup `rsEvery`).
const _ruleSetEvery = IntervalLimits(
  units: [('minutes', 60), ('hours', 3600), ('days', 86400)],
  min: 600,
  max: 30 * 86400,
);

String _actName(String act) => switch (act) {
  'direct' => 'Direct',
  'block' => 'Block',
  _ => 'Proxy',
};

// ───────────────────────────── Test an address ─────────────────────────────

/// "Where does it go?": which rule catches a site, an IP or an app, and where it goes.
Future<void> showRuleTest(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _RuleTest());

class _RuleTest extends StatefulWidget {
  const _RuleTest();

  @override
  State<_RuleTest> createState() => _RuleTestState();
}

class _RuleTestState extends State<_RuleTest> {
  final _ctl = TextEditingController();
  (String, String)? _result;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final host = CoreHostScope.read(context);
    final l10n = context.l10n;
    final cat = host.catalog;
    final installed = await host.installedApps();
    if (!mounted) return;
    final apps = [
      for (final a in installed) (pkg: a.pkg, name: a.name),
      for (final pkg in cat.appRules.keys)
        if (!installed.any((a) => a.pkg == pkg))
          (pkg: pkg, name: cat.appLabel(pkg)),
    ];
    final t = testAddress(cat, _ctl.text, apps: apps);
    setState(() {
      _result = t == null ? null : _describe(l10n, cat, t);
    });
  }

  (String, String) _describe(AppLocalizations l10n, Catalog cat, RuleTest t) {
    String to(String act, String target) => act == 'proxy' && target.isNotEmpty
        ? targetText(l10n, cat, target)
        : _actName(act);
    return switch (t.kind) {
      'app' =>
        t.app != null
            ? ('${l10n.apps2} ${t.appName}', appActText(l10n, cat, t.app!))
            : ('${l10n.noAppRuleFor} ${t.appName}', l10n.goesByTheRulesBelow),
      'local' => (l10n.localNetworksAlways, 'Direct'),
      'rule' => (
        '#${t.index} ${ruleTitleText(l10n, t.rule!)}',
        to(t.act, t.target),
      ),
      'ads' => (l10n.blockAds, 'Block'),
      'service' => (
        '${l10n.service} ${serviceTitles[t.key] ?? t.key}',
        _actName(t.act),
      ),
      'region' => ('${l10n.myRegionDirect} (${t.key})', 'Direct'),
      _ => (l10n.everythingElse, _actName(t.act)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final r = _result;
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
                l10n.whereDoesItGo,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.t1,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      controller: _ctl,
                      mono: true,
                      autofocus: true,
                      hint: l10n.youtubeCom1234,
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _run, child: Text(l10n.test)),
                ],
              ),
              const SizedBox(height: 8),
              HintText(l10n.aDomainAnIpWithPort),
              if (r != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    r.$1,
                    style: TextStyle(fontSize: 14, color: c.t1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '→ ${r.$2}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.accent,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Final order ─────────────────────────────

/// The list exactly as the engine checks it (read-only).
Future<void> showFinalOrder(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _FinalOrder());

class _FinalOrder extends StatelessWidget {
  const _FinalOrder();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final cat = CoreHostScope.of(context).catalog;
    final rows = <(String, String, String)>[];
    for (final r in effectiveRules(cat)) {
      rows.add(switch (r.kind) {
        'lan' => (l10n.localNetworks, l10n.alwaysFirstInGlobalToo, 'Direct'),
        'apps' => (l10n.apps, l10n.appsWithTheirOwnRoute2(r.count), l10n.mixed),
        'rule' => (
          ruleTitleText(l10n, r.rule!),
          r.rule!.name.isNotEmpty ? ruleSummaryText(l10n, r.rule!) : '',
          actText(l10n, cat, r.act, r.target),
        ),
        'ads' => (l10n.ads, l10n.quickRule, 'Block'),
        'service' => (
          serviceTitles[r.key] ?? r.key,
          l10n.service2,
          _actName(r.act),
        ),
        'region' => (l10n.region2(r.key), l10n.geositeGeoip, 'Direct'),
        _ => (l10n.everythingElse, '', _actName(r.act)),
      });
    }
    return SheetFrame(
      title: l10n.finalOrder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
            child: HintText(l10n.checkedTopToBottomTheFirst),
          ),
          SetGroup(
            children: [
              for (final (i, (title, sub, act)) in rows.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      RankText(i + 1),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(fontSize: 15, color: c.t1),
                            ),
                            if (sub.isNotEmpty) HintText(sub),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        act,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.t2,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Import / export ─────────────────────────────

/// Rules as sing-box JSON or Clash rules, out (copy) and in (paste).
Future<void> showRuleIO(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _RuleIO());

class _RuleIO extends StatefulWidget {
  const _RuleIO();

  @override
  State<_RuleIO> createState() => _RuleIOState();
}

class _RuleIOState extends State<_RuleIO> {
  final _ctl = TextEditingController();
  bool _import = false;
  bool _json = true;
  String? _err;
  bool _copied = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String _export(Catalog cat) =>
      _json ? exportRulesJson(cat) : exportClashRules(cat);

  Future<void> _action() async {
    final host = CoreHostScope.read(context);
    final cat = host.catalog;
    final l10n = context.l10n;
    if (!_import) {
      await Clipboard.setData(ClipboardData(text: _export(cat)));
      if (!mounted) return;
      setState(() => _copied = true);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _copied = false);
      });
      return;
    }
    List<UserRule> rules;
    String? fin;
    try {
      if (_json) {
        rules = parseJsonRules(cat, _ctl.text);
      } else {
        final p = parseClashRules(cat, _ctl.text);
        rules = p.rules;
        fin = p.finalAction;
      }
    } catch (e) {
      setState(() => _err = ioErrorText(l10n, e));
      return;
    }
    if (rules.isEmpty && fin == null) {
      setState(() => _err = l10n.nothingToImport);
      return;
    }
    cat.addRules(rules);
    if (fin != null) cat.quickCfg.finalAction = fin;
    host.changed();
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(l10n.importedRulesPlural(rules.length))),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cat = CoreHostScope.of(context).catalog;
    final text = _import ? null : _export(cat);
    final hint = _json
        ? '[{ "domain_suffix": ["example.com"], "outbound": "direct" }]'
        : 'DOMAIN-SUFFIX,example.com,DIRECT';
    return SheetFrame(
      title: l10n.importExport,
      full: true,
      subHeader: SheetTabs(
        tabs: [('export', l10n.exportText), ('import', l10n.importText)],
        value: _import ? 'import' : 'export',
        onChanged: (t) => setState(() {
          final imp = t == 'import';
          if (imp != _import) _ctl.clear();
          _import = imp;
          _err = null;
        }),
      ),
      footer: [
        PrimaryButton(
          label: _import
              ? l10n.importText
              : _copied
              ? l10n.copied
              : l10n.copy,
          onPressed: _action,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            child: ChipRow(
              padding: EdgeInsets.zero,
              children: [
                AppChip(
                  label: l10n.singBoxJson,
                  active: _json,
                  onTap: () => setState(() {
                    _json = true;
                    _err = null;
                  }),
                ),
                AppChip(
                  label: l10n.clashRules,
                  active: !_json,
                  onTap: () => setState(() {
                    _json = false;
                    _err = null;
                  }),
                ),
              ],
            ),
          ),
          FormGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_import)
                  AppTextField(
                    controller: _ctl,
                    lines: 12,
                    mono: true,
                    hint: hint,
                    onChanged: (_) => setState(() => _err = null),
                  )
                else
                  _ReadOnlyBox(text: text!),
                if (_err != null) HintText(_err!, warn: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The exported text: selectable, not editable.
class _ReadOnlyBox extends StatelessWidget {
  const _ReadOnlyBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: c.t1.tint(.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: SelectableText(
        text,
        style: monoText.copyWith(fontSize: 12, height: 1.45, color: c.t1),
      ),
    );
  }
}

// ───────────────────────────── Rule sets ─────────────────────────────

/// Rules -> Rule sets: the built-in geo lists and the remote ones the rules can name.
Future<void> showRuleSets(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _RuleSets());

class _RuleSets extends StatefulWidget {
  const _RuleSets();

  @override
  State<_RuleSets> createState() => _RuleSetsState();
}

class _RuleSetsState extends State<_RuleSets> {
  Future<Map<String, int>>? _times;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _times ??= CoreHostScope.read(context).ruleSetTimes();
  }

  Future<void> _open(String? id) async {
    await showRuleSetForm(context, id: id);
    if (!mounted) return;
    setState(() => _times = CoreHostScope.read(context).ruleSetTimes());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final cat = CoreHostScope.of(context).catalog;
    return SheetFrame(
      title: l10n.ruleSets,
      child: FutureBuilder<Map<String, int>>(
        future: _times,
        builder: (context, snap) {
          final times = snap.data ?? const <String, int>{};
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SetGroup(
                children: [
                  for (final s in cat.ruleSets)
                    SetRow(
                      onTap: () => _open(s.id),
                      labelWidget: Row(
                        children: [
                          Flexible(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: monoText.copyWith(
                                fontSize: 15,
                                color: c.t1,
                              ),
                            ),
                          ),
                          if (s.builtin) ...[
                            const SizedBox(width: 8),
                            ConnTag(l10n.builtIn, tone: TagTone.muted),
                          ],
                        ],
                      ),
                      hint: [
                        if (!s.builtin) (s.format ?? 'srs').toUpperCase(),
                        l10n.every(fmtEvery(l10n, s.every ?? 0)),
                        l10n.via2(s.via == 'direct' ? 'direct' : 'VPN'),
                        times[s.name] != null
                            ? shortAgo(l10n, times[s.name]!)
                            : l10n.never.toLowerCase(),
                      ].join(' · '),
                      trailing: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: c.t3,
                      ),
                    ),
                ],
              ),
              InkWell(
                onTap: () => _open(null),
                splashFactory: NoSplash.splashFactory,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 18, color: c.accent),
                      const SizedBox(width: 10),
                      Text(
                        l10n.addRuleSet,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One rule set: add ([id] null) or edit; a built-in one only changes its period and route.
Future<void> showRuleSetForm(BuildContext context, {String? id}) {
  final host = CoreHostScope.read(context);
  final cur = id == null
      ? null
      : host.catalog.ruleSets.where((s) => s.id == id).firstOrNull;
  final draft = cur == null
      ? RuleSetCfg(id: '', format: 'srs', via: 'vpn', every: 86400, url: '')
      : RuleSetCfg.fromJson(cur.toJson());
  return showAppSheet<void>(
    context,
    builder: (_) => _RuleSetForm(host: host, editing: cur?.id, draft: draft),
  );
}

class _RuleSetForm extends StatefulWidget {
  const _RuleSetForm({
    required this.host,
    required this.editing,
    required this.draft,
  });

  final CoreHost host;
  final String? editing;
  final RuleSetCfg draft;

  @override
  State<_RuleSetForm> createState() => _RuleSetFormState();
}

class _RuleSetFormState extends State<_RuleSetForm> {
  late final RuleSetCfg _d = widget.draft;
  late final _name = TextEditingController(text: _d.name);
  late final _url = TextEditingController(text: _d.builtin ? '' : _d.url ?? '');
  String? _err;

  Catalog get _cat => widget.host.catalog;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = context.l10n;
    if (!_d.builtin) {
      _d.name = _name.text.trim();
      _d.url = _url.text.trim();
    }
    final problem = _cat.ruleSetProblem(_d, editing: widget.editing);
    if (problem != null) {
      setState(
        () => _err = switch (problem) {
          'name' => l10n.nameLettersDigitsAnd,
          'nameTaken' => l10n.aRuleSetWithThisName,
          _ => l10n.urlHttps,
        },
      );
      return;
    }
    _cat.saveRuleSet(_d, editing: widget.editing);
    widget.host.changed();
    Navigator.of(context).pop();
  }

  void _delete() {
    final l10n = context.l10n;
    final users = _cat.ruleSetUsers(_d.name);
    if (users.isNotEmpty) {
      setState(
        () => _err = l10n.usedInRuleRemoveItThere(
          users.map((n) => '#$n').join(', '),
        ),
      );
      return;
    }
    _cat.deleteRuleSet(widget.editing!);
    widget.host.changed();
    Navigator.of(context).pop();
  }

  Future<void> _pickEvery() async {
    final l10n = context.l10n;
    final s = (_d.every ?? 86400).round();
    final unit = intervalUnitFor(_ruleSetEvery, s);
    final r = await showNumberUnitDialog(
      context,
      title: l10n.updateTheRuleSetEvery,
      hint: l10n.from10MinutesTo30Days,
      initial: fmtNum(s / unit),
      units: _ruleSetEvery.units,
      unit: unit,
      validate: (text, u) => parseInterval(_ruleSetEvery, text, u) != null
          ? null
          : l10n.from10MinutesTo30Days,
    );
    if (r == null) return;
    final secs = parseInterval(_ruleSetEvery, r.text, r.unit);
    if (secs != null) setState(() => _d.every = secs);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final editing = widget.editing;
    Widget chips(String key, List<(String, String)> opts) => ChipRow(
      padding: EdgeInsets.zero,
      children: [
        for (final (v, label) in opts)
          AppChip(
            label: label,
            active: (key == 'format' ? _d.format : _d.via) == v,
            onTap: () => setState(() {
              if (key == 'format') {
                _d.format = v;
              } else {
                _d.via = v;
              }
            }),
          ),
      ],
    );
    return SheetFrame(
      title: editing != null ? l10n.ruleSet : l10n.addRuleSet,
      full: true,
      footer: [
        if (_err != null) WarnNote(_err!),
        PrimaryButton(label: l10n.save, onPressed: _save),
        if (editing != null && !_d.builtin)
          DangerTextButton(label: l10n.deleteRuleSet, onPressed: _delete),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            label: l10n.name,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _locked(
                  _d.builtin,
                  AppTextField(
                    controller: _name,
                    mono: true,
                    hint: 'ru-blocked',
                    onChanged: (_) => setState(() => _err = null),
                  ),
                ),
                const SizedBox(height: 6),
                HintText(l10n.usedInRulesDomainsRuleSet),
              ],
            ),
          ),
          FormGroup(
            label: 'URL',
            child: _locked(
              _d.builtin,
              AppTextField(
                controller: _url,
                mono: true,
                hint: 'https://…/list.srs',
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() => _err = null),
              ),
            ),
          ),
          FormGroup(
            label: l10n.format,
            child: _d.builtin
                ? HintText('SRS (binary)')
                : chips('format', [
                    ('srs', 'SRS (binary)'),
                    ('json', l10n.jsonSource),
                  ]),
          ),
          FormGroup(
            label: l10n.downloadVia,
            child: chips('via', [('vpn', 'VPN'), ('direct', 'Direct')]),
          ),
          SetGroup(
            children: [
              SetRow(
                label: l10n.updateEvery,
                trailing: GestureDetector(
                  onTap: _pickEvery,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmtEvery(l10n, _d.every ?? 86400),
                        style: TextStyle(fontSize: 15, color: c.accent),
                      ),
                      Icon(Icons.chevron_right, size: 16, color: c.t3),
                    ],
                  ),
                ),
                onTap: _pickEvery,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _locked(bool locked, Widget child) =>
      locked ? IgnorePointer(child: Opacity(opacity: .5, child: child)) : child;
}
