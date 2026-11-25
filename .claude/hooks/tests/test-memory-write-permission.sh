#!/usr/bin/env bash
# Tests for .claude/hooks/memory-write-permission.sh (issue #1487).
# The hook gets PermissionRequest JSON on stdin and prints an allow decision only for
# writes that go through <workspace>/memory/ into THIS project's auto-memory folder.
# Every case also requires an empty stderr, so a crash inside the hook cannot pass as "silent".
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/memory-write-permission.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ERR="$TMP/stderr"

# slug_of <dir>: the project folder name Claude Code derives from the real path
slug_of() { (cd "$1" && pwd -P) | sed 's/[^A-Za-z0-9]/-/g'; }

CONFIG="$TMP/claude-config"
WS="$TMP/ws"
mkdir -p "$WS" "$TMP/outside"
SLUG="$(slug_of "$WS")"
MEM="$CONFIG/projects/$SLUG/memory"
mkdir -p "$MEM" "$CONFIG/projects/$SLUG/memory-evil" "$CONFIG/projects/-other-project/memory"
ln -s "$MEM" "$WS/memory"
ln -s "$TMP/outside" "$MEM/escape"          # a symlink INSIDE memory pointing out of it
mkdir -p "$MEM/sub" "$MEM/.git/hooks" "$MEM/.claude" "$MEM/.ssh" "$MEM/.github" "$MEM/.gnupg" "$MEM/sub/.hidden"

EXPECTED_ALLOW='{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}'
FAIL=0
PASS=0

# payload <mode> <tool> <path>: PermissionRequest JSON on stdout
payload() {
  local field="file_path"
  [ "$2" = "NotebookEdit" ] && field="notebook_path"
  jq -n --arg m "$1" --arg t "$2" --arg f "$field" --arg p "$3" \
    '{permission_mode:$m, tool_name:$t, tool_input:{($f):$p}}'
}

# run_hook <project dir> <stdin json> [env assignments...]: prints stdout, stderr goes to $ERR
run_hook() {
  local project="$1" json="$2"
  shift 2
  printf '%s' "$json" |
    env CLAUDE_PROJECT_DIR="$project" CLAUDE_CONFIG_DIR="$CONFIG" "$@" bash "$HOOK" 2>"$ERR"
}

# call <mode> <tool> <path> [env...]: the common case, workspace $WS
call() {
  local mode="$1" tool="$2" path="$3"
  shift 3
  run_hook "$WS" "$(payload "$mode" "$tool" "$path")" "$@"
}

check_stderr() {
  if [ -s "$ERR" ]; then
    echo "FAIL (stderr not empty): $1: $(head -c 300 "$ERR")"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

expect_allow() {
  local name="$1" out="$2" got
  check_stderr "$name" || return
  # jq prints the documents it could parse before a syntax error, so its exit status matters too.
  got="$(printf '%s' "$out" | jq -cS . 2>/dev/null)" || got="INVALID JSON: $out"
  if [ "$got" = "$EXPECTED_ALLOW" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected exactly one allow decision): $name; got: $out"
    FAIL=$((FAIL + 1))
  fi
}

expect_silent() {
  local name="$1" out="$2"
  check_stderr "$name" || return
  if [ -z "$out" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected no output): $name; got: $out"
    FAIL=$((FAIL + 1))
  fi
}

# --- approved: through <workspace>/memory/ into this project's auto-memory
expect_allow "write through the memory symlink, auto mode" "$(call auto Write "$WS/memory/note.md")"
expect_allow "edit through the symlink, acceptEdits mode" "$(call acceptEdits Edit "$WS/memory/note.md")"
expect_allow "MultiEdit through the symlink" "$(call auto MultiEdit "$WS/memory/note.md")"
expect_allow "NotebookEdit through the symlink" "$(call auto NotebookEdit "$WS/memory/n.ipynb")"
expect_allow "file in an existing subfolder" "$(call auto Write "$WS/memory/sub/note.md")"
expect_allow "extra slashes in the path" "$(call auto Write "$WS/memory//sub///note.md")"

expect_allow "ordinary name containing git is fine" "$(call auto Write "$WS/memory/sub/my.github-notes.md")"

# --- not approved: sensitive places inside memory keep their own confirmation
expect_silent "git hook inside memory" "$(call auto Write "$WS/memory/.git/hooks/pre-commit")"
expect_silent "dot-claude inside memory" "$(call auto Write "$WS/memory/.claude/settings.json")"
expect_silent "dot-github inside memory" "$(call auto Write "$WS/memory/.github/workflows/x.yml")"
expect_silent "dot-ssh inside memory" "$(call auto Write "$WS/memory/.ssh/authorized_keys")"
expect_silent "dot-gnupg inside memory" "$(call auto Write "$WS/memory/.gnupg/x")"
expect_silent "dotfile in memory root" "$(call auto Write "$WS/memory/.bashrc")"
expect_silent "dotfile in a subfolder" "$(call auto Write "$WS/memory/sub/.env")"
expect_silent "hidden subfolder" "$(call auto Write "$WS/memory/sub/.hidden/note.md")"
expect_silent "upper-case .GIT component" "$(call auto Write "$WS/memory/.GIT/config")"

# --- not approved: mode, tool, path shape
expect_silent "default mode keeps the prompt" "$(call default Write "$WS/memory/note.md")"
expect_silent "plan mode keeps the prompt" "$(call plan Write "$WS/memory/note.md")"
expect_silent "unknown mode" "$(call somethingNew Write "$WS/memory/note.md")"
expect_silent "other tool (Bash)" "$(call auto Bash "$WS/memory/note.md")"
expect_silent "workspace file next to memory" "$(call auto Write "$WS/CLAUDE.md")"
expect_silent "dot-dot out of memory" "$(call auto Write "$WS/memory/../CLAUDE.md")"
expect_silent "dot-dot back out through the real path" "$(call auto Write "$WS/memory/../../other.md")"
expect_silent "memory itself, not a file inside" "$(call auto Write "$WS/memory")"
expect_silent "symlink inside memory pointing outside" "$(call auto Write "$WS/memory/escape/x.md")"
expect_silent "relative path" "$(call auto Write "memory/note.md")"
expect_silent "parent folder does not exist" "$(call auto Write "$WS/memory/new-dir/note.md")"
expect_silent "real path written directly (Claude Code approves it itself)" "$(call auto Write "$MEM/note.md")"
expect_silent "sibling folder with the same prefix" "$(call auto Write "$CONFIG/projects/$SLUG/memory-evil/x.md")"
expect_silent "opt-out switch" "$(call auto Write "$WS/memory/note.md" IWE_MEMORY_WRITE_AUTO_APPROVE=0)"

# --- not approved: malformed input
expect_silent "malformed JSON" "$(run_hook "$WS" 'not json')"
[ "$(printf 'not json' | env CLAUDE_PROJECT_DIR="$WS" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK" >/dev/null 2>&1; echo $?)" = 0 ] \
  && PASS=$((PASS + 1)) || { echo "FAIL: malformed JSON must exit 0"; FAIL=$((FAIL + 1)); }
expect_silent "no tool_input" "$(run_hook "$WS" '{"permission_mode":"auto","tool_name":"Write"}')"
expect_silent "tool_input without a path" "$(run_hook "$WS" '{"permission_mode":"auto","tool_name":"Write","tool_input":{}}')"
expect_silent "path is null" "$(run_hook "$WS" '{"permission_mode":"auto","tool_name":"Write","tool_input":{"file_path":null}}')"
expect_silent "path is a number" "$(run_hook "$WS" '{"permission_mode":"auto","tool_name":"Write","tool_input":{"file_path":42}}')"
expect_silent "payload is a list" "$(run_hook "$WS" '[1,2]')"
expect_silent "workspace unknown" "$(printf '%s' "$(payload auto Write "$WS/memory/note.md")" |
  env -u CLAUDE_PROJECT_DIR -u IWE_WORKSPACE CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK" 2>"$ERR")"

# --- not approved: the memory symlink is not THIS project's auto-memory
# (a) a repository ships memory -> another project's memory
OTHER_WS="$TMP/other-ws"
mkdir -p "$OTHER_WS"
ln -s "$CONFIG/projects/-other-project/memory" "$OTHER_WS/memory"
expect_silent "memory symlink to another project's memory" \
  "$(run_hook "$OTHER_WS" "$(payload auto Write "$OTHER_WS/memory/x.md")")"

# (b) a repository ships memory -> a folder named "memory" outside the Claude config
HOSTILE="$TMP/hostile-ws"
mkdir -p "$HOSTILE" "$TMP/evil/memory"
ln -s "$TMP/evil/memory" "$HOSTILE/memory"
expect_silent "memory symlink outside the Claude projects folder" \
  "$(run_hook "$HOSTILE" "$(payload auto Write "$HOSTILE/memory/authorized_keys")")"

# (c) the right project folder but the target is not named memory
NAMED="$TMP/named-ws"
mkdir -p "$NAMED"
mkdir -p "$CONFIG/projects/$(slug_of "$NAMED")/notes"
ln -s "$CONFIG/projects/$(slug_of "$NAMED")/notes" "$NAMED/memory"
expect_silent "symlink target not named memory" \
  "$(run_hook "$NAMED" "$(payload auto Write "$NAMED/memory/x.md")")"

# (d) memory is a plain directory (here even inside the right projects/<slug>/): no symlink prompt exists
PLAIN="$TMP/plain-ws"
mkdir -p "$PLAIN" "$PLAIN/memory"
mkdir -p "$CONFIG/projects/$(slug_of "$PLAIN")/memory"
expect_silent "memory is a real directory" \
  "$(run_hook "$PLAIN" "$(payload auto Write "$PLAIN/memory/x.md")")"

# (e) environment substitution: another config folder, another project name
mkdir -p "$TMP/fake-config/projects/$SLUG/memory"
expect_silent "CLAUDE_CONFIG_DIR points elsewhere (the symlink no longer matches)" \
  "$(call auto Write "$WS/memory/note.md" CLAUDE_CONFIG_DIR="$TMP/fake-config")"
expect_silent "CLAUDE_CODE_PROJECT_DIR_NAME names another project" \
  "$(call auto Write "$WS/memory/note.md" CLAUDE_CODE_PROJECT_DIR_NAME=-other-project)"
expect_allow "CLAUDE_CODE_PROJECT_DIR_NAME names this project's folder" \
  "$(call auto Write "$WS/memory/note.md" CLAUDE_CODE_PROJECT_DIR_NAME="$SLUG")"

# --- paths with spaces still work
SP="$TMP/space ws"
mkdir -p "$SP"
SPMEM="$CONFIG/projects/$(slug_of "$SP")/memory"
mkdir -p "$SPMEM"
ln -s "$SPMEM" "$SP/memory"
expect_allow "workspace path with a space" "$(run_hook "$SP" "$(payload auto Write "$SP/memory/my note.md")")"

echo "memory-write-permission: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
