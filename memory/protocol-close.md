---
name: protocol-close
description: Slim-ядро протокола Close — триггеры, маршрутизация, Quick Close inline
type: reference
valid_from: 2026-04-13
originSessionId: b5655b53-7d87-478a-aad9-437479e81691

horizon: warm
domains: [protocol]
status: active
owner: user
schema_version: 1
---
# Протокол Close (ОРЗ-фрактал)

> **Три масштаба:** Сессия (Quick Close), День (Day Close), Неделя (Week Close).
> **Точка входа:** Вызвать Skill `run-protocol` с нужным аргументом (см. таблицу ниже).
> **Принцип:** Quick Close = «не потерять» (inline, без TodoWrite, ~3 мин). Day/Week Close = через SKILL.md + TodoWrite (принудительное исполнение).
> **CGUS (WP-481 Ф5):** порядок шагов = порядок удержания внимания, НЕ порядок исполнения. `[[gate]]`/`[[gate:AR.NNN]]` = предусловие (блокирует); `[[narrative]]` = демонстрационный порядок (skippable). Close проверяет удовлетворённость набора gate, не линейность прохождения.

## Маршрутизация

| Триггер | Аргумент | Skill |
|---------|---------|-------|
| «закрываю сессию» / «всё» / «закрывай» | `close` или `close session` | Quick Close (ниже, inline) |
| «закрываю день» / «итоги дня» | `close day` | `.claude/skills/day-close/SKILL.md` — **шаг 6: WakaTime + Мультипликатор IWE** |
| «закрываю неделю» / «итоги недели» | `week-close` | `.claude/skills/week-close/SKILL.md` |

> **`close` без уточнения** → Quick Close (сессия) по умолчанию.


## Quick Close (сессия, inline)

> **Роль:** R6 Кодировщик. **Бюджет:** ~3 мин. **Без TodoWrite** — намеренно, цель минимальный барьер.
> «Закрывай» = push сразу без вопросов (пользователь дал согласие словом).
> **Day Close ≠ Quick Close.** Day Close самодостаточен — Quick Close внутри него не повторять.

### Раннер — если есть (WP-482 Ф3+Ф5, дефолт с 17.07 у пилота; личная инфраструктура, в шаблоне не поставляется)

> Если у вас есть свой раннер по контракту `quick-close.yaml` (типизированное описание шагов ниже) — используйте, первым действием Quick Close:
> ```bash
> cd ${IWE_GOVERNANCE_REPO:-DS-strategy} && python3 scripts/process-runner.py start quick-close --slug <slug сессии> \
>   --input '{"agent":"<agent>","slug":"<slug>","session_file":"<путь или null>","repos":["<repo1>", ...]}'
> ```
> Раннер сам ведёт по шагам ниже и останавливается на каждом `pilot`/`ai`/`requires_input`; отвечать `process-runner.py next <run_id> --input '{...}'`, используя текст под каждым шагом как содержание ответа (какой JSON собрать), не как отдельный ручной прогон в обход раннера. Шаг раннера указан в скобках при каждом пункте ниже.
>
> **Три пункта чеклиста раннер пока не покрывает** (нет для них шага в `quick-close.yaml`) — выполнять вручную, как раньше: Decision log (п. ниже), Docs Gate (условный), conversational-report. Раннер их не подменяет, не пропускать из-за того, что появился раннер.

**Нет раннера** (типовая установка) — выполнять шаги 1-2.6+ ниже вручную по тексту; названия шагов раннера в скобках — справочные, не требуют самого раннера.

### Шаги (4 обязательных)

1. **Pre-commit checks → Commit + Push** (шаги раннера `precommit-checks` → `commit-push` → `commit-push-check`)

   **1a. Pre-commit checks (БЛОКИРУЮЩЕЕ, шаг `precommit-checks`).** `bash .claude/scripts/load-extensions.sh protocol-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/protocol-close.checks.md` И `extensions/protocol-close.checks.<suffix>.md`. **При ❌ commit запрещён** — исправить, повторить checks, только потом 1b. Семантика идентична Day/Week Close (см. `run-protocol/SKILL.md` Шаг 1b). [[gate]]

   **1b. Commit + Push (БЛОКИРУЮЩЕЕ, шаг `commit-push`, вход `{"commits":[{"repo","paths","message"}, ...]}`).** `git status --short` по ВСЕМ репо, которых касалась сессия (не только governance). Незафиксированные изменения → `git add <specific paths>` → commit → push (раннер делает это через хендлер, не руками в обход). Затем убедиться что `git status` чист. Провал push → раннер сам стоит на `blocked-push-failed`, не идти дальше в обход. [[gate:AR.005]]

   **1c. Session Index (шаг `session-index`/`session-index-write`, раннер маршрутизирует по наличию `session_file` сам — WP-7, 07.07, фикс недосчёта одиночных сессий).** Если сессия зафиксирована файлом `sessions/YYYY-MM-DD-<тема>.md` (не folder-структура peer-conversation, у той регистрацию уже делает `peer-session-finalize.sh`) — добавить строку в `sessions/00-index.md`: `Агенты` = только исполнявший агент (без пары), `Ходы`/`Эскал` = `—`, `Отчёт` = ссылка на сам файл сессии. Причина: Day Close считает мультипликатор по этому индексу как по полному журналу дня (§ Мультипликатор IWE ниже) — без этой строки одиночные сессии выпадают из расчёта бюджета. [[narrative]]

2. **WP Context File (БЛОКИРУЮЩЕЕ, факт а не шаблон, шаг `wp-context-update` — ai-контракт: вход `[git_diff, session_summary]`, выход `[status, what_tried, what_learned, what_next]`)** — обновить секцию «Осталось» (structured формат): [[gate]]
   - in_progress → structured handoff
   - done → пометить `status: done` **→ и немедленно архивировать (шаг `wp-archive-run`, вход `{"wp","repo"}`, раннер зовёт его сам после `wp-archive-check`):**
     ```bash
     git mv inbox/WP-N archive/wp-contexts/WP-N   # папка
     git mv inbox/WP-N-slug.md archive/wp-contexts/WP-N-slug.md  # файл
     # patch frontmatter: status: archived, archived_at: YYYY-MM-DD
     # нет results_in → добавить results_not_captured: true
     ```
     *(Реализует DP.SC.033 инвариант: done-РП не остаётся в inbox дольше одного Day Close)*
   - Незавершённое → context file. Идея → `MAPSTRATEGIC.md`. Зерно → `drafts/draft-list.md`
   - **Обнаружено «уже сделано» во время сессии (пункт, который значился pending, но по факту закрыт раньше)** → пометить done в WP-context ПРЯМО СЕЙЧАС, не переносить на следующий Close. Запрещено писать «Осталось» шаблонной фразой без связи с тем, что реально проверено в этой сессии — R23 (ниже) это отбраковывает.
   - Source: peer-сессия [2026-07-09-17-close-actualization-gap](../DS-strategy/sessions/2026-07/2026-07-09-17-close-actualization-gap/report.md) — разрыв не в том, что Close «забывает» актуализировать, а в том, что требование факт-чека не было явным/проверяемым.

2.5. **KE (шаг `ke-routing` — ai-контракт: вход `[what_learned]`, выход `[routed_to]`)** — прочитать поле «Что узнали» в «Осталось». Маршрутизировать СЕЙЧАС: [[gate]]
   - правило (1-3 строки) → `CLAUDE.md` или `distinctions.md`
   - доменное знание → Pack (конкретный файл)
   - урок → `memory/lessons_*.md` + строка в MEMORY.md
   - нет нового знания → пропустить молча (анонс не нужен)
   Анонс при маршрутизации: *«Capture: [что] → [куда]»*

2.6. **Session-Close Feeder (шаг `session-close-feeder`/`session-close-feeder-run`, раннер сам маршрутизирует по `duration_min`; WP-247 Ф-MULTI-SOURCE.1, авто >30мин / opt-in для коротких):** [[narrative]]
   Дополняет Шаг 2.5: вызывает R2 в feeder-режиме для автоматического захвата кандидатов из транскрипта сессии + git diff в `captures.md`.

   **Триггер автозапуска:** длительность сессии >30 мин (по timestamps первого и последнего сообщения). Иначе — пропустить (юзер может вызвать вручную: `/ke session-close-feed`).

   **Действие:** `bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close-feed` (реальная shell-переменная, НЕ `{{IWE_RUNTIME}}` — тот синтаксис визуально неотличим от build-time плейсхолдеров FMT и провоцирует вызов сырого файла из `FMT-exocortex-template/`, см. `bug-2026-07-01-extractor-workspace-dir-placeholder.md`). Скрипт пишет ###-блоки с маркером `[feed:session-close YYYY-MM-DD]` в `captures.md`. Идемпотентно (не дублирует за тот же день).

   **Что НЕ делает:** не создаёт extraction-report (это работа inbox-check), не показывает пользователю кандидатов сразу (увидит при следующем `/apply-captures`).

   **Защита от дубля:** если за сессию уже был ручной `/ke` или `/apply-captures` — feeder пропустить (по маркерам в текущем `captures.md`).

3. **MEMORY.md (часть шага `memory-update` — ai-контракт: вход `[wp_status]`, выход `[memory_line]`)** — обновить статус РП (одна строка: `in_progress` / `done`) [[gate]]

### Формат «Осталось»

```markdown
## Осталось

**Что пробовали:** [краткий итог сессии — 1-2 предложения]
**Что узнали:** [решения, инсайты, изменения контекста]
  → memory: [обновить: <что именно> / не нужно]
**Что дальше:**
- [ ] [конкретный следующий шаг]
- [ ] [следующий за ним]
**Следующий шаг:** [первый unchecked из списка выше]
**Контекст для следующей сессии:** [файлы, решения, блокеры]
```

> **Правило `→ memory:`** (обязательное поле): агент явно отвечает на вопрос «нужно ли обновить MEMORY.md или memory/*.md?». Триггеры обновления: блокер снят, внешний факт изменился (чужой деплой, встреча прошла, Паша что-то починил), статус РП сменился. Если обновление нужно — сделать СЕЙЧАС, не откладывать на Day Close.

### Отчёт Quick Close

```
**РП:** #N — [название]
**Статус:** done / in_progress
**Git:** закоммичено + запушено ✅
**EXTENSION POINT (protocol-close after):** `bash .claude/scripts/load-extensions.sh protocol-close after` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/protocol-close.after.md` И `extensions/protocol-close.after.<suffix>.md`.
**Handoff:** → WP context «Осталось» обновлён / done
```

### Верификация Quick Close (Haiku R23) · [[gate:AR.007]]

> Условный шаг: если `params.yaml → verify_quick_close: false` → пропустить.
> Исключения: сессия ≤15 мин, сессия-вопрос без изменений файлов.
> **Trace-satisfaction (WP-481 Ф5.1):** перед запуском R23 — `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --section "Quick Close"` (без `--section` гейты Week Close и Exit Protocol из этого же файла попадают в проверку тоже — блок гарантирован, они не выполняются за 3-минутную сессию). Набор gate — строки с `[[gate…]]` внутри секции, ключи через `list-gates --section "Quick Close"`; исполненные отмечать `mark-gate <key>` по ходу Close. Verdict block → вернуться на незакрытый gate, потом R23. JSON вердикта приложить к вводу R23.

Запустить sub-agent Haiku в роли R23 (context isolation). Передать: чеклист, WP context «Осталось», `git diff --name-only`, краткое резюме сессии (что делали/что нашли).

**Проверка факт-соответствия (не только присутствия секции):**
1. «Осталось» не шаблонная — содержит конкретику этой сессии (конкретные файлы/решения из `git diff`), не общую фразу, годную для любой сессии.
2. Если в ходе сессии агент упоминал «уже сделано» / «оказалось done» — соответствующий пункт в WP-context помечен done, не оставлен pending.
3. Расхождение (пункт помечен pending, хотя в сессии есть явное свидетельство done) → ❌, вернуть на исправление до отчёта пользователю.
4. **Дисциплина раннера (WP-482 Ф3+Ф5, только если раннер есть в этой установке — `scripts/process-runner.py` не поставляется шаблоном).** Раннера нет → пункт неприменим, пропустить молча (не ❌). Раннер есть → карточка находится по `inbox/agent/tasks/RUN-quick-close-<slug>*.md` (slug передан явно через `--slug`, чтобы карточка была детерминированно находимой, не по случайному timestamp). Проверить: `process_id == "quick-close"` и `status` ∈ {`completed`, `failed`} (терминальный статус через раннер, не в обход него). Отдельно зафиксировать `runner_terminated_cleanly: <true при completed, false при failed>` — это метрика качества исполнения, не дисциплины, смешивать с п.3 нельзя (peer-session 2026-07-14-06-wp-482-f3-pilot, ход 3). **Раннер есть, но карточки нет → ❌** (сессия прошла в обход раннера — сам факт обхода и есть находка для отчёта, не тихий пропуск). Исключение (не ❌): сессия ≤15 мин / сессия-вопрос без изменений файлов — те же исключения, что у самой R23-проверки выше.

### Чеклист Quick Close

- [ ] Всё закоммичено и запушено
- [ ] WP Context: «Осталось» записано (или done помечен) **и отражает факт, сверенный R23 с `git diff`** — не шаблон
- [ ] KE: «Что узнали» маршрутизировано (или «нет нового знания»)
- [ ] MEMORY.md: статус РП обновлён
- [ ] Decision log: прочитать записи сессии в `decisions/decision-log-YYYY-MM.md`, скорректировать если неточно
- [ ] **Docs Gate (условный):** РП затрагивал UX или поведение онбординга (skills, MCP-сервисы, бот `/start`, тиры доступа T0-T4, имена ролей)? → проверить и обновить вводные документы в `FMT-exocortex-template/docs/` (QUICK-START, SETUP-GUIDE, onboarding/, LEARNING-PATH, IWE-HELP) + `/verify` обновлённый файл. Владелец: пользователь. Если не затрагивал → пропустить молча.
- [ ] **Conversational-сессии:** report.md создан ИЛИ status: interrupted (DP.SC.154 Q8)
- [ ] **Раннер, если есть (WP-482 Ф3+Ф5):** карточка `RUN-quick-close-<slug>*` существует и в терминальном статусе `completed`/`failed`, `runner_terminated_cleanly` зафиксирован. Раннера в этой установке нет → пункт N/A, пропустить. Раннер есть, но карточки нет → ❌, кроме исключений (сессия ≤15 мин / вопрос без изменений файлов).


## Week Close (Неделя)

> **Роль:** R1 Стратег. **Бюджет:** ~20-30 мин. **Триггер:** «закрываю неделю» / `/week-close`.
> Выполняется через `.claude/skills/week-close/SKILL.md` + платформенные шаги.

### Шаги Week Close

> **Trace-satisfaction (WP-481 Ф5.1):** `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Week Close"` (без `--section` в проверку попадают ещё и гейты Quick Close). Вызывается из `.claude/skills/week-close/SKILL.md` шаг 12, перед R23.

1. **Бэкап + грязные репо** — `backup-icloud.sh` + `check-dirty-repos.sh` (платформа) [[gate]]
2. **Memory Validate** — `memory-bleed.sh` (HOT-лимит, orphans, superseded_by) [[gate]]
3. **ТО памяти (T, SC.024.3)** — проверка здоровья статической нагрузки: [[narrative]]
   - `wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md` → **> 80 строк = drift-флаг** (по правилу DP.KR.001 §6: 1-3 строки на различение). Предложить аудит в WP-7.
   - `wc -l` по MEMORY.md текущего проекта в `~/.claude/projects/<слаг-проекта>/memory/` (слаг = путь рабочей директории, `/` → `-`) → **> 200 строк = флаг** (превышен лимит).
   - Feedback/lessons файлы в `memory/` с `mtime > 14 дней` без обращения → предложить понизить `horizon: warm`.
   - Флаги — информативно. Пользователь решает действие.
4. **iwe-drift.sh** — полный drift-отчёт в Week Report (S) [[narrative]]
5. **STAGING.md** — есть `validated`? → предложить промоцию (S+T) [[narrative]]
6. **iwe-rules-review** — какие правила обходились? (S) [[narrative]]
7. **R-вопросник** (5-7 вопросов, `memory/r-questionnaire.md`) → ответы в Week Report [[gate]]
8. **Архивация done-WP** → `archive/wp-contexts/` (T) [[gate]]
9. **Обновить WeekPlan** — пометить итоги, создать carry-over секцию [[gate]]

### Симптом пропуска Week Close

- STAGING.md заморожен ≥2 недель с `validated`
- distinctions.md > 80 строк без флага в Week Report
- Week Report без R-ответов
- MEMORY.md > 200 строк уже 2+ недели подряд

## Мультипликатор IWE (WP-299 Ф5, шаг 6 Day Close)

> **Полная спецификация → `.claude/skills/day-close/SKILL.md` § 6.**

- **WakaTime-источник:** CLI `~/.wakatime/wakatime-cli --today` → если недоступен: Neon `domain_event WHERE event_type='coding_time'` за дату (fallback).
- **Мультипликатор** = сумма бюджетов закрытых РП за день / WakaTime (сек). Формат: `N.Nx`.
- **Эмиссия:** после вычисления — `day_close` событие в domain_event, `external_id = "day-close-YYYY-MM-DD"` (ON CONFLICT DO NOTHING — идемпотентно). Payload: `{wakatime_h, multiplier, date, session_id, source}`.
- **Pending-мультипликатор (если Day Close не успел):** Day Open шаг 1 «Вчера» — при отсутствии записи `day_close` за вчера пересчитать из Neon WakaTime (WakaTime API `summaries?start={вчера}&end={вчера}`).

## Deferred (отложены до Day Close)

> Quick Close намеренно не включает: DayPlan, WP-REGISTRY, Verification Gate, отчёт.
> KE включён (шаг 2.5) — знание теряется при откладывании на Day Close.
> Причина (ADR-207): атомарные шаги выполняются всегда > длинный список, из которого половина пропускается.


## Exit Protocol (при завершении любой роли)

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** [[gate]] | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** [[gate]] | Обновить трекер (MEMORY.md, WP context) |
| 3 | **Уведомление** [[gate]] | Сообщить следующему (пользователь, агент, Стратег) |
