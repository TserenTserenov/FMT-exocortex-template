#!/bin/bash
# inject-communication-style.sh
# Event: UserPromptSubmit
# see DP.SC.050 (promise «Unified conversational style for agents»), WP-388 Phase8
#
# Purpose: deliver S0 base conversational style (SoT in Pack) + S1 author-level
#             extensions into the context Claude Code BEFORE the response. Replaces the fragile
#             insertion of a marker-block into the generated CLAUDE.md / AGENTS.md (which
#             are overwritten by template-sync.sh / sync-agent-instructions.sh template-sync.sh / sync-agent-instructions.sh).
#
# Architecture (WP-388 Phase8, ArchGate passed):
#   S0 = PACK-digital-platform/.../02-domain-entities/communication-style-base.md (read-only)
#   S1 = ${IWE_GOVERNANCE_REPO:-DS-strategy}/memory/communication-style-author.md (additive-only,
#        only through the personal dispatcher — accessible only to the author with PACK-rhetoric)
#   S2 = memory/communication-style-personal.md (additive-only, file-fallback — WP-412 Phase13).
#        The user copies memory/communication-style-personal-template.md under this name
#        and fills it in; template-sample template is never read by the hook itself.
#   Delivery = this hook (UserPromptSubmit). Generated files are not touched.
#
# Behavior (density-based reinjection, peer-session 2026-06-08-23):
# - Refreshed during the session: first turn + as the conversation grows (not just once)
# - L0-file is absent → silent skip (echo '{}')
# - L1-file is absent → inject only L0
# - Thresholds: STYLE_REINJECT_TURNS (12), STYLE_REINJECT_BYTES (60000)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# jq required for JSON output JSON. No jq → silent valid '{}', not empty stdout (otherwise Claude Code will not be parsed).
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
# Empty/malformed id → unknown; sanitization against path traversal in the name of state-file
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/comm-style-injected-$SESSION_ID"

# Density-based reinjection: injection does NOT happen just once per session, but is refreshed as the session progresses.
# Trigger: first turn OR at least N turns have passed >= N turns OR the transcript has grown by at least >= M bytes of transcript.
REINJECT_EVERY_TURNS="${STYLE_REINJECT_TURNS:-12}"
REINJECT_BYTES="${STYLE_REINJECT_BYTES:-60000}"

# Current context size — size of the transcript (if the harness provided it)
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
  DO_INJECT=1                                                   # by turn count
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

# Content: registry dispatcher (if available) → file-snapshot s0-core.md → skip.
# Dispatcher: WP-412 Phase6 (thin hook with cascade L0+L1+author). Path to it via PROJECT_DIR.
# File-snapshot: WP-412 Phase11 (FMT-fallback, self-contained). Path via BASH_SOURCE — works in env -i.
# Runtime-mechanics (re-injection, state) stays in the hook. Rollback: git revert.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S0_CORE="$HOOK_DIR/../styles/s0-core.md"

DISPATCHER="$PROJECT_DIR/PACK-rhetoric/pack/language-style/registry/dispatcher.py"
if [ -f "$DISPATCHER" ]; then
  FRAGMENT=$(python3 "$DISPATCHER" --event userpromptsubmit-ide --quiet --no-cache 2>/dev/null)
fi

# If the dispatcher did not provide content — read the file-snapshot (strip frontmatter between --- --- )
if [ -z "${FRAGMENT:-}" ] && [ -f "$S0_CORE" ]; then
  FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$S0_CORE" 2>/dev/null)
fi

[ -n "${FRAGMENT:-}" ] || { echo '{}'; exit 0; }   # both sources are empty/failed → skip (safe)

# S2: personal override of the template user (WP-412 Phase13). Separate file from
# template-sample (communication-style-personal-template.md) — its hook
# never reads, otherwise placeholder-instruction would end up in the prompt as
# «user style» on every fresh installation. Empty/no file → simply
# do not append, FRAGMENT remains as it was (additive-only, does not block S0).
PERSONAL_OVERRIDE="$PROJECT_DIR/memory/communication-style-personal.md"
if [ -f "$PERSONAL_OVERRIDE" ]; then
  PERSONAL_FRAGMENT=$(awk '/^---/{n++; if(n==2){found=1; next}} found' "$PERSONAL_OVERRIDE" 2>/dev/null)
  if [ -n "${PERSONAL_FRAGMENT//[$' \t\n']/}" ]; then
    FRAGMENT="$FRAGMENT

$PERSONAL_FRAGMENT"
  fi
fi

CONTEXT="## 🗣 Conversational style IWE (S0 base + S1 author) — apply when responding to a human

Source of truth: \`DP.SC.050\` (Pack). Channel-detector: technical mode — for transcripts/commit/PR; «in plain terms» — for chat with the pilot and §1-§4 synthesis report.md.

$FRAGMENT"

# Record state: current turn = last injection, store transcript bytes
mkdir -p "$STATE_DIR"
echo "$TURN $TURN $CUR_BYTES" > "$STATE_FILE"

# Cleanup old state-files (>24h)
find "$STATE_DIR" -name "comm-style-injected-*" -mmin +1440 -delete 2>/dev/null || true

# JSON for Claude Code UserPromptSubmit hook
jq -n --arg ctx "$CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
