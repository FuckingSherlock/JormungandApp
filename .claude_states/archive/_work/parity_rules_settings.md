# Parity: Rules / Settings / Logs (analyzer report, saved by lead)

8 gaps: high 4 (P-S1, P-S2, P-S5, P-R2), medium 3 (P-S3, P-R1, P-R3), low 1 (P-S4).

- P-S1 (high) Launch at startup dead on Android: toggle shown (settings_look.dart:221-225), no RECEIVE_BOOT_COMPLETED / boot receiver (only MY_PACKAGE_REPLACED ResumeReceiver). docs/rules.md:557 plans BOOT_COMPLETED.
- P-S2 (high) Kill switch hidden on Android (platform_caps.dart:24, settings_conn.dart:222-291). Mockup 56-dns.js:241-267, docs/rules.md:453-513. Android design (BOOT + always-on VPN / block without VPN hint) — user decision.
- P-S3 (medium) «Resolve for IP rules» hidden on Android (settings_dns.dart:353, caps.dnsResolveForIp) though config.dart:325 opens mixed-in on 127.0.0.1 in TUN; docs/core.md:590 contradicts config.dart:325.
- P-S4 (low) Rule form «IP conditions only in TUN» block hidden on Android (rule_form.dart:328,373), same root as P-S3.
- P-S5 (high) «Start minimized» shown on Android as a dead toggle (settings_look.dart:227-231); hide or give meaning.
- P-R1 (medium) Rule form: no package_name condition on Android; Process group (process_name/path) is dead there (rules_logic.dart:81, routing.dart:730-737). Apps only via Per-app sheet, not combinable with domain etc.
- P-R2 (high) Live connections «Rule for this app» absent on Android (live_conns_sheet.dart:555-561 requires process; Android has pkg only, conn_view.dart:41-42,60).
- P-R3 (medium) Rules → Import → «From a subscription» is a mockup stub (40-rules.js:452); nothing on Android, no core support. Feature decision.

Logs: no gaps beyond mockup_todo Android-only changes. Other caps.* conditions legit.
Low-confidence question: is the local proxy port 127.0.0.1:port used on the phone while VPN is on? (settles P-S3/P-S4)
