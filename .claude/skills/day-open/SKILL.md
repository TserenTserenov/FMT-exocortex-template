---
name: day-open
description: "Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — builds DayPlan and compact dashboard."
argument-hint: ""
version: 2.0.0
routing:
  executor: sonnet
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо (CLAUDE.md) и upstream без push-доступа (Base, чужие fork).
> **Шаблоны DayPlan и dashboard:** в `templates.md` — загружать ТОЛЬКО в шаге 7a/7d.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
Каждый шаг алгоритма ниже → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).
**Почему:** без TodoWrite агент пропускает шаги из-за загрязнения контекста (SOTA.002).

## Правило кэша (READ ONCE)

> **БЛОКИРУЮЩЕЕ.** Каждый файл читать ровно один раз за протокол.
> Прочитал → держи в контексте, не перечитывай.
>
> Файлы, которые нужны в нескольких шагах — читать в первом шаге, где они нужны:
> - `day-rhythm-config.yaml` → шаг 0/4b
> - `WeekPlan` → шаг 2 (и держать до шага 7)
> - `MEMORY.md` → шаг 2
> - `fleeting-notes.md` → шаг 1c
> - вчерашний DayPlan → шаг 1

## Алгоритм

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить содержимое как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-open.before.md` И `extensions/day-open.before.<suffix>.md`.

### 1. Вчера
Прочитать вчерашний DayPlan (`archive/day-plans/` или `current/`). Взять:
- Секцию «Итоги» → 1-3 результата
- Секцию «Завтра начать с:» / carry-over РП → **приоритетный вход** для шага 2
- Незакрытые вопросы из «Требует внимания»

Fallback: файла нет → пропустить, работать из коммитов.

Коммиты за вчера по всем `$IWE_WORKSPACE/*/` репо. Сопоставить с DayPlan.

### 1b. GitHub Issues
`gh issue list` по всем репо (включая вложенным). Фильтр 2 дня. Связь с РП по ключевым словам.
**Только actionable:** пропускать read-only и upstream без push-доступа.

**Critical FMT issues (детектор):** `bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram` — выводит markdown-таблицу открытых issues с label `critical`/`deadline` в FMT-exocortex-template. Если `TG_BOT_TOKEN` и `TG_CHAT_ID` настроены — убрать `--no-telegram` для дублирования в Telegram.

### 1c. Inbox Triage (ежедневный)

**Источники:**
- `<governance-repo>/inbox/fleeting-notes.md` — свежие заметки
- `<governance-repo>/inbox/captures.md` — знаниевые кандидаты (если есть)
- `<governance-repo>/inbox/extraction-reports/*.md` со `status: pending-review`

**Категоризация заметок** по PD.FORM.083 (7 категорий): НЭП / Задача / Знание доменное / Знание реализационное / Черновик / Личные данные / Шум. НЕ удалять.
**Carry-over заметок из вчерашнего DayPlan:** проверить по git log (`note-review`), были ли обработаны.
**Гиперссылки на заметки (БЛОКИРУЮЩЕЕ):** каждая заметка в секции «Разбор заметок» — markdown-ссылка на источник.
**Знаниевые заметки = кандидаты (БЛОКИРУЮЩЕЕ):** категория «Знание доменное» без маркера «Экстрактору» → таблица **Кандидаты Экстрактору** в DayPlan.

### 2. План на сегодня
**Приоритет входов (строгий порядок):**
1. **Carry-over из Day Close (БЛОКИРУЮЩЕЕ):** ВСЕ РП из секции «Завтра начать с» → в план без обрезки.
2. **WeekPlan (ОБЯЗАТЕЛЬНО):** прочитать WeekPlan → ВСЕ in_progress и pending РП → проверить каждый: релевантен сегодня? Есть дедлайн? Просрочен?
   **Budget Spread** (если `budget_spread.enabled: true`):
   - `days_left` = оставшиеся рабочие дни пн–пт включая сегодня
   - `daily_slot` = round(budget_week / days_left, `rounding`)
   - Нет бюджета в WeekPlan → добавить в «Требует внимания»
   - РП уже в плане (carry-over) → взять max(carry_over_budget, daily_slot)
3. **MEMORY.md → «РП текущей недели»:** сверить — нет ли РП, упущенных в WeekPlan.
4. `day-rhythm-config.yaml → mandatory_daily_wps` — обязательные РП.

**Слот 1 = саморазвитие.**
Mandatory РП отсутствуют в WeekPlan → «Требует внимания».

### 3. Саморазвитие
Руководство, где остановился, черновики (`<governance-repo>/drafts/`).

### 4. Стратегирование
Если strategy_day → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

### 4b. Помидорки
Из `day-rhythm-config.yaml → pomodoro`.

### 4c. Календарь (Day Mode)
`bash $IWE_WORKSPACE/scripts/server-calendar.sh YYYY-MM-DD` — секция «Календарь» для DayPlan.

Что делает скрипт:
1. Запрашивает ВСЕ календари из `calendar_ids`.
2. Фильтрует только по `visibility == "private"`.
3. Классифицирует: Встречи / Напоминания.
4. Статус: ⏳ предстоит / 🔄 идёт / ✅ завершено.
5. Считает свободные блоки ≥1h в рамках 09:00–22:00.

**Формат в DayPlan:** две таблицы (Встречи + Напоминания) по шаблону `memory/templates-dayplan.md`.

### 4c-alt. Календарь недели (strategy_day)
Если сегодня `strategy_day` — перед формированием WeekPlan запустить:
```bash
bash $IWE_WORKSPACE/scripts/server-calendar.sh --week YYYY-MM-DD
```

### 5. IWE за ночь (светофор)
update.sh, MCP reindex, Scout. 🟢/🟡/🔴.

**Проверка обновлений:** `cd "$IWE_TEMPLATE" && bash update.sh --check 2>&1`. Если доступно → «Требует внимания».

**Проверка Base-репо (FPF, SPF, ZP):**
```bash
for repo in FPF SPF ZP; do
  dir="$IWE_WORKSPACE/$repo"
  [ -d "$dir/.git" ] && (cd "$dir" && git fetch --quiet 2>/dev/null && behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0) && [ "$behind" -gt 0 ] && echo "$repo: $behind новых коммитов" || echo "$repo: актуален")
done
```

### 5a2. Видео
Если `day-rhythm-config.yaml → video.enabled: true`:
1. Сканировать директории из `video.directories` на файлы с расширениями из `video.extensions`
2. Показать ТОЛЬКО новые записи за сегодня (`-mtime 0`).
3. `video.enabled: false` → пропустить

### 5c. Редактор контента (DP.ROLE.033 / DP.SC.127)
`config: content_editor.enabled` (day-rhythm-config.yaml) — `false` → пропустить.
1. Читать все `<governance-repo>/drafts/D-NNN-*.md` — frontmatter + текст.
2. Читать WeekPlan (уже в контексте — не перечитывать).
3. Оценить каждый черновик: сильная идея / актуальность / свежесть / полнота.
4. Отобрать топ-3 → секция «Редактор контента» в DayPlan.
5. Список застрявших (TTL истёк) — не архивировать, только показать.

### 5d. Scout
Scout report. Не проревьюен → «Требует внимания».

### 6. Мир
`day-rhythm-config.yaml → news`. Feeds/WebSearch. `enabled: false` → пропустить.
**Ссылки на источники обязательны** (URL).

**6a. News Lens (субагент Haiku):**
Промпт: «Ты — разведчик новостей. Дан список заголовков + активные РП. Написать 2-4 предложения: что важно для работы сегодня? Только русский.»
Вывод → поле **«Вывод:»** в начале секции «Мир».

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6c. Extensions (after)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open after`. Exit 0 → выполнить. Exit 1 → пропустить.

### 7. Запись
**7a.** Загрузить шаблоны: `Read .claude/skills/day-open/templates.md`. Записать DayPlan: `<governance-repo>/current/DayPlan YYYY-MM-DD.md`. Предыдущий → `archive/day-plans/`.
**7a2.** Записать журнал сессии: `<governance-repo>/sessions/YYYY-MM-DD.md`:
```markdown
---
type: session-log
date: YYYY-MM-DD
week: W{N}
agent: Стратег
---
# Session Log: YYYY-MM-DD
## Day Open
- DayPlan: `current/DayPlan YYYY-MM-DD.md`
- Carry-over: [список]
## Сессии дня
> Заполняется в Day Close
## Day Close
> Дописывается в Day Close
```
Если файл уже существует — не перезаписывать.
**7b.** Загрузить: `bash .claude/scripts/load-extensions.sh day-open checks`. Exit 0 → выполнить верификацию. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code (шаблон в `templates.md`).
