# State 5: шаги 6–9, per-app, пикер целей, Logs, Connections, русский интерфейс

Отправная точка для новой сессии. Ограничения — `state_3.md` («Ограничения»), методология работы —
CLAUDE.md «Working method». Этот файл: что сделано после `state_4.md` и с чего начинать.

## Где всё лежит
- Ветка `claude/core-mvp`, влита (fast-forward) в ветку по умолчанию
  `claude/karing-fork-environment-a45c2c`. Мокап: `npm run verify` 143/143.
- jormd у юзера: `dart run core/bin/jormd.dart --data core/.data-dev --lan` (launch config `jormd`).
  Перезапуск — постоянное разрешение (см. CLAUDE.md: гасить и его sing-box).
- TUN и системный прокси на хосте не включались и не проверялись; системный прокси ПК — Karing
  127.0.0.1:3067, порты 2080/9090 чужого софта не трогать.

## Сделано (сессия после state_4)
- 6. If unavailable на ходу: селекторы `<target>~<fallback>` + SelectOutbound (core/fallback.dart).
- 7. DNS failover через clash_mode (dns_failover.dart), status.dns {active, auto, servers}.
- 8. Порт прокси: пароль опционален (генерируется или свой), копирование SOCKS5/HTTP, ⟳, при
  пароле системному прокси — свой открытый порт sys-in (status.sysPort).
- 9. Resolve для IP-правил в DNS (auto/off/сервер) + «IP conditions only in TUN» в правиле.
- Per-app: порядок Default/Proxy/Direct/Block, If unavailable, Split TCP/UDP для любого действия,
  диалог с верхом на 1/3 экрана. Пикер целей в стиле Route (AUTO в шапке, Save-бар, повторный тап
  снимает выбор → основной поток).
- Форма правила: условия только через + Condition, × на поле, Form ⇄ JSON без потерь.
- Logs: бейджи непрочитанного по строкам (видна на экране = прочитана), цвет по худшему уровню,
  разделители, группировка одной секунды.
- Live connections как в Karing (76-conns.js): сортировка, фильтр (протокол / приложение / правило /
  Exit / хост), Filter by exit, пауза, копирование, Close shown, подробности с «Rule for this host /
  app…».
- Русский интерфейс: 03-i18n.js (DOM-слой, ключ = английский текст), 04-i18n-ru.js (словарь +
  глоссарий), docs/i18n.md, пресеты `ru-*`, `audit-ru`, выгрузка в ARB (tools/i18n-extract.mjs).

## Решения юзера по переводу
- Nodes — «Узлы», node — «узел». Auto, Fastest, Direct, Block — не переводить. Системный прокси —
  «sys proxy» без перевода. Kill switch, TUN, DNS и протоколы — по-английски.

## Доделано перед передачей
- Глоссарий выше применён в 04-i18n-ru.js.
- Connections: имя правила вместо сырой строки sing-box (ядро `rulenames.dart`, ruleName / ruleKind /
  ruleId в /api/traffic; sing-box 1.14 шлёт только условия правила без индекса, списки >3 обрезаны —
  сопоставление по тексту, при неоднозначности имени нет), «Open rule» в подробностях; группировка по
  сервису по умолчанию (Service / App / None в листе Sort and group).
- Сортировка узлов (Nodes ⋮) сохраняется между запусками (`genCfg.nodeSort`), кнопки — переключатель.
- Проверки: `npm run verify` 143/143, `dart test` 253. jormd перезапущен с новым ядром.

## Дальше
- 10. Настоящие приложения (per-app), подробно в `state_4.md` «Дальше» п.10: процессы ПК, «Add .exe»,
  иконки, матч по имени, «Survive updates» (process_path_regex), постоянный список приложений,
  ходивших через VPN (фильтр «Seen» в per-app + вкладка «Apps» в Logs с «Route…»), Android через
  PackageManager. Connections уже знает процесс каждого соединения — стыковать с ним.
- 11. Прыжки интерфейса — список в `state_4.md` «Дальше» п.11 (юзер разберёт сам, варианты давать
  по каждому случаю).
- Мелочи: текст подтверждения toggleKillSwitch всё ещё «(If the VPN cannot recover: Remove proxy)»;
  предлагалось ужать диалог per-app при Split и подсказку Password (ответа не было).
- Фильтр нод по выходному IP — юзер: «пока забудь».
