# Jormungand

VPN/proxy client over sing-box, a reworked clone of Karing. The user talks Russian; reply in Russian.

Three products, one repo (how they fit together: **`docs/platforms.md`** — read it before any
Flutter or build work):
- **Mockup** `design/` — the spec of UI and behaviour; also the live desktop web UI through the
  local daemon `jormd`. The user keeps designing here.
- **Flutter app** `app/` — the real app, Android first, then Windows. Ported from the mockup screen
  by screen; differences between platforms are listed in `docs/platforms.md`.
- **Core** `core/` — Dart package `jormungand_core` shared by both (parsers, catalog, plan, sing-box
  config and runtime, `CoreService`, updates). Design and API: `docs/core.md`.

Where things stand and what's next: the newest `.claude_states/state_N.md`.

## Docs (Russian, the knowledge base — keep them current)

| File | What |
|---|---|
| `docs/platforms.md` | mockup ↔ Flutter Windows ↔ Flutter Android: platform differences, file mapping, sync procedure, generators, toolchain, builds |
| `docs/core.md` | core design, CoreService / CoreApi, runtime, TUN, jormd HTTP API |
| `docs/connect-model.md` | sources, profiles, chains, modes, Auto, node identity, delete impact, validation, ping, dock |
| `docs/rules.md` | routing rules, targets and "If unavailable", apps, DNS, system proxy, kill switch, modes |
| `docs/subscription-parsing.md` | formats, UA strategy, dedup, latency URL, region rules |
| `docs/updates.md` | in-app updates: signed manifest, feeds, keys, Windows / Android install |
| `docs/i18n.md` | translation mechanism and glossary |
| `app/README.md` | Flutter app layout, conventions, TODO |

A change that adds or alters behaviour updates the doc in the same commit (logic → doc → mockup →
Flutter).

## Mockup

- `design/main_screen.html` is **generated** — never edit or read it; it is built from `design/src/`.
- `design/src/index.html` — skeleton with `@include` lines; `css/`, `markup/`, `js/` are concatenated
  in name order (keep the numeric prefix). All JS shares one global scope.
- `design/src/assets/` — binaries inlined as base64 via `{{asset:assets/name}}`. Never link fonts or
  images by outside URL (the viewer blocks them).
- `design/tools/geometry.mjs` — SVG paths of the Home dock; markup uses `{{geo.name}}`.
- `design/src/js/12-backend.js` — the seam: every async ask of the core goes through `backend`
  (mocked there, swapped for the real core by `95-live.js` when jormd serves the page). Never call
  `fetch` directly.
- `design/tools/check.mjs` — headless smoke tests and screenshot presets. Add a preset / check there
  for each new interaction instead of one-off Playwright scripts.

Commands (repo root):

```sh
npm run verify -- rules dns-form   # build + freshness + checks; one grid of the presets -> design/.shots/grid.png
npm run shot -- list               # unknown name prints all preset names; ru-<preset> or --lang ru for Russian
node design/tools/check.mjs audit-ru [presets|all]   # Latin text left in ru
node design/tools/i18n-extract.mjs --missing         # UI strings without a Russian entry
```

Hi-res set for the user: `npm run shot -- all --scale 2 --out design/.shots/<name> --files`, then
`node design/tools/grid.mjs design/.shots/<name> 8`. Do not send `main_screen.html` unless asked.

Design rules:
- Colours only via CSS variables from `css/00-themes.css` (themes original / karing / github);
  tints as `rgba(var(--accent-rgb), .15)`, never hex. Themes must not change layout.
- One viewport tall: header and bottom nav fixed, only `.view > .scroll` scrolls; scrollbars hidden.
- Text size 90–120 % zooms content via `--ui-zoom`, headers stay; new rows must fit 320 px at 120 %.
- Sheets open to the top, end above the bottom nav, close by swiping the header down; Back closes the
  top sheet and reopens the one it replaced, then goes Home.
- Name things after Flutter widgets (SourceCard, NodeRow, ConnectDock, PowerTab).
- Every new UI string gets a Russian entry in `js/04-i18n-ru.js` (rules in its header).

## Core

In `core/`: `dart analyze` + `dart test` (sing-box tests run on loopback only; a couple are flaky
under parallel load — rerun singly before concluding). sing-box binary in `core/tool/bin/` (not in
git). Live UI: preview_start `jormd` → http://127.0.0.1:7788. After core changes restart the dev jormd
yourself (standing permission): stop the old `dart … jormd.dart` and its sing-box child, then
preview_start `jormd`. While the user is testing the live UI, don't drive it with browser tools.

A sing-box started by a test outlives a killed test process on Windows. After such runs, kill our
orphans only (path in this repo, parent gone) — never the user's tunnel or jormd's live child:

```powershell
Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" | Where-Object { $_.ExecutablePath -like '*JormungandApp*' -and -not (Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Never bring up a real TUN on this machine — the user tests TUN by hand. Network: the home LAN is the
user's own; never target the corporate network past it (memory `user-home-network`). Exit checks
through a tunnel: `dart run tool/exit_check.dart`.

## Flutter app

Everything is in `docs/platforms.md` (mapping, sync from the mockup, generators, toolchain in
`G:\ANDROID_DEV`, `build_libbox.ps1`, `build_apk.ps1`, adb install) and `app/README.md` (layout,
conventions). Short version: change the mockup first; port by the mapping table; `node app/tool/gen_all.mjs`;
in `app/` `flutter analyze --no-fatal-infos` + `flutter test`; `pwsh app/tool/build_apk.ps1` (always release-signed, version picked from the feed; `-DryRun` previews);
`adb install -r`. Never port the mockup's demo data or stub services. Secrets (keystore password,
release signing key) are never written to the repo or read by the agent.

## Working method (lead + agents)

- The lead plans, talks to the user, keeps the architecture, reviews diffs and grids, commits.
  Implementation goes to background agents by brief: `coder-fast` (clear UI work), `coder-deep` (core
  logic, state, tricky bugs, screen ports), `tests` (`.claude/agents/tests.md`; runs, fixes and
  extends checks), `general-purpose` for mixed jobs.
- A brief states: goal, files to start from (with line hints), constraints (no commit, never read
  `main_screen.html`, CSS vars / theme extension only, 320 px / 120 % fit, Russian for new strings),
  checks to add, docs to update, the exact verify command, "report briefly".
- Parallel agents get told which files the others edit; shared files (`check.mjs`, `04-i18n-ru.js`,
  ARB files, `i18n_extra.json`, `core_host.dart`, `CLAUDE.md`) — small Edit-tool edits only, re-read
  the region first, never rewrite.
- After an agent reports, the lead runs the full checks (`npm run verify`; `dart analyze` / `dart test`
  for core; `flutter analyze` / `flutter test` for app), looks at the grid, commits, pushes and
  fast-forwards the default branch. A failing check is investigated (app or check wrong?), not
  retried until green.
- Token economy: batch edits, then one verify; grep first, then read only the needed lines; look at
  the grid, not single screenshots.
- Agent size: an agent re-reads its whole growing context on every tool call, so cost grows ~quadratically.
  Split big work into stages of ~40–60 tool calls (core → app → CI), each a fresh agent with a short summary
  of the previous stage; never one agent for a multi-layer feature.
- Diagnose + fix in one agent: for a bug with a known search area give `coder-deep` "verify the hypothesis,
  then fix" instead of an `analyzer` report followed by a coder re-reading the same code. `analyzer` only
  for real design questions or unfamiliar code.
- Checks in briefs: the coder runs only the tests of what it touched (+ `analyze`); the full suites and
  gradle run once, by the lead via the Haiku `test-runner`, before the commit.
- At most 4 Sonnet agents at once; avoid parallel agents in the same files. An agent stopped by a limit is
  resumed with SendMessage (its context survives), not restarted.
- User decisions and the plan go into `.claude_states/state_N.md` ("Дальше").

## Git, end of session, deploy

Commit `design/src`, `design/tools`, the rebuilt `design/main_screen.html`, `core/`, `app/`, `docs/`.
Each session works on its own `claude/...` branch; after each commit push it and fast-forward the
default branch (`git ls-remote --symref origin HEAD` shows it):
`git push origin <branch>:<default branch>`. Before finishing a session everything is committed,
pushed and merged into the default branch — a new session starts from it.

Every push touching `design/` redeploys the mockup to the Cloudflare Worker `jormungand-design`
(`.github/workflows/deploy.yml`; CI fails if `main_screen.html` was not rebuilt). Manual:
`npm run deploy`. URL: https://jormungand-design.slackerwarlock.workers.dev
