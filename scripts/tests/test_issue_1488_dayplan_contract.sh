#!/usr/bin/env bash
# Issue #1488: day-open-scaffold.sh only prints the DayPlan skeleton to stdout;
# saving it is the caller's job. The day-open skill must say so and its step 7a
# command must actually produce a non-empty plan file.
#   Behaviour: a bare run creates no DayPlan; the step-7a block, executed as
#   written (placeholders filled in), writes a non-empty plan.
#   Text: step 1b points to 7a instead of a separate run; 7a keeps the redirect
#   and the non-empty check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/.claude/skills/day-open/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

DAY="2026-11-10"
GOV="$TMP/iwe/DS-strategy"
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/iwe"
cp -R "$ROOT/seed/strategy" "$GOV" || fail "could not copy the seed governance repo"
[ -d "$GOV/current" ] || fail "fixture has no current/ directory"
# No network: issue sweeps must degrade, not hang.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

in_install() {
    (cd "$TMP" && env PATH="$TMP/bin:$PATH" HOME="$TMP/home" IWE_ROOT="$TMP/iwe" \
        IWE_WORKSPACE="$TMP/iwe" IWE_TEMPLATE="$ROOT" IWE_SCRIPTS="$ROOT/scripts" \
        IWE_GOVERNANCE_REPO=DS-strategy "$@")
}

dayplans() { find "$GOV" -name 'DayPlan*' -type f | wc -l | tr -d ' '; }

# 1. A bare run prints the skeleton and writes no plan file.
out=$(in_install bash "$ROOT/scripts/day-open-scaffold.sh" "$DAY" 2>/dev/null)
grep -q '^type: daily-plan' <<<"$out" || fail "scaffold did not print a DayPlan skeleton"
[ "$(dayplans)" -eq 0 ] || fail "bare run created a DayPlan file by itself"

# 2. The step-7a block, as written in the skill, writes a non-empty plan.
awk '/^\*\*7a\.\*\*/{s=1} s&&/^```bash/{b=1;next} b&&/^```/{exit} b{print}' "$SKILL" \
    | sed -e "s#<governance-repo>#$GOV#g" -e "s#YYYY-MM-DD#$DAY#g" > "$TMP/step7a.sh"
[ -s "$TMP/step7a.sh" ] || fail "could not extract the step 7a bash block"
in_install bash "$TMP/step7a.sh" 2>"$TMP/step7a.err" || fail "step 7a block failed: $(cat "$TMP/step7a.err")"
plan="$GOV/current/DayPlan $DAY.md"
[ -s "$plan" ] || fail "step 7a block left no non-empty $plan"
grep -q '^type: daily-plan' "$plan" || fail "saved plan is not the scaffold output"
grep -q 'DayPlan не записан' "$TMP/step7a.err" && fail "non-empty check fired on a good plan"

# 3. A second run the same day keeps the plan the pilot already edited.
printf 'правка пилота\n' >> "$plan"
cp "$plan" "$TMP/plan.edited"
in_install bash "$TMP/step7a.sh" 2>"$TMP/again.err" || fail "second run failed: $(cat "$TMP/again.err")"
cmp -s "$plan" "$TMP/plan.edited" || fail "second run overwrote an existing DayPlan"
grep -q 'уже есть' "$TMP/again.err" || fail "second run did not say the plan exists"
rm -f "$plan"

# 4. Empty output or a failing scaffold: the step fails and leaves no plan file.
for fake in 'true' 'printf "partial\\n"; exit 1'; do
    printf '#!/bin/bash\n%s\n' "$fake" > "$TMP/fake-scaffold.sh"
    sed "s#bash \"\$IWE_SCRIPTS/day-open-scaffold.sh\"#bash \"$TMP/fake-scaffold.sh\"#" \
        "$TMP/step7a.sh" > "$TMP/step7a-bad.sh"
    grep -q 'fake-scaffold' "$TMP/step7a-bad.sh" || fail "could not swap the scaffold in the block"
    if in_install bash "$TMP/step7a-bad.sh" 2>"$TMP/bad.err"; then
        fail "step 7a succeeded with a broken scaffold ($fake)"
    fi
    grep -q 'DayPlan не записан' "$TMP/bad.err" || fail "no failure message for: $fake"
    [ ! -e "$plan" ] || fail "a plan file was left behind for: $fake"
done

# 5. Text contract.
grep -A2 '^### 1b\.' "$SKILL" | grep -q 'шаге 7a с перенаправлением' \
    || fail "step 1b does not point the scaffold run to step 7a"
grep -q 'основой остаётся скелет' "$SKILL" || fail "step 7a lost the skeleton-first rule"

echo "PASS: issue 1488 (5 checks)"
