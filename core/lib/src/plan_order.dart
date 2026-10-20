/// A Priority order changed in the app while connected (docs/connect-model.md → «Порядок Priority — вживую»): when the
/// plans differ only in the order of the servers inside Priority groups, the core re-orders those groups live (auto.dart)
/// and nothing restarts.
library;

import 'dart:convert';

import 'plan.dart';

/// [newPlan] against [oldPlan] (the plans the app sent to `connect`): null when they differ in anything but the order of
/// the servers inside Priority groups (another server set, a Fastest group's order, a pinned group's pick, any other
/// field); {} when they are equal; else {selector tag: the group's new server order} for each Priority group whose
/// order changed.
Map<String, List<String>>? priorityReorder(Map<String, dynamic> oldPlan, Map<String, dynamic> newPlan) {
  if (!_deepEq(_canon(_targetPicks(oldPlan)), _canon(_targetPicks(newPlan)))) return null;
  final before = _priorityGroups(oldPlan), after = _priorityGroups(newPlan);
  final out = <String, List<String>>{};
  for (final e in after.entries) {
    final was = before[e.key], keys = _keys(e.value);
    if (was != null && !_deepEq(_keys(was), keys)) out[e.key] = keys;
  }
  return out;
}

/// The Priority groups of [plan] by their selector tags (routes `route<i>` / `route<i>-entry`, rule targets `t` / `t>entry`).
Map<String, Map> _priorityGroups(Map<String, dynamic> plan) {
  final out = <String, Map>{};
  final rs = planRoutes(plan);
  for (var i = 0; i < rs.length; i++) {
    for (final (tag, g) in [(routeTag(i), rs[i]['main']), (routeEntryTag(i), rs[i]['entry'])]) {
      if (g is Map && g['pick'] == 'priority') out[tag] = g;
    }
  }
  for (final (tag, g) in planTargetGroups(plan)) {
    if (g['pick'] == 'priority') out[tag] = g;
  }
  return out;
}

List<String> _keys(Map g) => [for (final n in (g['nodes'] as List? ?? const [])) '${(n as Map)['key']}'];

/// [plan] with each rule target's Priority group carrying its effective pick (`chosen`, else its first server) and kept
/// as pinned, so [_canon] keeps it: a rule target's pick counts, only a new plan moves it (planSigOf's rule).
Map<String, dynamic> _targetPicks(Map<String, dynamic> plan) {
  final routing = plan['routing'], specs = routing is Map ? routing['targets'] : null;
  if (specs is! Map) return plan;
  Object? pick(Object? g) {
    if (g is! Map || g['pick'] != 'priority') return g;
    final ns = g['nodes'] as List? ?? const [], chosen = g['chosen'];
    final key = chosen != null && '$chosen'.isNotEmpty ? chosen : (ns.isNotEmpty ? (ns.first as Map)['key'] : null);
    return {...g.cast<String, dynamic>(), 'chosen': key, 'pinned': true};
  }

  final out = {
    for (final e in specs.entries)
      '${e.key}': e.value is Map
          ? {
              ...(e.value as Map).cast<String, dynamic>(),
              if (e.value['main'] is Map) 'main': pick(e.value['main']),
              if (e.value['entry'] is Map) 'entry': pick(e.value['entry']),
            }
          : e.value,
  };
  return {...plan, 'routing': {...(routing as Map).cast<String, dynamic>(), 'targets': out}};
}

/// [v] with every Priority group's servers in a fixed order (by their JSON text) and, unless pinned, its `chosen` left
/// out (a route group's; a rule target's is kept by [_targetPicks]): what remains must be the same in both plans.
Object? _canon(Object? v) {
  if (v is List) return [for (final x in v) _canon(x)];
  if (v is! Map) return v;
  final m = {for (final e in v.entries) '${e.key}': _canon(e.value)};
  if (m['pick'] == 'priority' && m['nodes'] is List) {
    m['nodes'] = [...(m['nodes'] as List)]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    if (m['pinned'] != true) m.remove('chosen');
  }
  return m;
}

bool _deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _deepEq(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
