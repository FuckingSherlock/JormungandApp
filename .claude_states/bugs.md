# Багфиксы — найденные ошибки (решено чинить)

Каждый пункт живёт ровно в одном файле плана; исправлен — строкой в `archive/done.md` и удаляется отсюда.

## Ядро / Auto


## Android


## Тесты

- Нестабильный тест `app/test/live_core_host_test.dart:275` под полной нагрузкой `flutter test`.

## Windows

- **dev-jormd: `dart.exe` vs `dartvm.exe` в `selfProcessPaths`** (S59, `config.dart:99`).
- **Windows: ядро не знает сеть** (найдено 2026-10-15): jormd/десктоп не шлют `setNetwork` — Sentinel видит только пробы и `updated default interface` sing-box; смена Wi-Fi → Wi-Fi на ноутбуке не ловится так же, как было на Android. Нужен наблюдатель сети (NotifyIpInterfaceChange / NLM) → `POST /api/network`.
