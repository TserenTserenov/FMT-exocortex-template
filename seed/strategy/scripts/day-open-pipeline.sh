#!/usr/bin/env bash
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
# day-open-pipeline.sh — оркестратор полного конвейера Day Open (WP-356 DOE3)
# Поток: preflight → scaffold → llm-fill (per-section) → checks → commit/push
#
# FMT promotion note (WP-7 FMT-PROMOTE-DAYOPEN1): this entry point plus its 5
# dependencies (day-open-checks-runner.sh, day-open-llm-fill.py,
# day-open-budget-patch.py, update-derived-snapshot.py, llm-proxy-launcher.sh)
# and day-open-scaffold.sh are all promoted here and seeded into
# seed/strategy/scripts/ for new DS-strategy repos. Not yet wired: no launchd
# role registers this pipeline for a new user (see roles/ — none reference
# day-open); that remains a separate follow-up (day-open role, IntegrationGate
# required before implementation).

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

IWE="$(iwe_resolve_root)"
CONFIG="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml"

# ============================================
# 1.5. Opportunistic derived_snapshot refresh (WP-425 Level 2a)
# Runs update-derived-snapshot.py --if-stale-days=10 in background.
# Non-blocking: Day Open continues even if the refresh fails.
#
# Above every early-exit branch on purpose (WP-5 VDV correction, 2026-07-09):
# it serves guide freshness, not today's plan, so it must fire on every
# invocation regardless of how Day Open itself resolves. `--if-stale-days`
# is the only throttle — don't move it back below an early-exit.
# Runs before secrets are sourced further down — fine today, since
# update-derived-snapshot.py authenticates via the claude CLI session, not
# via any of AIST_ENV/ANTHROPIC_ENV. If it ever needs those, source secrets
# before this block instead of moving the block back down.
# ============================================
echo "=== 1.5. Snapshot refresh (opportunistic) ==="
(python3 "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/update-derived-snapshot.py" --if-stale-days 10 \
  >> "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/logs/personal-guide-update.log" 2>&1 || true) &
SNAPSHOT_PID=$!
echo "  snapshot refresh pid=$SNAPSHOT_PID (background, non-blocking)"

# --- CLI args ---
FORCE=false
DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)      FORCE=true; shift ;;
    --date|-d)       DATE="$2"; shift 2 ;;
    *)               DATE="$1"; shift ;;
  esac
done
DATE="${DATE:-$(date +%Y-%m-%d)}"

# tg_notify() comes from lib/common.sh (sourced above) — reads
# TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID directly, no local TG_TOKEN/TG_CHAT
# copy needed.

# --- Secrets (must load before the first tg_notify call below — WP-5 Ubuntu-audit
# П2, 2026-07-22: secrets used to be sourced after both the D2-dedup and
# pipeline-started notifications, so those two silently no-op'd every run) ---
AIST_ENV="$HOME/.config/aist/env"
if [ -f "$AIST_ENV" ]; then
  set -a
  source "$AIST_ENV"
  set +a
fi

# Anthropic API key for llm-proxy (WP-356)
ANTHROPIC_ENV="$HOME/IWE/.secrets/anthropic_key.env"
if [ -f "$ANTHROPIC_ENV" ]; then
  set -a
  source "$ANTHROPIC_ENV"
  set +a
fi

# --- Guard: already committed today (D2 dedup) ---
# Checks by file presence in git history, not commit message prefix —
# so both automated ("feat(dayplan):") and manual ("day-open:") commits are detected.
# WP-484 (2026-07-14): fetch origin first. Day Open now runs independently from
# both the pilot's Mac (01:00) and the always-on tsekh-1 server (scheduler
# catch-up, 04:00-22:00) as a deliberate primary+backup pair — a local-only git
# log missed a same-day commit the other side had already pushed, so whichever
# ran second redid the whole scaffold+LLM-fill for nothing.
if [ "$FORCE" != "true" ]; then
  cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" 2>/dev/null || true
  git fetch origin main --quiet 2>/dev/null || true
  DAYPLAN_FILE="current/DayPlan $DATE.md"
  ALREADY_COMMITTED=$(git log HEAD origin/main --since="$DATE 00:00:00" --until="$DATE 23:59:59" --name-only --format="" -- "$DAYPLAN_FILE" 2>/dev/null | grep -c "DayPlan $DATE" || true)
  if [ "${ALREADY_COMMITTED:-0}" -gt 0 ]; then
    echo "  DayPlan already committed today ($DATE, this machine or the other) — nothing to do."
    tg_notify "📋 DayPlan $DATE already committed today. Use --force to regenerate."
    # Record success heartbeat here too: the other machine did the work, but
    # day-open-pipeline-watchdog.sh only checks THIS machine's heartbeat file.
    # Without this, every day the two machines settle this D2 race the "losing"
    # side never writes success — its watchdog fires a false dead-man's-switch
    # alert even though a DayPlan genuinely exists for today.
    OTHER_COMMIT=$(git log -1 --format=%H HEAD origin/main -- "$DAYPLAN_FILE" 2>/dev/null | head -1)
    OTHER_COMMIT="${OTHER_COMMIT:-unknown}"
    mkdir -p "$HOME/.claude/state"
    jq -n \
      --arg date "$DATE" \
      --arg commit "$OTHER_COMMIT" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success", note: "done by the other machine"}' \
      > "$HOME/.claude/state/day-open-pipeline-last-success.json"
    exit 0
  fi
fi

# Notify pilot that pipeline has started (helps diagnose silent hangs)
tg_notify "🌅 Day Open pipeline started for $DATE"

# --- Lock file (prevent concurrent runs) ---
LOCK_FILE="/tmp/day-open-pipeline.lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "❌ Day Open already running (PID $LOCK_PID). Abort."
    exit 0
  else
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
# Trap set later (cleanup(), near PROXY_PID) already does `rm -f "$LOCK_FILE"` —
# a duplicate trap here would just get overwritten by that later `trap ... EXIT`.

# --- State store (pipeline heartbeat) ---
STATE_DIR="$HOME/.claude/state"
HEARTBEAT_FILE="$STATE_DIR/day-open-pipeline-last-success.json"
mkdir -p "$STATE_DIR"

# --- Paths ---
CURRENT_DIR="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current"
DAYPLAN_NAME="DayPlan $DATE.md"
DAYPLAN_PATH="$CURRENT_DIR/$DAYPLAN_NAME"
WEEKPLAN_PATH=$(ls "$CURRENT_DIR"/WeekPlan\ W*.md 2>/dev/null | head -1 || true)
WP_REGISTRY="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/WP-REGISTRY.md"
# WP-7 Ф-DRIFT-DATA-PIPELINES D1 (13.07): было memory/cp-profile.json, который не
# писал ни один механизм. update-derived-snapshot.py (шаг 1.5 выше) уже пишет сюда.
CP_PROFILE="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-425/cache/derived_snapshot.json"
CALENDAR_OUT="$IWE/.tmp/calendar-$DATE.txt"
LLM_PROXY_URL="${LLM_PROXY_URL:-http://localhost:18765}"
PROXY_PORT="${PROXY_PORT:-18765}"
PROXY_PID=""

# --- Helper: abort with notification + proxy cleanup ---
abort() {
  local reason="$1"
  echo "❌ $reason"
  tg_notify "🚨 Day Open pipeline aborted: ${reason}"
  exit 1
}

# Cleanup proxy on exit
cleanup() {
  if [ -n "$PROXY_PID" ]; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
  fi
  rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================
# 1. Pre-flight healthcheck
# ============================================
echo "=== 1. Pre-flight ==="
PREFLIGHT_JSON=$(bash "$IWE/scripts/day-open-preflight.sh" "$DATE" "$CONFIG" 2>/dev/null || echo '{"calendar":"unknown"}')
CALENDAR_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.calendar // "unknown"')
SCOUT_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.scout // "unknown"')
TRIAGE_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.triage // "unknown"')
MEMORY_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.memory // "unknown"')

echo "  calendar=$CALENDAR_PF scout=$SCOUT_PF triage=$TRIAGE_PF memory=$MEMORY_PF"

if [ "$CALENDAR_PF" = "fail" ]; then abort "Calendar preflight failed"; fi
if [ "$SCOUT_PF" = "fail" ]; then abort "Scout preflight failed"; fi
if [ "$TRIAGE_PF" = "fail" ]; then abort "Triage preflight failed"; fi

# ============================================
# 1.1. Day Close race guard (root cause of 2026-07-01 stale plan)
# launchd fires Day Open at 01:04, but the pilot often does yesterday's Day Close
# in the morning (~05:30). If Day Open runs first it reads stale WeekPlan/frontmatter
# and the LLM hallucinates "closed WP" counts. Defer (exit 0, not abort) when
# yesterday's Day Close isn't done yet — the day-close.after trigger will
# re-run this pipeline with --force once the close lands. --force bypasses the guard.
#
# WP-5 Ubuntu-portability audit (2026-07-22, П1): replaced the commit-message regex
# guard (matched literal "day-close.*$YDAY" text — broke silently whenever the close
# commit's wording drifted, most recently detecting only the close's *start* lock
# marker instead of its completion) with a deterministic signal: presence of
# yesterday's archived DayPlan. day-close step 10c (SKILL.md) writes it as the last
# thing before/with the commit, so its existence in HEAD or origin/main means the
# close genuinely landed — no dependency on any particular wording.
# ============================================
if [ "$FORCE" != "true" ]; then
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
    || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  if [ -n "$YDAY" ]; then
    (cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git fetch origin main --quiet 2>/dev/null || true)
    YDAY_DAYPLAN="archive/day-plans/DayPlan $YDAY.md"
    DC_DONE=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log HEAD origin/main --format="" --name-only -- "$YDAY_DAYPLAN" 2>/dev/null | head -1)
    # Only defer when there was actually work to close: if yesterday had zero commits
    # in the governance repo, there is nothing to close and deferring would stall the
    # plan forever on a genuinely quiet day.
    YDAY_COMMITS=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log HEAD origin/main --since="$YDAY 00:00:00" --until="$YDAY 23:59:59" --format=%H 2>/dev/null | head -1)
    if [ -z "$DC_DONE" ] && [ -n "$YDAY_COMMITS" ]; then
      echo "  Day Close for $YDAY not done yet (no archived DayPlan) — deferring Day Open (will regenerate after close)."
      tg_notify "⏸ Day Open $DATE отложен: Day Close за $YDAY ещё не сделан. Пересоберётся после закрытия (или запусти с --force)."
      exit 0
    fi
    if [ -n "$DC_DONE" ]; then
      echo "  Day Close for $YDAY found (archived DayPlan present) — proceeding."
    else
      echo "  No commits for $YDAY (quiet day, nothing to close) — proceeding."
    fi
  fi
fi

# ============================================
# 1.2. Git hooks provisioning self-heal (found 2026-07-23: force-push incident)
# core.hooksPath is per-checkout, not versioned — a fresh/reprovisioned clone
# silently falls back to the empty default .git/hooks, disabling the whole
# .githooks/ stack (including the pre-push force-push guard, WP-436) with no
# visible signal until something actually force-pushes over shared history.
# Self-heal here rather than just warn: this check runs on every Day Open on
# every machine that has this pipeline (server + Mac), so fixing it in place
# also covers checkouts this session has no direct access to.
# ============================================
DS_STRATEGY="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [ -d "$DS_STRATEGY/.githooks" ] && [ -n "$(ls -A "$DS_STRATEGY/.githooks" 2>/dev/null)" ]; then
  CURRENT_HOOKS_PATH=$(git -C "$DS_STRATEGY" config core.hooksPath 2>/dev/null || echo "")
  if [ "$CURRENT_HOOKS_PATH" != ".githooks" ]; then
    echo "=== 1.2. Git hooks: core.hooksPath='$CURRENT_HOOKS_PATH' (expected .githooks) — self-healing ==="
    if bash "$DS_STRATEGY/scripts/install-hooks.sh" "$DS_STRATEGY" >/dev/null 2>&1; then
      echo "  Fixed: core.hooksPath=.githooks (force-push guard now active)"
      tg_notify "⚠️ Day Open: core.hooksPath на $DS_STRATEGY был не .githooks — pre-push force-push guard молчал. Автоматически починил (install-hooks.sh)."
    else
      echo "  WARN: install-hooks.sh failed — hooks still inactive, needs manual attention"
      tg_notify "🚨 Day Open: core.hooksPath на $DS_STRATEGY сломан, автопочинка (install-hooks.sh) тоже упала — force-push guard не активен, нужна ручная проверка."
    fi
  fi
fi

# ============================================
# 2. Ensure LLM Proxy available
# ============================================
echo "=== 2. LLM Proxy healthcheck ==="
PROXY_HEALTH=$(curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && echo "ok" || echo "fail")
if [ "$PROXY_HEALTH" != "ok" ]; then
  if lsof -ti :"$PROXY_PORT" >/dev/null 2>&1; then
    # Port already held by another process — likely a live proxy the check above
    # missed on a transient blip. Spawning here would just crash into "Address
    # already in use" and spam the error log without helping (found 2026-07-11).
    echo "  Health check failed but port $PROXY_PORT is already held — not spawning a second proxy, just waiting."
  else
    echo "  Proxy not running. Starting via launcher (loads OPENROUTER_API_KEY from secrets)..."
    bash "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/llm-proxy-launcher.sh" "$PROXY_PORT" &
    PROXY_PID=$!
  fi
  # Retry up to 10 times (20s total) — launcher needs extra time to source secrets + import
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    PROXY_HEALTH=$(curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && echo "ok" || echo "fail")
    [ "$PROXY_HEALTH" = "ok" ] && break
    echo "  Waiting for proxy (attempt $_i/10)..."
  done
  if [ "$PROXY_HEALTH" != "ok" ]; then
    abort "LLM Proxy unavailable (tried to start, failed)"
  fi
fi
echo "  Proxy OK"

# ============================================
# 3. Scaffold
# ============================================
echo "=== 3. Scaffold ==="
if [ -z "$WEEKPLAN_PATH" ] || [ ! -f "$WEEKPLAN_PATH" ]; then
  abort "WeekPlan not found in $CURRENT_DIR"
fi

mkdir -p "$IWE/.tmp"
bash "$IWE/scripts/server-calendar.sh" "$DATE" "$CONFIG" > "$CALENDAR_OUT" 2>/dev/null || true

# Export so that day-open-scaffold.sh uses correct repo when run from launchd
# (launchd doesn't inherit shell env where IWE_GOVERNANCE_REPO is set via .zshrc)
export IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"

# Generate scaffold to temp file first (for hash guard)
SCAFFOLD_TEMP="$DAYPLAN_PATH.scaffold.tmp"
SCAFFOLD_SCRIPT="$IWE/scripts/day-open-scaffold.sh"
bash "$SCAFFOLD_SCRIPT" "$DATE" > "$SCAFFOLD_TEMP" || {
  SC=$?
  if [ $SC -eq 2 ]; then
    echo "  Strategy day — no DayPlan generated."
    rm -f "$SCAFFOLD_TEMP"
    tg_notify "📋 Strategy day — Day Open skipped."
    exit 0
  fi
  # Diagnostics for bug-2026-07-10 repro (день, когда scaffold "не найден" без явной причины)
  DIAG="pwd=$(pwd) PATH=$PATH scaffold_exists=$([ -e "$SCAFFOLD_SCRIPT" ] && echo yes || echo no) scaffold_x=$([ -x "$SCAFFOLD_SCRIPT" ] && echo yes || echo no) ls=$(ls -la "$SCAFFOLD_SCRIPT" 2>&1)"
  echo "  DIAG: $DIAG"
  tg_notify "🚨 Day Open pipeline aborted: Scaffold failed (exit $SC)
$DIAG"
  exit 1
}

# --- Input hash guard (D2: dedup manual retriggers) ---
# Include git HEAD so that any new commits in repo invalidate the hash
HEAD_HASH=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git rev-parse HEAD 2>/dev/null || echo "no-git")
INPUT_HASH_FILE="$IWE/.tmp/day-open-input-hash-$DATE.txt"
INPUT_HASH=$( (cat "$SCAFFOLD_TEMP" "$WEEKPLAN_PATH" "$CALENDAR_OUT" 2>/dev/null; echo "$HEAD_HASH") | iwe_sha256 )
if [ -f "$INPUT_HASH_FILE" ]; then
  PREV_HASH=$(cat "$INPUT_HASH_FILE")
  if [ "$PREV_HASH" = "$INPUT_HASH" ]; then
    echo "  Input hash unchanged — DayPlan already generated for this data set. Skipping."
    rm -f "$SCAFFOLD_TEMP"
    tg_notify "📋 DayPlan $DATE already up-to-date (input hash unchanged). Skipping LLM Fill."
    exit 0
  fi
fi
echo "$INPUT_HASH" > "$INPUT_HASH_FILE"

# Move scaffold to target
mv "$SCAFFOLD_TEMP" "$DAYPLAN_PATH"
echo "  Scaffold OK: $DAYPLAN_PATH"

# ============================================
# 4. LLM Fill (per-section)
# ============================================
echo "=== 4. LLM Fill ==="
python3 "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-llm-fill.py" \
  --scaffold "$DAYPLAN_PATH" \
  --weekplan "$WEEKPLAN_PATH" \
  --wp-registry "$WP_REGISTRY" \
  --wp-dir "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox" \
  --cp-profile "$CP_PROFILE" \
  --calendar "$CALENDAR_OUT" \
  --fleeting-notes "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/fleeting-notes.md" \
  --out "$DAYPLAN_PATH" \
  --proxy-url "$LLM_PROXY_URL" || {
  FILL_EXIT=$?
  if [ "$FILL_EXIT" -eq 2 ]; then
    echo "  Partial fill — some sections remain PENDING."
    tg_notify "⚠️ DayPlan $DATE partially filled — some PENDING sections remain. Checks will block commit until fixed."
    # Continue to checks (they will fail, but user gets full diagnostics)
  else
    echo "  LLM fill failed — leaving scaffold for manual completion."
    tg_notify "❌ LLM fill failed for $DATE — scaffold saved, needs manual completion."
    exit 0
  fi
}
echo "  LLM Fill OK"

# ============================================
# 4.2. Bottleneck patch (deterministic, AFTER LLM Fill — WP-484, moved 2026-07-14)
# llm-fill.py's has_pending check is whole-chunk: a second marker (week_context) in the
# same <details> block as "Горлышко недели" made it regenerate that whole chunk even
# when this script had already run first, overwriting its BOTTLENECK-PENDING/BY-SCRIPT
# marker with unmarked prose. Running last makes this script the authoritative source.
# ============================================
echo "=== 4.2. Bottleneck patch ==="
bash "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-bottleneck-patch.sh" "$DAYPLAN_PATH" 2>&1 || true

# ============================================
# 4.5. Budget patch (deterministic: sum h column, no LLM hallucination)
# ============================================
echo "=== 4.5. Budget patch ==="
python3 "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-budget-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --priorities "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml" 2>&1 || true

# ============================================
# 4.6. Sync + archive stale DayPlans (moved ahead of Checks — WP-484 Ф2)
# BUGFIX (2026-07-13): this used to run in step 6, AFTER Checks (step 5) — but one of
# the checks (day-open.checks.md «current/ без зависших DayPlan») hard-blocks commit
# if any non-today DayPlan sits in current/. Archiving only after that check had
# already failed meant the pipeline could never self-heal a leftover from a Day Close
# that ran late or incompletely: the one mechanism able to fix the condition always
# ran too late to prevent the block it was fixing.
# ============================================
echo "=== 4.6. Sync + archive ==="
cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" || abort "Cannot cd to repo"

# Sync with remote to avoid non-fast-forward push (race with other agents)
# WP-484 (2026-07-19): route through git-dirty-guard.sh first — a bare pull --rebase
# aborts the whole pipeline on the routine dirty tree sync-strategy-files.sh leaves on
# tsekh-1 (see git-dirty-guard.sh header). The guard either self-heals a stale mirror
# or confirms real uncommitted work is present; a plain pull is only safe after that.
bash "$IWE/scripts/git-dirty-guard.sh" "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" || abort "git-dirty-guard found real uncommitted work — not safe to pull/commit this round"
# iwe_safe_pull (lib/common.sh) adds same-patch-different-hash drop protection
# a bare `git pull --rebase` doesn't have — see WP-5 П4 audit факт #5.
iwe_safe_pull -C "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" || abort "iwe_safe_pull failed (see output above)"

# Archive stale DayPlans (move + overwrite, and record the deletion).
# Bug history (feedback_dayplan_archive_silent_skip.md): `git mv ... || true` silently
# skipped when the archive copy already existed (Day Close had archived an earlier copy),
# leaving a stale DayPlan stuck in current/. And the commit pathspec listed only archive/,
# so the current/ deletion was never committed even when git mv did run.
TODAY=$(date +%Y-%m-%d)
ARCHIVE_DIR="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans"
ARCHIVED_PATHS=()
for f in "$CURRENT_DIR"/DayPlan\ *.md; do
  [ -f "$f" ] || continue
  basename_f=$(basename "$f")
  echo "$basename_f" | grep -qF "$TODAY" && continue   # keep today's plan in current/
  if git mv -f "$f" "$ARCHIVE_DIR/" 2>/dev/null; then
    echo "  archived (git mv): $basename_f"
  else
    # Untracked or rename edge case: move on disk, then stage the new location explicitly.
    mv -f "$f" "$ARCHIVE_DIR/"
    git add "$ARCHIVE_DIR/$basename_f"
    echo "  archived (mv fallback): $basename_f"
  fi
  ARCHIVED_PATHS+=("$f")   # old current/ path: include below so the deletion is committed
done

# session-guard.sh scope gate (added 2026-07-07, WP-7 SGFIX3) blocks any new/renamed
# path that isn't declared in an active session's note-file log — a headless launchd
# run has no session open, so DayPlan (new file every day) and the archive moves always
# tripped it (bug found 2026-07-08, same class as the [allow:current] bug below: a guard
# added after this pipeline was written, nobody updated the pipeline for it).
# Agent id is a dedicated "day-open-pipeline", not "claude-code": note-file's
# select_semaphore matches any open semaphore for the given agent name and fails
# loudly on 2+ candidates — "claude-code" would collide with a live interactive
# session open on the same machine at the same time.
SG_AGENT="day-open-pipeline"
bash "$IWE/scripts/session-guard.sh" open --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true
bash "$IWE/scripts/session-guard.sh" note-file "$DAYPLAN_PATH" --agent "$SG_AGENT"
for f in "${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"}"; do
  bash "$IWE/scripts/session-guard.sh" note-file "$ARCHIVE_DIR/$(basename "$f")" --agent "$SG_AGENT"
done

# ============================================
# 5. Checks
# ============================================
echo "=== 5. Checks ==="
CHECKS_OUT=$(bash "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-checks-runner.sh" "$DAYPLAN_PATH" 2>&1)
CHECKS_EXIT=$?
echo "$CHECKS_OUT"

if [ $CHECKS_EXIT -ne 0 ]; then
  tg_notify "❌ DayPlan checks failed for $DATE. Commit blocked. Fix and retry."
  abort "Checks failed — see output above"
fi

# ============================================
# 6. Commit + Push
# ============================================
echo "=== 6. Commit + Push ==="
cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" || abort "Cannot cd to repo"

git add "$DAYPLAN_PATH"
git add "$ARCHIVE_DIR/" 2>/dev/null || true

# [allow:current]: the new-files guard (peer-audit 2026-06-04) blocks any commit that adds
# files under current/ without this tag. Every unattended run hit this — the guard was added
# after this line was written and nobody updated it (bug found 2026-07-02).
git commit -m "feat(dayplan): $DATE — auto Day Open (WP-356) [allow:current]" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>" -- "$DAYPLAN_PATH" "$ARCHIVE_DIR/" ${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"} || abort "Git commit failed"

git push || abort "Git push failed"

bash "$IWE/scripts/session-guard.sh" close --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true

COMMIT_HASH=$(git log -1 --format=%H)
echo "  Committed: $COMMIT_HASH"

# ============================================
# 7. Morning digest
# ============================================
echo "=== 7. Morning Digest ==="
SHORT_HASH="${COMMIT_HASH:0:8}"
PLAN_ROWS=$(sed -n '/<details open>/,/<\/details>/p' "$DAYPLAN_PATH" 2>/dev/null | \
  awk -F'|' 'NF>=6 && /\*\*WP/ {
    rp=$5; h=$6;
    gsub(/\*\*/, "", rp); gsub(/ — .*/, "", rp);
    sub(/^[[:space:]]+/, "", rp); sub(/[[:space:]]+$/, "", rp);
    printf "  %s\n", substr(rp, 1, 45)
  }' | head -6 || true)
PLAN_ROWS="${PLAN_ROWS:-  нет данных}"
MSG="✅ День открыт: $DATE"$'\n\n'
MSG+="📋 Сегодня:"$'\n'"${PLAN_ROWS}"$'\n\n'
MSG+="💾 ${SHORT_HASH}"

# WP-149 gate-dopo (peer-session 2026-06-23-07): surface rung_fidelity from last render.
GATE_STATUS_FILE="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/gate-status.yaml"
if [ -f "$GATE_STATUS_FILE" ]; then
  GATE_ST=$(grep -E "^  status:" "$GATE_STATUS_FILE" 2>/dev/null | awk '{print $2}' | tr -d "'\"")
  if [ "${GATE_ST:-ok}" != "ok" ] && [ -n "${GATE_ST:-}" ]; then
    echo "  ⚠️ rung_fidelity: $GATE_ST — проверь $GATE_STATUS_FILE"
    MSG+="\n⚠️ Руководство: rung_fidelity=$GATE_ST (gate-status.yaml)"
  fi
fi

tg_notify "$MSG"

# Record success heartbeat for dead-man's switch watchdog
jq -n \
  --arg date "$DATE" \
  --arg commit "$COMMIT_HASH" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success"}' \
  > "$HEARTBEAT_FILE"
echo "  Heartbeat recorded: $HEARTBEAT_FILE"

echo "=== Done ==="
