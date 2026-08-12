#!/usr/bin/env bash
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

IWE="${IWE_ROOT:-$HOME/IWE}"
CONFIG="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/day-rhythm-config.yaml"
# shellcheck source=lib/ledger-path.sh
. "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/lib/ledger-path.sh"

# Quarantine only provably orphaned semaphores (dead recorded pid). Old
# semaphores without pid proof are reported and kept for manual review.
mkdir -p "$IWE/.iwe-runtime"
bash "$IWE/scripts/session-guard.sh" audit --cleanup-orphans \
  >> "$IWE/.iwe-runtime/session-orphan-sweep.log" 2>&1 || true

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
PROBE=false
DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)      FORCE=true; shift ;;
    # --probe (WP-484, test stand): dry-run — real preflight+scaffold+LLM-fill+checks,
    # writes to a "(probe)" suffixed file (never the real DayPlan), skips commit/push/
    # archive-move/TG. Implies --force (guards are about real-file state, irrelevant here).
    --probe)         PROBE=true; FORCE=true; shift ;;
    --date|-d)       DATE="$2"; shift 2 ;;
    *)               DATE="$1"; shift ;;
  esac
done
DATE="${DATE:-$(date +%Y-%m-%d)}"
PROBE_START_S=$SECONDS

# --- Helper: send TG notification (safe JSON via jq) ---
# MUST be defined before first call (regression fix 2026-06-29).
tg_notify() {
  local msg="$1"
  if [ "$PROBE" = "true" ]; then
    echo "  [probe: TG suppressed] $msg" | head -1
    return 0
  fi
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    local payload resp http_code
    # No parse_mode: Markdown 400s on any unpaired _/*/` in dynamic text (DIAG,
    # LLM warns) — same failure class month-open-night-run.sh hit live on 27.07.
    payload=$(jq -n --arg chat "$TG_CHAT" --arg text "$msg" '{chat_id: $chat, text: $text}')
    resp=$(curl -s -w '\n%{http_code}' -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$payload")
    http_code=$(printf '%s' "$resp" | tail -n1)
    # WP-484 F64: a fired curl is not a delivered message — verify and say so.
    if [ "$http_code" != "200" ] || ! printf '%s' "$resp" | grep -q '"ok":true'; then
      echo "  [tg delivery FAILED http=$http_code] $msg" | head -2
      return 1
    fi
  else
    echo "  [no tg credentials] $msg" | head -1
    return 1
  fi
}

# --- Helper: portable single-field read from a Y-m-d date string ---
# BSD `date -j` (macOS) vs GNU `date -d` (Linux/tsekh-1) -- third use of this
# exact shape (P2: YDAY_DOW below was the second, inlined before this existed).
portable_date_field() {
  local input="$1" fmt="$2"
  date -j -f "%Y-%m-%d" "$input" "$fmt" 2>/dev/null || date -d "$input" "$fmt" 2>/dev/null
}

# Correlate kind and for_date inside one parsed event. Grepping the two fields
# independently can combine different events from a mixed legacy ledger and report a
# close that never happened for the requested date.
ledger_ref_has_digest_for_date() {
  local ledger_rel="$1"
  local target="$2"
  local allow_legacy="$3"
  local ref content

  for ref in HEAD origin/main; do
    content=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git show "$ref:$ledger_rel" 2>/dev/null) || content=""
    [ -n "$content" ] || continue
    if printf '%s' "$content" | python3 -c '
import sys

import yaml

target, allow_legacy = sys.argv[1], sys.argv[2] == "true"
try:
    doc = yaml.safe_load(sys.stdin.read()) or {}
except Exception:
    raise SystemExit(1)
events = doc.get("events") if isinstance(doc, dict) else []
for event in events if isinstance(events, list) else []:
    if not isinstance(event, dict) or event.get("kind") != "facts_digest":
        continue
    data = event.get("data")
    if not isinstance(data, dict):
        continue
    if data.get("for_date") == target or (allow_legacy and "for_date" not in data):
        raise SystemExit(0)
raise SystemExit(1)
' "$target" "$allow_legacy"; then
      return 0
    fi
  done
  return 1
}

# --- Secrets (must load before the first tg_notify call below — WP-5 Ubuntu-audit
# П2, 2026-07-22: TG_TOKEN/TG_CHAT used to be assigned after both the D2-dedup and
# pipeline-started notifications, so those two silently no-op'd every run) ---
source_env_if_present() {
  [ -f "$1" ] || return 0
  set -a
  source "$1"
  set +a
}
source_env_if_present "$HOME/.config/aist/env"
source_env_if_present "$HOME/IWE/.secrets/anthropic_key.env"  # Anthropic API key for llm-proxy (WP-356)
# WP-484 Ф50b named this file as the readable ANTHROPIC_API_KEY source for the
# remote-gateway fallback below (line ~534) but never sourced it -- the fallback
# chain silently resolved to empty and the authorized probe 401'd (found live
# 2026-08-05 running --probe ahead of a scheduled test run).
source_env_if_present "$HOME/.iwe/.proxy-env"
# WP-484 F64 (06.08): TELEGRAM_* live in ~/.secrets/tg-bots (canonical source per
# lib/telegram.sh) — none of the three files above carry them on tsekh-1, so every
# tg_notify on the server (incl. the "День открыт" digest and all aborts) was a
# silent no-op since the migration. Same fix as day-open-pipeline-watchdog.sh.
source_env_if_present "$HOME/.secrets/tg-bots"

TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-}"

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
if [ "$PROBE" = "true" ]; then
  DAYPLAN_NAME="DayPlan $DATE (probe).md"
fi
DAYPLAN_PATH="$CURRENT_DIR/$DAYPLAN_NAME"
# WP-484 27.07: старый формат "WeekPlan W{N} {дата}.md" сменился на
# "WeekPlan {год}-W{N} {дата} (night-cycle).md" (week-open-orchestrator.sh) — жёсткий
# glob "WeekPlan W*.md" переставал матчить ЛЮБОЙ реальный файл сразу как только старый
# формат исчез из current/ (обнаружено 27.07 при сборке --probe: пайплайн абортил бы на
# каждом прогоне, включая strategy_day, ещё ДО собственной проверки этого случая —
# тот же класс регрессии, что WP-149 уже поймал у build-strategic-context.py). Принимает
# оба формата, берёт самый свежий по mtime (не первый по алфавиту — конвенции WeekPlan
# W* и WeekPlan {год}-W* сортируются по-разному, mtime однозначен).
# Excludes "(probe)" files defensively (WP-484 27.07, independent review): a
# week-open-orchestrator.sh --probe run writes a "(probe)"-suffixed WeekPlan into
# this same directory — if it were ever left behind (crash before its own cleanup),
# this glob picking "newest by mtime" would otherwise silently feed test content
# into the pilot's real DayPlan. Belt-and-suspenders alongside that script's own
# end-of-run cleanup.
WEEKPLAN_PATH=$(ls -t "$CURRENT_DIR"/WeekPlan\ *.md 2>/dev/null | grep -v '(probe)' | head -1 || true)
WP_REGISTRY="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/WP-REGISTRY.md"
# WP-7 Ф-DRIFT-DATA-PIPELINES D1 (13.07): было memory/cp-profile.json, который не
# писал ни один механизм. update-derived-snapshot.py (шаг 1.5 выше) уже пишет сюда.
CP_PROFILE="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-425/cache/derived_snapshot.json"
CALENDAR_OUT="$IWE/.tmp/calendar-$DATE.txt"
LLM_PROXY_URL="${LLM_PROXY_URL:-https://iwe-llm-proxy-production.up.railway.app}"
PROXY_PORT="${PROXY_PORT:-18765}"
PROXY_PID=""
# WP-484 Ф48b (04.08): default flipped from the Mac-only localhost:18765 (the
# WP-149/504 "dead file" llm-proxy.py, superseded by auth-gateway.py at the
# WP-400 cutover 09.06) to the properly-maintained Railway gateway. This
# pipeline runs on either machine of the dual-machine pair (see note below) --
# a Mac-local address is simply wrong on tsekh-1, and was the root cause of
# the 30.07/02.08/04.08 stale-credential recurrences on the Mac. Local-only
# branches below (spawn-if-missing, kill-on-port self-heal) only make sense
# for an actual localhost target, so they're gated on PROXY_IS_LOCAL.
case "$LLM_PROXY_URL" in
  http://localhost:*|http://127.0.0.1:*) PROXY_IS_LOCAL=true ;;
  *) PROXY_IS_LOCAL=false ;;
esac

# --- Helper: abort with notification + proxy cleanup ---
abort() {
  local reason="$1"
  echo "❌ $reason"
  tg_notify "🚨 Day Open pipeline aborted: ${reason}"
  if [ "$PROBE" = "true" ]; then
    local wall_min=$(( (SECONDS - PROBE_START_S) / 60 ))
    echo ""
    echo "=== PROBE SUMMARY ==="
    echo "  date=$DATE verdict=🔴 red (abort) reason=\"$reason\" wall_min=$wall_min attention_min=0"
  fi
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
  # Same class of leak as week-open-orchestrator.sh/month-open-orchestrator.sh
  # (WP-484 27.07 independent review): a "(probe)"-suffixed DayPlan left behind
  # after this exits (crash, or --probe run not rerun) sits in current/ where the
  # WeekPlan glob above already defends against — but nothing was cleaning up
  # THIS script's own probe file. Found running night-cycle-day.sh --probe.
  if [ "$PROBE" = "true" ]; then
    rm -f "$DAYPLAN_PATH" 2>/dev/null || true
  fi
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
#
# WP-484 peer session with Kimi (2026-07-28): the archived-DayPlan signal is blind
# to strategy_day. On strategy_day, day-open-scaffold.sh skips DayPlan generation
# entirely by design (§3. Scaffold below, exit-2 branch) — so an archived DayPlan
# for that date can never exist, whether or not Day Close actually ran. Found live:
# every day right after a strategy_day (e.g. every Tuesday, given strategy_day:
# monday) deferred Day Open indefinitely on this guard, even though the prior
# day's Day Close had genuinely landed. Branch on whether YDAY was strategy_day and
# use a different deterministic signal for that case: the `facts_digest` ledger
# event day-close-prepare.sh appends at the end of every real Day Close (not just
# strategy_day) — same "concrete artifact, not wording" spirit as the DayPlan check.
# ============================================
if [ "$FORCE" != "true" ]; then
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
    || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  if [ -n "$YDAY" ]; then
    (cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git fetch origin main --quiet 2>/dev/null || true)

    YDAY_DOW=$(portable_date_field "$YDAY" "+%u")
    # Scoped to the day_open: block (not a flat grep) so a same-named key
    # elsewhere in the file can't silently hijack this lookup (review finding,
    # WP-484 peer session 2026-07-28).
    STRATEGY_DAY_NAME=$(awk '/^day_open:/{f=1} f && /strategy_day:/{print $2; exit}' "$CONFIG" 2>/dev/null)
    case "${STRATEGY_DAY_NAME:-monday}" in
      monday) STRATEGY_DOW=1 ;; tuesday) STRATEGY_DOW=2 ;; wednesday) STRATEGY_DOW=3 ;;
      thursday) STRATEGY_DOW=4 ;; friday) STRATEGY_DOW=5 ;; saturday) STRATEGY_DOW=6 ;;
      # Fail-open on an unrecognized value, matching day-open-scaffold.sh's own
      # default (STRATEGY_DOW=0 there) — an unparsed config must not accidentally
      # match a real day-of-week and route into the wrong signal below.
      sunday) STRATEGY_DOW=7 ;; *) STRATEGY_DOW=0 ;;
    esac

    # Only defer when there was actually work to close: if yesterday had zero commits
    # in the governance repo, there is nothing to close and deferring would stall the
    # plan forever on a genuinely quiet day.
    YDAY_COMMITS=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log HEAD origin/main --since="$YDAY 00:00:00" --until="$YDAY 23:59:59" --format=%H 2>/dev/null | head -1)

    if [ "${YDAY_DOW:-0}" = "$STRATEGY_DOW" ]; then
      YDAY_LEDGER="machine/ledger/$(ledger_path_rel day "$YDAY")"  # git-relative, see comment below
      # Two steps, not one `git show ... | grep` pipe (review finding, WP-484
      # peer session 2026-07-28): with `pipefail` (set at the top of this file),
      # a pipeline's exit status is that of its last-failing command — if the
      # ledger exists on HEAD (already committed) but not yet on origin/main
      # (not yet pushed — the exact window between day-close-prepare.sh and the
      # close's final push), the second `git show` fails and pipefail reports
      # the whole pipe as failed even though grep already matched, silently
      # dropping DC_DONE back to empty and reproducing the very bug this fixes.
      DC_DONE=""
      if ledger_ref_has_digest_for_date "$YDAY_LEDGER" "$YDAY" true; then
        DC_DONE=yes
      fi
      # WP-484 (2026-07-28, independent review caught a first version of this fix
      # that trusted ANY facts_digest found in TODAY's file — wrong, because that
      # file can legitimately hold a digest for a different day (e.g. today's own
      # ordinary close), which would then be misread as "yesterday's close is done".
      # Older day-close-prepare.sh versions stamped a late catch-up into the run day's
      # ledger and kept the target only in data.for_date. New writes use the target
      # file, but retain this fallback for already committed mixed legacy ledgers.
      if [ -z "$DC_DONE" ]; then
        # git-relative string, not a filesystem write -- ledger_path() also
        # mkdir's, which would land in the wrong place here (this runs before
        # the script's own `cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"` below) -- ledger_path_rel()
        # is the mkdir-free twin for exactly this case.
        TODAY_LEDGER="machine/ledger/$(ledger_path_rel day "$DATE")"
        if ledger_ref_has_digest_for_date "$TODAY_LEDGER" "$YDAY" false; then
          DC_DONE=yes
        fi
      fi
      if [ -z "$DC_DONE" ] && [ -n "$YDAY_COMMITS" ]; then
        echo "  Day Close for $YDAY (strategy_day) not done yet (no facts_digest in ledger) — deferring Day Open (will regenerate after close)."
        tg_notify "⏸ Day Open $DATE отложен: Day Close за $YDAY (день стратегирования) ещё не сделан. Пересоберётся после закрытия (или запусти с --force)."
        # Ф32 п.11 (WP-484, 31.07): deferred ≠ done — exit 7 tells the scheduler to
        # retry on the next window tick instead of burning the daily marker.
        exit 7
      fi
      if [ -n "$DC_DONE" ]; then
        echo "  Day Close for $YDAY found (strategy_day, ledger facts_digest present) — proceeding."
      else
        echo "  No commits for $YDAY (quiet day, nothing to close) — proceeding."
      fi
    else
      YDAY_DAYPLAN="archive/day-plans/DayPlan $YDAY.md"
      DC_DONE=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log HEAD origin/main --format="" --name-only -- "$YDAY_DAYPLAN" 2>/dev/null | head -1)
      if [ -z "$DC_DONE" ] && [ -n "$YDAY_COMMITS" ]; then
        echo "  Day Close for $YDAY not done yet (no archived DayPlan) — deferring Day Open (will regenerate after close)."
        tg_notify "⏸ Day Open $DATE отложен: Day Close за $YDAY ещё не сделан. Пересоберётся после закрытия (или запусти с --force)."
        # Ф32 п.11 (WP-484, 31.07): deferred ≠ done — exit 7, scheduler retries next tick.
        exit 7
      fi
      if [ -n "$DC_DONE" ]; then
        echo "  Day Close for $YDAY found (archived DayPlan present) — proceeding."
      else
        echo "  No commits for $YDAY (quiet day, nothing to close) — proceeding."
      fi
    fi
  fi
fi

# ============================================
# 1.1b. Week Close race guard (WP-484 Ф46, found 2026-08-02/03: 3x "LLM Proxy
# authorized probe failed" Telegram alerts near midnight on a Sunday). Late
# Sunday night, week-open-orchestrator.sh (meant to run ~23:50) is closing the
# outgoing week and opening the next one; if this pipeline also runs for that
# same Sunday's date while that cycle is mid-flight (or hasn't started at all
# yet), it can burn an attempt on an LLM Proxy call that's about to become
# moot, or produce a plan for a day whose week context is still in flux.
#
# Signal choice (2026-08-03, peer session with Codex+Hermes, corrected during
# implementation): week-open-orchestrator.sh commits an EMPTY "week-close-start:
# $WEEK" lock at its own STEP 0, before any real closing work happens
# (week-open-orchestrator.sh:95,123) -- that marker means "cycle started", not
# "week closed"; using it here would pass almost immediately after the cycle
# begins, defeating the guard. The real completion signal is STEP 5's commit
# ("week-close: $WEEK -> $NEXT_WEEK", week-open-orchestrator.sh:401), which
# lands together with current/WeekReport {WEEK}.md. Checking for that file's
# presence (not commit message text) follows this same file's own §1.1 lesson
# (WP-5, 2026-07-22): a commit-message regex silently breaks on wording drift;
# a concrete artifact doesn't.
#
# exit 7 = confirmed not closed yet -> defer, same contract as §1.1 above
#          (scheduler retries next tick, this run doesn't burn the daily marker).
# exit 8 = couldn't even check (origin unreachable) -> fail closed on a distinct
#          code, never silently treated as "not closed" from stale/absent data.
# ============================================
TARGET_DOW=$(portable_date_field "$DATE" "+%u")
CURRENT_HOUR=$(TZ=Asia/Nicosia date +%H)
if [ "$FORCE" != "true" ] && [ "${TARGET_DOW:-0}" = "7" ] && [ "$((10#$CURRENT_HOUR))" -ge 23 ]; then
  TARGET_WEEK=$(portable_date_field "$DATE" "+%Y-W%V")
  if ! (cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git fetch origin main --quiet 2>/dev/null); then
    echo "  Week Close guard: cannot refresh origin/main for week $TARGET_WEEK -- failing closed"
    tg_notify "🚨 Day Open $DATE заблокирован: не смог обновить origin/main, чтобы проверить закрытие недели $TARGET_WEEK. Нужна ручная проверка сети/репозитория."
    exit 8
  fi
  WEEK_REPORT_REL="current/WeekReport ${TARGET_WEEK}.md"
  WEEK_CLOSED=$(cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" && git log HEAD origin/main --format="" --name-only -- "$WEEK_REPORT_REL" 2>/dev/null | head -1)
  if [ -z "$WEEK_CLOSED" ]; then
    echo "  Week $TARGET_WEEK not closed yet (no '$WEEK_REPORT_REL' in HEAD/origin) -- deferring Day Open"
    tg_notify "⏸ Day Open $DATE отложен: неделя $TARGET_WEEK ещё закрывается (после 23:00 вс). Пересоберётся автоматически после завершения цикла."
    # Same contract as §1.1: deferred ≠ done -- exit 7 tells the scheduler to
    # retry on the next window tick instead of burning the daily marker.
    exit 7
  fi
  echo "  Week $TARGET_WEEK already closed ('$WEEK_REPORT_REL' found) -- proceeding."
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
# 1.3. Input freshness self-heal (WP-484 Ф90, 2026-08-12): priorities.yaml and
# WP-REGISTRY.md are read straight off local disk by LLM Fill below. On a
# shared checkout (tsekh-1) a live agent session can hold the tree's sync
# semaphore for hours after finishing its own work (found live: 11h46m past
# report.md completion) — the periodic sync timer correctly refuses to touch
# the tree while that semaphore stands, so these two files silently go stale
# for however long the semaphore lasts, and Day Open builds tonight's plan
# from yesterday's data. `git show <ref>:<path>` reads a blob straight from
# the object database without touching the working tree or index at all — no
# lock, no semaphore, safe regardless of what any other session is doing.
# Scoped to exactly these two inputs (not a general pull): a full sync still
# needs the semaphore respected, this only unblocks what Day Open itself
# reads. `git fetch` above (D2 dedup guard) already refreshed origin/main's
# ref; if that fetch failed offline, this diff is silently a no-op against a
# stale ref, which is the same degradation the rest of this pipeline already
# accepts everywhere else fetch can fail.
# ============================================
echo "=== 1.3. Input freshness self-heal ==="
for _f_rel in current/priorities.yaml docs/WP-REGISTRY.md; do
  _f_abs="$DS_STRATEGY/$_f_rel"
  _f_origin=$(cd "$DS_STRATEGY" && git show "origin/main:$_f_rel" 2>/dev/null || true)
  if [ -z "$_f_origin" ]; then
    echo "  skipped (origin/main unreadable, e.g. offline): $_f_rel"
  elif diff -q <(printf '%s' "$_f_origin") "$_f_abs" >/dev/null 2>&1; then
    echo "  already fresh: $_f_rel"
  else
    printf '%s' "$_f_origin" > "$_f_abs"
    echo "  refreshed from origin/main (local was stale): $_f_rel"
  fi
done

# ============================================
# 2. Ensure LLM Proxy available
# ============================================
echo "=== 2. LLM Proxy healthcheck ==="
PROXY_HEALTH=$(curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && echo "ok" || echo "fail")
if [ "$PROXY_HEALTH" != "ok" ]; then
  if $PROXY_IS_LOCAL; then
    # lsof (Mac) with ss fallback (NixOS server lacks lsof) — verified live: this
    # machine has lsof but not ss, so a bare ss-only version (as copied without
    # testing into month-open-night-run.sh:78) would silently break the Mac side
    # of the exact dual-machine pair this pipeline is designed to run on. Only
    # checking port occupancy either way, PID unused below.
    if lsof -ti :"$PROXY_PORT" >/dev/null 2>&1 || ss -tln 2>/dev/null | grep -q ":$PROXY_PORT "; then
      # Port already held by another process — likely a live proxy the check above
      # missed on a transient blip. Spawning here would just crash into "Address
      # already in use" and spam the error log without helping (found 2026-07-11).
      echo "  Health check failed but port $PROXY_PORT is already held — not spawning a second proxy, just waiting."
    else
      echo "  Proxy not running. Starting via launcher (loads OPENROUTER_API_KEY from secrets)..."
      bash "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/llm-proxy-launcher.sh" "$PROXY_PORT" &
      PROXY_PID=$!
    fi
  else
    echo "  Remote proxy ($LLM_PROXY_URL) failed health check — nothing local to spawn, just waiting/retrying."
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

# Alive != authorized: /v1/health never touches upstream credentials, so a proxy
# orphan that outlived a key rotation keeps answering "ok" while 401-ing every
# real call (2026-07-30 04:30 — 7/7 fill chunks failed with HTTP 401, day not
# opened). Same request contract as day-open-llm-fill.py: no "model" field, the
# proxy routes by verification_class.
# WP-484 Ф50b (04.08): LLM_PROXY_SECRET was never actually provisioned anywhere
# this pipeline runs -- confirmed live from tsekh-1. What IS already provisioned
# and already authenticates against this same gateway: PROXY_SHARED_SECRET
# (root-only /etc/iwe/env, used by iwe-llm-health/iwe-overnight-auditor) and
# ANTHROPIC_API_KEY (~/.iwe/.proxy-env, tseren-readable -- the one this pipeline's
# actual execution context can see). Falls back through what's really there
# instead of requiring a secret nobody would ever provision under this exact name.
LLM_PROXY_SECRET="${LLM_PROXY_SECRET:-${PROXY_SHARED_SECRET:-${ANTHROPIC_API_KEY:-}}}"
AUTH_PROBE_ARGS=(-H 'content-type: application/json')
[ -n "${LLM_PROXY_SECRET:-}" ] && AUTH_PROBE_ARGS+=(-H "X-IWE-Internal-Secret: ${LLM_PROXY_SECRET}")
AUTH_PROBE_BODY='{"messages":[{"role":"user","content":"ping"}],"max_tokens":1,"verification_class":"trivial"}'
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "${LLM_PROXY_URL}/v1/messages" \
  "${AUTH_PROBE_ARGS[@]}" -d "$AUTH_PROBE_BODY" 2>/dev/null) || AUTH_CODE="000"
if [ "$AUTH_CODE" != "200" ]; then
  if $PROXY_IS_LOCAL; then
    # Self-heal (WP-484, found 2026-08-04): this probe first caught this failure mode
    # on 2026-07-30 and has correctly fired on every recurrence since (2026-08-02 x3,
    # 2026-08-04) -- but detection never had matching remediation, so the same
    # process (confirmed 2026-08-04: same pid, 9 days uptime across all of the above)
    # kept serving the stale credential until a human happened to restart it by hand.
    # Kill the process holding the port and let launchd's KeepAlive respawn it fresh
    # (re-sources the secrets file) -- same fix two independent peer-session
    # diagnoses (2026-07-03, 2026-08-02) already landed on; retry the probe once
    # before falling back to abort.
    echo "  Authorized probe failed (HTTP $AUTH_CODE) — restarting local proxy and retrying once"
    STALE_PIDS=$(lsof -ti :"$PROXY_PORT" 2>/dev/null || true)
    for _pid in $STALE_PIDS; do kill "$_pid" 2>/dev/null || true; done
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 2
      curl -s "${LLM_PROXY_URL}/v1/health" 2>/dev/null | grep -q "ok" && break
      echo "  Waiting for proxy respawn (attempt $_i/10)..."
    done
  else
    # Remote gateway (WP-484 Ф48b, 04.08): no local process to kill -- Railway
    # supervises its own restarts (railway.toml restartPolicyType=ON_FAILURE).
    # A 401 here almost always means LLM_PROXY_SECRET is unset/wrong on this
    # host (confirmed missing on tsekh-1 at cutover time), not a crashed
    # process -- one short wait only covers a mid-deploy blip on Railway's side.
    echo "  Authorized probe failed (HTTP $AUTH_CODE) on remote gateway — short wait and retry once"
    sleep 5
  fi
  AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "${LLM_PROXY_URL}/v1/messages" \
    "${AUTH_PROBE_ARGS[@]}" -d "$AUTH_PROBE_BODY" 2>/dev/null) || AUTH_CODE="000"
  if [ "$AUTH_CODE" != "200" ]; then
    if $PROXY_IS_LOCAL; then
      tg_notify "🚨 Day Open aborted: LLM proxy on port $PROXY_PORT still fails after restart (HTTP $AUTH_CODE) — credential itself is likely dead at the provider, needs manual rotation (WP-399), not just a process restart."
    else
      tg_notify "🚨 Day Open aborted: remote LLM proxy ($LLM_PROXY_URL) still fails (HTTP $AUTH_CODE) — check LLM_PROXY_SECRET on this host matches Railway's PROXY_SHARED_SECRET, or WP-399 key rotation."
    fi
    abort "LLM Proxy authorized probe failed after restart (HTTP $AUTH_CODE)"
  fi
  echo "  Proxy authorized probe OK after restart"
else
  echo "  Proxy authorized probe OK"
fi

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
INPUT_HASH=$( (cat "$SCAFFOLD_TEMP" "$WEEKPLAN_PATH" "$CALENDAR_OUT" 2>/dev/null; echo "$HEAD_HASH") | shasum -a 256 | awk '{print $1}' )
# --force must beat BOTH guards: the D2 guard above already honors it, and its
# own user-facing message ("Use --force to regenerate") promises a regenerate —
# without this bypass the promise died here on unchanged inputs (review F64).
if [ "$FORCE" != "true" ] && [ -f "$INPUT_HASH_FILE" ]; then
  PREV_HASH=$(cat "$INPUT_HASH_FILE")
  if [ "$PREV_HASH" = "$INPUT_HASH" ]; then
    echo "  Input hash unchanged — DayPlan already generated for this data set. Skipping."
    rm -f "$SCAFFOLD_TEMP"
    tg_notify "📋 DayPlan $DATE already up-to-date (input hash unchanged). Skipping LLM Fill."
    exit 0
  fi
fi
# WP-484 F64 (06.08): the hash write itself moved AFTER a successful push (step 6).
# Writing it here poisoned every retry when a run died between scaffold and push
# (live case 06.08 03:03: runner timeout kill after LLM fill, before commit —
# each rerun then skipped with "already generated" while nothing was published).
# Same bug class as the probe-hash leak fixed 28.07.

# Move scaffold to target
mv "$SCAFFOLD_TEMP" "$DAYPLAN_PATH"
echo "  Scaffold OK: $DAYPLAN_PATH"

# ============================================
# 4. LLM Fill (per-section)
# ============================================
echo "=== 4. LLM Fill ==="
# Fill stderr is duplicated into a per-day file next to the night-cycle logs: on
# the morning path (scheduler → strategist → this script) the per-chunk failure
# reasons otherwise land only in ~/logs/strategist/*.log, where nobody looked
# during the 2026-07-30 04:30 incident.
DAY_OPEN_LOG="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/machine/logs/day-open-$DATE.log"
if [ "$PROBE" = "true" ]; then
  DAY_OPEN_LOG=$(mktemp)  # probe runs must not write real artifacts
fi
mkdir -p "$(dirname "$DAY_OPEN_LOG")"
FILL_ERR_TMP=$(mktemp)
FILL_EXIT=0
python3 "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-llm-fill.py" \
  --scaffold "$DAYPLAN_PATH" \
  --weekplan "$WEEKPLAN_PATH" \
  --wp-registry "$WP_REGISTRY" \
  --wp-dir "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox" \
  --cp-profile "$CP_PROFILE" \
  --calendar "$CALENDAR_OUT" \
  --fleeting-notes "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/fleeting-notes.md" \
  --priorities "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/current/priorities.yaml" \
  --out "$DAYPLAN_PATH" \
  --proxy-url "$LLM_PROXY_URL" \
  --proxy-secret "$LLM_PROXY_SECRET" 2> "$FILL_ERR_TMP" || FILL_EXIT=$?
cat "$FILL_ERR_TMP" >&2
{ echo "=== LLM Fill $(date '+%H:%M:%S') exit=$FILL_EXIT ==="; cat "$FILL_ERR_TMP"; } >> "$DAY_OPEN_LOG"
if [ "$FILL_EXIT" -eq 2 ]; then
  echo "  Partial fill — some sections remain PENDING."
  FILL_WARNS=$(grep '\[WARN\]' "$FILL_ERR_TMP" | head -5 || true)
  tg_notify "⚠️ DayPlan $DATE partially filled — some PENDING sections remain. Checks will block commit until fixed.
$FILL_WARNS"
  # Continue to checks (they will fail, but user gets full diagnostics)
elif [ "$FILL_EXIT" -ne 0 ]; then
  echo "  LLM fill failed — leaving scaffold for manual completion."
  FILL_ERRS=$(grep -E '\[WARN\]|\[ERROR\]' "$FILL_ERR_TMP" | head -5 || true)
  tg_notify "❌ LLM fill failed for $DATE (exit $FILL_EXIT) — scaffold saved, needs manual completion.
$FILL_ERRS"
  rm -f "$FILL_ERR_TMP"
  exit 0
fi
rm -f "$FILL_ERR_TMP"
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
# 4.3. Ledger render (deterministic, AFTER LLM Fill — same reason as 4.2 above:
# WP-484 Ф16.2 2b). Appends render-open.py's ledger sections (Итоги вчера/Очередь
# решений/Предлагаемые действия, Ф16.2 2c) as an ADDITIONAL block near the end of
# the DayPlan — never touches day-open-scaffold.sh's own legacy "Итоги вчера" block
# (CONCEPT-night-cycle.md §16: parallel run during migration, not a replacement).
# True no-op (file byte-identical) until scripts/day-close-prepare.sh (Ф16.2 2a,
# WP-485) starts landing facts_digest ledger events most nights — see the script's
# own docstring for the graceful-degradation design.
# ============================================
echo "=== 4.3. Ledger render ==="
python3 "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/day-open-ledger-render-patch.py" \
  --dayplan "$DAYPLAN_PATH" \
  --date "$DATE" 2>&1 || true

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

TODAY=$(date +%Y-%m-%d)
ARCHIVE_DIR="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/archive/day-plans"
ARCHIVED_PATHS=()

if [ "$PROBE" = "true" ]; then
  # WP-484 27.07 (found by independent review of the --probe stand itself): this whole
  # block used to run unconditionally BEFORE the PROBE check below, which only wrapped
  # the archive-move loop. git-dirty-guard.sh can self-heal a stale mirror via
  # `git reset --hard origin/<branch>` — a real, destructive operation on the production
  # checkout — and the plain `git pull --rebase` below it is a real mutation too. A
  # "dry run" that can silently `reset --hard` or rebase the real repo isn't a dry run.
  echo "  [probe] git-dirty-guard/pull/archive-move all skipped — no git state touched"
else
# Sync with remote to avoid non-fast-forward push (race with other agents)
# WP-484 (2026-07-19): route through git-dirty-guard.sh first — a bare pull --rebase
# aborts the whole pipeline on the routine dirty tree sync-strategy-files.sh leaves on
# tsekh-1 (see git-dirty-guard.sh header). The guard either self-heals a stale mirror
# or confirms real uncommitted work is present; a plain pull is only safe after that.
#
# NON-FATAL as of 2026-07-26 (WP-484, root-caused the 04:35 26.07 ledger-render
# incident): this used to `abort` the whole pipeline on real uncommitted work, which
# discarded everything steps 1-4.5 had already correctly rendered (including an honest
# ledger section) and forced strategist.sh's free-form LLM fallback, which has no
# awareness of the LEDGER-RENDER block and silently overwrote it with fabricated
# numbers — exactly the "no fabrication" invariant §5 CONCEPT-night-cycle.md exists to
# prevent, just via a path this guard didn't cover. Sync/archive is housekeeping, not
# required for today's DayPlan content, so a failure here degrades gracefully (skip
# pull, keep the already-written file) instead of discarding a good render.
if ! bash "$IWE/scripts/git-dirty-guard.sh" "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"; then
  tg_notify "⚠️ Day Open: git-dirty-guard нашёл незакоммиченную работу — pull пропущен, но уже отрендеренный DayPlan сохраняется (не абортим pipeline, WP-484 fix 26.07)"
else
  # Sync failures are reported out-of-repo only. Appending sync_skipped to the
  # tracked ledger here would make the next git-dirty-guard invocation reject the
  # pipeline's own diagnostic write and turn a transient failure into a permanent
  # dirty-tree loop. The periodic sync service owns persistent failure counters.
  git pull --rebase || {
    tg_notify "⚠️ Day Open: git pull --rebase failed — continuing without pull (WP-484 fix 26.07)"
  }
fi

# Archive stale DayPlans (move + overwrite, and record the deletion).
# Bug history (feedback_dayplan_archive_silent_skip.md): `git mv ... || true` silently
# skipped when the archive copy already existed (Day Close had archived an earlier copy),
# leaving a stale DayPlan stuck in current/. And the commit pathspec listed only archive/,
# so the current/ deletion was never committed even when git mv did run.
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
fi

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
if [ "$PROBE" != "true" ]; then
  bash "$IWE/scripts/session-guard.sh" open --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true
  bash "$IWE/scripts/session-guard.sh" note-file "$DAYPLAN_PATH" --agent "$SG_AGENT"
  for f in "${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"}"; do
    bash "$IWE/scripts/session-guard.sh" note-file "$ARCHIVE_DIR/$(basename "$f")" --agent "$SG_AGENT"
  done
fi

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
if [ "$PROBE" = "true" ]; then
  echo "=== 6. Commit + Push — SKIPPED (probe) ==="
  COMMIT_HASH="(probe, not committed)"
  echo "  Probe file left for review: $DAYPLAN_PATH"
else
echo "=== 6. Commit + Push ==="
cd "$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}" || abort "Cannot cd to repo"

git add "$DAYPLAN_PATH"
git add "$ARCHIVE_DIR/" 2>/dev/null || true

# [allow:current]: the new-files guard (peer-audit 2026-06-04) blocks any commit that adds
# files under current/ without this tag. Every unattended run hit this — the guard was added
# after this line was written and nobody updated it (bug found 2026-07-02).
git commit -m "feat(dayplan): $DATE — auto Day Open (WP-356) [allow:current]" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>" -- "$DAYPLAN_PATH" "$ARCHIVE_DIR/" ${ARCHIVED_PATHS[@]+"${ARCHIVED_PATHS[@]}"} || abort "Git commit failed"

git push || abort "Git push failed"

# WP-484 F64: input-hash means "this data set is PUBLISHED", so it is recorded
# only after the remote accepted the commit (see the guard comment at step 3).
if [ "$PROBE" != "true" ]; then
  echo "$INPUT_HASH" > "$INPUT_HASH_FILE"
fi

bash "$IWE/scripts/session-guard.sh" close --housekeeping day-open --agent "$SG_AGENT" 2>/dev/null || true

COMMIT_HASH=$(git log -1 --format=%H)
echo "  Committed: $COMMIT_HASH"
fi

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

if [ "$PROBE" = "true" ]; then
  echo "  [probe] real heartbeat not touched (watchdog reads only real runs)"
else
  # Record success heartbeat for dead-man's switch watchdog
  jq -n \
    --arg date "$DATE" \
    --arg commit "$COMMIT_HASH" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{date: $date, commit_hash: $commit, timestamp: $ts, status: "success"}' \
    > "$HEARTBEAT_FILE"
  echo "  Heartbeat recorded: $HEARTBEAT_FILE"
fi

# ============================================
# PROBE SUMMARY (WP-484 test stand — attention_min vs wall_min)
# attention_min: this pipeline has ZERO pilot-blocking steps in its normal path
# (abort() ends the run, it never pauses waiting on a human) — so attention_min is
# structurally 0 for every probe unless a future step type changes that. Not a
# guess: derived from reading the script, same way quick-close.yaml's reflex/ai vs
# pilot,blocking step types make session-close's attention_min = 0 in the happy path.
# ============================================
if [ "$PROBE" = "true" ]; then
  WALL_MIN=$(( (SECONDS - PROBE_START_S) / 60 ))
  VERDICT="🔴 red"
  [ "$CHECKS_EXIT" -eq 0 ] && VERDICT="🟢 green"
  echo ""
  echo "=== PROBE SUMMARY ==="
  echo "  date=$DATE verdict=$VERDICT checks_exit=$CHECKS_EXIT wall_min=$WALL_MIN attention_min=0"
  echo "  file=$DAYPLAN_PATH"
fi

echo "=== Done ==="
