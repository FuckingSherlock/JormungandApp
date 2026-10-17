# т2.2 — отзыв VPN системой: полная остановка без перезапусков

Решения пользователя 2026-10-17 (`events_plan.md` т2 п. 2). Спека — доки (уже написаны, коммит 4507507 и следующий):
- `docs/core.md` → «Швы» (абзац про `onExit` / `onRevoked`, `RevocableRunner`) и «Отзыв туннеля» (после «Down»);
- `docs/logs.md` → строка `conn/disconnected` в таблице типов, «По типам» (Подключение и сеть), «Тексты», «Уровни и атрибуция»;
- `docs/connect-model.md` → Notifications: переключатель `vpnRevoked`, соответствие тип → переключатель.

Сейчас: Kotlin `onRevoke` → Dart `{type:'stopped', reason:'revoked'}` → `LibboxRunner._gone(reason)`
(`app/lib/core/libbox_runner.dart:227`) → `onExit(0)` → `CoreService._crashed` (`core/lib/src/service.dart:2231`) →
`_recover` → `core/crashed {code:0}` → `restartFailed` ×N → `conn/vpnDown`.

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

## Прогон 2 — приложение (`cd app; flutter analyze --no-fatal-infos; flutter test`), после прогона 1

Кусок A (lite), `app/lib/core/libbox_runner.dart`: `LibboxRunner` реализует `RevocableRunner`; `_gone(reason)`:
`reason == 'revoked'` → `onRevoked`, иначе `onExit(0)` (остальное в `_gone` — как есть).
Кусок B (fast), `app/lib/core/settings_model.dart`, `app/lib/widgets/settings_look.dart`, `app/lib/core/event_text.dart`,
`app/lib/widgets/event_rows.dart`, `app/lib/core/system_notifier.dart`, `app/tool/i18n_extra.json` (+ `node app/tool/gen_all.mjs`):
`vpnRevoked` в `NotifCfg` (умолчание true, в `connectionKeys`), строка в Settings → Notifications → Connection только на
Android (как прочие platform-only строки), подпись «VPN turned off by system» и пояснение; текст события
`conn/disconnected by: system` — «Disconnected: VPN turned off by another VPN or the system»; кнопка **Connect** в строке и
жирная в системном уведомлении — как у `by: error`. Строки только английские.
Тесты (test-writer): `app/test/libbox_runner_test.dart` (`_gone('revoked')` → `onRevoked`, не `onExit`; другая причина →
`onExit(0)`), тесты настроек/текста события/кнопок по месту.
