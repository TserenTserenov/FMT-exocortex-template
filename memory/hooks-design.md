---
name: hooks-design
description: Принципы проектирования хуков IWE — trigger = artifact, не TOOL_INPUT текст
type: reference
valid_from: 2026-04-27
originSessionId: WP-273-stage-2
---
# Hooks Design Principles

> **Источник:** WP-273 R4.5 fix (Round 4 red-team Евгения, 26 апр).
> **Применимо:** все hooks в `.claude/hooks/*.sh`.

## Принцип 1. Trigger = artifact, НЕ TOOL_INPUT текст

**Антипаттерн:**
```bash
# ПЛОХО: trigger по тексту команды
if ! echo "$TOOL_INPUT" | grep -q 'DayPlan\|day-close\|WeekPlan'; then
    exit 0
fi
```

**Проблема:** TOOL_INPUT включает path'ы в `git add`, commit messages, file content в `cat <<EOF`. Поэтому commit файла `.claude/skills/day-close/SKILL.md` или commit message «fix day-close ordering» триггерит DayPlan-validation, хотя DayPlan не меняется. Это false positive — пользователь блокируется на нерелевантной проверке.

**Правильно:**
```bash
# ХОРОШО: trigger по staged files (фактический артефакт)
STAGED=$(cd "$GOV_PATH" && git diff --cached --name-only 2>/dev/null || echo "")
if ! echo "$STAGED" | grep -qE '^current/DayPlan.*\.md$|^current/WeekPlan.*\.md$'; then
    exit 0
fi
```

**Почему:** артефакт (что изменяется) ≠ намерение (что в команде). Hook валидирует артефакт, не текст. Точно так же linter не запускается на путях, упомянутых в commit message.

**Применимо:** PreToolUse hooks, особенно с matcher: Bash + git operations.

## Принцип 2. Граница ответственности hook'а

Hook должен:
- ✅ Валидировать ОДИН класс артефактов (DayPlan, WeekPlan, ...) — single responsibility
- ✅ Возвращать chunked decision (block/warn/ok) с конкретной причиной
- ❌ НЕ модифицировать файлы (read-only по контракту PreToolUse)
- ❌ НЕ вызывать сетевые операции (медленно + race condition)

## Принцип 3. Идемпотентность

Hook должен возвращать одинаковый результат при повторном вызове на том же state. Если hook зависит от внешнего состояния (env-var, git-status) — это часть его trigger; если от runtime семантики (random, timestamp) — антипаттерн.

## Принцип 4. Fail open для не-блокирующих проверок

Если hook не может определить (например, нет `jq`, или `$IWE_GOVERNANCE_REPO` не задан) — `echo '{}'; exit 0`, не блокировать. Лучше пропустить валидацию, чем заблокировать commit пользователя на инфраструктурном сбое.

## Применение

- Все новые hooks → следовать принципам 1-4
- Все существующие hooks → проверить через `integration-contract-validator.sh` (детектор Ф12.5 — grep `TOOL_INPUT.*grep` в `.claude/hooks/*.sh`)
- При нарушении: рефакторинг как в `protocol-artifact-validate.sh` (R4.5 fix, WP-273 commit 0.29.0)
