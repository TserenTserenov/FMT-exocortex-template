#!/bin/bash
# test-destructive-guard-find-delete.sh — WP-529 Ф270, RT-2 of the v0.42.0-rc.1 red team
# (and RT2-1 of rc.2: a wrapper after -exec, deletion carried by xargs; F2 of rc.3: find runs
# only commands that read, rg --pre is refused):
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

# === rc.2 red team (RT2-1): wrappers after -exec and deletion carried by xargs ===
expect "find -exec env rm" block 'find ~ -type f -exec env rm {} +'
expect "find -exec command rm" block 'find . -exec command rm {} \;'
expect "find -exec nice -n 5 rm" block 'find . -exec nice -n 5 rm {} +'
expect "find -exec busybox rm" block 'find . -exec busybox rm {} +'
expect "find -exec sudo -u x unlink" block 'find . -exec sudo -u x unlink {} \;'
expect "find | xargs -0 rm" block 'find ~ -type f -print0 | xargs -0 rm'
expect "find | xargs -n 1 /bin/rm" block 'find . -name x | xargs -n 1 /bin/rm'
expect "xargs env rm" block 'ls | xargs env rm'
expect "bash -c with find -exec env rm" block "bash -c 'find ~ -exec env rm {} +'"

# === rc.3 red team (F2): find runs only commands that read; rg --pre is refused ===
expect "find -exec sh -c rm" block "find ~ -type f -exec sh -c 'rm \"\$1\"' _ {} \;"
expect "find -exec bash -c" block "find . -exec bash -c 'true' \;"
expect "find -exec chrt rm" block 'find . -exec chrt -i 0 rm {} \;'
expect "find -exec truncate" block 'find . -exec truncate -s0 {} \;'
expect "find -exec cp /dev/null over the hook" block 'find . -maxdepth 0 -exec cp /dev/null .claude/hooks/destructive-guard.sh \;'
expect "find -exec mv" block 'find . -name x -exec mv {} /tmp/y \;'
expect "find -exec sed -i" block 'find . -name x -exec sed -i d {} +'
expect "find -exec sort -o" block 'find . -maxdepth 0 -exec sort -o .claude/hooks/destructive-guard.sh /dev/null \;'
expect "find -exec tee" block 'find . -maxdepth 0 -exec tee .claude/hooks/destructive-guard.sh \;'
expect "find -exec python3" block "find . -maxdepth 0 -exec python3 -c 'pass' \;"
expect "find -exec ln -sf" block 'find . -maxdepth 0 -exec ln -sf /dev/null .claude/hooks/destructive-guard.sh \;'
expect "rg --pre rm" block 'rg --pre rm x .'
expect "rg --pre=script" block 'rg --pre=./p.sh x'
expect "find -exec cat" pass 'find . -name "*.md" -exec cat {} +'
expect "find -exec sha256sum" pass 'find . -type f -exec sha256sum {} +'
expect "find -exec env grep" pass 'find . -exec env grep -l x {} +'
expect "rg plain search" pass "rg -n 'pre' docs/"

# === non-deleting finds stay allowed ===
expect "find -name -print" pass "find . -name '*.sh' -print"
expect "find -exec grep" pass 'find . -type f -exec grep -l rm {} +'
expect "find whose name pattern mentions delete" pass "find . -name '-delete-me.txt'"
expect "grep for the text find -delete" pass "grep -rn 'find -delete' docs/"
expect "find -newer and -empty, no delete" pass 'find /tmp -empty -newer x'
expect "find -exec env grep" pass 'find . -exec env grep -l rm {} +'
expect "xargs grep for rm" pass "git ls-files | xargs grep -n 'rm -f'"
expect "xargs echo" pass 'find . -name x | xargs echo'

echo "find-delete: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
