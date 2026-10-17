# «VPN не работает» — ядро (план прогона code-task)

Решение пользователя 2026-10-17. Спецификация поведения — `docs/logs.md`:
- раздел «### «VPN не работает» (`conn/vpnDown` / `vpnUp`)» (ищи заголовок; это главный текст);
- «### Свёртки» — механизм 5 «Вливание» (`joins`) и механизм 2 (последний абзац: закрывающее заменяет показанное
  уведомление при любом переключателе);
- «Каталог типов» — строки `conn/vpnDown` / `vpnUp`, `conn/offline` / `online`, `core/crashed`, `core/down`;
- «По типам» — строки `conn/vpnDown`, `conn/lost`, `conn/offline`, `core/crashed …`.
`docs/failures.md` — таблица «Что и как идёт через шлюз» (строки `conn/vpnDown`, `conn/offline`, `core/down`),
абзацы «Сеть», «Падение ядра», «„VPN не работает“ поверх корней», `attachEvent` в «Корни».
`docs/core.md` → «Down» (`status.down` остаётся как есть).

Коротко, что меняется:
1. Пока пользователь подключён, первая устоявшая причина — `core` (сейчас момент `_goDown`, 30 с после падения) или
   `network` (сейчас `_netOfflineStands`, корень `net.offline` простоял `netBlip`) — пишет ОДНО событие
   `conn/vpnDown` (error, `verdict: confirmed`, `why` = `core.down` / `net.offline` по первой причине, `trail` — её
   шаг: `ctx.core {phase: down}` / `ctx.net {state: none, source}`), `data: {causes: [...], proxy?, source?}`.
   Оба корня Sentinel (`core.down`, `net.offline`) — `sentinel.attachEvent(root, id)` на это же событие; корень,
   открывшийся позже, — тоже сразу на него.
2. Вторая причина появилась / одна ушла, пока другая стоит — `eventBook.update(id, data: …)` (`causes`, `proxy`,
   `source`), без нового события.
3. Ни одной причины (ядро `restarted` и сеть есть; или наоборот), или пользователь отключился — `conn/vpnUp`
   (info, `opens` = id `vpnDown`, `data: {downMs, causes: <все причины за время сбоя>, by?: 'user'}`).
4. Причина `core`: событие падения (`core/crashed` текущего падения) указывается в `vpnDown` полем верхнего уровня
   `joins: [crashId]` — при открытии `vpnDown` по `core` или при добавлении причины `core` к открытому
   (`update(id, joins: …)`).
5. `core/down`, `conn/offline` warn (стоячий) и `conn/online` при подключении больше не пишутся. Без подключения —
   пара `conn/offline` / `conn/online` **info** (стоячий offline был warn → теперь info), `blip` как был. Подключение
   при стоящем `offline` закрывает пару без `online` и сразу открывает `vpnDown` (`network`).
6. Пока `vpnDown` открыт: любое warn / error, записанное в журнал без `cause` любым писателем (service `_event`,
   прямые `eventBook.add`, апдейтер, Sentinel), кроме `own: true`, самих `conn/vpnDown` / `vpnUp`, событий падения
   (`core/crashed`, `restartFailed`, `restarted` — они вливаются через `joins`) и `core/stateLost`,
   `core/stateRestored`, `core/deprecated`, получает `cause` = id `vpnDown` и `verdict: 'consequence'` (одна точка
   на все писатели, например хук в `EventBook.add`, который ставит сервис).
7. Уведомления (`log_view.dart`): `conn/vpnDown`, `conn/vpnUp` → `connLost`. `core/crashed`, `restarted`,
   `restartFailed`, `conn/offline`, `conn/online` — убрать из `eventNotifKind`, warn/error среди них — в `journalOnly`
   с причиной; `core/down` оставить в каталоге (старые журналы), убрать из `eventNotifKind` → `journalOnly`
   ('no longer written; replaced by conn/vpnDown'). `notifDefaults` — без `coreCrash`. Каталог `eventCats`:
   `conn` + `vpnDown`, `vpnUp`.
8. Свёртка `foldEvents`: механизм 5 — событие с `joins` вливает строки перечисленных id (их `items`, повторы,
   следствия, закрытие) в свою строку; влитая строка исчезает из `rows`; `byId` влитых событий указывает на новую
   строку, так что поздние следствия / повторы / `opens` влитого ложатся туда же; `opens` влитого события (например
   `core/restarted` → `core/crashed`) внутри — шаг (`_relate`), строку НЕ закрывает; закрывает только закрывающее
   самого вливающего (`conn/vpnUp`). Id из `joins`, которого нет в журнале, игнорируется. `EventRecord.joins`
   (`List<int>?`, из JSON `joins`).
9. Правило закрывающего (`EventFeed`): закрывающее событие (`opens != null`) уведомляет, если уведомление с id
   `opens` уже показано (открывающим, или его следствием, обновившим его на месте), — при любом своём
   переключателе. Нужна одна функция в ядре, которую зовёт приложение вместо пары
   `eventNotifies(cfg, e) && feed.markNotified(e.id)` (`app/lib/core/logs_controller.dart:270`): например
   `bool EventFeed.notify(Object? cfg, EventRecord e)` — помнит id уведомления (`opens ?? cause ?? id`, как
   `SystemNotifier.postEvent`) и возвращает true один раз на событие. Приложение переключит вызов в своём прогоне.

## Куски

### A (deep) — сервис и журнал: `core/lib/src/service.dart`, `core/lib/src/eventbook.dart`
Пункты 1–6. `eventbook.dart`: параметр `joins` у `add` / `update` (поле верхнего уровня, как `opens`), хук пункта
6. `service.dart`: жизненный цикл сбоя (`_goDown`, `_syncNetEvents` / `_netOfflineStands`, ветка `restarted` в
`_recover`, `connect` / `disconnect`, `_crashed`), поле состояния открытого сбоя (id, причины, причины за всё время,
since). `status.down` и логика системного прокси при down не меняются. `sub/failed` при down (`_SubAbort`, сейчас
`cause: roots.byKind(rootCoreDown)?.eventId`) получает id `vpnDown` естественно через `attachEvent`.

### B (deep) — свёртка и уведомления: `core/lib/src/log_view.dart`
Пункты 7–9. Каталог, `eventNotifKind`, `journalOnly`, `notifDefaults`, `EventRecord.joins`, `foldEvents` (механизм
5), `EventFeed.notify` (правило закрывающего; `markNotified` остаётся для совместимости или удаляется, если
вызывает только приложение — тогда приложение переключится в своём прогоне, ядро не должно ломать его компиляцию
до того: оставь `markNotified`).

Стык A↔B: поле `joins` в JSON события (список int), типы `conn/vpnDown` / `conn/vpnUp`, ключи `data`.
