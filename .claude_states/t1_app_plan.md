# т1, этап приложения — план для workflow `code-task`

Спецификация: `docs/logs.md` → «Событие в приложении: что, почему, что делать (т1)» (строки ~209–447): «Строка в
Logs → Events», «Свёртки», «По типам», «Тексты», «Смена сети», «Один автор `sub/*`». Ядро т1 уже сделано
(`t1_core_plan.md`): события несут `op {id, kind}`, `opens`, `cause`, `verdict`, `data.why`, `data.trail`,
`data.repeat`; статус ядра — `subWaits`; ядро принимает `disconnect({error: {reason: 'pinLost', pick, why}})`,
настройку `detectNetProvider` и `operator` в состоянии сети.

Две очереди (строки UI — общий файл `app/tool/i18n_extra.json`, у него один владелец):
- **Прогон A** (этот план, юниты ниже): свёртка (чистая логика), хост, все новые строки.
- **Прогон B** (после A): UI — строки Events, уведомления, настройки, попап ожидания — на ключах l10n из A, без правок
  `i18n_extra.json`. План B пишется по итогам A.

## Прогон A

### u-fold (deep) — `core/lib/src/log_view.dart`
Модель строк ленты Events по «Свёрткам» (четыре механизма), без UI:
- `EventGroup` (или новая модель рядом, `foldEvents` остаётся точкой входа) описывает строку: открывающее/корневое
  событие, следствия по `cause` (счётчик, время последнего, список), закрывающее по `opens` (статус «завершилось»,
  длительность), события одной операции по `op.id` (итог — последнее/худшее событие, события внутри), повторы
  (`times`, `data.repeat`, окно 10 мин как сейчас для типов без `op`/`cause`).
- Уровень строки — худший из всех её событий. Корень стоит на месте (порядок ленты — по времени корня; новое
  следствие/закрытие/событие операции меняет счётчик и `lastAt`, строку не двигает). Повторы без корня — как сейчас.
- Корень отсутствует (выпал из журнала или нарочно не пишется, `net.captive`) — строка-группа: ключ `why.code`
  следствий, без события-корня. Открывающее пары выпало — закрывающее своей строкой.
- Фильтр: корень скрыт фильтром, а следствие подходит — следствие своей строкой; поиск по тексту следствия находит
  строку корня. Дай функции/параметры, которыми UI это спросит (предикат видимости события → строки).
- Пачки по `op`: `sub/updated` + `removed` + `back` одного обновления, `subUpdateAll`, `ruleSets`, `reconnect`
  (`conn/reconnected` с `core/sysProxy`/`rules/ruleSetUpdated` внутри), `connection` (`user/*` + `conn/*` одной
  командой), `appUpdate` (статус по последней стадии).
- `core/crashed` → `restartFailed` (×N) / `down` / `restarted`: одна строка, статус по последнему (это `cause` +
  `opens` из ядра — проверить, что выходит одной строкой).
- Существующие вызовы (`app/lib/core/logs_controller.dart`, `app/lib/widgets/event_rows.dart`, jormd) не ломать:
  если меняется API — старые поля/геттеры сохранить, пока UI (прогон B) не перейдёт; в отчёте — итоговый API.

### u-host (deep) — `app/lib/core/live_core_host.dart`, `app/lib/core/core_host.dart`, `app/test/fake_core_host.dart`,
`app/lib/platform/network_channel.dart`, `app/android/app/src/main/kotlin/**/NetworkChannel.kt`,
`app/android/app/src/main/kotlin/**/DefaultNetworkMonitor.kt`
1. Убрать свои `sub/*` из `_journal` (~1810, 1833, 1956, 1976–1994): пишет только ядро. `HostNotice`
   `subFailed`/`updateFailed` и `lastError` на карточке — свериться с ответом ядра (ядро ставит `lastError` само; не
   задваивать). Ответ `fetchSource` приходит после загрузки; ключа `waiting` нет.
2. `subWaits` из статуса ядра → `CoreHost`: `List<({String source, String name, String forWhat})> get subWaits`
   (`for`: `network` | `connection`) + уведомление слушателей при изменении (как прочее состояние статуса). Пусто —
   пустой список. UI (попап) — прогон B.
3. Потеря Manual-пина (`_reconnect` ~1713–1723, `catalog.pinLoss()`): `disconnect` передаёт в ядро
   `{error: {reason: 'pinLost', pick, why}}` (`why`: `deleted` / `off` / `unsupported` — из того, что даёт
   `pinLoss()`); journal `disconnect` от пользователя здесь не писать (отключил не пользователь). Сигнатуру
   `CoreHost.disconnect` расширить необязательным параметром, обычное отключение не меняется.
4. `detectNetProvider`: читать из настроек ядра там, где лежат прочие Connection (`catalog.connCfg`, ядро уже знает
   поле — `core/lib/src/catalog/settings.dart`), включить в сигнатуру и тело `_syncUpdateSettings` как
   `closeOnSwitch`. Тумблер — прогон B.
5. `operator` в состоянии сети с Android: `DefaultNetworkMonitor.kt` для мобильной сети добавляет `operator` —
   имя оператора SIM передачи данных (`TelephonyManager` от `SubscriptionManager.getDefaultDataSubscriptionId()`,
   `createForSubscriptionId(...).networkOperatorName`/`simOperatorName`), без новых разрешений; пусто/ошибка — поля
   нет. Заодно: `type` мобильной в этой карте — `cellular`, а в `NetworkChannel.kt` — `mobile`; ядро ждёт для
   `net/switched` значения из `docs/logs.md` «Смена сети» — выбрать то, что принимает ядро (`core/lib/src/netswitch.dart`),
   и привести к нему; вывод в отчёте.

### u-strings (fast) — `app/tool/i18n_extra.json`, генерируемые `app/lib/l10n/app_en.arb`, `app_ru.arb`,
`app/lib/l10n/gen/*`, `app/tool/i18n_keys.json`
Добавить английские строки (русский — к стейблу, не добавлять), затем `node app/tool/gen_all.mjs`:
- все фразы таблиц «Тексты» (`docs/logs.md` ~319–398): общие строки, фразы `why.code`, «По событиям» — с
  плейсхолдерами ARB для `<…>`; где тип уже имеет строку — переиспользовать/дополнить, не дублировать;
- подписи кнопок из таблицы «По типам», которых ещё нет (Connect, Choose server, Retry, Check now, Network settings,
  Pin, Switch server, Open rule, Choose target, Update subscription, Remove system proxy, Reconnect, Send report,
  Copy text, Install, Open update, In raw log …) — сначала найти существующие ключи;
- раскрытая строка: «Checks», «Related (N)», «Repeats», «N more», шаги `trail` (✓ ✗ ? ·) — подписи, если нужны;
- категория фильтра `net` («Network»), тип `net/switched`, `conn/reconnected` — подписи типа для фильтра;
- Settings → Notifications: «App data», «DNS server not responding» (+ подписи-пояснения в стиле соседних);
- Settings → Connection: «Detect network provider» + пояснение (Wi-Fi/Ethernet — ISP по прямому IP, мобильная —
  оператор SIM; SSID не берётся);
- попап: «Waiting for connection…», «Waiting for network…»; подписи путей подписки Auto / Proxy / Direct, если нет.
Имена ключей — в стиле файла. В отчёте — список новых ключей с плейсхолдерами (для прогона B).

## Тесты прогона A (test-writer-deep)
`core/test/event_fold_test.dart`, `app/test/t1_host_test.dart`:
- свёртка: корень + следствия — одна строка, счётчик, худший уровень, корень на месте при новом следствии; пара
  `opens` — одна строка со статусом закрытия, без открывающего — своя строка; `op` — одна строка; строка-группа без
  корня; следствие при скрытом фильтром корне — своей строкой; повторы без `op`/`cause` — как раньше (10 мин);
  `core/crashed` → `restartFailed`×N → `restarted` — одна строка;
- хост (через `fake_core_host` / существующие обвязки `live_core_host_test.dart`): ручное обновление подписки не
  пишет `sub/*` из приложения; `subWaits` из статуса доходит до `CoreHost`; потеря пина шлёт `pinLost` в
  `disconnect`; `detectNetProvider` уходит в `updateSettings`.
