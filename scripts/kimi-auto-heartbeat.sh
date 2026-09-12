#!/usr/bin/env bash
#
# kimi-auto-heartbeat.sh
# Запускает фоновый heartbeat для активной Kimi standalone-сессии.
# Должен вызываться сразу после session-guard.sh open.
#
# Usage: bash scripts/kimi-auto-heartbeat.sh [--interval 120] [--session-id <id>]

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"
INTERVAL="${IWE_HEARTBEAT_INTERVAL:-120}"
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    -i)         INTERVAL="$2"; shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    *)          echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: interval must be a positive integer" >&2; exit 1; }

# Bind once to an exact session. The pointer is only an admission hint; every
# mutation below carries the extracted id back through session-guard.
if [ -n "$SESSION_ID" ]; then
  [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] \
    || { echo "ERROR: unsafe exact session id" >&2; exit 1; }
  SEM_FILE="$SESSION_DIR/kimi-${SESSION_ID}.open"
else
  MATCH_COUNT=0
  for candidate in "$SESSION_DIR/kimi-"*.open; do
    [ -f "$candidate" ] || continue
    grep -qxF 'agent: kimi' "$candidate" 2>/dev/null || continue
    candidate_id="${candidate#"$SESSION_DIR/kimi-"}"
    candidate_id="${candidate_id%.open}"
    [[ "$candidate_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] || continue
    [ "$(sed -n 's/^session_id: //p' "$candidate" 2>/dev/null)" = "$candidate_id" ] || continue
    SEM_FILE="$candidate"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done
  if [ "$MATCH_COUNT" -ne 1 ]; then
    echo "ERROR: expected exactly one open kimi session without --session-id, found $MATCH_COUNT" >&2
    exit 1
  fi
  if [ -f "$SESSION_DIR/current-kimi.ptr" ] && \
     [ "$(cat "$SESSION_DIR/current-kimi.ptr" 2>/dev/null || true)" != "$SEM_FILE" ]; then
    echo "ERROR: current-kimi.ptr disagrees with the only exact open session" >&2
    exit 1
  fi
fi
if [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
  echo "ERROR: no active kimi session semaphore found in $SESSION_DIR" >&2
  echo "Run session-guard.sh open first." >&2
  exit 1
fi
case "$SEM_FILE" in
  "$SESSION_DIR/kimi-"*.open) ;;
  *) echo "ERROR: active pointer is outside the exact kimi namespace" >&2; exit 1 ;;
esac
SESSION_ID="${SEM_FILE#"$SESSION_DIR/kimi-"}"
SESSION_ID="${SESSION_ID%.open}"
if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] ||
   [ "$SEM_FILE" != "$SESSION_DIR/kimi-${SESSION_ID}.open" ]; then
  echo "ERROR: active pointer does not contain a safe exact session id" >&2
  exit 1
fi
[ -f "$SESSION_GUARD" ] || { echo "ERROR: session guard not found: $SESSION_GUARD" >&2; exit 1; }

PID_FILE="$SESSION_DIR/kimi-${SESSION_ID}-heartbeat.pid"
HEARTBEAT_LOG="$IWE_ROOT/.iwe-runtime/logs/kimi-heartbeat.log"
mkdir -p "$(dirname "$HEARTBEAT_LOG")"

echo "Starting auto-heartbeat for $(basename "$SEM_FILE") every ${INTERVAL}s"
echo "heartbeat_started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$HEARTBEAT_LOG"
echo "heartbeat_sem_file: $SEM_FILE" >> "$HEARTBEAT_LOG"

# Store PID
echo $$ > "$PID_FILE"

cleanup() {
  rm -f "$PID_FILE"
  echo "heartbeat_stopped_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ") | session_id: $SESSION_ID" >> "$HEARTBEAT_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

heartbeat_loop() {
  while true; do
    if [ ! -f "$SEM_FILE" ]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | semaphore gone, stopping heartbeat" >> "$HEARTBEAT_LOG"
      break
    fi
    # Guard: if current-kimi.ptr points to a different semaphore, a new session
    # has taken over. Stop this heartbeat to avoid leaving the old semaphore stale.
    if [ -f "$SESSION_DIR/current-kimi.ptr" ]; then
      local current_ptr
      current_ptr="$(cat "$SESSION_DIR/current-kimi.ptr")"
      if [ "$current_ptr" != "$SEM_FILE" ]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | current-kimi.ptr switched to $current_ptr, stopping heartbeat for $SEM_FILE" >> "$HEARTBEAT_LOG"
        break
      fi
    fi
    # The guard holds the permanent per-session lock, refuses staged/terminal
    # state, and never opens a missing `.open` with O_CREAT.
    if ! bash "$SESSION_GUARD" heartbeat --agent kimi --session-id "$SESSION_ID" \
      --owner-pid "$$" >/dev/null 2>&1; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | heartbeat rejected, session closing or identity changed" >> "$HEARTBEAT_LOG"
      break
    fi
    sleep "$INTERVAL"
  done
}

heartbeat_loop
