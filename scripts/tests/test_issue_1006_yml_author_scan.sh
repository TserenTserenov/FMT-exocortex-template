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
    local mode="$1" expected_path="${2:-$PROBE}" output rc=0
    output=$(cd "$REPO" && bash setup/validate-template.sh "--mode=$mode" . 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "FAIL: $mode accepted forbidden .yml" >&2; exit 1; }
    grep -qF "Found '$TOKEN' (global) in 1 locations:" <<<"$output" \
        || { echo "FAIL: $mode did not classify the .yml author token" >&2; echo "$output" >&2; exit 1; }
    grep -qF "$expected_path" <<<"$output" \
        || { echo "FAIL: $mode omitted the offending .yml path" >&2; echo "$output" >&2; exit 1; }
}

printf 'governance_repo: %s\n' "$TOKEN" > "$REPO/$PROBE"
git -C "$REPO" add -- "$PROBE"
expect_author_violation staged
expect_author_violation pristine

# A symbolic governance path is a valid template value in both modes.
printf 'governance_repo: "{{GOVERNANCE_REPO}}"\n' > "$REPO/$PROBE"
git -C "$REPO" add -- "$PROBE"
for mode in staged pristine; do
    output=$(cd "$REPO" && bash setup/validate-template.sh "--mode=$mode" . 2>&1) \
        || { echo "FAIL: $mode rejected a symbolic .yml value" >&2; echo "$output" >&2; exit 1; }
    grep -qF '[1/5] Author-specific content... PASS' <<<"$output" \
        || { echo "FAIL: $mode did not pass its author-content check" >&2; echo "$output" >&2; exit 1; }
done

# The exact workflow-context exception must not exempt the rest of that file.
printf '\nunsafe: %s\n' "$TOKEN" >> "$REPO/.github/workflows/changelog-gate.yml"
git -C "$REPO" add -- .github/workflows/changelog-gate.yml
expect_author_violation staged .github/workflows/changelog-gate.yml
expect_author_violation pristine .github/workflows/changelog-gate.yml

echo "PASS: issue 1006 .yml author-content scan (staged, pristine, exact exceptions)"
