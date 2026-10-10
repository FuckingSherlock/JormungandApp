import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle, sanitize, MAX_BYTES, type Env } from '../src/handler.ts';
import { hit, LIMITS, type Store } from '../src/limiter.ts';

function fakeEnv(extra: Partial<Env> = {}) {
  const objects = new Map<string, { value: Uint8Array; meta: Record<string, string>; ttl?: number }>();
  const env: Env = {
    REPORTS: {
      get: async (k) => (objects.has(k) ? {} : null),
      put: async (k, v, o) => {
        objects.set(k, { value: new Uint8Array(v), meta: o?.metadata ?? {}, ttl: o?.expirationTtl });
      },
    },
    limit: async () => ({ ok: true }),
    ...extra,
  };
  return { env, objects };
}

function ctx() {
  const pending: Promise<unknown>[] = [];
  return { waitUntil: (p: Promise<unknown>) => void pending.push(p), pending };
}

function body(extra = 10): Uint8Array {
  const b = new Uint8Array(4 + extra);
  b.set(new TextEncoder().encode('JRP1'));
  return b;
}

function post(data: BodyInit | null, headers: Record<string, string> = {}) {
  return new Request('https://x/v1/report', {
    method: 'POST',
    body: data,
    headers: { 'content-type': 'application/octet-stream', ...headers },
  });
}

const fixedNow = () => new Date('2026-10-10T12:00:00Z');

test('ping and 404', async () => {
  const { env } = fakeEnv();
  const r = await handle(new Request('https://x/v1/ping'), env, ctx());
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true });
  assert.equal((await handle(new Request('https://x/nope'), env, ctx())).status, 404);
  assert.equal((await handle(new Request('https://x/v1/report'), env, ctx())).status, 404);
});

test('success stores object with metadata and returns id', async () => {
  const { env, objects } = fakeEnv();
  const r = await handle(
    post(body(), { 'x-jorm-platform': 'android', 'x-jorm-version': '1.2.3', 'x-jorm-build': '42', 'x-jorm-format': 'jrp1' }),
    env,
    ctx(),
    { now: fixedNow },
  );
  assert.equal(r.status, 200);
  const j = (await r.json()) as { ok: boolean; id: string };
  assert.ok(j.ok);
  assert.match(j.id, /^20261010-[a-z2-9]{6}$/);
  const o = objects.get(`2026/10/${j.id}`)!;
  assert.ok(o);
  assert.equal(o.ttl, 90 * 24 * 3600);
  assert.equal(o.value.length, 14);
  assert.equal(new TextDecoder().decode(o.value.subarray(0, 4)), 'JRP1');
  assert.equal(o.meta.platform, 'android');
  assert.equal(o.meta.version, '1.2.3');
  assert.equal(o.meta.size, '14');
  assert.equal(o.meta.receivedAt, '2026-10-10T12:00:00.000Z');
});

test('optional meta headers may be absent', async () => {
  const { env, objects } = fakeEnv();
  const r = await handle(post(body(), { 'x-jorm-format': 'jrp1', 'x-jorm-size': '14' }), env, ctx(), { now: fixedNow });
  assert.equal(r.status, 200);
  const id = ((await r.json()) as { id: string }).id;
  const m = objects.get(`2026/10/${id}`)!.meta;
  assert.deepEqual(Object.keys(m).sort(), ['clientSize', 'format', 'receivedAt', 'size']);
  const bare = await handle(post(body()), env, ctx());
  assert.equal(bare.status, 200);
});

test('wrong content-type is 415', async () => {
  const { env } = fakeEnv();
  const r = await handle(post(body(), { 'content-type': 'application/json' }), env, ctx());
  assert.equal(r.status, 415);
});

test('declared oversize is 413', async () => {
  const { env } = fakeEnv();
  const r = await handle(post(body(), { 'content-length': String(MAX_BYTES + 1) }), env, ctx());
  assert.equal(r.status, 413);
});

test('actual oversize is 413', async () => {
  const { env, objects } = fakeEnv();
  const big = new Uint8Array(MAX_BYTES + 1);
  big.set(new TextEncoder().encode('JRP1'));
  const r = await handle(post(big), env, ctx());
  assert.equal(r.status, 413);
  assert.equal(objects.size, 0);
});

test('empty is 413', async () => {
  const { env } = fakeEnv();
  assert.equal((await handle(post(new Uint8Array(0)), env, ctx())).status, 413);
});

test('bad magic is 400', async () => {
  const { env, objects } = fakeEnv();
  const b = body();
  b[0] = 0x58;
  assert.equal((await handle(post(b), env, ctx())).status, 400);
  assert.equal((await handle(post(new Uint8Array([1, 2])), env, ctx())).status, 400);
  assert.equal(objects.size, 0);
});

test('rate limit is 429 with Retry-After', async () => {
  const { env } = fakeEnv({ limit: async () => ({ ok: false, retryAfter: 123 }) });
  const r = await handle(post(body()), env, ctx());
  assert.equal(r.status, 429);
  assert.equal(r.headers.get('retry-after'), '123');
});

test('id collision is retried', async () => {
  const { env, objects } = fakeEnv();
  let calls = 0;
  const random = (n: number) => {
    calls++;
    return new Uint8Array(n).fill(calls === 1 ? 0 : 1); // first id: aaaaaa, then bbbbbb
  };
  objects.set('2026/10/20261010-aaaaaa',{ value: new Uint8Array(), meta: {} });
  const r = await handle(post(body()), env, ctx(), { now: fixedNow, random });
  assert.equal(((await r.json()) as { id: string }).id, '20261010-bbbbbb');
});

test('telegram skipped without secrets', async () => {
  const { env } = fakeEnv();
  let called = false;
  const c = ctx();
  const r = await handle(post(body()), env, c, { fetch: (async () => ((called = true), new Response())) as typeof fetch });
  assert.equal(r.status, 200);
  await Promise.all(c.pending);
  assert.equal(called, false);
});

test('telegram message text and failure does not fail upload', async () => {
  const { env } = fakeEnv({ TELEGRAM_BOT_TOKEN: 'T', TELEGRAM_CHAT_ID: '7' });
  let url = '';
  let sent: { chat_id: string; text: string } | undefined;
  const c = ctx();
  let r = await handle(post(body(2048), { 'x-jorm-platform': 'windows', 'x-jorm-version': '0.9', 'x-jorm-build': '5' }), env, c, {
    fetch: (async (u: string, init: RequestInit) => {
      url = u;
      sent = JSON.parse(init.body as string);
      return new Response('{}');
    }) as unknown as typeof fetch,
  });
  await Promise.all(c.pending);
  const id = ((await r.json()) as { id: string }).id;
  assert.equal(url, 'https://api.telegram.org/botT/sendMessage');
  assert.equal(sent!.chat_id, '7');
  assert.equal(sent!.text, `Jormungand report ${id} · windows 0.9 (5) · 2 KB`);

  const c2 = ctx();
  r = await handle(post(body()), env, c2, {
    fetch: (async () => {
      throw new Error('net');
    }) as unknown as typeof fetch,
  });
  await Promise.all(c2.pending);
  assert.equal(r.status, 200);
});

test('meta is sanitized and length-limited', async () => {
  const { env, objects } = fakeEnv();
  const r = await handle(
    post(body(), {
      'x-jorm-platform': '<script>android\r',
      'x-jorm-version': 'v'.repeat(100),
      'x-jorm-build': '`rm -rf`; 7',
    }),
    env,
    ctx(),
    { now: fixedNow },
  );
  const id = ((await r.json()) as { id: string }).id;
  const m = objects.get(`2026/10/${id}`)!.meta;
  assert.equal(m.platform, 'scriptandroid');
  assert.equal(m.version.length, 32);
  assert.equal(m.build, 'rm -rf 7');
  assert.equal(sanitize(null, 5), '');
});

function memStore(): Store & { m: Map<string, number> } {
  const m = new Map<string, number>();
  return {
    m,
    get: async (k) => m.get(k),
    put: async (k, v) => void m.set(k, v),
    delete: async (ks) => void ks.forEach((k) => m.delete(k)),
    list: async (p) => [...m.keys()].filter((k) => k.startsWith(p)),
  };
}

test('limiter: hourly, daily and global caps', async () => {
  const s = memStore();
  const t = Date.UTC(2026, 9, 10, 12, 0, 1);
  for (let i = 0; i < LIMITS.perHour; i++) assert.deepEqual(await hit(s, 'a', t + i * 1000 + 1), { ok: true });
  const v = await hit(s, 'a', t + 20_000);
  assert.equal(v.ok, false);
  assert.ok(!v.ok && v.retryAfter > 0 && v.retryAfter <= 3600);
  // next hour: allowed again for 'a', until daily cap
  const t2 = t + 3_600_000;
  assert.deepEqual(await hit(s, 'a', t2 + 1), { ok: true });
  // global cap
  const g = memStore();
  const lim = { perHour: 1000, perDay: 1000, globalPerDay: 3 };
  for (let i = 0; i < 3; i++) assert.equal((await hit(g, 'ip' + i, t + 1, lim)).ok, true);
  assert.equal((await hit(g, 'other', t + 1, lim)).ok, false);
});
