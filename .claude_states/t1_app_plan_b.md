# т1, этап приложения — прогон B (план для workflow `code-task`)

Спецификация: `docs/logs.md` «Событие в приложении» (~209–447: «Строка в Logs → Events», «Свёртки», «По типам»,
«Тексты»); новые команды ядра — `docs/core.md`, строки `POST /api/check-now` и `POST /api/rule-sets/retry` (таблица
jormd HTTP API, ~1170). Итоги прогона A (API свёртки, ключи строк) — `.claude_states/t1_app_runA_notes.md`.
Решения 2026-10-17: «Check now» — проверка в ядре; у `dns/failed` кнопки «сменить сервер» нет, только Open (DNS);
«Retry» списков правил — перезагрузка в ядре.

Две очереди: **B-core** (ядро: две команды) → **B-app** (UI на готовом API).

## B-core

### u-core-acts (deep) — `core/lib/src/service.dart`, `core/lib/src/api.dart`, `core/lib/src/daemon.dart`,
`core/lib/src/rulesets.dart`, `core/lib/src/dns_failover.dart`, модуль раунда Auto и проверки цели правил (найти;
указать в отчёте)
- `CoreApi.checkNow(int eventId)` + `POST /api/check-now` — по `docs/core.md`: предмет из события (`conn/lost` —
  раунд Auto главного потока, `auto/unstable` — раунд записи, `rules/fallback` — цель, `dns/failed` / `failedOnNode` —
  сервер на нодах), тот же путь, что у планового раунда (итог закрывает пару тем же кодом, никаких своих событий);
  `data.recheck` pending → ok/fail через `EventBook.update`; повторная команда присоединяется; не подключено →
  `notConnected`; неподдерживаемый тип / нет события → 400.
- `CoreApi.retryRuleSets(int eventId)` + `POST /api/rule-sets/retry` — списки события (все `tag` его `op ruleSets`,
  иначе один), новый `op ruleSets`, тот же путь, что у автообновления списков (события, переподключение); ответ после
  загрузки `{updated, failed}`.
- jormd-обёртка и `CoreService` — как у соседних команд (`siteCheck` — образец).

Тесты (test-writer-deep): `core/test/check_now_test.dart` — каждый поддерживаемый тип ведёт в свою проверку,
pending → итог, присоединение второй команды, `notConnected`, 400; `retryRuleSets` — теги из `op`, один тег без `op`,
новый `op`, ответ. Без сети и sing-box, через существующие подделки сервиса.

## B-app (после B-core)

Общее для всех юнитов: строки — только существующие ключи l10n (список — notes A); новых строк нет, кроме юнита
u-text (владелец `app/tool/i18n_extra.json`). Если ключа не хватает в другом юните — ближайший существующий и пометка в
отчёте. Юниты идут параллельно и пишут против интерфейсов ниже; ошибки анализатора из-за ещё не готового символа
другого юнита — ожидаемы, свои файлы при этом должны быть верны.

### u-text (fast) — `app/lib/core/event_text.dart`, `app/tool/i18n_extra.json` (+ `node app/tool/gen_all.mjs`)
Тексты по «Тексты» (общие строки, фразы `why.code`, «По событиям»), одно состояние — один глагол. Интерфейс для
u-rows / u-notif (методы `EventWords`):
- `(String, String) describeGroup(EventGroup g)` — заголовок и деталь строки целиком: обычная строка → `describe(g.ev)`;
  операция → итог операции (`subUpdateAll` «Subscriptions updated: N of M», `appUpdate` — статус по последней стадии,
  `reconnect` — `conn/reconnected` с причиной из `parts`); строка-группа → заголовок по `whyCode` (`net.captive` —
  «sign-in … · events: N»);
- `String? reasonLine(EventGroup g)` — строка причины: по `verdict` (`consequence` → «Cause: <заголовок корня>»,
  `blip`, `workaround`, `unexplained` / `why.unknown`), иначе причина типа из `data` (`reason`, `why`, `error`);
- `String? relatedLine(EventGroup g)` «+N related» (+ время последнего); `String? closedLine(EventGroup g)` «Finished
  at HH:MM · lasted N»; `String? repeatsLine(EventGroup g)` «N times · from HH:MM to HH:MM»;
- `List<TrailRow> trailRows(EventRecord e)`, `class TrailRow {String mark /* ✓ ✗ ? · */; String text; String? at /* +1.2 s */}`;
  > 8 шагов — первые 3, строка «N more», последние 3; код без фразы — `code` + параметры;
- `net/switched` в `describe` («Network switched: Wi-Fi (ISP) → mobile (operator)», с провалом «· no network N s»).
- `searchText` учитывает новые тексты (поиск по следствию — через `foldEvents(matches:)`).

### u-rows (fast) — `app/lib/widgets/event_rows.dart`
Строка по «Строка в Logs → Events»: свёрнутая — мета (время · уровень · `×N` · «в фоне») → `describeGroup` → деталь →
`reasonLine` → до трёх кнопок; закрытая пара — статус и цвет «решено» (`closedLine`); корень — `relatedLine`;
раскрытая — поля `data`, **Checks** (`trailRows`), **Repeats** (`repeatsLine` + времена, свёрнуты), **Related (N)**
(список следствий), остальные кнопки, «Hide this type» / «Show only this type», «In raw log». `hitInside` — строка
раскрыта (через `openRows` контроллера). Кнопки — таблица «По типам», видны, пока действие имеет смысл; хост:
`checkNow(eventId)`, `retryRuleSets(eventId)`, `openNetworkSettings()` (u-acts), существующие `connect`, `retry`,
`pinRouteNode`, `releaseSysProxy`, `updateSource`, `checkUpdate` / `installUpdate`, ссылки `app_links.dart`
(`openNodesEntry`, `openRuleForm`, `openRules`, `openDns`, `openRuleSets`, `openRoute`), лист отправки отчёта с этим
событием, `copyText`. `Check now` при `data.recheck.state == 'pending'` — «Checking…» без действия.

### u-logs (lite) — `app/lib/core/logs_controller.dart`, `app/lib/pages/logs_page.dart`
`groups` — `foldEvents(feed.list, shown: <фильтр без текста>, matches: <поиск>)` по всему журналу вместо
`foldEvents(shownEvents)` (API — notes A, u-fold); строки с `hitInside` попадают в `openRows`; ключ строки в
`AnchoredList` прежний (`g.key`), порядок — по `g.at`. Счётчики фильтра — как сейчас.

### u-notif (fast) — `app/lib/core/system_notifier.dart`, `app/lib/shell/home_shell.dart`, новый `app/lib/widgets/sub_wait_popup.dart`
- уведомление: заголовок/текст из `describeGroup`/`reasonLine` строки события; до двух **жирных** кнопок таблицы
  «По типам» (ids действий — общие с u-rows по смыслу: `connect`, `retry`, `checkNow`, `rule`, `ignore`, `open`,
  `retrySub`, `retryRuleSets`, `networkSettings`, `removeProxy`, `reconnect`, `report`); `_actFromShade` в
  `home_shell.dart` разбирает их тем же хостом; тап — открывает событие (как сейчас);
- закрывающее пары (`opens`) заменяет уведомление открывающего (id уведомления = id открывающего); цепочка
  `core/crashed` … `restarted` — одно уведомление, обновляется на месте (id корня); следствие (`cause`) не уведомляет;
- попап «Waiting for connection…» / «Waiting for network…» по `host.subWaits` (имя подписки), закрывается сам, когда
  список пуст; монтируется в `home_shell.dart`.

### u-settings (lite) — `app/lib/widgets/settings_look.dart`, `app/lib/core/settings_model.dart`, `app/lib/widgets/settings_conn.dart`
- `NotifCfg`: ключи `appData`, `dnsFailed` (по умолчанию вкл., как `notifDefaults` ядра, `core/lib/src/log_view.dart`)
  в своих группах; строки в `NotifSheet` (подписи — notes A: `appData`, `dnsServerDoesNotAnswer`, пояснения);
- Settings → Connection: тумблер `detectNetProvider` рядом с `closeOnSwitch` (`cfg.detectNetProvider`), подпись
  `detectNetworkProvider` + пояснение.

### u-acts (lite) — `app/lib/core/core_host.dart`, `app/lib/core/live_core_host.dart`, `app/test/fake_core_host.dart`
`Future<bool> checkNow(int eventId)` → `api.checkNow`, `Future<void> retryRuleSets(int eventId)` → `api.retryRuleSets`,
`Future<void> openNetworkSettings()` → `openNetworkSettings()` из `network_channel.dart` (u-net). Подделка — записывает
вызовы.

### u-net (lite) — `app/lib/platform/network_channel.dart`, `app/android/app/src/main/kotlin/dev/jormungand/app/NetworkChannel.kt`
Верхнеуровневая `Future<void> openNetworkSettings()` в `network_channel.dart` → метод канала `openSettings` →
Android `Settings.ACTION_WIRELESS_SETTINGS` (новая задача, `FLAG_ACTIVITY_NEW_TASK`); на не-Android — ничего.

### Тесты B-app (test-writer) — `app/test/t1_events_ui_test.dart`, `app/test/t1_notify_test.dart` + правка существующих
`app/test/event_filter_test.dart`, `app/test/system_notification_test.dart`, `app/test/notification_toast_test.dart`,
`app/test/logs_conns_events_test.dart`, `app/test/settings_test.dart`
- строка: строка причины по каждому `verdict`; корень «+N related» и список в раскрытой; закрытая пара; строка-группа;
  `trail` > 8 шагов — 3 + «N more» + 3; кнопки по типам (выборка: `conn/lost` Check now, `rules/ruleSetFailed` Retry,
  `dns/failed` — Check now + Open, без «Switch server»; `conn/offline` Network settings); `Checking…` при pending;
- поиск по тексту следствия находит и раскрывает корень; скрытый фильтром корень — следствие своей строкой;
- уведомления: ≤ 2 кнопки, закрывающее заменяет открывающее (тот же id), следствие не уведомляет, тумблеры
  `appData` / `dnsFailed`; попап `subWaits` появляется и закрывается сам;
- настройки: тумблер `detectNetProvider` меняет `connCfg`.
Существующие тесты — обновить под новые тексты, не ослабляя проверок.

После B-app: лид смотрит `event_shots` (`flutter test test/_shots/event_shots_test.dart --run-skipped`), пишет заметку в
`mockup_todo.md`, снимает пометку «реализуется» в `logs.md`.
