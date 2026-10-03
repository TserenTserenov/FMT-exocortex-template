#!/usr/bin/env bash
# Issue #1006: author-content check must inspect .yml in staged and full modes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO="$TEST_ROOT/repo"
TOKEN="DS-my""-strategy"
PROBE=extensions/issue-1006-probe.yml

git clone --quiet --no-hardlinks "$ROOT" "$REPO"
cp "$ROOT/setup/validate-template.sh" "$REPO/setup/validate-template.sh"
git -C "$REPO" add -- setup/validate-template.sh

expect_author_violation() {
    local mode="$1" expected_path="${2:-$PROBE}" expected_pattern="${3:-$TOKEN}" output rc=0
    output=$(cd "$REPO" && bash setup/validate-template.sh "--mode=$mode" . 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "FAIL: $mode accepted forbidden .yml" >&2; exit 1; }
    grep -qF "Found '$expected_pattern' (global) in 1 locations:" <<<"$output" \
        || { echo "FAIL: $mode did not classify the .yml author token" >&2; echo "$output" >&2; exit 1; }
    grep -qF "$expected_path" <<<"$output" \
        || { echo "FAIL: $mode omitted the offending .yml path" >&2; echo "$output" >&2; exit 1; }
}
expect_author_pass() {
    local mode="$1" output
    output=$(cd "$REPO" && bash setup/validate-template.sh "--mode=$mode" . 2>&1) \
        || { echo "FAIL: $mode rejected a symbolic .yml value" >&2; echo "$output" >&2; exit 1; }
    grep -qF '[1/5] Author-specific content... PASS' <<<"$output" \
        || { echo "FAIL: $mode did not pass its author-content check" >&2; echo "$output" >&2; exit 1; }
}

printf 'governance_repo: %s\n' "$TOKEN" > "$REPO/$PROBE"
git -C "$REPO" add -- "$PROBE"
expect_author_violation staged
expect_author_violation pristine

# A symbolic governance path is a valid template value in both modes.
printf 'governance_repo: "{{GOVERNANCE_REPO}}"\n' > "$REPO/$PROBE"
git -C "$REPO" add -- "$PROBE"
for mode in staged pristine; do
    expect_author_pass "$mode"
done

# All four exact exceptions must also work when pristine grep sees CRLF.
for workflow in changelog-gate translate-sync release-watchdog validate-template; do
    file=".github/workflows/$workflow.yml"
    crlf_file="$TEST_ROOT/$workflow.yml"
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\r\n' "${line%$'\r'}"
    done < "$REPO/$file" > "$crlf_file"
    mv "$crlf_file" "$REPO/$file"
    case "$workflow" in
        changelog-gate) marker='NO_CHANGELOG_ALLOWED: "TserenTserenov"' ;;
        translate-sync) marker='TserenTserenov; it was never one of the aisystant repos slated for a' ;;
        release-watchdog) marker='DS-IT-systems для агента read-only.' ;;
        validate-template) marker="Имитируем pristine user: DS-strategy вместо $TOKEN, DayPlan с минимальным шаблоном." ;;
    esac
    grep -Fq "$marker"$'\r' "$REPO/$file" \
        || { echo "FAIL: CRLF fixture omitted $workflow exception" >&2; exit 1; }
done
git -C "$REPO" add -- \
    .github/workflows/changelog-gate.yml \
    .github/workflows/translate-sync.yml \
    .github/workflows/release-watchdog.yml \
    .github/workflows/validate-template.yml
expect_author_pass staged
expect_author_pass pristine

# A second copy in another job is executable author content, not an exception.
cp "$REPO/.github/workflows/changelog-gate.yml" "$TEST_ROOT/changelog-crlf-base.yml"
printf '\r\n  issue_1006_duplicate:\r\n    runs-on: ubuntu-latest\r\n    env:\r\n      NO_CHANGELOG_ALLOWED: "TserenTserenov"\r\n    steps:\r\n      - run: "true"\r\n' \
    >> "$REPO/.github/workflows/changelog-gate.yml"
git -C "$REPO" add -- .github/workflows/changelog-gate.yml
expect_author_violation staged .github/workflows/changelog-gate.yml tserentserenov
expect_author_violation pristine .github/workflows/changelog-gate.yml tserentserenov

# The exact CRLF workflow-context exception must not exempt another value.
cp "$TEST_ROOT/changelog-crlf-base.yml" "$REPO/.github/workflows/changelog-gate.yml"
printf '\r\n  issue_1006_unsafe:\r\n    runs-on: ubuntu-latest\r\n    env:\r\n      GOVERNANCE_REPO: %s\r\n    steps:\r\n      - run: "true"\r\n' "$TOKEN" \
    >> "$REPO/.github/workflows/changelog-gate.yml"
git -C "$REPO" add -- .github/workflows/changelog-gate.yml
expect_author_violation staged .github/workflows/changelog-gate.yml
expect_author_violation pristine .github/workflows/changelog-gate.yml

echo "PASS: issue 1006 .yml author-content scan (staged, pristine, LF/CRLF exact exceptions)"
