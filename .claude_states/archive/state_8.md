# State 8 — 2026-10-04

Ветка сессии `claude/core-mvp`, основная `claude/karing-fork-environment-a45c2c` (fast-forward после
каждого коммита). Предыдущие планы: `state_7.md` «Дальше», `state_6.md` «Дальше» / «На потом» — в силе.

## Сделано в этой сессии

- **Тулчейн Android** в `G:\ANDROID_DEV` (JDK 17, Flutter 3.47.6, Go, SDK 36, NDK 28.2); libbox.aar
  собирается локально (`core/tool/build_libbox.ps1`) и в CI. Подробно — `docs/platforms.md`.
- **Flutter-приложение `app/`**: перенесены все экраны мокапа (Home, Nodes, Route, Rules (шторкой),
  Settings целиком, Logs, Live connections), `platform_caps.dart` прячет то, чего нет на Android
  (системный прокси, TUN|Proxy). Global|Rules на Android горизонтальный.
- **Интервал обновления подписки** — секунды с выбором единиц (модалка число + с/мин/ч; пусто = авто,
  0 = никогда, мин. 10 с) в docs, ядре, мокапе и Flutter.
- **Raw-логи на Android**: строки ядра, sing-box туннеля и временных ping/speed-экземпляров (`[ping]`,
  `[speed]`), `[android]` из Kotlin; причины неудачных пингов по этапам. Пинги на телефоне работают
  (отвечают мосты через RU-SPB; прямые EU-ноды режет ТСПУ — не баг).
- **Дубли HY2** (`-1`/`-2`) — баг ядра: подписка опрашивается двумя UA (base64 + Clash), Clash-шаблон
  Remnawave дописывает `client-fingerprint` (→ uTLS, alpn h3) и `skip-cert-verify`. Исправлено:
  uTLS на QUIC не ставится (sing-box его там не умеет), `alpn h3` у hy2 не вариант, `pinSHA256` →
  `insecure` (sing-box не умеет пин сертификата; решение принято, юзер может отменить). parserVersion 4.
- **Документация**: `docs/platforms.md` (мокап ↔ Flutter Windows ↔ Flutter Android), CLAUDE.md
  переписан как короткий индекс.
- **Подпись и автодеплой**:
  - release-keystore создан: `%USERPROFILE%\.jormungand\android-release.jks` + пароль в
    `android-release.pass`; копии — секреты GitHub (`JORM_ANDROID_KEYSTORE_B64`, `JORM_ANDROID_KS_PASS`)
    и secrets-mcp (те же имена, хост `backup-only.invalid`). Токен `JORM_RELEASES_TOKEN` (PAT,
    contents:write на `jormungand-releases`) задан юзером.
  - **Всегда релизный ключ**, локально и в CI; `-DebugSigned` удалён. Локальная сборка
    `pwsh app/tool/build_apk.ps1` берёт версию из ленты (`<последняя>.dev`, тот же versionCode) —
    ставится `adb install -r` поверх CI-сборки, следующая CI-бета предлагается. `-DryRun` печатает план.
  - `.github/workflows/release-android.yml`: push в основную ветку (app/**, core/**) → **beta**
    `<pubspec>-beta.<run>`; тег `vX.Y.Z` → **stable**; общий versionCode `3000 + run_number`; beta после
    stable — выше него. Публикация в `FuckingSherlock/jormungand-releases` (релиз `feed` с манифестами).
    Опубликована и стоит на телефоне 0.1.0-beta.4 (данные приложения стёрты при переходе с debug-ключа —
    подписку юзер добавляет заново). Stable-тег живьём ещё не проверялся.
- Конфиги Remnawave читались только на чтение (API, токен в secrets-mcp); в панели ничего не менялось.

## Проверить в начале

- Зафиксировано: CI после cdc2813 опубликовал **0.1.0-beta.5**; локальная сборка `0.1.0-beta.4.dev`
  (code 3004, релизный ключ) встала `adb install -r` поверх CI beta.4 — сейчас она на телефоне.
- Юзер должен выбрать канал **Beta** в Settings → Data → App updates — проверить, что приложение
  находит обновление из ленты (end-to-end апдейтер на Android ещё не проверялся живьём).

## Дальше

- 4 падающих `flutter test` (устаревшие: `shell_test` ждёт Slider; `home_test` текст Android Proxy;
  алерт VPN-down) + переполнение 3.6 px в `app/lib/widgets/stat_cards.dart:205`.
- Подписать тосты-уведомления Logs в shell.
- Заглушки Nodes во Flutter: QR (share/scan/import), «?»-справки, «Route check» цепочки (pair-ping).
- Почистить `app/README.md` (устаревшее «Flutter не установлен», ручные шаги, TODO).
- Создать `app/SYNCED_FROM`, когда приложение совпадёт с мокапом.
- Опционально скиллы `sync-app` / `release`.
- Замечено, не сделано: `registerMyInterface` в Kotlin — no-op; `filesDir/libbox/configuration.json`
  содержит секрет API sing-box.
- Позже (из state_7): фичи Karing (IPv6, NTP, TUN, Mixed, TLS, Mux, порт, общий доступ, WARP),
  упрощённый per-app на Android, правила с учётом страны выхода, POST_NOTIFICATIONS и действия
  уведомления, статус «VPN отозван», версия sing-box на Android, урезать теги libbox (APK ~100 МБ).

## Правила, подтверждённые юзером

- Android = всё как в мокапе, кроме системного прокси, переключателя TUN|Proxy и настроек только для них;
  без заглушек и демо-данных.
- Экономия лимитов: мелкие задачи, свежие короткие агенты, 1–2 одновременно.
- Сборки только с релизным ключом; beta и stable сосуществуют.
