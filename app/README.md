# Jormungand — Flutter-приложение

Настоящий клиент поверх Dart-ядра `../core` (пакет `jormungand_core`). Первая цель — Android,
потом Windows. Макет (`design/`) остаётся образцом: виджеты названы так же (ConnectDock, PowerTab,
SourceCard, NodeRow), цвета и геометрия генерируются из него.

Состояние: каркас + Home на настоящем ядре. Есть оболочка (4 вкладки, темы, масштаб текста
90–120 %, en/ru), страница Home (статистика, сегменты режимов, VpnAlert, ConnectDock) поверх
`CoreService` + каталога из `jormungand_core`, остальные страницы — заглушки, заглушка `VpnService` +
`MethodChannel`. Флаттера на момент написания на машине не было — код ни разу не компилировался,
первая сборка потребует правок (`LiveCoreHost` проверен отдельно на голом Dart: стабы `flutter` +
настоящий `CoreService` с фальшивым `BoxRunner`, тот же `test/live_core_host_test.dart`).

## Раскладка

```
app/
  pubspec.yaml, l10n.yaml, analysis_options.yaml
  lib/
    main.dart, app.dart          MaterialApp: тема, локаль, политика масштаба текста
    core/core_host.dart          CoreHost (интерфейс для UI) + значения (DockSummary, ExitState…) + CoreHostScope
    core/live_core_host.dart     LiveCoreHost: CoreService + Catalog; connect = checkBeforeConnect -> livePlan -> api.connect
    core/platform_seams.dart     openCoreHost(): BoxRunner / SystemProxyBackend / каталог данных по платформе; ChannelLibboxPort (Android: канал к VpnService / libbox)
    core/libbox_runner.dart      LibboxRunner: BoxRunner Android (libbox + служба `api` в конфиге, как у десктопного процесса); LibboxPort — шов к платформе
    core/format.dart             fmtRate / fmtBytes / длительность / флаг
    state/app_settings.dart      тема / масштаб / язык (ChangeNotifier + InheritedNotifier)
    platform/vpn_channel.dart    MethodChannel `jormungand/vpn`: prepare / start / stop / startBox / stopBox / status + события `jormungand/vpn_events` (VPN отозван)
    shell/home_shell.dart        нижняя навигация Home · Nodes · Logs · Settings, Back -> Home
    pages/                       home, nodes, logs, settings (Settings: Appearance + Language рабочие)
    widgets/                     AppView, ConnectDock + PowerTab + DockProfile, ConnBadge, StatCards, SegmentsCard, VpnAlert, SourceCard, EntryCard, NodeRow, SettingsRow; Nodes: AppSheet (листы), nodes_menus, nodes_forms (подписка, сервер), entry_editors (профиль, цепочка), source_entry_sheet, speed_test_sheet
    theme/app_colors.g.dart      GENERATED: AppColors (ThemeExtension), 3 темы, ThemeData
    widgets/dock_paths.g.dart    GENERATED: фигуры дока из design/tools/geometry.mjs
    l10n/app_{en,ru}.arb         GENERATED из словаря макета; l10n/l10n.dart — `context.l10n`
  assets/fonts/                  Twemoji-флаги (TTF, сконвертирован из woff2 макета)
  android_overlay/               рукописные части android/ (манифест, Kotlin-шаблоны)
  tool/                          генераторы и скрипт наложения Android
  test/                          shell_test, home_test (FakeCoreHost), live_core_host_test (настоящий CoreService, фальшивый BoxRunner), libbox_runner_test (LibboxRunner с десктопным sing-box за портом; нужен core/tool/bin/sing-box)
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

`pwsh core/tool/build_libbox.ps1` собирает `libbox.aar` (arm64, armv7, x86_64) из исходников sing-box
той же версии, что у десктопного ядра (`core/tool/bin/sing-box.exe`; исходники в
`G:\ANDROID_DEV\src\sing-box`, gomobile в `G:\ANDROID_DEV\gopath`; нужны Go, JDK 17, Android NDK из
`ANDROID_NDK_HOME` / `ANDROID_HOME\ndk`). Результат — `app/android_overlay/app/libs/libbox.aar` (в git не
идёт); `node tool/apply_android_overlay.mjs` копирует его в `android/app/libs/` и дописывает в
`build.gradle(.kts)` управляемый блок (`// >>> jormungand overlay`: зависимость libbox, подпись
`jormRelease`, proguard). Скрипт собирает ту же main-вариацию тегов, что и релиз sing-box для Android;
версию Go берёт из CI sing-box (`GOTOOLCHAIN`), `-LocalGo` — использовать установленный.

Android-сторона: `JormungandVpnService` — служба переднего плана, открывает tun по `TunOptions` libbox
(`VpnService.Builder`, собственный пакет исключён из VPN, сокеты sing-box через `protect`);
`LibboxBox` — libbox без туннеля для разовых экземпляров (пинг, Speed Test). Конфиг sing-box строит
Dart-ядро и передаёт в память процесса (`VpnBridge`, extras у Intent малы); к конфигу `LibboxRunner`
добавляет службу `api` (loopback, случайный секрет), через неё работают Auto, трафик, соединения и
журнал (`SingBoxApi`) — как с десктопным процессом.

## Релизная сборка APK

```sh
$env:JORM_ANDROID_KS_PASS = '...'
pwsh app/tool/build_apk.ps1 [-BuildName 0.1.0 -BuildNumber 2] [-RebuildLibbox]
```

Скрипт: `flutter create` (если нет `android/`) → libbox.aar (если нет) → overlay → ключ → `flutter build
apk --release --split-per-abi`. Ключ — `%USERPROFILE%\.jormungand\android-release.jks` (alias
`jormungand`), создаётся через `keytool`, если его нет; **сделать копию**: обновление поверх
установленного приложения возможно только с тем же ключом. `android/key.properties` (путь и alias, в
git не идёт) пишет скрипт; пароль — только переменная `JORM_ANDROID_KS_PASS`. В конце печатаются APK
(по одному на ABI), их sha256 и SHA-256 сертификата подписи для манифеста обновлений.

## Генераторы

`node app/tool/gen_all.mjs` (можно по одному), результат коммитится. Запускать после правок:

| Источник | Генератор | Результат |
|---|---|---|
| `design/src/css/00-themes.css`, `js/90-themes.js` | `gen_theme.mjs` | `lib/theme/app_colors.g.dart` |
| `design/tools/geometry.mjs` | `gen_dock.mjs` | `lib/widgets/dock_paths.g.dart` |
| `design/src/js/04-i18n-ru.js` (+ `tool/i18n_extra.json`) | `gen_i18n.mjs` | `lib/l10n/app_{en,ru}.arb`, `tool/i18n_keys.json` — см. `docs/i18n.md` |
| `design/src/assets/TwemojiCountryFlags.woff2` | `gen_assets.mjs` | `assets/fonts/TwemojiCountryFlags.ttf` (Flutter не читает woff2; пересборка только при смене источника, нужен npm-пакет `wawoff2`, см. шапку скрипта) |

## Заглушки и TODO

- [x] `CoreHost`: `LiveCoreHost` поверх `CoreService`; статус, трафик, события, каталог (сохранение с задержкой 400 мс), переподключение при смене плана, добавление подписки. Не сделано: пинг-тесты по запросу (только после добавления подписки), `pingOnLaunch` / `connectOnLaunch`, `appInfo` каталога (список установленных приложений), поток логов в UI.
- [x] Android: `LibboxRunner` над каналом (`core/libbox_runner.dart`, `ChannelLibboxPort`) и Kotlin-сторона (libbox, `PlatformInterface`, VpnService) написаны; Dart-часть проверена с десктопным sing-box за портом, **Kotlin и сборка libbox / APK ещё не запускались** (нет Go / NDK на момент написания) — ждите правок при первой сборке.
- [x] Settings целиком (Auto mode, Appearance, General, Notifications, Connection, DNS, Data) и NavCards Home (Auto mode, DNS — листы; Rules — через `AppLinks.openRules`; Speed Test — последний результат). Различия Android — `platform/platform_caps.dart`. Не сделано / только хранится: установка обновления на Windows (нет `jorm-updater`, показывается путь к файлу), `Launch at startup` (Windows: автозапуск; Android — не применимо), `Start minimized` и группа «Pop-ups on PC», строка статуса в шторке; пинг DNS идёт напрямую (не через VPN), `quic://` не измеряется; версия sing-box на Android пуста; Kotlin-часть `FilesChannel` / `UpdateInstaller` не запускалась.
- [ ] Home: Route по нажатию на строку дока / «Open Route» (сейчас не делает ничего); лист Live connections; пинг верхних серверов по нажатию на рамку задержки.
- [x] Nodes: вкладки Simple / Profiles, SourceCard / EntryCard / NodeRow, режим правки, поиск, меню Add / ⋮, формы подписки и сервера, редакторы профиля и цепочки, удаление с последствиями, Speed test. Листы — `showModalBottomSheet` (`app_sheet.dart`), не стек «от верха экрана» как в макете. Не сделано: QR-код (в листе «Поделиться» пока текст + Copy; Scan QR / Import file — «Пока недоступно»), «Проверить маршрут» цепочки (нужен pair-ping в хосте), кнопки «?» со справкой, открытие сайта / поддержки подписки (только тост).
- [ ] Android: запрос `POST_NOTIFICATIONS`, строки уведомления в `strings.xml`, иконка уведомления (монохромная), действие «Отключить»; отзыв VPN системой сейчас приходит как `onExit(0)` — ядро пробует перезапуск и упирается в отсутствие согласия (нужен отдельный статус «отозвано»); `CoreService` на Android получает `singBox: ''` (версия sing-box в `version()` пуста).
- [x] Android: самообновление — ядро (`appupdate.dart`) качает и проверяет, `UpdateInstaller.kt.tmpl` ставит через `PackageInstaller` (по `docs/updates.md` §9). **На устройстве не проверялось**; проверка по WorkManager в фоне — не сделана.
- [ ] Страницы: Logs (Events / Raw), остальной Settings, листы (Route, Rules, Add, …) со стеком «Назад закрывает верхний лист».
- [ ] Иконки нижней навигации сейчас Material (`Icons.*`), в макете — свои SVG; точки непрочитанных ошибок / предупреждений на Logs.
- [ ] Анимации дока (смена цвета 0.7 с, свечение, пульс при `connecting`); сейчас рисуется статично.
- [ ] Сохранение `AppSettings` (тема, масштаб, язык) вместе с остальным состоянием.
- [ ] Шрифт Inter не вложен (макет тоже его не грузит, берёт системный); флаги — через `Flags` (Twemoji).
- [ ] Windows: `flutter create` уже делает `windows/`; ядро запускает sing-box само, TUN требует админа (`core/tunNeedsAdmin`); системный прокси, автозапуск.
- [ ] Иконка приложения, имя / метки, подпись релиза (`key.properties`), CI-сборка APK.
