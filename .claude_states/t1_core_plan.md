# т1, этап ядра — план для workflow `code-task`

Спецификация: `docs/logs.md` → «Каталог типов» (строки ~83–208) и «Событие в приложении» (~209–435). Приложение
(`app/`) в этом этапе НЕ трогается: оно читает новые поля позже, отдельным этапом. Пока приложение не обновлено, оно
продолжает писать свои `sub/*` — ядро не должно от этого ломаться.

## Общий контракт (все юниты держатся его)

- `EventRecord` / `EventBook.add` (`core/lib/src/log_view.dart`, `core/lib/src/eventbook.dart`): два новых поля
  верхнего уровня, рядом с `cause`:
  - `op: {id: String, kind: String}` — операция; `EventBook.add(..., Map<String, Object?>? op)`;
  - `opens: int` — у закрывающего события пары id открывающего; `EventBook.add(..., int? opens)`.
  Оба сериализуются в строку журнала, читаются `EventRecord.fromJson`, отдаются в `/api/events`, переживают `update()`
  и `repeated()`. Нет поля — не пишется.
- `op.kind`: `reconnect`, `connection` (ручное отключить → подключить), `subUpdate`, `subUpdateAll`, `ruleSets`,
  `appUpdate`, `speed`. id — строка, уникальная за жизнь журнала (например `<kind>-<seq>`).
- Новые типы каталога: `conn/reconnected`, `net/switched` (новая категория `net` в `eventCats`, после `conn`).

## Юниты

### u-book (fast) — `core/lib/src/eventbook.dart`, `core/lib/src/log_view.dart`
- поля `op`, `opens` (контракт выше);
- `eventCats`: `conn/reconnected`, категория `net` с `switched`;
- `eventNotifKind`: `conn/connectFailed`, `conn/disconnected`, `core/tunNeedsAdmin`, `core/sysProxy` → `connLost`;
  `core/stateLost`, `core/stateRestored` → `appData`; `dns/failed` → `dnsFailed`. `notifDefaults`: `appData: true`,
  `dnsFailed: true`;
- `eventNotifies`: `conn/disconnected` уведомляет только при `by: 'error'`, `core/sysProxy` — только с `error`;
- `const journalOnly = <String, String>{type: причина}` для warn / error без уведомления: `dns/failedOnNode`,
  `core/deprecated`, `speed/failed`, `core/updateFailed`, `core/updateDeltaFailed`, `core/updateChannelEmpty`,
  `sub/diverged`, `net/switched` (info, но перечислен явно). Комментарий — что это и что проверяет сторожевой тест.

### u-net (deep) — новый `core/lib/src/netswitch.dart`, `core/lib/src/exitip.dart`
- `exitip.dart`: `Future<({String ip, String? org})?> directIsp({Duration timeout})` — запрос к сервисам из
  `exitProbes`, отдающим организацию (ipwho.is `connection.org`, ipinfo `org` без префикса AS, ip-api `org`/`isp`),
  строго напрямую (DIRECT, мимо туннеля), первый ответивший с org; существующее поведение `checkExitIp` не меняется.
- `netswitch.dart` — чистая логика без ввода-вывода (lookup передаётся):
  ```dart
  class NetInfo { final String type; final String? id; final String? operator; final bool? metered; }
  class NetSwitchTracker {
    NetSwitchTracker({required Future<({String ip, String? org})?> Function() lookup,
                      required bool Function() providerEnabled, DateTime Function()? now});
    void onNetwork(NetInfo? net, DateTime at);       // каждое изменение сети от платформы; null — сети нет
    Future<Map<String, Object?>?> onSettled();        // сеть устоялась: data для net/switched или null
  }
  ```
  Смена = другой `type` или другой `id` при том же типе относительно последней устоявшейся сети; провал с возвратом в
  ту же сеть — не смена; первая сеть после старта — не смена. `data`: `{from, to}`, каждое `{type, provider?,
  operator?, metered?}`, `downMs`, если между сетями сети не было. `provider` — только для wifi / ethernet и только
  при `providerEnabled()`; кэш по id сети, новый lookup — если ответ дал другой IP (кэш хранит IP) или id новый.
  Мобильная — `operator` из `NetInfo`, без lookup.

### u-core (deep) — `core/lib/src/service.dart`, `core/lib/src/updater.dart`, `core/lib/src/rulesets.dart`,
`core/lib/src/api.dart`, `core/lib/src/daemon.dart`, `core/lib/src/dns_failover.dart`, `core/lib/src/sentinel/*`,
файл настроек ядра (где лежат прочие настройки Connection)
Использует контракт u-book и интерфейс u-net (пишет против них, как описано выше).
1. `conn/reconnected` вместо `conn/connected` при собственном переподключении живого подключения (`_connect` с
   `reason` settings / lists / reresolve; найти все пути): `{reason, changed?, tookMs}` + `op {kind: reconnect}`;
   события внутри переподключения (`core/sysProxy`, `core/deprecated`, `rules/ruleSetUpdated`) несут тот же `op`.
2. Ручное: `conn/disconnected` по команде пишет `op {kind: connection}`; команда connect в течение 7 с после него →
   `conn/reconnected {reason: 'user', tookMs, downMs}` с тем же `op.id` вместо `conn/connected`.
3. `conn/disconnected by: 'error'`: `reason: 'down'` (sing-box не поднялся после всех попыток), `reason: 'pinLost'`
   (`pick`, `why`) — найти путь потери Manual-пина (сейчас пишется `by: 'user'`).
4. `core/restartFailed`: на каждую попытку (снять `_attempt <= _backoff.length`), level error; повторы —
   `EventBook.repeated` на одном событии; `cause` — id `core/crashed` (как сейчас). `core/restarted` — `opens` = id crashed.
5. Фоновый `core/updateFailed` — warn. `core/deprecated`: повтор того же текста за запуск — `repeated` (счётчик), не
   молчание. События обновления приложения одного цикла — `op {kind: appUpdate}`.
6. `opens` у всех закрывающих пар: `conn/restored`←`lost`, `online`←`offline`, `core/restarted`←`crashed`,
   `core/tunTcpBack`←`tunTcpDead`, `rules/targetBack`←`fallback`, `rules/targetFound`←`targetLost`,
   `sub/back`←`removed`, `auto/switched reason: back`←failover того же маршрута, `dns/switched reason: back`←failover
   той же стороны.
7. `cause` (корни; уведомляет только корень): `conn/lost`, `site/*`, `conn/failing`, `sub/failed`,
   `rules/ruleSetFailed` под `conn/offline` (проверить, что уже так); `conn/failing` — под `site/*` того же адреса в
   том же окне; `rules/fallback` — под `rules/targetLost` той же цели; `dns/failedOnNode` — под `dns/failed` того же
   сервера; переключения записи под `auto/unstable`; серия `auto/switched` одной беды — под первым; отказ ноды X:
   первое событие инцидента (`auto/switched` failover / `rules/fallback` / `dns/switched node`) — корень, остальные
   события того же инцидента — `cause` на него; `auto/fastest` — повторы на маршрут (`repeated`).
8. `net/switched`: создать `NetSwitchTracker`, кормить его изменениями сети из того же источника, что Sentinel
   context (платформа / ОС), `onSettled` — когда context объявил сеть устоявшейся; событие info, корень для событий в
   окне смены (переподключение, `dns/switched`, `auto/switched`, сбои). Платформенное состояние сети принимает
   необязательное `operator` (приложение передаст позже). Настройка `detectNetProvider` (bool, по умолчанию true) —
   рядом с настройками Connection, в снимке настроек и в API настроек.
9. `sub/*` — один автор: ручное обновление (`POST /api/sources/fetch` → `fetchSource`) пишет `sub/updated` /
   `sub/failed` / `sub/removed` / `sub/back` само, `own: true`, без Sentinel, `op {kind: subUpdate}`; «обновить все» и
   тик автообновления по нескольким подпискам — общий `op {kind: subUpdateAll}`. Поля по `logs.md` → «Один автор
   `sub/*`» (`names` ≤ 10, `inUse`). `sub/removed` / `back` пишет ядро (сейчас не пишет). `sub/failed`: каждый
   подтверждённый сбой; пока `lastError` тот же — `repeated`, другая ошибка — новое событие (снять тихий потолок).
   Сбой из-за своего перезапуска (`RetryKind.ownRestart`) — ни события, ни `lastError`, повтор после `settled`, и для
   ручного тоже (ответ API даёт статус «ждёт подключения»). Ответ API для приложения не ломать.
10. `rules/ruleSetFailed`: поле `copyAt` при `hasCopy`; несколько списков одной операции — общий `op {kind: ruleSets}`;
    пачка `ruleSetUpdated` — тот же `op`.
11. `speed/*` при замере группы — `op {kind: speed}` (если замер в ядре).

## Тесты (test-writer-deep) — `core/test/event_catalog_test.dart`, `core/test/events_t1_test.dart`, `core/test/netswitch_test.dart`
- сторож: каждый warn / error тип каталога — либо в `eventNotifKind`, либо в `journalOnly`; `net/switched`,
  `conn/reconnected` в каталоге;
- `op` / `opens` переживают запись, чтение с диска, `update`, `repeated`;
- `eventNotifies`: `disconnected` только `by: error`; `sysProxy` только с `error`; `appData`, `dnsFailed` по умолчанию вкл.;
- `NetSwitchTracker`: смена типа, смена id, провал с возвратом — нет события, первая сеть — нет, `downMs`, provider
  только wifi/ethernet и только при `providerEnabled`, кэш по id и IP, мобильная — operator без lookup;
- `restartFailed` без потолка и error (через существующие тестовые обвязки сервиса, если есть; иначе — пропустить);
- поведение сервиса, которое есть чем проверить без сети и sing-box.
