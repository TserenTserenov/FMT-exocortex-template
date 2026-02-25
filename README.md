# Персональный экзокортекс

> Рабочее пространство для интеллектуальной работы и развития с ИИ-агентами.

Ты проходишь курсы. Бот помогает каждый день. Но знания остаются в голове, планы — в заметках, а контекст теряется между сессиями.

**Экзокортекс** — это твоё личное рабочее пространство, где Claude помогает планировать неделю, фиксировать знания и строить собственную базу. Он подключён к платформе: те же знания, тот же бот, но теперь ещё и личный стратег.

## Что ты получишь

После установки у тебя будет работающая система из 4 компонентов:

| Компонент | Что делает |
|-----------|-----------|
| **CLAUDE.md** | Правила для Claude Code: как открывать сессию, как фиксировать знания, как закрывать. Claude помнит контекст между сессиями |
| **memory/** | Оперативная память: текущие задачи, различения, чеклисты, SOTA-практики. Claude читает их в начале каждой сессии |
| **Стратег** | Роль (R1), запускается автоматически: утренний план дня, вечернее ревью, недельная сессия стратегирования |
| **DS-strategy/** | Твой стратегический хаб: планы недель, отчёты, неудовлетворённости, входящие заметки |

**Как это выглядит на практике:**

- Утром — получаешь план дня в Telegram (Стратег составил его ночью)
- Открываешь VS Code → `claude` → Claude знает, что в плане, и предлагает начать с приоритетного
- Работаешь — Claude фиксирует знания по ходу (Capture-to-Pack)
- Закрываешь сессию — результат зафиксирован, план обновлён
- В понедельник — Стратег готовит черновик недельного плана, вы обсуждаете его на сессии стратегирования

> **Первая установка?** [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) — пошаговое руководство от чистого компьютера (30-60 мин).
> **Хочешь понять, что за этим стоит?** [LEARNING-PATH.md](docs/LEARNING-PATH.md) — полный путь изучения: принципы, протоколы, агенты, Pack, SOTA и где всё найти.
> **Быстрая справка / FAQ:** [IWE-HELP.md](docs/IWE-HELP.md) — то же, что знает бот @aist_me_bot.
> **Почему принципы, а не навыки?** [principles-vs-skills.md](docs/principles-vs-skills.md) — аргументация и генеративная иерархия.

---

## Быстрый старт

### Требования

| Инструмент | Проверить | Установить |
|-----------|-----------|-----------|
| **ОС** | macOS, Linux или Windows (WSL) | macOS: launchd (авто). Linux: cron. Windows: WSL + cron |
| Git | `git --version` | macOS: `xcode-select --install` / Linux: `sudo apt install git` / Windows: WSL |
| GitHub CLI | `gh --version` | macOS: `brew install gh` / Linux: [cli.github.com](https://cli.github.com/) |
| GitHub аккаунт | `gh auth status` | `gh auth login` |
| Claude Code | `claude --version` | `npm install -g @anthropic-ai/claude-code` |
| WakaTime (рекомендуется) | `wakatime-cli --version` | `/setup-wakatime` в Claude Code (автоматически) |

> **WakaTime** трекает время работы: по проектам, категориям (AI Coding, Coding, Writing Docs), редакторам. Интеграция включает три уровня: (1) Claude Code hooks — heartbeat при каждом промпте и tool call, (2) VS Code extension — время редактирования файлов, (3) Desktop App — время фокуса окна (чтение ответов, браузер). Бесплатный план: статистика за 2 недели. Данные используются Стратегом в Week Review (S03) и Morning Check (S42). **Настройка:** `/setup-wakatime` в Claude Code. Подробнее: [wakatime.com](https://wakatime.com).

> **Автоматизация Стратега:** на macOS — launchd (устанавливается автоматически). На Linux — настройте cron вручную (`crontab -e`). Без автоматизации всё работает — Стратег запускается вручную: `bash roles/strategist/scripts/strategist.sh morning`

### Шаг 0: Создать рабочую папку

Создайте на своём компьютере **одну папку** для всех репозиториев — текущих и будущих. Все репозитории экзокортекса (шаблон, стратегия, Pack, проекты) должны находиться в одной общей папке. По умолчанию это `~/Github`:

```bash
mkdir -p ~/Github
```

> **Важно:** Эта папка — ваше рабочее пространство. В неё будут клонироваться все репозитории: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{область}/`, `DS-{проекты}/` и др. CLAUDE.md тоже будет лежать в корне этой папки. Название может быть любым (не обязательно `Github`), но все репо должны быть в одном месте — Claude Code ориентируется на эту структуру.

### Шаг 1: Запустить установку (~5 мин)

```bash
cd ~/Github    # или ваша рабочая директория из Шага 0
gh repo clone TserenTserenov/DS-ai-systems -- --depth 1
cd DS-ai-systems/setup
bash setup.sh
```

Скрипт спросит:
- GitHub username
- Рабочую директорию (по умолчанию `~/Github` — укажите путь из Шага 0)
- Путь к Claude CLI (определяется автоматически)
- Часовой пояс для Стратега (UTC)

<details>
<summary>Что делает setup.sh</summary>

1. Проверяет prerequisites (git, gh, claude)
2. Форкает `FMT-exocortex-template` → ваш GitHub аккаунт
3. Заменяет 7 плейсхолдеров (`{{GITHUB_USER}}`, `{{WORKSPACE_DIR}}` и др.)
4. Копирует `CLAUDE.md` → корень рабочей директории
5. Копирует `memory/*.md` → `~/.claude/projects/.../memory/`
6. Устанавливает launchd-агентов для Стратега
7. Создаёт `DS-strategy/` — приватный репозиторий для стратегирования

Посмотреть без выполнения: `bash setup.sh --dry-run`
</details>

### Шаг 2: Проверить установку

```bash
# Проверить файлы
ls ~/Github/CLAUDE.md
ls ~/.claude/projects/*/memory/

# Проверить launchd
launchctl list | grep strategist

# Проверить DS-strategy
ls ~/Github/DS-strategy/
```

### Шаг 3: Первая сессия (~30 мин)

```bash
cd ~/Github
claude
```

Скажи Claude: **«Проведём первую стратегическую сессию»**

Claude прочитает CLAUDE.md и memory/ и проведёт тебя через:
1. **Определение целей** — Кем ты хочешь быть через год? Чему научиться?
2. **Неудовлетворённости** — Что мешает? Где разрыв между текущим и желаемым?
3. **Первый WeekPlan** — Конкретные задачи на неделю с бюджетами времени
4. **Обновление MEMORY.md** — Твои РП появятся в таблице

После этого Claude в каждой сессии будет видеть твой план и работать по нему.

<details>
<summary>Ручная настройка (если setup.sh не подходит)</summary>

1. Замените `{{GITHUB_USER}}` на ваш GitHub username во всех файлах
2. Замените `{{WORKSPACE_DIR}}` на путь к рабочей директории (напр. `~/Github`)
3. Замените `{{HOME_DIR}}` на домашнюю директорию (значение `$HOME`)
4. Замените `{{CLAUDE_PROJECT_SLUG}}` на путь через дефисы (напр. для `~/Github` → `-Users-yourname-Github`)
5. Замените `{{TIMEZONE_HOUR}}` на час запуска стратега в UTC (напр. `4` для 7:00 MSK)
6. Замените `{{TIMEZONE_DESC}}` на описание времени (напр. `7:00 MSK`)
7. Замените `{{CLAUDE_PATH}}` на путь к Claude CLI (напр. `/opt/homebrew/bin/claude`)
8. Установите launchd-агентов: `cd roles/strategist && bash install.sh`
9. Скопируйте `memory/` в `~/.claude/projects/.../memory/`
10. Скопируйте `CLAUDE.md` в корень рабочей директории

</details>

---

## Обновления

Протоколы, промпты и справочники обновляются в upstream. Твои личные данные (планы, MEMORY.md, стратегия) **не затрагиваются**.

```bash
cd ~/Github/FMT-exocortex-template
bash update.sh
```

| Команда | Что делает |
|---------|-----------|
| `bash update.sh` | Скачивает обновления из upstream, применяет к стандартным файлам |
| `bash update.sh --check` | Показать доступные обновления без применения |
| `bash update.sh --dry-run` | Показать что изменится, не применять |

**Что обновляется (standard):** CLAUDE.md, memory/*.md (кроме MEMORY.md), промпты Стратега.
**Что НЕ трогается (personal):** MEMORY.md (твои РП), DS-strategy/ (твои планы).

---

## От шаблона к рабочему пространству

### Что происходит при setup.sh

```
FMT-exocortex-template/                    ~/Github/ (твоё рабочее пространство)
│                                           │
├── CLAUDE.md            ──── копия ────→   ├── CLAUDE.md
├── memory/*.md          ──── копия ────→   ├── ~/.claude/projects/.../memory/
│   └── MEMORY.md (скелет)                  │   └── MEMORY.md (★ твой, пустой)
│                                           │
├── roles/strategist/   ── install.sh ──→  ├── ~/Library/LaunchAgents/ (расписание)
│                                           │
├── seed/strategy/       ── создаёт репо ─→ ├── DS-strategy/ (★ отдельный приватный репо)
│                                           │
└── (остаётся как fork)                     ├── FMT-exocortex-template/ (НЕ трогать)
                                            ├── PACK-{область}/ (когда создашь)
                                            └── DS-{проекты}/ (когда создашь)
```

> **Ключевое:** `seed/strategy/` — заготовка. При setup она становится **отдельным приватным репозиторием** `DS-strategy/` на GitHub. После setup связь с seed/ разрывается — DS-strategy живёт своей жизнью.

### Что даёт платформа (Standard)

Через шаблон и обновления ты получаешь готовую методологию:

| Компонент | Что это | Как обновляется |
|-----------|---------|-----------------|
| **Протоколы** | Open → Work → Close: как начинать, вести и закрывать сессию | `update.sh` |
| **Память** | 9 файлов: различения, SOTA, чеклисты, навигация | `update.sh` |
| **Стратег** | 7 сценариев: утренний план, недельный обзор, стратегирование | `update.sh` |
| **Инструменты** | WakaTime hook, Claude Code skills | `update.sh` |
| **CLAUDE.md** | Правила для Claude Code: архитектура, процессы, gates | `update.sh` |

### Что накапливается у тебя (Personal)

Твои данные живут отдельно и **никогда не затрагиваются обновлениями**:

| Данные | Где живут | Как растут |
|--------|-----------|-----------|
| **Планы** | `DS-strategy/current/` | Стратег создаёт WeekPlan и DayPlan |
| **Контексты задач** | `DS-strategy/inbox/WP-*.md` | Claude фиксирует прогресс по задачам |
| **Стратегия** | `DS-strategy/docs/Strategy.md` | Обновляется на стратегических сессиях |
| **Задачи недели** | `MEMORY.md` | Claude обновляет таблицу РП каждую сессию |
| **Знания** | `PACK-{область}/` | Экстрактор формализует captures в Pack-сущности |
| **Проекты** | `DS-{проекты}/` | Ты создаёшь по мере роста |

### Как работают обновления

```
Платформа (upstream)                     Ты (downstream)

FMT-exocortex-template ──── update.sh ──→ Твой fork (git merge)
(автор обновляет)              │
                               ├──→ CLAUDE.md       → ~/Github/CLAUDE.md
                               ├──→ memory/*.md     → ~/.claude/projects/.../
                               │    (MEMORY.md НЕ трогается!)
                               └──→ roles/prompts/ → остаются в fork

DS-strategy/     ← НЕ затрагивается (отдельный репо)
PACK-{область}/  ← НЕ затрагивается (твой репо)
MEMORY.md        ← НЕ затрагивается (твои данные)
```

---

## Создание первого Pack

Когда ты определишь область знаний, которую хочешь формализовать — создай свой первый Pack.

### Когда создавать

- Ты регулярно работаешь в одной области (управление проектами, ML, продуктовый дизайн...)
- Тебе важно не терять знания между сессиями
- Ты хочешь, чтобы Claude знал термины и паттерны твоей области

### Как создать

```bash
# 1. Клонируй SPF (структура Pack, read-only reference)
gh repo clone TserenTserenov/SPF ~/Github/SPF

# 2. Создай Pack из шаблона
cp -r ~/Github/SPF/pack-template ~/Github/PACK-my-domain
cd ~/Github/PACK-my-domain
git init && git add -A && git commit -m "Initial Pack: my-domain"
gh repo create PACK-my-domain --private --source=. --push
```

Затем откройте Claude Code в этом репо — он прочитает шаблон и поможет заполнить:
- `00-pack-manifest.md` — метаданные области
- `01-domain-contract/` — границы, различения, онтология
- `02-domain-entities/` — роли, объекты, методы

### Опциональные компоненты

| Компонент | Когда добавлять | Что даёт |
|-----------|----------------|----------|
| **Экстрактор** | Создал первый Pack (10+ сущностей) | Автоматическое извлечение знаний из сессий в Pack |
| **Синхронизатор** | Появилось 3+ репозитория | Кросс-репо синхронизация, code-scan, автоматические проекции |

Принцип: минимальная сложность на старте, усложнение по мере роста.

---

## Путь на платформе

Платформа растёт вместе с тобой. Каждый тир разблокирует новую функциональность.

```
T1: Старт  →  T2: Изучение  →  T3: Персонализация  →  T4: Созидание (IWE)  →  T5: Администрирование
Бесплатно      БР                БР+                     БР++                    Владелец
```

| | T1: Старт | T2: Изучение | T3: Персонализация | T4: Созидание | T5: Администрирование |
|---|---|---|---|---|---|
| **Вход** | /start в боте (5 мин) | Подписка на программу | Заполнить Digital Twin (20 мин) | setup.sh (10 мин) | Владелец платформы |
| **ИИ-роль** | Ассистент | Эксперт | Наставник | Со-мыслитель | Архитектор |
| **Бот** | Марафон, Лента | + Руководства, Программы | + Персональные ответы | Всё из T3 + Claude Code | Всё из T4 |
| **Рабочее пространство** | Только бот | Бот + контент | + Digital Twin | + Git + Claude Code + Стратег + WakaTime | + исходный код + деплой |
| **Знания** | Поиск по базе | + полный доступ к гайдам | + персонализация | + свои Pack и DS | + управление standard/ |

---

## Репозитории пользователя

После установки и по мере роста у тебя появятся следующие репозитории:

### Создаются автоматически (setup.sh)

| Репо | Тип | Что это | Откуда |
|------|-----|---------|--------|
| **FMT-exocortex-template/** | Format | Твой форк шаблона экзокортекса (источник обновлений, CLAUDE.md, memory/, Стратег) | Fork от [FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template) |
| **DS-strategy/** | Downstream/governance | Стратегический хаб: WeekPlan, DayPlan, inbox, стратегия, неудовлетворённости | Создаётся setup.sh из шаблона `seed/strategy/` |

### Создаёшь сам (когда готов)

| Репо | Тип | Когда создавать | Как |
|------|-----|----------------|-----|
| **PACK-{твоя-область}/** | Pack | Определил область знаний, которую хочешь формализовать | Из шаблона [SPF/pack-template](https://github.com/TserenTserenov/SPF) |
| **DS-{твой-проект}/** | Downstream/instrument | Начал строить систему на основе Pack | `gh repo create DS-my-project --private` |

### Клонируешь при необходимости (read-only reference)

| Репо | Тип | Когда нужен | Ссылка |
|------|-----|-------------|--------|
| **SPF/** | Framework | Создаёшь первый Pack (нужен pack-template/) | [SPF](https://github.com/TserenTserenov/SPF) |
| **FPF/** | Framework | Нужны первые принципы (редко, для углублённого изучения) | [FPF](https://github.com/TserenTserenov/FPF) |
| **ZP/** | Foundation | Нулевые принципы (6 универсальных ограничений) | [ZP](https://github.com/TserenTserenov/ZP) |
| **PACK-digital-platform/** | Pack | Живой пример Pack (40+ сущностей: роли, тиры, архитектура) | [PACK-digital-platform](https://github.com/TserenTserenov/PACK-digital-platform) |
| **FMT-s2r/** | Format | Фреймворк для третьих принципов (S2R = System-to-Role) | [FMT-s2r](https://github.com/TserenTserenov/FMT-s2r) |
| **DS-Knowledge-Index-{user}/** | Downstream/surface | Пример surface downstream: блог, посты, материалы | Создаётся пользователем |

### Опциональные агенты (по мере роста)

| Репо | Агент | Когда добавлять | Ссылка |
|------|-------|----------------|--------|
| **DS-ai-systems/extractor/** | Экстрактор знаний | Первый Pack создан, 10+ сущностей. Автоматическое извлечение знаний из сессий | [DS-ai-systems/extractor](https://github.com/TserenTserenov/DS-ai-systems/tree/main/extractor) |
| **DS-ai-systems/synchronizer/** | Синхронизатор | 3+ репозитория. Кросс-репо синхронизация, code-scan, автоматические проекции | [DS-ai-systems/synchronizer](https://github.com/TserenTserenov/DS-ai-systems/tree/main/synchronizer) |

> **Принцип:** Начни с минимума (2 репо: FMT-exocortex-template + DS-strategy). Добавляй по мере роста. Не клонируй всё сразу.

---

## Структура

```
FMT-exocortex-template/
│
├── CLAUDE.md                        # Правила для Claude Code (протоколы, архитектура)
├── README.md                        # Быстрый старт (этот файл)
├── REPO-TYPE.md                     # Тип репозитория (Format)
├── ONTOLOGY.md                      # Онтология экзокортекса
├── update.sh                        # Обновление из upstream
│
├── memory/                          # Оперативная память (≤10 файлов, ≤100 строк каждый)
│   ├── MEMORY.md                    # ★ PERSONAL: задачи недели, навигация (авто-загрузка)
│   ├── protocol-open.md             # Протокол открытия сессии
│   ├── protocol-work.md             # Протокол работы
│   ├── protocol-close.md            # Протокол закрытия сессии
│   ├── navigation.md                # Навигация по репозиториям
│   ├── hard-distinctions.md         # Жёсткие различения
│   ├── fpf-reference.md             # Первые принципы (FPF)
│   ├── checklists.md                # Чеклисты
│   ├── sota-reference.md            # SOTA-практики
│   └── repo-type-rules.md           # Правила по типам репозиториев
│
├── docs/                            # Справочная документация
│   ├── SETUP-GUIDE.md               # Пошаговое руководство установки (от нуля)
│   ├── IWE-HELP.md                  # Справочник IWE для бота (FAQ, глоссарий)
│   └── LEARNING-PATH.md             # Путь изучения: принципы, протоколы, SOTA
│
├── roles/                          # Роли (точка расширения)
│   ├── strategist/                  # Роль: Стратег (R1)
│   │   ├── install.sh               # Установка launchd/cron
│   │   ├── prompts/                 # 9 сценариев (day-plan, week-review...)
│   │   └── scripts/                 # Скрипты запуска + launchd plist
│   ├── extractor/                   # Роль: Экстрактор знаний (R2)
│   │   ├── install.sh               # Установка launchd для inbox-check
│   │   ├── prompts/                 # 4 сценария (session-close, on-demand, inbox-check, audit)
│   │   ├── scripts/                 # Скрипт запуска + launchd plist
│   │   └── config/                  # routing.md, feedback-log.md
│   └── synchronizer/                # Роль: Синхронизатор (R8)
│       ├── install.sh               # Установка центрального scheduler (launchd)
│       ├── scripts/                 # scheduler, notify, code-scan, daily-report, sync-files
│       │   └── templates/           # Шаблоны уведомлений по агентам
│       └── config.yaml              # Расписание (reference)
│
├── seed/                            # Шаблоны → отдельные репо после setup
│   └── strategy/                    # → DS-strategy/ (стратегический хаб)
│       ├── current/                 # Текущие планы и отчёты
│       ├── archive/                 # Архив
│       ├── inbox/                   # Входящие заметки
│       ├── docs/                    # Стратегия, неудовлетворённости
│       └── exocortex/              # Backup memory + CLAUDE.md
│
└── .claude/                         # Конфигурация Claude Code
    ├── hooks/wakatime-heartbeat.sh  # WakaTime heartbeat для Claude Code
    └── skills/setup-wakatime.md     # /setup-wakatime (автонастройка WakaTime)
```

### Зоны

| Зона | Что | update.sh | Пользователь |
|------|-----|-----------|-------------|
| **PLATFORM** | `memory/*.md` (кроме MEMORY.md), `roles/`, `docs/`, `.claude/` | Обновляет | Не трогает |
| **PERSONAL** | `memory/MEMORY.md` | Не трогает | Редактирует каждую сессию |
| **SEED** | `seed/strategy/` | N/A | После setup → отдельный репо DS-strategy/ |
| **ROOT** | `CLAUDE.md`, `README.md`, `ONTOLOGY.md` | CLAUDE.md обновляет | Читает |

> **Правило:** Platform-space обновляется из upstream (`update.sh`). User-space (MEMORY.md, DS-strategy/) — никогда.

---

## Принципы

1. **Standard vs Personal** — протоколы и промпты (standard) обновляются из upstream. Твои планы, память и стратегия (personal) — только у тебя
2. **3-слойная память** — MEMORY.md (всегда в контексте, ≤100 строк) → CLAUDE.md (правила, ≤300 строк) → memory/*.md (справочники, по запросу)
3. **Capture-to-Pack** — знания фиксируются по ходу работы, не теряются
4. **WP Gate** — нетривиальная работа начинается с проверки плана. Нет в плане = не делаем
5. **Open → Work → Close** — каждая сессия: открытие (что делаем) → работа (с фиксацией знаний) → закрытие (результат зафиксирован)
6. **Безопасность по дизайну** — секреты вне git, per-user изоляция, приватные репозитории, CLI permission whitelist. Подробнее: [LEARNING-PATH.md § 8.5](docs/LEARNING-PATH.md)

> Подробное описание каждого принципа, протокола и агента — в [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## FAQ

**Q: Нужна ли подписка Anthropic?**
A: Да. Рекомендуется начать с **Claude Pro** ($20/мес). Если получите значительный эффект от работы с Claude Code и упрётесь в лимиты — переходите на **Claude Max** (~$100/мес) для работы без ограничений. Стратег использует Claude Code для генерации планов.

**Q: Работает ли на Linux/Windows?**
A: Да. Ядро (CLAUDE.md + memory/ + Claude Code) работает на любой ОС. Автоматизация Стратега: macOS — launchd (автоматически), Linux — cron (настроить вручную), Windows — через WSL + cron. Без автоматизации Стратег запускается вручную.

**Q: Что если я не хочу Стратега?**
A: Можно не устанавливать launchd-агентов. CLAUDE.md и memory/ будут работать и без них — просто не будет автоматических планов.

**Q: Как связан бот (@aist_me_bot) и экзокортекс?**
A: Бот работает на тирах T1-T3 (без git). Экзокортекс (этот шаблон) — для T4+. Они используют одну базу знаний, но экзокортекс даёт больше: Claude Code, Стратег, свои Pack.

**Q: Что такое Pack?**
A: Pack — это формализованная область знаний (паспорт предметной области). Например, PACK-product-management или PACK-machine-learning. Pack — единственный source-of-truth для доменного знания.

**Q: Безопасны ли мои данные?**
A: Три зоны защиты: (1) **Локальная** — CLAUDE.md и memory/ на вашем компьютере, защищены на уровне ОС; (2) **GitHub** — DS-strategy и Pack — приватные репозитории на вашем аккаунте; (3) **Платформа** — per-user OAuth, изоляция данных пользователей. Anthropic API [не использует данные для обучения](https://www.anthropic.com/policies/privacy-policy). Секреты (API-ключи, токены) хранятся в `~/.config/`, не в git. Подробнее: [LEARNING-PATH.md § 8.5](docs/LEARNING-PATH.md#85-безопасность-в-iwe).

**Q: Claude видит мои пароли и API-ключи?**
A: Нет. Claude Code видит только файлы в рабочей директории и исполняет только команды из whitelist (`.claude/settings.local.json`). Секреты хранятся в `~/.config/` и environment variables — за пределами рабочего пространства.

---

## Лицензия

MIT
