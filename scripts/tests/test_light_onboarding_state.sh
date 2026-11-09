#!/usr/bin/env bash
# Regression test for the light onboarding "new person" predicate (WP-406 Ф40,
# light onboarding v1.0.2): .claude/scripts/light-onboarding-state.sh and the
# branch of .claude/hooks/wp-gate-reminder.sh that uses it.
#
# Cases: fresh workspace -> active; working state (wp-numbers or a WP row in the
# registry) -> inactive, also after deleting `done`; `reset` -> active even with
# working state; `done` -> inactive and clears `force`; the hook injects the
# onboarding reminder only while active and the WP Gate reminder otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
STATE_SH="$ROOT/.claude/scripts/light-onboarding-state.sh"
HOOK="$ROOT/.claude/hooks/wp-gate-reminder.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

new_ws() {
    local ws="$TMP/$1"
    mkdir -p "$ws/.claude/scripts" "$ws/.claude/hooks" "$ws/DS-my-strategy/docs"
    cp "$STATE_SH" "$ws/.claude/scripts/"
    cp "$HOOK" "$ws/.claude/hooks/"
    printf '| # | P | Название | Ст | Репо | Бюджет |\n|---|---|---|---|---|---|\n| — | — | — | — | — | — |\n' \
        > "$ws/DS-my-strategy/docs/WP-REGISTRY.md"
    echo "$ws"
}

status_of() { (cd "$1" && env -u IWE_GOVERNANCE_REPO IWE_WORKSPACE="$1" bash .claude/scripts/light-onboarding-state.sh status); }
run_state() { (cd "$1" && env -u IWE_GOVERNANCE_REPO IWE_WORKSPACE="$1" bash .claude/scripts/light-onboarding-state.sh "$2" >/dev/null); }
hook_ctx() {
    printf '{"prompt":"%s"}' "$2" \
        | env -u IWE_GOVERNANCE_REPO -u IWE_WORKSPACE CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/wp-gate-reminder.sh" \
        | jq -r '.hookSpecificOutput.additionalContext'
}

# 1. Fresh workspace: active, hook leads to /onboarding.
WS=$(new_ws fresh)
[ "$(status_of "$WS")" = active ] || fail "fresh workspace must be active"
hook_ctx "$WS" "Подключилось?" | grep -q "НОВЫЙ ЧЕЛОВЕК" || fail "hook must inject the onboarding reminder on a fresh workspace"
hook_ctx "$WS" "Подключилось?" | grep -q "WP GATE" && fail "hook must not inject WP Gate on a fresh workspace"

# 2. wp-numbers present: inactive, hook gives WP Gate.
WS=$(new_ws numbers)
mkdir -p "$WS/.claude/state/wp-numbers"
[ "$(status_of "$WS")" = inactive ] || fail "wp-numbers must make onboarding inactive"
hook_ctx "$WS" "Что ты умеешь?" | grep -q "WP GATE" || fail "hook must inject WP Gate when work state exists"

# 3. A WP row in the registry: inactive even without wp-numbers.
WS=$(new_ws registry)
printf '| 7 | P2 | Отчёт | 🔄 | DS-my-strategy | 2h |\n' >> "$WS/DS-my-strategy/docs/WP-REGISTRY.md"
[ "$(status_of "$WS")" = inactive ] || fail "a registry row must make onboarding inactive"

# 4. Deleting `done` with work state does not bring onboarding back; `reset` does.
run_state "$WS" "done"
rm -f "$WS/.claude/state/light-onboarding-done"
[ "$(status_of "$WS")" = inactive ] || fail "deleting done must not reactivate when work state exists"
run_state "$WS" "reset"
[ "$(status_of "$WS")" = active ] || fail "reset must reactivate onboarding even with work state"
grep -q "Отчёт" "$WS/DS-my-strategy/docs/WP-REGISTRY.md" || fail "reset must not touch the registry"

# 5. `done` ends onboarding and clears `force`.
run_state "$WS" "done"
[ "$(status_of "$WS")" = inactive ] || fail "done must make onboarding inactive"
[ -e "$WS/.claude/state/light-onboarding-force" ] && fail "done must remove the force file"

# 6. Fresh workspace after `done`: inactive.
WS=$(new_ws passed)
run_state "$WS" "done"
[ "$(status_of "$WS")" = inactive ] || fail "done on a fresh workspace must make onboarding inactive"

# 7. Day Open trigger keeps its own branch; for a new person it asks to lift onboarding first.
WS=$(new_ws dayopen)
hook_ctx "$WS" "открывай день" | grep -q "DAY OPEN" || fail "day-open trigger must keep its branch"
hook_ctx "$WS" "открывай день" | grep -q "light-onboarding-state.sh done" || fail "day-open for a new person must ask to lift onboarding"
mkdir -p "$WS/.claude/state/wp-numbers"
hook_ctx "$WS" "открывай день" | grep -q "ЛЁГКИЙ ОНБОРДИНГ" && fail "day-open with work state must not mention onboarding"

# 8. Every registry row format create-wp.sh recognises counts as work.
for row in '| ~~12~~ |' '| **12** |' '| WP-12 |'; do
    WS=$(new_ws "row$RANDOM")
    printf '%s P2 | x | ✅ | r | 1h |\n' "$row" >> "$WS/DS-my-strategy/docs/WP-REGISTRY.md"
    [ "$(status_of "$WS")" = inactive ] || fail "registry row '$row' must count as work"
done

# 9. A WP card in inbox/ or a DayPlan in current/ counts as work (user without registry rows).
WS=$(new_ws inboxcard)
mkdir -p "$WS/DS-my-strategy/inbox/WP-3"
[ "$(status_of "$WS")" = inactive ] || fail "an inbox WP card must count as work"
WS=$(new_ws dayplan)
mkdir -p "$WS/DS-my-strategy/current"
touch "$WS/DS-my-strategy/current/DayPlan 2026-11-01.md" "$WS/DS-my-strategy/current/WeekPlan W1.md"
[ "$(status_of "$WS")" = inactive ] || fail "a DayPlan must count as work"
WS=$(new_ws weekplanonly)
mkdir -p "$WS/DS-my-strategy/current" "$WS/DS-my-strategy/inbox"
touch "$WS/DS-my-strategy/current/WeekPlan W1.md" "$WS/DS-my-strategy/inbox/fleeting-notes.md"
[ "$(status_of "$WS")" = active ] || fail "the seed WeekPlan and fleeting notes alone must not count as work"

# 10. Governance repo with a non-DS name: found via the setup env file and via IWE_GOVERNANCE_REPO.
WS=$(new_ws customgov)
mkdir -p "$WS/my-plans/docs"
printf '| 5 | P2 | x | ✅ | r | 1h |\n' > "$WS/my-plans/docs/WP-REGISTRY.md"
printf 'GITHUB_USER=x\nGOVERNANCE_REPO="my-plans"\n' > "$WS/.exocortex.env"
[ "$(status_of "$WS")" = inactive ] || fail "governance repo named in the setup env file must be checked"
rm -f "$WS/.exocortex.env"
[ "$(status_of "$WS")" = inactive ] || fail "without a configured name every repo of the workspace must be scanned"
[ "$(cd "$WS" && IWE_GOVERNANCE_REPO=my-plans IWE_WORKSPACE="$WS" bash .claude/scripts/light-onboarding-state.sh status)" = inactive ] \
    || fail "IWE_GOVERNANCE_REPO must be honoured"
[ "$(cd "$WS" && IWE_GOVERNANCE_REPO=DS-my-strategy IWE_WORKSPACE="$WS" bash .claude/scripts/light-onboarding-state.sh status)" = active ] \
    || fail "IWE_GOVERNANCE_REPO must restrict the check to the named repo"

if [ "$FAILED" -gt 0 ]; then
    echo "light onboarding state: $FAILED check(s) failed"
    exit 1
fi
echo "light onboarding state: all checks passed"
