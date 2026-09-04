#!/usr/bin/env bash
# test_issue_665.sh — regression for the false-positive HOOK-PATH-CONVENTION
# check (validate-fmt-scripts.sh) against a bare literal used as a
# positional fallback-default argument, e.g.
# `_selected_env(values, "IWE_GOVERNANCE_REPO", "GOVERNANCE_REPO", "DS-strategy")`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-fmt-scripts.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0

# Positive: the real shape from scripts/agent-fault/iwe_checklist_memory.py —
# the literal line has no env-var reference itself, but the call it belongs
# to does (paired with "IWE_GOVERNANCE_REPO" a few lines above).
cat > "$TMP/safe.py" <<'EOF'
def resolve():
    governance_name = _selected_env(
        values,
        "IWE_GOVERNANCE_REPO",
        "GOVERNANCE_REPO",
        "DS-strategy",
    ).strip()
    return governance_name
EOF

if ! env -u IWE_GOVERNANCE_REPO -u GOVERNANCE_REPO bash "$VALIDATOR" --scripts --files "$TMP/safe.py" >/dev/null 2>&1; then
    echo "❌ safe.py: positional fallback-default literal must NOT be flagged (issue #665)"
    fail=1
fi

# Negative: a bare literal with no "IWE_GOVERNANCE_REPO" neighbor within the
# lookback window must still be caught — the exception is not a blanket waiver.
cat > "$TMP/unsafe.py" <<'EOF'
def resolve():
    real_hardcode = (
        "DS-strategy",
    )
    return real_hardcode
EOF

if env -u IWE_GOVERNANCE_REPO -u GOVERNANCE_REPO bash "$VALIDATOR" --scripts --files "$TMP/unsafe.py" >/dev/null 2>&1; then
    echo "❌ unsafe.py: a genuine hardcode with no override-key neighbor must still be flagged"
    fail=1
fi

# Negative (cold-context review finding): an unrelated "IWE_GOVERNANCE_REPO"
# mention inside a COMMENT must not whitelist a genuine hardcode a few lines
# below it in an unrelated call — the exception is scoped to the same
# unbroken statement, not any nearby line.
cat > "$TMP/adversarial.py" <<'EOF'
def foo():
    # See docs for "IWE_GOVERNANCE_REPO" env var behavior in this module
    real_hardcode = (
        "DS-strategy",
    )
    return real_hardcode
EOF

if env -u IWE_GOVERNANCE_REPO -u GOVERNANCE_REPO bash "$VALIDATOR" --scripts --files "$TMP/adversarial.py" >/dev/null 2>&1; then
    echo "❌ adversarial.py: an unrelated comment mention must not whitelist a genuine hardcode below it"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_665: OK"
fi
exit "$fail"
