#!/bin/bash
# test-issue-1657-secret-file-read-block-kimi-envelope.sh — the secret-file guard
# must work for Kimi Code (own tool names, `path`, no hook_event_name/session_id)
# without relaxing anything for Claude Code or for malformed input (issue #1657).
#
# Run: bash .claude/hooks/tests/test-issue-1657-secret-file-read-block-kimi-envelope.sh
# HOOK_UNDER_TEST=<path> checks another copy of the hook (used to confirm the
# test fails on the version before the fix).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOK_DIR/secret-file-read-block.sh}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
# The hook writes its decision log under IWE_ROOT; keep it out of the real tree.
export IWE_ROOT="$TMP_DIR/iwe"
mkdir -p "$IWE_ROOT/.claude/logs"

PASS=0
FAIL=0

# check <name> <expected: deny|allow|rc2> <stdin>
check() {
  local name="$1" expect="$2" raw="$3" out rc got
  out=$(printf '%s' "$raw" | bash "$HOOK" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ]; then
    got=rc2
  elif [ "$rc" -ne 0 ]; then
    got="rc$rc"
  elif printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    got=deny
  elif [ -z "$out" ]; then
    got=allow
  else
    got="other:$out"
  fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: expected=%s got=%s\n' "$name" "$expect" "$got" >&2
  fi
}

# Kimi Code: the reported failure (every file call blocked) and the guard still biting.
check kimi_readfile_plain_file_allowed allow '{"tool_name":"ReadFile","tool_input":{"path":"README.md"}}'
check kimi_readfile_env_denied deny '{"tool_name":"ReadFile","tool_input":{"path":".env"}}'
check kimi_strreplace_key_denied deny '{"tool_name":"StrReplaceFile","tool_input":{"path":"id_rsa"}}'
check kimi_with_full_envelope_allowed allow '{"hook_event_name":"PreToolUse","session_id":"k","tool_name":"ReadFile","tool_input":{"path":"STAGING.md"}}'
check kimi_envelope_without_event_name_denied deny '{"session_id":"k","tool_name":"ReadFile","tool_input":{"path":"server.pem"}}'

# Claude Code envelope: unchanged behaviour.
check claude_read_plain_allowed allow '{"hook_event_name":"PreToolUse","session_id":"c","tool_name":"Read","tool_input":{"file_path":"README.md"}}'
check claude_read_env_denied deny '{"hook_event_name":"PreToolUse","session_id":"c","tool_name":"Read","tool_input":{"file_path":".env"}}'
check claude_grep_no_path_allowed allow '{"hook_event_name":"PreToolUse","session_id":"c","tool_name":"Grep","tool_input":{"pattern":"x"}}'

# Malformed input still fails closed (exit 2), never falls through to allow.
check other_event_rc2 rc2 '{"hook_event_name":"PostToolUse","tool_name":"ReadFile","tool_input":{"path":"README.md"}}'
check wrong_type_session_rc2 rc2 '{"session_id":{"a":1},"tool_name":"ReadFile","tool_input":{"path":"README.md"}}'
check missing_tool_input_rc2 rc2 '{"tool_name":"ReadFile"}'
check kimi_plain_file_path_secret_path_denied deny '{"tool_name":"ReadFile","tool_input":{"file_path":"README.md","path":".env"}}'
check kimi_secret_file_path_plain_path_denied deny '{"tool_name":"ReadFile","tool_input":{"file_path":".env","path":"README.md"}}'
check kimi_both_fields_safe_allowed allow '{"tool_name":"WriteFile","tool_input":{"file_path":"README.md","path":"docs/a.md"}}'
check numeric_path_rc2 rc2 '{"tool_name":"ReadFile","tool_input":{"path":123}}'
check numeric_file_path_cannot_hide_path_rc2 rc2 '{"tool_name":"Read","tool_input":{"file_path":123,"path":".env"}}'
check unknown_tool_rc2 rc2 '{"tool_name":"Shell","tool_input":{"command":"cat .env"}}'
check not_json_rc2 rc2 'not json'
check empty_rc2 rc2 ''

# The built-in self-test of the hook covers the same ground plus the pattern list.
if bash "$HOOK" --self-test >/dev/null 2>"$TMP_DIR/self-test.err"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  printf 'FAIL hook --self-test:\n' >&2
  head -5 "$TMP_DIR/self-test.err" >&2
fi

printf 'secret-file-read-block (issue #1657): %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
