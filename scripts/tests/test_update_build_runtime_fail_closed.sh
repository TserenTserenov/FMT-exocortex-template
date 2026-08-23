#!/usr/bin/env bash
# test_update_build_runtime_fail_closed.sh — WP-529 F6 (peer-session
# 2026-08-19-01, Evgenii post-update defect #5, 18.08).
#
# Scenario A: build-runtime fails during a real update (TOTAL_CHANGES>0) →
#   update.sh must exit EXIT_RUNTIME(3), keep .update-incomplete and say so.
#   Before the fix the failure was fully swallowed: the status flowed through
#   `| sed`, so even the warning-only branch never fired.
# Scenario B: rerun after the cause is fixed (now the TOTAL_CHANGES=0 recovery
#   path) → build-runtime MUST run on this path too (it never did), the marker
#   is removed, exit 0 — the same rerun-convergence contract as issue #459.
#
# Runs the REAL update.sh against a sandboxed SCRIPT_DIR/WORKSPACE_DIR with a
# curl shim serving fixture upstream content (same harness pattern as
# setup/test-update-issue-226.sh).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TEST_ROOT="/tmp/iwe-wp529-brt-test-$$"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# --- Fixture: fake upstream (served by the curl shim) ---
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/scripts"
printf '# Template CLAUDE.md\n' > "$UPSTREAM/CLAUDE.md"
printf '#!/bin/bash\necho v2\n' > "$UPSTREAM/scripts/dummy-new.sh"
python3 - "$UPSTREAM" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def entry(path):
    return {"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
manifest = {
    "schema_version": 2,
    "version": "0.99.0-brt-test",
    "files": [entry("CLAUDE.md"), entry("scripts/dummy-new.sh")],
    "deprecated_files": [],
}
(root / "update-manifest.json").write_text(json.dumps(manifest))
PY

# --- Fixture: local template copy, one file behind upstream ---
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/setup"
cp "$ROOT/update.sh" "$SCRIPT_DIR/update.sh"
cp "$ROOT/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$ROOT/scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"

WORKSPACE_DIR="$TEST_ROOT/repo"
cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

# Failing build-runtime stub; the probe log also proves it was invoked at all.
cat > "$SCRIPT_DIR/setup/build-runtime.sh" <<'EOF'
#!/bin/bash
echo "brt-invoked" >> "$(cd "$(dirname "$0")/.." && pwd)/brt-probe.log"
echo "stub: simulated build-runtime failure" >&2
exit 7
EOF
chmod +x "$SCRIPT_DIR/setup/build-runtime.sh"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t
git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A
git -C "$SCRIPT_DIR" commit -q -m init
git -C "$SCRIPT_DIR" checkout -q -b some-pr-branch

# --- curl shim: raw.githubusercontent.com/<REPO>/main/<path> → fixture ---
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
url="" out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
    esac
done
rel="\${url#*/main/}"
if [ "\$rel" = "update.sh" ]; then
    cp "$SCRIPT_DIR/update.sh" "\$out"
elif [ "\$rel" = "update-manifest.json" ]; then
    cp "$UPSTREAM/update-manifest.json" "\$out"
else
    src="$UPSTREAM/\$rel"
    [ -f "\$src" ] && cp "\$src" "\$out" || exit 22
fi
exit 0
SHIMEOF
chmod +x "$SHIM_DIR/curl"

echo "--- Scenario A: build-runtime fails during a real update ---"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-a.log" 2>&1
RC_A=$?
set -e

if [ "$RC_A" -eq 3 ]; then
    pass "A: exit 3 (EXIT_RUNTIME), not a silent success"
else
    fail "A: expected exit 3, got $RC_A"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "A: .update-incomplete kept — transaction stays open"
else
    fail "A: marker removed despite the runtime failure"
fi
if grep -q "build-runtime.sh завершился с ошибкой" "$TEST_ROOT/out-a.log"; then
    pass "A: explicit failure message with remediation printed"
else
    fail "A: no explicit build-runtime failure message"
fi
if grep -q "brt-invoked" "$SCRIPT_DIR/brt-probe.log" 2>/dev/null; then
    pass "A: build-runtime actually invoked (probe present)"
else
    fail "A: build-runtime never invoked"
fi

echo "--- Scenario A2: --check must not clear the marker left by the failed run ---"
# Cold review 2026-08-19 (Critical): the recovery branch used to call
# finish_update_transaction outside the CHECK_ONLY split, so the documented
# next step after a failure — update.sh --check — silently cleared the marker
# without repair or build-runtime, disarming the contract it now carries.
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-a2.log" 2>&1
RC_A2=$?
set -e

if [ "$RC_A2" -eq 0 ]; then
    pass "A2: --check itself succeeds (preview stays read-only)"
else
    fail "A2: --check exited $RC_A2"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "A2: preview (--check) leaves .update-incomplete in place"
else
    fail "A2: --check cleared the marker — contract disarmed by a read-only preview"
fi

echo "--- Scenario B: rerun after fixing the cause (TOTAL_CHANGES=0 recovery) ---"
cat > "$SCRIPT_DIR/setup/build-runtime.sh" <<'EOF'
#!/bin/bash
echo "brt-invoked-fixed" >> "$(cd "$(dirname "$0")/.." && pwd)/brt-probe.log"
exit 0
EOF
chmod +x "$SCRIPT_DIR/setup/build-runtime.sh"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-b.log" 2>&1
RC_B=$?
set -e

if [ "$RC_B" -eq 0 ]; then
    pass "B: rerun converges to exit 0"
else
    fail "B: expected exit 0, got $RC_B — no issue-#459-style convergence"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    fail "B: marker still present after a successful rerun"
else
    pass "B: marker removed after successful recovery"
fi
if grep -q "brt-invoked-fixed" "$SCRIPT_DIR/brt-probe.log" 2>/dev/null; then
    pass "B: build-runtime runs on the TOTAL_CHANGES=0 recovery path"
else
    fail "B: recovery path still skips build-runtime"
fi

echo "--- Scenario C: build-runtime fails with NO pre-existing marker (TOTAL_CHANGES=0 from the start) ---"
# Evgenii Red Team review 2026-08-19 (defect #3): after B the workspace is
# already in sync with upstream and .update-incomplete does not exist — the
# exact starting state defect #3 describes. This path used to call
# repair_pass()/run_build_runtime_or_die() without ever opening a transaction,
# so a build failure here exited EXIT_RUNTIME with NO marker at all: the
# fail-closed contract Scenario A checks was silently absent on this branch.
cat > "$SCRIPT_DIR/setup/build-runtime.sh" <<'EOF'
#!/bin/bash
echo "brt-invoked-scenario-c" >> "$(cd "$(dirname "$0")/.." && pwd)/brt-probe.log"
echo "stub: simulated build-runtime failure (scenario C)" >&2
exit 7
EOF
chmod +x "$SCRIPT_DIR/setup/build-runtime.sh"

if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    fail "C precondition: marker already present before the run — scenario invalid"
fi

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-c.log" 2>&1
RC_C=$?
set -e

if [ "$RC_C" -eq 3 ]; then
    pass "C: exit 3 (EXIT_RUNTIME) on the TOTAL_CHANGES=0 recovery path too"
else
    fail "C: expected exit 3, got $RC_C"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "C: transaction was opened — marker present despite starting with none"
else
    fail "C: no marker at all — the TOTAL_CHANGES=0 branch never opens a transaction"
fi

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "build-runtime fail-closed contract: $FAIL check(s) failed"
    exit 1
fi
echo "build-runtime fail-closed contract: all checks passed"
