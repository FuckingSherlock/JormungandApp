# App rules — task plan (2026-10-21)

Spec (Russian docs, the source of truth):
- `docs/rules.md` 124-138 (order, "N more" over 4 rules), 171-267 (§3 apps: sheet, app rules, model, routing,
  exclude_package, migration), 293-295 (no app condition on Android).
- `docs/connect-model.md` 972-1019 (event reason rows, the "Rule" row instead of Create rule, conflict rows,
  `rulesCatching`); `design/src/js/40-rules.js` 356-418 (`groupMatches`, `testAddress`, `rulesCatching` — reference
  only, read, never edit).

## Fixed interfaces (all units rely on these)

Core (`jormungand_core`):
- `AppRule.rules` — `List<UserRule>`, list order = check order; JSON key `rules` (absent = empty). Same `UserRule`
  format as own rules (incl. its on/off flag). An app whose route is default on both halves but has rules is stored;
  `appIsDefault` is true only when the route is default AND `rules` is empty.
- Catalog ops (in `rules_logic.dart`, next to `saveRule`):
  - `RuleProblem? saveAppRule(String app, UserRule d, {String? editing})` — same validation/normalisation as
    `saveRule`, but the `process` group is dropped; new rule appended to that app's list; creates the `AppRule`
    (default route) if the app has none; ids `ar<seq>` unique across the catalog.
  - `void deleteAppRule(String app, String id)`, `void moveAppRule(String app, int from, int to)`.
  - `UserRule? appRuleById(String app, String id)`.
- Matcher (new `core/lib/src/catalog/rule_match.dart`, exported):
  - `bool ruleCatches(UserRule r, String host, {int? port})` — true only when every condition group of the rule can be
    decided from host/port and matches (domain exact / suffix / keyword / regex; IP-CIDR when host is an IP; ports);
    groups it cannot decide (geosite, geoip, rule set, local networks for a name, network/protocol, source, process,
    composite JSON) → false (may miss, never a false positive). "кроме" (`not`) inverts a decidable group. Disabled
    rules → false.
  - `List<String> rulesCatching(Catalog cat, String host, {int? port, String? app})` — ids of own rules (in
    `ruleOrder`) that catch it; with `app` — ids of that app's rules instead.
- Routing: each app's enabled rules go right before that app's route rules, as the rule's conditions AND the app
  match (`package_name`; desktop `process_name`/`process_path` as the app route does). `RuleOrigin` kind `appRule`
  (with app key and rule id/name); event `data.rule` = `{kind: 'appRule', app, id, name}`. `exclude_package` only
  for an app fully Direct with no enabled rules.
- Migration on catalog load, Android only, once (marker in saved state): own rules whose `process` group is not
  inverted and whose values are packages → a copy without that group appended to each package's app rules; the own
  rule is removed. Inverted group / composite → left as is. One journal line listing what moved.

App: Rules sheet own list and app sheet list use one shared list widget: first 4 rows, the rest under a row
"{n} more" (tap expands; search expands). `showRuleForm(context, {id, host, app, via, appRuleOf, fallbackVia})`:
`appRuleOf` = package → edits/creates a rule of that app (no Process field, saves via `saveAppRule`);
`fallbackVia` = prefill Fallback = Proxy through that target (Action Proxy, main flow). New l10n keys (English
only, owned by unit A2): `moreN` "{n} more", `appRulesTitle` "Rules in this app", `newRuleForHost`
"New rule for {host}".
