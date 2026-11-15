---
name: app-tooling-quirks
description: Flutter app/ + core tooling quirks that cost time (generators, l10n keys, tests, gradle, formatting)
metadata:
  type: project
---

Flutter SDK: `export PATH="/g/ANDROID_DEV/flutter/bin:$PATH"`. `app/android/` is generated + overlay
(`node app/tool/apply_android_overlay.mjs`) — edit only `app/android_overlay/`.

- App strings: `app/tool/i18n_extra.json` → `node app/tool/gen_all.mjs` + `flutter gen-l10n`. Key = camelCase of the
  first English words, `{0}` → String s0, `{#0}` → num n0; collisions get suffixes — grep `app_en.arb` for the real
  identifier. Never delete `app/tool/i18n_keys.json`.
- Gradle: only from PowerShell `.\gradlew.bat :app:compileReleaseKotlin -x compileFlutterBuildRelease` in app/android
  (Bash: "Unable to establish loopback connection").
- Never `dart format` (neither app/ nor core/): files are wide-line, formatter rewrites unrelated code. Recover with
  `git show HEAD:path > path`.
- Bash hook blocks heredoc / `node -e` file writes: use Edit/Write.
- Widget tests: font is Ahem (glyph = font size wide) → Rows overflow first, use Flexible/ellipsis; NodeRow name and help
  lines are rich text (`findRichText: true`); FakeCoreHost needs `catalog.sourceOrder = [...]` before `syncCatalog()`.
- Android app tests with a fake AdoptRunner: a plan with rule lists fetches them through the dead fake port (~10-20 s) —
  use `route: global` in the snapshot.
- Android lifecycle traps: engine is process-owned (`AppEngine`); `AppLifecycleListener.onDetach` fires when the
  activity detaches — never shut the core down there. Details: docs/platforms.md.
- Long test runs: start via PowerShell `run_in_background` writing to `$env:TEMP\x.log` (Bash `/tmp` is hook-blocked,
  foreground Start-Sleep is blocked); wait with a bash `until [ -f "$(cygpath "$TEMP")/flag" ]` loop in background.
- Other agents edit docs/*.md and shared files concurrently: "file modified since read" on Edit = re-Read the region, retry.
- testWidgets with a controller owning periodic Timers: dispose inside the test body (try/finally), tearDown is too late.
- testWidgets: `await sub.cancel()` (stream subscription) in the body hangs the test forever under FakeAsync — use `unawaited(...)`.
  `flutter test` with `-r failures-only` prints nothing until the end; use `-r expanded --timeout 60s` into a log to see hangs.
- Kotlin overlay compile check: `node app/tool/apply_android_overlay.mjs` then gradle (PowerShell) as above.
- LiveCoreHost test that reconnects a running fake core: set `host.setGlobal(true)` first, else the second connect fetches
  rule lists through the dead tunnel port and hangs (looks like "reconnect never starts").
- Plan changes that diverge from the frozen mockup's JS: gate them on `Catalog.mockupPlan` (golden test sets it true), else
  `core/test/catalog_golden_test.dart` breaks (planBrief / planSig / picks compare to JS).
- Mockup is frozen: deferred mockup work goes to `.claude_states/mockup_todo.md`; golden tests skip via `_mockupBehind`.
- Outside-tunnel registry (`core/lib/src/outside_tunnel.dart`) is guarded by `core/test/outside_tunnel_scan.dart` (patterns +
  scanner, also imported by path from `app/test/outside_tunnel_guard_test.dart`); Kotlin source of truth is `app/android_overlay/kotlin/*.kt.tmpl`.
- Windows, Dart 3.13: `Platform.resolvedExecutable` = `dart.exe` launcher but sing-box's process lookup sees `dartvm.exe`
  (a `process_path` rule on resolvedExecutable misses the test / jormd VM; tests use the sibling `dartvm.exe`).
- Live DNS-rule tests with real sing-box: SOCKS5 CONNECT 9.9.9.9:53 to a mixed inbound + `hijack-dns` rule, `hosts` DNS servers;
  1.14 needs `route.default_domain_resolver`.
- DNS flags (rule_set files `<flagDir>/<tag>.json`): sing-box start and `sing-box check` both fail when a file is missing — tests that build a config with `routing.dns` call `writeDnsFlags(info.dnsCandidates)` (pass `dnsFlagDir` in a tmp dir; default `dns-flags` is relative to cwd). Candidate ids (`a-udp1`, `cf-doh1-v`) are what Sentinel/status.dns use, not provider ids.
