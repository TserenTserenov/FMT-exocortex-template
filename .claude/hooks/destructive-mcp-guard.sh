#!/bin/bash
# Destructive MCP Guard (WP-544 Ф1, пир-сессия с Codex 20.08)
# Event: PreToolUse (matcher: mcp__.*)
# Блокирует разрушительные MCP-вызовы (удаление облачных ресурсов), для которых
# сейчас нет вообще никакой проверки — интерактивный вопрос выключен (bypassPermissions),
# а до этого хука ни один matcher не смотрел на конкретное имя MCP-инструмента.
#
# Bypass: CC_ALLOW_DESTRUCTIVE_INPUT=1 (тот же контракт, что destructive-guard.sh —
# хук читает свой процессный env, агент не может выставить это сам себе через
# ещё не выполненный tool call).
#
# Лог: ~/IWE/.claude/logs/destructive-mcp-guard.jsonl

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/destructive-mcp-guard.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_decision() {
  local decision="$1" tool="$2"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc --arg ts "$ts" --arg sid "${CLAUDE_SESSION_ID:-}" --arg dec "$decision" --arg tool "$tool" \
    '{ts:$ts, hook:"destructive-mcp-guard", session_id:$sid, decision:$dec, tool:$tool}' \
    >> "$LOG_FILE" 2>/dev/null || true
}

input=$(cat 2>/dev/null || true)

# Fail-closed on a malformed/schema-invalid envelope (WP-544 Д22, peer session
# 2026-09-08-25-wp544-continue-f7, Codex). The old `jq -r '.tool_name //
# empty'` turned any jq parse error or wrong-typed field into an empty
# string, which then missed every `mcp__*` case below and fell through to
# `exit 0` — the same fail-open destructive-guard.sh had. The deny output
# below is a literal JSON string, not built with jq, so an absent/broken jq
# still denies instead of silently passing.
#
# No `timeout` wrapper here on purpose (unlike destructive-guard.sh):
# `timeout cmd` execs `cmd` directly, which does not consult bash's function
# table — an exported bash function used to simulate "jq absent" for a test
# is invisible to it, and it always finds the real jq on this script's own
# hardened PATH (line 15) instead. destructive-guard.sh has a second,
# unwrapped jq call downstream that still catches that case and keeps it
# testable; this hook's single combined call has no such second call, so
# wrapping it would make "jq missing" permanently unverifiable by test
# (confirmed live, cold review WP-544 Д22, 08.09) for a payload class (MCP
# tool-call metadata) much smaller than the Bash-guard's command strings —
# not worth trading away test coverage for.
if ! tool_name=$(printf '%s' "$input" | jq -er '.tool_name | select(type == "string" and length > 0)' 2>/dev/null); then
  log_decision "deny-malformed-input" ""
  printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Не удалось разобрать вход хука или tool_name отсутствует/пустой/неверного типа — блокирую как неопределённо опасный MCP-вызов."}}'
  exit 0
fi

case "$tool_name" in mcp__*) ;; *) exit 0 ;; esac

tn=$(printf '%s' "$tool_name" | tr 'A-Z' 'a-z')
case "$tn" in
  *remove_service*|*remove_volume*|*remove_tcp_proxy*|*remove_bucket*|*delete_domain*)
    ;;
  *) exit 0 ;;  # не разрушительный вызов — пропускаем
esac

if [ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ]; then
  log_decision "bypass-env" "$tool_name"
  exit 0
fi

reason="Инструмент ${tool_name} необратимо удаляет облачный ресурс (сервис/хранилище/домен). Разовая необходимость — запусти с CC_ALLOW_DESTRUCTIVE_INPUT=1 (осознанно, из реального шелла пилота)."
log_decision "deny" "$tool_name"
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
