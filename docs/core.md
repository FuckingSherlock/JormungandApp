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

Во Flutter-приложении колонка «Мокап» станет Dart-кодом приложения, API уйдёт — сервисы
будут вызывать ядро напрямую.

## Нода

`{id, name, flag, protocol, address, port, outbound, unsupported?}`. `id` =
`n` + 12 hex от sha256(`protocol|address|port|identity`) — одинаков для одного сервера в
любом формате подписки (см. subscription-parsing.md → Дедупликация). `outbound` — готовый
sing-box outbound без тега. Флаг вынимается из имени (первая пара regional indicators).

## План подключения

UI собирает вокруг записи-якоря (своя догадка `effectiveConnectId(true)`: верхняя запись
Auto, которая может работать; в Manual — закреплённая; `94-live-auto.js`):

```
{ routes: [Route],         // по приоритету Route
  current: 1,              // индекс якоря: с него стартует selector
  mixedPort: 2080, global: bool,
  urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold },
  auto: { failAfter, threshold, checkEvery, keepWarm, standby } }
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
- Режим Rules в MVP: только приватные адреса напрямую, всё остальное — в прокси.
  Global — всё в прокси. Экран Rules пока в конфиг не попадает.
- Подключено и план изменился — UI сам переподключает. Сравнивается состав: маршруты (в Auto —
  окно вокруг якоря, с которым подключались, пока он в Auto), серверы групп (у Fastest — без
  порядка), закреп Manual, Global/Rules, системный прокси, настройки Auto. Не сравниваются
  порядок по пингу, `chosen` и `current`: пинг и переключения AutoService — не повод рвать
  соединения; пока идёт пинг, проверка ждёт его конца.

## Auto в ядре (`auto.dart`)

`AutoService(ClashApi, plan)` — чистый Dart без UI: демон держит его, пока подключено
(Flutter возьмёт как есть). Раунд — через `checkEvery` (первый через 3 с; пока текущий
маршрут не отвечает — каждые 10 с):

1. `/proxies` — на каких серверах стоят группы. Clash API молчит — раунд ничего не решает.
2. Замер `/proxies/<сервер>/delay` сервера, на котором стоит группа: текущий маршрут, все
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
счёт попыток сбрасывается после минуты работы. Пока перезапускает — `connected: true`,
`recovering: {attempt, of, code, next}`; удалось — `restarts` +1, `warning`, системный прокси
снова включён (если был), новый AutoService; три неудачи — отключено, `error`.

## API (`jormd`)

Только `127.0.0.1`; каждый `/api`-запрос с заголовком `X-Jorm: 1` (чужие страницы не
пройдут CORS preflight) и loopback-Host.

| | |
|---|---|
| `GET /` | мокап, с `window.JORMD = true` → live-режим (`95-live.js`) |
| `GET/PUT /api/state` | снимок состояния UI / статус |
| `POST /api/sources/fetch` | `{url, userAgent, strategy, discoveredAt, prev:{nodes, gone}}` → ноды, gone, strategy, usage, expire, title |
| `POST /api/parse` | `{text}` → ноды из ссылок |
| `POST /api/connect` | `{plan, systemProxy}` |
| `POST /api/disconnect`, `GET /api/status`, `GET /api/log` | status: `{connected, systemProxy, error, warning, exit, recovering, restarts, auto}` — `auto` см. ниже |
| `GET /api/traffic` | `{running, down, up (Б/с), downTotal, upTotal, tcp, udp, conns:[{id, host, port, net, rule, out, process, down, up, downRate, upRate, start}]}` — см. ниже |
| `POST /api/exit` | перепроверить выход туннеля; результат — в `status.exit` |
| `POST /api/ping` | `{nodes:[{key, outbound}], pairs:[{key, entry, exit}]}` → поток NDJSON: строка `{kind:"n" или "p", key, ms}` на каждый результат сразу по готовности (-1 = нет ответа), в конце `{done:true}` или `{error}`. Замеры идут в порядке списка (32 параллельно); UI шлёт ноды по кэшу: живые, неизмеренные, мёртвые |

`status.auto` (пока подключено; `null` — нет): `{now: id маршрута, index, server, entryServer
(цепочка), routes: [{id, ms, fails, oks, at}], members: [{key, ms, fails, oks, at}], switches,
switchedAt, lastSwitch: {route?, from, to, reason: 'failover' | 'back', at}, allDown, checkedAt}`.
`ms`: −1 таймаут, −2 не мерили; `members` — все замеренные серверы (UI кладёт в кэш пингов);
`switches` — счёт переключений маршрутов и Priority-серверов (`lastSwitch.route` есть у второго,
тогда `from`/`to` — ключи серверов). UI опрашивает status раз в 4 с.

Пинг: временный sing-box без inbound'ов, задержка через clash API
`/proxies/{tag}/delay` (32 параллельно, таймаут 5 с). Пары entry→exit — копия выхода с
detour на копию входа.

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
(`route<i>/<sid::nid>`; у цепочки ещё `route<i>-entry/<sid::nid>`, в `out` выход первым).
Скорость — разница счётчиков между двумя опросами (любая частота опроса; перезапуск
sing-box не даёт отрицательных). Процесс (`process`) — `route.find_process`. UI опрашивает
раз в секунду, пока подключено и страница видна: карточки Speed / This session /
Connections и лист Live connections (новые сверху: хост:порт, TCP/UDP, вход → выход,
правило, приложение, скорость, объём, возраст). Без подключения скорость и соединения — 0,
итоги прошлой сессии остаются.

Системный прокси ставит ядро через реестр (HKCU Internet Settings), не sing-box: при
убитом процессе sing-box не вернул бы настройки. Прежние значения сохраняются и
возвращаются при отключении и при следующем старте после сбоя. PAC (AutoConfigURL,
типично для корпоративной сети) Windows спрашивает раньше ручного прокси — ядро
предупреждает.

## Не сделано в MVP

TUN и kill switch; правила, DNS и rule-sets из `rules.md` в конфиге; каналы загрузки
подписки (Direct first и т.п. — сейчас всегда напрямую, с учётом `HTTP(S)_PROXY`);
фильтр подписки, HWID; автообновление подписок по таймеру; пинг выбирает URL автоматически
(сейчас всегда gstatic). Auto: проверка по неудачным запросам, `speedOnFail`, пауза при
выключенном экране.
