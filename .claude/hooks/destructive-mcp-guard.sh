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

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)

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
