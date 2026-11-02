#!/bin/bash
# Close Gate Reminder Hook (v3 — Day Close via /run-protocol)
# Event: UserPromptSubmit
# Day Close → DIRECT INSTRUCTION to call /run-protocol day-close (not a reminder).
# Session Close → compact checklist.
# Read-only: only JSON additionalContext.
# Version: 2026-04-03. Fix: a multiline prompt broke jq (6th incident, Apr 3).

INPUT=$(cat)
# Resilience to multiline prompts: a literal \n in a JSON value
# is invalid for jq. Replace all control chars with spaces before parsing.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Close → FORCED call of /run-protocol
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
