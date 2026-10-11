# Инвентарь планов и обещаний (states 1–9, core_isolate_plan, mockup_todo, app/README TODO, docs)

Составлен 2026-10-11, read-only, проверка кода быстрая (1–3 grep на пункт). Источники: `.claude_states/state_1..9.md`,
`core_isolate_plan.md`, `mockup_todo.md`, `app/README.md`, маркеры «не сделано / позже / TODO / решено, не сделано» в `docs/*.md`,
`TODO(...)` в коде `app/lib` и Kotlin-шаблонах.

## Условные обозначения

- **era**: `mockup` = запланировано, пока ведущий продукт мокап (states 1–6 и state_7 до 2026-10-03); `android` = с 2026-10-03.
  Граница по git: первый коммит Flutter `0f89828` (2026-10-03, «Flutter skeleton, Android first») и решения пользователя в `state_7.md`
  «Решения юзера» (Flutter — отдельное приложение, Android первым). Формальная заморозка мокапа — 2026-10-06 (CLAUDE.md «Mockup»;
  коммит `3d611bc` от 10-10 закрепил правило «только заметки в mockup_todo»).
- **Статус** `заявлено → проверено`: заявлено states/docs; проверено grep по `app/lib`, `core/lib`, `design/src` (`done` / `partial` / `open` / `unsure`).
- **Продукт**: core / app (Android) / app (Windows) / app (обе) / mockup only / infra.
- В основном списке только open / partial / unsure. Закрытые — в приложении D в конце. Отклонённые/отложенные пользователем — в разделе Z.

---

# 1. Основной список (open / partial / unsure)

## 1.1 Connect & Home

**S1 — Карточка Speed Test на Home: компактная карточка + лист Speed Test как у ноды.**
Сейчас тап по карточке запускает/отменяет замер текущего подключения (кольцо вокруг иконки, результат двумя строками). Я предложил
компактную карточку + полноценный лист (кольца загрузка/отдача, Latency, Responsiveness) как у Speed Test ноды; ждали «да» пользователя.
Источники: state_9 «Дальше» п.1 («Открыто: карточка спидтеста … ждём «да»»); `mockup_todo.md` (Home → карточка Speed Test).
era: android · заявлено: open (ждёт ответа) → проверено: **open** (`app/lib/widgets/nav_cards.dart:79` `_speedCard` тоглит `host.toggleSpeedTest()`, листа нет). Продукт: app (обе).

**S2 — Переподключение при добавлении правила («в идеале избежать»).**
Пользователь: при добавлении/изменении правила туннель переподключается; хочет по возможности без этого. Вывод в state_9: правило без
рестарта в sing-box невозможно (маршруты — часть конфига). «Auto↔Manual не должно переподключать вообще» — это сделано (см. D37).
Источники: state_9 п.1 («Правило без рестарта — невозможно в sing-box») и п.3. era: android · заявлено: open (нужен способ смягчить) →
проверено: **open** (`live_core_host` сверяет `planSig` и переподключается после `reconnectDelay`, app/README «Перерисовки»). Продукт: core + app.

**S3 — «Direct → если не открывается → цель» (выученный список).**
Идея пользователя (после isolate, «если не переставит»): у правила Direct опция «If it doesn't open → <цель>» (по умолчанию основной
поток). Детектор — поток закрытых соединений (direct, отправлено > 0, принято 0 / таймаут / RST; 2 отказа подряд, не когда лежит весь
прямой путь) → домен в выученный локальный rule-set на диске (sing-box перечитывает local rule-set сам), правило «learned → цель» перед Direct.
Первый запрос теряется, дальше идут через VPN. Список в Rules (домен, когда, почему; удалить/очистить), TTL ~7 дней → снова пробуем direct.
Проверить: действительно ли наша версия sing-box авто-перечитывает local rule-set.
Источники: state_9 п.7; connect-model.md:539 («основа будущего «Direct → если не открылось → цель»»). era: android · заявлено: open →
проверено: **open** (основа — `FailureBook`/`conn/failing`, `core/lib/src/failures.dart` — есть; выученного списка нет: в `routing.dart` «learned» только в комментарии). Продукт: core + app.

**S4 — Fallback («If unavailable») для Route = Direct.**
В per-app диалоге и правилах Fallback на Direct отложен: непонятно, как надёжно определять недоступность Direct. Тесно связан с S3.
Источники: state_6 «Сделано» и «На потом»; rules.md §3 (при Direct/Block Fallback приглушён). era: mockup ·
заявлено: отложено → проверено: **open**. Продукт: core + app.

**S5 — Гео-провайдер для выхода, где режут все гео-сервисы.**
Если в какой-то стране все 7 сервисов Exit IP недоступны/без гео — добавить доступный там гео-провайдер; проверка `dart run tool/exit_check.dart` на такой ноде.
Источники: state_1 «Open / ideas». era: mockup · заявлено: идея → проверено: **open** (7 проб в `core/lib/src/exitip.dart`, новых нет). Продукт: core. Приоритет низкий.

**S6 — Скорость в тексте постоянного уведомления VPN.**
Источники: `app/android_overlay/kotlin/JormungandVpnService.kt.tmpl:40` (`TODO: live speed in the notification text`); app/README «TODO»; connect-model.md:731 («скорость — позже»);
platforms.md:361; state_8 «Позже». era: android · заявлено: open → проверено: **open**. Продукт: app (Android).

**S7 — Статус «VPN отозван» (revoked) в UI.**
Система может отозвать VPN; Kotlin `onRevoke` закрывает туннель (`JormungandVpnService.kt.tmpl:115`), но в UI отдельного статуса нет.
Источники: app/README «TODO → Позже»; state_8 «Позже». era: android · заявлено: open → проверено: **open** (в `app/lib` нет обработки «revoked»). Продукт: app (Android).

**S8 — Цепочки: проверить после беты с PairBook; HY2-выходы remna «недоступны».**
(а) Мерится ли выход через вход в ядре (`_checkRoute` сначала вход), не валится ли выход из-за мёртвого входа, сброс `fails` при смене входа — нужен журнал с телефона
(пользователь видит «failed its checks» между двумя выходными нодами = переключение внутри группы выхода `auto/switched`).
(б) HY2-выходы цепи remna «недоступны»: на клиенте не воспроизводится (`core/test/pair_udp_test.dart`), вероятно сервер входа режет/хэйрпинит UDP; ждём от пользователя строку
`Ping: N of M did not answer (failed tests: …)` и какой сервер — вход remna.
Источники: state_9 «Дальше» п.1 и п.4. era: android · заявлено: ждёт данных пользователя → проверено: **unsure** (код PairBook есть; без журнала подтвердить нельзя). Продукт: core.

**S9 — Детектор «не открывается»: не опираться на `up > 0`.**
sing-box в ~85 % мгновенных отказов отдаёт `up=0`; убедиться, что детектор/ретрай сайта не полагается на `up>0`.
Источники: state_9 п.1 (ссылка на `c1bb565`). era: android · заявлено: open → проверено: **partial**
(`failures.dart:74` `isFailure` = `down == 0` — хорошо; но `auto.dart:623` запоминает адрес для повтора сайта (`_failDests`) только при `c.up > 0`, т.е. мгновенные отказы с up=0 не повторяются на других маршрутах). Продукт: core.

**S10 — Живые соединения: «группировать по приложению» показывает id пакета.**
Мелочь: вместо имени приложения на Android — идентификатор пакета. Источник: state_9 п.1 («Мелочь»). era: android · заявлено: open → проверено: **unsure** (не искал в `live_conns_sheet.dart`). Продукт: app (Android).

## 1.2 Nodes / Sources / Chains / Auto

**S11 — Отказ ноды: остаток сценария (сводное уведомление, значок «не пропускает трафик»).**
Решено в схеме из 5 шагов (`connect-model.md` «Отказ ноды…»): не сделаны (а) сводное уведомление по нескольким недоступным сайтам, (б) значок «не пропускает трафик» (нода жива по пингу, но трафик не идёт; сейчас только мёртвый пинг), (в) «Не показывать для A» — по смыслу покрыто «Ignored sites» (сделано 10-07), но формулировка в доке осталась.
Источники: state_3 «Шаг 3 сделан → Не сделано»; connect-model.md:519,526. era: mockup · заявлено: не сделано → проверено: **partial** (Ignored sites есть; (а),(б) отсутствуют; строка доки 519 устарела). Продукт: core + app.

**S12 — `speedOnFail`: замер скорости текущего сервера после неудачных запросов.**
Тумблер есть в Settings → Auto mode, логика (порог/реакция) не написана.
Источники: connect-model.md:458 («логику порога / реакции — позже»); core.md «Не сделано в MVP». era: mockup · заявлено: open → проверено: **partial** (`catalog/settings.dart` + `settings_auto.dart` — только поле/UI; в `auto.dart` не читается). Продукт: core + app.

**S13 — Проверка UDP / NAT сервера (`StartSTUNTest`) рядом со Speed Test.**
Пропускает ли сервер UDP (звонки Telegram/WhatsApp/Discord, игры, QUIC) и тип NAT. Решение пользователя: «юзер пока не понял пользы» — делать только если решит.
Источники: state_3 п.3.8 («Под вопросом»); state_4. era: mockup · заявлено: вопрос → проверено: **open** (в коде только сгенерированный proto `sbapi/started_service.pb*.dart`, вызова нет). Продукт: core + app.

**S14 — Auto: пауза/растяжение проверок при выключенном экране (мобильный режим).**
state_2: «пока всё лежит — раз в 10 с (на мобилке потом растягивать)»; core.md: «пауза при выключенном экране» не сделана.
Источники: state_2 Auto п.1; core.md «Не сделано в MVP». era: mockup · заявлено: open → проверено: **open**. Продукт: core + app (Android).

**S15 — Ограничения Auto/Fallback/DNS в ядре.**
(а) группы целей правил AutoService не ведёт — их Priority меняется только новым планом; `FallbackService` («If unavailable» на лету) Priority тоже не двигает;
(б) переключение DNS не меняет `default_domain_resolver`; (в) в `status.auto` нет состояния целей правил (только события `rules/fallback`, `rules/targetBack`).
Источники: core.md «Не сделано в MVP» (1123–1127), core.md:823. era: mockup · заявлено: не сделано (ограничения) → проверено: **open**. Продукт: core.

**S16 — Проверка сервиса через узлы (второй индикатор в пикере цели правила).**
В пикере цели правила второй индикатор у каждого узла — открывается ли хост из правила через этот узел (переиспользовать `probeReach` + пул). Категории: 2xx/3xx ок, 403/451 отказ (геоблок/бан IP), сброс TLS (DPI), таймаут.
403 считать блоком, только если через другие узлы/напрямую 200. Запуск по ⚡ в шапке пикера, не при каждом открытии. Решение пользователя: «в долгий ящик / просто в план».
Источники: state_6 «На потом» п.1; state_7 (страна выхода — блоки по стране через эту проверку). era: mockup · заявлено: отложено → проверено: **open** (`probeReach` только для повтора сайтов, `auto.dart:352`). Продукт: core + app.

**S17 — Аудит «проверок через сервер, который пользователь явно не выбирал» + настройка.**
Причина: сервисы смотрят не только на IP — запросы к одному сервису с разных адресов при прочих равных могут снизить траст. Различать нейтральный test URL (безвреден) и реальные адреса пользователя (site/blocked: повтор через другой маршрут `auto.dart _sites`; будущая проверка сервиса S16).
Настройка по умолчанию вкл, можно выключить. Источники: state_6 «На потом» п.2. era: mockup · заявлено: отложено → проверено: **partial** (siteRetry Off / Up to 3 / All есть; общего аудита и единой настройки нет). Продукт: core + app.

**S18 — Диалог удаления цели не называет запасную цель правила.**
`targetImpact` проверяет только `target`/`h.target`, не `fallbackTarget`. Источники: state_6 «На потом» п.3. era: mockup · заявлено: open → проверено: **open**
(`core/lib/src/catalog/impact.dart:86–103`). Продукт: core + app.

**S19 — Правила с учётом страны текущего выхода (идея).**
Идея пользователя (не структурирована): сервисы страны Б — через сервер страны Б, не гонять трафик через VPN без нужды, не попадать под блок узла/страны.
Набросок: цель «серверы страны X» (группа по флагу) + условие geosite/geoip страны X; блоки по стране — через S16.
Источники: state_7 «Ответы юзера (03.10)». era: android (03.10) · заявлено: идея → проверено: **open**. Продукт: core + app.

**S20 — Фичи Karing, которые пользователь предложил рассмотреть.**
Решение пользователя: «потом посмотрим, что нужно, что автоматизировать, добавить/изменить». Список: IPv6 — **сделано** (`37d2493`), NTP, настройки TUN (MTU и т.д.; сейчас только stack Mixed/System/gVisor),
Mixed (вход), TLS (фрагментация и пр.), Mux, порт (Proxy port уже есть), общий доступ к сети (LAN sharing порта прокси), WARP (регистрация Cloudflare WARP, WireGuard-узел, WARP как вход/выход цепочки).
DNS, Правила, Автовыбор уже есть. Источники: state_7 «Дальше»; state_8 «Позже». era: android (03.10) · заявлено: рассмотреть → проверено: **open** (NTP/Mux/TLS/WARP/LAN-sharing в `core/lib/src` не найдены; `settings_conn.dart`: только Proxy port, Kill switch, TUN stack, IPv6, test URL, Backup checks, Close connections on route switch). Продукт: core + app.

**S21 — Decrypt password подписки.**
Хранится, но не применяется: «зашифрованных подписок с паролем в спецификации нет». Источники: subscription-parsing.md:146–147; core.md «Не сделано в MVP». era: mockup · заявлено: нет спецификации → проверено: **open** (блокировано спецификацией). Продукт: core.

**S22 — XHTTP-ноды и Xray сбоку.**
Ноды, которых sing-box не умеет (XHTTP), показываются, но в конфиг не идут (`node.unsupported`); «если понадобится — Xray сбоку только для таких нод». Источники: core.md:8. era: mockup · заявлено: «если понадобится» → проверено: **open** (опционально). Продукт: core.

**S23 — Автовыбор URL пинга.**
Сейчас выбор в Settings → Connection (по умолчанию gstatic), автоподбор не сделан. Источники: core.md «Не сделано в MVP» (1121–1122). era: mockup · заявлено: не сделано → проверено: **open** (низкий приоритет). Продукт: core + app.

## 1.3 Rules / DNS / Apps / Kill switch

**S24 — Kill switch на Android (вернуть, не «урезанный порт»).**
Решение пользователя (CLAUDE.md «Priorities», state_9 п.8): всё выпавшее при сборке Android возвращаем. Сейчас `caps.killSwitch => !android`
(`app/lib/platform/platform_caps.dart:24`; ядро делает kill switch через системный прокси Windows). Нужен Android-вариант (VpnService/TUN: блок при падении sing-box; подсказка про системные «Постоянный VPN» и «Блокировать соединения без VPN»).
Источники: state_9 п.8; CLAUDE.md «Priorities»; docs/rules.md §7. era: android · заявлено: gap to close → проверено: **open**. Продукт: core + app (Android).

**S25 — Kill switch «упало всё»: правила с явным Direct пропускаем.**
Решено: когда ядро упало и ни одна запись Auto не пропускает трафик — блок, **кроме правил, у которых в «If unavailable» явно Direct** (решение пользователя для этих адресов); пока kill switch включён, в таком правиле висит предупреждение. При офлайне ОС не забыть утечку в окне до 10 с.
Источники: rules.md:510–513 («Решено, не сделано»); state_3 «Решено юзером, не сделано». era: mockup · заявлено: не сделано → проверено: **open** (исключения в коде не нашёл; детали unsure). Продукт: core + app.

**S26 — Kill switch для TUN (Windows, WFP).**
В TUN сейчас только `strict_route`; непостоянные WFP-фильтры (снимает перезагрузка); постоянные — только у явных опций S27. В тексте шторки добавить «In TUN mode a reboot also lifts the block».
Источники: core.md «Не сделано в MVP»; rules.md:468–469, 492–494; state_7 «Решения юзера». era: android (03.10) · заявлено: план → проверено: **open** (нет WFP в `core/lib`). Продукт: core (Windows).

**S27 — «Запуск с системой»: Выкл / При входе / До входа + kill switch с загрузки + «Блок до старта VPN».**
План (rules.md §7, «план, не сделано»): Settings → General три уровня. При входе (по умолчанию для автозапуска) — задача Планировщика, как у Karing, с наивысшими правами; До входа — ядро (jormd) как служба Windows, права админа один раз;
kill switch с загрузки — постоянные WFP-фильтры (как у Mullvad), пропускают только ядро к серверам, LAN, DHCP; «Блок до старта VPN» (опция «для параноиков», выкл) со страховками (таймаут, `jormd --unblock`, деинсталлятор).
Android: старт по BOOT_COMPLETED + подсказка включить системные «Постоянный VPN» / «Блокировать соединения без VPN».
Сейчас `launchAtStartup`, `startMinimized` — только сохраняемые флаги без действия ОС (в `app/lib` нет автозапуска/трея/BOOT_COMPLETED; `settings_look.dart:221`). Проверять только на живом хосте с разрешения пользователя.
Источники: state_6 «Сделано → План»; rules.md:520–558. era: mockup · заявлено: план → проверено: **open**. Продукт: core + app (Windows; Android — BOOT_COMPLETED).

**S28 — Реальные приложения на ПК: процессы, «Add .exe», иконки, «Survive updates».**
ПК: список запущенных процессов, «Add .exe», иконки из exe; матч по имени процесса по умолчанию, по пути — опция; тумблер «Survive updates» (по умолчанию вкл): сегменты пути, похожие на версию (`app-1.0.9`, `1.2.3`, `v12`) → шаблон, `process_path_regex`
(в Happ выбор по exe ломается при обновлении Discord). Подсказка: в режиме системного прокси работают только приложения, которые его слушаются.
Источники: state_4 п.10; state_5 «Дальше» п.10; state_6. era: mockup · заявлено: open → проверено: **open** (в мокапе только комментарий `42-apps.js:7`; в core нет API процессов; `process_path_regex` — только для glob-путей `routing.dart:737`). Продукт: core + app (Windows) + mockup.

**S29 — Постоянный список приложений, ходивших через VPN + фильтр «Seen» + вкладка «Apps» в Logs.**
Ядро ведёт постоянный список (имя, путь, первый/последний раз, трафик). Показ: фильтр «Seen» в per-app (с поиском) + вкладка «Apps» в Logs по трафику с кнопкой «Route…». Стыковать с Connections (процесс каждого соединения уже известен).
Источники: state_4 п.10; state_5 п.10. era: mockup · заявлено: open → проверено: **open** (grep `Seen`/`appBook` — нет). Продукт: core + app (обе).

**S30 — Упрощённый per-app на Android («только из списка» / «все, кроме списка»).**
Через `include_package`/`exclude_package`; в `platforms.md` отмечено «позже». Источники: state_7 «Ответы юзера»; platforms.md:32; app/README TODO. era: android · заявлено: open → проверено: **open** (`include_package` в core нет). Продукт: core + app (Android).

**S31 — Аудит Android против мокапа/Windows (паритет).**
Решение пользователя: Android — не урезанный порт; всё выпавшее возвращаем. Нужен аудит: `platform_caps.dart` (`systemProxy`, `tunSwitch` — легитимно; `killSwitch` → S24; `dnsResolveForIp` скрыт на Android «Without TUN → Resolve for IP rules» — пересмотреть),
`isAndroid`-условия в `app/lib` (`settings_data.dart`, `live_core_host.dart` и др.), список отличий в `docs/platforms.md` (каждое отличие — с причиной; «пока не сделано» = пробел). Источники: state_9 п.8; CLAUDE.md «Priorities». era: android · заявлено: open → проверено: **open**.
Продукт: app (Android) + core.

**S32 — FakeIP.** Источники: rules.md:16; core.md:675. era: mockup · заявлено: не сделано → проверено: **open**. Продукт: core.

**S33 — Обновление гео-списков / rule-sets по таймеру во время работы.**
Сейчас только при подключении. Источники: rules.md:350; core.md «Не сделано в MVP». era: mockup · заявлено: не сделано → проверено: **open** (в `rulesets.dart` таймера нет). Продукт: core.

**S34 — Приоритет: адресное правило должно побеждать per-app.**
Пользователь считает, что адресное правило должно побеждать правило приложения; сейчас порядок: приложения → свои правила → быстрые → остальное (rules.md §1). Главное меню правил пользователь переделает сам; порядок до этого не трогать.
Источники: state_6 «На потом» п.4. era: mockup · заявлено: ждёт пользователя → проверено: **open** (порядок не менялся). Продукт: core + app.

**S35 — «Импорт из подписки» (Rules) и выбор процесса по пути на десктопе.**
В мокапе заглушка; поле Process есть, пикера файлов нет. Источники: rules.md:6–8. era: mockup · заявлено: не в мокапе → проверено: **unsure** (в `app/lib`/`design/src` строк «from subscription» не нашёл). Продукт: app (Windows) + mockup.

**S36 — Мелочь ядра правил: через `mixed-in` в режиме TUN домены не резолвятся для IP-условий.**
state_7 «Замечено, не чинили» (второй замеченный пункт — падение `_fallbackSelector` без `routing.targets` — исправлен, см. D47). Источники: state_7. era: mockup · заявлено: не чинили → проверено: **unsure**. Продукт: core.

## 1.4 Logs / Events / Diagnostics / Report

**S37 — Перевыпустить токен бота Telegram.**
Токен бота попал в чат; перевыпустить у BotFather и положить заново `npx wrangler secret put TELEGRAM_BOT_TOKEN` из `workers/reports`. Источники: state_9 п.10. era: android · заявлено: ОТКРЫТО → проверено: **open** (действие пользователя). Продукт: infra (Worker).

**S38 — Бэкап приватного ключа отчётов.**
`%USERPROFILE%\.jormungand\report_private.key` — «бэкап обязателен». Источники: state_9 п.10. era: android · заявлено: ОТКРЫТО → проверено: **unsure** (действие пользователя). Продукт: infra.

**S39 — Подтвердить приход Telegram-уведомления об отчёте + проверка на телефоне.**
Тестовый POST → Telegram 200 ok, но «прихода сообщения пользователь не подтвердил». Проверить на телефоне: Send report → id в Telegram, Download log.
Источники: state_9 п.10; коммиты `5d4ad69`, `daa50ed`, `d9a8c7d` (диагностика `_notify/last`). era: android · заявлено: ждёт пользователя → проверено: **unsure**. Продукт: infra + app (Android).

**S40 — Политика fallback по `tunTcpDead` (авто-реакция на мёртвый TCP в TUN) + проба Telegram DC.**
Детектор «осиротевших» SYN и события `core/tunTcpDead`/`tunTcpBack` сделаны; следующий шаг — политика: что делать приложению (авто-переключить стек TUN на gVisor? уведомление?). Также «проба достижимости Telegram DC через выход».
Источники: state_9 п.9–10 («Затем политика fallback по tunTcpDead и Direct fallback на классификаторе отказов»). era: android · заявлено: open → проверено: **open** (`service.dart:216` — только событие; проб Telegram DC в `core/lib` нет). Продукт: core + app (Android).

**S41 — Детектор TUN-TCP не проверен на Windows TUN.**
Пороги выведены из Android-сессий; Windows-TUN этим детектором не проверялся. Источники: core.md:509. era: android · заявлено: ограничение → проверено: **open**. Продукт: core (Windows).

**S42 — Подписи тостов-уведомлений Logs в оболочке; точки «непрочитанное» на пункте Logs.**
`app/README` TODO: «Logs: подписи тостов в оболочке»; `home_shell.dart:48` `TODO(ui): … unseen error / warning dots on the Logs item (mockup .nav-dot)`.
Источники: app/README TODO; state_8 «Дальше»; `app/lib/shell/home_shell.dart:48`. era: android · заявлено: open → проверено: **unsure** (`93880ac`/`9c9846d` сделали тосты с действиями; точки на пункте Logs не нашёл; TODO мог устареть). Продукт: app (обе).

**S43 — Экспорт лога: кольцо шума держит 500 новейших строк соединений.**
Старые `inbound connection` в экспорте не остаются (мешает сопоставлению SYN). Источники: core.md:510–511. era: android · заявлено: ограничение → проверено: **open** (принятое ограничение). Продукт: core.

## 1.5 Updates / Release / CI

**S44 — Windows-обновление: zip + `jorm-updater.exe`, сторож, откат.**
Спецификация готова (`updates.md` §9 Windows): копировать апдейтер во временную папку, ждать выхода процесса, распаковать в `<target>.new`, переименовать, откат на `.old`, сторож `updates/started.json` 30 с, UAC при отсутствии прав. Решение пользователя: апдейтер запускается только для замены файлов, не висит в фоне.
Источники: state_7 «Ответы юзера»; updates.md:436–459, 703–709. era: android (03.10) · заявлено: спецификация → проверено: **open** (в `core`/`app`/`.github` нет `jorm-updater`). Продукт: app (Windows) + infra.

**S45 — CI/релиз для Windows.**
Есть только Android CI (`release-android.yml`). Для Windows нужны сборочный workflow, zip-артефакты, манифесты `windows`; Visual Studio «Desktop development with C++» не установлена (platforms.md:163). Источники: platforms.md:163; updates.md §13. era: android · заявлено: open → проверено: **open**. Продукт: infra.

**S46 — Android: фоновая проверка обновлений (WorkManager) + системное уведомление «Update available».**
Сейчас «фоновой проверки нет, пока приложение не запущено» (updates.md:195); уведомление раз на версию, ключ `updateAvailable` в `notifCfg`, «позже, когда будет экран настроек уведомлений для этого» (экран уже есть).
Источники: updates.md:195, 495–497, 703–711. era: android · заявлено: open → проверено: **open** (в `app` нет WorkManager; в `settings_data.dart` только строка `updateAvailable(version)`, в notifCfg ключа нет). Продукт: app (Android).

**S47 — Тихая установка на Android 12+ — проверить на устройствах.** Источники: updates.md:710. era: android · заявлено: open → проверено: **unsure** (`PackageInstaller` используется; проверка на железе — действие пользователя). Продукт: app (Android).

**S48 — Принудительное обновление (`minSupported`): UX на подтверждение.**
Полноэкранный лист «Update required» с Download & install; подключение VPN не блокируется; вторая кнопка «Not now», пока проверка не удалась. «Решение по UX — предложено, ждёт подтверждения владельца». Источники: updates.md:283–291, 712. era: android · заявлено: ждёт подтверждения → проверено: **unsure** (реализован ли лист — не искал). Продукт: app + core.

**S49 — Первый stable-релиз по тегу `vX.Y.Z` — проверка вживую.**
Stable-путь CI ещё не проверялся живьём (state_8). Сейчас: тег `v0.1.1` создан 2026-10-11 (на `8bf1d4a`), workflow «Release Android» для тега в статусе `in_progress` на момент проверки; stable-релиза в `jormungand-releases` ещё нет (только беты до `0.1.1-beta.11`).
Источники: state_8 «Подпись и автодеплой»; `gh run list`. era: android · заявлено: не проверялся → проверено: **unsure** (идёт прогон). Продукт: infra.

**S50 — Вторая лента обновлений (Cloudflare R2 / иной хост).**
«Минимум для устойчивости: две ленты на разной инфраструктуре». Сейчас одна: GitHub `jormungand-releases` (`appupdate.dart:32`). Решение: «другие источники — потом». R2 на аккаунте не включён. Источники: updates.md:43–45; state_7. era: android (03.10) · заявлено: потом → проверено: **open**. Продукт: infra.

**S51 — Урезать теги libbox (APK ~100 МБ).** Источники: state_8 «Позже»; app/README TODO. era: android · заявлено: open → проверено: **open** (`build_libbox.ps1` берёт теги из sing-box, включая `with_gvisor`). Продукт: infra + app (Android).

**S52 — Скиллы `sync-app` / `release` (опционально).** Источники: state_8 «Дальше». era: android · заявлено: опционально → проверено: **open** (в `.claude/` нет `skills/`). Продукт: infra (tooling).

## 1.6 Settings / Backup / Notifications

**S53 — Перенос данных пользователя в сборку.**
Решение (state_7): данные сейчас не сохранять, перенос состояния для сборки — потом, отдельной задачей. (В state_8 при переходе на release-ключ данные приложения стёрты, подписка добавляется заново.) Старая заметка «147 серверов в `core/.data-dev/run/main/config.json`» (state_6, предложено восстановить ручными узлами, ответа нет) — вероятно потеряла актуальность.
Источники: state_7; state_6 «Данные юзера»; state_8. era: android (03.10) · заявлено: отложено → проверено: **unsure** (нужно решение пользователя). Продукт: app + core.

**S54 — `AppSettings` (тема/масштаб/язык) persistence — TODO в коде.**
`app/lib/state/app_settings.dart:67` `TODO(persistence)`. `app.dart:59` читает язык из настроек, поэтому TODO вероятно устарел. era: android · проверено: **unsure**. Продукт: app.

**S55 — Windows: собственные всплывающие окна уведомлений (`desktopStyle: own`).**
По умолчанию на ПК — собственные окна в углу экрана; в мокапе поле только хранится. Нужны во Flutter Windows. Источники: connect-model.md:745–749; platforms.md:37. era: mockup · заявлено: на ПК нужны → проверено: **open** (приложения для Windows нет). Продукт: app (Windows).

## 1.7 Platform (Android parity, Windows, isolate, TUN stacks)

**S56 — Ядро в отдельном isolate (вариант B).**
Решение пользователя: делать (релиза нет, ломать можно). `CoreService` целиком в worker isolate, `Catalog`+`LiveCoreHost`+UI-сервисы остаются в root. Этапы: 0 замер на телефоне; 1 async `CoreApi` (`log/events/updateStatus/postEvent` → Future; чистые хелперы вынести; `note`, `ruleSetTimes` в CoreApi; `CoreApi.flush()`; `watchApi:false` для пинг-боксов SingBoxProcess);
2 протокол `core/lib/src/remote/` (`CoreServer`/`RemoteCore`) + in-memory транспорт + контрактные тесты; 3 `CoreWorker.spawn` (Windows за флагом); 4 Android-мост (worker-side ChannelLibboxPort, один слушатель событий в root; проверка connect/revoke/adopt/resume/плитка);
5 сглаживание UI, docs; 6 опционально сериализация снапшота, супервизор worker'а (respawn+adopt).
Источники: `core_isolate_plan.md`; state_9 «Дальше» п.2. era: android · заявлено: этап 1 «после коммита» → проверено: **open** (нет `core/lib/src/remote/`; `CoreApi` синхронный: `api.dart:42,51,58,149`; `flush()` только у logbook/eventbook; `watchApi` только в `libbox_runner.dart`). Продукт: core + app (обе).

**S57 — Решение по стеку TUN на Android: gVisor по умолчанию? нужны ли другие?**
`mixed`/`system` на телефоне заработали после того, как приложение перестало исключать себя из VPN (бета 8, подтверждено 2026-10-10); gVisor — «страховка по умолчанию до подтверждения». Решение пользователя: решать по результату (производительность, батарея, совместимость), не по цене. Сейчас умолчание `tunStack = 'mixed'` (`catalog/settings.dart:55`).
Источники: state_9 п.9–10. era: android · заявлено: открыто → проверено: **open** (решение не принято). Продукт: core + app (Android).

**S58 — Android 8–9 (procfs-владелец соединения) не проверен; на API<31 монитор сети не берёт VPN как «сеть по умолчанию».** Источники: state_9 п.10. era: android · заявлено: не проверен → проверено: **open**. Продукт: app (Android).

**S59 — dev-jormd на Windows: `dart.exe` vs `dartvm.exe` в `selfProcessPaths`.** Самоправило использует `Platform.resolvedExecutable` (`config.dart:99`); при запуске jormd через `dart.exe` процесс — `dartvm.exe`. Источники: state_9 п.10. era: android · заявлено: открыто → проверено: **open** (unsure по реальному поведению). Продукт: core (Windows dev).

**S60 — Flutter-приложение для Windows (первая сборка и всё платформенное).**
Первая сборка — Android, потом Windows (решение пользователя). Для Windows нужны: Visual Studio C++, сборка, системный прокси из приложения, трей/`startMinimized`, автозапуск (S27), апдейтер (S44), собственные всплывающие окна (S55), TUN (админ, `core/tunNeedsAdmin`), kill switch/WFP (S26/S27).
Папка `app/windows/` есть (каркас `flutter create`), но не использовалась. Источники: state_7 «Решения юзера»; platforms.md:163, app/README. era: android · заявлено: потом → проверено: **open**. Продукт: app (Windows).

**S61 — Ручная проверка TUN на Windows пользователем.**
TUN в ядре реализован (state_7), но реально не поднимался на этой машине (никогда не поднимать самому); риски для ручной проверки: DNS-петля local-резолвера в TUN, срабатывание self-правила (`process_path_regex`) для ядра и ping-инстансов.
Источники: state_7 «Сделано». era: mockup (на границе) · заявлено: юзер проверит руками → проверено: **unsure** (результат не зафиксирован). Продукт: core (Windows).

**S62 — Листы (sheets) как стек от верха экрана, Back закрывает по одному.**
Во Flutter листы — `showModalBottomSheet`; в мокапе стек. `TODO(ui)` в `home_shell.dart:48`; platforms.md:36 («пока `showModalBottomSheet`»). era: android · заявлено: open → проверено: **open**. Продукт: app (обе).

**S63 — Kotlin: `registerMyInterface` — пустышка; `filesDir/libbox/configuration.json` содержит секрет API sing-box.**
Источники: `app/android_overlay/kotlin/LibboxPlatform.kt.tmpl:195`; app/README TODO; state_8. era: android · заявлено: замечено, не сделано → проверено: **open** (пустышка подтверждена; секрет в файле — unsure, код записи не искал). Продукт: app (Android).

**S64 — На будущее: libbox `StartOrReloadService` (перезагрузка конфига без перезапуска), boxdd (демон sing-box for Desktop: служба для TUN на Windows, отчёты о падениях), `managed_service.proto`.**
Источники: state_3 п.3.8 «На будущее (Flutter)». era: mockup · заявлено: идея → проверено: **open**. Продукт: core + app.

## 1.8 Other

**S65 — Прыжки интерфейса (аудит).**
Отложено пользователем: «потом разберу» (варианты давать по каждому случаю). Скрипты и скрины — `core/.data-dev/jumps/`. Список: значение справа сжимает подпись (Latency test URL, интервалы Auto mode: `.set-value`, `valueBtn`); ячейка пинга DNS `.lat` 52/33/7 px, `.lat.testing` на 2 px ниже; резкие появления (Then Proxy/Direct/Block, режим правки Route, поиск в Nodes);
None/All в выборе серверов 61→44 px; подпись цепочки «used as exit · tap to swap» ⇄ «16 nodes»; Home «Exit IP ⇄ Direct IP», «MB/s ⇄ B/s»; пикер при 320/120 % «No working nodes» ⇄ имя ноды.
Источники: state_4 п.11; state_5; state_6. era: mockup · заявлено: отложено пользователем → проверено: **open**. Продукт: mockup + app.

**S66 — Синхронизация мокапа (одним проходом из `mockup_todo.md`) и `app/SYNCED_FROM`.**
Мокап заморожен (с 2026-10-06); все Android-изменения записываются в `mockup_todo.md`. Когда вернёмся: перенести заметки (ниже), перегенерировать golden `core/test/golden/catalog.json`, очистить `_mockupBehind` (`core/test/catalog_golden_test.dart:265`), создать/сдвинуть `app/SYNCED_FROM` (файла нет).
Заметки в `mockup_todo.md` (по одной на пункт): chainExitOrder по pickOrder; убрать goneBlockHtml из редактора цепочки; Route Simple/Profiles только показывает режим + «Использовать этот режим»; Notifications: предупреждение «Уведомления заблокированы» и подсказка под Status; `42-apps.js` комментарий (удалённое приложение с правилом остаётся видимым);
фильтр подписки не пишет в `gone`; Settings → Data «Auto-download»; Route: раскрытие цепочки Entry/Exit; выход цепочки по паре (PairBook; `15-ping.js`, `70-profile-forms.js`, `20-profiles.js`); Route ⟳ постоянно + блок «Unavailable · N»; dock-ping цепочки по парам;
Logs: чип «Connections» + «Copy site»/«Create rule»; «Игнорируемые сайты»; «Фоновые ошибки»; источник запроса — приложение; внешний чекер check-host.net; редактор цепочки «Disabled in subscription · N»; Home → карточка Speed Test текущего подключения; Auto↔Manual вживую; «Close connections on route switch»;
Logs: диагностика и отчёты (одинаковая шапка, Send report, инкрементальные списки, Download log); Logs раунд правок 2026-10-11 (свёрнутые категории, Ignored sites в листах фильтра, подсказка Raw, группы по 24 строки, плашка «Filtered» убрана).
era: android (с 10-04) · заявлено: open (отложено) → проверено: **open** (`app/SYNCED_FROM` отсутствует; `_mockupBehind` на месте). Продукт: mockup only.

**S67 — Известные баги мокапа (заморожены).**
`42-apps.js targetImpact` падает на неизвестном пакете; сид мокапа `quickCfg` (сервисы на vpn) ≠ первый запуск liveApply (default) — «сид сервисов быстрых правил закомментирован (`40-rules.js`), чеки чинит агент». Источники: state_7 «Мелочи из отчётов». era: mockup · проверено: **unsure**. Продукт: mockup only.

**S69 — Кольца Speed Test во Flutter.**
`app/lib/widgets/speed_test_sheet.dart:198` `TODO(ui)`: в мокапе два анимированных кольца (загрузка снаружи, отдача внутри), во Flutter простой вариант. era: android · проверено: **unsure** (TODO мог устареть). Продукт: app.

---

# 2. Вопросы, которые ждут ответа пользователя

| # | Вопрос | Источник | Примечание |
|---|---|---|---|
| Q1 | Компактная карточка Speed Test на Home + лист как у ноды — «да»? (S1) | state_9 п.1 | предложено, ответа нет |
| Q2 | gVisor по умолчанию на Android? нужны ли стеки mixed/system? (S57) | state_9 п.9–10 | решать по результату (производительность/батарея/совместимость), не по цене |
| Q3 | Telegram-уведомление об отчёте реально приходит? (S39) | state_9 п.10 | тестовый POST дал 200 |
| Q4 | UX принудительного обновления (лист «Update required» + «Not now») — подтвердить (S48) | updates.md:291 | |
| Q5 | Нужна ли проверка UDP/NAT (STUN)? (S13) | state_3 п.3.8 | пользователь «не понял пользы» |
| Q6 | Global: оставлять ли Block и приложения (сейчас «правила не применяются вовсе») | rules.md:515–518 | «по умолчанию, требует решения» |
| Q7 | Десктоп: Apps = процессы и условие «Process» в правилах — оставить оба? | rules.md:221–223; state_2 | «пользователь не комментировал» |
| Q8 | Отмена решения `pinSHA256 → insecure` (sing-box не умеет пин сертификата у hy2) | state_8 «Дубли HY2» | «юзер может отменить»; parserVersion 4 |
| Q9 | Строка `Ping: N of M did not answer (failed tests: …)` и какой сервер — вход remna (S8) | state_9 п.1 | ждём данные |
| Q11 | Какие фичи Karing брать (NTP, TLS, Mux, LAN sharing, WARP, TUN-настройки) (S20) | state_7 | «потом посмотрим» |
| Q12 | Ужимать ли per-app диалог при Split и подсказку Password | state_5 «Мелочи» | «ответа не было» (state_6 применил часть: диалог по центру, подсказка в (?)) |
| Q13 | Приоритет правил vs per-app (S34) | state_6 | пользователь переделает меню правил сам |
| Q14 | Перевыпуск токена бота, бэкап приватного ключа отчётов (S37, S38) | state_9 п.10 | действия пользователя |
| Q15 | Перенос данных/серверов в новую сборку; 147 серверов из `config.json` (S53) | state_6, state_7 | state_8: подписки добавлены заново; вероятно неактуально |
| Q16 | (закрыто/устарело) Возврат на верхнюю запись: всегда vs «не медленнее текущей на threshold» | connect-model.md:1138–1141 | фактически решено настройкой returnTo always/faster/never (state_3 3a); док устарел |
| Q17 | (закрыто) Что значит «выкл» у паузы между повторами Auto | state_3 | снято: retryPause 0,1–10 с без «выкл» |

---

# 3. Известные нестабильные тесты и технический долг

## Flaky / нестабильное
- **F1** Мокап `npm run verify`: `liveApply is not defined` (state_3, 4, 6; один раз 148/149). Пресет `dock-empty` зовёт `liveApply` при моке; повтор проходит, причину не искали. Мокап заморожен. Статус: open.
- **F2** `core/test/delta_test.dart` — поток 50 МБ падает под общей нагрузкой (state_9 п.1). Статус: open.
- **F3** `core/test/sbapi_singbox_test.dart` ~101 (`closedConnections up>0`): падал ~2 из 3 и на `ecc2017` (не регрессия). Починка в `c1bb565` («retries until a record with up>0 arrives») — результат повторных прогонов не зафиксирован: unsure.
- **F4** sing-box-тесты ядра «a couple flaky under parallel load — rerun singly» (CLAUDE.md «Core»). open.
- **F5** Полный `flutter test` после коммита (state_9 п.1: «Коммит сделан ДО конца полного прогона … проверить результат, подозрение: `pumpAndSettle` на вечном спиннере») — результат неизвестен (unsure).
- **F6** На Windows дочерний sing-box переживает убитый процесс теста (state_3 «Известные хвосты»); обход — команда чистки из CLAUDE.md; Job Object (`killjob.dart`, state_7) закрыл основной случай.
- **F7** Плавающая проверка «route: a long node name wraps under its flag» (state_4 «Хвост»). Мокап. unsure.
- **F8** (закрыто) 4 падающих `flutter test` + overflow 3.6 px (`stat_cards.dart:205`) из state_8 — исправлено `093f2d3`.

## Технический долг / устаревшая документация
- **T1** Устаревшие места docs: `connect-model.md:1133–1145` «Открытые вопросы для бэка» (окно Auto «верх…якорь+standby», проверка по неудачным запросам — уже сделаны); `core.md:1118` «Не сделано в MVP» (часть Auto сделана); `updates.md:44` «`releaseFeeds` пока пуст, TODO» (в `appupdate.dart:32` лента задана);
  `connect-model.md:711` «пока только English, Русский выключен «soon»» (русский сделан); `connect-model.md:519` («Не показывать для A» — см. S11); `rules.md:3` «Статус: §0–§7 сделаны в макете» при заморозке; `updates.md:703–712` «Открытые вопросы» (часть решена).
- **T2** `app/flutter_test_output.txt` закоммичен (`git ls-files` показывает) — мусорный файл.
- **T3** Worktrees агентов в `.claude/worktrees/` (gitignored, state_2: «можно удалить») — на диске три `agent-*`.
- **T4** TODO в коде: `home_shell.dart:48`, `app_settings.dart:67`, `speed_test_sheet.dart:198`, `JormungandVpnService.kt.tmpl:40` (см. S42/S54/S69/S6).
- **T5** (закрыто) state_9 `4a` (немеренный сервер в `_firstAlive`/`coreGroupNode`) и `5` (`route_check` писал -1 при полном провале `pingPairs`) — исправлено (`catalog.dart:513–545`, `route_check.dart:117–122`).
- **T6** Решения агентов по подпискам «приняты по умолчанию» (state_2): интервал = период провайдера ≥1 ч или глобальный (позже заменён секундами с единицами); Proxy/Proxy-first без туннеля — напрямую; фильтр регистрозависимый; WireGuard не поддержан как outbound (`parse/build.dart:356`, «endpoint, not an outbound»). Не пересматривались.
- **T7** `/tmp` в Bash-инструменте не настоящий — временные файлы класть в `core/.data-dev/` (state_4).
- **T8** Ограничение окружения: порты 2080/9090 и системный прокси Karing (127.0.0.1:3067) — чужие, не трогать (state_3/5).

---

# Z. Отклонено / отложено решением пользователя

- **Z1** Фильтр нод по выходному IP — «пока забудь» (state_5).
- **Z2** SSE jormd → UI: не делаем (во Flutter слоя нет) (state_3 п.3.8).
- **Z3** Незаметный повтор запроса при неудачном dial (внутри sing-box, форк) — юзер отложил, «форки не искать» (state_3).
- **Z4** Группировка в профилях — «пока оставь» (state_4).
- **Z5** Наборы правил по сети (Wi-Fi SSID, «дом/работа») — «пока нет, возможно никогда» (rules.md:560–563).
- **Z6** Системный прокси на Android — не делаем, режим скрыт (state_7).
- **Z7** R2 для отчётов — на аккаунте не включён; используем KV, 90 суток (state_9, решение пользователя).
- **Z8** Нумерацию вида «Auto 2» не использовать (state_2/3) — правило оформления, не пункт плана.
- **Z9** Действующие ограничения (не пункты плана): TUN и системный прокси на хосте не включать; корпоративную сеть за домашним роутером не трогать (state_2/3, CLAUDE.md).

---

# D. Приложение: сделано (заявлено states и подтверждено кодом/git) — только заголовки

D1 Exit IP: 7 сервисов параллельно (`exitip.dart`) · D2 Fastest стартует на живом сервере (planGroup) · D3 jormd `--data` абсолютный · D4 Пинг как в Karing (`probe.dart`, probe-in) · D5 Локальные сети всегда напрямую (в т.ч. Global)
D6 Auto: запасные (`failAfter` 1–5, `standby` 0–20, `warmEvery`) · D7 Auto: все записи в конфиге, переключение без разрыва, returnTo always/faster/never, flap guard, retryPause, пачки по 10, noNet · D8 Clash API → gRPC API service (`sbapi.dart`) · D9 Speed Test сервера (Nodes ⋮)
D10 Отказ ноды: запросы/чекеры/запасные проверки (Backup checks), тост «сайт недоступен» с Rule · D11 If unavailable на ходу (`fallback.dart`), Fallback на цель (+ основной поток) · D12 DNS failover (`dns_failover.dart`) · D13 Порт прокси с паролем (`sys-in`)
D14 Резолв для IP-правил (DNS) + «IP conditions only in TUN» · D15 Kill switch для системного прокси (+ downProxy, closed-confirm) · D16 Per-app (Android — `package_name`/`exclude_package`; Split TCP/UDP; Fallback) · D17 Пикер целей Route-стиль
D18 Форма правила: «+ Condition», Form ⇄ JSON · D19 Logs: бейджи, группировка, Live connections как в Karing, rulenames · D20 Русский интерфейс (i18n, ARB, `audit-ru`)
D21 Общий пул проверок (`pool.dart`) · D22 Журнал: site/blocked / unreachable, перебор Off / Up to 3 / All · D23 Crash-safe состояние (`durable.dart`) · D24 Job Object (`killjob.dart`)
D25 Kill switch «Also while the app is closed» через шторку подтверждения · D26 TUN в ядре + TUN stack (Mixed/System/gVisor), Proxy по умолчанию · D27 CoreService/CoreApi, модель каталога на Dart, golden-тесты · D28 Обновления: подписанный манифест, ленты, Android-установка, дельты (`delta.dart`, CI «Delta patches»), автоскачивание Off/Wi-Fi/Always
D29 Android: Flutter-приложение (все экраны), libbox, VpnService, плитка, уведомления (POST_NOTIFICATIONS, действия), ядро переживает окно, переподключение после обновления · D30 Release-keystore, CI beta (`release-android.yml`), `build_apk.ps1`
D31 Дубли HY2 исправлены (parserVersion 4) · D32 Интервал обновления подписки в секундах · D33 Import config file → локальный источник (kind `file`), QR share/scan (flutter_zxing) · D34 Route check цепочки (pair-ping), «?»-справки
D35 PairBook: выход цепочки по паре, `status.auto.pairs`, dock-ping по парам · D36 Игнорируемые сайты, фоновые ошибки, внешний чекер check-host.net, источник запроса (пакет) · D37 Auto↔Manual без переподключения, «Close connections on route switch» · D38 Speed Test текущего подключения (карточка Home)
D39 Редактор цепочки: «Disabled in subscription · N» · D40 Android не исключает себя из VPN (self-rule `package_name → direct`), реестр `outside_tunnel.dart` + сторож-тесты · D41 Детектор TUN-TCP (`tun_ingress.dart`, события `tunTcpDead`/`tunTcpBack`), FailureBook (`conn/failing`)
D42 Logs/диагностика: одинаковая шапка, Send report (шифрование JRP1 на устройстве), Worker `jormungand-reports` (KV, rate limits, Telegram), Download log (`reportToText`) · D43 IPv6 настройка · D44 Экран Settings → Notifications (все типы) · D45 Пинги сохраняются между запусками (`pings` в снимке)
D46 Версия sing-box на Android из libbox · D47 `_fallbackSelector` без `routing.targets` исправлен · D48 Подписи/тосты Nodes во Flutter: QR, «?»-справки, Route check (state_8 «заглушки Nodes» закрыты коммитами `06fa836`, `619aff0`) · D49 4 устаревших flutter-теста исправлены (`093f2d3`)
