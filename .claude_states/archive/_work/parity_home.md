# Паритет mockup -> Android: Home и всё, что из него открывается

Дата: 2026-10-11. Только чтение. Область: ConnectDock, Route, режимы, формы профилей/цепочек, шапка, нижняя навигация, первый запуск, текст/темы/зум, поведение листов, тосты, "?"-справки, настройки с Home.
Исключены: различия из `docs/platforms.md`, записи `.claude_states/mockup_todo.md`, демо-данные `12-backend.js`.

## Итог

Home и вложенные экраны портированы почти целиком. Пробелы: 4 high, 1 low. Главное: kill switch на Android, "запуск при старте" не работает без BOOT-приёмника, "ссылки из буфера" ничего не делают, модель листов (стек, nav поверх листов, Back).

## Пробелы

### P-H1. Kill switch на Android не реализован (high)
- Mockup: `design/src/js/50-home.js:140-142` (поля killSwitch / killOnDisconnect / killWhileClosed в connCfg), `50-home.js:27-46` (`renderVpnAlert`: плашки down / kept / blocking с Retry / Disable sys proxy / Remove), `docs/rules.md` §7 (строки 453-520).
- Android: `app/lib/platform/platform_caps.dart:24` `bool get killSwitch => !android;`; группа настроек скрыта (`widgets/settings_conn.dart:222`); плашка blocking не возникает (`widgets/vpn_alert.dart:37-39`).
- Причина "пока не сделано", а не свойство платформы. Нужен дизайн для TUN: держать TUN поднятым как blackhole при падении ядра; killOnDisconnect с плашкой "blocking" и действием Remove; подсказка про системный Always-on VPN + "Block connections without VPN"; вариант `down.proxy kept`. Затрагивает и `killWhileClosed` (`settings_conn.dart:57,426`).

### P-H2. "Launch at startup" на Android ничего не делает (high)
- Mockup: `js/57-general.js` (genCfg.launchAtStartup, подпись "(Android: after reboot)").
- Android: настройка есть (`widgets/settings_look.dart:221`), но в `app/android_overlay/AndroidManifest.xml` только `ResumeReceiver` (MY_PACKAGE_REPLACED) и `EventActionReceiver`; приёмника BOOT_COMPLETED нет, `runLaunchActions` (`core/live_core_host.dart:1458`) на загрузку не вызывается. Тумблер обманывает пользователя; от него зависит и killWhileClosed.

### P-H3. "Links in the clipboard" не предлагает добавить ссылку (high)
- Mockup: `js/57-general.js:35` ("On open, offer to add a subscription or server link you copied"); в самом mockup это настройка и заглушка-тост (`js/32-nodes-forms.js:122`), но функция заявлена.
- Android: настройка есть, на открытии приложения чтения буфера и предложения нет.

### P-H4. Модель листов: стек, nav поверх листов, Back (high по nav, medium по Back/свайпу)
- Mockup: `js/60-sheets.js` (`sheetStack`, `justClosed`, `openSheetOver`, `goBack`, history), `js/34-ui.js:45-54` (`switchTab` закрывает все листы), `js/20-profiles.js:385-396` (`placeRouteSheet`: Route заканчивается над dock; тап по dock переключает Route, `toggleRoute` строка 376), `js/85-sheet-swipe.js` (свайп от ручки и шапки, порог 110 px).
- Android: `widgets/app_sheet.dart` `showAppSheet` = `showModalBottomSheet` ("Deviation from the mockup ... covers the nav bar"); TODO `shell/home_shell.dart:48`; `docs/platforms.md:36` ("пока").
- Различия: nav и dock закрыты модальным листом; тап по вкладке не закрывает листы; Route не заканчивается у края dock; Back не возвращает заменённый лист (напр. после `_explainBroken`); свайп-закрытие не только по ручке/шапке.

### P-H5. Тосты из листов могут быть не видны (low)
- Mockup: `js/34-ui.js` `toast(msg, act, onTap)` всегда поверх, летит в пункт Logs.
- Android: `widgets/app_sheet.dart:31-37` `showToast` = SnackBar через ScaffoldMessenger, Scaffold в `shell/home_shell.dart:498`; модальный лист в Overlay навигатора выше Scaffold, SnackBar из листа теоретически под ним. На устройстве не проверено.

## Проверено, портировано
- Шапка/conn-badge, `#vpnAlert` (кроме blocking, см. P-H1), stat cards, segments, 4 nav-карты (Speed Test на Android реально работает, в mockup инертна), dock-profile с ping-рамкой, DockDownLine, power-кнопка, nothingInAuto/catalogEmpty.
- Route: AUTO/MANUAL, pickMode, переключение режимов, edit, help, explainBroken (читано `pages/route_page.dart:1-450`; строки 450-1362 просмотрены по меткам).
- Редакторы профиля и цепочки (`widgets/entry_editors.dart`), Auto-лист (`settings_auto.dart`), Live connections (`live_conns_sheet.dart`), справки (`HelpTopic`, `NodesHelp`), темы, зум 90-120 %, unseen-бейдж на Logs.

## Вопросы к пользователю (low)
- P-H5: Видно ли тост (например "Copied" или "Not closed") поверх открытого листа, а не под ним?
