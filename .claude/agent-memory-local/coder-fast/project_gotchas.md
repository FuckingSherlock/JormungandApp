---
name: jormungand-tooling-gotchas
description: Hook/tool quirks that cost time in G:\DEV\JormungandApp design work
metadata:
  type: project
---

- Bash hook blocks heredoc / inline scripts that write files: use Edit/Write, or Write a scratch .mjs (e.g. design/.shots/x.mjs), run it, delete it. `/tmp` is not real.
- Write of a new/overwritten `.html` under design/src/markup needs `<!-- raw-html-confirmed -->` as the first line (project has its own fragment convention).
- `npm run verify -- <presets>` always runs the whole check suite (~120 checks); the grid is design/.shots/grid.png. `navigator.webdriver` is true under check.mjs (mock random events are off there).
- A toast just shown is still fading in (.2s): animate/measure it only after ~350ms.
