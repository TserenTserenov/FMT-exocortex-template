#!/usr/bin/env bash
# Issues #919/#1060 (scheduler row must verify the real scheduler log), #920 (uninstalled Scout
# shown yellow), #929 (Day Close not recognised without "day-close <date>" in the
# commit message). Runs the shipped scripts/day-open-scaffold.sh end to end in a
# throwaway workspace + HOME; nothing outside the temp dir is read or written.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1 (want «$3»; got «$2»)" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) fail "$1 (unexpected «$3»)" ;; *) ok "$1" ;; esac; }

YDAY=2026-09-25

# new_ws NAME [with-scripts] → prints the workspace root; HOME is $TMP/NAME/home
new_ws() {
  local ws="$TMP/$1/ws"
  mkdir -p "$ws/DS-strategy/current" "$ws/memory" "$TMP/$1/home/logs/synchronizer"
  [ "${2:-}" = with-scripts ] && ln -s "$ROOT/scripts" "$ws/scripts"
  echo "$ws"
}
# scaffold NAME DATE → stdout of the scaffold
scaffold() {
  local base="$TMP/$1" script="${3:-$ROOT/scripts/day-open-scaffold.sh}"
  env -i PATH="$PATH" HOME="$base/home" IWE_ROOT="$base/ws" IWE_WORKSPACE="$base/ws" \
    IWE_GOVERNANCE_REPO=DS-strategy bash "$script" "$2" 2>/dev/null
}
row() { printf '%s\n' "$1" | grep -F "| $2 |" | head -1; }

echo "== #919 scheduler row"
TODAY=$(date +%Y-%m-%d)
new_ws s919 with-scripts >/dev/null
SCHEDULER_LOG="$TMP/s919/home/logs/synchronizer/scheduler-$TODAY.log"
out=$(scaffold s919 "$TODAY")
assert_lacks "no scheduler evidence is not green" "$(row "$out" 'Scheduler/триаж')" "🟢"
touch "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "empty scheduler log is yellow" "$(row "$out" 'Scheduler/триаж')" "🟡"
assert_contains "empty scheduler log explains missing proof" "$(row "$out" 'Scheduler/триаж')" "чистый завершённый запуск не подтверждён"
printf 'WARN: strategist morning failed (rc=75)\n' > "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "failed scheduler log is red" "$(row "$out" 'Scheduler/триаж')" "🔴"
printf '[%s 06:00:00] [scheduler] ALARM: strategist morning deferred (rc=75)\n' "$TODAY" > "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "real rc=75 alarm is red" "$(row "$out" 'Scheduler/триаж')" "🔴"
printf '[%s 06:00:00] [scheduler] dispatch started (hour=06, dow=6)\n' "$TODAY" > "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "started but unfinished dispatch is yellow" "$(row "$out" 'Scheduler/триаж')" "🟡"
printf '[%s 06:00:00] [scheduler] dispatch started (hour=06, dow=6)\n[%s 06:00:01] [scheduler] SKIP: strategist morning already running (lock held)\n[%s 06:00:02] [scheduler] dispatch completed\n' "$TODAY" "$TODAY" "$TODAY" > "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "concurrent-run skip remains neutral yellow" "$(row "$out" 'Scheduler/триаж')" "🟡"
printf '[%s 06:00:00] [scheduler] dispatch started (hour=06, dow=6)\n[%s 06:00:01] [scheduler] dispatch completed\n' "$TODAY" "$TODAY" > "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "clean completed dispatch is green" "$(row "$out" 'Scheduler/триаж')" "🟢"
printf 'WARN: strategist morning failed (rc=75)\n' >> "$SCHEDULER_LOG"
out=$(scaffold s919 "$TODAY")
assert_contains "completion cannot mask a later failure" "$(row "$out" 'Scheduler/триаж')" "🔴"
mkdir -p "$TMP/s919/ws/DS-agent-workspace/scheduler/feedback-triage"
printf '# Clean feedback triage report\n' > "$TMP/s919/ws/DS-agent-workspace/scheduler/feedback-triage/$TODAY.md"
out=$(scaffold s919 "$TODAY")
assert_contains "triage report cannot mask a scheduler failure" "$(row "$out" 'Scheduler/триаж')" "🔴"

# The delivered template script must write the same failed row into a DayPlan.
INSTALLED_SCRIPTS="$TMP/s919/ws/FMT-exocortex-template/scripts"
mkdir -p "$(dirname "$INSTALLED_SCRIPTS")"
cp -R "$ROOT/scripts" "$INSTALLED_SCRIPTS"
DAYPLAN="$TMP/s919/ws/DS-strategy/current/DayPlan $TODAY.md"
scaffold s919 "$TODAY" "$INSTALLED_SCRIPTS/day-open-scaffold.sh" > "$DAYPLAN"
assert_contains "installed DayPlan records scheduler failure" "$(row "$(cat "$DAYPLAN")" 'Scheduler/триаж')" "🔴"

echo "== #920 Scout row"
new_ws s920a >/dev/null    # no scripts/ → preflight unavailable; no Scout directory
out=$(scaffold s920a "$TODAY")
assert_contains "no Scout dir, preflight unavailable → grey" "$(row "$out" Scout)" "⚪"
new_ws s920b >/dev/null
mkdir -p "$TMP/s920b/ws/DS-autonomous-agents"
out=$(scaffold s920b "$TODAY")
assert_contains "Scout dir exists, preflight unavailable → still yellow" "$(row "$out" Scout)" "🟡"

echo "== #929 Day Close recognition"
ws=$(new_ws s929)
git -C "$ws/DS-strategy" init -q
git -C "$ws/DS-strategy" config user.email t@example.invalid
git -C "$ws/DS-strategy" config user.name t
echo seed > "$ws/DS-strategy/README.md"
git -C "$ws/DS-strategy" add README.md
git -C "$ws/DS-strategy" commit -q -m "init"
out=$(scaffold s929 2026-09-26)
assert_contains "no archived plan → not found" "$out" "Day Close за $YDAY не найден"
mkdir -p "$ws/DS-strategy/archive/day-plans"
printf '# DayPlan\n\n### Завтра начать с\n- WP-1\n' > "$ws/DS-strategy/archive/day-plans/DayPlan $YDAY.md"
git -C "$ws/DS-strategy" add archive/day-plans
git -C "$ws/DS-strategy" commit -q -m "Закрытие дня 25.09: итоги"
out=$(scaffold s929 2026-09-26)
assert_lacks "archived plan + free-form commit message → found" "$out" "Day Close за $YDAY не найден"
assert_contains "archived plan → PENDING marker for the synthesis" "$out" "PENDING: count из Day Close отчёта за $YDAY"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS"; else echo "FAILED: $FAILS"; exit 1; fi
