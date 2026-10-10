// Разработческий помощник: список свежих отчётов и скачивание одного в .bin.
//   node tools/fetch.mjs                 # 20 новых
//   node tools/fetch.mjs --n 50          # 50 новых
//   node tools/fetch.mjs <id> [out.bin]  # скачать отчёт по id (20261010-k3x9ab) или ключу (2026/10/<id>)
// Запускать из workers/reports (или где угодно: используется wrangler.jsonc этой папки).
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function wrangler(args) {
  const r = spawnSync('npx', ['wrangler', ...args, '--binding', 'REPORTS', '--remote'], {
    cwd: root,
    shell: true,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.status !== 0) {
    process.stderr.write(r.stderr);
    process.exit(r.status ?? 1);
  }
  return r.stdout;
}

const argv = process.argv.slice(2);
const nIdx = argv.indexOf('--n');
const n = nIdx >= 0 ? Number(argv.splice(nIdx, 2)[1]) || 20 : 20;

if (argv.length === 0) {
  const out = wrangler(['kv', 'key', 'list']).toString('utf8');
  const keys = JSON.parse(out.slice(out.indexOf('[')));
  keys.sort((a, b) => String(b.metadata?.receivedAt ?? b.name).localeCompare(String(a.metadata?.receivedAt ?? a.name)));
  for (const k of keys.slice(0, n)) {
    const m = k.metadata ?? {};
    const id = k.name.split('/').pop();
    const kb = Math.max(1, Math.round(Number(m.size ?? 0) / 1024));
    console.log(`${id}  ${m.receivedAt ?? '?'}  ${m.platform ?? '?'} ${m.version ?? '?'} (${m.build ?? '?'})  ${kb} KB`);
  }
  if (keys.length === 0) console.log('(пусто)');
} else {
  const arg = argv[0];
  const key = arg.includes('/') ? arg : `${arg.slice(0, 4)}/${arg.slice(4, 6)}/${arg}`;
  const id = key.split('/').pop();
  const file = argv[1] ?? `${id}.bin`;
  const data = wrangler(['kv', 'key', 'get', key]);
  const at = data.indexOf('JRP1');
  if (at < 0) {
    console.error('Ключ не найден или это не конверт JRP1.');
    process.exit(1);
  }
  writeFileSync(file, data.subarray(at));
  console.log(`${file}: ${data.length - at} байт. Дальше: dart run core/tool/decrypt_report.dart ${file}`);
}
