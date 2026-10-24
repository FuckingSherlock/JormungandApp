import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:jormungand_core/jormungand_core.dart' show EventRecord, SiteChecker, nodeKeyOfTag;

import '../l10n/l10n.dart';
import '../widgets/event_card.dart';
import '../widgets/rules_parts.dart' show AppIcon;
import 'event_text.dart';

/// The card of `site/unreachable` and `site/blocked` (`connect-model.md`, "Карточка сайта"): one view, the verdict
/// only changes the title, the Fallback of a new rule, the Cause and the green row of the node that opened it. Every
/// action comes ready from the caller ([SiteCardCtx]); this builds the model and navigates nowhere.
class SiteCardCtx {
  const SiteCardCtx({
    required this.l,
    required this.words,
    required this.repeats,
    required this.background,
    required this.nodeLabel,
    required this.sourceLabel,
    required this.ruleFor,
    required this.nodeInfo,
    required this.onDetails,
    required this.onIgnore,
    required this.onOpenApp,
    required this.onOpenRule,
    this.onOpenAppRule,
    this.onNewAppRule,
    required this.onCreateRule,
    required this.onGoNode,
    required this.onRecheckNode,
    required this.onRecheckChecker,
    required this.busy,
  });

  final AppLocalizations l;

  /// The lookups of the event words (catalog, app, rule and checker texts): the existing row logic is called, not copied.
  final EventWords words;
  final int repeats;
  final bool background;
  final String Function(String nodeKey) nodeLabel;
  final String Function(String sourceId) sourceLabel;

  /// The existing user rule that catches the host (`rulesCatching`): `route` is the action label, `target` the main
  /// flow / subscription / node label; null = no rule yet (the "Create rule" row).
  final ({String id, String route, String target})? Function(String host) ruleFor;

  /// A node for a route row: the subscription name, the protocol, the node name; null = the catalog no longer has it.
  final ({String sub, String proto, String node})? Function(String nodeKey) nodeInfo;
  final VoidCallback onDetails;

  /// Opens the "Ignore site ▾" dropdown (Everywhere / On this route only, "Ignored sites…") under the button at [at]
  /// (global coordinates): the caller owns it.
  final void Function(Rect at) onIgnore;
  final VoidCallback onOpenApp;
  final void Function(String ruleId) onOpenRule;

  /// The form of a rule of an app (the sheet of the app with the form over it) / of a new rule of the app for a host
  /// ([via] '' = none).
  final void Function(String app, String ruleId)? onOpenAppRule;
  final void Function(String app, String host, String via)? onNewAppRule;

  /// The new-rule form; its prefill (Fallback = the route that opened the site, else Default) is the caller's.
  final VoidCallback onCreateRule;
  final void Function(String nodeKey) onGoNode;
  final void Function(String nodeKey) onRecheckNode;
  final VoidCallback onRecheckChecker;

  /// Whether the recheck of a row is running (row keys: a node key, 'checker').
  final bool Function(String rowKey) busy;
}

// The checker's name: the host of the core's checker (`SiteChecker.base`); the event's `check` never carries one.
final _checkerService = Uri.parse(SiteChecker.base).host;

/// A node of the card: the key, and the entry it was reached by (for an old event without a node key).
class _Hop {
  const _Hop(this.entry, this.server);
  final String entry, server;
  bool get isEmpty => entry.isEmpty && server.isEmpty;
}

_Hop _hop(Object? entry, Object? server) =>
    _Hop(entry == null ? '' : '$entry', server == null ? '' : '$server');

String _key(String k) => nodeKeyOfTag(k) ?? k;

EventCardModel? siteCard(EventRecord e, SiteCardCtx ctx) {
  if (e.cat != 'site' || (e.type != 'unreachable' && e.type != 'blocked')) return null;
  final l = ctx.l, w = ctx.words, d = e.data;
  final blocked = e.type == 'blocked';
  final host = w.host(d);

  // down everywhere: the site is down, our routes are no part of it
  final routes = blocked || !w.downEverywhere(d);
  final own = _hop(d['entry'] ?? d['route'], d['server']);
  // the checked nodes: `nodes` (after rechecks), else the old `tried` (red) + `via` (green)
  final nodes = <({_Hop hop, bool ok, int? ms})>[];
  if (d['nodes'] is List) {
    for (final x in d['nodes'] as List) {
      if (x is! Map) continue;
      final h = _hop(x['entry'], x['server']);
      if (h.isEmpty) continue;
      nodes.add((hop: h, ok: x['ok'] == true, ms: x['ms'] is num ? (x['ms'] as num).toInt() : null));
    }
  } else {
    if (d['tried'] is List) {
      for (final x in d['tried'] as List) {
        if (x is Map && !_hop(x['entry'], x['server']).isEmpty) {
          nodes.add((hop: _hop(x['entry'], x['server']), ok: false, ms: null));
        }
      }
    }
    final v = blocked ? _hop(d['via'], d['viaServer']) : const _Hop('', '');
    if (!v.isEmpty) nodes.add((hop: v, ok: true, ms: null));
  }
  final shown = nodes.where((n) => n.ok || routes).toList();
  final via = shown.where((n) => n.ok).firstOrNull?.hop ?? const _Hop('', '');
  final redNodes = shown.where((n) => !n.ok).length;
  final ownN = routes && !own.isEmpty ? 1 : 0;
  final opened = shown.any((n) => n.ok);
  final failedCount = ownN + redNodes;
  final total = ownN + shown.length;

  final title = total == 0
      ? l.doesNotOpen(host)
      : opened
      ? l.didNotOpenOnOfServers(host, failedCount, total)
      : l.didNotOpenOnServersPlural(total, host);

  String nodeName(_Hop h) => h.server.isNotEmpty ? ctx.nodeLabel(_key(h.server)) : w.entry(h.entry);

  // «<subscription> · <protocol>» / «└ <node>»
  (String, String?) routeText(_Hop h) {
    if (h.server.isEmpty) return (w.entry(h.entry), null);
    final k = _key(h.server);
    final info = ctx.nodeInfo(k);
    if (info == null) return (w.entry(h.entry), '└ ${ctx.nodeLabel(k)}');
    return (info.proto.isEmpty ? info.sub : '${info.sub} · ${info.proto}', '└ ${info.node}');
  }

  VoidCallback? go(_Hop h) => h.server.isEmpty ? null : () => ctx.onGoNode(_key(h.server));

  final rows = <BoxRow>[];

  // App + its Rule row: the existing "why" rows say which of the app / the rule decided (marks) and which app rule
  // catches the host; the card only draws them (an App row first, then the rule rows)
  final pkg = w.appPkg(d), appName = w.appName(d);
  if (appName.isNotEmpty) {
    final a = w.catalog.appRules[pkg];
    final hasOwn = a != null && a.halves.any((h) => h.$2.act != 'default');
    final why = w.whyRows(d);
    final appRow = why.where((x) => x.key == l.app).firstOrNull;
    final fb = opened ? nodeName(via) : '';
    VoidCallback? openApp() => pkg.isEmpty ? null : ctx.onOpenApp;
    rows.add(
      KeyRow(
        leading: pkg.isEmpty ? null : AppIcon(key: ValueKey('whyIcon:$pkg'), pkg: pkg, name: appName, size: 20),
        value: appName,
        sub: appRow != null && appRow.to.isNotEmpty ? appRow.to : pkg.isNotEmpty && !hasOwn ? l.noOwnRoute : null,
        mark: appRow?.mark,
        onTap: openApp(),
      ),
    );
    for (final x in why) {
      if (x == appRow || x.go == WhyGo.route) continue;
      switch (x.go) {
        case WhyGo.newAppRule:
          rows.add(
            KeyRow(
              name: l.rule,
              icon: LucideIcons.squarePlus,
              value: l.createRule2(x.host),
              sub: fb.isEmpty || x.via.isEmpty ? null : l.fallback2(fb),
              onTap: ctx.onNewAppRule == null ? ctx.onCreateRule : () => ctx.onNewAppRule!(x.app, x.host, x.via),
            ),
          );
        default:
          rows.add(
            KeyRow(
              name: l.rule,
              value: x.name,
              sub: x.to.isEmpty ? null : x.to,
              mark: x.mark,
              onTap: switch (x.go) {
                WhyGo.user => () => ctx.onOpenRule(x.id),
                WhyGo.appRule when ctx.onOpenAppRule != null => () => ctx.onOpenAppRule!(x.app, x.id),
                _ => null,
              },
            ),
          );
      }
    }
  }

  // Rule: the rule of this host if there is one, else the action that makes it
  if (host.isNotEmpty && appName.isEmpty) {
    final r = ctx.ruleFor(host);
    final reopened = d['reopened'] != null && d['reopened'] != false;
    if (r != null) {
      rows.add(KeyRow(name: l.rule, value: l.rule6(host), sub: '${r.route}: ${r.target}', onTap: () => ctx.onOpenRule(r.id)));
    } else if (!reopened) {
      final fb = opened ? nodeName(via) : '';
      rows.add(
        KeyRow(
          name: l.rule,
          icon: LucideIcons.squarePlus,
          value: l.createRule2(host),
          sub: fb.isEmpty ? null : l.fallback2(fb),
          onTap: ctx.onCreateRule,
        ),
      );
    }
  }

  // the route the failed connection went through: a red row, above the Checked section
  if (routes && !own.isEmpty) {
    final (v, s) = routeText(own);
    final k = own.server.isEmpty ? null : _key(own.server);
    rows.add(
      CheckRow(
        ok: false,
        value: v,
        sub: s,
        marquee: true,
        onRetry: k == null ? null : () => ctx.onRecheckNode(k),
        onGo: go(own),
        busy: k != null && ctx.busy(k),
      ),
    );
  }

  // Checked: only the additional checks
  final checks = <BoxRow>[];
  for (final n in shown) {
    final h = n.hop;
    final (v, s) = routeText(h);
    final k = h.server.isEmpty ? null : _key(h.server);
    final ms = n.ok && n.ms != null ? l.opensInMs(n.ms!) : null;
    checks.add(
      CheckRow(
        ok: n.ok,
        value: v,
        sub: ms == null ? s : s == null ? ms : '$s · $ms',
        marquee: true,
        onRetry: k == null ? null : () => ctx.onRecheckNode(k),
        onGo: go(h),
        busy: k != null && ctx.busy(k),
      ),
    );
  }
  final chk = _checkerRow(d['check'], ctx);
  if (chk != null) checks.add(chk);
  if (checks.isNotEmpty) rows..add(CardSection(title: l.checked2))..addAll(checks);

  // Cause
  (String, String)? cause;
  if (blocked || opened) {
    cause = (own.isEmpty ? host : nodeName(own), l.theSiteOpensThroughAnotherServer);
  } else {
    final verdict = w.checkText(d);
    cause = (
      verdict ??
          (!routes
              ? l.causeNotEstablishedSeeTheChecks
              : redNodes == 0
              ? (d['retries'] == 'off' ? l.retriesThroughOtherRoutesAreOff : l.noOtherWorkingRouteToTry)
              : l.causeNotEstablishedSeeTheChecks),
      '',
    );
  }

  return EventCardModel(
    level: e.level == 'error' ? CardLevel.error : CardLevel.warn,
    icon: Icons.language,
    time: w.clock(e.at),
    repeats: ctx.repeats,
    background: ctx.background || e.bg,
    title: title,
    copy: host.isEmpty ? null : host,
    blocks: rows.isEmpty ? const [] : [DataBox(rows: rows)],
    cause: cause,
    actions: [
      CardAction(label: l.details, onTap: ctx.onDetails, details: true),
      CardAction.menu(label: '${l.ignoreSite} ▾', onMenu: ctx.onIgnore),
    ],
  );
}

/// `service · kind` with the outcome under it; null when the checker has not said anything (off / asking).
CheckRow? _checkerRow(Object? c, SiteCardCtx ctx) {
  if (c is! Map) return null;
  final l = ctx.l;
  var busy = ctx.busy('checker');
  if (c['state'] == 'pending') {
    // the previous outcome stays drawn while the checker runs again
    final prev = c['prev'];
    if (prev is! Map) {
      final kind = '${c['kind'] ?? 'http'}'.toUpperCase();
      return CheckRow(
        ok: null,
        value: '$_checkerService · $kind',
        sub: l.checking,
        busy: true,
        onRetry: ctx.onRecheckChecker,
        onGo: null,
      );
    }
    c = prev;
    busy = true;
  }
  final state = c['state'];
  if (state != 'opens' && state != 'down' && state != 'failed') return null;
  final kind = '${c['kind'] ?? 'http'}'.toUpperCase();
  final route = c['via'] == 'tunnel' ? l.viaTunnel : c['via'] == 'direct' ? l.direct4 : null;
  final String outcome;
  if (state == 'failed') {
    outcome = l.theCheckerDidNotAnswer;
  } else {
    final ok = c['ok'] is num ? (c['ok'] as num).toInt() : 0;
    final total = c['total'] is num ? (c['total'] as num).toInt() : 0;
    outcome = total > 0 ? l.opensOnOfNodesPlural(ok, total) : (state == 'opens' ? l.theExternalCheckerOpensItFrom : l.downEverywhereCheckHost);
  }
  return CheckRow(
    ok: state == 'opens',
    value: '$_checkerService · $kind',
    sub: route == null ? outcome : '$outcome · $route',
    onRetry: ctx.onRecheckChecker,
    onGo: null,
    busy: busy,
  );
}
