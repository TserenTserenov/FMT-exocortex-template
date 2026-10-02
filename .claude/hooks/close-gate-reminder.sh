#!/bin/bash
# Close Gate Reminder Hook (v3 — Day Close через /run-protocol)
# Event: UserPromptSubmit
# Day Close → ПРЯМАЯ ИНСТРУКЦИЯ вызвать /run-protocol day-close (не напоминание).
# Session Close → compact-чеклист.
# Read-only: только JSON additionalContext.
# Версия: 2026-04-03. Fix: multiline prompt ломал jq (6-й инцидент 3 апр).

INPUT=$(cat)
# Устойчивость к многострочным промптам: literal \n в JSON value
# невалиден для jq. Заменяем все control chars на пробелы до парсинга.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Close → ПРИНУДИТЕЛЬНЫЙ вызов /run-protocol
if echo "$PROMPT" | grep -qE '(итоги дня|закрываю день|закрывай день)'; then
  CTX="⛔ БЛОКИРУЮЩЕЕ: Day Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'day-close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='day-close'. НЕ читать protocol-close.md вручную. НЕ выполнять шаги самостоятельно. НЕ писать итоги без /run-protocol. Причина: 5 инцидентов пропуска шагов при ручном исполнении (15, 18, 19, 27 мар). /run-protocol гарантирует пошаговый TodoList + верификацию Haiku R23."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'

# Session Close → /run-protocol close
elif echo "$PROMPT" | grep -qE '(закрывай|закрываю|заливай|запуши|закрывай сессию)'; then
  CTX="⛔ БЛОКИРУЮЩЕЕ: Session Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='close'. НЕ выполнять шаги самостоятельно. /run-protocol гарантирует пошаговый TodoList + верификацию."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'

else
  echo '{}'
fi
exit 0
