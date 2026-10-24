# DNS-события + карточка сайта — план workflow `code-task` (одна бета)

Спеки (это `plan` workflow):
- `docs/logs.md:148-191` — «DNS-события: состав и карточки»;
- `docs/connect-model.md:944-958` — «Новый вид карточки — общий набор блоков»;
- `docs/connect-model.md:959-995` — «Карточка сайта» (unreachable + blocked).
Схемы: `.claude_states/dns_schemes.html`, `.claude_states/dns_site_schemes.html` §4.
Пункты плана: `bugs.md` — «Заголовок site/unreachable врёт», «Карточка site/unreachable: два ряда Rule», «DNS-события».

## Главный принцип — без хардкода

- Карточка = данные события → модель → общие блоки. Никакой вёрстки «под тип», никаких веток с литералами в виджетах.
- Имена — из данных: DNS — `DnsServerCfg.name` (пусто → id), ноды — по ключу `sid::nid` через каталог; ни одного
  «AdGuard» / «Cloudflare» в коде.
- Все строки — l10n (английские, без русского), ключи ниже; транспорт → подпись одной таблицей (`doh`→DoH, `dot`→DoT,
  `doq`→DoQ, `udp`→UDP, `system`→System); стороны — `vpn`/`direct` → l10n.
- Цвета — тема; градиенты итога (красный/зелёный, от темы не зависят) — одна таблица констант.
- Причина — структурой (`cause.kind` + аргументы), текст собирает app; ядро не пишет английских фраз в данные.
- Пороги/окна — именованные константы рядом с существующими (`oldConnTail`, `flagWait`), не числа в коде.
- Старые сохранённые события (без новых полей) показываются старым путём, не падают.

## Контракт данных ядро → app (фиксирован для всех кусков)

`DnsEnd` (сервер на стороне): `{provider, name, kinds: [kind…]}`.

- `dns/switched` (warn после отказа; info — back/node/off): `{reason, sides: [{side, from: {provider, name, silent:
  [kind…], since}, to: {provider, name, kind, ms}}], same: bool, route?: {sub, proto, node}, cause}`.
  `same` — обе стороны сменились одинаково (одна строка «VPN / Direct»). Поля `side/from/to/fromProvider/toProvider`
  старого вида не пишутся.
- `dns/transport` (info, новый тип «DNS transport changes», скрыт фильтром по умолчанию): `{sides: [{side, provider,
  name, from: [kind…], to: kind, ms}], same, route?, cause: {kind: 'transport', a: kind, b: kind}}`.
- `dns/down` (error): `{sides: [{side, servers: [DnsEnd…], selected: provider}], noSpare: bool, nodes?: [{key, sub,
  proto, ok: bool}], cause}` — `nodes` только на стороне VPN без запасных DNS и когда проверка `dns.node` прошла.
- `dns/up` (info, закрывает `dns/down` через `opens`): `{afterMs, sides: [{side, provider, name, kind}]}`.
- `net/switched` + `dns?: {switches: [элементы `sides` как у dns/switched], same, transports: [элементы как у
  dns/transport]}` — смены DNS (и смена победителя гонки) в окне смены сети.
- `cause`: `{kind, id?, a?, b?, node?, server?}`, kind ∈ `itself` (a, b — имена), `transport` (a, b — kind), `node`
  (node — ключ, server — имя), `net`, `nodeIncident`, `autoNode`, `reconnect`, `coreRestart`, `none`; `id` — событие-причина.
- `dns/failed`, `dns/failedOnNode` больше не пишутся (каталог, уведомления, свёртка — убрать; старые записи в журнале
  читаются).
- `site/blocked`: + `viaMs` (мс открытия через `via`), если проба его даёт (НЕ ПРОВЕРЕНО — коде проверить; нет — поля нет,
  app не пишет «opens in»).

## Нарезка

### Стадия 1 — ядро. `stageCheck: cd core; dart analyze; dart test`

**c-dns-detect** — deep, `core/lib/src/dns_failover.dart`.
whyDeep: автомат failover по двум сторонам — каскад отказов сворачивается в один `down` без перебора по кругу, пара down/up, гейт `dns.node`.
- Все кандидаты стороны молчат (или нет запасных / выключены) → не переключать, отдать `DnsDown` (стороны, серверы,
  выбранный остаётся); ответил любой → `DnsUp` с длительностью. Переключений по кругу нет.
- `dns.node` (`:989-1014`) — только когда на стороне VPN переключаться некуда; итог — `nodes` в `DnsDown`; есть
  запасные — проверки нет, просто переключение.
- Отказ сервера с переключением — одна `DnsSwitch` с `from` (молчавшие транспорты + since) и `to` (транспорт + мс).
- Одна причина сменила обе стороны → одна запись на обе стороны (`same` по одинаковым from/to провайдерам).
- Смена транспорта того же провайдера — отдельный вид записи (`transport`), не `DnsSwitch`.
- Гонка (`_raceOnce :762-799`) после сети/ноды: победитель отличается от выбранного до неё → запись смены с
  reason `race` (сейчас пропускается `:1162`) — её судьбу решает c-dns-events.
- Имя провайдера (`DnsServerCfg.name`, `core/lib/src/catalog/rules_model.dart:315`) — в записи.
- Убрать выпуск `SuspicionEvent('dns','failed'|'failedOnNode')` (`:1043-1052`, `_dnsKind :111`), строки журнала
  оставить/дополнить по `logs.md:193-216`.
- Публичный API (фиксирован): поток `switches` (`DnsSwitch` с полями контракта), новые потоки `transports`, `outages`
  (`DnsDown`/`DnsUp`).

**c-dns-events** — deep, `core/lib/src/service.dart`, `core/lib/src/netswitch.dart`.
whyDeep: порядок асинхронных шагов — смены DNS во время нестабильной сети ждут `net/switched` и уходят блоком в него, иначе (сети не было) — своим событием.
- Подписка на потоки c-dns-detect (`service.dart:2641-2658`) → события по контракту; `opens` у back и у `dns/up`.
- Cause для каждого: сеть (`_netCause :1151`), инцидент ноды, смена ноды выхода Auto, переподключение, перезапуск
  ядра; внешней нет — `itself` / `transport`.
- Смена сети (`_netSettled :1162-1178`, `netswitch.dart`): смены DNS/транспорта и смена победителя гонки в окне —
  в `data.dns` события `net/switched` (через `eventBook.update`), отдельного события нет. До и после выбора по сторонам.
- `site/blocked` `viaMs` (`:1343-1371`, `:1540-1546`) — если время пробы доступно.

**c-catalog** — lite, `core/lib/src/log_view.dart`.
- `eventCats :123-143`: + `dns/down`, `dns/up`, `dns/transport`; − `dns/failed`, `dns/failedOnNode`.
- `eventNotifKind :146-169`: `dns/down` → `dnsFailed` (тот же переключатель); `dns/failed` убрать.
- `journalOnly :197-212`: − `dns/failedOnNode`; `dns/up` — по образцу пар (как `conn/vpnUp`).
- `_keyFields :267-283`: `dns/down` — стороны; `dns/switched`, `dns/transport` — стороны + провайдеры.
- `defaultOffTypes :812`: + `dns/transport`.

### Стадия 2 — app, основа. `stageCheck: cd app; flutter analyze --no-fatal-infos; flutter test`

**a-card** — fast, новый `app/lib/widgets/event_card.dart`.
Модель `EventCardModel {level, icon, time, repeats, background, title, transition?: (from, to) нейтральная, blocks:
[CardBlock], cause?: (bold, rest), actions: [EventAction]}`; `CardBlock` = `SwitchFrame {heading?, rows: [(label
одна/две строки, from: (title, sub), to: (title, sub))]}` | `DataBox {rows: [KeyRow (key?, icon?, value, sub?, onTap?,
go?) | Section(title) | CheckRow (ok/bad, value, sub, onRetry?, onGo?)]}`. Виджеты по `docs/connect-model.md:944-958` и
схемам: плашки с клином, рамка с отступом только слева у подписи, градиенты из одной таблицы, «Details ▾» первая.
Без знания о типах событий.

**a-strings** — lite, `app/lib/l10n/app_en.arb` (+ `i18n_extra.json`, если строки там), `app/lib/core/event_text.dart`
(только имена типов `:58-86` и удаление текстов `dns/failed*`), прогон `node app/tool/gen_all.mjs`.
Ключи (сначала искать существующие с тем же текстом — переиспользовать): `dnsSwitchedTitle` «DNS switched»,
`dnsTransportChanged` «{name} changed transport», `dnsNoAnswerTitle` «DNS does not answer», `dnsAnswersAgain` «DNS
answers again — after {dur}», `sideVpn` «VPN», `sideDirect` «Direct», `dnsNoAnswerFor` «no answer for {s} s»,
`dnsNoAnswer` «no answer», `dnsStaysSelected` «no answer · stays selected», `dnsNoSpare` «no answer · no spare DNS on
this side», `dnsCheckedThrough` «Checked through», `dnsThroughVpn` «Through VPN», `dnsSpareNode` «answers — spare
node», `causeItself` «{a} itself» + «{b} answers through the same route», `causeTransport` «{a} does not answer on this
route» + «{b} of the same server does», `causeNodeDns` «node {node}» + «{server} answers through another node»,
`dnsSettings` «DNS settings», `networkEvent` «Network event», `detailsMore` «Details ▾», `typeDnsTransport` «DNS
transport changes», `typeDnsDown` «DNS does not answer», `siteDidNotOpenN` «{host} did not open on {n} servers»
(plural), `siteDidNotOpenKofN` «{host} did not open on {k} of {n} servers», `siteOpensIn` «opens in {ms} ms»,
`ruleFallback` «Fallback: {route}», `siteCauseElsewhere` «{node}» + «the site opens through another server».
Cause — двумя ключами (жирная часть, пояснение), чтобы app собирал «Cause: <b>…</b> — …».

### Стадия 3 — app, карточки. `stageCheck` = общий `check`

**a-dns** — fast, новый `app/lib/core/event_cards_dns.dart`: `EventCardModel? dnsCard(event, ctx)` для `dns/switched`,
`dns/transport`, `dns/down`, `dns/up`; `NetDnsBlock? netDnsBlock(event, ctx)` — блок для `net/switched`. По
`docs/logs.md:167-191`: рамка перехода (подпись VPN / Direct / две строки при `same`, по строке на сторону иначе),
Route — при стороне VPN, Cause всегда, кнопки Details ▾ / DNS settings (+ Network event при `cause.kind == net`);
`dns/down` — DataBox по сторонам, Checked through с рядами нод. Старое событие без `sides` → `null` (старый путь).

**a-site** — fast, новый `app/lib/core/event_cards_site.dart`: `EventCardModel? siteCard(event, ctx)` для
`site/unreachable` и `site/blocked` по `docs/connect-model.md:959-995`: заголовок N / K of N (N = своя + `tried` +
открывшая, K = не открывшие; чекер не считается), ряды App / Rule / Route, Checked (ноды + чекер, у blocked —
зелёный ряд `via` с «opens in»), Rule нового правила с «Fallback: …» только у blocked, Cause, Details ▾ + Ignore site ▾
(Everywhere / On this route only, «Ignored sites…»). Предзаполнение формы правила — как сейчас (`viaTarget` / `via`,
`event_rows.dart:519-547`). Логику рядов брать из `event_text.dart:579-611`, `:1394`, `:1629-1636` (вызывать, не копировать).

**a-wire** — fast, `app/lib/widgets/event_rows.dart`: `EventRow` (`:278`) рисует `EventCard` из `dnsCard` / `siteCard`,
когда они вернули модель, иначе старый вид; в `net/switched` — `netDnsBlock`; действия (`:406-457`, `:519-547`) —
убрать ветки `dns/failed*`, добавить DNS settings / Network event / Ignore site ▾; перепроверка с рядов Checked —
существующий `_RecheckAct`. Обновить goldens `app/test/_shots/event_shots_test.dart` (новые пресеты: все варианты из
двух схем).

## Тесты

Тестописатели — по куску (Haiku на lite/fast; c-dns-detect и c-dns-events — один `test-writer-deep`). Старые тесты
меняемого поведения: `dns_failover_test.dart`, `sentinel_events_test.dart`, `events_t1*_test.dart`,
`event_catalog_test.dart`, `event_fold_test.dart`, `event_filter_default_test.dart`, app — `t1_events_ui_test.dart`,
`event_rule_row_test.dart`, `event_rows_check_again_test.dart`, `t1_notify_test.dart`.

## После workflow (лид)

Визуальная приёмка `event_shots` против схем; `mockup_todo.md` — заметка; пункты `bugs.md` убрать; `docs` — снять
«не реализовано», старые строки таблиц `logs.md` (124-126, 415-417, 512-514, 551) переписать.
