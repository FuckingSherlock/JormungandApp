# Аудит событий (для сессии редизайна событий), 2026-10-16

Только чтение кода. Пути от корня репо; `ctx/` = `core/lib/src/`. «План:» — где пункт уже записан (F = features.md, T = to_think.md, U = unfinished.md, W = windows.md); «нет в плане» — нигде.
Отметки: [проверено] — видно в коде; [вывод] — по структуре/именам.

Общее наблюдение: `verdict` и `cause` приходят в `EventRecord` (`core/lib/src/log_view.dart:23-39`), а `why`/`trail` в модель не читаются вовсе; приложение `verdict`/`cause` не показывает и следствия под корень не сворачивает (в `app/lib` обращений нет; `verdict` читает только `eventNotifies`, `log_view.dart:162`). Поэтому «почему» не отвечено ни для одного события. План: F «Этап 4 Sentinel» (протокол проверок в подробностях, свёртка следствий).

## 1. Ситуации без события

1. **Captive portal («Сеть требует входа»)**. Данные есть, события нет: Kotlin шлёт `captive` (`app/android_overlay/kotlin/DefaultNetworkMonitor.kt.tmpl:247`) → `setNetwork` (`app/lib/core/live_core_host.dart:165`) → Sentinel открывает корень `net.captive` (`ctx/sentinel/sentinel.dart:464`), но, в отличие от `net.offline` (`ctx/service.dart:1455-1506` пишет `conn/offline`), корню никто не пишет событие; типа в каталоге нет (`docs/failures.md:563`). Все сбои под ним молча становятся `consequence`. Пользователь не видит, почему «ничего не открывается». План: F «Этап 4 Sentinel» (net/captive), F «Разбор ложных сигналов».
2. **Нет интернета vs сервер мёртв**. `conn/offline` есть (`service.dart:1503`), но когда сеть есть, а маршруты молчат, — `conn/lost` без причины и без действия (`service.dart:1440`, текст всегда «No route answers, waiting», `app/lib/core/event_text.dart:271`). Частично: F «Разбор ложных сигналов».
3. **VPN отозван системой / другим VPN-приложением / always-on / lockdown**. Kotlin знает причину: `onRevoke` → `stopped reason=revoked` (`JormungandVpnService.kt.tmpl:119-126`) → Dart `VpnChannel.stopped` (`app/lib/platform/vpn_channel.dart:162`) → `LibboxRunner._gone` пишет строку Raw «sing-box stopped: revoked» и зовёт `onExit(0)` (`app/lib/core/libbox_runner.dart:227-234`) → ядро видит обычный `core/crashed {code:0}` (`service.dart:124,1759-1771`) и пытается перезапуститься: `restartFailed` ×N → `core/down`. Причина «отозван» потеряна, действия («включить VPN снова») нет. Always-on/lockdown не опрашиваются вообще [проверено grep]. План: T «Статус VPN отозван системой» (S7); связано с F «Kill switch на Android».
4. **Android Private DNS** — ни проверки, ни события; `isPrivateDnsActive` / `privateDnsServerName` в коде нет (`getLinkProperties` читается только в `LibboxPlatform.kt.tmpl:119`). Упомянут лишь как причина блокировки в F «Реклама/трекеры». План: частично F «Реклама/трекеры», T «Подмена DNS»; отдельного пункта нет.
5. **Служба убита батарейной оптимизацией** — события нет. Есть однократный запрос исключения (`app/lib/core/system_notifier.dart:172-177`) и строка в настройках (`settings_conn.dart:133`); `onDestroy` пишет только `ResumeStore.note` (`JormungandVpnService.kt.tmpl:129-135`). Нет в плане (U «S14» — пауза Auto, другое).
6. **Срок/трафик подписки** — парсятся (`ctx/fetch.dart:738-756`, `ctx/updater.dart:78`), рисуются на карточке (`app/lib/widgets/source_card.dart:322-327`); событий «скоро истекает / истекла / трафик на исходе / кончился» нет. Нет в плане.
7. **Выбранный (Manual) сервер пропал / нода в использовании удалена из подписки**. `sub/removed` несёт только `count` (`live_core_host.dart:1989-1994`), без «использовался ли». Потеря пина → `disconnect()` + тост `connectFailed` (`live_core_host.dart:1715-1723`): события нет, а ядро пишет `conn/disconnected by:'user', own:true` (`service.dart:3369`) — отключение выглядит как действие пользователя [проверено по коду; что disconnect идёт через `api.disconnect` — `live_core_host.dart:893`]. Для правил есть `rules/targetLost`, для имени сервера — `node/addressMissing` (inUse). Нет в плане.
8. **Смена IP выхода / неожиданная страна** — события нет: `_recheckExit` только обновляет `status.exit` (`service.dart:2058`), категории для этого нет (`ctx/eventbook.dart:61`). Ошибка всех сервисов Exit IP — тоже только статус. Нет в плане (U «S5» — гео-провайдер, другое).
9. **TUN упал / интерфейс исчез**. Есть `core/tunTcpDead` (TCP не доходит, `service.dart:1184`) и `core/down` (sing-box не стартует, `1883`). Не покрыто: интерфейс убран системой при живом sing-box; ранний «start test failed every try» — только warn в Raw (`service.dart:1258-1260`); реакции на `tunTcpDead` нет. План: T «Политика по мёртвому TCP в TUN» (S40).
10. **Сбой подхвата работающего туннеля** («A running tunnel could not be taken over … stopped», «older core … not taken over») — туннель останавливается, только Raw (`service.dart:2767,2774,2810`). Нет в плане.
11. **Системный прокси остался от kill switch / не снят**: «System proxy kept from the last run … no internet until connect or Remove» — warn только в Raw (`service.dart:623`); «system proxy not restored» в `_goDown` — Raw (`1874`). Плашка blocking на Android скрыта (`vpn_alert.dart:37-39`). План: F «Kill switch на Android».
12. **Сбои, видимые только тостом (`HostNotice`), следа в журнале нет**: `reconnectFailed` — переподключение после смены настроек (`live_core_host.dart:1738`), `initFailed` (`223`), `notSaved` — состояние не сохранено (`1142`), `vpnDenied` (`813`), `connectFailed` от `api.retry/disconnect/autoSettings/killSwitchSettings` (`893,910,1158,1185,1215`), `updateCheckFailed` (`1488,1501`). Тост пропал — следа нет. Нет в плане (T «Тосты — общая переделка» — про вид, не про след).
13. **Смена типа сети** (Wi-Fi ↔ мобильная, metered) — только шаг `net.switched` в trail (`docs/failures.md:429`), события нет; пользователю не объяснить, почему всё переподключилось. [вывод] Нет в плане (F «Память вердиктов по сетям» — другое).
14. **Подписка отдала пустой/резко урезанный список** — есть только `sub/removed {count}`, отдельного «подписка опустела» нет. [вывод] Нет в плане.

## 2. События неполные

**Нет категории уведомления** (`log_view.dart:111-128`; уровень в скобках): `conn/connectFailed` (error), `core/tunNeedsAdmin` (error), `core/stateLost` (error — потеря данных), `core/stateRestored` (warn), `core/sysProxy` с ошибкой (warn), `core/deprecated` (warn), `dns/failed`, `dns/failedOnNode`, `sub/diverged` (по замыслу без уведомления), `speed/failed`, `core/updateFailed` и др. `update*` (у `updateAvailable` свой путь: `app/lib/core/update_flow.dart:71`). Часть — осознанно «только журнал», но error-события без уведомления выглядят пропуском. План: только `dns/*` — F «Этап 4 Sentinel» (категория для dns/failed и dns/failedOnNode).

**Нет текста**: у каждого типа каталога подпись и фраза есть (сторожевой тест `core/test/event_catalog_test.dart`, `pendingLabels` пуст; описание `event_text.dart:249-501`); общий фолбэк `'${cat} / ${type}'` (`event_text.dart:502`) сработает для неописанных `user/*` и для любых будущих типов. Слабые тексты: `conn/lost` (всегда одна фраза), `conn/offline` («The system reports no connection», `event_text.dart:273`; неверно, когда источник — пробы, `data.source` не используется), `core/crashed` (`401`, не различает отзыв VPN, п. 1.3). «Последняя копия» у `ruleSetFailed` без учёта `hasCopy`, l10n подписей Auto/Proxy/Direct — план: F «Этап 4 Sentinel».

**Нет действий там, где очевидны** (действия строки — `app/lib/widgets/event_rows.dart:201-244`, `eventOpenTarget:146-162`; кнопки в шторке уведомления — только для `site`, `app/lib/core/system_notifier.dart:124-128`):
- `conn/failing`: ни одной кнопки (только `cat=='site'`, `event_rows.dart:205`). План: F «Единый вид событий о сбоях».
- `node/addressMissing`: нет «Open» — кейса `node` в `eventOpenTarget` нет (открыть источник/ноду). Нет в плане.
- `conn/connectFailed`, `core/tunNeedsAdmin`, `core/down`, `core/crashed`: нет «Retry» / «Open settings» / «Remove system proxy» (при `core/down` с `proxy:'kept'` интернет заблокирован, а кнопки «Remove» в строке нет). Нет в плане.
- `rules/ruleSetFailed`: только «Open», нет «Retry» (у `sub/failed` Retry есть, `event_rows.dart:226-230`). Нет в плане.
- `core/stateLost` / `stateRestored`: нет «Send report». Нет в плане.
- `dns/failed`: «Open» есть, нет «Switch server / Check now». Нет в плане.
- `sub/removed`: нет списка пропавших серверов и отметки «среди них используемый». Нет в плане.
- Уведомления: кнопки только у `site/*`; у всех остальных тап открывает Logs без действия. Нет в плане.

**Не отвечают на «почему»** — приложение не использует `why/trail/cause` (общее наблюдение): в строке `site/unreachable` есть чекер (`event_rows.dart:464-481`), у остальных причины нет; `core/restarted` без причины падения. План: F «Единый вид событий о сбоях», F «Этап 4».

**Дубли/производные одного корня**:
- Авария ядра: `core/crashed` → `core/restartFailed` ×N (`info`, verdict `consequence`, `service.dart:1813`) → `core/down` → `core/restarted` — 3–4 строки на один корень. План: F «Разбор ложных сигналов» (ядро/туннель упали).
- `conn/failing` и `site/unreachable` — один механизм подозрения, тип выбирается `_siteKind` (`service.dart:935-942`): одна беда под разными типами. План: F «Единый вид событий о сбоях», T «Журнал → таблица состояний».
- `conn/lost` + `conn/offline` + `site/unreachable` + `conn/failing` при отсутствии сети: следствия остаются отдельными строками (с `cause`, UI не сворачивает). План: F «Разбор ложных сигналов».
- `dns/failed` vs `dns/failedOnNode` (`ctx/dns_failover.dart:989`): один сервер — два типа. План: F (категория уведомления dns/*).
- `sub/*` пишут двое: ядро (автообновление, с вердиктом: `service.dart:2221-2228`) и приложение (ручное, без вердикта: `live_core_host.dart:1826,1949`; `updated/removed/back` — `1810,1979-1994`). Тип один, набор полей разный. Нет в плане (T «Событие проверки источника — редизайн» — общее).
- `rules/fallback` и `rules/targetLost` — один исход («If unavailable») разной природы, оба под `autoSwitch`. Нет в плане.

**Тихие потолки (CLAUDE.md «Never hide problems»)**: `restartFailed` пишется, только пока `_attempt <= _backoff.length` (`service.dart:1809-1812`, комментарий «a dead server retried every 30 s would fill it»); `sub/failed` — только первый сбой после удачного (`docs/core.md`, таблица, `sub/failed`); `core/deprecated` — раз за запуск (`service.dart:2712`); `conn/failing` — не больше `FailureBook.maxEvents` на окно, остаток сложен на последнее событие и виден в Raw (`service.dart:370-380`; это видимая свёртка). Явное молчание — `restartFailed` и `sub/failed`. Нет в плане.

**Уровни/атрибуция**: `core/restartFailed` — `info` (доки: error, `docs/core.md:1417`); не-ручной `core/updateFailed` — `info` (`appupdate.dart:831`); `conn/disconnected by:'error'` описан в `event_text.dart:268` и `docs/core.md:1397`, но ядро его не пишет (единственный автор — `service.dart:3369`, `by:'user'`). Нет в плане.

## 3. Каталог ↔ код ↔ доки

Сверка машинная: `core/test/event_catalog_test.dart` сканирует точки записи (`_event(`, `eventBook.add`, `SuspicionEvent`, app-`_journal`) и сверяет с `eventCats` и подписями, поэтому «пишется, но нет в каталоге» невозможно при зелёном тесте (тест в этом аудите не запускался).
- **В каталоге, но не пишется нигде:** `sub/dead` (только мокап; `mockupOnly` в тесте). Подпись (`event_text.dart:345`) и категория `subFailed` (`log_view.dart:121`) под него есть. [проверено]
- **Описано, но ядро не пишет:** `conn/disconnected by:'error'` (см. выше).
- **Пишется, но нет в `docs/core.md` (таблица ~1389-1425):** `sub/diverged`, `dns/failedOnNode`, `core/updateAvailable`, `updateFailed`, `updateChannelEmpty`, `updateDownloaded`, `updateDeltaFailed`, `updateInstalled` (в `docs/logs.md:104-130` они есть). План: F «Этап 4 Sentinel» (последняя строка про каталог в `logs.md`).
- **Расхождения `docs/core.md` с кодом:** `conn/lost` `data {}` и `conn/offline` «по строке sing-box `missing default interface`» (`core.md:1399-1400`) — устарело: теперь корни Sentinel (`service.dart:1455-1506`, `data.source`, `downMs`); `restartFailed` «только первые три, error» против `_backoff.length`, `info`/`consequence`.
- **Нет в `docs/logs.md`:** `net/captive` (типа ещё нет, п. 1.1); поля `repeat` у `site/*` (F, там же).
- **`user/*`** (`connect, disconnect, mode, route, sysProxy, pin`, `event_text.dart:250-257`) в каталоге нарочно нет; пишет приложение через `_journal` (`live_core_host.dart:2636`). Действия над правилами/игнором/подписками (кроме обновления) в журнал не пишутся. [вывод по перечню `_journal`-вызовов]

## Сводка по плану

- Уже в плане: captive, категории dns/*, trail в деталях, свёртка следствий, единый вид сбоев, ложные/дублирующие сигналы, реклама/трекеры, отзыв VPN (T), политика tunTcpDead (T), Kill switch (F), каталог в `logs.md` (F), журнал-как-таблица (T), «Down everywhere» (T).
- Нет в плане: п. 1.5, 1.6, 1.7, 1.8, 1.10, 1.12, 1.13, 1.14 (и 1.2/1.4 частично); кнопки у `connectFailed/tunNeedsAdmin/down/node/addressMissing/ruleSetFailed`; тихие потолки `restartFailed`/`sub/failed`; два автора `sub/*`; потеря пина записывается как действие пользователя.