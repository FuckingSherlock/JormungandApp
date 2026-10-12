import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show CatalogNode, Source;

import '../core/core_host.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'nodes_help.dart';
import 'nodes_menus.dart';
import 'settings_parts.dart';

/// The subscription / group form and the manual server form (mockup 32-nodes-forms.js). Both are
/// full-height sheets; what is wrong with the input is told inside the sheet (a toast would hide
/// behind it), what happened after it closed is a toast on the page.

// ── Subscription / group ──

/// Add a subscription ([sid] null, [prefillUrl] from the clipboard), edit one, or rename a manual
/// group. [onOpenCard] opens the card of a source that was just added.
Future<void> showSubscriptionForm(
  BuildContext context, {
  String? sid,
  String? prefillUrl,
  ValueChanged<String>? onOpenCard,
}) {
  final host = CoreHostScope.read(context);
  final source = sid == null ? null : host.catalog.sourcesData[sid];
  return showAppSheet<void>(
    context,
    builder: (_) => _SubscriptionForm(
      host: host,
      source: source,
      prefillUrl: prefillUrl,
      onOpenCard: onOpenCard,
      page: context,
    ),
  );
}

class _SubscriptionForm extends StatefulWidget {
  const _SubscriptionForm({
    required this.host,
    required this.source,
    required this.prefillUrl,
    required this.onOpenCard,
    required this.page,
  });

  final CoreHost host;
  final Source? source;
  final String? prefillUrl;
  final ValueChanged<String>? onOpenCard;
  final BuildContext page;

  @override
  State<_SubscriptionForm> createState() => _SubscriptionFormState();
}

class _SubscriptionFormState extends State<_SubscriptionForm> {
  late final TextEditingController _url;
  late final TextEditingController _name;
  /// the own update period: 'auto' or seconds (0 = never)
  late Object _interval;
  late final TextEditingController _filter;
  late final TextEditingController _password;
  late final TextEditingController _website;
  late bool _reload;
  late bool _test;
  late bool _hwid;
  late bool _keepRules;
  late String _ua;
  late String _channel;
  bool _advanced = false;
  String? _error;

  Source? get _edit => widget.source;
  bool get _isGroup => _edit?.kind == 'node';

  /// A manual group or a local file (kind 'file'): only the name is edited.
  bool get _nameOnly => _edit != null && _edit!.kind != 'sub';

  @override
  void initState() {
    super.initState();
    final s = _edit;
    final settings = s == null || _nameOnly
        ? const SubscriptionSettings()
        : SubscriptionSettings.of(s);
    _url = TextEditingController(text: widget.prefillUrl ?? s?.url ?? '');
    _name = TextEditingController(text: s?.name ?? '');
    _interval = settings.updateInterval;
    _filter = TextEditingController(text: settings.filter);
    _password = TextEditingController(text: settings.password);
    _website = TextEditingController(text: settings.website);
    _reload = settings.reloadAfterUpdate;
    _test = settings.testAfterUpdate;
    _hwid = settings.hwid;
    _keepRules = settings.keepRules;
    _ua = settings.userAgent;
    _channel = settings.channel;
  }

  @override
  void dispose() {
    for (final c in [_url, _name, _filter, _password, _website]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What 'auto' means for this source: the provider's period, else the global one (Auto mode).
  String _autoText(AppLocalizations l10n) {
    final global = widget.host.catalog.autoCfg.subsEvery;
    final s = _edit;
    final provider = s?.unknown['providerInterval'];
    final secs = global > 0 && provider is num && provider > 0
        ? math.max(1, provider) * 3600
        : global;
    return secs > 0 ? fmtEvery(l10n, secs) : l10n.off2;
  }

  Future<void> _pickInterval() async {
    final l10n = context.l10n;
    final spec = intervals['srcEvery']!;
    final cur = _interval is num ? _interval as num : 0;
    final unit = intervalUnitFor(spec, cur);
    final hint = l10n.emptyAuto0NeverFrom10;
    final r = await showNumberUnitDialog(
      context,
      title: l10n.updateThisSubscriptionEvery,
      hint: hint,
      initial: _interval is num ? fmtNum(cur / unit) : '',
      units: spec.units,
      unit: unit,
      validate: (text, u) =>
          text.trim().isEmpty || parseInterval(spec, text, u) != null ? null : hint,
    );
    if (r == null || !mounted) return;
    setState(
      () => _interval = r.text.trim().isEmpty
          ? 'auto'
          : parseInterval(spec, r.text, r.unit) ?? _interval,
    );
  }

  void _save() {
    final l10n = context.l10n;
    final host = widget.host;
    final name = _name.text.trim();
    final url = _url.text.trim();
    final filter = _filter.text.trim();
    final s = _edit;
    if (s != null && _nameOnly) {
      if (name.isNotEmpty) host.saveSource(s.id, name: name);
      Navigator.of(context).pop();
      return;
    }
    // the core applies the filter to server names; Dart and the mockup agree on plain regexes
    if (filter.isNotEmpty) {
      try {
        RegExp(filter, unicode: true);
      } catch (_) {
        setState(() => _error = l10n.filterIsNotAValidRegular);
        return;
      }
    }
    final settings = SubscriptionSettings(
      updateInterval: _interval,
      reloadAfterUpdate: _reload,
      testAfterUpdate: _test,
      hwid: _hwid,
      keepRules: _keepRules,
      filter: filter,
      password: _password.text,
      website: _website.text.trim(),
      userAgent: _ua,
      channel: _channel,
    );
    if (url.isEmpty) {
      setState(
        () => _error = s == null
            ? l10n.pasteASubscriptionUrlFirst
            : l10n.theSubscriptionUrlIsEmpty,
      );
      return;
    }
    if (s != null) {
      host.saveSource(s.id, name: name, url: url, settings: settings);
      Navigator.of(context).pop();
      return;
    }
    // the first fetch goes on after the form is closed; the source is in the catalog at once
    final done = host.addSubscription(url, name: name, settings: settings);
    final sid = host.catalog.sourceOrder.isEmpty
        ? null
        : host.catalog.sourceOrder.last;
    if (sid != null) widget.onOpenCard?.call(sid);
    done.ignore();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final s = _edit;
    final title = s == null
        ? l10n.addSubscription
        : s.kind == 'file'
        ? l10n.rename
        : _isGroup
        ? l10n.renameGroup
        : l10n.editSubscription;
    return SheetFrame(
      title: title,
      full: true,
      footer: [
        PrimaryButton(
          label: s == null ? l10n.add2 : l10n.save,
          onPressed: _save,
        ),
        if (s != null)
          DangerTextButton(
            label: l10n.delete,
            onPressed: () {
              Navigator.of(context).pop();
              if (widget.page.mounted) confirmDeleteSource(widget.page, s);
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_nameOnly)
            FormGroup(
              label: l10n.subscriptionUrl,
              child: AppTextField(
                controller: _url,
                lines: 3,
                mono: true,
                hint: 'https://…/api/sub/…',
                keyboardType: TextInputType.text, // not .url: SwiftKey hides its clipboard bar on the URL keyboard
              ),
            ),
          FormGroup(
            label: _isGroup ? l10n.groupName : l10n.name,
            child: AppTextField(
              controller: _name,
              hint: _nameOnly ? null : l10n.takenFromTheSubscriptionIfEmpty,
            ),
          ),
          if (!_nameOnly) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: FormLabel(l10n.updates),
            ),
            SetGroup(
              children: [
                SetRow(
                  label: l10n.updateEvery,
                  hint: l10n.emptyAutoTheProviderSPeriod2,
                  trailing: SetValueButton(
                    text: _interval is num
                        ? ((_interval as num) == 0
                              ? l10n.never2
                              : fmtEvery(l10n, _interval as num))
                        : '${l10n.auto} · ${_autoText(l10n)}',
                    onTap: _pickInterval,
                  ),
                ),
                SetRow(
                  label: l10n.reconnectAfterUpdate,
                  trailing: MiniToggle(
                    on: _reload,
                    onChanged: (v) => setState(() => _reload = v),
                  ),
                ),
                SetRow(
                  label: l10n.testLatencyAfterUpdate,
                  trailing: MiniToggle(
                    on: _test,
                    onChanged: (v) => setState(() => _test = v),
                  ),
                ),
              ],
            ),
            InkWell(
              onTap: () => setState(() => _advanced = !_advanced),
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _advanced ? .25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.chevron_right, size: 16, color: c.t2),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.advanced,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.t2,
                      ),
                    ),
                    const NodesHelpButton(NodesHelp.srcAdvanced),
                  ],
                ),
              ),
            ),
            if (_advanced)
              SetGroup(
                children: [
                  SetRow(
                    label: 'User-Agent',
                    hint: l10n.autoAsksTheServerAsSing,
                    below: ChipRow(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final ua in subscriptionUserAgents)
                          AppChip(
                            label: ua,
                            active: _ua == ua,
                            onTap: () => setState(() => _ua = ua),
                          ),
                      ],
                    ),
                  ),
                  SetRow(
                    label: l10n.downloadVia,
                    below: ChipRow(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final ch in subscriptionChannels)
                          AppChip(
                            label: _channelLabel(l10n, ch),
                            active: _channel == ch,
                            onTap: () => setState(() => _channel = ch),
                          ),
                      ],
                    ),
                  ),
                  SetRow(
                    label: l10n.sendXHwid,
                    trailing: MiniToggle(
                      on: _hwid,
                      onChanged: (v) => setState(() => _hwid = v),
                    ),
                  ),
                  SetRow(
                    label: l10n.keepProviderRules,
                    hint: l10n.useRoutingRulesShippedInThe,
                    trailing: MiniToggle(
                      on: _keepRules,
                      onChanged: (v) => setState(() => _keepRules = v),
                    ),
                  ),
                  SetRow(
                    label: l10n.filter,
                    trailing: InlineField(
                      controller: _filter,
                      width: 150,
                      hint: l10n.regexEGDeNl,
                    ),
                  ),
                  SetRow(
                    label: l10n.decryptPassword,
                    trailing: InlineField(
                      controller: _password,
                      width: 150,
                      hint: l10n.none2,
                      obscure: true,
                    ),
                  ),
                  SetRow(
                    label: l10n.website,
                    trailing: InlineField(
                      controller: _website,
                      width: 150,
                      hint: 'https://',
                      keyboardType: TextInputType.url,
                    ),
                  ),
                ],
              ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
              child: WarnNote(_error!),
            ),
        ],
      ),
    );
  }

  /// Auto / Proxy / Direct stay English in Russian too (the mockup's dictionary has no entry); a stored old
  /// `Direct first` / `Proxy first` shows as Auto.
  String _channelLabel(AppLocalizations l10n, String ch) => normalizeSubscriptionChannel(ch);
}

// ── Manual server ──

/// Add a manual server (a form, or a pasted [link]), or edit [node] of the manual group [sid]
/// (also: "Add server" of a group, [sid] only).
Future<void> showNodeForm(
  BuildContext context, {
  String? sid,
  CatalogNode? node,
  String link = '',
  ValueChanged<String>? onOpenCard,
}) {
  final host = CoreHostScope.read(context);
  return showAppSheet<void>(
    context,
    builder: (_) => _NodeForm(
      host: host,
      sid: sid,
      node: node,
      link: link,
      onOpenCard: onOpenCard,
      page: context,
    ),
  );
}

class _NodeForm extends StatefulWidget {
  const _NodeForm({
    required this.host,
    required this.sid,
    required this.node,
    required this.link,
    required this.onOpenCard,
    required this.page,
  });

  final CoreHost host;
  final String? sid;
  final CatalogNode? node;
  final String link;
  final ValueChanged<String>? onOpenCard;
  final BuildContext page;

  @override
  State<_NodeForm> createState() => _NodeFormState();
}

class _NodeFormState extends State<_NodeForm> {
  late final TextEditingController _link;
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _secret;
  late String _protocol;
  late String _group;
  bool _nameTouched = false;
  int _many = 0;
  bool _busy = false;
  String? _error;

  CatalogNode? get _edit => widget.node;

  @override
  void initState() {
    super.initState();
    final n = _edit;
    _link = TextEditingController(text: widget.link);
    _name = TextEditingController(text: n?.name ?? '');
    _address = TextEditingController(text: n?.address ?? '');
    _port = TextEditingController(text: n?.port == null ? '' : '${n!.port}');
    _secret = TextEditingController(text: n == null ? '' : nodeSecret(n));
    _protocol = n != null && protocolChips.containsKey(n.protocol)
        ? n.protocol
        : 'vless';
    final groups = _groups;
    _group =
        widget.sid ?? (groups.isEmpty ? NodeFormInput.newGroup : groups.first);
    if (widget.link.isNotEmpty) _parseLink();
  }

  @override
  void dispose() {
    for (final c in [_link, _name, _address, _port, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _groups => [
    for (final id in widget.host.catalog.sourceOrder)
      if (widget.host.catalog.sourcesData[id]?.kind == 'node') id,
  ];

  /// A pasted link fills the fields (several: a note instead of the fields).
  void _parseLink() {
    final nodes = widget.host.parseLinks(_link.text);
    setState(() {
      _many = _edit == null ? nodes.length : 0;
      if (nodes.length != 1 && _edit == null) return;
      if (nodes.isEmpty) return;
      final p = nodes.first;
      if (protocolChips.containsKey(p.protocol)) _protocol = p.protocol;
      _address.text = p.address;
      _port.text = p.port == null ? '' : '${p.port}';
      _secret.text = nodeSecret(p);
      if (p.name.isNotEmpty && !_nameTouched) _name.text = p.name;
    });
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final host = widget.host;
    final navigator = Navigator.of(context);
    final page = widget.page;
    final edit = _edit;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await host.saveManualNode(
      NodeFormInput(
        link: _link.text,
        protocol: _protocol,
        address: _address.text,
        port: _port.text,
        secret: _secret.text,
        name: _name.text,
        nameTouched: _nameTouched,
        editSid: widget.sid,
        editNid: edit?.id,
        group: _group,
      ),
    );
    if (!mounted) return;
    if (r.ok) {
      navigator.pop();
      if (!page.mounted) return;
      if (r.outcome == SaveNodeOutcome.added) {
        // the group it landed in (a new one is the last)
        final gid = host.catalog.sourcesData.containsKey(_group)
            ? _group
            : host.catalog.sourceOrder.last;
        widget.onOpenCard?.call(gid);
        if (r.added > 1 || r.duplicates > 0) {
          showToast(
            page,
            r.duplicates > 0
                ? l10n.addedServersAlreadyTherePlural(r.added, r.duplicates)
                : l10n.addedServersPlural(r.added),
          );
        }
      }
      return;
    }
    setState(() {
      _busy = false;
      _error = switch (r.outcome) {
        SaveNodeOutcome.duplicate =>
          r.duplicates > 1
              ? l10n.theseServersAreAlreadyInThe
              : l10n.thisServerIsAlreadyInThe,
        _ =>
          r.error == 'Address is required'
              ? l10n.addressIsRequired
              : r.error ?? '',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final edit = _edit;
    final catalog = widget.host.catalog;
    final secret = secretFields[_protocol]!;
    final many = _many > 1;
    return SheetFrame(
      title: edit != null ? l10n.editServer : l10n.addServer,
      full: true,
      footer: [
        PrimaryButton(
          label: edit != null
              ? l10n.save
              : many
              ? l10n.addServers(_many)
              : l10n.addServer,
          onPressed: _busy ? null : _save,
        ),
        if (edit != null && widget.sid != null)
          DangerTextButton(
            label: l10n.delete,
            onPressed: () {
              Navigator.of(context).pop();
              final s = catalog.sourcesData[widget.sid];
              if (s != null && widget.page.mounted) {
                confirmDeleteNode(widget.page, s, edit);
              }
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormGroup(
            label: l10n.shareLink,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  controller: _link,
                  lines: 2,
                  mono: true,
                  hint: edit != null
                      ? l10n.vlessReplacesThisServerKeepsIts
                      : l10n.vlessFillsTheFieldsBelowOne,
                  onChanged: (_) => _parseLink(),
                ),
                if (many) HintText('$_many ${l10n.serversEachIsAddedWithThe}'),
              ],
            ),
          ),
          if (!many) ...[
            FormGroup(
              label: l10n.name,
              child: AppTextField(
                controller: _name,
                hint: 'My server',
                onChanged: (_) => _nameTouched = true,
              ),
            ),
            FormGroup(
              label: l10n.protocol,
              child: ChipRow(
                padding: EdgeInsets.zero,
                children: [
                  for (final e in protocolChips.entries)
                    AppChip(
                      label: e.value,
                      active: _protocol == e.key,
                      onTap: () => setState(() => _protocol = e.key),
                    ),
                ],
              ),
            ),
            FormGroup(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormLabel(l10n.address),
                        AppTextField(controller: _address, hint: '1.2.3.4'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormLabel(l10n.port),
                        AppTextField(
                          controller: _port,
                          hint: '443',
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            FormGroup(
              label: _secretLabel(l10n, secret.label),
              child: AppTextField(
                controller: _secret,
                hint: secret.hint,
                mono: true,
              ),
            ),
          ],
          if (edit == null)
            FormGroup(
              label: l10n.group,
              child: ChipRow(
                padding: EdgeInsets.zero,
                children: [
                  for (final g in _groups)
                    AppChip(
                      label: catalog.sourcesData[g]?.name ?? g,
                      active: _group == g,
                      onTap: () => setState(() => _group = g),
                    ),
                  AppChip(
                    label: l10n.newGroup,
                    active: _group == NodeFormInput.newGroup,
                    onTap: () =>
                        setState(() => _group = NodeFormInput.newGroup),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 13, color: c.warn),
              ),
            ),
        ],
      ),
    );
  }

  String _secretLabel(AppLocalizations l10n, String label) => switch (label) {
    'Password' => l10n.password,
    'User:password (optional)' => l10n.userPasswordOptional,
    _ => label,
  };
}
