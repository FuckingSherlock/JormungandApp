/// Which of the user's rules a sing-box connection went by.
///
/// sing-box tells each connection the rule it matched only as that rule's `String()`
/// (`domain_suffix=[googlevideo.com] network=tcp`: the conditions, no action, no index, the
/// lists cut to their first 3 values). So the core keeps, when it builds the config, the same
/// text for every route rule it generates ([ruleText] follows sing-box's `route/rule` items,
/// pinned to the release in tool/bin) with the rule's origin ([RuleOrigin]: the user's rule,
/// an app, a service, a quick rule, or the core's own), and looks a connection's text up in
/// it ([RuleNames.of], used by traffic.dart).
library;

import 'dart:convert';

/// Where a generated route rule came from.
class RuleOrigin {
  const RuleOrigin(this.kind, this.name, {this.id = '', this.app = ''});

  /// The app's key for an `appRule`; '' = none.
  final String app;

  /// `user` (Rules → own rule), `app` (per-app route rule), `appRule` (one of an app's own rules, [app] +
  /// [id] = the rule's id), `service` (Rules → Services), `quick`
  /// (Block ads, My region direct) or `system` (the core's own: private networks, its checks).
  final String kind;

  /// Readable: the rule's / app's / service's name; a system rule's English title.
  final String name;

  /// The rule's id, the app's id, the service key or the system rule's slug; '' = none.
  final String id;
}

/// Route rule text → origin, in the order of the config's rules.
class RuleNames {
  final _byText = <String, List<({RuleOrigin origin, String key})>>{};

  /// Registers [rule] (a sing-box route rule as generated) as coming from [origin]. A rule whose
  /// text cannot be worked out (a condition this file does not know) or is empty (matches
  /// everything: sniff, resolve, a bare reject) is left out.
  void add(Map<String, dynamic> rule, RuleOrigin origin) {
    final text = ruleText(rule);
    if (text == null || text.isEmpty) return;
    _byText.putIfAbsent(text, () => []).add((origin: origin, key: jsonEncode(_conditionsOf(rule))));
  }

  /// The origin of the rule sing-box reported as [text]; null = unknown, or two rules with
  /// different conditions have this text (their lists are cut alike): better none than a wrong one.
  /// Rules with the same conditions and another action are the same to the traffic: the first
  /// of them is the one sing-box used.
  RuleOrigin? of(String text) {
    final l = _byText[text];
    if (l == null || l.isEmpty) return null;
    return l.every((e) => e.key == l.first.key) ? l.first.origin : null;
  }

  bool get isEmpty => _byText.isEmpty;
}

/// The rule a connection went by, for an event's data (`site/blocked`, `site/unreachable`):
/// `{kind: user | app | service | quick | system, name, id?}` as [RuleNames] knows it; `{kind: final}`
/// when no rule matched ([text] empty: the main flow); `{kind: unknown, text}` for a rule this cannot name.
Map<String, dynamic> ruleEventData(RuleNames? names, String text) {
  if (text.isEmpty) return {'kind': 'final'};
  final o = names?.of(text);
  if (o == null) return {'kind': 'unknown', 'text': text};
  if (o.kind == 'appRule') return {'kind': 'appRule', 'app': o.app, 'id': o.id, 'name': o.name};
  return {'kind': o.kind, 'name': o.name, if (o.id.isNotEmpty) 'id': o.id};
}

/// The app that made a request, for an event's data: `{name, path}` (the file name of the path);
/// null = unknown.
Map<String, dynamic>? processEventData(String path) {
  if (path.isEmpty) return null;
  final name = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? path;
  return {'name': name, 'path': path};
}

// Keys of a route rule that are not conditions: the action and its options.
const _actionKeys = {
  'action', 'outbound', 'method', 'no_drop', 'server', 'strategy', 'disable_cache', 'rewrite_ttl', 'client_subnet',
  'override_address', 'override_port', 'network_strategy', 'fallback_delay', 'udp_disable_domain_unmapping', 'udp_connect', 'udp_timeout', 'tls_fragment',
  'sniffer', 'timeout', 'tls_fragment_fallback_delay', 'tls_record_fragment', 'domain_resolver',
};
const _condKeys = {
  'invert', 'type', 'mode', 'rules', 'inbound', 'network', 'auth_user', 'protocol', 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex',
  'source_ip_cidr', 'source_ip_is_private', 'ip_cidr', 'ip_is_private', 'source_port', 'source_port_range', 'port', 'port_range',
  'process_name', 'process_path', 'process_path_regex', 'package_name', 'rule_set',
};

/// The conditions of [rule] alone (nested rules included), the identity of what it matches.
Map<String, dynamic> _conditionsOf(Map rule) => {
      for (final e in rule.entries)
        if (_condKeys.contains(e.key))
          '${e.key}': e.key == 'rules' && e.value is List
              ? [for (final s in e.value as List) s is Map ? _conditionsOf(s) : s]
              : e.value,
    };

/// sing-box's text for the route rule [rule] (as the config holds it); null = it has a
/// condition this does not know how sing-box writes.
String? ruleText(Map rule) {
  final String? body;
  if (rule['type'] == 'logical') {
    final op = switch (rule['mode']) { 'and' => '&&', 'or' => '||', _ => null };
    if (op == null || rule['rules'] is! List) return null;
    final parts = <String>[];
    for (final s in rule['rules'] as List) {
      final t = s is Map ? ruleText(s) : null;
      if (t == null) return null;
      parts.add(t);
    }
    body = parts.join(' $op ');
  } else {
    body = _items(rule);
  }
  if (body == null) return null;
  return rule['invert'] == true ? '!($body)' : body;
}

List<String> _vals(Object? v) => v is List ? [for (final x in v) '$x'] : v == null ? const [] : ['$v'];

String? _items(Map r) {
  for (final k in r.keys) {
    if (!_condKeys.contains(k) && !_actionKeys.contains(k)) return null;
  }
  if (r['type'] != null && r['type'] != 'default') return null;
  final out = <String>[];
  // [cut]: sing-box shows the first 3 of a longer list, [dots] with "..." after them
  void list(String key, {bool cut = false, bool dots = true}) {
    final v = _vals(r[key]);
    if (v.isEmpty) return;
    out.add(v.length == 1
        ? '$key=${v.first}'
        : cut && v.length > 3
            ? '$key=[${v.take(3).join(' ')}${dots ? '...' : ''}]'
            : '$key=[${v.join(' ')}]');
  }

  void flag(String key) {
    if (r[key] == true) out.add('$key=true');
  }

  // the order of sing-box's NewDefaultRule
  list('inbound');
  list('network');
  list('auth_user');
  list('protocol');
  list('domain', cut: true);
  list('domain_suffix', cut: true);
  list('domain_keyword', cut: true);
  list('domain_regex', cut: true, dots: false);
  list('source_ip_cidr', cut: true);
  flag('source_ip_is_private');
  list('ip_cidr', cut: true);
  flag('ip_is_private');
  list('source_port');
  list('source_port_range');
  list('port');
  list('port_range');
  list('process_name');
  list('process_path');
  list('process_path_regex', cut: true, dots: false);
  list('package_name');
  list('rule_set');
  return out.join(' ');
}
