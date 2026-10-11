#!/usr/bin/env bash
# dryrun-gate-knowledge-namespace-regression.sh — regression for issue #219.
#
# Old design: MCP-write whitelist matched exact tool names under the
# `mcp__claude_ai_IWE__*` prefix. The live MCP server is named `iwe-knowledge`,
# so none of its tools (mcp__iwe-knowledge__personal_write,
# mcp__iwe-knowledge__dt_write_digital_twin, ...) ever matched the whitelist —
# the gate was fail-open for the exact namespace it exists to protect.
#
# New design: deny-by-default for any MCP tool_name whose server segment
# contains "iwe"/"IWE"/"knowledge" — a read-only action is matched by name
# pattern (search/get_*/list_*/read_*/describe_*/*_status/*_stats/*_traverse/
# *_expand/*_search_by_name/backlinks/whoami/get_instructions), everything
# else is blocked. This test drives the real hook, not a reimplementation.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GATE="$ROOT/.claude/hooks/dry-run-gate.sh"
TMP=$(mktemp -d)

export IWE_DRY_RUN_DIR="$TMP/dry"
export IWE_DRY_RUN_SENTINEL="$TMP/sentinel.flag"
mkdir -p "$IWE_DRY_RUN_DIR"; chmod 700 "$IWE_DRY_RUN_DIR"
touch "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode"

SLEEP_PID=""
cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null || true
    rm -rf "$TMP"
    rm -rf "$ROOT/.claude/logs" 2>/dev/null || true
}
trap cleanup EXIT

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

gate_rc() { # <payload> → echoes rc
    printf '%s' "$1" | /bin/bash "$GATE" >/dev/null 2>&1; echo $?
}
expect_block() { # <desc> <tool_name>
    local rc payload
    payload=$(jq -nc --arg t "$2" '{tool_name:$t,tool_input:{}}')
    rc=$(gate_rc "$payload")
    [ "$rc" = "2" ] && ok "$1" || bad "$1 (ожидался rc=2, получен $rc)"
}
expect_allow() { # <desc> <tool_name>
    local rc payload
    payload=$(jq -nc --arg t "$2" '{tool_name:$t,tool_input:{}}')
    rc=$(gate_rc "$payload")
    [ "$rc" = "0" ] && ok "$1" || bad "$1 (ожидался rc=0, получен $rc)"
}
mkstate() { # <gate_id> <pid> <pgid> <sid> <token>
    local tsha
    tsha=$(printf '%s' "$5" | shasum -a 256 | awk '{print $1}')
    jq -nc --arg gid "$1" --argjson pid "$2" --argjson pgid "$3" --arg sid "$4" --arg tsha "$tsha" \
      '{version:2,gate_id:$gid,owner_session_id:$sid,owner_pid:$pid,owner_pgid:$pgid,owner_pid_start:"unknown-start",owner_token_sha256:$tsha,state:"active",created_at:"2026-10-11T00:00:00Z",initiator:"test"}' \
      > "$IWE_DRY_RUN_DIR/gate-$1.state"
}
mksentinel() { # <gate_id>
    jq -nc --arg gid "$1" '{gate_id:$gid,created_at:"2026-10-11T00:00:00Z",session_id:"s",initiator:"test"}' \
      > "$IWE_DRY_RUN_SENTINEL"
}

sleep 300 & SLEEP_PID=$!
SLEEP_PGID=$(ps -o pgid= -p "$SLEEP_PID" | tr -d ' ')
mkstate "g-219" "$SLEEP_PID" "$SLEEP_PGID" "sid-219" "tok-219"
mksentinel "g-219"

echo "== Текущий сервер (mcp__iwe-knowledge__*): write заблокирован =="
expect_block "personal_write заблокирован" "mcp__iwe-knowledge__personal_write"
expect_block "dt_write_digital_twin заблокирован" "mcp__iwe-knowledge__dt_write_digital_twin"
expect_block "send_telegram_message заблокирован" "mcp__iwe-knowledge__send_telegram_message"
expect_block "personal_delete заблокирован" "mcp__iwe-knowledge__personal_delete"
expect_block "неизвестное действие (не read-паттерн) заблокировано по умолчанию" \
  "mcp__iwe-knowledge__some_future_write_action"

echo "== Текущий сервер: read-only разрешён (не блокируется этой секцией) =="
expect_allow "search разрешён" "mcp__iwe-knowledge__search"
expect_allow "whoami разрешён" "mcp__iwe-knowledge__whoami"
expect_allow "get_instructions разрешён" "mcp__iwe-knowledge__get_instructions"
expect_allow "get_cognitive_brief (get_*) разрешён" "mcp__iwe-knowledge__get_cognitive_brief"
expect_allow "knowledge_list_documents (list_ в середине имени) разрешён" "mcp__iwe-knowledge__knowledge_list_documents"
expect_allow "user_profile_get_tier (get_ в середине имени) разрешён" "mcp__iwe-knowledge__user_profile_get_tier"
expect_allow "dt_read_digital_twin (read_ в середине имени) разрешён" "mcp__iwe-knowledge__dt_read_digital_twin"
expect_allow "personal_graph_stats (*_stats) разрешён" "mcp__iwe-knowledge__personal_graph_stats"
expect_allow "knowledge_pack_traverse (*_traverse) разрешён" "mcp__iwe-knowledge__knowledge_pack_traverse"
expect_allow "backlinks разрешён" "mcp__iwe-knowledge__backlinks"
expect_allow "agent_status_list (*_list) разрешён" "mcp__iwe-knowledge__agent_status_list"
expect_block "agent_status_update (это запись, не читать её как *_status) заблокирован" \
  "mcp__iwe-knowledge__agent_status_update"

echo "== Легаси-префикс (mcp__claude_ai_IWE__*) ловится тем же паттерном =="
expect_block "legacy personal_write тоже заблокирован" "mcp__claude_ai_IWE__personal_write"
expect_allow "legacy search тоже разрешён" "mcp__claude_ai_IWE__search"

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: все проверки прошли."
else
    echo "FAIL: провалено проверок: $fail"
    exit 1
fi
