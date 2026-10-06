# Jormungand — Flutter-приложение

Настоящий клиент поверх Dart-ядра `../core` (пакет `jormungand_core`). Первая цель — Android,
потом Windows. Макет (`design/`) остаётся образцом: виджеты названы так же (ConnectDock, PowerTab,
SourceCard, NodeRow), цвета и геометрия генерируются из него.

Состояние: Android-сборка работает (release-APK, VPN через libbox, самообновление); на Windows ядро
запускает sing-box само. Экраны Home, Nodes, Logs, Settings, Route, Rules портированы из макета.
Платформенные различия, сопоставление файлов, синхронизация с макетом, тулчейн и сборки — в
`../docs/platforms.md`; обновления — `../docs/updates.md`.

## Раскладка

```
app/
  pubspec.yaml, l10n.yaml, analysis_options.yaml
  lib/
    main.dart, app.dart          MaterialApp: тема, локаль, политика масштаба текста
    core/                        мост к ядру: core_host.dart (CoreHost — интерфейс для UI), live_core_host.dart
                                 (CoreService + каталог), platform_seams.dart (BoxRunner / системный прокси / каталог данных
                                 по платформе), libbox_runner.dart (BoxRunner Android поверх libbox), app_update.dart,
                                 logs_controller.dart, settings_model.dart, форматтеры и тексты
    state/app_settings.dart      тема / масштаб / язык (ChangeNotifier + InheritedNotifier)
    platform/                    vpn_channel.dart (MethodChannel `jormungand/vpn`), files_channel.dart, notify_channel.dart (системные уведомления), platform_caps.dart
    shell/                       home_shell.dart (нижняя навигация Home · Nodes · Logs · Settings, Back -> Home), app_links.dart
    pages/                       home, nodes, logs, settings, route, rules
    widgets/                     карточки, листы (AppSheet), формы, строки, док (ConnectDock + PowerTab); имена как в макете
    theme/app_colors.g.dart      GENERATED: AppColors (ThemeExtension), 3 темы, ThemeData
    widgets/dock_paths.g.dart    GENERATED: фигуры дока из design/tools/geometry.mjs
    l10n/app_{en,ru}.arb         GENERATED из словаря макета; l10n/l10n.dart — `context.l10n`
  assets/fonts/                  Twemoji-флаги (TTF, сконвертирован из woff2 макета)
  android_overlay/               рукописные части android/ (манифест, Kotlin-шаблоны, libs/libbox.aar)
  tool/                          генераторы, apply_android_overlay.mjs, build_apk.ps1
  test/                          widget-тесты на FakeCoreHost; live_core_host_test (настоящий CoreService, фальшивый BoxRunner);
                                 libbox_runner_test (нужен core/tool/bin/sing-box)
```

Цвета в виджетах — только `context.colors.<name>` (`AppColors`); `rgba(var(--x-rgb), a)` из CSS это
`context.colors.x.tint(a)`. Масштаб текста: корневой `MediaQuery` без масштабирования, `AppView`
масштабирует только содержимое (`ContentScale`) — заголовки и нижняя навигация не растут.
Состояние: `ChangeNotifier` + `InheritedNotifier`, без пакетов; настоящее состояние живёт в ядре.

## Сборка

Тулчейн (Flutter, Android SDK, JDK, Go, NDK) — в `G:\ANDROID_DEV`; `android/` создаётся скриптами
(`flutter create` + `node app/tool/apply_android_overlay.mjs`: манифест, Kotlin, applicationId, minSdk,
управляемый блок в `build.gradle`). Проверки в `app/`: `flutter analyze --no-fatal-infos`,
`flutter test`.

- `pwsh core/tool/build_libbox.ps1` — `libbox.aar` из исходников sing-box той же версии, что у
  десктопного ядра; кладётся в `android_overlay/app/libs/` (в git не идёт).
- `pwsh app/tool/build_apk.ps1 [-DryRun]` — release-APK, всегда подписан релизным ключом, версия
  выбирается по ленте обновлений; `-DryRun` печатает выбор и источник подписи, ничего не собирая.
  Ключ, версии, `adb install -r` — `../docs/platforms.md`, `../docs/updates.md`.
- CI: `.github/workflows/release-android.yml` (beta на push, stable на тег `vX.Y.Z`).

Android-сторона: `JormungandVpnService` — служба переднего плана, tun по `TunOptions` libbox;
`LibboxBox` — libbox без туннеля (пинг, Speed Test). Конфиг строит Dart-ядро и передаёт через
`VpnBridge`; `LibboxRunner` добавляет к нему службу `api` (loopback, случайный секрет), через неё
работают Auto, трафик, соединения и журнал — как с десктопным процессом.

## Генераторы

`node app/tool/gen_all.mjs` (можно по одному), результат коммитится. Запускать после правок:

| Источник | Генератор | Результат |
|---|---|---|
| `design/src/css/00-themes.css`, `js/90-themes.js` | `gen_theme.mjs` | `lib/theme/app_colors.g.dart` |
| `design/tools/geometry.mjs` | `gen_dock.mjs` | `lib/widgets/dock_paths.g.dart` |
| `design/src/js/04-i18n-ru.js` (+ `tool/i18n_extra.json`) | `gen_i18n.mjs` | `lib/l10n/app_{en,ru}.arb`, `tool/i18n_keys.json` — см. `docs/i18n.md` |
| `design/src/assets/TwemojiCountryFlags.woff2` | `gen_assets.mjs` | `assets/fonts/TwemojiCountryFlags.ttf` (Flutter не читает woff2; пересборка только при смене источника, нужен npm-пакет `wawoff2`, см. шапку скрипта) |

## TODO

- Logs: подписи тостов в оболочке.
- Kotlin: `registerMyInterface` — пустышка.
- `filesDir/libbox/configuration.json` содержит секрет API sing-box.
- Позже: скорость в уведомлении VPN, статус «VPN отозван», версия sing-box на Android, урезать теги libbox (APK ~100 МБ), упрощённый per-app на Android.
