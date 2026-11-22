#!/usr/bin/env bash
# routing: hook  see DP.SC.048, DP.ROLE.062
# Pre-tool-use guard: blocks Write/Edit on paths SPF/, FPF/ when active
# skill session /pack-creator. Fail-safe against fatigue (DP.ROLE.062 §FM.02).
#
# Triggers only if the environment variable PACK_CREATOR_ACTIVE=1.
# Otherwise — pass-through (other skills are not blocked).
#
# Exit codes:
#   0 — action is allowed
#   2 — action is blocked (PreToolUse contract — Claude will receive an error)

set -uo pipefail

# If not in pack-creator — pass-through
if [ "${PACK_CREATOR_ACTIVE:-0}" != "1" ]; then
    exit 0
fi

# Read PreToolUse JSON from stdin (Claude Code formal contract)
# Parse in full (input may span one or multiple lines).
TOOL_NAME=""
FILE_PATH=""
PAYLOAD=$(cat)

case "$PAYLOAD" in
    *'"tool_name"'*)
        TOOL_NAME=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"tool_name":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
        ;;
esac
case "$PAYLOAD" in
    *'"file_path"'*)
        FILE_PATH=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"file_path":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
        ;;
esac
# NotebookEdit's real tool_input key is "notebook_path", not "file_path" --
# without this branch the guard silently passed through every NotebookEdit
# call despite listing it in the tool-name allow-list two lines below
# (found by adversarial review, 2026-10-06: a real NotebookEdit payload
# targeting SPF/ was not blocked).
if [ -z "$FILE_PATH" ]; then
    case "$PAYLOAD" in
        *'"notebook_path"'*)
            FILE_PATH=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"notebook_path":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
            ;;
    esac
fi

# Guard only Write/Edit/MultiEdit/NotebookEdit
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

# Check path path against blocked directories. $CLAUDE_PROJECT_DIR is Claude
# Code's own, always-set-in-a-real-session project root (same idiom already
# used in inject-fault-profile.sh and sibling hooks) -- a bare "$HOME/IWE"
# guessed wrong on any non-default workspace location, the same bug class
# issue #1094 fixes elsewhere in this template (found by adversarial
# review, 2026-10-06). The bare fallback stays only for this hook's own
# unit test, which runs outside a real Claude Code session.
IWE_HOME="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
case "$FILE_PATH" in
    "$IWE_HOME"/SPF/*|"$IWE_HOME"/FPF/*)
        cat >&2 <<EOF
🚫 BLOCKED by pack-creator-spf-guard (DP.ROLE.062 §FM.02)

Write to upstream-location is forbidden in /pack-creator:
  $FILE_PATH

This will break upgrade SPF during update.sh. Use extension-mechanism:
  → PACK-X/pack/X/<corresponding-section>/

See details: SPF/process/00-process-overview.md#extension-mechanism

If the change is systemic in nature (affects all Pack) — that is a separate
WP for editing SPF, not the work of /pack-creator. See. SPF/CLAUDE.md §8.1.
EOF
        exit 2
        ;;
esac

exit 0
