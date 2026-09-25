# Jormungand

VPN/proxy client (sing-box core), a reworked clone of Karing. Current stage: an
interactive HTML mockup of the UI. The real app will be Flutter (Dart) — do not
start it until the mockup is finished. The user talks Russian; reply in Russian.

## Status

In the mockup: Home (modes incl. system proxy, connect dock), Nodes (the catalog: tabs
Simple / Profiles, swipeable — sources, profiles, chains are created and edited only here),
Route (main flow only: ✎ + animated Simple / Profiles switch, Auto / Manual, Use in Auto on
every row, own priority over the Nodes order), Settings (Auto mode, Appearance with themes and
text size 90–120%, General with startup / notifications and the launch ping, Connection, DNS), Rules (apps, own rules with form + JSON, target picker
over the whole catalog, "If unavailable" + global default, quick rules, services dropdown
linked to per-app routing, final order, address test, import/export, rule sets). All sheets
open to the top of the screen and close by swiping the header down.

Nodes edit mode: ✎ sits left of the Simple / Profiles tabs (as in Route), ✓ while editing;
the header never changes (search, ⚡, ⋮, + stay available in edit mode).

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

## Workflow

After any change under `design/src/` or `design/tools/`, one command:

```sh
npm run verify -- rules dns-form      # build + freshness + smoke tests, then one grid
                                      # of the given presets -> design/.shots/grid.png
```

It prints only failures, the pass count and the grid path. Without presets it just
builds and checks. Separate steps still exist: `npm run build`, `npm run check`,
`npm run shot -- <presets> [--grid] [--theme github] [--scale 2]` (-> `design/.shots/*.png`).

Presets: home, nodes, nodes-open, nodes-profiles, nodes-swipe, route, entry-delete,
target-picker, rule-fallback, settings, dock, dock-chain, dock-profile, dock-off,
profiles, broken, profiles-full, source-entry, gone, nothing-ticked,
simple-chain, chain-priority, profile-edit, chain-edit, chain-groups, drag-mid, addmenu,
srcform, nodeform, actions, more, automode, node-off, broken-node, delete-confirm,
nodes-edit, nodes-edit-chain, entry-priority, profile-priority, help, interval, settings-auto, settings-look,
rules, rules-more, rules-services, rule-form, rule-new, rule-json, rule-test, rule-order, rule-io,
rule-sets, apps, app-act, settings-dns, dns-form, settings-conn, text-large, text-large-rule.
Add a preset in `check.mjs` rather than writing one-off Playwright scripts; add a check
there for each new interaction.

Commit `design/src`, `design/tools`, the rebuilt `design/main_screen.html`, `docs/` and
push (the push redeploys the Cloudflare site, see Deploy). The user views the mockup as a
claude.ai Artifact, which live-updates in their app: the build stages it, so after each
change republish `design/.artifact/jormungand.html` with the Artifact tool to
https://claude.ai/artifact/Lu4gwFjCVtcv8BogsvqbhS (pass it as `url`). In a new session the
first publish is refused and the live copy is saved locally: it is the previous build
wrapped by the host, so read only its first lines to confirm, then publish again.
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
