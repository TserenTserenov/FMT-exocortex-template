# Онтология экзокортекса

> Source-of-truth: `FMT-exocortex/ONTOLOGY.md`

## Сущности

### Экзокортекс (Exocortex)

Персональная система управления знаниями и задачами с ИИ-агентами. Развёртывается из этого шаблона через fork + setup.

**Состав:** CLAUDE.md + memory/ + DS-strategist/ + DS-strategy/

### Пространства (Spaces)

| Пространство | Что | Обновление |
|-------------|-----|-----------|
| **Platform-space** | Шаблоны, промпты, протоколы, скрипты | Из upstream (git pull) |
| **User-space** | Планы, memory/MEMORY.md, стратегии, личные данные | Только локально |

**Ключевое различение:** Platform-space обновляется из upstream, User-space — никогда.

### Слои памяти (Memory Layers)

| Слой | Файл | Назначение | Лимит |
|------|------|-----------|-------|
| Layer 1 | `MEMORY.md` | Оперативная память: РП, навигация | ≤100 строк |
| Layer 2 | `CLAUDE.md` | Протоколы, правила, архитектура | ≤300 строк |
| Layer 3 | `memory/*.md` | Стабильные знания: различения, чеклисты | ≤10 файлов, ≤100 строк каждый |

### Протоколы сессии

| Протокол | Фаза | Назначение |
|----------|------|-----------|
| **WP Gate** | Open | Блокирующая проверка: задача есть в плане? |
| **Ритуал согласования** | Open | Объявление работы + подтверждение |
| **Capture-to-Pack** | Work | Фиксация знаний на рубежах |
| **Close** | Close | Коммит, обновление статусов, backup |

### Стратег (Strategist Agent)

Автоматический ИИ-агент, запускаемый по расписанию через launchd (macOS).

| Компонент | Путь | Назначение |
|-----------|------|-----------|
| Runner | `DS-strategist/scripts/strategist.sh` | Запуск Claude CLI с промптом |
| Промпты | `DS-strategist/prompts/*.md` | 9 сценариев (session-prep, strategy-session, day-plan, day-close, week-review…) |
| Расписание | `DS-strategist/scripts/launchd/*.plist` | LaunchAgent (утро + воскресенье) |
| Установщик | `DS-strategist/install.sh` | Копирование plist + загрузка |

### Стратегический хаб (DS-strategy)

Governance-хаб для управления задачами и стратегией.

| Компонент | Назначение |
|-----------|-----------|
| `current/` | Текущий WeekPlan |
| `docs/` | Strategy.md, Dissatisfactions.md, Session Agenda.md |
| `inbox/WP-*.md` | Файлы контекста РП: накопленная история работы между сессиями |
| `archive/` | Завершённые планы |
| `archive/wp-contexts/` | Архивированные контекстные файлы завершённых РП |
| `exocortex/` | Backup memory/ + CLAUDE.md |

**Паттерн:** Hub-and-Spoke — DS-strategy (хаб) координирует, */WORKPLAN.md (споки) в каждом репо.

## Типы репозиториев

| Тип | Критерий | Source-of-truth |
|-----|----------|-----------------|
| **Pack** | Паспорт предметной области | Да |
| **Framework** | Рамки корректности | Да |
| **Format** | Протокол структуры репо | Да (для формата) |
| **Downstream** | Производные от Pack | Нет |

Подтипы Downstream: `instrument` (код), `governance` (планы), `surface` (курсы).

**Fallback Chain:** Downstream → Pack → SPF → FPF

## Placeholder-переменные

| Переменная | Назначение | Пространство |
|------------|-----------|-------------|
| `{{GITHUB_USER}}` | GitHub username | Setup-time |
| `{{WORKSPACE_DIR}}` | Рабочая директория | Setup-time |
| `{{TIMEZONE_HOUR}}` | Час запуска стратега (UTC) | Setup-time |
| `{{TIMEZONE_DESC}}` | Описание времени | Setup-time |
| `{{CLAUDE_PATH}}` | Путь к Claude CLI | Setup-time |
| `{{HOME_DIR}}` | Домашняя директория | Setup-time |

Подставляются один раз при развёртывании (setup.sh) и далее не меняются.

## Механизм обновлений

```
[upstream] TserenTserenov/FMT-exocortex-template
    │
    │  git fetch upstream && git merge upstream/main
    ▼
[fork] user/FMT-exocortex-template
    │
    │  Подстановка переменных (setup.sh, один раз)
    ▼
[deployed] Рабочий экзокортекс
```

**Что обновляется (Platform-space):** промпты, протоколы, скрипты, memory-шаблоны (кроме MEMORY.md).

**Что НЕ обновляется (User-space):** MEMORY.md (содержимое), DS-strategy/current/, личные планы, стратегии.

**Конфликты при merge:** Возможны в файлах, которые пользователь изменил. Git merge показывает конфликты для ручного разрешения.
