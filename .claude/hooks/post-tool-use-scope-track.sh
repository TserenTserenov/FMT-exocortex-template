#!/bin/bash
# post-tool-use-scope-track.sh — route PostToolUse file scope to the exact
# session semaphore through session-guard.  The small bootstrap before stdin
# is consumed is intentional: project-relative settings execute the snapshot
# stored in a linked worktree, so that snapshot must trampoline to the primary
# worktree's current hook before parsing the one-shot hook payload.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

_primary_worktree() { # <project dir>
  local project="$1" top common primary primary_top primary_common
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 1
  common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common="$top/$common" ;;
  esac
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  case "$common" in
    */.git) primary="${common%/.git}" ;;
    *)
      primary=$(git -C "$top" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
      ;;
  esac
  [ -n "$primary" ] || return 1
  primary_top=$(git -C "$primary" rev-parse --show-toplevel 2>/dev/null) || return 1
  primary_top=$(cd "$primary_top" 2>/dev/null && pwd -P) || return 1
  [ "$primary_top" = "$(cd "$primary" 2>/dev/null && pwd -P)" ] || return 1
  primary_common=$(git -C "$primary_top" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$primary_common" in
    /*) : ;;
    *) primary_common="$primary_top/$primary_common" ;;
  esac
  primary_common=$(cd "$primary_common" 2>/dev/null && pwd -P) || return 1
  [ "$primary_common" = "$common" ] || return 1
  printf '%s\n' "$primary_top"
}

_trusted_hook() { # <path>
  python3 - "$1" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

path = sys.argv[1]
info = os.lstat(path)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.getuid()
    or info.st_nlink < 1
    or stat.S_IMODE(info.st_mode) & 0o022
):
    raise SystemExit(1)
PY
}

if [ "${IWE_SCOPE_HOOK_TRAMPOLINED:-0}" != "1" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_TOP=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  PRIMARY_TOP=$(_primary_worktree "$CLAUDE_PROJECT_DIR" 2>/dev/null || true)
  if [ -n "$PROJECT_TOP" ] && [ -n "$PRIMARY_TOP" ]; then
    PROJECT_TOP=$(cd "$PROJECT_TOP" 2>/dev/null && pwd -P) || exit 0
    if [ "$PROJECT_TOP" != "$PRIMARY_TOP" ]; then
      CANONICAL_HOOK="$PRIMARY_TOP/.claude/hooks/post-tool-use-scope-track.sh"
      [ -f "$CANONICAL_HOOK" ] && [ ! -L "$CANONICAL_HOOK" ] && _trusted_hook "$CANONICAL_HOOK" \
        || exit 0
      export IWE_SCOPE_HOOK_TRAMPOLINED=1
      export IWE_ROOT="$PRIMARY_TOP"
      export IWE_WORKSPACE="$PRIMARY_TOP"
      export CLAUDE_PROJECT_DIR="$PRIMARY_TOP"
      exec /bin/bash "$CANONICAL_HOOK"
    fi
    IWE_ROOT="${IWE_ROOT:-$PRIMARY_TOP}"
  fi
fi

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

HOOK_EVENT=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hook_event_name", ""))' 2>/dev/null || true)
[ "$HOOK_EVENT" = "PostToolUse" ] || exit 0
TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name", ""))' 2>/dev/null || true)
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

HARNESS_SESSION_ID=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id", ""))' 2>/dev/null || true)
FILE_PATH=$(printf '%s' "$INPUT" | python3 -c '
import json
import sys
tool_input = json.load(sys.stdin).get("tool_input", {})
print(tool_input.get("file_path", "") or tool_input.get("path", ""))
' 2>/dev/null || true)
[ -n "$HARNESS_SESSION_ID" ] && [ -n "$FILE_PATH" ] || exit 0
[[ "$HARNESS_SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || exit 0

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"
[[ "$AGENT" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || exit 0
[ -d "$SESSION_DIR" ] && [ -f "$SESSION_GUARD" ] || exit 0

# The harness id selects exactly one open receipt. The guard id is then read
# from that receipt and supplied explicitly; the singleton pointer is never an
# authority for a PostToolUse event from a concurrent worktree.
SEM_MATCHES=$(grep -lF "harness_session_id: $HARNESS_SESSION_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null || true)
SEM_COUNT=$(printf '%s\n' "$SEM_MATCHES" | grep -c . || true)
[ "$SEM_COUNT" -eq 1 ] || exit 0
SEM_FILE="$SEM_MATCHES"
GUARD_SESSION_IDS=$(sed -n 's/^session_id: //p' "$SEM_FILE" 2>/dev/null || true)
[ "$(printf '%s\n' "$GUARD_SESSION_IDS" | grep -c . || true)" -eq 1 ] || exit 0
GUARD_SESSION_ID="$GUARD_SESSION_IDS"
[[ "$GUARD_SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || exit 0
[ "$SEM_FILE" = "$SESSION_DIR/${AGENT}-${GUARD_SESSION_ID}.open" ] || exit 0

# Non-blocking by Claude hook contract; session-guard remains fail-closed for
# the mutation itself and never recreates a missing `.open`.
IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}" \
  bash "$SESSION_GUARD" note-file "$FILE_PATH" --agent "$AGENT" \
    --session-id "$GUARD_SESSION_ID" >/dev/null 2>&1 || true
exit 0
