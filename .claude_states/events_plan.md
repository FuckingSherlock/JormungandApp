# События — план по тирам (решения пользователя 2026-10-17)

Источник пунктов и пути в коде — `events_audit.md` (номера § ниже — его). Скрины текущего вида:
`cd app; flutter test test/_shots/event_shots_test.dart --run-skipped` → `app/build/event_shots/` (перегенерировать после
изменений). Порядок: т1 → т1.5 → т2 → т3. Пункт сделан — строкой в `archive/done.md` и удаляется отсюда.

## т1 — неполные события (аудит §2, «делать всё»), вместе с доками (§3)

1. «Почему» в UI: показывать `verdict` / `cause` / `why` / `trail` (в модель приложения `why`/`trail` сейчас не читаются),
   следствия сворачивать под корень (F «Этап 4 Sentinel», F «Единый вид событий о сбоях»).
2. Слабые тексты: `conn/lost` (одна фраза), `conn/offline` (не учитывает `data.source`), `core/crashed` (не различает
   отзыв VPN), `ruleSetFailed` «last copy» без `hasCopy`, l10n подписей Auto/Proxy/Direct.
3. Действия: `conn/failing` (нет кнопок), `node/addressMissing` (нет Open), `conn/connectFailed` / `core/tunNeedsAdmin` /
   `core/down` / `core/crashed` (Retry, Open settings, Remove system proxy при `proxy:'kept'`), `rules/ruleSetFailed`
   (Retry), `core/stateLost` / `stateRestored` (Send report), `dns/failed` (Switch server / Check now), `sub/removed`
   (список пропавших, отметка «используемый»), кнопки в системных уведомлениях не только у `site/*`.
4. Категории уведомлений для error/warn-событий без неё (`conn/connectFailed`, `core/tunNeedsAdmin`, `core/stateLost`,
   `stateRestored`, `core/sysProxy` с ошибкой, `core/deprecated`, `dns/*`, `speed/failed`, `core/update*`).
5. Один корень — одна запись: авария ядра (`crashed` → `restartFailed` ×N → `down` → `restarted`), `conn/failing` vs
   `site/unreachable`, следствия отсутствия сети, `dns/failed` vs `dns/failedOnNode`, `rules/fallback` vs
   `rules/targetLost` (оба под `autoSwitch`).
6. Тихие потолки (против «не прятать проблемы»): `restartFailed` пишется только `_attempt <= _backoff.length`;
   `sub/failed` — только первый после удачного. Повторы — видимой свёрткой.
7. Уровни и атрибуция: `restartFailed` info (доки: error), фоновый `updateFailed` info; `conn/disconnected by:'error'`
   описан, но не пишется — потеря Manual-пина сейчас записана как `by:'user'` (запись неверна независимо от т3 п. 1).
8. Два автора `sub/*` (ядро с вердиктом, приложение без) — один набор полей.
9. Доки: таблица событий `docs/core.md` (~1389–1425) — недостающие типы, устаревшие `conn/lost` / `conn/offline` /
   `restartFailed`; `docs/logs.md` — поле `repeat` у `site/*`. Каталог-мокап: `sub/dead` пишется только мокапом.

## т1.5

- Раскидать события по категориям (формулировка пользователя; уточнить с ним вид — фильтр/группы в Logs и/или категории
  уведомлений — перед брифом).

## т2

1. Captive portal: своего события не нужно — у Android есть системное уведомление. Проверить на телефоне, что оно
   приходит при поднятом VPN. Корень Sentinel `net.captive` (свёртка следствий) остаётся.
2. VPN отозван другим VPN / системой: события не нужно; убрать попытки перезапуска после отзыва (сейчас `onRevoke` →
   `core/crashed {code:0}` → `restartFailed` ×N → `core/down`, аудит §1.3). Бывший `to_think.md` S7.

## т3

1. Потеря Manual-пина — отдельное событие: нужно ли, пользователь не уверен (сейчас тост `connectFailed`).
2. События + уведомления (по умолчанию выкл): срок / трафик подписки (истекает, истёк, на исходе, кончился); смена IP выхода
   / неожиданная страна; включён Android Private DNS; служба убита экономией батареи.

## Решено не делать

- Сбои только тостом (`reconnectFailed`, `initFailed`, `notSaved`, `vpnDenied`, `connectFailed` от retry/disconnect/
  настроек, `updateCheckFailed`, аудит §1.12) — остаются всплывашками, без записи в журнал.

## Без тира (не было в списке на решение)

Аудит §1.2 (нет интернета vs сервер мёртв; частично F «Разбор ложных сигналов»), §1.9 (интерфейс TUN исчез при живом
sing-box; T S40), §1.10 (не удалось подхватить работающий туннель — только Raw), §1.11 (системный прокси остался;
F «Kill switch на Android»), §1.13 (смена типа сети без события), §1.14 (подписка опустела / резко урезана).
