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

# Project-relative settings execute the hook snapshot stored in a linked
# worktree. Verify that this snapshot consumes no stdin before it trampolines
# to the primary worktree's current hook, and that exact session scope lands
# only in the canonical runtime semaphore.
python3 - "$ROOT/.claude/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
matches = [
    entry
    for entry in settings["hooks"]["PostToolUse"]
    if any(
        hook.get("command") == "$CLAUDE_PROJECT_DIR/.claude/hooks/post-tool-use-scope-track.sh"
        for hook in entry.get("hooks", [])
    )
]
assert len(matches) == 1
assert matches[0].get("matcher") == "Write|Edit|MultiEdit|NotebookEdit"
PY

PRIMARY="$TMP/primary"
LINKED="$TMP/linked"
mkdir -p "$PRIMARY/.claude/hooks" "$PRIMARY/scripts" "$PRIMARY/DS-strategy/inbox/WP-001"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.name "Hook Test"
git -C "$PRIMARY" config user.email "hook@example.invalid"
cp "$ROOT/.claude/hooks/post-tool-use-scope-track.sh" "$PRIMARY/.claude/hooks/"
cp "$ROOT/scripts/session-guard.sh" "$PRIMARY/scripts/"
chmod +x "$PRIMARY/.claude/hooks/post-tool-use-scope-track.sh" "$PRIMARY/scripts/session-guard.sh"
printf '%s\n' 'hypothesis_relation: "tests"' > "$PRIMARY/DS-strategy/inbox/WP-001/WP-001.md"
printf '%s\n' seed > "$PRIMARY/edited.txt"
git -C "$PRIMARY" add -- .claude/hooks/post-tool-use-scope-track.sh scripts/session-guard.sh \
  DS-strategy/inbox/WP-001/WP-001.md edited.txt
git -C "$PRIMARY" commit -qm "test: seed primary hook"
git -C "$PRIMARY" worktree add -q -b linked "$LINKED"

CLAUDE_CODE_SESSION_ID="hook-harness" IWE_ROOT="$PRIMARY" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$PRIMARY/scripts/session-guard.sh" open --wp WP-001 --slug hook-test \
    --agent claude-code --session-id hook-session --owner-pid "$$" --close-path peer-session >/dev/null

mv "$PRIMARY/.claude/hooks/post-tool-use-scope-track.sh" \
  "$PRIMARY/.claude/hooks/post-tool-use-scope-track.real.sh"
cat > "$PRIMARY/.claude/hooks/post-tool-use-scope-track.sh" <<'WRAPPER'
#!/bin/bash
printf '%s\n' canonical >> "$HOOK_TRACE_FILE"
exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/post-tool-use-scope-track.real.sh"
WRAPPER
chmod +x "$PRIMARY/.claude/hooks/post-tool-use-scope-track.sh"
printf '%s\n' changed > "$LINKED/edited.txt"
HOOK_INPUT=$(python3 - "$LINKED/edited.txt" <<'PY'
import json
import sys
print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Edit",
    "session_id": "hook-harness",
    "tool_input": {"file_path": sys.argv[1]},
}))
PY
)
HOOK_TRACE_FILE="$TMP/hook-trace" CLAUDE_PROJECT_DIR="$LINKED" \
  IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$LINKED/.claude/hooks/post-tool-use-scope-track.sh" <<<"$HOOK_INPUT"

grep -qxF canonical "$TMP/hook-trace" \
  || { echo "FAIL: linked hook snapshot did not trampoline to primary" >&2; exit 1; }
grep -qxF 'file: edited.txt' "$PRIMARY/.iwe-runtime/sessions/claude-code-hook-session.open" \
  || { echo "FAIL: canonical hook did not exact-note the edited file" >&2; exit 1; }

echo "PASS: hook classification, role-prefix and canonical trampoline contracts hold"
