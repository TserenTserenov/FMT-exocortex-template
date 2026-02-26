# Установка IWE: пошаговое руководство

> Это руководство проведёт тебя от чистого компьютера до работающего IWE за 30-60 минут.
> Подходит для macOS. Linux и Windows (WSL) — см. примечания в каждом шаге.

---

## Где ты сейчас и куда идёшь

Платформа работает на 4 уровнях (тирах). Возможно, ты уже пользуешься ботом — это T1-T3. Это руководство переводит тебя на **T4**, где появляется персональное рабочее пространство с ИИ-агентами.

| Тир | Что есть | Как попасть |
|-----|---------|-------------|
| **T1: Старт** | Бот @aist_me_bot: поиск по базе знаний, марафоны | `/start` в Telegram |
| **T2: Изучение** | + Программы, руководства, расписание | Подписка на программу |
| **T3: Персонализация** | + Персональные ответы, цифровой двойник | `/twin` в боте |
| **T4: Созидание (IWE)** | + Claude Code, Стратег, Git, свои базы знаний | **Это руководство** |

> Всё, что ты накопил на T1-T3 (Digital Twin, профиль, прогресс) — сохраняется. T4 добавляет новые возможности, не заменяет старые.

---

## Что ты получишь в итоге

- **Claude Code** — ИИ-помощник, который знает твои цели, задачи и методологию. Помнит контекст между сессиями
- **Стратег** (ИИ-агент) — каждое утро готовит план дня, по воскресеньям — итоги недели
- **Экстрактор** (ИИ-агент, позже) — извлекает знания из сессий в базу знаний
- **Синхронизатор** (позже) — расписание агентов, уведомления в Telegram
- **DS-strategy** — твой личный стратегический хаб (приватный репозиторий на GitHub)
- **Заметки через Telegram** — пишешь мысль в бот, она попадает в систему планирования

---

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

---

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

Требует подписку Anthropic. Рекомендуется начать с **Claude Pro** ($20/мес). Если получите значительный эффект от работы с Claude Code и упрётесь в лимиты — переходите на **Claude Max** (~$100/мес) для работы без ограничений.

В терминале:
```bash
# Установить
npm install -g @anthropic-ai/claude-code

# Проверить
claude --version
```

При первом запуске Claude Code попросит войти в аккаунт Anthropic — следуй инструкциям в терминале.

### 0.6 VS Code (рекомендуется)

VS Code — редактор кода с графическим интерфейсом. В нём удобно работать с Claude Code: видишь файлы, терминал и ИИ-ассистента в одном окне. **Без VS Code** придётся работать только через терминал — это возможно, но менее наглядно.

- Скачай и установи: [code.visualstudio.com](https://code.visualstudio.com/)
- Открой VS Code → нажми `Cmd+Shift+X` (macOS) или `Ctrl+Shift+X` (Windows/Linux) → найди «Claude Code» → нажми Install

---

## Этап 1: Установка IWE (~5 мин)

### 1.1 Создай рабочую папку

Создай на своём компьютере **одну папку** для всех репозиториев — текущих и будущих. В неё будут клонироваться все репозитории: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{область}/`, `DS-{проекты}/` и др. `CLAUDE.md` тоже будет лежать в корне этой папки. По умолчанию это `~/Github`:

```bash
mkdir -p ~/Github
cd ~/Github
```

> **Важно:** Название может быть любым (не обязательно `Github`), но все репо должны быть в одном месте — Claude Code ориентируется на эту структуру.

### 1.2 Скачай и запусти установщик

Установщик находится в репозитории [DS-ai-systems](https://github.com/TserenTserenov/DS-ai-systems). В терминале:

```bash
# Скачать репо с установщиком
gh repo clone TserenTserenov/DS-ai-systems -- --depth 1
cd DS-ai-systems/setup

# Запустить установку
bash setup.sh
```

> **Посмотреть без выполнения:** `bash setup.sh --dry-run`

Скрипт спросит:

| Вопрос | Что ввести | Пример |
|--------|-----------|--------|
| GitHub username | Твой логин на GitHub | `ivan-petrov` |
| Workspace directory | Рабочая папка | `~/Github` (просто нажми Enter) |
| Claude CLI path | Путь к claude | Просто нажми Enter (определяется автоматически) |
| Strategist launch hour (UTC) | Час запуска Стратега | `4` (= 7:00 MSK, 8:00 Алматы) |
| Timezone description | Описание времени | `7:00 MSK` |

Скрипт выполнит 8 шагов:
1. Создаст твою копию (форк) [шаблона экзокортекса](https://github.com/TserenTserenov/FMT-exocortex-template) на GitHub
2. Подставит твои данные во все файлы (имя, пути, часовой пояс)
3. Установит `CLAUDE.md` — правила для Claude Code
4. Установит `memory/` — оперативную память для Claude Code
5. Настроит разрешения и MCP-подключение (`.claude/settings.local.json`)
6. Установит автоматический запуск Стратега (launchd на macOS)
7. Создаст `DS-strategy/` — твой приватный стратегический репозиторий на GitHub
8. Проверит MCP-подключение к базе знаний платформы

### 1.3 Проверь установку

В терминале:
```bash
# Должен существовать
ls ~/Github/CLAUDE.md

# Должны быть файлы памяти (10+)
ls ~/.claude/projects/*/memory/

# Должен быть стратегический хаб
ls ~/Github/DS-strategy/

# Стратег должен быть в расписании (macOS)
launchctl list | grep strategist
```

Если всё есть — проверь MCP-подключение (1.3b) и переходи к Этапу 2. Дополнительные роли (1.4) можно установить позже.

### 1.3b Проверь MCP-подключение

MCP (Model Context Protocol) — это доступ Claude Code к базе знаний платформы: документам, руководствам, цифровому двойнику. Подключение настроено автоматически через `.claude/settings.local.json`.

В Claude Code (VS Code или терминале):
```
# Открой Claude Code в папке экзокортекса
cd ~/Github/FMT-exocortex-template
claude

# В Claude Code выполни:
knowledge-mcp search("принципы")
# Ожидаемый результат: список документов из базы знаний

knowledge-mcp search("методы саморазвития", source_type="guides")
# Ожидаемый результат: список образовательных руководств
```

> **Не работает?** Проверь файл `.claude/settings.local.json` — должен содержать секцию `mcpServers` с двумя серверами (knowledge-mcp, ddt). Если файла нет — запусти `bash update.sh` для обновления.

### 1.4 Установка дополнительных ролей (позже)

Setup.sh устанавливает только Стратега. Экстрактор и Синхронизатор ставятся отдельно, когда освоишь базовый цикл:

В терминале:
```bash
cd ~/Github/FMT-exocortex-template

# Экстрактор — извлечение знаний из сессий, проверка inbox (каждые 3 часа)
bash roles/extractor/install.sh

# Синхронизатор — центральный scheduler: расписание агентов, уведомления, code-scan
bash roles/synchronizer/install.sh
```

> **Рекомендация:** Экстрактор и Синхронизатор можно установить позже, когда освоишь базовый цикл со Стратегом. Подробнее: [roles/extractor/README.md](../roles/extractor/README.md) и [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Важно:** Если устанавливаешь Синхронизатор, он заменяет отдельные launchd-агенты Стратега единым scheduler. Все роли будут запускаться по расписанию из одной точки.

<details>
<summary>Что-то не работает?</summary>

**`CLAUDE.md` не найден:**
```bash
cp ~/Github/FMT-exocortex-template/CLAUDE.md ~/Github/CLAUDE.md
```

**Memory не найдена:**
```bash
# Определи slug
echo $HOME/Github | tr '/' '-'
# Пример результата: -Users-ivan-Github

# Создай директорию и скопируй
mkdir -p ~/.claude/projects/-Users-ivan-Github/memory
cp ~/Github/FMT-exocortex-template/memory/*.md ~/.claude/projects/-Users-ivan-Github/memory/
```

**launchd не загружен:**
```bash
cd ~/Github/FMT-exocortex-template/roles/strategist
bash install.sh
```

**DS-strategy не создан:**
```bash
cd ~/Github
mkdir -p DS-strategy/{current,inbox,docs,archive/wp-contexts,exocortex}
cd DS-strategy && git init && git add -A && git commit -m "Initial"
gh repo create $(gh api user -q .login)/DS-strategy --private --source=. --push
```
</details>

---

## Этап 2: Первая стратегическая сессия (~30 мин)

Это самый важный шаг — ты настроишь свои цели и первый план.

**Вариант А — через VS Code (рекомендуется):**
1. Открой VS Code
2. `File → Open Folder` → выбери папку `~/Github`
3. Открой панель Claude Code: `Cmd+Shift+P` (macOS) или `Ctrl+Shift+P` (Windows) → набери «Claude Code: Open» → Enter

**Вариант Б — через терминал:**
```bash
cd ~/Github
claude
```

Скажи Claude:

> **«Проведём первую стратегическую сессию»**

Claude прочитает CLAUDE.md и memory/ и проведёт тебя через:

1. **Определение целей** — Кем ты хочешь быть через год? Чему научиться?
2. **Неудовлетворённости** — Что мешает? Где разрыв между текущим и желаемым?
3. **Первый WeekPlan** — Конкретные задачи на неделю с бюджетами
4. **Обновление MEMORY.md** — Твои рабочие продукты появятся в таблице

**Результат:** заполненные `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md` и первый `WeekPlan` в `DS-strategy/current/`.

---

## Этап 3: Настройка заметок через Telegram (5 мин)

Чтобы отправлять мысли в систему планирования прямо из Telegram:

1. Найди бота **@aist_me_bot** в Telegram
2. Нажми `/start`
3. Оформи подписку (если ещё нет)

**Как отправлять заметки:**
- Напиши: `.Моя мысль про архитектуру` (точка + текст)
- Или перешли/ответь на любое сообщение с `.`

Заметка попадёт в `DS-strategy/inbox/fleeting-notes.md`. Стратег разберёт её вечером (Note-Review, 23:00) и классифицирует: задача → план, знание → captures, идея → на обсуждение.

---

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

---

## Что происходит дальше (автоматически)

После установки система работает сама:

| Время | Агент | Что происходит | Где результат |
|-------|-------|---------------|---------------|
| **Утро (Вт-Вс)** | Стратег | Собирает коммиты за вчера, формирует план дня | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Утро (Пн)** | Стратег | Готовит черновик недельного плана + повестку сессии | `DS-strategy/current/WeekPlan W{N}.md` |
| **Каждые 3 часа** | Экстрактор* | Проверяет inbox (заметки, captures) → предлагает знания в Pack | `DS-strategy/inbox/extraction-reports/` |
| **Вечер (23:00)** | Стратег | Note-Review классифицирует заметки из Telegram | Целевые документы в DS-strategy |
| **Ночь (00:00)** | Синхронизатор* | Code-scan — обзор изменений в downstream-репо | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Ночь (Вс→Пн)** | Стратег | Week Review — итоги недели | `DS-strategy/current/WeekReport W{N}.md` |
| **Утро (06:00)** | Синхронизатор* | Daily report — сводка ночных задач | `DS-strategy/current/SchedulerReport YYYY-MM-DD.md` |

> *Экстрактор и Синхронизатор работают только если установлены (Этап 1.4).*

### Ручной запуск (если нужно)

В терминале:
```bash
# План дня прямо сейчас
bash ~/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan

# Сессия стратегирования (интерактивная)
bash ~/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh strategy-session

# Обзор заметок
bash ~/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh note-review

# Итоги недели
bash ~/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh week-review

# Экстрактор: извлечь знания из текущей сессии
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh session-close

# Экстрактор: проверить inbox
bash ~/Github/FMT-exocortex-template/roles/extractor/scripts/extractor.sh inbox-check

# Синхронизатор: статус всех задач
bash ~/Github/FMT-exocortex-template/roles/synchronizer/scripts/scheduler.sh status
```

---

## Ежедневная работа: три стадии (ОРЗ)

Каждая сессия в Claude Code проходит три стадии:

### Открытие (автоматически)
Ты даёшь задание → Claude проверяет: есть ли такая задача в плане недели? Если нет — предлагает добавить (WP Gate). Объявляет роль, метод, оценку.

### Работа
Claude выполняет задачу. На каждом рубеже (подзадача, паттерн, решение) — фиксирует знания: *«Capture: [что] → [куда]»*.

### Закрытие
Скажи **«закрывай»** → Claude коммитит, пушит, обновляет память, делает backup.

---

## Обновления

Шаблон экзокортекса обновляется — новые протоколы, улучшенные промпты, исправления.

В терминале:
```bash
cd ~/Github/FMT-exocortex-template
bash update.sh
```

Что обновляется: CLAUDE.md, memory/, промпты и скрипты ролей, `.claude/settings.local.json` (MCP-конфигурация) — всё стандартное (platform-space). Если скрипты ролей изменились — автоматически переустановятся launchd-агенты.
Что НЕ трогается: MEMORY.md, DS-strategy/, routing.md, пользовательские permissions — всё пользовательское (user-space).

> Посмотреть доступные обновления: `bash update.sh --check`

---

## Безопасность и приватность

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
| **MCP knowledge-mcp** | Сервер платформы | Поисковые запросы. Данные пользователя не отправляются |
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

---

## Часто задаваемые вопросы

**Нужна ли подписка Anthropic?**
Да, Claude Code требует подписку Anthropic. Рекомендуется начать с **Claude Pro** ($20/мес). Если получите значительный эффект и упрётесь в лимиты — переходите на **Claude Max** (~$100/мес).

**Работает ли на Windows?**
Через WSL (Windows Subsystem for Linux) — да. [Установи WSL](https://learn.microsoft.com/ru-ru/windows/wsl/install), затем следуй инструкции для Linux. Launchd не работает в WSL — используй cron.

**Можно ли без Стратега?**
Да. Стратег — это автоматизация (утренние планы, ревью). Без него Claude Code + CLAUDE.md + memory/ работают полностью. Планируешь вручную.

**Что такое Pack?**
Pack — это предметная база знаний. Создаётся позже, когда накопишь достаточно captures. Первый шаг — работа с `captures.md` через Экстрактор.

**Как проверить MCP?**
Открой Claude Code в папке экзокортекса и попроси: «Найди документы про принципы». Claude должен использовать `knowledge-mcp search` и вернуть результаты. Если не работает — проверь `.claude/settings.local.json`.

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
rm ~/Github/CLAUDE.md
rm -rf ~/.claude/projects/*/memory/
rm -rf ~/.local/state/exocortex/

# Репозитории (по желанию)
rm -rf ~/Github/FMT-exocortex-template
rm -rf ~/Github/DS-strategy
```

---

## Следующие шаги

| Когда | Что | Как |
|-------|-----|-----|
| После первой недели | Пройди сессию стратегирования (Пн) | Claude сам предложит |
| Через 2 недели | Создай первый Pack (личная база знаний) | `claude` → «Помоги создать мой первый Pack» |
| По мере роста | Настрой Экстрактор (автоматическое извлечение знаний) | См. [roles/extractor/README.md](../roles/extractor/README.md) |
| По желанию | Подключи Синхронизатор (уведомления в TG) | См. [roles/synchronizer/README.md](../roles/synchronizer/README.md) |

---

## Дополнительные материалы

| Документ | Что содержит |
|----------|-------------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Полный путь изучения IWE: принципы, протоколы, агенты, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Краткий справочник (FAQ, глоссарий) — то же, что знает бот |
| [principles-vs-skills.md](principles-vs-skills.md) | Почему навыков недостаточно: принципы и генеративная иерархия |

> **Нужна помощь?** Спроси бота @aist_me_bot — он знает всё про IWE, протоколы и настройку.
> **Техническая проблема?** Открой issue: [github.com/TserenTserenov/FMT-exocortex-template/issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues)
