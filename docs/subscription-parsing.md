# Логика парсинга подписок

## Проблема

Серверы подписок возвращают разные форматы и разные наборы нод в зависимости от User-Agent запроса. Karing решает это перебором UA до первого успешного ответа — теряет ноды и не оптимален по запросам.

Цель: получить максимально полный список нод с минимальным количеством HTTP-запросов.

---

## Форматы подписок

| Формат | Детект | Типичный UA |
|--------|--------|-------------|
| sing-box JSON | `Content-Type: application/json` или тело начинается с `{` + есть `"outbounds"` | `sing-box/1.x.x` |
| Clash/Meta YAML | `Content-Type: text/yaml` или тело начинается с `proxies:` | `mihomo/1.x.x`, `clash-verge` |
| Base64 URI-list | тело — валидный base64, после decode строки `vmess://`/`vless://`/`trojan://`/`ss://` | `v2ray`, `NekoBox` |
| URI-list (plain) | строки начинаются с известных схем без base64 | любой |

Формат определяется **по телу ответа**, не по UA — это позволяет слать один запрос и знать что получили.

---

## Стратегия: Discovery + Cache

### Первое добавление подписки

1. Слать **параллельно** запросы с тремя UA:
   - `sing-box/1.13.0` — нативный формат, часто содержит Reality/Hysteria2
   - `mihomo/1.19.28` — Clash.meta YAML, широко поддерживается
   - `ClashMeta` — запасной вариант clash
2. Для каждого ответа: детектировать формат → парсить → получить список нод
3. Дедупликация по `(address, port, protocol, uuid/password)` — не по имени, имена могут отличаться
4. Записать в кеш подписки:
   ```
   subscription.ua_strategy = [
     { ua: "sing-box/1.13.0", unique_node_count: 47, etag: "abc123" },
     { ua: "mihomo/1.19.28",  unique_node_count: 12, etag: "def456" },  // 12 нод которых нет в sing-box ответе
   ]
   ```
   Если UA давал 0 уникальных нод — он исключается из стратегии.

### Обновление подписки (повторные запросы)

1. Слать запросы **только по закешированным UA** (обычно 1, редко 2)
2. Добавлять заголовки `If-None-Match: <etag>` и `If-Modified-Since: <date>`
3. Получили `304 Not Modified` → ноды не изменились, пропускаем парсинг
4. Получили новый контент → парсить → обновить ETag в кеше

**Happy path обновления: 1 запрос + 304 = 0 работы.**

### Пересмотр стратегии

Пересматривать стратегию (заново делать discovery) при:
- Ручном запросе пользователя ("обновить со всеми UA")
- Количество нод в ответе упало >20% от предыдущего — возможно сервер сменил поведение
- Прошло >7 дней с последнего discovery

---

## Детектирование формата

```
detect_format(body, content_type):
  if content_type contains "json" OR body.trimmed starts with "{":
    if body contains "\"outbounds\"":  → FORMAT_SINGBOX
    else:                              → FORMAT_UNKNOWN_JSON
  
  if content_type contains "yaml" OR body starts with "proxies:":
    → FORMAT_CLASH_YAML
  
  decoded = try base64_decode(body.trim())
  if decoded is valid AND decoded contains "://":
    → FORMAT_URI_LIST (работать с decoded)
  
  if body contains "vmess://" OR "vless://" OR "trojan://" OR "ss://":
    → FORMAT_URI_LIST (plain)
  
  → FORMAT_UNKNOWN
```

---

## Дедупликация нод

Ключ дедупликации: `sha256(protocol + address + port + identity)`

Где `identity`:
- vmess/vless: uuid
- trojan: password
- ss: method + password
- hysteria2: password
- tuic: uuid

Имя ноды (`tag`) — **не** часть ключа, разные UA могут называть одну ноду по-разному.

При конфликте (одинаковый ключ, разные параметры) — предпочитать sing-box формат как наиболее полный (там могут быть дополнительные поля типа `multiplex`, `tls.reality`).

---

## Ранжирование нод после получения

После сбора полного списка — первичная сортировка ещё до тестирования latency:

1. **Фильтр явно нерабочих**: ноды с истёкшим сроком (если сервер пишет expiry в имени), дубли после дедупликации
2. **Протокольный приоритет** (настраивается пользователем): Reality > Hysteria2 > VLESS > VMess > Trojan > SS
3. **Latency-тест**: параллельно для всех нод, timeout 5 сек, URL выбирается автоматически из списка ниже
4. Финальная сортировка: работающие по latency ASC, нерабочие в конец

### Fallback-список URL для latency-теста

Karing использует статический список без автовыбора — пользователь выбирает вручную.
Мы делаем автодетект: при первом запуске (и при смене сети) проверяем список **напрямую** (без прокси) и кешируем первый рабочий.

Список (приоритет сверху вниз):
```
https://www.gstatic.com/generate_204          # Google — быстрый, заблокирован в CN/IR/RU
http://cp.cloudflare.com/generate_204         # Cloudflare
http://www.msftconnecttest.com/connecttest.txt # Microsoft
http://detectportal.firefox.com/success.txt   # Mozilla
http://connectivity-check.ubuntu.com          # Ubuntu
http://checkip.amazonaws.com                  # AWS (работает в большинстве стран)
```

Логика выбора:
1. Проверить все параллельно с таймаутом 3 сек (прямое соединение, без прокси)
2. Взять первый ответивший с кодом 200/204
3. Закешировать результат — перепроверять при смене сети (смена IP/интерфейса) или по запросу пользователя
4. Если все недоступны напрямую → fallback на `tcp_ping` (TCP-handshake к хосту ноды, без HTTP)
5. Пользователь может задать свой URL в настройках — он идёт первым в списке перед автодетектом

> **Karing-источник:** `setting_manager.dart:1621` — `kUrlTestList` — тот же набор URL,
> но без автовыбора. DNS по региону там есть (`getResolverDns`, `getDirectDns`),
> а urlTest URL — всегда статика.

**Важно:** latency-тест гоняется **через ноду** (через sing-box API `/proxies/{name}/delay`). TCP-ping как fallback даёт относительное ранжирование даже если все HTTP-цели заблокированы.

---

## Что хранится на диске

```
subscriptions/
  <id>.json          — метаданные подписки + закешированные ноды
  <id>.strategy.json — ua_strategy + etag + последний discovery
```

Ноды кешируются локально — приложение работает без интернета с последним известным списком.
