#!/usr/bin/env bash
# agent-status-report.sh — deterministic fallback for agent status registry.
# Primary path is MCP agent_status_update; this script is a local best-effort log.
set -euo pipefail

SESSION_ID="default"
if [ "${1:-}" = "--session-id" ]; then
  SESSION_ID="${2:-default}"
  shift 2
fi

AGENT="${1:-unknown}"
STATUS="${2:-working}"
TASK="${3:-}"
FILES_CSV="${4:-}"
REPO="${5:-}"

LOG_DIR="${IWE_AGENT_STATUS_LOG_DIR:-$HOME/logs/agent-status}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/status.jsonl"
LATEST_FILE="$LOG_DIR/${AGENT}.${SESSION_ID}.json"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$LOG_FILE" "$LATEST_FILE" "$AGENT" "$STATUS" "$TASK" "$FILES_CSV" "$REPO" "$SESSION_ID" <<'PY'
import json, sys, datetime
log_file, latest_file, agent, status, task, files_csv, repo, session_id = sys.argv[1:]
event = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "agent": agent,
    "status": status,
    "task": task,
    "files": [x for x in files_csv.split(',') if x],
    "repo": repo,
    "session_id": session_id,
    "source": "agent-status-report.sh",
}
line = json.dumps(event, ensure_ascii=False)
with open(log_file, "a", encoding="utf-8") as f:
    f.write(line + "\n")
with open(latest_file, "w", encoding="utf-8") as f:
    f.write(line + "\n")
PY
else
  printf '{"agent":"%s","status":"%s","task":"%s","files":"%s","repo":"%s","session_id":"%s","source":"agent-status-report.sh"}\n' \
    "$AGENT" "$STATUS" "$TASK" "$FILES_CSV" "$REPO" "$SESSION_ID" >> "$LOG_FILE"
fi
