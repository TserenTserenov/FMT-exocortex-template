#!/bin/bash
# capture-bus.sh
# see DP.SC.025 (capture-bus service clause), DP.ROLE.001#R47 (Detector)
# Dispatcher for capture-mechanism. Invoked by harness on PostToolUse / Stop / ...
# Source config/capture-detectors.sh → runs enabled detectors sequentially.
# Each detector: stdin = harness JSON, stdout = event JSON (or empty), exit 0.
# Dispatcher passes stdout detector output to capture_writer.sh.
#
# Dispatcher NEVER blocks (exit 0 always).

set -uo pipefail  # without -e, so that a failure in one detector does not break the loop

# Guard: harness may invoke hook with a restricted PATH.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1
LIB_DIR="$CLAUDE_DIR/lib"
LOG_FILE="${CAPTURE_LOG_FILE:-$CLAUDE_DIR/logs/capture_log.jsonl}"

# shellcheck source=../lib/log_formatter.sh
source "$LIB_DIR/log_formatter.sh"

CONFIG_FILE="$CLAUDE_DIR/config/capture-detectors.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  exit 0  # no config = nothing to do
fi

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TOOL_FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# shellcheck source=../config/capture-detectors.sh
source "$CONFIG_FILE"

export CAPTURE_CWD="$CWD"
export CAPTURE_TOOL_FILE="$TOOL_FILE"
export CAPTURE_SESSION_ID="$SESSION_ID"

# Timeout command detection (gtimeout on macOS coreutils, timeout on Linux).
# issue #339: a hung detector used to block the whole capture-bus hook silently.
TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
fi
# Default lives in capture-detectors.sh (CAPTURE_DETECTOR_TIMEOUT_SECONDS), next to CAPTURE_COST_LEVEL.
DETECTOR_TIMEOUT_SECONDS="$CAPTURE_DETECTOR_TIMEOUT_SECONDS"

# Warn once per run (not per detector) if no timeout binary is available.
if [ -z "$TIMEOUT_CMD" ]; then
  log_jsonl "$LOG_FILE" \
    detector="capture-bus" \
    status=detector_warn \
    reason="timeout command unavailable (CAPTURE_DETECTOR_TIMEOUT_SECONDS=${DETECTOR_TIMEOUT_SECONDS}s)"
fi

for entry in "${DETECTORS[@]}"; do
  IFS='|' read -r name path event_type cost_class enabled triggers <<< "$entry"

  [ "$enabled" != "true" ] && continue

  # cost_class filter
  if [ "$cost_class" = "llm" ] && [ "$CAPTURE_COST_LEVEL" != "llm" ]; then
    continue
  fi

  # trigger filter
  if [ -n "$HOOK_EVENT" ] && [[ ",$triggers," != *",$HOOK_EVENT,"* ]]; then
    continue
  fi

  detector_path="$IWE_ROOT/$path"
  if [ ! -x "$detector_path" ]; then
    log_jsonl "$LOG_FILE" \
      detector="$name" \
      status=detector_error \
      reason="not_executable: $path"
    continue
  fi

  # Run detector with timeout
  start_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000000000' 2>/dev/null || echo 0)

  if [ -n "$TIMEOUT_CMD" ]; then
    detector_cmd=("$TIMEOUT_CMD" "$DETECTOR_TIMEOUT_SECONDS" "$detector_path")
  else
    detector_cmd=("$detector_path")
  fi

  if detector_out=$(echo "$INPUT" | "${detector_cmd[@]}" 2>/tmp/capture_detector_err.$$); then
    :
  else
    detector_rc=$?
    err=$(cat /tmp/capture_detector_err.$$ 2>/dev/null | head -c 500)
    rm -f /tmp/capture_detector_err.$$
    if [ -n "$TIMEOUT_CMD" ] && [ "$detector_rc" -eq 124 ]; then
      reason="timeout (${DETECTOR_TIMEOUT_SECONDS}s)"
    else
      reason="${err:-nonzero_exit}"
    fi
    log_jsonl "$LOG_FILE" \
      detector="$name" \
      status=detector_error \
      reason="$reason"
    continue
  fi
  rm -f /tmp/capture_detector_err.$$

  end_ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000000000' 2>/dev/null || echo 0)
  latency_ms=$(( (end_ns - start_ns) / 1000000 ))

  if [ -z "$detector_out" ]; then
    log_jsonl "$LOG_FILE" \
      detector="$name" \
      status=skip \
      latency_ms="$latency_ms"
    continue
  fi

  # Pass event to writer (latency is passed via env for the log)
  export CAPTURE_DETECTOR_NAME="$name"
  export CAPTURE_DETECTOR_LATENCY_MS="$latency_ms"
  if echo "$detector_out" | "$LIB_DIR/capture_writer.sh"; then
    :  # writer writes fired to log
  fi
  unset CAPTURE_DETECTOR_NAME
  unset CAPTURE_DETECTOR_LATENCY_MS

  # Latency gate: threshold 150ms — warn to capture_log (does not block)
  if [ "$latency_ms" -gt 150 ] 2>/dev/null; then
    log_jsonl "$LOG_FILE" \
      detector="$name" \
      status=latency_warn \
      latency_ms="$latency_ms" \
      threshold_ms=150
  fi
done

exit 0
