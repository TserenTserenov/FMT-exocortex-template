#!/bin/bash
# test-issue-1411-stop-gate-blocked-skill.sh — issue #1411 item 7:
# a Skill call rejected before it ran (PreToolUse hook deny -> tool_result
# with is_error=true for the same tool_use_id) must not make the stop-gate
# demand a step-by-step plan. A Skill call that actually ran keeps the old
# behaviour (block-once without a plan).
#
# Run: bash .claude/hooks/tests/test-issue-1411-stop-gate-blocked-skill.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

IWE_ROOT="$TMP_DIR/iwe-root"
mkdir -p "$IWE_ROOT/.claude/logs"

write_transcript() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$TMP_DIR/$name.jsonl"
}

# run_gate <transcript-name> -> hook stdout + exit code; session id is keyed
# on the transcript name so one case's block-once marker never suppresses
# another (a counter would not survive the $(...) subshell).
run_gate() {
  printf '{"session_id":"test-1411-%s","transcript_path":"%s"}\n' "$1" "$TMP_DIR/$1.jsonl" \
    | IWE_ROOT="$IWE_ROOT" bash "$HOOK_DIR/protocol-stop-gate.sh" 2>/dev/null
  echo "exit=$?"
}

check() {
  local desc="$1" want_pattern="$2" got="$3"
  if printf '%s' "$got" | grep -qE "$want_pattern"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (want /$want_pattern/, got '$got')"
  fi
}

use_wp_new='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_wpnew1","name":"Skill","input":{"skill":"wp-new"}}]}}'
res_denied='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_wpnew1","is_error":true,"content":"PreToolUse:Skill hook error: [residency-gate-skill-adapter.sh]: BLOCKED"}]}}'
res_ok='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_wpnew1","content":"Launching skill: wp-new"}]}}'
res_denied_other='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_other","is_error":true,"content":"PreToolUse:Skill hook error: BLOCKED"}]}}'
use_wp_new2='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_wpnew2","name":"Skill","input":{"skill":"wp-new"}}]}}'
res_ok2='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_wpnew2","content":"Launching skill: wp-new"}]}}'
text='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'

# (a) rejected call -> no plan demanded
write_transcript denied "$use_wp_new" "$res_denied" "$text"
out=$(run_gate denied)
check "(a) rejected wp-new: no block" '^\{\}' "$out"
check "(a) rejected wp-new: exit 0" 'exit=0' "$out"

# (b) executed call -> existing block-once preserved
write_transcript executed "$use_wp_new" "$res_ok" "$text"
out=$(run_gate executed)
check "(b) executed wp-new: block-once" '"decision":"block".*wp-new' "$out"
check "(b) executed wp-new: exit 0" 'exit=0' "$out"

# (c) error result for a different tool_use_id does not hide this call
write_transcript other-id "$use_wp_new" "$res_ok" "$res_denied_other" "$text"
out=$(run_gate other-id)
check "(c) unrelated error result: still block" '"decision":"block"' "$out"

# (d) rejected first attempt, successful retry -> gate still applies
write_transcript retry "$use_wp_new" "$res_denied" "$use_wp_new2" "$res_ok2" "$text"
out=$(run_gate retry)
check "(d) rejected then executed: block" '"decision":"block"' "$out"

# (e) tool_use without any result (truncated transcript) stays fail-closed
write_transcript no-result "$use_wp_new" "$text"
out=$(run_gate no-result)
check "(e) no tool_result: block (fail-closed)" '"decision":"block"' "$out"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
