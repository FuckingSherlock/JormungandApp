# Фичи — новые запланированные (решено делать)

Запланировано в эпоху Android (с 2026-10-03), решение «делаем» есть. Спорное и недодуманное — в `to_think.md`;
недоделанное из эпохи мокапа — `unfinished.md`; что есть в мокапе, но потеряно в Android — `apk_losted.md`.
Источник истории пунктов: `archive/` (inventory `_work/inventory_states.md`, id `S..` в скобках).

## Android: сеть и TUN

- **gVisor — стек TUN по умолчанию на Android** (S57). Решение пользователя 2026-10-11: делаем точно. Сейчас
  `tunStack = 'mixed'` (`core/lib/src/catalog/settings.dart:55`). Остальные стеки остаются выбором в Settings → Connection.
- **Политика по `tunTcpDead`** (S40): детектор и события `core/tunTcpDead` / `tunTcpBack` есть (`core/lib/src/service.dart:216`,
  `tun_ingress.dart`); нет реакции (авто-смена стека? уведомление?) и пробы достижимости Telegram DC через выход.
- **Детектор «не открывается» без опоры на `up > 0`** (S9): `failures.dart:74` уже по `down == 0`, но повтор сайта
  в `auto.dart:623` (`_failDests`) запоминает адрес только при `c.up > 0` — мгновенные отказы (~85 % с up=0) не повторяются.
- **«Direct → если не открывается → цель» (выученный список)** (S3): детектор по закрытым direct-соединениям
  (принято 0 / таймаут / RST, 2 отказа подряд, не когда лежит весь прямой путь) → домен в выученный локальный rule-set,
  правило «learned → цель» перед Direct; список в Rules (домен, когда, почему; удалить/очистить), TTL ~7 дней.
  Проверить, что sing-box сам перечитывает local rule-set. Основа — `FailureBook` (`core/lib/src/failures.dart`).
- **Упрощённый per-app на Android: «только из списка» / «все, кроме списка»** (S30) через `include_package` /
  `exclude_package` (`docs/platforms.md:32`).

## Android: уведомления, статус

- **Скорость в тексте постоянного уведомления VPN** (S6): `JormungandVpnService.kt.tmpl:40` TODO; `connect-model.md:731`.
- **Статус «VPN отозван системой»** (S7): `onRevoke` закрывает туннель (`JormungandVpnService.kt.tmpl:115`), в UI статуса нет.
- **Фоновая проверка обновлений (WorkManager) + системное уведомление «Update available»** (S46): раз на версию,
  флаг `updateAvailable` в `notifCfg` и строка в Settings → Notifications (`docs/updates.md:195, 495–497`).

## Ядро

- **Ядро в отдельном isolate (вариант B)** (S56): план по этапам 0–6 — `archive/core_isolate_plan.md`. Ничего не начато
  (нет `core/lib/src/remote/`, `CoreApi` синхронный).

## Обновления, релизы, инфраструктура

- **Вторая лента обновлений на другой инфраструктуре** (S50): сейчас одна, GitHub `jormungand-releases` (`appupdate.dart:32`).
  R2 на аккаунте не включён — выбрать хост.
- **Урезать теги libbox** (S51): APK ~100 МБ, `build_libbox.ps1` берёт все теги sing-box.
- **Скиллы `sync-app` / `release`** (S52), опционально.

## Windows (после Android)

- **Flutter-приложение для Windows** (S60): Visual Studio C++, сборка, системный прокси из приложения, трей,
  TUN (админ, `core/tunNeedsAdmin`); подпункты ниже и в `unfinished.md` (автозапуск, kill switch WFP, окна уведомлений).
- **Апдейтер Windows: zip + `jorm-updater.exe`, сторож, откат** (S44): спецификация `docs/updates.md` §9; апдейтер
  запускается только на замену файлов.
- **CI/релиз для Windows** (S45): workflow, zip-артефакты, манифесты `windows`.
- **Детектор TUN-TCP на Windows TUN не проверен** (S41): пороги выведены из Android (`docs/core.md:509`).
- **dev-jormd: `dart.exe` vs `dartvm.exe` в `selfProcessPaths`** (S59, `config.dart:99`).

## Проверки на устройствах (пользователь)

- Тихая установка обновления на Android 12+ (S47).
- Android 8–9: procfs-владелец соединения; на API < 31 монитор сети не берёт VPN как «сеть по умолчанию» (S58).
- Kotlin: `registerMyInterface` — пустышка (`LibboxPlatform.kt.tmpl:195`); проверить, не лежит ли секрет API sing-box
  открыто в `filesDir/libbox/configuration.json` (S63).
