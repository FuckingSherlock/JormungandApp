# Сбои: проверять, потом объявлять (`Sentinel`)

Код: `core/lib/src/sentinel/` (`context.dart`, `sentinel.dart`, `roots.dart`, `retry.dart`, `model.dart`,
`clock.dart`), поля события — `core/lib/src/eventbook.dart`. Тесты: `core/test/sentinel_*_test.dart`.

Зачем: детектор видит симптом (соединения не удаются, сайт не открылся, rule set не скачался), но не причину.
Сбой во время нашего же перезапуска sing-box, при пропавшей сети или как следствие уже известной поломки —
не отдельная ошибка. `Sentinel` — общий шлюз: детектор сообщает **подозрение**, шлюз прогоняет его по
лестнице проверок и возвращает **вердикт**; в журнал и в уведомления попадает только подтверждённое.

Статус: этапы 1–2 готовы — механизм, контекст, детекторы соединений и ядра (`conn/*`, `site/*`, `core/tunTcp*`,
`core/crashed|restartFailed|down`, `auto/unstable`) идут через шлюз. Служебный трафик (rule set'ы, подписки,
обновления, отчёт) — этап 3, решение об уведомлениях в приложении — этап 4 (внизу, «Перенос детекторов»).

## Контекст

Единственный источник правды о сети и о самом ядре. Отдаётся снимком в `/api/status` (поле `context`:
`{network, core, roots}`), потоком `Sentinel.changes` (сервис по нему рассылает статус) и в `POST /api/network`.

### Сеть (`NetworkContext`)

`state`: `up` / `none` / `captive` / `unknown`; `since` — когда сменилось `state`; `changedAt` — когда
менялось `state`, id или тип сети, или основной интерфейс (от него начинают заново все таймеры повторов);
`type` (`wifi` / `cellular` / …) и `id` — как сказала платформа, могут быть пусты; `source` — что решило:
`default` / `platform` / `os` / `probes` / `doubt`.

Состояние выводится из входов, первый подходящий выигрывает:

| # | вход | состояние |
|---|---|---|
| 1 | платформа: `captive: true` | `captive` (`platform`) |
| 2 | платформа: `connected: false` | `none` (`platform`) |
| 3 | пул замеров: ОС без сети (`offline`, это же — `offline` Auto) | `none` (`os`) |
| 4 | пул замеров: `down` (все маршруты и direct молчат) | `none` (`probes`) |
| 5 | пул замеров: `unknown` | `unknown` (`doubt`) |
| 6 | платформа: `validated: false` без остального | `unknown` (`platform`) |
| 7 | иначе | `up` |

`validated: false` — только сомнение, не отсутствие сети: проверочные адреса ОС там, где живёт приложение,
часто заблокированы при рабочей сети. Строка sing-box `updated default interface` двигает `changedAt`.

Входы: `ProbePool.onChange` (в сервисе — `sentinel.context.pool(status, osOffline:)`), строка sing-box
выше, и **`CoreApi.setNetwork({connected?, validated?, captive?, type?, id?})`** → `POST /api/network` — приложение
(Android: `NET_CAPABILITY_VALIDATED` / `CAPTIVE_PORTAL`, транспорт, id сети) присылает отчёт целиком; он заменяет
предыдущий. Ответ — снимок контекста.

### Ядро (`CoreContext`)

`phase`: `stopped` / `starting` / `settling` / `settled` / `recovering` / `down`; `since`; `restartReason`
(`userConnect`, `refreshLists`, `recover`, `adopt`, …) и `restartAt` — зачем и когда мы перезапускали sing-box.

- `starting` — sing-box запускается нами (подключение, перезапуск); `settling` — работает, но с запуска
  прошло меньше **settle** (по умолчанию 5 с, поле `settle`); `settled` — работает и тихо ≥ settle.
- `recovering` — упал, поднимается; `down` — не вернулся за 30 с (`down` сервиса). Попытка перезапуска
  упавшего ядра не новое состояние, меняется только `restartReason`.
- `settling` / `settled` считаются по часам, а не хранятся: переход в `settled` тоже сообщается как изменение.
- Усыновлённый (`adopt`) sing-box, работающий давно, `settled` сразу.
- Промежутки «не устоялось» запоминаются: `lastUnsettled(since)` — последний момент после `since`, когда ядро
  не было устоявшимся (по ним сбой, начавшийся во время нашего перезапуска, получает окно заново).

## Подозрение → вердикт

`Sentinel.suspect(Suspicion)` возвращает `Future<Verdict>`; не бросает. Подозрение:

- `kind` (`conn.failing`, …), `subject` (карта: что сломано — `{host: …}`, `{route: …}`), `evidence` (факты
  детектора — идут в `data` события), `key` (по умолчанию `kind|subject`);
- `window` — сколько сбой должен длиться, чтобы быть подтверждённым; `checks` — активные проверки;
- `why` — причина по версии детектора (используется, если проверки ничего не нашли); `scope` — какие
  подозрения покрывает корень, если сбой подтвердится (по умолчанию — ровно его `subject`);
- `viaCore` — путь сбоя идёт через sing-box (по умолчанию да; нет — например, прямой запрос к серверу
  обновлений: его не оправдывает перезапуск ядра);
- `event` — какое событие записать (`cat`, `type`, `level`, `own`, `bg`, `link`); нет — вердикт только
  возвращается вызывающему;
- `session` — корень живёт, пока живёт подключение (по умолчанию да).

Одно и то же подозрение (тот же `key`) во время оценки присоединяется к ней: общий вердикт, свидетельства
сливаются. Пока корень по этому `key` открыт, повтор сразу даёт `confirmed` с `repeat: true`, ничего не пишется.
Детектор, увидевший, что сбой прошёл сам, говорит `Sentinel.recovered(key)`. Одновременно оцениваются не более
`maxActive` (32) подозрений, остальные ждут в очереди.

### Лестница

Шаги идут по кругу заново, если за время ожидания мир изменился. Каждый шаг пишет запись в `trail`.

| | шаг | результат |
|---|---|---|
| a | **внешняя причина**: сеть `none` / `captive` | `consequence` корня `net.offline` / `net.captive` |
| b | **мы сами**: наш reject-правилом (`evidence.ownReject`) → сразу `deferred`; ядро `stopped` → `deferred`; ядро не устоялось (`starting` / `settling` / `recovering`) → ждать устоявшегося, но не дольше `deferMax` (60 с) → иначе `deferred`; после устоявшегося, если был наш перезапуск, окно сбоя считается заново от его конца | — |
| c | **корень уже есть**: открытый корень покрывает `subject` (в т. ч. `core.down`) | `consequence` |
| e | **постоянство**: ждать `window` от первого появления (от конца нашего перезапуска); сбой прошёл сам внутри окна (`Sentinel.recovered`) | `blip` |
| d | **активные проверки** по порядку, останавливаясь на первой решающей | см. роли ниже |
| f | ничего не объясняет «почему» | `unexplained` (только журнал, предупреждение) |
| — | всё подтвердилось: причина — упавшая `diagnostic`-проверка, иначе `why` детектора | `confirmed`, открывается корень |

(Буквы — как в брифе; порядок исполнения: a → b → c → e (ожидание) → d → повторный взгляд на контекст → f / confirmed.)

Роли проверок (`Check`): `recovery` — прошла: `blip` (сбой кончился); `alternative` — прошла:
`workaround` (есть рабочий обходной путь, ошибкой это не считается); `diagnostic` — не прошла: это и есть
`why`. Проверка, которая бросила исключение или не уложилась в `timeout` (10 с по умолчанию), —
`inconclusive`, лестницу не останавливает. Проверки идут только после окна. После проверок контекст
смотрится снова (опоздавшая внешняя причина, перезапуск за это время — не более 3 кругов, опоздавший
корень).

### Вердикты

| `verdict` | смысл | событие в журнале | уведомление |
|---|---|---|---|
| `confirmed` | сбой постоянный, внешней причины нет, корень открыт | уровень из `event.level` | **да**, если нет `cause` |
| `blip` | прошёл сам / восстановился за окно; в `why` — `recovered {afterMs, by}` | `info` | нет |
| `consequence` | следствие открытого корня; `cause` — id события корня | `info` | нет |
| `workaround` | есть рабочий обход; `why` — `workaround {by}` | `info` | нет |
| `unexplained` | сбой был, но причина не найдена; `why.unknown` | `warn` | нет |
| `deferred` | ядро не устоялось / наш reject / остановлено: отпущено без записи | не пишется | нет |

`deferred` в журнал не попадает никогда; остальные пишутся, только если у подозрения есть `event`.

## Корни и следствия

`Root`: `id`, `kind`, `key`, `subject`, `scope` (кого покрывает: `all` / `none` / `of(карта)`; поле-список в
`subject` совпадает по вхождению), `since`, `eventId`, `session`, `fromContext`, `consequences`.

- **Контекстные корни** открывает и закрывает сам трекер: `net.offline` (сеть `none`), `net.captive`,
  `core.down`; `scope: all`, не сессионные. Закрытие пишется в лог (`root.closed` в trail события корня,
  если оно есть).
- **Подтверждённый корень** создаётся вердиктом `confirmed`. Закрывается: `Sentinel.recovered(key)` /
  `closeRoot`, концом сессии (остановка ядра, новый sing-box — `session: true`), или по истечении
  `maxAge` (24 ч).
- Последующие подозрения в `scope` открытого корня становятся его следствиями. Когда корень открывается,
  уже открытые некорневые записи в его `scope` **перепривязываются**: их события получают `cause`, вердикт
  `consequence` и шаг `root.relinked` в trail.
- `Sentinel.attachEvent(rootId, eventId)` — детектор сам пишет событие корня (например, `net.offline` пишет
  `conn/offline`): уже записанные следствия получают его как `cause`.
- Открытые корни — в `context.roots` статуса (`openJson`).

## Модель события

К `{id, at, cat, type, level, own, bg?, rev?, log?, data}` добавились поля — **только когда событие
рассматривал Sentinel**; у остальных и у старых записей их нет (старый журнал грузится как раньше):

| поле | что |
|---|---|
| `verdict` | `confirmed` / `blip` / `consequence` / `workaround` / `unexplained` |
| `why` | `{code, params}` — причина, только код и параметры |
| `trail` | `[{code, params, outcome, at}]` — протокол проверок; `outcome`: `pass` / `fail` / `inconclusive` / `info` |
| `cause` | id события-корня, следствием которого это событие является |

Готовых фраз в данных нет (текст — дело приложения). `EventBook.update(..., verdict, why, cause,
appendTrail)` дополняет событие задним числом, `EventBook.isQuiet(event)` — «уведомление молчит».

### Коды в `trail`

| code | outcome | params |
|---|---|---|
| `suspect` | fail | `kind`, `subject`, `facts`, `windowMs`, `firstSeen` |
| `ctx.net` | pass / inconclusive / fail | `state`, `since`, `source?` (fail — сети нет, лестница кончается) |
| `ctx.core` | pass / fail | `phase`, `reason?`, `since?` |
| `self.restarted` | info | `reason?`, `settledAt` — окно пошло заново |
| `self.reject` | fail | — |
| `defer.timeout` | fail | `maxMs` |
| `root.covers` | fail | `root`, `kind` |
| `persist.wait` | info | `windowMs` |
| `persist.window` | fail | `windowMs`, `elapsedMs` |
| код проверки | pass / fail / inconclusive | `role` (`recovery` / `alternative` / `diagnostic`) + её параметры; `reason: timeout` / `error` у неотвеченной |
| `blip.recovered` | pass | `afterMs`, `by` |
| `why.unknown` | inconclusive | — |
| `root.closed` | pass | `reason`, `afterMs` (дописывается к событию корня при закрытии) |
| `root.relinked` | info | `root`, `kind` |

Значения `why.code` вердиктов Sentinel: `recovered`, `workaround`, `why.unknown`, код упавшей диагностической
проверки или `why` детектора, у следствия — `kind` корня (`net.offline`, `net.captive`, `core.down`, …) с
`{root}`; у `deferred` (не пишется) — `self.reject`, `core.stopped`, `self.notSettled`, `sentinel.closed`.

## Повторы (`RetryPolicy`)

Для служебного трафика ядра (обновления, отчёты, rule set'ы); использует общий сборщик `ServiceFetch`
(`docs/core.md` → «Служебный трафик»: гонка по путям, `svc.fetch`-подозрение, `failure.advice`), вызывающие
код переносятся на него.
`advise(RetryKind)` → `RetryAdvice(waitFor, after?, attempt)`; `wait(advice)` ждёт.

- Сбой нашего перезапуска (`ownRestart`) → `RetryWait.settled`: повтор, когда ядро устоялось; не считается.
- Сетевой сбой (`network`) → `RetryWait.time`: 1 → 2 → 5 → 15 мин, дальше 15 мин. Ожидание обрывается, если
  сеть сменилась (`netEpoch`) на рабочую — на новой сети попытка стоит делать сразу.
- Сети нет (`none` / `captive`) → `RetryWait.networkUp`, что бы ни случилось; не считается.
- Счётчик сбрасывается сменой сети (id, тип, интерфейс, потеря или возвращение связи), новым запуском ядра
  (подключение, перезапуск) и `reset()` после удачи.

## Что уведомляет (правило для этапа 4)

Уведомление — только для события с `verdict == confirmed` **без** `cause` (`!EventBook.isQuiet(e)`);
событие без `verdict` — по правилам своего типа, как раньше. Решает приложение. `blip`, `consequence`,
`workaround`, `unexplained` остаются в журнале (Logs → Events) без уведомления; следствия приложение
может сворачивать под событие-причину по `cause`.

## Перенос детекторов

**Сделано (этап 2)** — детекторы соединений и ядра: ни один не пишет событие сбоя сам, все идут через
`suspect` (код: `service.dart`, `failures.dart`, `tun_ingress.dart`, `auto.dart`). **Этап 3:** сделано —
`rules/ruleSetFailed` (`rulesets.dart` на `ServiceFetch`, `service.dart` `_ruleSetFailed`: подозрение
`svc.fetch`, событие только при `confirmed`, `hasCopy` в данных; сбой своего перезапуска молчит до `settled`).
Не сделано: `sub/failed`, `core/updateFailed`, отправка отчёта (общий служебный трафик с
`RetryPolicy`); проверки запасных маршрутов Auto (`[auto]`, повтор для мёртвого запасного сервера) — этап 4.

### Окна (`FailureWindows`, `sentinel/windows.dart`)

Все пороги постоянства — именованные константы одного класса; `CoreService(windows:)` подменяет их (в тестах
`FailureWindows.instant()` — все окна нулевые).

| константа | по умолчанию | чьё |
|---|---|---|
| `connFailing` | 10 с | `conn/failing`: сбой должен длиться столько от первой неудачи серии (до этого сама серия — 3 неудачи за 60 с, `FailureBook.failAfter` / `streakWindow`) |
| `connLost` | 12 с | `conn/lost`: ни один маршрут не отвечает |
| `tunTcpDead` | 10 с | `core/tunTcpDead`: от первого необработанного запроса окна детектора |
| `netBlip` | 10 с | `conn/offline`: сети нет меньше этого — запись-`blip`, дольше — `warn` и `conn/online` потом |
| `autoUnstable`, `siteBlocked`, `siteUnreachable` | 0 | Auto уже сам выдержал свой срок; шлюз только проверяет и записывает |
| `siteChecker` | 40 с | потолок внешней проверки сайта (`site.checker`) |

### Что и как идёт через шлюз

| событие | подозрение (`kind`) | проверки по порядку | вердикты |
|---|---|---|---|
| `conn/failing` | `conn.failing`, ключ `conn.failing\|приложение\|host:port\|outbound\|inbound`, `scope {host, port, outbound}` | `recovery conn.recovered` (то же назначение снова открылось через тот же outbound, по живому трафику `FailureBook.okOutbounds`), `alternative conn.otherRoute` (через другой outbound открылось), `diagnostic probe.same` (тот же сервер, пробой Auto `reachSame`), `alternative probe.alt` (другие маршруты, `reachAlternates`; пропускается, если тот же сервер открывает) | `blip` / `workaround` / `consequence` / `confirmed` |
| `site/blocked` | `site.blocked` | уже сделанное Auto, как записанные проверки (`Check.recorded`): `probe.same` fail, `probe.alt` pass | всегда `workaround` (тихо; приложение по-прежнему предлагает правило) |
| `site/unreachable` | `site.unreachable` | записанные: `probe.same` fail, `probe.alt` (fail, или inconclusive при `retriesOff`); живая `diagnostic site.checker` (внешний чекер; запускается и при `retriesOff`) | чекер `opens` — `confirmed` (`why site.checker`, уведомляет); `down` / не смог / выключен — `unexplained` |
| `conn/lost` | `conn.lost` (корень над путём `proxy`) | — | `consequence` (сети нет), `blip`, `confirmed`; `conn/restored` пишется, только если корень стоял |
| `conn/offline` / `online` | сам корень `net.offline` контекста | — | событие корня пишет сервис по `sentinel.changes`: через `netBlip` — `confirmed` + `attachEvent`; раньше вернулась — `blip` (`info`, `downMs`); `conn/online {downMs}` — только после «стоявшего» `offline` |
| `core/tunTcpDead` | `tun.tcpDead`, `Scope.none` | активной проверки пока нет (см. TODO ниже) | `confirmed` (корень), `blip` (TCP вернулся в окно), `deferred` (`ownReject`) |
| `core/crashed` | — (факт) | — | `confirmed`, открывает корень `core.crashed` (не сессионный, с `eventId`) |
| `core/restartFailed` | — (факт) | — | `consequence`, `info`, `cause` = событие падения, `why core.crashed {attempt}` |
| `core/restarted` | — | — | без вердикта (это восстановление); закрывает `core.crashed` |
| `core/down` | корень `core.down` контекста | — | `confirmed`, `attachEvent` к корню; покрывает всё, что идёт через ядро (`Scope.all`) |
| `auto/unstable` | `auto.unstable\|<route>` | — | `confirmed` (корень закрывается сразу — это объявление, а не стоячий сбой) или `consequence` |

Подробности:

- **`conn/failing`**. `FailureBook` больше не пишет событие: он собирает серию и отдаёт `FailureReport` на `report`
  (ответ — id события, если сбой подтвердился, иначе `null`). Группировка (`more`) осталась в книге: следующие
  назначения того же приложения через тот же outbound присоединяются к событию (`update(id, {more})`, когда
  id известен). Не подтвердилось (blip / workaround / consequence / unexplained / deferred) — группа
  закрывается, запись не повторяется `FailureBook.recheckAfter` (60 с). Успех на «объявленной» записи вызывает
  `recovered(key)`: подозрение в работе становится `blip`, открытый корень закрывается. Запросы `probe-in`
  (проверки запасных маршрутов самим Auto) и `tunnel-in` не считаются вовсе. Прямой путь **не** проверяется
  (приватность: сеть не должна узнавать интерес к сайту). Данные события те же (`app`, `process`, `host`, `port`,
  `outbound`, `route`, `kind`, `count`, `windowMs`, `source`).
- **TUN.** `TunIngressDetector.start(stack, ownRejects:)`. Отказ нашим `reject`-правилом (IPv6 выключен в плане,
  правило блокировки пользователя) выглядит как мёртвый стек. sing-box 1.14 пишет `router: pre-match[N] … =>
  reject` **только на уровне debug**, в конфиге стоит `info` — на практике такой отказ неотличим от мёртвого стека
  (одинокая строка `router: found package name`). Что сделано: окно постоянства; разбор debug-строки по id соединения
  (отказ нашим правилом не считается; если им одним набрано окно — `onDead({…, ownReject: true})` один раз, Sentinel
  отпускает без записи, `dead` не ставится); в `evidence` — `ownRejects` (какие свои reject-правила включены) и
  `ownRejected`. Адресов назначения в логе sing-box нет, поэтому v4/v6 в свидетельстве нет. Свидетельство: `apps`,
  `appCounts` (запросов на приложение), `synSeen`, `accepted`, `windowMs`, `firstSeen`. `core/tunTcpBack` пишется,
  только если корень `tun.tcpDead` стоял. **TODO(sentinel):** активная `recovery`-проверка «открыть тестовый
  TCP-соединение через TUN» (`service.dart`, `_tunDead`, `checks: const []`): удалось — `blip`, отказ/тишина — `diagnostic`;
  заменит ожидание первого принятого соединения и снимет неразличимость собственного reject'а.
- **Сессия.** `_stopAuto` вызывает `Sentinel.dropAll()`: подозрения прошлой сессии sing-box отпускаются как `deferred`
  (шаг `session.dropped`) без записи; что всё ещё сломано, детектор заподозрит заново. Подозрение, пришедшее при
  `settling` после нашего (пере)запуска, ждёт устоявшегося и отсчитывает окно заново (шаг `self.restarted`).
- **Сеть.** `conn/offline` берётся только из корня `net.offline` (ОС, платформа, пробы — один источник, второго
  нет). `captive` события не имеет (в каталоге нет такого типа): все подозрения под ним — `consequence` корня
  `net.captive` без `cause`.
- **Падение ядра.** `core/crashed` открывает корень `core.crashed` (`Scope.none`, не сессионный), `restartFailed` —
  его следствие; корень закрывается при `restarted` / новом подключении / отключении. Через 30 с `core/down` —
  событие корня `core.down`, который покрывает всё через ядро.

### Дополнения к API шлюза

- `Check.recorded(role, result)` — уже сделанная проверка (Auto проверил сам): попадает в `trail` и решает вердикт
  как обычная, но не запускается.
- `SuspicionEvent.note(kind, evidence)` — одна строка в сыром логе при записи события (для людей; в событие не
  идёт).
- `Sentinel.dropAll({reason})` — отпустить все подозрения в работе (конец сессии).
- Коды `trail` сверх таблицы выше: `conn.recovered`, `conn.otherRoute`, `probe.same`, `probe.alt` (`role`,
  `outbound` / `via` / `tried` / `reason`), `site.checker` (`state`: `opens` / `down` / `failed` / `off`),
  `session.dropped` (`reason`), `core.exit` (`code`), `restart.failed` (`attempt`, `reason`), `ctx.core`
  (`phase: down` у `core/down`). `why.code` сверх таблицы: `conn.<kind>` (`refused` / `timeout` / `reset` /
  `stalled` / `instantRefusal` / `dnsFail`), `routes.silent`, `tun.tcpDead`, `route.unstable`, `net.offline`,
  `core.exit`, `core.crashed`, `core.down`, `site.blocked`.

Для перевода ничего менять в Sentinel не нужно: `subject` / `scope` задаёт детектор, события записывает
сам Sentinel через `book.add`, поэтому каталог типов (`event_catalog_test`) пополняется только вызовом
`SuspicionEvent` на стороне детектора (тест читает и его).
