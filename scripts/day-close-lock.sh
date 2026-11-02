#!/bin/bash
# requires: IWE_GOVERNANCE_REPO set via iwe-env-bootstrap.sh (fallback: DS-strategy, same as other scripts)
# day-close-lock.sh — git-native cross-machine lock against duplicate Day Close runs (WP-484 Phase 2).
#
# Incident of 17.07: the server (remote) and the pilot closed the same day manually, independently of each other,
# the gap was discovered only at the moment of commit+push. Git log by itself is non-atomic (read-then-act),
# so the source of truth is the push itself: whoever pushed "day-close-start:" first is the one who works,
# the others see someone else's fresh marker (or a reject when trying to push their own) and stop
# BEFORE starting work, not after.
#
# Markers are EMPTY commits created via commit-tree (not `git commit --allow-empty`, which
# does not guarantee an empty diff if the index holds someone else's staged files — a real risk in a repo where
# several agents work in parallel). Two independent empty commits with different messages
# never conflict on rebase — verified by a test on a real race.
#
# After a push reject the check goes against origin/<branch> DIRECTLY (git fetch, no rebase) — if
# we first rebase our own marker on top of new foreign commits and only then check the log,
# our own just-rebased marker (committer-date is updated by rebase to "now")
# becomes the freshest match and masks the real cause of the reject — review found this
# empirically (a reject caused by a FOREIGN commit gave a false "someone is closing the day" every time).
#
# The calendar date follows the system zone of the installation — the same zone in which the
# protocol writes the final day-close marker. The marker's epoch age does not depend on the zone.
#
# Two-level protection: first a fast local barrier (gateway-lock.py, for two processes on
# ONE machine), then a git marker (for a race BETWEEN machines — exactly the incident of 17.07). The first level
# is optional (gateway unavailable → simply skipped), the second is the only source of truth.
#
# Usage: day-close-lock.sh acquire
#   exit 0 — lock taken, can proceed with closing the day
#   exit 1 — the day is already closed today (final commit "day-close: YYYY-MM-DD" found)
#   exit 3 — someone is already closing the day right now (fresh "day-close-start:", locally or on another machine)
#   exit 2 — git/gateway operation failed outright (network/hook/environment) — retry from outside, do not treat as "already closed"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"
TTL_SECONDS=1800  # same convention as scripts/session-guard.sh HK_MAX_AGE (30 min)
GATEWAY_LOCK_PY="$REPO_DIR/scripts/lib/gateway-lock.py"

log() { echo "[day-close-lock] $1"; }

calendar_today() {
  date +%Y-%m-%d
}

# Single exit point after the local marker commit has already been created: rolls it back
# and exits with the needed code — instead of repeating "discard + exit" in three places (P2).
abort_after_marker() {
  local code="$1" msg="$2"
  log "$msg"
  discard_local_marker
  exit "$code"
}

# Fast barrier for two processes on ONE machine — optional, gateway unavailable → simply
# continue and rely on the git check below (it alone works between machines).
local_barrier() {
  [ -x "$GATEWAY_LOCK_PY" ] || { log "gateway-lock.py не найден — пропускаю локальный барьер"; return 0; }
  local rc=0
  python3 "$GATEWAY_LOCK_PY" acquire "day-close-lock" "$TTL_SECONDS" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    log "Локальный барьер: день уже закрывается на этой машине (gateway lock занят) — выхожу"
    exit 3
  elif [ "$rc" -eq 2 ]; then
    log "gateway недоступен — пропускаю локальный барьер, дальше решает git"
  fi
}

# Returns: "closed" | "start:<age_seconds>" | "" (empty — nothing happened today).
# $1 — git ref to check (HEAD by default; for the post-reject check — origin/<branch>,
# NOT the local HEAD after rebase, see the comment in the file header).
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

# The commit is guaranteed to have no diff (independent of index state, unlike --allow-empty).
create_start_marker() {
  local who="$1" today="$2"
  local parent tree new
  parent=$(git rev-parse HEAD) || return 1
  tree=$(git rev-parse 'HEAD^{tree}') || return 1
  new=$(git commit-tree -p "$parent" -m "day-close-start: ${today} by ${who}" "$tree") || return 1
  git update-ref HEAD "$new" || return 1
}

# Rolls the local unpushed marker back to the last known origin state — if we
# got stuck in a rebase (unlikely for empty commits, but not excluded), first leave it.
discard_local_marker() {
  local git_dir rm_dir ra_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  rm_dir="$git_dir/rebase-merge"; ra_dir="$git_dir/rebase-apply"
  { [ -d "$rm_dir" ] || [ -d "$ra_dir" ]; } && { git rebase --abort >/dev/null 2>&1 || log "git rebase --abort не удался — возможно локальный rebase-стейт остался, проверить вручную"; }
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -n "$branch" ] && git rev-parse "origin/$branch" >/dev/null 2>&1; then
    git reset --mixed "origin/$branch" >/dev/null 2>&1 \
      || log "не удалось откатить локальный маркер к origin/$branch — проверить вручную (git status)"
  fi
}

acquire() {
  cd "$REPO_DIR" || { log "не удалось перейти в $REPO_DIR — окружение не настроено, эскалирую"; exit 2; }

  local_barrier

  git pull --rebase --autostash || { log "git pull failed — не рискуем работать на устаревшей истории"; exit 2; }

  local state
  state=$(check_today_history)
  if [ "$state" = "closed" ]; then
    log "День уже закрыт сегодня (найден коммит day-close:) — выхожу, повторный прогон не нужен"
    exit 1
  fi
  if [[ "$state" == start:* ]]; then
    local age="${state#start:}"
    if [ "$age" -lt "$TTL_SECONDS" ]; then
      log "Кто-то уже закрывает день прямо сейчас (маркер моложе ${TTL_SECONDS}s, возраст ${age}s) — выхожу"
      exit 3
    fi
    log "Найден протухший day-close-start (возраст ${age}s ≥ ${TTL_SECONDS}s) — считаю осиротевшим, продолжаю"
  fi

  local who today branch
  who="${IWE_AGENT:-$(whoami)}@$(hostname -s)"
  today=$(calendar_today)
  branch=$(git rev-parse --abbrev-ref HEAD)
  create_start_marker "$who" "$today" || { log "Не удалось создать маркер-коммит — эскалирую"; exit 2; }

  if git push; then
    log "Lock acquired: day-close-start: ${today} by ${who}"
    return 0
  fi

  # Push rejected. Check origin/<branch> DIRECTLY via fetch, WITHOUT rebase: if we first
  # rebase our own marker, it itself becomes "the freshest" in the log and masks the real
  # cause of the reject (including a foreign commit unrelated to day-close) — see the file header.
  git fetch origin "$branch" || abort_after_marker 2 "git fetch после reject не удался — эскалирую"

  state=$(check_today_history "origin/$branch")
  if [ "$state" = "closed" ] || { [[ "$state" == start:* ]] && [ "${state#start:}" -lt "$TTL_SECONDS" ]; }; then
    abort_after_marker 3 "После reject подтверждено: день уже закрывается/закрыт кем-то другим на origin — выхожу"
  fi

  # There is no competitor on origin — the reject was caused by something unrelated. It is safe to rebase
  # our marker on top of the current origin and retry the push.
  git rebase --autostash "origin/$branch" || abort_after_marker 2 "rebase после fetch не удался — эскалирую"
  git push || abort_after_marker 2 "Повторный push не удался — эскалирую"
  log "Lock acquired на втором заходе: day-close-start: ${today} by ${who}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    acquire) acquire ;;
    *) echo "Usage: $0 acquire" >&2; exit 2 ;;
  esac
fi
