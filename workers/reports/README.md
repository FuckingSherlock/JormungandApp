# jormungand-reports

Cloudflare Worker, принимающий зашифрованные отчёты поддержки из приложения («Send report»), кладущий их
в Workers KV и уведомляющий разработчика в Telegram. Worker **ничего не расшифровывает**: тело — непрозрачные
байты (конверт `JRP1…`), открыть его может только приватный ключ разработчика.

URL: `https://jormungand-reports.slackerwarlock.workers.dev`

## Контракт

`POST /v1/report`, `Content-Type: application/octet-stream`, тело — конверт, начинается с `JRP1`.
Заголовки — простые метаданные, санитизируются (`[A-Za-z0-9 ._+-]`) и режутся по длине:
`X-Jorm-Format`, `X-Jorm-Size` клиент шлёт всегда; `X-Jorm-Version`, `X-Jorm-Build`, `X-Jorm-Platform`
**необязательны** (клиент опускает отсутствующие; Worker их не требует и пустые в metadata не пишет).

| Ответ | Когда |
|---|---|
| 200 `{"ok":true,"id":"20261010-k3x9ab"}` | сохранено |
| 400 | тело не начинается с `JRP1` / некорректный Content-Length |
| 413 | пусто или > 4 MiB (проверяются и `Content-Length`, и реально прочитанные байты) |
| 415 | не `application/octet-stream` |
| 429 + `Retry-After` | лимит запросов |
| 500 | сбой хранилища / не удалось подобрать id |

`GET /v1/ping` → `{"ok":true}`. Всё остальное — 404. Тела и IP не логируются; IP используется только как
ключ лимита (усечённый SHA-256 с солью).

`id` = `YYYYMMDD-` + 6 случайных символов из `[a-z2-9]` (crypto-random, без смещения, с проверкой
коллизии по KV).

## Хранение

Workers KV, namespace `jormungand-reports` (binding `REPORTS`):

- ключ `YYYY/MM/<id>`;
- значение — конверт как есть (≤ 4 MiB, лимит KV 25 MiB);
- `metadata`: `format`, `version`, `build`, `platform`, `clientSize` (присутствуют только полученные),
  `receivedAt` (ISO), `size` (реальный размер);
- `expirationTtl` = 90 дней — запись удаляется сама, отдельное lifecycle-правило не нужно.

Лимиты KV на free-плане: 1000 записей и 1000 list-операций в сутки; глобальный лимит Worker'а
(500 отчётов/сутки) под них подогнан.

## Лимиты

Один Durable Object `Limiter` (SQLite-backed — доступен на free-плане), один экземпляр на весь Worker.
Он обрабатывает запросы строго последовательно, поэтому счётчики точные и без гонок; все три окна
считаются за одно обращение:

- на IP: 10 отчётов / час и 50 / сутки;
- глобально: 500 / сутки (защита KV и Telegram-бота).

Окна календарные (UTC-час и UTC-сутки), `Retry-After` — секунды до конца окна. Старые счётчики
подчищаются периодически. Почему не Rate Limiting binding + KV: binding считает окна 10/60 с и не
подходит для часа/суток, а KV не атомарен (гонки при параллельных запросах); DO даёт и то и другое одним
механизмом. Если сам счётчик недоступен, приём не падает (fail-open).

## Секреты (Telegram)

Не хранятся в репозитории; ставятся один раз:

```sh
cd workers/reports
npx wrangler secret put TELEGRAM_BOT_TOKEN   # токен бота от @BotFather
npx wrangler secret put TELEGRAM_CHAT_ID     # id чата (см. ниже)
```

Узнать chat id: написать боту любое сообщение, затем

```sh
curl -s https://api.telegram.org/bot<TOKEN>/getUpdates
```

и взять `result[0].message.chat.id`. Пока секретов нет, Worker молча пропускает уведомление — отчёт
всё равно сохраняется. Сбой Telegram загрузку не ломает. Текст уведомления:
`Jormungand report <id> · <platform> <version> (<build>) · <size> KB` (отсутствующие поля — `?`).

Итог последней отправки (без токена) Worker кладёт в KV под ключом `_notify/last` (7 суток):
`npx wrangler kv key get --binding REPORTS --remote "_notify/last"` → `{at, id, status, ok, description}`.
`chat not found` — бот не знает этот чат: нужно сначала написать боту `/start` из чата с этим id (или
добавить его в группу, id группы — отрицательный, `-100…`).

## Получение отчёта разработчиком

```sh
cd workers/reports
node tools/fetch.mjs                                  # 20 новых отчётов (id, время, платформа, размер)
node tools/fetch.mjs --n 50                           # 50 новых
node tools/fetch.mjs 20261010-k3x9ab x.bin            # скачать конверт по id в x.bin
dart run core/tool/decrypt_report.dart x.bin          # из корня репозитория
```

Без помощника то же вручную (из `workers/reports`):

```sh
npx wrangler kv key list --binding REPORTS --remote
npx wrangler kv key get 2026/10/20261010-k3x9ab --binding REPORTS --remote > x.bin
npx wrangler kv key delete 2026/10/20261010-k3x9ab --binding REPORTS --remote   # удалить досрочно
```

## Разработка и деплой

```sh
npm test              # node --test (Node >= 22.18, TS без сборки), без сети
npx wrangler deploy   # из этой папки
```

Namespace создан командой `npx wrangler kv namespace create jormungand-reports`, его id записан в
`wrangler.jsonc`. В GitHub-workflow деплоя макета этот Worker не подключён.
