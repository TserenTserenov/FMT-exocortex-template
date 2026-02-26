# Навигация по репозиториям (Слой 3)

> Claude читает этот файл при поиске конкретного файла/репо. Для поиска знаний → MCP (см. секцию ниже).

## Ключевые файлы

| Тема | Файл |
|------|------|
| Различения (жёсткие пары) | `memory/hard-distinctions.md` |
| FPF (навигация, принципы) | `memory/fpf-reference.md` |
| Правила по типам репо | `memory/repo-type-rules.md` |
| Чеклисты | `memory/checklists.md` |
| SOTA-практики (18 шт.) | `memory/sota-reference.md` |
| Протокол Open (WP Gate, Ритуал) | `memory/protocol-open.md` |
| Протокол Close (чеклист, шаблон) | `memory/protocol-close.md` |
| Нулевые принципы + иерархия | `ZP/README.md` |
| Кодирование сущностей | `SPF/spec/SPF.SPEC.001-entity-coding.md` |
| Масштабируемость Pack | `SPF/spec/SPF.SPEC.003-pack-scalability.md` |

## Репозитории

| Репо | Путь |
|------|------|
| LMS Aisystant (READ-ONLY) | `DS-IT-systems/aisystant/` |
| SystemsSchool_bot (READ-ONLY) | `DS-IT-systems/SystemsSchool_bot/` |
| Монорепо ИИ-систем (7 шт.) | `DS-IT-systems/DS-ai-systems/` |
| — Стратег (Grade 3) | `DS-IT-systems/DS-strategist/` |
| — Шаблонизатор (Grade 0) | `DS-IT-systems/DS-ai-systems/setup/` |
| — Наладчик (Grade 2) | `DS-IT-systems/DS-ai-systems/fixer/` |
| — Статистик (Grade 1) | `DS-IT-systems/DS-ai-systems/pulse/` |
| — Оценщик (Grade 2) | `DS-IT-systems/DS-ai-systems/evaluator/` |
| Личная онтология | `DS-strategy/ontology.md` |
| Программа обучения | `DS-principles-curriculum/` |

## Pack-репо

| Pack | Путь |
|------|------|
| PACK-education | Методика обучения |
| PACK-personal | Личностное развитие |

## Ключевые документы (Pack DP)

| Документ | Код |
|----------|-----|
| Тиры обслуживания | DP.ARCH.002 |
| Role-Centric Architecture | DP.D.033 |
| Runbook ошибок бота | DP.RUNBOOK.001 |

## MCP — доступ к знаниям

> Конфигурация: `.claude/settings.local.json` → `mcpServers`. Подробнее: CLAUDE.md § 5.

| Что ищу | MCP-инструмент |
|---------|---------------|
| Доменное знание, паттерны, архитектура | `knowledge-mcp search("запрос", source_type="pack")` |
| Конкретный документ по коду (DP.AGENT.001) | `knowledge-mcp get_document("filename")` |
| Список источников знаний | `knowledge-mcp list_sources()` |
| Образовательные руководства | `knowledge-mcp search("запрос", source_type="guides")` |
| Цели ученика, самооценка | `ddt read_digital_twin("1_declarative/1_2_goals")` |
| Структура метамодели двойника | `ddt describe_by_path("/")` |

| MCP-сервер (исходники) | Путь |
|------------------------|------|
| knowledge-mcp | `DS-MCP/knowledge-mcp/src/index.ts` |
| digital-twin-mcp | `DS-MCP/digital-twin-mcp/src/worker-sse.js` |

## Стратегия

| Файл | Путь |
|------|------|
| Стратегия | `DS-strategy/docs/Strategy.md` |
| WeekPlan | `DS-strategy/current/` |

## WP Context Files

> Все context files: `DS-strategy/inbox/WP-{N}-{slug}.md`
> Архив: `DS-strategy/archive/wp-contexts/`
