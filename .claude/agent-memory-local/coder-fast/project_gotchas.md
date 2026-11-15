---
name: jormungand-tooling-gotchas
description: Hook/tool quirks that cost time in G:\DEV\JormungandApp
metadata:
  type: project
---

- Bash hook blocks heredoc / inline scripts that write files: use Edit/Write. `/tmp` is not real.
- Gradle only from PowerShell (`.\gradlew.bat`), Bash fails with a loopback error. Never `dart format` app/ or core/.
- Mockup (design/) is frozen: note deferred mockup work in `.claude_states/mockup_todo.md` instead.
- If the mockup is touched again: a new `.html` under design/src/markup needs `<!-- raw-html-confirmed -->` as the
  first line; `npm run verify` runs the whole check suite; a fresh toast fades in for ~.2 s (measure after ~350 ms).
