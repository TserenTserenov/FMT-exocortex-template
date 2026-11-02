#!/bin/bash
# detector_pattern_awareness.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Detector)
# event_type: agent_incident
# cost_class: free (rule-based, grep on file content)
# runtime: shell
# triggers: PostToolUse
#
# WP-217 Phase 8.5. Detects pattern P1 (DP.FM.011): writing a new rule
# into feedback_*.md without a reference to a catalog pattern DP.FM.010.
#
# Logic:
#   1. Fires on Write/Edit/MultiEdit to a file matching feedback_*.md.
#   2. Reads the file content after the write.
#   3. Checks the last added block for:
#      - the field "pattern: P{N}" (explicit reference)
#      - or the quote "DP.FM." (catalog reference)
#   4. If there is no reference — emit agent_incident with pattern=P1_not_capturing.
#   5. NEVER blocks (exit 0). Warn-before-block principle.
#
# Heuristic: look at the "fresh" lines of the file (last 30 lines after the write),
# since rules are appended to the end of the file. This is v1 — no diff, no git blame.
# v2: use tool_input.old_string/new_string from the Edit event.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# PostToolUse only
[ "$HOOK_EVENT" != "PostToolUse" ] && exit 0

# Write / Edit / MultiEdit only
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# feedback_*.md files only
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
if [[ "$BASENAME" != feedback_*.md ]]; then
  exit 0
fi

# The file must exist and be readable
if [ ! -f "$FILE_PATH" ] || [ ! -r "$FILE_PATH" ]; then
  exit 0
fi

# ── Determine target_repo ───────────────────────────────────────────────────
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
DETECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$DETECTOR_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1
TARGET_REPO_HINT=""

if [[ "$FILE_PATH" == /* ]]; then
  DIR=$(dirname "$FILE_PATH")
  if [ -d "$DIR" ]; then
    DIR_REAL=$(cd "$DIR" 2>/dev/null && pwd -P)
    BASENAME_FILE=$(basename "$FILE_PATH")
    FILE_PATH="$DIR_REAL/$BASENAME_FILE"
    GIT_ROOT=$(cd "$DIR_REAL" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$GIT_ROOT" ]; then
      TARGET_REPO_HINT="$GIT_ROOT"
    fi
  fi
fi

if [ -z "$TARGET_REPO_HINT" ] && [ -n "$CWD" ]; then
  if [[ "$CWD" == "$IWE_ROOT"/* ]]; then
    REL="${CWD#$IWE_ROOT/}"
    FIRST_SEG="${REL%%/*}"
    if [ -n "$FIRST_SEG" ] && [ -d "$IWE_ROOT/$FIRST_SEG" ]; then
      TARGET_REPO_HINT="$IWE_ROOT/$FIRST_SEG"
    fi
  fi
fi

# OwnerIntegrity: do not guess the repo
if [ -z "$TARGET_REPO_HINT" ]; then
  exit 0
fi

# ── Check for a pattern reference ──────────────────────────────────────────────
# Look at the last 30 lines of the file (heuristic: the rule is appended to the end).
# Look for signs of an explicit pattern reference:
#   - "pattern: P" (frontmatter-style or inline)
#   - "DP.FM." (catalog reference)
#   - "P1" / "P2" / ... "P10" as a separate word (weak marker)

TAIL_CONTENT=$(tail -30 "$FILE_PATH" 2>/dev/null || true)

if [ -z "$TAIL_CONTENT" ]; then
  exit 0
fi

# Strong signs of a reference → do NOT emit
if echo "$TAIL_CONTENT" | grep -qiE '(pattern:\s*P[0-9]|DP\.FM\.[0-9])'; then
  exit 0
fi

# Weak signs (self-sufficient words P1..P10) → do NOT emit
# Pattern: P{N} as a separate word (not P1a, not P10x).
# BSD grep does not support \b, use ERE with spaces/start/end of line.
if echo "$TAIL_CONTENT" | grep -qE '(^|[[:space:]])P([1-9]|10)([[:space:],\.)]|$)'; then
  exit 0
fi

# ── Emit P1_not_capturing ────────────────────────────────────────────────────
# Last 200 characters of the content as context
# tr -d control chars: prevents jq parse error from \r, \0, etc.
SNIPPET=$(tail -10 "$FILE_PATH" 2>/dev/null | tr -d '\000-\037' | head -c 200 || true)

jq -n \
  --arg pattern "P1_not_capturing" \
  --arg severity "minor" \
  --arg description "Write в ${BASENAME} без ссылки на паттерн (pattern: P{N} / DP.FM.). Проверь DP.FM.010 перед записью нового правила (DP.FM.011 §Correction)." \
  --arg file_path "$FILE_PATH" \
  --arg tool_name "$TOOL_NAME" \
  --arg snippet "$SNIPPET" \
  --arg hint "$TARGET_REPO_HINT" \
  '{
    event_type: "agent_incident",
    payload: {
      pattern: $pattern,
      severity: $severity,
      description: $description,
      tool_context: {
        tool_name: $tool_name,
        file_path: $file_path,
        snippet: $snippet
      }
    },
    repo_ctx: {
      target_repo_hint: $hint
    }
  }'

exit 0
