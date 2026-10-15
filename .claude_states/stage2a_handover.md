# Этап 2: 2a закоммичен (8e629dd), 2b — код написан, не закоммичен

Удалить после закрытия этапа 2.

## 2b — что в рабочем дереве (компилируется, `dart analyze` чистый)
- `runtime.dart` `TesterSession` (`ensure`, `probe`, `directAnswers`, `finish`, `stop`); `measureLatency` на нём.
- `group_pick.dart`: `afterEmpty` у `pickPriority` / `pickFastest` (один раз после пустой первой пачки; true = стоп).
- `plan.dart` `planWithChosen`; `address_pin.dart` `startHostnames` — только `chosen`.
- `auto.dart`: `_Group.start`, `groupServers()`; первый `refresh()` сверяет `api.selected` со стартом и делает `select`.
- `service.dart`: `connectPicks` (main / вход цепочки; pinned, <2, валидный chosen при продолжении — пропуск; пустая
  первая пачка → `direct`; никто → первый по рангу; тестер не стартовал → warn и план как есть), `_nextSeq()` /
  `_pickCancel`, `_continuationPlan` в 3 местах, Raw-строка `connect: …` и `pick` в `conn/connected`, `keep()`
  `selectorGroups: true`, `adopt()` без маркера — стоп.

## 2b — сделано (код + тесты, не закоммичено)
- Регрессия `service_address_test` (2 теста): `connectPicks` не вызывал `s.ensure()` — тестер, который не стартует,
  давал «все промахнулись» → сеть silent → `serverDown` отказывал. Теперь `await s.ensure()` внутри try (не стартовал →
  warn, план как есть). Тест: tester-box в `boot` — `_Runner(failStart: true)` (иначе в тесте нет сети).
- `refresh()` сверяет и `proxy` с `current`; `TesterSession.onWarn` (stop → warn-строка; `measureLatency` и connect передают).
- Тесты: service_address (startHostnames, connectPicks continuation/fresh, disconnect во время проверки), service_test
  (adopt без маркера), auto_test (selected после старта), fallback_test (networkChanged), failover_singbox_test
  (`connect: fastest|priority … dead first`, настоящий sing-box).
- Замечено: отмена во время `s.ensure()` тестера не прерывает старт (ждёт его конца, ~1 с) — приемлемо, не гонка.

- Docs 2b сделаны: `core.md` «Подключение: проверка перед стартом», `conn/connected` `pick`; `connect-model.md`
  (цепочки и цели правил при connect пока на выборе плана — до 2c). `rules.md` / `subscription-parsing.md` — на этапе 3.

## 2c ЗАКРЫТ (четвёртый агент), к коммиту готово — осталось только коммит + beta.txt
- Добавлены тесты: `failover_singbox_test` (настоящий sing-box): продолжение держит выбор ядра для выхода цепочки и цели правил через
  `_coreServers()`, группа с одной подсказкой приложения (новая цель) проверяется; усыновление (`_Handover`) не откатывает группу и
  `proxy`. `service_address_test` (`_ProbeBox`, поддельный SOCKS-тестер): поздний тестер (выход цепочки-цели, `targetGrace = 0`) берёт
  снимок адресных настроек плана. Проверено откатом строки: (а) `_coreServers()` без `fallback` и (б) `reconcileStart = true` — оба
  теста падают; (в) без `settings: addr` у пинов второго тестера — падает.
- Docs сверены с кодом и исправлены: `core.md` («Подключение: проверка перед стартом», `conn/connected`), `connect-model.md`, `rules.md`
  (67 и 273: urltest устарел). Остаётся вне scope: `pick` в `conn/connected` = первый из `picks`, и если маршрут не проверялся, а цель
  да — это выбор цели (docs описывают как есть; код можно сузить до группы маршрута). Не сделано: `logs.md` ~212 не трогали
  (там нет `picks`), `mockup_todo.md` — запись про 2c-2 не проверял.

## 2c часть 2 — ОБНОВЛЕНИЕ (третий агент): три бага починены, тесты добавлены; docs — за другим агентом
- (а) `connectPicks(plan, {cancel, held})`: `continuation: bool` заменён на `held` (тег группы → ключ из `_coreServers()`, null =
  свежий connect); группа пропускается, только если `held[tag] == chosen` (подсказка приложения проверяется). (б) `AutoService.reconcileStart`
  (false при adopt: `_startAuto(adopted: true)`) — первая сверка не откатывает группы и маршрут. (в) `addr = _addressSettings()` читается
  один раз в начале `connectPicks`, `_testerPins(..., settings:)` / `_testerResolver([settings])` — поздние тестеры берут снимок.
- Тесты: auto_test (reconcileStart), fallback_test (`groupServers`, `select`, `_reconcile` ×3), service_address_test (held, targets в
  `planWithChosen`/`planKeepingServers`, проверка цели с подсказкой), failover_singbox_test (настоящий sing-box: цепочка с мёртвым первым
  выходом; цель правил в grace и поздняя с `targetGrace = 0`, `select` переживает сверку).
- НЕ покрыто тестом: (в) напрямую (нет теста на источник ipv6/резолвера у позднего тестера); service-уровневый adopt «Auto не откатывает»;
  продолжение (`_connect` при работающем) удерживает выбор целей/выходов через `_coreServers()` на уровне сервиса.
Ниже — состояние до этого агента.

## 2c часть 2 — КОД СДЕЛАН (не закоммичен), тестов и docs НЕТ (бюджет агента кончился)
Код (`dart analyze` чист; service_address/fallback/routing/service/auto/failover_singbox/exit_via_singbox зелёные, новых тестов нет):
- `plan.dart`: `targetEntryTag`, `planTargetGroups`; `planWithChosen` / `planKeepingServers` знают `routing.targets` (теги `t`, `t>entry`).
- `fallback.dart`: `groupServers()`, `select(groupTag,key)` (помечает `_coreSelected`), `_select` (и в `_move`), сверка после старта
  (`_reconcile` по `groupsChanged`: кэш sing-box не перебивает выбор ядра; `reconcileStart=false` при adopt).
- `service.dart`: `connectPicks` переписан (юниты `_PickUnit`/`_PickGroup` в конце файла): главный маршрут + цели правил
  параллельно на одном тестере; выход цепочки (маршрута и цели) — парами через выбранный вход на втором тестере (`_runUnit`);
  вход никто не ответил → выход = первый, без проверки; шлюз = главный + `targetGrace` (1,5 с, публичное поле); опоздавшие —
  `_applyLate` после `_startAuto` (`_releaseLate`), через `FallbackService.select`; тестер живёт до конца всех проб (`finish`);
  `_pickCancel` не обнуляется после connect (отмена опоздавших). `_coreServers()` = Auto + fallback для `_continuationPlan` /
  `_keepCoreChoice`. `conn/connected`: `pick` = группа маршрута, `picks` (если >1) = все решённые до старта.
Осталось: (1) тесты: цепочка (выход через выбранный вход, мёртвый первый выход → живой), цель правил (в grace → в `default`
  конфига; медленная → connect не ждёт дольше main+grace, `select` после старта и переживает сверку; продолжение держит выбор
  целей/выходов; `planWithChosen`/`planKeepingServers` для targets), живой sing-box (цепочка / цель с мёртвым первым;
  стиль `failover_singbox_test`), fallback_test на `select`/`_reconcile`/`groupServers`; (2) docs: `core.md` «Подключение:
  проверка перед стартом» (строки 253-270: убрать «выходы цепочек и цели правил не проверяются», описать два шага, цели,
  grace, поздний select, Raw-строки `(late: …)`, `picks`), `connect-model.md` ~420-428 (убрать «пока не проверяются (этап 2c)»),
  `rules.md` ~67 и ~273, `logs.md` ~212/`core.md:1348` (`picks`), `mockup_todo.md`.
Замечено вне scope: (а) `connectPicks` пропускает группу при `continuation && chosen валиден` — для группы, которой у ядра
  нет (новая цель), это подсказка приложения, не выбор ядра; (б) `adopt` + Auto `_startChecked` откатит группы к `chosen`
  записи (для fallback сделано `reconcileStart=false`); (в) второй тестер (пары) строит резолвер/пины после `_starting=null`
  у поздних выходов целей — `_addressSettings` читает `_plan`/снимок.

## Для 2c
- **СДЕЛАНО (2c часть 1):** гонка (`_coreSelected` / `_select` в auto.dart; реальная причина флака `auto_singbox_test` —
  тест звал `check()` до первого ответа групп, `_groupsUp` в тесте), `_keepCoreChoice` / `planKeepingServers` (план при
  работе), `testBoxes` в app/test (тестер connect не стартует). Остаётся ниже: выход цепочки и цели правил (часть 2).
- (сделано) **Первым — гонка сверки после старта:** `auto_singbox_test.dart:141` («Auto moves between routes and back…», ждёт
  'B', получил 'A') падает в полном прогоне второй раз подряд (по отдельности проходит). Тот же признак, что у
  исправленной гонки `setManual` (2b): первый `refresh()` (`_startChecked`) возвращает `proxy` / группы к стартовому
  выбору и откатывает переход, сделанный до первого обновления групп (Auto `_moveTo`, `_pick`, fallback). Сверка должна
  откатывать только восстановленное кешем sing-box, а не любой `select` ядра после старта.
- **Затем:** план от приложения во время работы (`_sendPlan`) в `_connect` не получает `chosen` из
  `_auto.groupServers()` — главная группа перепроверяется при каждой смене плана (может сменить ноду и выходной IP).
  По схеме продолжение хранит выбор ядра: валидный выбор ядра (не pinned-группа) переносится в новый план.
- Тесты приложения с фейковыми раннерами и не падающим тестером ждут ~5 с на connect (проверка нод) — по умолчанию
  фикстура тестера «не стартует».
- Выход цепочки: пара через выбранный вход; цели правил при connect (ждать ≤ главный + ~1,5 с, остальные — `select`
  после старта, тестер живёт до их конца). Рабочие каталоги тестеров `run/connect-N` (общий счётчик с `_pingSeq`).
