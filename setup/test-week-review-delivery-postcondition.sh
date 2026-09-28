#!/bin/bash
# test-week-review-delivery-postcondition.sh -- WP-561 Ф25 acceptance test for
# verify_delivery_postcondition() in roles/strategist/scripts/strategist.sh.
# 28.09.2026: week-review wrote its report, could not commit, was logged "SUCCESS" and marked
# the day done. The wrapper now proves delivery on origin/main before it writes SUCCESS.
# Runs the REAL functions (cut out of the script by name) against a throwaway bare origin.
#
# Usage: bash setup/test-week-review-delivery-postcondition.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
SCRIPT="$REPO_ROOT/roles/strategist/scripts/strategist.sh"
TEST_ROOT="${WEEK_REVIEW_POSTCONDITION_TEST_ROOT:-/tmp/iwe-week-review-postcondition-$$}"

# The fetch retries pause between attempts; no test below waits for a real pause (the one case that
# checks the pause values passes its own).
export DELIVERY_FETCH_PAUSE=0

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

# Cut a top-level function (or constant) out of the runner instead of sourcing it: the runner is
# an executable with side effects at load time, not a library.
extract_block() {  # <start regex> <end regex, first match at or after start>
    local start end
    start=$(grep -n -m1 "$1" "$SCRIPT" | cut -d: -f1)
    [ -n "$start" ] || { echo "cannot find '$1' in $SCRIPT" >&2; exit 2; }
    end=$(awk -v s="$start" -v pat="$2" 'NR >= s && $0 ~ pat { print NR; exit }' "$SCRIPT")
    sed -n "${start},${end}p" "$SCRIPT"
}
# The runner defines this fallback itself at load time (macOS has no GNU timeout); the cut-out
# functions need the same command to exist.
TIMEOUT_SHIM='command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }'
FUNCTIONS="$TIMEOUT_SHIM
$(extract_block '^DELIVERY_POSTCONDITION_RC=' '^DELIVERY_POSTCONDITION_RC=')
$(extract_block '^expected_delivery_path()' '^}')
$(extract_block '^fetch_delivery_origin()' '^}')
$(extract_block '^delivery_baseline()' '^}')
$(extract_block '^verify_delivery_postcondition()' '^}')"

mkdir -p "$TEST_ROOT"
ORIGIN="$TEST_ROOT/origin.git"
WORKSPACE="$TEST_ROOT/workspace"     # the checkout the wrapper watches
OTHER="$TEST_ROOT/other"             # whoever pushes to origin while the model runs
LOG_FILE="$TEST_ROOT/run.log"

git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$WORKSPACE" 2>/dev/null
git -C "$WORKSPACE" config user.email t@test; git -C "$WORKSPACE" config user.name test
mkdir -p "$WORKSPACE/current"
echo seed > "$WORKSPACE/current/WeekPlan W39 2026-09-21.md"
git -C "$WORKSPACE" add -A && git -C "$WORKSPACE" -c commit.gpgsign=false commit -q -m seed
git -C "$WORKSPACE" push -q origin HEAD:main
git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
git -C "$OTHER" config user.email t@test; git -C "$OTHER" config user.name test

log() { echo "$1" >> "$LOG_FILE"; }

# run_postcondition <scenario> <pre-origin sha>  -> prints the exit code; the log is in $LOG_FILE
run_postcondition() {
    : > "$LOG_FILE"
    bash -c "log() { echo \"\$1\" >> \"$LOG_FILE\"; }
$FUNCTIONS
verify_delivery_postcondition \"\$1\" \"\$2\"
echo \$?" _ "$1" "$2" 2>/dev/null | tail -1
}
export WORKSPACE LOG_FILE

# run_baseline <scenario> -> prints what delivery_baseline() hands to the run (empty = none)
run_baseline() {
    : > "$LOG_FILE"
    bash -c "log() { echo \"\$1\" >> \"$LOG_FILE\"; }
$FUNCTIONS
delivery_baseline \"\$1\"" _ "$1" 2>/dev/null
}

push_from_other() {  # <path> [content]  -- commit one file on top of origin/main and push
    git -C "$OTHER" pull -q --ff-only origin main 2>/dev/null
    mkdir -p "$OTHER/$(dirname "$1")"
    echo "${2:-content}" > "$OTHER/$1"
    git -C "$OTHER" add -A && git -C "$OTHER" -c commit.gpgsign=false commit -q -m "add $1"
    git -C "$OTHER" push -q origin HEAD:main
}
pre_origin() { git -C "$WORKSPACE" fetch -q origin main && git -C "$WORKSPACE" rev-parse origin/main; }

echo "=== verify_delivery_postcondition ==="

PRE=$(pre_origin)
push_from_other "current/WeekReport W39 2026-09-21.md"
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "0" ] && pass "report delivered to origin/main during the run -> proven" || fail "delivered report must pass, rc=$rc: $(cat "$LOG_FILE")"

PRE=$(pre_origin)
rc=$(run_postcondition week-review "$PRE")
if [ "$rc" = "1" ] && grep -q 'отчёт не доставлен' "$LOG_FILE"; then
    pass "nothing pushed during the run -> not delivered, reason logged"
else
    fail "an undelivered run must fail with a logged reason, rc=$rc: $(cat "$LOG_FILE")"
fi

PRE=$(pre_origin)
push_from_other "current/DayPlan 2026-09-28.md"
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "1" ] && pass "an unrelated commit on origin/main does not count as delivery" || fail "unrelated commit must not satisfy the check, rc=$rc"

PRE=$(pre_origin)
push_from_other "archive/WeekReport W40 2026-09-28.md"
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "1" ] && pass "a report written outside current/ does not count (exact path)" || fail "report outside current/ must not pass, rc=$rc"

PRE=$(pre_origin)
push_from_other "current/nested/WeekReport W40 2026-09-28.md"
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "1" ] && pass "a report in a subfolder of current/ does not count (glob does not cross /)" || fail "nested report must not pass, rc=$rc"

PRE=$(pre_origin)
git -C "$OTHER" fetch -q origin main
git -C "$OTHER" reset -q --hard "$(git -C "$OTHER" rev-list --max-parents=0 HEAD | head -1)"
mkdir -p "$OTHER/current"; echo forced > "$OTHER/current/WeekReport W40 2026-09-28.md"
git -C "$OTHER" add -A && git -C "$OTHER" -c commit.gpgsign=false commit -q -m "rewritten history"
git -C "$OTHER" push -q --force origin HEAD:main
rc=$(run_postcondition week-review "$PRE")
if [ "$rc" = "1" ] && grep -q 'не продолжает' "$LOG_FILE"; then
    pass "force-pushed origin/main (old state not an ancestor) is refused even though a report file appears"
else
    fail "diverged origin must be refused, rc=$rc: $(cat "$LOG_FILE")"
fi

PRE=$(pre_origin)
git -C "$OTHER" fetch -q origin main && git -C "$OTHER" reset -q --hard origin/main
push_from_other "current/WeekReport W41 2026-10-05.md"
PRE=$(pre_origin)
git -C "$OTHER" rm -q "current/WeekReport W41 2026-10-05.md"
git -C "$OTHER" -c commit.gpgsign=false commit -q -m "delete the report"
git -C "$OTHER" push -q origin HEAD:main
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "1" ] && pass "deleting a report file is not a delivery" || fail "a deletion must not satisfy the check, rc=$rc: $(cat "$LOG_FILE")"

# A report that was already on origin/main before the run and did not change is not this run's
# delivery (per-run proof, on purpose) -- but the log must name it, so a rerun after an earlier
# delivery reads as a false alarm at a glance rather than as a lost report.
push_from_other "current/WeekReport W42 2026-10-12.md"
PRE=$(pre_origin)
rc=$(run_postcondition week-review "$PRE")
if [ "$rc" = "1" ] && grep -q 'отчёт не доставлен' "$LOG_FILE" && grep -q 'уже есть, без изменений за этот запуск: .*WeekReport W42 2026-10-12.md' "$LOG_FILE"; then
    pass "a pre-existing, unchanged report is not this run's delivery, and the log names what is already there"
else
    fail "unchanged pre-existing report: rc=$rc log=$(cat "$LOG_FILE")"
fi

rc=$(run_postcondition week-review "")
[ "$rc" = "1" ] && grep -q 'перед запуском' "$LOG_FILE" && pass "no baseline sha -> refused, cannot prove delivery" || fail "missing baseline must be refused, rc=$rc"

echo "=== delivery_baseline ==="

BASE=$(run_baseline week-review)
[ "$BASE" = "$(git -C "$ORIGIN" rev-parse main)" ] && pass "reachable origin -> baseline is the current origin/main" || fail "baseline must equal origin/main, got '$BASE'"

git -C "$WORKSPACE" fetch -q origin main   # a local remote-tracking ref now exists and is about to go stale
mv "$ORIGIN" "$ORIGIN.gone"
BASE=$(run_baseline week-review)
mv "$ORIGIN.gone" "$ORIGIN"
[ -z "$BASE" ] && pass "failed pre-run fetch -> no baseline, the stale local origin/main is NOT reused" || fail "a stale local ref must not become the baseline, got '$BASE'"

BASE=$(run_baseline day-plan)
[ -z "$BASE" ] && pass "a scenario without a delivery contract has no baseline" || fail "day-plan must have no baseline, got '$BASE'"

echo "=== back to verify_delivery_postcondition ==="

rc=$(run_postcondition day-plan "")
[ "$rc" = "0" ] && pass "a scenario without a delivery contract is untouched" || fail "day-plan must not be gated, rc=$rc"

PRE=$(pre_origin)
mv "$ORIGIN" "$ORIGIN.gone"
rc=$(run_postcondition week-review "$PRE")
mv "$ORIGIN.gone" "$ORIGIN"
[ "$rc" = "1" ] && grep -q 'git fetch не удался' "$LOG_FILE" && pass "unreachable origin -> refused, cannot prove delivery" || fail "unreachable origin must be refused, rc=$rc"

echo "=== fetch_delivery_origin: bounded retries ==="

# A stand-in for git, used through DELIVERY_GIT_BIN by fetch_delivery_origin ONLY: the publisher and
# the guard keep the real git. FETCH_PLAN holds one letter per call: F = fail, T = exit 124 (a
# timeout), G = print a line to stdout and then run the real git, anything else = the real git; calls
# past the plan use the real git.
REAL_GIT=$(command -v git)
FETCH_STATE="$TEST_ROOT/fetch.state"
cat > "$TEST_ROOT/fetch-git-stub.sh" <<'STUB'
#!/bin/bash
n=$(( $(cat "$FETCH_STATE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FETCH_STATE"
read -ra plan <<< "${FETCH_PLAN:-}"
case "${plan[$((n - 1))]:-.}" in
    F) echo "fatal: unable to access 'origin': Could not resolve host" >&2; exit 128 ;;
    T) exit 124 ;;
    G) echo "STDOUT-GARBAGE"; exec "$REAL_GIT" "$@" ;;
    *) exec "$REAL_GIT" "$@" ;;
esac
STUB
chmod +x "$TEST_ROOT/fetch-git-stub.sh"
export REAL_GIT FETCH_STATE

SLEEP_LOG="$TEST_ROOT/sleep.log"
PLAN_PAUSE=0
# run_with_plan <plan> <snippet that uses the cut-out functions>; sleep() is a recorder, log() as above
run_with_plan() {
    : > "$LOG_FILE"; : > "$SLEEP_LOG"; rm -f "$FETCH_STATE"
    FETCH_PLAN="$1" DELIVERY_GIT_BIN="$TEST_ROOT/fetch-git-stub.sh" DELIVERY_FETCH_PAUSE="$PLAN_PAUSE" bash -c "log() { echo \"\$1\" >> \"$LOG_FILE\"; }
sleep() { echo \"\$1\" >> \"$SLEEP_LOG\"; }
$FUNCTIONS
$2" 2>/dev/null
}
calls() { cat "$FETCH_STATE" 2>/dev/null || echo 0; }
ORIGIN_SHA=$(git -C "$ORIGIN" rev-parse main)

BASE=$(run_with_plan "F F ." 'delivery_baseline week-review')
[ "$BASE" = "$ORIGIN_SHA" ] && [ "$(calls)" = "3" ] \
    && pass "two failed fetches then a good one -> baseline is exactly the sha (stdout carries nothing else), 3 calls" \
    || fail "transient fetch failure: base='$BASE' calls=$(calls)"

BASE=$(run_with_plan "T T ." 'delivery_baseline week-review')
[ "$BASE" = "$ORIGIN_SHA" ] && grep -q 'GIT-FETCH: попытка 1 из 3 не удалась (код 124)' "$LOG_FILE" \
    && pass "exit 124 from timeout counts as a failed try, not as success" \
    || fail "a timeout must be retried: base='$BASE' log=$(cat "$LOG_FILE")"

PLAN_PAUSE=5
BASE=$(run_with_plan "F F F" 'delivery_baseline week-review')
PLAN_PAUSE=0
if [ -z "$BASE" ] && [ "$(calls)" = "3" ] && [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "5 10 " ] \
    && [ "$(grep -c 'GIT-FETCH: попытка' "$LOG_FILE")" = "3" ]; then
    pass "all three tries fail -> no baseline; pauses are 5 s then 10 s and none after the last try"
else
    fail "exhausted retries: base='$BASE' calls=$(calls) sleeps='$(tr '\n' ' ' < "$SLEEP_LOG")'"
fi

rc=$(run_with_plan "F F . F F ." 'pre=$(delivery_baseline week-review); verify_delivery_postcondition week-review "$pre"; echo $?' | tail -1)
if [ "$rc" = "1" ] && [ "$(calls)" = "6" ] && grep -q 'отчёт не доставлен' "$LOG_FILE" && ! grep -q 'git fetch не удался' "$LOG_FILE"; then
    pass "the retry budget is per call: 3 tries before the model and 3 after it, each recovered"
else
    fail "per-call budget: rc=$rc calls=$(calls) log=$(cat "$LOG_FILE")"
fi

BASE_ZERO=$(run_with_plan "F F ." 'export DELIVERY_FETCH_ATTEMPTS=0; delivery_baseline week-review')
BASE_TEXT=$(run_with_plan "F F ." 'export DELIVERY_FETCH_TIMEOUT=abc; delivery_baseline week-review')
[ "$BASE_ZERO" = "$ORIGIN_SHA" ] && [ "$BASE_TEXT" = "$ORIGIN_SHA" ] \
    && pass "a zero or non-numeric setting falls back to the defaults instead of breaking the loop" \
    || fail "bad settings must fall back to 3 tries: zero='$BASE_ZERO' text='$BASE_TEXT'"

# A leading zero is read by bash as octal: 09 would be an arithmetic error that ends the script, 010
# would wait 8 s. It must fall back to the default pause (5 s, then 10 s) instead.
BASE=$(run_with_plan "F F ." 'export DELIVERY_FETCH_PAUSE=09; delivery_baseline week-review')
[ "$BASE" = "$ORIGIN_SHA" ] && [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "5 10 " ] \
    && pass "a leading-zero pause (09) falls back to the default instead of an octal error" \
    || fail "pause 09: base='$BASE' sleeps='$(tr '\n' ' ' < "$SLEEP_LOG")'"

# Each setting is judged on its own: a bad pause must not throw away a good attempts value.
BASE=$(run_with_plan "F F F" 'export DELIVERY_FETCH_ATTEMPTS=2 DELIVERY_FETCH_PAUSE=abc; delivery_baseline week-review')
[ -z "$BASE" ] && [ "$(calls)" = "2" ] && [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "5 " ] \
    && pass "settings are checked one by one: attempts=2 is kept while the bad pause falls back to 5 s" \
    || fail "per-setting fallback: base='$BASE' calls=$(calls) sleeps='$(tr '\n' ' ' < "$SLEEP_LOG")'"

# Zero is the one legitimate zero: a pause of 0 means no waiting (the whole suite runs that way).
BASE=$(run_with_plan "F F F" 'delivery_baseline week-review')
[ -z "$BASE" ] && [ "$(calls)" = "3" ] && [ "$(tr '\n' ' ' < "$SLEEP_LOG")" = "0 0 " ] \
    && pass "a pause of 0 is accepted as no waiting" \
    || fail "pause 0: base='$BASE' calls=$(calls) sleeps='$(tr '\n' ' ' < "$SLEEP_LOG")'"

# The fetch binary's own stdout must not reach the caller: the baseline is captured with $(...).
BASE=$(run_with_plan "G" 'delivery_baseline week-review')
[ "$BASE" = "$ORIGIN_SHA" ] \
    && pass "the fetch's stdout is discarded: the baseline is exactly the sha" \
    || fail "fetch stdout leaked into the baseline: '$BASE'"

echo "=== end to end: the real strategist.sh week-review with a stand-in model ==="

# The wiring (run_claude ordering, retry wrapper, `set -e`, the case branch) is the part unit tests
# above cannot see, and it is where 28.09 went wrong. Everything external is stubbed: the model,
# the Telegram sender, macOS notifications; HOME and the workspace are throwaway.
E2E_HOME="$TEST_ROOT/home"; E2E_WS="$TEST_ROOT/iwe"; E2E_TPL="$TEST_ROOT/template"
mkdir -p "$E2E_HOME" "$E2E_WS" "$E2E_TPL/roles/synchronizer/scripts" "$TEST_ROOT/bin"
git clone -q "$ORIGIN" "$E2E_WS/DS-strategy" 2>/dev/null
git -C "$E2E_WS/DS-strategy" config user.email t@test; git -C "$E2E_WS/DS-strategy" config user.name test
ln -s "$REPO_ROOT/roles/strategist/prompts" "$E2E_TPL/roles/strategist_prompts_link" 2>/dev/null
mkdir -p "$E2E_TPL/roles/strategist"; ln -s "$REPO_ROOT/roles/strategist/prompts" "$E2E_TPL/roles/strategist/prompts"
NOTIFY_LOG="$TEST_ROOT/notify.log"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$E2E_TPL/roles/synchronizer/scripts/notify.sh"
printf '#!/bin/bash\nexit 0\n' > "$TEST_ROOT/bin/osascript"; cp "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/notify-send"
cat > "$TEST_ROOT/stub-model.sh" <<'STUB'
#!/bin/bash
# Stands in for the model. STUB_MODE: nothing (exit 0, deliver nothing) | deliver | crash
# | commit-crash (a local report commit, no push, exit 1) | auth403 (the CLI's own auth error, exit 1)
[ -z "${GUARD_LOG:-}" ] || echo MODEL >> "$GUARD_LOG"
case "${STUB_MODE:-nothing}" in
    deliver)
        cd "$STUB_WORKSPACE" || exit 9
        mkdir -p current
        # unique per run: origin already holds the file after the first delivery, and an identical
        # rewrite would commit nothing (and so deliver nothing)
        echo "report $$ $(date +%s%N)" > "current/WeekReport W39 2026-09-21.md"
        git add -A && git -c commit.gpgsign=false commit -q -m "week report" && git push -q origin HEAD:main
        ;;
    commit-crash)
        cd "$STUB_WORKSPACE" || exit 9
        mkdir -p current
        echo "report $$ $(date +%s%N)" > "current/WeekReport W39 2026-09-21.md"
        git add "current/WeekReport W39 2026-09-21.md" && git -c commit.gpgsign=false commit -q -m "week report (local)"
        exit 1
        ;;
    auth403) echo "API Error: 403 Request not allowed"; exit 1 ;;
    crash) exit 1 ;;
esac
exit 0
STUB
# A no-op sleep that records its argument while STUB_SLEEP_LOG is set (the model's auth retry waits
# 60 s and 300 s); the real sleep otherwise.
cat > "$TEST_ROOT/bin/sleep" <<'STUB'
#!/bin/bash
if [ -n "${STUB_SLEEP_LOG:-}" ]; then echo "$1" >> "$STUB_SLEEP_LOG"; exit 0; fi
exec /bin/sleep "$@"
STUB
chmod +x "$TEST_ROOT/bin/sleep"
chmod +x "$E2E_TPL/roles/synchronizer/scripts/notify.sh" "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/notify-send" "$TEST_ROOT/stub-model.sh"
# The stubs must shadow the real notifiers, or a test run would pop up real desktop notifications.
[ "$(PATH="$TEST_ROOT/bin:$PATH" command -v osascript)" = "$TEST_ROOT/bin/osascript" ] \
    || { echo "the stand-in osascript does not shadow the real one" >&2; exit 2; }

run_week_review() {  # <STUB_MODE> [keep-logs] -> exit code of the real script on stdout; notifications in $NOTIFY_LOG
    [ "${2:-}" = "keep-logs" ] || rm -rf "$E2E_HOME/logs"
    rm -f "$NOTIFY_LOG"
    HOME="$E2E_HOME" PATH="$TEST_ROOT/bin:$PATH" IWE_WORKSPACE="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy \
        IWE_TEMPLATE="$E2E_TPL" AI_CLI="$TEST_ROOT/stub-model.sh" STUB_MODE="$1" STUB_WORKSPACE="$E2E_WS/DS-strategy" \
        bash "$SCRIPT" week-review >/dev/null 2>&1
    echo $?
}
e2e_log_text() { cat "$E2E_HOME"/logs/strategist/*.log 2>/dev/null; }

git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main
rc=$(run_week_review nothing)
LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "70" ] && printf '%s' "$LOG_TEXT" | grep -q 'FAILED scenario: week-review (rc=70)' \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: week-review' \
    && printf '%s' "$LOG_TEXT" | grep -q 'POSTCONDITION scenario: week-review' \
    && grep -q 'strategist week-review-failed' "$NOTIFY_LOG"; then
    pass "model exits 0 but delivers nothing -> exit 70, FAILED + POSTCONDITION logged, no SUCCESS, alarm sent"
else
    fail "an undelivered run must be loud: rc=$rc notify=$(cat "$NOTIFY_LOG" 2>/dev/null) log=$(printf '%s' "$LOG_TEXT" | tail -4)"
fi
grep -q 'FAILED' "$E2E_HOME/logs/strategist/week-review-last-status" 2>/dev/null \
    && pass "the traffic-light status file records the failure" || fail "week-review-last-status must say FAILED"

git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main
# The scheduler reruns every non-zero exit at its next dispatch. A second failed run the same day
# must end the loop (exit 0) while still alarming; the first one must keep exit 70 so a retry is possible.
rc_first=$(run_week_review nothing)
rc_second=$(run_week_review nothing keep-logs)
LOG_TEXT=$(e2e_log_text)
if [ "$rc_first" = "70" ] && [ "$rc_second" = "0" ] && printf '%s' "$LOG_TEXT" | grep -q 'GAVE UP scenario: week-review after 2 failed runs' \
    && grep -q 'strategist week-review-failed' "$NOTIFY_LOG"; then
    pass "first failed run exits 70 (retry allowed), second the same day gives up with exit 0 and still alarms"
else
    fail "retry cap: first=$rc_first second=$rc_second notify=$(cat "$NOTIFY_LOG" 2>/dev/null) log=$(printf '%s' "$LOG_TEXT" | tail -3)"
fi

git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main
rc=$(run_week_review deliver)
LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "0" ] && printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: week-review' \
    && grep -qx 'strategist week-review' "$NOTIFY_LOG" && ! grep -q 'failed' "$NOTIFY_LOG"; then
    pass "report delivered to origin/main -> exit 0, SUCCESS logged, normal notification, no alarm"
else
    fail "a delivered run must succeed quietly: rc=$rc notify=$(cat "$NOTIFY_LOG" 2>/dev/null) log=$(printf '%s' "$LOG_TEXT" | tail -4)"
fi

git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main
rc=$(run_week_review crash)
if [ "$rc" = "1" ] && grep -q 'strategist week-review-failed' "$NOTIFY_LOG"; then
    pass "the model itself crashes (exit 1) -> the script exits 1 and alarms (before: silent under set -e)"
else
    fail "a crashed run must alarm and keep its own exit code: rc=$rc notify=$(cat "$NOTIFY_LOG" 2>/dev/null)"
fi

echo "=== end to end: the session the wrapper opens for the model ==="

# A stand-in guard records every call, and refuses on demand. The wrapper must call it in a fixed
# order around the model and must close what it opened exactly once, whatever happens to the model.
mkdir -p "$TEST_ROOT/guard-bin"
cat > "$TEST_ROOT/guard-bin/session-guard.sh" <<'STUB'
#!/bin/bash
echo "guard $*" >> "$GUARD_LOG"
case "${STUB_GUARD:-ok}" in
    open-refuses) [ "$1" = "open" ] && { echo "session-guard: refused (stub)"; exit 1; } ;;
    note-refuses) [ "$1" = "note-file" ] && { echo "session-guard: refused (stub)"; exit 1; } ;;
esac
exit 0
STUB
chmod +x "$TEST_ROOT/guard-bin/session-guard.sh"
GUARD_LOG="$TEST_ROOT/guard.log"
STALE_SEM="$E2E_WS/.iwe-runtime/sessions/strategist-week-review-housekeeping-week-review-2026-09-01-1.open"

# run_guarded <STUB_MODE> <STUB_GUARD> [with-guard|no-guard] -> exit code; calls in $GUARD_LOG
run_guarded() {
    rm -rf "$E2E_HOME/logs"; rm -f "$NOTIFY_LOG" "$GUARD_LOG"
    local scripts_dir="$TEST_ROOT/guard-bin"
    [ "${3:-with-guard}" = "no-guard" ] && scripts_dir="$TEST_ROOT/no-guard-here"
    [ "${3:-with-guard}" = "real-guard" ] && scripts_dir="$REPO_ROOT/scripts"
    HOME="$E2E_HOME" PATH="$TEST_ROOT/bin:$PATH" IWE_WORKSPACE="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy \
        IWE_TEMPLATE="$E2E_TPL" IWE_SCRIPTS="$scripts_dir" AI_CLI="$TEST_ROOT/stub-model.sh" STUB_MODE="$1" \
        STUB_GUARD="$2" GUARD_LOG="$GUARD_LOG" STUB_WORKSPACE="$E2E_WS/DS-strategy" \
        DELIVERY_GIT_BIN="${E2E_DELIVERY_GIT_BIN:-}" FETCH_PLAN="${E2E_FETCH_PLAN:-}" STUB_SLEEP_LOG="${E2E_SLEEP_LOG:-}" \
        bash "$SCRIPT" week-review >/dev/null 2>"${E2E_STDERR:-/dev/null}"
    echo $?
}
# with_fetch_plan <plan>: the next run_guarded calls use the fetch stand-in until without_fetch_plan
with_fetch_plan() { E2E_DELIVERY_GIT_BIN="$TEST_ROOT/fetch-git-stub.sh"; E2E_FETCH_PLAN="$1"; rm -f "$FETCH_STATE"; }
without_fetch_plan() { E2E_DELIVERY_GIT_BIN=""; E2E_FETCH_PLAN=""; }
model_runs() { grep -c '^MODEL$' "$GUARD_LOG" 2>/dev/null || true; }
guard_calls() {
    sed -E 's/--owner-pid [0-9]+/--owner-pid N/; s/week-review-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+/week-review-R/g' \
        "$GUARD_LOG" 2>/dev/null | tr '\n' '|'
}
reset_ws() { git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main; }
OPEN='guard open --housekeeping week-review-R --agent strategist-week-review --canonical-owner week-review --owner-pid N|'
# --slug: the run's own reason selects ITS session even when a second live session of the same agent
# exists (see the real-guard case below).
NOTE='guard note-file current/ --agent strategist-week-review --slug week-review-R|'
CLOSE='guard close --housekeeping week-review-R --agent strategist-week-review|'

reset_ws
rc=$(run_guarded deliver ok); calls=$(guard_calls); LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "0" ] && [ "$calls" = "${OPEN}${NOTE}MODEL|${CLOSE}" ] && printf '%s' "$LOG_TEXT" | grep -q 'SESSION: открыта служебная сессия'; then
    pass "session owned by the script: open (as scheduled runner) -> note-file current/ -> model -> close, exit 0"
else
    fail "wrong call order: rc=$rc calls=$calls"
fi

reset_ws
rc=$(run_guarded crash ok); calls=$(guard_calls)
[ "$rc" = "1" ] && [ "$calls" = "${OPEN}${NOTE}MODEL|${CLOSE}" ] \
    && pass "the model crashes -> the session is still closed, exactly once, and the run keeps its own exit code" \
    || fail "a crashed model must not leak the session: rc=$rc calls=$calls"

reset_ws
rc=$(run_guarded deliver open-refuses); calls=$(guard_calls); LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "71" ] && [ "$calls" = "${OPEN}" ] && printf '%s' "$LOG_TEXT" | grep -q 'FAILED scenario: week-review (rc=71)' \
    && grep -q 'strategist week-review-failed' "$NOTIFY_LOG"; then
    pass "a guard that refuses the session -> the model is NOT started, exit 71, alarm sent"
else
    fail "a refused open must stop the run before the model: rc=$rc calls=$calls notify=$(cat "$NOTIFY_LOG" 2>/dev/null)"
fi

reset_ws
rc=$(run_guarded deliver note-refuses); calls=$(guard_calls)
[ "$rc" = "71" ] && [ "$calls" = "${OPEN}${NOTE}${CLOSE}" ] \
    && pass "the scope cannot be declared -> the half-open session is closed and the model is NOT started" \
    || fail "a refused note-file must roll the session back: rc=$rc calls=$calls"

reset_ws
rc=$(run_guarded deliver ok no-guard); LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "0" ] && [ "$(guard_calls)" = "MODEL|" ] && printf '%s' "$LOG_TEXT" | grep -q 'session-guard.sh не найден'; then
    pass "an install with no guard at all runs as before (WARN in the log, no session)"
else
    fail "an install with no guard must still run and deliver, no guard calls: rc=$rc calls=$(guard_calls)"
fi

reset_ws
mkdir -p "$(dirname "$STALE_SEM")"; : > "$STALE_SEM"
rc=$(run_guarded deliver ok); calls=$(guard_calls); LOG_TEXT=$(e2e_log_text)
if [ "$rc" = "0" ] && [ "$calls" = "${CLOSE}${OPEN}${NOTE}MODEL|${CLOSE}" ] && printf '%s' "$LOG_TEXT" | grep -q 'остаточная сессия'; then
    pass "a leftover semaphore of a dead run (no live owner pid) is closed by its own reason, then the session opens as usual"
else
    fail "leftover handling: rc=$rc calls=$calls"
fi
rm -f "$STALE_SEM"

# A leftover whose recorded owner pid is alive belongs to a live run (for instance one that started
# before midnight, when the per-day lock name changes): it must be left alone.
reset_ws
# This test's own pid is alive for the whole run: no background process to spawn and reap.
mkdir -p "$(dirname "$STALE_SEM")"; printf 'agent: strategist-week-review\npid: %s\n' "$$" > "$STALE_SEM"
rc=$(run_guarded deliver ok); calls=$(guard_calls)
[ "$rc" = "0" ] && [ "$calls" = "${OPEN}${NOTE}MODEL|${CLOSE}" ] && [ -e "$STALE_SEM" ] \
    && pass "a semaphore whose owner pid is alive is not touched (its run may still be in the model)" \
    || fail "a live run's session must be left alone: rc=$rc calls=$calls"
rm -f "$STALE_SEM"

# The template's OWN guard keeps a receipt for every closed housekeeping name and refuses to reopen
# the same name (found by the cold review: with a fixed name the second run of a template install
# died with exit 71). Two runs one after another must both get their session.
rm -rf "$E2E_WS/.iwe-runtime"
reset_ws
rc_first=$(run_guarded nothing ok real-guard); LOG_FIRST=$(e2e_log_text)
reset_ws
rc_second=$(run_guarded deliver ok real-guard); LOG_SECOND=$(e2e_log_text)
open_left=$(find "$E2E_WS/.iwe-runtime/sessions" -name '*.open' 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc_first" = "70" ] && [ "$rc_second" = "0" ] && [ "$open_left" = "0" ] \
    && printf '%s' "$LOG_FIRST" | grep -q 'SESSION: открыта служебная сессия' \
    && printf '%s' "$LOG_SECOND" | grep -q 'SESSION: открыта служебная сессия'; then
    pass "template's own guard, two runs in a row: both get a session, none is left open (no wedge after a closed receipt)"
else
    fail "two runs against the template guard: first=$rc_first second=$rc_second open_left=$open_left log=$(printf '%s' "$LOG_SECOND" | tail -3)"
fi

# A second LIVE session of the same agent (a run that overlapped midnight, or a leftover whose pid
# got reused) makes an agent-only selector ambiguous: the real guard answered note-file with
# "несколько открытых семафоров" and the run died with 71 before the model (cold review, 28.09).
# The run must select its own session by its reason (slug), deliver, close only its own session and
# leave the live one alone.
LIVE_REASON="week-review-2026-09-01-1"
LIVE_SEM="$E2E_WS/.iwe-runtime/sessions/strategist-week-review-housekeeping-$LIVE_REASON.open"
real_guard() { ( cd "$E2E_WS/DS-strategy" && IWE_ROOT="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy bash "$REPO_ROOT/scripts/session-guard.sh" "$@" ) >/dev/null 2>&1; }
reset_ws
if real_guard open --housekeeping "$LIVE_REASON" --agent strategist-week-review --canonical-owner week-review --owner-pid "$$" && [ -e "$LIVE_SEM" ]; then
    rc=$(run_guarded deliver ok real-guard); LOG_TEXT=$(e2e_log_text)
    open_left=$(find "$E2E_WS/.iwe-runtime/sessions" -name '*.open' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$rc" = "0" ] && [ "$open_left" = "1" ] && [ -e "$LIVE_SEM" ] \
        && printf '%s' "$LOG_TEXT" | grep -q 'SESSION: открыта служебная сессия' \
        && printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: week-review'; then
        pass "template's own guard, a second live session of the same agent: the run still gets its scope (selected by slug), delivers, and leaves the live session alone"
    else
        fail "second live session: rc=$rc open_left=$open_left live_kept=$([ -e "$LIVE_SEM" ] && echo yes || echo no) log=$(printf '%s' "$LOG_TEXT" | tail -4)"
    fi
    real_guard close --housekeeping "$LIVE_REASON" --agent strategist-week-review
else
    fail "could not open the live session fixture with the template guard"
fi

echo "=== end to end: fetch failures around the model, and what counts as an auth failure ==="

# The week-review job has no rerun and no second chance at 00:00, so the wrapper must (1) ride out a
# short git outage on both sides of the model, (2) still run the model when the baseline could not be
# read (an unprovable delivery is better than no report at all), (3) restart the model only for the
# CLI's own auth errors, never for a 401 that came from git or from the publisher.
reset_ws
with_fetch_plan "F F . F F ."
rc=$(run_guarded deliver ok); LOG_TEXT=$(e2e_log_text)
without_fetch_plan
if [ "$rc" = "0" ] && [ "$(calls)" = "6" ] && [ "$(model_runs)" = "1" ] \
    && [ "$(printf '%s\n' "$LOG_TEXT" | grep -c 'GIT-FETCH: попытка')" = "4" ] \
    && printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: week-review'; then
    pass "a short git outage before and after the model is ridden out: delivered, proven, exit 0, 4 failed tries logged"
else
    fail "transient outage around the model: rc=$rc fetch_calls=$(calls) model_runs=$(model_runs) log=$(printf '%s' "$LOG_TEXT" | tail -4)"
fi

reset_ws
with_fetch_plan "F F F F F F"
rc=$(run_guarded deliver ok); LOG_TEXT=$(e2e_log_text); calls_seen=$(guard_calls)
without_fetch_plan
if [ "$rc" = "70" ] && [ "$(model_runs)" = "1" ] && [ "$calls_seen" = "${OPEN}${NOTE}MODEL|${CLOSE}" ] \
    && printf '%s' "$LOG_TEXT" | grep -q 'перед запуском прочитать не удалось' \
    && grep -q 'strategist week-review-failed' "$NOTIFY_LOG"; then
    pass "git is down before the run: the model STILL runs (no report is worse than an unprovable one), the run ends 70 with an alarm"
else
    fail "unreadable baseline: rc=$rc model_runs=$(model_runs) calls=$calls_seen notify=$(cat "$NOTIFY_LOG" 2>/dev/null)"
fi

# A publisher that fails with a 401 of its own, after a model that made a local commit and died.
# Restarting the model here would burn up to 90 minutes of a one-shot slot for a failure the model
# did not cause. The stand-in publisher makes no network call.
FAKE_PUB="$E2E_WS/DS-strategy/scripts/ds-publish.sh"
mkdir -p "$(dirname "$FAKE_PUB")"
printf '#!/bin/bash\necho "fatal: unable to access origin: The requested URL returned error: 401 Unauthorized"\nexit 1\n' > "$FAKE_PUB"
reset_ws
SLEEPS="$TEST_ROOT/e2e-sleeps.log"; : > "$SLEEPS"; E2E_SLEEP_LOG="$SLEEPS"
rc=$(run_guarded commit-crash ok); LOG_TEXT=$(e2e_log_text)
E2E_SLEEP_LOG=""
rm -f "$FAKE_PUB"; rmdir "$(dirname "$FAKE_PUB")" 2>/dev/null || true
if [ "$rc" = "1" ] && [ "$(model_runs)" = "1" ] && printf '%s' "$LOG_TEXT" | grep -q '401 Unauthorized' \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'AUTH_FAILURE' && [ ! -s "$SLEEPS" ]; then
    pass "a 401 from the publisher after a model failure is not a model auth error: no restart, the model ran once"
else
    fail "publisher 401 must not restart the model: rc=$rc model_runs=$(model_runs) sleeps='$(tr '\n' ' ' < "$SLEEPS")' log=$(printf '%s' "$LOG_TEXT" | tail -5)"
fi

# Positive control for the range: the CLI's OWN auth error still restarts the model (twice, with the
# 60 s and 300 s waits, which the recorder skips).
reset_ws
: > "$SLEEPS"; E2E_SLEEP_LOG="$SLEEPS"
rc=$(run_guarded auth403 ok); LOG_TEXT=$(e2e_log_text)
E2E_SLEEP_LOG=""
if [ "$rc" = "1" ] && [ "$(model_runs)" = "3" ] && [ "$(printf '%s\n' "$LOG_TEXT" | grep -c 'AUTH_FAILURE')" = "2" ] \
    && grep -qx 60 "$SLEEPS" && grep -qx 300 "$SLEEPS"; then
    pass "the CLI's own auth error still restarts the model (3 runs, waits 60 s and 300 s), then the run fails with an alarm"
else
    fail "CLI auth retry: rc=$rc model_runs=$(model_runs) sleeps='$(tr '\n' ' ' < "$SLEEPS")' log=$(printf '%s' "$LOG_TEXT" | grep -c AUTH_FAILURE)"
fi

# A model that dies without writing a byte leaves an empty output range. `head -c 0` is an error on
# BSD/macOS, and its complaint would land in the job's stderr (the launchd log) on every such run.
reset_ws
E2E_STDERR="$TEST_ROOT/e2e-stderr.log"; : > "$E2E_STDERR"
rc=$(run_guarded crash ok)
STDERR_TEXT=$(cat "$E2E_STDERR"); E2E_STDERR=""
if [ "$rc" = "1" ] && [ "$(model_runs)" = "1" ] && ! printf '%s' "$STDERR_TEXT" | grep -q 'illegal byte count'; then
    pass "a model that writes nothing and dies: no restart, and no stray complaint from head in stderr"
else
    fail "silent model failure: rc=$rc model_runs=$(model_runs) stderr=$STDERR_TEXT"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
