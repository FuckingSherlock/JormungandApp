export const meta = { name: "pending-code-task-f08476", description: "Launch saved by the workflow gate: code-task" }
return await workflow("code-task", {
 "task": "vpn-down-core",
 "repo": "G:/DEV/JormungandApp",
 "plan": "G:/DEV/JormungandApp/.claude_states/vpn_down_core_plan.md",
 "rules": "G:/DEV/JormungandApp/.claude/agent-rules.md",
 "estK": 900,
 "check": "cd core; dart analyze; dart test",
 "review": true,
 "units": [
  {
   "id": "A",
   "tier": "deep",
   "files": [
    "core/lib/src/service.dart",
    "core/lib/src/eventbook.dart"
   ],
   "brief": "Implement plan items 1-6 (plan file, section 'Куски' → A): the single `conn/vpnDown` / `conn/vpnUp` incident event while connected (causes core / network, in-place updates, attachEvent to both Sentinel roots core.down and net.offline, `joins` of the crash event, vpnUp on recovery or user disconnect), stop writing core/down and the standing conn/offline warn / conn/online while connected (disconnected: info pair), and one choke point that makes every warn/error written without cause while the incident is open a consequence of it (exceptions in item 6). Add `joins` to EventBook.add / update. Behaviour spec: docs/logs.md section '«VPN не работает» (`conn/vpnDown` / `vpnUp`)' and docs/failures.md rows/paragraphs named in the plan. status.down and the system proxy logic at down stay unchanged. Do not touch log_view.dart (unit B) or tests."
  },
  {
   "id": "B",
   "tier": "deep",
   "files": [
    "core/lib/src/log_view.dart"
   ],
   "brief": "Implement plan items 7-9 (plan file, section 'Куски' → B): catalog (conn vpnDown, vpnUp; keep core/down for old journals), eventNotifKind / journalOnly / notifDefaults changes (no coreCrash), EventRecord.joins, foldEvents mechanism 5 'joins' (merge rows of listed ids into the joining event's row; an `opens` of a merged event is a step, not a close; unknown ids ignored), and EventFeed.notify(cfg, e) implementing eventNotifies + the closer rule (a closer notifies when the notification id it replaces was already shown, whatever its own toggle) + once-per-event; keep markNotified. Spec: docs/logs.md «Свёртки» mechanisms 2 and 5. Do not touch service.dart / eventbook.dart (unit A) or tests."
  }
 ],
 "tests": {
  "files": [
   "core/test/vpn_down_test.dart",
   "core/test/vpn_down_fold_test.dart",
   "core/test/killswitch_test.dart",
   "core/test/service_failures_test.dart",
   "core/test/event_fold_test.dart",
   "core/test/log_view_test.dart",
   "core/test/events_t1_test.dart",
   "core/test/event_catalog_test.dart"
  ],
  "brief": "From the spec (plan + docs/logs.md section '«VPN не работает»', «Свёртки» 2 and 5), not the implementation. New vpn_down_test.dart (CoreService, fake clock / runner as existing service tests do, see killswitch_test.dart and service_failures_test.dart for harness): real crash → restartFailed ×N → 30 s → one conn/vpnDown {causes:[core], proxy} with joins=[crashId] → restarted → conn/vpnUp opens=vpnDown; crash restarted within 30 s → no vpnDown; network gone while connected (netBlip) → vpnDown {causes:[network]}; second cause added / removed in place (rev, no new event); user disconnect closes with by:user; not connected → conn/offline/online info pair, no vpnDown; while open a sub/failed or other warn without cause gets cause=vpnDown + verdict consequence, own:true and core/stateLost do not. New vpn_down_fold_test.dart (log_view): foldEvents with joins gives ONE row for crashed+restartFailed+vpnDown+restarted+vpnUp and consequences of vpnDown (sub/failed cause=vpnDown) inside it, row closed only by vpnUp; EventFeed.notify: vpnDown notifies under connLost, restartFailed / crashed / consequences never, vpnUp replaces even when its toggle is off if vpnDown was shown, a closer whose opener was not shown follows its own toggle, once per event. Update existing tests that assert the old behaviour (core/down written, conn/offline warn / conn/online while connected, coreCrash kind, catalog guard) in killswitch_test, service_failures_test, event_fold_test, log_view_test, events_t1_test, event_catalog_test. Run: cd core; dart test <file>. sing-box tests loopback only."
 }
})
