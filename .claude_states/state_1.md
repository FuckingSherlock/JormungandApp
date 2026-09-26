# State 1 — exit IP check, fastest start, jormd fixes (2026-09-26)

Branch `claude/core-mvp`, merged into the default `claude/karing-fork-environment-a45c2c`.

## Done
- **Exit IP check** (`core/lib/src/exitip.dart`), commit 8a3ffa6. It used to fail with a RU
  exit: both services (ipwho.is and the Cloudflare trace) sit on Cloudflare, which RU
  throttles, and they were asked one after another with 8 s each. Now 7 services
  (`exitProbes`) on different networks go in parallel: geo ones are ipwho.is (CF),
  ipinfo.io (Google) and ip-api.com (HTTP); Cloudflare trace gives IP + country; IP-only
  are Yandex, Amazon and ipip.net. An answer with country + city wins at once. With only
  an IP it waits a 1.5 s grace for geo. The overall limit is 7 s. UI shows "Location
  unknown" without geo. Tests: `core/test/exitip_test.dart` (parsers + race logic via a
  fake proxy). Diagnostics: `dart run tool/exit_check.dart [port]`.
- **Fastest groups start on a live server** (8c8f2ea). sing-box urltest uses its FIRST
  outbound until the first test round is done (~1 min with 115 nodes), so right after
  connect traffic went through a dead node and the exit check failed. `planGroup` in
  `95-live.js` now sends fastest nodes as: alive by ping, then unmeasured, dead last.
- The daemon's `_recheckExit` retries when every service fails fast (< 3 s): every 2 s,
  up to 15 s.
- `jormd --data` is made absolute (a relative path broke sing-box, which runs with `-D`).
- Checked live: RU exit (Moscow, Start2 LLC) answered right after connect.
- Docs: `docs/core.md` (Exit IP, urltest order). Network rules: CLAUDE.md points to the
  user memory `user-home-network`.

## Environment
- jormd was started from that session (`--lan`, http://192.168.0.92:7788). It dies with
  the session; restart it with
  `dart run core/bin/jormd.dart --data core/.data-dev --lan` (the user allows `--lan`:
  the home LAN is theirs).
- `tool/fake_sub.dart` also runs (loopback test subscription), started earlier by the user.
- `npm run verify` needs NODE_PATH / PLAYWRIGHT_BROWSERS_PATH. They are set in the user
  env; the Claude app has to be restarted to pick them up.
- No Artifact tool in that session, so the mockup artifact was not republished. The user
  does not care: the UI lives on the web.

## Open / ideas
- Pings are not persisted across launches (a known MVP gap). After a fresh page load
  without the launch ping, fastest order falls back to catalog order.
- If some country kills all geo services, add a geo provider reachable there. Check with
  `tool/exit_check.dart` on such a node.
