# Установка IWE: пошаговое руководство

> Это руководство проведёт тебя от чистого компьютера до работающего IWE за 30-60 минут.
> Подходит для macOS. Linux и Windows (WSL) — см. примечания в каждом шаге.

---

## Что ты получишь в итоге

- **Claude Code** знает твои цели, задачи и методологию — помнит контекст между сессиями
- **Стратег** (ИИ-агент) каждое утро готовит план дня, по воскресеньям — итоги недели
- **Экстрактор** (ИИ-агент, опционально) — извлекает знания из сессий и заметок в Pack-репо
- **Синхронизатор** (центральный scheduler, опционально) — расписание агентов, уведомления в Telegram, ночной скан кода
- **DS-strategy** — твой личный стратегический хаб (приватный репозиторий)
- **Заметки через Telegram** — пишешь мысль в бот, она попадает в систему планирования
- **WakaTime** (опционально) — автоматический трекинг рабочего времени

---

## Этап 0: Подготовка (15-20 мин)

Если у тебя уже установлены Git, Node.js и GitHub CLI — переходи к Этапу 1.

### 0.1 Homebrew (только macOS)

Homebrew — менеджер пакетов для macOS. Если уже есть — пропусти.

```bash
# Проверить
brew --version

# Установить (если нет)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

После установки Homebrew может попросить выполнить команду для PATH — скопируй и выполни её.

### 0.2 Git

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

Нужны для установки Claude Code CLI.

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

```bash
# Проверить
gh --version

# Установить
# macOS:
brew install gh
# Linux:
# https://cli.github.com/ — инструкция по установке
```

**GitHub аккаунт:** если нет — зарегистрируйся на [github.com](https://github.com/signup).

```bash
# Авторизация (выполни один раз)
gh auth login
# Выбери: GitHub.com → HTTPS → Login with a web browser
# Откроется браузер → войди в свой аккаунт
```

Проверка:
```bash
gh auth status
# Должно показать: ✓ Logged in to github.com as <username>
```

### 0.5 Claude Code CLI

Требует подписку Anthropic: **Claude Max** (~$100/мес) или **Claude Pro** ($20/мес, с ограничениями). Для полноценной работы рекомендуется Max.

```bash
# Установить
npm install -g @anthropic-ai/claude-code

# Проверить
claude --version
```

При первом запуске Claude Code попросит войти в аккаунт Anthropic — следуй инструкциям.

### 0.6 VS Code (рекомендуется)

VS Code — редактор, в котором удобно работать с Claude Code.

- Скачай: [code.visualstudio.com](https://code.visualstudio.com/)
- Установи расширение Claude Code (опционально): `Ctrl+Shift+X` → поиск «Claude Code»

---

## Этап 1: Установка IWE (~5 мин)

### 1.1 Создай рабочую директорию

```bash
mkdir -p ~/Github
cd ~/Github
```

### 1.2 Скачай и запусти установщик

```bash
# Клонировать репо с установщиком
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
| Workspace directory | Рабочая папка | `~/Github` (Enter = по умолчанию) |
| Claude CLI path | Путь к claude | Enter (определяется авто) |
| Strategist launch hour (UTC) | Час запуска Стратега | `4` (= 7:00 MSK, 8:00 Алматы) |
| Timezone description | Описание времени | `7:00 MSK` |

Скрипт выполнит 7 шагов:
1. Форкнет шаблон экзокортекса в твой GitHub
2. Подставит твои данные во все файлы
3. Установит CLAUDE.md в рабочую директорию
4. Установит память (memory/) для Claude Code
5. Настроит разрешения Claude Code
6. Установит автоматический запуск Стратега (launchd)
7. Создаст DS-strategy — твой приватный стратегический репо

### 1.3 Проверь установку

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

Если всё есть — переходи к Этапу 1.4 (или к Этапу 2, если хочешь настроить роли позже).

### 1.4 Установка дополнительных ролей (опционально)

Setup.sh устанавливает только Стратега. Экстрактор и Синхронизатор ставятся отдельно:

```bash
cd ~/Github/FMT-exocortex-template

# Экстрактор — извлечение знаний из сессий, проверка inbox (каждые 3 часа)
bash roles/extractor/install.sh

# Синхронизатор — центральный scheduler: расписание агентов, уведомления, code-scan
bash roles/synchronizer/install.sh
```

> **Рекомендация:** Экстрактор и Синхронизатор можно установить позже, когда освоишь базовый цикл со Стратегом. См. `roles/extractor/README.md` и `roles/synchronizer/README.md`.

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

```bash
cd ~/Github
claude
```

Скажи Claude:

> **/setup-wakatime**

Claude проведёт через установку:
1. wakatime-cli
2. API-ключ (получи на [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Хуки для Claude Code
4. Desktop App (опционально)

После настройки: данные WakaTime автоматически включаются в утренний план дня и недельный отчёт.

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

```bash
cd ~/Github/FMT-exocortex-template
bash update.sh
```

Что обновляется: CLAUDE.md, memory/, промпты и скрипты ролей (Стратег, Экстрактор, Синхронизатор) — всё стандартное (platform-space). Если скрипты ролей изменились — автоматически переустановятся launchd-агенты.
Что НЕ трогается: MEMORY.md, DS-strategy/, routing.md, твои личные настройки — всё пользовательское (user-space).

> Посмотреть доступные обновления: `bash update.sh --check`

---

## Часто задаваемые вопросы

**Нужна ли подписка Anthropic?**
Да, Claude Code требует подписку Anthropic. Рекомендуется **Claude Max** (~$100/мес). **Claude Pro** ($20/мес) тоже работает, но с лимитами на количество сообщений.

**Работает ли на Windows?**
Через WSL (Windows Subsystem for Linux) — да. Установи WSL, затем следуй инструкции для Linux. Launchd не работает в WSL — используй cron.

**Можно ли без Стратега?**
Да. Стратег — это автоматизация (утренние планы, ревью). Без него Claude Code + CLAUDE.md + memory/ работают полностью. Планируешь вручную.

**Что такое Pack?**
Pack — это предметная база знаний. Создаётся позже, когда накопишь достаточно captures. Первый шаг — работа с `captures.md` через Экстрактор.

**Безопасны ли мои данные?**
DS-strategy — приватный репо. MEMORY.md — локальный файл. Ничего не публикуется без твоего ведома. WakaTime — отдельный SaaS с собственной политикой приватности.

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
| По мере роста | Настрой Экстрактор (автоматическое извлечение знаний) | См. `roles/extractor/README.md` |
| По желанию | Подключи Синхронизатор (уведомления в TG) | См. `roles/synchronizer/README.md` |

---

---

## Дополнительные материалы

| Документ | Что содержит |
|----------|-------------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Полный путь изучения IWE: принципы, протоколы, агенты, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Краткий справочник (FAQ, глоссарий) — то же, что знает бот |
| [principles-vs-skills.md](principles-vs-skills.md) | Почему навыков недостаточно: принципы и генеративная иерархия |

> **Нужна помощь?** Спроси бота @aist_me_bot — он знает всё про IWE, протоколы и настройку.
> **Техническая проблема?** Открой issue: [github.com/TserenTserenov/FMT-exocortex-template/issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues)
