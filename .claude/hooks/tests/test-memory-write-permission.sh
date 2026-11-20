#!/usr/bin/env bash
# Tests for .claude/hooks/memory-write-permission.sh (issue #1487).
# The hook gets PermissionRequest JSON on stdin and prints an allow decision only for
# writes that land (after resolving symlinks) inside the agent's auto-memory folder.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/memory-write-permission.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CONFIG="$TMP/claude-config"
WS="$TMP/ws"
MEM="$CONFIG/projects/-ws/memory"
mkdir -p "$MEM" "$WS" "$TMP/outside" "$CONFIG/projects/-ws/memory-evil"
ln -s "$MEM" "$WS/memory"
ln -s "$TMP/outside" "$MEM/escape"          # a symlink INSIDE memory pointing out of it

FAIL=0
PASS=0

# run_hook <mode> <tool> <path> [extra env assignments...] -> prints the hook's stdout
run_hook() {
  local mode="$1" tool="$2" path="$3"
  shift 3
  local field="file_path"
  [ "$tool" = "NotebookEdit" ] && field="notebook_path"
  jq -n --arg m "$mode" --arg t "$tool" --arg f "$field" --arg p "$path" \
    '{permission_mode:$m, tool_name:$t, tool_input:{($f):$p}}' |
    env CLAUDE_PROJECT_DIR="$WS" CLAUDE_CONFIG_DIR="$CONFIG" "$@" bash "$HOOK"
}

expect_allow() {
  local name="$1" out="$2"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == "allow"' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected allow): $name; got: $out"
    FAIL=$((FAIL + 1))
  fi
}

expect_silent() {
  local name="$1" out="$2"
  if [ -z "$out" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL (expected no output): $name; got: $out"
    FAIL=$((FAIL + 1))
  fi
}

expect_allow "write through the memory symlink, auto mode" "$(run_hook auto Write "$WS/memory/note.md")"
expect_allow "write by the real path, auto mode" "$(run_hook auto Write "$MEM/note.md")"
expect_allow "edit through the symlink, acceptEdits mode" "$(run_hook acceptEdits Edit "$WS/memory/note.md")"
expect_allow "MultiEdit through the symlink" "$(run_hook auto MultiEdit "$WS/memory/note.md")"
expect_allow "NotebookEdit through the symlink" "$(run_hook auto NotebookEdit "$WS/memory/n.ipynb")"
expect_allow "new file in a new subfolder of memory" "$(run_hook auto Write "$WS/memory/new-dir/note.md")"

expect_silent "default mode keeps the prompt" "$(run_hook default Write "$WS/memory/note.md")"
expect_silent "plan mode keeps the prompt" "$(run_hook plan Write "$WS/memory/note.md")"
expect_silent "other tool (Bash)" "$(run_hook auto Bash "$WS/memory/note.md")"
expect_silent "workspace file next to memory" "$(run_hook auto Write "$WS/CLAUDE.md")"
expect_silent "dot-dot out of memory" "$(run_hook auto Write "$WS/memory/../CLAUDE.md")"
expect_silent "dot-dot out of the real memory path" "$(run_hook auto Write "$MEM/../other.md")"
expect_silent "memory itself, not a file inside" "$(run_hook auto Write "$WS/memory")"
expect_silent "symlink inside memory pointing outside" "$(run_hook auto Write "$WS/memory/escape/x.md")"
expect_silent "sibling folder with the same prefix" "$(run_hook auto Write "$CONFIG/projects/-ws/memory-evil/x.md")"
expect_silent "relative path" "$(run_hook auto Write "memory/note.md")"
expect_silent "opt-out switch" "$(run_hook auto Write "$WS/memory/note.md" IWE_MEMORY_WRITE_AUTO_APPROVE=0)"

# A repository that ships its own memory symlink to somewhere outside projects/ is not approved.
HOSTILE="$TMP/hostile-ws"
mkdir -p "$HOSTILE" "$TMP/evil/memory" "$TMP/ssh"
ln -s "$TMP/evil/memory" "$HOSTILE/memory"      # target is NAMED "memory" but lives outside projects/
out=$(jq -n --arg p "$HOSTILE/memory/authorized_keys" \
  '{permission_mode:"auto", tool_name:"Write", tool_input:{file_path:$p}}' |
  env CLAUDE_PROJECT_DIR="$HOSTILE" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK")
expect_silent "memory symlink outside the Claude projects folder" "$out"

# A symlink inside projects/ whose target is not named "memory" is not the auto-memory folder.
mkdir -p "$CONFIG/projects/-ws/notes"
NAMED="$TMP/named-ws"
mkdir -p "$NAMED"
ln -s "$CONFIG/projects/-ws/notes" "$NAMED/memory"
out=$(jq -n --arg p "$NAMED/memory/x.md" \
  '{permission_mode:"auto", tool_name:"Write", tool_input:{file_path:$p}}' |
  env CLAUDE_PROJECT_DIR="$NAMED" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK")
expect_silent "symlink target not named memory" "$out"

# memory is a plain directory (here even inside projects/), not a symlink: no symlink prompt exists to answer.
PLAIN="$CONFIG/projects/plain-ws"
mkdir -p "$PLAIN/memory"
out=$(jq -n --arg p "$PLAIN/memory/x.md" \
  '{permission_mode:"auto", tool_name:"Write", tool_input:{file_path:$p}}' |
  env CLAUDE_PROJECT_DIR="$PLAIN" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK")
expect_silent "memory is a real directory" "$out"

# Broken input never breaks the session and never approves.
out=$(printf 'not json' | env CLAUDE_PROJECT_DIR="$WS" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK"); rc=$?
expect_silent "malformed JSON" "$out"
[ "$rc" -eq 0 ] && PASS=$((PASS + 1)) || { echo "FAIL: malformed JSON exit code $rc"; FAIL=$((FAIL + 1)); }
out=$(printf '{"permission_mode":"auto","tool_name":"Write"}' | env CLAUDE_PROJECT_DIR="$WS" CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK")
expect_silent "no tool_input" "$out"
out=$(jq -n --arg p "$WS/memory/note.md" '{permission_mode:"auto", tool_name:"Write", tool_input:{file_path:$p}}' |
  env -u CLAUDE_PROJECT_DIR -u IWE_WORKSPACE CLAUDE_CONFIG_DIR="$CONFIG" bash "$HOOK")
expect_silent "workspace unknown" "$out"

echo "memory-write-permission: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
