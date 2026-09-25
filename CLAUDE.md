# Jormungand

VPN/proxy client (sing-box core), a reworked clone of Karing. Current stage: an
interactive HTML mockup of the UI. The real app will be Flutter (Dart) — do not
start it until the mockup is finished. The user talks Russian; reply in Russian.

## Layout

- `docs/` — product logic for the real app (Russian): `subscription-parsing.md`
  (formats, UA strategy, dedup, latency URL, region rules), `connect-model.md` (sources,
  profiles, chains, modes, Auto settings, node identity and dropped nodes, servers off in
  Nodes, delete impact, validation, ping, dock), `rules.md` (routing rules, apps,
  DNS, system proxy, kill switch; the target picker is still a stub).
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

After any change under `design/src/` or `design/tools/`:

```sh
npm run build          # regenerate design/main_screen.html (+ stage deploy/artifact copies)
npm run check          # freshness check + smoke tests, prints only failures
```

Screenshots only when the visual result matters, cropped and at 1x:

```sh
npm run shot -- dock nodes            # -> design/.shots/*.png
npm run shot -- settings --theme github --scale 2
```

Presets: home, nodes, nodes-open, settings, dock, dock-chain, dock-profile, dock-off, profiles, broken, profiles-full,
profiles-menu, source-entry, gone, nothing-ticked, simple-chain, chain-priority, profile-edit,
chain-edit, chain-groups, drag-mid, addmenu,
srcform, nodeform, actions, more, automode, node-off, broken-node, delete-confirm, nodes-edit, entry-priority, profile-priority, help, interval, settings-auto, settings-look, rules, rules-more, rule-form, rule-new, rule-json, rule-test,
rule-order, rule-io, rule-sets, apps, app-act, settings-dns, dns-form, settings-conn. Add a preset in `check.mjs` rather than writing
one-off Playwright scripts; add a check there for each new interaction.

Commit both `design/src` changes and the rebuilt `design/main_screen.html` and push
(the push redeploys the Cloudflare site, see Deploy). The user views the mockup as a
claude.ai Artifact, which live-updates in their app: `npm run build` also stages it, so after each change just republish `design/.artifact/jormungand.html` with the
Artifact tool to https://claude.ai/artifact/Lu4gwFjCVtcv8BogsvqbhS (pass it as `url`
from a new session). Do not send `main_screen.html` as a file unless asked.

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
- Scrollbars are hidden globally; the app frame is one viewport tall: status bar,
  view header and bottom nav are fixed, only `.view > .scroll` scrolls.
- Name things after future Flutter widgets (SourceCard, NodeRow, ConnectDock,
  PowerTab) so the port is a straight mapping.
