# Ядро в отдельном isolate — план (2026-10-07)

Решение пользователя: делать (релиза нет, ломать можно). Разбор — analyzer, проверено по коду.

## Выбор: вариант B
`CoreService` целиком (runtime, Auto, пул пингов, sbapi gRPC, LogBook/EventBook, SnapshotStore, updater) —
в worker isolate. `Catalog` + `LiveCoreHost` + UI-сервисы (TileSync, SystemNotifier, resume) остаются в root.
Граница уже есть: `LiveCoreHost` ходит в ядро только через `CoreApi` (JSON-карты, `core/lib/src/api.dart`).
Вариант A (Catalog в worker) нереален: 4.3k строк, 121 прямая правка `.catalog` в 29 файлах app.

## Ограничения платформы
- Dart зовёт libbox только MethodChannel'ами (`jormungand/vpn`) + loopback gRPC; FFI/JNI нет. Исходящие
  вызовы из worker — `BackgroundIsolateBinaryMessenger` (`ensureInitialized(rootIsolateToken)`).
- Входящие platform→Dart (EventChannel, setMessageHandler) в фоне НЕ работают: `vpn_events` (stopped, log —
  один native sink), `network_events`, `tile_events`, resume `windowAttached`, notify `onDisconnect` остаются
  в root; `stopped`/`log`/metered пересылаются в worker через порт.
- Root-only значения (data dir, appVersion, abis, installedApkPath, box cache dir) — в spawn config.
- Windows: каналов нет, FFI/Job-объекты процессные — только spawn; `onExitRequested` ждёт dispose worker'а.

## Протокол (`core/lib/src/remote/`, чистый Dart)
`CoreServer` (worker) / `RemoteCore implements CoreApi` (root). Один FIFO-порт на направление.
`{t:req,id,m,a}` → `{t:res,id,ok|err:{kind,message,code}}` (ошибки восстанавливаются в типы: TunNeedsAdmin,
CatalogException, SingBoxError, FormatException — `_explain`). Стримы: `sub/ev/end/cancel`, подписка по
первому слушателю (statusChanges запускает таймер на onListen). Отмена ping/speedTest. Коалесинг в worker
≤10 Гц: логи пачками ~100 мс, результаты пингов пачками. Нормализовать типы карт на приёме.

## Этапы
0. Замер на телефоне (Timeline-метки, `--profile`) — нужен телефон по adb; пропускаем, если его нет.
1. Async `CoreApi`: `log/events/updateStatus/postEvent` → Future; чистые хелперы (`manualNode/share/parse/
   addSourceFromText`) вон из CoreApi — прямые вызовы; `note`, `ruleSetTimes` в CoreApi (вместо
   `core.logBook.note`, `core.ruleSets.updatedTimes` в platform_seams). Всё in-process, тесты зелёные.
   Заодно: `CoreApi.flush()` (EventBook пишет пачками раз в 1,5 с) и вызов из LiveCoreHost на паузе
   приложения; desktop `SingBoxProcess.start` — `watchApi:false` для пинг-боксов, как у LibboxRunner.
2. Протокол + in-memory транспорт; контрактный набор тестов CoreApi через RemoteCore.
3. Реальный spawn (`CoreWorker.spawn`, handshake, onError/onExit, dispose с таймаутом); сначала Windows
   за флагом.
4. Android-мост: worker-side ChannelLibboxPort, root-side единственный слушатель событий; проверка на
   устройстве: connect/disconnect, пинг-боксы, revoke, adopt, resume после обновления, плитка/уведомления.
5. Сглаживание UI (если не сделано раньше), docs/core.md + docs/platforms.md.
6. Опционально: сериализация снапшота вне root, LogFeed/foldEvents вне root, супервизор worker'а
   (respawn + adopt — туннель переживает ядро).

## Риски
Копирование сообщений меняет рантайм-типы; лишний хоп на connect; падение worker'а при поднятом туннеле;
порядок root `stopped` vs worker `_gone`; Windows exit ждёт dispose; холодный старт ждёт handshake.
jormd не меняется (держит CoreService напрямую). FakeCoreHost не меняется.
