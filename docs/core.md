# Ядро (core/) — MVP

Чистый Dart-пакет `jormungand_core` (без Flutter). Flutter-приложение потом подключит его
как зависимость. Пока приложения нет, ядро работает как локальный демон `jormd`: он отдаёт
мокап как веб-интерфейс, мокап управляет ядром через `/api`.

Ядро — только sing-box (1.14.x, бинарник в `core/tool/bin/`, в git не хранится).
Xray не подключён; ноды, которых sing-box не умеет (XHTTP), показываются, но в конфиг не идут
(`node.unsupported`). Если понадобится — Xray сбоку только для таких нод.

## Запуск

```
cd core
dart pub get
dart run bin/jormd.dart            # → http://127.0.0.1:7788
dart run tool/fake_sub.dart        # тестовая подписка http://127.0.0.1:18080/sub (loopback ss)
dart test                          # парсеры, конфиги (sing-box check), loopback e2e
dart run tool/report_keys.dart     # один раз: пара ключей отчётов, закрытый ключ → %USERPROFILE%\.jormungand\
dart run tool/decrypt_report.dart report.bin --out report.json   # открыть присланный отчёт (logs.md → «Отправка»)
```

Бинарник sing-box: скачать `sing-box-<ver>-windows-amd64.zip` из релизов SagerNet/sing-box,
положить `sing-box.exe` в `core/tool/bin/`. Состояние: `%APPDATA%\Jormungand`
(`--data` меняет; для разработки `core/.data-dev`).

`--lan` — слушать и локальную сеть (открыть UI с телефона); адреса печатаются при старте.
Авторизации нет: любой в сети может управлять ядром, поэтому только в доверенной сети.
Windows Firewall должен пропускать входящие для `dartvm.exe` на этот порт.

sing-box привязан к процессу ядра (`killjob.dart`, Windows): Job Object с
`KILL_ON_JOB_CLOSE`, создаётся лениво один раз, в него кладётся только дочерний sing-box
(сам процесс ядра — нет, иначе убились бы и запущенные для пользователя программы, например
браузер). Убили ядро любым способом (`taskkill /F`, крах, убитый тест-раннер) — система
убивает и sing-box, не только при штатном `stop()`. Сбой привязки не фатален: sing-box
работает как раньше, в логе строка `[jormd] sing-box is not tied to the core (…)`. При
старте jormd добивает осиротевшие sing-box от прежних запусков: только тот же самый
бинарник (чужие sing-box, например Karing, не трогаются) и только если родителя уже нет;
убитые pid пишутся в лог. Flutter-приложение получит то же само, ядро в нём работает в
том же процессе. Тест: `killjob_test.dart` (вспомогательный процесс `killjob_helper.dart`
поднимает sing-box, тест убивает его жёстко и ждёт, что sing-box исчез).
Весь код `package:win32` вынесен в `killjob_win.dart` и `elevation_win.dart`; `killjob.dart` /
`elevation.dart` вызывают его только за `Platform.isWindows`. win32 6.x привязывает функции
лениво (top-level `final _X = _kernel32.lookupFunction(...)` — Dart инициализирует их при первом
обращении), поэтому на Android (где `dart.library.ffi` тоже true) подключение пакета не открывает
библиотек и не ищет символов: сборка и запуск безопасны, а tree-shaking Flutter выкидывает код.

Прокси: mixed (HTTP + SOCKS5) на `127.0.0.1:<mixedPort>` (Settings → Connection → Proxy port, по умолчанию 2080). С sing-box ядро говорит только
через его API service (gRPC, свободный порт loopback, см. ниже); Clash API не включается.
Пароль на порт — необязательный (`plan.mixedAuth`, см. «Входы sing-box»); по умолчанию порт открыт. Режим TUN (`plan.mode: 'tun'`) — см. «TUN»; порт остаётся открытым и в нём.

## Кто за что отвечает

| | Мокап (UI) | Ядро |
|---|---|---|
| Источники, профили, цепочки, порядок, Auto/Manual, off/disabled | хранит и решает | хранит снимок (`ui-state.json`) |
| Что подключать (запись + резервные, ноды, fastest/priority) | решает → «план» | — |
| Auto при подключении (failover, возврат, Priority-сервер) | показывает то, что сообщило ядро | `auto.dart` (AutoService) |
| Скачивание подписок, UA discovery, ETag, dedup, gone | — | `fetch.dart`, `merge.dart` |
| Парсинг ссылок / Clash / sing-box JSON | — | `parse/` |
| Локальный источник (импорт файла: текст → источник `kind: 'file'`) | выбор файла, id, карточка | `localsource.dart` |
| Конфиг sing-box | — | `config.dart` |
| Запуск, остановка, пинг | — | `runtime.dart` |
| Системный прокси (Windows) | переключатель | `sysproxy.dart` |
| Ссылка сервера (Copy share link, QR) | просит | `share.dart` |
| Сервер вручную (форма без ссылки, правка) | поля формы | `manual.dart` |
| Лог (вкладка Logs) | фильтр, поиск, копирование | `logbook.dart` |
| Самообновление приложения (манифест, подпись Ed25519, ленты, загрузка) | блок App updates в Settings → Data | `appupdate.dart`, `updates.md` (ещё не в `/api` и не в `CoreService`) |
| Отправка отчёта разработчику (шифрование X25519 + AES-GCM на устройстве, загрузка на Worker) | «Send report» в Logs ⋮ (мокап заморожен — только Flutter) | `report_upload.dart` (`HttpReportUploader`), `report_crypto.dart`, `logs.md` → «Отправка» |

Во Flutter-приложении колонка «Мокап» станет Dart-кодом приложения, а HTTP уйдёт: приложение
создаёт `CoreService` (ниже) в своём процессе и вызывает его методы напрямую, без `jormd` и
без `/api`. `jormd` остаётся только для мокапа.

## Модель каталога (Dart)

`core/lib/src/catalog/` (`catalog_lib.dart`, экспортируется из `jormungand_core.dart`) — колонка
«Мокап» из таблицы выше, портированная в чистый Dart: приложение держит один `Catalog` вместо
JS мокапа. Без Flutter, без IO, без таймеров; время — `now:` (как `now` у `CoreService`).

- **Состояние** = снимок мокапа (`liveSnapshot()`): `Catalog.fromJson(снимок)` / `toJson()` читают и
  пишут тот же JSON, что лежит в `ui-state.json`. Ключи, которых модель не знает (`genCfg`,
  `notifCfg`, `logCfg`, `userAgent` / `usage` подписки, поля нод…), возвращаются как были; ключ,
  которого во входе не было, не дописывается, пока значение дефолтное. Загрузка повторяет `liveApply`
  (`autoConnect !== false`, дефолты настроек, `appNormalize`, встроенные rule sets и DNS-серверы, ключи
  пингов `proto://addr:port` без `#id`). Типы: `Source`, `Profile`, `Chain`, `ModeSlot`, `CatalogNode`,
  `ConnCfg`, `AutoCfg`, `SegState`, `UserRule`, `AppRule`, `QuickCfg`, `RuleSetCfg`, `DnsServerCfg`,
  `DnsCfg`; `PingBook` — единственное хранилище замеров (ключ `proto://addr:port#id`).
- **Решения** (имена как в JS): `effectiveConnectId` (Auto / Manual, `coreRoute` ядра, `ownGuess`),
  `unitNode` / `chainEntryNode` / `chainExitNode`, `knownDead` / `mayWork`, `brokenBy` / `visibleOrder`
  (выключенное в Nodes), `unitRefs` / `profileRefsOf` / `chainEntryRefs` / `chainExitRefs`.
- **План** (`plan_builder.dart`): `livePlan([anchor])` → тот же JSON, что мокап шлёт в `/api/connect`
  (`routes`, `current`, `routing`, `auto`, `urlTest`, `mixedAuth`…; порядок ключей тоже), `planSigOf` /
  `planSig` — строка-подпись, не меняющаяся от порядка пингов и ходов Auto, `routingPlan`,
  `routingTarget`, `targetInfo`. Нет чем подключаться — `CatalogException` с `code`
  (`nothingInAuto` | `nothingToConnect` | `noUsableServer`) и английским текстом мокапа.
- **Проверки и удаление**: `checkBeforeConnect`, `profileProblem`, `chainProblems`; `deleteSourceImpact` /
  `deleteNodeImpact` / `deleteEntryImpact` (список «This will affect» в виде `ImpactLine`).
- **Операции** (`ops.dart`): `syncCatalog` (звать после любой правки), `selectConnect`,
  `setAutoConnect`, `pinRouteNode`, `toggleEntryAuto`, `setConnectMode`, `reorderRoute`,
  `addSource`, `deleteSource` / `deleteNode` / `deleteProfile` / `deleteChain`, `forgetGone`,
  `purgeExpiredGone`, включение / выключение источников и серверов. Каждая меняет `Catalog` и ничего
  не рисует; что показать пользователю (тост «Nothing left in Auto…»), решает вызывающий по результату.
- **Не портировано** (только UI): отрисовка, листы и тосты, drag-жесты (вместо них `reorder*` с новым
  порядком), режимы правки и развёрнутые строки, сортировка нод, журнал событий и настройки
  уведомлений / логов, замер пингов и их расписание, `sourcesDown`, `killPlan`, вызовы `backend` / `api`,
  слияние ответа `fetchSource` в подписку (это `state.dart` ядра).
- **Проверка на мокапе**: `core/tool/catalog_golden.mjs` гоняет настоящий `main_screen.html`
  (Playwright, фиксированные `Math.random` / `Date.now`) по ~65 сценариям и пишет
  `core/test/golden/catalog.json`: снимок и ответы JS (кто подключён, план, подпись, цели, импакт
  удаления, снимок после операции). `core/test/catalog_golden_test.dart` даёт ту же загрузку Dart-модели
  и сверяет всё. Поменяли логику мокапа — `npm run build`, `node core/tool/catalog_golden.mjs`,
  `dart test test/catalog_golden_test.dart`; расхождение значит, что Dart-порт отстал (или мокап поменяли
  намеренно — тогда доки и порт вместе).

## CoreService, CoreApi и платформенные швы

Вся логика ядра (подключение, перезапуск sing-box, kill switch, системный прокси, Auto,
журнал, снимок UI, подписки по таймеру, проверка выхода, пинг, Speed Test) живёт в
`service.dart` — `CoreService`: чистый Dart, без `HttpServer` / `HttpRequest`. `daemon.dart`
(`Daemon`) — только HTTP-адаптер над ним: маршруты, JSON, заголовок `X-Jorm`, проверка Host,
отдача мокапа; те же маршруты и тот же JSON, что описаны в «API (`jormd`)». Один метод
`CoreService` = один маршрут: `state / saveState / status / traffic / log / events / postEvent /
version / manualNode / share / fetchSource / parse / addSourceFromText / connect / disconnect / releaseSysProxy /
retry / killSwitchSettings / autoSettings / dnsAutoSetting / recheckExit / ping / speedTest /
closeConnections`. Тела и ответы — те же карты (`Map<String, dynamic>`), что в HTTP;
`FormatException` — сообщение для пользователя (в HTTP это 400), любая другая ошибка — сбой ядра
(500). `ping` и `speedTest` возвращают `Stream` строк (в HTTP это NDJSON); отмена подписки на
`speedTest` останавливает замер, `ping` досчитывает (результаты нужны пулу).

`CoreApi` (`api.dart`) — абстрактный интерфейс, который `CoreService` реализует: через него приложение
(и адаптер) говорят с ядром. Удалённая реализация (HTTP / IPC к фоновому движку или службе Windows)
сможет реализовать тот же интерфейс; пока есть только внутрипроцессная.

Вместо опроса — потоки (broadcast): `statusChanges` (статус при каждом изменении состояния —
подключение, падение, Auto, проверка выхода — и раз в 4 с, пока есть слушатель, ради замеров внутри
`status.auto`; одинаковый статус подряд не повторяется), `eventStream` (каждое событие журнала),
`logStream` (каждая строка лога). Опрос `status()` / `events(since)` / `log(since)` остаётся.

Жизненный цикл: `init()` — каталог данных, журнал, снимок, прокси, оставшийся от прошлого запуска,
таймер подписок; `dispose()` — штатная остановка: sing-box остановлен, системный прокси возвращён по
правилам kill switch (`killWhileClosed`), потоки закрыты (в `jormd` это `shutdown`).

Платформенные швы — интерфейсы с текущей реализацией по умолчанию, подставляются в конструктор
`CoreService`:

| шов | интерфейс | по умолчанию | зачем подменять |
|---|---|---|---|
| запуск sing-box | `BoxRunner` (`runtime.dart`; `runner:` — главный, `boxFactory:` — одноразовые для пинга и Speed Test) | `SingBoxProcess` (процесс + `-D`, Job Object) | Android: libbox в процессе приложения; тесты: фейк |
| системный прокси | `SystemProxyBackend` (`sysproxy.dart`) | `SystemProxy` (реестр Windows); на Android / iOS — `NoSystemProxy` | платформа без системного прокси: `enable` ничего не ставит, возвращает предупреждение |
| права для TUN | `isElevated: bool Function()` | `processIsElevated` | Android: TUN даёт `VpnService`, права не нужны |
| проверка выхода, таймеры, часы | `exitCheck`, `timer`, `now` | `checkExitIp`, `Timer.new`, `DateTime.now` | тесты |

`BoxRunner.api` по-прежнему `SingBoxApi` (gRPC API service sing-box): Auto, трафик и Speed Test говорят
с sing-box только через него, поэтому другой раннер должен отдавать тот же API (или адаптер к нему).
`singBox` (путь к бинарнику) нужен `CoreService` для версии, списка программ «напрямую» в TUN и
запасного `boxFactory`. Android: `LibboxRunner` (`app/lib/core/libbox_runner.dart`) добавляет к конфигу
службу `api` через `withApiService(config, newApiSecret(), port)` (`runtime.dart`), и `api` — тот же
`SingBoxApi` на loopback; журнал sing-box идёт через `SingBoxApi.logLines()` (процесса с выводом нет).
Платформенная сторона (libbox, `VpnService`) — `app/android_overlay/kotlin/`, шов к ней —
`LibboxPort`. Код Kotlin ещё не собирался.

Свой файл кэша у каждого экземпляра. libbox держит bbolt-файл `cache.db` в рабочей папке и включает его
сам (при `PlatformLogWriter`); файл под замком, и второй экземпляр в том же процессе (бокс пинга при
поднятом туннеле, туннель при идущем пинге) через ~10 с падает с `initialize cache-file: timeout`.
Поэтому `LibboxRunner` кладёт в конфиг `experimental.cache_file.path` (`withCacheFile`, `runtime.dart`;
`cache_id` туннеля сохраняется): туннель — постоянный `<dataDir>/run/main/cache.db`, разовые боксы —
`<cacheDir>/boxes/boxN.db`, удаляется при остановке (остатки убитого приложения чистятся при старте).
Десктоп не затронут: у каждого процесса sing-box свой `-D workDir` (`run/main`, `run/ping-N`, `run/speed`).

**Усыновление работающего sing-box** (Android, `AdoptableRunner` в `runtime.dart`; общая картина —
`docs/platforms.md` → «Работа в фоне»). Туннель живёт в `VpnService`, ядро — в движке Dart; ядро может
родиться заново при живом туннеле. Раннер, который это умеет, реализует `AdoptableRunner`:
`keep(record)` — `CoreService` вызывает его после каждого успешного старта sing-box (`_startSingBox`) и
отдаёт запись `{plan, tunnelPort, probePort, probeSecret, sysPort, sysWanted, ruleSetFiles, upSince}`
(платформа хранит её, пока туннель поднят); `adopt()` — запись или `null`, если ничего не запущено
(бросает `SingBoxError`, если запущено, а подключиться нельзя). `CoreApi.adopt(body)` (тело — то же, что
у `connect` для живого состояния: `dnsAuto`, поля kill switch и `auto` с настройками Auto «сейчас») зовут
в `init()` до чего-либо ещё; ответ: `{adopted: false}` (нечего усыновлять или раннер не умеет),
`{adopted: false, stopped: true}` (работало, но не усыновилось — ядро остановило его, чтобы состояние
было верным) или `{adopted: true, plan, status}`. Ядро собирает конфиг заново из записи только ради
`RoutingInfo` (имена правил, fallback-и, DNS-серверы), не отправляя его; запускает Auto / проверку
выхода, как после `connect`; `start` и `stop` раннера не вызываются. Вызывающий сравнивает вернувшийся
план с тем, что его каталог строит сейчас: разница — обычная смена плана (перезапуск после паузы), а не
тихий рестарт. Десктопный `SingBoxProcess` не `AdoptableRunner`: `adopt` у него всегда `{adopted: false}`.

## Нода

`{id, name, flag, protocol, address, port, outbound, unsupported?}`. `id` =
`n` + 12 hex от sha256(`protocol|address|port|identity|variant`), где `variant` — поля
outbound, меняющие способ подключения (TLS / SNI / ALPN / uTLS / Reality, транспорт с
host / path, obfs…; см. `variantOf` в `node.dart`), прочитанные одинаково из любого формата.
Поэтому id одинаков для одного сервера в любом формате подписки (см. subscription-parsing.md →
Дедупликация), а два варианта одного адреса — разные ноды. `base` — тот же хеш без `variant`.
`outbound` — готовый sing-box outbound без тега. Флаг вынимается из имени (первая пара
regional indicators). `unsupported` — причина, по которой ноду нельзя отдать sing-box (схема
или тип, которых он не знает): нода видна в списке, но в конфиг не идёт.

## План подключения

UI собирает вокруг записи-якоря (своя догадка `effectiveConnectId(true)`: верхняя запись
Auto, которая может работать; в Manual — закреплённая; `94-live-auto.js`):

```
{ routes: [Route],         // по приоритету Route
  current: 1,              // индекс якоря: с него стартует selector
  mixedPort: 2080, global: bool,
  mode?: 'tun' | 'proxy',       // 'tun' — вход tun-in (см. «TUN»); нет / иное = только локальный порт
  mixedAuth?: { user, pass },   // пароль на пользовательский порт; нет = порт открыт
  tunStack?: 'mixed' | 'system' | 'gvisor',   // стек TUN (connCfg.tunStack, по умолчанию mixed); читается только в TUN
  ipv6?: bool,                  // connCfg.ipv6, по умолчанию false: без AAAA в DNS и с отказом IPv6 в TUN (см. «TUN» → IPv6)
  urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold,
             url: connCfg.testUrl /* нет — gstatic; им же проверяет AutoService */ },
  auto: { failAfter, threshold, checkEvery, standby, warmEvery,
          retryPause /*с*/, returnTo: 'always' | 'faster' | 'never', flapGuard, flapMax /*мин*/, flapReset /*мин*/,
          siteRetry: 'off' | '3' | 'all' /* сколько других маршрутов пробовать для упавшего сайта, по умолчанию 3 */,
          siteCheck?: false /* ключа нет = внешний чекер включён (CoreService.siteCheckOn) */ },
  routing: Routing }       // правила, приложения, быстрые правила, DNS — ниже
Route = { id, kind: 'unit' | 'chain', main: Group, entry?: Group }   // entry — вход цепочки, выход идёт через него (detour)
Group = { pick: 'fastest' | 'priority', chosen: 'sid::nid' | null, pinned?: true, nodes: [{ key: 'sid::nid', outbound }] }
```

- Маршруты: в Auto — все записи Auto (`current` — якорь); в Manual — только якорь. Записи без пригодных серверов пропускаются. План без `routes` (старый вид:
  `kind/main/entry` сверху) = один маршрут.
- Теги (`plan.dart`): маршрут i — группа `route<i>` (у цепочки выход `route<i>` с detour на
  `route<i>-entry`), сервер — `route<i>/<sid::nid>`; над маршрутами `selector` `proxy`
  (`default` = `current`), `route.final = proxy`. У `proxy` и групп маршрутов
  `interrupt_exist_connections: false` (переключение Auto соединений не рвёт); у групп целей
  правил — `true`.
- `fastest` → `urltest` (interval/tolerance из Auto mode); `priority` → `selector` с
  `chosen`; `pinned` — сервер закреплён в Manual, AutoService его не двигает.
- `urltest` до конца своего первого круга замеров (со сотней серверов — около минуты) шлёт
  всё через первый сервер списка. Поэтому для `fastest` UI передаёт ноды по известному пингу:
  живые по возрастанию, потом неизмеренные, мёртвые в конце.
- Режим Rules: правила из `routing` (ниже); «через VPN», `final` и `tunnel-in` ведут в
  selector `proxy`, то есть в маршрут, на котором сейчас Auto. Global — всё в `proxy`,
  правила не применяются.
- План строится на выборе самого UI, не ядра (`withoutCore`): переключения AutoService не
  меняют план.
- Подключено и план изменился — UI сам переподключает. Сравнивается состав: маршруты (все записи
  Auto; в Manual тот же состав), серверы групп (у Fastest — без порядка, и в маршрутах, и в целях
  правил), закреп Manual на сервер, правила, Global/Rules, системный прокси, `urlTest`. Auto ↔ Manual
  (`plan.manual`) и Manual на другую запись Auto в подпись не входят: хост шлёт `{manual, entry}` в
  `POST /api/auto`, sing-box не трогается. `plan.auto` не сравнивается: изменённые
  настройки Auto mode UI шлёт в `POST /api/auto`, работающий AutoService берёт их со следующего
  раунда. Не сравниваются порядок по пингу, `chosen` групп маршрутов и
  `current`: пинг и переключения AutoService — не повод рвать соединения. `chosen` цели правила
  сравнивается: её Priority никто, кроме нового плана, не двигает. Пока идёт пинг, проверка
  ждёт его конца.

## Auto в ядре (`auto.dart`)

`AutoService(BoxControl, plan, delay:)` — чистый Dart без UI: демон держит его, пока подключено
(Flutter возьмёт как есть). Раунд — через `checkEvery` (первый через 3 с; после промаха
текущего — через `retryPause`, и такой раунд меряет только его; «нет сети» — раз в 10 с):

1. На каких серверах стоят группы — из потока групп API service (`api.selected`, приходит
   после каждого раунда urltest; до первого ответа раунд ничего не решает). Fastest группа
   текущего маршрута сама сменила сервер → тоже переключение (`reason: fastest`, тост «Auto: …»).
2. Замер сервера, на котором стоит группа (`_ping`: probe, см. «Пинг» ниже): текущий маршрут, все
   выше него (не при `returnTo: never`), раз в `warmEvery` (на ближайшей проверке, не чаще) ещё `standby` ниже
   (запасные; 0 = нет) — параллельно. Цепочка: вход, потом выход
   (его замер идёт через вход и в `members` не попадает: он идёт в `pairs`, а счёт промахов выхода —
   на пару «вход в работе + выход», у новой пары начинается с нуля).
   - Fastest: сервер молчит → `URLTest(<группа>)`: urltest перемеряет всех и сам берёт
     живой; ждём, пока он уйдёт с упавшего или у всех будут свежие результаты
     (`timeoutMs + 5 с` максимум). Ответившие засчитываются как живые (числа — наши, probe).
   - Priority: `failAfter` таймаутов подряд → первый ответивший по порядку (пачки по 10),
     `SelectOutbound(<группа>)`; сервер выше текущего — обратно по правилу `returnTo`.
3. Маршруты: у текущего `failAfter` таймаутов подряд → вместе меряются маршруты выше и
   запасные, потом остальные пачками по 10 по приоритету, пока кто-то не ответит;
   `SelectOutbound(proxy)` на первый по приоритету ответивший. Не ответил никто — `noNet`: ничего
   не двигается (дальше в `noNet` — только первая пачка за раунд). Возврат выше — `returnTo`
   (`always`: ответил `failAfter` раз подряд и не медленнее больше чем на `threshold`;
   `faster`: быстрее на `threshold`; `never`) и испытательный срок защиты от мигания.
4. Раунд без единого ответа откатывает промахи всех, кроме текущего маршрута. Раунд с ответом:
   маршрут, набравший `failAfter` промахов, пока другой отвечал, получает «падение»
   (`strikes`; срок 1, 2, 4 … `flapMax` мин ответов подряд до возврата; сброс после `flapReset`
   работы на нём); со второго — событие `unstable`.
5. После ухода с мёртвого маршрута / сервера: соединения из таблицы потока соединений, у
   которых в цепочке его тег и счётчики байт не изменились за 10 с, — `CloseConnection`
   (каждые 10 с, до 6 раз).

Замер (`_ping`) — тест-URL, не ответил — сразу все запасные проверки (`withCheckers`,
probe.dart; `plan.auto.checkers`, иначе `urlTest.checkers`, нет поля — `defaultCheckers`):
живой, если ответила хоть одна. Идёт через пул замеров (следующий раздел): свежий ответ того же
сервера (пинг UI, замер «If unavailable») засчитывается вместо нового теста — не старше
`reuse` = min(`checkEvery`/3, 20 с); сервер, которого ещё не мерили в этом подключении, — не
старше 2 мин (`startAge`, чтобы первый раунд начинался с пинга запуска).

## Пул замеров и состояние сети (`pool.dart`)

Все проверки серверов — Auto (`_ping`), «If unavailable» (`fallback.dart`), пинг каталога
(`/api/ping`, пинг при запуске) — идут через один `ProbePool` (демон держит один на всё время
работы; у модуля, запущенного отдельно / в тесте, свой приватный `ProbePool.solo()` — ничего не
переиспользует, но склеивание и состояние работают). Так сервер не мерится тремя расписаниями.

**Ключ** — что измерено, а не как sing-box это назвал: `serverIdentity(outbound)` — отпечаток
(FNV-1a 64 бит от канонического JSON outbound без `tag` / `detour`, 16 hex), поэтому один и тот же
узел — один ключ и как участник группы маршрута Auto (`route0/<key>`), и как лист группы цели
правила, и как `t/<key>` в тестере. Выход цепочки — пара `pairIdentity(вход, выход)`
(`<id входа>><id выхода>`, вход — тот сервер, что стоит сейчас); пара — свой ключ, отдельный от
одиночного выхода. К ключу добавляются тест-URL и набор запасных проверок (без URL, по
алфавиту): результат отвечает только на такой же тест. Прямой путь — `directIdentity`
(`direct`). В ключ **не** входит тег sing-box, id источника и ключ UI — ключ ноды в UI
(`src::<id>`) и тег группы в плане с этим не связаны.

**Склеивание.** Запрос на ключ, который уже мерится, ждёт тот замер (один тест на любое число
спрашивающих).

**Свежесть задаёт вызывающий.** `maxAge` — насколько старый ответ годится (старше — меряется
заново; без `maxAge` — всегда заново). Промах живёт отдельно: `missAge` (по умолчанию 0) — не
выдаётся вообще, поэтому «вернулся ли сервер?» — всегда настоящий тест, и закешированный промах
не скроет восстановление и не задержит возврат на сервер; потолок любого `missAge` — `missCap`
3 с (пачка параллельных спрашивающих получит один результат, не больше). `maxAge` Auto —
`reuse` / `startAge` (см. выше), «If unavailable» — `reuse`, пинг UI — 0 («Ping all» всегда
меряет), пинг запуска — `maxAgeMs` в теле `/api/ping`. UI-пинг пишет результат в пул
(`record`), поэтому Auto и «If unavailable» стартуют с него; в самом ядре пул живёт в памяти,
сохраняемые данные пинга — по-прежнему в снимке UI (пул их питает, не заменяет: после
перезапуска демона пул пуст).

**Состояние сети** `ProbePool.status`: `up` | `down` | `unknown`, в `status.network` (`GET
/api/status`): `{status, since (мс), lastAnswer (мс), offline, silent, doubt}`.
- Любой ответивший замер любого модуля (`record` / `probe` с `ms >= 0`: прямой путь, сервер,
  запасная цель, пинг UI) → `up` сразу и снимает все признаки ниже. Ответ локального резолвера
  DNS в `answered` не идёт: он ничего не доказывает про интернет.
- `down` — только по верному признаку: ОС без сети (`missing default interface`, `offline`), или
  ни один маршрут Auto не ответил **и** прямой путь тоже молчит (`silent`; Auto мерит `direct`
  через пул — probe inbound всегда содержит пользователя `direct`).
- Сомнение — `unknown` (`doubt`): промах у текущего маршрута Auto, или ни один маршрут не
  ответил, а прямой путь проверить нечем. Переключения ждут, замеры продолжаются.
- Нет данных — `up` (как предполагали модули раньше); новое подключение / отключение
  (`resetNetwork`) начинает с чистого листа.

Кто что читает: Auto пишет признаки (`doubt`, `offline`, `silent`); «If unavailable» судит
обычные цели только при `up`, цель Main flow — пока не `down` (мёртвый Main flow Auto видит как
сомнение, а `fallback.dart` отличает его от мёртвой сети своими замерами `direct` и запасных
целей: ответ любого из них делает статус `up`); `DnsFailover` — только при `up`. `/api/ping`:
если не ответил ни один сервер, тестер мерит ещё и `direct`; ответил — `up` (серверы мертвы,
сеть нет), молчит — `down` (статус пишется в пул, снимается любым ответом). Итог — поле
`network` (`up` | `down` | `unknown`) последней строки `{done:true, network}`; UI может
показать «нет сети» вместо «все мертвы» (UI позже). Тестер запускается лениво: если всё
отдаётся из пула по `maxAgeMs`, sing-box не стартует.

Упавшие запросы (`onClosed`): демон подписан на поток закрытых соединений API service
(ниже); соединение через текущий маршрут без единого байта ответа → проверка сразу (одна на
`failWindow` 10 с). Нода живая → сайты таких запросов проверяются `reach` (`probeReach`: TLS на
443, HEAD на 80) через неё и через другие отвечающие маршруты по порядку Auto (до первого,
где открылся; число — `AutoSettings.siteAlternates` из `plan.auto.siteRetry`: 0 / 3 / все) →
событие `blocked` (`AutoBlocked {route, server, dest, via, viaServer}`); не открылся нигде или
другого маршрута нет → `unreachable` (`AutoUnreachable {route, server, dest, tried, retriesOff}`);
оба — пара маршрут + сайт раз в час. Ответ `reach` «не знаю» (null) не считается пробой;
`probeReach` отвечает null и когда проба не состоялась (`ProbeRefused`: probe inbound не принял
имя пользователя — у групп его нет; inbound не отвечает), false — только если запрос прошёл через
тег и не удался. Тег группы маршрута (urltest до первого раунда не называет сервер) `AutoService`
сводит к серверу в работе (`_serverTag`), неизвестен — сайт пропускается. `onLog`: строка
sing-box `missing default interface` → `offline` (раунды ничего не меряют, как `noNet`),
`updated default interface` → снова в сети, проверка сразу.

Настройки — `plan.auto` (URL — `urlTest.url`), `checkEvery` 10–3600 с. Тесты: `auto_test.dart`
(фейковый `BoxControl`), `auto_singbox_test.dart` (настоящий sing-box
на loopback: переключение без перезапуска, цепочка, urltest, падение процесса). Системный
прокси в тестах — фейк (`Daemon(sysProxy: …)`): реестр тесты не трогают. Перезапуск, down и kill switch — `killswitch_test.dart`: фейковые sing-box (`process:`), часы и паузы (`now:`, `timer:`), ничего не ждётся.

**API service sing-box** (1.14+, gRPC, `sbapi.dart`) — единственная связь ядра с sing-box
(Clash API убран, шаг 3.8). `SingBoxProcess.start(config)` добавляет `services: [{type: api}]`
на свободном порту loopback со случайным секретом на каждый запуск (все вызовы — с
`authorization: Bearer`; чужая программа туннель не переключит) и ждёт `ServiceStatus`:
STARTED — поднялся, FATAL — ошибка с причиной от sing-box. Потом `api.watch()` держит
открытыми (переоткрывает после ошибки) три потока:
- соединения (раз в 1 с): таблица открытых (сервер — конечный outbound, цепочка, приложение,
  байты и скорость за секунду) и события закрытия (→ Auto `onClosed`);
- группы: что выбрано в каждом selector / urltest и результаты urltest (→ Auto, трафик);
- статус (раз в 1 с): скорость, итоги сессии (с уже закрытыми соединениями), память.
Команды: `SelectOutbound`, `URLTest`, `CloseConnection` / `CloseAllConnections`,
`SetClashMode` / `GetClashModeStatus` (режим clash работает и без блока `clash_api` в
конфиге — проверено на 1.14.2; на нём держится переключение DNS, см. «Правила в конфиге»),
`GetDeprecatedWarnings` (после старта — в лог как `warn`: что сломается в конфиге с
новым sing-box), `StartNetworkQualityTest` (Speed Test). Тестер пинга каталога запускается
так же (готовность — по статусу сервиса).
Код сообщений сгенерирован официальным `protoc` из `daemon/started_service.proto` релиза
sing-box, лежащего в `tool/bin` (`tool/proto/`, `tool/gen_sbapi.sh`; protoc — в
`tool/bin/protoc`, не в git, плюс `dart pub global activate protoc_plugin`). Обновили
sing-box — перегенерировать.

Падение sing-box (процесс вышел сам, не наш stop): ядро **не трогает системный прокси** и в
фоне, незаметно для пользователя, перезапускает sing-box с тем же планом на маршруте, где был
Auto — паузы 1 / 4 / 15 с, потом каждые 30 с, без предела, пока пользователь не отключился
(счёт попыток сбрасывается после минуты работы; после долгого простоя быстрый повторный сбой
идёт сразу с 30-секундной паузы). Перезапуск идёт тем же путём, что connect (`_startSingBox`:
списки правил, новый `tunnel-in`, предупреждения сборки; потом фоновое обновление списков).
Пока перезапускает — `connected: true`, `recovering: {attempt, code, next}` (`next` — мс с эпохи,
когда следующая попытка; `attempt` — номер ожидаемой / идущей попытки); удалось — `restarts`
+1, `warning`, `recovering` и `down` = null, системный прокси снова включён, если он был снят
(при «down» или кнопкой пользователя; если стоял всё время — событие про него не пишется),
новый AutoService, событие `core/restarted`. Фоновая докачка списков, требующая
переподключения, тоже встаёт на маршрут, где был Auto.

**Down.** Перезапуск, не удавшийся за 30 с от падения (после третьей неудачной попытки), — «down»:
`status.down = {since (мс, когда объявлено), attempt, proxy}`, событие `core/down` (error,
`{proxy}`). Попытки идут дальше, `connected` остаётся true. `proxy` — что с системным прокси:
`kept` (стоит; программы, слушающие прокси, без интернета), `removed` (снят, трафик идёт
напрямую; также когда системного прокси не было), `released` (снял пользователь). Что делает
ядро в момент down (заданные в connect настройки, см. «Kill switch»):
- killSwitch включён → прокси остаётся (`kept`);
- killSwitch выключен, `downProxy: 'remove'` → прокси возвращается на прежний (`removed`),
  проверка выхода идёт напрямую;
- killSwitch выключен, `downProxy: 'keep'` → прокси остаётся (`kept`).

До 30-й секунды прокси остаётся при любых настройках.

Не пишется в журнал: `core/restartFailed` только за первые три попытки (сбой раз в 30 с
заполнил бы журнал; в сыром логе — каждая).

## Неудачные соединения (`failures.dart`, `tun_ingress.dart`)

> Общий шлюз «проверить, потом объявлять» (`sentinel/`, контекст сети и ядра, лестница вердиктов, корни и
> следствия, поля события `verdict` / `why` / `trail` / `cause`) — `docs/failures.md`. Эти детекторы сами
> событие не пишут: книга неудач и детектор TUN сообщают **подозрение**, шлюз проверяет и записывает событие
> с вердиктом (окна и проверки по видам — `docs/failures.md` → «Перенос детекторов»).

Тихий отказ 2026-10-10 (на Android-стеках TUN `mixed` / `system` Telegram не работал: приложение
исключало себя из VPN, sing-box писал `found package name`, а TCP до маршрутизации не доходил; ни
ошибки, ни закрытого соединения) показал, что «ничего не пришло» ядро должно замечать само и
говорить об этом, а не ждать, пока пользователь прочтёт сырой лог. Две части — по двум видам
отказа; обе читают тот единственный sing-box, что запущен, и работают, пока подключено (в том
числе когда API service нет — тестовый процесс — по сырому логу).

### Что говорит закрытое соединение (`ConnOutcome`)

Одно место, где решается «пришло ли что-нибудь». `ClosedConnection` кроме сервера, цепочки,
адреса и байтов несёт `network` (tcp/udp), `inbound` (тег входа), `durationMs` (сколько жило).

- `down > 0` — `ok`. `down == 0` — отказ (это и есть то, по чему Auto запускает проверку:
  `ConnOutcome.isFailure`, поведение Auto не менялось).
- Нет ответа, прожило < `instantMs` = 2 с — `instantRefusal` (отказ через цепочку занимает
  круги до дальнего конца: на мобильной сети секунда и больше, поэтому порог 2 с, а байты
  `up` тут не решают — sing-box для большинства таких пишет `up == 0`); ≥ 2 с и `up > 0` —
  `stalled` (запрос ушёл, ответа нет); `up == 0` — `timeout`.
- `up == 0`, `down == 0`, жило ≥ `idleMs` = 60 с — простаивавшее соединение пула, закрытое без
  единого байта: не успех и не отказ (`idle`, в книгу не идёт).
- Причина из лога перекрывает догадку по времени: строка
  `connection: open connection to H:P using outbound/…[tag]: <ошибка>` даёт `timeout` / `reset` /
  `refused` / `dnsFail` (`ConnOutcome.kindOfError`; `context canceled` / `canceled by local` — клиент
  сам отказался, не вина маршрута, вида нет). Подсказка живёт 20 с (`hintTtl`) и относится только
  к закрытому соединению того же тега outbound'а и того же адреса: закрытая запись приходит
  примерно секундой позже строки с ошибкой.

### Книга неудач (`FailureBook`, `CoreService.failuresSnapshot({top})`)

Скользящие счётчики по ключу (пакет Android | процесс, `host:port`, outbound / маршрут, inbound,
tcp/udp): за последние 10 минут (`window`, минутными корзинами) и с начала подключения. Ограничено:
не больше 400 записей (`maxEntries`, вытесняются самые старые), в снимке — `top` (по умолчанию
20) самых провальных; итоги (`ok` / `failed`) от вытеснения не зависят. Не считаются: игнорируемые
сайты (список «Игнорируемые сайты», `ignoredSites`), входы `probe-in` (наши же пробы), простаивающие соединения.
UDP и `tunnel-in` считаются, но события не дают. Фоновые (экран выключен, Android) считаются
отдельно (`bgFailed`, `bgSince`) и событие получает `bg: true`.

Снимок (`toJson`): `active`, `since`, `windowMs`, `ok`, `failed`, `ok10m`, `failed10m`, `bgFailed`,
`byKind`, `events`, `entries`, `apps[]` (пакет/процесс: `failed10m`, `ok10m`, `failedSince`,
`okSince`, `bgSince`, `destinations`), `top[]` (`app`/`process`, `host`, `port`, `outbound`,
`route`, `inbound`, `network`, `failed10m`, `ok10m`, `failedSince`, `okSince`, `bgSince`,
`byKind`, `lastKind`, `lastAt`, `lastDurationMs`, `failing` — есть, пока по адресу не было успеха
после сообщённой серии), `dns[]` (имена, что не разрешились: `host`, `count`, `lastAt`; до 50).

### Событие `conn/failing` (warn)

≥ `failAfter` = 3 отказов одного (приложение, адрес, outbound) в пределах `streakWindow` = 60 с
без успеха между ними — это **подозрение** (`FailureBook.report`), а не событие: шлюз ждёт, чтобы сбой
продлился `FailureWindows.connFailing` = 10 с, проверяет (тот же адрес снова открылся; открылся через
другой outbound; тот же сервер и другие маршруты пробой Auto), и только устойчивый сбой без внешней причины
пишется как `warn` с `verdict: confirmed`; иначе в журнале `info` с `blip` / `workaround` / `consequence`
(сети нет, ядро упало) или ничего (наш перезапуск, остановка ядра). Данные не изменились: `{app?, process?,
host, port, outbound, route, kind, count, windowMs, source: 'closed'}` — `app` = пакет Android, `process` =
`{name, path}` (как у `site/*`), `kind` — какой вид был у большинства серии, `windowMs` = 60000, `source`
показывает, откуда это взято (закрытые соединения; поле на вырост — другие источники); `trail` — протокол
проверок. Дальше:

- одно событие, пока успех не сбросит серию; после успеха по этому же адресу новые 3 отказа —
  новое событие (повторный отказ); подозрение, что не подтвердилось, не повторяется `recheckAfter` = 60 с;
- другие адреса того же приложения через тот же outbound в течение `groupWindow` = 5 мин не дают
  новых событий — событие обновляется полем `more` (сколько ещё адресов); другой outbound или
  приложение — отдельное событие;
- не более `maxEvents` = 6 в 10 минут (числа продолжают считаться);
- сайт, о котором Auto уже сказал (`site/blocked` / `site/unreachable`), `coveredFor` = 10 мин
  не получает `conn/failing` (и его поддомены): это то же самое событие, но с проверкой маршрутов.

Событие нужно не вместо `site/*`, а там, где Auto молчит: нода живая (замер проходит), а
конкретное приложение или порт не открывается.

### TCP из TUN не доходит (`TunIngressDetector`, `tunIngressSnapshot()`)

Отказ 2026-10-10 в книгу не попадает: запросы так и не становились соединениями. Сигнал в логе —
**осиротевшие** `router: found package name` / `found process path`: поиск приложения идёт до
того, как соединение создано, и у здорового стека рядом (в пределах `pairLines` = 5 строк, до или
после, у TCP два поиска на соединение, `tcpCapacity` = 2; у UDP и DNS `otherCapacity` = 1)
есть настоящая строка входа `inbound connection` / `inbound packet connection` / `inbound DNS
packet`. На мёртвом TCP строк входа нет вовсе — поиски остаются без пары.

Детектор читает сырой поток строк runner'а (не вкладку Logs: её кольцо вытесняет строки соединений
первыми) и говорит:

- `core/tunTcpDead` (error): за `window` = 30 с набралось ≥ `minUnpaired` = 8 осиротевших поисков, и
  ни одного настоящего TCP-соединения TUN за это же окно; `grace` = 5 с после старта не судит.
  Детектор это **подозрение** (`tun.tcpDead`); событие пишет шлюз: если сбой держится
  `FailureWindows.tunTcpDead` = 10 с от первого необработанного поиска — `confirmed` (и корень), если TCP вернулся
  раньше — `blip` (`info`). Данные: `{stack, synSeen, accepted: 0, windowMs, apps, appCounts, firstSeen,
  ownRejects?, ownRejected, udp, dns}` (`apps` — до `maxApps` = 5 приложений с наибольшим числом
  осиротевших, `appCounts` — сколько у каждого). Одно на период «мёртв».
- Отказ нашим `reject`-правилом (IPv6 выключен в плане, правило блокировки) выглядит так же, как мёртвый
  стек. sing-box 1.14.2 пишет `router: pre-match[N] … => reject` только на уровне debug; на `info` конфига
  такой отказ неотличим от мёртвого стека. Что учтено: строка отказа с тем же id, если она есть, снимает
  поиск со счёта; окно, набранное только своими отказами, уходит в шлюз с `ownReject: true` и отпускается без
  записи (`dead` не ставится). Активная проверка «открыть тестовое TCP через TUN» — пока TODO
  (`docs/failures.md`).
- `core/tunTcpBack` (info): первое настоящее TCP-соединение после «мёртв»; пишется, только если событие
  `tunTcpDead` было подтверждено. Данные: `{stack, accepted, deadMs}`; потом возможен новый `Dead`.

Пороги — по трём записанным сессиям (`core/test/fixtures/tun_ingress`): здоровый gVisor остаётся
на ≤ 4 непарных за любое окно 10–60 с без TCP (несколько поисков без пары бывают и в норме, поэтому
счёт по окну, а не «любой одиночный»); мёртвые `system` и `mixed` набирают 8 за 2–3 с и 10 за 4 с.
Пороги именованные константы; тесты — повтор записанных логов (`tun_ingress_test.dart`).

Снимок: `state` (`off` | `ok` | `dead`), `stack`, `sinceMs`, `windowMs`, `tcpInWindow`,
`unpairedInWindow`, счётчики `tcp` / `udp` / `dns`, `lookedAt`, `unpaired`, `deadEvents`,
`deadForMs?`, `apps?`, `thresholds`.

Ограничения: пороги выведены из сессий Android; TUN рабочего стола (Windows) этим детектором не
проверялся (там нет аналога исключения приложения, но строки те же). В экспорте Logs на телефоне
кольцо шума держит только 500 новейших строк соединений — старые `inbound connection` в нём
вытеснены, и повтор сырого экспорта целиком даёт ложное «мёртв»; фикстуры вырезаны из частей, где
строки входа ещё есть.

## Kill switch

Только системный прокси (в TUN — лишь `strict_route`, отдельного kill switch для него нет). Настройки приходят **верхнеуровневыми полями** тела
`POST /api/connect` (не в `plan`); отсутствующее поле остаётся как было (демон при старте —
всё выключено). Менять на ходу, без переподключения — `POST /api/killswitch` (те же поля).

| поле | по умолчанию | смысл |
|---|---|---|
| `killSwitch` | false | системный прокси не снимается, пока VPN должен быть включён (см. Down выше) |
| `killOnDisconnect` | false | нужен `killSwitch`; отключение пользователем оставляет прокси → интернет закрыт до connect / Remove |
| `killWhileClosed` | false | нужен `killSwitch`; остановка jormd не возвращает прокси. Решение «только при автозапуске + connectOnLaunch» принимает UI: ядро верит булеву |
| `downProxy` | `'remove'` | `'remove'` \| `'keep'`; только при выключенном `killSwitch`: что делать с прокси при down |

- **Отключение пользователем** (`POST /api/disconnect`): `killSwitch && killOnDisconnect` и прокси
  стоит → он остаётся, `status.blocking = {since (мс), reason: 'disconnect', proxy: 'kept'}`;
  событие «прокси снят» не пишется. Иначе прокси возвращается, как раньше. Повторный disconnect
  блок не меняет. Отключение во время перезапуска / down останавливает попытки, прокси — по тому
  же правилу.
- **Остановка jormd** (`shutdown`): `killSwitch && killWhileClosed` и прокси стоит → не
  возвращается; в `<dataDir>/kill.json` пишется `{keepWhileClosed: true, since}` (пишется и при
  connect / смене настроек, если оба поля включены; удаляется, если выключены). Иначе
  прокси возвращается, событие `core/sysProxy {on:false}` (`own: false`) пишется, как для любого
  снятия прокси.
- **Старт jormd**: `kill.json` с `keepWhileClosed` и прокси стоит → он не трогается,
  `status.blocking = {since (из файла), reason: 'closed', proxy: 'kept'}`. Прокси стоит без
  такого файла (след падения ядра) → возвращается, как раньше.
- **connect** сбрасывает `blocking`. Если connect не удался при действующем блоке
  (killSwitch включён, прокси стоит) — блок остаётся как был, а не снимается.
- **Remove / Disable sys proxy** — `POST /api/sysproxy/release`: возвращает сохранённый системный
  прокси сейчас; во время перезапуска / down — `down.proxy = 'released'` (попытки идут), при
  блоке — `blocking.proxy = 'released'` (запись остаётся до connect). Событие `core/sysProxy
  {on: false, by: 'user'}`, `own: true`. Вне перезапуска / блока ничего не делает. Восстановление
  соединения после release снова ставит прокси.
- **Смена настроек на ходу** (`POST /api/killswitch`) — для следующего решения про down /
  disconnect / shutdown; уже случившееся пересматривается сразу: при down прокси ставится
  (killSwitch включили или `downProxy: 'keep'`) или снимается (оба выключены, `remove`), кроме
  снятого пользователем (`released` остаётся); при блоке прокси возвращается, если
  настройка, на которой он держался (`killOnDisconnect` для `disconnect`, `killWhileClosed`
  для `closed`, оба — с `killSwitch`), выключена; `blocking` тогда null. События `core/sysProxy`
  при этом `own: true`.
- **Retry** — `POST /api/retry`: попытка перезапуска сейчас, не дожидаясь паузы (следующая пауза
  считается заново, 30 с до down не сбрасывается). Не перезапускается — ничего не делает.
  Все три POST принимают пустое тело.

## Входы sing-box

Все — mixed (HTTP + SOCKS5), только `127.0.0.1` (плюс `tun-in` в режиме TUN, см. «TUN»):

| тег | порт | пароль | зачем |
|---|---|---|---|
| `mixed-in` | `plan.mixedPort` (2080) | по `plan.mixedAuth` | пользовательский: его вписывают в программы вручную; идёт по правилам |
| `sys-in` | свой, см. ниже | никогда | системный прокси при пароле на `mixed-in`; идёт по правилам, как `mixed-in` |
| `tunnel-in` | свободный, новый на каждый запуск | никогда | сам процесс ядра: проверка выхода, подписки «via proxy», списки «через VPN»; всегда в `proxy` мимо правил |
| `probe-in` | свободный | случайный, на запуск | замер пинга (`probe.dart`) |
| `svc-in` | свободный | случайный, на запуск | служебный трафик ядра по путям на выбор (`svc_in.dart`, «Служебный трафик») |

- **Пароль на `mixed-in`.** `plan.mixedAuth = {user, pass}` → `users: [{username, password}]` у
  `mixed-in` (SOCKS5 user/pass и HTTP Basic `Proxy-Authorization`; без логина — отказ SOCKS5 /
  `407`). Нет поля — порт открыт, как раньше (как и у Karing). Пустой логин / пароль или `:` в
  логине — `ArgumentError` (`mixedAuthUser`, connect не удаётся): лучше ошибка, чем порт, который
  выглядит защищённым и не защищён. Пароль в плане — часть плана: смена при подключении =
  переподключение, как у порта (UI сравнивает план целиком). Логин и пароль хранятся в снимке UI
  (`connCfg`), значит бэкапы их содержат.
- **`sys-in`.** Системный прокси Windows не умеет отдавать пароль, поэтому при
  `plan.mixedAuth` **и** `systemProxy: true` в конфиг добавляется `sys-in` без пароля, и
  `SystemProxy.enable` ставит его порт (в том числе прокси, который держит kill switch, и после
  перезапуска sing-box). Без пароля `sys-in` нет, системный прокси указывает на `mixedPort`.
  Порт выбирается один раз и хранится в `<dataDir>/sys-in.json` `{port}`: удерживаемый прокси
  должен попадать в него и после падения sing-box, и после нового запуска jormd. Переиспользуется,
  пока свободен (или занят нашим же работающим sing-box — переподключение), иначе выбирается
  новый и перезаписывается. Порты `mixed-in` / `tunnel-in` / `probe-in` / `svc-in` / `sys-in` не совпадают.
  `status.sysPort` — порт `sys-in` (`null` — его нет).
- **Что ядро делает через порты сам** — только через `tunnel-in` (`_innerPort` = `tunnel-in`):
  проверка выхода (`exitCheck`), подписки с каналом Proxy (`updater` / `_fetch`), списки правил.
  Пользовательский порт ядро не трогает, поэтому пароль на нём ничего не ломает. Инструмент
  `tool/exit_check.dart [порт] [логин:пароль]` — для порта с паролем.
- **Android.** В TUN пользовательский порт по умолчанию не открывается (приложения идут через
  VPN-интерфейс); порт, пароль и `sys-in` нужны только в режиме прокси.
- Тесты: `proxy_auth_singbox_test.dart` (настоящий sing-box на loopback: без логина и с неверным
  — отказ, верный — работает по SOCKS5 и HTTP; `sys-in` и `tunnel-in` открыты; без пароля порт
  открыт), `killswitch_test.dart` → «password on the user port» (порт `sys-in` в конфиге,
  в реестр, в status; тот же после падения, переподключения и нового jormd; занятый заменяется).

## Служебный трафик (`svc_in.dart`, `svc_fetch.dart`)

Запросы самого ядра (подписки, списки правил, обновление приложения, отчёт) идут общим сборщиком
`ServiceFetch` (`CoreService.svcFetch`): один запрос гонится по нескольким путям сразу. Вызывающий
код переносится на него по одному; пока он ничем не занят.

**Вход `svc-in`.** `mixed`, `127.0.0.1`, свободный порт на каждый запуск, пароль случайный на запуск.
Пользователи `u0..uN` (логин непрозрачный: в тегах есть `:` `/` `[`, они ломают разбор прокси в Dart),
правила `auth_user` стоят первыми в `route.rules` (как у `probe-in`) и ведут пользователя в свой outbound:
`direct`; главный селектор `proxy` (`main`: куда сейчас смотрит Auto); каждая группа маршрута `route<i>`.
Идентификатор пути (`direct` / `main` / `route<i>`) стабилен, пока в плане те же маршруты. Таблица
логин → путь строится вместе с конфигом (`buildConfig(svc: SvcIn(port))` заполняет `svc.paths`) и вместе
с портом и секретом лежит в записи `AdoptableRunner.keep` (`svc`), так что принятый sing-box работает;
запись старого ядра без `svc` — путей нет (только прямой сокет), до следующего запуска. HTTP-прокси
(абсолютный URI и `CONNECT`) выбирает outbound по логину так же, как SOCKS (проверено настоящим sing-box).
`FailureBook` соединения `svc-in` не считает: провал на всех путях сообщает сам сборщик.
`CoreService.svcInbound` / `svcPaths` — текущие порт, секрет и пути; пусто, пока sing-box не запущен.

**`ServiceFetch.get(uri, {purpose, policy, prefer, range, maxBytes, headers, onData, cancel})`** →
`SvcResult` (`response` — ответ, `failure` — ни один путь не ответил):
- `SvcPolicy.race({kinds})` — все доступные пути сразу; `SvcPolicy.strict(id)` — один путь.
- Сам запрос и есть гонка, отдельной пробы нет. Каждый путь читает только первые ~64 КиБ (`sample`);
  первый, кто их прочитал, продолжает тем же ответом, остальные обрываются. Ничья (второй успел в
  `tieGrace` ~300 мс) — за туннелем (`SvcPrefer.tunnel`). `SvcPrefer.direct` (обновление приложения):
  прямой путь ждут до `preferGrace` (2 с) и берут, даже если туннель был быстрее.
- Хороший ответ — 2xx / 304. Остальные статусы — ответ сервера (`response.ok == false`), а не провал
  пути: хороший ответ другого пути их обгоняет; если хорошего нет, возвращается ответ (туннель впереди).
- Обрыв посреди скачивания (нет байтов 3 с — общее правило `stall_guard.dart`, как у отчёта — или
  разрыв) — докачка `Range` с места обрыва по следующему пути; `If-Range` по ETag / Last-Modified первой
  части, `200` на него — `changed` (файл другой, докачка невозможна). Упавшие в этом вызове пути
  не спрашиваются снова. Статус и заголовки ответа — первой части, `via` — того, кто закончил.
- Победитель помнится по хосту:порту + `prefer` + `netEpoch` + `coreEpoch`: следующий запрос идёт сначала
  только к нему; сбой, смена сети, переподключение (любая смена эпохи) — память стирается, гонка полная.
- Без работающего sing-box — один прямой сокет (`via == 'plain'`), `strict('main')` — `noPath`.
- Провал: `SvcFailure(code, host, paths[{id, kind, code, ms, detail}], received, advice)`. `code`:
  `allFailed`, `noPath`, `tooBig` (больше `maxBytes`), `cancelled`. Коды путей: `timeout`, `stall`,
  `connect`, `refused`, `reset`, `dns`, `tls`, `tunnel` (прокси не открыл путь дальше), `auth`, `closed`,
  `range`, `changed`, `http`, `error`. `failure.suspicion()` (только для `allFailed`) → `Suspicion`
  `svc.fetch`, субъект `{host, purpose}`, улика — пути; вызывающий отдаёт её шлюзу `sentinel.suspect`
  (своё `event`, `checks`, `window`). `failure.advice` — совет `RetryPolicy` (`retryFor(purpose)`: счёт на
  назначение; сбой при нашем перезапуске — после устоявшегося ядра, нет сети — ждать её, иначе 1 → 2 → 5
  → 15 мин); ждать: `await svcFetch.waitRetry(failure)`. Удача сбрасывает счёт назначения.
- Тесты: `svc_fetch_test.dart` (петля: поддельный `svc-in` и настоящий sing-box).

## TUN (`config.dart`, `elevation.dart`)

`plan.mode == 'tun'` добавляет к входам `tun-in` (остальные входы те же). Только desktop-вариант:
sing-box сам создаёт интерфейс (wintun встроен в бинарник). Поля:

| поле | значение |
|---|---|
| `address` | `172.19.0.1/30`, `fdfe:dcba:9876::1/126` (dual stack всегда, при любом `plan.ipv6`) |
| `mtu` | 9000 |
| `auto_route`, `strict_route` | true, true |
| `stack` | `plan.tunStack`: `mixed` (по умолчанию) / `system` / `gvisor`; неизвестное = `mixed` |
| `route_exclude_address` | локальные сети мимо туннеля: `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `224/4`, `255.255.255.255/32`, `fc00::/7`, `fe80::/10`, `ff00::/8` (`tunBypass`) |

**IPv6** (`plan.ipv6`, Settings → Connection → IPv6; по умолчанию **выкл.**, нет в плане = выкл.).
Телефон / сеть часто без глобального IPv6, а выходы прокси его не несут: приложение получает AAAA,
идёт на IPv6-адрес через туннель и зависает. Выкл. — две меры. (1) В `dns` стоит
`strategy: ipv4_only` (поле верхнего уровня `dns.strategy`, не устаревшее `strategy` DNS-правила
1.14): sing-box отвечает на AAAA пустым ответом и режет IPv6-подсказки HTTPS-записей, а имена
(серверы прокси, DoH-хосты, `resolve`) разрешает только в IPv4; это действует и в режиме
прокси (клиенты порта тоже не получают AAAA). (2) Только в TUN: системное правило
`{inbound: tun-in, ip_version: 6, action: reject, no_drop: true}` (`ipv6OffRule`) — любое IPv6-соединение,
вошедшее в туннель (например, на IPv6-литерал, без DNS), сразу получает отказ (TCP RST / ICMP
unreachable, метод `default`), и приложение уходит на IPv4, а не зависает; `no_drop` — чтобы при
шквале попыток sing-box не переключился на тихий drop (50 срабатываний за 30 с). Правило стоит
**после** `sniff` и DNS hijack (DNS к IPv6-резолверу туннеля всё равно отвечается) и до остальных.
Сам TUN **остаётся dual stack** (адрес, `::/0`, исключения): без IPv6-маршрута IPv6-литералы
уходили бы мимо VPN на сети с IPv6 — утечка. Android: `VpnService` берёт адреса и маршруты из
конфига `tun` (libbox `TunOptions`), IPv6-маршрут есть, отказ даёт sing-box. Вкл.: как раньше,
dual stack, без `strategy` и без reject. Смена — часть подписи плана (переподключение) в обоих
режимах. Тесты: `tun_test.dart` (в т. ч. настоящий `sing-box check`), `catalog_model_test.dart`.

Синтаксис 1.14 (`address`, правила-действия): sniff — правило `route` (`{action: sniff}` для всех
входов), не поле входа; `route.auto_detect_interface: true` — свои исходящие sing-box привязаны к
реальному интерфейсу и в туннель не попадают. Подсеть `172.19.0.0/30` лежит внутри исключённого
`172.16.0.0/12`: интерфейсный маршрут /30 точнее, адрес DNS туннеля остаётся внутри.

**Правила пользователя в TUN** работают при Rules так же, как через порт: порядок и состав те же
(`rules.md` §1: приложения → свои → быстрые → final), включая приложения Direct / Block / Proxy
(+ «If unavailable»), исключения, сервисы. Приходят настоящие IP: IP-условия срабатывают без
`resolve` (для `tun-in` его нет; для `mixed-in` / `sys-in` он остаётся), правила «IP conditions only in TUN» работают полностью. При Global всё
из TUN уходит в `proxy`, правил пользователя нет (остаются системные и `Private networks`).

**Системные правила** (идут раньше правил пользователя, в обоих режимах, названы `RuleOrigin
'system'` в `RoutingInfo.ruleNames`):
1. `probe-in` (замеры) — как раньше, первыми; `sniff`.
2. TUN: `DNS hijack` (`dns-hijack`): запросы к резолверу туннеля — здесь, остальные перехваты —
   после п. 4 (см. «DNS» ниже). Затем, при IPv6 выкл., `reject` для IPv6 из `tun-in` (без имени в
   `ruleNames`; см. «IPv6» выше; стоит после всех перехватов и самоправил).
3. `tunnel-in` → `proxy` (`Core checks`, `tunnel`) — как раньше.
4. Свои соединения приложения → `direct` (`Core and speed tests`, `core`; `selfRules`). Приложение
   **внутри** VPN на всех платформах (Android себя из VPN больше не исключает): его соединение входит
   в TUN как соединение любого приложения и без этого правила зациклилось бы в прокси, который само
   проверяет. Чем оно матчится — по платформе:
   - ПК: `process_path` (Windows — `process_path_regex` `(?i)^…$`, без учёта регистра пути) из
     `selfProcessPaths(singBox)`: сам процесс ядра (`Platform.resolvedExecutable`: для jormd — dart VM,
     потом exe Flutter) и бинарник sing-box (замеры и Speed Test — отдельные процессы sing-box).
   - Android: `{package_name: [<пакет приложения>], action: route, outbound: direct}`
     (`selfPackageNames`). Пакет приходит в ядро параметром `CoreService(ownPackage:)`; не задан — ядро
     читает имя своего процесса из `/proc/self/cmdline` (главный процесс приложения называется как
     пакет, `pkg:service` → `pkg`), не распознал — правила нет и в журнале предупреждение. `selfProcessPaths`
     на Android пуст: `resolvedExecutable` там — общий для всех приложений zygote `app_process64`, `process_path`
     по нему сматчил бы чужие приложения. Совпадение — по владельцу соединения
     (`getConnectionOwnerUid`, Android 10+; тот же механизм, что у правил приложений, `rules.md` §3).
     Боксы пинга / Speed Test на Android в TUN не входят вовсе: их сокеты защищает `VpnService`
     (`platforms.md` → «Работа вне туннеля»).
   Правило стоит после `tunnel-in` (то, что ядро шлёт через `tunnel-in`, по-прежнему идёт в туннель),
   перед `Private networks` и правилами пользователя; есть и в Global. Список всего, что должно работать
   мимо туннеля, и тест, не дающий про него забыть, — `core/lib/src/outside_tunnel.dart`.
5. TUN: остальные `hijack-dns` (порт 53, протокол `dns`; при Hijack DNS вкл.), затем п. 2 про IPv6.
6. `Private networks` (`private`) — и так первое в `routing.rules`.
Правила есть и в режиме прокси (там они ничего не ловят: ядро ходит через `tunnel-in`).

**DNS.** `plan.routing.dns.hijack` (по умолчанию включено, UI шлёт `dnsCfg.hijack`): включён —
`{inbound: tun-in, port: 53} → hijack-dns` и `{inbound: tun-in, protocol: dns} → hijack-dns`: любой
DNS-запрос из TUN, даже к зашитому 8.8.8.8, отвечает DNS ядра (серверы, правила и `final` из
«Правила в конфиге»). Выключен — запросы идут как обычный трафик по правилам, **кроме** запросов
к собственному резолверу туннеля (`172.19.0.2`, `fdfe:dcba:9876::2`, порт 53; на Windows системный
DNS интерфейса TUN смотрит именно туда, а ответить там некому, кроме ядра): они отвечаются всегда
(`{inbound: tun-in, ip_cidr: [...], port: 53} → hijack-dns`). FakeIP убран до переработки (`rules.md` §DNS).

*Порядок перехватов.* Правило резолвера туннеля стоит **до** самоправил, остальные перехваты — **после**:
собственный системный резолвер приложения (getaddrinfo → резолвер туннеля) отвечает ядро, а его
прямые запросы на порт 53 (пинг DNS-серверов в Settings → DNS, `dns_probe.dart`) уходят мимо перехвата
к тому серверу, который проверяют; иначе пинг показывал бы ответ DNS ядра.

*Свой DNS приложения не зависит от прокси.* Системный резолвер приложения — запрос в TUN → перехват →
DNS ядра, у которого правила и `final` могут вести через прокси (сервер «via VPN»). Обновление подписки
при всех умерших узлах упёрлось бы в собственный DNS. Поэтому в `dns.rules` первым стоит правило из
самоправила (`selfDnsRules`: те же `package_name` / `process_path`, `inbound: tun-in`, `action: route`,
`server: <default_domain_resolver>`): запросы процессов приложения из TUN отвечает **прямой** сервер —
первый отмеченный не-VPN сервер списка DNS, иначе системный (тот же, что резолвит адреса серверов
прокси). Правило есть и в Global; в режиме прокси его нет (`inbound` — только TUN, запросы через порты
не «свои»). Проверено: `sing-box check` (`package_name` и `process_path_regex` в DNS-правиле) и живой
sing-box на loopback — `outside_tunnel_dns_test.dart` (DNS-правило по пути процесса срабатывает на
перехваченном запросе, процесс — тот, что спрашивает; не наш процесс и другой вход — отвечает `final`).
На Android совпадение по пакету идёт тем же путём (владелец соединения), на устройстве проверяется
вручную. Кэш DNS sing-box общий для всех серверов (`independent_cache` выкл.): ответ прямого сервера
на имя может отдаться и приложению, спросившему то же имя позже, — как и у DNS-правил по доменам.

**Права администратора.** TUN поднимается только из процесса с правами (`processIsElevated`:
Windows — `TokenIsElevated` токена, иначе `id -u` = 0; проверку можно подменить —
`Daemon(isElevated:)`). Проверка идёт в `_startSingBox`, до скачивания списков и запуска, при
connect и при перезапуске после падения. Нет прав → sing-box не стартует, connect отдаёт 500 с
текстом `TUN needs administrator rights: run the app as administrator, or switch to Proxy mode`
(`status.error`), прежний sing-box (connect при смене режима) останавливается — неудавшийся connect =
не подключено, и пишется событие `core/tunNeedsAdmin` (error, `{stage: 'check'}`) вместо
`conn/connectFailed`. Отказ самого sing-box по правам (`Access is denied`, `not permitted`,
`privilege`… в тексте старта TUN) — то же событие и тот же текст, `{stage: 'start', error: <слова
sing-box>}`; прочие сбои старта остаются `conn/connectFailed`. Перезапуск с правами — дело
приложения (jormd сам не поднимает UAC).

`status.mode`: `'tun'` | `'proxy'` у подключённого, `null` без подключения (также `conn/connected.mode`).

**Android** (libbox): TUN-дескриптор даёт `VpnService` по `TunOptions` из конфига `tun-in` (адреса и
маршруты берутся из него как есть); приложение **само внутри** VPN: его соединения ловит правило
`package_name` → `direct` (п. 4 «Системных правил»), DNS — прямой сервер (см. «DNS»), сокеты разовых
libbox-инстансов защищает `VpnService.protect` (`platforms.md` → «Работа вне туннеля»); `package_name`
вместо `process_name` / `process_path`; пользовательский порт по умолчанию не открывается. Стеки `system` /
`mixed` требуют именно этого: слушатель стека `system` живёт в процессе приложения, и у исключённого из
VPN приложения его ответы шли мимо TUN — TCP не доходил до маршрутизации.

**Проверка без сети**: `test/tun_test.dart` — конфиг (поля, диапазоны, стек, порядок и состав правил,
Global, hijack вкл / выкл, системные правила первыми), `sing-box check` на конфигах всех стеков (check
интерфейс не создаёт и права не требует), демон без прав. Живой TUN тесты не поднимают.

## Правила в конфиге

`routing` (`js/93-routing-plan.js` → `core/lib/src/routing.dart`; логика — `rules.md`):

```
{ apps:  [{ id, kind: 'package'|'process'|'path', name, act: 'default'|'proxy'|'direct'|'block', target,
            fallback, split, udp: { act, target, fallback } }],   // split: act… = TCP, udp = UDP
            // fallback: 'default'|'main'|'block'|'direct'|<target id> (a key of `targets`); a rule's
            // and an app's. On act 'default' / 'proxy' with no target an explicit block / direct /
            // target id is the main flow's own "If unavailable" (selector `proxy~…`, rules.md §0)
  rules: [{ id, name, action, target, fallback, block, dns, groups, composite?, extra?,
            ipTunOnly? }],                          // ipTunOnly: его IP-условия не требуют resolve
  quick: { ads, region: 'RU'|…|null, services: { telegram: 'vpn'|'direct', … }, final },
  fallback: 'main'|'block'|'direct',            // Rules → Target unavailable
  targets: { '<цель>': { kind: 'unit'|'chain', main: Group, entry?: Group } | null },
  ruleSets: [{ name, url, format, via, every }],
  geo: { geosite: { via, every }, geoip: { via, every } },
  dns: { servers: [{ id, addr, via, on }],
         resolve?: 'auto'|'off'|'<id сервера>',   // «Resolve for IP rules» (только порты, в TUN тоже), по умолчанию 'auto'
         hijack?: bool } }                         // Hijack DNS (только TUN), по умолчанию true
```

- UI шлёт свою модель: группы условий формы, `composite` (составное правило из JSON, без
  action), цели. Каталог живёт в UI, поэтому каждую названную цель UI сам разворачивает в
  группы (как `main`), `null` — цель недоступна (тогда её «If unavailable»). Всё остальное —
  AND/OR, CIDR, порты, DNS-серверы, списки — строит ядро.
- Порядок route: `sniff` → (TUN: hijack-dns резолвера туннеля) → `tunnel-in` → свои соединения
  приложения напрямую → (TUN: прочие hijack-dns, IPv6 off; «TUN») →
  `Private networks` → приложения → свои правила (перед первым с IP-условиями
  и без `ipTunOnly` — `resolve`; в TUN только для `mixed-in` / `sys-in`) → быстрые → `final`. Группы целей — теги целей
  (`src:…`, `chain:…` + `chain:…>entry`).
- **`resolve` перед IP-правилами** (`routing.dart` `_resolveAction`, `rules.md` §4). Через
  proxy-порт приложение шлёт домен, IP-условия его не видят — поэтому один `resolve` ставится
  перед первым своим правилом с IP-условиями (`ip_cidr`, `ip_is_private`, `geoip-*`, в том числе
  внутри `composite`), у которого нет `ipTunOnly`. `dns.resolve`: `off` — шага нет; `auto`
  (по умолчанию; так же — id удалённого или снятого с галочки сервера) — `{action: resolve,
  server: dns-<первый отмеченный «через VPN»>}`; id — `server: dns-<id>` (любой отмеченный,
  и прямой — выбор пользователя). Сервер названа явно, поэтому переключение DNS (clash_mode)
  и свои DNS-серверы правил на этот шаг не влияют; если выбранный молчит — домены под IP-правила
  не соединяются. Нет отмеченного сервера «через VPN» в `auto` → `resolve` без `server` (решают
  DNS-правила и `dns.final`) и предупреждение о возможной утечке. Один `resolve` на конфиг:
  правило с `ipTunOnly` ниже него всё равно видит уже полученный адрес. Собственные rule-sets
  IP-условием не считаются (по .srs не видно, что внутри). Быстрые правила не резолвят. В TUN
  (`plan.mode: 'tun'`) шаг ограничен входами порта: `{inbound: [mixed-in, sys-in], action: resolve, …}`.
  Трафик `tun-in` идёт без шага (адрес приходит как есть, правила с `ipTunOnly` работают как
  обычные), а соединение на открытый в TUN `mixed-in` / `sys-in` доменом получает IP-условия,
  как в режиме прокси (и предупреждение про DNS «через VPN» от этого шага то же, что в прокси).
- `tunnel-in` — второй mixed-вход на свободном порту loopback, всегда в `proxy` мимо правил:
  через него проверка выходного IP (российский сервис проверки иначе ушёл бы напрямую по
  правилу региона) и списки «через VPN».
- Списки: `RuleSetCache` (`rulesets.dart`) перед стартом кладёт нужные на диск
  (`<dataDir>/rulesets`), в конфиг — `type: local`. После подключения в фоне: устаревшие
  обновляет, недостающие качает через туннель — и тогда переподключает.
- Предупреждения сборки (правило без списка, пропущенное правило) приходят в `warning`
  ответа на connect (тост в UI).
- `cache_file` включён; `cache_id` = хэш выбранных `default` у selector-ов: выбор через
  API переживает перезапуск, новый выбор из UI — нет.
- Сравнение планов для переподключения нормализует и цели правил (порядок Fastest после
  пинга — не изменение).
- **«If unavailable» на лету** (`fallback.dart`, `FallbackService`). Правило / приложение с
  доступной целью (не Main flow) ведёт в selector `<цель>~<запасной>` = `[цель, запасной]`,
  `default` — цель, `interrupt_exist_connections: false`; запасной — `block` (outbound
  `block` добавляется в конфиг, только если нужен selector; sing-box 1.14.2 принимает его
  внутри selector'а, deprecated не ругается — проверено настоящим sing-box), `direct`
  (или `direct@dns-<id>`, если у правила свой DNS) или `proxy` (Main flow). `buildConfig`
  отдаёт список таких selector'ов в `info: RoutingInfo` (`fallbacks`: тег, цель, группы,
  запасной, имена правил для журнала). Сервис — раз в `checkEvery` (Auto-настройки, тот же
  probe inbound и `withCheckers`, второго пингера нет) мерит сервер, на котором стоит группа
  цели (цепочка — выход через вход); молчит `failAfter` раундов подряд → `SelectOutbound`
  на запасной, тем же путём назад после `failAfter` ответов и паузы flap guard
  (`Watched`, общий с DNS). Fastest-группа при промахе сначала перетестируется
  (`URLTest` + повтор), Priority не двигается. Замеры — через пул (`pool.dart`, ключ — сервер
  и тест; свежий ответ Auto или пинга UI берётся вместо нового теста). Не судит, пока статус
  сети пула не `up` (нет сети / у текущего маршрута Auto промахи). Уход на запасной выход закрывает зависшие
  соединения через цель (`StallSweeper`, общий с Auto: байты стоят `stallAfter`). Выбор в
  начале раунда читается из `api.selected` (после рестарта `cache_file` мог оставить
  запасной). Группы целей по-прежнему не ведёт AutoService.
  Запасной выход — цель каталога: selector `<цель>~<запасная цель>` = `[цель, запасная цель,
  proxy]` (`TargetFallback.fallbackTarget` / `fallbackSpec`), запасная цель наблюдается тем
  же кодом; оба упали → `proxy` (`to: main`), решения принимаются за раунд целиком (`_decide`
  выставляет флаги всех целей, потом `_flip` двигает selector'ы один раз). Основной поток
  как цель: `proxy~<запасной>` = `[proxy, запасной]`, цель в сервисе — `_Target.mainFlow`: тест
  через лист `proxy` → маршрут → сервер (ключ пула листа даёт `AutoService.identityOf`);
  промах считается, только если ответил `direct` (он всегда в probe inbound) или запасная цель;
  судится при `up` и `unknown`, но не при `down` (статус пула: ОС без сети или прямой путь
  тоже молчит). Подробности — rules.md §0.
- **Переключение DNS** (`dns_failover.dart`, `DnsFailover`). При двух и более отмеченных
  серверах у каждого `dns-<id>` DNS-правило `clash_mode: "dns-<id>"` (после остальных
  DNS-правил, `routing.dart` `_dnsModes`); `dns.final` — первый отмеченный, стартовый режим
  `Rule` ему же и равен. Не судит, пока статус сети пула не `up`; ответы DNS статус не питают.
  Проверка сервера — `probeDns` (`probe.dart`): SOCKS-запрос в probe
  inbound с пользователем `dns-check/<тег>`; для него в конфиге правило `resolve` с явным
  `server` (`disable_cache`, `ipv4_only`) и следом `route` в `direct` с `override_address`
  на сам probe inbound, поэтому успех SOCKS-ответа = имя разрешилось именно этим сервером
  (по его же пути: `detour` сервера действует). Имена — `cp.cloudflare.com`, запасные
  `www.gstatic.com`, `captive.apple.com`. Раунд — `checkEvery`; сервер упал после
  `failAfter` промахов, вернулся после `failAfter` ответов и паузы flap guard; при падении
  используемого — `SetClashMode(dns-<самый приоритетный из отвечающих>)`, когда оживает
  более приоритетный — обратно. Настройка «Switch automatically» — поле `dnsAuto` тела
  connect (не в `plan`, чтобы её смена не давала переподключения) и `POST /api/dns/auto`
  `{auto}`; выключение возвращает первый сервер сразу (`reason: 'off'`), проверки и
  `status.dns` продолжаются. Ограничение: `default_domain_resolver` (адреса серверов прокси,
  прямой трафик) режим не меняет.

## API (`jormd`)

Только `127.0.0.1`; каждый `/api`-запрос с заголовком `X-Jorm: 1` (чужие страницы не
пройдут CORS preflight) и loopback-Host.

| | |
|---|---|
| `GET /` | мокап, с `window.JORMD = true` → live-режим (`95-live.js`) |
| `GET/PUT /api/state` | снимок состояния UI / статус |
| `POST /api/sources/fetch` | `{sid, source:{url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid, filter, channel}, rediscover}` → `{patch, title, notModified, via}`; `patch` — серверные поля источника (`nodes`, `gone`, `count`, `uaStrategy`, `discoveredAt`, `usage`, `expire`, `format`, `providerInterval`, `webPage`, `supportUrl`, `announce`, `updatedAt`), UI кладёт их в источник как есть. См. subscription-parsing.md |
| `POST /api/parse` | `{text}` → ноды из ссылок |
| `POST /api/sources/import` | `{name, text}` → `{source}`: локальный источник (`kind: 'file'`, без `id` — его выдаёт владелец каталога) из текста выбранного файла (Nodes → + → Import config file). `name` — имя файла, расширение (`.json` `.yaml` `.yml` `.txt` `.conf` `.list`) отбрасывается. Формат определяется по содержимому, как у подписки (sing-box JSON, Clash YAML, список ссылок, всё это и в base64); серверы дедуплицируются и именуются как у подписки. `source`: `{kind, name, enabled, inAuto, offNodes, disabledNodes, nodes, gone, count, format, updatedAt}`. Ничего не распознано или файл > 16 МБ — 400 `{error}` (`No servers found in the file`), ядро ничего не хранит: источник кладёт в каталог и сохраняет вызывающий (`PUT /api/state`). Источник не обновляется ни таймером, ни `fetchSource` (тот отвечает 400). См. connect-model.md → «Локальный источник» |
| `POST /api/connect` | `{plan, systemProxy, killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?, dnsAuto?}` — kill switch, см. «Kill switch»; `dnsAuto` — Settings → DNS → Switch automatically (по умолчанию true), см. «Правила в конфиге» |
| `POST /api/dns/auto` | `{auto: bool}` — Switch automatically на ходу, без переподключения (выкл — первый сервер сразу) → status |
| `POST /api/killswitch` | `{killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?}` — сменить на ходу, без переподключения → status |
| `POST /api/sysproxy/release` | вернуть системный прокси сейчас (Disable sys proxy при down / Remove при блоке) → status |
| `POST /api/retry` | перезапустить sing-box сейчас, не дожидаясь паузы → status |
| `POST /api/network` | `{connected?, validated?, captive?, type?, id?}` — что платформа знает о сети (Android); заменяет прошлый отчёт → контекст `Sentinel` (`{network, core, roots}`, он же `context` в status). См. `failures.md` |
| `POST /api/auto` | `{auto?, manual?, entry?}` — новые настройки Auto mode (как `plan.auto`) работающему AutoService, без переподключения. `manual` (bool) — Auto ↔ Manual вживую: план уже держит все маршруты Auto (`plan.manual` — режим на старте), контроллер лишь перестаёт/начинает ходить между ними; `entry` (id записи) — маршрут, на котором стоит Manual: селектор `proxy` переключается туда без перезапуска и без события `auto/switched`. Записи нет в плане — режим применён, маршрут не двигается (хост шлёт новый план). `status.auto`: `manual`, `routes[].server` / `entryServer` — где стоят группы **каждого** маршрута → status |
| `POST /api/disconnect`, `GET /api/status` | status: `{connected, mode: 'tun'\|'proxy'\|null, systemProxy, sysPort, error, warning, exit, recovering, down, blocking, restarts, auto, network, dns, sourcesRev}` — `network: {status: 'up'\|'down'\|'unknown', since, lastAnswer, offline, silent, doubt}` — общее состояние сети пула замеров (см. «Пул замеров»); `connected` true и пока sing-box перезапускается (`recovering: {attempt, code, next}`, `down: {since, attempt, proxy: 'kept'\|'removed'\|'released'}` — после 30 с; null, когда нет), `blocking: {since, reason: 'disconnect'\|'closed', proxy: 'kept'\|'released'}` — не подключено, прокси оставлен kill switch'ем (см. «Падение sing-box», «Kill switch»); `auto` см. ниже; `sourcesRev` растёт, когда ядро само обновило подписку в снимке (или записало `lastError` неудачного обновления) |
| `GET /api/log?since=N&conns=0` | `{lines:[{n, t, src: "sing-box" или "core", lvl: debug/info/warn/error, msg}], next, hidden?}` — строки с номером ≥ N (без `since` — все хранимые: до 5000 + 500 шума); UI опрашивает с `next` прошлого ответа. `conns=0` — шум-кольцо (успешные соединения, `found package name`) не отдаётся, `hidden` = сколько строк пропущено; нумерация и `next` те же. `DELETE /api/log` — очистить (нумерация продолжается). Подробно — `docs/logs.md` |
| `GET /api/report`, `POST /api/report` | `CoreApi.report({appInfo})` → отчёт для разработчика одной картой: версии, состояние, план без секретов, настройки, сеть, сводка TUN, счётчики детекторов, все события и обе кольца сырого лога, секреты замаскированы (`report.dart`, `redact.dart`). `POST` — тело `{appInfo: {…}}` (то, что знает только вызывающий: версия приложения, устройство, `planSig`, `names`, …). Формат и маскирование — `docs/logs.md` → Отчёт |
| `POST /api/report/send` | `CoreApi.sendReport({note, appInfo})` → отправка отчёта разработчику: ужесточённое маскирование, заметка пользователя (≤ 500 знаков, тоже маскируется), gzip, передача `ReportUploader` (`CoreService(reportUploader:)`; в настоящих хостах — `HttpReportUploader`: шифрование на устройстве и загрузка на Worker, у `jormd` тоже; без параметра `NotConfiguredUploader`). Тело `{note, appInfo}`, ответ `{ok: true, id, bytes}` или `{ok: false, error, message?}` — сбой доставки не исключение. `error`: `not-configured`, `network`, `rejected`, `server`, `failed`. Подробно — `docs/logs.md` → Отправка |
| `POST /api/site-check` | `{event}` (id события `site/*`) → `{check}` — «Check with checker»: ядро спрашивает check-host.net о сайте события (`CoreApi.siteCheck`, `sitecheck.dart`), событие сначала получает `data.check.state: 'pending'`, потом результат с `manual: true`; идёт до ~30 с. 400, если события нет / оно не про сайт / сайт игнорируется |
| `GET /api/events?since=N` | `{events:[…], updated?, next, first}` — журнал событий (ниже): события с `id ≥ N`, старые первыми; без `since` — последние 200. `updated` (только когда есть) — события, которые ядро изменило на месте за последние 10 минут (`EventBook.update`: поле `rev` = число изменений, `data` дополнено, `id` и место прежние), какой бы у них ни был `id`: читатель, у которого уже есть событие, заменяет его, если `rev` новее (`EventFeed.apply`), и событие уходит ещё раз в `eventStream`. `next` — id следующего события, `first` — id самого старого из хранимых (пропуск между своим `next` и `first` = журнал обрезан или очищен). `POST /api/events` `{cat, type, level, own?, data?}` → `{id}` — событие, которое первым узнал UI (400 с причиной, если форма не та: неизвестные `cat` / `level`, `type` не `[A-Za-z][A-Za-z0-9_]{0,47}`, `own` не bool, `data` не объект или больше 4096 знаков JSON); к такому событию `log` не привязывается. `DELETE /api/events` — очистить (нумерация продолжается) |
| `GET /api/version` | `{core, singBox, dataDir, dart, os}` — Settings → Data → About |
| `POST /api/node` | `{protocol, address, port, secret, name, outbound?, unsupported?}` → `{node}`; ошибка формы — 400 `{error}` с текстом для пользователя |
| `POST /api/share` | `{outbound, name, flag, unsupported?}` → `{link}` (null — у сервера нет формы ссылки) |
| `DELETE /api/connections`, `DELETE /api/connections/{id}` | закрыть все / одно соединение (API service sing-box); без подключения `{ok:false}` |
| `GET /api/traffic` | `{running, down, up (Б/с), downTotal, upTotal, tcp, udp, conns:[{id, host, port, net, rule, ruleName, ruleKind, ruleId?, out, process, pkg?, down, up, downRate, upRate, start}]}` — см. ниже |
| `POST /api/exit` | перепроверить выход туннеля; результат — в `status.exit` |
| `POST /api/speedtest` | `{node:{key, outbound}}` или `{pair:{key, entry, exit}}`, `configUrl?` → поток NDJSON по ходу замера: `{phase (0 задержка, 1 загрузка, 2 отдача, 3 готово), down, up (бит/с), downRpm, upRpm, latency (мс), elapsed, final}`, последняя строка `final: true` (при сбое с `error`). Отдельный sing-box с одним сервером, network quality test sing-box (серверы Apple mensura, если не задан `configUrl`); закрыли страницу/лист — замер останавливается. `{current: true}` — вместо отдельного бокса меряет **работающее подключение**: тест через исходящий `proxy` (главный поток) основного sing-box; не подключено → одна строка `{error: 'Not connected', final: true}`. Законченный замер хранится в `<data>/last-speed.json`, отдаётся в `status.speed` (`{down, up, latency, rpm, at}`) и пишется в журнал (`speed/done`, `speed/failed`); отменённый ничего не оставляет |
| `POST /api/ping` | `{nodes:[{key, outbound}], pairs:[{key, entry, exit}], url?, maxAgeMs?, …checkers}` → поток NDJSON: строка `{kind:"n" или "p", key, ms}` на каждый результат сразу по готовности (-1 = нет ответа), в конце `{done:true, network:"up"\|"down"\|"unknown"}` или `{error}`. Замеры идут через пул (см. «Пул замеров»): результат пишется в него, `maxAgeMs` > 0 отдаёт ответ пула не старше этого вместо замера (пинг запуска; по умолчанию 0 — меряет всегда); `network` — состояние сети (`down`: ни один сервер не ответил и прямой путь молчит — UI может сказать «нет сети»). Замеры идут в порядке списка (16 параллельно; запасные проверки промахнувшегося сервера — по две за раз, не все сразу: каталожный пинг на сотнях серверов не держит сотни соединений; Auto по-прежнему спрашивает все сразу); UI шлёт ноды по кэшу: живые, неизмеренные, мёртвые |

`status.auto` (пока подключено; `null` — нет): `{now: id маршрута, index, server, entryServer
(цепочка), routes: [{id, ms, fails, oks, at, strikes, holdUntil}], members: [{key, ms, fails, oks,
at}], pairs: [{entry, key, ms, fails, oks, at}], switches, switchedAt, lastSwitch: {route?, from, to, reason: 'failover' | 'back', at}, unstable
(счёт), lastUnstable: {id, strikes, hold (мс), at}, noNet, stalledClosed, checkedAt}`. `holdUntil` —
когда запись на испытательном сроке сможет забрать трафик, если продолжит отвечать.
`ms`: −1 таймаут, −2 не мерили; `members` — все замеренные серверы (UI кладёт в кэш пингов);
`pairs` — выходы цепочек, замеренные через вход (`entry` — ключ входа, `key` — выхода, оба `sid::nid`; одна
запись на пару; UI кладёт в кэш пар `PairBook`, `snapshot.pairs`, см. connect-model.md «Пинг»);
`switches` — счёт переключений маршрутов и Priority-серверов (`lastSwitch.route` есть у второго,
тогда `from`/`to` — ключи серверов). UI опрашивает status раз в 4 с.

`status.dns` (пока подключено и есть DNS-серверы; иначе `null`): `{active: id сервера в работе,
auto, servers: [{id, ok, ms}]}` в порядке приоритета. `ok`: `null` не мерили, `false` — упал
(`failAfter` промахов подряд); `ms`: −1 нет ответа, −2 не мерили. Метки «In use» / «No answer»
в Settings → DNS. При одном сервере переключать некуда, но проверка и `status.dns` есть.

Пинг (`probe.dart`): ядро меряет само, через loopback SOCKS5-inbound конфига `probe-in` —
имя пользователя = тег outbound'а (правило `auth_user` → этот outbound, первым в route),
пароль случайный на каждый старт. Два `HEAD` к тест-URL по одному соединению, результат —
время второго: один проход туда-обратно по всему пути, без рукопожатий (как Karing /
«unified delay» mihomo). Clash API `/proxies/{tag}/delay` sing-box считает первый запрос с
рукопожатиями — через мост (RU → EU, мост открывает своё соединение дальше) это в 3–4 раза
больше (замер 2026-09-27: 210–290 мс против 64–90 у Karing и у нас сейчас). Сервер закрыл
соединение после первого ответа → время первого. Ещё причина не брать Clash API: он молча
заменяет любой `http://` тест-URL на gstatic (`getProxyDelay` в sing-box), probe берёт URL как есть. Каталог: временный sing-box только с
`probe-in` (16 параллельно, запасные проверки по две за раз, таймаут 5 с), пары entry→exit — копия выхода с detour на копию
входа. Auto: `probe-in` рабочего конфига; urltest-группы Fastest внутри sing-box по-прежнему
выбирают по своему замеру (относительный порядок тот же).

Exit IP (`exitip.dart`): после каждого (пере)подключения и по запросу ядро спрашивает
через свой вход `tunnel-in` (не пользовательский порт: на нём может быть пароль) сразу несколько сервисов (`exitProbes`) на разной инфраструктуре,
параллельно: с геоданными — ipwho.is (Cloudflare), ipinfo.io (Google), ip-api.com (свой
хостинг, только HTTP); IP и страна — Cloudflare trace; только IP — Яндекс (доступен из РФ),
Amazon, ipip.net (из Китая). Страна, которая режет один CDN (РФ — Cloudflare), не ломает
проверку. Первый ответ со страной и городом — сразу результат; если пока есть только IP,
ещё 1,5 с ждём геоданные, потом берём что есть (тогда в UI «Location unknown»). Ответы про
один IP дополняют друг друга. Общий лимит — 7 с. Если все сервисы упали быстро (< 3 с) —
туннель ещё не везёт трафик, демон повторяет через 2 с, до 15 с от начала. Диагностика по сервисам на конкретной
ноде: `dart run tool/exit_check.dart [port]`.
Без подключения (при старте демона, после отключения, по тапу) те же сервисы
спрашиваются напрямую, без прокси, — это собственный IP устройства; в UI карточка
называется «Direct IP». Повторов «туннель ещё не везёт» у прямой проверки нет.
Пока идёт проверка, `status.exit = null`;
затем `{ip, country?, city?, org?, source, direct, at}` или `{error, direct}`. Результат устаревшей
проверки (после нового подключения или отключения) отбрасывается. UI опрашивает status,
пока ответа нет; тап по карточке — `POST /api/exit` (через туннель или напрямую, смотря по
состоянию).

Трафик (`traffic.dart`, `trafficOf`): всё из потоков API service — скорость и итоги из статуса,
соединения из таблицы (сервер — конечный outbound, `route<i>/<sid::nid>`; у цепочки ещё
выбранный сервер входа `route<i>-entry/…` из потока групп; у цели правила `<цель>/…` и
`<цель>>entry/…`; в `out` выход первым; скорость соединения — байты за последнюю секунду).
Процесс (`process`) — `route.find_process`; на Android ещё `pkg` — первый пакет из `packageNames`
(ключ есть, только если он не пуст). Для `LiveConn.app` (группировка, фильтр, поиск) пакет — запасное
значение, когда пути процесса нет; в заголовке группы / поиске пакет подменяется именем приложения
(`ConnView.appName`, его задаёт UI — список установленных приложений у хоста, не у ядра).

Правило соединения (`rulenames.dart`). sing-box сообщает сработавшее правило только как его
`String()` — условия без действия и без номера (`network=tcp port=443`), списки длиннее
3 значений обрезаны (`domain_suffix=[a b c...]`, у `domain_regex` / `process_path_regex`
без `...`); это `rule` — сырое, оставляется как есть. Поэтому при сборке конфига ядро
считает тот же текст для каждого сгенерированного правила (`ruleText`: порядок и формат
полей как в `NewDefaultRule` sing-box, сверено с настоящим sing-box в
`test/rulenames_test.dart`) и запоминает происхождение (`RuleOrigin`) в
`RoutingInfo.ruleNames`; `trafficOf(api, names:)` ищет по нему текст соединения. К
соединению добавляются `ruleKind` — `user` (своё правило: `ruleName` = его имя, `ruleId` =
id), `app` (правило приложения, у Split — «Имя (TCP)» / «Имя (UDP)», `ruleId` = id
приложения), `service` (Rules → Services, `ruleId` = ключ сервиса), `quick` (`Block ads`,
`My region direct`), `system` (своё ядра: `Private networks` / `private`, `Core checks` /
`tunnel` — tunnel-in, `Latency check` / `probe`, `DNS check` / `dns-check`), `final` (ни одно
правило не сработало, `ruleName` = ''), либо '' — имя не определить (`ruleName` = '': UI
показывает `rule`). Не определить = условие, которого `ruleText` не знает (в JSON-правиле),
или два правила с разными условиями, у которых текст совпал из-за обрезки списков (лучше
без имени, чем с чужим). Правила с одинаковыми условиями и разными действиями — то же
соединение: берётся первое (его и применяет sing-box). Правила без условий (sniff,
resolve, голый reject) имён не дают.

UI опрашивает
раз в секунду, пока подключено и страница видна: карточки Speed / This session /
Connections и лист Live connections (новые сверху: хост:порт, TCP/UDP, вход → выход,
правило, приложение, скорость, объём, возраст). Без подключения скорость и соединения — 0,
итоги прошлой сессии остаются. В листе — фильтр (хост, приложение, правило, сервер), × на
строке закрывает соединение, Close all — все; сортировка, фильтр, пауза, раскрытие строки —
`connect-model.md` «Лист Live connections» (`DELETE /api/connections[/id]` → `CloseConnection` /
`CloseAllConnections`; приложение обычно тут же открывает новое).

Лог (`logbook.dart`): вывод sing-box (уровень `info`, со временем) и заметки самого ядра
(подключено / отключено / не подключилось, предупреждение системного прокси, упавшие
`/api`-запросы) — одна нумерованная очередь. Префикс даты sing-box срезается, уровень
(TRACE/DEBUG → debug, WARN → warn, ERROR/FATAL/PANIC → error) — отдельным полем; строки
рантайма `[jormd] …` считаются строками ядра. `since(n)` находит начало ответа бинарным
поиском по номеру (номера растут вдоль очереди): цена — размер ответа, не книги (приложение
спрашивает после каждого всплеска строк).

**LogBook: два кольца и файл.** Строки sing-box об удачных соединениях (`connLineRe`: `inbound/…:
inbound connection …`, `outbound connection`, `packet connection`; не warn / error) и строки
`router: found package name: …` / `found process path: …` (`isNoiseLine`: одна на каждое соединение;
раньше занимали до 79 % основного кольца) живут в своём малом кольце (`noiseCap`, 500), всё остальное — warn, error, заметки ядра, прочие info — в основном
(`cap`, 5000): поток соединений за ночь не вытесняет ошибки. `since` сливает кольца по номеру; приложение
держит у себя до `logKeep` (5500) строк. Warn / error дополнительно пишутся в
`<dataDir>/problems.jsonl` (`{t, src, lvl, msg}` на строку; ≤ 1 МБ): буферизованно и асинхронно, как
EventBook (одна запись через 1,5 с после первой, `flush()` в `dispose`, без fsync на строку и без
синхронного IO в рабочее время); при превышении лимита файл переписывается из самых новых проблем
(до половины лимита). `load()` при старте (`init`) возвращает их в книгу (с новыми номерами, время
сохраняется), так что ночные ошибки видны после перезапуска и сбоя; оборванная строка пропускается,
`clear()` чистит и файл. Вид Raw с выключенным Connections скрывает именно строки малого кольца.

**Экран** (`CoreApi.updateSettings({screenOn: bool})`, поле `CoreService.screenOn`, по умолчанию `true`):
платформа (Android, `jormungand/screen`) сообщает состояние экрана при старте и при каждой смене; пока
он `false`, `siteBlocked` / `siteUnreachable` пишут событие с `bg: true` (`EventBook.add(..., bg:)`,
в JSON события только когда true, `EventRecord.bg`). Без переподключения, маршрутизацию не трогает;
уведомляют ли такие события, решает приложение (`notifCfg.bgErrors`, `docs/connect-model.md` → «Фоновые ошибки»).

**Закрывать соединения при смене маршрута** (`CoreApi.updateSettings({closeOnSwitch: bool})`, поле
`CoreService.closeOnSwitch`, по умолчанию `true`; в приложении `connCfg.closeOnSwitch`): `autoSettings
{manual, entry}` передаёт его в `AutoService.setManual(..., closeOld:)`; после успешного `select(proxy,
новый маршрут)` закрываются (`BoxControl.closeConnection` по id) соединения, чья цепочка содержит и
`proxy`, и тег прежнего маршрута. Не закрывается ничего, если маршрут не менялся (Manual на тот же,
Manual → Auto) или `select` отказал. Собственные переходы Auto сюда не входят (у них свой свип
застрявших, `stall.dart`). Подробности и поведение выкл. — `docs/connect-model.md` → «Auto в ядре».

**Игнорируемые сайты** (`ignored_sites.dart`, `IgnoredSites`): список хостов, о которых пользователь
не хочет слышать (мёртвый сайт, в который что-то ломится). Приложение шлёт его
`CoreApi.updateSettings({ignoredSites: [host…]})` (ключи независимы; тот же шов, что у настроек
обновления; без переподключения, на маршрутизацию не влияет; хранит список приложение —
`notifCfg.ignoredSites`, оно же присылает его заново при каждом старте ядра). Совпадение — хост и его
поддомены (`example.com` покрывает `api.example.com`, не `notexample.com`); запись чистится (регистр,
схема, путь, порт, `*.`, точка на конце). Действует в трёх местах: (1) `CoreService.siteBlocked` /
`siteUnreachable` (обработчики потоков Auto) не пишут `site/blocked|unreachable` для такого хоста —
ни события, ни уведомления; (2) `LogBook.ignored`: warn / error строка, в тексте которой есть слово —
 игнорируемый хост или поддомен (`matchesText`: «lookup a.dead.org», «connection to dead.org:443»,
заметки Auto «dead.org:443 does not open…»), уходит в малое кольцо (`noiseCap`), а не в основное, и не
пишется в `problems.jsonl` — такой шум не вытесняет ошибки; действует на строки, пришедшие после
смены списка; (3) Auto по-прежнему проверяет маршрут после упавших запросов (это его работа с
узлом, не сообщение пользователю). Вид Raw (`LogFeed.setIgnored`, `isIgnored`, `lineShows`) сортирует
строки сам по текущему списку, поэтому и старые строки скрываются сразу, а Undo возвращает их;
`logCfg.showIgnored` (выкл.) включает их чипом «N from ignored sites».

Журнал событий (`eventbook.dart`, `EventBook`) — «что произошло», структурно: вкладка
Logs → Events и все уведомления делаются из него; сырой лог выше остаётся как есть (вкладка
Raw). Событие:

```
{ id,        // растёт на 1, не откатывается: ни после рестарта, ни после очистки
  at,        // мс с эпохи
  cat,       // conn | auto | site | sub | rules | dns | speed | core | user
  type, level: 'info' | 'warn' | 'error',
  own,       // true = причина — действие самого пользователя: уведомления нет
  log?,      // номер строки LogBook, записанной в тот же момент (переход в Raw)
  data }     // только поля, без готовой фразы: текст и язык — дело приложения
```

Хранится в `<dataDir>/events.jsonl` (JSON Lines): последние 7 суток и не больше 1000
событий. В памяти обрезка строгая и при каждой записи; файл пишется позади памяти: новые события
копятся и дописываются одной асинхронной записью (с fsync) через 1,5 с после первого (`flushEvery`) и
в `dispose` (`flush()`), так что всплеск из сотен событий стоит один fsync, а при сбое теряется не
больше последней секунды-двух. Обрезанное остаётся в файле, пока не накопится 100 лишних строк
(`pruneChunk`), тогда файл переписывается целиком (tmp + fsync + rename); так же при очистке и при
старте (там — сразу, синхронно, до первых записей). Первая строка переписанного файла —
`{"seq": N}`, по ней id продолжаются, даже когда событий не осталось. Записи идут по очереди одна
за другой; неудавшаяся запись делает следующую полным переписыванием. `since(id)` ищет начало
бинарным поиском по id. Битая строка (запись оборвалась на сбое) пропускается. Ошибка записи на
диск до вызывающего не доходит (журнал остаётся в памяти). Ядро пишет сначала строку в сырой лог,
потом событие — `log` указывает на неё.

Что и где пишет ядро (`cat/type`, уровень, `data`):

| событие | когда | `data` |
|---|---|---|
| `conn/connected` info | подключились (`own: true`, если по команде пользователя; `false` — переподключение ядра за докачанными списками) | `{entry, server?, mode: 'proxy'\|'tun', route: 'global'\|'rules'}` — `server` только если он уже известен (у Fastest его выбирает urltest позже) |
| `conn/connectFailed` error | подключение не вышло | `{reason}` |
| `conn/disconnected` info / error | `by: 'user'` — по команде (`own: true`, пишется, только если было подключено); `by: 'error'` — sing-box не поднялся после всех попыток | `{by, reason?}` |
| `conn/lost` warn | Auto: ни один маршрут не отвечает (`noNet` стал true из-за проверок) | `{}` |
| `conn/restored` info | `noNet` снова false | `{downMs}` |
| `conn/offline` warn / `conn/online` info | у ОС нет сети — по строке sing-box `missing default interface` / `updated default interface` (пока подключено) | `{}` / `{downMs}` |
| `auto/switched` info | Auto переключил маршрут (без `route`) или Priority-сервер внутри маршрута (`route` есть) | `{route?, from, to, reason: 'failover'\|'back'}` |
| `auto/fastest` info | Fastest сам сменил сервер (urltest внутри sing-box) | `{route, from, to}` |
| `auto/unstable` warn | маршрут падает снова и снова (flap guard) | `{id, strikes, holdMs}` |
| `site/blocked` warn | сайт не открывается через сервер, но открывается через другой маршрут (кнопка Create rule); другие отвечающие маршруты пробуются по порядку Auto до первого, где открылся (не больше `siteRetry`), он и есть `via` | `{host, port?, entry, server, dest, via, viaServer, rule, process?}` — `rule` и `process`: см. ниже |
| `site/unreachable` warn | сайт не открывается ни через сервер, ни через проверенные другие маршруты (или нет другого отвечающего / повторы выключены); пара маршрут + сайт раз в час, как у `blocked` | `{host, port?, entry, server, dest, tried: [{entry, server}], retries?: 'off', rule, process?}` — `rule` и `process`: см. ниже; `tried` пуст: нет другого рабочего маршрута, при `retries: 'off'` — повторы выключены (`siteRetry`); без `retries: 'off'` в `data` ещё `check` — `{state: 'pending'\|'off'\|'opens'\|'down'\|'failed', at, kind?, via?, ok?, total?, nodes?, error?, manual?}`, внешний чекер check-host.net (docs/connect-model.md «Внешний чекер»): событие меняется на месте (`rev`), тихое, пока нет `opens` |
| `sub/updated` info | автообновление по таймеру ядра изменило список серверов (без изменений — события нет) | `{source, name, added, removed, total}` |
| `sub/failed` error | автообновление не вышло — только первый сбой после удачного (пока на карточке висит `lastError`, повторы молчат) | `{source, name, error}` |
| `rules/fallback` warn | цель правил перестала отвечать, их трафик ушёл на запасной выход («If unavailable»); одно событие на пару цель + запасной выход | `{rule?, app?, more?, target, to: 'block'\|'direct'\|'main'\|<id of the fallback target>}` — `target`: the cause (`proxy` = the main flow); `rule`: имя первого правила (безымянного — `rule <id>`); `app`: имя первого приложения, когда через selector нет правил; `more` — сколько ещё правил / приложений через тот же selector |
| `rules/targetBack` info | цель снова отвечает, трафик вернулся | `{rule?, app?, more?, target}` |
| `dns/switched` info | DNS-сервер в работе сменился (Switch automatically); `own: true` при `reason: 'off'` | `{from, to, reason: 'failover'\|'back'\|'off'}` — id серверов из UI |
| `rules/ruleSetFailed` warn | скачивание списка не удалось (не чаще, чем раз в `retryAfter` = 5 мин на список) | `{tag, url, error}` — `url` последний из пробованных |
| `rules/ruleSetUpdated` info | старая копия списка заменена новой, или список скачан после сбоя (первая закачка отсутствующего списка — не новость) | `{tag}` |
| `core/crashed` error | sing-box вышел сам (перезапуск идёт в фоне; уведомление — по решению UI) | `{code}` |
| `core/down` error | перезапуск не удался за 30 с от падения (см. «Down») | `{proxy: 'kept'\|'removed'\|'released'}` |
| `core/restarted` info | после падения запущен снова | `{attempt, downMs?}` — `downMs` (мс от падения) только если успел быть down |
| `core/tunNeedsAdmin` error | TUN не поднялся: у процесса нет прав администратора (проверка до запуска) или sing-box отказал по правам. Вместо `conn/connectFailed`; `own: true` при connect по команде пользователя | `{stage: 'check'\|'start', error?}` — `error` только при `start`: слова sing-box |
| `core/restartFailed` error | попытка перезапуска не удалась (только первые три) | `{attempt, error}` |
| `core/sysProxy` info / warn | системный прокси включён / возвращён (`own: true` при команде пользователя); при остановке jormd тоже; `warn` — не вышло. Прокси, оставленный kill switch'ем, события не пишет | `{on, by?, error?}`, `on` — что хотели получить; `by: 'user'` — кнопка Remove / Disable sys proxy (`POST /api/sysproxy/release`) |
| `core/deprecated` warn | sing-box сообщил, что конфиг перестанет работать в новой версии; каждый текст — раз за запуск демона (в сыром логе — при каждом подключении) | `{text}` |

**`rule` и `process` у `site/blocked` / `site/unreachable`** — почему запрос пошёл этим маршрутом и кто его
послал: sing-box присылает в закрытом соединении текст сработавшего правила (`rule`, как в Live
connections) и путь приложения; ядро хранит их рядом с адресом упавшего запроса (`_failDests`) и
переводит текст в имя тем же `RuleNames`, что и `/api/traffic` (`ruleEventData`, rulenames.dart).
`rule: {kind, name?, id?, text?}` — `kind`: `user` (id правила), `app` (id приложения), `service`
(ключ), `quick` (`ads` / `region`), `system` (`private` и служебные), `final` (правило не сработало:
основной поток, `name` нет), `unknown` (имя не удалось определить — `text` сырой текст). `process?:
{name, path}` — имя файла и полный путь; нет, если sing-box не знает приложение. `app?: string` —
Android-пакет приложения (первое из `processInfo.packageNames` sing-box; `android` — системный uid
1000); нет на десктопе и когда владельца не нашли. Путь с пакетом идёт той же цепочкой, что `process`:
`ClosedConnection.pkg` / `LiveConnection.pkg` → `AutoBlocked.pkg` / `AutoUnreachable.pkg` (рядом с
`process` в `_failDests`) → `data.app` в `siteBlocked` / `siteUnreachable`. UI только показывает (значок
и имя, тап → диалог приложения), правил не создаёт.

Не пишет ядро (нет данных или это знает только UI): `sub/removed`, `sub/back`, `sub/dead` (модель
серверов и пинги живут в UI; UI шлёт их `POST /api/events`), `user/*` (действия пользователя — тоже
`POST`; у них `own: true`), а также результаты ручного обновления подписки из UI. Провал скачивания
списка правил в предупреждение `warning` ответа на connect не попадает (туда идут только
предупреждения сборки: правило пропущено, потому что списка нет).

Ссылка сервера (`share.dart`) — обратная сторона парсера ссылок: из outbound снова
vless/trojan/hy2/tuic/anytls-URL, vmess — JSON v2rayN (URL-вид, если JSON не умеет: Reality,
insecure), ss — SIP002 (у шифров 2022 userinfo без base64). Имя во фрагменте, флаг впереди.
Разобранная обратно ссылка даёт тот же `key` и тот же outbound (тест `share_test.dart`).
socks — `socks5://user:pass@host:port` (`socks4://` для v4), Hysteria v1 — `hysteria://host:port?auth=…`.
Нет ссылки у http/wireguard
из подписок и у `unsupported`-нод (их outbound без
xhttp — ссылка назвала бы другой сервер).

Сервер вручную (`manual.dart`): протокол, адрес, порт, секрет формы (UUID / пароль;
`method:password` у ss, `uuid:password` у tuic, `user:password` у socks — необязательно).
Новый — простой outbound теми же билдерами, что у парсера ссылок (VLESS/VMess без TLS,
Trojan/HY2/TUIC/AnyTLS с TLS по адресу). Правка того же протокола меняет только адрес,
порт и секрет (пустой секрет — прежний), TLS, транспорт, flow остаются; `key` пересчитывается,
`id` UI оставляет прежним, чтобы настройки с этим сервером не потерялись.

Системный прокси ставит ядро через реестр (HKCU Internet Settings), не sing-box; порт — `mixedPort`,
а при пароле на нём — открытый `sys-in` («Входы sing-box»): при
убитом процессе sing-box не вернул бы настройки. Прежние значения сохраняются и
возвращаются при отключении, при остановке и при следующем старте после сбоя (kill switch может
оставить прокси на месте — «Kill switch»; при падении sing-box прокси не снимается). PAC (AutoConfigURL,
типично для корпоративной сети) Windows спрашивает раньше ручного прокси — ядро
предупреждает.

Подписки (`fetch.dart`, `updater.dart`, `state.dart`): загрузка с UA-стратегией, фильтром,
HWID (`device.dart`) и каналом Direct / Proxy; автообновление по таймеру ядра прямо в снимке
`ui-state.json` (доступ к снимку — через `SnapshotStore`, одна очередь на чтение и запись).
Правила и конфликты с UI — subscription-parsing.md → «Автообновление».

Состояние UI на диске (`ui-state.json`) переживает отключение питания (`durable.dart`, `SnapshotStore`):
запись идёт в `ui-state.json.tmp` с `flush` (fsync) и только потом `rename` поверх файла (без fsync
после питания остаётся файл из одних NUL-байт). Заменяемый файл остаётся как `.bak` (предыдущая
сохранённая версия), прежний `.bak` уходит в `.bak2`, если ему не меньше 10 минут (иначе плохой, но
валидный снимок вытеснил бы последнюю хорошую копию за секунды); на любом шаге сбоя файл — старый или
новый, между двумя rename его нет, и подхватывается `.bak`. Загрузка: нет файла / не читается / пуст /
NUL / не JSON / не объект → файл не удаляется, а переименовывается в `ui-state.json.corrupt-<UTC-время>`
(остаются 5 новейших), берётся `.bak`, затем `.bak2` (битая копия тоже уходит в `corrupt`), найденная
копия записывается обратно как файл; иначе состояние пустое. Всё это не бросает: чтения и сохранения
работают дальше. Ядро говорит об этом сразу при старте (`init`): событие `core/stateRestored` (warn,
`{from: 'bak'|'bak2', savedAt, reason: nul|empty|invalid|notObject|unreadable|missing, kept?}`) или
`core/stateLost` (error, `{reason, kept?}`, копий нет — UI стартует пустым) и строка в Raw. Так же
(tmp + fsync + rename) пишутся `kill.json`, `sys-in.json`, `device.json`, файл прежнего системного
прокси; `events.jsonl` дописывается пачками с fsync (см. «Журнал событий»). Битый файл прежнего системного прокси при старте
не ломает его: прокси выключается (`ProxyEnable=0`), файл удаляется, прежние значения потеряны.

## Не сделано в MVP

Kill switch для TUN (есть только `strict_route`; для системного прокси kill switch есть, см. «Kill switch»); FakeIP; обновление гео-списков по таймеру; Decrypt
password подписки (нет спецификации); автовыбор URL пинга (сейчас — выбор в Settings →
Connection, по умолчанию gstatic).
Auto: проверка по неудачным запросам, `speedOnFail`, пауза при выключенном экране; группы
целей правил AutoService не ведёт (их Priority меняется только новым планом), за целями следит
`FallbackService` («If unavailable» на лету), но и он Priority не двигает. Переключение DNS не
меняет `default_domain_resolver`; в `status.auto` нет состояния целей правил (только события
`rules/fallback` / `rules/targetBack`).
