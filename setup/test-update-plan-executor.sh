#!/bin/bash
# test-update-plan-executor.sh — WP-529 F245 step 2 (wiring): Step 5 of
# update.sh writes the template clone only through the frozen plan and the
# single executor (setup/lib/apply-op.sh), with the journal hook contract.
#
# What lives where:
#   - plan format and executor internals (order, pre/post fingerprints, symlink
#     parents, refusal-before-write, /tmp vs /private/tmp canonicalization) are
#     covered by setup/test-apply-op.sh against the lib itself — not repeated.
#   - here: the WIRING — Step 5 builds and freezes a plan, apply goes through
#     apply_op, the hook gate works, and the visible behavior (messages, tree)
#     of a real update run is preserved. Static barriers (grep-style, red on
#     the pre-wiring code) plus an end-to-end run on the issue-226 harness
#     pattern.
#
# Red/green control: checks S1-S4 and E8/E11 are red on the pre-wiring
# update.sh (verified via git stash on wp529-f245-plan-executor).
#
# Usage: bash setup/test-update-plan-executor.sh   (KEEP=1 keeps the sandbox)

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SELF_DIR")"
UPDATE_SH_REAL="$TEMPLATE_DIR/update.sh"
TEST_ROOT="${PLAN_EXECUTOR_WORKSPACE:-/tmp/iwe-plan-executor-test-$$}"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT" "$FAKE_HOME"

echo "============================================"
echo "  Plan-executor wiring: update.sh Step 5 (WP-529 F245)"
echo "============================================"

# ------------------------------------------------------------------
# Static barriers (S1-S4 red on pre-wiring code)
# ------------------------------------------------------------------
echo "--- static barriers ---"

if grep -qF 'apply_op_begin "$UPDATE_PLAN_FILE"' "$UPDATE_SH_REAL" \
    && grep -qF 'apply_op "$_update_plan_id"' "$UPDATE_SH_REAL"; then
    pass "S1: Step 5 accepts and executes the frozen plan through apply_op"
else
    fail "S1: Step 5 does not go through apply_op_begin/apply_op"
fi

if grep -qF 'cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"' "$UPDATE_SH_REAL"; then
    fail "S2: the old direct cp from the download staging into the clone is still in update.sh"
else
    pass "S2: no direct cp from download staging into the clone in the apply loops"
fi

if grep -qF '"$TMPDIR_UPDATE/files/setup/lib/apply-op.sh"' "$UPDATE_SH_REAL"; then
    pass "S3: update.sh sources the delivered executor (TMPDIR copy, then the installed one)"
else
    fail "S3: update.sh does not source setup/lib/apply-op.sh"
fi

if grep -qF 'mv "$UPDATE_PLAN_TMP" "$UPDATE_PLAN_FILE"' "$UPDATE_SH_REAL"; then
    pass "S4: the plan is frozen by a single rename into its final name"
else
    fail "S4: plan freeze (build-name -> final-name rename) not found"
fi

# repair_pass never writes into the template clone root: it re-copies runtime
# files OUT of it ($dst targets). A write command whose last path argument or
# redirect target is under $SCRIPT_DIR breaks the rollback boundary.
repair_body=$(awk '/^repair_pass\(\) \{/{c=1} c{print} c&&/^}/{exit}' "$UPDATE_SH_REAL")
if [ -z "$repair_body" ]; then
    fail "S5: repair_pass() not found in update.sh"
else
    repair_hits=$(printf '%s\n' "$repair_body" | grep -nE '(cp|mv|rm|rmdir|mkdir|chmod|ln|install)\s' \
        | grep -E '\$SCRIPT_DIR[^"]*"?\s*$|>\s*"?[^" ]*\$SCRIPT_DIR' || true)
    if [ -z "$repair_hits" ]; then
        pass "S5: repair_pass writes only outside the clone root (barrier)"
    else
        fail "S5: repair_pass has a write targeting \$SCRIPT_DIR: $repair_hits"
    fi
fi

# Increment boundary: deprecated files still move directly (destination is in
# .backups, outside the clone root) — not through the plan in this step.
if grep -q 'move_deprecated_to_backup "$SCRIPT_DIR" "$f" template "$f"' "$UPDATE_SH_REAL"; then
    pass "S6: deprecated moves stay direct (agreed increment boundary)"
else
    fail "S6: deprecated move block changed unexpectedly"
fi

# ------------------------------------------------------------------
# Fixture: fake "upstream" tree (curl shim serves it)
# ------------------------------------------------------------------
echo "--- end-to-end: synthetic install ---"
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks" "$UPSTREAM/memory" "$UPSTREAM/setup/lib"

cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

Same content both sides.
EOF

cat > "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'EOF'
#!/bin/bash
echo "dummy hook v2"
EOF

cat > "$UPSTREAM/memory/dummy-memo.md" <<'EOF'
# Dummy memo v2
EOF

cat > "$UPSTREAM/scripts.probe.sh" <<'EOF'
EOF
rm "$UPSTREAM/scripts.probe.sh"
mkdir -p "$UPSTREAM/scripts"
cat > "$UPSTREAM/scripts/plan-executor-probe.sh" <<'EOF'
#!/bin/bash
echo "probe v1"
EOF

# The executor itself is delivered like the real manifest delivers it.
cp "$SELF_DIR/lib/apply-op.sh" "$UPSTREAM/setup/lib/apply-op.sh"

build_manifest() {
python3 - "$UPSTREAM" <<'PYEOF'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
def entry(p):
    return {'path': p, 'sha256': hashlib.sha256((root / p).read_bytes()).hexdigest()}
manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-plan-executor',
    'files': [
        entry('CLAUDE.md'),
        entry('.claude/hooks/dummy-hook.sh'),
        entry('memory/dummy-memo.md'),
        entry('scripts/plan-executor-probe.sh'),
        entry('setup/lib/apply-op.sh'),
    ],
    'deprecated_files': [],
}
(root / 'update-manifest.json').write_text(json.dumps(manifest))
PYEOF
}
build_manifest

# ------------------------------------------------------------------
# Fixture: local clone (old state) + workspace
# ------------------------------------------------------------------
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/memory"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
cp "$TEMPLATE_DIR/.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"

cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
printf '#!/bin/bash\necho "dummy hook v1"\n' > "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
printf '# Dummy memo v1\n' > "$SCRIPT_DIR/memory/dummy-memo.md"

WORKSPACE_DIR="$TEST_ROOT/repo"
cat > "$WORKSPACE_DIR/.exocortex.env" <<'EOF'
GOVERNANCE_REPO="pilot-governance"
EOF
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t; git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m init
git -C "$SCRIPT_DIR" checkout -q -b some-pr-branch

# ------------------------------------------------------------------
# curl shim (compact copy of the issue-226 one: --help all, -K batch, single)
# ------------------------------------------------------------------
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
simulate_one_transfer() {
    local u="\$1" o="\$2"
    local rel="\${u#*/main/}"
    if [ "\$rel" = "update.sh" ]; then
        cp "$SCRIPT_DIR/update.sh" "\$o"
    elif [ "\$rel" = "update-manifest.json" ]; then
        cp "$UPSTREAM/update-manifest.json" "\$o"
    else
        local src="$UPSTREAM/\$rel"
        [ -f "\$src" ] && cp "\$src" "\$o" || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; }
    fi
}

if [ "\$1" = "--help" ] && [ "\$2" = "all" ]; then
    printf -- '  --parallel \\n  --parallel-max <num>\\n  --remove-on-error \\n'
    exit 0
fi

url="" out="" cfgfile=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
        -K) cfgfile="\${args[i+1]}" ;;
    esac
done

if [ -n "\$cfgfile" ]; then
    had_error=0
    pending_url=""
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*)
                [ -n "\$pending_url" ] && had_error=1
                pending_url=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//')
                ;;
            'output = '*)
                if [ -z "\$pending_url" ]; then
                    had_error=1
                else
                    pending_out=\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')
                    simulate_one_transfer "\$pending_url" "\$pending_out" || had_error=1
                    pending_url=""
                fi
                ;;
        esac
    done < "\$cfgfile"
    [ -n "\$pending_url" ] && had_error=1
    exit "\$had_error"
fi

simulate_one_transfer "\$url" "\$out"
exit \$?
SHIMEOF
chmod +x "$SHIM_DIR/curl"

JOURNAL="$TEST_ROOT/journal-fake.log"

run_update() {
    PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
        IWE_UPDATE_JOURNAL_FAKE_LOG="$JOURNAL" \
        bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/$1" 2>&1
}

# ------------------------------------------------------------------
# Run 1: full update through the plan executor
# ------------------------------------------------------------------
echo "--- run 1: update through the frozen plan ---"
set +e
run_update out-1.log
RC1=$?
set -e

if [ "$RC1" -eq 0 ]; then
    pass "E1: update.sh exits 0"
else
    fail "E1: update.sh exited rc=$RC1 (log: $TEST_ROOT/out-1.log)"
fi

if [ -x "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh" ] && grep -q 'v2' "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"; then
    pass "E2: updated hook replaced, content v2, exec bit kept"
else
    fail "E2: hook not replaced with an executable v2"
fi

if grep -q 'v2' "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "E3: updated memory file replaced"
else
    fail "E3: memory file not replaced"
fi

if [ -x "$SCRIPT_DIR/scripts/plan-executor-probe.sh" ] && grep -q 'probe v1' "$SCRIPT_DIR/scripts/plan-executor-probe.sh"; then
    pass "E4: new script created via plan with the exec bit"
else
    fail "E4: new script missing or not executable"
fi

if [ -f "$SCRIPT_DIR/setup/lib/apply-op.sh" ]; then
    pass "E5: the executor itself delivered (mkdir ops for setup/ and setup/lib/)"
else
    fail "E5: setup/lib/apply-op.sh not delivered into the clone"
fi

if grep -qF '  + scripts/plan-executor-probe.sh' "$TEST_ROOT/out-1.log" \
    && grep -qF '  ~ .claude/hooks/dummy-hook.sh' "$TEST_ROOT/out-1.log"; then
    pass "E6: per-file apply lines printed on successful ops"
else
    fail "E6: expected '  + '/'  ~ ' lines missing in the output"
fi

leftovers=$(find "$SCRIPT_DIR" -name '.apply-op.*' -print 2>/dev/null)
if [ -z "$leftovers" ]; then
    pass "E7: no executor temp files left next to targets"
else
    fail "E7: executor temp files left behind: $leftovers"
fi

# Journal contract: lines are "intent N"/"done N", ids strictly ascending,
# every intent immediately closed by its done (the run succeeded).
check_journal_log() {
    local _file="$1" _prev=0 _expect="intent" _line _ev _id
    [ -f "$_file" ] || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        _ev=${_line%% *}; _id=${_line##* }
        case "$_id" in '' | *[!0-9]*) return 1 ;; esac
        if [ "$_expect" = "intent" ]; then
            [ "$_ev" = "intent" ] || return 1
            [ "$_id" -gt "$_prev" ] || return 1
            _prev=$_id; _expect="done"
        else
            [ "$_ev" = "done" ] || return 1
            [ "$_id" = "$_prev" ] || return 1
            _expect="intent"
        fi
    done < "$_file"
    [ "$_expect" = "intent" ]
}

# The checker itself must catch a broken log (its own red/green control).
printf 'intent 1\ndone 1\nintent 2\ndone 2\n' > "$TEST_ROOT/j-good.log"
printf 'intent 1\ndone 1\ndone 2\n' > "$TEST_ROOT/j-bad-doubledone.log"
printf 'intent 2\ndone 2\nintent 1\ndone 1\n' > "$TEST_ROOT/j-bad-desc.log"
printf 'intent 1\ndone 1\nintent 2\n' > "$TEST_ROOT/j-bad-unclosed.log"
journal_selfcheck_ok=1
check_journal_log "$TEST_ROOT/j-good.log" || journal_selfcheck_ok=0
check_journal_log "$TEST_ROOT/j-bad-doubledone.log" && journal_selfcheck_ok=0
check_journal_log "$TEST_ROOT/j-bad-desc.log" && journal_selfcheck_ok=0
check_journal_log "$TEST_ROOT/j-bad-unclosed.log" && journal_selfcheck_ok=0
if [ "$journal_selfcheck_ok" -eq 1 ]; then
    pass "E8a: journal checker self-check (accepts a good log, catches done-done, descending id, unclosed intent)"
else
    fail "E8a: journal checker misses a broken log shape"
fi

journal_ops=0
if [ -f "$JOURNAL" ]; then
    journal_ops=$(wc -l < "$JOURNAL" | tr -d ' ')
    journal_ops=$((journal_ops / 2))
fi
if check_journal_log "$JOURNAL" && [ "$journal_ops" -ge 5 ]; then
    pass "E8: journal hook saw intent->done for all $journal_ops ops in plan order (red on pre-wiring code)"
else
    fail "E8: journal hook log broken (ops=$journal_ops): $(head -4 "$JOURNAL" 2>/dev/null)"
fi

# ------------------------------------------------------------------
# Run 2: retry right after a successful run does not touch the tree
# ------------------------------------------------------------------
echo "--- run 2: idempotent retry ---"
tree_snapshot() {
    (cd "$SCRIPT_DIR" && find . -type f ! -path './.git/*' -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null)
}
snap_before=$(tree_snapshot)
journal_size_before=$(wc -c < "$JOURNAL" 2>/dev/null || echo 0)
set +e
run_update out-2.log
RC2=$?
set -e
snap_after=$(tree_snapshot)

if [ "$RC2" -eq 0 ] && [ "$snap_before" = "$snap_after" ]; then
    pass "E9: second run leaves the clone tree byte-identical"
else
    fail "E9: retry changed the tree or failed (rc=$RC2)"
fi

journal_size_after=$(wc -c < "$JOURNAL" 2>/dev/null || echo 0)
if [ "$journal_size_before" = "$journal_size_after" ]; then
    pass "E10: nothing to apply -> no new plan ops (journal untouched)"
else
    fail "E10: retry ran plan ops although nothing changed"
fi

# ------------------------------------------------------------------
# Run 3: a failing journal hook stops the run before ANY write
# ------------------------------------------------------------------
echo "--- run 3: hook refusal ---"
printf '# Dummy memo v3\n' > "$UPSTREAM/memory/dummy-memo.md"
build_manifest
# The fake hook appends to IWE_UPDATE_JOURNAL_FAKE_LOG; pointing it into a
# nonexistent directory makes the hook itself fail, like a real journal would.
JOURNAL="$TEST_ROOT/no-such-dir/journal.log"
set +e
run_update out-3.log
RC3=$?
set -e

if [ "$RC3" -ne 0 ]; then
    pass "E11: update.sh exits non-zero when the journal hook refuses (red on pre-wiring code)"
else
    fail "E11: update.sh succeeded despite a failing journal hook"
fi

if grep -q 'v2' "$SCRIPT_DIR/memory/dummy-memo.md" && ! grep -q 'v3' "$SCRIPT_DIR/memory/dummy-memo.md"; then
    pass "E12: hook refusal happened before any write (memo still the run-1 content)"
else
    fail "E12: a write happened although the hook refused"
fi

leftovers=$(find "$SCRIPT_DIR" -name '.apply-op.*' -print 2>/dev/null)
if [ -z "$leftovers" ]; then
    pass "E13: no temp file appeared next to the target on hook refusal"
else
    fail "E13: temp file appeared before the refused op: $leftovers"
fi

if grep -q 'журнальный хук' "$TEST_ROOT/out-3.log"; then
    pass "E14: the refusal is reported with its reason"
else
    fail "E14: hook refusal not reported (log: $TEST_ROOT/out-3.log)"
fi

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
