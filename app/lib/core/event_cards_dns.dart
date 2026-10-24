import 'dart:ui' show VoidCallback;

import 'package:jormungand_core/jormungand_core.dart' show EventRecord;

import '../l10n/l10n.dart';
import '../widgets/event_card.dart';
import 'settings_model.dart' show dnsKindName;

/// The DNS events as generic cards (`logs.md`, "Карточка dns/switched"): turns the data of `dns/switched`,
/// `dns/transport`, `dns/down`, `dns/up` into an [EventCardModel], and `net/switched`'s `data.dns` into frames.
/// Every name comes from the event data (or the lookups of [DnsCardCtx]); no navigation code here.

/// What a card needs from the row that draws it: the strings, the name lookups and the buttons' callbacks.
class DnsCardCtx {
  const DnsCardCtx({
    required this.l,
    required this.repeats,
    required this.nodeLabel,
    required this.sourceLabel,
    required this.causeTitle,
    required this.onDetails,
    required this.onDnsSettings,
    required this.onOpenEvent,
    required this.onGoNode,
  });

  final AppLocalizations l;
  final int repeats;

  /// The display name of a node key (`sid::nid`) / of a source id.
  final String Function(String nodeKey) nodeLabel;
  final String Function(String sourceId) sourceLabel;

  /// The title of the root event [eventId] (a cause); null = not at hand.
  final String? Function(int eventId) causeTitle;
  final VoidCallback onDetails;

  /// Opens Settings → DNS on the [side] (`vpn` / `direct`).
  final void Function(String side) onDnsSettings;

  /// Opens the event [eventId] (the Network event button).
  final void Function(int eventId) onOpenEvent;

  /// Opens the node [nodeKey] in Routes.
  final void Function(String nodeKey) onGoNode;
}

String _kind(Object? k) => dnsKindName('$k');

Map<String, dynamic> _map(Object? o) => o is Map ? Map<String, dynamic>.from(o) : <String, dynamic>{};

List<Map<String, dynamic>> _list(Object? o) => o is List ? [for (final x in o) if (x is Map) _map(x)] : const [];

String _name(Map<String, dynamic> m) {
  final n = '${m['name'] ?? ''}';
  return n.isNotEmpty ? n : '${m['provider'] ?? ''}';
}

CardLevel _level(String l) => switch (l) {
  'warn' => CardLevel.warn,
  'error' => CardLevel.error,
  'ok' => CardLevel.ok,
  _ => CardLevel.info,
};

String _sideLabel(AppLocalizations l, Object? side) => '$side' == 'vpn' ? l.vpn : l.direct3;

/// The same wording as the journal's duration («N s», «N min», «H h M min»).
String _duration(AppLocalizations l, num ms) {
  final s = (ms / 1000).round();
  if (s < 90) return l.s(s);
  if (s < 5400) return l.min((s / 60).round());
  return l.hMin(s ~/ 3600, ((s % 3600) / 60).round());
}

/// The rows of a switch: one for both sides in two lines when [same], else one per side.
List<SwitchRow> _switchRows(AppLocalizations l, List<Map<String, dynamic>> sides, bool same, int at) {
  SwitchRow row(String label, Map<String, dynamic> s) {
    final from = _map(s['from']), to = _map(s['to']);
    final silent = [for (final k in (from['silent'] as List? ?? const [])) _kind(k)];
    final since = from['since'];
    final parts = [
      if (silent.isNotEmpty) silent.join(', '),
      if (since is num && since > 0) l.noAnswerForS(((at - since) / 1000).round().clamp(0, 1 << 30)),
    ];
    final ms = to['ms'];
    final toParts = [
      if ('${to['kind'] ?? ''}'.isNotEmpty) _kind(to['kind']),
      if (ms is num && ms >= 0) '${ms.round()} ms',
    ];
    return SwitchRow(
      label: label,
      from: ChipText(title: _name(from), sub: parts.isEmpty ? null : parts.join(' · ')),
      to: ChipText(title: _name(to), sub: toParts.isEmpty ? null : toParts.join(' · ')),
    );
  }

  if (same && sides.length > 1) {
    return [row(sides.map((s) => _sideLabel(l, s['side'])).join('\n'), sides.first)];
  }
  return [for (final s in sides) row(_sideLabel(l, s['side']), s)];
}

/// The rows of a transport change: the chips are the transports.
List<SwitchRow> _transportRows(AppLocalizations l, List<Map<String, dynamic>> sides, bool same) {
  SwitchRow row(String label, Map<String, dynamic> s) {
    final ms = s['ms'];
    return SwitchRow(
      label: label,
      from: ChipText(title: [for (final k in (s['from'] as List? ?? const [])) _kind(k)].join(', ')),
      to: ChipText(title: _kind(s['to']), sub: ms is num && ms >= 0 ? '${ms.round()} ms' : null),
    );
  }

  if (same && sides.length > 1) {
    return [row(sides.map((s) => _sideLabel(l, s['side'])).join('\n'), sides.first)];
  }
  return [for (final s in sides) row(_sideLabel(l, s['side']), s)];
}

/// The Route row: «subscription · protocol», under it «└ node»; the chevron goes to the node in Routes.
DataBox? _routeBox(DnsCardCtx ctx, Map<String, dynamic> route) {
  final node = '${route['node'] ?? ''}', sub = '${route['sub'] ?? ''}', proto = '${route['proto'] ?? ''}';
  if (node.isEmpty && sub.isEmpty) return null;
  final value = [if (sub.isNotEmpty) ctx.sourceLabel(sub), if (proto.isNotEmpty) proto].join(' · ');
  return DataBox(
    rows: [
      KeyRow(
        name: ctx.l.route,
        value: value,
        sub: node.isEmpty ? null : '└ ${ctx.nodeLabel(node)}',
        marquee: true,
        onGo: node.isEmpty ? null : () => ctx.onGoNode(node),
      ),
    ],
  );
}

/// The Cause line: «bold — rest».
(String, String) _cause(DnsCardCtx ctx, Map<String, dynamic> c) {
  final l = ctx.l;
  switch ('${c['kind']}') {
    case 'itself':
      return (l.itself('${c['a'] ?? ''}'), l.answersThroughTheSameRoute('${c['b'] ?? ''}'));
    case 'transport':
      return (l.doesNotAnswerOnThisRoute(_kind(c['a'])), l.ofTheSameServerDoes(_kind(c['b'])));
    case 'node':
      return (l.node(ctx.nodeLabel('${c['node'] ?? ''}')), l.answersThroughAnotherNode('${c['server'] ?? ''}'));
    case 'net' || 'nodeIncident' || 'autoNode' || 'reconnect' || 'coreRestart':
      final id = c['id'];
      final title = id is num ? ctx.causeTitle(id.toInt()) : null;
      if (title != null) return (title, '');
  }
  return (l.causeNotEstablishedSeeTheChecks, '');
}

List<CardAction> _actions(DnsCardCtx ctx, Map<String, dynamic> cause, String side) {
  final l = ctx.l;
  final id = cause['id'];
  return [
    CardAction(label: l.details, onTap: ctx.onDetails, details: true),
    CardAction(label: l.dnsSettings, onTap: () => ctx.onDnsSettings(side)),
    if (cause['kind'] == 'net' && id is num) CardAction(label: l.networkEvent, onTap: () => ctx.onOpenEvent(id.toInt())),
  ];
}

/// The card of a DNS event; null = not a DNS event the card draws (or an old one without `sides`: the old view stays).
EventCardModel? dnsCard(EventRecord e, DnsCardCtx ctx) {
  if (e.cat != 'dns') return null;
  final d = e.data;
  final sides = _list(d['sides']);
  if (sides.isEmpty) return null;
  final l = ctx.l;
  final same = d['same'] == true;
  final cause = _map(d['cause']);
  final side = '${sides.first['side'] ?? 'vpn'}';
  switch (e.type) {
    case 'switched' || 'transport':
      final isSwitch = e.type == 'switched';
      final route = _map(d['route']);
      final vpnInvolved = same || sides.any((s) => '${s['side']}' == 'vpn');
      final box = route.isEmpty || !vpnInvolved ? null : _routeBox(ctx, route);
      return EventCardModel(
        level: _level(e.level),
        repeats: ctx.repeats,
        background: e.bg,
        title: isSwitch ? l.dnsSwitched : l.changedTransport(_name(sides.first)),
        blocks: [
          SwitchFrame(rows: isSwitch ? _switchRows(l, sides, same, e.at) : _transportRows(l, sides, same)),
          ?box,
        ],
        cause: _cause(ctx, cause),
        actions: _actions(ctx, cause, side),
      );
    case 'down':
      final noSpare = d['noSpare'] == true;
      final nodes = _list(d['nodes']);
      return EventCardModel(
        level: CardLevel.error,
        repeats: ctx.repeats,
        background: e.bg,
        title: l.dnsDoesNotAnswer,
        blocks: [
          DataBox(
            rows: [
              for (final s in sides) ...[
                CardSection(title: '${s['side']}' == 'vpn' ? l.throughVpn : l.direct3),
                for (final sv in _list(s['servers']))
                  CheckRow(
                    ok: false,
                    value: [_name(sv), (sv['kinds'] as List? ?? const []).map(_kind).join(', ')]
                        .where((x) => x.isNotEmpty)
                        .join(' · '),
                    sub: noSpare ? l.noAnswerNoSpareDnsOn : l.noAnswerStaysSelected,
                  ),
              ],
              if (nodes.isNotEmpty) ...[
                CardSection(title: l.checkedThrough),
                for (final n in nodes)
                  CheckRow(
                    ok: n['ok'] == true,
                    value: [ctx.nodeLabel('${n['key'] ?? ''}'), '${n['proto'] ?? ''}'].where((x) => x.isNotEmpty).join(' · '),
                    sub: n['ok'] == true ? l.answersSpareNode : l.noAnswer,
                    marquee: true,
                    onGo: '${n['key'] ?? ''}'.isEmpty ? null : () => ctx.onGoNode('${n['key']}'),
                  ),
              ],
            ],
          ),
        ],
        cause: _cause(ctx, cause),
        actions: _actions(ctx, cause, side),
      );
    case 'up':
      final after = d['afterMs'];
      return EventCardModel(
        level: CardLevel.ok,
        repeats: ctx.repeats,
        background: e.bg,
        title: l.dnsAnswersAgainAfter(_duration(l, after is num ? after : 0)),
        blocks: [
          DataBox(
            rows: [
              for (final s in sides)
                CheckRow(
                  ok: true,
                  value: [_name(s), if ('${s['kind'] ?? ''}'.isNotEmpty) _kind(s['kind'])].join(' · '),
                  sub: _sideLabel(l, s['side']),
                ),
            ],
          ),
        ],
        actions: _actions(ctx, const {}, side),
      );
  }
  return null;
}

/// The DNS blocks of a `net/switched` (`data.dns`): the frame «DNS switched» and one frame per transport change; empty
/// when there is no DNS change in it.
List<CardBlock> netDnsBlocks(EventRecord e, DnsCardCtx ctx) {
  final dns = _map(e.data['dns']);
  final l = ctx.l;
  final same = dns['same'] == true;
  final switches = _list(dns['switches']), transports = _list(dns['transports']);
  return [
    if (switches.isNotEmpty) SwitchFrame(heading: l.dnsSwitched, rows: _switchRows(l, switches, same, e.at)),
    // the sides of one provider that changed transport go to one frame
    for (final group in _transportGroups(transports, same))
      SwitchFrame(heading: l.changedTransport(_name(group.first)), rows: _transportRows(l, group, same)),
  ];
}

List<List<Map<String, dynamic>>> _transportGroups(List<Map<String, dynamic>> all, bool same) {
  if (all.isEmpty) return const [];
  if (same) return [all];
  final by = <String, List<Map<String, dynamic>>>{};
  for (final t in all) {
    by.putIfAbsent('${t['provider']}', () => []).add(t);
  }
  return by.values.toList();
}
