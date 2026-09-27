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

Прокси: mixed (HTTP + SOCKS5) на `127.0.0.1:<mixedPort>` (Settings → Connection → Proxy port, по умолчанию 2080). Clash API основного процесса —
`127.0.0.1:9090`. TUN в MVP нет: переключатель TUN подключает как прокси с предупреждением.

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
  auto: { failAfter, threshold, checkEvery, keepWarm, standby },
  routing: Routing }       // правила, приложения, быстрые правила, DNS — ниже
Route = { id, kind: 'unit' | 'chain', main: Group, entry?: Group }   // entry — вход цепочки, выход идёт через него (detour)
Group = { pick: 'fastest' | 'priority', chosen: 'sid::nid' | null, pinned?: true, nodes: [{ key: 'sid::nid', outbound }] }
```

- Маршруты: в Auto — все записи Auto выше якоря, якорь и `standby` записей ниже; в Manual —
  только якорь. Записи без пригодных серверов пропускаются. План без `routes` (старый вид:
  `kind/main/entry` сверху) = один маршрут.
- Теги (`plan.dart`): маршрут i — группа `route<i>` (у цепочки выход `route<i>` с detour на
  `route<i>-entry`), сервер — `route<i>/<sid::nid>`; над маршрутами `selector` `proxy`
  (`default` = `current`, `interrupt_exist_connections`), `route.final = proxy`.
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
- Подключено и план изменился — UI сам переподключает. Сравнивается состав: маршруты (в Auto —
  окно вокруг якоря, с которым подключались, пока он в Auto), серверы групп (у Fastest — без
  порядка, и в маршрутах, и в целях правил), закреп Manual, правила, Global/Rules, системный
  прокси, настройки Auto. Не сравниваются порядок по пингу, `chosen` групп маршрутов и
  `current`: пинг и переключения AutoService — не повод рвать соединения. `chosen` цели правила
  сравнивается: её Priority никто, кроме нового плана, не двигает. Пока идёт пинг, проверка
  ждёт его конца.

## Auto в ядре (`auto.dart`)

`AutoService(ClashApi, plan)` — чистый Dart без UI: демон держит его, пока подключено
(Flutter возьмёт как есть). Раунд — через `checkEvery` (первый через 3 с; пока текущий
маршрут не отвечает — каждые 10 с):

1. `/proxies` — на каких серверах стоят группы. Clash API молчит — раунд ничего не решает.
2. Замер сервера, на котором стоит группа (probe, см. «Пинг» ниже): текущий маршрут, все
   выше него, при `keepWarm` ещё `standby` ниже (параллельно). Цепочка: вход, потом выход
   (его замер идёт через вход и в `members` не попадает).
   - Fastest: сервер молчит → `/group/<tag>/delay`: urltest перемеряет всех и сразу берёт
     живой; не ответившие — тоже таймауты.
   - Priority: `failAfter` таймаутов подряд → первый ответивший по порядку (пачки по 8),
     `PUT /proxies/<группа>`; сервер выше текущего ответил `failAfter` раз подряд и не
     медленнее больше чем на `threshold` → обратно на него.
3. Маршруты: у текущего `failAfter` таймаутов подряд → `PUT /proxies/proxy` на первый по
   приоритету ответивший (не мерянные в раунде проверяются по одному); не ответил никто —
   `allDown`. Возврат выше — по тому же правилу, что у Priority.

Настройки — `plan.auto` (URL — `urlTest.url`), `checkEvery` 10–3600 с. Тесты: `auto_test.dart`
(фейковый Clash API из того же `buildConfig`), `auto_singbox_test.dart` (настоящий sing-box
на loopback: переключение без перезапуска, цепочка, urltest, падение процесса). Системный
прокси в тестах — фейк (`Daemon(sysProxy: …)`): реестр тесты не трогают.

Clash API: случайный секрет на каждый запуск sing-box (`clash_api.secret`), все вызовы ядра
идут с `Authorization: Bearer`; без него — 401, чужая программа туннель не переключит.

Падение sing-box (процесс вышел сам, не наш stop): ядро сразу возвращает системный прокси,
затем перезапускает sing-box с тем же планом на маршруте, где был Auto — паузы 1 / 4 / 15 с,
счёт попыток сбрасывается после минуты работы. Перезапуск идёт тем же путём, что connect
(`_startSingBox`: списки правил, новый `tunnel-in`, предупреждения сборки; потом фоновое
обновление списков). Пока перезапускает — `connected: true`, `recovering: {attempt, of, code,
next}`; удалось — `restarts` +1, `warning`, системный прокси снова включён (если был), новый
AutoService; три неудачи — отключено, `error`. Фоновая докачка списков, требующая
переподключения, тоже встаёт на маршрут, где был Auto.

## Правила в конфиге

`routing` (`js/93-routing-plan.js` → `core/lib/src/routing.dart`; логика — `rules.md`):

```
{ apps:  [{ id, kind: 'package'|'process'|'path', act, target, split, udpTarget }],
  rules: [{ id, name, action, target, fallback, block, dns, groups, composite?, extra? }],
  quick: { lan, ads, region: 'RU'|…|null, services: { telegram: 'vpn'|'direct', … }, final },
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
  Clash API переживает перезапуск, новый выбор из UI — нет.
- Сравнение планов для переподключения нормализует и цели правил (порядок Fastest после
  пинга — не изменение).

## API (`jormd`)

Только `127.0.0.1`; каждый `/api`-запрос с заголовком `X-Jorm: 1` (чужие страницы не
пройдут CORS preflight) и loopback-Host.

| | |
|---|---|
| `GET /` | мокап, с `window.JORMD = true` → live-режим (`95-live.js`) |
| `GET/PUT /api/state` | снимок состояния UI / статус |
| `POST /api/sources/fetch` | `{sid, source:{url, userAgent, uaStrategy, discoveredAt, nodes, gone, hwid, filter, channel}, rediscover}` → `{patch, title, notModified, via}`; `patch` — серверные поля источника (`nodes`, `gone`, `count`, `uaStrategy`, `discoveredAt`, `usage`, `expire`, `format`, `providerInterval`, `webPage`, `supportUrl`, `announce`, `updatedAt`), UI кладёт их в источник как есть. См. subscription-parsing.md |
| `POST /api/parse` | `{text}` → ноды из ссылок |
| `POST /api/connect` | `{plan, systemProxy}` |
| `POST /api/disconnect`, `GET /api/status` | status: `{connected, systemProxy, error, warning, exit, recovering, restarts, auto, sourcesRev}` — `auto` см. ниже; `sourcesRev` растёт, когда ядро само обновило подписку в снимке (или записало `lastError` неудачного обновления) |
| `GET /api/log?since=N` | `{lines:[{n, t, src: "sing-box" или "core", lvl: debug/info/warn/error, msg}], next}` — строки с номером ≥ N (без `since` — все хранимые, последние 2000); UI опрашивает с `next` прошлого ответа. `DELETE /api/log` — очистить (нумерация продолжается) |
| `GET /api/version` | `{core, singBox, dataDir, dart, os}` — Settings → Data → About |
| `POST /api/node` | `{protocol, address, port, secret, name, outbound?, unsupported?}` → `{node}`; ошибка формы — 400 `{error}` с текстом для пользователя |
| `POST /api/share` | `{outbound, name, flag, unsupported?}` → `{link}` (null — у сервера нет формы ссылки) |
| `DELETE /api/connections`, `DELETE /api/connections/{id}` | закрыть все / одно соединение (clash API sing-box, с её секретом); без подключения `{ok:false}` |
| `GET /api/traffic` | `{running, down, up (Б/с), downTotal, upTotal, tcp, udp, conns:[{id, host, port, net, rule, out, process, down, up, downRate, upRate, start}]}` — см. ниже |
| `POST /api/exit` | перепроверить выход туннеля; результат — в `status.exit` |
| `POST /api/ping` | `{nodes:[{key, outbound}], pairs:[{key, entry, exit}]}` → поток NDJSON: строка `{kind:"n" или "p", key, ms}` на каждый результат сразу по готовности (-1 = нет ответа), в конце `{done:true}` или `{error}`. Замеры идут в порядке списка (32 параллельно); UI шлёт ноды по кэшу: живые, неизмеренные, мёртвые |

`status.auto` (пока подключено; `null` — нет): `{now: id маршрута, index, server, entryServer
(цепочка), routes: [{id, ms, fails, oks, at}], members: [{key, ms, fails, oks, at}], switches,
switchedAt, lastSwitch: {route?, from, to, reason: 'failover' | 'back', at}, allDown, checkedAt}`.
`ms`: −1 таймаут, −2 не мерили; `members` — все замеренные серверы (UI кладёт в кэш пингов);
`switches` — счёт переключений маршрутов и Priority-серверов (`lastSwitch.route` есть у второго,
тогда `from`/`to` — ключи серверов). UI опрашивает status раз в 4 с.

Пинг (`probe.dart`): ядро меряет само, через loopback SOCKS5-inbound конфига `probe-in` —
имя пользователя = тег outbound'а (правило `auth_user` → этот outbound, первым в route),
пароль случайный на каждый старт. Два `HEAD` к тест-URL по одному соединению, результат —
время второго: один проход туда-обратно по всему пути, без рукопожатий (как Karing /
«unified delay» mihomo). Clash API `/proxies/{tag}/delay` sing-box считает первый запрос с
рукопожатиями — через мост (RU → EU, мост открывает своё соединение дальше) это в 3–4 раза
больше (замер 2026-09-27: 210–290 мс против 64–90 у Karing и у нас сейчас). Сервер закрыл
соединение после первого ответа → время первого. Каталог: временный sing-box только с
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

Трафик (`traffic.dart`, `TrafficMeter`): clash API sing-box `/connections` даёт счётчики
байт и группы соединения (`chains`); реальный сервер — `now` групп из `/proxies`
(`route<i>/<sid::nid>`; у цепочки ещё `route<i>-entry/<sid::nid>`; у цели правила `<цель>/…` и `<цель>>entry/…`; в `out` выход первым).
Скорость — разница счётчиков между двумя опросами (любая частота опроса; перезапуск
sing-box не даёт отрицательных). Процесс (`process`) — `route.find_process`. UI опрашивает
раз в секунду, пока подключено и страница видна: карточки Speed / This session /
Connections и лист Live connections (новые сверху: хост:порт, TCP/UDP, вход → выход,
правило, приложение, скорость, объём, возраст). Без подключения скорость и соединения — 0,
итоги прошлой сессии остаются. В листе — фильтр (хост, приложение, правило, сервер), × на
строке закрывает соединение, Close all — все (`DELETE /api/connections[/id]` → clash API
`DELETE /connections[/{id}]`; приложение обычно тут же открывает новое).

Лог (`logbook.dart`): вывод sing-box (уровень `info`, со временем) и заметки самого ядра
(подключено / отключено / не подключилось, предупреждение системного прокси, упавшие
`/api`-запросы) — одна нумерованная очередь. Префикс даты sing-box срезается, уровень
(TRACE/DEBUG → debug, WARN → warn, ERROR/FATAL/PANIC → error) — отдельным полем; строки
рантайма `[jormd] …` считаются строками ядра.

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
возвращаются при отключении и при следующем старте после сбоя. PAC (AutoConfigURL,
типично для корпоративной сети) Windows спрашивает раньше ручного прокси — ядро
предупреждает.

Подписки (`fetch.dart`, `updater.dart`, `state.dart`): загрузка с UA-стратегией, фильтром,
HWID (`device.dart`) и каналом Direct / Proxy; автообновление по таймеру ядра прямо в снимке
`ui-state.json` (доступ к снимку — через `SnapshotStore`, одна очередь на чтение и запись).
Правила и конфликты с UI — subscription-parsing.md → «Автообновление».

## Не сделано в MVP

TUN и kill switch; Hijack DNS / FakeIP; «If unavailable» на лету и автопереключение DNS
(сейчас — при сборке конфига / переподключении); обновление гео-списков по таймеру; Decrypt
password подписки (нет спецификации); автовыбор URL пинга (сейчас — выбор в Settings →
Connection, по умолчанию gstatic).
Auto: проверка по неудачным запросам, `speedOnFail`, пауза при выключенном экране; группы
целей правил AutoService не ведёт (их Priority меняется только новым планом).
