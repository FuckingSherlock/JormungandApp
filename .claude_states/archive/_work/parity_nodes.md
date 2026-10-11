# Паритет мокап -> Android: вкладка Nodes и всё, что с неё открывается

Метод: перечень функций мокапа (`design/src/markup/20-nodes.html`, `60-sheets-nodes.html`, `50-sheets-connect.html`,
`js/15-ping, 30-nodes, 31-catalog, 32-nodes-forms, 33-source-error, 36-qr, 37-share, 38-speed, 58-help, 60-sheets,
70-profile-forms, 72-source-entry`, `css/72-share-data.css`) против Flutter (`app/lib/pages/nodes_page.dart`,
`widgets/nodes_menus, nodes_forms, source_card, node_row, entry_card, entry_editors, source_entry_sheet,
gone_block, route_check, speed_test_sheet, pick_parts, nodes_help, latency_text, app_sheet`,
`core/live_core_host.dart`). Исключены: строки `docs/platforms.md` с нормальной причиной (Scan QR на ПК,
системный прокси, TUN и т.п.) и пункты `.claude_states/mockup_todo.md` (там Android впереди, в т.ч.
блок «Disabled in subscription» в редакторе цепочки).

Итог: основная масса Nodes перенесена полно (поиск, тест всех, меню "три точки", Add/Create, режим правки с ручками,
меню источника/узла/«недоступного», карточка ошибки с Retry, анонс, usage, форма подписки со всеми Advanced-полями
и проверкой regex, ручной узел/группы, импорт файла/буфера/QR, share-лист, delete impact, редакторы профиля и
цепочки, Route settings источника, GoneBlock с «Forget all», проверка маршрута Pairs/By entry/By exit, тест
скорости, 5 тем справки; все ключи тостов мокапа есть в `app_en.arb`). Нашлось 5 расхождений + 1 вопрос к телефону.

## Пробелы

### P-N1. Back не возвращает предыдущий лист (стек листов) — уверенность: высокая
- Мокап: `js/60-sheets.js:53-116` (`sheetStack`, `justClosed`, `goBack`): лист, который закрылся в том же тапе,
  что открыл следующий (Add -> Subscription, меню "три точки" -> Delete -> confirm, меню узла -> Speed test / Share и т.д.),
  заменяется; Back закрывает верхний и **заново открывает заменённый как был**. Закрытие крестиком/свайпом/Done
  стек забывает. Для Nodes затрагивает все цепочки «меню -> форма/подтверждение».
- Android: нет. Каждый переход «меню -> следующий лист» = `pop` меню + новый `showAppSheet`
  (`widgets/nodes_menus.dart:29-32` `_after`; вызовы `:369`, `:454`, `:469`, `:128`); Back с формы/подтверждения
  уходит на страницу, а не в меню. Автор сам оставил `// TODO(ui): sheets ... as a stack that Back closes one by one`
  (`shell/home_shell.dart:48-49`), `app_sheet.dart:11-13` называет это «Deviation from the mockup».
- Сквозное: затрагивает все вкладки (Rules, Settings, Logs), здесь указаны только Nodes-цепочки.

### P-N2. Листы перекрывают нижнюю навигацию и не идут «от верха экрана» — уверенность: средняя
- Мокап: листы открываются сверху и заканчиваются над нижним баром (`60-sheets.js:9-14` `--nav-h`; CLAUDE.md
  «Sheets open to the top, end above the bottom nav»); закрываются свайпом шапки вниз.
- Android: `showModalBottomSheet` поверх всего, закрывает нижний бар (`widgets/app_sheet.dart:14-28`).
  В `docs/platforms.md:36` это записано как отличие платформ «пока `showModalBottomSheet`» — **слабая причина**
  («пока» = «не сделано», а не платформенное ограничение; Flutter позволяет сделать лист поверх `Scaffold.body`
  / во вложенном навигаторе). По правилам проекта это пробел, а не отличие. Средняя, потому что пользователь мог
  принять перекрытие бара осознанно.

### P-N3. Тест скорости: кольца без анимации, упрощённый вид — уверенность: высокая (косметика)
- Мокап: `css/72-share-data.css:120-125,146-148` — кольца download/upload растут плавно
  (`transition: stroke-dasharray .35s ease-out`), на ошибке бледнеют (opacity .35), полоса прогресса
  `transition: width .5s linear` и серая на ошибке (`js/38-speed.js:77-108`).
- Android: `widgets/speed_test_sheet.dart:198-199` — `TODO(ui): the mockup draws two animated rings ... the painter
  below is a plain version`; `_GaugePainter` без анимации (скачок на каждом обновлении, :415-458);
  `LinearProgressIndicator` без плавности и красный (`c.danger`), а не серый (`c.muted`) на ошибке (:286-294).
  Функционально (числа, RPM-слова, Stop/Run again, тексты ошибок, 20 с) совпадает.

### P-N4. Подсказки (hover title) на карточке источника без касания — уверенность: средняя
- Мокап: `js/30-nodes.js:156,158,159` — на счётчике `live/total` подсказка «N off, M gone from the subscription»,
  на возрасте обновления — «Updated 3 hours ago» / «Imported …» (точное время вместо `5m/2h/1d`).
- Android: `widgets/source_card.dart:261-273` показывает `live/total` (жёлтым при gone) и `shortAgo`, без
  пояснения причины и без полного возраста (Tooltip только у «local file»: `:255`). На телефоне hover нет, но
  Tooltip во Flutter срабатывает по long-press; как есть, причину «меньше, чем всего» и точное время обновления
  из карточки не узнать (частично видно по блоку «Unavailable» и серым узлам).

### P-N5. Состояние раскрытия блока «Unavailable» не помнится по контексту — уверенность: высокая (мелочь)
- Мокап: `js/30-nodes.js:91-94,109-112` — `goneOpen` по контексту (`se:<sid>`, профиль, цепочка, карточка):
  раскрытие переживает перерисовку и повторное открытие листа.
- Android: `widgets/gone_block.dart:34-36` — `bool _open` в `State` виджета: при пересоздании (повторное открытие
  листа, выгрузка строки из списка) блок снова свёрнут.

## Низкая уверенность (нужен телефон)

### P-N6. Свайп вкладок Simple/Profiles у края экрана — уверенность: низкая
- Мокап исключает 24 px у краёв (`js/31-catalog.js:8-10,38`, «Android has its back gesture»).
  Android: голый `PageView` без исключения (`pages/nodes_page.dart:197-212`). Вероятно, системный жест сам забирает
  край, но проверить на устройстве.
- Вопрос: на телефоне свайп от самого края экрана в Nodes вызывает «назад» вместо смены вкладки и не листает
  вкладки случайно (или наоборот конфликтует)? да/нет.

## Не пробелы (проверено)
- Все ключи тостов Nodes/форм/Route settings из мокапа есть в `app/lib/l10n/app_en.arb`
  (Address is required, At least 1 server is needed, Entry and exit must be different, Filter is not a valid
  regular expression, Nothing left in Auto, Paste a subscription URL first, Subscription URL found in clipboard,
  Too long for a QR code, Forgot N unavailable servers, No share link, Could not import/load).
- Проверка маршрута: кэш пингов 5 мин, повтор при отсутствии пар через 2 первых входа, пары по входам, виды
  Pairs/By entry/By exit, «Show top 4/Show all», Stop/Check again = `testChainRoute`/`renderChainTest`
  (`widgets/route_check.dart`).
- Route settings источника (`72-source-entry.js`): откат выбора при 0 узлов + тост, Fastest/Priority со свайпом
  переключателя (`form_parts.dart:857`), drag порядка, «off in Nodes», GoneBlock — есть
  (`widgets/source_entry_sheet.dart`).
- Справка: 5 тем Nodes (nodes, srcadvanced, profile, sourceentry, chain) — `widgets/nodes_help.dart`;
  `subsupdate` относится к Settings.
- Регион-правила, дедупликация, URL пинга: в мокапе нет UI в Nodes; настройка URL теста — Settings -> Connection
  (`widgets/settings_conn.dart:314`), не моя зона.

## Связи с другими зонами
- Settings -> Connection (URL теста задержки, интервал обновления подписок, справка `subsupdate`) — `settings_conn.dart`.
- P-N1 и P-N2 касаются всех листов приложения (Route/Rules/Settings/Logs), не только Nodes.
- Logs: TODO про непросмотренные точки ошибок на пункте Logs (`shell/home_shell.dart:48-49`, `.nav-dot`) — не Nodes.
