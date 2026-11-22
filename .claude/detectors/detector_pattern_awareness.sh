#!/bin/bash
# detector_pattern_awareness.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Detector)
# event_type: agent_incident
# cost_class: free (rule-based, grep on file contents)
# runtime: shell
# triggers: PostToolUse
#
# WP-217 Phase8.5. Detects pattern P1 (DP.FM.011): writing a new rule
# in feedback_*.md without a reference to the pattern catalog DP.FM.010.
#
# Logic:
#   1. Triggers on Write/Edit/MultiEdit to file matching feedback_*.md.
#   2. Reads the file contents after writing.
#   3. Checks the last added block for the presence of:
#      - field "pattern: P{N}" (explicit reference)
#      - or mention of "DP.FM." (reference to catalog)
#   4. If no reference is found — emit agent_incident with pattern=P1_not_capturing.
#   5. NEVER blocks (exit 0). Principle warn-before-block.
#
# Heuristic: we look at "fresh" lines of the file (last 30 lines after write),
# i.e..because. rules are appended to the end of the file. This is v1 — without diff, without git blame.
# v2: use tool_input.old_string/new_string from Edit-event.

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

# Only PostToolUse
[ "$HOOK_EVENT" != "PostToolUse" ] && exit 0

# Only Write / Edit / MultiEdit
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# Only feedback_*.md files
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

# ── Determining target_repo ───────────────────────────────────────────────────
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

# ── Checking for pattern reference ──────────────────────────────────────────────
# We look at the last 30 lines of the file (heuristic: rule was appended to the end).
# Looking for signs of an explicit pattern reference:
#   - "pattern: P" (frontmatter-style or inline)
#   - "DP.FM." (reference to catalog)
#   - "P1" / "P2" / ... "P10" as a standalone word (weak marker)

TAIL_CONTENT=$(tail -30 "$FILE_PATH" 2>/dev/null || true)

if [ -z "$TAIL_CONTENT" ]; then
  exit 0
fi

# Strong indicators of a reference presence → NOT emit
if echo "$TAIL_CONTENT" | grep -qiE '(pattern:\s*P[0-9]|DP\.FM\.[0-9])'; then
  exit 0
fi

# Weak indicators (self-contained words P1..P10) → NOT emit
# Pattern: P{N} as a standalone word (not P1a, not P10x).
# BSD grep does not support \b, use ERE with spaces/start of line/end of line.
if echo "$TAIL_CONTENT" | grep -qE '(^|[[:space:]])P([1-9]|10)([[:space:],\.)]|$)'; then
  exit 0
fi

# ── Emit P1_not_capturing ────────────────────────────────────────────────────
# Last 200 characters of content as context
# tr -d control chars: prevents jq parse error from-due to \r, \0, etc.
SNIPPET=$(tail -10 "$FILE_PATH" 2>/dev/null | tr -d '\000-\037' | head -c 200 || true)

jq -n \
  --arg pattern "P1_not_capturing" \
  --arg severity "minor" \
  --arg description "Write to ${BASENAME} without a reference to the pattern (pattern: P{N} / DP.FM.). Check DP.FM.010 before writing a new rule (DP.FM.011 §Correction)." \
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
