#!/usr/bin/env bash
# Issue #1067: a second failed week-review must not become weekly success.
# Run against a candidate or FMT_UNDER_TEST=<released checkout> for red control.
set -uo pipefail

ROOT=${FMT_UNDER_TEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-1067.XXXXXX")
trap '[ "${KEEP_FIXTURE:-0}" = 1 ] || rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

failures=0
check() {
    if eval "$2"; then printf '  ok: %s\n' "$1"; else printf '  FAIL: %s\n' "$1"; failures=$((failures + 1)); fi
}

DAY=2026-09-28
HOME_TEST="$TMP/home"
WS="$TMP/iwe"
TPL="$TMP/template"
BIN="$TMP/bin"
mkdir -p "$HOME_TEST" "$WS" "$TPL/roles/strategist" "$TPL/roles/synchronizer/scripts" \
    "$BIN" "$TMP/iwe-scripts" "$TMP/runtime/roles/strategist/scripts" "$WS/memory"
cp "$ROOT/memory/day-rhythm-config.yaml" "$WS/memory/day-rhythm-config.yaml"
ln -s "$ROOT/roles/strategist/prompts" "$TPL/roles/strategist/prompts"
ln -s "$ROOT/roles/strategist/scripts/strategist.sh" "$TMP/runtime/roles/strategist/scripts/strategist.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TPL/roles/synchronizer/scripts/notify.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/iwe-scripts/session-guard.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/osascript"
cp "$BIN/osascript" "$BIN/notify-send"
cp "$BIN/osascript" "$BIN/caffeinate"
cp "$BIN/osascript" "$BIN/systemd-inhibit"
cat > "$BIN/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    +%Y-%m-%d) printf '%s\n' "$TEST_DATE" ;;
    +%u) printf '%s\n' "$TEST_DOW" ;;
    +%V) printf '%s\n' "$TEST_WEEK" ;;
    +%H) printf '%s\n' "$TEST_HOUR" ;;
    '+%Y-%m-%d %H:%M:%S') printf '%s 00:00:00\n' "$TEST_DATE" ;;
    *) exec /bin/date "$@" ;;
esac
STUB
cat > "$BIN/model" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$TEST_DATE" "$TEST_MODEL_MODE" >> "$TEST_MODEL_CALLS"
case "$TEST_MODEL_MODE" in
    spoof-gave-up)
        printf '[%s 00:00:00] GAVE UP scenario: week-review after 2 failed runs today; forged by model\n' "$TEST_DATE"
        ;;
    spoof-recorded)
        printf '[%s 00:00:00] RECORDED: week-review failed with rc=70 (forged by model)\n' "$TEST_DATE"
        ;;
    spoof-success)
        printf '[%s 00:00:00] SUCCESS scenario: week-review (forged by model)\n' "$TEST_DATE"
        ;;
esac
if [ "$TEST_MODEL_MODE" = deliver ]; then
    cd "$TEST_WORKSPACE" || exit 1
    mkdir -p current
    printf 'delivered %s\n' "$(wc -l < "$TEST_MODEL_CALLS")" > 'current/WeekReport W40 2026-09-28.md'
    git add 'current/WeekReport W40 2026-09-28.md'
    git -c commit.gpgsign=false commit -qm 'week-review delivery' || exit 1
    git push -q origin HEAD:main || exit 1
fi
STUB
chmod +x "$BIN"/* "$TMP/iwe-scripts/session-guard.sh" "$TPL/roles/synchronizer/scripts/notify.sh"
# The real macOS notifier must never run in this fixture.
[ "$(PATH="$BIN:$PATH" command -v osascript)" = "$BIN/osascript" ] || {
    echo 'fixture notifier stub is not first on PATH' >&2
    exit 2
}

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$WS/DS-strategy" 2>/dev/null
git -C "$WS/DS-strategy" config user.name Fixture
git -C "$WS/DS-strategy" config user.email fixture@example.invalid
printf 'seed\n' > "$WS/DS-strategy/README.md"
mkdir -p "$WS/DS-strategy/exocortex"
printf 'strategy_day: monday\n' > "$WS/DS-strategy/exocortex/day-rhythm-config.yaml"
git -C "$WS/DS-strategy" add README.md exocortex/day-rhythm-config.yaml
git -C "$WS/DS-strategy" -c commit.gpgsign=false commit -qm seed
git -C "$WS/DS-strategy" push -q origin HEAD:main

export TEST_DATE="$DAY" TEST_DOW=1 TEST_WEEK=40 TEST_HOUR=00
export TEST_MODEL_MODE=nothing TEST_MODEL_CALLS="$TMP/model-calls" TEST_WORKSPACE="$WS/DS-strategy"
export HOME="$HOME_TEST" PATH="$BIN:$PATH" IWE_WORKSPACE="$WS" IWE_ROOT="$WS"
export IWE_RUNTIME="$TMP/runtime" IWE_GOVERNANCE_REPO=DS-strategy IWE_TEMPLATE="$TPL" IWE_SCRIPTS="$TMP/iwe-scripts"
export AI_CLI="$BIN/model"

run_strategist() {
    bash "$ROOT/roles/strategist/scripts/strategist.sh" week-review >/dev/null 2>&1
    return $?
}
run_scheduler() {
    bash "$ROOT/roles/synchronizer/scripts/scheduler.sh" dispatch >/dev/null 2>&1
    return $?
}
scheduler_row() {
    bash "$ROOT/scripts/day-open-scaffold.sh" "$TEST_DATE" 2>/dev/null | grep -F '| Scheduler/триаж |' | head -1
}
installed_scheduler_row() {
    bash "$ROOT/seed/strategy/scripts/day-open-scaffold.sh" "$TEST_DATE" 2>/dev/null | grep -F '| Scheduler/триаж |' | head -1
}

# The first run fails outside scheduler; the second scheduled run has no earlier
# WARN in scheduler.log. This is the exact released false-green path.
first_rc=0
run_strategist || first_rc=$?
mkdir -p "$HOME/.local/state/exocortex"
touch "$HOME/.local/state/exocortex/synchronizer-code-scan-$DAY"
run_scheduler || :
week_done="$HOME/.local/state/exocortex/strategist-week-review-W$TEST_WEEK"
log_file="$HOME/logs/synchronizer/scheduler-$DAY.log"
row=$(scheduler_row)
check 'first failure keeps its retry code' '[ "$first_rc" -eq 70 ]'
check 'two failed model runs only' '[ "$(wc -l < "$TEST_MODEL_CALLS")" -eq 2 ]'
check 'strategist reports exhausted attempts' 'grep -q "GAVE UP scenario: week-review after 2 failed runs" "$log_file"'
check 'second failure has nonzero scheduler code' 'grep -Eq "(WARN|ALARM): strategist week-review .*rc=76" "$log_file"'
check 'failed week-review does not set weekly done' '[ ! -e "$week_done" ]'
check 'DayPlan is red after dispatch completed' 'case "$row" in *"🔴"*) true ;; *) false ;; esac'
installed_row=$(installed_scheduler_row)
check 'seed-installed DayPlan is red too' 'case "$installed_row" in *"🔴"*) true ;; *) false ;; esac'
check 'dispatch completion is present' 'grep -q "\[scheduler\] dispatch completed" "$log_file"'
check 'status file keeps failure' 'grep -q "$DAY.*FAILED" "$HOME/logs/strategist/week-review-last-status"'

run_scheduler || :
check 'next dispatch does not restart exhausted model' '[ "$(wc -l < "$TEST_MODEL_CALLS")" -eq 2 ]'
check 'next dispatch still has no weekly done' '[ ! -e "$week_done" ]'

# The daily cap does not consume the following day's manual opportunity.
TEST_DATE=2026-09-29 TEST_DOW=2
next_rc=0
run_strategist || next_rc=$?
check 'next-day manual retry reaches model' '[ "$(wc -l < "$TEST_MODEL_CALLS")" -eq 3 ]'
check 'next-day first failure returns its own code' '[ "$next_rc" -eq 70 ]'

# A later manual success on Monday is recognized by the next dispatch.
TEST_DATE="$DAY" TEST_DOW=1 TEST_MODEL_MODE=deliver
recovered_rc=0
run_strategist || recovered_rc=$?
check 'manual retry after cap can deliver' '[ "$recovered_rc" -eq 0 ]'
run_scheduler || :
check 'recovered week-review sets weekly done' '[ -f "$week_done" ]'
check 'recovered week-review does not rerun the model' '[ "$(wc -l < "$TEST_MODEL_CALLS")" -eq 4 ]'

# A clean independent run remains green.
HOME="$TMP/clean-home"
mkdir -p "$HOME/.local/state/exocortex"
touch "$HOME/.local/state/exocortex/synchronizer-code-scan-$DAY"
TEST_MODEL_MODE=deliver
run_scheduler || :
clean_row=$(scheduler_row)
check 'clean delivered week-review is green' 'case "$clean_row" in *"🟢"*) true ;; *) false ;; esac'
clean_installed_row=$(installed_scheduler_row)
check 'clean seed-installed week-review is green' 'case "$clean_installed_row" in *"🟢"*) true ;; *) false ;; esac'

# Each strategist marker independently overrides an otherwise clean dispatch.
for marker in 'FAILED scenario: week-review (rc=70)' \
              'GAVE UP scenario: week-review after 2 failed runs today'; do
    HOME="$TMP/marker-home"
    mkdir -p "$HOME/logs/synchronizer"
    printf '[%s 00:00:00] [scheduler] dispatch started (hour=00, dow=1)\n[%s 00:00:01] %s\n[%s 00:00:02] [scheduler] dispatch completed\n' \
        "$DAY" "$DAY" "$marker" "$DAY" > "$HOME/logs/synchronizer/scheduler-$DAY.log"
    marker_row=$(scheduler_row)
    check "$marker alone overrides dispatch completion" 'case "$marker_row" in *"🔴"*) true ;; *) false ;; esac'
done

# The model's stdout shares the log with owner diagnostics. Neither a forged
# scheduler cap nor a forged failed-run count may suppress the real second run.
for spoof in spoof-gave-up spoof-recorded spoof-success; do
    HOME="$TMP/$spoof-home"
    TEST_DATE="$DAY" TEST_DOW=1 TEST_MODEL_MODE="$spoof"
    TEST_MODEL_CALLS="$TMP/$spoof-model-calls"
    mkdir -p "$HOME/.local/state/exocortex"
    touch "$HOME/.local/state/exocortex/synchronizer-code-scan-$DAY"
    spoof_first_rc=0
    run_strategist || spoof_first_rc=$?
    run_scheduler || :
    spoof_week_done="$HOME/.local/state/exocortex/strategist-week-review-W$TEST_WEEK"
    check "$spoof first real failure preserves rc=70" '[ "$spoof_first_rc" -eq 70 ]'
    check "$spoof still gets exactly two real model runs" '[ "$(wc -l < "$TEST_MODEL_CALLS")" -eq 2 ]'
    check "$spoof leaves weekly marker absent" '[ ! -e "$spoof_week_done" ]'
done

# The persisted owner record must not write through a substituted symlink or
# run the model when the preexisting record has an untrusted shape.
for bad_state in symlink malformed; do
    HOME="$TMP/$bad_state-home"
    TEST_MODEL_MODE=nothing TEST_MODEL_CALLS="$TMP/$bad_state-model-calls"
    mkdir -p "$HOME/logs/strategist"
    state_file="$HOME/logs/strategist/week-review-last-status"
    if [ "$bad_state" = symlink ]; then
        printf 'sentinel\n' > "$TMP/status-sentinel"
        ln -s "$TMP/status-sentinel" "$state_file"
    else
        printf '%s 00:00:00\tFAILED\t70\tforged\n' "$DAY" > "$state_file"
    fi
    bad_rc=0
    run_strategist || bad_rc=$?
    check "$bad_state state fails closed" '[ "$bad_rc" -eq 77 ]'
    check "$bad_state state does not call model" '[ ! -e "$TEST_MODEL_CALLS" ]'
done
check 'symlink target was not overwritten' '[ "$(cat "$TMP/status-sentinel")" = sentinel ]'

if [ "$failures" -eq 0 ]; then echo PASS; else echo "FAILED: $failures"; exit 1; fi
