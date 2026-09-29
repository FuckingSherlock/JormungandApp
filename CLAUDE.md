# Jormungand

VPN/proxy client (sing-box core), a reworked clone of Karing. Current stage: an
interactive HTML mockup of the UI plus the pure-Dart core (`core/`, MVP) that the mockup
drives as a web UI through the local daemon `jormd` (see `docs/core.md`). The real app
will be Flutter over the same core — do not start the Flutter UI until the mockup is
finished. The user talks Russian; reply in Russian.

## Status

In the mockup: Home (modes incl. system proxy, connect dock), Nodes (the catalog: tabs
Simple / Profiles, swipeable — sources, profiles, chains are created and edited only here),
Route (main flow only: animated Simple / Profiles switch, Auto / Manual, always-on ⋮⋮ own
priority over the Nodes order, AUTO / MANUAL button + Use in Auto on every row, a row unfolds to
Fastest / Priority, ⚡ and its servers), Settings (Auto mode, Appearance with themes and
text size 90–120%, General with startup / notifications and the launch ping, Connection, DNS), Rules (apps, own rules with form + JSON, target picker
over the whole catalog, "If unavailable" + global default, quick rules, services dropdown
linked to per-app routing, final order, address test, import/export, rule sets). All sheets
open to the top of the screen, end above the bottom nav (always visible; a tab tap closes them)
and close by swiping the header down. Back (phone / browser / Esc)
closes the top sheet and reopens the one it replaced (Add → Subscription), then goes Home.

Nodes edit mode: ✎ sits left of the Simple / Profiles tabs, ✓ while editing;
the header never changes (search, ⚡, ⋮, + stay available in edit mode).

Also: Logs tab (Events journal with filter, dots on the tab and notifications driven by it; Raw = sing-box + core lines, filter, search, follow), Settings → Data (backup,
restore, about), Copy URL / share link, QR and Speed test in the Nodes ⋮ menus (QR encoder vendored in
`36-qr.js`), the source error strip with Retry, filter / close in Live connections.

## Layout

- `docs/` — product logic for the real app (Russian): `subscription-parsing.md`
  (formats, UA strategy, dedup, latency URL, region rules), `connect-model.md` (sources,
  profiles, chains, modes, Auto settings, node identity and dropped nodes, servers off in
  Nodes, delete impact, validation, ping, dock), `rules.md` (routing rules, apps,
  DNS, system proxy, kill switch; rule targets and "If unavailable" in §0).
  Keep them in step with the mockup: when a change adds or alters behaviour the Flutter
  app must implement, update the doc in the same commit.
- `design/main_screen.html` — **generated** mockup, the file the user opens.
  Never edit it by hand; it is rebuilt from `design/src/`.
- `design/src/index.html` — page skeleton with `@include` lines.
- `design/src/css/`, `markup/`, `js/` — the mockup split by area; files are
  concatenated in name order (numeric prefix = order, keep it when adding files).
  All JS shares one global scope, so later files may use earlier ones.
- `design/src/assets/` — binary files inlined by the build as base64 via
  `{{asset:assets/name}}` (e.g. the Twemoji flag font; Windows has no flag emoji).
  Never link fonts/images by outside URL: the app viewer blocks them.
- `design/tools/geometry.mjs` — SVG paths for the Home connect dock (trapezoid tab,
  hexagon power button, corner wedges). Change shapes here, not in markup; markup
  uses `{{geo.name}}` placeholders.
- `design/tools/check.mjs` — headless smoke tests and screenshot presets.
- `design/src/js/12-backend.js` — the seam: every async ask of the core (fetch / update a
  subscription, ping, connect) goes through `backend`; mocked there, swapped for the real
  core by `95-live.js` when jormd serves the page (`window.JORMD`). New core calls go
  through the seam, never straight to `fetch`.
- `core/` — Dart package `jormungand_core` (parsers, sing-box config, runtime, `bin/jormd.dart`,
  `tool/fake_sub.dart` = loopback test subscription). sing-box binary in `core/tool/bin/`
  (not in git). Design and API: `docs/core.md`.

## Workflow

After any change under `design/src/` or `design/tools/`, one command:

```sh
npm run verify -- rules dns-form      # build + freshness + smoke tests, then one grid
                                      # of the given presets -> design/.shots/grid.png
```

It prints only failures, the pass count and the grid path. Without presets it just
builds and checks. Separate steps still exist: `npm run build`, `npm run check`,
`npm run shot -- <presets> [--grid] [--theme github] [--scale 2]` (-> `design/.shots/*.png`).
Hi-res set of every preset for the user: `npm run shot -- all --scale 2 --out design/.shots/<name> --files`,
then `node design/tools/grid.mjs design/.shots/<name> 8` (-> `<name>/grids/grid-NN.png`).

Presets: home, nodes, nodes-open, nodes-profiles, nodes-swipe, route, entry-delete,
target-picker, target-picker-open, rule-fallback, settings, dock, dock-chain, dock-profile, dock-off,
profiles, broken, profiles-full, source-entry, gone, nothing-ticked,
simple-chain, chain-priority, profile-edit, chain-edit, chain-groups, drag-mid, addmenu,
srcform, nodeform, actions, more, automode, node-off, broken-node, delete-confirm,
nodes-edit, nodes-edit-chain, entry-priority, profile-priority, help, interval, settings-auto, settings-look,
rules, rules-more, rules-services, rule-form, rule-new, rule-json, rule-test, rule-order, rule-io,
rule-sets, apps, app-act, settings-dns, dns-form, dns-failover, settings-conn, kill-on, kill-off-confirm, core-down-kept, core-down-direct, kill-blocking, core-recovering, settings-notif, text-large, text-large-rule,
connections, route-pin, sys-on, sys-off, no-auto, no-auto-dock, logs, logs-raw, logs-search, logs-warn, logs-filter, logs-event-open, logs-new-below, nav-dots, toast-fly,
qr-node, qr-sub, settings-data, restore-confirm, test-url, lang-soon, conn-filter, source-error,
dock-empty, nodeform-many, nodeform-edit, checkers, blocked-toast, speed-test, speed-done, speed-fail.
Add a preset in `check.mjs` rather than writing one-off Playwright scripts; add a check
there for each new interaction.

Core: in `core/`, `dart analyze` + `dart test` (the sing-box tests run on loopback only).
Live UI: `dart run bin/jormd.dart` → http://127.0.0.1:7788 (launch config `jormd`). After core changes
restart the dev jormd yourself (standing permission): stop the old `dart … jormd.dart` process, then
preview_start `jormd`.
Running, fixing and extending tests is the `tests` subagent's job (`.claude/agents/tests.md`).
On Windows a sing-box started by a test outlives a killed / timed-out test process. After such
a run (and before finishing), kill the orphans: ours only (path in this repo), parent gone —
never the user's tunnel or jormd's live child:

```powershell
Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" | Where-Object { $_.ExecutablePath -like '*JormungandApp*' -and -not (Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Network of this machine (home LAN is the user's own; never target the corporate network past it):
user memory `user-home-network`. Exit checks through a tunnel: `dart run tool/exit_check.dart`.

Commit `design/src`, `design/tools`, the rebuilt `design/main_screen.html`, `core/`, `docs/` and
push (the push redeploys the Cloudflare site, see Deploy).
Do not send `main_screen.html` as a file unless asked.

## End of session

Each session works on its own `claude/...` branch, so the default branch must receive
the latest work. Before finishing a session: commit and push everything, then merge the
working branch into the repo default branch (`git ls-remote --symref origin HEAD` shows
it) and push it. A new session starts from the default branch, so this is how it picks
up the latest state.

## Token economy

Every tool call re-reads the whole conversation, so the number of calls and the context
size are what cost, not the code written.
- Batch: make all edits for a step, then one `npm run verify -- <presets>`; look at the
  grid, not separate screenshots.
- Read only what is needed: `grep -n` for the function, then `sed -n 'a,bp'` / Read with
  offset+limit. Never read `main_screen.html`; the JS files in `design/src/js` are big.
- Plan and discuss in one session, implement in a fresh one pointed at `docs/`.

## Deploy (Cloudflare Worker)

The mockup is served by the Worker `jormungand-design` (static assets only,
config in `wrangler.jsonc`). Every push touching `design/` deploys it via
`.github/workflows/deploy.yml`; CI fails if `main_screen.html` was not rebuilt.
The workflow needs repo secrets `CLOUDFLARE_API_TOKEN` (template "Edit Cloudflare
Workers") and `CLOUDFLARE_ACCOUNT_ID`. Manual deploy: `npm run deploy` (runs
wrangler 4 via npx; log in once with `npx wrangler login` or set the same env vars).
URL: https://jormungand-design.slackerwarlock.workers.dev

## Design rules

- Colours only via CSS variables from `css/00-themes.css`; three themes
  (original = default navy, karing, github) switched in Settings → Appearance.
  For tinted colours use `rgba(var(--accent-rgb), .15)`, never a hex literal.
- Themes must not change layout (same font everywhere) — `check` verifies it.
- Scrollbars are hidden globally; the app frame is one viewport tall (no fake status bar):
  view header and bottom nav are fixed, only `.view > .scroll` scrolls.
- Text size (Settings → Appearance, 90–120%) zooms `.view > .scroll`, `.nodes-page` and
  `.sheet-body` via `--ui-zoom`; titles and headers stay fixed. New rows must fit at 120% on
  a 320px screen (a check verifies it).
- Name things after future Flutter widgets (SourceCard, NodeRow, ConnectDock,
  PowerTab) so the port is a straight mapping.
