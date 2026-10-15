# Этап 2 — connect по свежей проверке, селектор вместо urltest (схема analyzer, 2026-10-15)

Рабочий файл этапа: удалить, когда этап закрыт (итог — в `archive/done.md`).

## Как сейчас
- `service.dart:2800 _connect` → `_stopAuto` → `_locked` → `_startSingBox` (`:2528 buildConfig`) → `_startAuto` (`:1196`); проверки кандидатов нет.
- `planGroup` (`plan_builder.dart:51-71`): Fastest — `stableSorted(ok, pings.rank)`; `chosen` только для priority.
- `config.dart:272-291`: не-priority → `urltest` из всех нод, без `default` → трафик через первый член до конца первого раунда (`bugs.md` Auto).
- `address_pin.dart:132 startHostnames` ждёт адреса ВСЕХ членов главной группы.
- Auto (`auto.dart`): переключает селектор `proxy` между маршрутами; внутри группы меряет только `g.current` (`_checkGroup :1349`). Priority — `failAfter`, `_firstAnswering`, `_priorityBack :1522`. Fastest — промах → `_heal :1540` = `URLTest(group)`. `refresh() :1315-1335` ловит смену члена urltest → `auto/fastest`.
- Fallback (`fallback.dart`): `_fallbackSelector` на каждую цель через прокси (`routing.dart:895`); `:358` промах → `testGroup` для не-priority; priority-цель не двигает.

## Что давал urltest и чем заменить
- Периодический перетест + смена на быстрее по `tolerance` → шаг «улучшение»: раз в `checkEvery` топ-K (5) кандидатов без текущего, `ms + threshold <= curMs` → `_pick(..,'fastest')`. Только используемый маршрут и Fastest-цели правил.
- Уход с мёртвого → `pickFastest` пачками без текущего (вместо `_heal` и `fallback.dart:358`), `_closeStalled` сохраняется.
- Цепочки: вход — как обычная группа; выход с `detour` — парой через выбранный вход (`pairIdentity`, `buildTesterConfig(pairs:)`); предконнект двухфазный.
- Цели правил: лечение + улучшение в `FallbackService`.
- `sbapi.dart`: `testGroup` / `BoxGroup.results` удаляются; `selected` остаётся.
- `refresh()` не шлёт `fastest` по расхождению с `cache_file` — событие только от `_pick`. После старта сверить `api.selected` с выбором (`cache_id` = sha1 default'ов, `config.dart:352`).

## Дизайн
- **`group_pick.dart` (новый, чистый):** `typedef Probe1 = Future<PoolResult> Function(String key)`; `pickPriority(ordered, t)` — параллельно, ждём только вышестоящих; `pickFastest(keys, t, {window: 1s})` — первый сильный (`answered && !byChecker`) открывает окно, min ms среди сильных; слабые — только если сильных нет за раунд. Пачки по 5 по рангу: `pool.peek` (сильные по ms) → порядок плана → лестница в конец. Результат `{key, ms, weak, tried, answered, tookMs}`.
- **Предконнект `connectPicks(plan, {Cancel})` → `{groupTag: member}`** в `_connect` после `sentinel.context.starting`, внутри `_locked`, до `_startSingBox`. `_starting = plan` (для `_testerResolver`), `_testerPins` (без ожидания). Общий `TesterSession`, вынесенный из `measureLatency`. Проверяются main + entry главного маршрута и цели правил (параллельно, один тестер); pinned и одночленные — нет; standby-маршруты — нет. Гейт: главный маршрут; цели — не дольше главного + ~1,5 с, остальные — `api.select` после старта. Потолок раундов; после пустого раунда — проверка `direct`; сети нет → первый по рангу. Тестер живёт до конца своих проб (результаты — в пул). Выбор → `chosen` в копии плана → `buildConfig` → `startHostnames` (сузить до выбранных). Лог + `pick: {tried, answered, ms, tookMs, weak}` в `conn/connected`.
- **config.dart:** всегда selector, `default = chosen` если член, иначе первый.
- **Auto:** `_Group.now = chosen` для всех; `_checkGroup` не-priority → `pickFastest` вместо `_heal`; `_improve(r, g)` после успешного замера текущего; `Health.weak`; смена сети → внеочередной раунд с `_improve`.
- **Fallback:** то же через `group_pick.dart`; `_Group.initial` из `chosen` и для Fastest.
- **Продолжение:** `service.dart:1641, 2493, 2788` строят план через `_continuationPlan()` (current + chosen из `_auto.g.now`, до `_stopAuto`). Продолжение (`runner.running && _plan != null`) уважает `chosen` ядра, проверяет только группы без валидного. Свежий connect всегда проверяет (hint приложения игнорируется, кроме pinned). `adopt`: запись `keep()` без маркера селектора — не принимать, переподключить.
- **Приложение:** новых полей статуса не нужно (`status.auto.routes[].server/entryServer` заполнены сразу); `members[].weak`. Фоновый пинг каталога запускает приложение (`_pingNodes :2507`); после connect — пинг подписок активного маршрута; `PingEntry.byChecker`, слабые после сильных в `rank`.

## Этапы
- **2a** логика: `group_pick.dart` + тесты, `Health.weak`, config selector, auto.dart, fallback.dart, sbapi.dart; тесты auto/fallback/auto_singbox/sbapi_singbox/config.
- **2b** connect: `TesterSession`, `connectPicks`, `_continuationPlan`, `startHostnames`, сверка `selected`, adopt-маркер; живой тест сценария бага (мёртвая первая нода).
- **2c** цепочки и цели правил: двухфазный выбор, поздний `select`, потолок, `direct`.
- **3** приложение + docs (`core.md` 228-232, 258, 274, 966, 1113, 1296; `connect-model.md` 395, 415, 483, 541, 572-591, 1177; `rules.md` 67, 273; `subscription-parsing.md` 268), `mockup_todo.md`.

## Решения пользователя по вопросам
2026-10-15:
1. Первая пачка — 5 нод (параллельно); никто не ответил → остальные сразу обычным механизмом пинга (параллельность
   16, как `measureLatency`), по рангу, до первого ответа (Priority — по правилу «ждать только вышестоящих»). Потолка
   в 4 пачки нет. Проверка `direct` после пустой первой пачки — как в схеме (нет сети → первый по рангу, лечит Auto).
2. Цели правил: подключение ждёт главный маршрут + ~1,5 с, остальные цели — `select` после старта (настройки нет,
   пока пользователь не попросит; утечки нет: трафик цели идёт через прокси, не мимо).
3. Ответ только запасного чекера: для Priority — ответ; для Fastest — после сильных.
4. **`failAfter` — на оба режима** (Fastest тоже уходит после `failAfter` промахов, как Priority; сейчас уходит после
   одного — баг).
5. K=5 и окно 1 с — константы.
6. Подписка: список заменяется, пропавшие ноды уходят в `source.gone[]` — объединять с текущим не нужно.
