# Сбои: проверять, потом объявлять (`Sentinel`)

Код: `core/lib/src/sentinel/` (`context.dart`, `sentinel.dart`, `roots.dart`, `retry.dart`, `model.dart`,
`clock.dart`), поля события — `core/lib/src/eventbook.dart`. Тесты: `core/test/sentinel_*_test.dart`.

Зачем: детектор видит симптом (соединения не удаются, сайт не открылся, rule set не скачался), но не причину.
Сбой во время нашего же перезапуска sing-box, при пропавшей сети или как следствие уже известной поломки —
не отдельная ошибка. `Sentinel` — общий шлюз: детектор сообщает **подозрение**, шлюз прогоняет его по
лестнице проверок и возвращает **вердикт**; в журнал и в уведомления попадает только подтверждённое.

Статус: этап 1 — ядро механизма, контекст подключён к сервису. Детекторы пока пишут события сами
(список на перевод — внизу, «Перенос детекторов»).

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

Для служебного трафика ядра (обновления, отчёты, rule set'ы); пока ни кем не используется.
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

## Перенос детекторов (этап 2)

Сейчас эти места пишут события сами, без шлюза; переводятся на `suspect`:

- `conn/failing` (`failures.dart`, `FailureBook`) и `TunIngressDetector` («TCP из TUN не доходит») — окно,
  `recovery`-проверка, диагностика прямым путём; `ownReject` из правил блокировки.
- `conn/lost` / `restored`, `conn/offline` / `online` — это сам контекст сети (`net.offline` корень); события
  привязать через `attachEvent`.
- `site/blocked`, `site/unreachable` — `alternative`-проверка (другой маршрут), `diagnostic` (SiteChecker).
- `core/crashed`, `restartFailed`, `down` — `core.down` корень, `restartFailed` с `ownRestart`.
- `auto/unstable`, проверки запасных маршрутов Auto (`[auto]`, повтор для мёртвого запасного сервера).
- `sub/failed`, `rules/ruleSetFailed`, обновления и отправка отчёта — через общий служебный трафик с
  `RetryPolicy`.

Для перевода ничего менять в Sentinel не нужно: `subject` / `scope` задаёт детектор, события записывает
сам Sentinel через `book.add`, поэтому каталог типов (`event_catalog_test`) пополняется только вызовом
`SuspicionEvent` на стороне детектора.
