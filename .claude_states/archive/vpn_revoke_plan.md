# т2.2 — отзыв VPN системой: полная остановка без перезапусков

Решения пользователя 2026-10-17 (`events_plan.md` т2 п. 2). Спека — доки (уже написаны, коммит 4507507 и следующий):
- `docs/core.md` → «Швы» (абзац про `onExit` / `onRevoked`, `RevocableRunner`) и «Отзыв туннеля» (после «Down»);
- `docs/logs.md` → строка `conn/disconnected` в таблице типов, «По типам» (Подключение и сеть), «Тексты», «Уровни и атрибуция»;
- `docs/connect-model.md` → Notifications: переключатель `vpnRevoked`, соответствие тип → переключатель.

Сейчас: Kotlin `onRevoke` → Dart `{type:'stopped', reason:'revoked'}` → `LibboxRunner._gone(reason)`
(`app/lib/core/libbox_runner.dart:227`) → `onExit(0)` → `CoreService._crashed` (`core/lib/src/service.dart:2231`) →
`_recover` → `core/crashed {code:0}` → `restartFailed` ×N → `conn/vpnDown`.

## Факты разведки (2026-10-18, скаут + лид)

Прогон 1, кусок A (ядро):

| где | что |
|---|---|
| `service.dart:126` | `runner.onExit = _crashed` — сюда же подписка `onRevoked` |
| `service.dart:3545` `connect` → `3549` `_connect` | `seq = _nextSeq()` 3566 (`_connectSeq`, 468-476), `_wakeUp` 3567, `_stopAuto` 3575; `_locked` 3584 (639-643), `if (seq != _connectSeq) return` 3585, `_plan = null` 3588 |
| `service.dart:3596` → `_startSingBox` 3223 → `runner.start` 3274 | старт sing-box |
| `service.dart:3630-3647` catch | `sentinel.context.stopped()` 3632, `core/tunNeedsAdmin` 3637, иначе `conn/connectFailed` 3640, rethrow 3647; finally 3648-3653: `_connectOp = null`, `_vpnSync()` при `seq == _connectSeq` |
| connect в полёте | `_plan` null во время connect → `_crashed` выходит сразу (2232-2233); признак фазы — `_connectOp` / `seq`. Повторов автоподключения в ядре нет (Retry — кнопка приложения) |
| `service.dart:2231-2247` `_crashed`; `2249-2337` `_recover` | `core/crashed` 2239, `_crashRoot` 2241; `restartFailed` 2303 / `repeated` 2295; `_goDown` 2359-2375 |
| `service.dart:1773-1850` `_vpnSync({String? by})` | `by` → `_vpnClose(id, by)` 1843-1846 → `conn/vpnUp {downMs, causes, by?}`; сейчас `by` передаёт только disconnect (4013) — `'system'` проходит без изменений |
| `service.dart:3973-4020` `disconnect` | образец остановки: `_wakeUp`, поля плана, `_stopAuto`, `_closeCrashRoot('disconnected')` (2380-2385), `_locked` + `runner.stop` + `sentinel.context.stopped()` (context.dart:447), туннельные поля, событие, `_vpnSync(by:)`, ветка kill switch 4014 |
| `log_view.dart:146-168` `eventNotifKind` | плоская карта; `conn/disconnected` → `connLost` (165) |
| `log_view.dart:174-187` `journalOnly`; `190-205` `notifDefaults`; `217-234` `eventNotifies` | стр. 221: `conn/disconnected` уведомляет только при `by == 'error'` |
| вид уведомления в app/lib | `eventNotifKind` / `eventNotifies` / `notifDefaults` в app/lib не используются; у приложения своя копия умолчаний (`settings_model.dart:86-100`, прогон 2) |
| тесты (владеет test-writer) | `event_catalog_test.dart:132-153` (сторож: warn/error в виде или `journalOnly`), `events_t1_test.dart:109-177`, `log_view_test.dart:163-261`, `service_test.dart:379`, `site_scheme_test.dart:198`, `app/test/_shots/event_shots_test.dart:86, 511-515, 622` |
| обвязка теста | `core/test/vpn_down_test.dart:14-41` `_Runner implements BoxRunner` (`up`, `failStarts`, `onExit`), 77-95: `FakeTime` (`core/test/sentinel_fakes.dart:8-39`, `advance`, `advanceSeconds`), `CoreService(now:, timer:, sentinelClock:, resolveAddresses: false, sysProxy: NoSystemProxy(), …)`, `svc.connect(_body())` |

Прогон 2 (приложение):

| где | что |
|---|---|
| `app/lib/core/libbox_runner.dart:48` | `class LibboxRunner implements AdoptableRunner` → добавить `RevocableRunner` |
| `libbox_runner.dart:148` | `_port.stoppedOnItsOwn.listen(_gone)` — единственный вызов `_gone`; причина из `platform_seams.dart:54-56` (`_vpn.stopped.map((e) => e.reason)`), Kotlin шлёт `'revoked'` |
| `libbox_runner.dart:227-235` `_gone(reason)` | `note`, `_closeLocal`, `_dropCache`, `onExit?.call(0)` |
| `settings_model.dart:86-100` `NotifCfg.defaults`; `104-110` `connectionKeys`; `120-126` `allKeys` | platform-only ключей нет — ключ общий, Android решает только UI |
| `app/lib/widgets/settings_look.dart:303-323` `row(key, label, hint)`; группа Connection 332-358 | строки без платформенного условия; Android-only — через `PlatformCaps` (`app/lib/platform/platform_caps.dart:10-37`, сейчас `systemProxy`, `killSwitch` = `!android`): новое свойство вида `vpnRevoke` = `android` |
| `app/lib/core/event_text.dart:55` (подпись), `279-292` (фраза) | `by != 'error'` → `youDisconnected` (280) — `by: 'system'` нужна своя ветка до неё |
| `app/lib/widgets/event_rows.dart:265-267` | Connect при `live && by == 'error' && !host.isOn` → добавить `system` |
| `app/lib/core/system_notifier.dart:153-154` | `conn/disconnected` при `by == 'error'` → `('connect', l.connect)` → добавить `system` |
| `app/tool/i18n_extra.json` | плоская карта «английский → русский», русское — `null` (`gen_i18n.mjs:6`); образцы подписи/пояснения тумблера: `appData` / `savedDataWasDamagedAndRestored`, `dnsServerDoesNotAnswer` / `aDnsServerStopsAnsweringOn` (`app_en.arb:3400, 3596-3598`) |
| тесты | `libbox_runner_test.dart:18-73` (`ProcessPort`, `revoke()` 68-72; реальный sing-box, пропуск без бинарника), 248-264 «stopped on its own: onExit fires once» — теперь `revoke` даёт `onRevoked`; `settings_test.dart:264-295, 328-343` (тумблеры, `PlatformCaps`); `t1_buttons_test.dart:252-304, 349-353`; `system_notification_test.dart:525-550`; `_shots/event_shots_test.dart:165-167, 236-238` |

Непрочитано: `event_text.dart:801`, `app/lib/shell/home_shell.dart:212` — кусок B смотрит сам.

## Прогон 1 — ядро (`cd core; dart analyze; dart test`)

Кусок A (deep), файлы `core/lib/src/runtime.dart`, `core/lib/src/service.dart`, `core/lib/src/log_view.dart`:
1. `runtime.dart`: `abstract interface class RevocableRunner implements BoxRunner { void Function()? onRevoked; }`
   с doc-комментарием (рядом с `AdoptableRunner`). `BoxRunner` не меняется — фейки тестов не трогаем.
2. `service.dart`: в конструкторе рядом с `runner.onExit = _crashed` (стр. 126) — если `runner is RevocableRunner`,
   подписать `onRevoked` на новый обработчик отзыва.
3. Обработчик: по фазам из «Отзыв туннеля» —
   - подключено / идёт перезапуск (`_recovering`): полная остановка тем же путём, что `disconnect` (стр. 3973: план
     снят, `_wakeUp`, `_stopAuto`, Sentinel `stopped`, `_closeCrashRoot`, туннельные поля), но событие одно —
     `conn/disconnected` warn `{by: 'system', reason: 'revoked'}`; открытое `vpnDown` закрывается `vpnUp {by: 'system'}`
     (через `_vpnSync`); kill switch «и после отключения» на отзыв не держит прокси (системный прокси на Android и так
     нет, но ветку не заводить); `runner.stop()` безопасен (раннер уже не `running`);
   - идёт connect: connect завершается без подключения, `conn/connectFailed` не пишется, только `disconnected by: system`;
     автоподключение не повторяет;
   - отключено / идёт Disconnect: ничего.
   Ни `_recover`, ни `core/crashed`, ни `restartFailed`. Лучше общий приватный метод остановки для `disconnect` и отзыва,
   чем копия.
4. `log_view.dart`: переключатель `vpnRevoked` в `notifDefaults` (true); `eventNotifies` — `conn/disconnected` с
   `by: 'system'` уведомляет под `vpnRevoked` (сейчас уведомляет только `by: 'error'` под `connLost`). Если
   `eventNotifKind` — плоская карта по ключу, ввести функцию вида по событию (тип + `data.by`) и использовать её везде,
   где берётся вид (grep `eventNotifKind`, в т.ч. `app/test/_shots/event_shots_test.dart` — им владеют тесты).

Тесты (test-writer-deep): новый `core/test/vpn_revoke_test.dart` — `CoreService` с фейковым раннером, реализующим
`RevocableRunner` (обвязка как в `core/test/vpn_down_test.dart`): отзыв при подключении → ни одного перезапуска за
минуты фейкового времени, `connected: false`, `recovering`/`down` null, в журнале ровно одно новое событие
`conn/disconnected {by: system, reason: revoked}` warn, нет `core/crashed`/`restartFailed`; отзыв во время перезапуска
после падения и при открытом `vpnDown` → `vpnUp {by: system}` + `disconnected`, попытки прекратились; отзыв во время
connect → нет `connectFailed`, одно `disconnected`; отзыв после disconnect → ничего; раннер без `RevocableRunner` —
поведение падения прежнее. `log_view`: `eventNotifies` — `disconnected by: system` уведомляет при `vpnRevoked` вкл.,
молчит при выкл., `by: user` молчит, `by: error` — по `connLost` как раньше; `notifDefaults['vpnRevoked'] == true`.
Обновить сторожевые тесты каталога/уведомлений, если ломаются.

Прогон 1 сделан 2026-10-18 (PASS, коммит «Core: VPN revoke…»). API: `RevocableRunner.onRevoked`,
`eventNotifKindOf(EventRecord)` (log_view.dart) — вид уведомления по событию; порядок при отзыве — `vpnUp {by: system}`,
затем `disconnected`. Для прогона 2: `app/test/_shots/event_shots_test.dart:514` перевести на `eventNotifKindOf`;
`vpnUp` в приложении всегда «VPN снова работает» (`event_text.dart:60, 482-484`) — при `by: user/system` это неверно.
Решение пользователя 2026-10-18 (вариант 2, доки обновлены — `logs.md` «Закрытие» в «„VPN не работает“», «Тексты»):
`vpnUp` с `by: user/system` — строка «Outage ended: VPN disconnected», своего уведомления нет; показанное «VPN не работает»
при `by: user` снимается, при `by: system` его заменяет уведомление `disconnected by: system` (тот же id). Текст
`disconnected by: system` — «VPN turned off by the system or another app».

Прогон 2 ждёт решения по аудиту формулировок (`wording_audit.md`, пользователь просил заменить «юзер-френдли» тексты на
понятные и технически верные): одобренные замены идут в тот же прогон — те же файлы (`event_text.dart`, `i18n_extra.json`).

## Прогон 2 — приложение (`cd core; dart test test/log_view_test.dart test/vpn_down_fold_test.dart; cd ../app; flutter analyze --no-fatal-infos; flutter test`), после прогона 1

Кусок C (lite), `core/lib/src/log_view.dart` (`EventFeed.notify`, правило закрывающего): `conn/vpnUp` с `by: user` /
`system` не уведомляет никогда (правило «закрывающее заменяет всегда» на него не действует). Снятие / замену уведомления
`vpnDown` делает приложение (кусок B).

Кусок A (lite), `app/lib/core/libbox_runner.dart`: `LibboxRunner` реализует `RevocableRunner`; `_gone(reason)`:
`reason == 'revoked'` → `onRevoked`, иначе `onExit(0)` (остальное в `_gone` — как есть).
Кусок B (fast), `app/lib/core/settings_model.dart`, `app/lib/widgets/settings_look.dart`, `app/lib/core/event_text.dart`,
`app/lib/widgets/event_rows.dart`, `app/lib/core/system_notifier.dart`, `app/lib/platform/platform_caps.dart`, `app/tool/i18n_extra.json` (+ `node app/tool/gen_all.mjs`):
`vpnRevoked` в `NotifCfg` (умолчание true, в `connectionKeys`), строка в Settings → Notifications → Connection только на
Android (как прочие platform-only строки), подпись «VPN turned off by system» и пояснение; текст события
`conn/disconnected by: system` — «VPN turned off by the system or another app»; `vpnUp` с `by: user/system` — «Outage
ended: VPN disconnected»; кнопка **Connect** в строке и жирная в системном уведомлении — как у `by: error`; уведомление
`disconnected by: system` берёт id показанного `vpnDown` (его `vpnUp` пришёл перед ним, `opens`), `vpnUp by: user`
снимает показанное (`app/lib/core/logs_controller.dart:267-269` — добавить в файлы куска). Плюс одобренные строки
`wording_audit.md`. Строки только английские.
Тесты (test-writer): `app/test/libbox_runner_test.dart` (`_gone('revoked')` → `onRevoked`, не `onExit`; другая причина →
`onExit(0)`), тесты настроек/текста события/кнопок по месту.
