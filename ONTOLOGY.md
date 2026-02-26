# Онтология IWE

> Source-of-truth: `FMT-exocortex-template/ONTOLOGY.md`
> Pack-обоснование: [DP.IWE.001](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md)

## IWE (Intelligent Working Environment)

Персональная интегрированная среда для интеллектуальной работы: мышления, планирования, создания и развития при поддержке ИИ-систем, методологии и накопленных знаний. Развёртывается из этого шаблона через fork + setup.

**IWE — не инструмент, а среда.** Инструмент решает задачу. Среда формирует способ работы.

**Четыре архитектурных вида IWE** (ISO 42010 / TOGAF):

| Вид | Тип (FPF) | Элементы | Без них |
|-----|-----------|---------|---------|
| **Системы** | U.System | Claude Code, бот, MCP-серверы (knowledge-mcp, ddt), WakaTime, Git | Нет исполнения |
| **Описания** | U.Description | Экзокортекс (CLAUDE.md + memory/), Pack, промпты, методология (FPF/SPF) | ИИ = stateless, вайб-работа |
| **Роли** | U.RoleAssignment | Стратег (R1), Экстрактор (R2), Синхронизатор (R8), Пользователь | Хаос задач |
| **Артефакты** | U.Work | DS-strategy/, Pack-репо, проекты, Цифровой двойник | Нет результата |

Полная модель с таблицами по каждому виду: [LEARNING-PATH.md § 1.2](docs/LEARNING-PATH.md).

> **Почему 4 вида, а не плоский список?** IWE содержит элементы разных онтологических типов. Системы запускаются, описания загружаются, роли назначаются, артефакты производятся. Плоский список смешивает типы — категориальная ошибка (FPF A.7 Strict Distinction).

> **Почему IWE, а не «экзокортекс»?** Экзокортекс — описания и инструкции (Вид 2: Описания), один из четырёх видов. Называть всю среду «экзокортексом» = называть компьютер «жёстким диском». Подробнее: [DP.IWE.001 §2.1](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.001-intelligent-working-environment.md).

## Экзокортекс (Exocortex)

Подсистема памяти и инструкций внутри IWE. Конфигурация взаимодействия пользователя с ИИ-системами через модульный CLAUDE.md и структурированную Memory.

**Состав:** CLAUDE.md + MEMORY.md + memory/*.md

## Пространства (Spaces)

| Пространство | Что | Обновление |
|-------------|-----|-----------|
| **Platform-space** | Шаблоны, промпты, протоколы, скрипты | Из upstream (update.sh) |
| **User-space** | Планы, MEMORY.md, стратегии, личные данные | Только локально |

**Ключевое различение:** Platform-space обновляется из upstream, User-space — никогда.

## Слои памяти (Memory Layers)

| Слой | Файл | Назначение | Лимит |
|------|------|-----------|-------|
| Layer 1 | `MEMORY.md` | Оперативная память: РП, навигация | ≤100 строк |
| Layer 2 | `CLAUDE.md` | Протоколы, правила, архитектура | ≤300 строк |
| Layer 3 | `memory/*.md` | Стабильные знания: различения, чеклисты, SOTA | ≤10 файлов, ≤100 строк каждый |

## Протоколы сессии

| Протокол | Фаза | Назначение |
|----------|------|-----------|
| **WP Gate** | Open | Блокирующая проверка: задача есть в плане? |
| **Ритуал согласования** | Open | Объявление работы + подтверждение |
| **Capture-to-Pack** | Work | Фиксация знаний на рубежах |
| **Close** | Close | Коммит, обновление статусов, backup |
| **Exit Protocol** | Close | Артефакт + статус + уведомление (для всех агентов) |

## Контуры системы (Platform Contours)

> Экзокортекс — часть 4-контурной системы. Ты получаешь шаблон (L3), настраиваешь под себя (L4) и подключаешься к платформе (L2).

```
L1: Ecosystem    — платформа + сообщество + все IWE пользователей + МИМ
  L2: Platform   — инфраструктура и сервисы (бот, MCP-серверы, Knowledge Index)
    L3: Template — этот шаблон (CLAUDE.md + memory/ + стратег + DS-strategy/)
      L4: Personal IWE — твой экземпляр (настроенный, с личными Pack и данными)
```

| Контур | Что для тебя | Как обновляется |
|--------|-------------|-----------------|
| **L1: Ecosystem** | Сообщество, семинары, контент | Ты участвуешь |
| **L2: Platform** | Бот, Knowledge Index, MCP | Обновляется разработчиком |
| **L3: Template** | Этот репо: формат, протоколы | `update.sh` (Platform-space) |
| **L4: Personal IWE** | Твоя работа, планы, знания | Только ты (User-space) |

**Опциональные сервисы (L3 рекомендует, L4 настраивает):**

| Сервис | Тип | Роль | Продукт |
|--------|-----|------|---------|
| knowledge-mcp | MCP-сервер | Поиск по Pack, guides, DS | Результаты hybrid search (~5400 документов) |
| ddt | MCP-сервер | Цифровой двойник ученика | Метамодель, цели, самооценка (IND.1-4) |
| WakaTime | Инструмент | Observability работы | Метрики времени по проектам |

> Подробная модель: [DS-ecosystem-development/11-platform-contours.md](https://github.com/TserenTserenov/DS-ecosystem-development)

## MCP — протокол доступа к знаниям

Claude Code подключается к 2 MCP-серверам платформы через HTTP (Cloudflare Workers). Конфигурация: `.claude/settings.local.json` → `mcpServers`. Обновляется через `update.sh`.

| MCP-сервер | URL | Инструменты |
|------------|-----|-------------|
| **knowledge-mcp** | `https://knowledge-mcp.aisystant.workers.dev/mcp` | `search`, `get_document`, `list_sources` |
| **ddt** | `https://digital-twin-mcp.aisystant.workers.dev/mcp` | `describe_by_path`, `read_digital_twin`, `write_digital_twin` |

> Поиск по руководствам: `knowledge-mcp search("запрос", source_type="guides")`. Отдельный guides-mcp не нужен.

**Принцип:** Одна база знаний — бот и экзокортекс работают с одними и теми же MCP-серверами. Поменял знание в Pack → и бот, и Claude Code сразу его видят.

## Иерархия принципов

```
Level 0: ZP (нулевые принципы)       ← аксиомы, фреймворка нет
    ↓ дисциплинируют
Level 1: FPF (первые принципы)       ← принципы + фреймворк (бандл)
    ↓ ограничивают
Level 2: SPF → Pack (вторые принципы) ← фреймворк + принципы (раздельно)
    ↓ определяют
Level 3: S2R и др. → DS              ← фреймворки + принципы (раздельно)
```

**Fallback Chain:** DS (3-й) → Pack (2-й) → Base.Принципы (SPF → FPF → ZP)

## Типы репозиториев (3 типа)

| Тип | Подтип | Что содержит | Source-of-truth | Кто создаёт |
|-----|--------|-------------|-----------------|-------------|
| **Base** | Принципы | ZP, FPF, SPF — принципы и фреймворки | Да | Платформа |
| **Base** | Форматы | FMT-* — протоколы структуры | Да (для формата) | Платформа |
| **Pack** | — | Паспорт предметной области | Да | Пользователь |
| **DS** | instrument / governance / surface | Производные от Pack | Нет | Пользователь |

## Ролецентричная архитектура (DP.D.033)

Роль описывается **независимо от исполнителя**. Сначала: что делать, какие обязательства, какие рабочие продукты. Потом: кто исполняет (bash-скрипт, Claude, человек).

| Понятие | Определение |
|---------|-----------|
| **Роль** | Функция: ЧТО делать (обязательства, РП, методы) |
| **Исполнитель (holder)** | Система: КТО делает (Claude, bash, человек) |
| **Агент** | Исполнитель с автономностью (Grade 2+) |
| **Инструмент** | Исполнитель без автономности (Grade 0-1) |

**Нотация:** `Holder#Role:Context@Window` (FPF A.2)

Каталог: 21 платформенная роль (R1-R21) в DP.AGENT.001 §3.2. Cross-Pack: 35 ролей (§3.3).

## Стратег (Strategist Agent)

Автоматический ИИ-агент, запускаемый по расписанию через launchd (macOS) или cron (Linux).

| Компонент | Путь | Назначение |
|-----------|------|-----------|
| Runner | `roles/strategist/scripts/strategist.sh` | Запуск Claude CLI с промптом |
| Промпты | `roles/strategist/prompts/*.md` | 9 сценариев (session-prep, strategy-session, day-plan, day-close, week-review...) |
| Расписание | `roles/strategist/scripts/launchd/*.plist` | LaunchAgent (утро + воскресенье) |
| Установщик | `roles/strategist/install.sh` | Копирование plist + загрузка |

## Стратегический хаб (DS-strategy)

Governance-хаб для управления задачами и стратегией.

| Компонент | Назначение |
|-----------|-----------|
| `current/` | Текущий WeekPlan, DayPlan |
| `docs/` | Strategy.md, Dissatisfactions.md, Session Agenda.md |
| `inbox/WP-*.md` | Файлы контекста РП: накопленная история работы между сессиями |
| `archive/` | Завершённые планы и контексты |
| `exocortex/` | Backup memory/ + CLAUDE.md |

**Паттерн:** Hub-and-Spoke — DS-strategy (хаб) координирует, WORKPLAN.md (споки) в каждом репо.

## Placeholder-переменные

| Переменная | Назначение | Когда |
|------------|-----------|-------|
| `{{GITHUB_USER}}` | GitHub username | setup.sh |
| `{{WORKSPACE_DIR}}` | Рабочая директория | setup.sh |
| `{{TIMEZONE_HOUR}}` | Час запуска стратега (UTC) | setup.sh |
| `{{TIMEZONE_DESC}}` | Описание времени | setup.sh |
| `{{CLAUDE_PATH}}` | Путь к Claude CLI | setup.sh |
| `{{HOME_DIR}}` | Домашняя директория | setup.sh |
| `{{CLAUDE_PROJECT_SLUG}}` | Slug проекта Claude | setup.sh |

Подставляются один раз при развёртывании (setup.sh) и далее не меняются.

## Механизм обновлений

```
Авторская сторона (еженедельно):
  Авторские репо → template-sync.sh → FMT-exocortex-template (GitHub)

Пользовательская сторона (по запросу):
  FMT-exocortex-template → update.sh → git fetch upstream → merge
                                         ↓
                           CLAUDE.md → workspace root
                           memory/*.md → ~/.claude/projects/
                           (MEMORY.md НИКОГДА не перезаписывается)
```

**Platform-space (обновляется):** CLAUDE.md, 7 memory/*.md, промпты, скрипты.

**User-space (не обновляется):** MEMORY.md, DS-strategy/, личные планы.
