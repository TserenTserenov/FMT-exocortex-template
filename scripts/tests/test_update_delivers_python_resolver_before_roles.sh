#!/usr/bin/env bash
# test_update_delivers_python_resolver_before_roles.sh — WP-529 F6 acceptance
# (peer-session 2026-08-19-01, codex requirement on В1): the shared python
# resolver must be delivered before any role reload can consume it, and every
# consumer must actually go through it. Checked as a structural invariant of
# update.sh mechanics (file apply = Step 5 precedes runtime rebuild = Step 6d
# precedes roles reinstall) plus manifest membership — the equivalent
# order-invariant check codex accepted in place of a full fixture update run.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }

# 1. Resolver is part of the update delivery (manifest files[])
if python3 - "$ROOT/update-manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
paths = {f["path"] for f in manifest["files"]}
sys.exit(0 if "scripts/lib/find-python3.sh" in paths else 1)
PY
then
    pass "resolver present in update-manifest.json files[]"
else
    fail "resolver missing from update-manifest.json — update-only installs will not receive it"
fi

# 2. Resolver is executable in both delivery topologies. The `.claude/lib`
# copy is what fresh-installed hooks can actually reach; exact equality keeps
# the two entrypoints from becoming different dependency policies.
if [ -x "$ROOT/scripts/lib/find-python3.sh" ]; then
    pass "template resolver is executable"
else
    fail "template resolver is not executable"
fi
if [ -x "$ROOT/.claude/lib/find-python3.sh" ]; then
    pass "installed-hook resolver is executable"
else
    fail "installed-hook resolver is not executable"
fi
if cmp -s "$ROOT/scripts/lib/find-python3.sh" "$ROOT/.claude/lib/find-python3.sh"; then
    pass "template and installed-hook resolvers are byte-identical"
else
    fail "template and installed-hook resolvers drifted"
fi

# 3. Every consumer references the shared resolver and keeps no local copy
for consumer in scripts/server-calendar.sh scripts/server-news.sh scripts/active-wp-sweep.sh; do
    if grep -q "lib/find-python3.sh" "$ROOT/$consumer"; then
        pass "$consumer uses the shared resolver"
    else
        fail "$consumer does not reference the shared resolver"
    fi
    if grep -q "_find_python3()" "$ROOT/$consumer"; then
        fail "$consumer still defines a local _find_python3() copy"
    else
        pass "$consumer has no local resolver copy"
    fi
done

# 4. update.sh order invariant: Step 5 (apply) < Step 6d (build-runtime) < roles reinstall.
# Files are applied before any launchctl load can fire a runner, so the
# resolver lands on disk before consumers can be re-run by a reloaded role.
L_APPLY=$(grep -n "^# === Step 5: Apply updates ===" "$ROOT/update.sh" | head -1 | cut -d: -f1)
L_BRT=$(grep -n "^# === Step 6d: Rebuild generated runtime" "$ROOT/update.sh" | head -1 | cut -d: -f1)
L_ROLES=$(grep -n "^# Reinstall roles if changed" "$ROOT/update.sh" | head -1 | cut -d: -f1)
if [ -n "$L_APPLY" ] && [ -n "$L_BRT" ] && [ -n "$L_ROLES" ]; then
    if [ "$L_APPLY" -lt "$L_BRT" ] && [ "$L_BRT" -lt "$L_ROLES" ]; then
        pass "update.sh order: apply ($L_APPLY) < build-runtime ($L_BRT) < roles reinstall ($L_ROLES)"
    else
        fail "update.sh step order violated: apply=$L_APPLY build-runtime=$L_BRT roles=$L_ROLES"
    fi
else
    fail "structural anchors not found in update.sh (apply='$L_APPLY' brt='$L_BRT' roles='$L_ROLES') — update anchors or this test together"
fi

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "resolver delivery-order invariant: $FAIL check(s) failed"
    exit 1
fi
echo "resolver delivery-order invariant: all checks passed"
