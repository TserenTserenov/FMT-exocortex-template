#!/bin/bash
# inject-fault-profile.sh
# Event: UserPromptSubmit
# Purpose: inject the recurring agent error profile into the system prompt
#             BEFORE the first task in the session. Replacement of the section «Error Profile» in DayPlan
#             (which was shown to the pilot — which is incorrect: the profile is intended for the agent).
#
# Architecture: calls the single scripts/agent-fault/iwe_checklist_memory.py
#             remind --protocol open with an explicit subject → parses the output
#             → returns additionalContext with top-3 critical reminders.
#
# see: peer-session 2026-05-30-07-gap-list-day-open sub-step 3
# see: WP-356 «Pipeline Day Open: auto-run checks»
# see: WP-316 (Agent Fault Profile, data source)
#
# Behavior:
# - Activated once per session (state-file `.claude/state/fault-profile-injected-<session_id>`)
# - If the profile DB is absent — silent skip
# - If there are no reminders with n≥3 — silent skip
# - Otherwise — additionalContext with 2-3 reminders

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq is required for both input parsing and JSON output — without it the hook
# cannot honor the UserPromptSubmit protocol, so degrade to a silent no-op.
if ! command -v jq >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

INPUT=$(cat 2>/dev/null || echo '{}')
# session_id lands in a filesystem path below — strip everything outside
# [A-Za-z0-9_-] so a hostile/matformed value cannot traverse directories.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | cut -c1-64)
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/fault-profile-injected-$SESSION_ID"

# Only one injection per session
if [ -f "$STATE_FILE" ]; then
  echo '{}'
  exit 0
fi

if [ "${IWE_FAULT_SUBJECT_KIND+x}" != x ] && \
   [ "${IWE_FAULT_SUBJECT_ID+x}" != x ]; then
  SUBJECT_KIND="runtime"
  SUBJECT_ID="claude-code"
elif [ "${IWE_FAULT_SUBJECT_KIND+x}" = x ] && \
     [ "${IWE_FAULT_SUBJECT_ID+x}" = x ]; then
  SUBJECT_KIND="$IWE_FAULT_SUBJECT_KIND"
  SUBJECT_ID="$IWE_FAULT_SUBJECT_ID"
else
  echo '{}'
  exit 0
fi
case "$SUBJECT_KIND" in
  personality|runtime|system) ;;
  *) echo '{}'; exit 0 ;;
esac
if [ -z "$SUBJECT_ID" ]; then
  echo '{}'
  exit 0
fi

PYTHON_BIN=$(command -v python3 2>/dev/null || true)
if [ -z "$PYTHON_BIN" ]; then
  echo '{}'
  exit 0
fi

resolve_workspace_cli() {
  "$PYTHON_BIN" - "$PROJECT_DIR" "$1" <<'PYEOF'
import os
from pathlib import Path
import sys


try:
    workspace = Path(sys.argv[1]).resolve(strict=True)
    candidate = Path(sys.argv[2]).expanduser().resolve(strict=True)
    if os.path.commonpath((str(workspace), str(candidate))) != str(workspace):
        raise ValueError("candidate escapes physical workspace")
    if not candidate.is_file():
        raise ValueError("candidate is not a regular file")
except (OSError, ValueError):
    raise SystemExit(1)
print(candidate)
PYEOF
}

REMIND_SCRIPT=""
WORKSPACE_REMIND_SCRIPT="$PROJECT_DIR/scripts/agent-fault/iwe_checklist_memory.py"
TEMPLATE_REMIND_SCRIPT="$PROJECT_DIR/IWE/scripts/agent-fault/iwe_checklist_memory.py"
for candidate in "$WORKSPACE_REMIND_SCRIPT" "$TEMPLATE_REMIND_SCRIPT"; do
  if resolved_candidate=$(resolve_workspace_cli "$candidate" 2>/dev/null); then
    REMIND_SCRIPT="$resolved_candidate"
    break
  fi
done
if [ -z "$REMIND_SCRIPT" ] && [ -n "${IWE_SCRIPTS:-}" ]; then
  if resolved_candidate=$(resolve_workspace_cli \
      "$IWE_SCRIPTS/agent-fault/iwe_checklist_memory.py" 2>/dev/null); then
    REMIND_SCRIPT="$resolved_candidate"
  fi
fi
if [ -z "$REMIND_SCRIPT" ]; then
  echo '{}'
  exit 0
fi
REMIND_ARGS=(
  "$REMIND_SCRIPT" remind
  --protocol open
  --subject-kind "$SUBJECT_KIND"
  --subject-id "$SUBJECT_ID"
)

# Run the script (with timeout if available, otherwise without — on macOS not available timeout by default)
if command -v timeout >/dev/null 2>&1; then
  REMIND_OUT=$(IWE_WORKSPACE="$PROJECT_DIR" timeout 5 "$PYTHON_BIN" "${REMIND_ARGS[@]}" 2>/dev/null || echo "")
elif command -v gtimeout >/dev/null 2>&1; then
  REMIND_OUT=$(IWE_WORKSPACE="$PROJECT_DIR" gtimeout 5 "$PYTHON_BIN" "${REMIND_ARGS[@]}" 2>/dev/null || echo "")
else
  # Fallback without timeout — script is fast (sqlite-read)
  REMIND_OUT=$(IWE_WORKSPACE="$PROJECT_DIR" "$PYTHON_BIN" "${REMIND_ARGS[@]}" 2>/dev/null || echo "")
fi
if [ -z "$REMIND_OUT" ]; then
  echo '{}'
  exit 0
fi

# Parsing lines of format: "🔴 [CRITICAL | n=8] WP context is read bottom-up..."
# Take top-3 with n >= 3 (statistically significant)
RELEVANT=$(echo "$REMIND_OUT" | grep -E "^🔴 \[(CRITICAL|MAJOR) \| n=[0-9]+\]" | head -3)
if [ -z "$RELEVANT" ]; then
  echo '{}'
  exit 0
fi

# Build additionalContext
CONTEXT="## 🧠 Recurring agent fault profile (n≥3 across session history)

Apply BEFORE the first Read/Write/Bash in the session. Source: unified \`agent-fault\` CLI (private database \`exocortex/agent-fault-profile/iwe_memory.db\`, subject \`$SUBJECT_KIND:$SUBJECT_ID\`).

$RELEVANT

Rule source: WP-316 (Session Memory). Do not show to the user — this is an internal agent tool.
"

# Write state-file
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Cleanup old state-files (>24h)
find "$STATE_DIR" -name "fault-profile-injected-*" -mmin +1440 -delete 2>/dev/null || true

# Return JSON with additionalContext (Claude Code UserPromptSubmit hook protocol)
jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
