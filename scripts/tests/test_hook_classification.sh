#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude/hooks" "$TMP/.claude"
cp "$ROOT/setup/validate-template.sh" "$TMP/validate-template.sh"
cp "$ROOT/.claude/settings.json" "$TMP/.claude/settings.json"
cp "$ROOT/.claude/hooks/"*.sh "$TMP/.claude/hooks/"

OUTPUT=$(bash "$TMP/validate-template.sh" "$TMP" 2>&1 || true)
for name in agent-trace-uploader residency-gate-init residency-gate-lazy rule-engine; do
  if grep -q "WARN: hook $name.sh" <<<"$OUTPUT"; then
    echo "FAIL: explicitly classified $name.sh still reported as orphan" >&2
    exit 1
  fi
done

printf '#!/bin/sh\n' > "$TMP/.claude/hooks/unknown-orphan.sh"
OUTPUT=$(bash "$TMP/validate-template.sh" "$TMP" 2>&1 || true)
grep -q 'WARN: hook unknown-orphan.sh' <<<"$OUTPUT"

# issue #525: UserPromptSubmit carries the user text in `.prompt`, not the
# obsolete `.message` field. Exercise the shipped hook with a real payload and
# assert the observable additionalContext, rather than only grepping its source.
ROLE_HOOK="$ROOT/.claude/hooks/inject-role-prefixes.sh"
ROLE_OUT=$(printf '%s' '{"session_id":"issue-525","prompt":"Навигатор, помоги выбрать следующий шаг"}' \
  | CLAUDE_PROJECT_DIR="$ROOT" bash "$ROLE_HOOK")
printf '%s' "$ROLE_OUT" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
hook = payload["hookSpecificOutput"]
assert hook["hookEventName"] == "UserPromptSubmit"
assert "Полный контекст ролей IWE" in hook["additionalContext"]
assert "Навигатор" in hook["additionalContext"]
' || {
  echo "FAIL: inject-role-prefixes did not inject context from the .prompt payload" >&2
  exit 1
}

ROLE_LEGACY_OUT=$(printf '%s' '{"session_id":"issue-525","message":"Навигатор, legacy field"}' \
  | CLAUDE_PROJECT_DIR="$ROOT" bash "$ROLE_HOOK")
[ "$ROLE_LEGACY_OUT" = "{}" ] || {
  echo "FAIL: inject-role-prefixes still reads the obsolete .message field" >&2
  exit 1
}

ROLE_ORDINARY_OUT=$(printf '%s' '{"session_id":"issue-525","prompt":"Обычный вопрос без роли"}' \
  | CLAUDE_PROJECT_DIR="$ROOT" bash "$ROLE_HOOK")
[ "$ROLE_ORDINARY_OUT" = "{}" ] || {
  echo "FAIL: ordinary .prompt unexpectedly triggered role-prefix context" >&2
  exit 1
}

echo "PASS: hook classification and UserPromptSubmit role-prefix contracts hold"
