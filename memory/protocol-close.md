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

## Маршрутизация

| Триггер | Аргумент | Skill |
|---------|---------|-------|
| «закрываю сессию» / «всё» / «закрывай» | `close` или `close session` | Quick Close (ниже, inline) |
| «закрываю день» / «итоги дня» | `close day` | `.claude/skills/day-close/SKILL.md` |
| «закрываю неделю» / «итоги недели» | `week-close` | `.claude/skills/week-close/SKILL.md` |

> **`close` без уточнения** → Quick Close (сессия) по умолчанию.


## Quick Close (сессия, inline)

> **Роль:** R6 Кодировщик. **Бюджет:** ~3 мин. **Без TodoWrite** — намеренно, цель минимальный барьер.
> «Закрывай» = push сразу без вопросов (пользователь дал согласие словом).
> **Day Close ≠ Quick Close.** Day Close самодостаточен — Quick Close внутри него не повторять.

### Шаги (4 обязательных)

1. **Pre-commit checks → Commit + Push**

   **1a. Pre-commit checks (БЛОКИРУЮЩЕЕ).** `bash .claude/scripts/load-extensions.sh protocol-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/protocol-close.checks.md` И `extensions/protocol-close.checks.<suffix>.md`. **При ❌ commit запрещён** — исправить, повторить checks, только потом 1b. Семантика идентична Day/Week Close (см. `run-protocol/SKILL.md` Шаг 1b).

   **1b. Commit + Push.** После прохождения checks все изменения зафиксированы и запушены.

2. **WP Context File** — обновить секцию «Осталось» (structured формат):
   - in_progress → structured handoff
   - done → пометить `status: done`
   - Незавершённое → context file. Идея → `MAPSTRATEGIC.md`. Зерно → `drafts/draft-list.md`

2.5. **KE** — прочитать поле «Что узнали» в «Осталось». Маршрутизировать СЕЙЧАС:
   - правило (1-3 строки) → `CLAUDE.md` или `distinctions.md`
   - доменное знание → Pack (конкретный файл)
   - урок → `memory/lessons_*.md` + строка в MEMORY.md
   - нет нового знания → пропустить молча (анонс не нужен)
   Анонс при маршрутизации: *«Capture: [что] → [куда]»*

2.6. **Session-Close Feeder (WP-247 Ф-MULTI-SOURCE.1, авто >30мин / opt-in для коротких):**
   Дополняет Шаг 2.5: вызывает R2 в feeder-режиме для автоматического захвата кандидатов из транскрипта сессии + git diff в `captures.md`.

   **Триггер автозапуска:** длительность сессии >30 мин (по timestamps первого и последнего сообщения). Иначе — пропустить (юзер может вызвать вручную: `/ke session-close-feed`).

   **Действие:** `bash {{IWE_RUNTIME}}/roles/extractor/scripts/extractor.sh session-close-feed`. Скрипт пишет ###-блоки с маркером `[feed:session-close YYYY-MM-DD]` в `captures.md`. Идемпотентно (не дублирует за тот же день).

   **Что НЕ делает:** не создаёт extraction-report (это работа inbox-check), не показывает пользователю кандидатов сразу (увидит при следующем `/apply-captures`).

   **Защита от дубля:** если за сессию уже был ручной `/ke` или `/apply-captures` — feeder пропустить (по маркерам в текущем `captures.md`).

3. **MEMORY.md** — обновить статус РП (одна строка: `in_progress` / `done`)

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

### Верификация Quick Close (Haiku R23)

> Условный шаг: если `params.yaml → verify_quick_close: false` → пропустить.
> Исключения: сессия ≤15 мин, сессия-вопрос без изменений файлов.

Запустить sub-agent Haiku в роли R23 (context isolation). Передать: чеклист, WP context «Осталось», `git diff --name-only`.

### Чеклист Quick Close

- [ ] Всё закоммичено и запушено
- [ ] WP Context: «Осталось» записано (или done помечен)
- [ ] KE: «Что узнали» маршрутизировано (или «нет нового знания»)
- [ ] MEMORY.md: статус РП обновлён
- [ ] Decision log: прочитать записи сессии в `decisions/decision-log-YYYY-MM.md`, скорректировать если неточно
- [ ] **Docs Gate (условный):** РП затрагивал поведение онбординга (skills, MCP-сервисы, бот `/start`)? → обновить онбординг-документацию в governance-репо + `/verify` обновлённый файл. Владелец: пользователь. Если не затрагивал → пропустить молча.


## Week Close (Неделя)

> **Роль:** R1 Стратег. **Бюджет:** ~20-30 мин. **Триггер:** «закрываю неделю» / `/week-close`.
> Выполняется через `.claude/skills/week-close/SKILL.md` + платформенные шаги.

### Шаги Week Close

1. **Бэкап + грязные репо** — `backup-icloud.sh` + `check-dirty-repos.sh` (платформа)
2. **Memory Validate** — `memory-bleed.sh` (HOT-лимит, orphans, superseded_by)
3. **ТО памяти (T, SC.024.3)** — проверка здоровья статической нагрузки:
   - `wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md` → **> 80 строк = drift-флаг** (по правилу DP.KR.001 §6: 1-3 строки на различение). Предложить аудит в WP-7.
   - `wc -l ~/.claude/projects/{{CLAUDE_PROJECT_SLUG}}/memory/MEMORY.md` → **> 200 строк = флаг** (превышен лимит).
   - Feedback/lessons файлы в `memory/` с `mtime > 14 дней` без обращения → предложить понизить `horizon: warm`.
   - Флаги — информативно. Пользователь решает действие.
4. **iwe-drift.sh** — полный drift-отчёт в Week Report (S)
5. **STAGING.md** — есть `validated`? → предложить промоцию (S+T)
6. **iwe-rules-review** — какие правила обходились? (S)
7. **R-вопросник** (5-7 вопросов, `memory/r-questionnaire.md`) → ответы в Week Report
8. **Архивация done-WP** → `archive/wp-contexts/` (T)
9. **Обновить WeekPlan** — пометить итоги, создать carry-over секцию

### Симптом пропуска Week Close

- STAGING.md заморожен ≥2 недель с `validated`
- distinctions.md > 80 строк без флага в Week Report
- Week Report без R-ответов
- MEMORY.md > 200 строк уже 2+ недели подряд

## Deferred (отложены до Day Close)

> Quick Close намеренно не включает: DayPlan, WP-REGISTRY, Verification Gate, отчёт.
> KE включён (шаг 2.5) — знание теряется при откладывании на Day Close.
> Причина (ADR-207): атомарные шаги выполняются всегда > длинный список, из которого половина пропускается.


## Exit Protocol (при завершении любой роли)

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** | Обновить трекер (MEMORY.md, WP context) |
| 3 | **Уведомление** | Сообщить следующему (пользователь, агент, Стратег) |
