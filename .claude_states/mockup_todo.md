# Отложенные правки мокапа

Мокап (`design/src`) заморожен с 2026-10-06 ради экономии токенов: изменения логики и UI идут в core + Flutter,
а сюда пишется, что перенести в мокап, когда вернёмся к ПК-версии.

- `20-profiles.js` `chainExitOrder`: узлы, которым цепочка не задала порядок, идут в порядке `pickOrder`
  юнита выхода (подписки/профиля): `orderRefs(orderRefs(unitRefs(...), unitOwner(c.outId)?.pickOrder), c.exitOrder)`.
  Как в core `catalog.dart` `chainExitOrder`.
- `70-profile-forms.js` ~307: убрать `goneBlockHtml` из редактора цепочки (`cc:${side}:${id}`) —
  пропавшие серверы в цепочке не показываются (docs/connect-model.md «Пропавшие ноды»).
- Route: переключатель Simple / Profiles только показывает режим (точка — режим в работе); полоса
  «Сейчас маршрут идёт через X» + «Использовать этот режим» — единственное, что меняет режим; пустой
  режим — «Профилей пока нет» + «Создать профиль» / «Добавить подписку или сервер» (закрывает лист,
  Nodes «+» на той вкладке). Док / кнопка питания: текущий режим пуст, другой нет → Route на другом
  режиме (`dockTap`, `toggleMain`); вторую строку дока для этого случая можно переформулировать.
- Golden: после переноса — перегенерировать `core/test/golden/catalog.json` и очистить `_mockupBehind`
  в `core/test/catalog_golden_test.dart` (пока там пропущены сценарии, где core ушёл вперёд мокапа).
- Лист Notifications: строка-предупреждение «Уведомления заблокированы» + «Открыть настройки» (на
  телефоне, когда POST_NOTIFICATIONS запрещено), как `NotifPermissionHint` во Flutter.
- Лист Notifications: под Status на телефоне вторая подсказка «Если выключить, уведомление скрывается.
  VPN продолжает работать; значок ключа — от Android…» (Flutter: `settings_look.dart`, `NotifSheet`);
  мастер и Status выключены = постоянное уведомление VPN скрыто совсем.
- `42-apps.js`: в комментарии-шапке — приложение с правилом, которого нет на устройстве, остаётся
  видимым в User и Configured.
- Фильтр подписки (`updater.dart`): отфильтрованные серверы не попадают в `gone`. В мокапе логики
  обновления нет (mock backend) — переносить нечего, только если мок имитирует `gone` по фильтру.
- Settings → Data (блок App updates): строка «Auto-download» (`genCfg.updAutoDownload`: `off` / `wifi` по умолчанию / `always`) между Auto-check и Channel; серая, когда Auto-check выкл. Выбор: Off / Wi-Fi only / Always (в браузерном макете платных сетей нет — можно показывать Off / Always). Подпись «Downloads what Auto-check finds; installing stays yours». Flutter: `settings_data.dart` (`_UpdatesBlock`); в бэкап через genCfg; нужна и мок-логика (`mockUpdate`) — после найденного плановой проверкой сразу `downloading` → `ready`. Док: `docs/updates.md` §6, §11.
