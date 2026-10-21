---
name: day-open
description: "Day Open protocol. Collects yesterday's commits, issues, notes, calendar, bot QA, Scout, world events — builds DayPlan and compact dashboard."
argument-hint: ""
version: 1.1.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/day-open]
  phrases: [открывай]
routing:
  executor: sonnet
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** Плановик (DP.ROLE.066) ведёт план дня; Стратег (R1) подключается при пересмотре приоритетов. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо и upstream без push-доступа.
> **Шаблоны:** `.claude/skills/day-open/templates.md` (читать перед шагами 7a и 7d).
> **Детали шагов:** `day-open/day-open-details.md`

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Блокирующее требование — наблюдаемое свойство: **ни один шаг не пропущен молча**; каждый шаг отмечается ДО перехода к следующему.
Инструмент по умолчанию — список задач сессии (TodoWrite): каждый шаг → отдельная задача (pending → in_progress → completed).
**TodoWrite недоступен в сессии** (на моделях новее Sonnet 4.6 клиент по умолчанию не выдаёт этот инструмент — включается переменной `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` в `env` настроек, issue #1216) → НЕ останавливаться и НЕ вести протокол «в уме»: сообщить пилоту одной строкой («пошаговый контроль без TodoWrite — веду явную нумерацию»), вести шаги явной нумерацией в ответах («Шаг X из Y: <название> — выполнен») с отметкой каждого перед переходом к следующему, факт замены зафиксировать в отчёте открытия дня.
Шаг невозможен → blocked (не пропускать молча).
**Почему:** без явного трекинга агент пропускает шаги из-за загрязнения контекста (SOTA.002). Правило сформулировано через свойство, а не через конкретный инструмент: доступность инструментов контролирует клиент, не шаблон (issues #561, #563).

## Алгоритм

### 0. Extensions (before)
`bash .claude/scripts/load-extensions.sh day-open before` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.
<!-- Детали: day-open-details.md § Шаг 0 -->

### 0а. Session-guard: привязка к РП-1 (S-68 — каждый коммит обязан нести реальный РП)
Day Open сам по себе не рабочий продукт, но `session-open-gate.sh` (S-68) не делает для него исключения — коммит шага 7c без привязки к `--wp` будет отклонён. Если сессия уже привязана к другому РП, вторая привязка не нужна:
```bash
HARNESS_ID="${CLAUDE_CODE_SESSION_ID:-}"
SESSION_DIR="${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
ALREADY_BOUND=0
if [ -n "$HARNESS_ID" ]; then
  while IFS= read -r sem; do
    [ -z "$sem" ] && continue
    grep -qE '^wp: .+' "$sem" 2>/dev/null && { ALREADY_BOUND=1; break; }
  done < <(grep -lxF "harness_session_id: $HARNESS_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
fi
[ "$ALREADY_BOUND" = 1 ] || bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --housekeeping day-open --agent "$AGENT" 2>&1 || true
```
`session-open-gate.sh` принимает `housekeeping: day-open` как легитимную привязку — это закрытый список из 4 операционных протоколов, не произвольная причина (S-68 запрещает именно произвольные `--housekeeping`-обходы, не эти четыре). Отказ открытия (коллизия с параллельной сессией) не блокирует протокол.

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
Единый источник — подключённый календарный коннектор (MCP-инструменты календаря; имена зависят от установки, имя содержит «calendar» без учёта регистра, напр. `mcp__claude_ai_Google_Calendar__*`): список календарей → события каждого за день → секция «Календарь» для DayPlan (Встречи + Напоминания).
Если коннектора нет — фоллбэк: `bash $IWE_SCRIPTS/server-calendar.sh YYYY-MM-DD`. NB: его ответ «Google credentials не настроены» — факт о скрипте (он ходит за собственным файлом ключей `~/.secrets/google-calendar`), не о календаре; при работающем коннекторе скрипт не нужен (issue #581).
Если `strategy_day`: та же логика для недели (у фоллбэка — `--week YYYY-MM-DD`) → секция «Календарь недели» в WeekPlan.
<!-- Детали (алгоритм классификации, формат): day-open-details.md § Шаг 4c -->

### 5. IWE за ночь (светофор)
`(cd "$IWE_TEMPLATE" && bash update.sh --check --fast)` + проверка Base-репо (FPF, SPF, ZP) на отставание от origin. Обновления → «Требует внимания». Scout report не проревьюен → «Требует внимания».
<!-- Детали (bash-скрипты): day-open-details.md § Шаг 5 -->

### 5a2. Видео
`video.enabled: true` → показать только новые файлы за сегодня (`-mtime 0`). `false` → пропустить.
<!-- Детали: day-open-details.md § Шаг 5a2 -->

### 5c. Редактор контента
`content_editor.enabled: true` → топ-3 черновика из `drafts/` по актуальности/свежести/полноте → таблица в DayPlan. Сигнал готовых постов → «Требует внимания». Любое другое значение, включая отсутствие секции `content_editor` (issue #804) → пропустить.
<!-- Детали (полный алгоритм оценки): day-open-details.md § Шаг 5c -->

### 6. Мир
`news.enabled: false` → пропустить. Иначе: Feeds/WebSearch → заголовки с URL. Субагент Haiku (context isolation) анализирует заголовки + топ-5 РП → «Вывод: 2-4 предложения» в начале секции.
<!-- Детали (промпт субагента, формат секции): day-open-details.md § Шаг 6 -->

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6b2. Разметка ТВС
Пометить каждый РП режимом Текущее / Важное / Срочное. Хотя бы один блок Важного обязателен. Срочное — только угроза остановки конвейера.
<!-- Детали (правила ТВС, различения): day-open-details.md § Шаг 6b2 -->

### 6c. Extensions (after)
`bash .claude/scripts/load-extensions.sh day-open after` → Exit 0: Read каждый файл, выполнить. Exit 1: пропустить.

### 7. Запись

> ⚠️ **Перед шагами 7a и 7d:** `Read .claude/skills/day-open/templates.md`. Файл не найден → сообщить пилоту, не продолжать.
> Прочитать `params.yaml → multiplier_enabled` (нет ключа = `true`). При
> `false` выбрать только ветки `multiplier:off`: не выводить физическое время,
> WakaTime, плановый/фактический мультипликатор и соответствующую подсекцию Week Close.

**7a.** DayPlan: `<governance-repo>/current/DayPlan YYYY-MM-DD.md` по шаблону из `templates.md`. Предыдущий → `archive/day-plans/`.
**7a2.** Session Log: `<governance-repo>/sessions/YYYY-MM-DD.md`. Если существует — не перезаписывать.
<!-- Шаблон Session Log: day-open-details.md § Шаг 7a2 -->
**7b.** `bash .claude/scripts/load-extensions.sh day-open checks` → Exit 0: выполнить верификацию. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения всех checks.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code по шаблону «Шаблон compact dashboard» из `templates.md`.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
