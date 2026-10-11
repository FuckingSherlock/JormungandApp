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

Ещё необязательные заголовки (неверные значения молча игнорируются):

| Заголовок | Значение |
|---|---|
| `X-Jorm-Note` | заметка пользователя: base64url без паддинга от UTF-8, ≤ 500 символов (заголовок ≤ ~4 KB). Не UTF-8 / не base64url → игнорируется. Текст идёт **только в Telegram**, в KV не пишется |
| `X-Jorm-Via` | `vpn` или `direct` — каким путём отправлено |
| `X-Jorm-Vpn` | `on` или `off` — был ли включён VPN |

| Ответ | Когда |
|---|---|
| 200 `{"ok":true,"id":"20261010-k3x9ab"}` | сохранено |
| 400 | тело не начинается с `JRP1` / некорректный Content-Length |
| 413 | пусто или > 4 MiB (проверяются и `Content-Length`, и реально прочитанные байты) |
| 415 | не `application/octet-stream` |
| 429 + `Retry-After` | лимит запросов |
| 500 | сбой хранилища / не удалось подобрать id |

`GET /v1/ping` → `{"ok":true}` (старые приложения). `POST /v1/ping` — пробный обмен: читает тело (≤ 64 KiB,
иначе 413) и отвечает 200 `application/octet-stream` ровно на 32768 байт; приложение считает пробу
пройденной только при получении всех 32 KiB (DPI замораживает соединения после ~16 KB). Лимитером ни тот,
ни другой ping не считаются. Всё остальное — 404. Тела и IP не логируются; IP используется только как
ключ лимита (усечённый SHA-256 с солью).

`id` = `YYYYMMDD-` + 6 случайных символов из `[a-z2-9]` (crypto-random, без смещения, с проверкой
коллизии по KV).

## Хранение

Workers KV, namespace `jormungand-reports` (binding `REPORTS`):

- ключ `YYYY/MM/<id>`;
- значение — конверт как есть (≤ 4 MiB, лимит KV 25 MiB);
- `metadata`: `format`, `version`, `build`, `platform`, `clientSize`, `via`, `vpn`, `noteLength`
  (присутствуют только полученные; сам текст заметки не хранится), `receivedAt` (ISO), `size` (реальный размер);
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

Токен бота не хранится в репозитории; ставится один раз из этой папки (не из корня — иначе секрет
попадёт на другой Worker):

```sh
cd workers/reports
npx wrangler secret put TELEGRAM_BOT_TOKEN   # токен бота от @BotFather
```

`TELEGRAM_CHAT_ID` — не секрет, лежит в `vars` файла `wrangler.jsonc` (id группы отрицательный,
`-100…`). Пока токена нет, Worker молча пропускает уведомление — отчёт всё равно сохраняется. Сбой
Telegram загрузку не ломает. Уведомление — `sendDocument`: конверт файлом `<id>.jrp` и подпись
(`parse_mode: HTML`, значения экранируются, видимый текст ≤ 1024, заметка при нехватке места режется с «…»):

```
🐞 Report 20261011-gc75wr
Android · 0.1.2-beta.3 (3039) · 106 KB
VPN on · sent via VPN
> заметка пользователя        (или «no note» курсивом)
```

Отсутствующие части опускаются. Если `sendDocument` не удался (отказ или сеть) — тот же текст уходит
`sendMessage`.

Итог последней отправки (без токена) Worker кладёт в KV под ключом `_notify/last` (7 суток):
`npx wrangler kv key get --binding REPORTS --remote "_notify/last"` → `{at, id, method, status, ok, description}`;
при отказе Telegram добавляются `bot` (кто это) и `seenChats` (чаты из `getUpdates`, по ним находится
верный chat id). `chat not found` — бот не знает этот чат: добавить бота в группу и дать право читать
сообщения / написать в группу.

## Получение отчёта разработчиком

```sh
cd workers/reports
node tools/fetch.mjs                                  # 20 новых отчётов (id, время, платформа, размер)
node tools/fetch.mjs --n 50                           # 50 новых
node tools/fetch.mjs 20261010-k3x9ab x.bin            # скачать конверт по id в x.bin
dart run core/tool/decrypt_report.dart x.bin          # из корня репозитория
node tools/fetch.mjs 20261010-k3x9ab --open           # скачать и расшифровать одной командой
node tools/fetch.mjs --latest --open                  # то же для самого свежего отчёта
```

`--open` кладёт конверт в `core/.data-dev/reports/<id>.jrp` (папка в .gitignore), запускает из `core/`
`dart run tool/decrypt_report.dart` дважды (`<id>.txt` с `--text` и `<id>.json`) и печатает три пути.
Приватный ключ читает только decrypt-инструмент, помощник его не трогает.

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
