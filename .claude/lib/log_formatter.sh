#!/bin/bash
# log_formatter.sh
# Shared JSONL formatter for capture_log.jsonl / gate_log.jsonl.
# Writes one line JSON to the specified file, atomic append.
#
# Usage:
#   log_jsonl <file> <key=val>...
# Example:
#   log_jsonl .claude/logs/capture_log.jsonl detector=incident status=fired latency_ms=42

set -euo pipefail

log_jsonl() {
  local file="$1"; shift
  local ts
  ts=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

  local args=(--arg ts "$ts")
  local jq_obj='{ts: $ts'

  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    args+=(--arg "$key" "$val")
    jq_obj+=", $key: \$$key"
  done
  jq_obj+="}"

  mkdir -p "$(dirname "$file")"
  jq -nc "${args[@]}" "$jq_obj" >> "$file"
}

# If the script is called directly — acts as CLI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  log_jsonl "$@"
fi
