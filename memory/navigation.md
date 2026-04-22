---
valid_from: 2026-04-13
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
---
# Навигация по репозиториям (Слой 3)

> Claude читает этот файл при поиске конкретного файла/репо. Для поиска знаний → соответствующий MCP-search tool (зависит от подключённого knowledge-сервера).

## Ключевые файлы

| Тема | Файл |
|------|------|
| Различения (жёсткие пары) | `memory/hard-distinctions.md` |
| FPF (навигация, принципы) | `memory/fpf-reference.md` |
| Правила по типам репо | `memory/repo-type-rules.md` |
| Чеклисты | `memory/checklists.md` |
| SOTA-практики (18 шт.) | `memory/sota-reference.md` |
| Протокол Open (WP Gate, Ритуал) | `memory/protocol-open.md` |
| Протокол Close (маршрутизация, Quick Close) | `memory/protocol-close.md` |
| Day Close (полный алгоритм) | `.claude/skills/day-close/SKILL.md` |
| Week Close (полный алгоритм) | `.claude/skills/week-close/SKILL.md` |
| Шаблоны DayPlan/WeekPlan | `memory/templates-dayplan.md` |
| Нулевые принципы + иерархия | `ZP/README.md` |
| Кодирование сущностей | `SPF/spec/SPF.SPEC.001-entity-coding.md` |
| Масштабируемость Pack | `SPF/spec/SPF.SPEC.003-pack-scalability.md` |

## Репозитории

| Репо | Путь |
|------|------|
<!-- Добавьте свои DS-репо. Пример: -->
<!-- | Мой бот (READ-ONLY) | `your-org/your-bot/` | -->
<!-- | Монорепо ИИ-систем | `your-org/ai-systems/` | -->
| Шаблонизатор | `FMT-exocortex-template/setup.sh` |
| Личная онтология | `DS-strategy/ontology.md` |
| Программа обучения | `DS-principles-curriculum/` |

## Pack-репо

| Pack | Путь |
|------|------|
| PACK-personal | Личностное развитие |
| PACK-verification | Верификация и приёмка (трансдоменный) |
| PACK-autonomous-agents | Автономные агенты (BC, различения, методы) |

## Ключевые документы (Pack DP)

| Документ | Код |
|----------|-----|
| Тиры обслуживания | DP.ARCH.002 |
| Каталог ролей (Role-Centric) | DP.ROLE.001 § 3.2 |
| Role-Centric Architecture | DP.D.033 |
| Реестр исполнителей | DP.ROLE.001 § 3.1 |
| Runbook ошибок бота | DP.RUNBOOK.001 |

## MCP

| MCP | Путь |
|-----|------|
<!-- Добавьте свои MCP-серверы. Пример: -->
<!-- | `<domain>-mcp` (исходники) | `DS-MCP/<domain>-mcp/src/index.ts` | -->
<!-- | `<domain>-mcp` (ingest)    | `DS-MCP/<domain>-mcp/scripts/ingest.ts` | -->
<!-- | Activity Hub               | `your-org/activity-hub/` | -->
<!-- | Автономные агенты (код)    | `DS-autonomous-agents/` | -->
<!-- | Данные агентов (workspace) | `DS-agent-workspace/` | -->

## Стратегия

| Файл | Путь |
|------|------|
| Стратегия | `DS-strategy/docs/Strategy.md` |
| Реестр всех РП (WP-1…WP-85+) | `DS-strategy/docs/WP-REGISTRY.md` |
| WeekPlan | `DS-strategy/current/` |

## GitHub-организации (НЕ путать!)

| Org | Какие репо | Примеры |
|-----|-----------|---------|
| `ailev` | FPF | `ailev/FPF` |

> **Правило:** При генерации GitHub-ссылки → проверь org по этой таблице. НЕ подставляй `aisystant` по умолчанию.

## WP Context Files

> Все context files: `DS-strategy/inbox/WP-{N}-{slug}.md`
> Архив: `DS-strategy/archive/wp-contexts/`
