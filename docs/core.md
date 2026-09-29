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
```

Бинарник sing-box: скачать `sing-box-<ver>-windows-amd64.zip` из релизов SagerNet/sing-box,
положить `sing-box.exe` в `core/tool/bin/`. Состояние: `%APPDATA%\Jormungand`
(`--data` меняет; для разработки `core/.data-dev`).

`--lan` — слушать и локальную сеть (открыть UI с телефона); адреса печатаются при старте.
Авторизации нет: любой в сети может управлять ядром, поэтому только в доверенной сети.
Windows Firewall должен пропускать входящие для `dartvm.exe` на этот порт.

Прокси: mixed (HTTP + SOCKS5) на `127.0.0.1:<mixedPort>` (Settings → Connection → Proxy port, по умолчанию 2080). С sing-box ядро говорит только
через его API service (gRPC, свободный порт loopback, см. ниже); Clash API не включается. TUN в MVP нет: переключатель TUN подключает как прокси с предупреждением.

## Кто за что отвечает

| | Мокап (UI) | Ядро |
|---|---|---|
| Источники, профили, цепочки, порядок, Auto/Manual, off/disabled | хранит и решает | хранит снимок (`ui-state.json`) |
| Что подключать (запись + резервные, ноды, fastest/priority) | решает → «план» | — |
| Auto при подключении (failover, возврат, Priority-сервер) | показывает то, что сообщило ядро | `auto.dart` (AutoService) |
| Скачивание подписок, UA discovery, ETag, dedup, gone | — | `fetch.dart`, `merge.dart` |
| Парсинг ссылок / Clash / sing-box JSON | — | `parse/` |
| Конфиг sing-box | — | `config.dart` |
| Запуск, остановка, пинг | — | `runtime.dart` |
| Системный прокси (Windows) | переключатель | `sysproxy.dart` |
| Ссылка сервера (Copy share link, QR) | просит | `share.dart` |
| Сервер вручную (форма без ссылки, правка) | поля формы | `manual.dart` |
| Лог (вкладка Logs) | фильтр, поиск, копирование | `logbook.dart` |

Во Flutter-приложении колонка «Мокап» станет Dart-кодом приложения, API уйдёт — сервисы
будут вызывать ядро напрямую.

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
  urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold,
             url: connCfg.testUrl /* нет — gstatic; им же проверяет AutoService */ },
  auto: { failAfter, threshold, checkEvery, standby, warmEvery,
          retryPause /*с*/, returnTo: 'always' | 'faster' | 'never', flapGuard, flapMax /*мин*/, flapReset /*мин*/ },
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
  Auto), серверы групп (у Fastest — без порядка, и в маршрутах, и в целях правил), закреп Manual,
  правила, Global/Rules, системный прокси, `urlTest`. `plan.auto` не сравнивается: изменённые
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
   (его замер идёт через вход и в `members` не попадает).
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
живой, если ответила хоть одна.

Упавшие запросы (`onClosed`): демон подписан на поток закрытых соединений API service
(ниже); соединение через текущий маршрут без единого байта ответа → проверка сразу (одна на
`failWindow` 10 с). Нода живая → сайты таких запросов проверяются `reach` (`probeReach`: TLS на
443, HEAD на 80) через неё и через другой отвечающий маршрут → событие `blocked`
(`AutoBlocked {route, server, dest, via}`, пара маршрут + сайт раз в час). `onLog`: строка
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

## Kill switch

Только системный прокси (TUN в MVP нет). Настройки приходят **верхнеуровневыми полями** тела
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

## Правила в конфиге

`routing` (`js/93-routing-plan.js` → `core/lib/src/routing.dart`; логика — `rules.md`):

```
{ apps:  [{ id, kind: 'package'|'process'|'path', act, target, split, udpTarget }],
  rules: [{ id, name, action, target, fallback, block, dns, groups, composite?, extra? }],
  quick: { ads, region: 'RU'|…|null, services: { telegram: 'vpn'|'direct', … }, final },
  fallback: 'main'|'block'|'direct',            // Rules → Target unavailable
  targets: { '<цель>': { kind: 'unit'|'chain', main: Group, entry?: Group } | null },
  ruleSets: [{ name, url, format, via, every }],
  geo: { geosite: { via, every }, geoip: { via, every } },
  dns: { servers: [{ id, addr, via, on }] } }
```

- UI шлёт свою модель: группы условий формы, `composite` (составное правило из JSON, без
  action), цели. Каталог живёт в UI, поэтому каждую названную цель UI сам разворачивает в
  группы (как `main`), `null` — цель недоступна (тогда её «If unavailable»). Всё остальное —
  AND/OR, CIDR, порты, DNS-серверы, списки — строит ядро.
- Порядок route: `sniff` → `tunnel-in` → приложения → свои правила (перед первым с IP —
  `resolve`) → быстрые → `final`. Группы целей — теги целей (`src:…`, `chain:…` + `chain:…>entry`).
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
  (`URLTest` + повтор), Priority не двигается. Не судит, пока `AutoService.networkUncertain`
  (нет сети / у текущего маршрута промахи). Уход на запасной выход закрывает зависшие
  соединения через цель (`StallSweeper`, общий с Auto: байты стоят `stallAfter`). Выбор в
  начале раунда читается из `api.selected` (после рестарта `cache_file` мог оставить
  запасной). Группы целей по-прежнему не ведёт AutoService.
- **Переключение DNS** (`dns_failover.dart`, `DnsFailover`). При двух и более отмеченных
  серверах у каждого `dns-<id>` DNS-правило `clash_mode: "dns-<id>"` (после остальных
  DNS-правил, `routing.dart` `_dnsModes`); `dns.final` — первый отмеченный, стартовый режим
  `Rule` ему же и равен. Проверка сервера — `probeDns` (`probe.dart`): SOCKS-запрос в probe
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
| `POST /api/connect` | `{plan, systemProxy, killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?, dnsAuto?}` — kill switch, см. «Kill switch»; `dnsAuto` — Settings → DNS → Switch automatically (по умолчанию true), см. «Правила в конфиге» |
| `POST /api/dns/auto` | `{auto: bool}` — Switch automatically на ходу, без переподключения (выкл — первый сервер сразу) → status |
| `POST /api/killswitch` | `{killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?}` — сменить на ходу, без переподключения → status |
| `POST /api/sysproxy/release` | вернуть системный прокси сейчас (Disable sys proxy при down / Remove при блоке) → status |
| `POST /api/retry` | перезапустить sing-box сейчас, не дожидаясь паузы → status |
| `POST /api/auto` | `{auto}` — новые настройки Auto mode (как `plan.auto`) работающему AutoService, без переподключения → status |
| `POST /api/disconnect`, `GET /api/status` | status: `{connected, systemProxy, error, warning, exit, recovering, down, blocking, restarts, auto, sourcesRev}` — `connected` true и пока sing-box перезапускается (`recovering: {attempt, code, next}`, `down: {since, attempt, proxy: 'kept'\|'removed'\|'released'}` — после 30 с; null, когда нет), `blocking: {since, reason: 'disconnect'\|'closed', proxy: 'kept'\|'released'}` — не подключено, прокси оставлен kill switch'ем (см. «Падение sing-box», «Kill switch»); `auto` см. ниже; `sourcesRev` растёт, когда ядро само обновило подписку в снимке (или записало `lastError` неудачного обновления) |
| `GET /api/log?since=N` | `{lines:[{n, t, src: "sing-box" или "core", lvl: debug/info/warn/error, msg}], next}` — строки с номером ≥ N (без `since` — все хранимые, последние 2000); UI опрашивает с `next` прошлого ответа. `DELETE /api/log` — очистить (нумерация продолжается) |
| `GET /api/events?since=N` | `{events:[…], next, first}` — журнал событий (ниже): события с `id ≥ N`, старые первыми; без `since` — последние 200. `next` — id следующего события, `first` — id самого старого из хранимых (пропуск между своим `next` и `first` = журнал обрезан или очищен). `POST /api/events` `{cat, type, level, own?, data?}` → `{id}` — событие, которое первым узнал UI (400 с причиной, если форма не та: неизвестные `cat` / `level`, `type` не `[A-Za-z][A-Za-z0-9_]{0,47}`, `own` не bool, `data` не объект или больше 4096 знаков JSON); к такому событию `log` не привязывается. `DELETE /api/events` — очистить (нумерация продолжается) |
| `GET /api/version` | `{core, singBox, dataDir, dart, os}` — Settings → Data → About |
| `POST /api/node` | `{protocol, address, port, secret, name, outbound?, unsupported?}` → `{node}`; ошибка формы — 400 `{error}` с текстом для пользователя |
| `POST /api/share` | `{outbound, name, flag, unsupported?}` → `{link}` (null — у сервера нет формы ссылки) |
| `DELETE /api/connections`, `DELETE /api/connections/{id}` | закрыть все / одно соединение (API service sing-box); без подключения `{ok:false}` |
| `GET /api/traffic` | `{running, down, up (Б/с), downTotal, upTotal, tcp, udp, conns:[{id, host, port, net, rule, out, process, down, up, downRate, upRate, start}]}` — см. ниже |
| `POST /api/exit` | перепроверить выход туннеля; результат — в `status.exit` |
| `POST /api/speedtest` | `{node:{key, outbound}}` или `{pair:{key, entry, exit}}`, `configUrl?` → поток NDJSON по ходу замера: `{phase (0 задержка, 1 загрузка, 2 отдача, 3 готово), down, up (бит/с), downRpm, upRpm, latency (мс), elapsed, final}`, последняя строка `final: true` (при сбое с `error`). Отдельный sing-box с одним сервером, network quality test sing-box (серверы Apple mensura, если не задан `configUrl`); закрыли страницу/лист — замер останавливается |
| `POST /api/ping` | `{nodes:[{key, outbound}], pairs:[{key, entry, exit}]}` → поток NDJSON: строка `{kind:"n" или "p", key, ms}` на каждый результат сразу по готовности (-1 = нет ответа), в конце `{done:true}` или `{error}`. Замеры идут в порядке списка (32 параллельно); UI шлёт ноды по кэшу: живые, неизмеренные, мёртвые |

`status.auto` (пока подключено; `null` — нет): `{now: id маршрута, index, server, entryServer
(цепочка), routes: [{id, ms, fails, oks, at, strikes, holdUntil}], members: [{key, ms, fails, oks,
at}], switches, switchedAt, lastSwitch: {route?, from, to, reason: 'failover' | 'back', at}, unstable
(счёт), lastUnstable: {id, strikes, hold (мс), at}, noNet, stalledClosed, checkedAt}`. `holdUntil` —
когда запись на испытательном сроке сможет забрать трафик, если продолжит отвечать.
`ms`: −1 таймаут, −2 не мерили; `members` — все замеренные серверы (UI кладёт в кэш пингов);
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
`probe-in` (32 параллельно, таймаут 5 с), пары entry→exit — копия выхода с detour на копию
входа. Auto: `probe-in` рабочего конфига; urltest-группы Fastest внутри sing-box по-прежнему
выбирают по своему замеру (относительный порядок тот же).

Exit IP (`exitip.dart`): после каждого (пере)подключения и по запросу ядро спрашивает
через свой mixed-порт сразу несколько сервисов (`exitProbes`) на разной инфраструктуре,
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
Процесс (`process`) — `route.find_process`. UI опрашивает
раз в секунду, пока подключено и страница видна: карточки Speed / This session /
Connections и лист Live connections (новые сверху: хост:порт, TCP/UDP, вход → выход,
правило, приложение, скорость, объём, возраст). Без подключения скорость и соединения — 0,
итоги прошлой сессии остаются. В листе — фильтр (хост, приложение, правило, сервер), × на
строке закрывает соединение, Close all — все (`DELETE /api/connections[/id]` → `CloseConnection` /
`CloseAllConnections`; приложение обычно тут же открывает новое).

Лог (`logbook.dart`): вывод sing-box (уровень `info`, со временем) и заметки самого ядра
(подключено / отключено / не подключилось, предупреждение системного прокси, упавшие
`/api`-запросы) — одна нумерованная очередь. Префикс даты sing-box срезается, уровень
(TRACE/DEBUG → debug, WARN → warn, ERROR/FATAL/PANIC → error) — отдельным полем; строки
рантайма `[jormd] …` считаются строками ядра.

Журнал событий (`eventbook.dart`, `EventBook`) — «что произошло», структурно: вкладка
Logs → Events и все уведомления делаются из него; сырой лог выше остаётся как есть (вкладка
Raw). Событие:

```
{ id,        // растёт на 1, не откатывается: ни после рестарта, ни после очистки
  at,        // мс с эпохи
  cat,       // conn | auto | site | sub | rules | dns | core | user
  type, level: 'info' | 'warn' | 'error',
  own,       // true = причина — действие самого пользователя: уведомления нет
  log?,      // номер строки LogBook, записанной в тот же момент (переход в Raw)
  data }     // только поля, без готовой фразы: текст и язык — дело приложения
```

Хранится в `<dataDir>/events.jsonl` (JSON Lines): последние 7 суток и не больше 1000
событий, обрезка при старте и при каждой записи; при обрезке и очистке файл переписывается
целиком, первой строкой `{"seq": N}` — по ней id продолжаются, даже когда событий не осталось.
Битая строка (запись оборвалась на сбое) пропускается. Ошибка записи на диск до вызывающего
не доходит (журнал остаётся в памяти). Ядро пишет сначала строку в сырой лог, потом событие —
`log` указывает на неё.

Что и где пишет ядро (`cat/type`, уровень, `data`):

| событие | когда | `data` |
|---|---|---|
| `conn/connected` info | подключились (`own: true`, если по команде пользователя; `false` — переподключение ядра за докачанными списками) | `{entry, server?, mode: 'proxy', route: 'global'\|'rules'}` — `server` только если он уже известен (у Fastest его выбирает urltest позже); `mode: 'tun'`, когда TUN появится |
| `conn/connectFailed` error | подключение не вышло | `{reason}` |
| `conn/disconnected` info / error | `by: 'user'` — по команде (`own: true`, пишется, только если было подключено); `by: 'error'` — sing-box не поднялся после всех попыток | `{by, reason?}` |
| `conn/lost` warn | Auto: ни один маршрут не отвечает (`noNet` стал true из-за проверок) | `{}` |
| `conn/restored` info | `noNet` снова false | `{downMs}` |
| `conn/offline` warn / `conn/online` info | у ОС нет сети — по строке sing-box `missing default interface` / `updated default interface` (пока подключено) | `{}` / `{downMs}` |
| `auto/switched` info | Auto переключил маршрут (без `route`) или Priority-сервер внутри маршрута (`route` есть) | `{route?, from, to, reason: 'failover'\|'back'}` |
| `auto/fastest` info | Fastest сам сменил сервер (urltest внутри sing-box) | `{route, from, to}` |
| `auto/unstable` warn | маршрут падает снова и снова (flap guard) | `{id, strikes, holdMs}` |
| `site/blocked` warn | сайт не открывается через сервер, но открывается через другой маршрут (кнопка Rule) | `{host, port?, entry, server, dest, via}` |
| `sub/updated` info | автообновление по таймеру ядра изменило список серверов (без изменений — события нет) | `{source, name, added, removed, total}` |
| `sub/failed` error | автообновление не вышло — только первый сбой после удачного (пока на карточке висит `lastError`, повторы молчат) | `{source, name, error}` |
| `rules/fallback` warn | цель правил перестала отвечать, их трафик ушёл на запасной выход («If unavailable»); одно событие на пару цель + запасной выход | `{rule, more?, target, to: 'block'\|'direct'\|'main'}` — `rule`: имя первого правила (приложения — его id, безымянного — `rule <id>`), `more` — сколько ещё правил / приложений через тот же selector |
| `rules/targetBack` info | цель снова отвечает, трафик вернулся | `{rule, more?, target}` |
| `dns/switched` info | DNS-сервер в работе сменился (Switch automatically); `own: true` при `reason: 'off'` | `{from, to, reason: 'failover'\|'back'\|'off'}` — id серверов из UI |
| `rules/ruleSetFailed` warn | скачивание списка не удалось (не чаще, чем раз в `retryAfter` = 5 мин на список) | `{tag, url, error}` — `url` последний из пробованных |
| `rules/ruleSetUpdated` info | старая копия списка заменена новой, или список скачан после сбоя (первая закачка отсутствующего списка — не новость) | `{tag}` |
| `core/crashed` error | sing-box вышел сам (перезапуск идёт в фоне; уведомление — по решению UI) | `{code}` |
| `core/down` error | перезапуск не удался за 30 с от падения (см. «Down») | `{proxy: 'kept'\|'removed'\|'released'}` |
| `core/restarted` info | после падения запущен снова | `{attempt, downMs?}` — `downMs` (мс от падения) только если успел быть down |
| `core/restartFailed` error | попытка перезапуска не удалась (только первые три) | `{attempt, error}` |
| `core/sysProxy` info / warn | системный прокси включён / возвращён (`own: true` при команде пользователя); при остановке jormd тоже; `warn` — не вышло. Прокси, оставленный kill switch'ем, события не пишет | `{on, by?, error?}`, `on` — что хотели получить; `by: 'user'` — кнопка Remove / Disable sys proxy (`POST /api/sysproxy/release`) |
| `core/deprecated` warn | sing-box сообщил, что конфиг перестанет работать в новой версии; каждый текст — раз за запуск демона (в сыром логе — при каждом подключении) | `{text}` |

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

Системный прокси ставит ядро через реестр (HKCU Internet Settings), не sing-box: при
убитом процессе sing-box не вернул бы настройки. Прежние значения сохраняются и
возвращаются при отключении, при остановке и при следующем старте после сбоя (kill switch может
оставить прокси на месте — «Kill switch»; при падении sing-box прокси не снимается). PAC (AutoConfigURL,
типично для корпоративной сети) Windows спрашивает раньше ручного прокси — ядро
предупреждает.

Подписки (`fetch.dart`, `updater.dart`, `state.dart`): загрузка с UA-стратегией, фильтром,
HWID (`device.dart`) и каналом Direct / Proxy; автообновление по таймеру ядра прямо в снимке
`ui-state.json` (доступ к снимку — через `SnapshotStore`, одна очередь на чтение и запись).
Правила и конфликты с UI — subscription-parsing.md → «Автообновление».

## Не сделано в MVP

TUN (и kill switch для него; для системного прокси он есть, см. «Kill switch»); Hijack DNS / FakeIP; обновление гео-списков по таймеру; Decrypt
password подписки (нет спецификации); автовыбор URL пинга (сейчас — выбор в Settings →
Connection, по умолчанию gstatic).
Auto: проверка по неудачным запросам, `speedOnFail`, пауза при выключенном экране; группы
целей правил AutoService не ведёт (их Priority меняется только новым планом), за целями следит
`FallbackService` («If unavailable» на лету), но и он Priority не двигает. Переключение DNS не
меняет `default_domain_resolver`; в `status.auto` нет состояния целей правил (только события
`rules/fallback` / `rules/targetBack`).
