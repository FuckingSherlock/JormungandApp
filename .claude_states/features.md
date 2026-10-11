# Фичи — новые запланированные (решено делать)

Приоритет — Android; Windows — после. Каждый пункт живёт ровно в одном файле плана (`features` / `unfinished` /
`apk_losted` / `to_think`); сделан — удаляется. Id `S..` — история в `archive/_work/inventory_states.md`.

## Android

- **gVisor — стек TUN по умолчанию на Android** (S57). Решение пользователя 2026-10-11: делаем точно. Сейчас
  `tunStack = 'mixed'` (`core/lib/src/catalog/settings.dart:55`). Остальные стеки остаются выбором в Settings → Connection.
- **Установка обновления: сразу системный диалог.** Сейчас «Download & install» → после загрузки ещё кнопка «Install».
  Нужно: после загрузки сразу вызывать системный диалог установки; кнопка «Install» остаётся, только если пользователь его отклонил.
- **Проверка обновлений, когда процесса приложения нет** (S46). Сейчас ядро проверяет при запуске (через 10 с) и раз в 24 ч,
  пока процесс жив (`core/lib/src/appupdate.dart:876` `startSchedule`) — то есть с включённым VPN или открытым приложением.
  Когда процесс выгружен, проверки нет: WorkManager + системное уведомление «Update available» (раз на версию, флаг
  `updateAvailable` в `notifCfg` и строка в Settings → Notifications; `docs/updates.md:195, 495–497`).
- **Детектор «не открывается» без опоры на `up > 0`** (S9): повтор сайта в `auto.dart:623` (`_failDests`) запоминает адрес
  только при `c.up > 0`, а ~85 % мгновенных отказов приходят с up=0 и не повторяются на других маршрутах.

## Ядро

- **Ядро в отдельном isolate (вариант B)** (S56): план по этапам 0–6 — `archive/core_isolate_plan.md`. Не начато.

## Инфраструктура

- **Вторая лента обновлений на другой инфраструктуре** (S50): сейчас одна, GitHub `jormungand-releases`. R2 не включён — выбрать хост.
- **Урезать теги libbox** (S51): APK ~100 МБ.
- **Скиллы `sync-app` / `release`** (S52), опционально.

## Проверки на устройствах (пользователь)

- Тихая установка обновления на Android 12+ (S47).
- Android 8–9: procfs-владелец соединения; на API < 31 монитор сети не берёт VPN как «сеть по умолчанию» (S58).
- Kotlin: `registerMyInterface` — пустышка (`LibboxPlatform.kt.tmpl:195`); не лежит ли секрет API sing-box открыто в
  `filesDir/libbox/configuration.json` (S63).

## Windows (после Android)

- **Flutter-приложение для Windows** (S60): Visual Studio C++, сборка, системный прокси из приложения, трей, TUN (админ).
- **Апдейтер Windows: zip + `jorm-updater.exe`, сторож, откат** (S44, `docs/updates.md` §9).
- **CI/релиз для Windows** (S45).
- **Детектор TUN-TCP на Windows TUN не проверен** (S41, `docs/core.md:509`).
- **dev-jormd: `dart.exe` vs `dartvm.exe` в `selfProcessPaths`** (S59, `config.dart:99`).
