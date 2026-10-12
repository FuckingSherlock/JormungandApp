import type { Verdict } from './limiter.ts';

export const MAX_BYTES = 4 * 1024 * 1024;
export const MAGIC = 'JRP1';
export const TTL_SECONDS = 90 * 24 * 3600;

export interface Env {
  /** Workers KV (подмножество API): ключ `YYYY/MM/<id>`, значение — конверт, metadata — мета-поля. */
  REPORTS: {
    get(key: string, type: 'stream' | 'text'): Promise<unknown | null>;
    put(
      key: string,
      value: ArrayBuffer,
      opts?: { metadata?: Record<string, string>; expirationTtl?: number },
    ): Promise<unknown>;
  };
  /** Проверка лимита; в рантайме — Durable Object, в тестах — подмена. */
  limit(ipKey: string): Promise<Verdict>;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
  /** Токен, которым CI вызывает `POST /v1/release`; не задан — анонсы выключены (503). */
  RELEASE_NOTIFY_TOKEN?: string;
  /** Чат для анонсов релизов; не задан — `TELEGRAM_CHAT_ID`. */
  RELEASE_CHAT_ID?: string;
}

export interface Ctx {
  waitUntil(p: Promise<unknown>): void;
}

export interface Deps {
  now?: () => Date;
  fetch?: typeof fetch;
  random?: (n: number) => Uint8Array;
}

/** [a-z2-9]: 26 + 8 = 34 символа. */
const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz23456789';
const META_HEADERS = [
  ['X-Jorm-Format', 'format', 16],
  ['X-Jorm-Version', 'version', 32],
  ['X-Jorm-Build', 'build', 16],
  ['X-Jorm-Platform', 'platform', 24],
  ['X-Jorm-Size', 'clientSize', 12],
] as const;

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}

/** Оставляет безопасные для печати символы и режет по длине. */
export function sanitize(value: string | null, max: number): string {
  if (!value) return '';
  return value.replace(/[^A-Za-z0-9 ._+-]/g, '').trim().slice(0, max);
}

/** `YYYYMMDD-` + 6 символов; rnd — 6 значений-индексов (уже без смещения). */
export function makeId(now: Date, rnd: Uint8Array): string {
  const p = (n: number, w: number) => String(n).padStart(w, '0');
  const date = `${p(now.getUTCFullYear(), 4)}${p(now.getUTCMonth() + 1, 2)}${p(now.getUTCDate(), 2)}`;
  let tail = '';
  for (let i = 0; i < 6; i++) tail += ID_ALPHABET[rnd[i]! % ID_ALPHABET.length];
  return `${date}-${tail}`;
}

function cryptoBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}

export function objectKey(id: string): string {
  return `${id.slice(0, 4)}/${id.slice(4, 6)}/${id}`;
}

async function freshId(env: Env, now: Date, rand: (n: number) => Uint8Array): Promise<string | null> {
  // Отбраковка байтов >= 238 (кратно 34), чтобы не было смещения по алфавиту.
  const cut = 256 - (256 % ID_ALPHABET.length);
  for (let attempt = 0; attempt < 8; attempt++) {
    const buf = new Uint8Array(6);
    let have = 0;
    while (have < 6) {
      for (const b of rand(16)) {
        if (b < cut && have < 6) buf[have++] = b;
      }
    }
    const id = makeId(now, buf);
    // stream: значение не буферизуется, нужен только факт наличия
    if ((await env.REPORTS.get(objectKey(id), 'stream')) === null) return id;
  }
  return null;
}

async function ipKey(ip: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`jorm-reports:${ip}`));
  return [...new Uint8Array(d).slice(0, 12)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function readLimited(req: Request, max = MAX_BYTES): Promise<Uint8Array | 'toolarge'> {
  if (!req.body) return new Uint8Array(0);
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return 'toolarge';
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}

export const PING_BODY_MAX = 64 * 1024;
export const PING_REPLY_BYTES = 32768;
export const NOTE_MAX = 500;
const NOTE_HEADER_MAX = 4096;
const CAPTION_MAX = 1024;

/** base64url (без паддинга) → UTF-8 текст заметки; любая ошибка → '' (заметка просто игнорируется). */
export function decodeNote(header: string | null): string {
  if (!header || header.length > NOTE_HEADER_MAX || !/^[A-Za-z0-9_-]+={0,2}$/.test(header)) return '';
  try {
    const b64 = header.replace(/=+$/, '').replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4));
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    // управляющие символы (кроме перевода строки) в уведомлении не нужны
    return [...text.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, '')]
      .slice(0, NOTE_MAX)
      .join('')
      .trim();
  } catch {
    return '';
  }
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function prettyPlatform(p: string): string {
  const known: Record<string, string> = { android: 'Android', windows: 'Windows', ios: 'iOS', macos: 'macOS', linux: 'Linux' };
  return known[p.toLowerCase()] ?? (p ? p[0]!.toUpperCase() + p.slice(1) : '');
}

/** Подпись для Telegram (parse_mode HTML); видимый текст ≤ 1024 символов, заметка режется с «…». */
export function buildCaption(
  id: string,
  m: { platform?: string; version?: string; build?: string; via?: string; vpn?: string },
  sizeBytes: number,
  note: string,
): string {
  const kb = Math.max(1, Math.round(sizeBytes / 1024));
  const info: string[] = [];
  if (m.platform) info.push(prettyPlatform(m.platform));
  if (m.version) info.push(m.build ? `${m.version} (${m.build})` : m.version);
  else if (m.build) info.push(`(${m.build})`);
  info.push(`${kb} KB`);
  const state: string[] = [];
  if (m.vpn) state.push(`VPN ${m.vpn}`);
  if (m.via) state.push(m.via === 'vpn' ? 'sent via VPN' : 'sent direct');
  const lines = [`🐞 <b>Report</b> <code>${escapeHtml(id)}</code>`, escapeHtml(info.join(' · '))];
  const visible = [`🐞 Report ${id}`, info.join(' · ')];
  if (state.length) {
    lines.push(state.join(' · '));
    visible.push(state.join(' · '));
  }
  if (!note) {
    lines.push('<i>no note</i>');
    return lines.join('\n');
  }
  const budget = CAPTION_MAX - visible.join('\n').length - 1; // -1: перевод строки перед цитатой
  let shown = note;
  if (shown.length > budget) {
    let cut = Math.max(0, budget - 1);
    const code = shown.charCodeAt(cut - 1);
    if (code >= 0xd800 && code <= 0xdbff) cut--; // не рвём суррогатную пару
    shown = shown.slice(0, cut).trimEnd() + '…';
  }
  lines.push(`<blockquote>${escapeHtml(shown)}</blockquote>`);
  return lines.join('\n');
}

export const RELEASE_BODY_MAX = 64 * 1024;
export const RELEASE_TEXT_MAX = 4096;
const RELEASE_MARKER_TTL = 30 * 24 * 3600;
const VERSION_RE = /^\d+\.\d+\.\d+(-beta\.\d+)?$/;

export interface ReleaseInfo {
  channel: 'beta' | 'stable';
  version: string;
  build: number;
  notes: string;
  url?: string;
}

/** Текст анонса (parse_mode HTML); видимый текст ≤ 4096 символов, заметки при нехватке места режутся с «…». */
export function buildReleaseText(r: ReleaseInfo): string {
  const beta = r.channel === 'beta';
  const head = beta ? `🧪 Beta ${r.version} · build ${r.build}` : `🚀 Jormungand ${r.version} — стабильная версия`;
  const headHtml = beta
    ? `🧪 <b>Beta ${escapeHtml(r.version)}</b> · build ${r.build}`
    : `🚀 <b>Jormungand ${escapeHtml(r.version)}</b> — стабильная версия`;
  const label = 'Скачать';
  const tail = r.url ? `\n\n${label}` : '';
  const budget = RELEASE_TEXT_MAX - head.length - 2 - tail.length; // -2: пустая строка перед заметками
  let shown = r.notes;
  if (shown.length > budget) {
    let cut = Math.max(0, budget - 1);
    const code = shown.charCodeAt(cut - 1);
    if (code >= 0xd800 && code <= 0xdbff) cut--; // не рвём суррогатную пару
    shown = shown.slice(0, cut).trimEnd() + '…';
  }
  let out = `${headHtml}\n\n${escapeHtml(shown)}`;
  if (r.url) out += `\n\n<a href="${escapeHtml(r.url).replace(/"/g, '&quot;')}">${label}</a>`;
  return out;
}

async function sameSecret(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  const x = new Uint8Array(da);
  const y = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!;
  return diff === 0;
}

function parseRelease(raw: unknown): ReleaseInfo | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  if (o.channel !== 'beta' && o.channel !== 'stable') return null;
  if (typeof o.version !== 'string' || !VERSION_RE.test(o.version)) return null;
  if (typeof o.build !== 'number' || !Number.isSafeInteger(o.build) || o.build < 1) return null;
  if (typeof o.notes !== 'string') return null;
  const notes = o.notes.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, '').trim();
  if (!notes) return null;
  const info: ReleaseInfo = { channel: o.channel, version: o.version, build: o.build, notes };
  if (typeof o.url === 'string' && /^https:\/\/\S+$/.test(o.url.trim())) info.url = o.url.trim();
  return info;
}

async function handleRelease(request: Request, env: Env, deps: Deps): Promise<Response> {
  if (!env.RELEASE_NOTIFY_TOKEN) return json({ ok: false, error: 'disabled' }, 503);
  const auth = /^Bearer (.+)$/.exec(request.headers.get('authorization') ?? '');
  if (!auth || !(await sameSecret(auth[1]!, env.RELEASE_NOTIFY_TOKEN))) {
    return json({ ok: false, error: 'unauthorized' }, 401);
  }
  const chat = env.RELEASE_CHAT_ID || env.TELEGRAM_CHAT_ID;
  if (!env.TELEGRAM_BOT_TOKEN || !chat) return json({ ok: false, error: 'disabled' }, 503);

  const ctype = (request.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase();
  if (ctype !== 'application/json') return json({ ok: false, error: 'unsupported-media-type' }, 415);
  const declared = Number(request.headers.get('content-length') ?? 0);
  if (Number.isFinite(declared) && declared > RELEASE_BODY_MAX) return json({ ok: false, error: 'too-large' }, 413);
  const bytes = await readLimited(request, RELEASE_BODY_MAX);
  if (bytes === 'toolarge') return json({ ok: false, error: 'too-large' }, 413);
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch {
    return json({ ok: false, error: 'bad-json' }, 400);
  }
  const rel = parseRelease(raw);
  if (!rel) return json({ ok: false, error: 'bad-request' }, 400);

  const marker = `_release/${rel.channel}/${rel.version}+${rel.build}`;
  let seen = false;
  try {
    seen = (await env.REPORTS.get(marker, 'text')) !== null;
  } catch {
    // без маркера в худшем случае повторный анонс, но не потерянный
  }
  if (seen) return json({ ok: true, duplicate: true });

  const f = deps.fetch ?? fetch;
  let description = '';
  try {
    const r = await f(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        chat_id: chat,
        text: buildReleaseText(rel),
        parse_mode: 'HTML',
        disable_web_page_preview: true,
      }),
    });
    if (!r.ok) {
      try {
        const j = (await r.json()) as { description?: unknown };
        description = typeof j.description === 'string' ? j.description.slice(0, 200) : `HTTP ${r.status}`;
      } catch {
        description = `HTTP ${r.status}`;
      }
      return json({ ok: false, error: 'telegram', description }, 502);
    }
  } catch (e) {
    return json({ ok: false, error: 'telegram', description: String(e).slice(0, 200) }, 502);
  }
  try {
    await env.REPORTS.put(marker, new TextEncoder().encode('1').buffer as ArrayBuffer, {
      expirationTtl: RELEASE_MARKER_TTL,
    });
  } catch {
    // анонс ушёл; потеря маркера = возможный повтор при перезапуске CI
  }
  return json({ ok: true });
}

export async function handle(request: Request, env: Env, ctx: Ctx, deps: Deps = {}): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === '/v1/release' && request.method === 'POST') return handleRelease(request, env, deps);
  if (url.pathname === '/v1/ping' && request.method === 'GET') return json({ ok: true });
  if (url.pathname === '/v1/ping' && request.method === 'POST') {
    // Пробный обмен: клиент считает его пройденным только при полном эхо 32 KiB (DPI режет соединения
    // после ~16 KB). Лимитером не считается, как и GET.
    const declaredPing = Number(request.headers.get('content-length') ?? 0);
    if (Number.isFinite(declaredPing) && declaredPing > PING_BODY_MAX) return json({ ok: false, error: 'too-large' }, 413);
    if ((await readLimited(request, PING_BODY_MAX)) === 'toolarge') return json({ ok: false, error: 'too-large' }, 413);
    return new Response(new Uint8Array(PING_REPLY_BYTES), {
      headers: { 'content-type': 'application/octet-stream', 'cache-control': 'no-store' },
    });
  }
  if (url.pathname !== '/v1/report' || request.method !== 'POST') {
    return json({ ok: false, error: 'not-found' }, 404);
  }

  const ctype = (request.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase();
  if (ctype !== 'application/octet-stream') return json({ ok: false, error: 'unsupported-media-type' }, 415);

  const declared = request.headers.get('content-length');
  if (declared !== null) {
    const n = Number(declared);
    if (!Number.isFinite(n) || n < 0) return json({ ok: false, error: 'bad-length' }, 400);
    if (n > MAX_BYTES || n === 0) return json({ ok: false, error: n === 0 ? 'empty' : 'too-large' }, 413);
  }

  const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
  const verdict = await env.limit(await ipKey(ip));
  if (!verdict.ok) {
    return json({ ok: false, error: 'rate-limited' }, 429, { 'retry-after': String(verdict.retryAfter) });
  }

  const body = await readLimited(request);
  if (body === 'toolarge') return json({ ok: false, error: 'too-large' }, 413);
  if (body.length === 0) return json({ ok: false, error: 'empty' }, 413);
  if (body.length < 4 || new TextDecoder('latin1').decode(body.subarray(0, 4)) !== MAGIC) {
    return json({ ok: false, error: 'bad-magic' }, 400);
  }

  const now = (deps.now ?? (() => new Date()))();
  const id = await freshId(env, now, deps.random ?? cryptoBytes);
  if (id === null) return json({ ok: false, error: 'server' }, 500);

  const meta: Record<string, string> = {};
  for (const [header, name, max] of META_HEADERS) {
    // Все поля необязательны: клиент не шлёт отсутствующие, пустые в metadata не пишем.
    const v = sanitize(request.headers.get(header), max);
    if (v) meta[name] = v;
  }
  const via = (request.headers.get('X-Jorm-Via') ?? '').trim().toLowerCase();
  if (via === 'vpn' || via === 'direct') meta.via = via;
  const vpn = (request.headers.get('X-Jorm-Vpn') ?? '').trim().toLowerCase();
  if (vpn === 'on' || vpn === 'off') meta.vpn = vpn;
  const note = decodeNote(request.headers.get('X-Jorm-Note'));
  if (note) meta.noteLength = String([...note].length);
  meta.receivedAt = now.toISOString();
  meta.size = String(body.length);

  try {
    await env.REPORTS.put(objectKey(id), body.buffer as ArrayBuffer, {
      metadata: meta,
      expirationTtl: TTL_SECONDS,
    });
  } catch {
    return json({ ok: false, error: 'server' }, 500);
  }

  if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    const caption = buildCaption(id, meta, body.length, note);
    const f = deps.fetch ?? fetch;
    ctx.waitUntil(
      (async () => {
        // Итог последней отправки (без токена) лежит в `_notify/last`: по нему видно, почему
        // уведомление не пришло (чат не найден, бот заблокирован, токен отозван).
        let result: Record<string, unknown>;
        try {
          // Основной путь — конверт файлом `<id>.jrp` с подписью; при сбое — тот же текст сообщением.
          let method = 'sendDocument';
          let r: Response | undefined;
          try {
            const form = new FormData();
            form.set('chat_id', String(env.TELEGRAM_CHAT_ID));
            form.set('caption', caption);
            form.set('parse_mode', 'HTML');
            form.set('document', new Blob([body.buffer as ArrayBuffer], { type: 'application/octet-stream' }), `${id}.jrp`);
            r = await f(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendDocument`, { method: 'POST', body: form });
          } catch {
            r = undefined;
          }
          if (!r || !r.ok) {
            method = 'sendMessage';
            r = await f(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                chat_id: env.TELEGRAM_CHAT_ID,
                text: caption,
                parse_mode: 'HTML',
                disable_web_page_preview: true,
              }),
            });
          }
          let description = '';
          try {
            const j = (await r.json()) as { description?: unknown };
            description = typeof j.description === 'string' ? j.description.slice(0, 200) : '';
          } catch {
            // не JSON — оставим пустым
          }
          result = { at: now.toISOString(), id, method, status: r.status, ok: r.ok, description };
          if (!r.ok) {
            // Отказ: добавим, какой это бот и какие чаты он видел (id чатов не секрет) — по этому
            // находится верный TELEGRAM_CHAT_ID, не показывая токен.
            const api = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}`;
            try {
              const me = (await (await f(`${api}/getMe`)).json()) as { result?: { id?: number; username?: string } };
              result.bot = { id: me.result?.id, username: me.result?.username };
            } catch {
              // диагностика не обязательна
            }
            try {
              const up = (await (await f(`${api}/getUpdates?limit=50`)).json()) as {
                result?: { message?: { chat?: { id?: number; type?: string; title?: string; username?: string } }; my_chat_member?: { chat?: { id?: number; type?: string; title?: string } }; channel_post?: { chat?: { id?: number; type?: string; title?: string } } }[];
              };
              const seen = new Map<number, { id: number; type?: string; title?: string; username?: string }>();
              for (const u of up.result ?? []) {
                const c = u.message?.chat ?? u.my_chat_member?.chat ?? u.channel_post?.chat;
                if (c && typeof c.id === 'number') seen.set(c.id, { id: c.id, type: c.type, title: c.title, username: (c as { username?: string }).username });
              }
              result.seenChats = [...seen.values()].slice(0, 20);
            } catch {
              // диагностика не обязательна
            }
          }
        } catch (e) {
          // уведомление не критично: отчёт уже сохранён
          result = { at: now.toISOString(), id, ok: false, error: String(e).slice(0, 200) };
        }
        try {
          await env.REPORTS.put('_notify/last', JSON.stringify(result), { expirationTtl: 7 * 24 * 3600 });
        } catch {
          // наблюдаемость не должна ничего ломать
        }
      })(),
    );
  }

  return json({ ok: true, id });
}
