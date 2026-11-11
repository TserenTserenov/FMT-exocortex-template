#!/bin/bash
# test-destructive-guard-git-branch-remote.sh — WP-529 Ф270, F2 of the v0.42.0-rc.4 red team:
# `git branch` and `git remote` are pre-approved in settings.json, so `git branch -D`, `git remote
# set-url` and the like ran without a prompt. Their writing forms are refused; listing passes.
# Same run also covers the two edge forms of the rc.4 Linux check: RIPGREP_CONFIG_PATH (an rg
# config may carry --pre) and a redirection or tee onto a protective file.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-git-branch-remote.sh

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

# === git branch: forms the red team ran, and their spellings ===
expect "branch -D" block 'git branch -D main'
expect "branch -d" block 'git branch -d feature'
expect "branch --delete" block 'git branch --delete feature'
expect "branch --del prefix" block 'git branch --del feature'
expect "branch -Dr cluster" block 'git branch -Dr origin/main'
expect "branch -f move" block 'git branch -f main HEAD~5'
expect "branch --force" block 'git branch --force main HEAD~5'
expect "branch --forc prefix" block 'git branch --forc main HEAD~5'
expect "branch -M rename over" block 'git branch -M old main'
expect "branch -m rename" block 'git branch -m main old'
expect "branch --move" block 'git branch --move main old'
expect "branch -C copy over" block 'git branch -C feature main'
expect "branch -D with -C dir" block 'git -C /repo branch -D main'
expect "branch -D after &&" block 'git status && git branch -D main'

# === git remote: forms the red team ran ===
expect "remote set-url" block 'git remote set-url origin https://example.invalid/x.git'
expect "remote remove" block 'git remote remove origin'
expect "remote rm" block 'git remote rm origin'
expect "remote add" block 'git remote add evil https://example.invalid/x.git'
expect "remote rename" block 'git remote rename origin old'
expect "remote -v set-url" block 'git remote -v set-url origin u'
expect "remote set-head" block 'git remote set-head origin -d'
expect "remote prune" block 'git remote prune origin'

# === edge forms of the rc.4 Linux check ===
expect "RIPGREP_CONFIG_PATH prefix" block 'RIPGREP_CONFIG_PATH=/tmp/rgrc rg foo'
expect "RIPGREP_CONFIG_PATH export" block 'export RIPGREP_CONFIG_PATH=/tmp/rgrc; rg foo'
expect "find > hook" block 'find . -maxdepth 0 -exec echo x \; > .claude/hooks/destructive-guard.sh'
expect "cat >> hook" block 'cat /dev/null >> .claude/hooks/secret-leak-block.sh'
expect "> settings.json" block 'echo {} > .claude/settings.json'
expect "> settings.local.json" block 'echo {} >.claude/settings.local.json'
expect "tee onto bin" block 'echo x | tee .claude/bin/guarded-rm'
expect "tee -a onto hook" block 'echo x | tee -a "$HOME/IWE/.claude/hooks/x.sh"'

# === listing and harmless forms pass ===
expect "branch list" pass 'git branch'
expect "branch -a -vv" pass 'git branch -a -vv'
expect "branch --list pattern" pass "git branch --list 'feat-*'"
expect "branch --show-current" pass 'git branch --show-current'
expect "branch --contains" pass 'git branch --contains HEAD'
expect "branch --merged" pass 'git branch --merged main'
expect "branch -r" pass 'git branch -r'
expect "branch create" pass 'git branch new-feature'
expect "git -C dir branch -vv" pass 'git -C /repo branch -vv'
expect "remote" pass 'git remote'
expect "remote -v" pass 'git remote -v'
expect "remote get-url" pass 'git remote get-url origin'
expect "remote show" pass 'git remote show origin'
expect "rg plain" pass 'rg -n foo .claude/hooks'
expect "redirect elsewhere" pass 'find .claude/hooks -name "*.sh" > /tmp/list.txt'
expect "read hook" pass 'cat .claude/hooks/destructive-guard.sh'
expect "grep 2>/dev/null" pass 'grep -r x .claude/hooks 2>/dev/null'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
