#!/usr/bin/env bash
# test_issue_891_loose_claude_files_delivery.sh - regression for issue #891.
#
# .claude/rules-registry.yaml (and its siblings: parity-contract.yaml,
# process-pattern-catalog.yaml, runtime-overlay.yaml, skills-catalog.yaml,
# sync-manifest.yaml, capture-config.sh.example) were checksummed in
# update-manifest.json but neither setup.sh's [4b] propagation loop nor
# update.sh's NEW_FILES/UPDATED_FILES case statement had a branch matching
# a bare .claude/*.yaml path -- only subdirectories and settings.json were
# copied. A fresh install landed with the file simply absent; sql-pii-guard.sh
# then failed closed on every .sql write (AR.112/AR.113 unevaluable), the
# same symptom as #753 but with a different root cause.
#
# Part A drives a real setup.sh --core e2e install and asserts every loose
# top-level .claude/ file the template ships actually reaches the workspace.
# Part B is a static grep on update.sh's own case-statement branches (same
# style as smoke-test-fresh-install.sh's own "[6d]" .claude/*/ coverage
# check) -- not a live e2e run. update.sh derives WORKSPACE_DIR from ITS OWN
# on-disk location and, at least on this host, running it against a
# symlinked/disposable template tree triggered some other self-repair
# machinery that silently reverted dozens of unrelated files in the REAL
# template checkout to a much older snapshot (recovered via `git checkout
# --` here, nothing was lost only because nothing had been committed yet).
# That is a separate, serious platform defect outside this issue's scope --
# flagged to the pilot, not chased down or fixed here -- and reason enough
# not to invoke update.sh e2e from an automated test on a live checkout.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TEMPLATE_DIR="$ROOT"

PYTHON=$(command -v python3 || true)
SMOKE_CLEAN_PATH="/usr/bin:/bin"
[ -d /run/current-system/sw/bin ] && SMOKE_CLEAN_PATH="$SMOKE_CLEAN_PATH:/run/current-system/sw/bin"
[ -n "$PYTHON" ] && SMOKE_CLEAN_PATH="$(dirname "$PYTHON"):$SMOKE_CLEAN_PATH"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Part A: fresh install (setup.sh --core) ---
E2E_WS=$(mktemp -d)
E2E_HOME=$(mktemp -d)
E2E_OUT=$(HOME="$E2E_HOME" PATH="$SMOKE_CLEAN_PATH" SETUP_CI=1 GITHUB_USER=test-891 WORKSPACE_DIR="$E2E_WS" \
    GIT_AUTHOR_NAME="test-891" GIT_AUTHOR_EMAIL="test@test.local" \
    GIT_COMMITTER_NAME="test-891" GIT_COMMITTER_EMAIL="test@test.local" \
    bash "$TEMPLATE_DIR/setup.sh" --core 2>&1)
E2E_RC=$?
if [ "$E2E_RC" -ne 0 ]; then
    fail "setup.sh --core exited $E2E_RC: $(echo "$E2E_OUT" | tail -5)"
else
    pass "setup.sh --core exit 0"
    while IFS= read -r -d '' loose_file; do
        name=$(basename "$loose_file")
        case "$name" in
            settings.json|settings.local.json) continue ;;  # separately handled, covered elsewhere
        esac
        dst="$E2E_WS/.claude/$name"
        if [ -f "$dst" ] && cmp -s "$loose_file" "$dst"; then
            pass "setup.sh delivers .claude/$name byte-identical"
        else
            fail "setup.sh did not deliver .claude/$name to a fresh install"
        fi
    done < <(find "$TEMPLATE_DIR/.claude" -maxdepth 1 -type f -print0)
fi
rm -rf "$E2E_WS" "$E2E_HOME" 2>/dev/null || true

# --- Part B: update.sh's case-statement branches, statically ---
# Every case arm that matches subdir paths (.claude/skills/*, .claude/hooks/*,
# ...) must also match a loose top-level file (.claude/*.yaml, .claude/*.yml,
# .claude/*.example), in BOTH places update.sh copies from: the NEW_FILES/
# UPDATED_FILES propagation loop and repair_pass() (which walks the whole
# manifest, not just subdirectories -- a stale/missing loose file needs the
# same repair arm or it is silently skipped there too).
UPDATE_SH="$TEMPLATE_DIR/update.sh"
LOOSE_ARM_COUNT=$(grep -cE '\.claude/\*\.yaml\|\.claude/\*\.yml\|\.claude/\*\.example\)' "$UPDATE_SH")
if [ "$LOOSE_ARM_COUNT" -eq 2 ]; then
    pass "update.sh has the loose .claude/*.yaml|*.yml|*.example arm in both case statements"
else
    fail "update.sh has $LOOSE_ARM_COUNT (expected 2) loose-file case arms -- propagation and/or repair_pass() branch missing"
fi
# Each such arm must sit in the SAME case statement as the subdir arms (not
# a separate, later-in-the-list arm that never gets to run the same body) --
# checked by requiring the two patterns share one `|`-joined case label line.
SAME_LINE_COUNT=$(grep -cE '\.claude/skills/\*\|.*\.claude/\*\.yaml\|\.claude/\*\.yml\|\.claude/\*\.example\)' "$UPDATE_SH")
if [ "$SAME_LINE_COUNT" -eq 2 ]; then
    pass "the loose-file arm shares one case label (and so one body) with the subdir arms, in both statements"
else
    fail "the loose-file arm is not joined into the subdir arms' case label ($SAME_LINE_COUNT of 2 statements)"
fi

echo "Result: $FAIL FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
