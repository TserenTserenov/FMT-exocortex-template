# Чеклист безопасности (§Б) — WP-212 B7.1

> Lazy-reference. Загружается по Security Gate (B7.3): РП затрагивает PII, секреты или payment_credentials.
> Извлечён из скилла `/archgate` при удалении АрхГейта (2026-08-08) — гейт снят, чеклист безопасности сохранён как самостоятельное правило.

Отвечай на каждый пункт кратко.

## Auth & Access

- Требует ли компонент аутентификации? JWT верифицируется локально (JWKS), не через доверие заголовкам? (ADR-IWE-012)
- Есть ли авторизация (subscription check / RBAC)? Нет — ⚠️.
- Могут ли аргументы инструмента подменить identity пользователя? (например, `user_id` в теле запроса — должен браться из JWT, не из body)

## Secrets

- Есть ли новые секреты? Где хранятся (Cloudflare secrets / GHA secrets / `.secrets/`)? Не хардкодятся?
- Обновлён ли B2.1 Secrets Inventory?

## Классификация данных (B7.3.1) — БЛОКИРУЮЩЕЕ для РП с PII / payment_credentials / secrets

Source-of-truth: `{{WORKSPACE_DIR}}/DS-ecosystem-development/C.IT-Platform/C2.IT-Platform/C2.2.Architecture/Data-Governance/B7.3.1-l2-data-classification-map.md` (если файл не найден — ищи в своём DS-ecosystem-development-репо). Если затрагивается чувствительный класс — пройти 6 пунктов:

1. **Класс данных?** public / PII / payment_credentials / secrets — определить по тестам §1 B7.3.1. Если только public → остальное пропустить.
2. **Слой?** L1 / L2 / L3 / L4 — проверить таблицу B7.3.1 §2 «где какие классы могут жить». Размещение запрещено таблицей = ❌.
3. **Логирование** соответствует §3.1 B7.3.1? PII только маскированно/тип-без-значения; payment_credentials + secrets запрещены в любом виде. Иначе ❌.
4. **Шифрование at-rest + column-level** соответствует §3.2? Для secrets/payment_credentials column-level Fernet обязателен. Иначе ❌.
5. **RLS-политика** есть для user-level ownership? Если нет — БЛОКЕР до первого insert на prod.
6. **Cross-user агрегация** соблюдает §3.5 (k-anonymity k=10 для группировок, consent для индивидуальных строк)? Экспорт PII во внешнюю систему без DPA = ❌.

## Injection & Input

- SQL: параметризованные запросы? Нет whitelist динамических имён? (иначе ⚠️)
- Команды: shell injection возможна?
- MCP tools: аргументы sanitized перед SQL/shell?

## Шифрование

- Токены OAuth в БД — шифруются? (B2.5 pending — отмечать как ⚠️ до закрытия)
- HTTPS везде? TLS до БД (Neon — да по умолчанию)?

## Итог

≥2 пунктов ❌ или PII логируется → блокер: реализацию не начинать до исправления.
