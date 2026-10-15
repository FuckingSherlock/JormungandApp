# Этап 2a выполнен (selector вместо urltest, выбор сервера группы — ядром)

Удалить после закрытия этапа 2. Код: `group_pick.dart` (+тест), `config.dart` (всегда selector), `auto.dart` (Health.weak, failAfter и
`pickFastest` для Fastest, `_improve`), `fallback.dart` (то же для целей правил + внеочередной раунд `networkChanged()`, вызывается из
`service.dart` рядом с `auto.networkChanged()`), `sbapi.dart` (testGroup/results удалены). Доки `docs/core.md` обновлены.

## Для 2b
- Слабый ответ (`PoolResult.byChecker`) в Fastest не «живой»: одна лишняя волна из 16 ради сильного, иначе лучший слабый (`pickFastest`).
- `pickFastest(keys, probe1)` / `pickPriority` / `rankCandidates` — чистые, пригодны для выбора при connect.
- Нет теста на `FallbackService.networkChanged()` (у Auto есть: «a network change looks out of turn»).
- Не сделано: заметка в `.claude_states/mockup_todo.md` (Fastest-группы — selector, выбирает ядро; `failAfter` теперь действует и на Fastest;
  `auto/fastest` = «Auto сменил Fastest-сервер»; правила «If unavailable» двигаются так же, без события) — дописать.
- Проверить глазами `docs/core.md` ~1130-1135 (строка про пинг в абзаце «Auto: probe-in») и строки 228-236, 257-290.
