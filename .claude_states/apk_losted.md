# apk_losted — есть в мокапе, потеряно в Android

Правило CLAUDE.md «Android is not a cut-down port». Каждый пункт только здесь (не дублируется в других файлах плана).
Источник: `archive/_work/parity_*.md` (id `P-..`), ответы пользователя 2026-10-11.

- **Kill switch на Android — приоритетная фича** (P-H1, P-S2, S24). Сейчас `caps.killSwitch => !android`
  (`app/lib/platform/platform_caps.dart:24`), группа скрыта (`settings_conn.dart:222–291`), плашка blocking не возникает
  (`vpn_alert.dart:37–39`). Мокап: `50-home.js:27–46, 140–142`, `56-dns.js:241–267`; `docs/rules.md` §7. Нужен дизайн для TUN:
  держать TUN как blackhole при падении ядра, killOnDisconnect с плашкой «blocking» и Remove, killWhileClosed, подсказка про
  системные «Постоянный VPN» и «Блокировать соединения без VPN». Решение по дизайну — пользователя.
  Сюда же исключение «правила с явным Direct в If unavailable пропускаем» (S25, `rules.md:510–513`): блок, кроме таких правил,
  предупреждение в правиле, пока kill switch вкл.
- **Запуск при старте системы** (P-H2, P-S1): тумблер есть, но нет `RECEIVE_BOOT_COMPLETED` и приёмника; `runLaunchActions`
  (`live_core_host.dart:1458`) на загрузку не вызывается. Решение пользователя: после загрузки приложение не открывается,
  только поднимается подключение. На Android тумблеры «Launch at startup» и «Connect on launch» объединить в один
  (приложение без окна всё равно стартует ради подключения — отдельный «запуск» без подключения смысла не имеет).
- **Убрать «Start minimized» на Android** (P-S5): тумблер мёртвый (`settings_look.dart:227–231`), не нужен.
- **«Links in the clipboard» не работает** (P-H3, подтверждено): при открытии приложения ссылка из буфера не предлагается.
  Мокап: `57-general.js:35`, `32-nodes-forms.js:122`.
- **«Rule for this app» в Live connections** (P-R2, подтверждено скрином): чип только при `x.process`
  (`live_conns_sheet.dart:555–561`), на Android есть только `pkg` (`conn_view.dart:41–42, 60`). На Android — открыть диалог
  приложения из Per-app (`apps_sheet.dart:305`) для `pkg`.
