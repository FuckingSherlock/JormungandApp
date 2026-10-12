import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle, sanitize, decodeNote, buildCaption, MAX_BYTES, type Env } from '../src/handler.ts';
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

const b64u = (s: string) => Buffer.from(s, 'utf8').toString('base64url');

/** Прогоняет отчёт через Worker с подменённым Telegram; возвращает вызовы и итог. */
async function tgRun(headers: Record<string, string>, tg: (u: string, init: RequestInit) => Response | Promise<Response> = () => new Response('{}'), size = 2048) {
  const { env, objects } = fakeEnv({ TELEGRAM_BOT_TOKEN: 'T', TELEGRAM_CHAT_ID: '7' });
  const calls: { url: string; init: RequestInit }[] = [];
  const c = ctx();
  const r = await handle(post(body(size), headers), env, c, {
    now: fixedNow,
    fetch: (async (u: string, init: RequestInit) => {
      calls.push({ url: u, init });
      return tg(u, init);
    }) as unknown as typeof fetch,
  });
  await Promise.all(c.pending);
  const id = ((await r.json()) as { id: string }).id;
  return { calls, id, objects };
}

test('telegram sendDocument: file, caption, parse mode', async () => {
  const { calls, id, objects } = await tgRun({
    'x-jorm-platform': 'windows',
    'x-jorm-version': '0.9',
    'x-jorm-build': '5',
    'x-jorm-via': 'vpn',
    'x-jorm-vpn': 'on',
    'x-jorm-note': b64u('Не подключается <b>& всё</b>'),
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.url, 'https://api.telegram.org/botT/sendDocument');
  const form = calls[0]!.init.body as FormData;
  assert.equal(form.get('chat_id'), '7');
  assert.equal(form.get('parse_mode'), 'HTML');
  const doc = form.get('document') as File;
  assert.equal(doc.name, `${id}.jrp`);
  assert.equal(doc.size, 2052);
  assert.equal(
    form.get('caption'),
    `🐞 <b>Report</b> <code>${id}</code>\nWindows · 0.9 (5) · 2 KB\nVPN on · sent via VPN\n<blockquote>Не подключается &lt;b&gt;&amp; всё&lt;/b&gt;</blockquote>`,
  );
  const meta = [...objects.values()][0]!.meta;
  assert.equal(meta.via, 'vpn');
  assert.equal(meta.vpn, 'on');
  assert.equal(meta.noteLength, String([...'Не подключается <b>& всё</b>'].length));
  assert.ok(!JSON.stringify(meta).includes('подключается'));
});

test('telegram caption without headers and with bad note', async () => {
  const { calls, id, objects } = await tgRun({ 'x-jorm-platform': 'android', 'x-jorm-note': '!!!not base64!!!', 'x-jorm-via': 'weird', 'x-jorm-vpn': 'maybe' });
  const caption = (calls[0]!.init.body as FormData).get('caption');
  assert.equal(caption, `🐞 <b>Report</b> <code>${id}</code>\nAndroid · 2 KB\n<i>no note</i>`);
  const meta = [...objects.values()][0]!.meta;
  assert.deepEqual(Object.keys(meta).sort(), ['platform', 'receivedAt', 'size']);
  // валидный base64url, но не UTF-8, и слишком длинный заголовок
  assert.equal(decodeNote(Buffer.from([0xff, 0xfe, 0xfd]).toString('base64url')), '');
  assert.equal(decodeNote('A'.repeat(5000)), '');
  assert.equal(decodeNote(null), '');
  assert.equal(decodeNote(b64u('  hi \r\nthere\u0007 ')), 'hi \nthere');
});

test('telegram caption truncates a long note to 1024 visible chars', async () => {
  const visibleLen = (c: string) => c.replace(/<\/?(b|code|i|blockquote)>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').length;
  // заметка в заголовке режется до 500 символов и целиком влезает в подпись, а экранирование не считается
  const { calls } = await tgRun({ 'x-jorm-platform': 'android', 'x-jorm-note': b64u('я<'.repeat(400)) });
  const caption = (calls[0]!.init.body as FormData).get('caption') as string;
  assert.ok(visibleLen(caption) <= 1024 && !caption.includes('…'));
  assert.ok(caption.includes('&lt;'));
  // buildCaption сам режет слишком длинное с «…», не ломая экранирование и суррогатные пары
  const cut = buildCaption('20261010-aaaaaa', { platform: 'android', version: '1.0', build: '1' }, 2048, '😀<'.repeat(900));
  assert.ok(cut.includes('…</blockquote>'));
  assert.ok(visibleLen(cut) <= 1024, String(visibleLen(cut)));
  assert.ok(!/[\ud800-\udbff]…/.test(cut));
});

test('telegram falls back to sendMessage when sendDocument fails', async () => {
  const { calls, id } = await tgRun({ 'x-jorm-note': b64u('hi') }, (u) => (u.endsWith('/sendDocument') ? new Response('{"description":"too big"}', { status: 413 }) : new Response('{}')));
  assert.deepEqual(calls.map((x) => x.url.split('/').pop()), ['sendDocument', 'sendMessage']);
  const sent = JSON.parse(calls[1]!.init.body as string);
  assert.equal(sent.chat_id, '7');
  assert.equal(sent.parse_mode, 'HTML');
  assert.ok(sent.text.includes(`<code>${id}</code>`) && sent.text.includes('<blockquote>hi</blockquote>'));
  // сеть упала на sendDocument: тоже запасной путь
  const t = await tgRun({}, (u) => {
    if (u.endsWith('/sendDocument')) throw new Error('net');
    return new Response('{}');
  });
  assert.equal(t.calls.length, 2);
});

test('telegram diagnostics stay in _notify/last and failure does not fail upload', async () => {
  const { env, objects } = fakeEnv({ TELEGRAM_BOT_TOKEN: 'T', TELEGRAM_CHAT_ID: '7' });
  const store: Record<string, string> = {};
  const put = env.REPORTS.put;
  env.REPORTS.put = async (k, v, o) => {
    if (k === '_notify/last') store[k] = v as unknown as string;
    return put(k, v, o);
  };
  const c0 = ctx();
  await handle(post(body()), env, c0, { fetch: (async () => new Response('{"description":"chat not found"}', { status: 400 })) as unknown as typeof fetch });
  await Promise.all(c0.pending);
  const last = JSON.parse(store['_notify/last']!);
  assert.equal(last.method, 'sendMessage');
  assert.equal(last.ok, false);
  assert.equal(last.description, 'chat not found');
  assert.equal([...objects.keys()].filter((k) => !k.startsWith('_')).length, 1); // отчёт сохранён, несмотря на отказ Telegram
});

test('POST /v1/ping echoes 32 KiB, is not rate-limited, caps the body', async () => {
  let limited = 0;
  const { env } = fakeEnv({ limit: async () => ((limited++), { ok: true }) });
  const req = (n: number) => new Request('https://x/v1/ping', { method: 'POST', body: new Uint8Array(n), headers: { 'content-type': 'application/octet-stream' } });
  const r = await handle(req(32768), env, ctx());
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'application/octet-stream');
  assert.equal((await r.arrayBuffer()).byteLength, 32768);
  assert.equal((await handle(req(64 * 1024), env, ctx())).status, 200);
  assert.equal((await handle(req(64 * 1024 + 1), env, ctx())).status, 413);
  assert.equal((await handle(new Request('https://x/v1/ping', { method: 'POST' }), env, ctx())).status, 200);
  assert.equal(limited, 0);
});

test('telegram failure does not fail upload', async () => {
  const { env } = fakeEnv({ TELEGRAM_BOT_TOKEN: 'T', TELEGRAM_CHAT_ID: '7' });
  let r: Response;
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

// ---- POST /v1/release ----

const REL_ENV = { RELEASE_NOTIFY_TOKEN: 'sekret', TELEGRAM_BOT_TOKEN: 'bot', TELEGRAM_CHAT_ID: '-100' };

function rel(payload: unknown, headers: Record<string, string> = { authorization: 'Bearer sekret' }) {
  return new Request('https://x/v1/release', {
    method: 'POST',
    body: typeof payload === 'string' ? payload : JSON.stringify(payload),
    headers: { 'content-type': 'application/json', ...headers },
  });
}

const goodBeta = { channel: 'beta', version: '0.1.2-beta.3', build: 3039, notes: 'Fix <a> & b\nsecond line' };

function tgStub(ok = true) {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const fetchStub = (async (u: string, init?: RequestInit) => {
    calls.push({ url: String(u), body: JSON.parse(String(init?.body)) });
    return ok
      ? new Response(JSON.stringify({ ok: true }), { status: 200 })
      : new Response(JSON.stringify({ ok: false, description: 'chat not found' }), { status: 400 });
  }) as typeof fetch;
  return { calls, fetchStub };
}

test('release: disabled without secret, 401 on bad or missing token, limiter untouched', async () => {
  let limited = 0;
  const lim = async () => (limited++, { ok: true as const });
  const off = fakeEnv({ ...REL_ENV, RELEASE_NOTIFY_TOKEN: undefined, limit: lim });
  const r0 = await handle(rel(goodBeta), off.env, ctx());
  assert.equal(r0.status, 503);
  assert.deepEqual(await r0.json(), { ok: false, error: 'disabled' });
  const { env } = fakeEnv({ ...REL_ENV, limit: lim });
  assert.equal((await handle(rel(goodBeta, {}), env, ctx())).status, 401);
  assert.equal((await handle(rel(goodBeta, { authorization: 'Bearer nope' }), env, ctx())).status, 401);
  assert.equal((await handle(rel(goodBeta, { authorization: 'sekret' }), env, ctx())).status, 401);
  const noBot = fakeEnv({ ...REL_ENV, TELEGRAM_BOT_TOKEN: undefined, limit: lim });
  assert.equal((await handle(rel(goodBeta), noBot.env, ctx())).status, 503);
  assert.equal(limited, 0);
});

test('release: validation', async () => {
  const { env } = fakeEnv(REL_ENV);
  const { fetchStub, calls } = tgStub();
  const bad: unknown[] = [
    'not json',
    [],
    { ...goodBeta, channel: 'alpha' },
    { ...goodBeta, version: '1.2' },
    { ...goodBeta, version: '1.2.3-rc.1' },
    { ...goodBeta, build: 0 },
    { ...goodBeta, build: 1.5 },
    { ...goodBeta, build: '7' },
    { ...goodBeta, notes: '  \n ' },
    { ...goodBeta, notes: 5 },
  ];
  for (const b of bad) {
    const r = await handle(rel(b), env, ctx(), { fetch: fetchStub });
    assert.equal(r.status, 400, JSON.stringify(b));
    assert.equal(((await r.json()) as { ok: boolean }).ok, false);
  }
  const wrongType = new Request('https://x/v1/release', {
    method: 'POST',
    body: 'x',
    headers: { 'content-type': 'text/plain', authorization: 'Bearer sekret' },
  });
  assert.equal((await handle(wrongType, env, ctx(), { fetch: fetchStub })).status, 415);
  const huge = rel(JSON.stringify({ ...goodBeta, notes: 'x'.repeat(70 * 1024) }));
  assert.equal((await handle(huge, env, ctx(), { fetch: fetchStub })).status, 413);
  assert.equal(calls.length, 0);
});

test('release: beta text, escaping, download button only for https', async () => {
  const { env, objects } = fakeEnv(REL_ENV);
  const { fetchStub, calls } = tgStub();
  const r = await handle(rel({ ...goodBeta, url: 'https://example.com/a?x=1&y="2"' }), env, ctx(), { fetch: fetchStub });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true });
  assert.equal(calls.length, 1);
  assert.match(calls[0]!.url, /\/botbot\/sendMessage$/);
  const b = calls[0]!.body;
  assert.equal(b.chat_id, '-100');
  assert.equal(b.parse_mode, 'HTML');
  assert.equal(b.disable_web_page_preview, true);
  assert.equal(
    b.text,
    '🧪 <b>Beta 0.1.2-beta.3</b> · build 3039\n\nFix &lt;a&gt; &amp; b\nsecond line',
  );
  assert.deepEqual(b.reply_markup, { inline_keyboard: [[{ text: 'Скачать', url: 'https://example.com/a?x=1&y="2"' }]] });
  const marker = objects.get('_release/beta/0.1.2-beta.3+3039');
  assert.ok(marker);
  assert.equal(marker.ttl, 30 * 24 * 3600);

  const http = tgStub();
  await handle(rel({ ...goodBeta, build: 4, url: 'http://example.com/a' }), env, ctx(), { fetch: http.fetchStub });
  assert.equal(http.calls[0]!.body.reply_markup, undefined);
});

test('release: stable text', async () => {
  const { env } = fakeEnv(REL_ENV);
  const { fetchStub, calls } = tgStub();
  const r = await handle(
    rel({ channel: 'stable', version: '0.2.0', build: 4000, notes: 'Big one', url: 'https://example.com/r' }),
    env,
    ctx(),
    { fetch: fetchStub },
  );
  assert.equal(r.status, 200);
  assert.equal(
    calls[0]!.body.text,
    '🚀 <b>Jormungand 0.2.0</b> — стабильная версия\n\nBig one',
  );
});

test('release: visible text is cut to 4096 with an ellipsis', async () => {
  const { env } = fakeEnv(REL_ENV);
  const { fetchStub, calls } = tgStub();
  await handle(rel({ ...goodBeta, notes: 'ab '.repeat(3000), url: 'https://example.com/r' }), env, ctx(), { fetch: fetchStub });
  const html = String(calls[0]!.body.text);
  const visible = html.replace(/<[^>]+>/g, '');
  assert.ok(visible.length <= 4096, String(visible.length));
  assert.ok(visible.length > 4000);
  assert.ok(html.endsWith('…'));
  // экранируемые символы считаются как один видимый
  const amp = tgStub();
  await handle(rel({ ...goodBeta, build: 5, notes: '&'.repeat(5000) }), env, ctx(), { fetch: amp.fetchStub });
  const t = String(amp.calls[0]!.body.text);
  assert.ok(t.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').length <= 4096);
  assert.ok(t.endsWith('…'));
});

test('release: duplicate is not sent twice', async () => {
  const { env } = fakeEnv(REL_ENV);
  const { fetchStub, calls } = tgStub();
  assert.equal((await handle(rel(goodBeta), env, ctx(), { fetch: fetchStub })).status, 200);
  const r = await handle(rel(goodBeta), env, ctx(), { fetch: fetchStub });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true, duplicate: true });
  assert.equal(calls.length, 1);
});

test('release: telegram failure is 502 and leaves no marker', async () => {
  const { env, objects } = fakeEnv(REL_ENV);
  const { fetchStub } = tgStub(false);
  const r = await handle(rel(goodBeta), env, ctx(), { fetch: fetchStub });
  assert.equal(r.status, 502);
  assert.deepEqual(await r.json(), { ok: false, error: 'telegram', description: 'chat not found' });
  assert.equal(objects.size, 0);
  const boom = (async () => {
    throw new Error('net down');
  }) as unknown as typeof fetch;
  const r2 = await handle(rel(goodBeta), env, ctx(), { fetch: boom });
  assert.equal(r2.status, 502);
  assert.equal(objects.size, 0);
});

test('release: RELEASE_CHAT_ID overrides the chat', async () => {
  const { env } = fakeEnv({ ...REL_ENV, RELEASE_CHAT_ID: '-200' });
  const { fetchStub, calls } = tgStub();
  await handle(rel(goodBeta), env, ctx(), { fetch: fetchStub });
  assert.equal(calls[0]!.body.chat_id, '-200');
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
