#!/usr/bin/env bash
#
# agent-heartbeat.sh
# Update a heartbeat timestamp in the active session semaphore.
# Agents must call this at least every 180 seconds during long operations
# to prove the session is not stuck.
#
# Usage: bash scripts/agent-heartbeat.sh [--agent kimi|claude-code|hermes] [--session-id <id>]

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"
# Parse args
AGENT="${IWE_AGENT:-}"
SESSION_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    -a)      AGENT="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    *)       echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$AGENT" ]; then
  # Try to infer from current session pointer
  if [ -f "$SESSION_DIR/current-kimi.ptr" ]; then
    AGENT="kimi"
  elif [ -f "$SESSION_DIR/current-claude-code.ptr" ]; then
    AGENT="claude-code"
  elif [ -f "$SESSION_DIR/current-hermes.ptr" ]; then
    AGENT="hermes"
  else
    echo "ERROR: --agent or IWE_AGENT required" >&2
    exit 1
  fi
fi

if ! [[ "$AGENT" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]]; then
  echo "ERROR: unsafe agent id" >&2
  exit 1
fi

if [ -n "$SESSION_ID" ]; then
  if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]]; then
    echo "ERROR: unsafe exact session id" >&2
    exit 1
  fi
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
else
  MATCH_COUNT=0
  for candidate in "$SESSION_DIR/${AGENT}-"*.open; do
    [ -f "$candidate" ] || continue
    grep -qxF "agent: $AGENT" "$candidate" 2>/dev/null || continue
    candidate_id="${candidate#"$SESSION_DIR/${AGENT}-"}"
    candidate_id="${candidate_id%.open}"
    [[ "$candidate_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || continue
    [ "$(sed -n 's/^session_id: //p' "$candidate" 2>/dev/null)" = "$candidate_id" ] || continue
    SEM_FILE="$candidate"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done
  if [ "$MATCH_COUNT" -ne 1 ]; then
    echo "ERROR: expected exactly one open $AGENT session without --session-id, found $MATCH_COUNT" >&2
    exit 1
  fi
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  if [ -f "$PTR_FILE" ] && [ "$(cat "$PTR_FILE" 2>/dev/null || true)" != "$SEM_FILE" ]; then
    echo "ERROR: current $AGENT pointer disagrees with the only exact open session" >&2
    exit 1
  fi
fi
if [ ! -f "$SEM_FILE" ]; then
  echo "ERROR: session semaphore not found: $SEM_FILE" >&2
  exit 1
fi

case "$SEM_FILE" in
  "$SESSION_DIR/${AGENT}-"*.open) ;;
  *) echo "ERROR: active pointer is outside the exact $AGENT namespace" >&2; exit 1 ;;
esac
SESSION_ID="${SEM_FILE#"$SESSION_DIR/${AGENT}-"}"
SESSION_ID="${SESSION_ID%.open}"
if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] ||
   [ "$SEM_FILE" != "$SESSION_DIR/${AGENT}-${SESSION_ID}.open" ]; then
  echo "ERROR: active pointer does not contain a safe exact session id" >&2
  exit 1
fi
[ -f "$SESSION_GUARD" ] || { echo "ERROR: session guard not found: $SESSION_GUARD" >&2; exit 1; }

# Never open `.open` for writing here. The guard serializes this exact session
# against close, validates agent/PID, and refuses to create a missing path.
bash "$SESSION_GUARD" heartbeat --agent "$AGENT" --session-id "$SESSION_ID" \
  --owner-pid "$$" >/dev/null
