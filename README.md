# Exocortex Template

> **Тип репозитория:** `Format` — source-of-truth для структуры персонального экзокортекса.

Типовой репозиторий для развёртывания персонального экзокортекса — системы управления знаниями и задачами с ИИ-агентами (Claude Code).

## Что вы получите

После fork + setup у вас будет:

- **CLAUDE.md** — глобальные правила для Claude Code (протоколы Open/Work/Close, Capture-to-Pack, WP Gate)
- **memory/** — оперативная память: текущие задачи, различения, чеклисты
- **DS-strategist/** — автоматический агент-стратег: утренние планы, вечерние ревью, недельные сессии
- **DS-strategy/** — личный стратегический хаб: планы, отчёты, неудовлетворённости
- **launchd** — автоматический запуск агента по расписанию (macOS)

## Быстрый старт

### 1. Fork

```bash
gh repo fork TserenTserenov/FMT-exocortex --clone
```

### 2. Setup

Используйте [DS-exocortex-setup](https://github.com/TserenTserenov/DS-exocortex-setup) для автоматической настройки:

```bash
gh repo clone TserenTserenov/DS-exocortex-setup
cd DS-exocortex-setup
bash setup.sh
```

Или настройте вручную:

1. Замените `{{GITHUB_USER}}` на ваш GitHub username во всех файлах
2. Замените `{{WORKSPACE_DIR}}` на путь к вашей рабочей директории (напр. `~/Github`)
3. Замените `{{TIMEZONE_HOUR}}` на час запуска стратега в UTC (напр. `4` для 7:00 MSK)
4. Замените `{{TIMEZONE_DESC}}` на описание времени (напр. `7:00 MSK`)
5. Замените `{{CLAUDE_PATH}}` на путь к Claude CLI (напр. `/opt/homebrew/bin/claude`)
6. Установите launchd-агентов: `cd DS-strategist && bash install.sh`
7. Скопируйте `memory/` в `~/.claude/projects/.../memory/`
8. Скопируйте `CLAUDE.md` в корень рабочей директории

### 3. Первая сессия

```bash
cd DS-strategy
claude
```

Попросите Claude провести первую стратегическую сессию.

## Обновления из upstream

```bash
git remote add upstream https://github.com/TserenTserenov/FMT-exocortex.git
git fetch upstream
git merge upstream/main
```

Обновления шаблонов, промптов и протоколов приходят из upstream. Ваши личные данные (планы, memory) не затрагиваются.

## Структура

```
FMT-exocortex/
├── CLAUDE.md                    # Глобальные правила Claude Code
├── .claude/settings.local.json  # Permissions
├── memory/                      # Оперативная память (7 файлов)
├── DS-strategist/               # Агент-стратег (промпты + скрипты + launchd)
└── DS-strategy/                 # Стратегический хаб (планы, отчёты)
```

## Placeholder-переменные

| Переменная | Описание | Пример |
|------------|----------|--------|
| `{{GITHUB_USER}}` | Ваш GitHub username | `johndoe` |
| `{{WORKSPACE_DIR}}` | Рабочая директория | `~/Github` |
| `{{TIMEZONE_HOUR}}` | Час запуска стратега (UTC) | `4` |
| `{{TIMEZONE_DESC}}` | Описание времени | `7:00 MSK` |
| `{{CLAUDE_PATH}}` | Путь к Claude CLI | `/opt/homebrew/bin/claude` |

## Принципы

1. **Platform-space vs User-space** — шаблоны (platform) обновляются из upstream, личные данные (user) — только у вас
2. **3-слойная архитектура** — Layer 1 (MEMORY.md, ≤100 строк) → Layer 2 (CLAUDE.md, ≤300 строк) → Layer 3 (memory/*.md, on-demand)
3. **Capture-to-Pack** — знания фиксируются по ходу работы, не теряются
4. **WP Gate** — любая нетривиальная работа начинается с проверки плана
5. **Hub-and-Spoke** — DS-strategy (хаб) + */WORKPLAN.md (споки)

## Лицензия

MIT
