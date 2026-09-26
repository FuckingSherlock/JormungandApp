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
| Что подключать сейчас (entry, ноды, fastest/priority) | решает → «план» | — |
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
`n` + 12 hex от sha256(`protocol|address|port|identity`) — одинаков для одного сервера в
любом формате подписки (см. subscription-parsing.md → Дедупликация). `outbound` — готовый
sing-box outbound без тега. Флаг вынимается из имени (первая пара regional indicators).

## План подключения

UI собирает из `effectiveConnectId()`:

```
{ kind: 'unit' | 'chain',
  main:  Group,            // юнит, или выход цепочки
  entry: Group,            // только цепочка: выход идёт через неё (detour)
  mixedPort: 2080, global: bool,
  urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold,
             url: connCfg.testUrl /* нет — gstatic */ } }
Group = { pick: 'fastest' | 'priority', chosen: 'sid::nid' | null, nodes: [{ key: 'sid::nid', outbound }] }
```

- `fastest` → `urltest` (interval/tolerance из Auto mode); `priority` → `selector` с
  выбранным UI сервером. failAfter / standby — дело AutoService приложения, не ядра.
- `urltest` до конца своего первого круга замеров (со сотней серверов — около минуты) шлёт
  всё через первый сервер списка. Поэтому для `fastest` UI передаёт ноды по известному пингу:
  живые по возрастанию, потом неизмеренные, мёртвые в конце.
- Режим Rules в MVP: только приватные адреса напрямую, всё остальное — в прокси.
  Global — всё в прокси. Экран Rules пока в конфиг не попадает.
- Подключено и план изменился (другой entry, сервер выключен, Global/Rules, системный
  прокси) — UI сам переподключает. Сравнивается состав групп и выбор, а не порядок: пинг
  переставляет Fastest и помечает серверы «testing» — это не повод рвать соединения; пока
  идёт пинг, проверка ждёт его конца.

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
| `POST /api/disconnect`, `GET /api/status` | status: `{connected, systemProxy, error, warning, exit}` |
| `GET /api/log?since=N` | `{lines:[{n, t, src: "sing-box" или "core", lvl: debug/info/warn/error, msg}], next}` — строки с номером ≥ N (без `since` — все хранимые, последние 2000); UI опрашивает с `next` прошлого ответа. `DELETE /api/log` — очистить (нумерация продолжается) |
| `GET /api/version` | `{core, singBox, dataDir, dart, os}` — Settings → Data → About |
| `POST /api/node` | `{protocol, address, port, secret, name, outbound?, unsupported?}` → `{node}`; ошибка формы — 400 `{error}` с текстом для пользователя |
| `POST /api/share` | `{outbound, name, flag, unsupported?}` → `{link}` (null — у сервера нет формы ссылки) |
| `DELETE /api/connections`, `DELETE /api/connections/{id}` | закрыть все / одно соединение (clash API sing-box); без подключения `{ok:false}` |
| `GET /api/traffic` | `{running, down, up (Б/с), downTotal, upTotal, tcp, udp, conns:[{id, host, port, net, rule, out, process, down, up, downRate, upRate, start}]}` — см. ниже |
| `POST /api/exit` | перепроверить выход туннеля; результат — в `status.exit` |
| `POST /api/ping` | `{nodes:[{key, outbound}], pairs:[{key, entry, exit}]}` → поток NDJSON: строка `{kind:"n" или "p", key, ms}` на каждый результат сразу по готовности (-1 = нет ответа), в конце `{done:true}` или `{error}`. Замеры идут в порядке списка (32 параллельно); UI шлёт ноды по кэшу: живые, неизмеренные, мёртвые |

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
байт и только группу соединения (`chains: ["proxy"]`); реальный сервер — `now` группы из
`/proxies` (`proxy/<sid::nid>`; у цепочки ещё `entry/<sid::nid>`, в `out` выход первым).
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
Нет ссылки у socks/http/wireguard из подписок и у `unsupported`-нод (их outbound без
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

## Не сделано в MVP

TUN и kill switch; правила, DNS и rule-sets из `rules.md` в конфиге; каналы загрузки
подписки (Direct first и т.п. — сейчас всегда напрямую, с учётом `HTTP(S)_PROXY`);
фильтр подписки, HWID; автообновление подписок по таймеру; автовыбор URL пинга (сейчас —
выбор в Settings → Connection, по умолчанию gstatic).
