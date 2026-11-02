#!/bin/bash
# inject-communication-style.sh
# Event: UserPromptSubmit
# see DP.SC.050 (promise "Unified conversational style of agents"), WP-388 Phase 8
#
# Purpose: deliver S0 base conversational style (SoT in Pack) + S1 author
#             add-ons into the Claude Code context BEFORE the reply. Replaces the fragile
#             pasting of a marker block into the generated CLAUDE.md / AGENTS.md (which are
#             overwritten by template-sync.sh / sync-agent-instructions.sh).
#
# Architecture (WP-388 Phase 8, ArchGate passed):
#   S0 = PACK-digital-platform/.../02-domain-entities/communication-style-base.md (read-only)
#   S1 = ${IWE_GOVERNANCE_REPO:-DS-strategy}/memory/communication-style-author.md (additive-only,
#        only through the personal dispatcher — available only to the author with PACK-rhetoric)
#   S2 = memory/communication-style-personal.md (additive-only, file fallback — WP-412 Phase 13).
#        The user copies memory/communication-style-personal-template.md under this name
#        and fills it in; the hook itself never reads the sample template.
#   Delivery = this hook (UserPromptSubmit). Generated files are not touched.
#
# Behavior (density-based reinjection, peer-session 2026-06-08-23):
# - Refreshed during the session: the first turn + as the conversation grows (not once)
# - L0 file missing → silent skip (echo '{}')
# - L1 file missing → inject only L0
# - Thresholds: STYLE_REINJECT_TURNS (12), STYLE_REINJECT_BYTES (60000)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq is needed for JSON output. No jq → quiet valid '{}', not empty stdout (otherwise Claude Code cannot parse it).
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
# Empty/broken id → unknown; sanitization against path traversal in the state file name
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/comm-style-injected-$SESSION_ID"

# Density-based reinjection: injection is NOT once per session, but refreshed along the way.
# Trigger: first turn OR >= N turns have passed OR the transcript has grown by >= M bytes.
REINJECT_EVERY_TURNS="${STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${STYLE_REINJECT_BYTES:-60000}"

# Current context volume — transcript size (if the harness passed it)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
CUR_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CUR_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ' || echo 0)
  [ -n "$CUR_BYTES" ] || CUR_BYTES=0
fi

# State: "turn last_inject_turn last_inject_bytes"
TURN=0; LAST_INJECT_TURN=0; LAST_INJECT_BYTES=0
if [ -f "$STATE_FILE" ]; then
  read -r TURN LAST_INJECT_TURN LAST_INJECT_BYTES < "$STATE_FILE" 2>/dev/null || true
  [ -n "${TURN:-}" ] || TURN=0
  [ -n "${LAST_INJECT_TURN:-}" ] || LAST_INJECT_TURN=0
  [ -n "${LAST_INJECT_BYTES:-}" ] || LAST_INJECT_BYTES=0
fi
TURN=$((TURN + 1))

DO_INJECT=0
if [ ! -f "$STATE_FILE" ]; then
  DO_INJECT=1                                                   # first turn
elif [ $((TURN - LAST_INJECT_TURN)) -ge "$REINJECT_EVERY_TURNS" ]; then
  DO_INJECT=1                                                   # by number of turns
elif [ "$CUR_BYTES" -gt 0 ] && [ $((CUR_BYTES - LAST_INJECT_BYTES)) -ge "$REINJECT_BYTES" ]; then
  DO_INJECT=1                                                   # by conversation volume
fi

# Not time to inject yet — update the turn counter and exit
if [ "$DO_INJECT" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  echo "$TURN $LAST_INJECT_TURN $LAST_INJECT_BYTES" > "$STATE_FILE"
  echo '{}'
  exit 0
fi

# Content: registry dispatcher (if available) → snapshot file s0-core.md → skip.
# Dispatcher: WP-412 Phase 6 (thin hook with the L0+L1+author cascade). The path to it goes through PROJECT_DIR.
# Snapshot file: WP-412 Phase 11 (FMT-fallback, self-sufficient). Path via BASH_SOURCE — works in env -i.
# Runtime mechanics (reinjection, state) stay in the hook. Rollback: git revert.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0_CORE="$HOOK_DIR/../styles/s0-core.md"

DISPATCHER="$PROJECT_DIR/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
if [ -f "$DISPATCHER" ]; then
  FRAGMENT=$(python3 "$DISPATCHER" --event userpromptsubmit-ide --quiet --no-cache 2>/dev/null)
fi

# If the dispatcher gave no content — read the snapshot file (cut the frontmatter between --- --- )
if [ -z "${FRAGMENT:-}" ] && [ -f "$S0_CORE" ]; then
  FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$S0_CORE" 2>/dev/null)
fi

[ -n "${FRAGMENT:-}" ] || { echo '{}'; exit 0; }   # both sources empty/failed → skip (safe)

# S2: personal override of the template user (WP-412 Phase 13). A file separate from
# the sample template (communication-style-personal-template.md) — the hook
# never reads it, otherwise the placeholder instruction would land in the prompt as
# the "user's style" on every clean install. Empty/no file → simply
# do not add, FRAGMENT stays as it was (additive-only, does not block S0).
PERSONAL_OVERRIDE="$PROJECT_DIR/memory/communication-style-personal.md"
if [ -f "$PERSONAL_OVERRIDE" ]; then
  PERSONAL_FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$PERSONAL_OVERRIDE" 2>/dev/null)
  if [ -n "${PERSONAL_FRAGMENT//[$' \t\n']/}" ]; then
    FRAGMENT="$FRAGMENT

$PERSONAL_FRAGMENT"
  fi
fi

CONTEXT="## 🗣 Разговорный стиль IWE (S0 база + S1 автор) — применять при ответе человеку

Источник истины: \`DP.SC.050\` (Pack). Канал-детектор: технический режим — для стенограмм/commit/PR; «на пальцах» — для чата с пилотом и §1-§4 синтеза report.md.

$FRAGMENT"

# Write state: current turn = last injection, remember the transcript bytes
mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"

# Cleanup of old state files (>24h)
find "$STATE_DIR" -name "comm-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

# JSON for the Claude Code UserPromptSubmit hook
jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
