import { handle, type Env } from './handler.ts';
import { hit, type Store, type Verdict } from './limiter.ts';

interface RuntimeEnv {
  REPORTS: Env['REPORTS'];
  LIMITER: {
    idFromName(n: string): unknown;
    get(id: unknown): { fetch(url: string, init?: RequestInit): Promise<Response> };
  };
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;
}

export default {
  async fetch(request: Request, env: RuntimeEnv, ctx: ExecutionContext): Promise<Response> {
    const limiter = env.LIMITER.get(env.LIMITER.idFromName('global'));
    const e: Env = {
      REPORTS: env.REPORTS,
      TELEGRAM_BOT_TOKEN: env.TELEGRAM_BOT_TOKEN,
      TELEGRAM_CHAT_ID: env.TELEGRAM_CHAT_ID,
      async limit(ipKey: string): Promise<Verdict> {
        try {
          const r = await limiter.fetch(`https://limiter/hit?k=${ipKey}`);
          return (await r.json()) as Verdict;
        } catch {
          return { ok: true }; // отказ счётчика не должен ронять приём отчётов
        }
      },
    };
    return handle(request, e, ctx);
  },
};

/** Один экземпляр на весь Worker: последовательная обработка = точные счётчики без гонок. */
export class Limiter {
  private state: DurableObjectState;
  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const k = new URL(request.url).searchParams.get('k') ?? 'unknown';
    const st = this.state.storage;
    const store: Store = {
      get: async (key) => (await st.get<number>(key)) ?? undefined,
      put: async (key, value) => void (await st.put(key, value)),
      delete: async (keys) => void (await st.delete(keys)),
      list: async (prefix) => [...(await st.list({ prefix })).keys()],
    };
    const verdict = await hit(store, k, Date.now());
    return new Response(JSON.stringify(verdict), { headers: { 'content-type': 'application/json' } });
  }
}
