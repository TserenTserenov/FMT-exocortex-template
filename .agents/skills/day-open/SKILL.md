---
name: day-open
description: "Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — builds DayPlan and compact dashboard."
argument-hint: ""
version: 1.1.0
layer: L1
status: active
triggers:
  slash: [/day-open]
  phrases: [открывай]
routing:
  executor: agent
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо и upstream без push-доступа.
> **Шаблоны:** `.agents/skills/day-open/templates.md` (читать перед шагами 7a и 7d).
> **Детали шагов:** `day-open/day-open-details.md`

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Исполнять ТОЛЬКО пошагово через update_plan.
Каждый шаг → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).
**Почему:** без update_plan агент пропускает шаги из-за загрязнения контекста (SOTA.002).

## Алгоритм

### 0. Extensions (before)
`bash .claude/scripts/load-extensions.sh day-open before` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.
<!-- Детали: day-open-details.md § Шаг 0 -->

### 1. Вчера
Прочитать вчерашний DayPlan (только секции «Итоги», «Завтра начать с», «Требует внимания»). Коммиты за вчера по всем `$IWE_WORKSPACE/*/` репо.
<!-- Детали (адресное чтение, fallback): day-open-details.md § Шаг 1 -->

### 1b. GitHub Issues
`day-open-scaffold.sh` (`render_repo_issues`) делает свип. Critical FMT issues: `bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram`.
<!-- Детали (фильтры, кэш): day-open-details.md § Шаг 1b -->

### 1c. Inbox Triage
Разобрать `inbox/fleeting-notes.md`, `inbox/captures.md`, `inbox/extraction-reports/*.md` (pending-review). Категоризировать по PD.FORM.083. Знание доменное без маркера «Экстрактору» → таблица **Кандидаты Экстрактору** в DayPlan. Каждая заметка в DayPlan — markdown-ссылка на источник.
<!-- Детали (гиперссылки, блокирующие правила): day-open-details.md § Шаг 1c -->

### 2. План на сегодня
Приоритет: (1) carry-over из Day Close → все без обрезки; (2) WeekPlan: in_progress + pending → проверить релевантность, бюджет (Budget Spread); (3) MEMORY.md «РП текущей недели»; (4) `mandatory_daily_wps`. Слот 1 = саморазвитие.
<!-- Детали (Budget Spread алгоритм, экономия контекста): day-open-details.md § Шаг 2 -->

### 3. Саморазвитие
Руководство, где остановился, черновики (`<governance-repo>/drafts/`).

### 4. Стратегирование
Если `strategy_day` → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

### 4b. Помидорки
Из `day-rhythm-config.yaml → pomodoro`.

### 4c. Календарь
`bash $IWE_SCRIPTS/server-calendar.sh YYYY-MM-DD` → секция «Календарь» для DayPlan (Встречи + Напоминания).
Если `strategy_day`: `bash $IWE_SCRIPTS/server-calendar.sh --week YYYY-MM-DD` → секция «Календарь недели» в WeekPlan.
<!-- Детали (алгоритм классификации, формат): day-open-details.md § Шаг 4c -->

### 5. IWE за ночь (светофор)
`cd "$IWE_TEMPLATE" && bash update.sh --check` + проверка Base-репо (FPF, SPF, ZP) на отставание от origin. Обновления → «Требует внимания». Scout report не проревьюен → «Требует внимания».
<!-- Детали (bash-скрипты): day-open-details.md § Шаг 5 -->

### 5a2. Видео
`video.enabled: true` → показать только новые файлы за сегодня (`-mtime 0`). `false` → пропустить.
<!-- Детали: day-open-details.md § Шаг 5a2 -->

### 5c. Редактор контента
`content_editor.enabled: false` → пропустить. Иначе: топ-3 черновика из `drafts/` по актуальности/свежести/полноте → таблица в DayPlan. Сигнал готовых постов → «Требует внимания».
<!-- Детали (полный алгоритм оценки): day-open-details.md § Шаг 5c -->

### 6. Мир
`news.enabled: false` → пропустить. Иначе: Feeds/WebSearch → заголовки с URL. Лёгкий субагент (context isolation) анализирует заголовки + топ-5 РП → «Вывод: 2-4 предложения» в начале секции.
<!-- Детали (промпт субагента, формат секции): day-open-details.md § Шаг 6 -->

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6b2. Разметка ТВС
Пометить каждый РП режимом Текущее / Важное / Срочное. Хотя бы один блок Важного обязателен. Срочное — только угроза остановки конвейера.
<!-- Детали (правила ТВС, различения): day-open-details.md § Шаг 6b2 -->

### 6c. Extensions (after)
`bash .claude/scripts/load-extensions.sh day-open after` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.

### 7. Запись

> ⚠️ **Перед шагами 7a и 7d:** `Read .agents/skills/day-open/templates.md`. Файл не найден → сообщить пилоту, не продолжать.

**7a.** DayPlan: `<governance-repo>/current/DayPlan YYYY-MM-DD.md` по шаблону из `templates.md`. Предыдущий → `archive/day-plans/`.
**7a2.** Session Log: `<governance-repo>/sessions/YYYY-MM-DD.md`. Если существует — не перезаписывать.
<!-- Шаблон Session Log: day-open-details.md § Шаг 7a2 -->
**7b.** `bash .claude/scripts/load-extensions.sh day-open checks` → Exit 0: выполнить верификацию. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения всех checks.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code по шаблону «Шаблон compact dashboard» из `templates.md`.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
