#!/bin/bash
# test-session-prep-leftover-changes.sh -- issue #1674 acceptance test for
# verify_no_leftover_changes() in roles/strategist/scripts/strategist.sh.
# session-prep moved last week's files into archive/ with plain `mv`, staged only the new paths and
# was logged SUCCESS while the deletions of the old paths stayed uncommitted (HEAD held both copies).
# The runner now refuses SUCCESS (exit 78) when the run leaves a NEW uncommitted change behind.
# Runs the real script end to end with a stand-in model against a throwaway bare origin.
#
# Usage: bash setup/test-session-prep-leftover-changes.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
SCRIPT="$REPO_ROOT/roles/strategist/scripts/strategist.sh"
TEST_ROOT="${SESSION_PREP_LEFTOVER_TEST_ROOT:-/tmp/iwe-session-prep-leftover-$$}"
export DELIVERY_FETCH_PAUSE=0

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

OLD_PLAN="current/WeekPlan W47 2026-11-16.md"

mkdir -p "$TEST_ROOT"
ORIGIN="$TEST_ROOT/origin.git"
E2E_HOME="$TEST_ROOT/home"; E2E_WS="$TEST_ROOT/iwe"; E2E_TPL="$TEST_ROOT/template"
GOV="$E2E_WS/DS-strategy"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$GOV" 2>/dev/null
git -C "$GOV" config user.email t@test; git -C "$GOV" config user.name test
mkdir -p "$GOV/current" "$GOV/docs"
echo "last week" > "$GOV/$OLD_PLAN"
echo "strategy" > "$GOV/docs/Strategy.md"
git -C "$GOV" add -A && git -C "$GOV" -c commit.gpgsign=false commit -q -m seed
git -C "$GOV" push -q origin HEAD:main
SEED=$(git -C "$GOV" rev-parse HEAD)

mkdir -p "$E2E_HOME" "$E2E_TPL/roles/synchronizer/scripts" "$E2E_TPL/roles/strategist" "$TEST_ROOT/bin"
ln -s "$REPO_ROOT/roles/strategist/prompts" "$E2E_TPL/roles/strategist/prompts"
NOTIFY_LOG="$TEST_ROOT/notify.log"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$E2E_TPL/roles/synchronizer/scripts/notify.sh"
printf '#!/bin/bash\nexit 0\n' > "$TEST_ROOT/bin/osascript"; cp "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/notify-send"
cat > "$TEST_ROOT/stub-model.sh" <<'STUB'
#!/bin/bash
# Stands in for the model. STUB_MODE: mv-new-only (plain mv, stages only the new path: the defect)
# | git-mv (the move recorded as a rename) | nothing
cd "$STUB_WORKSPACE" || exit 9
old="current/WeekPlan W47 2026-11-16.md"; new="archive/week-plans/WeekPlan W47 2026-11-16.md"
case "${STUB_MODE:-nothing}" in
    mv-new-only)
        mkdir -p archive/week-plans && mv "$old" "$new"
        git add "$new" && git -c commit.gpgsign=false commit -q -m "session prep" && git push -q origin HEAD:main
        ;;
    git-mv)
        mkdir -p archive/week-plans && git mv "$old" "$new"
        git -c commit.gpgsign=false commit -q -m "session prep" && git push -q origin HEAD:main
        ;;
esac
exit 0
STUB
chmod +x "$E2E_TPL/roles/synchronizer/scripts/notify.sh" "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/notify-send" "$TEST_ROOT/stub-model.sh"
[ "$(PATH="$TEST_ROOT/bin:$PATH" command -v osascript)" = "$TEST_ROOT/bin/osascript" ] \
    || { echo "the stand-in osascript does not shadow the real one" >&2; exit 2; }

reset_gov() {  # back to the seed commit on both sides, working tree clean
    git -C "$GOV" reset -q --hard "$SEED" && git -C "$GOV" clean -qfd
    git -C "$GOV" push -q --force origin "$SEED:main"
    git -C "$GOV" fetch -q origin main
}
run_session_prep() {  # <STUB_MODE> -> exit code of the real script on stdout
    rm -rf "$E2E_HOME/logs"; rm -f "$NOTIFY_LOG"
    HOME="$E2E_HOME" PATH="$TEST_ROOT/bin:$PATH" IWE_WORKSPACE="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy \
        IWE_TEMPLATE="$E2E_TPL" IWE_SCRIPTS="$TEST_ROOT/no-guard-here" AI_CLI="$TEST_ROOT/stub-model.sh" \
        STUB_MODE="$1" STUB_WORKSPACE="$GOV" \
        bash "$SCRIPT" session-prep >/dev/null 2>&1
    echo $?
}
log_text() { cat "$E2E_HOME"/logs/strategist/*.log 2>/dev/null; }

echo "=== session-prep: a move must be committed as a whole ==="

reset_gov
rc=$(run_session_prep mv-new-only); LOG_TEXT=$(log_text)
if [ "$rc" = "78" ] && printf '%s' "$LOG_TEXT" | grep -q 'FAILED scenario: session-prep (rc=78)' \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: session-prep' \
    && printf '%s' "$LOG_TEXT" | grep -qF "LEFTOVER    D $OLD_PLAN"; then
    pass "plain mv, only the new path committed -> exit 78, FAILED, the uncommitted deletion is named, no SUCCESS"
else
    fail "a half-committed move must not pass: rc=$rc log=$(printf '%s' "$LOG_TEXT" | grep -E 'LEFTOVER|scenario' | tail -5)"
fi

reset_gov
rc=$(run_session_prep git-mv); LOG_TEXT=$(log_text)
if [ "$rc" = "0" ] && printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: session-prep' \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'LEFTOVER' && [ -z "$(git -C "$GOV" status --porcelain)" ]; then
    pass "git mv -> the rename is committed, the tree is clean, exit 0 and SUCCESS"
else
    fail "a whole move must succeed: rc=$rc status=$(git -C "$GOV" status --porcelain) log=$(printf '%s' "$LOG_TEXT" | tail -3)"
fi

# The checkout is shared: a change somebody left before the run is not the run's leftover.
reset_gov
echo "edited by another session" >> "$GOV/docs/Strategy.md"
rc=$(run_session_prep git-mv); LOG_TEXT=$(log_text)
if [ "$rc" = "0" ] && printf '%s' "$LOG_TEXT" | grep -q 'SUCCESS scenario: session-prep' \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'LEFTOVER' \
    && git -C "$GOV" status --porcelain | grep -qF 'docs/Strategy.md'; then
    pass "a change left before the run is not blamed on it and stays untouched -> exit 0"
else
    fail "a pre-existing change must not fail the run: rc=$rc log=$(printf '%s' "$LOG_TEXT" | grep LEFTOVER)"
fi

reset_gov
echo "edited by another session" >> "$GOV/docs/Strategy.md"
rc=$(run_session_prep mv-new-only); LOG_TEXT=$(log_text)
if [ "$rc" = "78" ] && printf '%s' "$LOG_TEXT" | grep -qF "LEFTOVER    D $OLD_PLAN" \
    && ! printf '%s' "$LOG_TEXT" | grep -q 'LEFTOVER .*docs/Strategy.md'; then
    pass "with a foreign change present, only the run's own leftover is named"
else
    fail "only the run's own leftover may be named: rc=$rc log=$(printf '%s' "$LOG_TEXT" | grep LEFTOVER)"
fi

# A rename another session staged before the run: the runner unstages it after the model, and it then
# reads as a deletion plus an untracked file. Neither path is the run's leftover.
reset_gov
git -C "$GOV" mv docs/Strategy.md "docs/Strategy old.md"
rc=$(run_session_prep git-mv); LOG_TEXT=$(log_text)
if [ "$rc" = "0" ] && ! printf '%s' "$LOG_TEXT" | grep -q 'LEFTOVER'; then
    pass "a foreign rename staged before the run is not blamed on it (both of its paths are known)"
else
    fail "a staged foreign rename must not fail the run: rc=$rc log=$(printf '%s' "$LOG_TEXT" | grep LEFTOVER)"
fi

# Another scenario has no clean-finish contract: a leftover there does not change its outcome.
reset_gov
rm -rf "$E2E_HOME/logs"
HOME="$E2E_HOME" PATH="$TEST_ROOT/bin:$PATH" IWE_WORKSPACE="$E2E_WS" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_TEMPLATE="$E2E_TPL" IWE_SCRIPTS="$TEST_ROOT/no-guard-here" AI_CLI="$TEST_ROOT/stub-model.sh" \
    STUB_MODE=mv-new-only STUB_WORKSPACE="$GOV" bash "$SCRIPT" note-review >/dev/null 2>&1
rc=$?; LOG_TEXT=$(log_text)
if ! printf '%s' "$LOG_TEXT" | grep -q 'LEFTOVER'; then
    pass "note-review is not gated by the session-prep check (rc=$rc)"
else
    fail "the check must apply to session-prep only: log=$(printf '%s' "$LOG_TEXT" | grep LEFTOVER)"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
