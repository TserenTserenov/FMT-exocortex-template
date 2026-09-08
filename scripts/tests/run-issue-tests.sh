#!/usr/bin/env bash
# run-issue-tests.sh — single versioned runner for issue-regression tests
# (WP-529 F6, peer-session 2026-08-19-01, codex В3).
#
# A new scripts/tests/test_issue_*.sh is picked up by mere existence of the
# file. Legacy-named issue regressions live in ADDITIONAL_ISSUE_TESTS below:
# they are explicit so a file cannot merely be shipped while remaining dormant.
# Stable order, shebang sanity check, run all, fail on any.
# This closes the recurring class "test sat in the repo, never wired into CI"
# (issue #226 in July; then the entire test_issue_* family found unwired on
# 18.08 by an external user). *.py siblings need the pytest context of
# scripts/tests and are listed here, not run — silence would read as coverage.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
shopt -s nullglob

fail=0
ran=0
ADDITIONAL_ISSUE_TESTS=(
    "scripts/tests/test_generate_manifest_registers_setup_exclusions.sh"
    "scripts/tests/test_hindsight_docs_contract.sh"
    "scripts/tests/test_hook_classification.sh"
    "scripts/tests/test_launchd_identity_runtime.sh"
    "scripts/tests/test_update_install_path_guard.sh"
    "scripts/tests/test_update_install_path_guard_provenance.sh"
)

run_shell_test() {
    local t="$1"
    local name
    name=$(basename "$t")
    if [ ! -f "$t" ]; then
        echo "❌ $name: зарегистрированный regression-файл отсутствует"
        fail=$((fail+1))
        return 0
    fi
    if ! head -1 "$t" | grep -q '^#!'; then
        echo "❌ $name: нет shebang — файл не запускаем"
        fail=$((fail+1))
        return 0
    fi
    echo "=== $name ==="
    if bash "$t"; then
        ran=$((ran+1))
    else
        echo "❌ $name: упал"
        fail=$((fail+1))
    fi
}

for t in "$ROOT"/scripts/tests/test_issue_*.sh; do
    run_shell_test "$t"
done
for t in "${ADDITIONAL_ISSUE_TESTS[@]}"; do
    run_shell_test "$ROOT/$t"
done

for t in "$ROOT"/scripts/tests/test_issue_*.py; do
    echo "ℹ $(basename "$t"): python-тест, запускается через pytest — вне scope этого раннера"
done

echo "---"
echo "issue-tests: прошло=$ran, упало=$fail"
# Cold review 2026-08-19: an empty family must not read as green — zero
# executed tests means the glob/layout broke, not that everything passed.
[ "$fail" -eq 0 ] && [ "$ran" -gt 0 ]
