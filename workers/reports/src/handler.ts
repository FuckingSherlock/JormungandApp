import type { Verdict } from './limiter.ts';

export const MAX_BYTES = 4 * 1024 * 1024;
export const MAGIC = 'JRP1';
export const TTL_SECONDS = 90 * 24 * 3600;

export interface Env {
  /** Workers KV (подмножество API): ключ `YYYY/MM/<id>`, значение — конверт, metadata — мета-поля. */
  REPORTS: {
    get(key: string, type: 'stream'): Promise<unknown | null>;
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

async function readLimited(req: Request): Promise<Uint8Array | 'toolarge'> {
  if (!req.body) return new Uint8Array(0);
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BYTES) {
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

export async function handle(request: Request, env: Env, ctx: Ctx, deps: Deps = {}): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === '/v1/ping' && request.method === 'GET') return json({ ok: true });
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
    const kb = Math.max(1, Math.round(body.length / 1024));
    const text = `Jormungand report ${id} · ${meta.platform || '?'} ${meta.version || '?'} (${meta.build || '?'}) · ${kb} KB`;
    const f = deps.fetch ?? fetch;
    ctx.waitUntil(
      (async () => {
        try {
          await f(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, disable_web_page_preview: true }),
          });
        } catch {
          // уведомление не критично: отчёт уже сохранён
        }
      })(),
    );
  }

  return json({ ok: true, id });
}
