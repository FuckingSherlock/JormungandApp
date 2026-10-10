// Логика лимитов без привязки к Workers-рантайму (тестируется под node).
// Счётчики хранятся по ключам "h:<ip-hash>:<час>", "d:<ip-hash>:<сутки>", "g:<сутки>".

export interface Limits {
  perHour: number;
  perDay: number;
  globalPerDay: number;
}

export const LIMITS: Limits = { perHour: 10, perDay: 50, globalPerDay: 500 };

export interface Store {
  get(key: string): Promise<number | undefined>;
  put(key: string, value: number): Promise<void>;
  delete(keys: string[]): Promise<void>;
  list(prefix: string): Promise<string[]>;
}

export type Verdict = { ok: true } | { ok: false; retryAfter: number };

/** Атомарность даёт вызывающий: Durable Object обрабатывает запросы последовательно. */
export async function hit(store: Store, ipKey: string, now: number, limits: Limits = LIMITS): Promise<Verdict> {
  const hour = Math.floor(now / 3_600_000);
  const day = Math.floor(now / 86_400_000);
  const kh = `h:${ipKey}:${hour}`;
  const kd = `d:${ipKey}:${day}`;
  const kg = `g:${day}`;
  const [h, d, g] = await Promise.all([store.get(kh), store.get(kd), store.get(kg)]);
  const toHour = Math.max(1, Math.ceil(((hour + 1) * 3_600_000 - now) / 1000));
  const toDay = Math.max(1, Math.ceil(((day + 1) * 86_400_000 - now) / 1000));
  if ((g ?? 0) >= limits.globalPerDay) return { ok: false, retryAfter: toDay };
  if ((d ?? 0) >= limits.perDay) return { ok: false, retryAfter: toDay };
  if ((h ?? 0) >= limits.perHour) return { ok: false, retryAfter: toHour };
  await Promise.all([
    store.put(kh, (h ?? 0) + 1),
    store.put(kd, (d ?? 0) + 1),
    store.put(kg, (g ?? 0) + 1),
  ]);
  // Уборка устаревших ключей — не при каждом обращении.
  if (now % 20 === 0) await sweep(store, hour, day);
  return { ok: true };
}

async function sweep(store: Store, hour: number, day: number): Promise<void> {
  const stale: string[] = [];
  for (const k of await store.list('h:')) if (Number(k.split(':')[2]) < hour) stale.push(k);
  for (const k of await store.list('d:')) if (Number(k.split(':')[2]) < day) stale.push(k);
  for (const k of await store.list('g:')) if (Number(k.split(':')[1]) < day) stale.push(k);
  while (stale.length) await store.delete(stale.splice(0, 128));
}
