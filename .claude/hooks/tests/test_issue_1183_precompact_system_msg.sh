#!/bin/bash
# test_issue_1183_precompact_system_msg.sh — issue #1183:
# precompact-checkpoint.sh больше не использует hookSpecificOutput (невалидно
# для PreCompact, до агента не доходит); вывод — {"systemMessage": ...}, exit 0.
#
# Запуск: bash .claude/hooks/tests/test_issue_1183_precompact_system_msg.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

check() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

OUT=$(printf '{"session_id":"t","cwd":"%s","hook_event_name":"PreCompact","trigger":"manual"}\n' "$PWD" \
  | bash "$HOOK_DIR/precompact-checkpoint.sh")
CODE=$?

check "exit code 0" "0" "$CODE"
check "stdout — валидный JSON" "ok" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)"
check "есть .systemMessage" "yes" "$(printf '%s' "$OUT" | jq -r 'if (.systemMessage // "") != "" then "yes" else "no" end' 2>/dev/null)"
check "нет .hookSpecificOutput" "no" "$(printf '%s' "$OUT" | jq -r 'if has("hookSpecificOutput") then "yes" else "no" end' 2>/dev/null)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
