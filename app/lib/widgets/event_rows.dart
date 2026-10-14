import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show EventGroup, EventRecord, eventCats;

import '../core/core_host.dart';
import '../core/event_text.dart';
import '../core/logs_controller.dart';
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'follow_list.dart' show HitFlash;
import 'form_parts.dart';
import 'ignored_sites.dart';
import 'nodes_menus.dart' show copyText;
import 'rules_parts.dart' show AppIcon;

/// Rows of the Events journal (mockup 47-events.js: `evRowHtml`, `evBlockedHtml`, `evWhyHtml`,
/// the filter sheet): one row per event, repeats folded, the title, the reason, the actions and
/// every field of the event when tapped open.

/// The colour of a category (`--ev-c`).
Color eventColor(AppColors c, String cat) => switch (cat) {
  'conn' => c.active,
  'auto' => c.accent,
  'site' => c.purple,
  'sub' => c.activeDim,
  'rules' => c.accentDim,
  'dns' => c.purple,
  'speed' => c.purple,
  'core' => c.t2,
  _ => c.t3,
};

/// The glyph of a category (`EV_ICON`).
IconData eventIcon(String cat) => switch (cat) {
  'conn' => Icons.wifi,
  'auto' => Icons.shuffle,
  'site' => Icons.public,
  'sub' => Icons.cloud_download_outlined,
  'rules' => Icons.call_split,
  'dns' => Icons.dns_outlined,
  'speed' => Icons.speed,
  'core' => Icons.memory,
  _ => Icons.person_outline,
};

/// `.log-tag`: WARN / ERROR / the core's own lines.
class LogTag extends StatelessWidget {
  const LogTag(this.text, {super.key, required this.kind});

  final String text;

  /// `warn` | `error` | `core` | anything else (grey).
  final String kind;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = switch (kind) {
      'warn' => (c.warn, c.warn.tint(.15)),
      'error' => (c.muted, c.muted.tint(.15)),
      'core' => (c.accent, c.accent.tint(.15)),
      _ => (c.t3, c.t1.tint(.06)),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10,
            height: 1.5,
            fontWeight: FontWeight.w700,
            letterSpacing: .4,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// `.ev-act`: a small accent button of a row.
class EventAct extends StatelessWidget {
  const EventAct(this.label, {super.key, required this.onTap});

  final String label;

  /// Null = not available now (shown dimmed).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? .55 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.accent.tint(.13),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.ev-day`: "TODAY", "YESTERDAY" or the date over the first row of a day.
class EventDay extends StatelessWidget {
  const EventDay(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: .6,
        color: context.colors.t3,
      ),
    ),
  );
}

/// What an action of a row does (`evAct`).
enum EventActKind { rule, retry, open, raw }

/// The tap target of "Open" (`evOpenTarget`): a catalog entry id, or `rules` (the rule sets),
/// `rulelist` (the rules), `dns`; null = nothing to open.
String? eventOpenTarget(EventRecord e, CoreHost host) {
  final d = e.data, cat = host.catalog;
  switch (e.cat) {
    case 'sub':
      return cat.sourcesData['${d['source']}'] != null ? '${d['source']}' : null;
    case 'auto' when e.type == 'unstable':
      return cat.connectEntry('${d['id']}') != null ? '${d['id']}' : null;
    case 'site':
      final entry = '${d['entry'] ?? ''}';
      return entry.isNotEmpty && cat.connectEntry(entry) != null ? entry : null;
    case 'rules':
      return e.type == 'fallback' || e.type == 'targetBack' ? 'rulelist' : 'rules';
    case 'dns':
      return 'dns';
  }
  return null;
}

/// One row of the journal.
class EventRow extends StatelessWidget {
  const EventRow({
    super.key,
    required this.group,
    required this.logs,
    required this.words,
    required this.first,
  });

  final EventGroup group;
  final LogsController logs;
  final EventWords words;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final links = AppLinksScope.of(context);
    final g = group, e = g.ev;
    final d = words.describe(e);
    final open = logs.openRows.contains(g.key);
    final rep = g.times;
    final hit = logs.hitEvent != null && g.items.any((x) => x.id == logs.hitEvent!.id)
        ? logs.hitEvent!.token
        : null;
    final tone = eventColor(c, e.cat);
    final lvlColor = g.level == 'warn'
        ? c.warn
        : g.level == 'error'
        ? c.danger
        : null;
    final problem = g.level == 'warn' || g.level == 'error';

    // what a tap on an action does; each one that leaves the journal remembers the row
    void leave() => logs.returnId = e.id;
    final acts = <(String, VoidCallback?)>[];
    final dd = e.data;
    // "does not open": the site can be copied and made a rule whenever the event names one
    final site = e.cat == 'site' ? words.host(dd) : '';
    if (site.isNotEmpty) {
      // the external checker (check-host): a check that is running now (older than 90 s = the core died meanwhile)
      final check = dd['check'];
      final asking =
          check is Map &&
          check['state'] == 'pending' &&
          DateTime.now().millisecondsSinceEpoch - ((check['at'] as num?)?.toInt() ?? 0) < 90000;
      acts.add((asking ? l10n.checking : l10n.checkWithChecker, asking ? null : () => host.checkSite(e.id)));
      acts.add((l10n.copySite, () => copyText(context, site, l10n.site)));
      if (links.newRuleFor != null) {
        final via = dd['via'] == null || '${dd['via']}'.isEmpty ? null : '${dd['via']}';
        acts.add((l10n.createRule, () => links.newRuleFor!(host: site, via: via)));
      }
      acts.add((
        l10n.ignoreSite,
        () => ignoreSiteWithUndo(ScaffoldMessenger.of(context), l10n, logs, site),
      ));
    }
    if (e.cat == 'sub' &&
        e.type == 'failed' &&
        host.catalog.sourcesData['${dd['source']}']?.kind == 'sub') {
      acts.add((l10n.retry, () => host.updateSource('${dd['source']}')));
    }
    final target = e.cat == 'site' ? null : eventOpenTarget(e, host);
    if (target != null) {
      final go = _openAction(links, target, leave);
      if (go != null) acts.add((l10n.open, go));
    }
    if (e.log != null) {
      acts.add((
        l10n.inRawLog,
        () {
          logs.showRawLine(e.log!);
          leave();
        },
      ));
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              words.clock(g.lastAt),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.3,
                color: c.t3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (problem) ...[
              const SizedBox(width: 6),
              LogTag(g.level == 'warn' ? 'WARN' : 'ERROR', kind: g.level),
            ],
            if (rep > 1) ...[
              const SizedBox(width: 6),
              Text(
                '×$rep',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.t2),
              ),
            ],
            // found while the screen was off
            if (e.bg) ...[
              const SizedBox(width: 6),
              Icon(Icons.nightlight_round, key: const ValueKey('evBg'), size: 12, color: c.t3),
              const SizedBox(width: 2),
              Text(
                l10n.background.toLowerCase(),
                style: TextStyle(fontSize: 11.5, color: c.t3),
              ),
            ],
          ],
        ),
        Padding(
          padding: EdgeInsets.only(top: problem ? 1 : 0),
          child: Text(
            d.title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.t1),
          ),
        ),
        if (e.cat == 'site' && (e.type == 'blocked' || e.type == 'unreachable'))
          _Vias(event: e, logs: logs, words: words)
        else if (d.detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              d.detail,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: c.t2),
            ),
          ),
        if (acts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final (label, fn) in acts) EventAct(label, onTap: fn)],
            ),
          ),
        if (open)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: c.t1.tint(.035),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (final (k, v) in words.fields(g))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(k, style: TextStyle(fontSize: 12, color: c.t3)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            v,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.t1),
                          ),
                        ),
                      ],
                    ),
                  ),
                // the type of this event: take it out of the journal, or look at it alone
                // (`user/*` is outside the type filter: «Show my actions» rules it)
                if (e.cat != 'user')
                  Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        EventAct(
                          l10n.hideThisType,
                          key: const ValueKey('evHideType'),
                          onTap: () => logs.toggleType(e.key),
                        ),
                        EventAct(
                          l10n.showOnlyThisType,
                          key: const ValueKey('evOnlyType'),
                          onTap: () => logs.showOnlyType(e.key),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return HitFlash(
      token: hit,
      child: Material(
        color: lvlColor?.tint(g.level == 'error' ? .07 : .05) ?? Colors.transparent,
        child: InkWell(
          onTap: () => logs.toggleRow(g.key),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: lvlColor ?? Colors.transparent, width: 2),
                top: first ? BorderSide.none : BorderSide(color: c.border),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: tone.tint(.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(eventIcon(e.cat), size: 16, color: tone),
                ),
                const SizedBox(width: 10),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The "Open" of a row: where it leads, or null when that screen is not wired.
  VoidCallback? _openAction(AppLinks links, String target, VoidCallback leave) {
    switch (target) {
      case 'rules':
        final f = links.openRuleSets;
        return f == null ? null : () { f(); leave(); };
      case 'rulelist':
        final f = links.openRules;
        return f == null ? null : () { f(); leave(); };
      case 'dns':
        final f = links.openDns;
        return f == null ? null : () { f(); leave(); };
      default:
        final f = links.openNodesEntry;
        return f == null ? null : () { f(target); leave(); };
    }
  }
}

/// `.ev-vias`: "site does not open": the why rows, the entry that fails and the one that works.
class _Vias extends StatelessWidget {
  const _Vias({required this.event, required this.logs, required this.words});

  final EventRecord event;
  final LogsController logs;
  final EventWords words;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final links = AppLinksScope.of(context);
    final e = event, d = e.data;
    final entry = '${d['entry'] ?? d['route'] ?? ''}';
    final tried = d['tried'] is List ? d['tried'] as List : const [];

    Widget via(String mark, String id, Object? server) {
      final has = host.catalog.connectEntry(id) != null && links.openNodesEntry != null;
      return _ViaRow(
        leading: Text(mark, style: const TextStyle(fontSize: 14, height: 1)),
        name: words.entry(id),
        sub: server != null && '$server'.isNotEmpty ? words.server(server) : null,
        trailing: has
            ? EventAct(
                l10n.open,
                onTap: () {
                  links.openNodesEntry!(id);
                  logs.returnId = e.id;
                },
              )
            : null,
      );
    }

    final rows = <Widget>[
      for (final w in words.whyRows(d)) _WhyRow(row: w, event: e, logs: logs),
      if (entry.isNotEmpty) via('⚠️', entry, d['server']),
      if (e.type == 'blocked' && d['via'] != null && '${d['via']}'.isNotEmpty)
        via('✅', '${d['via']}', d['viaServer']),
      if (e.type == 'unreachable')
        for (final x in tried)
          if (x is Map) via('⚠️', '${x['entry']}', x['server']),
    ];
    final note = e.type == 'unreachable' && tried.isEmpty
        ? (d['retries'] == 'off'
              ? l10n.retriesThroughOtherRoutesAreOff
              : l10n.noOtherWorkingRouteToTry)
        : null;
    final verdict = words.checkText(d);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.t1.tint(.035),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
            rows[i],
          ],
          if (note != null) ...[
            if (rows.isNotEmpty) Divider(height: 1, thickness: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(note, style: TextStyle(fontSize: 12, color: c.t3)),
            ),
          ],
          // what the external checker said (check-host): opens elsewhere / down everywhere / asking
          if (verdict != null) ...[
            if (rows.isNotEmpty || note != null) Divider(height: 1, thickness: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                verdict,
                key: const ValueKey('evCheck'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: d['check']['state'] == 'opens' ? c.accent : c.t2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ViaRow extends StatelessWidget {
  const _ViaRow({required this.leading, required this.name, this.sub, this.trailing});

  final Widget leading;
  final String name;
  final String? sub;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 20, child: Center(child: leading)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.t1),
                ),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(sub!, style: TextStyle(fontSize: 11.5, color: c.t3)),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// A "why" row: the rule routing matched, or the app that sent the request; a tap opens it.
class _WhyRow extends StatelessWidget {
  const _WhyRow({required this.row, required this.event, required this.logs});

  final WhyRow row;
  final EventRecord event;
  final LogsController logs;

  VoidCallback? _go(AppLinks links) {
    void leave() => logs.returnId = event.id;
    switch (row.go) {
      case WhyGo.user:
        final f = links.openRuleForm;
        return f == null ? null : () { f(row.id); leave(); };
      case WhyGo.app:
        final f = links.openAppAct;
        return f == null ? null : () { f(row.id); leave(); };
      case WhyGo.rules:
        final f = links.openRules;
        return f == null ? null : () { f(row.at.isEmpty ? null : row.at); leave(); };
      case WhyGo.route:
        final f = links.openRoute;
        return f == null ? null : () { f(); leave(); };
      case WhyGo.none:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final go = _go(AppLinksScope.of(context));
    final sub = [row.to, if (row.mark != null) row.mark!].where((s) => s.isNotEmpty).join(' · ');
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Text(row.key, style: TextStyle(fontSize: 11, color: c.t3)),
          ),
          // an app that sent the request: its icon (cached by the host) before the name
          if (row.icon.isNotEmpty) ...[
            AppIcon(key: ValueKey('whyIcon:${row.icon}'), pkg: row.icon, name: row.name, size: 20),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: row.dim ? FontWeight.w400 : FontWeight.w600,
                    color: row.dim ? c.t3 : c.t1,
                  ),
                ),
                if (sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(sub, style: TextStyle(fontSize: 11.5, color: c.t3)),
                  ),
              ],
            ),
          ),
          if (go != null) Icon(Icons.chevron_right, size: 18, color: c.t3),
        ],
      ),
    );
    return go == null
        ? content
        : InkWell(
            onTap: go,
            splashFactory: NoSplash.splashFactory,
            highlightColor: c.t1.tint(.04),
            child: content,
          );
  }
}

/// The sheet of the filter button: only problems, the categories with their types (and how many
/// events of each the journal holds), and "Show my actions" (kept with the settings). The search is
/// in the header of the page.
Future<void> showEventFilter(BuildContext context, LogsController logs) {
  return showAppSheet<void>(
    context,
    builder: (sheet) => _EventFilterSheet(logs: logs),
  );
}

class _EventFilterSheet extends StatefulWidget {
  const _EventFilterSheet({required this.logs});

  final LogsController logs;

  @override
  State<_EventFilterSheet> createState() => _EventFilterSheetState();
}

class _EventFilterSheetState extends State<_EventFilterSheet> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final logs = widget.logs;
    return SheetFrame(
      title: l10n.filterEvents,
      full: true,
      child: ListenableBuilder(
        listenable: logs,
        builder: (context, _) {
          final c = context.colors;
          final w = EventWords(l10n, logs.host.catalog);
          final f = logs.filter;
          // how many events of each type the journal holds now (before any filter)
          final counts = <String, int>{};
          for (final e in logs.feed.list) {
            counts[e.key] = (counts[e.key] ?? 0) + 1;
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SetGroup(
                children: [
                  SetRow(
                    label: l10n.onlyProblems2,
                    hint: l10n.warningsAndErrors,
                    trailing: MiniToggle(on: f.problems, onChanged: logs.setProblems),
                  ),
                  // only where a screen-off failure exists (Android), or while it is hidden (to bring it back)
                  if (f.hideBg || logs.feed.list.any((e) => e.bg))
                    SetRow(
                      key: const ValueKey('evFilterBg'),
                      label: l10n.background,
                      hint: l10n.foundWhileTheScreenWasOff,
                      trailing: MiniToggle(on: !f.hideBg, onChanged: (v) => logs.setHideBg(!v)),
                    ),
                ],
              ),
              _Caption(l10n.categories),
              SetGroup(
                children: [
                  for (final cat in eventCats)
                    _CatBlock(
                      cat: cat,
                      words: w,
                      logs: logs,
                      counts: counts,
                      // all folded until the user opens one; what they opened stays so (kept)
                      open: logs.catOpen(cat.$1),
                      onFold: () => logs.toggleCatOpen(cat.$1),
                    ),
                ],
              ),
              if (f.count > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: EventAct(l10n.resetTheFilter, onTap: logs.resetFilter),
                  ),
                ),
              _Caption(l10n.keptWithYourSettings),
              Container(
                margin: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: c.t1.tint(.035),
                  border: Border.all(color: c.accent.tint(.5)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    SetRow(
                      label: l10n.showMyActions,
                      hint: l10n.connectDisconnectPinModeAndRoute2,
                      trailing: MiniToggle(on: logs.cfg.showOwn, onChanged: logs.setShowOwn),
                    ),
                    Divider(height: 1, thickness: 1, color: c.border),
                    IgnoredSitesRow(logs: logs),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: .6,
        color: context.colors.t3,
      ),
    ),
  );
}

/// `.evf-check`: none / some / all.
class _Check extends StatelessWidget {
  const _Check(this.state);

  /// `''` | `part` | `on`.
  final String state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final on = state != '';
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? c.accent : null,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: on ? c.accent : c.borderHi, width: 2),
      ),
      child: Text(
        state == 'on' ? '✓' : state == 'part' ? '–' : '',
        style: TextStyle(
          fontSize: 13,
          height: 1,
          fontWeight: FontWeight.w800,
          color: onAccentOf(context),
        ),
      ),
    );
  }
}

class _CatBlock extends StatelessWidget {
  const _CatBlock({
    required this.cat,
    required this.words,
    required this.logs,
    required this.counts,
    required this.open,
    required this.onFold,
  });

  final (String, List<String>) cat;
  final EventWords words;
  final LogsController logs;

  /// Events in the journal by `cat/type`.
  final Map<String, int> counts;
  final bool open;
  final VoidCallback onFold;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = logs.filter;
    final n = f.typesOn(cat);
    final state = n == cat.$2.length ? 'on' : n > 0 ? 'part' : '';
    final tone = eventColor(c, cat.$1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => logs.toggleCat(cat.$1),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
                child: _Check(state),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onFold,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(eventIcon(cat.$1), size: 16, color: tone),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          words.catLabel(cat.$1),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: c.t1),
                        ),
                      ),
                      const Spacer(),
                      Text('$n/${cat.$2.length}', style: TextStyle(fontSize: 12, color: c.t3)),
                      const SizedBox(width: 8),
                      AnimatedRotation(
                        turns: open ? .25 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Text('›', style: TextStyle(fontSize: 20, height: 1, color: c.t3)),
                      ),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (open)
          for (final t in cat.$2)
            InkWell(
              onTap: () => logs.toggleType('${cat.$1}/$t'),
              splashFactory: NoSplash.splashFactory,
              highlightColor: c.t1.tint(.03),
              child: Container(
                decoration: BoxDecoration(
                  color: c.t1.tint(.02),
                  border: Border(top: BorderSide(color: c.border)),
                ),
                padding: const EdgeInsets.fromLTRB(44, 12, 14, 12),
                child: Row(
                  children: [
                    _Check(f.off.contains('${cat.$1}/$t') ? '' : 'on'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        words.typeLabel(cat.$1, t),
                        style: TextStyle(
                          fontSize: 14,
                          color: (counts['${cat.$1}/$t'] ?? 0) > 0 ? c.t1 : c.t3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${counts['${cat.$1}/$t'] ?? 0}',
                      key: ValueKey('evCount:${cat.$1}/$t'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: c.t3,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
