#!/usr/bin/env bash
# Regression coverage for issue #718: a locally-held fix can be silently lost
# on the next update.sh run, and the pilot only notices weeks later because
# the affected mechanism keeps producing a plausible-looking result instead
# of a loud error (the issue's own example: #717).
#
# Two things are under test:
#  1. wp-sync-bundle.sh --self-test <WP-N> — before this fix it only checked
#     that the WP's file exists (find_wp_file), never that the registry row
#     actually resolves to a real status (registry_status()). A WP file that
#     exists but is missing from (or unparseable in) the registry used to
#     report "OK" — exactly the "plausible instead of loud" failure class.
#  2. update.sh's run_sync_canary() — the --check-mode wiring that runs the
#     self-test canary and turns a failure into a distinct, non-zero exit
#     code (EXIT_CANARY_FAILED) instead of update.sh's normal "Всё в порядке".
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

# --- Part 1: wp-sync-bundle.sh --self-test <WP-N> against a synthetic tree ---

WORKSPACE="$TMP/workspace"
GOV="gov-repo"
mkdir -p "$WORKSPACE/$GOV/docs" "$WORKSPACE/$GOV/inbox/WP-10" "$WORKSPACE/$GOV/inbox/WP-11"

cat >"$WORKSPACE/$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | Название | Статус | Приоритет |
|---|----------|--------|-----------|
| 10 | С реестром | 🔄 | P1 |
EOF

# WP-10: file + registry row both present — canary must pass.
cat >"$WORKSPACE/$GOV/inbox/WP-10/WP-10.md" <<'EOF'
---
name: "С реестром"
status: in_progress
---
EOF

# WP-11: file exists but has NO row in the registry at all — this is the
# exact gap the old self-test (file-lookup only) could not see.
cat >"$WORKSPACE/$GOV/inbox/WP-11/WP-11.md" <<'EOF'
---
name: "Без реестра"
status: in_progress
---
EOF

good_out=$(IWE_WORKSPACE="$WORKSPACE" IWE_GOVERNANCE_REPO="$GOV" \
    bash "$ROOT/.claude/scripts/wp-sync-bundle.sh" --self-test 10 2>&1)
good_status=$?
if [ "$good_status" -eq 0 ] && echo "$good_out" | grep -q "registry_status: 🔄 in_progress"; then
    pass "self-test WP-10 (file + registry row present) exits 0"
else
    fail "self-test WP-10 expected exit 0 with a resolved status, got exit $good_status:\n$good_out"
fi

orphan_out=$(IWE_WORKSPACE="$WORKSPACE" IWE_GOVERNANCE_REPO="$GOV" \
    bash "$ROOT/.claude/scripts/wp-sync-bundle.sh" --self-test 11 2>&1)
orphan_status=$?
if [ "$orphan_status" -ne 0 ] && echo "$orphan_out" | grep -q "Canary FAILED"; then
    pass "self-test WP-11 (file present, registry row missing) exits non-zero — old self-test would have reported OK here"
else
    fail "self-test WP-11 expected a non-zero Canary FAILED exit, got exit $orphan_status:\n$orphan_out"
fi

# --- Part 2: update.sh's run_sync_canary() wiring ---

# Load only the two functions under test — sourcing update.sh would run its
# CLI/network path (same isolation pattern as the other test_issue_*.sh files).
eval "$(awk '
  /^effective_governance_repo\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { print ""; capture=0 }
' "$ROOT/update.sh")"
eval "$(awk '
  /^run_sync_canary\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"

EXIT_CANARY_FAILED=5
WORKSPACE_DIR="$TMP/rsc-workspace"
SCRIPT_DIR="$TMP/rsc-template"
mkdir -p "$WORKSPACE_DIR" "$SCRIPT_DIR/.claude/scripts"

# SCRIPT_DIR always ships its own wp-sync-bundle.sh (it's the template
# install, not a bare directory) — a real one, so this fixture exercises the
# same "governance repo not set up yet" path a fresh install hits, not the
# unrelated "script file missing" path a bare empty SCRIPT_DIR would hit
# instead. That distinction is exactly the gap that hid the bug this test
# was written for: effective_governance_repo() always resolves a repo NAME
# (default DS-strategy) even when that directory doesn't exist, so the old
# run_sync_canary fell through to actually invoking wp-sync-bundle.sh, which
# hard-exits 1 on a missing WP-REGISTRY.md — reported as a canary FAILURE
# instead of the "not configured yet" SKIP it actually is.
cp "$ROOT/.claude/scripts/wp-sync-bundle.sh" "$SCRIPT_DIR/.claude/scripts/wp-sync-bundle.sh"
chmod +x "$SCRIPT_DIR/.claude/scripts/wp-sync-bundle.sh"

# No governance repo configured at all -> SKIP (exit 0), not FAIL.
ENV_GOVERNANCE_REPO=""
rsc_out=$(run_sync_canary 2>&1)
rsc_status=$?
if [ "$rsc_status" -eq 0 ] && echo "$rsc_out" | grep -q "SKIP"; then
    pass "run_sync_canary SKIPs (exit 0) when no governance repo is configured"
else
    fail "run_sync_canary expected SKIP/exit 0 with no governance repo, got exit $rsc_status:\n$rsc_out"
fi

# Governance repo configured AND set up (docs/WP-REGISTRY.md exists — this
# is what distinguishes "configured but its canary genuinely fails" from the
# "not configured yet" SKIP case above), wp-sync-bundle.sh present but its
# self-test fails -> run_sync_canary must propagate EXIT_CANARY_FAILED, not
# mask it.
# shellcheck disable=SC2034  # read by effective_governance_repo(), eval'd above
ENV_GOVERNANCE_REPO="gov"
mkdir -p "$WORKSPACE_DIR/gov/.claude/scripts" "$WORKSPACE_DIR/gov/docs"
touch "$WORKSPACE_DIR/gov/docs/WP-REGISTRY.md"
cat >"$WORKSPACE_DIR/gov/.claude/scripts/wp-sync-bundle.sh" <<'EOF'
#!/usr/bin/env bash
echo "simulated registry failure"
exit 1
EOF
chmod +x "$WORKSPACE_DIR/gov/.claude/scripts/wp-sync-bundle.sh"

rsc_out=$(run_sync_canary 2>&1)
rsc_status=$?
if [ "$rsc_status" -eq "$EXIT_CANARY_FAILED" ]; then
    pass "run_sync_canary returns EXIT_CANARY_FAILED when the self-test canary fails"
else
    fail "run_sync_canary expected exit $EXIT_CANARY_FAILED on a failing canary, got exit $rsc_status:\n$rsc_out"
fi

echo "✅ test_issue_718_sync_canary: $pass_count checks passed"
