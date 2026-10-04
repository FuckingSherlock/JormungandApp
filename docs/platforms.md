# Мокап → Flutter (Windows, Android): соответствие, перенос, сборка

Три продукта из одного репо:

| | Что это | Где | Чем запускается |
|---|---|---|---|
| **Мокап** | Спецификация UI и поведения. Живой веб-UI десктопа через `jormd` | `design/src/` → `design/main_screen.html` | браузер; `jormd` на 127.0.0.1:7788 |
| **Flutter Windows** | Настоящее десктоп-приложение | `app/` (`windows/`) | sing-box — дочерний процесс ядра (Job Object) |
| **Flutter Android** | Настоящее мобильное приложение (первая цель) | `app/` (`android/`, `android_overlay/`) | sing-box — libbox в `VpnService` |

Общее у всех трёх — Dart-ядро `core/` (`jormungand_core`): парсеры, каталог, план, конфиг sing-box,
`CoreService`. Логику не дублировать в UI: мокап ходит в ядро через `12-backend.js` → `95-live.js`,
Flutter — через `CoreHost` (`app/lib/core/core_host.dart`) → `LiveCoreHost` → `CoreService`.

**Источник правды — мокап + `docs/`.** Дизайн и поведение меняются сначала в мокапе (и в доке, если
меняется логика), потом переносятся во Flutter. Во Flutter не изобретать то, чего нет в мокапе; если
приходится (платформенное), записать в «Отличия платформ» ниже.

## Отличия платформ

Всё, чего нет в этом списке, на всех платформах как в мокапе.

| Что | Мокап / Windows | Android |
|---|---|---|
| Системный прокси | есть (режим Home, Settings, kill switch «пока приложение закрыто») | нет совсем — скрыт вместе со всеми настройками, нужными только ему |
| Переключатель TUN \| Proxy | есть, по умолчанию Proxy | нет: всегда VPN (TUN через `VpnService`) |
| Global \| Rules | вертикальный сегмент рядом с TUN \| Proxy | горизонтальный переключатель в одну строку |
| TUN | нужен админ (`core/tunNeedsAdmin`), WFP kill switch непостоянный | согласие VPN (`prepare`), отзыв системой |
| Per-app | по пути процесса | по пакету (`include/exclude_package`); позже упрощённый режим «только из списка / все, кроме» |
| sing-box | процесс `core/tool/bin/sing-box.exe` | `libbox.aar` (`core/tool/build_libbox.ps1`) |
| Обновления | zip + `jorm-updater` | APK через `PackageInstaller`, проверка — WorkManager (`docs/updates.md`) |
| Листы (sheets) | стек от верха экрана, над нижней навигацией | пока `showModalBottomSheet` (`app_sheet.dart`) |

Платформенные условия во Flutter — через один помощник возможностей платформы (не разбросанные
`Platform.isAndroid`), чтобы тесты могли подменить платформу.

## Соответствие файлов

Перенос и сверка идут по этой таблице. Имена виджетов — как в мокапе (SourceCard, NodeRow, ConnectDock…).

| Область | Мокап (`design/src/`) | Flutter (`app/lib/`) |
|---|---|---|
| Темы, цвета | `css/00-themes.css`, `js/90-themes.js` | `theme/app_colors.g.dart` (генерируется) |
| Переводы | `js/03-i18n.js`, `js/04-i18n-ru.js` | `l10n/app_{en,ru}.arb` (генерируется) + `app/tool/i18n_extra.json` (строки только Flutter) |
| Оболочка, нижняя навигация | `markup/40-bottomnav.html`, `css/10-shell.css`, `30-bottomnav.css`, `js/60-sheets.js`, `85-sheet-swipe.js` | `shell/home_shell.dart`, `widgets/app_view.dart`, `widgets/app_sheet.dart` |
| Home, док | `markup/10-home.html`, `js/50-home.js`, `css/20-home.css`, `50-dock.css`, `design/tools/geometry.mjs` | `pages/home_page.dart`, `widgets/connect_dock.dart`, `dock_profile.dart`, `dock_paths.g.dart` (генерируется), `stat_cards.dart`, `segments.dart`, `nav_cards.dart` (Auto mode / Rules / DNS / Speed Test), `vpn_alert.dart`, `conn_badge.dart` |
| Nodes | `markup/20-nodes.html`, `60-sheets-nodes.html`, `js/20-profiles.js`, `30-nodes.js`, `31-catalog.js`, `32-nodes-forms.js`, `33-source-error.js`, `70-profile-forms.js`, `72-source-entry.js`, `80-drag.js`, `css/70-nodes.css` | `pages/nodes_page.dart`, `widgets/source_card.dart`, `entry_card.dart`, `node_row.dart`, `catalog_card.dart`, `gone_block.dart`, `nodes_menus.dart`, `nodes_forms.dart`, `entry_editors.dart`, `source_entry_sheet.dart`, `source_error_strip.dart`, `pick_parts.dart`, `core/catalog_forms.dart` |
| Share, QR | `js/36-qr.js`, `37-share.js`, `css/72-share-data.css` | `widgets/nodes_menus.dart` (лист «Поделиться») |
| Speed test | `js/38-speed.js` | `widgets/speed_test_sheet.dart` |
| Пинг | `js/15-ping.js` | ядро (`CoreService`), `widgets/latency_text.dart` |
| Route, Auto | `markup/50-sheets-connect.html`, `js/55-automode.js`, `94-live-auto.js`, `css/55-automode.css` | `pages/route_page.dart` |
| Live connections | `js/76-conns.js` | лист соединений (рядом с `route_page.dart` / Home) |
| Rules, приложения | `markup/55-sheets-rules.html`, `js/40-rules.js`, `42-apps.js`, `44-target-picker.js`, `75-rule-form.js`, `css/65-rules.css` | `pages/rules_page.dart`, `widgets/rules_*.dart`; список приложений Android — канал `jormungand/vpn` (`apps`) |
| Logs, события | `markup/35-logs.html`, `js/46-logs.js`, `47-events.js`, `css/67-logs.css` | `pages/logs_page.dart`, `widgets/logs_*.dart` |
| Settings | `markup/30-settings.html`, `js/56-dns.js`, `57-general.js`, `58-notif.js`, `59-data.js`, `css/95-settings.css` | `pages/settings_page.dart` (меню), `widgets/settings_auto.dart` (Auto mode, + `autoCardSub`), `settings_look.dart` (Appearance / General / Notifications), `settings_conn.dart`, `settings_dns.dart`, `settings_data.dart` (обновления, бэкап, About), `settings_parts.dart` (общие части листов), `core/settings_model.dart` (хранение `genCfg` / `notifCfg`, диапазоны и проверки полей), `core/app_update.dart` (состояние обновления для UI), `state/app_settings.dart`; различия платформ — `platform/platform_caps.dart` (`host.caps`); файлы бэкапа и установка APK — `platform/files_channel.dart` + `android_overlay/kotlin/FilesChannel.kt.tmpl`, `UpdateInstaller.kt.tmpl` |
| Справка «?» | `js/58-help.js` | `widgets/settings_parts.dart` (`showHelp`, `HelpTopic`) |
| Меню, формы, тосты | `js/34-ui.js`, `css/80-menus-forms.css`, `90-toast.css` | `widgets/form_parts.dart`, `app_card.dart`, `settings_row.dart` |
| Шов к ядру | `js/12-backend.js`, `93-routing-plan.js`, `95-live.js` | `core/core_host.dart`, `core/live_core_host.dart`, `core/platform_seams.dart`, `core/libbox_runner.dart` |
| Демо-данные мокапа | `js/10-data.js`, моки в `12-backend.js` | **не переносятся** — только реальные данные ядра или пустые состояния |

Новый файл в мокапе или во Flutter — новая строка здесь в том же коммите.

## Синхронизация мокап → Flutter

`app/SYNCED_FROM` — хеш коммита, с которым Flutter-версия сверена целиком. Что отстаёт:

```sh
git diff $(cat app/SYNCED_FROM)..HEAD --stat -- design/src design/tools docs
```

Порядок:
1. По diff и таблице выше составить список задач по областям. Строки `04-i18n-ru.js` / темы / геометрия
   дока — генераторы (шаг 3), не вручную.
2. Раздать области агентам (`coder-deep` / `coder-fast`), параллельно по непересекающимся файлам.
   В брифе: файлы мокапа и Flutter из таблицы; «как в мокапе, без демо-заглушек»; «Отличия платформ»;
   цвета только `context.colors.*`, строки только ARB + русский; помещается в 320 dp при 120 %; общие
   файлы (`app_*.arb`, `i18n_extra.json`, `core_host.dart`, `live_core_host.dart`, `home_shell.dart`) —
   только точечные правки; виджет-тесты в `app/test/`; не собирать APK, не коммитить.
3. `node app/tool/gen_all.mjs` → `flutter gen-l10n` → `flutter analyze --no-fatal-infos` → `flutter test`
   (в `app/`); при правках ядра — `dart analyze` + `dart test` в `core/`.
4. Сборка и установка (ниже), проверка на телефоне.
5. Коммит, `git rev-parse HEAD > app/SYNCED_FROM` (коммитом позже — следующий коммит), push.

Если меняется логика (не только вид) — сначала `docs/*.md`, потом мокап, потом Flutter.

## Генераторы (`node app/tool/gen_all.mjs`, результат коммитится)

| Источник | Генератор | Результат |
|---|---|---|
| `css/00-themes.css`, `js/90-themes.js` | `gen_theme.mjs` | `lib/theme/app_colors.g.dart` |
| `design/tools/geometry.mjs` | `gen_dock.mjs` | `lib/widgets/dock_paths.g.dart` |
| `js/04-i18n-ru.js` + `tool/i18n_extra.json` | `gen_i18n.mjs` | `lib/l10n/app_{en,ru}.arb`, `tool/i18n_keys.json` (`docs/i18n.md`) |
| `assets/TwemojiCountryFlags.woff2` | `gen_assets.mjs` | `assets/fonts/TwemojiCountryFlags.ttf` (только при смене источника) |

Сгенерированное руками не править — менять источник или генератор.

## Тулчейн (локально, `G:\ANDROID_DEV`)

JDK 17 (`jdk-17`), Flutter 3.47.6 (`flutter`), Go (`go`, `GOPATH=gopath`), Android SDK (`android-sdk`:
platform-tools, android-36, build-tools 36.1.0, NDK 28.2.13676358), исходники sing-box для libbox
(`src\sing-box`). Переменные пользователя: `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_NDK_HOME`, `GOPATH`,
`PATH` — в старом шелле их может не быть, скрипты сами берут эти пути по умолчанию.
Особенности: `sdkmanager` принимает имена пакетов только через `/` (`ndk/28.2.13676358`); Flutter
на Windows требует включённый «Режим разработчика» (симлинки плагинов). Для Flutter Windows нужна
Visual Studio с «Desktop development with C++» — пока не установлена.

## Сборка

| Что | Команда | Результат |
|---|---|---|
| Мокап | `npm run verify [-- presets]` | `design/main_screen.html`, деплой — push (CI) |
| Живой UI на ядре | preview `jormd` (`dart run core/bin/jormd.dart`) | http://127.0.0.1:7788 |
| libbox | `pwsh core/tool/build_libbox.ps1 [-Force]` | `app/android_overlay/app/libs/libbox.aar` (не в git; пропускается, если актуален) |
| APK для теста | `pwsh app/tool/build_apk.ps1 -DebugSigned` | `app/build/app/outputs/flutter-apk/app-<abi>-release.apk`, подпись debug-ключом |
| APK релиз | `$env:JORM_ANDROID_KS_PASS=…; pwsh app/tool/build_apk.ps1 -BuildName X.Y.Z -BuildNumber N` | то же, подпись `%USERPROFILE%\.jormungand\android-release.jks` |
| Установка | `adb install -r <apk>` (`G:\ANDROID_DEV\android-sdk\platform-tools\adb.exe`) | телефон юзера: Galaxy Note20, arm64-v8a, Android 13 |
| Flutter Windows | `flutter build windows` в `app/` | нужна VS C++ |

`build_apk.ps1`: `flutter create` (если нет `android/`) → libbox (если нет aar) → `apply_android_overlay.mjs`
→ ключ → `flutter build apk --release --split-per-abi`. APK, подписанный debug-ключом, не обновляется
поверх релизного и наоборот — только удалением.

Android-часть живёт в `app/android_overlay/` (Kotlin-шаблоны `*.kt.tmpl`, манифест, proguard);
`node app/tool/apply_android_overlay.mjs` накладывает её на `app/android/` и дописывает управляемый блок
в `build.gradle.kts` (`// >>> jormungand overlay`). Править шаблоны, не `app/android/`; после правки —
перезапустить скрипт. Проверка Kotlin без сборки Dart:
`app/android> .\gradlew.bat :app:compileReleaseKotlin -x compileFlutterBuildRelease`.
Логи с телефона: `adb logcat -s flutter:* AndroidRuntime:E`.

## Релиз

Подписанный манифест и файлы — в публичном репо `FuckingSherlock/jormungand-releases` (релиз `feed`);
ключ подписи манифеста и порядок — `docs/updates.md`. Ключ подписи APK и ключ манифеста — разные.
