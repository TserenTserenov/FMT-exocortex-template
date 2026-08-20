#!/bin/bash
# check-python-resolver-contract.sh — WP-529 Ф9 (Evgenii 20.08): anti-
# regression ratchet for the "invoke repo-owned .py via find-python3.sh, not
# bare python3/python" contract (WP-529 Ф6, #453/#463).
#
# NOT a proof of compliance: on 20.08 a real scan of scripts/**/*.sh,
# setup/**/*.sh, roles/**/*.sh found ~10 pre-existing bare-python3 call sites
# unrelated to this phase's two confirmed live bugs (route-task.sh,
# headless-runner.sh, both already fixed). Auditing whether each of those 10
# needs PyYAML is a separate follow-up, not this gate's job — this gate only
# stops the count from growing. Baseline entries are keyed on
# `path:trimmed-line-content`, not line number, so unrelated edits elsewhere
# in a baselined file don't cause spurious baseline drift.
#
# Scope: scripts/**/*.sh, setup/**/*.sh, roles/**/*.sh (the delivered-shell
# perimeter, matches docs/critical-files-map.yaml categories). Deliberately
# NOT .github/workflows/** — different execution context (CI step installs
# PyYAML explicitly via `pip install`), different format (YAML `run:`, not a
# .sh file) — a workflow-level equivalent would need its own contract,
# not shoehorned into this one (peer-session 2026-08-20-28, turn 1-2).
#
# Known blind spot (documented, not solved): variable-indirected calls like
# `PY=python3; $PY script.py` are not caught — that needs variable-flow
# analysis, out of scope for a static grep-gate (peer-session 2026-08-20-28,
# turn 3, codex).
#
# Usage:
#   scripts/check-python-resolver-contract.sh              — check against baseline, exit 1 on new hits
#   scripts/check-python-resolver-contract.sh --update-baseline — regenerate the baseline from the current tree (conscious, manual — not run in CI)

set -euo pipefail

# REPO_ROOT override lets tests point this at a throwaway copy of the tree
# instead of mutating the real one (same convention as T13/T17/T25 tests).
SCRIPT_DIR="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASELINE="$SCRIPT_DIR/scripts/tests/fixtures/python-resolver-baseline.txt"
MODE="${1:-check}"

# Matches a literal `python3`/`python` token immediately followed by a
# repo-owned `.py` path — NOT preceded by a resolver variable ($PYTHON3,
# $RESOLVED_PYTHON3, $RESOLVER, etc., since those are variable references,
# not the literal word "python"/"python3").
PATTERN='(^|[^$A-Za-z0-9_."'"'"'-])python3?[[:space:]]+"?[A-Za-z0-9_./${}-]*\.py\b'

# This gate's own test writes example "bad" python3-calling lines as fixture
# content inside test_issue_python_resolver_contract.sh — scanning the gate's
# own test suite for the exact pattern it's designed to catch is a
# self-referential false positive, not a real violation.
SELF_TEST_BASENAME="test_issue_python_resolver_contract.sh"

scan() {
    grep -rnE "$PATTERN" \
        "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/setup" "$SCRIPT_DIR/roles" \
        --include="*.sh" 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -v "/$SELF_TEST_BASENAME:" \
        | while IFS=: read -r file line content; do
            rel="${file#"$SCRIPT_DIR"/}"
            trimmed="$(printf '%s' "$content" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            printf '%s\t%s\n' "$rel" "$trimmed"
        done \
        | LC_ALL=C sort -u
}

if [ "$MODE" = "--update-baseline" ]; then
    mkdir -p "$(dirname "$BASELINE")"
    scan > "$BASELINE"
    echo "Baseline обновлён: $(wc -l < "$BASELINE" | tr -d ' ') строк → $BASELINE"
    exit 0
fi

[ -f "$BASELINE" ] || { echo "ERROR: baseline не найден: $BASELINE (запусти --update-baseline осознанно, не в CI)"; exit 2; }

CURRENT="$(mktemp)"
trap 'rm -f "$CURRENT"' EXIT
scan > "$CURRENT"

NEW_HITS="$(LC_ALL=C comm -23 "$CURRENT" <(LC_ALL=C sort -u "$BASELINE"))"

if [ -z "$NEW_HITS" ]; then
    echo "✅ python-resolver contract: новых голых python3/python-вызовов repo-owned .py нет (baseline: $(wc -l < "$BASELINE" | tr -d ' ') известных)"
    exit 0
fi

echo "❌ python-resolver contract: новые голые python3/python-вызовы вне baseline:" >&2
echo "$NEW_HITS" | while IFS=$'\t' read -r rel content; do
    echo "  $rel: $content" >&2
done
echo "" >&2
echo "Каждый .py-исполнитель должен резолвиться через scripts/lib/find-python3.sh" >&2
echo "(см. route-task.sh::_resolve_python3 или headless-runner.sh для образца)." >&2
echo "Если это осознанное легаси-исключение — обнови baseline осознанно:" >&2
echo "  scripts/check-python-resolver-contract.sh --update-baseline" >&2
exit 1
