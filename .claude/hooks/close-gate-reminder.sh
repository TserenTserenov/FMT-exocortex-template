#!/bin/bash
# Close Gate Reminder Hook (v4 — texts and trigger phrases from language catalogs)
# Event: UserPromptSubmit
# Day Close → DIRECT INSTRUCTION to call /run-protocol day-close (not a reminder).
# Session Close → compact checklist.
# Read-only: only JSON additionalContext.
# Day Close is checked first: a prompt matching both gets the day instruction.
# Push ("заливай"/"запуши") is checked last and only reminds about commit + push:
# a prompt that also asks to close ("заливай и закрывай") gets the close
# instruction (issue #1472). Quoted words are not requests: «…», „…“, "…" and “…”
# are cut out before matching, so "я не писал «закрывай»" stays silent.
# A catalog failure exits non-zero with a diagnostic and no JSON (WP-610 F9).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/../lib/i18n.sh" || { echo "close-gate-reminder: cannot load i18n.sh" >&2; exit 1; }

INPUT=$(cat)
# Resilience to multiline prompts: a literal \n in a JSON value
# is invalid for jq. Replace all control chars with spaces before parsing.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" \
  | jq -r '(.prompt // "") | gsub("«[^»]*»|„[^“]*“|\"[^\"]*\"|“[^”]*”"; " ")' \
  | tr '[:upper:]' '[:lower:]')

emit() {
  local ctx
  ctx=$(i18n_msg "$1" && printf x) || exit 1
  jq -n --arg ctx "${ctx%x}" '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
}

for gate in day session push; do
  key="recognition.close_$gate"
  [ "$gate" = push ] && key="recognition.push_only"
  i18n_match "$key" "$PROMPT"
  case $? in
    0) emit "agent.close_gate.$gate"; exit 0 ;;
    1) ;;
    *) exit 1 ;;
  esac
done
echo '{}'
exit 0
