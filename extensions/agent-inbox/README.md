# Agent Inbox IWE

> Единый конвейер агентных задач: постановка → диспетчеризация → результат.
> **Source-of-truth для архитектуры:** [SPEC.md](SPEC.md). Контекст РП: [WP-324](../WP-324-agentnyj-konvejer-iwe.md).

## Зачем

Поставить задачу агенту «на потом» и забрать результат при открытии дня. Не держать в голове, где смотреть и через какой канал запускать.

## Что внутри

| Папка | Что хранит |
|-------|-----------|
| `tasks/` | Активные задачи (markdown + frontmatter), `status: pending | assigned | in_progress` |
| `results/` | Результаты завершённых задач (артефакт + audit-trail) |
| `scout/` | Дневные находки разведчика (`YYYY-MM-DD.md`) |
| `templates/` | Шаблоны промптов: analyze-section, scout-daily, evolution-cron, soak-verify |
| `archive/YYYY/` | Закрытые задачи и результаты старше 7 дней |

## Как поставить задачу

1. Скопируй подходящий шаблон:
   ```bash
   cp inbox/agent/templates/analyze-section.md \
      inbox/agent/tasks/TASK-$(date +%Y-%m-%d)-<slug>.md
   ```
2. Заполни frontmatter:
   - `id` — соответствует имени файла
   - `kind` — что за тип задачи (см. SPEC §3)
   - `priority` — P0 (critical), P1 (high), P2 (medium), P3 (low)
   - `agent` — канал исполнения (`ccr-opus` / `ccr-sonnet` / `remote-systemd` / `local-launchd`)
   - `due` — когда должно быть запущено
   - `result_location` — **обязательно**: repo + branch + path. Единственная точка истины.
   - `acceptance` — критерии готовности
   - `params` — параметры для подстановки в template
3. `git add tasks/ && git commit && git push`

## Где забрать результат

В `result_location` task'а (внешний репо) ИЛИ в `results/RESULT-<task-id>.md` (audit-trail + ссылка).

## Какие шаблоны есть

| Template | Назначение |
|----------|-----------|
| `_template.md` | Skeleton — копируй для новых kind'ов |
| `analyze-section.md` | Анализ раздела руководства по WRITING-PIPELINE (WP-321, WP-300) |
| `scout-daily.md` | Дневная разведка медленных источников |
| `evolution-cron.md` | Weekly evolution правила Pack (WP-272 паттерн) |
| `soak-verify.md` | Soak-verify сервиса после deploy (WP-277 паттерн) |

## Состояния task'а

```
pending ─→ assigned ─→ in_progress ─→ completed | failed | blocked
   ↑           │
   └───────────┘ (sweeper возвращает stale assigned >2h в pending)
```

## Инвариант (критически важно)

> Каждый task имеет **единственный `result_location`**. Агенту запрещено создавать результат в другом месте через fallback (если main защищён → НЕ создаёт feature branch + PR автоматически). Несоответствие = `status: failed`.

Корень правила: 17 мая инцидент — навигационная путаница, когда результаты 07-10 оказались на разных ветках + 1 PR + феды коммиты на main, из-за fallback-инструкции в промпте. См. [inventory-2026-05-17.md](inventory-2026-05-17.md) §«Расследование».

## Безопасность

- `tasks/*-secrets-*.md` — в `.gitignore` (если нужно передать что-то приватное — env, не файл).
- Pre-commit hook grep на `API_KEY|TOKEN|PASSWORD` (B7.7a) защищает от случайного коммита секретов в промпт.
- Dispatcher НЕ выполняет произвольный bash из task body — только через template-substitution и предусмотренный канал.

## Статус автоматизации (на 17 мая 2026)

- ✅ Архитектура: SPEC.md + DP.SC.135 + DP.ROLE.045 опубликованы.
- ✅ Структура папок + 5 шаблонов + dispatcher/scout-промпты (референс).
- ⚠️ **Dispatcher CCR** заблокирован API issue (RemoteTrigger v1→v2 event_type, см. [bug-2026-05-17](../bugs/bug-2026-05-17-remote-trigger-v1-v2-event-type.md)).
- ⚠️ Постановка задач сейчас — manual (через git). Dispatch — manual через локальный Claude.

## Roadmap

1. Разобраться с RemoteTrigger v2 API → разблокировать автоматический dispatcher.
2. Альтернатива (если v2 API долго): локальный dispatcher на личном сервере (systemd timer + Python + RemoteTrigger v1 API через сохранённый OAuth) — даёт ту же функциональность без зависимости от CCR-окружения.
3. Promotion в FMT (Ф6 WP-324) — `extensions/agent-inbox/` шаблон для других IWE-инсталляций.

## Связанные документы

- [SPEC.md](SPEC.md) — полная архитектура (10 разделов)
- [inventory-2026-05-17.md](inventory-2026-05-17.md) — реестр существующих рутин IWE
- [DP.SC.135 Agent Inbox](https://github.com/{{GOVERNANCE_ORG}}/PACK-digital-platform/blob/main/pack/digital-platform/08-service-clauses/DP.SC.135-agent-inbox.md) — обещание
- [DP.ROLE.045 Dispatcher](https://github.com/{{GOVERNANCE_ORG}}/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.045-dispatcher.md) — роль
