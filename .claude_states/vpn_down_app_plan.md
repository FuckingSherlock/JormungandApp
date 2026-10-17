# «VPN не работает» — приложение (план прогона code-task)

Ядро уже пишет `conn/vpnDown` / `conn/vpnUp` (план ядра: `.claude_states/vpn_down_core_plan.md`, пункты 1–9).
Спецификация: `docs/logs.md` — раздел «### «VPN не работает» (`conn/vpnDown` / `vpnUp`)», «Свёртки» (механизмы 2, 5),
«По типам» (строки `conn/vpnDown`, `conn/offline`, `core/crashed …`), «Тексты» (строка `conn/vpnDown` / `vpnUp`).
`docs/connect-model.md` → Settings → Notifications, «Connection» (переключателя `coreCrash` нет).

API ядра для приложения:
- событие `conn/vpnDown`: error, `data: {causes: ['core'|'network', ...], proxy?: 'kept'|'removed'|'released', source?}`,
  меняется на месте (`rev`); `joins: [crashId]` — строка падения влита в его строку (свёртка ядра уже это делает);
- `conn/vpnUp`: info, `opens` = vpnDown, `data: {downMs, causes, by?: 'user'}`;
- `EventFeed.notify(cfg, e)` в `log_view.dart` — заменяет `eventNotifies(cfg, e) && feed.markNotified(e.id)`;
- `core/down`, стоячий `conn/offline` warn, `conn/online` при подключении больше не пишутся (старые журналы — тексты
  оставить); `conn/offline` / `online` без подключения — info, журнал; `core/crashed|restarted|restartFailed` не
  уведомляют; `coreCrash` нет в `notifDefaults`.

## Куски

### U1 (fast) — тексты: `app/lib/core/event_text.dart` + строки (`app/tool/i18n_keys.json`, ARB через генератор)
- `typeLabel`, `describe`, заголовок цепочки (сейчас ~687–693, строки падения) для `conn/vpnDown` / `vpnUp`:
  заголовок «VPN is down»; строка причины по `causes`: core — «sing-box stopped and does not start (N attempts)»
  (N — из влитых `restartFailed`, если доступно, иначе без числа), network — «No internet connection», обе — обе
  через « · »; при `proxy: kept` — «system proxy left on, programs have no internet»; закрыто (`vpnUp`) —
  «VPN works again · down N» (`downMs`). Строка, в которую влито падение, — заголовок и статус по `vpnDown`/`vpnUp`.
- Тексты `core/down`, `conn/offline` / `online` оставить (старые журналы).
- Новые строки — только английские (правила репо), генератор `node app/tool/gen_all.mjs`.

### U2 (fast) — кнопки и уведомления: `app/lib/core/system_notifier.dart`, `app/lib/widgets/event_rows.dart`,
`app/lib/core/logs_controller.dart`
- `logs_controller.dart:270` → `feed.notify(cfg, e)`.
- `SystemNotifier.eventActions`: `conn/vpnDown` — `causes` содержит `core` и ядро не запущено → `retry`; содержит
  `network` → `networkSettings` (до двух). `postEvent`: id уведомления `opens ?? cause ?? id` остаётся; особый
  случай «`core/*` с `cause` обновляет уведомление корня» больше не нужен (падение не уведомляет) — убрать, если
  ничто другое на него не опирается.
- Строка события (`event_rows.dart`, сейчас ~274–275 offline, ~318–322 падение/down): для `vpnDown` — Retry (live,
  не подключено к ядру, причина core), Remove system proxy (`proxy: kept`), Send report (как у error ядра),
  Network settings (причина network). Те же id действий, что уже понимает `home_shell._actFromShade`.

### U3 (lite) — настройки: `app/lib/widgets/settings_look.dart`, `app/lib/core/settings_model.dart`
- Убрать переключатель `coreCrash` (строка ~348–352 settings_look, default и `connectionKeys` в settings_model ~92, ~109).
  Сохранённое значение в старом `notifCfg` просто игнорируется. Подпись `connLost` — без изменений.
