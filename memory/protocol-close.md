---
name: protocol-close
description: Slim-ядро протокола Close — триггеры, маршрутизация, Quick Close inline
type: reference
valid_from: 2026-04-13
originSessionId: b5655b53-7d87-478a-aad9-437479e81691
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

---

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

---

## Deferred (отложены до Day Close)

> Quick Close намеренно не включает: DayPlan, WP-REGISTRY, Verification Gate, отчёт.
> KE включён (шаг 2.5) — знание теряется при откладывании на Day Close.
> Причина (ADR-207): атомарные шаги выполняются всегда > длинный список, из которого половина пропускается.

---

## Exit Protocol (при завершении любой роли)

| # | Шаг | Что делать |
|---|-----|-----------|
| 1 | **Артефакт** | Зафиксировать результат (коммит, файл, запись) |
| 2 | **Статус** | Обновить трекер (MEMORY.md, WP context) |
| 3 | **Уведомление** | Сообщить следующему (пользователь, агент, Стратег) |
