#!/usr/bin/env bash
# test_issue_870_dayplan_validator.sh — regression for issue #870.
#
# protocol-artifact-validate.sh (DayPlan validation) had two defects:
#   1. (already fixed for the plan itself in #248, but not for its predecessor)
#      the "previous DayPlan" was taken as the second-newest file on disk, so
#      committing anything but the newest plan compared it with its own future
#      (or skipped the carry-over check altogether when the two coincided);
#   2. the multiplier / budget-line regexes accepted only a dot as the decimal
#      separator, while the Russian Day Open writes "~7,5h РП" and "~1,2x".
# The hook is run for real against throwaway governance repos; assertions look
# at the exact error strings the hook emits, not at "did not crash".
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/.claude/hooks/protocol-artifact-validate.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed — the hook itself needs it"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# make_repo <case-dir>: throwaway workspace with an initialised governance repo.
make_repo() {
    local ws="$TMP/$1"
    mkdir -p "$ws/DS-strategy/current"
    git -C "$ws/DS-strategy" init -q
    git -C "$ws/DS-strategy" config user.email t@example.invalid
    git -C "$ws/DS-strategy" config user.name t
    echo "$ws"
}

# write_plan <ws> <date> <budget-line> [carry]: minimal DayPlan; only the lines the
# assertions below look at matter, the other validation errors are ignored.
write_plan() {
    local ws="$1" date="$2" budget="$3" carry="${4:-}"
    {
        echo "# DayPlan $date"
        echo
        echo "## План на сегодня"
        echo "$budget"
        [ -n "$carry" ] && echo "Carry-over: вчерашний хвост"
        true
    } > "$ws/DS-strategy/current/DayPlan $date.md"
}

# run_hook <ws> <staged-date>: stage one plan and run the hook as PreToolUse(Bash).
run_hook() {
    local ws="$1" date="$2"
    git -C "$ws/DS-strategy" add -- "current/DayPlan $date.md"
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
        | IWE_WORKSPACE="$ws" IWE_GOVERNANCE_REPO=DS-strategy bash "$HOOK"
}

# --- 1a. comma decimals in budget and multiplier are accepted ---
WS=$(make_repo comma)
write_plan "$WS" 2026-09-18 '**Бюджет дня:** ~7,5h РП / ~9h физ / Плановый мультипликатор ~1,2x' carry
OUT=$(run_hook "$WS" 2026-09-18)
if grep -q 'Бюджет дня не в формате' <<<"$OUT"; then bad "comma budget '~7,5h РП' still rejected"; else ok "comma budget '~7,5h РП' accepted"; fi
if grep -q 'Мультипликатор не найден' <<<"$OUT"; then bad "comma multiplier '~1,2x' still rejected"; else ok "comma multiplier '~1,2x' accepted"; fi

# --- 1b. dot decimals and the Russian 'ч' unit keep working ---
WS=$(make_repo dot)
write_plan "$WS" 2026-09-18 '**Бюджет дня:** ~7.5ч РП / ~9ч физ / Плановый мультипликатор ~1.2x' carry
OUT=$(run_hook "$WS" 2026-09-18)
if grep -q 'Бюджет дня не в формате' <<<"$OUT" || grep -q 'Мультипликатор не найден' <<<"$OUT"; then
    bad "dot decimals / 'ч' unit regressed"
else
    ok "dot decimals and 'ч' unit still accepted"
fi

# --- 1c. negative control: a budget line with no number is still rejected ---
WS=$(make_repo nobudget)
write_plan "$WS" 2026-09-18 '**Бюджет дня:** как получится' carry
OUT=$(run_hook "$WS" 2026-09-18)
if grep -q 'Бюджет дня не в формате' <<<"$OUT"; then ok "budget line without a number is still rejected"; else bad "validator no longer catches a missing budget number"; fi
if grep -q 'Мультипликатор не найден' <<<"$OUT"; then ok "missing multiplier is still rejected"; else bad "validator no longer catches a missing multiplier"; fi

# --- 2a. staging the OLDEST plan while newer ones exist: nothing to compare with ---
WS=$(make_repo oldest)
LINE='**Бюджет дня:** ~7h РП / ~9h физ / ~1.0x'
write_plan "$WS" 2026-09-15 "$LINE"          # no carry-over: oldest plan has no predecessor
write_plan "$WS" 2026-09-17 "$LINE" carry
write_plan "$WS" 2026-09-18 "$LINE" carry
OUT=$(run_hook "$WS" 2026-09-15)
if grep -q 'Carry-over цитата' <<<"$OUT"; then
    bad "oldest staged plan was compared with a NEWER plan (carry-over error): $OUT"
else
    ok "oldest staged plan has no predecessor, no carry-over demand"
fi

# --- 2b. staging a middle plan: predecessor is the OLDER neighbour, named in the error ---
WS=$(make_repo middle)
write_plan "$WS" 2026-09-15 "$LINE"
write_plan "$WS" 2026-09-17 "$LINE"          # no carry-over: must be demanded
write_plan "$WS" 2026-09-18 "$LINE" carry
OUT=$(run_hook "$WS" 2026-09-17)
if grep -q 'Carry-over цитата' <<<"$OUT" && grep -q 'предыдущий DayPlan: DayPlan 2026-09-15.md' <<<"$OUT"; then
    ok "middle staged plan is compared with its older neighbour (2026-09-15)"
else
    bad "middle staged plan: wrong or missing predecessor in: $OUT"
fi

# --- 2c. staging the newest plan keeps working as before ---
WS=$(make_repo newest)
write_plan "$WS" 2026-09-17 "$LINE" carry
write_plan "$WS" 2026-09-18 "$LINE"          # newest, no carry-over: error names 09-17
OUT=$(run_hook "$WS" 2026-09-18)
if grep -q 'предыдущий DayPlan: DayPlan 2026-09-17.md' <<<"$OUT"; then
    ok "newest staged plan is compared with the previous plan (2026-09-17)"
else
    bad "newest staged plan: wrong predecessor in: $OUT"
fi

# --- 2d. a non-canonical name ("DayPlan_..." instead of "DayPlan ...") is still compared with
#         the newest canonical plan, as before the predecessor fix ---
WS=$(make_repo noncanon)
write_plan "$WS" 2026-09-17 "$LINE" carry
{ echo "# DayPlan"; echo "## План на сегодня"; echo "$LINE"; } > "$WS/DS-strategy/current/DayPlan_2026-09-18.md"
git -C "$WS/DS-strategy" add -- "current/DayPlan_2026-09-18.md"
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
    | IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO=DS-strategy bash "$HOOK")
if grep -q 'предыдущий DayPlan: DayPlan 2026-09-17.md' <<<"$OUT"; then
    ok "non-canonical staged name is compared with the newest canonical plan"
else
    bad "non-canonical staged name skipped the carry-over check: $OUT"
fi

echo "Result: $fail FAIL"
[ "$fail" -eq 0 ]
