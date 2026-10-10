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

Решает `isNoiseLine(text)` (`logbook.dart`): предупреждение или ошибка никогда не шум (кроме строк игнорируемого
сайта — они в шум-кольце, но остаются предупреждениями). `found package name` — по одной строке на каждое
соединение, шквал одного приложения (Telegram) раньше занимал 79 % основного кольца.

Предупреждения и ошибки основного кольца дополнительно лежат в `problems.jsonl` (переживают перезапуск).
Строки шум-кольца на диск не пишутся.

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

Приложение: параметр проведён до хоста (`CoreHost.logPage({since, conns = true})` → `CoreApi.log`), но
опрос Raw пока идёт без `conns` и прячет шум у себя (`LogLine.isConn`, переключатель «Connections», по
умолчанию выключен; строки `found package name` теперь тоже под ним). Перевод опроса на `conns: false` при
выключенном «Connections» (с показом `hidden` и полным перезапросом при включении) — задача этапа Flutter.

## События

`EventBook` — журнал структурированных записей `{id, at, cat, type, level, own, bg?, rev?, log?, data}`:
`data` — только поля, готовых фраз нет (текст — дело приложения, на языке пользователя); `log` — номер сырой
строки, записанной в тот же момент; `own` — действие пользователя; `bg` — случилось при погашенном экране.
Хранится 7 суток / 1000 штук, `events()` отдаёт хвост, `since` — с номера.

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
| dns | switched | `from`, `to`, `reason` |
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

Зарезервированные ключи `appInfo` (в `app` не попадают, лежат в своих местах): `libbox` → `core.libbox`,
`planSig` → `connection.planSig`, `names` → подписи в `connection`, `network` → `network.host`,
`settings` → `settings.app`.

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

Режим «Send report» (отправка разработчику, Worker `jormungand-reports`) может ужесточать маскирование
сверх этого; локальный экспорт — ровно это.
