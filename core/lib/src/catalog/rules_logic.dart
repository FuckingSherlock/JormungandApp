/// The Rules screen's logic, apart from the screen: condition groups, validation, a rule ⇄
/// sing-box JSON, the address test, the final order, Clash import / export, per-app and rule-set
/// helpers. Port of `40-rules.js`, `42-apps.js` and `75-rule-form.js` (docs/rules.md).
///
/// Results carry codes and structure, never sentences: the app puts its own (localised) words
/// on them. The English the functions do produce (`VAL_HINT`-style hints) is not here either.
library;

import 'dart:convert';

import '../conn_view.dart' show serviceApps;
import '../routing.dart' as core show adsDomains, ipToCidrs, lanSuffixes, regions, services;
import 'catalog.dart';
import 'impact.dart';
import 'json_util.dart';
import 'plan_builder.dart';
import 'rules_model.dart';

/* ───────────────────────────── condition groups ───────────────────────────── */

/// A value field of a condition card. [kind] picks the validator ([validRuleValue]).
class RuleField {
  const RuleField(this.key, this.placeholder, this.kind);

  final String key;
  final String placeholder;

  /// `suffix` | `domain` | `text` | `regex` | `name` | `ruleset` | `ip` | `port`.
  final String kind;
}

/// A field of a card that is picked from a fixed list (network, sniffed protocol).
class RuleChoice {
  const RuleChoice(this.key, this.options);

  final String key;
  final List<String> options;
}

/// A condition card: inside a field the values are OR, between cards AND; a card may be
/// negated ("except").
class RuleGroupDef {
  const RuleGroupDef(this.key, {this.fields = const [], this.choices = const [], this.flag, this.desktop = false});

  final String key;
  final List<RuleField> fields;
  final List<RuleChoice> choices;

  /// The key of the on / off field of the card (`ip_is_private`), if it has one.
  final String? flag;

  /// Only means something where sing-box sees process names (not on Android).
  final bool desktop;

  /// Every field the card can hold, in the order of the add menu: values, choices, the flag.
  List<String> get fieldKeys => [for (final f in fields) f.key, for (final c in choices) c.key, ?flag];
}

const ruleGroups = <RuleGroupDef>[
  RuleGroupDef('domain', fields: [
    RuleField('domain_suffix', 'google.com', 'suffix'),
    RuleField('domain', 'example.com', 'domain'),
    RuleField('domain_keyword', 'google', 'text'),
    RuleField('domain_regex', r'^.+\.ru$', 'regex'),
    RuleField('geosite', 'youtube', 'name'),
    RuleField('rule_set', 'ru-blocked', 'ruleset'),
  ]),
  RuleGroupDef('ip', fields: [
    RuleField('ip_cidr', '10.0.0.0/8, 1.1.1.1-1.1.1.9', 'ip'),
    RuleField('geoip', 'ru', 'name'),
  ], flag: 'ip_is_private'),
  RuleGroupDef('port', fields: [RuleField('port', '443, 8000-9000', 'port')]),
  RuleGroupDef('source', fields: [
    RuleField('source_ip_cidr', '192.168.1.0/24', 'ip'),
    RuleField('source_port', '5000-6000', 'port'),
  ]),
  RuleGroupDef('network', choices: [
    RuleChoice('network', ['tcp', 'udp']),
    RuleChoice('protocol', ['tls', 'http', 'quic', 'bittorrent', 'stun', 'dns']),
  ]),
  RuleGroupDef('process', desktop: true, fields: [RuleField('process', 'chrome.exe, /usr/bin/*', 'text')]),
];

RuleGroupDef ruleGroup(String key) => ruleGroups.firstWhere((g) => g.key == key);

/// Field key → the key of the card it lives on.
final Map<String, String> fieldGroup = {
  for (final g in ruleGroups)
    for (final f in [...g.fields.map((x) => x.key), ...g.choices.map((x) => x.key)]) f: g.key,
};

/// The validator kind of a value field (`null` for a choice / the flag).
String? fieldKind(String field) {
  for (final g in ruleGroups) {
    for (final f in g.fields) {
      if (f.key == field) return f.kind;
    }
  }
  return null;
}

/* ───────────────────────────── validation ───────────────────────────── */

int _ip2n(String s) => s.split('.').fold(0, (a, o) => a * 256 + int.parse(o));
bool _isIp4(String s) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s) && s.split('.').every((o) => int.parse(o) <= 255);

/// An IP, a CIDR (v4 or v6) or an IPv4 range (1.1.1.1-1.1.1.9).
bool isIpValue(String v) {
  if (v.contains(':')) {
    final p = v.split('/');
    return RegExp(r'^[0-9a-f:]+(/\d{1,3})?$', caseSensitive: false).hasMatch(v) && !((int.tryParse(p.length > 1 ? p[1] : '') ?? 0) > 128);
  }
  final r = v.split('-');
  if (r.length == 2) return _isIp4(r[0]) && _isIp4(r[1]) && _ip2n(r[0]) <= _ip2n(r[1]);
  final ap = v.split('/');
  if (ap.length > 2) return false;
  final p = ap.length > 1 ? ap[1] : null;
  return _isIp4(ap[0]) && (p == null || RegExp(r'^\d{1,2}$').hasMatch(p) && int.parse(p) <= 32);
}

/// `443` or `8000-9000`.
bool isPortValue(String v) {
  final m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(v);
  if (m == null) return false;
  final a = int.parse(m[1]!), b = m[2] == null ? a : int.parse(m[2]!);
  return a >= 1 && b <= 65535 && a <= b;
}

/// Is [v] right for a field of [kind] (`RuleField.kind`)? [ruleSetNames] = the names of Rules →
/// Rule sets, for kind `ruleset`.
bool validRuleValue(String kind, String v, {Iterable<String> ruleSetNames = const []}) {
  switch (kind) {
    case 'domain':
      return RegExp(r'^(\*\.)?([a-z0-9-]+\.)+[a-z0-9-]{2,}$', caseSensitive: false).hasMatch(v);
    case 'suffix':
      return RegExp(r'^\.?([a-z0-9-]+\.)*[a-z0-9-]+$', caseSensitive: false).hasMatch(v);
    case 'text':
      return !RegExp(r'\s').hasMatch(v);
    case 'regex':
      try {
        RegExp(v);
        return true;
      } on FormatException {
        return false;
      }
    case 'name':
      return RegExp(r'^[a-z0-9@!_-]+$', caseSensitive: false).hasMatch(v);
    case 'ruleset':
      return ruleSetNames.contains(v);
    case 'ip':
      return isIpValue(v);
    case 'port':
      return isPortValue(v);
  }
  return true;
}

/// What the values the user typed are checked against: split a typed / pasted text into values.
List<String> splitRuleValues(String text) => [
      for (final s in text.split(RegExp(r'[\n,;]+')))
        if (s.trim().isNotEmpty) s.trim(),
    ];

/* ───────────────────────────── a draft's groups ───────────────────────────── */

/// A fresh rule as the form starts it ("+ Add"): on, Proxy through the main flow, no groups.
UserRule newRule({Json? groups}) => UserRule(
      id: '',
      enabled: true,
      block: 'drop',
      fallbackTarget: '',
      dns: 'auto',
      groups: groups ?? Json(),
    );

/// The draft a "+ Add" opens: one empty Suffix field on the Domains card.
UserRule newRuleDraft() => newRule(groups: {
      'domain': {
        'not': false,
        'v': {'domain_suffix': <String>[]},
      },
    });

/// A copy to edit.
UserRule cloneRule(UserRule r) => UserRule.fromJson(r.toJson());

Json _g(UserRule r, String key) => asJson(r.groups?[key]);
Json _gv(Json g) => asJson(g['v']);

/// Does the card hold [field] (an empty list = added, not filled in yet)? The flag: `flag` is set.
bool groupHasField(Json? g, RuleGroupDef def, String field) {
  if (g == null) return false;
  return def.flag != null && field == def.flag ? g.containsKey('flag') : _gv(g).containsKey(field);
}

/// + Condition: puts [field] on its card (the card is made when it is not there yet).
void addRuleField(UserRule r, String group, String field) {
  final groups = r.groups ??= Json();
  final def = ruleGroup(group);
  final g = (groups[group] ??= {'not': false, 'v': <String, dynamic>{}}) as Map<String, dynamic>;
  if (def.flag != null && field == def.flag) {
    g['flag'] = true;
  } else {
    final v = (g['v'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    v[field] ??= <String>[];
  }
}

/// A field's x: the card goes with its last field.
void removeRuleField(UserRule r, String group, String field) {
  final g = r.groups?[group];
  if (g is! Map<String, dynamic>) return;
  final def = ruleGroup(group);
  if (def.flag != null && field == def.flag) {
    g.remove('flag');
  } else {
    (g['v'] as Map?)?.remove(field);
  }
  if (_gv(g).isEmpty && !g.containsKey('flag')) r.groups!.remove(group);
}

List<String> ruleFieldValues(UserRule r, String group, String field) => strList(_gv(_g(r, group))[field]);

/// Sets the values of a field (a list is stored as `List<String>`).
void setRuleFieldValues(UserRule r, String group, String field, List<String> values) {
  final g = r.groups?[group];
  if (g is! Map<String, dynamic>) return;
  (g['v'] ??= <String, dynamic>{});
  (g['v'] as Map)[field] = values;
}

/// Adds typed / pasted values to a field (no duplicates).
void addRuleValues(UserRule r, String group, String field, String text) {
  final list = ruleFieldValues(r, group, field);
  for (final v in splitRuleValues(text)) {
    if (!list.contains(v)) list.add(v);
  }
  setRuleFieldValues(r, group, field, list);
}

/// A chip's text edited in place: [text] may be a list (replaces the chip with those values).
void replaceRuleValue(UserRule r, String group, String field, int index, String text) {
  final list = ruleFieldValues(r, group, field);
  if (index < 0 || index >= list.length) return;
  final old = list[index];
  final parts = splitRuleValues(text);
  list.replaceRange(index, index + 1, [for (final v in parts) if (!list.contains(v) || v == old) v]);
  setRuleFieldValues(r, group, field, [for (final (k, v) in list.indexed) if (list.indexOf(v) == k) v]);
}

/// Does the rule match on the destination IP: IP / CIDR, local networks, GeoIP; a JSON rule: any
/// of those keys anywhere inside. Own rule sets are not looked into.
bool ruleHasIpCondition(UserRule d) {
  bool inJson(Object? o) {
    if (o is List) return o.any(inJson);
    if (o is Map) {
      return o.entries.any((e) =>
          e.key == 'ip_cidr' ||
          e.key == 'ip_is_private' ||
          e.key == 'geoip' ||
          (e.key == 'rule_set' && (e.value is List ? e.value as List : [e.value]).any((t) => '$t'.startsWith('geoip-'))) ||
          inJson(e.value));
    }
    return false;
  }

  if (d.composite != null) return inJson(d.composite);
  final g = d.groups?['ip'];
  if (g is! Map) return false;
  final v = _gv(asJson(g));
  return truthy(g['flag']) || strList(v['ip_cidr']).isNotEmpty || strList(v['geoip']).isNotEmpty;
}

/* ───────────────────────────── rule ⇄ sing-box JSON ───────────────────────────── */

/// One card as the keys of a flat sing-box rule.
Json groupJson(Json d) {
  final o = <String, dynamic>{};
  for (final e in _gv(d).entries) {
    final f = e.key, list = strList(e.value);
    if (list.isEmpty) continue;
    if (f == 'port' || f == 'source_port') {
      final one = [for (final v in list) if (!v.contains('-')) ?int.tryParse(v)];
      final rng = [for (final v in list) if (v.contains('-')) v.replaceFirst('-', ':')];
      if (one.isNotEmpty) o[f] = one;
      if (rng.isNotEmpty) o['${f}_range'] = rng;
    } else if (f == 'ip_cidr' || f == 'source_ip_cidr') {
      o[f] = [
        for (final v in list)
          if (RegExp(r'^[\d.]+-[\d.]+$').hasMatch(v) && isIpValue(v)) ...(core.ipToCidrs(v) ?? [v]) else v,
      ];
    } else if (f == 'process') {
      final paths = [for (final v in list) if (RegExp(r'[\\/]').hasMatch(v)) v];
      final names = [for (final v in list) if (!RegExp(r'[\\/]').hasMatch(v)) v];
      if (names.isNotEmpty) o['process_name'] = names;
      if (paths.isNotEmpty) o['process_path'] = paths;
    } else {
      o[f] = [...list];
    }
  }
  if (truthy(d['flag'])) o['ip_is_private'] = true;
  return o;
}

/// What a target is called in JSON and Clash text: `kind:name`, or `proxy` for the main flow.
String targetName(Catalog c, String t) {
  final i = c.targetInfo(t);
  return i.gone ? 'deleted ${i.kind}' : i.name;
}

String targetTag(Catalog c, String t) => t.isEmpty ? 'proxy' : '${c.targetInfo(t).kind}:${targetName(c, t)}';

/// Every target the picker offers, in its order (for a JSON import: outbound tag → target).
List<String> allTargets(Catalog c) => [
      '',
      for (final sid in c.sourceOrder) ...['src:$sid', for (final n in c.sourcesData[sid]?.nodes ?? const []) 'node:$sid::${n.id}'],
      for (final id in c.getProfileIds()) 'profile:$id',
      for (final id in c.chainsData.keys) 'chain:$id',
    ];

Json actionJson(Catalog c, UserRule r) {
  if (r.action == 'block') return {'action': 'reject', 'method': (r.block ?? 'drop') == 'drop' ? 'drop' : 'default'};
  return {'action': 'route', 'outbound': r.action == 'direct' ? 'direct' : targetTag(c, r.target)};
}

/// The rule as a sing-box route rule (the JSON tab, the export). A negated card, or Domains
/// together with IP (sing-box ORs those inside one rule), makes it a logical AND.
Json ruleJson(Catalog c, UserRule r) {
  if (r.composite != null) return asJson(deepCopy(r.composite));
  final groups = r.groups ?? Json();
  // an empty card says nothing: no JSON for it (a {} inside the logical rule would not read back)
  final gs = [
    for (final g in ruleGroups)
      if (groups[g.key] is Map && groupJson(asJson(groups[g.key])).isNotEmpty) asJson(groups[g.key]),
  ];
  final Json body;
  if (gs.any((d) => truthy(d['not'])) || (groups['domain'] != null && groups['ip'] != null)) {
    body = {
      'type': 'logical',
      'mode': 'and',
      'rules': [for (final d in gs) {...groupJson(d), if (truthy(d['not'])) 'invert': true}],
    };
  } else {
    body = {for (final d in gs) ...groupJson(d)};
  }
  return {...body, ...actionJson(c, r), ...asJson(deepCopy(r.extra))};
}

Json _keysToGroups(Json o, Json extra) {
  final groups = <String, dynamic>{};
  Json card(String k) => (groups[k] ??= {'not': false, 'v': <String, dynamic>{}}) as Json;
  void put(String f, List<String> vals) {
    final v = card(fieldGroup[f]!)['v'] as Json;
    v[f] = [...strList(v[f]), ...vals];
  }

  for (final e in o.entries) {
    final k = e.key, v = e.value;
    final list = [for (final x in v is List ? v : [v]) '$x'];
    if (fieldGroup.containsKey(k)) {
      put(k, list);
    } else if (k == 'port_range' || k == 'source_port_range') {
      put(k.replaceFirst('_range', ''), [for (final x in list) x.replaceFirst(':', '-')]);
    } else if (k == 'process_name' || k == 'process_path') {
      put('process', list);
    } else if (k == 'ip_is_private') {
      card('ip')['flag'] = truthy(v);
    } else {
      extra[k] = v;
    }
  }
  return groups;
}

/// A JSON rule the form cannot read: [code] `notObject`.
class RuleJsonError implements Exception {
  RuleJsonError(this.code, {this.line, this.detail = ''});

  /// `notObject` | `syntax`.
  final String code;

  /// For `syntax`: the line of the text (1-based) and the parser's words.
  final int? line;
  final String detail;

  @override
  String toString() => code == 'syntax' ? (line != null ? 'Line $line: $detail' : detail) : code;
}

/// A sing-box rule → a rule of the form. Keys the form does not know are kept as `extra`; any
/// other logical rule is `composite` (edited in JSON only).
UserRule ruleFromJson(Catalog c, Object? o) {
  if (o is! Map) throw RuleJsonError('notObject');
  final rest = asJson(o);
  final action = rest.containsKey('action') ? rest.remove('action') : 'route';
  final outbound = rest.remove('outbound');
  final method = rest.remove('method');
  final r = newRule();
  if (action == 'reject') {
    r.action = 'block';
    r.block = method == 'drop' ? 'drop' : 'reject';
  } else if (action == 'route') {
    if (outbound == 'direct') {
      r.action = 'direct';
    } else {
      r.action = 'proxy';
      r.target = allTargets(c).firstWhere((t) => targetTag(c, t) == outbound, orElse: () => '');
    }
  } else {
    rest['action'] = action;
  }
  final extra = <String, dynamic>{};
  if (rest['type'] == 'logical') {
    final subs = rest['rules'] is List ? rest['rules'] as List : const [];
    final simple = rest['mode'] == 'and' &&
        rest.keys.every((k) => const ['type', 'mode', 'rules'].contains(k)) &&
        subs.every((s) => s is Map && !truthy(s['type']));
    final parts = <(Json, Object?, Json)>[];
    if (simple) {
      for (final s in subs) {
        final keys = asJson(s), invert = keys.remove('invert'), x = <String, dynamic>{};
        parts.add((_keysToGroups(keys, x), invert, x));
      }
    }
    final keys = [for (final p in parts) p.$1.keys.toList()];
    // each part must be exactly one card, no unknown keys, cards not repeated
    if (simple &&
        keys.every((k) => k.length == 1) &&
        keys.expand((k) => k).toSet().length == keys.length &&
        parts.every((p) => p.$3.isEmpty)) {
      for (final (g, inv, _) in parts) {
        final k = g.keys.first;
        r.groups![k] = {...asJson(g[k]), 'not': truthy(inv)};
      }
    } else {
      r.composite = {...rest, ...actionJson(c, r)};
    }
  } else {
    r.groups = _keysToGroups(rest, extra);
    if (truthy(extra['invert'])) {
      final ks = r.groups!.keys.toList();
      if (ks.length == 1) {
        (r.groups![ks[0]] as Json)['not'] = true;
        extra.remove('invert');
      }
    }
  }
  if (extra.isNotEmpty) r.extra = extra;
  return r;
}

/// A JSON syntax error as a line and the parser's own words.
RuleJsonError jsonSyntaxError(String text, FormatException e) {
  final off = e.offset;
  final line = off != null ? text.substring(0, off.clamp(0, text.length)).split('\n').length : null;
  var msg = e.message.split('\n').first.replaceAll(RegExp(r'\s*\(at (line|character).*$'), '').trim();
  if (msg.isEmpty) msg = 'invalid JSON';
  return RuleJsonError('syntax', line: line, detail: msg);
}

/// The JSON of a rule as text. A text that does not parse or is not a rule throws [RuleJsonError].
UserRule ruleFromJsonText(Catalog c, String text) {
  Object? o;
  try {
    o = jsonDecode(text);
  } on FormatException catch (e) {
    throw jsonSyntaxError(text, e);
  }
  return ruleFromJson(c, o);
}

/// Several rules in one text (an array, or one object): the import.
List<UserRule> parseJsonRules(Catalog c, String text) {
  Object? o;
  try {
    o = jsonDecode(text);
  } on FormatException catch (e) {
    throw jsonSyntaxError(text, e);
  }
  return [for (final x in o is List ? o : [o]) ruleFromJson(c, x)];
}

/// JSON tab → draft: keeps what the JSON has no place for (the name, Fallback, DNS, enabled, the
/// ipTunOnly flag, the target of a non-Proxy action…) and the cards / fields the form had added but
/// not filled yet. [parsed] is [ruleFromJsonText] of the tab, [old] the draft before it.
UserRule applyJsonToDraft(UserRule parsed, UserRule old) {
  final r = parsed;
  final json = (UserRule.fromJson({...r.toJson(), 'id': old.id}))
    ..name = old.name
    ..enabled = old.enabled
    ..fallback = old.fallback
    ..fallbackTarget = old.fallbackTarget
    ..dns = old.dns
    ..ipTunOnly = old.ipTunOnly;
  if (json.action != 'proxy') json.target = old.target;
  if (json.action != 'block') json.block = old.block;
  // cards and fields not filled yet are not in the JSON: keep them as the form had them
  if (json.composite == null) {
    json.groups ??= Json();
    for (final e in (old.groups ?? Json()).entries) {
      final g = asJson(e.value), v = _gv(g);
      final n0 = json.groups![e.key] is Map ? asJson(json.groups![e.key]) : null;
      final empty = [for (final f in v.keys) if (strList(v[f]).isEmpty && !(n0 != null && _gv(n0).containsKey(f))) f];
      final flagOff = g['flag'] == false && !(n0 != null && n0.containsKey('flag'));
      if (empty.isEmpty && !flagOff) continue;
      final n = n0 ?? {'not': g['not'], 'v': <String, dynamic>{}};
      n['v'] ??= <String, dynamic>{};
      for (final f in empty) {
        (n['v'] as Map)[f] = <String>[];
      }
      if (flagOff) n['flag'] = false;
      json.groups![e.key] = n;
    }
  }
  return json;
}

/* ───────────────────────────── saving a rule ───────────────────────────── */

/// Why a rule cannot be saved: `invalidValues` | `noConditions`.
enum RuleProblem { invalidValues, noConditions }

extension RulesOps on Catalog {
  /// The names of Rules → Rule sets (for the validator of a `rule_set` field).
  List<String> get ruleSetNames => [for (final s in ruleSets) s.name];

  /// Checks and tidies a draft (empty fields and cards go, Fallback only for Proxy, the
  /// "target" of a fallback differs from the route's), then stores it: [editing] replaces the rule
  /// of that id, else it is added at the end. Returns what stopped it, or null.
  RuleProblem? saveRule(UserRule d, {String? editing}) {
    final problem = _tidyDraft(d);
    if (problem != null) return problem;
    final next = editing != null && rulesData.containsKey(editing) ? editing : null;
    final id = next ?? 'r${ruleSeq++}';
    final saved = UserRule.fromJson({...d.toJson(), 'id': id});
    rulesData[id] = saved;
    if (next == null) ruleOrder.add(id);
    return null;
  }

  /// The checks and tidying [saveRule] and [saveAppRule] share; null = the draft is fine.
  RuleProblem? _tidyDraft(UserRule d) {
    if (d.composite == null) {
      final groups = d.groups ??= Json();
      for (final g in groups.values) {
        for (final e in _gv(asJson(g)).entries) {
          final kind = fieldKind(e.key);
          if (kind != null && strList(e.value).any((v) => !validRuleValue(kind, v, ruleSetNames: ruleSetNames))) {
            return RuleProblem.invalidValues;
          }
        }
      }
      for (final g in groups.values) {
        final v = (g as Map)['v'];
        if (v is Map) v.removeWhere((_, list) => list is List && list.isEmpty);
      }
      groups.removeWhere((_, g) => g is! Map || (_gv(asJson(g)).isEmpty && !truthy(g['flag'])));
      if (groups.isEmpty) return RuleProblem.noConditions;
    }
    if (d.action != 'proxy') d.fallback = 'default'; // Fallback only means something for Proxy
    if (d.fallback != 'main' || d.fallbackTarget == d.target) d.fallbackTarget = '';
    if (!ruleHasIpCondition(d) || !d.ipTunOnly) d.ipTunOnly = false;
    return null;
  }

  void deleteRule(String id) {
    rulesData.remove(id);
    ruleOrder.remove(id);
  }

  /// Rules imported from JSON / Clash go to the end of the list.
  void addRules(List<UserRule> rules) {
    for (final r in rules) {
      final id = 'r${ruleSeq++}';
      rulesData[id] = UserRule.fromJson({...r.toJson(), 'id': id});
      ruleOrder.add(id);
    }
  }

  /// A service's state (`default` = not added) (Rules → Services).
  void setService(String key, String v) => quickCfg.services[key] = v;

  /// Rules and apps whose route a rule set the list names is used by: positions (1-based) of the
  /// rules that use [name] in Domains → Rule set.
  List<int> ruleSetUsers(String name) => [
        for (final (i, id) in ruleOrder.indexed)
          if (strList(_gv(_g(rulesData[id] ?? UserRule(id: id), 'domain'))['rule_set']).contains(name)) i + 1,
      ];

  /// `name` | `nameTaken` | `url`, or null: the rule set form's checks.
  String? ruleSetProblem(RuleSetCfg d, {String? editing}) {
    if (d.builtin) return null;
    if (!RegExp(r'^[a-z0-9_-]+$', caseSensitive: false).hasMatch(d.name)) return 'name';
    if (ruleSets.any((s) => s.name == d.name && s.id != editing)) return 'nameTaken';
    if (!RegExp(r'^https?://\S+$').hasMatch(d.url ?? '')) return 'url';
    return null;
  }

  /// Stores a checked rule set: [editing] replaces that one, else a new id.
  void saveRuleSet(RuleSetCfg d, {String? editing}) {
    if (editing != null) {
      final i = ruleSets.indexWhere((s) => s.id == editing);
      if (i >= 0) {
        ruleSets[i] = RuleSetCfg.fromJson({...d.toJson(), 'id': editing});
        return;
      }
    }
    ruleSets.add(RuleSetCfg.fromJson({...d.toJson(), 'id': 'rs${rsSeq++}'}));
  }

  void deleteRuleSet(String id) => ruleSets.removeWhere((s) => s.id == id);
}

/* ───────────────────────────── per-app routing ───────────────────────────── */

/// An app's rule is only a draft until saved: [AppRule] as the dialog edits it.
AppRule cloneApp(AppRule? a) => a == null ? AppRule() : AppRule.fromJson(a.toJson());

/// An app has nothing of its own unless every half is Default with no Fallback and it has no rules.
bool appIsDefault(AppRule a) => a.rules.isEmpty && a.halves.every((h) => h.$2.act == 'default' && h.$2.fallback == 'default');

/// The colour class of an app row: the one action, or the first half that is not Default.
String appStateAct(AppRule a) {
  for (final (_, h) in a.halves) {
    if (h.act != 'default') return h.act;
  }
  return a.tcp.act;
}

extension AppRulesOps on Catalog {
  /// The package of the app that overrides service [key] for its own app, or null.
  String? appOfService(String key) {
    // a service's own app is matched earlier by Apps, so an app rule wins for that app's traffic
    for (final p in serviceApps[key] ?? const <String>[]) {
      if (appRules.containsKey(p)) return p;
    }
    return null;
  }

  /// Saves the dialog's draft: an app left on Default is not stored. [label] (the app's name) is
  /// kept with the rule, so the name shows where the installed list is not at hand.
  void saveApp(String pkg, AppRule draft, {String label = ''}) {
    if (appIsDefault(draft)) {
      appRules.remove(pkg);
      return;
    }
    final a = AppRule.fromJson(draft.toJson());
    if (!a.split) a.udp = AppHalf(); // the UDP half only lives while Split is on
    if (label.isNotEmpty && label != pkg) a.unknown['name'] = label;
    appRules[pkg] = a;
  }

  /// Checks and stores a rule of app [app] like [saveRule] (but the `process` card goes: the app
  /// is the condition): [editing] replaces that rule of the app, else it is added at the end of the
  /// app's list. An app that has none yet is made (default route). Returns what stopped it, or null.
  RuleProblem? saveAppRule(String app, UserRule d, {String? editing}) {
    d.groups?.remove('process');
    final problem = _tidyDraft(d);
    if (problem != null) return problem;
    final a = appRules.putIfAbsent(app, () => AppRule());
    final at = editing == null ? -1 : a.rules.indexWhere((r) => r.id == editing);
    if (at >= 0) {
      a.rules[at] = UserRule.fromJson({...d.toJson(), 'id': editing});
    } else {
      a.rules.add(UserRule.fromJson({...d.toJson(), 'id': _newAppRuleId()}));
    }
    return null;
  }

  String _newAppRuleId() {
    final used = {for (final a in appRules.values) for (final r in a.rules) r.id};
    var id = 'ar${appRuleSeq++}';
    while (used.contains(id)) {
      id = 'ar${appRuleSeq++}';
    }
    return id;
  }

  /// Removes a rule of [app]; an app left with the default route and no rules is no longer stored.
  void deleteAppRule(String app, String id) {
    final a = appRules[app];
    if (a == null) return;
    a.rules.removeWhere((r) => r.id == id);
    if (appIsDefault(a)) appRules.remove(app);
  }

  /// Moves a rule of [app] from index [from] to [to] (the index it has after the move).
  void moveAppRule(String app, int from, int to) {
    final list = appRules[app]?.rules;
    if (list == null || from < 0 || from >= list.length) return;
    list.insert(to.clamp(0, list.length - 1), list.removeAt(from));
  }

  UserRule? appRuleById(String app, String id) {
    for (final r in appRules[app]?.rules ?? const <UserRule>[]) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The name of an app: the installed list's (through [appInfo]), else the label kept with the
  /// rule, else the package.
  String appLabel(String pkg) {
    final n = appInfo?.call(pkg)?.name;
    if (n != null && n.isNotEmpty) return n;
    final kept = appRules[pkg]?.unknown['name'];
    return kept is String && kept.isNotEmpty ? kept : pkg;
  }
}

/* ───────────────────────────── the address test ───────────────────────────── */

const _privateNets = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16'];

bool _inCidr(String ip, String c) {
  if (c.contains('-')) {
    final p = c.split('-');
    return _ip2n(ip) >= _ip2n(p[0]) && _ip2n(ip) <= _ip2n(p[1]);
  }
  final p = c.split('/'), a = p[0], bits = p.length > 1 ? int.tryParse(p[1]) ?? 32 : 32;
  final size = 1 << (32 - bits);
  return _ip2n(ip) ~/ size == _ip2n(a) ~/ size;
}

bool _onDomain(String host, String d) => host == d || host.endsWith('.$d');

/// What the test knows of an address: [ip] (dotted IPv4) or a name.
class _Target {
  _Target(this.host, this.port) : ip = _isIp4(host);

  final String host;
  final int port;
  final bool ip;
}

/// A card against the address: true / false, null = cannot be judged from host:port (rule sets,
/// GeoIP, source, process, a name for an IP condition…).
bool? _cardMatches(String key, Json d, _Target t) {
  final v = _gv(d);
  List<String> f(String x) => strList(v[x]);
  if (v.keys.any((k) => (k == 'rule_set' || k == 'geoip') && f(k).isNotEmpty)) return null;
  bool? m;
  switch (key) {
    case 'domain':
      if (t.ip) return null;
      m = f('domain').any((x) => x.startsWith('*.') ? _onDomain(t.host, x.substring(2)) : t.host == x) ||
          f('domain_suffix').any((x) => _onDomain(t.host, x.replaceFirst(RegExp(r'^\.'), ''))) ||
          f('domain_keyword').any(t.host.contains) ||
          f('domain_regex').any((x) {
            try {
              return RegExp(x).hasMatch(t.host);
            } on FormatException {
              return false;
            }
          }) ||
          f('geosite').any((x) => (core.services[x]?.domains ?? const <String>[]).any((h) => _onDomain(t.host, h)));
    case 'ip':
      if (!t.ip) return null;
      m = f('ip_cidr').any((x) => !x.contains(':') && isIpValue(x) && _inCidr(t.host, x)) ||
          (truthy(d['flag']) && _privateNets.any((c) => _inCidr(t.host, c)));
    case 'port':
      m = f('port').any((x) {
        final p = x.split('-'), a = int.tryParse(p[0]), b = p.length > 1 ? int.tryParse(p[1]) : a;
        return a != null && b != null && t.port >= a && t.port <= b;
      });
    case 'network':
      m = (f('network').isEmpty || f('network').contains('tcp')) && (f('protocol').isEmpty || f('protocol').contains(t.port == 443 ? 'tls' : 'http'));
    default:
      return null;
  }
  return truthy(d['not']) ? !m : m;
}

/// How an address was caught. [kind]: `app` (an app of that name / package; [app] its rule, null =
/// none), `local` (always direct), `rule` ([rule] with its 1-based [index]), `ads`, `service`
/// ([key]), `region` ([key] = the region code), `final`. [act] is `proxy` | `direct` | `block`
/// (`mixed` never here), [target] the Via of a Proxy rule.
class RuleTest {
  const RuleTest(this.kind, {this.index = 0, this.rule, this.key = '', this.act = '', this.target = '', this.appName = '', this.app});

  final String kind;
  final int index;
  final UserRule? rule;
  final String key;
  final String act;
  final String target;
  final String appName;
  final AppRule? app;
}

/// Which rule catches [raw] (a domain, an IP with `:port`, or an app name / package of [apps]).
/// A light judge with today's settings: a rule it cannot judge from host:port alone is left out, so
/// it can miss a rule, never invent one. null = nothing typed.
RuleTest? testAddress(Catalog c, String raw, {List<({String pkg, String name})> apps = const []}) {
  final s = raw.trim().toLowerCase().replaceFirst(RegExp(r'^\w+://'), '').split('/').first;
  if (s.isEmpty) return null;
  for (final a in apps) {
    if (a.name.toLowerCase() == s || a.pkg == s) {
      final r = c.appRules[a.pkg];
      return RuleTest('app', appName: a.name, app: r);
    }
  }
  final parts = s.split(':');
  final host = parts[0], port = parts.length > 1 ? int.tryParse(parts[1]) ?? 443 : 443;
  final t = _Target(host, port);
  if (t.ip ? _privateNets.any((n) => _inCidr(host, n)) : core.lanSuffixes.any((d) => _onDomain(host, d))) {
    return const RuleTest('local', act: 'direct');
  }
  for (final (i, id) in c.ruleOrder.indexed) {
    final r = c.rulesData[id];
    if (r == null || !r.enabled || r.composite != null) continue;
    final gs = (r.groups ?? Json()).entries.toList();
    if (gs.isEmpty) continue;
    if (gs.every((e) => _cardMatches(e.key, asJson(e.value), t) == true)) {
      return RuleTest('rule', index: i + 1, rule: r, act: r.action, target: r.action == 'proxy' ? r.target : '');
    }
  }
  if (c.quickCfg.ads && core.adsDomains.any((d) => _onDomain(host, d))) return const RuleTest('ads', act: 'block');
  for (final e in core.services.entries) {
    final v = c.quickCfg.services[e.key];
    if (v != null && v != 'default' && e.value.domains.any((d) => _onDomain(host, d))) {
      return RuleTest('service', key: e.key, act: v == 'vpn' ? 'proxy' : 'direct');
    }
  }
  final reg = core.regions[c.quickCfg.region];
  if (c.quickCfg.regionOn && !t.ip && reg != null && reg.tlds.any((tld) => host.endsWith('.$tld'))) {
    return RuleTest('region', key: c.quickCfg.region, act: 'direct');
  }
  return RuleTest('final', act: c.quickCfg.finalAction);
}

/* ───────────────────────────── the final order ───────────────────────────── */

/// One line of "Final order": [kind] `lan` | `apps` ([count]) | `rule` ([rule]) | `ads` | `service`
/// ([key]) | `region` ([key]) | `final`. [act]: `proxy` | `direct` | `block` | `mixed`.
class FinalRow {
  const FinalRow(this.kind, this.act, {this.rule, this.count = 0, this.key = '', this.target = ''});

  final String kind;
  final String act;
  final UserRule? rule;
  final int count;
  final String key;
  final String target;
}

/// The list exactly as the engine checks it (docs/rules.md: local networks, apps, own rules, ads,
/// services, region, everything else).
List<FinalRow> effectiveRules(Catalog c) => [
      const FinalRow('lan', 'direct'),
      if (c.appRules.isNotEmpty) FinalRow('apps', 'mixed', count: c.appRules.length),
      for (final id in c.ruleOrder)
        if (c.rulesData[id]?.enabled == true)
          FinalRow('rule', c.rulesData[id]!.action, rule: c.rulesData[id], target: c.rulesData[id]!.action == 'proxy' ? c.rulesData[id]!.target : ''),
      if (c.quickCfg.ads) const FinalRow('ads', 'block'),
      for (final k in core.services.keys)
        if (c.quickCfg.services[k] != null && c.quickCfg.services[k] != 'default') FinalRow('service', c.quickCfg.services[k] == 'vpn' ? 'proxy' : 'direct', key: k),
      if (c.quickCfg.regionOn) FinalRow('region', 'direct', key: c.quickCfg.region),
      FinalRow('final', c.quickCfg.finalAction),
    ];

/* ───────────────────────────── Clash rules ───────────────────────────── */

const _clashTypes = {
  'domain': 'DOMAIN',
  'domain_suffix': 'DOMAIN-SUFFIX',
  'domain_keyword': 'DOMAIN-KEYWORD',
  'domain_regex': 'DOMAIN-REGEX',
  'geosite': 'GEOSITE',
  'ip_cidr': 'IP-CIDR',
  'geoip': 'GEOIP',
  'port': 'DST-PORT',
  'source_ip_cidr': 'SRC-IP-CIDR',
  'source_port': 'SRC-PORT',
  'process': 'PROCESS-NAME',
};

String _clashOut(Catalog c, UserRule r) => r.action == 'direct'
    ? 'DIRECT'
    : r.action == 'block'
        ? 'REJECT'
        : r.target.isNotEmpty
            ? targetName(c, r.target)
            : 'PROXY';

/// The rules as Clash lines (`TYPE,value,POLICY`). A rule Clash's one-type lines cannot hold (a
/// composite, several cards, "except", local networks) is a comment line naming it.
String exportClashRules(Catalog c) => [
      for (final id in c.ruleOrder)
        if (c.rulesData[id] case final r?) _clashLines(c, r),
    ].join('\n');

String _clashLines(Catalog c, UserRule r) {
  final gs = (r.groups ?? Json()).entries.toList();
  List<MapEntry<String, dynamic>>? vals;
  if (gs.length == 1 && !truthy(asJson(gs[0].value)['not']) && !truthy(asJson(gs[0].value)['flag'])) {
    vals = [for (final e in _gv(asJson(gs[0].value)).entries) if (_clashTypes.containsKey(e.key)) e];
  }
  if (r.composite != null || vals == null || vals.length != _gv(asJson(gs[0].value)).length) {
    return '# skipped (only sing-box JSON can hold it): ${ruleTitle(r)}';
  }
  return [
    for (final e in vals)
      for (final v in strList(e.value)) '${_clashTypes[e.key]},$v,${_clashOut(c, r)}',
  ].join('\n');
}

/// A Clash line that is not `TYPE,value,POLICY` (1-based [line] among the lines that count).
class ClashLineError implements Exception {
  ClashLineError(this.line);

  final int line;

  @override
  String toString() => 'Line $line: expected TYPE,value,POLICY';
}

/// Clash rules → rules; `MATCH,POLICY` (the catch-all) is [finalAction] (Everything else), not a rule.
({List<UserRule> rules, String? finalAction}) parseClashRules(Catalog c, String text) {
  final byType = {for (final e in _clashTypes.entries) e.value: e.key};
  final lines = [
    for (final l in text.split('\n'))
      if (l.trim().isNotEmpty && !l.trim().startsWith('#')) l.trim(),
  ];
  String? match;
  for (final l in lines) {
    if (RegExp(r'^MATCH,', caseSensitive: false).hasMatch(l)) {
      match = l;
      break;
    }
  }
  String? fin;
  if (match != null) {
    final p = match.split(',')[1].trim().toUpperCase();
    fin = p == 'DIRECT'
        ? 'direct'
        : p == 'REJECT'
            ? 'block'
            : 'proxy';
  }
  final rules = <UserRule>[];
  final rest = [for (final l in lines) if (l != match) l];
  for (final (i, l) in rest.indexed) {
    final p = [for (final s in l.split(',')) s.trim()];
    final type = p.isNotEmpty ? p[0] : '', value = p.length > 1 ? p[1] : '', pol = p.length > 2 ? p[2] : '';
    final f = byType[type.toUpperCase()] ?? (type == 'IP-CIDR6' ? 'ip_cidr' : null);
    if (f == null || value.isEmpty || pol.isEmpty) throw ClashLineError(i + 1);
    final P = pol.toUpperCase();
    rules.add(newRule(groups: {
      fieldGroup[f]!: {
        'not': false,
        'v': {f: [value]},
      },
    })
      ..action = P == 'DIRECT'
          ? 'direct'
          : P == 'REJECT'
              ? 'block'
              : 'proxy');
  }
  return (rules: rules, finalAction: fin);
}

/// The rules as sing-box JSON text (the export).
String exportRulesJson(Catalog c) =>
    const JsonEncoder.withIndent('  ').convert([for (final id in c.ruleOrder) if (c.rulesData[id] case final r?) ruleJson(c, r)]);
