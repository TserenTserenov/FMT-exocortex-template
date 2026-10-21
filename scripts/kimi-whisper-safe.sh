#!/usr/bin/env bash
# optional-deps: ffmpeg openai-whisper  (see docs/PLATFORM-COMPAT.md — not required for core IWE)
#
# kimi-whisper-safe.sh — safe wrapper for whisper with protection against
# foreground-foreground hangs on long audio (WP-7 KHP2).
#
# Protocol:
#   - Before starting, always measure the file duration via ffprobe.
#   - ≤ 60 s  → foreground s hard timeout 120 s.
#   - > 60 s  → foreground-foreground launch is not allowed; we print a warning and
#               commands for background/API-launch. If the flag is provided
#               --background (or env IWE_WHISPER_BACKGROUND=1), we launch
#               whisper in the background via nohup.
#
# Usage:
#   bash scripts/kimi-whisper-safe.sh /path/to/audio.mp3 [whisper-args...]
#   IWE_WHISPER_BACKGROUND=1 bash scripts/kimi-whisper-safe.sh /path/to/audio.mp3 --model base --language Russian ...

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs"
mkdir -p "$LOG_DIR"

# Thresholds per Kimi Long Operation Protocol
SHORT_THRESHOLD_S=60
FOREGROUND_TIMEOUT_S=120

# Extract audio path (first non-flag argument)
AUDIO_FILE=""
WHISPER_ARGS=()
BACKGROUND_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) BACKGROUND_FLAG=1; shift ;;
    -*)           WHISPER_ARGS+=("$1"); shift ;;
    *)
      if [ -z "$AUDIO_FILE" ]; then
        AUDIO_FILE="$1"
      else
        WHISPER_ARGS+=("$1")
      fi
      shift ;;
  esac
done

if [ -z "$AUDIO_FILE" ]; then
  echo "ERROR: audio file required" >&2
  echo "Usage: bash scripts/kimi-whisper-safe.sh /path/to/audio.mp3 [whisper-args...]" >&2
  exit 1
fi

if [ ! -f "$AUDIO_FILE" ]; then
  echo "ERROR: file not found: $AUDIO_FILE" >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ERROR: ffprobe not found. Install ffmpeg." >&2
  exit 1
fi

if ! command -v whisper >/dev/null 2>&1; then
  echo "ERROR: whisper not found. Install openai-whisper." >&2
  exit 1
fi

DURATION_RAW="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO_FILE" 2>/dev/null || true)"
if [ -z "$DURATION_RAW" ]; then
  echo "ERROR: could not determine duration of $AUDIO_FILE" >&2
  exit 1
fi

# Round to integer seconds
DURATION_S="$(printf '%.0f' "$DURATION_RAW")"

log_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

echo "$(log_timestamp) | whisper-safe | duration: ${DURATION_S}s | file: $AUDIO_FILE" >&2

if [ "$DURATION_S" -le "$SHORT_THRESHOLD_S" ]; then
  echo "$(log_timestamp) | whisper-safe | short file → foreground with ${FOREGROUND_TIMEOUT_S}s timeout" >&2
  # Use perl alarm for cross-platform timeout (macOS lacks GNU timeout)
  exec perl -e 'alarm shift @ARGV; exec @ARGV' -- "$FOREGROUND_TIMEOUT_S" whisper "$AUDIO_FILE" "${WHISPER_ARGS[@]}"
fi

# Long file: background only
if [ "$BACKGROUND_FLAG" -eq 1 ] || [ "${IWE_WHISPER_BACKGROUND:-0}" = "1" ]; then
  LOG_FILE="$LOG_DIR/whisper-$(basename "$AUDIO_FILE" | sed 's/[^a-zA-Z0-9._-]/_/g')-$(date +%s).log"
  echo "$(log_timestamp) | whisper-safe | long file → background (log: $LOG_FILE)" >&2
  nohup whisper "$AUDIO_FILE" "${WHISPER_ARGS[@]}" > "$LOG_FILE" 2>&1 &
  echo "WHISPER_BACKGROUND_PID=$!"
  echo "WHISPER_LOG=$LOG_FILE"
  echo "Started whisper in background. Check progress: tail -f $LOG_FILE"
  exit 0
fi

echo "ERROR: audio is ${DURATION_S}s (> ${SHORT_THRESHOLD_S}s). Foreground whisper is not allowed because it looks like a hang." >&2
echo "Options:" >&2
echo "  1. Background: IWE_WHISPER_BACKGROUND=1 bash scripts/kimi-whisper-safe.sh \"$AUDIO_FILE\" ${WHISPER_ARGS[*]}" >&2
echo "  2. Background: bash scripts/kimi-whisper-safe.sh --background \"$AUDIO_FILE\" ${WHISPER_ARGS[*]}" >&2
echo "  3. Use API/offline transcription service for long files." >&2
exit 1
