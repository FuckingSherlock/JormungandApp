# Логи, события, отчёт

Как устроены журналы ядра и что из них собирается в отчёт для разработчика. Код: `core/lib/src/logbook.dart`
(сырой лог), `eventbook.dart` (события), `log_view.dart` (модель вкладки Logs, каталог событий),
`report.dart` (отчёт), `redact.dart` (маскирование секретов). Экран Logs в приложении и мокапе — в конце файла.

## Сырой лог: два кольца

`LogBook` хранит строки sing-box и собственные заметки ядра (`src: sing-box | core`) одной нумерованной
последовательностью `{n, t, src, lvl, msg}` (`lvl`: debug / info / warn / error). Номера только растут, Clear
очищает кольца, нумерация продолжается.

Два кольца, чтобы поток успешных соединений не вытеснял остальное:

| Кольцо | Размер | Что в нём |
|---|---|---|
| основное (`cap`) | 5000 | всё, кроме «шума»: заметки ядра, предупреждения и ошибки sing-box, служебные строки |
| шум (`noiseCap`) | 500 | успешные соединения (`inbound/… connection`, `outbound/… connection`, `packet connection`), строки `router: found package name: …` / `found process path: …`, и упавшие соединения **игнорируемых сайтов** (`IgnoredSites`) |

Классификация шквальных строк (`logbook.dart`): соединения — `connLineRe` (включая multiplex, UoT, DNS packet,
`[user]`; **теги серверов содержат `::`**, например `outbound/vless[route0-entry/src1::n3]: outbound connection
to …` — раньше такие строки не распознавались, забивали основное кольцо и игнорировали «Connections»);
`found package name` / `found user` / `found neighbor` (`foundLineRe`); ответы DNS уровня info
(`dns: exchanged|cached|optimistic|refreshed|lookup succeed for …`, `dnsLineRe`). Всё это — шум-кольцо и
скрыто при выключенном «Connections».

Решает `isNoiseLine(text)` (`logbook.dart`): предупреждение или ошибка никогда не шум (кроме строк игнорируемого
сайта — они в шум-кольце, но остаются предупреждениями). `found package name` — по одной строке на каждое
соединение, шквал одного приложения (Telegram) раньше занимал 79 % основного кольца.

Предупреждения и ошибки основного кольца дополнительно лежат в `problems.jsonl` (переживают перезапуск).
Строки шум-кольца на диск не пишутся.

### Свои проверки ядра в Raw

Проверки ядра (замеры Auto, «If unavailable», сайты, DNS, флаги) идут через служебный вход sing-box `probe-in`
(`probe.dart`, `probeInboundTag`), и его строки — не трафик пользователя и не настоящие сбои. `LogBook.singBox`
ставит на каждую такую строку метку: `[check]`, а если строка сама называет проверку (SOCKS-пользователь
`dns-check/<сервер>`, `flag-check/<сторона>`) — `[dns-check]` / `[flag-check]`. Строки, у которых метка уже есть
(пинг каталога: `[ping]`), не трогаются; обычные соединения пользователя — без метки. Метка — текст в начале
сообщения: строки по-прежнему идут через те же кольца и фильтры, ничего не скрывается и не сворачивается.

### Чтение: `since`, `conns`, `hidden`

`log({since, conns = true})` → `{lines, next, hidden?}`:

- `since` — номер, с которого отдавать (без него — всё, что держат кольца); `next` — номер следующей строки.
  Кольца склеиваются по номеру. Поиск начала — бинарный, цена ответа = размер ответа.
- `conns: false` (в jormd — `GET /api/log?conns=0`): шум-кольцо пропускается **на стороне ядра**; в ответе
  `hidden` = сколько строк шума (не предупреждений/ошибок) пропущено в **этом** ответе. Нумерация и `next`
  те же, поэтому «Connections» включённый позже догружается тем же `since`. Упавшие соединения игнорируемых
  сайтов (они в шум-кольце, но warn/error) приходят и при `conns: false`: их прячет переключатель
  «Ignored sites», а не «Connections».
- без `conns: false` ответ тот же, что был (поля `hidden` нет).
- Поток `logStream` (`LogBook.stream`) **не фильтруется**: отдаёт каждую строку, шум тоже. Подписчик,
  которому шум не нужен, отбрасывает его сам (`LogLine.isConn`).

Приложение: параметр проведён до хоста (`CoreHost.logPage({since, conns = true})` → `CoreApi.log`), опрос Raw
идёт с `conns: cfg.showConns` («Connections» выключен по умолчанию, строки `found package name` под ним же);
`hidden` показывается в строке состояния Raw, включение «Connections» — полный перезапрос (см. «Экран Logs»).

## События

`EventBook` — журнал структурированных записей `{id, at, cat, type, level, own, bg?, rev?, log?, data}`:
`data` — только поля, готовых фраз нет (текст — дело приложения, на языке пользователя); `log` — номер сырой
строки, записанной в тот же момент; `own` — действие пользователя; `bg` — случилось при погашенном экране.
Хранится 7 суток / 1000 штук, `events()` отдаёт хвост, `since` — с номера.

Событие, которое рассматривал `Sentinel`, несёт ещё `verdict` (`confirmed` / `blip` / `consequence` /
`workaround` / `unexplained`), `why` (`{code, params}`), `trail` (протокол проверок `[{code, params, outcome, at}]`)
и `cause` (id события-корня). Только коды и параметры; у остальных и у старых записей полей нет. Уведомляет
только `confirmed` без `cause`. Подробно — `docs/failures.md`.

### Каталог типов

Один каталог — `eventCats` в `log_view.dart` (порядок = порядок фильтра в Events). Категория `user`
(действия пользователя: `connect`, `disconnect`, `mode`, `route`, `sysProxy`, `pin`, …) в каталоге не
перечислена — это явный список-исключение сторожевого теста.

| cat | type | data |
|---|---|---|
| conn | connected | план подключения (режим, маршрут, сервер) |
| conn | disconnected | `by` |
| conn | connectFailed | `reason` |
| conn | lost / restored | `downMs?` — сеть пропала / вернулась на живом подключении |
| conn | offline / online | `downMs?` — нет интернета вообще / вернулся |
| conn | failing | соединения массово не удаются (детектор неудавшихся соединений, `failures.dart`) |
| auto | switched | `route?`, `from`, `to`, `reason` |
| auto | fastest | `route`, `from`, `to` |
| auto | unstable | `id`, `strikes`, `holdMs` |
| site | blocked | `host`, `entry`, … — не открывается на маршруте, открывается на другом |
| site | unreachable | `host`, `entry`, `check?` — не открылся нигде (+ результат чекера) |
| sub | updated | `source`, `name`, `added`, `removed`, `total` |
| sub | failed | `source`, `name`, `error` |
| sub | removed / back | `count`, `source`, `name` — серверы пропали из подписки / вернулись |
| sub | dead | только мокап (серверы подписки не отвечают); ядро и приложение его не пишут |
| rules | fallback / targetBack | `target`, `to?` — «If unavailable» сработал / цель вернулась |
| rules | ruleSetFailed | `tag`, `url`, `error` |
| rules | ruleSetUpdated | `tag` |
| dns | switched | `side` (`direct` / `vpn`), `from`, `to` (id кандидатов), `fromProvider`, `toProvider`, `reason` (`failover` — отвечавший упал, `back` — вернулся более приоритетный, `off` — выключили «Switch automatically»); `own` у `off`. На сторону, когда меняется её отвечающий кандидат |
| dns | failed | `server`, `path` (`direct` / `proxy`), `since`, `provider`, `side`, `servers` (id упавших транспортов) — DNS-сервер подтверждённо не отвечает (Sentinel, `dns.down`), причины выше нет. На провайдера и сторону: упал один транспорт, а провайдер на этой стороне ещё отвечает — только строка журнала |
| speed | done / failed | результат / `error` |
| core | crashed | `code` |
| core | restarted | `attempt`, `downMs?` |
| core | restartFailed | `attempt`, `error` |
| core | tunNeedsAdmin | `stage`, `error?` |
| core | down | `proxy` |
| core | sysProxy | `on`, `by?`, `error?` |
| core | deprecated | `text` |
| core | stateRestored / stateLost | `from`, `savedAt`, `reason`, `kept?` |
| core | updateAvailable | `version`, `build`, `channel`, `forced`, `via` |
| core | updateFailed | `stage` (check/download/verify/install), `code`, `error`, `attempts?` |
| core | updateChannelEmpty | `channel`, `attempts` |
| core | updateDownloaded | `version`, `build`, `size`, `via`, `delta?`, `downloaded?` |
| core | updateDeltaFailed | `code`, `error`, `from`, `attempts?` |
| core | updateInstalled | `from`, `to` |
| core | tunTcpDead / tunTcpBack | TCP через TUN не доходит до маршрутизации / снова идёт (детектор «осиротевших» SYN) |

(Поля `data` у `conn/failing`, `core/tunTcpDead`, `core/tunTcpBack` описывает `failures.dart`.)

**Строки журнала DNS-флагов** (основное кольцо ядра, `logBook.note`; события выше — только итог, ход дела — здесь):
- `dns flag: <кандидат> (<сторона>) on|off (<причина>): written to <файл>` — каждая запись флага (info; при старте
  sing-box — debug, по строке на кандидата). Причина: `verdict`, `back`, `auto off`, `connect`, `restart re-apply`,
  `adopt`. Не записался файл — error `… not written to <файл>: <ошибка>`; не удалось в исполнителе —
  warn `dns flag: <кандидат> stays on|off (<причина>): the write failed` (ничего не переключается).
- `dns flag check (<сторона>): <кандидат> answers after N ms (<почему>)` (info) — sing-box подхватил файл (flagcheck
  отвечает именем кандидата, что должен отвечать); `dns flag not applied after N s (<сторона>): expected X, Y answers`
  (warn) — не подхватил за `flagWait` (3 с); `… cannot be told, this sing-box has no flagcheck` (debug) — старый sing-box.
  Проверка идёт после записи, одна — после старта для обеих сторон.
- `dns <сторона>: A → B (failover|back|off)` (info) — смена отвечающего кандидата (рядом событие `dns/switched`).
- `dns <сторона>: answers <кандидат>; flags on [id мс, …]; off [id (down) …]` (debug) — по строке на сторону в каждом
  раунде проверок.
- `dns: <id> (<провайдер>, <сторона>) does not answer, its provider still does through …: not an event` (info) — упал
  один транспорт, события нет. `dns: switch automatically on|off …` (info) — переключатель; `dns: flags off again
  after the restart: …` (info) — перезапуск sing-box применил погашенные флаги заново.

**Строки журнала предрезолва адресов** (основное кольцо ядра, `logBook.note`; событий нет, `rules.md` §6):
- `address: N hosts for <причина>: K from the cache, M stale (refreshed in the background), …` (info) — итог
  подготовки списка имён; `address: config for <причина>: N of M hostnames pinned to an address …` (info) — что
  легло в конфиг и какие имена остались именами (резерв: домен + `domain_resolver`); `address: connect waited N ms (up to 1500 ms) for K hosts …` (info; warn, если часть не успела) — ожидание connect. Причина: `connect`, `reresolve`, `recover`, `node down`, `subscription update`, `ping`, `speed test`, суффиксы `, refresh` и `, background`.
- `address: <имя> → <IP…> via <сервер> (<метка>) in N ms [fresh, <причина>] (параллельный опрос: `[fresh, <причина>, parallel]`; поздний ответ — `answered late … not used`)` (info) — имя разрешено;
  `address: <имя> via <сервер> failed: <причина> (N ms), next` (info) — один сервер не ответил, пробуется
  следующий; `address: <имя>: <сервер> skipped (judged dead)` (info); `address: DoQ servers are not used …` (info,
  один раз).
- Не разрешилось: `address: <имя> not resolved by any server in N ms [<причина>]` (warn; «the cached address
  stays», если кэш есть), `address: <имя>: out of time (N ms), K servers not tried` (warn),
  `address: not everything resolved within 1500 ms for <причина>; the config keeps the names …` (warn — резерв
  на старое поведение для этих имён), `address: the saved DNS settings could not be read …` /
  `the addresses could not be prepared …` (warn — только системный резолвер / имена в конфиге).
- Сбой узла: `address: <имя> (<группа>/<узел> is down) on <IP>: another cached address <IP> is tried (N of M
  tried)` / `… every cached address was tried, looked up again` (info); `address: <имя>: the same addresses …
  (IP set unchanged): no restart` / `the addresses changed (… → …): restart` (info); `… not looked at now
  (network not up, core not settled or restarting)` (info); `address: restarting sing-box for <что>` и
  `restart for <что> skipped …` (info) — собственный перезапуск с причиной `reresolve` (не падение sing-box).

Уведомления (`eventNotifKind`): `conn/failing` → «Сайт не открывается» (`blocked`); `core/tunTcpDead` и
`core/tunTcpBack` → «Соединение потеряно» (`connLost`); события обновления приложения (`core/update*`)
не уведомляют — у обновления своя поверхность.

Фильтр Events в приложении: рядом с каждым типом — число событий этого типа в журнале (типы без
событий приглушены, но переключаются); категория, где есть события или выключенный тип, раскрыта
сразу; поиск (в шапке) находит и по названию типа и категории, а не только по фразе и данным;
у раскрытого события — «Скрыть этот тип» и «Показывать только этот тип». События `user/*` в каталоге
типов нет — ими управляет только «Показывать мои действия».

### Правило: новое событие → каталог + подпись + сторож

Любой новый `(cat, type)`, который пишут ядро (`_event(…)`, `eventBook.add(…)`) или приложение
(`postEvent` / `_journal` с `cat` ≠ `user`), в **одном коммите** получает:

1. запись в `eventCats` (`core/lib/src/log_view.dart`) и строку в таблице выше;
2. подпись в `app/lib/core/event_text.dart` (`typeLabel`, фраза в описании события) и строки в
   `app/lib/l10n` (en + ru, через `app/tool/i18n_extra.json`);
3. при необходимости — ключ уведомления в `eventNotifKind` (`log_view.dart`).

Сторожевой тест `core/test/event_catalog_test.dart` сканирует места записи событий в `core/lib/src` и
`app/lib` и падает, если пара `(cat, type)` не в `eventCats` (и не `user/*`); второй тест падает, если у типа
каталога нет подписи в `event_text.dart` и он не в явном списке `pendingLabels` (долг, который надо погасить
на этапе Flutter, а не копить). Динамические места записи (тип из переменной) тест знает поимённо — новое
такое место добавляется в его таблицу `dynamicSites`.

## Отчёт

`CoreApi.report({appInfo})` → одна карта (`GET /api/report` у jormd; `POST` с `{appInfo}` — страница
мокапа сообщает то, что знает только она). Строится из памяти за один проход (кольца ≤ 5500 строк, события
≤ 1000); вызывающий может сжать gzip. Секреты замаскированы (см. ниже), **имена серверов и хосты
остаются** — локальный экспорт: маскируются учётные данные и токены, не домены.

`reportToText(report)` — тот же отчёт простым текстом (шапка, события, сырой лог) для «Download log»
и чтения глазами.

Поля (`format: 1`; новое поле — не повод менять `format`, поменялся смысл или убрано — повод):

| Поле | Что |
|---|---|
| `format` | 1 |
| `createdAt` / `createdAtMs` | ISO-8601 UTC / мс |
| `app` | `appInfo` как передан, **кроме** зарезервированных ключей ниже: `version`, `versionCode`, `commit`, `platform`, `androidApi`, `device` (модель, производитель), `abis`, `locale`, `timezone`, … Ядро ничего не угадывает: чего хозяин не передал — того нет |
| `core` | `version`, `singBox`, `libbox?` (из `appInfo.libbox`), `dart`, `os`. `dataDir` не включён намеренно (путь содержит имя пользователя) |
| `connection` | `state` (connected / recovering / down / disconnected), `mode` (tun / proxy), `systemProxy`, `blocking?`, `recovering?`, `down?`, `restarts`, `error?`, `warning?`, `upSince` / `uptimeMs` (пока подключено), `exit` (`country`, `direct`, `error?`, `at?`; IP-адреса нет), `planHash` (12 hex от скелета плана без секретов; серверы — по ключам), `planSig?` (из `appInfo.planSig`: до 40 символов как есть, длиннее — 12 hex-дайджест), `stack` (для TUN), `routing` (global / rules), `manual`, `servers` (уникальных серверов в плане), `routes[]` (`id`, `kind`, `name?`, `servers`, `entryServers?`, `pick`, `pinned?`, `current`, `health?` из Auto: `ms`, `fails`, `oks`, `at`, `strikes`, `holdUntil`, `server`, `entryServer`, `serverName?`, `entryServerName?`), `current` (`id`, `index`, `kind`, `server?`, `entryServer?`, `name?`, `serverName?`, `entryServerName?`), `auto` (`switches`, `switchedAt`, `lastSwitch`, `unstable`, `lastUnstable`, `noNet`, `offline`, `requestFails`, `blocked`, `unreachable`, `stalledClosed`, `checkedAt` — те, что есть). Имена (`name`, `serverName`, …) — из `appInfo.names` (ключ id маршрута / ключ сервера → отображаемое имя) |
| `settings` | то, что ядро знает без секретов: из плана `mode`, `mixedPort`, `mixedAuth` (**булево**, логин не попадает), `tunStack`, `ipv6`, `hijackDns`, `global`, `urlTest`, `auto`; из сервиса `systemProxy`, `killSwitch`, `killOnDisconnect`, `killWhileClosed`, `downProxy`, `closeOnSwitch`, `dnsAuto`, `ignoredSites` (число), `screenOn`; объекты снимка UI `segState`, `connCfg` (без `proxyUser` / `proxyPass`), `autoCfg`, `genCfg`, `notifCfg`, `logCfg`; `app` = `appInfo.settings` (настройки Flutter-приложения, у которого свой стор) |
| `network` | статус пула проб ядра (`status.network`), `interfaces` (имена), `tunUp`, `host` = `appInfo.network` (тип сети, VPN-сервис поднят, metered — это знает платформа) |
| `counters.tun` | сводка по приложениям из сырых колец (`tunSummary`, ниже): `packages[]` (≤ 30: `package`, `syn`, `orphan`), `others` (`packages`, `syn`, `orphan` — остальные), `total` (`syn`, `orphan`, `tcp`, `udp`, `dns`), `window` (`lines`, `from`, `to` — окно колец) |
| `counters.failures` / `counters.tunIngress` | снимки `failuresSnapshot()` / `tunIngressSnapshot()` (`failures.dart`, `tun_ingress.dart`); `null`, если трекера нет |
| `counters.rings` | `lines`, `events` — сколько строк в кольцах и событий в журнале |
| `events` | **все** хранимые события со всеми `data` |
| `raw` | все строки обоих колец `{n, t, src, lvl, msg}` |
| `resume` | строки, начинающиеся с `[resume]` (их пишет приложение при переподключении после обновления), — подмножество `raw` для быстрого чтения |
| `redactions` | `total`, `byKind` — сколько значений замаскировано и чего |
| `note` | заметка пользователя («что не работает и с какого момента»), только в отправляемом отчёте (`sendReport`), ≤ 500 знаков, маскируется тем же `Redactor` |

Зарезервированные ключи `appInfo` (в `app` не попадают, лежат в своих местах): `libbox` → `core.libbox`,
`planSig` → `connection.planSig`, `names` → подписи в `connection`, `network` → `network.host`,
`settings` → `settings.app`.

Откуда `appInfo` у приложения: `app/lib/core/report_info.dart` (`ReportInfo.build`). Версия, сборка, коммит,
платформа, локаль, часовой пояс — у хоста; `device` (модель, производитель, бренд, API и релиз Android) и
`abis` — от `VpnChannel` (`device`, `abis`); `libbox` — от `VpnChannel.libboxVersion`; `network.type`
(wifi / ethernet / mobile / other / none / unknown) и `metered` — от `NetworkChannel` (`type`, `metered`),
`network.vpnService` — от `VpnChannel`; `names` — отображаемые имена маршрутов и серверов плана; `settings` —
настройки самого приложения (вид, язык, запуск, обновления, переключатели уведомлений; ни логинов, ни
ссылок). Каждый ответ платформы ограничен по времени (2 с) и необязателен: зависший канал стоит поля, а
не отчёта. `planSig` у приложения — строка каталога, в которой есть локальный логин прокси; в отчёт ядро
кладёт только 12-hex дайджест (длиннее 40 символов), поэтому наружу она не уходит.

### Сводка TUN по приложениям

Считается по сырым строкам sing-box одной проходкой тем же способом, что и живой детектор
`TunIngressDetector` (`tun_ingress.dart`, его же константы окна и ёмкости): строка `router: found package
name: …` (на десктопе `found process path`, ключ — имя файла) — это поиск программы за соединением, у неё
**свой** номер `[id]`, а строка самого соединения идёт рядом. Поэтому `found …` спаривается со строкой
реального соединения `inbound/tun…: inbound connection | packet connection | DNS packet` в пределах
`pairLines` (5) строк (TCP-соединение забирает два поиска, остальные — один); `syn` = число `found …` по
приложению, `orphan` = те, которых никто не забрал: TCP не дошёл до маршрутизации (признак поломки стека
`mixed` / `system`). Номера, у которых есть своя строка входящего соединения (mixed / socks), поиском не
считаются. `total.tcp | udp | dns` — реальные соединения TUN по типам; по приложениям их разложить нельзя
(строка соединения не несёт приложения), поэтому в `packages[]` только `syn` и `orphan`. Окно = то, что ещё
держат кольца (шум-кольцо 500 строк), накопленные с начала сеанса счётчики — в `counters.tunIngress`.

Строки сырого лога о TUN, которые пишет само ядро (источник `jormd`): `TUN (<стек>): TCP does not reach sing-box: N
connection attempts in S s, none accepted (<apps>)` — подозрение детектора; `TUN (<стек>): TCP passes the tunnel; N
look-ups of <apps> end without a connection (that app only)` — активная проверка `tun.test` прошла, повтор для того же набора
приложений в течение 15 мин в журнал не идёт, только сюда (`docs/failures.md`, «TUN»).

### Маскирование (`redact.dart`)

`Redactor` заменяет значение стабильной подстановкой `<вид#N>` (одно значение — один номер, чтобы видеть
«то же самое» в разных строках) и считает по видам:

| Вид | Что маскируется |
|---|---|
| `url` | `http(s)://` URL: схема и хост (с портом) остаются, путь и query — `<url#N>` (корень `/` и голый хост не трогаются) |
| `userinfo` | `user:pass@` перед хостом URL — `<userinfo#N>@` |
| `link` | ссылки прокси (`vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `hy2://`, `tuic://`, `wireguard://`, …): `userinfo` и значения секретных параметров (`pbk`, `sid`, `password`, `key`, `token`, `psk`, `obfs-password`, …) маскируются, `sni`/`type`/`security`/`flow`/`fp`, хост, порт и имя (`#…`) остаются; `vmess://` — вся base64-нагрузка |
| `uuid` | UUID где угодно |
| `secret` | значения `password=`, `token=`, `secret=`, `pbk=`, `psk=`, `hwid=`, `api_key=`…, `key=` / `pass=` / `sid=` / `auth=` (только в виде `имя=значение`, в прозе это просто слова), `"password": "…"` в JSON-тексте; в структурах — значения ключей с такими именами (`password`, `uuid`, `token`, `private_key`, `public_key`, `pbk`, `psk`, `authorization`, …), на любой глубине |
| `token` | `Bearer …`, токен бота Telegram, `ghp_…` / `github_pat_…` / JWT, длинные (≥ 32) буквенно-цифровые «слова» с цифрами (только в свободном тексте; sha256 файла — hex — не трогается) |

Не маскируются: домены и IP, имена серверов, порты, пакеты приложений. Структурные поля отчёта, не
являющиеся свободным текстом (`app`, `core`, `connection`, …), проходят только правила по ключам, UUID и
URL; длинные «токены» ищутся лишь в свободном тексте (`events`, `raw`, `resume`), чтобы не испортить
хэш коммита.

Режим отправки (`Redactor(strict: true)`, см. «Отправка») ужесточает это сверх таблицы; локальный
экспорт — ровно таблица.

## Отправка

«Send report» (⋮ в Logs) отдаёт отчёт разработчику. Цепочка:

1. `showSendReport` (`app/lib/widgets/report_actions.dart`) — лист: что уходит, необязательная заметка
   (≤ 500 знаков), «Send report». Лист только **показывает** `ReportSendController`
   (`app/lib/core/report_send.dart`, один на приложение, у `LogsController.reportSend`): отправка и её
   результат живут вне листа. Закрыли лист посреди отправки — отправка идёт; открыли снова — тот же
   «Sending…» (или уже результат: номер отчёта / причина сбоя и заметка). Номер, который лист успел показать,
   «потребляется» закрытием листа или «Done»: следующее открытие — пустая форма. Во время отправки
   рядом с «Sending…» есть «Cancel»: `CoreHost.cancelSendReport` → `CoreApi.cancelReport`
   (`POST /api/report/cancel`) обрывает загрузку, лист возвращается в форму с заметкой (отмена — не ошибка).
   **Обратный отсчёт:** вместо «Sending…» кнопка показывает «Sending… N с» — секунды, оставшиеся от общего срока
   (`reportSendDeadline`, 28 с), полоска под заметкой убывает вместе с ним (1 → 0). Время считает контроллер от
   `startedAt` (`secondsLeft` / `fractionLeft`, часы подменяются в тестах), лист лишь перерисовывает его
   раз в 250 мс, поэтому закрытый и снова открытый лист показывает то же оставшееся время, а не отсчёт с начала.
   Контроллер страхуется сам: нет ответа хоста за срок + 5 с (33 с) — сбой `timeout`.
   Подпись под номером бывает одна: отправка напрямую **после неудачи туннеля** (`via: direct` и непустой
   `firstError`) — «Sent directly: the VPN path did not work.» и мелкой строкой сырая причина (`firstError`,
   не переводится). Через туннель (`via: vpn` — обычный путь при поднятом VPN, в т.ч. после неудачи прямого
   пути) и напрямую при выключенном VPN подписи нет.
2. `CoreHost.sendReport({note})` → `LiveCoreHost` собирает `appInfo` (`ReportInfo`) и зовёт
   `CoreApi.sendReport({note, appInfo})` (`POST /api/report/send` у jormd).
3. `CoreService.sendReport`: отчёт строится с **ужесточённым** `Redactor(strict: true)`, заметка проходит
   через тот же редактор, `packReport` (`core/lib/src/report_upload.dart`) сериализует и сжимает gzip,
   `ReportUploader.upload(gzipped, meta:, proxyPort:, cancel:)` доставляет. `proxyPort` — локальный прокси
   работающего туннеля (`tunnel-in`), `null` без подключения. Второй вызов, пока идёт первый, присоединяется
   к нему. **Вся отправка ограничена 28 с** (`reportSendDeadline` = пробы 3 с + 2 × попытка загрузки 10 с + запас 5 с на
   сборку и шифрование): по их истечении — `{ok: false, error: 'timeout', message: 'no
   result in 28 s, stuck while <этап>'}` и обрыв загрузки; этап (`building the report` / `uploading`; пробы
   и обе попытки входят в `uploading`) в `message` и в журнале указывает, где завис.
4. Ответ — карта: `{ok: true, id, bytes, via, firstError?}` (`via`: `direct` | `vpn`; `firstError` — почему не
   вышел первый путь, если отправка ушла вторым: проба первого не прошла или его загрузка встала) или `{ok: false, error, message?}`.
   Сбой доставки — не исключение: приложение показывает причину и «Retry», заметка остаётся в поле.

**Ужесточение (`strict`).** Сверх таблицы выше маскируются адреса e-mail (`email` → `<email#N>`) и имя
пользователя в домашнем пути (`C:\Users\<имя>`, `/home/<имя>`, `/Users/<имя>` → `path`). Домены, IP, имена
серверов и пакеты приложений остаются: без них отчёт бесполезен для разбора («нет TCP у пакета X к хосту Y»).
Это сознательно: лист честно говорит пользователю, что именно уходит, и что пароли, UUID, токены и ссылки
подписок скрыты.

**Что получает приёмник.** `gzip(JSON отчёта)` и `meta`: `format`, `createdAt`, `version`, `versionCode`,
`commit`, `platform` (из `app`), `bytes`, `gzipBytes`, `noteLength`, `note` (заметка после строгого
редактора; нет, если пуста — уходит в заголовок `X-Jorm-Note`). Квитанция —
`ReportReceipt{id, at?, via, firstError?}`; `id` пользователь называет разработчику («Sent. Report id: …»).

**Коды `error`:** `not-configured` (в сборке нет приёмника — лист так и говорит и предлагает «Download
log»), `network` (нет связи с сервером отчётов; `message` — причина, если пробовались оба пути — обе:
`via VPN: …; direct: …`), `no-route` (проба не нашла прямого пути, а туннель не поднят — лист: «No direct path
to the report server, and the VPN is off…»), `rejected` (сервер не принял; `message` — причина), `server`
(сбой на стороне сервера), `cancelled` (пользователь нажал «Cancel»), `timeout` (вся отправка не уложилась
в 28 с), `failed` (прочее; `message` — текст). Приёмник сообщает их через
`ReportUploadException(code, message)`. При `network`, `timeout` и `server` лист показывает `message`
мелкой второй строкой под текстом ошибки (сырой текст, не переводится): по скриншоту видно, какой путь и
почему не удался. В `rejected` и `failed` `message` уже в самом тексте.

«Download log» (⋮) от отправки не зависит: тот же отчёт (`report()` без строгого режима) как текст
(`reportToText`) в файл `jormungand-log-<дата>.txt` через `BackupIo`. Сохранение — по общей схеме
экспорта (`docs/platforms.md`, «Сохранение файлов»): системный диалог не открывается каждый раз,
сообщение «Logs saved» называет папку и фактическое имя файла (`папка/имя`).

### Загрузчик (`HttpReportUploader`)

`core/lib/src/report_upload.dart`. В настоящих хостах (`app/lib/core/platform_seams.dart` — Android и ПК,
`core/bin/jormd.dart`) в `CoreService(reportUploader:)` / `Daemon(reportUploader:)` подключён он; без
параметра (тесты, чужой хост) остаётся `NotConfiguredUploader` и `not-configured`.

`upload(gzipped, meta:)`: шифрует (`encryptReport`, `report_crypto.dart`) открытым ключом `reportPublicKey`,
проверяет размер конверта и делает `POST` на `reportEndpoint`. Ничего не логирует из содержимого;
`CoreService.sendReport` пишет в журнал только `id` / код ошибки.

**Конверт v1** (бинарный, всё подряд):

| Байты | Что |
|---|---|
| 4 | магия `JRP1` (`4A 52 50 31`): формат и версия |
| 32 | эфемерный открытый ключ X25519 (новый на каждую отправку) |
| 12 | nonce AES-GCM (случайный) |
| остальное | AES-256-GCM: шифртекст `gzip(JSON отчёта)` + тег 16 байт |

Ключ шифрования — `HKDF-SHA256(ikm = X25519(эфемерный закрытый, открытый получателя), salt = эфемерный
открытый ‖ открытый получателя, info = utf8 "jormungand-report-v1")`, 32 байта. AAD = 4 байта магии.
Накладные расходы конверта — 64 байта (`reportEnvelopeOverhead`). Новый формат — новая магия (`JRP2`), старый
расшифровщик отвечает «wrong magic» и не пытается гадать.

**Контракт с Worker'ом:**

- `POST https://jormungand-reports.slackerwarlock.workers.dev/v1/report` (`reportEndpoint`; конструктор
  загрузчика позволяет подменить — тесты ходят на `HttpServer` в loopback), тело — конверт,
  `Content-Type: application/octet-stream`. Без заголовка авторизации.
- Заголовки (всё открытое, из `meta`; отсутствующее не посылается, значения — печатный ASCII ≤ 64 знаков):
  `X-Jorm-Format` (номер формата отчёта), `X-Jorm-Version`, `X-Jorm-Build` (`versionCode`),
  `X-Jorm-Platform`, `X-Jorm-Size` (байт конверта). Сверх них — на каждой попытке загрузки (печатный ASCII):
  `X-Jorm-Via` (`vpn` | `direct` — путь этой попытки), `X-Jorm-Vpn` (`on` | `off` — туннель подключён),
  `X-Jorm-Note` — заметка пользователя **после строгого редактора**, UTF-8 в base64url без паддинга (не
  посылается, если заметка пуста; ≤ 500 знаков). Заметка по-прежнему и внутри зашифрованного отчёта; заголовок
  нужен, чтобы разработчик читал её без ключа (и чтобы Worker мог переслать). Заголовки `X-Jorm-Via` /
  `X-Jorm-Vpn` — диагностика приёмника: понять, прошёл ли отчёт через туннель, не открывая отчёт.
- Предел тела — 4 MiB (`reportMaxBytes`): больший конверт клиент не посылает, `rejected` локально
  («use Download log instead»).
- Ответ: `200 {"ok":true,"id":"<короткий id, напр. 20261010-k3x9qa>"}` → `ReportReceipt` (`at` — заголовок
  `Date` ответа). Остальное: `400` / `413` / `415` → `rejected`; `429` → `rejected` (сообщение — «rate limit»);
  `5xx` → `server`; нет соединения, TLS, обрыв, таймаут → `network`; всё прочее (в т.ч. `200` без `id`,
  редирект, `401`/`404`) → `failed`. Причина из `{"error": …}` ответа попадает в `message`.
- `POST /v1/ping` с телом `reportProbeBytes` (**32 KiB**) случайных байт, `Content-Type:
  application/octet-stream` → `200` с **эхом** тела (ровно те же 32 KiB), отвечает до лимита запросов
  (`reportProbePath`). Проба с крошечным телом не годится: DPI замораживает соединения к Cloudflare после
  ~16–20 KB, так что маленький запрос проходит, а настоящая загрузка встаёт.
- Времена (всё — константы в `report_upload.dart`): проба — **3 с** на каждый путь (`reportProbeTimeout`);
  преимущество туннеля — **300 мс** ожидания после прохода прямой пробы (`reportTunnelGrace`); загрузка
  мертва, если **3 с** соединение не принимает байты тела (`reportStallTimeout`) или **5 с** после отправки
  всего тела не начался ответ (`reportResponseTimeout`); абсолютный предел одной попытки — **10 с**
  (`reportAttemptTimeout`, страховка под двумя первыми); соединение (TCP + TLS) 10 с (`reportConnectTimeout`);
  общий срок отправки — **28 с** (`reportSendDeadline` = проба 3 + 2 × попытка 10 + запас 5 с на сборку и
  шифрование `reportBuildMargin`; считается из констант). Редиректы не выполняются.

**Путь: пробы параллельно, загрузка по первому проходящему.** Соединение — своего процесса, поэтому запись
`report-upload` в `outside_tunnel.dart` (`ownRule`): самоправило (`package_name` на Android, `process_path` на
ПК) уводит прямое соединение `direct` раньше правил пользователя, DNS отвечает прямой сервер. Но прямой путь к
Cloudflare в РФ может быть задушен (соединение открывается, проба с крошечным телом проходит, а загрузка
~100 KB встаёт), а через туннель путь часто чище, поэтому пути выбирает объёмная проба, а не порядок:

1. **Пробы** (`_probe`): `POST /v1/ping` с 32 KiB случайных байт на тот же origin, 3 с на всё. При поднятом
   VPN (`proxyPort != null`) **две пробы одновременно**: прямая (вне туннеля) и через локальный прокси
   `tunnel-in` (`findProxy = PROXY 127.0.0.1:<порт>`); без VPN — только прямая. Проходит **только** `200` с
   телом ровно в 32 KiB: это значит, что TCP, TLS (с проверкой сертификата системой — заглушка провайдера или
   captive portal не пройдут) и объёмный обмен в обе стороны реально работают. Всё остальное — отказ, TLS,
   обрыв, зависание после первых килобайт, другой статус или длина (в т.ч. 404 старого Worker'а без эха;
   отказ прокси на CONNECT — 502/503 sing-box — тоже исключение клиента, то есть «пути нет») — «пути нет», с
   причиной строкой. Проба проверяет путь, а не скорость: медленный, но живой путь дольше 3 с признаётся
   недоступным.
2. **Первый путь.** Прошла проба туннеля — туннель (`via: vpn`); если прямая прошла раньше, туннелю даётся
   ещё `reportTunnelGrace`, и если его проба за это время не ответила — первым идёт прямой (`via: direct`).
   Если проба туннеля к этому моменту уже провалилась, причина идёт в `firstError` (`via VPN: no path (…)`);
   если она просто ещё не ответила — о туннеле ничего не утверждается, `firstError` пуст.
   Туннель не поднят и прямая проба не прошла — `no-route` («no direct path to the receiver (<причина>) and
   the VPN is not connected»), лист предлагает включить VPN. Туннель поднят и не прошла ни одна —
   `network` с обеими причинами (`via VPN: no path (…); direct: no path (…)`), без загрузки.
3. **Загрузка** на первом пути. Ответ приёмника **любым статусом** (200, 429, 5xx…) — итог. Сетевая ошибка
   (соединение, TLS, обрыв), **застой** (3 с соединение не принимает байты тела — DPI-«заморозка»), **нет
   ответа** за 5 с после тела, либо предел попытки 10 с — путь мёртв (`network`).
4. **Второй путь.** Первый путь мёртв, VPN поднят, а проба другого пути прошла (если ещё идёт — дожидается
   своего срока в 3 с) — тот же конверт один раз уходит другим путём; ответ приёмника — итог. Он тоже мёртв —
   `network` с обеими причинами (`via VPN: …; direct: …`); проба другого не прошла — `network`
   (`<первый путь>: <причина>; <другой>: no path (<причина пробы>)`). Успех на втором пути несёт причину
   первого в `firstError`; журнал пишет, какой путь не удался первым и почему. Без VPN второго пути нет:
   застой/сетевая ошибка прямой загрузки — `network`.

«Cancel» и общий срок прерывают любой этап: клиент закрывается принудительно, соединения не остаются.
Kotlin-стороне ничего не нужно: Dart-клиент, как у загрузки подписок и обновлений.

**Ключи.** Пара X25519 для получателя; закрытый ключ — только у разработчика.

- `dart run tool/report_keys.dart` (в `core/`) создаёт пару, пишет закрытый ключ (base64 от 32 байт) в
  `%USERPROFILE%\.jormungand\report_private.key` (`HOME` вне Windows), существующий файл **не перезаписывает**,
  выводит только открытый ключ и путь. Открытый ключ — константа `reportPublicKey` в `report_upload.dart`.
- Закрытый ключ в репозиторий не попадает, нигде не печатается и не логируется; **потеря = все накопленные
  отчёты нечитаемы**, поэтому копию — в надёжное место (рядом с копией ключа подписи релизов). Смена ключа =
  новая сборка с новым `reportPublicKey`; отчёты, зашифрованные старым, читаются только старым закрытым
  ключом — старый файл не выбрасывать.
- Открытый ключ в сборке — не секрет (из него закрытый не получить), но подменить его можно только сборкой:
  Worker хранит лишь шифртекст, его утечка не раскрывает отчётов.

**Расшифровка.** `dart run tool/decrypt_report.dart <file.bin> [--out report.json] [--key <файл ключа>] [--text]`
(в `core/`): ключ — из `--key`, иначе из `report_private.key`; без `--out` — в stdout (UTF-8), `--text` — как
«Download log» (плюс раздел `## Note` с заметкой). Ошибки: `Not a report envelope` (слишком короткий),
`the magic is not JRP1` (не тот файл / новый формат), `authentication failed` (чужой ключ или файл изменён —
тег GCM не сошёлся). Код — `report_crypto.dart` (`encryptReport`, `decryptReport`, `openReport`,
`generateReportKeys`), им же пользуются тесты `report_crypto_test.dart` и `report_upload_test.dart`.

**Приёмная сторона.** Worker `jormungand-reports` (`workers/reports/`, README там же): приём, лимиты
(Durable Object: на IP 10/час и 50/сутки, всего 500/сутки), хранение шифртекста в Workers KV (namespace
`jormungand-reports`, ключ `YYYY/MM/<id>`, TTL 90 суток; R2 на аккаунте не включён), выдача `id`, уведомление
в Telegram. Токен бота и chat id — секреты Worker'а (`wrangler secret put`), не в приложении и не в
репозитории; без них отчёты принимаются и хранятся, уведомление пропускается. Достать отчёт:
`node workers/reports/tools/fetch.mjs <id> x.bin`, затем `dart run core/tool/decrypt_report.dart x.bin`
(приватный ключ — `%USERPROFILE%\.jormungand\report_private.key`, копия у разработчика обязательна).

## Экран Logs (приложение)

Код: `app/lib/pages/logs_page.dart`, `core/logs_controller.dart`, `widgets/follow_list.dart` (`AnchoredList`,
`FollowController`), `widgets/log_parts.dart` (группы Raw), `widgets/raw_filter_sheet.dart`,
`widgets/event_rows.dart` (лист фильтра Events), `widgets/ignored_sites.dart` (строка и лист «Ignored sites»).

**Шапка одна на обе вкладки:** [фильтр с бейджем] [поиск] [⋮]. Больше в шапке ничего нет: корзины, «скачать»
и «копировать» отдельными иконками нет.

- **Фильтр** открывает лист своей вкладки. Бейдж на иконке — сколько в этом листе настроено не по умолчанию
  (поиск считается отдельно — его подсвечивает своя кнопка).
  - Events: типы по категориям, «Background», «Show my actions» (без поиска внутри листа; поиск —
    кнопка в шапке). Категории **по умолчанию свёрнуты**; что пользователь развернул, запоминается
    (`logCfg.openCats`, `LogsController.catOpen` / `toggleCatOpen`) и при повторном открытии листа остаётся
    развёрнутым. Плашки «Filtered: …» над лентой **нет** (активный фильтр виден по бейджу на кнопке, Reset —
    в листе).
  - Raw (`showRawFilter`): **уровень** (All / Warnings & errors); **Connections** — переключатель с
    пояснением «Successful connections and DNS answers: one line each, thousands per minute. Hidden by
    default; failed connections are always shown.»; **«N from ignored sites»** — переключатель, когда такие строки
    есть (или он включён — чтобы его можно было выключить); **Reset** — только когда что-то настроено.
    Переключатели хранятся в `logCfg` (`showConns`, `showIgnored`).
  - **«Ignored sites»** (`IgnoredSitesRow`, `widgets/ignored_sites.dart`) — отдельная настройка, строка есть в
    обоих листах (Events: в блоке «Kept with your settings»; Raw: отдельной группой под Reset). Не входит в
    бейдж фильтра, Reset её не трогает. Из меню ⋮ убрана.
  - **Группы Raw** (`groupRaw`, `log_parts.dart`) ограничены `rawGroupMax = 24` строками: секунда шквала раньше
    была одной гигантской строкой, строившейся целиком (подвисание). Серия продолжается в следующей группе
    со своей meta-строкой; нумерация первых групп стабильна, меняется только последняя.
    **Долгое нажатие на группу** копирует её целиком (meta-строка `HH:MM:SS LEVEL [core]` и сообщения) в буфер,
    тост «Copied» и лёгкая вибрация; тап и прокрутка не затронуты.
- **Поиск** — поле под вкладками; у каждой вкладки свой запрос; закрытие поля очищает запрос.
- **⋮**: «Clear events» / «Clear raw log» (по текущей вкладке; очистка событий спрашивает подтверждение),
  «Download log» (весь отчёт текстом, как в «Отправке»), «Send report» (лист отправки).
  **Copy убран**: делать буфер из тысяч строк не для чего, а «Download log» отдаёт то же файлом
  (`LogsController.exportText` удалён).

### Строка состояния Raw

Под вкладками Raw: «N lines» и, пока «Connections» выключен, «· Connections hidden (K)» (акцентным цветом,
тап открывает лист фильтра). K — сумма `hidden` ответов ядра с последней полной загрузки
(`LogsController.rawHidden`: ответ без `since` заменяет счётчик, ответ с курсора прибавляет; Clear и
перезапрос обнуляют). Высота строки не зависит от того, есть ли в ней K: список под ней не двигается.

### Чтение, пачки и что не делается

- Потоки событий и строк только взводят таймер: события собираются **300 мс**, строки Raw — **500 мс**
  (список перерисовывается не чаще двух раз в секунду, как бы быстро ни писал sing-box); страховочный опрос —
  раз в **5 с** (поток говорит «что-то новое», опрос находит то, что поток пропустил).
- Raw читается с `conns: cfg.showConns`. Включение/выключение «Connections» — **полный перезапрос**
  (`since: null`) с сохранением места в ленте (ниже); номера строк стабильны, поэтому строки соединений
  встают между уже имеющимися на свои места.
- **Ничего не делается для вкладки, которой не видно:** Raw не читается, пока на экране вкладка Events,
  вкладка Logs спрятана за другой или приложение в фоне (нет подписки на поток строк, нет списка); при
  показе догоняет с курсора `next`, пришедшее за это время — непрочитанное. События читаются всегда
  (тосты, точки на навбаре), но страница слышит изменения и перестраивается только пока на экране. Список
  чужой вкладки показывается прежним (тот же виджет), а спрятанная страница целиком — прежней.
- Списки строятся инкрементально: события свёрнуты один раз за версию журнала, группы Raw — за версию
  строк; каждая группа — виджет с ключом по номеру первой строки и **тот же экземпляр**, пока группа и её
  вид не изменились, поэтому пачка строк перестраивает только затронутую группу (замеряется тестом
  `logs_header_test.dart`: одна новая строка — 1–2 перестройки `RawGroupView`, не вся видимая страница).

### Место в ленте (`AnchoredList`)

Лента, прокрученная вверх, не прыгает, когда что-то меняется под ней: на хвост приходят строки, с головы
выпадают самые старые (кольцо 5000 + 500), меняется фильтр / поиск / «Connections», очищается лента.

- Список — `CustomScrollView(center:)` с точкой отсчёта (**pivot**): строки от неё и новее лежат ниже
  начала прокрутки, старые — над ним, поэтому позиция измеряется от строки, а не от начала данных, и сдвиг
  индексов в голове её не трогает. Каждая строка несёт порядок (`RowAnchor`: номер последней строки группы Raw,
  id события), pivot — порядок самой верхней видимой строки.
- Перед перестройкой (`_Anchor.sync`, из слушателя контроллера) измеряется самая верхняя видимая строка
  **прежнего** дерева, которая есть и в новых данных (иначе — просто самая верхняя), pivot ставится на неё,
  прокрутка корректируется на её позицию без уведомления (`correctPixels`; во время fling — `jumpTo`). Лента,
  стоящая внизу («следит»), pivot не держит: после перестройки она уходит на конец.
- Плашка внизу: «↓ Latest» или «↓ N new» (непросмотренные пришедшие, пока лента прокручена вверх).
- «In raw log» / открытие события из уведомления ставят pivot на нужную строку, строят её на месте и
  подводят к середине (`showRow`); строки нет в ленте — перезапрос и один повтор, затем «That line is no
  longer in the raw log».
- Незаконченное «дотягивание до низа» (`FollowController.toBottom`, несколько кадров, пока уточняется оценка
  высоты) прекращается, как только лента оставлена: следующий кадр не возвращает её вниз.

### Мокап

Мокап заморожен: переработка Logs записана в `.claude_states/mockup_todo.md` и переносится в него позже.
