#!/bin/bash
# test-update-issue-1143.sh — regression test for issue #1143: update.sh must
# reinstall an already-installed auto:false role's plist (synchronizer,
# extractor) even though it never activates one the user never asked for,
# and must not silently re-enable a role the user deliberately disabled via
# `launchctl unload`.
#
# Extracts the REAL role-reinstall loop from update.sh between the
# BEGIN-TESTABLE/END-TESTABLE sentinel comments and evals it in a sandbox
# with a mocked launchctl — not a reimplementation of its logic, same
# philosophy as setup/test-delivery-route-label.sh.
#
# Usage: bash setup/test-update-issue-1143.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
UPDATE_SH_REAL="$REPO_ROOT/update.sh"
TEST_ROOT="${ISSUE_1143_WORKSPACE:-/tmp/iwe-issue-1143-test-$$}"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"

# Extract the real loop (sed between the sentinel lines, exclusive) — fails
# loudly if update.sh ever drops or renames the sentinels, instead of
# silently testing stale extracted text.
LOOP_BLOCK="$TEST_ROOT/loop-block.sh"
sed -n '/# BEGIN-TESTABLE: role-reinstall-loop/,/# END-TESTABLE: role-reinstall-loop/p' "$UPDATE_SH_REAL" \
    | sed '1d;$d' > "$LOOP_BLOCK"
if [ ! -s "$LOOP_BLOCK" ]; then
    echo "FATAL: sentinel comments not found in $UPDATE_SH_REAL — update.sh moved or renamed the role-reinstall loop" >&2
    exit 2
fi

# run_scenario NAME ROLE_NAME ROLE_YAML_AUTO PLIST_EXISTS WAS_LOADED
# Builds a fresh roles/ fixture with ONE role (named ROLE_NAME) plus one
# auto:true role with NO PLIST_DST= line at all (regression guard for the
# set -e/grep bug: a role lacking that line must not abort the whole loop),
# then evals the extracted block and reports what the fake install.sh saw.
run_scenario() {
    local name="$1" role_name="$2" auto="$3" plist_exists="$4" was_loaded="$5"
    local scenario_dir="$TEST_ROOT/$name"
    rm -rf "$scenario_dir"
    mkdir -p "$scenario_dir/roles/$role_name" "$scenario_dir/roles/no-plist-role" \
        "$scenario_dir/fake-home/Library/LaunchAgents" "$scenario_dir/.iwe-runtime"

    # The role under test: declares PLIST_DST= exactly like the real
    # synchronizer/extractor install.sh, records what it was called with.
    cat > "$scenario_dir/roles/$role_name/role.yaml" <<EOF
install:
  auto: $auto
EOF
    cat > "$scenario_dir/roles/$role_name/install.sh" <<'INSTALLEOF'
#!/bin/bash
PLIST_DST="$FAKE_HOME/Library/LaunchAgents/com.test.role.plist"
echo "IWE_SKIP_LOAD=${IWE_SKIP_LOAD:-}" > "$CALL_LOG"
echo "called" >> "$CALL_LOG"
touch "$PLIST_DST"
exit 0
INSTALLEOF
    chmod +x "$scenario_dir/roles/$role_name/install.sh"

    # Regression guard for Critical #1 (first code review): a role with NO
    # PLIST_DST= line at all must not abort the whole loop under set -e.
    cat > "$scenario_dir/roles/no-plist-role/role.yaml" <<'EOF'
install:
  auto: true
EOF
    cat > "$scenario_dir/roles/no-plist-role/install.sh" <<'INSTALLEOF'
#!/bin/bash
echo "no-plist-role called" >> "$NO_PLIST_LOG"
exit 0
INSTALLEOF
    chmod +x "$scenario_dir/roles/no-plist-role/install.sh"

    if [ "$plist_exists" = "yes" ]; then
        touch "$scenario_dir/fake-home/Library/LaunchAgents/com.test.role.plist"
    fi

    CALL_LOG="$scenario_dir/call.log"
    NO_PLIST_LOG="$scenario_dir/no-plist.log"
    rm -f "$CALL_LOG" "$NO_PLIST_LOG"

    # Mock launchctl: `list <label>` exits 0 only if $was_loaded=yes — the
    # real exact-match semantics (verified live: exit 0 vs 113), not a
    # grep-the-whole-listing stand-in.
    local launchctl_mock="$scenario_dir/launchctl"
    cat > "$launchctl_mock" <<EOF
#!/bin/bash
if [ "\$1" = list ]; then
    [ "$was_loaded" = yes ] && exit 0 || exit 113
fi
exit 0
EOF
    chmod +x "$launchctl_mock"

    (
        export HOME="$scenario_dir/fake-home"
        export FAKE_HOME="$scenario_dir/fake-home"
        export CALL_LOG NO_PLIST_LOG
        export PATH="$scenario_dir:$PATH"
        export SCRIPT_DIR="$scenario_dir"
        export WORKSPACE_DIR="$scenario_dir/fake-home"
        export HOST_GLOBAL_OWNER_CONFLICT=false
        export ROLE_REINSTALL_GOV="DS-strategy"
        effective_governance_repo() { echo DS-strategy; }
        set -e
        source "$LOOP_BLOCK"
    ) > "$scenario_dir/stdout.log" 2>&1
    echo "$?" > "$scenario_dir/exit.code"
}

# --- Scenario a: auto:false, plist installed and loaded -----------------
run_scenario a role-a false yes yes
if [ "$(cat "$TEST_ROOT/a/exit.code")" = 0 ]; then
    pass "a: loop did not abort (exit 0)"
else
    fail "a: loop aborted (exit $(cat "$TEST_ROOT/a/exit.code")), stdout: $(cat "$TEST_ROOT/a/stdout.log")"
fi
if grep -q "^called$" "$TEST_ROOT/a/call.log" 2>/dev/null; then
    pass "a: install.sh was called (plist already installed, auto:false)"
else
    fail "a: install.sh was NOT called"
fi
if grep -q "^IWE_SKIP_LOAD=$" "$TEST_ROOT/a/call.log" 2>/dev/null; then
    pass "a: IWE_SKIP_LOAD is empty (role was loaded, must not skip load)"
else
    fail "a: IWE_SKIP_LOAD unexpectedly set: $(cat "$TEST_ROOT/a/call.log" 2>/dev/null)"
fi

# --- Scenario b: auto:false, plist installed, NOT loaded (user disabled it) ---
run_scenario b role-b false yes no
if grep -q "^called$" "$TEST_ROOT/b/call.log" 2>/dev/null; then
    pass "b: install.sh was called (plist refreshed even though role was unloaded)"
else
    fail "b: install.sh was NOT called"
fi
if grep -q "^IWE_SKIP_LOAD=1$" "$TEST_ROOT/b/call.log" 2>/dev/null; then
    pass "b: IWE_SKIP_LOAD=1 (role was unloaded by the user, load must be skipped)"
else
    fail "b: IWE_SKIP_LOAD not 1: $(cat "$TEST_ROOT/b/call.log" 2>/dev/null)"
fi

# --- Scenario c: auto:false, plist NOT installed (role never set up here) ---
run_scenario c role-c false no no
if [ -f "$TEST_ROOT/c/call.log" ]; then
    fail "c: install.sh was called for a role never installed on this host"
else
    pass "c: install.sh was correctly skipped (role not installed, not auto)"
fi

# --- Scenario d: auto:true role with NO PLIST_DST= line (Critical #1 regression) ---
run_scenario d role-d true no no
if [ "$(cat "$TEST_ROOT/d/exit.code")" = 0 ]; then
    pass "d: loop did not abort when a role has no PLIST_DST= line (set -e regression guard)"
else
    fail "d: loop aborted under set -e (exit $(cat "$TEST_ROOT/d/exit.code")), stdout: $(cat "$TEST_ROOT/d/stdout.log")"
fi
if grep -q "no-plist-role called" "$TEST_ROOT/d/no-plist.log" 2>/dev/null; then
    pass "d: the no-PLIST_DST= auto:true role was still reached and reinstalled"
else
    fail "d: the no-PLIST_DST= role was never reached"
fi

echo ""
echo "Passed: $PASS_COUNT, failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
