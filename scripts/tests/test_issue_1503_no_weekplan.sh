#!/usr/bin/env bash
# Issue #1503: create-wp.sh can leave the WeekPlan alone. --no-weekplan or
# params.yaml `wp_new_add_to_weekplan: false` keep the WP in the card and the
# registry only; --weekplan (strategy session approving the WP into the week)
# overrides the parameter; both flags together are refused. check-wp-registered.sh
# --no-weekplan accepts a WP without a plan row and still checks card + registry.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$TMP/home"
mkdir -p "$HOME"
export IWE_TEMPLATE="$ROOT" IWE_ROOT="$TMP/iwe" IWE_GOVERNANCE_REPO="strategy"
GOV="$IWE_ROOT/strategy"
WEEKPLAN="$GOV/current/WeekPlan W1.md"

fresh_install() {
    rm -rf "$IWE_ROOT"
    mkdir -p "$IWE_ROOT"
    cp -R "$ROOT/seed/strategy" "$GOV"
}

# Prints the created WP number; the run's output goes to $TMP/run.out.
create() {
    bash "$ROOT/scripts/create-wp.sh" --title "Weekplan Opt Out" --budget 1h --priority P4 \
        --verification-class closed-loop --no-consent-check --no-artifactor-check "$@" \
        >"$TMP/run.out" 2>&1 || return 1
    find "$GOV/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*' -exec basename {} \; \
        | sed 's/^WP-0*//' | sort -n | tail -1
}

plan_rows_for() { grep -cE "^\|.*\| *$1 *\|.*Weekplan Opt Out" "$WEEKPLAN"; }

check() { bash "$ROOT/scripts/check-wp-registered.sh" "$@" "$GOV" "$WEEKPLAN" >"$TMP/check.out" 2>&1; }

# 1. Default: the row is added, the full check passes.
fresh_install
n=$(create) || fail "default run failed: $(cat "$TMP/run.out")"
[ "$(plan_rows_for "$n")" -eq 1 ] || fail "default: expected one WeekPlan row for WP $n"
check "$n" || fail "default: full check failed: $(cat "$TMP/check.out")"

# 2. --no-weekplan: WeekPlan byte-identical; full check fails, --no-weekplan check passes.
fresh_install
cp "$WEEKPLAN" "$TMP/plan.before"
n=$(create --no-weekplan) || fail "--no-weekplan run failed: $(cat "$TMP/run.out")"
cmp -s "$WEEKPLAN" "$TMP/plan.before" || fail "--no-weekplan: WeekPlan was modified"
grep -q 'строка не добавляется (--no-weekplan)' "$TMP/run.out" || fail "--no-weekplan: no skip notice"
grep -qE "\| *$n *\|" "$GOV/docs/WP-REGISTRY.md" || fail "--no-weekplan: WP $n missing from the registry"
check "$n" && fail "--no-weekplan: full check passed without a plan row"
check --no-weekplan "$n" || fail "--no-weekplan check failed: $(cat "$TMP/check.out")"

# 2a. The --no-weekplan check still catches a missing registry row.
sed -i.bak -E "/\| *$n *\|/d" "$GOV/docs/WP-REGISTRY.md"
check --no-weekplan "$n" && fail "--no-weekplan check passed without a registry row"

# 3. params.yaml false: no row.
fresh_install
printf 'wp_new_add_to_weekplan: false  # issue 1503\n' > "$IWE_ROOT/params.yaml"
cp "$WEEKPLAN" "$TMP/plan.before"
n=$(create) || fail "params=false run failed: $(cat "$TMP/run.out")"
cmp -s "$WEEKPLAN" "$TMP/plan.before" || fail "params=false: WeekPlan was modified"

# 4. params.yaml false + --weekplan: the row is added.
n=$(create --weekplan) || fail "--weekplan run failed: $(cat "$TMP/run.out")"
[ "$(plan_rows_for "$n")" -eq 1 ] || fail "--weekplan did not override params.yaml false"

# 5. params.yaml true keeps the default.
fresh_install
printf 'wp_new_add_to_weekplan: true\n' > "$IWE_ROOT/params.yaml"
n=$(create) || fail "params=true run failed: $(cat "$TMP/run.out")"
[ "$(plan_rows_for "$n")" -eq 1 ] || fail "params=true: row not added"

# 6. Both flags: refused before anything is written.
fresh_install
create --weekplan --no-weekplan >/dev/null && fail "both flags accepted"
grep -q 'взаимоисключающие' "$TMP/run.out" || fail "both flags refused for another reason: $(cat "$TMP/run.out")"
[ -z "$(find "$GOV/inbox" -mindepth 1 -maxdepth 1 -type d -name 'WP-*')" ] \
    || fail "both flags: a WP was created anyway"

echo "PASS: issue 1503 (7 scenarios)"
