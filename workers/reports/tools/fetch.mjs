// Разработческий помощник: список свежих отчётов, скачивание одного, открытие в одну команду.
//   node tools/fetch.mjs                      # 20 новых
//   node tools/fetch.mjs --n 50               # 50 новых
//   node tools/fetch.mjs <id> [out.bin]       # скачать отчёт по id (20261010-k3x9ab) или ключу (2026/10/<id>)
//   node tools/fetch.mjs <id> --open          # скачать + расшифровать: core/.data-dev/reports/<id>.{jrp,txt,json}
//   node tools/fetch.mjs --latest [--open]    # то же для самого свежего отчёта
// Запускать из workers/reports (или где угодно: используется wrangler.jsonc этой папки).
// Приватный ключ читает только core/tool/decrypt_report.dart; здесь он не читается и не печатается.
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const coreDir = resolve(root, '..', '..', 'core');

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

function listKeys() {
  const out = wrangler(['kv', 'key', 'list']).toString('utf8');
  const keys = JSON.parse(out.slice(out.indexOf('[')));
  // служебные ключи (`_notify/last`) — не отчёты
  const reports = keys.filter((k) => /^\d{4}\/\d{2}\/\d{8}-/.test(k.name));
  reports.sort((a, b) => String(b.metadata?.receivedAt ?? b.name).localeCompare(String(a.metadata?.receivedAt ?? a.name)));
  return reports;
}

function takeFlag(argv, name) {
  const i = argv.indexOf(name);
  if (i < 0) return false;
  argv.splice(i, 1);
  return true;
}

function download(key) {
  const data = wrangler(['kv', 'key', 'get', key]);
  const at = data.indexOf('JRP1');
  if (at < 0) {
    console.error('Ключ не найден или это не конверт JRP1.');
    process.exit(1);
  }
  return data.subarray(at);
}

function decrypt(file, outName, extra) {
  const r = spawnSync('dart', ['run', 'tool/decrypt_report.dart', file, ...extra, '--out', outName], {
    cwd: coreDir,
    shell: true,
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || r.stdout);
    process.exit(r.status ?? 1);
  }
}

const argv = process.argv.slice(2);
const nIdx = argv.indexOf('--n');
const n = nIdx >= 0 ? Number(argv.splice(nIdx, 2)[1]) || 20 : 20;
const latest = takeFlag(argv, '--latest');
const open = takeFlag(argv, '--open');

if (argv.length === 0 && !latest) {
  const keys = listKeys();
  for (const k of keys.slice(0, n)) {
    const m = k.metadata ?? {};
    const id = k.name.split('/').pop();
    const kb = Math.max(1, Math.round(Number(m.size ?? 0) / 1024));
    console.log(`${id}  ${m.receivedAt ?? '?'}  ${m.platform ?? '?'} ${m.version ?? '?'} (${m.build ?? '?'})  ${kb} KB`);
  }
  if (keys.length === 0) console.log('(пусто)');
} else {
  let key;
  if (latest) {
    const keys = listKeys();
    if (keys.length === 0) {
      console.error('Отчётов нет.');
      process.exit(1);
    }
    key = keys[0].name;
  } else {
    const arg = argv[0];
    key = arg.includes('/') ? arg : `${arg.slice(0, 4)}/${arg.slice(4, 6)}/${arg}`;
  }
  const id = key.split('/').pop();
  if (open) {
    const dir = resolve(coreDir, '.data-dev', 'reports');
    mkdirSync(dir, { recursive: true });
    const file = resolve(dir, `${id}.jrp`);
    writeFileSync(file, download(key));
    const txt = resolve(dir, `${id}.txt`);
    const json = resolve(dir, `${id}.json`);
    decrypt(file, txt, ['--text']);
    decrypt(file, json, []);
    console.log([file, txt, json].join('\n'));
  } else {
    const file = argv[1] ?? `${id}.bin`;
    const data = download(key);
    writeFileSync(file, data);
    console.log(`${file}: ${data.length} байт. Дальше: dart run core/tool/decrypt_report.dart ${file}`);
  }
}
