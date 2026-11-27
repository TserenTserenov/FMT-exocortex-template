#!/usr/bin/env bash
# Codex CLI PreToolUse/Bash adapter for the shared destructive-guard.sh.
#
# destructive-guard.sh speaks the Claude Code contract: exit 2 + reason on
# stderr = block. Codex accepts that too (pre_tool_use.rs), but treats every
# other guard failure as a hook error, not a block (fail-open). This wrapper
# forwards stdin unchanged, keeps the guard's env-based bypass
# (CC_ALLOW_DESTRUCTIVE_INPUT) intact and answers with the JSON deny Codex
# understands whenever the guard blocks OR cannot evaluate the command:
# guard missing, guard crashed, jq missing (the guard silently allows without
# jq, so jq is checked here before the guard runs). WP-544 Д22.
set -u

deny() {
  local reason=$1
  reason=${reason//\\/\\\\}
  reason=${reason//\"/\\\"}
  reason=${reason//$'\n'/ }
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/.claude/hooks/destructive-guard.sh"

command -v jq >/dev/null 2>&1 || deny "сторож destructive-guard.sh не может оценить команду: jq не установлен"
[ -x "$GUARD" ] || deny "сторож destructive-guard.sh не найден или не исполняемый: $GUARD"

err_file=$(mktemp) || deny "сторож destructive-guard.sh не может оценить команду: mktemp не сработал"
out=$(bash "$GUARD" 2>"$err_file")
status=$?
reason=$(cat "$err_file")
rm -f -- "$err_file"
case $status in
  0)
    # Since FMT #1568 the guard can answer exit 0 + JSON permissionDecision
    # "ask" (human confirmation). Codex has no prompt here, so a silent exit 0
    # would let the command through: answer deny with the guard's reason.
    if [ -n "$out" ] && decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null) \
        && [ "$decision" = "ask" ]; then
      ask_reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out")
      deny "нужно подтверждение человека: ${ask_reason:-сторож destructive-guard.sh просит подтверждения}"
    fi
    exit 0 ;;
  2) deny "${reason:-заблокировано сторожем destructive-guard.sh}" ;;
  *) deny "сторож destructive-guard.sh упал с кодом $status: $reason" ;;
esac
