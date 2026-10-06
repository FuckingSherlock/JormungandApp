# Отложенные правки мокапа

Мокап (`design/src`) заморожен с 2026-10-06 ради экономии токенов: изменения логики и UI идут в core + Flutter,
а сюда пишется, что перенести в мокап, когда вернёмся к ПК-версии.

- `20-profiles.js` `chainExitOrder`: узлы, которым цепочка не задала порядок, идут в порядке `pickOrder`
  юнита выхода (подписки/профиля): `orderRefs(orderRefs(unitRefs(...), unitOwner(c.outId)?.pickOrder), c.exitOrder)`.
  Как в core `catalog.dart` `chainExitOrder`.
- Golden: после переноса — перегенерировать `core/test/golden/catalog.json` и очистить `_mockupBehind`
  в `core/test/catalog_golden_test.dart` (пока там пропущены сценарии, где core ушёл вперёд мокапа).
- Лист Notifications: строка-предупреждение «Уведомления заблокированы» + «Открыть настройки» (на
  телефоне, когда POST_NOTIFICATIONS запрещено), как `NotifPermissionHint` во Flutter.
- `42-apps.js`: в комментарии-шапке — приложение с правилом, которого нет на устройстве, остаётся
  видимым в User и Configured.
- Фильтр подписки (`updater.dart`): отфильтрованные серверы не попадают в `gone`. В мокапе логики
  обновления нет (mock backend) — переносить нечего, только если мок имитирует `gone` по фильтру.
