# apk_losted — есть в мокапе (включая наброски), потеряно в Android

Правило CLAUDE.md «Android is not a cut-down port»: каждое отличие — либо с причиной в `docs/platforms.md`, либо здесь.
Источник: `archive/_work/parity_*.md` (id `P-..`), ответы пользователя 2026-10-11.

## Высокий приоритет

- **Kill switch на Android** (P-H1, P-S2, S24). Сейчас `caps.killSwitch => !android` (`app/lib/platform/platform_caps.dart:24`),
  группа скрыта (`settings_conn.dart:222–291`), плашка blocking не возникает (`vpn_alert.dart:37–39`). Мокап: `50-home.js:27–46, 140–142`,
  `56-dns.js:241–267`; `docs/rules.md` §7. Нужен дизайн для TUN: держать TUN как blackhole при падении ядра, killOnDisconnect с плашкой
  «blocking» и Remove, killWhileClosed, подсказка про системные «Постоянный VPN» и «Блокировать соединения без VPN». Решение по дизайну — пользователя.
- **Запуск при старте системы** (P-H2, P-S1): тумблер есть, но нет `RECEIVE_BOOT_COMPLETED` и приёмника (в манифесте только
  `ResumeReceiver` и `EventActionReceiver`), `runLaunchActions` (`live_core_host.dart:1458`) на загрузку не вызывается.
  Решение пользователя: после загрузки **приложение не открывается, только поднимается подключение**.
- **Убрать «Start minimized» на Android** (P-S5): тумблер мёртвый (`settings_look.dart:227–231`); пользователь: не нужен —
  «в фоне» и так означает автозапуск без окна.
- **«Links in the clipboard» не работает** (P-H3, подтверждено на телефоне): настройка есть, при открытии приложения ссылка из
  буфера не предлагается. Мокап: `57-general.js:35`, тост-заглушка `32-nodes-forms.js:122`.
- **«Rule for this app» в Live connections** (P-R2, подтверждено скрином): чип только при `x.process` (`live_conns_sheet.dart:555–561`),
  на Android есть только `pkg` (`conn_view.dart:41–42, 60`). На Android — открыть диалог приложения из Per-app (`apps_sheet.dart:305`) для `pkg`.
- **Условие «приложение» (package_name) в форме правила** (P-R1): группа Process на Android мёртвая (`rules_logic.dart:81`
  `desktop: true` → `process_name/path`, `routing.dart:730–737`). Приложение не сочетается с доменом/портом в одном правиле.
- **Модель листов** (P-H4, P-N2, S62): листы — `showModalBottomSheet` поверх всего (`app_sheet.dart`, «Deviation from the mockup»;
  `platforms.md:36` «пока» — не причина). Мокап (`60-sheets.js`, `34-ui.js:45–54`, `20-profiles.js:376–396`, `85-sheet-swipe.js`):
  лист заканчивается над нижней навигацией, тап по вкладке закрывает листы, Route заканчивается у края dock и тап по dock его
  переключает, свайп-закрытие от ручки/шапки (порог 110 px). Возврат заменённого листа по Back — см. `to_think.md`.
- **Тосты под листами** (P-H5, подтверждено скринами): SnackBar из листа (Live connections → Copy) не виден — лист в Overlay выше Scaffold.
  Плюс на Android 13+ «Copied» дублирует системный тост «Copied to clipboard» (скрин Nodes: два тоста сразу), и наш SnackBar светлый,
  не в теме. В мокапе тост всегда поверх (`34-ui.js` `toast`). Делать вместе с общей переделкой тостов (`to_think.md`).

## Средний и низкий

- **Подсказки на карточке источника** (P-N4): «N off, M gone from the subscription» на счётчике и точный возраст обновления
  («Updated 3 hours ago») вместо `8 h` (`30-nodes.js:156–159`; `source_card.dart:261–273`). На телефоне — long-press Tooltip или иное.
- **Раскрытие блока «Unavailable» помнится по контексту** (P-N5): мокап `goneOpen` по ключу (`30-nodes.js:91–112`),
  Android — `bool _open` в State (`gone_block.dart:34–36`), сворачивается при пересоздании.
