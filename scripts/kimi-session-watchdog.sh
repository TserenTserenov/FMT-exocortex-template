#!/usr/bin/env bash
#
# kimi-session-watchdog.sh
# External mechanical guard against silent/hung Kimi sessions.
# Formal sessions and observational peer beacons use separate namespaces:
# only formal `sessions/*.open` files participate in session-guard admission.
#
# Run manually:
#   bash scripts/kimi-session-watchdog.sh
# Or via launchd (see exocortex/launchd/com.iwe.kimi-watchdog.plist).

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
PEER_HEARTBEAT_DIR="$IWE_ROOT/.iwe-runtime/peer-heartbeats"
SILENCE_THRESHOLD_S="${SILENCE_THRESHOLD_S:-180}"
CHECK_INTERVAL_S="${CHECK_INTERVAL_S:-60}"

require_positive_integer() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*|0)
      echo "ERROR: $name must be a positive integer." >&2
      return 1
      ;;
  esac
}

require_positive_integer SILENCE_THRESHOLD_S "$SILENCE_THRESHOLD_S"
require_positive_integer CHECK_INTERVAL_S "$CHECK_INTERVAL_S"

now_epoch() { date +%s; }

mac_notify() {
  local msg="$1" subtitle="$2"
  # Both fields become AppleScript string literals. Escape slash first so the
  # quote escaping itself cannot be neutralized by caller-controlled text.
  msg=${msg//\\/\\\\}; msg=${msg//\"/\\\"}
  subtitle=${subtitle//\\/\\\\}; subtitle=${subtitle//\"/\\\"}
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"IWE Kimi Watchdog\" subtitle \"$subtitle\" sound name \"Purr\"" 2>/dev/null || true
  fi
}

notify_pilot() {
  local session_file="$1"
  local age="$2"
  local wp task
  wp="$(grep "^wp: " "$session_file" | cut -d' ' -f2- || echo "unknown")"
  task="$(grep "^task: " "$session_file" | cut -d' ' -f2- || echo "unknown")"

  local msg="Kimi молчит ${age}s в WP:${wp}. Возможно, зависание."

  mac_notify "$msg" "$task"

  # Also append to a local alert log
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $msg | $session_file" >> "$IWE_ROOT/.iwe-runtime/logs/kimi-watchdog.log"
}

latest_heartbeat_age() {
  local session_file="$1"
  local last_hb
  last_hb="$(grep "^heartbeat_at: " "$session_file" | tail -1 | cut -d' ' -f2- || true)"
  if [ -z "$last_hb" ]; then
    # No heartbeat yet: use session open time
    last_hb="$(grep "^opened_at: " "$session_file" | cut -d' ' -f2- || true)"
  fi
  if [ -z "$last_hb" ]; then
    echo "9999"
    return
  fi
  local hb_epoch now
  # heartbeat_at пишется в UTC с суффиксом Z. macOS date -j -f интерпретирует
  # литеральный Z как часть формата и парсит время как локальное, завышая возраст
  # на смещение часового пояса. Убираем Z и парсим как UTC (-u).
  hb_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${last_hb%Z}" +%s 2>/dev/null || date -d "$last_hb" +%s 2>/dev/null || echo "0")"
  now="$(now_epoch)"
  echo "$((now - hb_epoch))"
}

check_heartbeat_file() {
  local session="$1"
  local age
  age="$(latest_heartbeat_age "$session")"
  if [ "$age" -gt "$SILENCE_THRESHOLD_S" ]; then
    notify_pilot "$session" "$age"
  fi
}

scan_once() {
  local session
  for session in "$SESSION_DIR"/kimi-*.open; do
    [ -f "$session" ] && [ ! -L "$session" ] || continue
    check_heartbeat_file "$session"
  done

  # Peer calls need watchdog visibility, but their liveness hints must never
  # masquerade as formal sessions or become an admission/commit barrier.
  for session in "$PEER_HEARTBEAT_DIR"/kimi-peer-*.heartbeat; do
    [ -f "$session" ] && [ ! -L "$session" ] || continue
    check_heartbeat_file "$session"
  done
}

run_forever() {
  while true; do
    scan_once
    sleep "$CHECK_INTERVAL_S"
  done
}

mkdir -p "$IWE_ROOT/.iwe-runtime/logs"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_forever
fi
