---
name: day-open
description: "Протокол открытия дня (Day Open). Собирает вчерашние коммиты, issues, заметки, календарь, бота QA, Scout, мир — формирует DayPlan и compact dashboard."
argument-hint: ""
version: 1.1.0
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо (CLAUDE.md) и upstream без push-доступа (Base, чужие fork).
> **Шаблоны:** ниже (после алгоритма).

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
Каждый шаг алгоритма ниже → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).
**Почему:** без TodoWrite агент пропускает шаги из-за загрязнения контекста (SOTA.002).

## Алгоритм

### 0. Extensions (before)
Проверить: `ls extensions/day-open.before.md`. Если существует → `Read extensions/day-open.before.md` → выполнить содержимое как первые шаги. Не существует → пропустить.

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

### 1c. Заметки
`DS-my-strategy/inbox/fleeting-notes.md` → категоризация: → РП / → Backlog / → Контент / → Pack / → Обсудить / → Шум. НЕ удалять.
**Carry-over заметок из вчерашнего DayPlan:** проверить по git log (`note-review`), были ли обработаны. Если да → секция «Разбор заметок» = «все обработаны» (с ссылкой на коммит). Не переносить обработанные заметки как carry-over.
**Гиперссылки на заметки (БЛОКИРУЮЩЕЕ):** каждая заметка в секции «Разбор заметок» DayPlan — markdown-ссылка на её источник (`inbox/fleeting-notes.md` для свежих, `archive/notes/Notes-Archive.md#L<line>` для обработанных, `inbox/captures.md` для знания). Причина: после Note-Review сама заметка исчезает из fleeting-notes.md, и без ссылки суть заметки теряется через день. Формат строки таблицы: `[«заголовок»](путь#L<line>) (DD мес HH:MM)`.
**Знаниевые заметки = кандидаты (БЛОКИРУЮЩЕЕ):** заметки категории «Знание доменное» без явного маркера «Экстрактору» в тексте → в DayPlan секция «Разбор заметок» таблицей **Кандидаты Экстрактору** с колонками «Заметка | Тип | Предполагаемый Pack | Действие». Решение «отдать / оставить» принимает пользователь в живом разборе. Note-Review в `captures.md` пишет ТОЛЬКО при явном маркере. Причина: `captures.md` = очередь Экстрактора; любое знание туда = неявное согласие на формализацию, которое Note-Review делать не уполномочен.

### 2. План на сегодня
**Приоритет входов (строгий порядок):**
1. **Carry-over из Day Close (БЛОКИРУЮЩЕЕ):** ВСЕ РП из секции «Завтра начать с» → в план без обрезки. Это решение пользователя — Day Open не фильтрует и не сокращает этот список
2. **WeekPlan (ОБЯЗАТЕЛЬНО):** прочитать WeekPlan → ВСЕ in_progress и pending РП → проверить каждый: релевантен сегодня? Есть дата/дедлайн сегодня? Просрочен? → добавить.
   **Budget Spread** (если `budget_spread.enabled: true` в day-rhythm-config.yaml): для каждого РП с бюджетом ≥ `threshold_h` (колонка «h» в таблице WeekPlan):
   - `days_left` = оставшиеся рабочие дни пн–пт включая сегодня
   - `daily_slot` = round(budget_week / days_left, `rounding`)
   - Нет бюджета в WeekPlan → пропустить, добавить в «Требует внимания»
   - РП уже в плане (carry-over) → взять max(carry_over_budget, daily_slot)
   - Иначе → добавить с daily_slot
   Не ограничиваться «2-4 штуки» — план дня отражает реальную нагрузку
3. **MEMORY.md → «РП текущей недели»:** сверить — нет ли РП, упущенных в WeekPlan (ad-hoc, reopened)
4. `day-rhythm-config.yaml → mandatory_daily_wps` — обязательные РП (проверить наличие в плане, если нет → добавить)

**Слот 1 = саморазвитие.**
Mandatory РП отсутствуют в WeekPlan → «Требует внимания».

### 3. Саморазвитие
Руководство, где остановился, черновики (`DS-my-strategy/drafts/`).

### 4. Стратегирование
Если strategy_day → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

### 4b. Помидорки
Из `day-rhythm-config.yaml → pomodoro`.

### 4c. Календарь
Из `day-rhythm-config.yaml → calendar_ids` (если указаны) или все доступные календари → list-events → свободные блоки ≥1h (09:00–19:00). Private — пропустить.

### 5. IWE за ночь (светофор)
Scheduler report, update.sh, template-sync, MCP reindex, Scout. 🟢/🟡/🔴.

**Проверка обновлений:** `cd "$IWE_TEMPLATE" && bash update.sh --check 2>&1`. Если доступно обновление → добавить в «Требует внимания»: «Доступно обновление IWE → `/iwe-update`».

**Проверка Base-репо (FPF, SPF, ZP):**
```bash
for repo in FPF SPF ZP; do
  dir="$IWE_WORKSPACE/$repo"
  [ -d "$dir/.git" ] && (cd "$dir" && git fetch --quiet 2>/dev/null && behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0) && [ "$behind" -gt 0 ] && echo "$repo: $behind новых коммитов" || echo "$repo: актуален")
done
```
Если есть новые коммиты → добавить в «Требует внимания»: «[repo] обновлён upstream → `cd "$IWE_WORKSPACE/[repo]" && git pull --rebase`». После pull FPF/SPF → reindex: `bash "$IWE_WORKSPACE/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh" FPF` (или SPF).

### 5a2. Видео
Если `day-rhythm-config.yaml → video.enabled: true`:
1. Сканировать директории из `video.directories` на файлы с расширениями из `video.extensions`
2. Показать ТОЛЬКО новые записи за сегодня (`-mtime 0`). Старые файлы — не оповещать (архивный долг, не daily concern)
3. Есть новые → «N новых видеозаписей сегодня (X ГБ)». Нет → «0 новых записей сегодня»
4. `video.enabled: false` → пропустить

### 5b. Бот QA
Feedback-triage report: `DS-agent-workspace/scheduler/feedback-triage/YYYY-MM-DD.md`. Проверить дату файла. Фильтр 2 дня. Нет файла → «нет отчёта». Дельта, urgent.

### 5c. Контент
Стратегия маркетинга + draft-list. 1-3 темы.

### 5d. Scout
Scout report. Не проревьюен → «Требует внимания».

### 6. Мир
`day-rhythm-config.yaml → news`. Feeds/WebSearch. `enabled: false` → пропустить.
**Ссылки на источники обязательны** (URL).

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6c. Extensions (after)
Проверить: `ls extensions/day-open.after.md`. Если существует → `Read extensions/day-open.after.md` → выполнить содержимое (smoke-тесты, Scout gate, доп. проверки). Не существует → пропустить.

### 7. Запись
**7a.** Записать DayPlan: `DS-my-strategy/current/DayPlan YYYY-MM-DD.md` по шаблону ниже. Предыдущий → `archive/day-plans/`.
**7b.** Проверить: `ls extensions/day-open.checks.md`. Если существует → `Read extensions/day-open.checks.md` → выполнить верификацию. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения checks.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code по шаблону ниже.

---

## Шаблон DayPlan

> **Стиль:** collapsible, без `---`, `<b>` в summary. Приоритет = светофор (🔴🟡🟢). Результат = краткое название из Strategy.md.

```markdown
---
type: daily-plan
date: YYYY-MM-DD
week: W{N}
status: active
agent: Стратег
---

# Day Plan: DD месяца YYYY (День недели)

<details open>
<summary><b>План на сегодня</b></summary>

| 🚦 | # | РП | h | Статус | Результат |
|----|---|-----|---|--------|-----------|
| ⚫ | N | **Саморазвитие** — [тема] | 1-2 | pending | — |
| 🔴 | ... | **Название** | X | in_progress | Краткое название |

**Бюджет дня:** ~Yh РП всего / ~Xh физ / Плановый мультипликатор ~N.Nx

</details>
<details>
<summary><b>Календарь (DD месяца)</b></summary>

| Время | Событие | Длит. | Связь с РП |
|-------|---------|-------|------------|
| HH:MM | Название | Xh | WP-N / — |

⏱ Свободных блоков ≥1h: [слоты]

</details>
<details>
<summary><b>Здоровье бота (QA)</b></summary>

**Дельта:** Сегодня: N (↑↓X vs вчера) | За 7д: N (↑↓X vs пред. 7д)

| # | Вопрос | Sev | Cluster | Дата |
|---|--------|-----|---------|------|

</details>
<details>
<summary><b>IWE за ночь (светофор)</b></summary>

| Подсистема | Статус | Детали |
|------------|--------|--------|
| Scheduler | 🟢/🟡/🔴 | [детали] |
| template-sync | 🟢/🔴 | [статус] |
| Scout | 🟢/🟡/🔴 | [N находок] |

</details>
<details>
<summary><b>Наработки Scout (разбор)</b></summary>

> Отчёт за DD мес — N находок, M capture-кандидатов
> **Статус ревью:** ⬜ не проверен / ✅ проверен

**Ожидают разбора:** N captures за последние DD дней (без ревью).

</details>
<details>
<summary><b>Разбор заметок</b></summary>

> Источник: Note-Review (вчера) или мини-триаж (Day Open шаг 1c).
> **Если все обработаны** (проверить git log `note-review`) → написать: «Все заметки обработаны (коммит HASH, N заметок). Carry-over: нет.»
> **Если есть необработанные** → таблица ниже. Неразобранное переносится в следующий DayPlan.

| Заметка | Тип | Предложение | ✅ |
|---------|-----|-------------|---|
| «текст» | НЭП / Задача / Черновик / Знание / Шум | → куда | [ ] |

</details>
<details>
<summary><b>Итоги вчера (DD мес)</b></summary>

**Коммиты:** N в M репо | **РП закрыто:** N

</details>

*Создан: YYYY-MM-DD (Day Open)*
```

## Шаблон compact dashboard (VS Code)

> Короткая сводка для быстрого старта. Подробности — в DayPlan (git).

```markdown
## DD месяца YYYY (День недели) — Day Open

**Вчера:** N РП done, N коммитов. Ключевое: #X [название], #Y [название]
**Issues:** N открытых в M репо [самые свежие: #X repo, #Y repo]
**Бот:** N новых жалоб (↑↓X vs вчера), M urgent открыто (самые старые ≤дата)
**Календарь:** [события через запятую или «свободен»]
**Бюджет:** W{N}: ~Zh РП / ~Yh физ | Сегодня: ~Zh РП / ~Yh физ
**ТОС:** [узкое горлышко] | Прогресс: R1 ✅/🔄/⏳, R2 ...

### План дня

| 🚦 | # | РП | h |
|----|---|-----|---|
| ⚫ | N | **Саморазвитие** — [тема] | 1 |
| 🔴 | ... | **Название** | X |

### Требует внимания

1. [пункт — если есть]

*Нет пунктов → секция не выводится.*

> Подробно: [DayPlan YYYY-MM-DD](ссылка на git)
```

## Шаблон WeekPlan

> **Стиль:** collapsible, без `---`, `<b>` в summary. Приоритет = светофор (🔴🟡🟢). Результат = краткое название из Strategy.md (не ID).
> **Бюджет:** формат `~Zh РП всего (в том числе Xh на R1-R{N}) / ~Yh физ / Плановый мультипликатор ~N.Nx`. Активные — **жирным**. Done — зачёркнуть: `| ~~#~~ | ~~название~~ | ... |`

```markdown
---
type: week-plan
week: W{N}
date_start: YYYY-MM-DD
date_end: YYYY-MM-DD
status: draft
agent: Стратег
---

# WeekPlan W{N}: DD мес — DD мес YYYY

<details open>
<summary><b>План на неделю W{N}</b></summary>

**Фокус:** [1 предложение]
**Бюджет:** ~Zh РП всего (в том числе Xh на R1-R{N}) / ~Yh физ / Плановый мультипликатор ~N.Nx

> 🔴 критический 🟡 средний 🟢 низкий

| 🚦 | # | РП | h | Статус | Результат |
|----|---|-----|---|--------|-----------|
| 🔴 | ... | **Название** — описание | X | in_progress | Краткое название |

**Сводка:** N РП, Xh. 🔴 Xh (N) 🟡 Xh (N) 🟢 Xh (N)
**Off-plan:** [список]

</details>
<details>
<summary><b>Итоги прошлой недели W{N-1}</b></summary>

**Выполнение:** X/Y РП (Z%)
**Перенос:** [список]
**Ключевые выводы:** [2-3 пункта]

</details>
<details>
<summary><b>Стратегическая сверка</b></summary>

| ID | Результат | Бюджет | Статус | Связанные РП |
|----|-----------|--------|--------|-------------|
| R1 | ... | ... | ... | WP-X, WP-Y |

**ТОС-месяца:** [узкое горлышко]
**Расхождения:** [план vs факт]

</details>
<details>
<summary><b>Повестка сессии стратегирования</b></summary>

- [ ] Ревью прошлой недели
- [ ] Inbox Triage (недельный)
- [ ] НЭП: проверить O1-O{N}
- [ ] Стратегическая сверка
- [ ] Видео-ревью (С3)
- [ ] Проверка активации + ревью спящих

### Вопросы для обсуждения
1. ...

</details>
<details>
<summary><b>Inbox Triage (недельный)</b></summary>

[из fleeting-notes, unsatisfied-questions, WP context files]

</details>
<details>
<summary><b>Контент-план W{N}</b></summary>

1. **#NNN Название** — канал, бюджет, дедлайн

</details>
<details open>
<summary><b>План на понедельник DD мес</b></summary>

| 🚦 | # | РП | h | Результат |
|----|---|-----|---|-----------|

</details>

*Создан: YYYY-MM-DD (Strategy Session)*
```
