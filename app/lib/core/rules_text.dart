import 'package:jormungand_core/jormungand_core.dart';

import '../l10n/l10n.dart';

/// The words of the Rules screens. The core's lists carry codes (`ruleGroups`, `RuleTest`, ...);
/// what the user reads is made here, in the app's language (the core's own English texts are for
/// the JSON / Clash export and the journal).

/// A target kind as a small tag: `subscription`, `profile`, `chain`, `servers`, `node`.
String kindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'subscription' => l10n.subscription2,
  'servers' => l10n.servers.toLowerCase(),
  'node' => l10n.server.toLowerCase(),
  'profile' => l10n.profile2,
  'chain' => l10n.chain2,
  _ => kind,
};

/// What a target is called: `Main flow`, the item's name, or `deleted chain` when it is gone.
String targetText(AppLocalizations l10n, Catalog c, String t) {
  if (t.isEmpty) return l10n.mainFlow2;
  final i = c.targetInfo(t);
  return i.gone ? l10n.deleted(kindLabel(l10n, i.kind)) : i.name;
}

/// A rule's / app half's action as its badge / state says it: `Direct`, `Block`, `-> name`, `Proxy`.
String actText(AppLocalizations l10n, Catalog c, String act, String target) =>
    switch (act) {
      'direct' => 'Direct',
      'block' => 'Block',
      'default' => 'Default',
      _ => target.isNotEmpty ? '→ ${targetText(l10n, c, target)}' : 'Proxy',
    };

String ruleTargetText(AppLocalizations l10n, Catalog c, UserRule r) =>
    actText(l10n, c, r.action, r.target);

/// `Main flow` / `Block` / `Direct` (the global Target unavailable and a rule's Fallback).
String fallbackName(AppLocalizations l10n, String v) => switch (v) {
  'main' => l10n.mainFlow2,
  'block' => 'Block',
  'direct' => 'Direct',
  _ => '',
};

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

/// A rule in a few words: its conditions.
String ruleSummaryText(AppLocalizations l10n, UserRule r) {
  if (r.composite != null) return l10n.compositeRule;
  final groups = r.groups ?? const <String, dynamic>{};
  final parts = <String>[];
  for (final g in ruleGroups) {
    final raw = groups[g.key];
    if (raw is! Map || raw.isEmpty) continue;
    final d = raw.cast<String, dynamic>();
    final v = d['v'] is Map
        ? (d['v'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    // The prefix goes on a field's first value only: "port 443, 8000-9000".
    final vals = <String>[
      for (final e in v.entries)
        if (e.value is List)
          for (final (i, x) in (e.value as List).indexed)
            '${i == 0 ? _fieldPrefix[e.key] ?? '' : ''}$x',
    ];
    if (d['flag'] == true) vals.insert(0, l10n.localNetworks);
    final shown =
        vals.take(2).join(', ') +
        (vals.length > 2 ? ' +${vals.length - 2}' : '');
    parts.add(
      (d['not'] == true ? '${l10n.not.toLowerCase()} ' : '') +
          (shown.isEmpty ? '—' : shown),
    );
  }
  return parts.isEmpty ? l10n.noConditions : parts.join(' · ');
}

String ruleTitleText(AppLocalizations l10n, UserRule r) =>
    r.name.isNotEmpty ? r.name : ruleSummaryText(l10n, r);

String groupTitle(AppLocalizations l10n, String key) => switch (key) {
  'domain' => l10n.domains,
  'ip' => 'IP',
  'port' => l10n.ports,
  'source' => l10n.source,
  'network' => l10n.network,
  'process' => l10n.process,
  _ => key,
};

String fieldLabel(AppLocalizations l10n, String field) => switch (field) {
  'domain_suffix' => l10n.suffix,
  'domain' => l10n.exactDomain,
  'domain_keyword' => l10n.keyword,
  'domain_regex' => l10n.regex,
  'geosite' => 'Geosite',
  'rule_set' => l10n.ruleSet,
  'ip_cidr' => l10n.ipCidrRange,
  'geoip' => 'GeoIP',
  'ip_is_private' => l10n.localNetworks2,
  'port' => l10n.portsAndRanges,
  'source_ip_cidr' => l10n.sourceIpCidr,
  'source_port' => l10n.sourcePorts,
  'network' => l10n.network,
  'protocol' => l10n.protocolSniffed,
  'process' => l10n.nameOrPath,
  _ => field,
};

/// What is wrong with a value of a field of [kind] (`RuleField.kind`).
String valueHint(AppLocalizations l10n, String kind) => switch (kind) {
  'domain' => l10n.aDomainEGExampleCom,
  'suffix' => l10n.aDomainSuffixEGGoogle,
  'text' => l10n.noSpaces,
  'regex' => l10n.notAValidRegularExpression,
  'name' => l10n.lettersDigitsAnd,
  'ruleset' => l10n.noRuleSetWithThisName,
  'ip' => l10n.anIpCidr1000,
  'port' => l10n.n165535OrARangeLike,
  _ => '',
};

/// `🇷🇺 Russia`.
String regionLabel(AppLocalizations l10n, String code) => switch (code) {
  'RU' => l10n.russia,
  'BY' => l10n.belarus,
  'KZ' => l10n.kazakhstan,
  'UA' => l10n.ukraine,
  'CN' => l10n.china,
  'IR' => l10n.iran,
  _ => code,
};

/// `VPN` / `Direct` of a service.
String serviceState(String v) => v == 'vpn'
    ? 'VPN'
    : v == 'direct'
    ? 'Direct'
    : '';

/// One half of an app rule: `Direct`, `-> name`, `Proxy`, `Default`, `Block`.
String appHalfText(AppLocalizations l10n, Catalog c, AppHalf h) =>
    actText(l10n, c, h.act, h.target);

/// An app rule as a line: one half, or `TCP ... · UDP ...` when split.
String appActText(AppLocalizations l10n, Catalog c, AppRule a) {
  if (!a.split) return appHalfText(l10n, c, a.tcp);
  return [
    for (final (p, h) in a.halves) '$p ${appHalfText(l10n, c, h)}',
  ].join(' · ');
}

/// The message under a JSON / Clash import that failed.
String ioErrorText(AppLocalizations l10n, Object e) {
  if (e is RuleJsonError) {
    if (e.code == 'notObject') return l10n.aRuleMustBeAJson;
    return e.line != null ? l10n.line2('${e.line}', e.detail) : e.detail;
  }
  if (e is ClashLineError) return l10n.lineExpectedTypeValuePolicy('${e.line}');
  return '$e';
}
