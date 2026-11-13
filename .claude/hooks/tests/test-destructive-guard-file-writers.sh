#!/bin/bash
# test-destructive-guard-file-writers.sh — WP-529 Ф270, RT2-3 of the v0.42.0-rc.2 red team:
# `git diff --output=<file>` and `find … -fprint <file>` are pre-approved in settings.json and
# write the file named in their arguments without a prompt; the red team zeroed
# .claude/hooks/destructive-guard.sh with one and every check went off. The option is refused on
# any path; the same output through a shell redirection, and the look-alike options, pass.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-file-writers.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TMP_DIR"' EXIT

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

# === the writes the red team ran ===
expect "git diff --output=hook" block 'git diff --output=.claude/hooks/destructive-guard.sh'
expect "find -fprint into a hook" block 'find .claude/hooks -maxdepth 0 -fprint .claude/hooks/secret-leak-block.sh'

# === other spellings of the same write ===
expect "git diff --output FILE" block 'git diff --output x.txt'
expect "git log --outp= abbreviation" block 'git log -1 --outp=x.txt'
expect "git -C dir show --output" block 'git -C . show HEAD --output="$F"'
expect "find -fprint0" block 'find . -fprint0 out'
expect "find -fprintf" block "find . -fprintf out '%p'"
expect "find -fls" block 'find . -fls out'
expect "bash -c with git diff --output" block "bash -c 'git diff --output=x'"

# === look-alikes stay allowed ===
expect "git diff into a redirection" pass 'git diff > /tmp/x.diff'
expect "git diff --output-indicator-new" pass 'git diff --output-indicator-new=+'
expect "git format-patch --output-directory" pass 'git format-patch -1 --output-directory /tmp/p'
expect "find -print and -printf" pass "find . -name '*.sh' -printf '%p\n'"
expect "grep for the text --output" pass "grep -rn -- '--output=' docs/"

echo "file-writers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
