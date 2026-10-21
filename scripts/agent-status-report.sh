#!/bin/bash
# agent-status-report.sh — WP-395 Phase3 fail-safe writer.
#
# PURPOSE: deterministic writing runtime-of the agent runtime status (Claude/Kimi) into
# the platform registry indicators.agent_status, WHEN the agent-LLM did not report itself.
#
# This is FAIL-SAFE, not primary. Primary write-path = behavioral invocation MCP-tool
# agent_status_update by the agent itself (see. Agent Core in CLAUDE.md/AGENTS.md). This helper
# writes directly to the DB (degraded-path) — a deliberate exception for reliability, i.e. OAuth
# for Claude/Kimi does not refresh the way it does for Hermes-runtime, and dashboard must see the status even
# if LLM forgot to call the tool (fault-profile ~15-20%).
#
# Called by: Claude SessionStart/SessionEnd-hook (settings) + kimi-peer-adapter.sh (Kimi headless).
# Writes under user_id pilot (the same Ory sub, as the MCP-path) — rows are consistent.
#
# CONTRACT STALENESS (cold-review H1/R1): SessionEnd/idle not guaranteed on crash/kill.
# Therefore the reader (dashboard, agent_status_list) MUST treat `working`/`peer-session`
# with a stale updated_at (> ~15 min) as stale.
#
# Usage:
#   agent-status-report.sh [--session-id <id>] <agent> <status> [task] [files-csv]
#   agent-status-report.sh claude-code working "WP-395 Phase3" "src/a.ts,src/b.ts"
#   agent-status-report.sh --session-id 20260604-s1 kimi idle
#   agent-status-report.sh --gc                    # one-time stale cleanup (client-side)
#
# WP-398 Phase2: --session-id <id> (default 'default') — multi-session mode.
# No flag = default (backward-compat, single session). The flag can be placed at any = 'default' (backward-compat, single session). The flag can be placed at any
# position before positional arguments; parsed separately from <agent>/<status>/[task]/[files].
#
# Never causes the calling process to fail: always exit 0, errors silently to stderr.

GC_MODE=""
SESSION_ID="default"
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) SESSION_ID="${2:-default}"; shift 2 ;;
    --gc)         GC_MODE="1"; shift ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

AGENT="${1:-}"
STATUS="${2:-idle}"
TASK="${3:-}"
FILES_CSV="${4:-}"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

SECRETS_DIR="${IWE_SECRETS_DIR:-$HOME/IWE/.secrets}"
NEON_ENV="$SECRETS_DIR/neon-urls.env"
UID_FILE="$SECRETS_DIR/pilot-user-id"

fail() { echo "agent-status-report: $1" >&2; exit 0; }   # fail-safe: never break caller

# In GC mode agent is not required — skip validation
if [ -z "$GC_MODE" ]; then
  [ -z "$AGENT" ] && fail "agent required (claude-code|kimi|hermes)"
  # Enum synchronized with AGENT_STATUS_VALUES (gateway-mcp/src/agent-status.ts).
  # When extending the enum enum in TS — update here as well.
  case "$STATUS" in idle|working|peer-session|blocked) ;; *) fail "bad status '$STATUS'";; esac
fi

# user_id pilot (Ory sub) — from secret or env. tr -d: robustness against an accidental \n in the file.
USER_ID="${IWE_PILOT_USER_ID:-}"
[ -z "$USER_ID" ] && [ -f "$UID_FILE" ] && USER_ID="$(tr -d '[:space:]' < "$UID_FILE")"
[ -z "$USER_ID" ] && fail "pilot user_id not found ($UID_FILE)"

# DSN database indicators
INDICATORS_URL="${INDICATORS_URL:-}"
if [ -z "$INDICATORS_URL" ] && [ -f "$NEON_ENV" ]; then
  # shellcheck disable=SC1090
  set -a; . "$NEON_ENV"; set +a
fi
[ -z "${INDICATORS_URL:-}" ] && fail "INDICATORS_URL not found ($NEON_ENV)"

command -v psql >/dev/null 2>&1 || fail "psql not installed"

# === GC mode: one-time stale cleanup (client-side fallback until server-side GC) ===
if [ -n "$GC_MODE" ]; then
  psql "$INDICATORS_URL" -v ON_ERROR_STOP=1 -v uid="$USER_ID" \
    >/dev/null 2>&1 <<'SQL' || fail "gc failed"
UPDATE agent_status
SET status = 'idle'
WHERE user_id = :'uid'::uuid
  AND status = 'working'
  AND updated_at < now() - interval '4 hours';
UPDATE agent_status
SET status = 'idle'
WHERE user_id = :'uid'::uuid
  AND status = 'peer-session'
  AND updated_at < now() - interval '2 hours';
UPDATE agent_status
SET status = 'idle'
WHERE user_id = :'uid'::uuid
  AND status = 'blocked'
  AND updated_at < now() - interval '24 hours';
SQL
  exit 0
fi

# UPSERT (mirrors gateway-mcp/src/agent-status.ts). psql :'var' quoting = injection protection.
# files: CSV → text[] via string_to_array; empty → '{}'.
psql "$INDICATORS_URL" -v ON_ERROR_STOP=1 \
  -v uid="$USER_ID" -v ag="$AGENT" -v st="$STATUS" -v tk="$TASK" -v fl="$FILES_CSV" -v sid="$SESSION_ID" \
  >/dev/null 2>&1 <<'SQL' || fail "db write failed"
INSERT INTO agent_status (user_id, agent, session_id, status, task, files, updated_at)
VALUES (
  :'uid'::uuid,
  :'ag',
  :'sid',
  :'st',
  NULLIF(:'tk', ''),
  CASE WHEN :'fl' = '' THEN '{}'::text[] ELSE string_to_array(:'fl', ',') END,
  now()
)
ON CONFLICT (user_id, agent, session_id) DO UPDATE SET
  status = EXCLUDED.status,
  task = EXCLUDED.task,
  files = EXCLUDED.files,
  updated_at = now();
SQL

exit 0
