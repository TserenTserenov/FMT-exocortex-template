#!/bin/bash
# test-destructive-guard-path-spellings.sh — issue #1567, F1 of the v0.42.0 red team: the write
# to protective files (.claude/hooks, .claude/bin, settings*.json) was matched literally, so
# `.claude//hooks/x`, `./.claude/./hooks/x`, `.claude/hook?/x`, `.claude/{hooks,x}/x` and
# `.claude//settings.json` passed. Every spelling that names the same file must be refused; reads
# of the same paths and writes elsewhere still pass.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-path-spellings.sh

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

# === the spellings the red team used ===
expect "double slash" block 'cat README.md > .claude//hooks/destructive-guard.sh'
expect "dot components" block 'cat README.md > ./.claude/./hooks/destructive-guard.sh'
expect "glob in a component" block 'cat README.md > .claude/hook?/destructive-guard.sh'
expect "brace expansion" block 'cat README.md > .claude/{hooks,x}/destructive-guard.sh'
expect "double slash before settings" block 'cat README.md > .claude//settings.json'

# === the same class, other spellings ===
expect "parent component" block 'cat README.md > .claude/x/../hooks/destructive-guard.sh'
expect "star glob" block 'cat README.md > .claude/h*/destructive-guard.sh'
expect "bracket glob" block 'cat README.md > .claude/[h]ooks/destructive-guard.sh'
expect "glob on .claude itself" block 'cat README.md > .cl?ude/hooks/destructive-guard.sh'
expect "absolute with double slash" block 'cat README.md > "$HOME/IWE/.claude//hooks/x.sh"'
expect "quoted dot components" block "cat README.md > './.claude/./bin/guarded-rm'"
expect "append, double slash" block 'cat README.md >> .claude//hooks/x.sh'
expect "clobber, glob" block 'cat README.md >| .claude/hook?/x.sh'
expect "settings.local glob" block 'cat README.md > .claude/settings.loc*.json'
expect "tee, double slash" block 'echo x | tee .claude//bin/guarded-rm'
expect "tee -a, dot component" block 'echo x | tee -a ./.claude/./hooks/x.sh'
expect "inside bash -c" block "bash -c 'cat README.md > .claude//hooks/x.sh'"

# === WP-529 F275: here-doc input and comments do not lift the block ===
expect "empty here-doc onto a hook" block "cat > .claude//hooks/x.sh <<EOF
EOF"
expect "grep with a here-string onto settings" block 'grep x README.md > ./.claude/./settings.json <<< x'
expect "apostrophe in a comment hides the next line" block "ls # don't
cat README.md > .claude//hooks/x.sh"
expect "here-doc opener in a comment hides the next lines" block "ls # <<EOF
cat README.md > .claude//hooks/x.sh
EOF"
expect "comment quote, then tee into bin" block "ls # it's
echo x | tee .claude/bin/guarded-rm"

# === look-alikes stay allowed ===
expect "read a hook" pass 'cat .claude//hooks/destructive-guard.sh'
expect "grep hooks dir" pass 'grep -rn x ./.claude/./hooks 2>/dev/null'
expect "write another .claude dir" pass 'cat README.md > /tmp/.claude//skills/x.md'
expect "hooks outside .claude" pass 'cat README.md > /tmp/hooks//x.sh'
expect "settings outside .claude" pass 'echo {} > /tmp/x/settings.json'

echo "path-spellings: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
