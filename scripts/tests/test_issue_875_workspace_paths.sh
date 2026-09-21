#!/usr/bin/env bash
# test_issue_875_workspace_paths.sh - regression for issue #875.
#
# Scripts that derive a path from the workspace FOLDER NAME ("-Users-<user>-IWE",
# "$HOME/IWE" as a hard-coded root) silently read another workspace's data when
# the install lives elsewhere (e.g. ~/IWE_custom): no error, just wrong data.
# Two defects of the issue were already fixed on main earlier (strategist.sh's
# day-rhythm config lookup; the .iwe-paths generator/consumer mismatch, WP-529
# F94). This test covers the remaining one - roles/synchronizer/scripts/dt-collect.sh -
# and pins the CLASS with the issue's own search, so the next occurrence fails CI.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
DT="$ROOT/roles/synchronizer/scripts/dt-collect.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# --- 1. the workspace root honours IWE_WORKSPACE (real assignment line, evaluated) ---
LINE=$(grep -E '^WORKSPACE=' "$DT" | head -1)
if [ -z "$LINE" ]; then
    bad "no top-level WORKSPACE= assignment found in dt-collect.sh (moved?)"
else
    got=$(env -i HOME=/home/someone IWE_WORKSPACE=/srv/custom_ws bash -c "$LINE; printf %s \"\$WORKSPACE\"")
    if [ "$got" = "/srv/custom_ws" ]; then ok "IWE_WORKSPACE is honoured (got: $got)"; else bad "IWE_WORKSPACE ignored: got '$got'"; fi
    got=$(env -i HOME=/home/someone bash -c "$LINE; printf %s \"\$WORKSPACE\"")
    if [ "$got" = "/home/someone/IWE" ]; then ok "default install path unchanged (got: $got)"; else bad "default changed: got '$got'"; fi
fi

# --- 2. MEMORY.md is read through the workspace, not through a guessed auto-memory slug ---
MEM=$(grep -E 'local MEMORY_FILE=' "$DT" | head -1)
if grep -q '\$WORKSPACE/memory/MEMORY.md' <<<"$MEM"; then
    ok "MEMORY_FILE is built from the workspace ($MEM)"
else
    bad "MEMORY_FILE is not built from \$WORKSPACE: $MEM"
fi

# --- 3. class guard: no live path derived from the folder name / user name ---
# The issue's own search. Comment lines are excluded (explanations of the old
# defect legitimately quote the pattern); tests are excluded (fixtures).
HITS=$(cd "$ROOT" && grep -rn --include='*.sh' --include='*.py' -E 'whoami\)-IWE|USER}-IWE|projects/-Users|SLUG\}-IWE' \
        roles scripts setup .claude 2>/dev/null \
    | grep -v '/tests/' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -z "$HITS" ]; then
    ok "no live workspace-folder-name path in roles/ scripts/ setup/ .claude/"
else
    bad "live workspace-folder-name path(s) found:"
    echo "$HITS" | cut -c1-200
fi

echo "Result: $fail FAIL"
[ "$fail" -eq 0 ]
