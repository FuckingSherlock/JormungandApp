import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show
        ConnFilter,
        ConnGroup,
        ConnGroupBy,
        ConnSection,
        ConnSort,
        ConnView,
        LiveConn;

import '../core/core_host.dart';
import '../core/format.dart';
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_mark.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'nodes_menus.dart' show copyText;
import 'search_field.dart';

/// The Live connections sheet (mockup js/76-conns.js, Home -> Connections card): the open
/// connections of the core, grouped by service / app, with a search, a filter (OR inside a
/// section, AND across sections), a sort, pause, details and close. The list is
/// `host.traffic.conns`; the view logic (sort, group, filter, values) is the core's `ConnView`.
Future<void> showLiveConnections(BuildContext context) {
  return showAppSheet<void>(context, builder: (_) => const LiveConnsSheet());
}

class LiveConnsSheet extends StatefulWidget {
  const LiveConnsSheet({super.key});

  @override
  State<LiveConnsSheet> createState() => _LiveConnsSheetState();
}

class _LiveConnsSheetState extends State<LiveConnsSheet> {
  final _view = ConnView();
  final _search = TextEditingController();
  final _folded = <String>{};

  /// Closed in this sheet: hidden until the core stops listing them.
  final _gone = <String>{};
  bool _paused = false;
  List<LiveConn>? _snap;
  String? _open;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ── names ──

  /// A route tag of the core (`route<i>/<sid>::<nid>`): the server's flag and name, else the tag.
  String _tag(CoreHost host, String t, {bool filter = false}) {
    if (t == 'direct') return filter ? 'Direct' : 'direct';
    final m = RegExp(r'^[^/]+/(.+?)::(.+)$').firstMatch(t);
    final n = m == null ? null : host.catalog.nodeOfKey('${m.group(1)}::${m.group(2)}');
    return n == null ? t : '${n.flag} ${n.name}';
  }

  String _via(CoreHost host, List<String> out, {bool filter = false}) {
    final s = out.reversed.map((t) => _tag(host, t, filter: filter)).join(' → ');
    return s.isEmpty ? '—' : s;
  }

  String _rate(num b) {
    final (v, u) = fmtRate(b);
    return '$v $u';
  }

  String _age(AppLocalizations l10n, DateTime start) {
    final s = math.max(0, DateTime.now().difference(start).inSeconds);
    return s < 60 ? l10n.s2(s) : s < 3600 ? l10n.m(s ~/ 60) : l10n.h2(s ~/ 3600);
  }

  String _ruleName(AppLocalizations l10n, LiveConn c) =>
      c.ruleLabel.isEmpty ? l10n.defaultFinal : c.ruleLabel;

  String _text(AppLocalizations l10n, CoreHost host, LiveConn c) => [
    '${c.net} ${c.host}${c.port.isNotEmpty ? ':${c.port}' : ''}',
    c.pkg.isNotEmpty ? appDisplayName(l10n, host.catalog, c.pkg) : (c.app.isEmpty ? l10n.unknown : c.app),
    _ruleName(l10n, c),
    _via(host, c.out, filter: true),
    '↓${fmtBytes(c.down)} ↑${fmtBytes(c.up)}',
    _age(l10n, c.start),
  ].join(' · ');

  // ── data ──

  List<LiveConn> _live(CoreHost host) => host.isOn ? host.traffic.conns : const [];

  List<LiveConn> _source(CoreHost host) => [
    for (final c in _paused ? _snap ?? const <LiveConn>[] : _live(host))
      if (!_gone.contains(c.id)) c,
  ];

  void _setPaused(CoreHost host, bool on) => setState(() {
    _paused = on;
    _snap = on ? List.of(_live(host)) : null;
  });

  Future<void> _close(CoreHost host, Iterable<LiveConn> list, {String? done}) async {
    final l10n = context.l10n;
    final ids = [for (final c in list) c.id];
    try {
      await Future.wait([for (final id in ids) host.closeConnection(id)]);
      if (!mounted) return;
      setState(() => _gone.addAll(ids));
      if (done != null) showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, l10n.notClosed('$e'));
    }
  }

  String _closedText(AppLocalizations l10n, int n) =>
      n == 1 ? l10n.connectionClosed(n) : l10n.connectionsClosed(n);

  Future<void> _closeShown(CoreHost host, List<LiveConn> shown) async {
    final l10n = context.l10n;
    if (shown.isEmpty) return;
    final all = !_paused && _view.filter.isEmpty && _view.query.trim().isEmpty;
    if (all) {
      try {
        await host.closeConnection();
        if (!mounted) return;
        setState(() => _gone.addAll(shown.map((c) => c.id)));
        showToast(context, l10n.allConnectionsClosed);
      } catch (e) {
        if (mounted) showToast(context, l10n.notClosed('$e'));
      }
    } else {
      await _close(host, shown, done: _closedText(l10n, shown.length));
    }
  }

  // ── build ──

  // the speed and the connections tick on their own notifier (not the host's)
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CoreHostScope.of(context).trafficNotifier,
    builder: (context, _) => _body(context),
  );

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final c = context.colors;
    if (!host.isOn && _paused) {
      _paused = false;
      _snap = null;
    }
    _view.via = (x) => _via(host, x.out, filter: true);
    final src = _source(host);
    final live = _live(host);
    final shown = _view.shown(src);
    final groups = _view.groups(shown);
    final nF = _view.filter.count;
    return SheetFrame(
      title: l10n.liveConnections,
      full: true,
      subHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 60),
                    child: SearchField(
                      controller: _search,
                      hint: l10n.hostAppRuleServer,
                      margin: EdgeInsets.zero,
                      onChanged: (v) => setState(() => _view.query = v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconBtn(
                      tooltip: l10n.filter,
                      active: nF > 0,
                      onTap: () => _openFilter(host, src),
                      icon: const Icon(Icons.filter_alt_outlined, size: 19),
                    ),
                    if (nF > 0)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.accent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$nF',
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.5,
                              fontWeight: FontWeight.w700,
                              color: onAccentOf(context),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
                _SortButton(
                  label: _sortShort(l10n, _view.sort),
                  on: _view.sortChanged,
                  tooltip: l10n.sort,
                  onTap: _openSort,
                ),
                const SizedBox(width: 8),
                IconBtn(
                  tooltip: l10n.more,
                  onTap: () => _openMore(host, shown),
                  icon: const Icon(Icons.more_vert, size: 19),
                ),
              ],
            ),
          ),
          if (_paused)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: c.warn.tint(.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _pausedText(l10n, host),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: c.t1),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _setPaused(host, false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      child: Text(
                        l10n.resume,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: c.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      bodyPadding: EdgeInsets.zero,
      child: _list(context, host, src, live, shown, groups),
    );
  }

  String _pausedText(AppLocalizations l10n, CoreHost host) {
    final known = {for (final c in _snap ?? const <LiveConn>[]) c.id};
    final fresh = _live(host).where((c) => !known.contains(c.id)).length;
    return fresh == 1 ? l10n.pausedNewConnection(fresh) : l10n.pausedNewConnections(fresh);
  }

  Widget _list(
    BuildContext context,
    CoreHost host,
    List<LiveConn> src,
    List<LiveConn> live,
    List<LiveConn> shown,
    List<ConnGroup>? groups,
  ) {
    final l10n = context.l10n;
    final c = context.colors;
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
        child: Text(
          !host.isOn
              ? l10n.notConnected2
              : src.isNotEmpty
              ? l10n.nothingMatches
              : l10n.noOpenConnections,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: c.t3),
        ),
      );
    }
    final searching = _view.query.trim().isNotEmpty;
    final children = <Widget>[];
    if (groups == null) {
      for (final x in shown) {
        children.add(_row(context, host, x, false));
      }
    } else {
      for (final g in groups) {
        final key = '${_view.group.name}|${g.key}';
        final folded = _folded.contains(key) && !searching;
        children.add(
          _GroupHeader(
            group: g,
            folded: folded,
            rate: _rate,
            onToggle: () => setState(() {
              if (!_folded.remove(key)) _folded.add(key);
            }),
            onClose: () => _close(
              host,
              g.rows,
              done: g.rows.length == 1
                  ? l10n.connectionClosed2(g.name, g.rows.length)
                  : l10n.connectionsClosed2(g.name, g.rows.length),
            ),
          ),
        );
        if (!folded) {
          for (final x in g.rows) {
            children.add(_row(context, host, x, true));
          }
        }
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _row(BuildContext context, CoreHost host, LiveConn x, bool grouped) {
    final l10n = context.l10n;
    final c = context.colors;
    final open = _open == x.id;
    final rule = x.ruleLabel;
    final links = AppLinksScope.of(context);
    final meta = TextStyle(fontSize: 13, color: c.t2);
    // leaves the sheet for the screen the tap opens
    void leave(VoidCallback f) {
      Navigator.of(context).pop();
      f();
    }

    return Material(
      color: open ? c.accent.tint(.06) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _open = open ? null : x.id),
        splashFactory: NoSplash.splashFactory,
        highlightColor: c.t1.tint(.03),
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.t1.tint(.03))),
          ),
          padding: EdgeInsets.fromLTRB(grouped ? 30 : 18, 10, 18, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${x.host}${x.port.isNotEmpty ? ':${x.port}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoText.copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: c.t1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ProtoTag(x.net),
                  const SizedBox(width: 6),
                  _CloseX(
                    tooltip: l10n.closeConnection,
                    onTap: () => _close(host, [x]),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: _via(host, x.out)),
                    if (rule.isNotEmpty) ...[
                      const TextSpan(text: ' · '),
                      TextSpan(text: rule, style: TextStyle(color: c.t1)),
                    ],
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoText.merge(meta),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: x.pkg.isEmpty
                    ? Text(
                        '${x.app.isNotEmpty ? '${x.app} · ' : ''}↓ ${_rate(x.downRate)} ↑ ${_rate(x.upRate)}'
                        ' · ${fmtBytes(x.down + x.up)} · ${_age(l10n, x.start)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoText.copyWith(fontSize: 12, color: c.t3),
                      )
                    // Android: the app's icon and name (a tap opens its route), then the numbers
                    : Row(
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: AppMark(
                              key: ValueKey('connApp:${x.id}'),
                              pkg: x.pkg,
                              name: appDisplayName(l10n, host.catalog, x.pkg),
                              size: 16,
                              style: monoText.copyWith(fontSize: 12),
                              onTap: links.openAppAct == null ? null : () => leave(() => links.openAppAct!(x.pkg)),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              ' · ↓ ${_rate(x.downRate)} ↑ ${_rate(x.upRate)}'
                              ' · ${fmtBytes(x.down + x.up)} · ${_age(l10n, x.start)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: monoText.copyWith(fontSize: 12, color: c.t3),
                            ),
                          ),
                        ],
                      ),
              ),
              if (open) _details(context, host, x),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(BuildContext context, CoreHost host, LiveConn x) {
    final l10n = context.l10n;
    final c = context.colors;
    final links = AppLinksScope.of(context);
    final raw = x.raw;
    final name = _ruleName(l10n, x);
    Widget line(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(k, style: TextStyle(fontSize: 12.5, color: c.t3))),
          const SizedBox(width: 10),
          Expanded(child: v),
        ],
      ),
    );
    Widget val(String s) => Text(s, style: monoText.copyWith(fontSize: 12.5, color: c.t1));
    final catalog = host.catalog;
    final ruleTarget = x.ruleKind == 'user' && catalog.rulesData[x.ruleId] != null
        ? 'rule'
        : x.ruleKind == 'app' && (catalog.appInfo?.call(x.ruleId) != null || catalog.appRules.containsKey(x.ruleId))
        ? 'app'
        : '';
    void leave(VoidCallback f) {
      Navigator.of(context).pop();
      f();
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line('Host', val('${x.host}${x.port.isNotEmpty ? ':${x.port}' : ''}')),
          line(l10n.network, val(x.net.toUpperCase())),
          line(
            l10n.rule,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                val(name),
                if (raw.isNotEmpty && raw != name)
                  Text(raw, style: monoText.copyWith(fontSize: 11, color: c.t3)),
              ],
            ),
          ),
          line(l10n.route, val(_via(host, x.out))),
          line(
            l10n.app,
            x.pkg.isNotEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: AppMark(
                      pkg: x.pkg,
                      name: appDisplayName(l10n, catalog, x.pkg),
                      style: monoText.copyWith(fontSize: 12.5),
                      onTap: links.openAppAct == null ? null : () => leave(() => links.openAppAct!(x.pkg)),
                    ),
                  )
                : val(x.process.isNotEmpty ? x.process : l10n.unknown),
          ),
          line(
            l10n.started,
            val(
              '${TimeOfDay.fromDateTime(x.start.toLocal()).format(context)} · ${_age(l10n, x.start)}',
            ),
          ),
          line(l10n.down, val('${fmtBytes(x.down)} · ${_rate(x.downRate)}')),
          line(l10n.up, val('${fmtBytes(x.up)} · ${_rate(x.upRate)}')),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                AppChip(label: l10n.close, active: false, small: true, onTap: () => _close(host, [x])),
                AppChip(
                  label: l10n.copy,
                  active: false,
                  small: true,
                  onTap: () => copyText(context, _text(l10n, host, x), l10n.connection),
                ),
                if (ruleTarget == 'rule' && links.openRuleForm != null)
                  AppChip(
                    label: l10n.openRule,
                    active: false,
                    small: true,
                    onTap: () => leave(() => links.openRuleForm!(x.ruleId)),
                  ),
                if (ruleTarget == 'app' && links.openAppAct != null)
                  AppChip(
                    label: l10n.openRule,
                    active: false,
                    small: true,
                    onTap: () => leave(() => links.openAppAct!(x.ruleId)),
                  ),
                if (links.newRuleFor != null)
                  AppChip(
                    label: x.isIp ? l10n.ruleForThisAddress : l10n.ruleForThisHost,
                    active: false,
                    small: true,
                    onTap: () => leave(() => links.newRuleFor!(host: x.host)),
                  ),
                if (links.newRuleFor != null && x.process.isNotEmpty)
                  AppChip(
                    label: l10n.ruleForThisApp,
                    active: false,
                    small: true,
                    onTap: () => leave(() => links.newRuleFor!(app: x.app)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── menus ──

  String _sortShort(AppLocalizations l10n, ConnSort s) => switch (s) {
    ConnSort.newest => l10n.newest,
    ConnSort.downSpeed => l10n.speed2,
    ConnSort.upSpeed => l10n.speed3,
    ConnSort.downloaded => l10n.total,
    ConnSort.uploaded => l10n.total2,
    ConnSort.duration => l10n.longest,
  };

  String _sortName(AppLocalizations l10n, ConnSort s) => switch (s) {
    ConnSort.newest => l10n.newest,
    ConnSort.downSpeed => l10n.downloadSpeed,
    ConnSort.upSpeed => l10n.uploadSpeed,
    ConnSort.downloaded => l10n.downloaded,
    ConnSort.uploaded => l10n.uploaded,
    ConnSort.duration => l10n.duration,
  };

  void _openSort() {
    final l10n = context.l10n;
    Widget mark(bool on) => on ? const Icon(Icons.check) : const SizedBox(width: 18);
    showAppSheet<void>(
      context,
      builder: (sheet) => SheetFrame(
        title: l10n.sortAndGroup,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in ConnSort.values)
              MenuRow(
                icon: mark(_view.sort == s),
                label: _sortName(l10n, s),
                onTap: () {
                  Navigator.of(sheet).pop();
                  setState(() => _view.sort = s);
                },
              ),
            MenuCaption(l10n.groupBy),
            for (final (g, name) in [
              (ConnGroupBy.service, l10n.service),
              (ConnGroupBy.app, l10n.app),
              (ConnGroupBy.none, l10n.none),
            ])
              MenuRow(
                icon: mark(_view.group == g),
                label: name,
                onTap: () {
                  Navigator.of(sheet).pop();
                  setState(() => _view.group = g);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openMore(CoreHost host, List<LiveConn> shown) {
    final l10n = context.l10n;
    final some = _view.filter.count > 0 || _view.query.trim().isNotEmpty;
    final n = shown.length;
    showAppSheet<void>(
      context,
      builder: (sheet) => SheetFrame(
        title: l10n.connections,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              label: _paused ? l10n.resume : l10n.pause,
              sub: _paused ? null : l10n.freezesTheListTheCardsOn,
              onTap: () {
                Navigator.of(sheet).pop();
                _setPaused(host, !_paused);
              },
            ),
            MenuRow(
              icon: const Icon(Icons.copy),
              label: l10n.copy,
              sub: l10n.theShownListAsText,
              onTap: () {
                Navigator.of(sheet).pop();
                _copyShown(host, shown);
              },
            ),
            MenuRow(
              icon: const Icon(Icons.filter_alt_outlined),
              label: l10n.filterByExit,
              onTap: () {
                Navigator.of(sheet).pop();
                _openFilter(host, _source(host), only: ConnSection.exit);
              },
            ),
            MenuRow(
              icon: const Icon(Icons.close),
              label: some ? l10n.closeShown(n) : l10n.closeAll,
              danger: true,
              disabled: n == 0,
              onTap: n == 0
                  ? null
                  : () {
                      Navigator.of(sheet).pop();
                      _closeShown(host, shown);
                    },
            ),
          ],
        ),
      ),
    );
  }

  void _copyShown(CoreHost host, List<LiveConn> shown) {
    final l10n = context.l10n;
    if (shown.isEmpty) {
      showToast(context, l10n.nothingToCopy);
      return;
    }
    final groups = _view.groups(shown);
    final text = groups == null
        ? shown.map((c) => _text(l10n, host, c)).join('\n')
        : groups
              .map(
                (g) =>
                    '# ${g.name} · ${l10n.connectionsPlural(g.rows.length)}'
                    ' · ↓ ${_rate(g.downRate)} ↑ ${_rate(g.upRate)}\n'
                    '${g.rows.map((c) => _text(l10n, host, c)).join('\n')}',
              )
              .join('\n\n');
    copyText(
      context,
      text,
      l10n.connectionsPlural(shown.length),
    );
  }

  Future<void> _openFilter(CoreHost host, List<LiveConn> src, {ConnSection? only}) async {
    final draft = await showAppSheet<ConnFilter>(
      context,
      builder: (_) => _FilterSheet(
        view: _view,
        host: host,
        src: src,
        only: only,
        tag: (t) => _tag(host, t, filter: true),
        via: (tags) => _via(host, tags, filter: true),
      ),
    );
    if (draft != null && mounted) setState(() => _view.filter = draft);
  }
}

// ── small pieces ──

class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.label,
    required this.on,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final bool on;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = on ? c.accent : c.t2;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 88,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? c.accent : c.border),
          ),
          child: Row(
            children: [
              Icon(Icons.swap_vert, size: 15, color: fg),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProtoTag extends StatelessWidget {
  const _ProtoTag(this.net);

  final String net;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tone = net == 'udp' ? c.purple : c.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: tone.tint(.15), borderRadius: BorderRadius.circular(4)),
      child: Text(
        net.toUpperCase(),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone),
      ),
    );
  }
}

class _CloseX extends StatelessWidget {
  const _CloseX({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 24,
        height: 24,
        child: Center(child: Icon(Icons.close, size: 17, color: context.colors.t3)),
      ),
    ),
  );
}

/// `.live-group`: chevron, a letter badge in the hue of the name, the name and count, the summed
/// speed under it, x closes the group.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.folded,
    required this.rate,
    required this.onToggle,
    required this.onClose,
  });

  final ConnGroup group;
  final bool folded;
  final String Function(num) rate;
  final VoidCallback onToggle;
  final VoidCallback onClose;

  static int _hash(String s) {
    var h = 0;
    for (final r in s.runes) {
      h = (h * 31 + r) & 0x7fffffff;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final hue = (_hash(group.key) % 360).toDouble();
    final name = group.name.isEmpty ? l10n.other : group.name;
    final letter = String.fromCharCode(name.runes.first).toUpperCase();
    return Material(
      color: c.accent.tint(.05),
      child: InkWell(
        onTap: onToggle,
        splashFactory: NoSplash.splashFactory,
        highlightColor: c.accent.tint(.1),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.t1.tint(.03)))),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            children: [
              AnimatedRotation(
                turns: folded ? -.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.keyboard_arrow_down, size: 16, color: c.t3),
              ),
              const SizedBox(width: 8),
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: HSLColor.fromAHSL(.18, hue, .6, .55).toColor(),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: HSLColor.fromAHSL(1, hue, .7, .72).toColor(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.t1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: c.muted.tint(.18),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '${group.rows.length}',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 16 / 11.5,
                              fontWeight: FontWeight.w700,
                              color: c.t2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '↓ ${rate(group.downRate)} ↑ ${rate(group.upRate)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoText.copyWith(fontSize: 12, color: c.t3),
                    ),
                  ],
                ),
              ),
              _CloseX(tooltip: l10n.closeGroup, onTap: onClose),
            ],
          ),
        ),
      ),
    );
  }
}

// ── the filter ──

/// The nested filter sheet: sections Protocol, App, Rule, Exit, Host with the values of the
/// connections now and their counts. Nothing is applied until the check; it pops the new filter.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.view,
    required this.host,
    required this.src,
    required this.only,
    required this.tag,
    required this.via,
  });

  final ConnView view;
  final CoreHost host;
  final List<LiveConn> src;
  final ConnSection? only;
  final String Function(String tag) tag;
  final String Function(List<String> tags) via;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final ConnFilter _draft = widget.view.filter.copy();
  final _q = TextEditingController();
  final _expanded = <ConnSection>{};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String _title(AppLocalizations l10n, ConnSection s) => switch (s) {
    ConnSection.net => l10n.protocol,
    ConnSection.app => l10n.app,
    ConnSection.rule => l10n.rule,
    ConnSection.exit => l10n.exit,
    ConnSection.host => 'Host',
  };

  String _label(AppLocalizations l10n, ConnSection s, String v) => switch (s) {
    ConnSection.net => v.toUpperCase(),
    ConnSection.app => v.isEmpty ? l10n.unknown : v,
    ConnSection.rule => v.isEmpty ? l10n.defaultFinal : v,
    ConnSection.exit => widget.tag(v),
    ConnSection.host => v,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final q = _q.text.trim().toLowerCase();
    final only = widget.only;
    final sections = <Widget>[];
    for (final s in ConnSection.values) {
      if (only != null && s != only) continue;
      final vals = widget.view.values(
        s,
        widget.src,
        _draft.sel[s]!,
        label: (v) => _label(l10n, s, v),
        query: q,
        viaText: widget.via,
      );
      if (vals.isEmpty) continue;
      final cap = only == null && q.isEmpty && !_expanded.contains(s) && vals.length > 8;
      final picked = _draft.sel[s]!.length;
      sections.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _title(l10n, s).toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .6,
                  color: c.t3,
                ),
              ),
              Text(
                picked > 0 ? l10n.selected(picked) : '',
                style: TextStyle(fontSize: 12, color: c.t3),
              ),
            ],
          ),
        ),
      );
      for (final v in cap ? vals.take(8) : vals) {
        final on = _draft.sel[s]!.contains(v.value);
        sections.add(
          InkWell(
            onTap: () => setState(() => _draft.toggle(s, v.value)),
            splashFactory: NoSplash.splashFactory,
            highlightColor: c.t1.tint(.04),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                children: [
                  _Checkbox(on),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: _label(l10n, s, v.value)),
                          if (v.via.isNotEmpty)
                            TextSpan(
                              text: '  ${l10n.via2(v.via.join(', '))}',
                              style: TextStyle(fontSize: 12, color: c.t3),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: v.count == 0 ? c.t3 : c.t1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${v.count}',
                    style: monoText.copyWith(fontSize: 12.5, color: c.t3),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (cap) {
        sections.add(
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded.add(s)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
              child: Text(
                l10n.showAll2(vals.length),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent),
              ),
            ),
          ),
        );
      }
    }
    return SheetFrame(
      title: only != null ? l10n.filterByExit2 : l10n.filter,
      full: true,
      headerActions: [
        IconBtn(
          kind: IconBtnKind.ghost,
          tooltip: l10n.clearAll,
          onTap: () => setState(_draft.clear),
          icon: const Icon(Icons.delete_outline, size: 18),
        ),
        IconBtn(
          kind: IconBtnKind.ghost,
          tooltip: l10n.apply,
          onTap: () => Navigator.of(context).pop(_draft),
          icon: Icon(Icons.check, size: 18, color: c.accent),
        ),
      ],
      subHeader: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: SearchField(
          controller: _q,
          hint: l10n.findAValue,
          margin: const EdgeInsets.only(bottom: 4),
          onChanged: (_) => setState(() {}),
        ),
      ),
      bodyPadding: const EdgeInsets.only(bottom: 18),
      child: sections.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
              child: Text(
                l10n.nothingMatches,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: c.t3),
              ),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections),
    );
  }
}

/// `.sub-checkbox`.
class _Checkbox extends StatelessWidget {
  const _Checkbox(this.on);

  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? c.accent : null,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: on ? c.accent : c.borderHi, width: 1.5),
      ),
      child: on
          ? Text(
              '✓',
              style: TextStyle(
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w700,
                color: onAccentOf(context),
              ),
            )
          : null,
    );
  }
}
