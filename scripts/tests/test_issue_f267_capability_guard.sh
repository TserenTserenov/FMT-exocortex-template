#!/usr/bin/env bash
# test_issue_f267_capability_guard.sh - where a script may check that tar, restic or claude
# exists (WP-7 F267 stage 2: the guard "as a list of allowed places, not a ban").
#
# The capability record (scripts/iwe-capabilities.sh, scripts/lib/iwe-capabilities.sh) is the
# one place that knows what this installation has. A NEW script that asks the system again
# ("command -v restic") reintroduces the disagreement the record was built to remove, and a
# scheduler with a short PATH answers it wrongly. So:
#   - a direct check outside the list below fails this test with a hint;
#   - a listed place that no longer has such a check fails too, so the list shrinks as the
#     places move to `cap_resolve` and never becomes a graveyard.
# Adding a place is allowed: put it in the list WITH the reason, in the same change.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

# path|reason - paths relative to the template root
ALLOWED='
scripts/iwe-backup-check.sh|reads the restic freshness only when restic exists; a missing restic is information there
scripts/iwe-backup-run.sh|the engine script itself; the entry point iwe-backup.sh already resolved the program and put it on PATH
scripts/iwe-backup-protect.sh|the protective snapshot before a risky operation; runs by hand, outside the scheduler
scripts/claude-peer-adapter.sh|a peer-session adapter for one vendor CLI; its own contract, not the installation record
roles/strategist/scripts/strategist.sh|the role runner picks its model client at start, with its own fallback order
roles/extractor/scripts/extractor.sh|the role runner picks its model client at start, with its own fallback order
roles/extractor/scripts/connect.sh|a one-off connection helper run by hand
roles/extractor/install.sh|install-time check that decides whether the role can be installed at all
'

HITS="$(
    find "$ROOT/scripts" "$ROOT/roles" "$ROOT/setup" "$ROOT/.claude" -name '*.sh' -type f \
        -not -path '*/tests/*' -not -path '*/.git/*' -not -name 'test*' -not -name '*-test.sh' 2>/dev/null |
    while read -r f; do
        if grep -Eq '(^|[^A-Za-z0-9_-])(command -v|which|type -P)[[:space:]]+(tar|restic|claude)($|[^A-Za-z0-9_-])' "$f"; then
            echo "${f#"$ROOT"/}"
        fi
    done | sort
)"

ALLOWED_PATHS="$(printf '%s\n' "$ALLOWED" | sed -n 's/|.*//p' | sort)"

NEW="$(comm -23 <(printf '%s\n' "$HITS") <(printf '%s\n' "$ALLOWED_PATHS") | sed '/^$/d')"
if [ -z "$NEW" ]; then
    pass "no direct tar/restic/claude presence check outside the allowed places"
else
    fail "direct presence check outside the allowed list: $(printf '%s' "$NEW" | tr '\n' ' ')- use: bash scripts/iwe-capabilities.sh resolve <tar|restic|claude_cli> (or cap_resolve), or add the place to ALLOWED in this test WITH the reason"
fi

STALE="$(comm -13 <(printf '%s\n' "$HITS") <(printf '%s\n' "$ALLOWED_PATHS") | sed '/^$/d')"
if [ -z "$STALE" ]; then
    pass "every allowed place still has such a check (the list has no dead entries)"
else
    fail "allowed but no longer checking directly - remove from ALLOWED: $(printf '%s' "$STALE" | tr '\n' ' ')"
fi

# The guard itself must be able to see a violation, or a green result means nothing.
PROBE_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$PROBE_DIR" 2>/dev/null; rm -rf "$PROBE_DIR"' EXIT
printf '#!/bin/bash\nif command -v restic >/dev/null; then :; fi\n' > "$PROBE_DIR/violator.sh"
if grep -Eq '(^|[^A-Za-z0-9_-])(command -v|which|type -P)[[:space:]]+(tar|restic|claude)($|[^A-Za-z0-9_-])' "$PROBE_DIR/violator.sh"; then
    pass "the detector recognises a direct check (a green result is not blindness)"
else
    fail "the detector missed a planted direct check"
fi
printf '#!/bin/bash\ncommand -v restic-wrapper; command -v claudette\n' > "$PROBE_DIR/neighbour.sh"
if grep -Eq '(^|[^A-Za-z0-9_-])(command -v|which|type -P)[[:space:]]+(tar|restic|claude)($|[^A-Za-z0-9_-])' "$PROBE_DIR/neighbour.sh"; then
    fail "the detector fired on programs with a similar name"
else
    pass "the detector does not fire on similarly named programs"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $FAIL"; exit 1; fi
