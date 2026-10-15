# Windows — всё по ПК-версии (не скоро: после Android)

Отдельный файл решением пользователя 2026-10-16: Windows-пункты не живут в `features` / `bugs` / `unfinished`. Сюда же —
всё, что найдено по Windows/jormd в ходе работы над Android. Id `S..` — из `archive/_work/inventory_states.md`.

## Приложение, сборка, релиз

- **Flutter-приложение для Windows** (S60): Visual Studio C++, сборка, системный прокси из приложения, трей, TUN (админ).
- **Апдейтер Windows: zip + `jorm-updater.exe`, сторож, откат** (S44, `docs/updates.md` §9).
- **CI/релиз для Windows** (S45).

## Ядро на Windows

- **Ядро не знает сеть**: jormd/десктоп не шлют `setNetwork` — Sentinel видит только пробы и `updated default interface`
  sing-box. Нужен наблюдатель сети (NotifyIpInterfaceChange / NLM) → `POST /api/network`.
- **dev-jormd: `dart.exe` vs `dartvm.exe` в `selfProcessPaths`** (S59, `config.dart:99`).
- **Детектор TUN-TCP на Windows TUN не проверен** (S41, `docs/core.md:509`).

## Недоделанное эпохи мокапа

- **Kill switch для TUN на Windows (WFP)** (S26): непостоянные WFP-фильтры; текст шторки «In TUN mode a reboot also lifts the block».
- **«Запуск с системой»: Выкл / При входе / До входа + kill switch с загрузки + «Блок до старта VPN»** (S27, `rules.md:520–558`).
- **Приложения на ПК: процессы, «Add .exe», иконки, «Survive updates»** (S28); **пикер файла для Process** (S35, `rules.md:6–8`).
- **Собственные всплывающие окна уведомлений (`desktopStyle: own`)** (S55, `connect-model.md:745–749`).
