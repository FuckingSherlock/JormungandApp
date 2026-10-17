# Jormungand — rules for coding agents

Read this when your brief points here. Only what you need to edit code and tests in this repo.

## Repo

- `core/` — Dart package `jormungand_core`; `app/` — Flutter app (Android first); `design/` — HTML mockup.
- `design/` is frozen: never edit anything under it, never read `design/main_screen.html` (generated, huge).
- No commits, no pushes — the lead commits.

## Strings (Flutter)

- New UI strings in English only, never add Russian.
- A string that is only in the app goes to `app/tool/i18n_extra.json` as `{"English text": null}`; key rules —
  `docs/i18n.md` § Flutter (lines ~53–85).
- After changing strings run `node app/tool/gen_all.mjs` (regenerates `lib/l10n/app_{en,ru}.arb`,
  `tool/i18n_keys.json`); the generated files are committed, never edit them by hand.

## Checks

- Core, in `core/`: `dart analyze` (must say "No issues found") and `dart test` (only the tests of what you touched
  unless the brief says otherwise).
- App, in `app/`: `flutter analyze --no-fatal-infos` and `flutter test` (same scope rule).
- `dart` / `flutter` missing from PATH in an old shell → in PowerShell:
  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.
- sing-box tests (real binary from `core/tool/bin/`, loopback only) — a couple are flaky under parallel load: rerun
  the failing test alone before concluding it is broken.

## Tests

- Fixtures in `core/test/fixtures.dart`; made-up servers only (`*.example`, 192.0.2.x). Never a real subscription
  URL, key or password.
- Fix a test only when the test is wrong; when the product code is wrong, say so. Say which of the two it was.
- A flaky check: find what async state it races with and remove the race; never just add a longer sleep.
