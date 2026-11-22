#!/bin/bash
# Close Gate Reminder Hook (v3 — Day Close via /run-protocol)
# Event: UserPromptSubmit
# Day Close → DIRECT INSTRUCTION to invoke /run-protocol day-close (not a reminder).
# Session Close → compact-checklist.
# Read-only: only JSON additionalContext.
# Version: 2026-04-03. Fix: multiline prompt was breaking jq (6-th incident 3 Apr).

INPUT=$(cat)
# Resilience against multiline prompts: literal \n in JSON value
# is invalid for jq. Replace all control chars with spaces before parsing.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Close → FORCED invocation /run-protocol
if echo "$PROMPT" | grep -qE '(end of day summary|closing the day|close the day)'; then
  CTX="⛔ BLOCKING: Day Close is executed ONLY via skill /run-protocol with argument 'day-close'. FIRST AND ONLY action = invoke Skill tool: skill='run-protocol', args='day-close'. DO NOT read protocol-close.md manually. DO NOT perform steps independently. DO NOT write summaries without /run-protocol. Reason: 5 incidents of missed steps during manual execution (15, 18, 19, 27 Mar). /run-protocol guarantees step-by-step TodoList + verification Haiku R23."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'

# Session Close → /run-protocol close
elif echo "$PROMPT" | grep -qE '(close|closing|push it|push|close session)'; then
  CTX="⛔ BLOCKING: Session Close is executed ONLY via skill /run-protocol with argument 'close'. FIRST AND ONLY action = invoke Skill tool: skill='run-protocol', args='close'. DO NOT perform steps independently. /run-protocol guarantees step-by-step TodoList + verification."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'

else
  echo '{}'
fi
exit 0
