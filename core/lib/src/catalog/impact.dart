/// What a deletion does to everything that uses the deleted thing — the list the delete
/// dialog shows (`deleteImpact` in 30-nodes.js, `targetImpact` / `ruleSummary` in 40-rules.js,
/// `confirmDeleteSource` / `confirmDeleteNode` / `confirmDeleteEntry`). Found by previewing the
/// lists without the thing ([Catalog.simExclude]).
library;

import 'catalog.dart';
import 'json_util.dart';
import 'models.dart';
import 'rules_logic.dart' show AppRulesOps;
import 'rules_model.dart';

/// One line of the "This will affect" list. [level]: `warn` | `bad`.
class ImpactLine {
  const ImpactLine(this.name, this.kind, this.what, this.level, {this.aKind, this.aId, this.aTo, this.aName});

  /// The entry, rule or app.
  final String name;

  /// `chain` | `profile` | `entry` | `rule #N` | `app` | `app · TCP`… | '' (the connection).
  final String kind;

  /// What happens to it (the mockup's English text).
  final String what;
  final String level;

  /// The line as an `affected` item of a journal event (docs/logs.md → «Задетые настройки»): [aKind] `connection` |
  /// `chain` | `profile` | `rule` | `app`, [aId], [aTo] (where its traffic goes now: `block` / `direct` / `main` / a
  /// target id / `none`), [aName] when it is not [name]. Null [aKind]: the line says nothing of a setting in use (a
  /// route entry nobody uses, a chain that only loses some servers); not part of the equality.
  final String? aKind, aId, aTo, aName;

  List<String> toList() => [name, kind, what, level];

  @override
  bool operator ==(Object other) => other is ImpactLine && other.name == name && other.kind == kind && other.what == what && other.level == level;

  @override
  int get hashCode => Object.hash(name, kind, what, level);

  @override
  String toString() => '[$name | $kind | $what | $level]';
}

const _ruleGroupKeys = ['domain', 'ip', 'port', 'source', 'network', 'process'];
const _fieldPrefix = {
  'domain_keyword': 'kw ',
  'domain_regex': 're ',
  'geosite': 'geosite:',
  'rule_set': 'set:',
  'geoip': 'geoip:',
  'port': 'port ',
  'source_ip_cidr': 'from ',
  'source_port': 'from port ',
};

/// A rule in a few words: its conditions (`ruleSummary`).
String ruleSummary(UserRule r) {
  if (r.composite != null) return 'composite rule';
  final groups = r.groups ?? const <String, dynamic>{};
  final parts = <String>[];
  for (final key in _ruleGroupKeys) {
    if (!truthy(groups[key])) continue;
    final d = asJson(groups[key]);
    final v = d['v'] is Map ? asJson(d['v']) : Json();
    // The prefix goes on a field's first value only: "port 443, 8000-9000".
    final vals = <String>[
      for (final e in v.entries)
        if (e.value is List)
          for (final (i, x) in (e.value as List).indexed) '${i == 0 ? _fieldPrefix[e.key] ?? '' : ''}$x',
    ];
    if (truthy(d['flag'])) vals.insert(0, 'local networks');
    final shown = vals.take(2).join(', ') + (vals.length > 2 ? ' +${vals.length - 2}' : '');
    parts.add((truthy(d['not']) ? 'not ' : '') + (shown.isEmpty ? '—' : shown));
  }
  return parts.isEmpty ? 'no conditions' : parts.join(' · ');
}

String ruleTitle(UserRule r) => r.name.isNotEmpty ? r.name : ruleSummary(r);

extension CatalogImpact on Catalog {
  /// A rule's / app's own "If unavailable", else the global one (`ruleFallback`).
  String ruleFallback(String fallback) => fallback.isNotEmpty && fallback != 'default' ? fallback : quickCfg.fallback;

  static String _fallbackText(String v) => const {
        'main': 'through the main flow',
        'block': 'nowhere (blocked)',
        'direct': 'direct',
      }[v] ?? 'undefined'; // the mockup prints JS `undefined` for a target id here

  /// Rules and apps whose target a deletion removes ([gone]: target -> bool) (`targetImpact`).
  List<ImpactLine> targetImpact(bool Function(String target) gone) {
    final lines = <ImpactLine>[];
    for (final (i, id) in ruleOrder.indexed) {
      final r = rulesData[id];
      if (r != null && r.action == 'proxy' && r.target.isNotEmpty && gone(r.target)) {
        lines.add(ImpactLine(ruleTitle(r), 'rule #${i + 1}', 'loses its target — traffic goes ${_fallbackText(ruleFallback(r.fallback))}', 'warn',
            aKind: 'rule', aId: r.id, aTo: _fallbackTo(r.fallback, r.fallbackTarget)));
      }
    }
    for (final e in appRules.entries) {
      for (final (proto, h) in e.value.halves) {
        if (h.act == 'proxy' && h.target.isNotEmpty && gone(h.target)) {
          final name = appLabel(e.key);
          lines.add(ImpactLine(name, 'app${proto.isNotEmpty ? ' · $proto' : ''}', 'loses its target — traffic goes ${_fallbackText(ruleFallback(h.fallback))}', 'warn',
              aKind: 'app', aId: e.key, aTo: _fallbackTo(h.fallback, h.fallbackTarget)));
        }
      }
    }
    return lines;
  }

  /// Where a rule / app with "If unavailable" [fallback] sends its traffic when its target is gone (`main` with a
  /// [fallbackTarget] is that target).
  String _fallbackTo(String fallback, String? fallbackTarget) {
    final f = ruleFallback(fallback);
    return f == 'main' && fallbackTarget != null && fallbackTarget.isNotEmpty ? fallbackTarget : f;
  }

  /// What deleting the servers [excl] picks (a whole source [sid], or one server) does to
  /// the connection, entries, profiles and chains (`deleteImpact`).
  List<ImpactLine> deleteImpact(bool Function(NodeRef) excl, [String? sid]) {
    final lines = <ImpactLine>[];
    (int, int) both(int Function() f) {
      simExclude = null;
      final a = f();
      simExclude = excl;
      final b = f();
      simExclude = null;
      return (a, b);
    }

    String srv(int k) => '$k server${k == 1 ? '' : 's'}';
    // The connection right now.
    final id0 = effectiveConnectId(), c0 = id0 == null ? null : chainsData[id0];
    final using = <NodeRef>[];
    if (c0 != null) {
      final e = chainEntryNode(c0), x = chainExitNode(c0);
      for (final r in chainEntryRefs(c0)) {
        if (identical(r.node, e)) {
          using.add(r);
          break;
        }
      }
      for (final r in chainExitRefs(c0)) {
        if (identical(r.node, x)) {
          using.add(r);
          break;
        }
      }
    } else {
      final n = unitNode(id0);
      for (final r in unitRefs(id0)) {
        if (identical(r.node, n)) {
          using.add(r);
          break;
        }
      }
    }
    if (using.any(excl)) {
      lines.add(ImpactLine('Current connection', '', 'goes through it — will reconnect through the next working server', 'warn',
          aKind: 'connection', aId: id0 ?? '', aTo: 'main', aName: id0 == null ? null : connectEntry(id0)?.name));
    }
    for (final mode in const ['simple', 'profiles']) {
      for (final id in catalogOrder[mode]!) {
        final e = connectEntry(id);
        if (e == null || id == sid) continue;
        final c = chainsData[id];
        if (c != null) {
          if (sid != null && (c.inId == sid || c.outId == sid)) {
            lines.add(ImpactLine(e.name, 'chain', 'is deleted with it', 'bad', aKind: 'chain', aId: id, aTo: 'none'));
            continue;
          }
          final (ei, eo) = both(() => chainEntryRefs(c).length);
          final (xi, xo) = both(() => chainExitRefs(c).length);
          if ((ei > 0 && eo == 0) || (xi > 0 && xo == 0)) {
            lines.add(ImpactLine(e.name, 'chain', "its ${ei > 0 && eo == 0 ? 'entry' : 'exit'} is left with no servers — won't connect until you select another", 'bad',
                aKind: 'chain', aId: id, aTo: 'none'));
          } else if (eo < ei || xo < xi) {
            lines.add(ImpactLine(
                e.name,
                'chain',
                [
                  if (eo < ei) 'entry loses ${srv(ei - eo)}',
                  if (xo < xi) 'exit loses ${srv(xi - xo)}${c.exitMode == 'priority' ? ' (out of its priority order)' : ''}',
                ].join(', '),
                'warn'));
          }
          continue;
        }
        final (a, b) = both(() => unitRefs(id).length);
        final kind = profilesData.containsKey(id) ? 'profile' : 'entry';
        if (a > 0 && b == 0) {
          lines.add(ImpactLine(e.name, kind, "is left with no servers — won't connect until you select another", 'bad',
              aKind: kind == 'profile' ? 'profile' : null, aId: id, aTo: 'none'));
        } else if (b < a && profilesData.containsKey(id)) {
          lines.add(ImpactLine(e.name, kind, 'loses ${srv(a - b)} of $a', 'warn'));
        }
      }
    }
    return lines;
  }

  /// The whole "This will affect" list of deleting a source (`confirmDeleteSource`).
  List<ImpactLine> deleteSourceImpact(String sid) {
    final dead = {for (final c in chainsData.values) if (c.inId == sid || c.outId == sid) 'chain:${c.id}'};
    return [
      ...deleteImpact((r) => r.sid == sid, sid),
      ...targetImpact((t) => t == 'src:$sid' || t.startsWith('node:$sid::') || dead.contains(t)),
    ];
  }

  /// … of deleting one server (`confirmDeleteNode`).
  List<ImpactLine> deleteNodeImpact(String sid, String nid) => [
        ...deleteImpact((r) => r.sid == sid && r.node.id == nid),
        ...targetImpact((t) => t == 'node:$sid::$nid'),
      ];

  /// … of losing the servers [nids] of source [sid] (a provider's update, a switch-off): the same lists as deleting them.
  /// A rule's target of the whole source is gone too when none of its servers is left.
  List<ImpactLine> lostNodesImpact(String sid, Set<String> nids) {
    final s = sourcesData[sid];
    final all = s != null && liveNodes(s).every((n) => nids.contains(n.id));
    return [
      ...deleteImpact((r) => r.sid == sid && nids.contains(r.node.id)),
      ...targetImpact((t) => (all && t == 'src:$sid') || nids.any((n) => t == 'node:$sid::$n')),
    ];
  }

  /// [lines] as the `affected` of a journal event: `[{kind, id, name, to}]`, one per setting (a half-split app once).
  static List<Map<String, dynamic>> affectedOf(Iterable<ImpactLine> lines) {
    final out = <Map<String, dynamic>>[];
    for (final l in lines) {
      final kind = l.aKind;
      if (kind == null || out.any((a) => a['kind'] == kind && a['id'] == l.aId)) continue;
      out.add({'kind': kind, 'id': l.aId ?? '', 'name': l.aName ?? l.name, 'to': l.aTo ?? 'none'});
    }
    return out;
  }

  /// … of deleting a profile or a chain (`confirmDeleteEntry`). Deleting a profile moves the
  /// chains that use it to the first other profile (a chain left with the same profile on both
  /// ends is deleted).
  List<ImpactLine> deleteEntryImpact(String id) {
    final lines = <ImpactLine>[];
    if (connectEntry(id) == null) return lines;
    final dead = {'chain:$id', 'profile:$id'};
    if (profilesData.containsKey(id)) {
      final others = getProfileIds().where((x) => x != id).toList();
      final fb = others.isEmpty ? null : others.first; // none: the last profile goes, its chains with it
      for (final c in chainsData.values) {
        if (c.inId != id && c.outId != id) continue;
        final inId = c.inId == id ? fb : c.inId, outId = c.outId == id ? fb : c.outId;
        if (fb == null || inId == outId) {
          lines.add(ImpactLine(c.name, 'chain', 'is deleted with it', 'bad'));
          dead.add('chain:${c.id}');
        } else {
          lines.add(ImpactLine(c.name, 'chain', 'its ${c.inId == id ? 'entry' : 'exit'} moves to ${profilesData[fb]!.name}', 'warn'));
        }
      }
    }
    if (effectiveConnectId() == id) {
      lines.insert(0, const ImpactLine('Current connection', '', 'goes through it — will reconnect through the next entry', 'warn'));
    }
    return [...lines, ...targetImpact(dead.contains)];
  }
}
