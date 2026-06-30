---
name: day-open
description: "Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — builds DayPlan and compact dashboard."
argument-hint: ""
version: 1.2.0
layer: L1
status: active
triggers:
  slash: [/day-open]
  phrases: [открывай]
routing:
  executor: sonnet
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Выходы:** DayPlan (git, 80+ строк) → compact dashboard (VS Code, 20-30 строк). **Первое действие:** `date`.
> **Режим:** `day-rhythm-config.yaml → interactive: false` = одним блоком, решения → «Требует внимания». Свежесть: 2 дня (urgent — всегда). Issues — только actionable (не read-only, не upstream без push).
> **Шаблоны:** `day-open/templates.md` (читать перед 7a и 7d). **Детали шагов:** `day-open/day-open-details.md`.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение через TodoWrite

Каждый шаг → задача (pending → in_progress → completed). Следующий — ТОЛЬКО после отметки текущего. Невозможен → blocked.

## Шаги

**0. Extensions (before)** — `bash .claude/scripts/load-extensions.sh day-open before` → Exit 0: Read + выполнить. Exit 1: пропустить.

**1. Вчера** — вчерашний DayPlan (секции «Итоги», «Завтра начать с», «Требует внимания») + коммиты по всем `$IWE_WORKSPACE/*/` репо.

**1b. GitHub Issues** — `day-open-scaffold.sh` (`render_repo_issues`). Critical FMT: `bash $IWE_SCRIPTS/fmt-critical-alert.sh --no-telegram`.

**1c. Inbox Triage** — `inbox/fleeting-notes.md`, `inbox/captures.md`, `inbox/extraction-reports/*.md` (pending-review). Категоризировать по PD.FORM.083. Доменное знание без «Экстрактору» → таблица **Кандидаты Экстрактору** (ссылки на источники).

**2. План на сегодня** — приоритет: (1) carry-over из Day Close; (2) WeekPlan in_progress + pending (Budget Spread); (3) MEMORY.md РП недели; (4) `mandatory_daily_wps`. Слот 1 = саморазвитие.

**3. Саморазвитие** — руководство (где остановился) + черновики `<governance-repo>/drafts/`.

**4. Стратегирование** — `strategy_day` → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

**4b. Помидорки** — из `day-rhythm-config.yaml → pomodoro`.

**4c. Календарь** — `mcp__claude_ai_Google_Calendar__list_events` для каждого ID из `day-rhythm-config.yaml → calendar_ids`, диапазон 00:00–23:59 (Europe/Berlin). Объединить → секция «Календарь» (Встречи + Напоминания). `strategy_day`: диапазон 7 дней → «Календарь недели» в WeekPlan.

**5. IWE за ночь** — `cd "$IWE_TEMPLATE" && bash update.sh --check` + Base-репо (FPF, SPF, ZP) на отставание от origin. Обновления + непроверенный Scout → «Требует внимания».

**5a2. Видео** — `video.enabled: true` → новые файлы за сегодня (`-mtime 0`). `false` → пропустить.

**5c. Редактор контента** — `content_editor.enabled: false` → пропустить. Иначе: топ-3 черновика из `drafts/` → таблица в DayPlan. Готовые посты → «Требует внимания».

**6. Мир** — `news.enabled: false` → пропустить. Иначе: Feeds/WebSearch → заголовки + URL. Субагент Haiku анализирует + топ-5 РП → «Вывод: 2-4 предложения» в начале секции.

**6b. Требует внимания** — собрать из шагов 1–6. Нет → не выводить.

**6b2. Разметка ТВС** — пометить каждый РП: Текущее / Важное / Срочное. Хотя бы один Важного обязателен. Срочное — только угроза остановки конвейера.

**6c. Extensions (after)** — `bash .claude/scripts/load-extensions.sh day-open after` → Exit 0: выполнить. Exit 1: пропустить.

**7. Запись** — ⚠️ перед 7a и 7d: `Read day-open/templates.md`. Не найден → стоп, сообщить пилоту.
- **7a.** `<governance-repo>/current/DayPlan YYYY-MM-DD.md` по шаблону. Предыдущий → `archive/day-plans/`.
- **7a2.** `<governance-repo>/sessions/YYYY-MM-DD.md` — не перезаписывать если существует.
- **7b.** `bash .claude/scripts/load-extensions.sh day-open checks` → БЛОКИРУЮЩЕЕ: commit только после прохождения.
- **7c.** `git commit` + `git push`.
- **7d.** Compact dashboard → VS Code по шаблону «Шаблон compact dashboard».

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
