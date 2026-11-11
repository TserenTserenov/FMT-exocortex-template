#!/bin/bash
# test-destructive-guard-find-delete.sh — WP-529 Ф270, RT-2 of the v0.42.0-rc.1 red team:
# destructive-guard.sh let `find` delete what it walks (`find ~ -delete`,
# `find "$HOME" -exec rm -f {} +`) because only `rm -r -f` was refused. A find that
# deletes must be refused; a find that only lists, or runs a non-deleting command, passes.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run, and never
# embedded in this test's own shell commands (this guard runs on the runner's Bash calls).
#
# Run: bash .claude/hooks/tests/test-destructive-guard-find-delete.sh

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

# === forms the red team found allowed ===
expect "find ~ -delete" block 'find ~ -delete'
expect "find \$HOME -mindepth 1 -delete" block 'find "$HOME" -mindepth 1 -delete'
expect "find -exec rm -f {} +" block "find ~ -name '*.md' -exec rm -f {} +"
expect "find -exec /bin/rm" block 'find . -type f -exec /bin/rm {} \;'
expect "find -exec unlink" block 'find ~/IWE -exec unlink {} \;'
expect "find -exec shred -u" block 'find ~ -type f -exec shred -u {} +'
expect "find -execdir rm" block 'find . -execdir rm {} \;'
expect "find -ok rm" block 'find . -ok rm {} \;'

# === the same through wrappers and a shell string ===
expect "sudo find -delete" block 'sudo find / -delete'
expect "bash -c with find -delete" block 'bash -c "find ~ -delete"'
expect "find -delete after another command" block 'ls ~ && find ~/x -delete'

# === non-deleting finds stay allowed ===
expect "find -name -print" pass "find . -name '*.sh' -print"
expect "find -exec grep" pass 'find . -type f -exec grep -l rm {} +'
expect "find whose name pattern mentions delete" pass "find . -name '-delete-me.txt'"
expect "grep for the text find -delete" pass "grep -rn 'find -delete' docs/"
expect "find -newer and -empty, no delete" pass 'find /tmp -empty -newer x'

echo "find-delete: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
