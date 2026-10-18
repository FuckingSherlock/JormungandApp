# events-t2 — task plan for code-task (one run, core + app)

Behaviour spec: `docs/logs.md` — sections «Свёртки» item 2, «„VPN не работает“» (Ожидание, Закрытие), «Линия VPN»,
«По типам», «Тексты», «Задетые настройки (`sub/updated` warn, `node/lost`)», catalog table rows `conn/vpnDown`,
`sub/updated`, `sub/back`, `sub/removed`, `node/lost` / `node/back`, `auto/unstable`. Revoke app part:
`.claude_states/vpn_revoke_plan.md` «Прогон 2» + `docs/core.md` «Отзыв туннеля». English wording for every changed
string: `.claude_states/wording_audit.md` — the «proposed English text» column of the rows listed below, with the
user's decisions at the top of that file overriding the table. All UI strings English only.

Not in this task (do not implement): wording rows 6, 12 (replaced by «Ожидание» below), 15–17 (keep current
`conn/lost` / `restored` texts), 20 behaviour (only the prepared event), 26, 29–36 (notifications wording), Windows
system-proxy button (row 8 button).

## Lead decisions after run 1 (override anything below and in other plan files)

- English wording: `docs/logs.md` «Тексты» / «Задетые настройки» wins over `wording_audit.md` and `vpn_revoke_plan.md`
  where they differ. Closing texts: «VPN works again · sing-box is running» / «· internet is available» / «· sing-box
  is running, internet is available»; by user/system «VPN outage ended · VPN disconnected»; `disconnected by: system`
  «VPN disconnected · by the system or another app». Settings row label «VPN turned off by the system».
- l10n key names are what the generator makes from the English (keys are not renamed): `donTExclude`,
  `vpnTurnedOffByTheSystem`, `anotherVpnAppTookOverOr`; affected labels via `EventWords.affectedKindLabel(kind)` /
  `EventWords.affectedToLabel(a)` (methods of `EventWords`, not top-level).
- VPN line before the first state event: `connected` / `reconnected` / `vpnDown` / `disconnected` first → `on` above
  it; `vpnUp` first → `down` above it; no state events → `off` (docs/logs.md «Линия VPN» fixed accordingly).
- VPN line colour of `off`: `AppColors.t3` (grey), dashed. `AppColors.muted` is red in every theme — not used.
- vpnUp by user removes only the shown vpnDown notification: add a per-id cancel (`NotifyIo.cancelEvent(int id)` in
  `app/lib/platform/notify_channel.dart`, method `cancelEvent` in `NotifyChannel.kt` → `AppNotifier.cancelEvent`),
  never `cancelEvents()` for this.

## Lead decisions after run 2

- `node/lost` data gains `nodeIds` (ids of all used servers it names; `nodes` stays names, ≤ 10, for the text). «Switch on»
  in the app reads `nodeIds` (and the source's enabled flag for a whole source).
- Stale old tests are updated to the t2 spec by the test-writers that own them now: `core/test/event_fold_test.dart`
  (closer is its own row: opener keeps closed / closedAfter / closedById, closer has opensId — also the crash chain
  closed by `core/restarted`), `vpn_down_test.dart` + `service_failures_test.dart` (network-only vpnDown is warn),
  `manual_fetch_sentinel_test.dart` (manual update writes no success `sub/updated`), `events_t1_review_test.dart`
  (no `sub/removed`: warn `sub/updated` with lost used servers ↔ `sub/back` with `opens`); app fakes of `NotifyIo` in
  `system_notification_test.dart` / `update_resume_test.dart` get `cancelEvent`.

## Shared interfaces (fixed here; units code against them)

### Core `core/lib/src/log_view.dart` (unit core-feed)

- Pair rows (mechanism 2): a closing event (`opens` set) is no longer merged into the opening group; it is its own
  `EventGroup`. Opening group keeps `isClosed`, close time and duration (as now) and gains `int? closedById` (id of the
  closing event). The closing event's group gains `int? opensId` (id of the opening event, null if the opening event
  is not in the journal). Mechanism 5 (`joins`) unchanged: a closing event of a joined event stays a step inside.
- `const Set<String> alwaysShownTypes = {'conn/connected', 'conn/disconnected', 'conn/reconnected', 'conn/vpnDown',
  'conn/vpnUp'};` — the Events type filter (hidden types, "show only this type") never hides these.
- VPN line:
  ```dart
  enum VpnLine { on, down, waiting, off }
  enum VpnDot { none, change, reconnect }
  class VpnMark { final VpnLine above; final VpnLine below; final VpnDot dot; const VpnMark(this.above, this.below, this.dot); }
  /// Over the whole journal (not the filtered view), oldest → newest. Key: event id.
  /// `above` = state before the event (older side, the feed shows newest at the bottom), `below` = state after it.
  Map<int, VpnMark> vpnLineMarks(Iterable<EventRecord> journal);
  ```
  State changes: `conn/connected` → on (dot change); `conn/disconnected` → off (change); `conn/reconnected` → stays
  (dot reconnect); `conn/vpnDown` open or update → `waiting` when `causes` is exactly `['network']`, else `down`
  (dot change when the state changes); `conn/vpnUp` → on, or off when `by` is `user` / `system` (dot change). Other
  events: above == below == current state, dot none. Before the first state event: inferred from it (`connected` /
  `reconnected` / `vpnDown` first → `on` above it; `disconnected` first → `on` above it too, since it ended a
  connection; nothing → `off`).
- Notification kinds (`eventNotifKind` / `eventNotifKindOf`): `sub/updated` info → `subUpdated`, warn → `subFailed`;
  `sub/back` → `subFailed`; `node/lost`, `node/back` → journal only (reason: user's own action); `conn/vpnUp` with
  `by: user` / `system` → never notifies (closing-replaces-always rule does not apply to it; revoke plan «Кусок C»).
- `eventCats`: add `node/lost`, `node/back` (category of `node/addressMissing`); `sub/removed` stays (old journal).

### Core events (unit core-events)

- `conn/vpnDown` level: `warn` while `causes` is exactly `['network']`, `error` otherwise; the level changes in place
  with `causes` (extend `EventBook.update` to take a level if it cannot). `vpnUp` unchanged.
- `sub/updated`: auto update — info as now; manual update (`own: true`) writes no success event. Warn variation (auto
  and manual): the update removed used servers → `data.lost` (≤ 10 names), `lostCount`, `affected`. `sub/removed` is no
  longer written. `sub/back` (info, `opens` = that warn `sub/updated`) when all its lost servers are back (or the rest
  are no longer used); partial return — no event. `{source, name, count, names, affected}`.
- `node/lost` (warn, `own: true`) / `node/back` (info, `opens`): user switched off (`action: off`) or deleted
  (`deleted`) a node or a whole source through the app, and used servers are among them; `node/back` when all
  switched-off used nodes of that event are switched on again; after `deleted` no pair.
  `{action, source, name, nodes, nodeCount, affected}` / `{source, name, nodes, affected}`.
- `affected`: `[{kind: 'connection' | 'chain' | 'profile' | 'rule' | 'app', id, name, to}]`, built from
  `deleteImpact` / `targetImpact` (`core/lib/src/catalog/impact.dart`); `to` = where that setting's traffic goes now:
  `'block'`, `'direct'`, `'main'`, a target id, or `'none'` (chain / profile not working).
- `rules/targetLost` / `targetFound` caused by such a change: `cause` = the `sub/updated` warn / `node/lost` /
  `node/back` / `sub/back` event id, `verdict: consequence`, silent.
- Host API (`app/lib/core/core_host.dart` interface + `live_core_host.dart`):
  - node / source toggle and delete go through new `CoreService` methods (which write `node/*`) instead of calling
    `catalog/ops.dart` directly; the host method signatures stay as they are;
  - `Future<void> retargetAll(List<Map<String, dynamic>> affected, String target)` — sets `target` for every
    `rule` / `app` item (their target) and `connection` (route); `chain` / `profile` items are ignored. `''` = main
    flow (as `showTargetPicker` returns). Implemented in core (`catalog/ops.dart` `retargetAll`) and saved like a
    normal user edit.

### App l10n keys (unit app-texts adds them; other units only use them)

`chooseForAll` «Choose for all», `switchOn` «Switch on», `openSubscription` «Open subscription», `returnOnce`
«Return once», `dontExclude` «Don't exclude», `alwaysShown` «Always shown», `backToStart` «Back to start: {s0}»,
`affectedConnection` «Connection», `affectedRule` «Rule», `affectedApp` «App», `affectedChain` «Chain»,
`affectedProfile` «Profile», `affectedNotWorking` «not working», `notifVpnRevoked` «VPN turned off by the system»,
`notifVpnRevokedHint` «Another VPN app took over, or the VPN was switched off in the system settings. sing-box is
stopped and not restarted». Plus helpers in `event_text.dart`: `String affectedKindLabel(String kind)`,
`String affectedToLabel(Map a)` (target name via catalog, `block` / `direct` / `main` / `none` words).

### App row API (unit app-rows ↔ app-feed)

`EventRow` gets `final void Function(int eventId)? onJump;` — called by the pair link (opening row's «Ended at … ·
lasted …» status → `closedById`; closing row's «Back to start: <opening title>» → `opensId`). `logs_page.dart`
passes it and scrolls with the existing `showRow`.
