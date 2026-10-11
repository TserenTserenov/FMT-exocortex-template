# shellcheck shell=bash
# Sourced, not executed: declares functions only, no shebang needed
# (smoke-clean-env.sh exemption, issue #1013).
# session-index-draft.sh — single point of truth for writing to the
# sessions/00-index.md draft buffer (WP-537 Ф4, design consensus at
# sessions/2026-08/17/2026-08-17-09-sessions-index-snapshotter/report.md).
#
# Every session-index writer (session-index.sh, peer-conversation SKILL.md
# §1.3/§4.3, kimi-peer-writer SKILL.md, peer-session-finalize.sh) calls
# session_index_draft_write instead of touching sessions/00-index.md
# directly. session-index-snapshot.sh is the ONLY process allowed to write
# that git-tracked file — same split as WP-530 Ф3 made for open-sessions.log,
# for the same reason: two writers editing the same tracked row concurrently
# resolve as a git add/add conflict, not a merge, and one side's update can
# be lost.
#
# Buffer format: one YAML file per session_id, hybrid per the design —
# opened_at is written once and never overwritten by a later call; every
# other field is replaced wholesale each call (the snapshotter always reads
# the latest state, it does not need history).
# Source, don't execute: `. "$(dirname "${BASH_SOURCE[0]}")/lib/session-index-draft.sh"`

# session_index_draft_write — writes/updates one session's draft row.
# Args: session_id date task agents turns escalations status report_link
session_index_draft_write() {
  local session_id="$1" date="$2" task="$3" agents="$4" turns="$5" escalations="$6" session_status="$7" report_link="$8"
  local root="${IWE_ROOT:-$HOME/IWE}"
  local draft_dir="$root/.iwe-runtime/session-index-drafts"
  local draft="$draft_dir/${session_id}.yaml"
  mkdir -p "$draft_dir"

  local opened_at
  opened_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$draft" ]; then
    local existing
    existing="$(python3 -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
except Exception:
    data = None
v = data.get("opened_at") if isinstance(data, dict) else None
if v:
    v = str(v)
    while len(v) >= 2 and v[0] == v[-1] and v[0] in ("\x27", "\x22"):
        v = v[1:-1]
    print(v)
' "$draft")"
    [ -n "$existing" ] && opened_at="$existing"
  fi

  jq -n \
    --arg opened_at "$opened_at" \
    --arg date "$date" \
    --arg session_id "$session_id" \
    --arg task "$task" \
    --arg agents "$agents" \
    --arg turns "$turns" \
    --arg escalations "$escalations" \
    --arg status "$session_status" \
    --arg report_link "$report_link" \
    '{opened_at: $opened_at, date: $date, session_id: $session_id, task: $task,
      agents: $agents, turns: $turns, escalations: $escalations, status: $status,
      report_link: $report_link}' | \
    python3 -c 'import json, sys, yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, allow_unicode=True, sort_keys=False)' \
    > "${draft}.tmp" && mv "${draft}.tmp" "$draft"
}
