// Runs every generator of the app (themes, dock paths, i18n ARB, flags font).
//   node app/tool/gen_all.mjs
// Run it after changing design/src/css/00-themes.css, design/tools/geometry.mjs,
// design/src/js/04-i18n-ru.js or the flags font; commit the output.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = dirname(fileURLToPath(import.meta.url));
let failed = false;
for (const g of ['gen_theme', 'gen_dock', 'gen_i18n', 'gen_assets']) {
  const r = spawnSync(process.execPath, [join(dir, g + '.mjs')], { stdio: 'inherit' });
  if (r.status !== 0) failed = true;
}
process.exit(failed ? 1 : 0);
