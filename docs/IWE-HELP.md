# IWE: справочник для бота

> Краткая справка по Intelligent Working Environment (IWE) для поиска и ответов бота.
> Полная установка: [SETUP-GUIDE.md](SETUP-GUIDE.md)

---

## Что такое IWE

IWE (Intelligent Working Environment) — интеллектуальная рабочая среда. Состоит из 6 компонентов:

1. **Экзокортекс** — подсистема памяти (CLAUDE.md + MEMORY.md + memory/*.md)
2. **Агенты** — ИИ-роли: Стратег (планирование), Экстрактор (знания), Синхронизатор (оркестрация)
3. **Инструменты** — Claude Code, WakaTime, Telegram-бот
4. **Методология** — протоколы ОРЗ (Открытие → Работа → Закрытие), WP Gate, Capture-to-Pack
5. **Рабочее пространство** — GitHub-репозитории (шаблон + DS-strategy + Pack-репо)
6. **Цифровой двойник** — профиль ученика в системе

Source-of-truth: DP.IWE.001.

---

## Что нужно для установки

### Обязательно
- macOS, Linux или Windows (через WSL)
- Git + GitHub аккаунт + GitHub CLI (`gh`)
- Node.js v18+ и npm
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Подписка Anthropic: **Claude Max** (~$100/мес) или **Claude Pro** ($20/мес, с ограничениями). Для полноценной работы с Claude Code рекомендуется Max.

### Опционально
- VS Code (рекомендуется)
- Telegram (@aist_me_bot) — для заметок
- WakaTime — трекинг рабочего времени

---

## Как установить IWE

**Время установки: 30–60 минут** (зависит от опыта с терминалом).

```bash
cd ~/Github
gh repo clone TserenTserenov/DS-ai-systems -- --depth 1
cd DS-ai-systems/setup
bash setup.sh
```

Скрипт спросит: GitHub username, рабочую директорию, час запуска Стратега (UTC), описание часового пояса.

Результат:
- Форк шаблона экзокортекса в твой GitHub
- Заполненные файлы (плейсхолдеры → твои данные)
- CLAUDE.md установлен в рабочую директорию
- Memory/ для Claude Code
- Стратег (launchd) в расписании
- DS-strategy — приватный репо

---

## Три роли в IWE

> В шаблоне экзокортекса ровно **3 роли**: Стратег, Экстрактор, Синхронизатор. Других ролей (Рецензент, Аналитик и т.д.) в шаблоне нет.

### Стратег (R1)
Планирование и рефлексия. Каждое утро (Вт-Вс) формирует план дня из коммитов вчера. Понедельник — подготовка к недельной сессии. Вечером (23:00) — разбор заметок из Telegram.

Ручной запуск:
```bash
bash ~/Github/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan
```

### Экстрактор (R2)
Извлечение знаний в Pack-репозитории. 4 сценария: session-close (при закрытии сессии), on-demand (по запросу), inbox-check (каждые 3 часа), knowledge-audit (аудит полноты).

Всегда предлагает, никогда не пишет без одобрения (human-in-the-loop).

Установка: `bash ~/Github/FMT-exocortex-template/roles/extractor/install.sh`

### Синхронизатор (R8)
Центральный диспетчер (bash, не ИИ). Управляет расписанием всех ролей, отправляет уведомления в Telegram, делает ночной обзор кода.

Установка: `bash ~/Github/FMT-exocortex-template/roles/synchronizer/install.sh`

---

## Протокол ОРЗ (ежедневная работа)

Каждая сессия в Claude Code — три стадии:

**Открытие.** Даёшь задание → Claude проверяет WP Gate (есть ли в плане недели?). Если нет — предлагает добавить. Объявляет роль, метод, оценку.

**Работа.** Claude выполняет задачу. На рубежах фиксирует знания: «Capture: [что] → [куда]».

**Закрытие.** Скажи «закрывай» → Claude коммитит, пушит, обновляет память, бэкапит.

---

## Память (3 слоя)

| Слой | Файл | Когда загружается |
|------|------|-------------------|
| Оперативная | `memory/MEMORY.md` | Всегда (авто-контекст) |
| Правила | `CLAUDE.md` | Всегда (авто-контекст) |
| Справочная | `memory/*.md` | По запросу |

MEMORY.md — личные (текущие задачи, РП недели). Редактируется каждую сессию.
Остальные memory/*.md — платформенные. Обновляются из upstream через `update.sh`.

---

## Обновление IWE

```bash
cd ~/Github/FMT-exocortex-template
bash update.sh          # обновить
bash update.sh --check  # проверить без применения
```

Обновляются: CLAUDE.md, memory/ (кроме MEMORY.md), промпты ролей, скрипты.
НЕ трогаются: MEMORY.md, DS-strategy/, routing.md, личные настройки.

---

## Telegram-заметки

Бот @aist_me_bot принимает заметки:
- `.Текст заметки` (точка + текст)
- `.` + ответ/пересылка на сообщение

Заметки попадают в `DS-strategy/inbox/fleeting-notes.md`. Стратег разбирает вечером (Note-Review).

---

## Частые проблемы

**Claude Code не запускается** — проверь подписку Anthropic и `claude --version`. Рекомендуется Max plan ($100/мес). Pro plan ($20/мес) работает, но с лимитами на количество сообщений.

**Стратег не формирует план** — проверь `launchctl list | grep strategist` (macOS). Если нет — `bash roles/strategist/install.sh`.

**MEMORY.md не загружается** — проверь путь: `~/.claude/projects/-Users-<username>-Github/memory/MEMORY.md`. Имя директории = путь к workspace через дефисы.

**DS-strategy не создан** — вручную: `mkdir -p ~/Github/DS-strategy/{current,inbox,docs,archive} && cd ~/Github/DS-strategy && git init`.

**Заметки не приходят из Telegram** — проверь подписку в @aist_me_bot. Формат: точка + текст (`.Моя заметка`).

**Как настроить уведомления в Telegram** — создай `~/.config/aist/env`:
```bash
export TELEGRAM_BOT_TOKEN="your-token"
export TELEGRAM_CHAT_ID="your-id"
```

---

## Глоссарий

| Термин | Значение |
|--------|---------|
| IWE | Intelligent Working Environment — интеллектуальная рабочая среда |
| Экзокортекс | Подсистема памяти IWE (CLAUDE.md + MEMORY.md + memory/) |
| Pack | Предметная база знаний (source-of-truth для домена) |
| DS-strategy | Личный стратегический хаб (приватный репо) |
| WP Gate | Проверка: есть ли задача в плане недели? |
| ОРЗ | Открытие → Работа → Закрытие (три стадии сессии) |
| Capture | Фиксация знания по ходу работы |
| Platform-space | Стандартные файлы, обновляются из upstream |
| User-space | Личные файлы, никогда не затираются |
| Routing | Таблица маршрутизации знаний (куда класть captures) |
