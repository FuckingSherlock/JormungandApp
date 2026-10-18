import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show EventGroup, EventRecord, alwaysShownTypes, eventCats;

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
import 'report_actions.dart' show showSendReport;
import 'rules_parts.dart' show AppIcon;
import 'settings_data.dart' show showDataSheet;
import 'target_picker.dart' show showTargetPicker;

/// The "Return once" / "Don't exclude" buttons of `auto/unstable`: built, hidden until the core has the
/// time-limited exclusion (`features.md`, "Unstable entry"); the feature switches this on.
const bool kAutoExcludeActions = false;

/// The `data.affected` list of an event: `[{kind, id, name, to}]`.
List<Map<String, dynamic>> eventAffected(EventRecord e) {
  final a = e.data['affected'];
  if (a is! List) return const [];
  return [for (final x in a) if (x is Map) x.map((k, v) => MapEntry('$k', v))];
}

/// The affected items "Choose for all" changes: rules, apps and the connection (chains and profiles are not).
bool _retargetable(Map<String, dynamic> a) => const ['rule', 'app', 'connection'].contains('${a['kind']}');

/// What "Switch on" of a `node/lost` (`action: off`) still has to switch on: the source (`enabled` false) and / or the
/// servers of `data.nodeIds` (ids; `data.nodes` are names) that are still off. Empty = nothing to do.
({bool source, List<String> nodes}) _switchedOff(CoreHost host, Map<String, dynamic> d) {
  final s = host.catalog.sourcesData['${d['source']}'];
  if (s == null) return (source: false, nodes: const []);
  final ids = d['nodeIds'] is List ? [for (final x in d['nodeIds'] as List) '$x'] : const <String>[];
  return (source: !s.enabled, nodes: [for (final id in ids) if (s.disabledNodes.contains(id)) id]);
}

void _switchOn(CoreHost host, Map<String, dynamic> d) {
  final off = _switchedOff(host, d), sid = '${d['source']}';
  if (off.source) host.toggleSourceEnabled(sid);
  for (final nid in off.nodes) {
    host.toggleNodeEnabled(sid, nid);
  }
}

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
/// `rulelist` (the rules), `dns`, `route` (the Route sheet), `app:<package>` (the app's route in Per-app);
/// null = nothing to open.
String? eventOpenTarget(EventRecord e, CoreHost host) {
  final d = e.data, cat = host.catalog;
  switch (e.cat) {
    case 'conn':
      switch (e.type) {
        case 'lost' || 'restored':
          return 'route';
        case 'failing':
          final app = d['app'];
          return app is String && app.isNotEmpty ? 'app:$app' : null;
      }
      return null;
    case 'auto' when e.type == 'switched' || e.type == 'fastest':
      // the route's own entry; a switch of the main flow names the entries (`to` is the one in use now)
      final route = '${d['route'] ?? ''}', to = '${d['to'] ?? ''}';
      if (route.isNotEmpty && cat.connectEntry(route) != null) return route;
      if (route.isEmpty && to.isNotEmpty && cat.connectEntry(to) != null) return to;
      return 'route';
    case 'core' when e.type == 'tunNeedsAdmin':
      return 'route';
    case 'sub':
      return cat.sourcesData['${d['source']}'] != null ? '${d['source']}' : null;
    case 'auto' when e.type == 'unstable':
      return cat.connectEntry('${d['id']}') != null ? '${d['id']}' : null;
    case 'node':
      return cat.sourcesData['${d['source']}'] != null ? '${d['source']}' : null;
    case 'site':
      final entry = '${d['entry'] ?? ''}';
      return entry.isNotEmpty && cat.connectEntry(entry) != null ? entry : null;
    case 'rules':
      return const ['fallback', 'targetBack', 'targetLost', 'targetFound'].contains(e.type) ? 'rulelist' : 'rules';
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
    this.onJump,
  });

  final EventGroup group;
  final LogsController logs;
  final EventWords words;
  final bool first;

  /// The pair link: scroll to another event of the journal (the opening row's closing status, the closing
  /// row's "Back to start").
  final void Function(int eventId)? onJump;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final host = CoreHostScope.of(context); // Retry follows the core's state
    final links = AppLinksScope.of(context);
    final g = group, e = g.ev;
    final (title, detail) = words.describeGroup(g);
    final reason = words.reasonLine(g, find: (id) => logs.feed.list.where((x) => x.id == id).firstOrNull);
    final related = words.relatedLine(g);
    final closedLine = words.closedLine(g);
    final resolved = g.closed;
    // the closing row of a pair names the opening one (tap: jump to it)
    final opening = g.opensId == null ? null : logs.feed.list.where((x) => x.id == g.opensId).firstOrNull;
    final backTitle = opening == null ? null : words.describe(opening).title;
    final open = logs.openRows.contains(g.key);
    final trail = open ? words.trailRows(g.worst.trail != null ? g.worst : e) : const <TrailRow>[];
    final repeatsLine = open ? words.repeatsLine(g) : null;
    final repeatTimes = open ? [for (final x in g.repeats) ...x.occurrences] : const <int>[];
    final rep = g.times;
    final hit = logs.hitEvent != null && g.items.any((x) => x.id == logs.hitEvent!.id)
        ? logs.hitEvent!.token
        : null;
    final tone = eventColor(c, e.cat);
    // a pair that has ended is "resolved": the colour of a good state instead of the level's
    final lvlColor = resolved
        ? c.active
        : g.level == 'warn'
        ? c.warn
        : g.level == 'error'
        ? c.danger
        : null;
    final problem = g.level == 'warn' || g.level == 'error';

    // what a tap on an action does; each one that leaves the journal remembers the row
    void leave() => logs.returnId = e.id;
    final dd = e.data;
    // the buttons by the table "По типам" (docs/logs.md); the first three stand in the folded row, the rest in the opened
    final acts = <(String, VoidCallback?)>[];
    void add(String label, VoidCallback? fn) => acts.add((label, fn));
    VoidCallback? link(VoidCallback? f) => f == null ? null : () { f(); leave(); };
    void addOpen() {
      final target = e.cat == 'site' ? null : eventOpenTarget(e, host);
      final go = target == null ? null : _openAction(links, target, leave);
      if (go != null) add(l10n.open, go);
    }

    // "Check now": the core checks again what the event is about; while it does, the button says so
    void addCheckNow() {
      final r = dd['recheck'];
      final pending = r is Map && r['state'] == 'pending';
      add(pending ? l10n.checking : l10n.checkNow, pending ? null : () => host.checkNow(e.id));
    }

    // "Open update": the Data sheet, where the update card is
    void addOpenUpdate() => add(l10n.openUpdate, () => showDataSheet(context));

    // Retry/Connect/... only mean something while the pair is not closed
    final live = !resolved;
    // the crash chain is worded by its last event
    final ce = g.opKind == null && e.cat == 'core' && const ['crashed', 'restartFailed', 'down', 'restarted'].contains(e.type) ? g.last : e;
    bool inUseOf(Map<String, dynamic> d) => d['inUse'] == true || d['inUse'] == 'true';
    final inUse = inUseOf(dd);
    final pinLost = eventPinLost(e);
    final vpnCauses = e.key == 'conn/vpnDown' && dd['causes'] is List ? (dd['causes'] as List).map((c) => '$c').toList() : const <String>[];
    // "Choose for all": one target for every affected rule / app / connection (more than one of them)
    final affected = eventAffected(e);
    final affectedAll = affected.where(_retargetable).length;
    void addChooseForAll() => add(l10n.chooseForAll, () async {
      final picked = await showTargetPicker(context, current: '');
      if (picked != null) await host.retargetAll(affected, picked);
    });
    void addChooseServer() => add(l10n.chooseServer, link(links.openRoute == null ? null : () => links.openRoute!()));
    switch ('${e.cat}/${e.type}') {
      case 'conn/disconnected' when live && (dd['by'] == 'error' || dd['by'] == 'system') && !host.isOn:
        add(l10n.connect, () => host.connect());
        if (pinLost) addChooseServer();
      case 'conn/connectFailed' when live:
        add(l10n.retry, () => host.connect());
        if (pinLost) addChooseServer();
        if (eventCauseInSettings(e)) add(l10n.openSettings, link(links.openConn));
      case 'conn/lost' || 'conn/restored':
        if (live && e.type == 'lost') addCheckNow();
        addOpen();
      case 'conn/offline' when live:
        add(l10n.networkSettings, () => host.openNetworkSettings());
      case 'conn/vpnDown' when live:
        // Retry: the core is the cause and sing-box is not running; the rest goes below (Send report, Network settings)
        if (vpnCauses.contains('core') && host.phase != ConnectionPhase.connected) add(l10n.retry, () => host.retry());
        if ('${dd['proxy']}' == 'kept') add(l10n.removeSystemProxy, () => host.releaseSysProxy());
      case 'conn/failing':
        final h = words.host(dd);
        if (h.isNotEmpty && links.newRuleFor != null) add(l10n.createRule, () => links.newRuleFor!(host: h));
        addOpen();
      case 'auto/switched' || 'auto/fastest':
        addOpen();
        final route = '${dd['route'] ?? ''}', to = '${dd['to'] ?? ''}';
        if (live && route.isNotEmpty && to.isNotEmpty && host.catalog.connectEntry(route) != null) {
          add(l10n.pin, () => host.pinRouteNode(route, to));
        }
      case 'auto/unstable':
        addOpen();
        if (live) addCheckNow();
        if (kAutoExcludeActions && live) {
          // no host call yet: the core has no exclusion to lift (the feature wires these when it adds the flag)
          add(l10n.returnOnce, null);
          add(l10n.donTExclude, null);
        }
      case 'dns/failed' || 'dns/failedOnNode':
        if (live) addCheckNow();
        addOpen();
      case 'sub/failed':
        if (live && host.catalog.sourcesData['${dd['source']}']?.kind == 'sub') {
          add(l10n.retry, () => host.updateSource('${dd['source']}'));
        }
        addOpen();
      case 'sub/removed':
        addOpen();
        if (inUse) addChooseServer();
      case 'sub/back' || 'node/back':
        break;
      case 'sub/updated' when e.level == 'warn':
        if (affectedAll > 1) addChooseForAll();
        final subTarget = eventOpenTarget(e, host);
        // the subscription is still there: the button stands (dimmed while Nodes is not wired, like "Open rule")
        if (subTarget != null) add(l10n.openSubscription, _openAction(links, subTarget, leave));
      case 'node/lost':
        if (dd['action'] == 'off') {
          final off = _switchedOff(host, dd);
          if (off.source || off.nodes.isNotEmpty) add(l10n.switchOn, () => _switchOn(host, dd));
        }
        if (affectedAll > 1) addChooseForAll();
      case 'sub/updated':
        addOpen();
        // the removed / returned servers of the same update sit in this row: one of them in use needs a new pick
        if (g.items.any((x) => x.cat == 'sub' && (x.type == 'removed' || x.type == 'back') && inUseOf(x.data))) addChooseServer();
      case 'node/addressMissing':
        addOpen();
        if (live && host.catalog.sourcesData['${dd['source']}'] != null) {
          add(l10n.updateSubscription, () => host.updateSource('${dd['source']}'));
        }
      case 'rules/targetLost' || 'rules/targetFound':
        add(l10n.openRule, link(links.openRules == null ? null : () => links.openRules!()));
        if (live && e.type == 'targetLost') add(l10n.chooseTarget, link(links.openRules == null ? null : () => links.openRules!()));
      case 'rules/fallback' || 'rules/targetBack':
        add(l10n.openRule, link(links.openRules == null ? null : () => links.openRules!()));
        if (live && e.type == 'fallback') addCheckNow();
      case 'rules/ruleSetFailed':
        if (live) add(l10n.retry, () => host.retryRuleSets(e.id));
        addOpen();
      case 'core/crashed' || 'core/restartFailed' || 'core/down' || 'core/restarted':
        // Retry only while sing-box is not running (it is back: nothing to retry)
        if (live && ce.type != 'restarted' && host.phase != ConnectionPhase.connected) add(l10n.retry, () => host.retry());
        // `proxy: kept` is written by the chain's `core/down`, not by the crash that roots the row
        if (ce.type != 'restarted' && g.items.any((x) => x.key == 'core/down' && '${x.data['proxy']}' == 'kept')) add(l10n.removeSystemProxy, () => host.releaseSysProxy());
      case 'core/tunNeedsAdmin':
        if (live) add(l10n.retry, () => host.retry());
        add(l10n.openSettings, link(links.openRoute == null ? null : () => links.openRoute!()));
      case 'core/tunTcpDead' when live:
        add(l10n.reconnect, () async {
          await host.disconnect();
          await host.connect();
        });
      case 'core/sysProxy' when dd['error'] != null:
        add(l10n.retry, () => host.setSysProxy(true));
        add(l10n.removeSystemProxy, () => host.releaseSysProxy());
      case 'core/deprecated':
        final t = '${dd['text'] ?? dd['message'] ?? ''}';
        if (t.isNotEmpty) add(l10n.copyText, () => copyText(context, t, l10n.event));
      case 'core/updateAvailable' || 'core/updateDownloaded' || 'core/updateDeltaFailed':
        add(l10n.install, () => host.installUpdate());
        addOpenUpdate();
      case 'core/updateFailed' || 'core/updateChannelEmpty':
        add(l10n.retry, () => host.checkUpdate());
        addOpenUpdate();
      case 'speed/failed':
        // the same measure again (it runs on the connection in use)
        if (!host.speedTesting) add(l10n.retry, () => host.toggleSpeedTest());
      default:
        break;
    }
    // "does not open": the site can be copied and made a rule whenever the event names one
    final site = e.cat == 'site' ? words.host(dd) : '';
    if (site.isNotEmpty) {
      // the table's order (logs.md «По типам»), Copy site last: the collapsed row shows the first three
      // the external checker (check-host): a check that is running now (older than 90 s = the core died meanwhile)
      final check = dd['check'];
      final asking =
          check is Map &&
          check['state'] == 'pending' &&
          DateTime.now().millisecondsSinceEpoch - ((check['at'] as num?)?.toInt() ?? 0) < 90000;
      add(asking ? l10n.checking : l10n.checkWithChecker, asking ? null : () => host.checkSite(e.id));
      // `viaTarget`: the node that opened the site when it is a node of the failing entry itself (a rule for the entry would not help)
      if (links.newRuleFor != null) {
        final v = dd['viaTarget'] ?? dd['via'];
        final via = v == null || '$v'.isEmpty ? null : '$v';
        add(l10n.createRule, () => links.newRuleFor!(host: site, via: via));
      }
      add(l10n.ignoreSite, () => ignoreSiteWithUndo(ScaffoldMessenger.of(context), l10n, logs, site));
      add(l10n.copySite, () => copyText(context, site, l10n.site));
    }
    // the rows whose "Open" has no button of its own above
    if (const ['dns/switched', 'sub/diverged'].contains('${e.cat}/${e.type}')) addOpen();
    // every error of the core can be sent to the developers with the event; some warnings name it in the table
    final sendable = const ['core/stateLost', 'core/stateRestored', 'core/tunTcpDead', 'sub/diverged'].contains('${e.cat}/${e.type}');
    if ((e.cat == 'core' && g.level == 'error') || sendable || e.key == 'conn/vpnDown') {
      add(l10n.sendReport, () => showSendReport(context, logs));
    }
    if (e.key == 'conn/vpnDown' && live && vpnCauses.contains('network')) {
      add(l10n.networkSettings, () => host.openNetworkSettings());
    }
    final rawLine = e.log == null
        ? null
        : () {
            logs.showRawLine(e.log!);
            leave();
          };
    const folded = 3;

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
              Flexible(
                child: Text(
                  l10n.background.toLowerCase(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: c.t3),
                ),
              ),
            ],
          ],
        ),
        Padding(
          padding: EdgeInsets.only(top: problem ? 1 : 0),
          child: Text(
            title,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.t1),
          ),
        ),
        if (!g.isGroup && e.cat == 'site' && (e.type == 'blocked' || e.type == 'unreachable'))
          _Vias(event: e, logs: logs, words: words)
        else if (detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              detail,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: c.t2),
            ),
          ),
        if (closedLine != null)
          _PairLink(
            closedLine,
            key: const ValueKey('evClosed'),
            color: c.active,
            onTap: g.closedById == null || onJump == null ? null : () => onJump!(g.closedById!),
          ),
        if (backTitle != null)
          _PairLink(
            l10n.backToStart(backTitle),
            key: const ValueKey('evBackToStart'),
            color: c.accent,
            onTap: onJump == null ? null : () => onJump!(g.opensId!),
          ),
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              reason,
              key: const ValueKey('evReason'),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: c.t3),
            ),
          ),
        if (related != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              related,
              key: const ValueKey('evRelated'),
              style: TextStyle(fontSize: 12.5, color: c.t3),
            ),
          ),
        if (open && affected.isNotEmpty && (e.key == 'node/lost' || (e.key == 'sub/updated' && e.level == 'warn')))
          _Affected(items: affected, event: e, logs: logs, words: words),
        if (acts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final (label, fn) in acts.take(folded)) EventAct(label, onTap: fn)],
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
                if (trail.isNotEmpty) ...[
                  _Section(l10n.checks),
                  for (final t in trail) _TrailLine(row: t),
                ],
                if (repeatsLine != null) _RepeatsBlock(summary: repeatsLine, times: repeatTimes),
                if (g.related.isNotEmpty) ...[
                  _Section(l10n.related(g.related.length)),
                  for (final r in g.related)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text(words.clock(r.lastAt), style: TextStyle(fontSize: 12, color: c.t3)),
                          ),
                          Expanded(
                            child: Text(
                              words.describe(r).title,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.t1),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final (label, fn) in acts.skip(folded)) EventAct(label, onTap: fn),
                        if (rawLine != null) EventAct(l10n.inRawLog, key: const ValueKey('evRaw'), onTap: rawLine),
                        // the type of this event: take it out of the journal, or look at it alone
                        // (`user/*` is outside the type filter: «Show my actions» rules it)
                        if (e.cat != 'user') ...[
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
    final go = openTargetAction(links, target);
    return go == null ? null : () { go(); leave(); };
  }
}

/// Where an [eventOpenTarget] leads (the row's "Open" and the notification's "Open" are this one); null when that screen
/// is not wired.
VoidCallback? openTargetAction(AppLinks links, String target) {
  switch (target) {
    case 'rules':
      final f = links.openRuleSets;
      return f == null ? null : () => f();
    case 'rulelist':
      final f = links.openRules;
      return f == null ? null : () => f();
    case 'dns':
      final f = links.openDns;
      return f == null ? null : () => f();
    case 'route':
      final f = links.openRoute;
      return f == null ? null : () => f();
    case final t when t.startsWith('app:'):
      final f = links.openAppAct;
      return f == null ? null : () => f(t.substring(4));
    default:
      final f = links.openNodesEntry;
      return f == null ? null : () => f(target);
  }
}

/// A status line of a pair row; a tap jumps to the other event of the pair.
class _PairLink extends StatelessWidget {
  const _PairLink(this.text, {super.key, required this.color, this.onTap});

  final String text;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: color,
          decoration: onTap == null ? null : TextDecoration.underline,
          decorationColor: color.tint(.5),
        ),
      ),
    ),
  );
}

/// The settings an event touched (`data.affected`), rows like the "site does not open" routes: the kind, the name
/// and "→ where it goes now"; a tap opens that item's settings.
class _Affected extends StatelessWidget {
  const _Affected({required this.items, required this.event, required this.logs, required this.words});

  final List<Map<String, dynamic>> items;
  final EventRecord event;
  final LogsController logs;
  final EventWords words;

  VoidCallback? _go(AppLinks links, CoreHost host, Map<String, dynamic> a) {
    final id = '${a['id']}';
    void Function()? f;
    switch ('${a['kind']}') {
      case 'rule':
        final h = links.openRuleForm;
        if (h != null) f = () => h(id);
      case 'app':
        final h = links.openAppAct;
        if (h != null) f = () => h(id);
      case 'connection':
        final h = links.openNodesEntry;
        if (h != null && host.catalog.connectEntry(id) != null) {
          f = () => h(id);
        } else if (links.openRoute != null) {
          f = () => links.openRoute!();
        }
      default: // chain / profile
        final h = links.openNodesEntry;
        if (h != null) f = () => h(id);
    }
    if (f == null) return null;
    final go = f;
    return () {
      go();
      logs.returnId = event.id;
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final links = AppLinksScope.of(context);
    final host = CoreHostScope.read(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.t1.tint(.035),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
            Builder(
              builder: (context) {
                final a = items[i], go = _go(links, host, a);
                final row = _ViaRow(
                  leading: Text(
                    words.affectedKindLabel('${a['kind']}'),
                    style: TextStyle(fontSize: 11, color: c.t3),
                  ),
                  name: '${a['name']}',
                  sub: '→ ${words.affectedToLabel(a)}',
                  trailing: go == null ? null : Icon(Icons.chevron_right, size: 18, color: c.t3),
                  leadingWidth: 68,
                );
                return go == null
                    ? row
                    : InkWell(
                        key: ValueKey('evAffected:${a['kind']}:${a['id']}'),
                        onTap: go,
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: c.t1.tint(.04),
                        child: row,
                      );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// A caption inside the opened row (Checks, Related).
class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .5,
          color: context.colors.t3,
        ),
      ),
    ),
  );
}

/// One step of the `trail`: the mark (✓ ✗ ? ·), the phrase and the time from the start of the suspicion.
class _TrailLine extends StatelessWidget {
  const _TrailLine({required this.row});

  final TrailRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final markColor = switch (row.mark) {
      '✓' => c.active,
      '✗' => c.warn,
      _ => c.t3,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(row.mark, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: markColor)),
          ),
          Expanded(child: Text(row.text, style: TextStyle(fontSize: 12, color: c.t1))),
          if (row.at != null) ...[
            const SizedBox(width: 8),
            Text(
              row.at!,
              style: TextStyle(fontSize: 11.5, color: c.t3, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Repeats": "N times · from HH:MM to HH:MM"; the times themselves are folded until it is tapped.
class _RepeatsBlock extends StatefulWidget {
  const _RepeatsBlock({required this.summary, required this.times});

  final String summary;
  final List<int> times;

  @override
  State<_RepeatsBlock> createState() => _RepeatsBlockState();
}

class _RepeatsBlockState extends State<_RepeatsBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final words = EventWords(context.l10n, CoreHostScope.read(context).catalog);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(context.l10n.repeats),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.times.length > 1 ? () => setState(() => _open = !_open) : null,
          child: Text(
            widget.summary,
            key: const ValueKey('evRepeats'),
            style: TextStyle(fontSize: 12, color: c.t1),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              widget.times.map((t) => words.clock(t, seconds: true)).join(', '),
              style: TextStyle(fontSize: 12, color: c.t3),
            ),
          ),
      ],
    );
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

    // the checker could not open the site either: it is down, our routes are no part of the event
    final routes = !(e.type == 'unreachable' && words.downEverywhere(d));
    final rows = <Widget>[
      for (final w in words.whyRows(d)) _WhyRow(row: w, event: e, logs: logs),
      if (routes) ...[
        if (entry.isNotEmpty) via('⚠️', entry, d['server']),
        if (e.type == 'blocked' && d['via'] != null && '${d['via']}'.isNotEmpty)
          via('✅', '${d['via']}', d['viaServer']),
        if (e.type == 'unreachable')
          for (final x in tried)
            if (x is Map) via('⚠️', '${x['entry']}', x['server']),
      ],
    ];
    final note = routes && e.type == 'unreachable' && tried.isEmpty
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
  const _ViaRow({required this.leading, required this.name, this.sub, this.trailing, this.leadingWidth = 20});

  final Widget leading;
  final double leadingWidth;
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
          SizedBox(width: leadingWidth, child: Center(child: leading)),
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
              // the types of the VPN line are never hidden: nothing to toggle
              onTap: alwaysShownTypes.contains('${cat.$1}/$t') ? null : () => logs.toggleType('${cat.$1}/$t'),
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
                    if (alwaysShownTypes.contains('${cat.$1}/$t'))
                      const SizedBox(width: 20, height: 20)
                    else
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
                    if (alwaysShownTypes.contains('${cat.$1}/$t')) ...[
                      Text(
                        context.l10n.alwaysShown,
                        key: ValueKey('evAlways:${cat.$1}/$t'),
                        style: TextStyle(fontSize: 12, color: c.t3),
                      ),
                      const SizedBox(width: 8),
                    ],
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
