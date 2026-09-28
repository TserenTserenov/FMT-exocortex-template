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
git -C "$OTHER" pull -q --ff-only origin main 2>/dev/null || git -C "$OTHER" fetch -q origin main && git -C "$OTHER" reset -q --hard origin/main
push_from_other "current/WeekReport W41 2026-10-05.md"
PRE=$(pre_origin)
git -C "$OTHER" rm -q "current/WeekReport W41 2026-10-05.md"
git -C "$OTHER" -c commit.gpgsign=false commit -q -m "delete the report"
git -C "$OTHER" push -q origin HEAD:main
rc=$(run_postcondition week-review "$PRE")
[ "$rc" = "1" ] && pass "deleting a report file is not a delivery" || fail "a deletion must not satisfy the check, rc=$rc: $(cat "$LOG_FILE")"

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
case "${STUB_MODE:-nothing}" in
    deliver)
        cd "$STUB_WORKSPACE" || exit 9
        mkdir -p current
        echo report > "current/WeekReport W39 2026-09-21.md"
        git add -A && git -c commit.gpgsign=false commit -q -m "week report" && git push -q origin HEAD:main
        ;;
    crash) exit 1 ;;
esac
exit 0
STUB
chmod +x "$E2E_TPL/roles/synchronizer/scripts/notify.sh" "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/notify-send" "$TEST_ROOT/stub-model.sh"

run_week_review() {  # <STUB_MODE> [keep-logs] -> exit code of the real script on stdout; notifications in $NOTIFY_LOG
    [ "${2:-}" = "keep-logs" ] || rm -rf "$E2E_HOME/logs"
    rm -f "$NOTIFY_LOG"
    HOME="$E2E_HOME" PATH="$TEST_ROOT/bin:$PATH" IWE_WORKSPACE="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy \
        IWE_TEMPLATE="$E2E_TPL" AI_CLI="$TEST_ROOT/stub-model.sh" STUB_MODE="$1" STUB_WORKSPACE="$E2E_WS/DS-strategy" \
        bash "$SCRIPT" week-review >/dev/null 2>&1
    echo $?
}
e2e_log_text() { cat "$E2E_HOME"/logs/strategist/*.log 2>/dev/null; }

git -C "$E2E_WS/DS-strategy" pull -q --ff-only origin main 2>/dev/null || git -C "$E2E_WS/DS-strategy" fetch -q origin main && git -C "$E2E_WS/DS-strategy" reset -q --hard origin/main
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

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
