#!/bin/bash
# test-destructive-guard-reader-overwrite.sh — issue #1568, F2 of the v0.42.0 red team: readers
# pre-approved in settings.json (grep, ls, head, tail, diff …) with an empty output emptied a
# working file through `>` without a prompt; only `cat /dev/null > f` and `head -c0 > f` were
# known. The class: a truncating redirection after a pre-approved reader into anything outside a
# temporary directory asks the person (permissionDecision "ask"), whatever the reader is.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-reader-overwrite.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TMP_DIR"' EXIT

# expect $1=desc $2=want(block|ask|pass) $3=command_text
expect() {
  local desc="$1" want="$2" cmd="$3" input got_exit got decision out_file="$TMP_DIR/out" err_file="$TMP_DIR/err"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$WORKSPACE_ROOT")
  printf '%s' "$input" | bash "$HOOK" >"$out_file" 2>"$err_file"
  got_exit=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out_file" 2>/dev/null)
  if [ "$got_exit" -eq 2 ]; then got="block"
  elif [ "$got_exit" -eq 0 ] && [ "$decision" = "ask" ]; then got="ask"
  elif [ "$got_exit" -eq 0 ] && [ -z "$decision" ]; then got="pass"
  else got="unexpected(exit=$got_exit, decision=$decision)"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# === the forms the red team ran ===
expect "grep without a match" ask 'grep zzzqqq README.md > params.yaml'
expect "ls of a missing path" ask 'ls /nonexistent > params.yaml'
expect "head -0" ask 'head -0 F > params.yaml'
expect "tail past the end" ask 'tail -n +999999 F > params.yaml'
expect "diff of a file with itself" ask 'diff F F > params.yaml'

# === the same class with other readers and redirections ===
expect "cat copies over a plan" ask 'cat README.md > DS-strategy/current/WeekPlan.md'
expect "wc" ask 'wc -l README.md > params.yaml'
expect "rg" ask 'rg zzzqqq > params.yaml'
expect "find" ask 'find . -name nothing > params.yaml'
expect "git log" ask 'git log -1 > params.yaml'
expect "git show" ask 'git show HEAD:README.md > README.md'
expect "clobber" ask 'grep zzzqqq README.md >| params.yaml'
expect "stderr into a file" ask 'ls /nonexistent 2> params.yaml'
expect "both streams" ask 'ls /nonexistent &> params.yaml'
expect "no blank" ask 'grep zzzqqq README.md>params.yaml'
expect "after a pipe" ask 'cat README.md | grep zzzqqq > params.yaml'
expect "after &&" ask 'true && grep zzzqqq README.md > params.yaml'
expect "absolute path" ask 'grep zzzqqq README.md > "$HOME/IWE/params.yaml"'
expect "escape from tmp with .." ask 'ls > /tmp/../home/x/params.yaml'

# === the older blocks keep blocking ===
expect "cat /dev/null still blocked" block 'cat /dev/null > params.yaml'
expect "protective file still blocked" block 'grep x README.md > .claude/hooks/destructive-guard.sh'

# === allowed without a prompt ===
expect "into /tmp" pass 'grep x README.md > /tmp/out.txt'
expect "into TMPDIR" pass 'git diff > "$TMPDIR/x.diff"'
expect "into /dev/null" pass 'grep -q x README.md > /dev/null'
expect "stderr to /dev/null" pass 'cat README.md 2>/dev/null | head -5'
expect "descriptor copy" pass 'ls 2>&1 | head'
expect "append" pass 'cat README.md >> notes.md'
expect "plain read" pass 'grep -rn x .claude/hooks'
expect "input redirection" pass 'grep x < params.yaml'
expect "not a reader" pass 'python3 x.py > out.json'
expect "heredoc body is data" pass "grep x <<'EOF'
a > params.yaml
EOF"

echo "reader-overwrite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
