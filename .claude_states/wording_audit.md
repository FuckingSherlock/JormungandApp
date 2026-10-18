# Аудит английских текстов: «псевдо-дружелюбные» формулировки

## Решения пользователя (2026-10-18, по номерам строк; разделы 3–4 отложены → `wording_notif.md`)

Принцип: понятно, но технически верно; однотипные события — одно событие с дополнением, подробности — в развёртке
(меньше элементов, которые оформлять по отдельности).
- 1, 5, 11 — одно событие отключения: «VPN disconnected · <by>» (вы / система или другое приложение / ошибка: причина).
- 2, 3 — открыто: идея пользователя «скобки» — выделять в ленте отрезки «VPN работал / не работал» парами (как цветные
  парные скобки): подключение–отключение, падение–восстановление; переподключение — отдельное событие, но выделенное,
  «скобка» проходит сквозь него. Обдумать (`to_think.md`).
- 4 — одно обобщённое событие конца сбоя, в развёртке: что падало, сколько лежало, что восстановилось.
- 5 — поле «By» в развёртке убрать (кто — в заголовке, п. 1).
- 6 — поведение — баг (`bugs.md`: выключение автоматики сбрасывает выбор, DNS и Auto); текст — после починки.
- 7 — события `core/stateLost` / `stateRestored` остаются (пересмотрено 2026-10-18: автоматическое восстановление из
  `.bak` должно быть видно); текст — по таблице (без догадки о причине). Модалка — только для ручной резервной копии
  (`features.md`).
- 10 — вторую строку («From the VPN is down / Kill switch notice») убрать.
- 11 — входит в п. 1; политика перезапусков — вопрос в `bugs.md`.
- 21 — подписи с категорией («Subscription updated» и т.п.); `sub/removed` / `back` — одно событие изменения подписки
  (+ / − серверы).
- 22, 23 — да (предложения таблицы). Вопрос в `bugs.md`: удалена цель «If unavailable».
- 25 — текст вида сбоя сайта — по таблице; 26 — в `bugs.md`; 27 — да.
- Общие события с дополнением (п. 1, 4, 14), «ожидание» (п. 12) — приняты.
- 8 — да + кнопка к настройке системного прокси (ставить / снимать, автоматически при вкл / выкл). 9 — сократить, см. 8.
- 12 — третье состояние «ожидание»: VPN в порядке, не хватает внешнего (сети); не падение.
- 13 — проверить, что старый `core/down` и `vpnDown` говорят одинаково.
- 14 — «Reconnected · <кратко: rules / settings / …>», подробности в развёртке; штатные reconnected не уведомляют.
- 15–17 — `conn/lost` / `restored` / `online` — в модель сбоя (Sentinel / «VPN не работает»), не отдельные тексты.
- 18 — конкретизировать (причина и следствие), если событие не ломает работу полностью.
- 19 — не «Fastest server changed»: смена сервера Auto по настройке Fastest.
- 20 — нестабильная запись: исключать из подборок на время (минута или больше, возможно настройка), кнопки
  «вернуть разово» и «не исключать».
- 24 — да. 28 — да, имя чекера из данных, не хардкод `check-host.net`.
- 26 — `tunTcpDead`: причина неясна, связать с причиной (политика `tunTcpDead` — `to_think.md` S40).
- 13 — свести «30 с» / «down»-тексты новых событий (`vpnDown`, причина `core`, `restartFailed`) к одной формулировке;
  старый `core/down` не трогать.
- 25 — на усмотрение лида: текст таблицы.
- 2, 3 — линия VPN и вывод конца пары отдельной строкой — `events_plan.md` т2 п. 4.

Дата: 2026-10-18. Только анализ, код и ARB не менялись. Английские тексты процитированы как есть (значения из `app/lib/l10n/app_en.arb`, ключ указан). Номера строк - `app/lib/core/event_text.dart`, если не сказано иное; `logs.md` = `docs/logs.md`.

Принцип правки: сказать, что именно остановилось, кто это сделал и в каком состоянии сейчас; без «снова работает», «вернулось», «вышло» там, где данные этого не доказывают. В «proposed» плейсхолдеры в формате ARB (`{s0}`, `{n0}`); где нужна множественная форма, она подразумевается.

Условные пометки: **[decided]** - уже решено заказчиком; **[inferred]** - формулировка опирается на документ, а не на код, проверить перед внедрением.

---

## 1. Явно неверное (ложные утверждения) - события

| # | where (file:line, l10n key) | current text | what is wrong | proposed English text |
|---|---|---|---|---|
| 1 | event_text.dart:280-281 `conn/disconnected`, `disconnected` + `youDisconnected` (ветка `d['by'] != 'error'` ловит и `by:'system'`) | `Disconnected` / `You disconnected` | ЛОЖЬ: при `by:'system'` (отзыв VPN, logs.md:95-97) пользователь ничего не отключал | **[decided]** title: `VPN turned off by the system or another app`; строки `You disconnected` нет. Деталь (по core.md:598-601, можно опустить): `sing-box was stopped and is not restarted` |
| 2 | event_text.dart:482-484 `conn/vpnUp`, `vpnWorksAgain` / `vpnWorksAgainDown` (поле `by` не читается) | `VPN works again` / `VPN works again · down {s0}` | ЛОЖЬ при `by:'user'` и `by:'system'`: сбой закончился отключением, VPN не работает вовсе (logs.md:288-290, core.md:603-605) | **[decided]** для `by:'user'`/`'system'`: `Outage ended: VPN disconnected` (без «works», без «down X»; длительность даёт `closedLine`) |
| 3 | event_text.dart:60 typeLabel `conn/vpnUp` -> `connectionRestored` | `Connection restored` | то же: при отключении ничего не «восстановлено»; к тому же не сказано, какое соединение | `VPN outage ended` |
| 4 | event_text.dart:482-484 `conn/vpnUp` без `by` (настоящее закрытие) | `VPN works again · down {s0}` | утверждение сверх данных: событие значит «причин не осталось» (ядро запущено / сеть появилась), что трафик через VPN идёт - никто не проверял; «down {s0}» двусмысленно | по `data.causes`: core -> `Outage ended: sing-box is running again`; network -> `Outage ended: internet is available again`; обе -> `Outage ended: sing-box is running, internet is available`; хвост ` · lasted {s0}` вместо `down {s0}` |
| 5 | event_text.dart:1271 `fieldValue` `by` (ключи `you`, `anError`) | `You` / `An error` (всё, кроме `user`, - `An error`) | ЛОЖЬ для `by:'system'`: это не ошибка | `user` -> `You`; `system` -> `The system or another app`; `error` -> `An error` |
| 6 | event_text.dart:445-452 `dns/switched`, ключ `switchAutomaticallyIsOffTheFirst` (ветка «всё остальное» после `failover`/`back`) | `Switch automatically is off: the first server is back` | ЛОЖЬ для `reason:'node'` (сменилась нода выхода, logs.md:118) - текст говорит про выключенный Switch automatically; и для `off` фраза «the first server is back» подразумевает восстановление, а это возврат из-за выключения. В `fieldValue` (1183-1189) ветки `node` тоже нет - уйдёт сырой код | `off`: `Switch automatically was turned off - back on the first server`; `node`: `The exit node changed; the DNS results of the new node were applied` [inferred по logs.md:118] |
| 7 | event_text.dart:1201 `core/stateRestored`/`stateLost`, `reason:'nul'`, ключ `theFileWasEmptyAPower` | `The file was empty (a power cut)` | предположение о причине, которого в данных нет (код `nul` - только содержимое файла) | `The file contained only zero bytes` [inferred: `nul` отличается от `empty`] |
| 8 | event_text.dart:585 `_vpnDownReason`, `systemProxyLeftOnProgramsHave` | `system proxy left on, programs have no internet` | слишком общо: без интернета только программы, которые идут через системный прокси (core.md:581-582) | `system proxy is still set, so programs that use it have no internet` |
| 9 | event_text.dart:478-480 `core/down` (старый журнал; новых событий нет, logs.md:125), `coreNotRunningFor30S` / `trafficGoesDirectStillTrying` | `Core not running for 30 s — traffic is blocked, system proxy kept` / `Traffic goes direct — still trying` | утверждения про весь трафик: при `kept` отрезаны только программы, использующие прокси; при `removed`/`released` «goes direct» верно для прокси-режима, для TUN в данных не подтверждено [inferred] | `sing-box has not been running for 30 s; the system proxy is still set, so programs that use it have no internet` / `sing-box has not been running for 30 s; the system proxy is removed, traffic bypasses the VPN` |
| 10 | event_text.dart:493-494 `core/sysProxy`, `by:'user'`, `fromTheVpnIsDownKill` | `You removed the system proxy` + `From the VPN is down / Kill switch notice` | вторая строка - не факт события, а место кнопки в интерфейсе | detail: `Removed with the Remove system proxy button` (logs.md:128) |
| 11 | event_text.dart:288-291 `conn/disconnected` `by:'error'`: `disconnectedTheCoreDidNotStart`, `theConnectionDropped`, сырой `reason` | `Disconnected: the core did not start after {n0} attempts` / `The connection dropped` / сырой код (`down`, ...) | «1 attempts» (нет plural); при неизвестном `reason` - расплывчатое «dropped» или сырой код; не сказано, кто отключил | `Disconnected: sing-box did not start after {n0, plural, one{# attempt} other{# attempts}}`; запасной: `Disconnected after an error: {reason}` (без `reason` - `Disconnected after an error`) |

## 2. Расплывчатое (не ложь, но не говорит, что случилось) - события

| # | where | current text | what is wrong | proposed English text |
|---|---|---|---|---|
| 12 | event_text.dart:59, 481, 716 `conn/vpnDown`, `vpnIsDown` (при `causes: ['network']`) | `VPN is down` | при одной причине `network` процесс VPN работает, нет интернета; «down» читается как «VPN сломан» (имя события решено в logs.md:266, поэтому - вариант только для чистой сети) | causes=network: `VPN has no internet`; causes содержит core: `VPN is down` (оставить) |
| 13 | event_text.dart:583 `_vpnDownReason`, `singBoxStoppedAndDoesNot` / `singBoxStoppedAndDoesNot3` | `sing-box stopped and does not start` / `... ({n0} attempts)` | «does not start» - прогноз; факт: не поднялся за 30 с, попытки продолжаются (core.md:578-580) | `sing-box stopped and has not restarted for 30 s` / `... ({n0} restart attempts so far)` |
| 14 | event_text.dart:309-314 `conn/reconnected`: `reconnectedRuleListsLoaded`, `reconnectedServerAddressesChanged`, `reconnectedByCommandABreakOf` (+ `reconnectedSettingsChanged` :307) | `Reconnected — rule lists loaded` / `Reconnected — server addresses changed` / `Reconnected — by command, a break of {s0}` / `Reconnected — settings changed: {s0}` | не сказано, кто и зачем переподключил; «by command» - чья команда; «a break» - какой перерыв | `Reconnected to apply downloaded rule lists` / `Reconnected because server addresses changed` / `Reconnected: you disconnected and connected again, VPN was off for {s0}` / `Reconnected to apply changed settings: {s0}` |
| 15 | event_text.dart:57 typeLabel `conn/lost`, `connectionLost` | `Connection lost` | какое соединение? Событие значит «ни один маршрут Auto не отвечает» (logs.md:99) | `No route answers` |
| 16 | event_text.dart:58, 331-333 `conn/restored`, `connectionRestored` / `connectionRestoredBreakOf` | `Connection restored` / `Connection restored · break of {s0}` | «break» не говорит, чего не было; что восстановлено, не названо (logs.md:99: `noNet` снова false) | `A route answers again` / `A route answers again · no answer for {s0}` [inferred по logs.md:99] |
| 17 | event_text.dart:62, 339-341 `conn/online`, `networkBack` / `internetRestoredBreakOf` / `networkIsBack` | `Network back` / `Internet restored · break of {s0}` / `Network is back` | три разных слова (network / internet) для одного события; «break» расплывчато | typeLabel `Internet available again`; title `Internet is available again · was unavailable for {s0}`; без `downMs` - `Internet is available again` |
| 18 | event_text.dart:88 typeLabel `core/restartFailed`, `couldNotStartAgain` | `Could not start again` | кто не смог запуститься - не сказано | `sing-box restart failed` |
| 19 | event_text.dart:64 typeLabel `auto/fastest`, `fastestMoved` | `Fastest moved` | непонятно, что «moved» | `Fastest server changed` |
| 20 | event_text.dart:355-359 `auto/unstable`, `droppedBackToItAfterMin` | `Dropped {n0}× — back to it after {n1} min without drops` | не сказано, что вернётся Auto, и что условие - ответы подряд, а не «минуты» (connect-model.md:421-425) | `Dropped {n0} times. Auto returns to it only after it answers for {n1} min in a row` |
| 21 | event_text.dart:68-71 typeLabel `sub/updated|failed|removed|back` | `Updated` / `Update failed` / `Servers removed` / `Servers back` | без контекста «Updated» неотличимо от `App updated`; «Servers back» - куда? | `Subscription updated` / `Subscription update failed` / `Provider removed servers` / `Servers returned to the subscription` |
| 22 | event_text.dart:223-227 `rules/fallback`, ключи `ruleBlockedWhileItIsDown`, `appBlockedWhileItIsDown`, `ruleGoesDirect`, `appGoesDirect`, `ruleGoesThroughTheMainFlow`, `ruleGoesThrough` (и app-варианты) | `Rule {s0} blocked while it is down` / `Rule {s0} goes direct` / `Rule {s0} goes through the main flow` / `Rule {s0} goes through {s1}` | «it» не определено (правило или цель); «Rule goes direct» - правило не ходит, ходит его трафик; не сказано, что это настройка If unavailable | `Rule {s0}: traffic is blocked (If unavailable: Block)` / `Rule {s0}: traffic goes direct (If unavailable: Direct)` / `Rule {s0}: traffic goes through the main flow` / `Rule {s0}: traffic goes through {s1}`; для приложений `App {s0}: ...` |
| 23 | event_text.dart:435, 443 `rules/targetBack|Found`, `ruleBackThroughIt`, `appBackThroughIt` | `Rule {s0} back through it` | обрывок фразы, «it» не определено | `Rule {s0}: traffic goes through the target again` / `App {s0}: traffic goes through the target again` |
| 24 | event_text.dart:438, rules_text.dart:47-52 `rules/targetLost`, `targetLost`, `targetOffInNodes`, `targetHasNoServerTheCore` | `Target lost: {s0}` / `Target off in Nodes` / `Target has no server the core can run` | «lost» - сбой это или удаление? последняя фраза не говорит, что причина - `unsupported` (logs.md:115) | `Target {s0} is unavailable` / `Target is switched off in Nodes` / `None of the target's servers is supported by the core` [inferred по `unsupported`] |
| 25 | event_text.dart:595 `_failKind` `instantRefusal`, `closedAtOnce` | `Closed at once` | кем закрыто? По core.md:634 - нет ответа и соединение прожило меньше 2 с | `No answer, connection ended in under 2 s` |
| 26 | event_text.dart:102-103, 524-533 `core/tunTcpDead`, `stackTcpOfAppsIsNot`, `stackTcpOfIsNotReaching` | `TCP does not pass the tunnel` / `Stack {s0}: TCP of apps is not reaching routing` / `Stack {s0}: TCP of {s1} is not reaching routing` | жаргон («stack», «reaching routing»), нет чисел из данных (`synSeen`, `accepted: 0`, `windowMs`), не упомянуто, что наше reject-правило выглядит так же (core.md:714) | `TCP connections do not get through TUN` / `TUN stack {s0}: TCP connection attempts of {s1} were seen but none was accepted by sing-box` (+ в Raw/детали: причиной может быть и reject-правило) |
| 27 | event_text.dart:557 `core/updateChannelEmpty`, `feedsAsked` | `Feeds asked: {n0}` | «feeds» и «asked» - внутренний жаргон | `Update sources checked: {n0}` |
| 28 | event_text.dart:1337 `checkText` `opens`, `opensElsewhereNotThroughYourRoutes` | `Opens elsewhere, not through your routes` | «elsewhere» не говорит откуда; это ответ внешнего чекера, а не знание об «ваших маршрутах» | `check-host.net opens it from its own servers` |

## 3. Системные уведомления / toast (`app/lib/core/system_notifier.dart`)

Собственных строк, кроме `addedToIgnoredSites` (`{s0} added to ignored sites`) и `undo` (`Undo`), в файле нет - проблем с ними нет. Заголовок/текст уведомления = `describeGroup`/`describe` + `reasonLine` (system_notifier.dart:119-130), поэтому все строки из разделов 1-2 попадают и в уведомление.

| # | where | current text | what is wrong | proposed English text |
|---|---|---|---|---|
| 29 | system_notifier.dart:119-122, 126-131 (`postEvent`, ветка `e.key == 'conn/vpnUp'` берёт `words.describe(e)`) | заголовок уведомления `VPN works again` (под id «VPN is down») | то же, что #2/#4: при `by:'user'`/`'system'` пользователь увидит «VPN works again» вместо «Outage ended: VPN disconnected»; по logs.md:290-292 своего уведомления у такого `vpnUp` вообще быть не должно (код не отфильтровывает - см. Connections) | исправляется текстом #2/#4; для `by:'user'`/`'system'` уведомление не слать |

## 4. Settings -> Notifications (`app/lib/widgets/settings_look.dart`)

Соответствие переключатель -> события: logs.md:319-361 («Уведомление»).

| # | where (file:line, key) | current text | what is wrong | proposed English text |
|---|---|---|---|---|
| 30 | settings_look.dart:343-347 `connLost`, ключи `connectionLost` / `noNetworkOrNoServerAnswers` | `Connection lost` / `No network or no server answers, and when it is back` | переключатель шире: он же отвечает за VPN is down (падение sing-box), failed connect, отключение по ошибке, TUN без прав, «TCP через TUN не идёт», ошибку системного прокси (logs.md:319-322, 358-360); «and when it is back» - обрывок | label `VPN connection problems`; hint `VPN is down or no route answers; a connection attempt failed or ended with an error; TUN cannot start or TCP does not pass TUN; the system proxy could not be set. Also notifies when it is working again.` (последнее - про `restored`/`vpnUp`) |
| 31 | settings_look.dart:333-337 `autoSwitch`, `whenAutoSwitches` / `autoMovedToAnotherEntryOr` | `When Auto switches` / `Auto moved to another entry or server; a rule went to its Fallback or a DNS server was replaced` | переключатель охватывает ещё `rules/targetLost`, `targetFound`, `targetBack` и `auto/fastest` (logs.md:332-335, 348-349); слово «Fallback» не совпадает с названием настройки «If unavailable» | label `Switches and fallbacks`; hint `Auto changed the entry, server or Fastest server; a DNS server was replaced; a rule target became unavailable or available again (traffic uses or leaves If unavailable)` |
| 32 | settings_look.dart:338-342 `unstable`, `anEntryKeepsDroppingAndWaits` | `An entry keeps dropping and waits before it gets the traffic back` | «waits» - кто ждёт, чего; на деле Auto вернёт запись только после ответов подряд | `An entry keeps failing. Auto returns to it only after it answers for some minutes in a row` |
| 33 | settings_look.dart:361-364 `subUpdated`, `aBackgroundUpdateFinishedNameAnd` | `A background update finished: name and number of servers` | событие пишется только когда список серверов изменился, без изменений - события нет (logs.md:109); «finished» подразумевает уведомление о каждом обновлении. Выключено по умолчанию (settings_model.dart:94) | `A subscription update changed its server list: name, servers added and removed. No notification when nothing changed` |
| 34 | settings_look.dart:365-369 `subFailed`, `aBackgroundUpdateFailedTheProvider` | `A background update failed, the provider removed or brought back servers, its servers do not respond` | «its servers do not respond» - событие `sub/dead` только в мокапе, ядро его не пишет (logs.md:113); зато переключатель отвечает за `node/addressMissing` (адрес сервера не существует, logs.md:347), его в тексте нет | `A subscription update failed; the provider removed servers or returned them; the domain of a server in use does not exist` |
| 35 | settings_look.dart:348-352 `blocked`, `itDoesNotOpenThroughThe` | `It does not open through the current entry: another one opens it (with a Create rule button), or none does` | перегружено, «it» без подлежащего, не сказано, что переключатель ещё покрывает `conn/failing` (logs.md:325-326) | `A site does not open through the current entry, or an app's connections keep failing. The notification offers Create rule when another entry opens the site` |
| 36 | settings_look.dart:400-403 `notifications`, `offTheAppStaysSilentIn` | `Off: the app stays silent in the background` | не сказано, что отключается (события), и что действия пользователя показываются всё равно (текст на строке 466 говорит об этом) | `Off: no event notifications or toasts. Results of what you start yourself (Update, Add, Ping) are still shown` |

## 5. Что проверено и оставлено без изменений (не строки таблиц)

Fine as is: `You connected`, `You pinned {s0}`, `Connected: {s0}`, `Network switched: {s0} → {s1} · no network for {s2}`, `No internet connection — the system reports no network`, `Auto: {s0} → {s1}` и reason-строки `failedChecksPlural` / `isBackReturnedToIt`, `Could not update subscription {s0}`, `Could not load rule list {s0}` и его детали про копию, `{s0}: domain {s1} does not exist · servers: {n2}`, `DNS server {s0} does not answer`, все тексты Sentinel `whyPhrase` (`No internet connection: the system reports no network, or direct checks fail` и др.), `Recovered on its own · after {s0}`, `Cause not established — see the checks`.

## Connections (не следовал, для других аналитиков)

- `app/lib/core/system_notifier.dart:113-131`: `postEvent` не пропускает `conn/vpnUp` с `by:'user'|'system'`, а по logs.md:290-292 и core.md:603-605 у такого `vpnUp` уведомления быть не должно; и `conn/disconnected by:'system'` должен заменять показанное «VPN is down» тем же id. Это поведение, не текст.
- Переключателя `vpnRevoked` («VPN turned off by the system») в `settings_look.dart` пока нет (группы 325-389), хотя logs.md:319 и core.md:601 его требуют; при добавлении нужны label/hint, например `VPN turned off by the system` / `Another VPN app took over, or the VPN was switched off in the system settings. sing-box is stopped and not restarted`.
- `eventNotifKind` / список `journalOnly` (`log_view.dart`), `app/lib/core/rules_text.dart` (`lostWhyText`), `app/lib/widgets/event_rows.dart` - другие места, где собираются те же тексты (statusLine, кнопки); не читал.
- Русские файлы `app_ru.arb` по заданию не трогал.

## Open questions

- `core/updateDeltaFailed`, ключ `thePatchDidNotDownloadThe` («The patch did not download — the whole file is used»): по данным `{code, error, from, attempts?}` не ясно, патч не скачался или не применился; если второе - формулировка неверна. Решить может чтение кода обновления (`core/updateDeltaFailed` writer).
- #12 (`VPN has no internet`) - предложение, противоречащее закреплённому в docs названию «VPN не работает»; нужно решение заказчика.
- #24 `unsupported`: смысл «None of the target's servers is supported by the core» выведен из кода `why`, не из кода проверки.
- #26: число попыток (`synSeen`) можно вставлять в деталь только если оно всегда есть в данных события; в docs указано в `data`, но не проверено на практике.
