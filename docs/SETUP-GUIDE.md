# Установка IWE: пошаговое руководство

> Это руководство проведёт тебя от чистого компьютера до работающего IWE за 30-60 минут.
> Подходит для macOS. Linux и Windows (WSL) — см. примечания в каждом шаге.
> Не уверен, что нужно менять под твою платформу? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** `DP.IWE.002` (Pack). При расхождении с этим файлом — приоритет у Pack.
> Через Aisystant MCP: `knowledge_search("установка IWE шаблон")`.
>
> **Нужна короткая версия?** → [QUICK-START.md](QUICK-START.md) (15 минут, если Git, Node.js и CLI уже установлены). Здесь - полная установка с нуля.

## Где ты сейчас и куда идёшь

Платформа открывает доступ по уровням (тирам, `DP.ARCH.002`): от T0 (без аккаунта) до T4 (Созидание, IWE). Возможно, ты уже пользуешься ботом — это T1-T3. Это руководство переводит тебя на **T4**, где появляется персональное рабочее пространство с ИИ-агентами.

| Тир | Что есть | Как попасть |
|-----|---------|-------------|
| **T1: Старт** | Бот @aist_me_bot: поиск по базе знаний, марафоны | `/start` в Telegram |
| **T2: Изучение** | + Программы, руководства, расписание | Подписка на программу |
| **T3: Персонализация** | + Персональные ответы, цифровой двойник | `/twin` в боте |
| **T4: Созидание (IWE)** | + Claude Code, Стратег, Git, свои базы знаний | **Это руководство** |

> Всё, что ты накопил на T1-T3 (Digital Twin, профиль, прогресс) — сохраняется. T4 добавляет новые возможности, не заменяет старые.

## Что ты получишь в итоге

- **Claude Code** — ИИ-помощник, который знает твои цели, задачи и методологию. Помнит контекст между сессиями
- **Стратег** (ИИ-агент) — каждое утро готовит план дня, по воскресеньям — итоги недели
- **Экстрактор** (ИИ-агент, позже) — извлекает знания из сессий в базу знаний
- **Синхронизатор** (позже) — расписание агентов, уведомления в Telegram
- **DS-strategy** — твой личный стратегический хаб (приватный репозиторий на GitHub)
- **Заметки через Telegram** — пишешь мысль в бот, она попадает в систему планирования

### Карта этапов

| Этап | Что | Время | При первой установке |
|------|-----|-------|---------------------|
| **0** | Подготовка (Git, Node, Claude Code) | 15-20 мин | **обязательно** |
| **1** | Установка IWE | ~5 мин | **обязательно** |
| **2** | Первая стратегическая сессия | ~30 мин | **обязательно** |
| **3** | Заметки через Telegram | 5 мин | можно позже |
| **4** | WakaTime (трекинг времени) | 10 мин | можно позже |
| **5** | Google Calendar | 10 мин | можно позже |
| **6** | Видеоинтеграция | 5 мин | можно позже |
| **7** | Agent Workspace (данные агентов) | 10 мин | когда >2 агента |

> **Минимум для старта:** Этапы 0 → 1 → 2. Всё остальное подключается в любой момент — скажи Claude *«настрой календарь»* или *«подключи видеозаписи»*.
>
> **Kimi как второй агент:** если хочешь работать в IWE не только с Claude, но и с Kimi Code — подключение описано в [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## Как открыть терминал

Все команды в этом руководстве выполняются в **терминале** — это программа, куда ты вводишь текстовые команды.

**macOS:**
- Нажми `Cmd + Пробел` (Spotlight) → набери `Terminal` → нажми Enter
- Или: Finder → Программы → Утилиты → Терминал

**Windows:**
- Сначала установи [WSL](https://learn.microsoft.com/ru-ru/windows/wsl/install) (Windows Subsystem for Linux)
- Потом открой: Пуск → набери `Ubuntu` → нажми Enter

**Linux:**
- `Ctrl + Alt + T` (в большинстве дистрибутивов)

> В терминале ты увидишь строку вроде `username@computer:~$` — это приглашение к вводу. Просто набирай команду и нажимай Enter.

## Этап 0: Подготовка (15-20 мин)

Если у тебя уже установлены Git, Node.js, GitHub CLI и Claude Code CLI — переходи к [Этапу 1](#этап-1-установка-iwe-5-мин).

### 0.1 Homebrew (только macOS)

Homebrew — менеджер пакетов для macOS. Он нужен, чтобы устанавливать остальные инструменты одной командой. Если уже есть — пропусти.

В терминале:
```bash
# Проверить, есть ли Homebrew
brew --version

# Установить (если нет)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

После установки Homebrew может попросить выполнить команду для PATH — скопируй и выполни её.

### 0.2 Git

Git — система контроля версий. Она хранит историю изменений файлов и позволяет синхронизировать работу через GitHub.

В терминале:
```bash
# Проверить
git --version

# Установить
# macOS:
xcode-select --install
# Linux:
# sudo apt install git
```

### 0.3 Node.js и npm

Node.js — среда выполнения JavaScript. Нужна для установки Claude Code CLI. npm — менеджер пакетов Node.js (устанавливается вместе с Node.js).

В терминале:
```bash
# Проверить
node --version    # должен быть v18+
npm --version

# Установить
# macOS:
brew install node
# Linux:
# curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs
```

### 0.4 GitHub CLI и аккаунт

GitHub CLI (`gh`) — инструмент для работы с GitHub из терминала. Через него установщик создаёт репозитории и копирует шаблон.

**GitHub аккаунт:** если нет — зарегистрируйся на [github.com](https://github.com/signup).

В терминале:
```bash
# Проверить
gh --version

# Установить
# macOS:
brew install gh
# Linux:
# https://cli.github.com/ — инструкция по установке
```

Теперь нужно авторизоваться в GitHub (один раз):
```bash
gh auth login
# Выбери: GitHub.com → HTTPS → Login with a web browser
# Откроется браузер → войди в свой аккаунт GitHub
```

Проверка:
```bash
gh auth status
# Должно показать: ✓ Logged in to github.com as <username>
```

### 0.5 Claude Code CLI

Claude Code — это ИИ-агент, работающий в терминале (или в VS Code). Он читает файлы, выполняет команды, помогает планировать и писать код.

Требует подписку Anthropic. Рекомендуется начать с **Claude Pro** ($20/мес). При необходимости — **Claude Max** (~$100/мес) для работы без ограничений.

В терминале:
```bash
# Установить
npm install -g @anthropic-ai/claude-code

# Проверить
claude --version
```

При первом запуске Claude Code попросит войти в аккаунт Anthropic — следуй инструкциям в терминале.

### 0.5b Оптимизация стоимости: выбор модели

Claude Code позволяет выбирать модель для каждой задачи. Правильный выбор экономит лимит подписки:

| Модель | Класс верификации | Когда использовать | Стоимость |
|--------|-------------------|-------------------|-----------|
| **Opus** | open-loop, problem-framing | Архитектура, сложный код, стратегия, multi-system изменения | Высокая |
| **Sonnet** | closed-loop | Типовые задачи, одно-файловые правки, написание контента | Средняя |
| **Haiku** | trivial | Переименование, обновление ссылок, форматирование, поиск файла, cron-агенты | Низкая |

Переключить модель в Claude Code: `/model` → выбрать. Для автоматических задач (Стратег, Экстрактор) рекомендуется Haiku — экономит ~80% лимита по сравнению с Opus.

> **Как это работает — два сценария:**
> - **Вся сессия на другой модели:** При открытии Claude определяет класс верификации. Если задача trivial/closed-loop и текущая модель избыточна, Claude скажет: *«Рекомендую переключиться на [Haiku/Sonnet] через `/model`. Переключить автоматически я не могу.»* Пользователь переключает сам.
> - **Отдельная задача внутри сессии:** Если посреди сессии появилась trivial-задача, Claude делегирует её sub-agent'у на дешёвой модели. Основная сессия не прерывается. Делегирование только вниз (Opus→Sonnet/Haiku, Sonnet→Haiku). Переключение вверх — только через `/model`.
>
> **Совет:** На подписке Claude Pro ($20/мес) активно используйте Haiku для рутины (утренние планы, поиск по файлам, тривиальные правки). Opus — только для архитектурных решений и сложного кода.

### 0.6 VS Code (рекомендуется)

VS Code — редактор кода с графическим интерфейсом. В нём удобно работать с Claude Code: видишь все свои репо, файлы, терминал и ИИ-ассистента в одном окне и можешь в одной сессии менять репо разных проектов. **Без VS Code** придётся работать только через терминал — это возможно, но менее наглядно.

- Скачай и установи: [code.visualstudio.com](https://code.visualstudio.com/)
- Открой VS Code → нажми `Cmd+Shift+X` (macOS) или `Ctrl+Shift+X` (Windows/Linux) → найди «Claude Code» → нажми Install

## Этап 1: Установка IWE (~5 мин)

### 1.1 Создай рабочую папку

Создай на своём компьютере **одну папку** для всех репозиториев — текущих и будущих. В неё будут клонироваться все репозитории: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{область}/`, `DS-{проекты}/` и др. `CLAUDE.md` тоже будет лежать в корне этой папки. По умолчанию это `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Важно:** Название может быть любым, но все репо должны быть в одном месте — Claude Code ориентируется на эту структуру. Рекомендуем `~/IWE`.

### 1.2 Форкни шаблон и запусти установку

В терминале:

```bash
# Убедиться, что мы в рабочей папке
cd ~/IWE

# Форкнуть шаблон на свой GitHub и склонировать
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template

# Запустить установку
bash setup.sh
```

> **Посмотреть без выполнения:** `bash setup.sh --dry-run`

Скрипт спросит:

| Вопрос | Что ввести | Пример |
|--------|-----------|--------|
| GitHub username | Твой логин на GitHub | `ivan-petrov` |
| Workspace directory | Рабочая папка | Просто нажми Enter (определяется автоматически) |
| Claude CLI path | Путь к claude | Просто нажми Enter (определяется автоматически) |
| Strategist launch hour (UTC) | Час запуска Стратега | `4` (= 7:00 MSK, 8:00 Алматы) |
| Timezone description | Описание времени | `7:00 MSK` |

Скрипт выполнит 6 шагов:
1. Подставит твои данные во все файлы (имя, пути, часовой пояс)
2. Установит `CLAUDE.md` — правила для Claude Code
3. Установит `memory/` — оперативную память для Claude Code
4. Настроит разрешения (`.claude/settings.local.json`) и выведет инструкцию по подключению MCP
5. Установит автоматический запуск Стратега (launchd на macOS)
6. Создаст `DS-strategy/` — твой приватный стратегический репозиторий на GitHub

### 1.3 Проверь установку

В терминале:
```bash
# Должен существовать
ls ~/IWE/CLAUDE.md

# Должны быть файлы памяти (10+)
ls ~/.claude/projects/*/memory/

# Должен быть стратегический хаб
ls ~/IWE/DS-strategy/

# Стратег должен быть в расписании (macOS)
launchctl list | grep strategist
```

Если всё есть — проверь MCP-подключение (1.3b) и переходи к Этапу 2. Дополнительные роли (1.4) можно установить позже.

### 1.3b Подключи MCP-серверы

MCP (Model Context Protocol) -- это доступ Claude Code к базе знаний платформы и твоим личным репозиториям. Через него Claude видит документы, руководства, цифровой двойник и твои собственные Pack-репо — предметные базы знаний, которые ты создаёшь со временем.

> **Зачем:** Документация и Pack-сущности (DP.IWE.001, DP.ARCH.001 и др.) ссылаются на source-of-truth в PACK-digital-platform. После подключения MCP Claude сможет находить эти сущности по запросу и работать с твоими личными репо напрямую. Без MCP -- сущности доступны только как файлы на GitHub.

**Подключение:**

1. Открой https://claude.ai/settings/connectors
2. Добавь MCP-сервер (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Перезапусти Claude Code

**Как работает:** Claude Code подключается к Aisystant MCP через claude.ai connectors. Сервер агрегирует все бэкенды (knowledge, digital-twin) и предоставляет инструменты (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin` и др.).

#### Проверка

Открой Claude Code в папке экзокортекса и набери `/mcp` -- серверы должны быть в статусе Connected. Затем попроси:
> Найди документы про принципы

Claude должен использовать `knowledge_search("принципы")` и вернуть список документов из базы знаний.

**Диагностика:**

```bash
# Проверить всю установку (env, файлы, extensions, MCP-доступность)
bash FMT-exocortex-template/setup.sh --validate
```

| Проблема | Решение |
|----------|---------|
| `/mcp` -- серверов нет | Повтори шаги 1-3 (claude.ai connectors) |
| Открыл URL в браузере -- "Not found" | Нормально. MCP работает по POST (JSON-RPC), не по GET. Проверяй через `/mcp` в Claude Code |
| Aisystant MCP -- connection error | Проверь интернет-соединение |
| `--validate` показывает ошибки | Следуй подсказкам. Недостающие ключи -- заполни в `.exocortex.env` |

> **Подсказка:** `setup.sh --validate` проверяет ВСЕ категории сразу: env-конфиг, обязательные файлы, extensions, MCP-доступность.

### 1.4 Установка дополнительных ролей (позже)

Setup.sh устанавливает только Стратега. Экстрактор и Синхронизатор ставятся отдельно, когда освоишь базовый цикл:

В терминале:
```bash
cd ~/IWE/FMT-exocortex-template

# Экстрактор — извлечение знаний из сессий, проверка inbox (каждые 3 часа)
bash roles/extractor/install.sh

# Синхронизатор — центральный scheduler: расписание агентов, уведомления, code-scan
bash roles/synchronizer/install.sh
```

> **Рекомендация:** Экстрактор и Синхронизатор можно установить позже, когда освоишь базовый цикл со Стратегом. Подробнее: [roles/extractor/README.md](../roles/extractor/README.md) и [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Важно:** Если устанавливаешь Синхронизатор, он заменяет отдельные launchd-агенты Стратега единым scheduler. Все роли будут запускаться по расписанию из одной точки.

## Что-то не работает?

**`CLAUDE.md` не найден:**
```bash
cp ~/IWE/FMT-exocortex-template/CLAUDE.md ~/IWE/CLAUDE.md
```

**Memory не найдена:**
```bash
# Определи slug
echo $HOME/IWE | tr '/' '-'
# Пример результата: -Users-ivan-IWE

# Создай директорию и скопируй
mkdir -p ~/.claude/projects/-Users-ivan-IWE/memory
cp ~/IWE/FMT-exocortex-template/memory/*.md ~/.claude/projects/-Users-ivan-IWE/memory/
```

**launchd не загружен:**
```bash
cd ~/IWE/FMT-exocortex-template/roles/strategist
bash install.sh
```

**DS-strategy не создан:**
```bash
cd ~/IWE
mkdir -p DS-strategy/{current,inbox,docs,archive/wp-contexts,exocortex}
cd DS-strategy && git init && git add -A && git commit -m "Initial"
gh repo create $(gh api user -q .login)/DS-strategy --private --source=. --push
```

## Восстановление на новом устройстве (из exocortex-бэкапа)

Если IWE уже настроен на одном устройстве, на новом **не нужно** инициализировать память с нуля. `day-close.sh --backup` и хук `memory-exocortex-sync.sh` держат зеркало памяти в `DS-strategy/exocortex/`, и оно уезжает на GitHub вместе с governance-репо. `restore-from-exocortex.sh` разворачивает его обратно.

**Шаги на новом устройстве:**

```bash
# 1. Этап 0 (бинарники, gh auth, claude CLI) — как обычно
# 2. Рабочая папка + клонировать шаблон и governance-репо (он несёт exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
git clone https://github.com/<твой-логин>/DS-strategy.git

# 3. Восстановить память из бэкапа (вместо инициализации с нуля)
bash ~/IWE/FMT-exocortex-template/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — превью без изменений
#    --force    — перезаписать уже населённую memory/

# 4. Перезапустить Claude Code → память на месте
```

Скрипт: копирует `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, создаёт симлинк `~/IWE/memory → auto-memory`. Непустую `memory/` без `--force` не трогает (защита от случайной перезаписи рабочей инсталляции).

## Этап 2: Первая стратегическая сессия (~30 мин)

Это самый важный шаг — ты настроишь свои цели и первый план.

**Вариант А — через VS Code (рекомендуется):**
1. Открой VS Code
2. `File → Open Folder` → выбери папку `~/IWE`
3. Открой панель Claude Code: `Cmd+Shift+P` (macOS) или `Ctrl+Shift+P` (Windows) → набери «Claude Code: Open» → Enter

**Вариант Б — через терминал:**
```bash
cd ~/IWE
claude
```

Скажи Claude:

> **«Проведём первую стратегическую сессию»**

Claude прочитает CLAUDE.md и memory/ и проведёт тебя через:

1. **Определение целей** — Кем ты хочешь быть через год? Чему научиться?
2. **Неудовлетворённости** — Что мешает? Где разрыв между текущим и желаемым?
3. **Первый WeekPlan** — Конкретные задачи на неделю с бюджетами
4. **Регистрация в WP-REGISTRY.md и WeekPlan** — рабочие продукты из сессии появятся в реестре и плане

**Результат:** заполненные `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md` и первый `WeekPlan` в `DS-strategy/current/`.

## Этап 3: Настройка заметок через Telegram (5 мин, опционально)

Чтобы отправлять мысли в систему планирования прямо из Telegram:

1. Найди бота **@aist_me_bot** в Telegram
2. Нажми `/start`
3. Оформи подписку (если ещё нет)

**Как отправлять заметки:**
- Напиши: `.Моя мысль про архитектуру` (точка + текст)
- Или перешли/ответь на любое сообщение с `.`

Заметка попадёт в `DS-strategy/inbox/fleeting-notes.md`. Стратег разберёт её вечером (Note-Review, 23:00) и классифицирует: задача → план, знание → captures, идея → на обсуждение.

## Этап 4: WakaTime — трекинг времени (10 мин, опционально)

WakaTime трекает время работы автоматически: по проектам, языкам, категориям.

В VS Code или терминале запусти Claude Code и скажи:

> **/setup-wakatime**

Claude проведёт через установку:
1. wakatime-cli
2. API-ключ (получи на [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Хуки для Claude Code
4. Desktop App (опционально)

После настройки: данные WakaTime автоматически включаются в утренний план дня и недельный отчёт.

> **Privacy:** WakaTime — SaaS-сервис (wakatime.com, серверы AWS, США). На сервер отправляются **метаданные** работы: имена проектов, имена файлов, языки, ветки, время активности. Содержимое файлов **НЕ** отправляется. CLI — open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). Desktop App — closed source, запрашивает Accessibility permission (видит активные окна). Если метаданные критичны — используй self-hosted альтернативу [Wakapi](https://github.com/muety/wakapi) (wakatime-cli поддерживает кастомный `api_url` в `~/.wakatime.cfg`).

## Этап 5: Google Calendar — события дня в Day Open (10 мин, опционально)

Подключение Google Calendar позволяет видеть события дня прямо в утреннем плане, создавать события из Claude Code и готовиться к встречам.

### Что получишь

- **Day Open** покажет таблицу событий дня + свободные слоты для работы
- **Создание событий** — «поставь созвон на среду 11:00» прямо из Claude Code
- **Подготовка к встрече** — Claude подтянет контекст из связанных РП

### Настройка (~1 мин)

Из корня шаблона выполни одну команду:

```bash
bash setup/optional/setup-calendar.sh
```

Скрипт:
1. Запишет OAuth credentials (Shared App IWE) в `.secrets/`
2. Создаст `.mcp.json` с настройками Calendar MCP
3. Откроет браузер → залогинься через свой Google-аккаунт → нажми «Разрешить»
4. Перезапусти Claude Code → проверь: **«покажи мои события на сегодня»**

> **⚠ Google может показать «This app isn't verified».** Это нормально — нажми «Advanced» → «Go to IWE (unsafe)». После верификации приложения это предупреждение исчезнет.

### Несколько аккаунтов

Можно подключить несколько Google-аккаунтов (работа + личный):

```
Claude, подключи ещё один Google Calendar аккаунт
```

Каждый аккаунт получает nickname (`personal`, `work`) для адресации.

### Privacy

Данные календаря обрабатываются через Google Calendar API. OAuth-токены хранятся локально. Содержимое событий передаётся в Claude API для генерации плана дня. Конфиденциальные события (visibility=private) можно исключить из показа.

## Этап 6: Видеоинтеграция — связь записей с РП (5 мин, опционально)

Если ты записываешь встречи (Zoom, Телемост, Google Meet), Claude может сканировать папки с записями и привязывать видео к рабочим продуктам.

### Что получишь

- **Day Open** покажет новые видеозаписи с привязкой к РП
- **Strategy Session** — еженедельный обзор всех необработанных видео
- **Транскрипция** → автоматические captures и идеи для постов (опционально, требует whisper)

### Настройка

1. Открой `memory/day-rhythm-config.yaml`
2. В секции `video` укажи свои папки:

```yaml
video:
  enabled: true
  directories:
    - ~/Documents/Zoom
    - ~/Documents/Телемост
    # Добавь свои папки с видеозаписями
```

3. Проверь: **«покажи мои видеозаписи»** — Claude запустит `video-scan.sh`

### Где искать папки

| Приложение | Типичный путь (macOS) |
|------------|----------------------|
| Zoom | `~/Documents/Zoom` |
| Яндекс.Телемост | `~/Documents/Телемост` или `~/Видеозаписи Телемост` |
| Google Meet | Записи в Google Drive (не локально) |
| OBS | Настраивается в OBS → Settings → Output |

### Привязка к РП

Скрипт привязывает видео к РП по имени файла:
- `WP-73-...mp4` → привязка к WP-73
- `2026-03-14-...mp4` → привязка по дате (сопоставление с календарём)
- Остальные → предлагается привязать вручную

### Транскрипция (опционально)

Для автоматической транскрипции установи [whisper](https://github.com/openai/whisper):

```bash
pip install openai-whisper
```

Затем включи в конфиге:

```yaml
video:
  auto_transcribe:
    enabled: true
```

## Этап 7: Agent Workspace — отдельное хранилище данных агентов (10 мин, опционально)

### Прочитай перед решением

Это **осознанный выбор**, а не обязательный шаг. Два вопроса помогут решить:

**1. У тебя есть автономные агенты?**

Если ты только начал работу с IWE и используешь только Claude Code в интерактивном режиме — **тебе это НЕ нужно**. Все отчёты планировщика будут храниться в `DS-strategy/current/` и `DS-strategy/archive/` — этого достаточно.

**2. Агенты генерируют >10 файлов в неделю?**

Когда Scheduler, Scout, Extractor и другие агенты работают ежедневно, они создают десятки файлов: отчёты планировщика, QA-отчёты бота, находки, черновики планов. Эти автокоммиты засоряют git history DS-strategy, где должны быть только **человеческие решения** (планы, утверждённые captures).

### Что даёт Agent Workspace

| Без Agent Workspace | С Agent Workspace |
|---------------------|------------------|
| Всё в DS-strategy | Машинный output отдельно |
| Git history перемешана | Чистая история решений |
| 1 репозиторий | 2 репозитория |
| Проще начать | Масштабируется |

### Настройка

```bash
bash setup/optional/setup-agent-workspace.sh
```

Скрипт создаст приватный GitHub-репо `DS-agent-workspace` со структурой для каждого типа агента. После создания скрипты планировщика (`daily-report.sh` и др.) автоматически начнут писать туда — проверка по наличию `DS-agent-workspace/.git`.

### Когда подключать

**Рекомендуемый путь:**
1. Начни без Agent Workspace (Этапы 0-2)
2. Подключи Scheduler (launchd) — отчёты пойдут в DS-strategy
3. Когда автокоммитов станет >5/день → создай Agent Workspace

## Автоматическое пробуждение и предотвращение сна

Агенты запускаются по расписанию. Если ноутбук спит — задачи ждут пробуждения. Настрой автоматический wake, чтобы план был готов до твоего пробуждения.

**macOS:**

```bash
# Пробуждение в 3:55 ежедневно (за 5 мин до Стратега)
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00

# ВАЖНО: если ноутбук на зарядке, Optimized Battery Charging может
# переключить профиль питания на «батарея». На батарейном профиле
# Mac засыпает даже при подключённом кабеле. Решение:
sudo pmset -b sleep 0      # не засыпать на батарейном профиле
sudo pmset -b standby 0    # не уходить в deep standby

# Проверить: pmset -g custom (sleep=0 в обоих профилях)
# Отменить wake: sudo pmset repeat cancel
# Вернуть sleep: sudo pmset -b sleep 1 && sudo pmset -b standby 1
```

> **Как это работает:** Mac просыпается в 3:55, scheduler запускается в 4:00, план готов к ~4:20. Скрипты автоматически держат Mac бодрым через `caffeinate -diu` (работает и на батарейном профиле).
>
> **Charge Limit (рекомендуется):** вместо Optimized Battery Charging включи фиксированный лимит (System Settings → Battery → Charge Limit → 80%). Защищает батарею без непредсказуемых переключений профиля.

**Linux:**

```bash
# Пробуждение через rtcwake (одноразовое, обычно в cron)
sudo rtcwake -m no -t $(date -d "tomorrow 03:55" +%s)

# Или systemd timer (постоянное расписание)
# /etc/systemd/system/exocortex-wake.timer
# [Timer]
# OnCalendar=*-*-* 03:55:00
# WakeSystem=true
# Persistent=true

# Предотвращение сна (скрипты делают это автоматически через systemd-inhibit)
# Ручная проверка: systemd-inhibit --list
```

**Windows (WSL):**

```powershell
# Пробуждение через Task Scheduler
schtasks /create /tn "ExocortexWake" /tr "wsl ~/IWE/scripts/scheduler.sh dispatch" /sc daily /st 04:00
# Предотвращение сна: powercfg /change standby-timeout-ac 0
```

> **Общее правило:** скрипты `strategist.sh` и `scheduler.sh` автоматически предотвращают сон на время работы (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). Настроить нужно только **пробуждение** и **запрет засыпания на уровне ОС** для ноутбуков.

## Что происходит дальше (автоматически)

После установки система работает сама:

| Время | Агент | Что происходит | Где результат |
|-------|-------|---------------|---------------|
| **Утро (Вт-Вс)** | Стратег | Собирает коммиты за вчера, формирует план дня | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Утро (Пн)** | Стратег | Готовит черновик недельного плана + повестку сессии | `DS-strategy/current/WeekPlan W{N}.md` |
| **Каждые 3 часа** | Экстрактор* | Проверяет inbox (заметки, captures) → предлагает знания в Pack | `DS-strategy/inbox/extraction-reports/` |
| **Вечер (23:00)** | Стратег | Note-Review классифицирует заметки из Telegram | Целевые документы в DS-strategy |
| **Ночь (00:00)** | Синхронизатор* | Code-scan — обзор изменений в downstream-репо | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Ночь (Вс→Пн)** | Стратег | Week Review — итоги недели | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Утро (06:00)** | Синхронизатор* | Daily report — сводка ночных задач | `DS-agent-workspace/scheduler/reports/` (или `DS-strategy/current/` если без Agent Workspace) |

> *Экстрактор и Синхронизатор работают только если установлены (Этап 1.4).*

### Ручной запуск (если нужно)

В терминале:
```bash
# План дня прямо сейчас
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan

# Сессия стратегирования (интерактивная)
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh strategy-session

# Обзор заметок
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh note-review

# Итоги недели
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh week-review

# Экстрактор: извлечь знания из текущей сессии (собранная runtime-копия, не сырой файл в FMT)
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close

# Экстрактор: проверить inbox
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Синхронизатор: статус всех задач
bash ~/IWE/FMT-exocortex-template/roles/synchronizer/scripts/scheduler.sh status
```

## Ежедневная работа: три стадии (ОРЗ)

Каждая сессия в Claude Code проходит три стадии:

### Открытие (автоматически)
Ты даёшь задание → Claude проверяет: есть ли такая задача в плане недели? Если нет — предлагает добавить (WP Gate). Объявляет роль, метод, оценку.

### Работа
Claude выполняет задачу. На каждом рубеже (подзадача, паттерн, решение) — фиксирует знания: *«Capture: [что] → [куда]»*.

### Закрытие
Скажи **«закрывай»** → Claude коммитит, пушит, обновляет память, делает backup.

## Обновления

Шаблон экзокортекса обновляется — новые протоколы, улучшенные промпты, скиллы, скрипты, исправления.

В терминале:
```bash
cd ~/IWE/FMT-exocortex-template
bash update.sh
```

Скрипт скачивает манифест обновлений с GitHub, сравнивает с вашими файлами, показывает превью (что нового, что изменилось) и применяет после вашего подтверждения. Self-update: `update.sh` обновляет сам себя при каждом запуске.

**Что обновляется (platform-space):**
CLAUDE.md (§1-7), memory/ (протоколы, справочники), промпты и скрипты ролей, hooks, скиллы, setup-скрипты. Если скрипты ролей изменились — автоматически переустановятся launchd-агенты.

**Что НЕ трогается (user-space):**
- CLAUDE.md — 3-way merge: ваши правки в любой секции сохраняются при обновлении
- extensions/ — ваши расширения протоколов
- params.yaml — ваши параметры протоколов
- MEMORY.md — ваша оперативная память (РП, уроки)
- DS-strategy/ — планы, стратегия, inbox
- .secrets/, .mcp.json — ключи и конфигурация интеграций
- .claude/settings.local.json — персональные permissions
- personal/ — ваши файлы

**Кастомизация протоколов:** создавайте файлы в `extensions/` — они подключаются в протоколы через extension points. Формат: `<protocol>.<hook>.md` (например `day-close.after.md`). Управляйте параметрами через `params.yaml`. Подробнее: [extensions/README.md](../extensions/README.md).

> Посмотреть доступные обновления без применения: `bash update.sh --check`

## Безопасность и приватность

> Полная политика данных: [DATA-POLICY.md](DATA-POLICY.md) | Каноническое описание: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

IWE работает преимущественно локально. Вот что нужно знать о безопасности.

### Что остаётся локально

| Компонент | Где хранится | Отправляется ли куда-то |
|-----------|-------------|------------------------|
| CLAUDE.md, memory/ | Локальные файлы | Нет (только в контекст Claude при работе) |
| DS-strategy | Приватный репо на GitHub | Только на GitHub (private) |
| Launch agents (Стратег и др.) | Локальные bash-скрипты | Нет |
| Git-репозитории | Локальные + GitHub | Только на GitHub |

### Что отправляется на внешние серверы

| Компонент | Куда | Какие данные |
|-----------|------|-------------|
| **Claude Code** | Anthropic API (США) | Промпты, содержимое файлов из контекста. [Privacy Policy](https://www.anthropic.com/privacy) |
| **WakaTime** (опц.) | wakatime.com (США) | Метаданные: имена проектов, файлов, языки, время. **НЕ** содержимое файлов |
| **Aisystant MCP** | Сервер платформы (mcp.aisystant.com) | Поисковые запросы. Данные пользователя не отправляются |
| **GitHub** | github.com (США) | Содержимое репозиториев |

### Рекомендации по безопасности Mac

Перед началом работы проверь:

1. **Firewall** — должен быть включён: `System Settings → Network → Firewall`
2. **FileVault** — шифрование диска: `System Settings → Privacy & Security → FileVault`
3. **SIP** (System Integrity Protection) — не отключай: `csrutil status` в Terminal
4. **.gitignore** — в каждом репо с кодом должен исключать `.env`, `*.key`, `*.pem`, `credentials.json`
5. **Secrets** — API-ключи хранить в `.env` (gitignored) или в менеджере паролей, **никогда** не в коде

### Что НЕ рекомендуется устанавливать

- Браузеры из юрисдикций с принудительным доступом к данным (проверяй Privacy Policy)
- Closed-source расширения с широким доступом к файловой системе
- Electron-приложения с неясной телеметрией — проверяй через `Little Snitch` или `LuLu` (open-source firewall)

### Self-hosted альтернативы

Если ты работаешь с чувствительными данными, рассмотри:

| SaaS | Self-hosted альтернатива |
|------|------------------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) — полный аналог, свой сервер |
| GitHub | [Gitea](https://gitea.io/) или [GitLab Self-Managed](https://about.gitlab.com/install/) |

## Часто задаваемые вопросы

**Нужна ли подписка Anthropic?**
Да, Claude Code требует подписку Anthropic. Рекомендуется начать с **Claude Pro** ($20/мес). При необходимости — **Claude Max** (~$100/мес).

**Подойдут ли Qwen, Perplexity, ChatGPT (чат) или другие чат-боты?**
Нет. Чат-боты и поисковые помощники (Qwen-чат, Perplexity, routerai.ru, обычный ChatGPT) **не подходят** — они не умеют читать/писать файлы на вашем компьютере и выполнять команды в терминале. Экзокортекс требует **агентного ИИ-ассистента** — такого, который работает с файловой системой, запускает команды и сохраняет контекст между сессиями.

**Какие альтернативы Claude Code?**

| Альтернатива | Что это | Цена | Модели |
|---|---|---|---|
| **Cursor** | IDE с ИИ (замена VS Code) | от $20/мес | Claude, GPT, свои |
| **GitHub Copilot** (Agent mode) | Расширение VS Code | от $10/мес | Claude, GPT |
| **Cline / Roo Code** | Расширение VS Code (open source) | Бесплатно + API-ключ | Любые (Claude, GPT, Gemini) |
| **Aider** | CLI-инструмент (open source) | Бесплатно + API-ключ | Любые |

> **Важно о модели:** Экзокортекс требует от модели сложного агентного поведения — следование многошаговым протоколам, работа с 5-10 файлами одновременно, надёжное редактирование. Рекомендуемые модели: **Claude Opus/Sonnet**, **GPT-4o/o1**, **Gemini 2.5 Pro**. Модели послабее (Qwen, Llama, Mistral) могут терять контекст и пропускать шаги протокола — для обычного кодинга они подходят, но для управления экзокортексом ненадёжны.

**Работает ли на Windows?**
Через WSL (Windows Subsystem for Linux) — да. [Установи WSL](https://learn.microsoft.com/ru-ru/windows/wsl/install), затем следуй инструкции для Linux. Launchd не работает в WSL — используй cron.

**Можно ли без Стратега?**
Да. Стратег — это автоматизация (утренние планы, ревью). Без него Claude Code + CLAUDE.md + memory/ работают полностью. Планируешь вручную.

**Что такое Pack?**
Pack — это предметная база знаний. Создаётся позже, когда накопишь достаточно captures. Первый шаг — работа с `captures.md` через Экстрактор.

**Как проверить MCP?**
`/mcp` в Claude Code -- серверы должны быть Connected. Попроси: «Найди документы про принципы». Не работает? Запусти `bash FMT-exocortex-template/setup.sh --validate` -- покажет что именно сломано. Подробности -- см. шаг 1.3b.

**Безопасны ли мои данные?**
DS-strategy — приватный репо. MEMORY.md — локальный файл. Ничего не публикуется без твоего ведома. Подробности о том, что отправляется на внешние серверы (Claude API, WakaTime, GitHub) — см. раздел [Безопасность и приватность](#безопасность-и-приватность).

**Как удалить?**
```bash
# Удалить launchd агенты
launchctl unload ~/Library/LaunchAgents/com.strategist.morning.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.strategist.weekreview.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.extractor.inbox-check.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.exocortex.scheduler.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.strategist.*.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.extractor.*.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.exocortex.*.plist 2>/dev/null

# Удалить файлы
rm ~/IWE/CLAUDE.md
rm -rf ~/.claude/projects/*/memory/
rm -rf ~/.local/state/exocortex/

# Репозитории (по желанию)
rm -rf ~/IWE/FMT-exocortex-template
rm -rf ~/IWE/DS-strategy
```

## Следующие шаги

| Когда | Что | Как |
|-------|-----|-----|
| После первой недели | Пройди сессию стратегирования (Пн) | Claude сам предложит |
| Через 2 недели | Создай первый Pack (личная база знаний) | `claude` → «Помоги создать мой первый Pack» |
| По мере роста | Настрой Экстрактор (автоматическое извлечение знаний) | См. [roles/extractor/README.md](../roles/extractor/README.md) |
| По желанию | Подключи Синхронизатор (уведомления в TG) | См. [roles/synchronizer/README.md](../roles/synchronizer/README.md) |

## Дополнительные материалы

**В этом репо:**

| Документ | Что содержит |
|----------|-------------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Полный путь изучения IWE: принципы, протоколы, агенты, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Краткий справочник (FAQ, глоссарий) — то же, что знает бот |
| [principles-vs-skills.md](principles-vs-skills.md) | Почему навыков недостаточно: принципы и генеративная иерархия |

**В Pack (через Aisystant MCP `knowledge_search`):**

| Сущность | Что содержит |
|----------|-------------|
| `DP.IWE.001` | Что такое IWE, зачем, 5 архитектурных видов (системы, описания, роли, методы, рабочие продукты), тиры, контуры |
| `DP.IWE.002` | Шаблон и установка: пререквизиты, стоимость, роли, ОРЗ, FAQ, безопасность |
| `DP.EXOCORTEX.001` | Модульный экзокортекс: 3 слоя, template-sync, standard/personal |
| `DP.ARCH.002` | Тиры T0-T4 + TM1-TM3 + TA1-TA4 + TD1: что доступно на каждом уровне |
| `DP.ROLE.001` | Полный реестр ИИ-ролей (21 роль) |

> **Нужна помощь?** Спроси бота @aist_me_bot — он ищет по базе знаний платформы (Pack).
> **Техническая проблема?** Открой issue: [github.com/aisystant/FMT-exocortex-template/issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues)

