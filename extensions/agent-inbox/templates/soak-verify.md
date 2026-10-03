# Template: soak-verify

> Проверка устойчивости сервиса за N часов после deploy (паттерн WP-277).

## Параметры

| Параметр | Тип | Пример |
|----------|-----|--------|
| `service_name` | str | `multi-domain-projection-worker` |
| `deploy_commit` | str | `b0558ce` |
| `since` | datetime | 2026-04-28T11:37:00+03:00 |
| `metrics` | list | [throughput, error_rate, lag] |
| `notify_via` | str | `gmail` / `telegram` |
| `recipient` | str | `pilot@example.invalid` (пример; укажите адрес получателя) |

## Промпт

```
Ты one-time soak-verify агент для сервиса {{service_name}} (deploy commit {{deploy_commit}} в {{since}}).

## Контекст

Через 24h после deploy. Проверь устойчивость по метрикам {{metrics}}.

## Шаги

1. `git log --oneline -10` в репо {{service_name}}: есть ли коммиты после {{deploy_commit}} с `revert` / `hotfix` / `fix({{wp}})` → ⚠️ regression.

2. Сформируй email-чеклист с конкретными командами для пилота (Railway logs, SQL queries, TG alerter check) — он за 30 мин закроет verify локально.

3. Отправь через {{notify_via}} на {{recipient}}:
   - subject: `[{{wp}}] {{n}}h soak verify — checklist готов`
   - body: markdown-чеклист с verdict ✅ STABLE / ⚠️ NEW COMMIT / 🚨 ROLLBACK

## Чеклист (template для тела email)

См. полный WP-277 промпт как образец — содержит секции:
- Git status (auto-checked)
- Railway deployment status (что проверить)
- Логи за {{n}}h (что грепать)
- Throughput sample (как считать)
- SQL lag за {{n}}h (psql query)
- TG alerter channel (что искать)
- Verdict logic (когда закрывать РП vs не закрывать)

## Acceptance

- Email отправлен на {{recipient}} в течение 5 мин после старта.
- Git verdict ✅/⚠️/🚨 включён в тело.
- Конкретные команды Railway/SQL/TG прописаны.
```
