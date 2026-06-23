#!/usr/bin/env bash
# day-open-preflight.sh — deterministic pre-flight status for day-open-scaffold.sh
# No network calls, no MCP calls, no writes. Outputs compact JSON.
set -euo pipefail

DATE="${1:-$(date +%Y-%m-%d)}"
CONFIG="${2:-}"
IWE_ROOT="${IWE_WORKSPACE:-${IWE_ROOT:-$HOME/IWE}}"
IWE_TEMPLATE="${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}"

has_executable() {
  local p
  for p in "$@"; do
    [ -n "$p" ] && [ -x "$p" ] && return 0
  done
  return 1
}

calendar="fail"
if has_executable \
  "${IWE_SCRIPTS:-}/server-calendar.sh" \
  "$IWE_ROOT/scripts/server-calendar.sh" \
  "$IWE_TEMPLATE/scripts/server-calendar.sh"; then
  calendar="ok"
fi

memory="fail"
if [ -f "$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/MEMORY.md" ] || [ -f "$IWE_ROOT/memory/MEMORY.md" ]; then
  memory="ok"
fi

config_status="fail"
[ -n "$CONFIG" ] && [ -f "$CONFIG" ] && config_status="ok"

python3 - "$DATE" "$calendar" "$memory" "$config_status" <<'PY'
import json, sys
_, date, calendar, memory, config_status = sys.argv
print(json.dumps({
    "date": date,
    "calendar": calendar,
    "scout": "unknown",
    "triage": "unknown",
    "memory": memory,
    "config": config_status,
}, ensure_ascii=False))
PY
