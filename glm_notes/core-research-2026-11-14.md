# Разведка ядер, 2026-11-14 (4 агента; здесь — детали, файлы планирования пользователя не трогаем)

Решение пользователя: **sing-box-lx делаем**. Переход на mihomo — план записан в `to_think.md` по явному указанию.

## Корневая причина поломки vless-reality (подтверждено)

- Xray-core **v26.9.8** (08.09.2026) поднял `xtls/reality` → сервер требует в ClientHello PQ key share
  **X25519MLKEM768**; sing-box (все версии 1.12–1.15, включая dev) вырезает его
  (`common/tls/reality_client.go`, фильтр из коммита dbdcce2, май 2025) → сервер молча уходит в fallback,
  клиент видит `reality verification failed`. Ломается на всех fingerprint'ах. Не mldsa65, не XHTTP-only.
- Источники: sing-box#4520 (открыт, мейнтейнер молчит), XTLS#7259 (RPRX: требование не откатят).
- Фикс апстрима: коммит **`3950135`** «Stop removing X25519MLKEM768…» в ветке `testing` от 14.11.2026;
  в релизах нет (1.14.4 / 1.15.0-alpha.13 от 24.10.2026). Вторая дыра: session-id sing-box пишет ClientVer
  «1.8.2» → отбраковка на серверах с `minClientVer` (дефолт v26.7.11–26.9.x = v26.3.27).

## Временные фиксы reality

1. Собрать sing-box `testing@3950135+` (Win-бинарь в `core/tool/bin/` + пересборка `libbox.aar` — оба пути дёшевы).
2. Серверный пин Xray **v26.6.27** на нодах Remnawave (проверено несколькими отчётами; xray-клиенты не ломаются).
   Или v26.7.28 + `"minClientVer": "1.0.0"` в realitySettings (для sing-box не подтверждён, для mihomo — да).
3. Remnawave node бандлит xray (docs.rw/install/remnawave-node); пин версии — remnawave-scripts (`remnanode.sh`),
   build-args `XRAY_VERSION`.

## Вариант «одно ядро»: sing-box-lx (ВЫБРАН)

`Leadaxe/sing-box-lx`, база апстрим 1.14.4, ветка `lx`, ребейз за днями, всё за build-тегами
(сборка без тегов = апстрим байт-в-байт). 278★, 1 мейнтейнер, проекту 7 мес., 4 replace-зависимости
(sing-tun, gvisor, utls, wireguard-go → свои сабмодули).

- XHTTP-клиент (`transport/v2rayxhttp/`, режимы auto/packet-up/stream-up/stream-one, xmux; stream-one+REALITY
  «device-verified» автором).
- REALITY X25519MLKEM768: опция `tls.reality.key_share: classical|hybrid`, **default `""` = как в
  отпечатке uTLS** (уточнение 2026-11-14 по коду форка, не «hybrid»): chrome-отпечаток несёт
  X25519MLKEM768 → дефолт закрывает #4520; «hybrid» требует отпечаток с этим share, «classical» —
  только для серверов < 26.9.8.
- VLESS PQ encryption (`mlkem768x25519plus`) — SPEC 012/032.
- Не поддерживает: REALITY PQV (ml-dsa-65 подписи) — как и вся sing-box-линейка.
- Расширения libbox CommandClient (tag `with_lx_command`): GetRules/GetGroups/GetPool/
  SubscribeDNSQueries/Connection.detourList — observability богаче апстрима.
- Релиз v1.14.4-lx.33 (07.11.2026): **готовый `libbox-1.14.4-lx.33.aar`** + legacy-aar, Win exe (amd64/arm64/
  386-legacy), SHA256SUMS. Параллельная ветка v1.15.0-lx.1-rc.1.
- Митигация supply-chain: собирать из аудированного дерева самим, пин версий, SHA256SUMS, следить за ребейзом.
- Перед основным переходом: **своя матричная проверка** (xhttp режимы + reality против Xray ≥26.9.9).

Запасной форк: `shtorm-7/sing-box-extended` (v1.14.3-extended-2.7.3 от 19.10.2026; MLKEM opt-in
`support_x25519mlkem768`; **XHTTP сломан против Xray 26.9.x — issue #151 открыт**; aar не публикуется).
Нишевый: `ushan0v/sing-box-forkop` (14★, MLKEM default true по комментарию юзера) — только источник патчей.

## Апстрим sing-box

XHTTP не будет: PR #4326 закрыт без единого комментария и залочен, #3879 закрыт. Единственное движение —
`3950135` в `testing`. KaringX/sing-box и hiddify-sing-box пробелы не закрывают.

## Xray-путь (fallback, дороже и с деградациями)

- TUN нативный: `proxy/tun` с v26.1.23 — Win/Linux/macOS/FreeBSD, Android через `XRAY_TUN_FD` (или
  `StartLoop(config, tunFd)` в AndroidLibXrayLite; env в исходнике wrapper — `xray.tun.fd`, сверить).
  Windows: Wintun.dll рядом с xray.exe; `autoSystemWfpBlockLeak` (dns/tcp/udp/icmp/misconfigtun/all/allexceptlan),
  `autoSystemRoutingTable`, `autoOutboundsInterface`. Нет: стеки mixed/system/gvisor, strict_route,
  route_exclude_address, per-app на уровне ядра (VpnService Builder на Android).
- hysteria2: in+out есть, клиент молодой (flow-control блок Oct 2026, статы/UDP #5868/#6574).
- **API-тупик**: per-connection слоя нет (#6634 closed **not_planned**); `xray api`: агрегаты StatsService,
  per-user online-IP, HandlerService, OverrideBalancerTarget (живое переключение balancer'а), AddRule/RemoveRule;
  access.log без байтов/длительности. PR #5844 UserConnTracker висит с 03.2026. Панели — только пер-юзер.
- Полная замена = редизайн живых соединений/Sentinel/Auto-статистики (~10-12k строк, 15-20 файлов + 80+
  тестовых), потеря DNS failover (нет resolve-action, hot-перечитывания списков, DoT в DNS-модуле),
  TUN-стеков; Android: в AndroidLibXrayLite **нет protect()-хука** (свои соединения — exclude своего UID или
  sockopt.interface); нет cache_file-аналога. Пинг переносится 1:1 (`user`-matcher = аналог `auth_user`).
- Аддитивное второе ядро (xray только для vless/xhttp-нод, sing-box default): ~3.5-4.5k строк, 15-20 новых
  файлов, 5-7 общих touched (planGroup core-параметр, один if в `_startSingBox` `service.dart:4177-4236`,
  имя бинарника в `killOrphans`), нулевая регрессия sing-box (golden защищает). Деградации на xray-коннектах:
  conn-док (агрегат или скрыть), Sentinel conn-детекторы и network-move по логу, DNS failover, Speed Test,
  tun_check; Auto рестартами; пинг требует throwaway-xray тестера. `Node.outbound` — sing-box JSON по
  определению (`node.dart:13`); вторая форма `xoutbound` без смены identity (variantOf/serverIdentity не трогать).
  Remnawave отдаёт Xray JSON подписки (формат XTLS#4877) — парсить напрямую в xoutbound.

## mihomo (план перехода — в `to_think.md` по указанию пользователя)

MetaCubeX/mihomo v1.19.34 (11.11.2026), релизы из ветки `Alpha` (main осиротел — code-search врёт).
VLESS+REALITY (`support-x25519mlkem768`, с v1.19.31 от 14.09.2026), VLESS PQ encryption 1rtt/0rtt,
XHTTP-клиент (v1.19.28-32), hy2, masque/mieru/anytls, TUN. API: REST/WS /connections (стрим с байтами),
DELETE /connections/{id}, PUT /proxies (селекторы), /traffic, /logs, /memory; `external-controller-unix` и
`external-controller-pipe` (Windows named pipe); `profile.store-selected`. Android: ClashMetaForAndroid
(49k★, активен) — но это не libbox.aar, интеграция с нуля (конфиг-модель YAML, .srs→.mrs rule-providers,
DNS actions, fd-passing/protect по образцу CFMA). Цена ~ «новый клиент», trust выше всех.

## hy2-отвалы на sing-box

Давняя слабость, не регрессия: QUIC keepalive не уходит при idle (подозрение «application limited» в форке
quic-go, коммит 0cae1a7 от 30.08.2026; не подтверждено мейнтейнерами). Throne#1908 (смерть ~120с idle,
закрыт not planned), sing-box#3043, #4375 (осиротевшие UDP-сессии). Обходы: лёгкий keepalive-трафик из
приложения ~раз в минуту, исключение из doze/батареи, серверные idle-таймауты, port hopping. Версии-фикса нет.
У xray/mihomo свои QUIC-стеки — там поведение другое.

## Разное

- В Happ hy2, по данным релизов Happ, обслуживает sing-box core (Happ несёт оба ядра; tun-type:
  singbox/tun2proxy/default/xray). Проверка пользователем — была в to_check.md, перенесена сюда по требованию:
  «в Happ глянуть, какое ядро реально обслуживает hy2-профиль».
- tuic/anytls пользователь отклонил как нерелевантные.
- Числа для аддитивного пути: core/lib/src 103 dart-файла, 56 упоминают sing-box, 10 импортируют sbapi;
  83-86 из 121 тест-файлов core с sing-box; golden: «XHTTP is not in sing-box» в `catalog_golden_test.dart`
  + `golden/catalog.json` (`catalog_model_test.dart:883,896`).
