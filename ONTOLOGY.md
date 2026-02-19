# Онтология экзокортекса

> Source-of-truth: `FMT-exocortex-template/ONTOLOGY.md`

## Экзокортекс (Exocortex)

Персональная система управления знаниями и задачами с ИИ-агентами. Развёртывается из этого шаблона через fork + setup.

**Состав:** CLAUDE.md + memory/ + Стратег + DS-strategy/

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

## Иерархия принципов

```
Level 0: ZP (нулевые принципы)       ← аксиомы, фреймворка нет
    ↓ дисциплинируют
Level 1: FPF (первые принципы)       ← принципы + фреймворк (бандл)
    ↓ ограничивают
Level 2: SPF → Pack (вторые принципы) ← фреймворк + принципы (раздельно)
    ↓ определяют
Level 3: S2R и др. → Downstream      ← фреймворки + принципы (раздельно)
```

**Fallback Chain:** Downstream (3-й) → Pack (2-й) → SPF (форма 2-го) → FPF (1-й) → ZP (0-й)

## Типы репозиториев

| Тип | Уровень | Критерий | Source-of-truth |
|-----|---------|----------|-----------------|
| **Foundation** | 0-й | Транс-дисциплинарные аксиомы | Да |
| **Framework** | 1-й / 2-й | Фреймворки корректности | Да |
| **Pack** | 2-й | Паспорт предметной области | Да |
| **Format** | 3-й | Протокол структуры репо | Да (для формата) |
| **Downstream** | 3-й | Производные от Pack | Нет |

Подтипы Downstream: `instrument` (код), `governance` (планы), `surface` (курсы).

## Стратег (Strategist Agent)

Автоматический ИИ-агент, запускаемый по расписанию через launchd (macOS) или cron (Linux).

| Компонент | Путь | Назначение |
|-----------|------|-----------|
| Runner | `strategist-agent/scripts/strategist.sh` | Запуск Claude CLI с промптом |
| Промпты | `strategist-agent/prompts/*.md` | 9 сценариев (session-prep, strategy-session, day-plan, day-close, week-review...) |
| Расписание | `strategist-agent/scripts/launchd/*.plist` | LaunchAgent (утро + воскресенье) |
| Установщик | `strategist-agent/install.sh` | Копирование plist + загрузка |

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
