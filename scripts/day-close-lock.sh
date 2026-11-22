#!/bin/bash
# requires: IWE_GOVERNANCE_REPO set via iwe-env-bootstrap.sh (fallback: DS-strategy, same as other scripts)
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Phase2).
#
# Incident 17.07: server (remote) and the pilot manually closed the same day independently of each other,
# gap was discovered only at the moment of commit+push. Git log is not atomic by itself (read-then-act),
# therefore the source of truth — the very fact of push: whoever pushed first "day-close-start:", is the one that proceeds,
# the others see a newer foreign marker (or reject when attempting to push their own) and stop
# BEFORE the work begins, not after.
#
# Markers — EMPTY commits, created via commit-tree (not `git commit --allow-empty`, which
# does not guarantee an empty diff if the index contains foreign staged-files — a real risk in a repo, where
# multiple agents work in parallel). Two independent empty commits with different messages
# never conflict during rebase — verified by a test on a real race condition.
#
# After push-reject the check goes against origin/<branch> DIRECTLY (git fetch, without rebase) — if
# first rebase your own marker on top of the new foreign commits and only then inspect the log,
# your own freshly rebased marker (committer-date is updated rebase'by rebase to "now")
# becomes the most recent match and masks the real reason for the reject reject'and — review found this
# empirically (reject from an UNRELATED commit produced a false "some-one is closing the day" every single time).
#
# The calendar date follows the system installation timezone — the same timezone, in which
# the log writes the final day-close marker day-close. Epoch-the epoch age of the marker does not depend on the timezone.
#
# Two-level protection: first a fast local barrier (gateway-lock.py, for two processes on
# THE SAME machine), then git-marker (for a race BETWEEN machines — exactly incident 17.07). The first level
# is not required (gateway unavailable → simply skipped), the second — the single source of truth.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — lock acquired, day close can proceed
#   exit 1 — day has already been closed today (final commit found "day-close: YYYY-MM-DD")
#   exit 3 — some-one is already closing the day right now (recent "day-close-start:", locally or on another machine)
#   exit 2 — git/gateway-operation failed unambiguously (network/hook/environment) — retry from outside, do not treat as "already closed"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # same convention, as scripts/session-guard.sh HK_MAX_AGE (30 min)
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"

log() { echo "[day-close-lock] $1"; }

calendar_today() {
  date +%Y-%m-%d
}

# Single exit point after, the local marker-commit has already been created: rolls it back
# and exits with the required code — instead of repeating "discard + exit" in three places (P2).
abort_after_marker() {
  local code="$1" msg="$2"
  log "$msg"
  discard_local_marker
  exit "$code"
}

# Fast barrier for two processes on the SAME machine — optional, gateway unavailable → simply
# continue and rely on git-check below (it is the only one that works across machines).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py not found — skipping local barrier"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Local barrier: day is already being closed on this machine (gateway lock busy) — exiting"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway unavailable — skipping local barrier, git will decide from here git"
  fi
}

# Returns: "closed" | "start:<age_seconds>" | "" (empty — nothing happened today).
# $1 — git-ref for checking (default HEAD; for post-reject check — origin/<branch>,
# NOT the local HEAD after rebase, see. comment in the file header).
check_today_history() {
  local ref="${1:-HEAD}"
  local today; today=$(calendar_today)
  local log_lines
  log_lines=$(git log "$ref" --since="${today} 00:00" --format="%ct %s" 2>/dev/null || true)

  if echo "$log_lines" | grep -q "day-close: ${today}"; then
    echo "closed"
    return
  fi

  local start_line
  start_line=$(echo "$log_lines" | grep "day-close-start: ${today}" | head -1 || true)
  if [ -n "$start_line" ]; then
    local ts now
    ts=$(echo "$start_line" | awk '{print $1}')
    now=$(date +%s)
    echo "start:$(( now - ts ))"
    return
  fi

  echo ""
}

# Commit is guaranteed to have no diff diff (does not depend on the index state, unlike --allow-empty).
create_start_marker() {
  local who="$1" today="$2"
  local parent tree new
  parent=$(git rev-parse HEAD) || return 1
  tree=$(git rev-parse 'HEAD^{tree}') || return 1
  new=$(git commit-tree -p "$parent" -m "day-close-start: ${today} by ${who}" "$tree") || return 1
  git update-ref HEAD "$new" || return 1
}

# Rolls back the local unpushed marker to the last known origin state origin — if we
# got stuck in rebase (unlikely for empty commits, but not impossible), first abort it.
discard_local_marker() {
  local git_dir rm_dir ra_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  rm_dir="$git_dir/rebase-merge"; ra_dir="$git_dir/rebase-apply"
  { [ -d "$rm_dir" ] || [ -d "$ra_dir" ]; } && { git rebase --abort >/dev/null 2>&1 || log "git rebase --abort failed — possibly the local rebase-state was left behind, check manually"; }
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ] && git rev-parse "origin/$branch" >/dev/null 2>&1; then
    git reset --mixed "origin/$branch" >/dev/null 2>&1 \
      || log "failed to roll back local marker to origin/$branch — check manually (git status)"
  fi
}

acquire() {
  cd "$REPO_DIR" || { log "failed to change into $REPO_DIR — environment is not configured, escalating"; exit 2; }

  local_barrier

  git pull --rebase --autostash || { log "git pull failed — do not risk working on stale history"; exit 2; }

  local state
  state=$(check_today_history)
  if [ "$state" = "closed" ]; then
    log "Day has already been closed today (found commit day-close:) — exiting, re-run is not needed"
    exit 1
  fi
  if [[ "$state" == start:* ]]; then
    local age="${state#start:}"
    if [ "$age" -lt "$TTL_SECONDS" ]; then
      log "Someone-is already closing the day right now (marker is younger than ${TTL_SECONDS}s, age ${age}s) — exiting"
      exit 3
    fi
    log "Found a stale day-close-start (age ${age}s ≥ ${TTL_SECONDS}s) — treating as orphaned, continuing"
  fi

  local who today branch
  who="${IWE_AGENT:-$(whoami)}@$(hostname -s)"
  today=$(calendar_today)
  branch=$(git rev-parse --abbrev-ref HEAD)
  create_start_marker "$who" "$today" || { log "Failed to create marker-commit — escalating"; exit 2; }

  if git push; then
    log "Lock acquired: day-close-start: ${today} by ${who}"
    return 0
  fi

  # Push rejected. Checking origin/<branch> DIRECTLY via fetch, WITHOUT rebase: if first
  # rebase our own marker, it will itself become "the most recent" in the log and will mask the real
  # reason reject'of (including.e.g.. an unrelated, not associated with day-close commit) — see. file header.
  git fetch origin "$branch" || abort_after_marker 2 "git fetch after reject failed — escalating"

  state=$(check_today_history "origin/$branch")
  if [ "$state" = "closed" ] || { [[ "$state" == start:* ]] && [ "${state#start:}" -lt "$TTL_SECONDS" ]; }; then
    abort_after_marker 3 "After reject confirmed: the day is already being closed/closed by some-one else on origin — exiting"
  fi

  # On origin there is no competing marker — reject was caused by some-thing unrelated. It is safe to rebase
  # our own marker on top of the current origin and retry push.
  git rebase --autostash "origin/$branch" || abort_after_marker 2 "rebase after fetch failed — escalating"
  git push || abort_after_marker 2 "Retry push failed — escalating"
  log "Lock acquired on the second attempt: day-close-start: ${today} by ${who}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    acquire) acquire ;;
    *) echo "Usage: $0 acquire" >&2; exit 2 ;;
  esac
fi
