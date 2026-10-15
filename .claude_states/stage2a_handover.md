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

## Для 2c
- **Первым — гонка сверки после старта:** `auto_singbox_test.dart:141` («Auto moves between routes and back…», ждёт
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
