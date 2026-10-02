# Jormungand — Flutter-приложение

Настоящий клиент поверх Dart-ядра `../core` (пакет `jormungand_core`). Первая цель — Android,
потом Windows. Макет (`design/`) остаётся образцом: виджеты названы так же (ConnectDock, PowerTab,
SourceCard, NodeRow), цвета и геометрия генерируются из него.

Состояние: каркас. Есть оболочка (4 вкладки, темы, масштаб текста 90–120 %, en/ru), заглушки
страниц, заглушка `VpnService` + `MethodChannel`. Флаттера на момент написания на машине не было —
код ни разу не компилировался, первая сборка потребует правок.

## Раскладка

```
app/
  pubspec.yaml, l10n.yaml, analysis_options.yaml
  lib/
    main.dart, app.dart          MaterialApp: тема, локаль, политика масштаба текста
    core/core_host.dart          CoreHost (интерфейс) + IdleCoreHost (заглушка) + CoreHostScope
    state/app_settings.dart      тема / масштаб / язык (ChangeNotifier + InheritedNotifier)
    platform/vpn_channel.dart    MethodChannel `jormungand/vpn`: prepare / start / stop
    shell/home_shell.dart        нижняя навигация Home · Nodes · Logs · Settings, Back -> Home
    pages/                       home, nodes, logs, settings (Settings: Appearance + Language рабочие)
    widgets/                     AppView, ConnectDock + PowerTab, ConnBadge, SourceCard, NodeRow, SettingsRow
    theme/app_colors.g.dart      GENERATED: AppColors (ThemeExtension), 3 темы, ThemeData
    widgets/dock_paths.g.dart    GENERATED: фигуры дока из design/tools/geometry.mjs
    l10n/app_{en,ru}.arb         GENERATED из словаря макета; l10n/l10n.dart — `context.l10n`
  assets/fonts/                  Twemoji-флаги (TTF, сконвертирован из woff2 макета)
  android_overlay/               рукописные части android/ (манифест, Kotlin-шаблоны)
  tool/                          генераторы и скрипт наложения Android
  test/shell_test.dart
```

Цвета в виджетах — только `context.colors.<name>` (`AppColors`); `rgba(var(--x-rgb), a)` из CSS это
`context.colors.x.tint(a)`. Масштаб текста: корневой `MediaQuery` без масштабирования, `AppView`
масштабирует только содержимое (`ContentScale`) — заголовки и нижняя навигация не растут.
Состояние: `ChangeNotifier` + `InheritedNotifier`, без пакетов — пока в приложении два маленьких
хранилища, а настоящее состояние живёт в ядре.

## Первая сборка (Android)

Нужны Flutter SDK (stable), Android SDK / Studio, JDK 17.

```sh
cd app
git add -A .                         # на случай, если flutter create что-то перезапишет
flutter create --platforms=android,windows --org dev.jormungand --project-name jormungand .
node tool/apply_android_overlay.mjs  # манифест, Kotlin, applicationId, minSdk 26
git diff pubspec.yaml lib/main.dart  # flutter create не должен был их тронуть; если тронул — git checkout
rm test/widget_test.dart             # счётчик-тест от flutter create, наш — test/shell_test.dart
flutter pub get                      # заодно gen-l10n -> lib/l10n/gen/
flutter analyze
flutter test
flutter run                          # устройство / эмулятор
flutter build apk --release --split-per-abi
```

`applicationId` (`dev.jormungand.app`) задаётся в одном месте — константа `APPLICATION_ID` в
`tool/apply_android_overlay.mjs`; скрипт пишет её в `android/app/build.gradle(.kts)` (namespace,
applicationId) и в `package` Kotlin-файлов. `flutter create --org dev.jormungand` нужен только для
структуры проекта.

Зависимость `jormungand_core: path: ../core` тянет `grpc`, `protobuf`, `win32`, `ffi` — на Android
они только собираются, не вызываются. Если `pub get` упрётся в конфликт версий — первое место, где
смотреть.

## libbox.aar

Положить в `app/android/app/libs/libbox.aar` (в git не идёт). Взять готовый релиз sing-box для Android
или собрать из исходников sing-box (`cmd/internal/build_libbox`, нужен gomobile-форк, см. документацию
sing-box). Достаточно положить файл и снова запустить `node tool/apply_android_overlay.mjs` — скрипт
добавит `implementation(files("libs/libbox.aar"))`. Дальше — `JormungandVpnService.startTunnel`
(комментарий в классе: PlatformInterface, openTun, protect). Конфиг sing-box по-прежнему строит
Dart-ядро; сервис только открывает tun.

## Генераторы

`node app/tool/gen_all.mjs` (можно по одному), результат коммитится. Запускать после правок:

| Источник | Генератор | Результат |
|---|---|---|
| `design/src/css/00-themes.css`, `js/90-themes.js` | `gen_theme.mjs` | `lib/theme/app_colors.g.dart` |
| `design/tools/geometry.mjs` | `gen_dock.mjs` | `lib/widgets/dock_paths.g.dart` |
| `design/src/js/04-i18n-ru.js` (+ `tool/i18n_extra.json`) | `gen_i18n.mjs` | `lib/l10n/app_{en,ru}.arb`, `tool/i18n_keys.json` — см. `docs/i18n.md` |
| `design/src/assets/TwemojiCountryFlags.woff2` | `gen_assets.mjs` | `assets/fonts/TwemojiCountryFlags.ttf` (Flutter не читает woff2; пересборка только при смене источника, нужен npm-пакет `wawoff2`, см. шапку скрипта) |

## Заглушки и TODO

- [ ] `CoreHost`: настоящая реализация поверх `CoreService` / `CoreApi` (их выделяют из `core/lib/src/daemon.dart`); потоки трафика, соединений, событий, логов; подключение = `VpnChannel.prepare` -> конфиг ядра -> `VpnChannel.start`.
- [ ] Android: libbox (см. выше), `PlatformInterface`, события сервиса в Dart (`onRevoke`, up / down), запрос `POST_NOTIFICATIONS`, строки уведомления в `strings.xml`, иконка уведомления (монохромная), действие «Отключить».
- [ ] Android: самообновление (`REQUEST_INSTALL_PACKAGES` в манифесте уже есть) — загрузка APK, проверка подписи / хеша, установка через `PackageInstaller`.
- [ ] Страницы: Home (StatCards, сегменты режимов, VpnAlert), Nodes (SourceCard / NodeRow, вкладки Simple / Profiles, редактирование), Logs (Events / Raw), остальной Settings, листы (Route, Rules, Add, …) со стеком «Назад закрывает верхний лист».
- [ ] Иконки нижней навигации сейчас Material (`Icons.*`), в макете — свои SVG; точки непрочитанных ошибок / предупреждений на Logs.
- [ ] Анимации дока (смена цвета 0.7 с, свечение, пульс при `connecting`); сейчас рисуется статично.
- [ ] Сохранение `AppSettings` (тема, масштаб, язык) вместе с остальным состоянием.
- [ ] Шрифт Inter не вложен (макет тоже его не грузит, берёт системный); флаги — через `Flags` (Twemoji).
- [ ] Windows: `flutter create` уже делает `windows/`; ядро запускает sing-box само, TUN требует админа (`core/tunNeedsAdmin`); системный прокси, автозапуск.
- [ ] Иконка приложения, имя / метки, подпись релиза (`key.properties`), CI-сборка APK.
