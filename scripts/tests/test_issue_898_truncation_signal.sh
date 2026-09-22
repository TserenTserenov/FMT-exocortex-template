#!/usr/bin/env bash
# Regression coverage for issue #898: git-diff-feed.md's "<=8 candidates per
# run" limit had no observable signal when it actually cut a busy day short
# -- the next scheduled run looks at its own new window, so whatever did not
# fit was lost, not deferred. This is a prompt file (LLM instructions, not
# executable code), so the only verifiable contract here is that the
# instruction and the report template both carry the TRUNCATED marker and
# say when to emit it (and, just as important, when NOT to).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
PROMPT="$ROOT/roles/extractor/prompts/git-diff-feed.md"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

if grep -q 'TRUNCATED: K of M substantive commits captured' "$PROMPT"; then
    pass "report template carries the TRUNCATED marker"
else
    fail_test "report template is missing the TRUNCATED marker"
fi

if grep -q 'issue #898' "$PROMPT"; then
    pass "limit step references issue #898 (traceable to the report)"
else
    fail_test "limit step does not reference issue #898"
fi

# The marker must be conditional (only on real truncation), not always
# printed -- otherwise "TRUNCATED: 8 of 8" would look like data loss on
# every ordinary day that happens to hit exactly 8 candidates.
if grep -q 'K = M.*не писать' "$PROMPT" || grep -q 'не писать `TRUNCATED: 8 of 8`' "$PROMPT"; then
    pass "instructions explicitly forbid emitting TRUNCATED when the limit was not actually hit"
else
    fail_test "instructions do not say to omit TRUNCATED on an ordinary (non-truncated) day"
fi

# The limit step must say what to prioritize among >8 substantive commits,
# not just "take 8" (silently dropping which ones is its own kind of loss).
if grep -qE 'первые 8 по важности' "$PROMPT"; then
    pass "limit step says how the 8 captured candidates are prioritized"
else
    fail_test "limit step does not say how the kept 8 are chosen"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_898_truncation_signal: all checks passed"
fi
exit "$fail"
