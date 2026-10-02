#!/bin/bash
# test-destructive-guard-malformed-json.sh — regression corpus for the WP-544
# Д22 fail-closed fix (08.09, peer session 2026-09-08-25-wp544-continue-f7,
# Codex): a malformed/schema-invalid envelope must block, not exit 0.
#
# The live fail-open this closes: `jq -r '.tool_input.command // empty' || true`
# turned any jq parse error into an empty $CMD, and `[ -z "$CMD" ] && exit 0`
# read that as "no command, nothing to check" — a truncated payload carrying a
# real `rm -rf /x` passed silently. Reproduced with the fixtures below before
# the fix; all must block after it.
#
# Запуск: bash .claude/hooks/tests/test-destructive-guard-malformed-json.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# expect_raw $1=desc $2=want(block|pass) $3=raw_stdin_string
#
# got_exit is classified into exactly three outcomes, not two: "block" (2),
# "pass" (0), or "crashed" (anything else). Collapsing "crashed" into "pass"
# is itself a bug that hid the ARG_MAX crash this suite's oversized-command
# case exists to catch (cold review, WP-544 Д22, 08.09) — a hook that dies
# with exit 126 before reaching either block() or its final exit 0 has not
# decided to pass anything; treating that the same as a real pass would make
# a crash regression invisible to `want=pass`, and any exit code the test
# didn't anticipate should always fail the assertion, never satisfy it.
expect_raw() {
  local desc="$1" want="$2" raw="$3"
  local got_exit got err_file="$TMP_DIR/err.$$"
  printf '%s' "$raw" | bash "$HOOK" >/dev/null 2>"$err_file"
  got_exit=$?
  case "$got_exit" in
    2) got="block" ;;
    0) got="pass" ;;
    *) got="crashed (exit=$got_exit)" ;;
  esac
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# expect_wellformed $1=desc $2=want $3=command
#
# The command text goes to python3 over stdin, not argv (`sys.argv[1]`) — an
# oversized $cmd as an argv element hits the exact same execve ARG_MAX this
# suite's own big-command case exists to catch, which silently turned that
# case into an empty $input (block on empty stdin, for the wrong reason)
# rather than actually exercising the hook against a huge command (found
# live while adding the oversized-command test itself, WP-544 Д22, 08.09).
expect_wellformed() {
  local desc="$1" want="$2" cmd="$3"
  local input
  input=$(WORKSPACE_ROOT="$WORKSPACE_ROOT" python3 -c '
import json, os, sys
cmd = sys.stdin.read()
print(json.dumps({"tool_input": {"command": cmd}, "cwd": os.environ["WORKSPACE_ROOT"]}))
' <<<"$cmd")
  expect_raw "$desc" "$want" "$input"
}

# === malformed / schema-invalid envelopes must block ===
expect_raw "усечённый JSON с опасным rm -rf внутри блокируется" block \
  '{"tool_input":{"command":"rm -rf /x'

expect_raw "произвольный malformed JSON блокируется" block \
  '{not even json'

expect_raw "пустой stdin блокируется" block \
  ''

expect_raw "top-level null блокируется" block \
  'null'

expect_raw "top-level массив блокируется" block \
  '[{"tool_input":{"command":"ls"}}]'

expect_raw "отсутствующее поле tool_input блокируется" block \
  '{"cwd":"/tmp"}'

expect_raw "tool_input не объект блокируется" block \
  '{"tool_input":"rm -rf /x"}'

expect_raw "tool_input.command отсутствует блокируется" block \
  '{"tool_input":{"cwd":"/tmp"}}'

expect_raw "tool_input.command не строка (число) блокируется" block \
  '{"tool_input":{"command":123}}'

expect_raw "tool_input.command не строка (null) блокируется" block \
  '{"tool_input":{"command":null}}'

expect_raw "tool_input.command пустая строка блокируется" block \
  '{"tool_input":{"command":""}}'

# === well-formed envelopes keep working exactly as before ===
expect_wellformed "валидный безопасный запрос НЕ блокируется" pass \
  'git status --short'

expect_wellformed "валидный опасный запрос (git push --force) блокируется" block \
  'git push --force origin main'

# === oversized command must not crash the perl scanners (cold review,
# WP-544 Д22, 08.09): command text was passed to `perl -e` through the
# process environment (CMD_SCAN="$CMD" perl -e ...) at four call sites,
# which is subject to execve ARG_MAX exactly like argv — a ~1.2MB command
# crashed with "Argument list too long" (exit 126) before any block()/exit 0
# decision, bypassing every check below it. Fixed by piping the command
# through stdin instead at all four sites. Padding pushes the command past
# this host's observed ARG_MAX threshold (~1,048,576 bytes).
BIG_PADDING=$(python3 -c "print('x' * 1200000)")
expect_wellformed "негабаритная опасная команда (>1.2МБ) вне /tmp блокируется, не крашится" block \
  "rm -rf $WORKSPACE_ROOT/DS-strategy/sessions # $BIG_PADDING"

# === отсутствие jq — тоже fail-closed, не fail-open. A bash function named
# `jq`, exported into the child bash process, wins command lookup over any
# PATH entry (functions resolve before external binaries) — this shadows the
# real jq regardless of which directory it lives in, which a PATH edit alone
# cannot guarantee on a machine where jq sits in a standard system path.
jq() { return 127; }
export -f jq
got_exit=0
printf '%s' '{"tool_input":{"command":"git status"}}' \
  | bash "$HOOK" >/dev/null 2>"$TMP_DIR/err.nojq" || got_exit=$?
unset -f jq
if [ "$got_exit" -eq 2 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: отсутствие jq на PATH блокирует, а не пропускает (ожидалось exit=2, получено exit=$got_exit)"
  echo "  stderr: $(cat "$TMP_DIR/err.nojq")"
fi

# === сырой payload не попадает в диагностику stderr (может содержать секреты) ===
SECRET_PAYLOAD='{"tool_input":{"command":"echo sk-ant-super-secret-token-do-not-leak"'
printf '%s' "$SECRET_PAYLOAD" | bash "$HOOK" >/dev/null 2>"$TMP_DIR/err.secret" || true
if grep -q "sk-ant-super-secret-token-do-not-leak" "$TMP_DIR/err.secret" 2>/dev/null; then
  FAIL=$((FAIL+1))
  echo "FAIL: сырой payload (секрет) утёк в диагностику stderr"
else
  PASS=$((PASS+1))
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
