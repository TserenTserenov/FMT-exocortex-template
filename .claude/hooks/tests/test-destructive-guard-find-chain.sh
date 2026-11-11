#!/bin/bash
# test-destructive-guard-find-chain.sh — WP-529 Ф270, F1 of the v0.42.0-rc.6 red team:
# the segmenter split the command at the escaped `\;` that ends `find -exec … \;`, so whatever
# followed the first reading action (`-delete`, a second `-exec rm`, `-fprint` onto a hook) was a
# separate piece without the name find, and no find rule saw it. `find` is pre-approved, so those
# forms deleted files and overwrote this hook without a prompt. Same run covers the `>|` emptying
# form left open after rc.5 (RT5-3).
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-find-chain.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "${TMP_DIR:?}"' EXIT

# expect $1=desc $2=want(block|pass) $3=command_text
expect() {
  local desc="$1" want="$2" cmd="$3" input got_exit got err_file="$TMP_DIR/err"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$WORKSPACE_ROOT")
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>"$err_file"
  got_exit=$?
  if [ "$got_exit" -eq 2 ]; then got="block"; else got="pass"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got, exit=$got_exit)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# === the eight forms of the rc.6 red team: a reading action, then a writing one ===
expect "grep then -delete" block 'find . -name v -exec grep -l foo {} \; -delete'
expect "cat then -delete" block 'find . -name v -exec cat {} \; -delete'
expect "-execdir cat then -exec rm" block 'find . -name v -execdir cat {} \; -exec rm {} \;'
expect "cat then -exec rm -f" block 'find . -name v -exec cat {} \; -exec rm -f {} \;'
expect "wc then -exec sh -c" block "find . -name v -exec wc -l {} \\; -exec sh -c 'rm \"\$0\"' {} \\;"
expect "head then -execdir rm +" block 'find . -name v -exec head -1 {} \; -execdir rm {} +'
expect "cat then -fprint" block 'find . -name v -exec cat {} \; -fprint out.txt'
expect "cat then -fprint onto the hook" block 'find .claude/hooks -name destructive-guard.sh -exec cat {} \; -fprint .claude/hooks/destructive-guard.sh'
expect "quoted ';' then -delete" block "find . -name v -exec cat {} ';' -delete"
expect "three readers then -fls" block 'find . -exec cat {} \; -exec wc -l {} \; -exec head -1 {} \; -fls x.txt'
expect "find chain after &&" block 'git status && find . -exec cat {} \; -delete'

# === emptying through the noclobber-override redirect ===
expect "cat /dev/null >| file" block 'cat /dev/null >| DS-strategy/current/WeekPlan.md'
expect "head -c0 >| file" block 'head -c0 /dev/null >|params.yaml'
expect "cat /dev/null >| tmp" pass 'cat /dev/null >| /tmp/empty.txt'

# === reading chains stay allowed ===
expect "one reader" pass 'find . -name "*.md" -exec grep -l foo {} \;'
expect "two readers" pass 'find . -name "*.md" -exec cat {} \; -exec wc -l {} \;'
expect "reader piped" pass 'find . -type f -exec wc -c {} \; | sort'
expect "reader then -print" pass 'find . -exec grep -q x {} \; -print'
expect "escaped ; in echo" pass 'echo a\; b'
expect "reader then next command" pass 'find . -exec cat {} \; ; ls'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
