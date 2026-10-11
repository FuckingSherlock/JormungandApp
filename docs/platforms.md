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

**Мокап заморожен (с 2026-10-06).** Источник правды — `docs/` и само Flutter-приложение; изменения
логики и UI идут docs → core → Flutter, а в мокап не вносятся: в `.claude_states/mockup_todo.md` (в том же
коммите) пишется короткая заметка «что изменилось на Android» — файл мокапа, раздел дока. Потом мокап
подтягивается одним проходом по этим заметкам (и снимается `_mockupBehind`, двигается `SYNCED_FROM`).
Раздел «Синхронизация мокап → Flutter» ниже — для обратной ситуации, когда мокап разморожен и
опережает приложение. Платформенные отличия — в «Отличия платформ».

## Отличия платформ

Всё, чего нет в этом списке, на всех платформах как в мокапе.

| Что | Мокап / Windows | Android |
|---|---|---|
| Системный прокси | есть (режим Home, Settings, kill switch «пока приложение закрыто») | нет совсем — скрыт вместе со всеми настройками, нужными только ему |
| Переключатель TUN \| Proxy | есть, по умолчанию Proxy | нет: всегда VPN (TUN через `VpnService`) |
| Global \| Rules | вертикальный сегмент рядом с TUN \| Proxy | горизонтальный переключатель в одну строку |
| TUN | нужен админ (`core/tunNeedsAdmin`), WFP kill switch непостоянный | согласие VPN (`prepare`), отзыв системой |
| Per-app | по пути процесса | по пакету: правила `package_name`, приложение целиком на Direct — `exclude_package` (мимо VPN); список — установленные приложения со значками (`rules.md`); позже упрощённый режим «только из списка / все, кроме» (`include_package`) |
| Свои соединения приложения (подписки, обновления, пинги) | приложение внутри TUN; правило `process_path → direct` по exe приложения и sing-box | приложение внутри VPN; правило `package_name → direct` по пакету; сокеты разовых libbox защищает `VpnService.protect` (раздел «Работа вне туннеля» ниже) |
| sing-box | процесс `core/tool/bin/sing-box.exe` | `libbox.aar` (`core/tool/build_libbox.ps1`) |
| Обновления | zip + `jorm-updater` | APK через `PackageInstaller`, проверка — WorkManager (`docs/updates.md`) |
| Листы (sheets) | стек от верха экрана, над нижней навигацией | пока `showModalBottomSheet` (`app_sheet.dart`) |
| Уведомления о событиях | тост в приложении (ПК — ещё свои всплывающие окна, `desktopStyle`) | в фоне — системное уведомление Android (канал «Events», группа со сводкой), на переднем плане — тост; разрешение `POST_NOTIFICATIONS` запрашивается (раздел «Системные уведомления» ниже); на ПК системных нет |
| Уведомление VPN | нет | постоянное уведомление службы: имя подключения и кнопка «Отключить» |
| Закрытие окна | закрытие = выход, ядро останавливается (`AppLifecycleListener.onDetach`) | Back на Home — «свернуть» (`moveTaskToBack`), смахивание из недавних — не конец: движок Dart и туннель живут в процессе, а не в Activity; раздел «Работа в фоне» ниже |
| Работа в фоне | — | строка Settings → Connection «Работа в фоне» (исключение из оптимизации батареи); просьба один раз после первого успешного подключения, подключение она не блокирует |
| Nodes → + → Scan QR code | заглушка («камера недоступна в мокапе») | камера на zxing-cpp (`flutter_zxing`, без Google Play Services / ML Kit), разрешение `CAMERA` из оверлея манифеста; на ПК строки нет (`caps.cameraScan`), QR-картинка идёт через «Import config file» |

Платформенные условия во Flutter — через один помощник возможностей платформы (не разбросанные
`Platform.isAndroid`), чтобы тесты могли подменить платформу.

## Работа вне туннеля

Приложение само **внутри** VPN (Android себя из VPN больше не исключает, на ПК так и было), поэтому
соединение, которое оно открывает, входит в TUN как соединение любого приложения: без исключения оно
зациклится в прокси, который проверяет, или не выйдет, пока прокси лежит. Всё, что открывает своё
соединение или процесс и должно работать мимо туннеля, перечислено в одном списке:
`core/lib/src/outside_tunnel.dart` (`outsideTunnel`: `id`, `what`, `how`, `files`). `how` — чем оно
держится вне туннеля:

| `how` | Что | Чем держится |
|---|---|---|
| `ownRule` | соединения процесса приложения: HTTP-клиенты Dart (подписки, списки правил, обновления, проверка IP и сайта, пинг DNS, отправка отчёта), процессы sing-box на ПК (пинг, Speed Test) | системное правило ядра «Core and speed tests» (`config.dart` → `selfRules`): Android `package_name: [пакет]`, ПК `process_path` (приложение и бинарник sing-box) → `direct`; после `sniff`, перехвата резолвера туннеля и `tunnel-in`, до `Private networks` и правил пользователя; есть и в Global. DNS-запросы тех же процессов — DNS-правило с прямым сервером (`core.md` → «TUN», «DNS») |
| `protectedSocket` | Android: libbox-инстансы без туннеля (пинг, Speed Test, проверка маршрута), `LocalResolver` (`local` DNS sing-box) | сокеты держит вне VPN платформа (`VpnService.protect`, привязка к базовой сети); в TUN не входят, правил нет |
| `loopback` | 127.0.0.1: API-сервис sing-box, `probe-in`, `tunnel-in`, `mixed-in`, поиск свободных портов | в TUN не попадает |
| `noConnection` | локальные утилиты и опросы ОС (`reg`, `id`, `sing-box version`, `powershell` диалога файла, колбэки состояния сети) | соединений не открывает; в списке, чтобы новое использование API процессов было замечено |

Нужно **через** туннель — не «вне»: код ходит через `tunnel-in` (loopback), правило `tunnel-in → proxy`
стоит раньше самоправила.

**Охранный тест.** `core/test/outside_tunnel_test.dart` (исходники ядра `core/lib/src`) и
`app/test/outside_tunnel_guard_test.dart` (`app/lib` и Kotlin-оверлей `app/android_overlay/kotlin` —
источник `app/android/**/*.kt`) ищут вызовы сетевых API: Dart — `HttpClient(`, `Socket.connect`,
`RawDatagramSocket`, `ServerSocket`, `HttpServer`, `ClientChannel(`, `InternetAddress.lookup`,
`Process.start` / `run`, пакеты `http` / `dio`; Kotlin — `URL`, сокеты, `DnsResolver`, `protect(`,
`LibboxBox(`, колбэки сети (точный список — `core/test/outside_tunnel_scan.dart`; закомментированное не
считается). Файл с находкой, которого нет в `outsideTunnel`, роняет тест; запись, чей файл исчез или
больше не использует сетевой API, — тоже. Сообщение говорит, что делать.

**Новое соединение (своё или перенесённое с другой платформы):**
1. Запись в `outsideTunnel`: `id`, `what`, `how`, `files` — и `how` должен быть правдой: `ownRule` —
   код исполняется в процессе, который матчит самоправило (Dart внутри приложения — да; внешняя
   программа, которую мы запускаем, — её путь надо добавить в `selfProcessPaths`); `protectedSocket` —
   сокеты действительно защищены платформой; `loopback` — только 127.0.0.1.
2. Отличается между платформами — строка в «Отличия платформ» выше.
3. Тесты: `dart test test/outside_tunnel_test.dart` в `core/`, `flutter test test/outside_tunnel_guard_test.dart`
   в `app/`.

Ограничения: `package_name` матчится по владельцу соединения (`getConnectionOwnerUid`, Android 10+),
как правила приложений (`rules.md` §3).

## Соответствие файлов

Перенос и сверка идут по этой таблице. Имена виджетов — как в мокапе (SourceCard, NodeRow, ConnectDock…).

| Область | Мокап (`design/src/`) | Flutter (`app/lib/`) |
|---|---|---|
| Темы, цвета | `css/00-themes.css`, `js/90-themes.js` | `theme/app_colors.g.dart` (генерируется) |
| Переводы | `js/03-i18n.js`, `js/04-i18n-ru.js` | `l10n/app_{en,ru}.arb` (генерируется) + `app/tool/i18n_extra.json` (строки только Flutter) |
| Оболочка, нижняя навигация | `markup/40-bottomnav.html`, `css/10-shell.css`, `30-bottomnav.css`, `js/60-sheets.js`, `85-sheet-swipe.js` | `shell/home_shell.dart`, `widgets/app_view.dart`, `widgets/app_sheet.dart` |
| Home, док | `markup/10-home.html`, `js/50-home.js`, `css/20-home.css`, `50-dock.css`, `design/tools/geometry.mjs` | `pages/home_page.dart`, `widgets/connect_dock.dart`, `dock_profile.dart`, `dock_paths.g.dart` (генерируется), `stat_cards.dart`, `segments.dart`, `nav_cards.dart` (Auto mode / Rules / DNS / Speed Test), `vpn_alert.dart`, `conn_badge.dart` |
| Nodes | `markup/20-nodes.html`, `60-sheets-nodes.html`, `js/20-profiles.js`, `30-nodes.js`, `31-catalog.js`, `32-nodes-forms.js`, `33-source-error.js`, `70-profile-forms.js`, `72-source-entry.js`, `80-drag.js`, `css/70-nodes.css` | `pages/nodes_page.dart`, `widgets/source_card.dart`, `entry_card.dart`, `node_row.dart`, `catalog_card.dart`, `gone_block.dart`, `nodes_menus.dart`, `nodes_forms.dart`, `entry_editors.dart`, `source_entry_sheet.dart`, `source_error_strip.dart`, `pick_parts.dart`, `core/catalog_forms.dart` |
| Share, QR | `js/36-qr.js`, `37-share.js`, `css/72-share-data.css` | `widgets/nodes_menus.dart` (лист «Поделиться», «Open website» / «Support» через `url_launcher`), `qr_box.dart` (код, `qr_flutter`) |
| Импорт: Scan QR, файл | `60-sheets-nodes.html`, `js/32-nodes-forms.js` (`pickConfigFile` / `readConfigFile`); Scan QR — заглушка | `platform/import_io.dart` (шов камеры и файла, `ImportIo.current`; `pickFile` → `PickedFile`: картинка читается как QR, прочий файл — текст), `widgets/qr_scanner_page.dart` (камера, `flutter_zxing`), `nodes_menus.dart` (`_importText` — общий путь QR / «From clipboard»; `_importFile` — не-картинка → `CoreHost.importConfigFile` → `CoreApi.addSourceFromText` → локальный источник `kind: 'file'`, см. `connect-model.md` → «Локальный источник»); карточка `file`: `source_card.dart` (метка `local file`, без Update / расхода), форма Rename — `nodes_forms.dart` (`_nameOnly`), меню / удаление — `nodes_menus.dart`, метка дока `file` — `DockKind.file` |
| Speed test | `js/38-speed.js` | `widgets/speed_test_sheet.dart` |
| Пинг | `js/15-ping.js` | ядро (`CoreService`), `widgets/latency_text.dart` |
| Route, Auto | `markup/50-sheets-connect.html`, `js/55-automode.js`, `94-live-auto.js`, `css/55-automode.css` | `pages/route_page.dart` |
| Live connections | `js/76-conns.js` | лист соединений (рядом с `route_page.dart` / Home) |
| Rules, приложения | `markup/55-sheets-rules.html`, `js/40-rules.js`, `42-apps.js`, `44-target-picker.js`, `75-rule-form.js`, `css/65-rules.css` | `pages/rules_page.dart`, `widgets/rules_*.dart`; список приложений Android — канал `jormungand/apps` (`list`, `icon`; `platform/apps_io.dart`, шов `AppsIo.current`, Kotlin `AppsChannel.kt.tmpl`; манифест — `QUERY_ALL_PACKAGES`), ленивый лист `widgets/apps_sheet.dart`; подробности — `rules.md` → «Приложения» |
| Logs, события | `markup/35-logs.html`, `js/46-logs.js`, `47-events.js`, `css/67-logs.css` | `pages/logs_page.dart`, `widgets/logs_*.dart`, `widgets/report_actions.dart` («Download log» / «Send report»; у мокапа их нет — он заморожен), `core/report_info.dart` |
| Settings | `markup/30-settings.html`, `js/56-dns.js`, `57-general.js`, `58-notif.js`, `59-data.js`, `css/95-settings.css` | `pages/settings_page.dart` (меню), `widgets/settings_auto.dart` (Auto mode, + `autoCardSub`), `settings_look.dart` (Appearance / General / Notifications), `settings_conn.dart`, `settings_dns.dart`, `settings_data.dart` (обновления, бэкап, About), `settings_parts.dart` (общие части листов), `core/settings_model.dart` (хранение `genCfg` / `notifCfg`, диапазоны и проверки полей), `core/app_update.dart` (состояние обновления для UI), `state/app_settings.dart`; различия платформ — `platform/platform_caps.dart` (`host.caps`); файлы бэкапа и установка APK — `platform/files_channel.dart` + `android_overlay/kotlin/FilesChannel.kt.tmpl`, `UpdateInstaller.kt.tmpl` |
| Системные уведомления Android | `js/58-notif.js` (только настройки; уведомлений нет) | `core/system_notifier.dart` (`SystemNotifier`), `platform/notify_channel.dart` (шов `NotifyIo`, канал `jormungand/notify`), `shell/home_shell.dart` (`_notify`, тап), `widgets/settings_look.dart` (`NotifPermissionHint`), `android_overlay/kotlin/AppNotifier.kt.tmpl`, `NotifyChannel.kt.tmpl`, `EventActionReceiver.kt.tmpl` («Ignore site» / «Undo» без приложения), `res/values{,-ru}/jorm_notif_strings.xml` |
| Работа в фоне Android | — (в мокапе окно = приложение) | `android_overlay/kotlin/AppEngine.kt.tmpl` (движок и каналы процесса), `MainActivity.kt.tmpl` (только окно), `PowerChannel.kt.tmpl` (канал `jormungand/power`), `JormungandVpnService.kt.tmpl` (`onTaskRemoved`, запись для усыновления); Dart: `platform/power_channel.dart` (шов `PowerIo`), `widgets/background_access_row.dart` (строка в `settings_conn.dart`), `core/libbox_runner.dart` (`keep` / `adopt`), `core/live_core_host.dart` (`_adoptRunning`), `app.dart` (`onDetach`), `shell/home_shell.dart` (Back на Home) |
| Справка «?» | `js/58-help.js` | `widgets/settings_parts.dart` (`showHelp`, `HelpTopic`; Settings), `widgets/nodes_help.dart` (`NodesHelp`: Nodes, Advanced подписки, профиль, пункт-источник, цепочка), `rules_parts.dart` (`RoundHelp`, `showTermsSheet`) |
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
3. **Обязательно:** переносишь с ПК функционал, который открывает своё соединение или запускает процесс
   (HTTP-клиент, сокет, DNS-запрос, `Process`, на Android — libbox-инстанс / резолвер), — зарегистрируй
   его в `core/lib/src/outside_tunnel.dart` с `how` (раздел «Работа вне туннеля» выше); тест не даст
   собрать без этого (`outside_tunnel_test.dart`, `outside_tunnel_guard_test.dart`). Приложение внутри
   VPN: незарегистрированное соединение либо зациклится в туннеле, либо не выйдет при лежащем прокси.
4. `node app/tool/gen_all.mjs` → `flutter gen-l10n` → `flutter analyze --no-fatal-infos` → `flutter test`
   (в `app/`); при правках ядра — `dart analyze` + `dart test` в `core/`.
5. Сборка и установка (ниже), проверка на телефоне.
6. Коммит, `git rev-parse HEAD > app/SYNCED_FROM` (коммитом позже — следующий коммит), push.

Если меняется логика (не только вид) — сначала `docs/*.md`, потом core, потом Flutter; мокап пока
заморожен — только заметка в `.claude_states/mockup_todo.md`.

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
| APK для теста | `pwsh app/tool/build_apk.ps1` (`-DryRun` — только показать версию и источник подписи) | `app/build/app/outputs/flutter-apk/app-<abi>-release.apk`; **всегда** подпись релизным ключом `%USERPROFILE%\.jormungand\android-release.jks` (пароль — `JORM_ANDROID_KS_PASS` или `android-release.pass`); версия сама: `<версия CI>.dev`, versionCode = последней CI-сборки — встаёт `adb install -r` поверх неё, следующая CI-бета предлагается (`docs/updates.md` §5) |
| APK с заданной версией | `pwsh app/tool/build_apk.ps1 -BuildName X.Y.Z -BuildNumber N` | то же, версия как задана (так вызывает CI) |

Настройки → Данные → «О приложении»: «Сборка» = `versionCode · короткий коммит` (коммит скрипт передаёт как
`--dart-define=JORM_COMMIT=<sha>` из `git rev-parse --short HEAD`, CI тоже идёт через скрипт; без него — только номер);
версия sing-box на Android — из libbox (`VpnChannel` `libboxVersion` → `CoreService(knownSingBoxVersion:)`), на десктопе — `sing-box version`.
`coreVersion` остаётся только в `/api/version` jormd.
| APK + публикация beta (CI) | push в основную ветку (`app/**`, `core/**`) или `workflow_dispatch` → `.github/workflows/release-android.yml` | релиз `v<версия>-beta.N` в `FuckingSherlock/jormungand-releases` + `manifest-beta.json(.sig)` в релизе `feed`; секреты и разовые шаги — `docs/updates.md` §13 |
| APK + публикация stable (CI) | `git tag v0.1.0 && git push origin v0.1.0` (версия тега = `X.Y.Z` в `app/pubspec.yaml`); **перед stable-тегом `node app/tool/gen_i18n.mjs --missing` должен быть чист** — русский делается только для stable (`docs/i18n.md`) | обычный релиз `v0.1.0` в `jormungand-releases` + `manifest-stable.json(.sig)` в `feed`; beta после stable идёт выше него (`0.1.1-beta.N`), `docs/updates.md` §5, §13 |
| Установка | `adb install -r <apk>` (`G:\ANDROID_DEV\android-sdk\platform-tools\adb.exe`) | телефон юзера: Galaxy Note20, arm64-v8a, Android 13 |
| Flutter Windows | `flutter build windows` в `app/` | нужна VS C++ |

`build_apk.ps1`: `flutter create` (если нет `android/`) → libbox (если нет aar) → `apply_android_overlay.mjs`
→ ключ → `flutter build apk --release --split-per-abi`. Debug-подписанных сборок нет: и локальные, и
CI-сборки подписаны одним релизным ключом, поэтому они обновляют друг друга; отсутствующее
хранилище — ошибка (новый ключ ломает обновления; создаёт только `-NewKeystore`). Оба скрипта (`build_libbox.ps1`, `build_apk.ps1`)
работают и на Linux под `pwsh` (CI): пути берутся из `JAVA_HOME` / `ANDROID_HOME` / `ANDROID_NDK_HOME` /
`PATH`, `-KeystorePath` задаёт чужое хранилище ключа.

Android-часть живёт в `app/android_overlay/` (Kotlin-шаблоны `*.kt.tmpl`, манифест, proguard);
`node app/tool/apply_android_overlay.mjs` накладывает её на `app/android/` и дописывает управляемый блок
в `build.gradle.kts` (`// >>> jormungand overlay`). Править шаблоны, не `app/android/`; после правки —
перезапустить скрипт. Проверка Kotlin без сборки Dart:
`app/android> .\gradlew.bat :app:compileReleaseKotlin -x compileFlutterBuildRelease`.
Логи с телефона: `adb logcat -s flutter:* AndroidRuntime:E`.
Плагины с Kotlin (`url_launcher`, `file_picker`, `camera`) лежат в Pub-кеше на `C:`, проект — на `G:`:
инкрементальные кеши Kotlin на двух дисках падают («Could not close incremental caches»), поэтому
оверлей дописывает `kotlin.incremental=false` в `android/gradle.properties`. Нативная часть
`flutter_zxing` (zxing-cpp) собирается CMake из SDK (`cmake/3.22.1`) и NDK.

Сырой лог (Logs → Raw) на Android собирается из трёх источников: заметки ядра (`LogBook.note`), строки
sing-box туннеля и разовых боксов пинга / Speed Test (через `SingBoxApi.logLines()`; libbox шлёт строки
с ANSI-цветом и всех уровней — `LibboxRunner` отрезает цвет и лишние уровни по `log.level` конфига,
строки разового бокса идут с меткой `[ping]` / `[speed]`) и собственные строки Kotlin-стороны
(`VpnBridge.log` → EventChannel `jormungand/vpn_events`, `{type: 'log', level, text}` → `[android] …`:
старт / стоп libbox, сети, которые видит libbox, DNS, `protect`). Неудачный пинг пишет в лог одну
строку `Ping: N of M did not answer (failed tests: …)` с причинами по стадиям (`socks`, `tls`, `request`).

Потоки API sing-box (соединения / группы / статус, `SingBoxApi.watch()`) нужны только туннелю (Auto, док,
Live connections): разовые боксы пинга / Speed Test создаются с `LibboxRunner(watchApi: false)` и открывают
один лишь поток лога — иначе каждый бокс гонит три gRPC-потока раз в секунду в UI-изолят. Фильтр уровня строк
libbox не использует regex (`_rankOfLine`): он работает на каждую строку.

Каждый libbox процесса (туннель и каждый разовый бокс) получает свой файл кэша sing-box — общий
`cache.db` под замком, второй экземпляр падает по `initialize cache-file: timeout` (docs/core.md →
BoxRunner, `withCacheFile`). Правила `process_path → direct` для самого приложения на Android нет:
`resolvedExecutable` там — общий `app_process64`; приложение матчится по пакету (`package_name`,
«Работа вне туннеля» выше).

### Работа в фоне (Android)

Правило: **туннель никогда не перезапускается из-за того, что интерфейс закрыли или открыли заново**;
приложение показывает правду и продолжает управлять туннелем. Туннель (`JormungandVpnService`, служба
переднего плана с libbox) переживает окно, поэтому и ядро Dart (Auto, пинги, журнал, уведомления,
действия плитки) живёт не в окне.

- **Движок принадлежит процессу** (`AppEngine.kt.tmpl`): `FlutterEngine` и все каналы (`vpn`, `files`,
  `apps`, `tile`, `notify`, `power`) создаются один раз при первом окне и держат application-контекст.
  `MainActivity` только подключается (`provideFlutterEngine` → `AppEngine.get`) и никогда не
  уничтожает движок (`shouldDestroyEngineWithHost() = false`); плагины (`file_picker`, `camera`, …)
  привязываются к каждому новому окну сами (ActivityAware). Что требует окна (согласие VPN, диалоги
  файлов / разрешений / батареи, `moveTaskToBack`) идёт через `AppEngine.activity` — открытое сейчас окно;
  его нет — ответ «нет», ничего не зависает.
- **Службе** в манифесте задано `android:stopWithTask="false"`; смахивание из недавних приводит только к
  строке в логе (`onTaskRemoved`). Процесс заканчивается — вместе умирают движок, служба и туннель
  (уведомление и плитка при следующем старте процесса стираются: `AppEngine.get`, `TileBridge.refresh`).
- **Back на Home** сворачивает приложение (`moveTaskToBack`, `HomeShell`: `PopScope`), а не выходит; на
  остальных вкладках Back, как раньше, ведёт на Home. При включённом VPN сначала диалог «Закрыть
  приложение?»: «Закрыть окно» (VPN работает дальше) / «Отключить и закрыть»; тап мимо — остаться.
  Без VPN — сразу свернуть. Ещё туннель выключается кнопкой дока, плиткой или кнопкой уведомления.
- **`AppLifecycleState.detached`**: когда Activity отсоединяется от переживающего движка, Flutter шлёт
  `detached`. На ПК это «закрыли окно» и ядро выключается (`AppLifecycleListener.onDetach`); на Android
  этот колбэк не ставится (`app.dart`) — иначе закрытие окна остановило бы туннель.
- **Усыновление: запасной путь** (процесс остался, а новый движок Dart — с холодным ядром; на практике
  редко, но состояние обязано быть верным). Пока туннель поднят, ядро держит у Kotlin **запись**:
  `BoxRunner.keep` → `VpnChannel.remember` → `VpnBridge.record` (одна непрозрачная JSON-строка в
  памяти процесса: `{apiPort, secret, level, core: {plan, tunnelPort, probePort, probeSecret, sysPort,
  sysWanted, ruleSetFiles, upSince}}`). Она стирается в `closeBoxLocked()` и живёт ровно столько, сколько
  туннель и процесс (на диск не пишется: секрет API не должен переживать процесс). Новое ядро в `init()`
  перед всем остальным (`LiveCoreHost._adoptRunning` → `CoreApi.adopt` → `CoreService.adopt`)
  спрашивает `status` (`VpnChannel.recall`: работает ли туннель + запись) и:
  - **нет туннеля** — «отключено», как раньше;
  - **есть и запись годится** — `LibboxRunner.adopt` проверяет API (`serviceState`), подключает журнал
    sing-box, ловит «остановился сам»; ядро восстанавливает план, порты, пробу, Auto / fallback / DNS /
    трафик, состояние «подключено» **без** остановки и запуска; kill switch и Auto берутся текущие;
  - **есть, а годной записи нет** (API молчит, запись не разобралась) — ядро **останавливает** туннель
    и показывает «отключено»: честное состояние важнее сохранённого соединения.
  Усыновлённый план становится «запущенным» (`_planSig`, `catalog.liveAnchor`); если каталог сейчас
  строит другой план, это обычное «нужен перезапуск» — тот же путь, что после любой смены настроек
  (`_scheduleReconnect`, пауза 600 мс, уведомление `reconnectFailed` при отказе), а не тихий рестарт.
- **Работа в фоне (батарея).** Doze и «убийцы задач» вендоров (MIUI, One UI…) могут останавливать
  помощников туннеля и сам процесс. Приложение просит исключение из оптимизации, но **не требует**:
  подключение никогда не блокируется. Канал `jormungand/power` (`PowerChannel.kt.tmpl`; Dart —
  `PowerIo`, в тестах подменяется): `status` → разрешено ли (`isIgnoringBatteryOptimizations`),
  `request {once}` → системный диалог `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` напрямую (своего листа
  нет; нет такого диалога у вендора — системный список `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`).
  Спрашивается **один раз** за установку при первом успешном подключении (`SystemNotifier._askOnce`,
  сразу после запроса разрешения на уведомления; флаг в SharedPreferences `jorm_power/asked` считается,
  только если диалог реально открылся — без окна ничего не потрачено); повторно сам не спрашивает.
  Дальше — строка **Settings → Connection → «Работа в фоне»** (только Android, `BackgroundAccessRow`):
  «Разрешено» / «Ограничено системой»; при ограничении — кнопка «Разрешить» (тот же диалог, не `once`);
  состояние перечитывается при возврате в приложение. Плитке отдельный путь не нужен.

- **Обновление приложения.** Замена пакета убивает процесс и туннель; VPN возвращается сам: нативная
  запись «был включён» (`ResumeStore`), приёмник `MY_PACKAGE_REPLACED` (`ResumeReceiver`), движок без
  окна (`AppEngine.startDart`; `main()` ждёт вид перед `runApp`), `CoreHost.resumeAfterUpdate` →
  обычный `connect()`; нет согласия VPN — уведомление «Обновлено — нажмите, чтобы подключиться». Всё
  описано в `docs/updates.md` → «Подключение после обновления».
- **Имя в уведомлении VPN** переживает перезапуск службы: `AppNotifier.vpnNode` не стирается в `leave()`,
  а только если следующий старт службы позже 15 с (Dart шлёт имя раз за подключение).
- **Платная сеть** для «Settings → Data → Auto-download → Wi-Fi only»: канал `jormungand/network`
  (`NetworkChannel.kt.tmpl`, Dart — `NetworkPort`): метод `metered` и поток смен. Считается по
  нижележащим (не-VPN) сетям, потому что наш VPN объявляет себя неплатным. На Windows платных сетей
  нет (`metered = false`, пункта «Wi-Fi only» в выборе нет). Подробно — `docs/updates.md` (разделы 6, 9).
  Для отчёта поддержки тот же канал отвечает на `type` (wifi / ethernet / mobile / other / none / unknown —
  по тем же нижележащим сетям), а `VpnChannel` — на `device` (модель, производитель, API Android);
  из этого `core/report_info.dart` собирает `appInfo` (`docs/logs.md` → Отправка).
- **Экран** (фоновые ошибки при выключенном экране): канал `jormungand/screen` (`ScreenChannel.kt.tmpl`,
  Dart — `ScreenPort`): метод `on` (`PowerManager.isInteractive`) и поток смен. `ACTION_SCREEN_ON/OFF` нельзя
  объявить в манифесте — приёмник регистрируется в рантайме на application-контексте, пока Dart слушает поток
  (движок, ядро и служба VPN живут в одном процессе, так что приёмник живёт, пока живо ядро); при подписке
  текущее значение приходит сразу. `LiveCoreHost` шлёт его ядру `updateSettings {screenOn}` (без
  переподключения). На Windows порта нет — экран всегда «включён». Логика — `docs/connect-model.md` → «Фоновые ошибки».

Проверяется только на устройстве: смахивание из недавних при поднятом VPN; возврат VPN после обновления
(из приложения и APK из браузера / `adb install -r` с другим `versionCode`; без согласия VPN); повторное подключение
плагинов к новому окну (файлы, камера, разрешения); подключение плиткой при живом ядре без окна и
согласие VPN без окна; диалог батареи на первом подключении; кнопка «Disconnect» уведомления без
окна; убитый процесс — чистое «отключено» (плитка и уведомление очищены); скрытое уведомление VPN
(Notifications → мастер / Status выключены): подключение, переключение на лету, возврат после обновления и
подключение плиткой, а главное — что туннель и Auto живут с погашенным экраном и после смахивания из
недавних (раздел «Системные уведомления»).

### Системные уведомления (Android)

Источник и фильтр те же, что у тостов: `LogsController.notifications` (новые события журнала, не `own`,
пропущенные `notifAllows`, см. `connect-model.md` → Notifications). Оболочка (`_notify`) решает по
`AppLifecycleState`: `resumed` — тост как раньше; любое другое (свёрнуто, шторка, диалог) — системное
уведомление (`SystemNotifier.postEvent`: заголовок и пояснение события на языке приложения). Дубля нет:
в одном случае показывается ровно одно. Возврат на передний план убирает уведомления событий.

- **Канал `jormungand/notify`** (`NotifyChannel.kt.tmpl`, отдельный от `jormungand/vpn`): `permission`,
  `request {once}`, `openSettings`, `post {id, title, text, actions?, site?, via?, ignoredText?, undoLabel?}`,
  `cancelEvents`, `setStatus {node?, visible?}`, `takeLaunchEvent`, `takeLaunchAction`, `takeIgnoreOps`;
  Kotlin → Dart: `openEvent` (тап), `eventAct` (кнопка Create rule), `ignoreQueued` (в очередь легло «Ignore
  site» / «Undo»), `disconnect` (кнопка уведомления VPN). Dart-шов —
  `NotifyIo` (`NotifyIo.current`, в тестах подменяется); где `available` = false (не Android) всё пусто и
  остаются тосты.
- **Уведомления** (`AppNotifier.kt.tmpl`): канал `events` (важность default; отдельный от `vpn`), по
  одному на событие, все в группе `jorm.events` со сводкой («N событий», InboxStyle); остаётся не больше
  6, старые убираются; звук — только от сводки и не чаще раза в 15 с. Тап → `MainActivity` с действием
  `OPEN_EVENT` и id события → Dart (`openEvent`; при холодном старте — `takeLaunchEvent` после запуска
  оболочки) → `AppLinks.openLogsEvent`, как у тоста. Тексты канала, сводки и кнопки — ресурсы
  `jorm_notif_strings.xml` (язык системы, не выбор в приложении).
- **Кнопки уведомления «сайт не открывается»** (`site/blocked` с `via` — «Create rule» и «Ignore site»;
  `site/unreachable` — только «Ignore site»; подписи на языке приложения, их шлёт Dart в `post {actions:
  [{id, label}], site, via, ignoredText, undoLabel}`).
  - **Create rule** — `PendingIntent.getActivity` на `MainActivity` с действием `EVENT_ACT` (id события,
    `rule`, `site`, `via` в extras — событие к тому времени может выпасть из журнала) → `NotifyChannel.onIntent`
    убирает это уведомление (кнопка само его не снимает) и шлёт Dart `eventAct` (холодный старт —
    `takeLaunchAction` после запуска оболочки) → `NotifyIo.actionTaps` → оболочка открывает редактор правила
    с хостом. Приложение выходит на передний план.
  - **Ignore site приложение не открывает.** Кнопка — `PendingIntent.getBroadcast` на `EventActionReceiver`
    (`exported=false`, манифест оверлея). Приёмник (1) дописывает выбор (`+host`) в очередь `IgnoreQueue`
    (SharedPreferences `jorm_notify/ignoreQueue`, по порядку) — ничего не теряется, пока Dart не запущен;
    (2) заменяет то же уведомление (тот же id) на «{host} added to ignored sites» (тексты приходят из Dart
    вместе с событием, язык приложения) с кнопкой «Undo»: вне группы, без звука, `setTimeoutAfter` 10 с,
    сводка пересчитывается без звука; тап по нему — как по событию; (3) если движок жив, шлёт в Dart
    `ignoreQueued`. Dart (`SystemNotifier.drainIgnoreOps`) забирает очередь (`takeIgnoreOps`, очередь
    очищается) при старте оболочки, при возврате на передний план и по каждому `ignoreQueued`, ждёт `host.ready`
    и по порядку применяет через `LogsController.ignoreSite` / `unignoreSite` — те же сохранение и
    `updateSettings` ядру, что и из приложения. Если процесс жив (туннель держит его), список меняется сразу;
    после гибели процесса — на следующем запуске (туннеля тогда нет, уведомлять нечему). **Undo** — `-host` в
    очередь и `cancel` уведомления (оно просто исчезает; «removed» не показывается: лишний текст, язык и
    жизненный цикл ради ничего). Кнопка `ignore` от уведомления старой сборки (activity-интент) по-прежнему
    обрабатывается оболочкой как раньше (тост «{host} ignored · Undo»).
- **Тап по уведомлению** (`ACTION_OPEN_EVENT` + id события; тап по свёрнутой сводке группы — id самого нового
  события группы, а не просто «открыть приложение») → `openEvent` / `takeLaunchEvent` → оболочка закрывает
  оставленные листы и диалоги (`popUntil` первого маршрута) и открывает Logs → Events на событии
  (`LogsController.showEvent`: фильтр сбрасывается, если прячет событие).
- **Уведомления об обновлении приложения** (не события журнала; `core/update_flow.dart`, `UpdateFlow`): канал
  `update`, id 4 (один на «Update X available» / «Update X ready · Install»; заменяется, не копится), BigText,
  кнопка **Install** только у «ready». Dart шлёт `postUpdate {title, text, version, install, installLabel, file?}`
  (язык приложения), общая запись «объявлено» — `updateAnnounced` / `setUpdateAnnounced` (SharedPreferences
  `jorm_update/announced`). Тап по телу — `ACTION_OPEN_UPDATE` (+ `EXTRA_INSTALL`) → `openUpdate(install)` /
  `takeLaunchUpdate` → оболочка открывает Settings → Data (`_openUpdate`) и при `install` запускает установку.
  Если в `postUpdate` есть `file` (путь скачанного APK), кнопка Install **не открывает приложение**: это
  `PendingIntent.getActivity` на прозрачную `UpdateInstallActivity` (`UpdateInstallShade.kt.tmpl`, манифест
  оверлея: без окна, вне Recents), которая сверяет файл с `ready.json` и зовёт `UpdateInstaller` (системный
  диалог); нет файла / не совпал — приложение на карточке обновлений. Показываются только в фоне (из живого
  процесса) либо заданием WorkManager при закрытом процессе (`UpdateJob.kt.tmpl`: `UpdateCheckWorker` поднимает
  безголовый FlutterEngine на `updateJobMain`; канал `jormungand/updatejob` — `sync` настроек из приложения,
  `input` / `done` для изолята задания; зависимость `androidx.work:work-runtime-ktx` добавляет
  `apply_android_overlay.mjs` — не ниже 2.10: старые тянут Room 2.5, и R8 full mode (AGP 9) вырезает конструктор
  `WorkDatabase_Impl` → падение в `InitializationProvider` на каждом старте (так сломалась 0.1.2-beta.2); страховка —
  `-keep class * extends androidx.room.RoomDatabase { <init>(); }` в `jormungand-proguard.pro`; `ResumeReceiver` после замены пакета перерегистрирует работу). Фильтр — мастер и
  `notifCfg.updateAvailable` («New version»). Логика и причины — `updates.md`, раздел 6.
- **Разрешение** (API 33+; ниже — только переключатель системы). Запрос один раз за установку при первом
  успешном подключении (`request(once: true)`, нативный флаг в SharedPreferences; мастер-переключатель
  Notifications выключен — не просим) и когда пользователь включает переключатель на странице
  Notifications (`SystemNotifier.askForSwitch`; Android сам не покажет диалог после двух отказов).
  Заблокировано (отказ или выключено в системе) — на странице Notifications строка-предупреждение с
  кнопкой «Open settings» (`ACTION_APP_NOTIFICATION_SETTINGS`); состояние перечитывается при возврате.
- **Уведомление VPN.** Заголовок Jormungand, текст «VPN is on · <запись · сервер>», кнопка «Disconnect»,
  тап открывает приложение. Имя шлёт Dart (`setStatus {node}`) на каждое изменение, пока подключено, и только
  при включённых мастере и Status; иначе общий текст. «Disconnect» просит Dart (`CoreHost.disconnect`,
  как кнопка дока); нет ответа (ядро Dart не слушает) — служба сама закрывает туннель. Скорость в тексте — пока нет.
- **Скрыть уведомление VPN.** Мастер или Status выключены (`NotifCfg.vpnStatusShown` = false) — уведомления
  нет вообще. `SystemNotifier` шлёт `setStatus {visible}` (`NotifyIo.setVpnVisible`) на каждое изменение
  (подключено или нет) и при старте, `resumeInBackground` — после возврата VPN. Натив хранит выбор сам
  (SharedPreferences `jorm_notify/vpnShown`, по умолчанию «показано»): служба слушается его без Dart —
  старт после обновления (`ResumeAfterUpdate`), плитка, перезапуск. Служба обязана войти в foreground за 5 с
  после `startForegroundService`, поэтому `enterForeground()` всегда делает `startForeground`, а при
  «скрыто» сразу `stopForeground(STOP_FOREGROUND_REMOVE)` (на Android 12+ показ уведомления службы
  отложен ~10 с, так что обычно оно не мелькает вовсе). Переключение на лету: скрыто → `stopForeground(REMOVE)`,
  показано → `startForeground` с текущим уведомлением (`refreshNotification`; отказ системы — остаётся
  скрытым, в логе). **Почему VPN не умирает:** пока туннель установлен, система сама держит привязку к `VpnService`
  (`BIND_VPN_SERVICE`, процесс получает приоритет как у foreground-службы); WireGuard для Android живёт вообще
  без постоянного уведомления. Движок Dart (`AppEngine`) от foreground-статуса службы напрямую не зависит —
  он держится процессом, а процесс — этой привязкой. Другого, что требует «foreground» (плитка, `ResumeStore.hold`,
  Disconnect), нет: плитка читает `isUp`, `hold` — про окно приёмника, «Disconnect» из уведомления
  при скрытом остаётся кнопками дока / плитки. По умолчанию уведомление **показано**: на агрессивных
  прошивках (MIUI, ColorOS…) видимое уведомление может быть надёжнее для долгой жизни процесса. Под
  Status в Settings → Notifications на Android подсказка: скрытое уведомление — VPN всё равно работает
  (значок ключа в строке состояния — от Android).

### Плитка быстрых настроек (Android)

Круглая плитка в шторке включает и выключает VPN и показывает имя текущего подключения под подписью
(API 29+; раньше имя идёт в подпись). Код: `JormungandTileService.kt.tmpl` (`JormungandTileService`,
`TileBridge`, `TileChannel`), Dart — `lib/platform/tile_channel.dart` (`TilePort` / `TileChannel`) и
`lib/core/tile_sync.dart` (`TileSync`, его запускает `JormungandApp` только на Android). Иконка —
`android_overlay/app/src/main/res/drawable/ic_tile.xml` (шестиугольник дока с символом питания; у
приложения пока нет собственного глифа), тексты — `res/values{,-ru}/jorm_strings.xml` (язык системы, не
выбор в приложении).

- **Каналы.** Отдельные от `jormungand/vpn`: MethodChannel `jormungand/tile` (`state` {phase, name,
  canConnect}, `launchAction`, `moveToBack`) и EventChannel `jormungand/tile_events`
  (`{type: 'tile', action: 'connect' | 'disconnect' | 'home', launch}`). Событие плитки НЕ копится, пока Dart не
  слушает (у `vpn_events` очередь есть): старое нажатие не должно сработать позже. Подписка Dart на этот
  канал = признак «ядро Dart живо»; движок живёт с процессом (раздел «Работа в фоне»), поэтому метка остаётся и после закрытия окна; снимается, когда Dart перестаёт слушать.
- **Долгое нажатие на плитку** (на One UI — нажатие на её подпись) система шлёт `QS_TILE_PREFERENCES` в
  `MainActivity` (intent-filter в манифесте; по умолчанию открылись бы «О приложении»). `TileBridge.onLaunchIntent`
  превращает его в то же событие канала с `action: 'home'` (живой Dart — сразу, иначе через `launchAction`),
  `TileSync.onHome` → `HomeShell`: закрывает шиты и диалоги (`popUntil` первого маршрута) и открывает вкладку
  Home с доком.
- **Состояние плитки.** «Включено» — факт нативной стороны (`JormungandVpnService.isUp`): верно и без Dart
  (активность закрыта, туннель держится) и после рестарта процесса (ничего не поднято = выключено). Dart
  добавляет то, чего натив не знает: «Подключение…» / «Отключение…» (`unavailable`, пока живой Dart
  подтверждает фазу; устаревшее за 90 с не считается) и имя. `TileSync` шлёт `state` на каждое изменение
  `CoreHost` (фаза, имя, `canConnect = dock.hasEntry`), натив держит последнее в SharedPreferences. Служба
  туннеля сама просит плитку перечитаться на старте и остановке. Плитка не `ACTIVE_TILE`: система
  привязывает её при каждом открытии шторки, состояние читается заново.
- **Имя** (`tileName`): цепочка — её имя; иначе сервер, через который уходит трафик (`флаг имя`); без
  сервера — имя записи; нет записи — пусто («Не подключено» / «Настройте в приложении»).
- **Нажатие, включено.** Dart жив → событие `disconnect` (его `CoreHost.disconnect`, как кнопка дока; если
  Dart не отметился за 6 с — туннель останавливается нативно). Dart не жив → `stopTunnel` в службе.
- **Нажатие, выключено.** Нет согласия VPN (`VpnService.prepare != null`) или нечего подключать
  (`canConnect` = false) → открывается приложение (`startActivityAndCollapse`, на API 34+ с
  PendingIntent). Dart жив → событие `connect` (то же `CoreHost.connect`, с запомненным текущим
  профилем / цепочкой; не «переподключить»: включённое и занятое игнорируется). Dart не жив →
  `MainActivity` с extra `TileBridge.EXTRA_ACTION=connect`; Dart забирает его (`launchAction`) после
  `init()`, подключается и по успеху отправляет приложение назад (`moveTaskToBack` — движок остаётся
  жить, а не `finish()`).
- **Почему не безголовый движок.** Два движка Dart в одном процессе — два `CoreService` на одном каталоге
  данных (состояние, кэш libbox); согласие VPN требует Activity; план и каталог живут только в Dart.
  Один движок на процесс (`AppEngine`), один код пути подключения, без гонок; пока движка нет (процесс только что стартовал) — `MainActivity` с extra, цена — окно приложения
  на секунду; дальше движок живёт и без окна, плитка шлёт событие прямо в него.

## Релиз

Подписанный манифест и файлы — в публичном репо `FuckingSherlock/jormungand-releases` (релиз `feed`);
ключ подписи манифеста и порядок — `docs/updates.md`. Ключ подписи APK и ключ манифеста — разные.
