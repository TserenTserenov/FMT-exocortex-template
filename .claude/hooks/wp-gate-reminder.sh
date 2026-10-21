#!/bin/bash
# WP Gate Reminder Hook
# Event: UserPromptSubmit
# (1) On Day Open trigger — injects the real date (currentDate from Anthropic may lie).
# (2) For all other messages — standard WP Gate reminder.
# Read-only: only returns JSON with additionalContext, modifies nothing.

INPUT=$(cat)
# Resilience to multi-line prompts: literal \n in JSON value
# is invalid for jq. Replace all control chars with spaces before parsing.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')

# Day Open → inject the real date + WP Gate
if echo "$PROMPT" | grep -qE '(open day|open$|open day)'; then
  REAL_DATE=$(date "+%Y-%m-%d %A %H:%M %Z")
  CTX="⛔ DAY OPEN: Real date and time: ${REAL_DATE}. Use THIS date to determine the day of the week, strategy_day, commit filters. Do NOT trust currentDate from system prompt. SchedulerReport: read ~/logs/strategist/$(date +%Y-%m-%d).log, NOT the file from current/. EXTENSION LOADING: BEFORE step 1 verify extensions/day-open.before.md. AFTER step 6b verify extensions/day-open.after.md. BEFORE git commit verify extensions/day-open.checks.md. Skipping extensions = incomplete open."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
else
  CTX="⛔ WP GATE: Before processing this message — verify: (1) If this is a new task — go through WP Gate: Read memory/protocol-open.md. (2) If this is a continuation of work on the same WP — continue. (3) If the question is escalating into work — escalate."
  jq -n --arg ctx "$CTX" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
fi
exit 0
