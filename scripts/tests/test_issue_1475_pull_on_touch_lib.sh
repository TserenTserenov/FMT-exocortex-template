#!/bin/bash
# test_issue_1475_pull_on_touch_lib.sh -- regression guard for #1475.
# In an installed workspace the hook lives in $WORKSPACE/.claude/hooks and there is
# no $WORKSPACE/scripts/lib, so the self-relative library path does not exist.
# Checks: with $IWE_SCRIPTS the library is found and a clean stale clone is
# fast-forwarded; with no library anywhere the hook warns and still exits 0.
# scripts/tests/run-issue-tests.sh picks up test_issue_*.sh by existence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# run_case <name> <IWE_SCRIPTS or empty> -- prints "rc head-after origin-head" then the hook output
run_case() {
  local d="$TMP/$1" ws
  ws="$d/IWE"; mkdir -p "$ws/.claude/hooks"
  cp "$TEMPLATE/.claude/hooks/pull-on-touch.sh" "$ws/.claude/hooks/"
  git init -q -b main "$d/src" && git -C "$d/src" commit -q --allow-empty -m a
  git clone -q --bare "$d/src" "$d/origin.git"
  git clone -q "$d/origin.git" "$ws/FPF"
  git -C "$d/src" commit -q --allow-empty -m b && git -C "$d/src" push -q "$d/origin.git" main
  local input out rc
  input=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s/FPF status"},"session_id":"t-%s"}' "$ws" "$1")
  out=$(printf '%s' "$input" | env -u IWE_TEMPLATE IWE_SCRIPTS="$2" HOME="$d/home" IWE_WORKSPACE="$ws" \
        /bin/bash "$ws/.claude/hooks/pull-on-touch.sh" 2>&1); rc=$?
  echo "$rc $(git -C "$ws/FPF" rev-parse HEAD) $(git -C "$d/src" rev-parse HEAD)"
  echo "$out"
}

res=$(run_case with-scripts "$TEMPLATE/scripts")
read -r rc head origin <<<"$(head -1 <<<"$res")"
[ "$rc" -eq 0 ] && check "IWE_SCRIPTS: exit 0" ok || check "IWE_SCRIPTS: exit 0 (rc=$rc)" bad
[ "$head" = "$origin" ] && check "IWE_SCRIPTS: stale clean clone fast-forwarded" ok || check "IWE_SCRIPTS: stale clean clone fast-forwarded" bad

res=$(run_case no-lib "")
read -r rc head origin <<<"$(head -1 <<<"$res")"
[ "$rc" -eq 0 ] && check "no library: exit 0" ok || check "no library: exit 0 (rc=$rc)" bad
[ "$head" != "$origin" ] && check "no library: clone left as is" ok || check "no library: clone left as is" bad
tail -n +2 <<<"$res" | python3 -c 'import json,sys; c=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; sys.exit(0 if "проверка свежести недоступна" in c else 1)' 2>/dev/null \
  && check "no library: stale note in additionalContext" ok || check "no library: stale note in additionalContext" bad

[ "$FAILURES" -eq 0 ] && { echo "OK: all checks passed"; exit 0; }
echo "FAILED: $FAILURES"; exit 1
