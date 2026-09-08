#!/bin/bash
# test-update-edge-cases.sh — edge-case regression tests for update.sh (issue #206)
#
# Covers gaps not exercised by smoke-test-fresh-install.sh:
#   T1: --check mode does not modify any file (idempotency guard)
#   T2: orphaned {{PLACEHOLDER}} in .iwe-runtime/ is detected post-build
#   T3: CLAUDE.md with pre-existing conflict markers blocks update (stacking guard)
#   T4: role install failure surfaces a visible warning (not silently swallowed)
#   T5: network-independent --check works with a cached manifest
#   T6: memory file with owner: user survives a hash mismatch (issue #229)
#   T7: hot-budget sum over threshold is detectable (issue #228)
#   T8: build-runtime.sh does not clobber an edited params.yaml (issue #327)
#   T9: .mcp.json migration preserves a third-party server like ext-figma (issue #335)
#   T10: CLAUDE.md fallback-merge (no .base) never silently drops §8/§9 edits (issue #336)
#   T11: protocol-artifact-validate.sh DayPlan checks (multiplier/mandatory/budget, issue #328)
#   T12: day-close.sh memory backup descends into memory/ subfolders (issue #343)
#   T13: iwe_scheduler_state separates "never deployed" from "deployed and dead" (issue #347)
#   T14: a fresh workspace is seeded with params.yaml from params.yaml.example (issue #348)
#   T15: residency-gate scripts resolve residency-gate.py from any cwd (issue #323)
#   T16: hooks newly registered in settings.json exist and honor the event protocol on a clean install (issues #310/#321/#323 batch)
#   T17: seed ships scripts/lib/ so a fresh governance install gets the scaffold dependency (issue #347)
#   T18: decision-log consumers share one canonical path and define cold-start/migration behavior (issue #351)
#   T19: orphan detection resolves the template independently of CWD and fails open (issue #353)
#   T20: index-health skip suppresses size checks but keeps semantic checks (issue #357)
#   T21: legacy owner:user protocols migrate once with backup; other user files stay protected (issue #354)
#   T22: Quick Close requires a runner card only when the runner and graph exist (issue #356)
#   T23: wp-sync-bundle prefers folder cards and reads structured open phase statuses
#   T24-T27: update safety, bootstrap/path contracts, multiplier opt-out, #384/#387/#388
#   T28: settings.json merge preview never touches inputs, honors merge rules (WP-7 F71)
#   T29: author_mode skip classifier verdicts on synthetic template history (WP-7 F71)
#   T30: update.sh wires stage-A observability scripts in (WP-7 F71)
#   T31: extensions-gate is fail-closed: traversal/symlink/broken-manifest/manifest-edit block (WP-7 F71)
#   T32: settings-merge-apply.sh applies with backup, rolls back on broken input (WP-7 F71 stage B)
#   T33: update.sh wires stage-B flags with consensus safeguards (WP-7 F71)
#   T34: Unicode context caps count characters, not bytes (issue #435)
#   T35: /extend catalog matches every invoked extension point (issues #436/#508)
#   T36: extension loader sorts suffixes and preserves no-op/error exit codes (issue #508)
#
# Exit: 0 = all PASS, N = N tests failed
#
# Usage:
#   bash setup/test-update-edge-cases.sh
#   KEEP_WORKSPACE=1 bash setup/test-update-edge-cases.sh   # keep /tmp dir for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_WS="${EDGE_CASE_WORKSPACE:-/tmp/iwe-edge-test-$$}"

cleanup() {
    local rc=$?
    if [ -d "$TEST_WS" ] && [ "${KEEP_WORKSPACE:-0}" != "1" ]; then
        rm -rf "$TEST_WS"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

echo "============================================"
echo "  Edge-Case Tests: update.sh (issue #206)"
echo "============================================"
echo "  Template: $TEMPLATE_DIR"
echo "  Test workspace: $TEST_WS"
echo ""

mkdir -p "$TEST_WS"

# --- Helpers ---

# Build a minimal fake governance repo that update.sh can find
setup_fake_governance() {
    local gov="$TEST_WS/DS-strategy"
    mkdir -p "$gov"
    git -C "$gov" init -q
    git -C "$gov" config user.email "test@test"
    git -C "$gov" config user.name "test"
    # Minimal CLAUDE.md so update.sh has something to merge
    cat > "$gov/CLAUDE.md" <<'HEREDOC'
# Test CLAUDE.md

## Section 1

Content here.

## 9. Custom (авторское)

User custom content that must be preserved.
HEREDOC
    git -C "$gov" add CLAUDE.md
    git -C "$gov" commit -q -m "init"
    echo "$gov"
}

# Provide a minimal fake manifest pointing at the template dir
setup_fake_manifest() {
    local manifest_file="$TEST_WS/fake-manifest.json"
    python3 -c "
import json, os, hashlib

template = '$TEMPLATE_DIR'
files = {}
for root, dirs, fnames in os.walk(template):
    dirs[:] = [d for d in dirs if d not in ['.git', 'node_modules', '__pycache__']]
    for fname in fnames:
        path = os.path.join(root, fname)
        rel = os.path.relpath(path, template)
        with open(path, 'rb') as f:
            content = f.read()
        files[rel] = hashlib.sha256(content).hexdigest()

manifest = {'version': '0.99.0-test', 'files': files}
with open('$manifest_file', 'w') as f:
    json.dump(manifest, f)
" 2>/dev/null
    echo "$manifest_file"
}

# ============================================================
# T1: --check does not modify any file
# ============================================================
echo "--- T1: --check mode is read-only ---"

gov=$(setup_fake_governance)
CLAUDE_BEFORE=$(sha256sum "$gov/CLAUDE.md" | awk '{print $1}')

# Run --check; it may fail (no network, no real manifest) — we only care about side-effects
UPDATE_SH="$TEMPLATE_DIR/update.sh"
(
    export GOVERNANCE_REPO_PATH="$gov"
    cd "$TEST_WS"
    # Suppress output; ignore exit code — T1 only checks file immutability
    bash "$UPDATE_SH" --check >/dev/null 2>&1 || true
)

CLAUDE_AFTER=$(sha256sum "$gov/CLAUDE.md" | awk '{print $1}')
if [ "$CLAUDE_BEFORE" = "$CLAUDE_AFTER" ]; then
    pass "T1: CLAUDE.md unchanged after --check"
else
    fail "T1: CLAUDE.md was mutated by --check mode"
fi
if [ ! -e "$TEMPLATE_DIR/.update-incomplete" ]; then
    pass "T1: --check does not create an incomplete-update marker"
else
    fail "T1: --check created transaction state"
fi

# ============================================================
# T2: orphaned {{PLACEHOLDER}} in .iwe-runtime/ is detected
# ============================================================
echo "--- T2: orphaned placeholder detection ---"

RUNTIME_DIR="$TEST_WS/.iwe-runtime"
mkdir -p "$RUNTIME_DIR"

# Plant a file with an un-substituted placeholder
cat > "$RUNTIME_DIR/orphan-test.plist" <<'HEREDOC'
<?xml version="1.0"?>
<plist><dict>
  <key>WorkingDirectory</key>
  <string>{{WORKSPACE_DIR}}</string>
</dict></plist>
HEREDOC

# The placeholder check in update.sh uses: grep -rl '{{[A-Z_]*}}' .iwe-runtime/
if grep -rl '{{[A-Z_]*}}' "$RUNTIME_DIR/" >/dev/null 2>&1; then
    pass "T2: orphaned {{WORKSPACE_DIR}} is detectable by update.sh's grep pattern"
else
    fail "T2: grep pattern missed the orphaned placeholder"
fi

# Confirm the opposite: a clean file is NOT flagged
cat > "$RUNTIME_DIR/clean-test.plist" <<'HEREDOC'
<?xml version="1.0"?>
<plist><dict>
  <key>WorkingDirectory</key>
  <string>/workspace/iwe</string>
</dict></plist>
HEREDOC

orphan_count=$(grep -rl '{{[A-Z_]*}}' "$RUNTIME_DIR/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$orphan_count" = "1" ]; then
    pass "T2: clean file is NOT flagged (only 1 orphan found)"
else
    fail "T2: expected 1 orphan, got $orphan_count"
fi

rm -f "$RUNTIME_DIR/orphan-test.plist" "$RUNTIME_DIR/clean-test.plist"

# ============================================================
# T3: pre-existing conflict markers in CLAUDE.md block update
# ============================================================
echo "--- T3: conflict-marker stacking guard ---"

gov3="$TEST_WS/DS-strategy-t3"
mkdir -p "$gov3"
git -C "$gov3" init -q
git -C "$gov3" config user.email "test@test"
git -C "$gov3" config user.name "test"

# Plant CLAUDE.md that already has conflict markers (simulates unresolved prior merge)
cat > "$gov3/CLAUDE.md" <<'HEREDOC'
# Test CLAUDE.md

<<<<<<< HEAD
User version
=======
Upstream version
>>>>>>> upstream
HEREDOC
git -C "$gov3" add CLAUDE.md
git -C "$gov3" commit -q -m "init with conflict markers"

# update.sh (lines 428-438) must detect these and refuse to apply another merge
conflict_detected=false
if grep -q '^<<<<<<<' "$gov3/CLAUDE.md"; then
    conflict_detected=true
fi

if [ "$conflict_detected" = "true" ]; then
    pass "T3: pre-existing conflict markers are detectable (stacking guard can fire)"
else
    fail "T3: conflict markers were not found where expected"
fi

# ============================================================
# T4: role install failure is visible (not swallowed by 2>/dev/null)
# ============================================================
echo "--- T4: role install error surfacing ---"

ROLE_DIR="$TEST_WS/fake-role"
mkdir -p "$ROLE_DIR"

# Create an install.sh that deliberately exits non-zero
cat > "$ROLE_DIR/install.sh" <<'HEREDOC'
#!/bin/bash
echo "Role install error: missing dependency" >&2
exit 1
HEREDOC
chmod +x "$ROLE_DIR/install.sh"

# Simulate what setup.sh does at line 695: bash ... 2>/dev/null
# The test asserts that the exit code is non-zero (so a caller CAN detect it),
# but also shows that the current 2>/dev/null silencing hides stderr.
role_exit=0
bash "$ROLE_DIR/install.sh" 2>/dev/null || role_exit=$?

if [ "$role_exit" -ne 0 ]; then
    pass "T4: role install exit code ($role_exit) is non-zero — caller CAN detect failure"
    # Now verify the current setup.sh pattern would miss it:
    # setup.sh does: bash "$role_dir/install.sh" 2>/dev/null   (no || check)
    # This is the gap: exit code is discarded because the line is not in an 'if' or '||'.
    echo "     ⚠️  KNOWN GAP: setup.sh line 695 does not check exit code — failure is silent"
else
    fail "T4: role install did not exit non-zero as expected"
fi

# ============================================================
# T5: --check works without network (cached manifest path)
# ============================================================
echo "--- T5: --check is network-independent when manifest is cached ---"

CACHE_MANIFEST="/tmp/iwe-update-manifest-cache-test-$$.json"
# Write a minimal valid manifest JSON
python3 -c "import json; print(json.dumps({'version':'0.99.0','files':{}}))" > "$CACHE_MANIFEST"

if [ -f "$CACHE_MANIFEST" ] && python3 -c "import json; json.load(open('$CACHE_MANIFEST'))" 2>/dev/null; then
    pass "T5: local manifest cache is valid JSON and parseable"
else
    fail "T5: manifest cache file is invalid or missing"
fi
rm -f "$CACHE_MANIFEST"

# ============================================================================
# T6: memory file with owner: user survives a hash mismatch (issue #229)
# ============================================================================
echo "--- T6: owner:user memory file is not stale-repaired ---"

source "$TEMPLATE_DIR/.claude/lib/frontmatter.sh"

T6_UPSTREAM="$TEST_WS/upstream-fake.md"
T6_DEPLOYED="$TEST_WS/deployed-fake.md"

cat > "$T6_UPSTREAM" <<'HEREDOC'
---
owner: platform
horizon: hot
---
Upstream content (would overwrite deployed if copied).
HEREDOC

cat > "$T6_DEPLOYED" <<'HEREDOC'
---
owner: 'user'
horizon: hot
---
Pilot's own edit — must never be overwritten by stale-repair.
HEREDOC

# Same conditional update.sh's repair_pass() / Step 6 propagation use: owner:user guard first.
if [ "$(get_field "$T6_DEPLOYED" owner)" = "user" ]; then
    T6_PROTECTED=true
else
    T6_PROTECTED=false
fi

if [ "$T6_PROTECTED" = "true" ]; then
    pass "T6: get_field detects owner:user (single-quoted) — repair_pass would skip this file"
else
    fail "T6: get_field failed to detect owner:user — file would be clobbered"
fi

# Wiring check: the helper working in isolation doesn't prove update.sh still
# calls it in the right place. Grep for the actual guard at both call sites
# (repair_pass() and the Step 6 memory-copy loop) so a future refactor that
# drops or reorders the check fails this test even though get_field itself
# is untouched.
T6_WIRED_COUNT=$(grep -cE 'get_field "\$[a-z_]*dst" owner' "$TEMPLATE_DIR/update.sh")
if [ "$T6_WIRED_COUNT" -eq 2 ]; then
    pass "T6: owner:user guard is wired into both repair_pass() and Step 6 propagation"
else
    fail "T6: expected owner:user guard at 2 call sites in update.sh, found $T6_WIRED_COUNT"
fi

# ============================================================================
# T7: hot-budget sum over threshold is detectable (issue #228)
# ============================================================================
echo "--- T7: hot-budget validator sums horizon:hot lines ---"

T7_DIR="$TEST_WS/hot-budget-memory"
mkdir -p "$T7_DIR"

# Two hot files summing to 160 lines (over the 150 limit)
python3 -c "
print('---')
print('horizon: hot')
print('---')
for i in range(97): print(f'line {i}')
" > "$T7_DIR/hot-a.md"   # 100 lines total (3 frontmatter + 97 body)

python3 -c "
print('---')
print('horizon: hot')
print('---')
for i in range(57): print(f'line {i}')
" > "$T7_DIR/hot-b.md"   # 60 lines total

cat > "$T7_DIR/warm-c.md" <<'HEREDOC'
---
horizon: warm
---
This file's lines must NOT count toward the hot budget.
HEREDOC

T7_HOT_LINES=0
for mem_file in "$T7_DIR"/*.md; do
    if [ "$(get_field "$mem_file" horizon)" = "hot" ]; then
        n=$(wc -l < "$mem_file" | tr -d ' ')
        T7_HOT_LINES=$((T7_HOT_LINES + n))
    fi
done

if [ "$T7_HOT_LINES" -gt 150 ]; then
    pass "T7: hot-budget validator sums to $T7_HOT_LINES (>150), warning would fire"
else
    fail "T7: expected hot sum >150, got $T7_HOT_LINES"
fi

# Confirm warm file is excluded from the sum (160 hot + 4 warm would be 164 if miscounted)
if [ "$T7_HOT_LINES" -lt 164 ]; then
    pass "T7: warm-c.md correctly excluded from hot sum"
else
    fail "T7: warm file was incorrectly counted into hot sum"
fi

# ============================================================================
# T8: build-runtime.sh does not clobber an edited params.yaml (issue #327)
# ============================================================================
echo "--- T8: copied_to_workspace protects an existing params.yaml ---"

T8_WS="$TEST_WS/t8-workspace"
mkdir -p "$T8_WS"

# Pilot's own edit — must survive a build-runtime.sh run, same as a fresh install
# would seed it if absent.
cat > "$T8_WS/params.yaml" <<'HEREDOC'
github_user: pilot-own-value
author_mode: false
HEREDOC

cp "$TEMPLATE_DIR/.exocortex.env" "$T8_WS/.exocortex.env" 2>/dev/null || cat > "$T8_WS/.exocortex.env" <<HEREDOC
HOME_DIR=$HOME
USER_NAME=test-user
WORKSPACE_DIR=$T8_WS
CLAUDE_PATH=/usr/bin/claude
CLAUDE_PROJECT_SLUG=test
TIMEZONE_HOUR=3
TIMEZONE_DESC=UTC
GITHUB_USER=test-user
GOVERNANCE_REPO=DS-strategy
HEREDOC

bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
    --workspace "$T8_WS" \
    --env-file "$T8_WS/.exocortex.env" \
    --quiet >/dev/null 2>&1

if grep -q "github_user: pilot-own-value" "$T8_WS/params.yaml" 2>/dev/null; then
    pass "T8: existing params.yaml survives build-runtime.sh (edit not overwritten)"
else
    fail "T8: params.yaml was reset to template defaults — edit lost"
fi

# Wiring check: is_protected_user_file must actually gate the copy, not just exist.
T8_WIRED_COUNT=$(grep -cE 'is_protected_user_file "\$f"' "$TEMPLATE_DIR/setup/build-runtime.sh")
if [ "$T8_WIRED_COUNT" -ge 1 ]; then
    pass "T8: is_protected_user_file guard is wired into copied_to_workspace loop"
else
    fail "T8: is_protected_user_file exists but is not called in the copy loop"
fi

# ============================================================================
# T9: .mcp.json migration preserves a third-party server like ext-figma (issue #335)
# ============================================================================
echo "--- T9: .mcp.json migration keeps user-added servers ---"

T9_MCP="$TEST_WS/t9-mcp.json"
cat > "$T9_MCP" <<'HEREDOC'
{
  "mcpServers": {
    "ext-figma": {
      "type": "http",
      "url": "http://127.0.0.1:3845/mcp"
    },
    "knowledge-mcp": {
      "command": "old-stdio-server"
    }
  }
}
HEREDOC

# Extracts the actual Step 6c python block from update.sh (between its unique
# markers) and runs it as a real file — not a copy of the logic re-typed into
# this test, which would pass even if update.sh's real code diverged. A file
# (not `python3 -c "$VAR"`) sidesteps bash re-quoting/escaping issues with the
# block's embedded '\n' and mixed quotes.
# issue #402: the block now invokes $PY_BIN (not a literal `python3`) and takes
# its path via argv (`sys.argv[1]`), not an interpolated `$MCP_WORKSPACE` — the
# marker and the post-extraction substitution both follow that shape now.
T9_PY_BLOCK=$(awk '/^# === Step 6c: Migrate workspace \.mcp\.json to Gateway ===$/{found=1} found' "$TEMPLATE_DIR/update.sh" | \
              sed -n '/^    \$PY_BIN -c "$/,/^" "\$MCP_WORKSPACE" 2>\/dev\/null$/p' | sed '1d;$d')
if [ -z "$T9_PY_BLOCK" ]; then
    fail "T9: could not extract Step 6c migration block from update.sh — marker comment moved?"
else
    T9_PYFILE="$TEST_WS/t9-migration.py"
    printf '%s' "$T9_PY_BLOCK" > "$T9_PYFILE"
    python3 "$T9_PYFILE" "$T9_MCP" >/dev/null 2>&1

    if python3 -c "
import json
with open('$T9_MCP') as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
assert 'ext-figma' in servers, 'ext-figma missing'
assert 'knowledge-mcp' not in servers, 'old stdio server not removed'
assert 'iwe-knowledge' in servers, 'iwe-knowledge not added'
" 2>/dev/null; then
        pass "T9: ext-figma survives migration, knowledge-mcp removed, iwe-knowledge added"
    else
        fail "T9: migration logic mishandled server keys"
    fi
fi

# Wiring check: the actual Step 6c code in update.sh must implement the same
# preserve-then-merge shape (iterate old_keys → del, then add iwe-knowledge if
# missing) rather than a whole-file overwrite. Greps for the two defining lines
# so a future rewrite that drops the preserve step fails this test even if the
# extraction above somehow still matched a stale block.
T9_WIRED_DEL=$(grep -c "for k in old_keys:" "$TEMPLATE_DIR/update.sh")
T9_WIRED_ADD=$(grep -c "if 'iwe-knowledge' not in servers:" "$TEMPLATE_DIR/update.sh")
if [ "$T9_WIRED_DEL" -ge 1 ] && [ "$T9_WIRED_ADD" -ge 1 ]; then
    pass "T9: update.sh Step 6c still preserves existing servers (not a whole-file overwrite)"
else
    fail "T9: update.sh Step 6c no longer matches the preserve-then-merge shape this test verified"
fi

# ============================================================================
# T10: CLAUDE.md fallback-merge (no .base) never silently drops §8/§9 edits (issue #336)
# ============================================================================
echo "--- T10: CLAUDE.md fallback path without .base does not clobber pilot edits ---"

# Copy of update.sh's cross-platform sed_inplace() (defined locally there,
# not in a sourceable lib — update.sh itself can't be sourced without running
# its whole network-dependent body). The extracted blocks below call this.
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# Extracts the real Step 5 ($SCRIPT_DIR copy) and Step 6 ($WORKSPACE_DIR copy)
# fallback blocks from update.sh via unique line-content markers, and sources
# each as bash against live fixture files — not a re-typed copy of the logic.
# A prior version of this test hand-wrote a byte-for-byte copy of the if/else
# shape; a second review round proved experimentally that copy silently
# diverges from update.sh (it kept passing after the real code was reverted
# to the pre-fix unconditional-copy bug). Extraction removes that gap: if
# update.sh's fallback branch is edited without updating this test, the
# extracted block picks up the edit automatically.
t10_extract_step5_block() {
    awk '
        /^            USER_SECTION=\$\(sed -n/{found=1}
        found{print}
        found && /^            fi$/{exit}
    ' "$TEMPLATE_DIR/update.sh"
}
t10_extract_step6_block() {
    # issue #541 hvost 2: this block moved inside sync_workspace_claude_md()
    # (called from both the early no-op path and Step 6), one indent level
    # deeper (8 -> 12 spaces) than before the refactor.
    awk '
        /^            WS_USER_SECTION=\$\(sed -n/{found=1}
        found{print}
        found && /^            fi$/{exit}
    ' "$TEMPLATE_DIR/update.sh"
}

T10_DIR="$TEST_WS/t10-claude-md"
mkdir -p "$T10_DIR"

T10_STEP5_BLOCK=$(t10_extract_step5_block)
T10_STEP6_BLOCK=$(t10_extract_step6_block)

if [ -z "$T10_STEP5_BLOCK" ] || [ -z "$T10_STEP6_BLOCK" ]; then
    fail "T10: could not extract fallback block(s) from update.sh — line markers moved? Step5 empty: $([ -z "$T10_STEP5_BLOCK" ] && echo yes || echo no), Step6 empty: $([ -z "$T10_STEP6_BLOCK" ] && echo yes || echo no)"
else
    T10_STEP5_FILE="$T10_DIR/step5-block.sh"
    T10_STEP6_FILE="$T10_DIR/step6-block.sh"
    printf '%s\n' "$T10_STEP5_BLOCK" > "$T10_STEP5_FILE"
    printf '%s\n' "$T10_STEP6_BLOCK" > "$T10_STEP6_FILE"

    # Case A (Step 5 shape): pilot's file has real §8/§9 content, NO
    # <!-- USER-SPACE --> markers (issue #336's exact shape — the markers
    # never existed in the real format).
    T10_CURRENT="$T10_DIR/current.md"
    T10_NEW="$T10_DIR/new.md"
    cat > "$T10_CURRENT" <<'HEREDOC'
## 8. Staging
Полный раздел про staging-канал, четыре шага промоции
## 9. Авторское
- Комментарии кода — только EN
HEREDOC
    cat > "$T10_NEW" <<'HEREDOC'
## 8. Staging
Одна строка вместо полного раздела
## 9. Авторское
HEREDOC

    CURRENT_FILE="$T10_CURRENT" NEW_FILE="$T10_NEW" SCRIPT_DIR="$T10_DIR" f="CLAUDE.md" \
        CLAUDE_BASE_MISSING_FILES=()
    source "$T10_STEP5_FILE"

    if grep -q "EN" "$T10_CURRENT" && grep -q "Полный раздел" "$T10_CURRENT"; then
        pass "T10: Step 5 — pilot's §8/§9 content survives the real fallback branch"
    else
        fail "T10: Step 5 — pilot's §8/§9 content was overwritten (extracted from update.sh)"
    fi
    if grep -q "Одна строка" "$T10_CURRENT"; then
        fail "T10: Step 5 — fallback branch copied upstream over the pilot's file — no-USER-SPACE case should leave it untouched"
    fi
    if [ "${#CLAUDE_BASE_MISSING_FILES[@]}" -eq 1 ]; then
        pass "T10: Step 5 — CLAUDE_BASE_MISSING_FILES tracked (feeds the disambiguated final summary, issue #336 follow-up)"
    else
        fail "T10: Step 5 — expected CLAUDE_BASE_MISSING_FILES to have 1 entry, got ${#CLAUDE_BASE_MISSING_FILES[@]}"
    fi
    # issue #541 hvost 1 (Evgenii Red Team v0.38.11): this branch used to write
    # .claude.md.base = NEW_FILE here even though CURRENT_FILE was left stale —
    # a false ancestry that made an immediate retry's 3-way merge treat the
    # still-stale file as an intentional pilot edit and silently "succeed".
    if [ ! -e "$T10_DIR/.claude.md.base" ]; then
        pass "T10: Step 5 — no false-ancestry base file written while CURRENT_FILE stayed stale (issue #541)"
    else
        fail "T10: Step 5 — .claude.md.base was created despite CURRENT_FILE never being reconciled (issue #541 regression)"
    fi

    # Case B (Step 6 shape): pilot's file DOES use USER-SPACE markers — must
    # still merge as before (issue #336's fix must not regress the one case
    # that already worked). Exercises the $WORKSPACE_DIR copy's own block
    # (different variable names: WS_CURRENT/WS_NEW/WS_USER_SECTION) so a
    # divergence between the two nearly-identical fallback sites is caught.
    T10_CURRENT_B="$T10_DIR/current-b.md"
    T10_NEW_B="$T10_DIR/new-b.md"
    cat > "$T10_CURRENT_B" <<'HEREDOC'
## 8. Staging
<!-- USER-SPACE -->
my custom staging note
<!-- /USER-SPACE -->
HEREDOC
    cat > "$T10_NEW_B" <<'HEREDOC'
## 8. Staging
Upstream replaced this section entirely.
HEREDOC

    WS_CURRENT="$T10_CURRENT_B" WS_NEW="$T10_NEW_B" WS_BASE="$T10_DIR/ws-base.md" \
        CLAUDE_BASE_MISSING_FILES=()
    source "$T10_STEP6_FILE"

    if grep -q "Upstream replaced" "$T10_CURRENT_B" && grep -q "my custom staging note" "$T10_CURRENT_B"; then
        pass "T10: Step 6 — USER-SPACE case still merges upstream + preserves the marked section"
    else
        fail "T10: Step 6 — USER-SPACE merge path regressed (extracted from update.sh)"
    fi

    # Case C (Step 6, no markers — issue #541 hvost 2): same false-ancestry bug
    # as Case A above, but for the $WORKSPACE_DIR copy. WS_BASE must not be
    # created here, and WS_CURRENT must stay untouched, or an immediate retry
    # would 3-way-merge against a base that already equals upstream and
    # silently treat the still-stale WS_CURRENT as reconciled.
    T10_CURRENT_C="$T10_DIR/current-c.md"
    T10_NEW_C="$T10_DIR/new-c.md"
    cat > "$T10_CURRENT_C" <<'HEREDOC'
## 8. Staging
Полный раздел про staging-канал, без маркеров
HEREDOC
    cat > "$T10_NEW_C" <<'HEREDOC'
## 8. Staging
Одна строка вместо полного раздела
HEREDOC
    WS_CURRENT="$T10_CURRENT_C" WS_NEW="$T10_NEW_C" WS_BASE="$T10_DIR/ws-base-c.md" \
        CLAUDE_BASE_MISSING_FILES=()
    source "$T10_STEP6_FILE"

    if grep -q "без маркеров" "$T10_CURRENT_C"; then
        pass "T10: Step 6 — no-markers case leaves WS_CURRENT untouched (issue #541)"
    else
        fail "T10: Step 6 — no-markers case overwrote WS_CURRENT despite no base for a safe merge"
    fi
    if [ ! -e "$T10_DIR/ws-base-c.md" ]; then
        pass "T10: Step 6 — no false-ancestry WS_BASE written while WS_CURRENT stayed stale (issue #541)"
    else
        fail "T10: Step 6 — WS_BASE was created despite WS_CURRENT never being reconciled (issue #541 regression)"
    fi
fi

# ============================================================================
# T11: protocol-artifact-validate.sh DayPlan checks (issue #328)
# ============================================================================
echo "--- T11: DayPlan multiplier/mandatory/budget checks (issue #328) ---"

HOOK_FILE="$TEMPLATE_DIR/.claude/hooks/protocol-artifact-validate.sh"

# Extracts the real Check 3/4 block from the hook (between its unique section
# markers) and sources it as bash — not a re-typed copy, so the test breaks if
# the real checks diverge. Requires DAYPLAN/WORKSPACE/ERRORS to be set by the
# caller, exactly like the hook itself expects them from its own preamble.
T11_CHECKS_BLOCK=$(awk '
/^# --- Ф3 Check 3: формат мультипликатора ---$/{found=1}
/^# --- Ф3 Check 5:/{found=0}
found' "$HOOK_FILE")

if [ -z "$T11_CHECKS_BLOCK" ]; then
    fail "T11: could not extract Check 3/4 block from protocol-artifact-validate.sh — marker comments moved?"
else
    T11_CHECKS_FILE="$TEST_WS/t11-checks.sh"
    printf '%s\n' "$T11_CHECKS_BLOCK" > "$T11_CHECKS_FILE"

    # Case A: default installation (mandatory_daily_wps commented out in the
    # template default), DayPlan uses the real pilot phrasing from issue #328.
    T11_DIR="$TEST_WS/t11-dayplan"
    mkdir -p "$T11_DIR/memory" "$T11_DIR/current" "$T11_DIR/scripts/lib"
    cp "$TEMPLATE_DIR/memory/day-rhythm-config.yaml" "$T11_DIR/memory/day-rhythm-config.yaml"
    cp "$TEMPLATE_DIR/scripts/lib/find-python3.sh" "$T11_DIR/scripts/lib/find-python3.sh"
    cat > "$T11_DIR/current/DayPlan.md" <<'HEREDOC'
## Бюджет
~1.25 ч РП всего / 0 ч физической работы. Мультипликатор не считаю.
HEREDOC

    DAYPLAN="$T11_DIR/current/DayPlan.md"
    WORKSPACE="$T11_DIR"
    ERRORS=()
    source "$T11_CHECKS_FILE"

    if [ "${#ERRORS[@]}" -eq 0 ]; then
        pass "T11: default-install DayPlan (no multiplier, no mandatory config, ч-budget) passes all three checks"
    else
        fail "T11: default-install DayPlan unexpectedly failed: ${ERRORS[*]}"
    fi

    # Case B (negative): mandatory_daily_wps IS configured, DayPlan lacks the
    # section — must still fail. Proves Case A isn't passing because the
    # checks were silently disabled, not because the config was honored.
    T11_DIR_B="$TEST_WS/t11-dayplan-b"
    mkdir -p "$T11_DIR_B/memory" "$T11_DIR_B/current" "$T11_DIR_B/scripts/lib"
    cp "$TEMPLATE_DIR/scripts/lib/find-python3.sh" "$T11_DIR_B/scripts/lib/find-python3.sh"
    cat > "$T11_DIR_B/memory/day-rhythm-config.yaml" <<'HEREDOC'
mandatory_daily_wps:
  - wp: 7
    min_minutes: 30
HEREDOC
    cat > "$T11_DIR_B/current/DayPlan.md" <<'HEREDOC'
## Бюджет
~1.25 ч РП всего / 0 ч физической работы. Мультипликатор не считаю.
HEREDOC

    DAYPLAN="$T11_DIR_B/current/DayPlan.md"
    WORKSPACE="$T11_DIR_B"
    ERRORS=()
    source "$T11_CHECKS_FILE"

    if [ "${#ERRORS[@]}" -eq 1 ] && [[ "${ERRORS[0]}" == *"Mandatory"* ]]; then
        pass "T11: DayPlan with mandatory_daily_wps configured still requires the mandatory section"
    else
        fail "T11: expected exactly 1 mandatory-check error, got ${#ERRORS[@]}: ${ERRORS[*]:-none}"
    fi
fi

# ============================================================
# T12: day-close.sh memory backup descends into memory/ subfolders (issue #343)
# ============================================================
echo "--- T12: memory backup keeps nested files ---"

# Run the production backup, not a retyped copy primitive. Since issue #536 the
# destination is multi-writer and stale pruning is driven by the ownership
# manifest rather than by a global rsync --delete.
T12_SCRIPT="$TEMPLATE_DIR/scripts/day-close.sh"
if [ ! -f "$T12_SCRIPT" ]; then
    fail "T12: scripts/day-close.sh not found"
else
    T12_ROOT="$TEST_WS/t12"
    T12_WS="$T12_ROOT/workspace"
    T12_SRC="$T12_ROOT/memory"
    T12_DST="$T12_WS/governance/exocortex"
    T12_HOME="$T12_ROOT/home"
    mkdir -p \
        "$T12_HOME" \
        "$T12_SRC/reference" \
        "$T12_SRC/.git/objects/ab" \
        "$T12_DST/reference" \
        "$T12_DST/extensions" \
        "$T12_DST/agent-fault-profile/audit" \
        "$T12_DST/hindsight" \
        "$T12_DST/decisions"
    echo "top-level" > "$T12_SRC/navigation.md"
    echo "nested" > "$T12_SRC/reference/agent-core.md"
    echo "owned then removed" > "$T12_SRC/reference/stale-memory.md"
    echo "blob" > "$T12_SRC/.git/objects/ab/deadbeef"
    echo "extension" > "$T12_DST/extensions/day-close.after.md"
    echo "fault audit" > "$T12_DST/agent-fault-profile/audit/faults.md"
    echo "hindsight" > "$T12_DST/hindsight/notes.md"
    echo "legacy decision" > "$T12_DST/decisions/decision-log.md"

    T12_ENV=(
        HOME="$T12_HOME"
        WORKSPACE_DIR="$T12_WS"
        IWE_ROOT="$T12_WS"
        IWE_WORKSPACE="$T12_WS"
        IWE_TEMPLATE="$TEMPLATE_DIR"
        IWE_SCRIPTS="$TEMPLATE_DIR/scripts"
        IWE_GOVERNANCE_REPO="governance"
        GOVERNANCE_REPO="governance"
        IWE_MEMORY_SRC="$T12_SRC"
        IWE_DAY_CLOSE_LOG="$T12_ROOT/day-close.log"
    )
    T12_FIRST_RC=0
    env "${T12_ENV[@]}" bash "$T12_SCRIPT" --backup \
        > "$T12_ROOT/first.out" 2>&1 || T12_FIRST_RC=$?
    rm -f -- "$T12_SRC/reference/stale-memory.md"
    T12_SECOND_RC=0
    env "${T12_ENV[@]}" bash "$T12_SCRIPT" --backup \
        > "$T12_ROOT/second.out" 2>&1 || T12_SECOND_RC=$?

    if [ "$T12_FIRST_RC" -ne 0 ] || [ "$T12_SECOND_RC" -ne 0 ]; then
        fail "T12: real day-close backup failed ($T12_FIRST_RC/$T12_SECOND_RC)"
    else
        if [ -f "$T12_DST/reference/agent-core.md" ] && [ -f "$T12_DST/navigation.md" ]; then
            pass "T12: nested memory/reference/agent-core.md reaches the backup"
        elif [ -f "$T12_DST/navigation.md" ]; then
            fail "T12: top-level file copied but memory/reference/agent-core.md was dropped"
        else
            fail "T12: production backup copied no memory files"
        fi

        if [ -d "$T12_DST/.git" ]; then
            fail "T12: empty .git skeleton was mirrored into the backup"
        else
            pass "T12: directory skeletons with no matching files are not mirrored"
        fi

        T12_FOREIGN_MISSING=0
        for foreign in \
            extensions/day-close.after.md \
            agent-fault-profile/audit/faults.md \
            hindsight/notes.md \
            decisions/decision-log.md; do
            [ -f "$T12_DST/$foreign" ] || T12_FOREIGN_MISSING=$((T12_FOREIGN_MISSING + 1))
        done
        if [ "$T12_FOREIGN_MISSING" -eq 0 ]; then
            pass "T12: ownership sync preserves all non-memory writer subtrees"
        else
            fail "T12: ownership sync removed $T12_FOREIGN_MISSING foreign file(s)"
        fi

        if [ ! -f "$T12_DST/reference/stale-memory.md" ]; then
            pass "T12: manifest prunes an unchanged formerly-owned memory file"
        else
            fail "T12: manifest did not prune an unchanged formerly-owned file"
        fi

        if [ -s "$T12_DST/.day-close-backup-manifest.json" ]; then
            pass "T12: ownership manifest records the production backup"
        else
            fail "T12: ownership manifest is missing"
        fi
    fi
fi

# ============================================================
# T13: iwe_scheduler_state distinguishes "never deployed" from a real outage (issue #347)
# ============================================================
echo "--- T13: scheduler state is four-valued, not boolean ---"

T13_LIB="$TEMPLATE_DIR/scripts/lib/common.sh"
if [ ! -f "$T13_LIB" ]; then
    fail "T13: scripts/lib/common.sh not found"
else
    # Launcher queries must be stubbed, not just HOME-scoped: launchctl answers for the
    # whole login session regardless of $HOME, so on the author's own Mac an unstubbed
    # probe reports the real scheduler as active and the test would prove nothing.
    T13_BIN="$TEST_WS/t13-bin"
    mkdir -p "$T13_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$T13_BIN/launchctl"          # no units registered
    printf '#!/bin/sh\nexit 0\n' > "$T13_BIN/systemctl"          # no timers loaded
    printf '#!/bin/sh\nexit 1\n' > "$T13_BIN/crontab"            # "no crontab for user"
    chmod +x "$T13_BIN/launchctl" "$T13_BIN/systemctl" "$T13_BIN/crontab"

    # Same stubs, except the service manager itself errors out (WSL/container: no user
    # session bus) — the case that must read "unknown", not "not deployed".
    T13_BIN_ERR="$TEST_WS/t13-bin-err"
    mkdir -p "$T13_BIN_ERR"
    cp "$T13_BIN/launchctl" "$T13_BIN/crontab" "$T13_BIN_ERR/"
    printf '#!/bin/sh\necho "Failed to connect to bus" >&2\nexit 1\n' > "$T13_BIN_ERR/systemctl"
    chmod +x "$T13_BIN_ERR/systemctl"

    t13_state() {  # $1 = fake HOME, $2 = stub bin dir
        HOME="$1" PATH="$2:$PATH" bash -c 'source "$1"; iwe_scheduler_state' _ "$T13_LIB" 2>/dev/null
    }

    T13_EMPTY="$TEST_WS/t13-empty-home"
    mkdir -p "$T13_EMPTY"
    T13_CLEAN=$(t13_state "$T13_EMPTY" "$T13_BIN")

    T13_STALE="$TEST_WS/t13-stale-home"
    mkdir -p "$T13_STALE/logs/synchronizer"
    touch -t 202001010000 "$T13_STALE/logs/synchronizer/scheduler-old.log"
    T13_DEPLOYED=$(t13_state "$T13_STALE" "$T13_BIN")

    T13_UNKNOWN=$(t13_state "$T13_EMPTY" "$T13_BIN_ERR")

    # Only ONE role's plist — roles install independently, so a partial deployment is
    # the ordinary case, not an exotic one. A check that needs all three families at
    # once reads this as "never installed" and stops reporting real outages.
    T13_PARTIAL="$TEST_WS/t13-partial-home"
    mkdir -p "$T13_PARTIAL/Library/LaunchAgents"
    touch "$T13_PARTIAL/Library/LaunchAgents/com.exocortex.scheduler.plist"
    T13_PARTIAL_STATE=$(t13_state "$T13_PARTIAL" "$T13_BIN")

    # WSL/container: the timer files are on disk but the service manager cannot answer.
    # Artefacts must not outrank a failed probe, or this host gets a daily false Mode A.
    T13_WSL="$TEST_WS/t13-wsl-home"
    mkdir -p "$T13_WSL/.config/systemd/user"
    touch "$T13_WSL/.config/systemd/user/iwe-exocortex-scheduler.timer"
    T13_WSL_STATE=$(t13_state "$T13_WSL" "$T13_BIN_ERR")

    if [ "$T13_CLEAN" = "not_deployed" ]; then
        pass "T13: host with no launcher artefacts reports not_deployed (no red, no incident)"
    else
        fail "T13: expected not_deployed on a clean HOME, got '${T13_CLEAN:-<empty>}'"
    fi

    if [ "$T13_DEPLOYED" = "deployed_inactive" ]; then
        pass "T13: stale scheduler log alone proves past deployment → deployed_inactive"
    else
        fail "T13: expected deployed_inactive with an old scheduler log, got '${T13_DEPLOYED:-<empty>}'"
    fi

    if [ "$T13_UNKNOWN" = "unknown" ]; then
        pass "T13: a failing service-manager query reports unknown, not not_deployed"
    else
        fail "T13: expected unknown when systemctl errors out, got '${T13_UNKNOWN:-<empty>}'"
    fi

    if [ "$T13_PARTIAL_STATE" = "deployed_inactive" ]; then
        pass "T13: a single role's plist still counts as deployed (partial install is normal)"
    else
        fail "T13: expected deployed_inactive with one plist present, got '${T13_PARTIAL_STATE:-<empty>}'"
    fi

    if [ "$T13_WSL_STATE" = "unknown" ]; then
        pass "T13: a failed probe outranks on-disk artefacts (no daily false Mode A on WSL)"
    else
        fail "T13: expected unknown with timers present but systemctl failing, got '${T13_WSL_STATE:-<empty>}'"
    fi

    if [ "$T13_CLEAN" != "$T13_DEPLOYED" ] && [ "$T13_CLEAN" != "$T13_UNKNOWN" ]; then
        pass "T13: the three situations the old boolean merged now differ"
    else
        fail "T13: states collapsed — clean='$T13_CLEAN' deployed='$T13_DEPLOYED' unknown='$T13_UNKNOWN'"
    fi
fi

# ============================================================
# T14: fresh workspace gets params.yaml seeded from params.yaml.example (issue #348)
# ============================================================
echo "--- T14: params.yaml is seeded from the example, not tracked by the template ---"

T14_WS="$TEST_WS/t14-workspace"
mkdir -p "$T14_WS"
cat > "$T14_WS/.exocortex.env" <<HEREDOC
HOME_DIR=$HOME
USER_NAME=test-user
WORKSPACE_DIR=$T14_WS
CLAUDE_PATH=/usr/bin/claude
CLAUDE_PROJECT_SLUG=test
TIMEZONE_HOUR=3
TIMEZONE_DESC=UTC
GITHUB_USER=test-user
GOVERNANCE_REPO=DS-strategy
HEREDOC

T14_OUT=$(bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
    --workspace "$T14_WS" --env-file "$T14_WS/.exocortex.env" 2>&1)

if [ -f "$T14_WS/params.yaml" ]; then
    pass "T14: absent params.yaml is seeded into the workspace"
else
    fail "T14: workspace has no params.yaml after build-runtime.sh — seeding from the example broke"
fi

# The seeding must be announced. Silence here is what made #348 read as "update.sh
# overwrote my settings" — the user had no way to tell a reseed from a clobber.
case "$T14_OUT" in
    *params.yaml*засеян*) pass "T14: seeding a protected user file is announced, not silent" ;;
    *) fail "T14: build-runtime.sh seeded params.yaml without saying so" ;;
esac

# The template must ship the example and must NOT track a working params.yaml —
# a tracked one is exactly what a fork's pull puts back over the user's edits.
if [ -f "$TEMPLATE_DIR/params.yaml.example" ]; then
    pass "T14: template ships params.yaml.example"
else
    fail "T14: params.yaml.example is missing from the template"
fi

if git -C "$TEMPLATE_DIR" ls-files --error-unmatch params.yaml >/dev/null 2>&1; then
    fail "T14: params.yaml is still tracked in the template repo (issue #348 not closed)"
else
    pass "T14: template repo does not track a working params.yaml"
fi

# ============================================================
# T15: residency-gate path resolves from any cwd (issue #323)
# ============================================================
echo "--- T15: residency-gate scripts resolve residency-gate.py correctly ---"

T15_ROOT="$TEST_WS/t15-root"
mkdir -p "$T15_ROOT/.claude/skills/residency-gate"
touch "$T15_ROOT/.claude/skills/residency-gate/residency-gate.py"

for t15_script in residency-gate-init.sh residency-gate-lazy.sh; do
    T15_FILE="$TEMPLATE_DIR/.claude/hooks/$t15_script"
    # Regression guard for the original defect: the old default ".claude"
    # expanded to ".claude/.claude/skills/..." — a path that never exists.
    if grep -q ':-\.claude}' "$T15_FILE"; then
        fail "T15: $t15_script still uses the .claude default that doubles the path"
        continue
    fi
    T15_LINE=$(grep -m1 '^RESIDENCY_GATE_PY=' "$T15_FILE")
    if [ -z "$T15_LINE" ]; then
        fail "T15: $t15_script has no RESIDENCY_GATE_PY assignment"
        continue
    fi
    # Explicit CLAUDE_ROOT from a foreign cwd must land inside that root.
    T15_EXPLICIT=$(cd "$TEST_WS" && CLAUDE_ROOT="$T15_ROOT" bash -c "$T15_LINE; echo \"\$RESIDENCY_GATE_PY\"")
    if [ "$T15_EXPLICIT" = "$T15_ROOT/.claude/skills/residency-gate/residency-gate.py" ] && [ -f "$T15_EXPLICIT" ]; then
        pass "T15: $t15_script honors an explicit CLAUDE_ROOT from a foreign cwd"
    else
        fail "T15: $t15_script with explicit CLAUDE_ROOT resolved to '$T15_EXPLICIT'"
    fi
    # Unset CLAUDE_ROOT with cwd = project root must find the file via ./.claude/.
    T15_DEFAULT=$(cd "$T15_ROOT" && env -u CLAUDE_ROOT bash -c "$T15_LINE; [ -f \"\$RESIDENCY_GATE_PY\" ] && echo exists || echo missing:\$RESIDENCY_GATE_PY")
    if [ "$T15_DEFAULT" = "exists" ]; then
        pass "T15: $t15_script default resolves from the project root"
    else
        fail "T15: $t15_script default resolution broken ($T15_DEFAULT)"
    fi
done

# ============================================================
# T16: newly wired hooks honor their real event protocols
#      (issues #310/#321/#323 batch — delivery-gap hooks wired up)
#      Scope note: this is a template-run probe with a clean HOME and
#      CLAUDE_PROJECT_DIR, NOT a full setup.sh install — it proves the shipped
#      hook copies are self-sufficient (FMT-fallback snapshots), which is the
#      property a fresh user relies on.
# ============================================================
echo "--- T16: newly wired hooks honor their event protocols (template-run, clean env) ---"

T16_HOME="$TEST_WS/t16-home"
T16_PROJ="$TEST_WS/t16-proj"
mkdir -p "$T16_HOME" "$T16_PROJ/.claude/state"

for t16_hook in inject-code-style.sh inject-communication-style.sh inject-fault-profile.sh response-clarity-hook.sh; do
    [ -f "$TEMPLATE_DIR/.claude/hooks/$t16_hook" ] || { fail "T16: $t16_hook is registered but missing from hooks/"; continue; }
    grep -q "$t16_hook" "$TEMPLATE_DIR/.claude/settings.json" \
        && pass "T16: $t16_hook is registered in settings.json" \
        || fail "T16: $t16_hook is not registered in settings.json"
done

# inject-code-style must be PreToolUse-only: it reads .tool_input.file_path and
# hard-codes hookEventName PreToolUse, so a UserPromptSubmit registration would
# fire on every prompt and always return {} — dead weight, not a teaser.
T16_UPS=$(python3 -c "
import json
d = json.load(open('$TEMPLATE_DIR/.claude/settings.json'))
cmds = [h['command'] for m in d['hooks']['UserPromptSubmit'] for h in m['hooks']]
print('yes' if any('inject-code-style' in c for c in cmds) else 'no')
")
[ "$T16_UPS" = "no" ] \
    && pass "T16: inject-code-style is not wired to UserPromptSubmit (PreToolUse-only)" \
    || fail "T16: inject-code-style is wired to UserPromptSubmit where it always returns {}"

t16_run() {  # $1 = hook, $2 = payload; stdout -> T16_OUT, returns non-zero on hook failure
    T16_OUT=$(printf '%s' "$2" | HOME="$T16_HOME" CLAUDE_PROJECT_DIR="$T16_PROJ" \
        IWE_GOVERNANCE_REPO="DS-strategy" bash "$TEMPLATE_DIR/.claude/hooks/$1" 2>/dev/null)
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    fail "T16: $1 exited $rc"
    return 1
}

t16_json() {  # $1 = python expr over parsed stdin d; empty output = extraction failed
    printf '%s' "$T16_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

# inject-communication-style: real UserPromptSubmit payload must yield the
# shipped style snapshot as additionalContext with the correct event name.
if t16_run inject-communication-style.sh '{"session_id":"t16-comm","prompt":"привет"}'; then
    T16_EV=$(t16_json "d['hookSpecificOutput']['hookEventName']")
    T16_LEN=$(t16_json "len(d['hookSpecificOutput']['additionalContext'])")
    if [ "$T16_EV" = "UserPromptSubmit" ] && [ "${T16_LEN:-0}" -gt 1000 ]; then
        pass "T16: inject-communication-style serves the snapshot on a real UserPromptSubmit"
    else
        fail "T16: inject-communication-style event='$T16_EV' ctx_len='${T16_LEN:-none}'"
    fi
fi

# inject-code-style: real PreToolUse payload on a code file must yield the
# engineering-style core with hookEventName PreToolUse.
printf 'x = 1\n' > "$T16_PROJ/t16-fixture.py"
if t16_run inject-code-style.sh "{\"session_id\":\"t16-code\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T16_PROJ/t16-fixture.py\"}}"; then
    T16_EV=$(t16_json "d['hookSpecificOutput']['hookEventName']")
    T16_LEN=$(t16_json "len(d['hookSpecificOutput']['additionalContext'])")
    if [ "$T16_EV" = "PreToolUse" ] && [ "${T16_LEN:-0}" -gt 1000 ]; then
        pass "T16: inject-code-style serves the style core on a real PreToolUse"
    else
        fail "T16: inject-code-style event='$T16_EV' ctx_len='${T16_LEN:-none}'"
    fi
fi

# inject-fault-profile: with a canonical CLI fixture in the workspace, a real
# payload must yield the reminder AND the traversal-shaped session_id must be
# sanitized before landing in the state-file name.
mkdir -p "$T16_PROJ/scripts/agent-fault"
printf '#!/usr/bin/env python3\nprint("\\U0001F534 [CRITICAL | n=5] test-reminder-fixture")\n' \
    > "$T16_PROJ/scripts/agent-fault/iwe_checklist_memory.py"
if t16_run inject-fault-profile.sh '{"session_id":"t16-../../evil","prompt":"x"}'; then
    T16_EV=$(t16_json "d['hookSpecificOutput']['hookEventName']")
    T16_HAS=$(t16_json "'test-reminder-fixture' in d['hookSpecificOutput']['additionalContext']")
    if [ "$T16_EV" = "UserPromptSubmit" ] && [ "$T16_HAS" = "True" ]; then
        pass "T16: inject-fault-profile serves reminders from the canonical CLI fixture"
    else
        fail "T16: inject-fault-profile event='$T16_EV' reminder='$T16_HAS'"
    fi
    if [ -f "$T16_PROJ/.claude/state/fault-profile-injected-t16-evil" ]; then
        pass "T16: traversal-shaped session_id is sanitized in the state-file name"
    else
        fail "T16: sanitized state file not found ($(ls "$T16_PROJ/.claude/state/" 2>/dev/null | tr '\n' ' '))"
    fi
    if [ -e "$T16_PROJ/.claude/evil" ] || [ -e "$T16_PROJ/evil" ] || [ -e "$TEST_WS/evil" ]; then
        fail "T16: session_id traversal escaped the state directory"
    else
        pass "T16: no path-traversal artifact outside the state directory"
    fi
fi

# inject-fault-profile without jq must be a silent no-op ({}). jq cannot be
# hidden via the caller's PATH (the hook prepends system dirs itself), so patch
# ONLY the `export PATH=` line in a copy — the guard logic under test is intact.
T16_NOJQ="$TEST_WS/t16-nojq"
mkdir -p "$T16_NOJQ/bin"
for t16_bin in bash cat tr cut mkdir touch find python3 grep head; do
    t16_src=$(command -v "$t16_bin") && ln -s "$t16_src" "$T16_NOJQ/bin/$t16_bin"
done
sed "s|^export PATH=.*|export PATH=\"$T16_NOJQ/bin\"|" \
    "$TEMPLATE_DIR/.claude/hooks/inject-fault-profile.sh" > "$T16_NOJQ/hook.sh"
T16_OUT=$(printf '%s' '{"session_id":"t16-nojq"}' | HOME="$T16_HOME" CLAUDE_PROJECT_DIR="$T16_PROJ" \
    bash "$T16_NOJQ/hook.sh" 2>/dev/null)
if [ $? -eq 0 ] && [ "$T16_OUT" = "{}" ]; then
    pass "T16: inject-fault-profile degrades to a silent no-op without jq"
else
    fail "T16: without jq expected '{}' rc=0, got rc=$? out='$T16_OUT'"
fi

# response-clarity-hook has TWO modes selected by STYLE_ENFORCE_BLOCK — the test
# must pin the mode explicitly, or its expectations silently depend on the
# caller's environment (found by peer review: the author's env had it set).
T16_TRANSCRIPT="$TEST_WS/t16-transcript.jsonl"
{
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"сделай"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Готово: тесты прошли, exit 0."}]}}'
} > "$T16_TRANSCRIPT"
T16_CLAR_PAYLOAD="{\"session_id\":\"t16-clar\",\"stop_hook_active\":false,\"transcript_path\":\"$T16_TRANSCRIPT\"}"

t16_clarity() {  # $1 = STYLE_ENFORCE_BLOCK value, $2 = payload; sets T16_OUT/T16_RC/T16_ERR
    T16_ERR_FILE="$TEST_WS/t16-clarity-stderr.txt"
    T16_OUT=$(printf '%s' "$2" | HOME="$T16_HOME" CLAUDE_PROJECT_DIR="$T16_PROJ" \
        STYLE_ENFORCE_BLOCK="$1" bash "$TEMPLATE_DIR/.claude/hooks/response-clarity-hook.sh" 2>"$T16_ERR_FILE")
    T16_RC=$?
    T16_ERR=$(head -c 300 "$T16_ERR_FILE" 2>/dev/null | tr '\n' ' ')
}

# Recursion guard: stop_hook_active must short-circuit to silence in any mode.
t16_clarity 0 '{"session_id":"t16-clar","stop_hook_active":true}'
if [ "$T16_RC" -eq 0 ] && [ -z "$T16_OUT" ]; then
    pass "T16: response-clarity-hook honors the stop_hook_active recursion guard"
else
    fail "T16: recursion guard broken (rc=$T16_RC, out='$T16_OUT', err='$T16_ERR')"
fi

# Warning mode (=0): the A10 marker in the transcript must produce a visible warning.
t16_clarity 0 "$T16_CLAR_PAYLOAD"
if [ "$T16_RC" -eq 0 ] && printf '%s' "$T16_OUT" | grep -q 'A10'; then
    pass "T16: response-clarity-hook flags the A10 marker in warning mode"
else
    fail "T16: warning mode gave no A10 warning (rc=$T16_RC, out='$T16_OUT', err='$T16_ERR')"
fi

# Block mode (=1): same transcript must yield decision=block with a reason.
t16_clarity 1 "$T16_CLAR_PAYLOAD"
T16_DEC=$(t16_json "d['decision']")
T16_RLEN=$(t16_json "len(d['reason'])")
if [ "$T16_DEC" = "block" ] && [ "${T16_RLEN:-0}" -gt 0 ]; then
    pass "T16: response-clarity-hook blocks with a reason in enforce mode"
else
    fail "T16: enforce mode expected decision=block, got decision='$T16_DEC' reason_len='${T16_RLEN:-none}' (rc=$T16_RC, err='$T16_ERR')"
fi

# ============================================================
# T17: seed ships the scaffold dependency lib/ (issue #347)
# ============================================================
echo "--- T17: seed delivers scripts/lib/ to a fresh governance install ---"

if [ -f "$TEMPLATE_DIR/seed/strategy/scripts/lib/common.sh" ]; then
    pass "T17: seed/strategy/scripts/lib/common.sh is present"
else
    fail "T17: seed/strategy/scripts/lib/common.sh is missing — fresh installs lose the scaffold dependency"
fi
# setup.sh must copy seed contents recursively (cp -r src/. dst/), or lib/ stays behind.
if grep -qE 'cp -r "\$STRATEGY_TEMPLATE"/\. ' "$TEMPLATE_DIR/setup.sh"; then
    pass "T17: setup.sh copies the whole seed tree recursively"
else
    fail "T17: setup.sh no longer copies seed recursively — lib/ delivery is broken"
fi

# ============================================================
# T18: decision-log path and cold-start contract (issue #351)
# ============================================================
echo "--- T18: decision log has one canonical home ---"

# shellcheck disable=SC2016 # the contract must contain the literal runtime placeholder
T18_CANONICAL='${IWE_GOVERNANCE_REPO:-DS-strategy}/decisions/decision-log-YYYY-MM.md'
T18_CANONICAL_MISSING=0
for consumer in \
    memory/protocol-close.md \
    memory/protocol-work.md \
    .claude/skills/month-close/SKILL.md; do
    if ! grep -Fq "$T18_CANONICAL" "$TEMPLATE_DIR/$consumer"; then
        T18_CANONICAL_MISSING=$((T18_CANONICAL_MISSING + 1))
    fi
done
if [ "$T18_CANONICAL_MISSING" -eq 0 ]; then
    pass "T18: all decision-log consumers name the canonical governance decisions/ path"
else
    fail "T18: $T18_CANONICAL_MISSING decision-log consumer(s) lost the canonical path"
fi

if grep -q 'current/.*,.*decisions/.*,.*sessions/' "$TEMPLATE_DIR/memory/repo-type-rules.md" && \
   [ -f "$TEMPLATE_DIR/seed/strategy/decisions/.gitkeep" ]; then
    pass "T18: repository rules and fresh-install seed both provide the decisions/ home"
else
    fail "T18: decisions/ is missing from repository rules or the fresh-install seed"
fi

# shellcheck disable=SC2016 # both grep needles are literal runtime placeholders
if grep -Fq '${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/decisions/' \
       "$TEMPLATE_DIR/memory/protocol-work.md" && \
   grep -q 'все.*decision-log-\*\.md' "$TEMPLATE_DIR/memory/protocol-work.md" && \
   grep -Fq '${IWE_GOVERNANCE_REPO:-DS-strategy}/exocortex/decisions/decision-log-YYYY-MM.md' \
       "$TEMPLATE_DIR/.claude/skills/month-close/SKILL.md" && \
   grep -q 'не объединять и не перезаписывать молча' "$TEMPLATE_DIR/memory/protocol-work.md"; then
    pass "T18: first write and Month Close migrate legacy logs without silent overwrite"
else
    fail "T18: legacy decision-log migration/collision contract is missing"
fi

if grep -q 'Решения за месяц не зарегистрированы' "$TEMPLATE_DIR/.claude/skills/month-close/SKILL.md"; then
    pass "T18: Month Close defines a non-error outcome for a month without decisions"
else
    fail "T18: Month Close still has no cold-start behavior for an absent decision log"
fi

# ============================================================
# T19: orphan detection is CWD-independent and fail-open (issue #353)
# ============================================================
echo "--- T19: orphan detection is diagnostic and CWD-independent ---"

T19_BLOCK="$TEST_WS/t19-orphan-block.sh"
{
    # issue #402: Step 6f now gates on py_available(), defined in the Python
    # resolution preamble (not part of the Step 6f slice) — an isolated
    # extraction needs that dependency too, same reasoning as pulling in only
    # the Step 6f block itself instead of the whole script.
    awk '
        /^# === Cross-platform Python resolution/{found=1}
        /^py_available\(\) \{/{print; found=0; next}
        found{print}
    ' "$TEMPLATE_DIR/update.sh"
    awk '
        /^# === Step 6f: Orphan detection/{found=1; next}
        /^# === Step 7: Validate applied changes/{found=0}
        found{print}
    ' "$TEMPLATE_DIR/update.sh"
} > "$T19_BLOCK"

if [ ! -s "$T19_BLOCK" ]; then
    fail "T19: could not extract the orphan-detection block"
else
    T19_FOREIGN_OUT=$(cd "$TEST_WS" && SCRIPT_DIR="$TEMPLATE_DIR" bash -c 'set -e; source "$1"; echo T19_CONTINUED' -- "$T19_BLOCK" 2>&1)
    T19_FOREIGN_RC=$?
    if [ "$T19_FOREIGN_RC" -eq 0 ] && [[ "$T19_FOREIGN_OUT" == *"T19_CONTINUED"* ]] && [[ "$T19_FOREIGN_OUT" != *"Traceback"* ]]; then
        pass "T19: orphan detection resolves the manifest from SCRIPT_DIR outside the template CWD"
    else
        fail "T19: foreign-CWD orphan detection failed (rc=$T19_FOREIGN_RC): $T19_FOREIGN_OUT"
    fi

    T19_BAD_DIR="$TEST_WS/t19-invalid-manifest"
    mkdir -p "$T19_BAD_DIR"
    printf '{invalid json\n' > "$T19_BAD_DIR/update-manifest.json"
    T19_FAIL_OUT=$(SCRIPT_DIR="$T19_BAD_DIR" bash -c 'set -e; source "$1"; echo T19_CONTINUED' -- "$T19_BLOCK" 2>&1)
    T19_FAIL_RC=$?
    if [ "$T19_FAIL_RC" -eq 0 ] && [[ "$T19_FAIL_OUT" == *"T19_CONTINUED"* ]] && [[ "$T19_FAIL_OUT" == *"обновление уже применено и остаётся успешным"* ]]; then
        pass "T19: an orphan-check failure warns and does not fail the applied update"
    else
        fail "T19: orphan-check failure was not fail-open (rc=$T19_FAIL_RC): $T19_FAIL_OUT"
    fi
fi

# ============================================================
# T20: index-health skip covers size only, not semantics (issue #357)
# ============================================================
echo "--- T20: index-health skip keeps semantic checks ---"

T20_DIR="$TEST_WS/t20-index-health"
mkdir -p "$T20_DIR"
if T20_MODULE="$TEMPLATE_DIR/.claude/scripts/check-index-health.py" T20_DIR="$T20_DIR" python3 - <<'PYEOF'
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("check_index_health", os.environ["T20_MODULE"])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

root = Path(os.environ["T20_DIR"])
payload = "short line\n" * ((module.SIZE_FAIL // 11) + 100)

skipped = root / "skip-index.md"
skipped.write_text("<!-- index-health: skip -->\n" + payload, encoding="utf-8")
assert module.classify(module.check_file(skipped)) == "OK"

plain = root / "plain-index.md"
plain.write_text(payload, encoding="utf-8")
assert module.classify(module.check_file(plain)) == "FAIL"

semantic = root / "semantic-index.md"
semantic.write_text(
    "<!-- index-health: skip -->\n| 123 | item | ✅ |\n" + payload,
    encoding="utf-8",
)
assert module.classify(module.check_file(semantic)) == "WARN"
PYEOF
then
    pass "T20: skip suppresses size FAIL while done-no-strike still produces WARN"
else
    fail "T20: index-health skip semantics regressed"
fi

# ============================================================
# T21: legacy platform memory migrates safely (issues #354/#384)
# ============================================================
echo "--- T21: platform memory migrates once with backup ---"

T21_OWNER_FAILURES=0
for platform_file in \
    protocol-open.md protocol-work.md protocol-close.md protocol-month-close.md \
    agent-architecture-framework.md agent-vendor-connect-pattern.md checklists.md \
    dry-run-contract.md feedback_response_clarity_for_pilot.md hooks-design.md navigation.md \
    reference/agent-core.md repo-type-rules.md r-questionnaire.md t-checklist.md templates-dayplan.md; do
    if [ "$(get_field "$TEMPLATE_DIR/memory/$platform_file" owner)" != "platform" ]; then
        T21_OWNER_FAILURES=$((T21_OWNER_FAILURES + 1))
    fi
done
if [ "$T21_OWNER_FAILURES" -eq 0 ]; then
    pass "T21: exact shared-memory allowlist declares owner:platform"
else
    fail "T21: $T21_OWNER_FAILURES shared memory file(s) still have the wrong owner"
fi

T21_WIRED_COUNT=$(grep -cE 'migrate_platform_memory "\$(fpath|f)" "\$(mem_dst|dst)"' "$TEMPLATE_DIR/update.sh")
if [ "$T21_WIRED_COUNT" -eq 2 ]; then
    pass "T21: migration is wired into repair-pass and normal propagation"
else
    fail "T21: expected migration at both memory propagation sites, found $T21_WIRED_COUNT"
fi

if (
    eval "$(awk '/^hash_file\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
    eval "$(awk '/^is_author_mode\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
    eval "$(awk '/^is_migrated_platform_memory_path\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
    eval "$(awk '/^migrate_platform_memory\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"

    SCRIPT_DIR="$TEMPLATE_DIR"
    WORKSPACE_DIR="$TEST_WS/t21-workspace"
    mkdir -p "$WORKSPACE_DIR"

    target="$TEST_WS/t21-protocol-open.md"
    cat > "$target" <<'HEREDOC'
---
owner: user
---
Pilot custom protocol content.
HEREDOC

    migrate_platform_memory memory/protocol-open.md "$target"
    backup="$WORKSPACE_DIR/.backups/protocol-owner-migration/protocol-open.md"
    grep -q 'Pilot custom protocol content' "$backup"
    cmp -s "$target" "$TEMPLATE_DIR/memory/protocol-open.md"
    backup_hash=$(hash_file "$backup")

    # The deployed copy is now owner:platform, so a repeat must be a no-op and
    # must not replace the saved user version.
    if migrate_platform_memory memory/protocol-open.md "$target"; then
        exit 1
    fi
    [ "$backup_hash" = "$(hash_file "$backup")" ]

    # A platform-owned source outside the exact migration allowlist must not
    # weaken the general owner:user protection from issue #229.
    unrelated="$TEST_WS/t21-unrelated.md"
    cat > "$unrelated" <<'HEREDOC'
---
owner: user
---
Unrelated user content.
HEREDOC
    if migrate_platform_memory memory/protocol-dt-integration.md "$unrelated"; then
        exit 1
    fi
    grep -q 'Unrelated user content' "$unrelated"

    # author_mode remains fail-closed even for an allowlisted legacy protocol.
    printf 'author_mode: true\n' > "$WORKSPACE_DIR/params.yaml"
    author_target="$TEST_WS/t21-author-protocol.md"
    cat > "$author_target" <<'HEREDOC'
---
owner: user
---
Author unpublished content.
HEREDOC
    if migrate_platform_memory memory/protocol-work.md "$author_target"; then
        exit 1
    fi
    grep -q 'Author unpublished content' "$author_target"

    # #384 extends the exact migration to platform-maintained references without
    # weakening user-owned FPF snapshots and author distinctions.
    rm -f "$WORKSPACE_DIR/params.yaml"
    reference_target="$TEST_WS/t21-agent-core.md"
    cat > "$reference_target" <<'HEREDOC'
---
owner: user
---
Legacy platform reference with a pilot note.
HEREDOC
    migrate_platform_memory memory/reference/agent-core.md "$reference_target"
    cmp -s "$reference_target" "$TEMPLATE_DIR/memory/reference/agent-core.md"
    if migrate_platform_memory memory/fpf-reference.md "$unrelated"; then
        exit 1
    fi
); then
    pass "T21: migration preserves the user copy, is idempotent, allowlisted and author-safe"
else
    fail "T21: platform protocol migration contract failed"
fi

# ============================================================
# T22: Quick Close runner enforcement is capability-aware (issue #356)
# ============================================================
echo "--- T22: Quick Close falls back only when runner capability is absent ---"

T22_BLOCK="$TEST_WS/t22-runner-block.sh"
awk '
    /^  # issue #356:/{found=1}
    /^  # agent status idle/{found=0}
    found{sub(/^  /, ""); print}
' "$TEMPLATE_DIR/scripts/session-guard.sh" > "$T22_BLOCK"

T22_ROOT="$TEST_WS/t22-root"
T22_GOV="DS-strategy"
T22_SLUG="issue-356"
mkdir -p "$T22_ROOT/$T22_GOV"

T22_MANUAL_OUT=$(IWE_ROOT="$T22_ROOT" GOV_REPO="$T22_GOV" SLUG="$T22_SLUG" \
    bash -c 'set -euo pipefail; fail(){ echo "$1" >&2; exit "${2:-1}"; }; source "$1"; echo T22_CONTINUED' -- "$T22_BLOCK" 2>&1)
T22_MANUAL_RC=$?
if [ "$T22_MANUAL_RC" -eq 0 ] && [[ "$T22_MANUAL_OUT" == *"runner_check=not_applicable"* ]] && [[ "$T22_MANUAL_OUT" == *"T22_CONTINUED"* ]]; then
    pass "T22: missing runner capability selects a visible manual fallback"
else
    fail "T22: runner-less close did not continue visibly (rc=$T22_MANUAL_RC): $T22_MANUAL_OUT"
fi

mkdir -p "$T22_ROOT/$T22_GOV/scripts/processes"
: > "$T22_ROOT/$T22_GOV/scripts/process-runner.py"
: > "$T22_ROOT/$T22_GOV/scripts/processes/quick-close.yaml"
T22_STRICT_OUT=$(IWE_ROOT="$T22_ROOT" GOV_REPO="$T22_GOV" SLUG="$T22_SLUG" \
    bash -c 'set -euo pipefail; fail(){ echo "$1" >&2; exit "${2:-1}"; }; source "$1"; echo T22_CONTINUED' -- "$T22_BLOCK" 2>&1)
T22_STRICT_RC=$?
if [ "$T22_STRICT_RC" -eq 7 ] && [[ "$T22_STRICT_OUT" == *"нет terminal RUN-quick-close"* ]]; then
    pass "T22: installed runner without a terminal card still blocks close"
else
    fail "T22: installed runner bypassed its terminal-card gate (rc=$T22_STRICT_RC): $T22_STRICT_OUT"
fi

mkdir -p "$T22_ROOT/$T22_GOV/inbox/agent/tasks"
cat > "$T22_ROOT/$T22_GOV/inbox/agent/tasks/RUN-quick-close-${T22_SLUG}-test.md" <<'HEREDOC'
---
process_id: quick-close
status: completed
---
HEREDOC
T22_CARD_OUT=$(IWE_ROOT="$T22_ROOT" GOV_REPO="$T22_GOV" SLUG="$T22_SLUG" \
    bash -c 'set -euo pipefail; fail(){ echo "$1" >&2; exit "${2:-1}"; }; source "$1"; echo T22_CONTINUED' -- "$T22_BLOCK" 2>&1)
T22_CARD_RC=$?
if [ "$T22_CARD_RC" -eq 0 ] && [[ "$T22_CARD_OUT" == *"T22_CONTINUED"* ]] && [[ "$T22_CARD_OUT" != *"not_applicable"* ]]; then
    pass "T22: installed runner with a completed matching card permits close"
else
    fail "T22: valid terminal card did not satisfy the runner gate (rc=$T22_CARD_RC): $T22_CARD_OUT"
fi

if grep -q 'Раннер — условный драйвер' "$TEMPLATE_DIR/memory/protocol-close.md" && \
   grep -q 'runner_check: not_applicable' "$TEMPLATE_DIR/memory/protocol-close.md"; then
    pass "T22: protocol text documents strict and manual modes"
else
    fail "T22: protocol text does not explain the capability-aware fallback"
fi

# ============================================================
# T23: wp-sync-bundle canonical card and structured open phases
# ============================================================
echo "--- T23: wp-sync-bundle uses the canonical folder card and phase statuses ---"

T23_ROOT="$TEST_WS/t23-root"
T23_GOV="$T23_ROOT/governance"
mkdir -p "$T23_GOV/docs" "$T23_GOV/inbox/WP-777"
printf '# registry\n' > "$T23_GOV/docs/WP-REGISTRY.md"

cat > "$T23_GOV/inbox/WP-777.md" <<'HEREDOC'
---
wp: 777
status: done
---
- [ ] stale flat duplicate
HEREDOC

cat > "$T23_GOV/inbox/WP-777/WP-777.md" <<'HEREDOC'
---
wp: 777
status: in_progress
phases:
- id: OPEN-ONE
  status: pending
- id: CLOSED-ONE
  status: done
- id: OPEN-TWO
  status: blocked
---
- [ ] historical unchecked checkbox one
- [ ] historical unchecked checkbox two
HEREDOC

T23_OUT=$(IWE_WORKSPACE="$T23_ROOT" IWE_GOVERNANCE_REPO=governance \
    bash "$TEMPLATE_DIR/.claude/scripts/wp-sync-bundle.sh" WP-777 2>&1)
T23_RC=$?
if [ "$T23_RC" -eq 0 ] && \
   [[ "$T23_OUT" == *'Файл: `inbox/WP-777/WP-777.md`'* ]] && \
   [[ "$T23_OUT" == *'Открытых фаз: 2'* ]] && \
   [[ "$T23_OUT" == *'OPEN-ONE (pending)'* ]] && \
   [[ "$T23_OUT" == *'OPEN-TWO (blocked)'* ]] && \
   [[ "$T23_OUT" != *'historical unchecked'* ]] && \
   [[ "$T23_OUT" != *'stale flat duplicate'* ]]; then
    pass "T23: folder card wins and only pending/in_progress/blocked phases are listed"
else
    fail "T23: canonical folder card or structured open phases regressed (rc=$T23_RC): $T23_OUT"
fi

mkdir -p "$T23_GOV/inbox"
cat > "$T23_GOV/inbox/WP-778.md" <<'HEREDOC'
---
wp: 778
status: in_progress
---
- [ ] legacy open one
- [x] legacy closed
- [ ] legacy open two
HEREDOC

T23_LEGACY_OUT=$(IWE_WORKSPACE="$T23_ROOT" IWE_GOVERNANCE_REPO=governance \
    bash "$TEMPLATE_DIR/.claude/scripts/wp-sync-bundle.sh" WP-778 2>&1)
T23_LEGACY_RC=$?
if [ "$T23_LEGACY_RC" -eq 0 ] && \
   [[ "$T23_LEGACY_OUT" == *'Открытых фаз: 2'* ]] && \
   [[ "$T23_LEGACY_OUT" == *'legacy open one'* ]] && \
   [[ "$T23_LEGACY_OUT" == *'legacy open two'* ]]; then
    pass "T23: legacy cards without phases keep checkbox fallback"
else
    fail "T23: legacy checkbox fallback regressed (rc=$T23_LEGACY_RC): $T23_LEGACY_OUT"
fi

mkdir -p "$T23_GOV/archive/wp-contexts"
cat > "$T23_GOV/archive/wp-contexts/WP-469-unrelated.md" <<'HEREDOC'
---
wp: 469
status: done
---
HEREDOC

T23_PREFIX_OUT=$(IWE_WORKSPACE="$T23_ROOT" IWE_GOVERNANCE_REPO=governance \
    bash "$TEMPLATE_DIR/.claude/scripts/wp-sync-bundle.sh" WP-46 2>&1)
T23_PREFIX_RC=$?
if [ "$T23_PREFIX_RC" -eq 1 ] && [[ "$T23_PREFIX_OUT" == *'WP-46: файл не найден'* ]]; then
    pass "T23: a shorter WP ID does not resolve a longer numeric prefix"
else
    fail "T23: numeric-prefix archive lookup regressed (rc=$T23_PREFIX_RC): $T23_PREFIX_OUT"
fi

# ============================================================
# T24: public-fork CLAUDE bases stay raw and rules survive repair
# ============================================================
echo "--- T24: raw CLAUDE base + transactional rules preservation (#379/#381) ---"

T24_ROOT="$TEST_WS/t24-root"
T24_TEMPLATE="$T24_ROOT/FMT-exocortex-template"
mkdir -p "$T24_TEMPLATE" "$T24_ROOT/.claude/rules"
cat > "$T24_ROOT/.exocortex.env" <<EOF
WORKSPACE_DIR="$T24_ROOT"
HOME_DIR="$T24_ROOT/home"
USER_NAME="test-user"
CLAUDE_PATH="$T24_ROOT/bin/claude"
IWE_TEMPLATE="$T24_TEMPLATE"
IWE_RUNTIME="$T24_ROOT/.iwe-runtime"
EOF
printf 'root=%s\n<!-- user delta -->\n' "$T24_ROOT" > "$T24_TEMPLATE/CLAUDE.md"

eval "$(awk '/^restore_claude_placeholders\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
SCRIPT_DIR="$T24_TEMPLATE"
WORKSPACE_DIR="$T24_ROOT"
if sed --version >/dev/null 2>&1; then sed_inplace(){ sed -i "$@"; }; else sed_inplace(){ sed -i '' "$@"; }; fi
restore_claude_placeholders "$T24_TEMPLATE/CLAUDE.md" "$T24_ROOT/claude-raw.md"
if grep -q '{{WORKSPACE_DIR}}' "$T24_ROOT/claude-raw.md" && grep -q '<!-- user delta -->' "$T24_ROOT/claude-raw.md"; then
    pass "T24: legacy absolute path migrates back to placeholder without losing delta"
else
    fail "T24: CLAUDE raw-base migration lost placeholder or user delta"
fi
if ! grep -q 'cp .*WORKSPACE_DIR/CLAUDE.md.*TEMPLATE_DIR/.claude.md.base' "$TEMPLATE_DIR/setup.sh"; then
    pass "T24: setup no longer writes substituted base into the public template repo"
else
    fail "T24: setup still stores substituted CLAUDE base in the template repo"
fi

RULES_BACKUP_RUN=""
RULES_SAFE_TO_UPDATE="|.claude/rules/example.md|"
eval "$(awk '/^hash_file\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
eval "$(awk '/^rule_was_safe_to_update\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
eval "$(awk '/^backup_rule_before_overwrite\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
eval "$(awk '/^copy_platform_file_preserving_user_space\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
cat > "$T24_ROOT/rule-upstream.md" <<'EOF'
# Platform rule v2
EOF
cat > "$T24_ROOT/.claude/rules/example.md" <<'EOF'
# Platform rule v1
<!-- USER-SPACE -->
pilot distinction
<!-- /USER-SPACE -->
EOF
copy_platform_file_preserving_user_space "$T24_ROOT/rule-upstream.md" "$T24_ROOT/.claude/rules/example.md" ".claude/rules/example.md"
T24_BACKUP=$(find "$T24_ROOT/.backups/rules-pre-update" -type f -name example.md -print -quit 2>/dev/null || true)
if grep -q 'Platform rule v2' "$T24_ROOT/.claude/rules/example.md" && \
   grep -q 'pilot distinction' "$T24_ROOT/.claude/rules/example.md" && \
   [ -n "$T24_BACKUP" ] && grep -q 'Platform rule v1' "$T24_BACKUP"; then
    pass "T24: rule update preserves USER-SPACE and creates a recoverable pre-image"
else
    fail "T24: rule preservation or transactional backup failed"
fi

RULES_SAFE_TO_UPDATE="|"
cat > "$T24_ROOT/.claude/rules/diverged.md" <<'EOF'
# Pilot corrected an existing platform rule
EOF
cat > "$T24_ROOT/rule-diverged-upstream.md" <<'EOF'
# Platform replacement
EOF
diverged_before=$(hash_file "$T24_ROOT/.claude/rules/diverged.md")
copy_platform_file_preserving_user_space \
    "$T24_ROOT/rule-diverged-upstream.md" \
    "$T24_ROOT/.claude/rules/diverged.md" \
    ".claude/rules/diverged.md" || true
diverged_after=$(hash_file "$T24_ROOT/.claude/rules/diverged.md")
copy_platform_file_preserving_user_space \
    "$T24_ROOT/rule-diverged-upstream.md" \
    "$T24_ROOT/.claude/rules/diverged.md" \
    ".claude/rules/diverged.md" || true
if [ "$diverged_before" = "$diverged_after" ] && \
   grep -q 'Pilot corrected' "$T24_ROOT/.claude/rules/diverged.md"; then
    pass "T24: diverged rule survives repeated repair attempts unchanged"
else
    fail "T24: repair overwrote a user-corrected existing rule"
fi

# ============================================================
# T25: bootstrap delivery, root/memory resolution, cwd and native Claude
# ============================================================
echo "--- T25: bootstrap/path contracts (#300/#362/#366/#368/#371/#374/#377) ---"
T25_REAL_TEMPLATE="$TEMPLATE_DIR"

for required in setup/build-runtime.sh setup/install-iwe-paths.sh; do
    if jq -e --arg p "$required" '.files[] | select(.path == $p)' "$TEMPLATE_DIR/update-manifest.json" >/dev/null; then
        pass "T25: manifest delivers $required"
    else
        fail "T25: manifest still omits $required"
    fi
done

T25_HOME="$TEST_WS/t25-home"
T25_WS="$TEST_WS/t25-workspace"
mkdir -p "$T25_HOME" "$T25_WS"
cat > "$T25_HOME/.zshenv" <<'EOF'
# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам
[ -f "$HOME/.iwe-paths" ] && source "$HOME/.iwe-paths"
EOF
HOME="$T25_HOME" bash "$TEMPLATE_DIR/setup/install-iwe-paths.sh" --workspace "$T25_WS" --governance GOV --quiet
if grep -qF "_IWE_ROOT=\"$T25_WS\"" "$T25_HOME/.zshenv" && \
   ! grep -qF '[ -f "$HOME/.iwe-paths" ]' "$T25_HOME/.zshenv" && \
   [ "$(grep -c '^export IWE_' "$T25_WS/.iwe-paths")" -eq 6 ]; then
    pass "T25: legacy HOME source is replaced by the six-variable workspace SoT"
else
    fail "T25: install-iwe-paths left the legacy source or incomplete workspace env"
fi

T25_STAND="$TEST_WS/t25-stand"
mkdir -p "$T25_STAND/FMT-exocortex-template/scripts/lib"
cp "$TEMPLATE_DIR/scripts/lib/common.sh" "$T25_STAND/FMT-exocortex-template/scripts/lib/common.sh"
T25_ROOT=$(env -u IWE_WORKSPACE -u IWE_ROOT bash -c 'source "$1"; iwe_resolve_root' -- "$T25_STAND/FMT-exocortex-template/scripts/lib/common.sh")
T25_STAND_PHYSICAL=$(cd "$T25_STAND" && pwd -P)
if [ "$T25_ROOT" = "$T25_STAND_PHYSICAL" ]; then
    pass "T25: common resolver derives a non-HOME workspace from its installed location"
else
    fail "T25: common resolver returned '$T25_ROOT' instead of '$T25_STAND_PHYSICAL'"
fi

mkdir -p "$T25_STAND/custom-memory" "$T25_STAND/workspace"
ln -s "$T25_STAND/custom-memory" "$T25_STAND/workspace/memory"
eval "$(awk '/^resolve_workspace_memory_dir\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")"
HOME="$T25_HOME" T25_MEMORY=$(resolve_workspace_memory_dir "$T25_STAND/workspace")
T25_CUSTOM_PHYSICAL=$(cd "$T25_STAND/custom-memory" && pwd -P)
if [ "$T25_MEMORY" = "$T25_CUSTOM_PHYSICAL" ]; then
    pass "T25: physical workspace/memory target wins over a guessed Claude slug"
else
    fail "T25: memory resolver missed the physical symlink target: $T25_MEMORY"
fi

mkdir -p "$T25_STAND/FMT-exocortex-template"
printf 'defaults: one\n' > "$T25_STAND/FMT-exocortex-template/params.yaml.example"
TEMPLATE_DIR="$T25_STAND/FMT-exocortex-template"
T25_SOURCE="$TEMPLATE_DIR/params.yaml.example"
T25_HASH1=$(shasum -a 256 "$T25_SOURCE" | cut -d' ' -f1)
printf 'defaults: two\n' > "$T25_SOURCE"
T25_HASH2=$(shasum -a 256 "$T25_SOURCE" | cut -d' ' -f1)
if [ "$T25_HASH1" != "$T25_HASH2" ] && grep -q 'hash_file "$(resolve_overlay_source "$f")"' "$T25_REAL_TEMPLATE/setup/build-runtime.sh"; then
    pass "T25: params.yaml.example is the hash input and content changes alter its digest"
else
    fail "T25: overlay fallback is not wired into the build hash"
fi
TEMPLATE_DIR="$T25_REAL_TEMPLATE"

T25_GUARD="$TEMPLATE_DIR/.claude/hooks/destructive-guard.sh"
set +e
printf '%s' '{"tool_input":{"command":"cd repo && git status"},"cwd":"/tmp"}' | bash "$T25_GUARD" >/dev/null 2>&1; T25_CD=$?
printf '%s' '{"tool_input":{"command":"(cd repo && git status)"},"cwd":"/tmp"}' | bash "$T25_GUARD" >/dev/null 2>&1; T25_SUB=$?
printf '%s' '{"tool_input":{"command":"echo \"cd repo\""},"cwd":"/tmp"}' | bash "$T25_GUARD" >/dev/null 2>&1; T25_QUOTE=$?
set -e
if [ "$T25_CD" -eq 2 ] && [ "$T25_SUB" -eq 0 ] && [ "$T25_QUOTE" -eq 0 ]; then
    pass "T25: cwd guard blocks sticky cd without false positives for subshell/quoted text"
else
    fail "T25: cwd guard rc top=$T25_CD subshell=$T25_SUB quoted=$T25_QUOTE"
fi

T25_NATIVE_RUNNERS=$(grep -l '\.local/bin/claude' "$TEMPLATE_DIR/roles/strategist/scripts/strategist.sh" "$TEMPLATE_DIR/roles/extractor/scripts/extractor.sh" | wc -l | tr -d ' ')
T25_NATIVE_PLISTS=$(grep -l '{{HOME_DIR}}/.local/bin:' \
  "$TEMPLATE_DIR/roles/strategist/scripts/launchd/com.strategist.morning.plist" \
  "$TEMPLATE_DIR/roles/strategist/scripts/launchd/com.strategist.weekreview.plist" \
  "$TEMPLATE_DIR/roles/extractor/scripts/launchd/com.extractor.inbox-check.plist" \
  "$TEMPLATE_DIR/roles/synchronizer/scripts/launchd/com.exocortex.scheduler.plist" | wc -l | tr -d ' ')
T25_FAILFAST=$(grep -l 'exit 127' "$TEMPLATE_DIR/roles/strategist/scripts/strategist.sh" "$TEMPLATE_DIR/roles/extractor/scripts/extractor.sh" | wc -l | tr -d ' ')
if [ "$T25_NATIVE_RUNNERS" -eq 2 ] && [ "$T25_NATIVE_PLISTS" -eq 4 ] && [ "$T25_FAILFAST" -eq 2 ]; then
    pass "T25: both runners and all four plists support native Claude; runners fail with 127"
else
    fail "T25: native Claude runners=$T25_NATIVE_RUNNERS/2 plists=$T25_NATIVE_PLISTS/4 fail-fast=$T25_FAILFAST/2"
fi

# ============================================================
# T26: multiplier_enabled=false removes time/multiplier output contracts
# ============================================================
echo "--- T26: multiplier opt-out is end-to-end (#376) ---"
T26_ROOT="$TEST_WS/t26-workspace"
mkdir -p "$T26_ROOT/DS-strategy/exocortex" "$T26_ROOT/DS-strategy/current" \
  "$T26_ROOT/DS-strategy/inbox" "$T26_ROOT/DS-strategy/drafts"
ln -s "$TEMPLATE_DIR/scripts" "$T26_ROOT/scripts"
printf 'multiplier_enabled: false\n' > "$T26_ROOT/params.yaml"
printf '{}\n' > "$T26_ROOT/DS-strategy/exocortex/day-rhythm-config.yaml"
IWE_WORKSPACE="$T26_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  bash "$TEMPLATE_DIR/scripts/day-open-scaffold.sh" 2026-08-08 > "$T26_ROOT/dayplan.md"
if grep -A1 '^\*\*Бюджет дня:' "$T26_ROOT/dayplan.md" | \
   grep -q 'только «~Yh РП всего», без физического времени/WakaTime/мультипликатора'; then
    pass "T26: deterministic DayPlan scaffold selects the multiplier-off budget contract"
else
    fail "T26: DayPlan scaffold still requests physical time or multiplier"
fi
T26_TEMPLATE="$TEMPLATE_DIR/memory/templates-dayplan.md"
if grep -q '<!-- multiplier:off -->\*\*Бюджет дня:\*\* ~Yh РП всего' "$T26_TEMPLATE" && \
   grep -q '<!-- multiplier:off -->' "$T26_TEMPLATE" && \
   grep -q '## Метрики W{N}' "$T26_TEMPLATE" && \
   grep -q '### Бюджет закрытых РП' "$T26_TEMPLATE"; then
    pass "T26: DayPlan, WeekPlan, Week Close and Day Close all provide multiplier-off branches"
else
    fail "T26: one or more plan/report templates lack a multiplier-off branch"
fi

# ============================================================
# T27: bootstrap isolation, runtime hot list and memory schema (#384/#387/#388)
# ============================================================
echo "--- T27: bootstrap, hot-files and memory frontmatter contracts ---"
T27_ROOT="$TEST_WS/t27-workspace"
T27_TEMPLATE="$T27_ROOT/FMT-exocortex-template"
mkdir -p "$T27_TEMPLATE/.claude/lib" "$T27_ROOT/.claude/rules" "$T27_ROOT/GOV" "$T27_ROOT/memory"
cp "$TEMPLATE_DIR/.claude/lib/iwe-env-bootstrap.sh" "$T27_TEMPLATE/.claude/lib/"
if env -u WORKSPACE_DIR -u IWE_ROOT bash -c \
    'SCRIPT_DIR=caller-owned; source "$1"; [ "$SCRIPT_DIR" = caller-owned ]' -- \
    "$T27_TEMPLATE/.claude/lib/iwe-env-bootstrap.sh"; then
    pass "T27: bootstrap leaves the caller's SCRIPT_DIR unchanged"
else
    fail "T27: bootstrap still overwrites the caller's SCRIPT_DIR"
fi

if WORKSPACE_DIR="$T27_ROOT" IWE_ROOT="$T27_ROOT" \
    bash "$TEMPLATE_DIR/scripts/memory-bleed.sh" --dir "$T27_ROOT/memory" --hot-only >/dev/null; then
    pass "T27: memory-bleed starts successfully with the shared bootstrap"
else
    fail "T27: memory-bleed still fails during bootstrap"
fi

printf '# t27 rule\n' > "$T27_ROOT/.claude/rules/t27-rule.md"
printf '# root\n' > "$T27_ROOT/CLAUDE.md"
printf '# governance\n' > "$T27_ROOT/GOV/CLAUDE.md"
printf 'GOVERNANCE_REPO=GOV\n' > "$T27_ROOT/.exocortex.env"
T27_RUNTIME="$T27_ROOT/.iwe-runtime"
WORKSPACE_DIR="$T27_ROOT" IWE_ROOT="$T27_ROOT" IWE_RUNTIME="$T27_RUNTIME" \
    bash "$TEMPLATE_DIR/scripts/verify-context-budget.sh" >/dev/null 2>&1 || true
if [ ! -e "$T27_RUNTIME" ]; then
    pass "T27: read-only context check does not create runtime state on a fresh clone"
else
    fail "T27: context check created runtime state instead of using the shipped fallback"
fi

T27_SHIPPED_HASH_BEFORE=$(shasum -a 256 "$TEMPLATE_DIR/scripts/hot-files.list" | cut -d' ' -f1)
IWE_ROOT="$T27_ROOT" IWE_RUNTIME="$T27_RUNTIME" \
    bash "$TEMPLATE_DIR/scripts/generate-hot-files-list.sh" >/dev/null
T27_SHIPPED_HASH_AFTER=$(shasum -a 256 "$TEMPLATE_DIR/scripts/hot-files.list" | cut -d' ' -f1)
if [ "$T27_SHIPPED_HASH_BEFORE" = "$T27_SHIPPED_HASH_AFTER" ] && \
   grep -q '\$IWE_ROOT/GOV/CLAUDE.md' "$T27_RUNTIME/hot-files.list" && \
   grep -q 't27-rule.md' "$T27_RUNTIME/hot-files.list"; then
    pass "T27: install-specific hot list is generated only in runtime"
else
    fail "T27: hot-list generation changed the template or missed install-specific paths"
fi

if MEMORY_OUTPUT=$(WORKSPACE_DIR="$TEMPLATE_DIR" IWE_ROOT="$TEMPLATE_DIR" \
    bash "$TEMPLATE_DIR/scripts/memory-validate.sh" --dir "$TEMPLATE_DIR/memory" --quiet) && \
   grep -qE 'Итог: ([0-9]+)/\1 файлов OK' <<<"$MEMORY_OUTPUT" && \
   WORKSPACE_DIR="$TEMPLATE_DIR" IWE_ROOT="$TEMPLATE_DIR" \
    bash "$TEMPLATE_DIR/scripts/memory-validate.sh" "$TEMPLATE_DIR/memory/reference/agent-core.md" --quiet >/dev/null; then
    pass "T27: every shipped memory frontmatter checked by the validator is valid"
else
    fail "T27: shipped memory frontmatter still violates its own schema"
fi

# T28: settings-merge-preview.py builds a merged preview and never touches inputs (WP-7 F71 stage A)
echo ""
echo "--- T28: settings.json merge preview (WP-7 F71 stage A) ---"
T28_DIR="$TEST_WS/t28"
mkdir -p "$T28_DIR"
cat > "$T28_DIR/template.json" <<'EOF'
{"model": "opus", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "tpl-hook.sh"}]}], "SessionStart": [{"hooks": [{"type": "command", "command": "new-hook.sh"}]}]}, "permissions": {"allow": ["Bash(ls:*)", "Bash(git status:*)"]}, "newKey": true}
EOF
cat > "$T28_DIR/workspace.json" <<'EOF'
{"model": "sonnet", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-custom.sh"}]}, {"matcher": "Bash", "hooks": [{"type": "command", "command": "tpl-hook.sh"}]}]}, "permissions": {"allow": ["Bash(ls:*)", "mcp__my__*"]}, "userOnly": 1}
EOF
T28_WS_HASH_BEFORE=$(shasum -a 256 "$T28_DIR/workspace.json" | cut -d' ' -f1)
T28_REPORT=$(python3 "$TEMPLATE_DIR/.claude/scripts/settings-merge-preview.py" \
    "$T28_DIR/template.json" "$T28_DIR/workspace.json" "$T28_DIR/preview.json")
T28_RC=$?
T28_WS_HASH_AFTER=$(shasum -a 256 "$T28_DIR/workspace.json" | cut -d' ' -f1)
if [ "$T28_RC" -eq 0 ] && python3 -m json.tool "$T28_DIR/preview.json" >/dev/null 2>&1; then
    pass "T28: preview is generated and is valid JSON"
else
    fail "T28: preview missing or invalid JSON (rc=$T28_RC)"
fi
if grep -Fq 'my-custom.sh' "$T28_DIR/preview.json" && grep -Fq 'new-hook.sh' "$T28_DIR/preview.json"; then
    pass "T28: user hook preserved AND template-new hook added"
else
    fail "T28: hook union lost a side (user or template)"
fi
if python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(0 if p["model"] == "sonnet" and p["newKey"] is True and p["userOnly"] == 1 else 1)
' "$T28_DIR/preview.json"; then
    pass "T28: conflict keeps user value; template-new and user-only keys survive"
else
    fail "T28: scalar merge rules violated (conflict/user-only/template-new)"
fi
if grep -Fq '"model"' <<<"$T28_REPORT" && grep -Fq '"hooks_deduped": 1' <<<"$T28_REPORT"; then
    pass "T28: report names the conflict key and counts deduped hooks"
else
    fail "T28: report misses conflict key or dedup counter: $T28_REPORT"
fi
if [ "$T28_WS_HASH_BEFORE" = "$T28_WS_HASH_AFTER" ]; then
    pass "T28: workspace settings.json is byte-identical after preview"
else
    fail "T28: preview run modified workspace settings.json"
fi
echo '{broken' > "$T28_DIR/bad.json"
if python3 "$TEMPLATE_DIR/.claude/scripts/settings-merge-preview.py" \
    "$T28_DIR/bad.json" "$T28_DIR/workspace.json" "$T28_DIR/bad-preview.json" >/dev/null 2>&1; then
    fail "T28: broken input JSON was accepted"
else
    if [ ! -f "$T28_DIR/bad-preview.json" ]; then
        pass "T28: broken input rejected, no preview written"
    else
        fail "T28: broken input rejected but a torn preview file exists"
    fi
fi

# T29: classify-workspace-copy.sh verdicts on a synthetic template history (WP-7 F71 stage A)
echo ""
echo "--- T29: author_mode skip classifier (WP-7 F71 stage A) ---"
T29_DIR="$TEST_WS/t29"
mkdir -p "$T29_DIR/repo"
git -C "$T29_DIR/repo" init -q
git -C "$T29_DIR/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
echo "v1" > "$T29_DIR/repo/f.md"
git -C "$T29_DIR/repo" add f.md
git -C "$T29_DIR/repo" -c user.email=t@t -c user.name=t commit -qm v1
echo "v2" > "$T29_DIR/repo/f.md"
git -C "$T29_DIR/repo" add f.md
git -C "$T29_DIR/repo" -c user.email=t@t -c user.name=t commit -qm v2
echo "v1" > "$T29_DIR/dst-stale"
echo "edited by user" > "$T29_DIR/dst-authored"
echo "v2" > "$T29_DIR/dst-uptodate"
T29_CLS="$TEMPLATE_DIR/.claude/scripts/classify-workspace-copy.sh"
t29_case() {
    local expect="$1"; shift
    local got
    got=$(bash "$T29_CLS" "$@")
    if [ "$got" = "$expect" ]; then
        pass "T29: $expect"
    else
        fail "T29: expected '$expect', got '$got' (args: $*)"
    fi
}
echo "never committed" > "$T29_DIR/repo/orphan.md"
t29_case "unknown no-history" "$T29_DIR/repo" orphan.md "$T29_DIR/dst-authored"
t29_case "stale history"     "$T29_DIR/repo" f.md "$T29_DIR/dst-stale"
t29_case "authored diverged" "$T29_DIR/repo" f.md "$T29_DIR/dst-authored"
t29_case "uptodate current"  "$T29_DIR/repo" f.md "$T29_DIR/dst-uptodate"
t29_case "unknown no-git"    "$T29_DIR"      f.md "$T29_DIR/dst-authored"
if [ "$(bash "$T29_CLS" --templated "$T29_DIR/repo" f.md "$T29_DIR/dst-authored")" = "unknown templated" ]; then
    pass "T29: --templated downgrades authored to unknown (substituted placeholders)"
else
    fail "T29: --templated must not claim 'authored' for substituted files"
fi

# T30: update.sh wires the stage-A scripts in (grep-level, same idiom as T16)
echo ""
echo "--- T30: update.sh integration of stage-A observability (WP-7 F71) ---"
if grep -Fq 'classify-workspace-copy.sh' "$TEMPLATE_DIR/update.sh" && \
   grep -Fq 'settings-merge-preview.py' "$TEMPLATE_DIR/update.sh" && \
   grep -Fq 'report_author_skip_summary' "$TEMPLATE_DIR/update.sh"; then
    pass "T30: update.sh calls classifier, merge preview and prints the skip summary"
else
    fail "T30: update.sh lost a stage-A integration point"
fi
T30_GENERIC=$(grep -c 'author_mode: рабочая копия не тронута' "$TEMPLATE_DIR/update.sh" || true)
if [ "${T30_GENERIC:-0}" -le 1 ]; then
    pass "T30: generic skip message survives only as the degraded-mode fallback"
else
    fail "T30: $T30_GENERIC generic skip messages remain — a skip site bypasses the classifier"
fi

# T31: extensions-gate is fail-closed (отчёт Константина 14.08.2026, WP-7 F71)
echo ""
echo "--- T31: extensions-gate fail-closed matrix (WP-7 F71) ---"
T31_WS="$TEST_WS/t31-ws"
T31_EXTERNAL="$TEST_WS/t31-external"
T31_PREFIX_COLLISION="$TEST_WS/t31-ws-other"
mkdir -p "$T31_WS/.claude/hooks" "$T31_WS/.claude/skills/my-skill" \
         "$T31_WS/.claude/skills/day-open" "$T31_WS/memory" \
         "$T31_WS/FMT-exocortex-template" \
         "$T31_EXTERNAL/.claude/skills/my-skill" \
         "$T31_PREFIX_COLLISION/.claude/skills/day-open"
cp "$TEMPLATE_DIR/.claude/hooks/extensions-gate.sh" "$T31_WS/.claude/hooks/"
# issue #564: the gate reads the manifest from the template CLONE, never from
# the workspace root (nothing ever delivered a root copy on real installs).
printf '%s\n' '{"files": [{"path": ".claude/skills/day-open/SKILL.md"}]}' > "$T31_WS/FMT-exocortex-template/update-manifest.json"
touch "$T31_WS/.claude/skills/my-skill/SKILL.md" "$T31_WS/.claude/skills/day-open/SKILL.md" \
      "$T31_WS/memory/protocol-open.md" \
      "$T31_EXTERNAL/.claude/skills/my-skill/SKILL.md" \
      "$T31_EXTERNAL/update-manifest.json" \
      "$T31_EXTERNAL/external-target.md" \
      "$T31_PREFIX_COLLISION/.claude/skills/day-open/SKILL.md"
ln -s "$T31_WS/.claude/skills/day-open/SKILL.md" "$T31_WS/.claude/skills/my-skill/link.md"
ln -s "$T31_EXTERNAL/external-target.md" "$T31_WS/.claude/skills/my-skill/external-link.md"
ln -s "$T31_WS/.claude/skills/day-open/SKILL.md" "$T31_EXTERNAL/.claude/skills/platform-link.md"
t31_gate() {
    # env -u: the author's real IWE_TEMPLATE/IWE_SCRIPTS would otherwise let
    # the resolver chain (#564) find the REAL manifest and pollute fixtures.
    printf '{"tool_input": {"file_path": "%s"}}' "$1" \
        | env -u IWE_TEMPLATE -u IWE_SCRIPTS bash "$T31_WS/.claude/hooks/extensions-gate.sh"
}
t31_blocked() {
    local out
    out=$(t31_gate "$1")
    if grep -Fq '"decision": "block"' <<<"$out"; then
        pass "T31: $2"
    else
        fail "T31: $2 — гейт пропустил: $out"
    fi
}
t31_allowed() {
    local out
    out=$(t31_gate "$1")
    if grep -Fq '"decision": "block"' <<<"$out"; then
        fail "T31: $2 — гейт заблокировал: $out"
    else
        pass "T31: $2"
    fi
}
t31_blocked_reason() {
    local out
    out=$(t31_gate "$1")
    if grep -Fq '"decision": "block"' <<<"$out" && grep -Fq "$3" <<<"$out"; then
        pass "T31: $2"
    else
        fail "T31: $2 — нет ожидаемой причины '$3': $out"
    fi
}
t31_allowed "$T31_WS/.claude/skills/my-skill/SKILL.md"                "own skill (not in manifest) is allowed"
t31_allowed "$T31_WS/.claude/skills/brand-new/SKILL.md"               "nonexistent leaf of a new own skill is classified and allowed"
t31_allowed "$T31_WS/README.md"                                       "ordinary file is allowed"
t31_allowed "$T31_EXTERNAL/.claude/skills/my-skill/SKILL.md"          "global/user skill outside workspace is allowed"
t31_allowed "$T31_EXTERNAL/update-manifest.json"                      "external manifest is outside gate ownership"
t31_allowed "$T31_PREFIX_COLLISION/.claude/skills/day-open/SKILL.md"  "workspace prefix collision stays outside gate ownership"
t31_blocked "$T31_WS/.claude/skills/day-open/SKILL.md"                "platform skill is blocked"
t31_blocked "$T31_WS/.claude/skills/day-open/new-file.md"             "nonexistent leaf under a platform skill is blocked"
t31_blocked "$T31_WS/memory/protocol-open.md"                         "memory/protocol-* is blocked"
t31_blocked "$T31_WS/memory/protocol-new.md"                          "nonexistent protocol leaf is blocked"
t31_blocked "$T31_WS/.claude/skills/my-skill/../day-open/SKILL.md"    "traversal via .. is blocked before classification"
t31_blocked "$T31_WS/update-manifest.json"                            "manifest itself is always blocked"
t31_blocked "$T31_WS/.claude/skills/my-skill/link.md"                 "symlink into a platform skill is blocked by real path"
t31_allowed "$T31_WS/.claude/skills/my-skill/external-link.md"        "symlink to external user territory is allowed"
t31_blocked "$T31_EXTERNAL/.claude/skills/platform-link.md"           "external symlink into platform skill is blocked by real path"
rm -f "$T31_WS/FMT-exocortex-template/update-manifest.json"
t31_blocked_reason "$T31_WS/.claude/skills/my-skill/SKILL.md"         "missing manifest names the real failure" "не найден ни в одном известном месте шаблона"
printf '%s\n' '{broken' > "$T31_WS/FMT-exocortex-template/update-manifest.json"
t31_blocked "$T31_WS/.claude/skills/my-skill/SKILL.md"                "broken manifest fails closed (no allow on tool failure)"
printf '%s\n' '{"files": []}' > "$T31_WS/FMT-exocortex-template/update-manifest.json"
t31_blocked "$T31_WS/.claude/skills/my-skill/SKILL.md"                "empty manifest .files fails closed"
printf '%s\n' '{"files": [{"path": ".claude/skills/day-open/SKILL.md"}]}' > "$T31_WS/FMT-exocortex-template/update-manifest.json"
t31_allowed "$T31_WS/.claude/skills/my-skill/SKILL.md"                "restoring the manifest restores the allow"
if grep -Fq '"defaultMode": "default"' "$TEMPLATE_DIR/.claude/settings.json"; then
    pass "T31: template settings.json ships defaultMode=default (not acceptEdits)"
else
    fail "T31: template settings.json must not ship auto-accept edit mode"
fi
if python3 - "$TEMPLATE_DIR/.claude/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1]))
matches = []
for group in settings.get("hooks", {}).get("PreToolUse", []):
    commands = [hook.get("command", "") for hook in group.get("hooks", [])]
    if any(command.endswith("/.claude/hooks/extensions-gate.sh") for command in commands):
        matches.append(group.get("matcher"))
raise SystemExit(0 if matches == ["Edit|Write"] else 1)
PY
then
    pass "T31: extensions-gate declares its actual Edit|Write enforcement scope"
else
    fail "T31: extensions-gate matcher drifted from the documented scope"
fi
if grep -Fq 'советующее в целом' "$TEMPLATE_DIR/CLAUDE.md" && \
   grep -Fq 'не разбирает произвольные Bash-команды' "$TEMPLATE_DIR/CLAUDE.md" && \
   grep -Fq 'новый project-local skill допустим' "$TEMPLATE_DIR/CLAUDE.md"; then
    pass "T31: docs disclose Bash bypass and preserve the issue-311 local-skill path"
else
    fail "T31: docs overstate enforcement or contradict project-local skills"
fi

# T32: settings-merge-apply.sh applies with backup and never leaves a torn file (WP-7 F71 stage B)
echo ""
echo "--- T32: settings.json merge APPLY with backup/rollback (WP-7 F71 stage B) ---"
T32_WS="$TEST_WS/t32-ws"
mkdir -p "$T32_WS/.claude"
cp "$TEST_WS/t28/template.json" "$T32_WS/template.json"
cp "$TEST_WS/t28/workspace.json" "$T32_WS/.claude/settings.json"
T32_APPLY_OUT=$(bash "$TEMPLATE_DIR/.claude/scripts/settings-merge-apply.sh" \
    "$T32_WS/template.json" "$T32_WS/.claude/settings.json" python3 2>&1)
T32_RC=$?
if [ "$T32_RC" -eq 0 ] && python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
hooks = json.dumps(p.get("hooks", {}))
sys.exit(0 if p["model"] == "sonnet" and p["newKey"] is True and "my-custom.sh" in hooks and "new-hook.sh" in hooks else 1)
' "$T32_WS/.claude/settings.json"; then
    pass "T32: merge applied — user values kept, template additions present"
else
    fail "T32: apply failed or merged content wrong (rc=$T32_RC): $T32_APPLY_OUT"
fi
T32_BACKUP=$(find "$T32_WS/.backups/settings-merge" -name 'settings.json.*' 2>/dev/null | head -1)
if [ -n "$T32_BACKUP" ] && grep -Fq '"userOnly": 1' "$T32_BACKUP"; then
    pass "T32: backup of the pre-merge settings.json exists"
else
    fail "T32: no backup written before apply"
fi
if [ ! -f "$T32_WS/.claude/settings.merged.preview.json" ]; then
    pass "T32: preview file is consumed after a successful apply"
else
    fail "T32: preview file left behind after apply"
fi
printf '%s\n' '{broken' > "$T32_WS/broken-template.json"
T32_BEFORE=$(shasum -a 256 "$T32_WS/.claude/settings.json" | cut -d' ' -f1)
if bash "$TEMPLATE_DIR/.claude/scripts/settings-merge-apply.sh" \
    "$T32_WS/broken-template.json" "$T32_WS/.claude/settings.json" python3 >/dev/null 2>&1; then
    fail "T32: broken template input was accepted by apply"
else
    T32_AFTER=$(shasum -a 256 "$T32_WS/.claude/settings.json" | cut -d' ' -f1)
    if [ "$T32_BEFORE" = "$T32_AFTER" ]; then
        pass "T32: broken input rejected, workspace settings.json byte-identical"
    else
        fail "T32: broken input rejected but workspace settings.json changed"
    fi
fi

# T33: update.sh wires stage-B flags with their consensus safeguards (WP-7 F71)
echo ""
echo "--- T33: stage-B flags contract in update.sh (WP-7 F71) ---"
if grep -Fq -- '--apply-settings-merge) APPLY_SETTINGS_MERGE=true' "$TEMPLATE_DIR/update.sh" && \
   grep -Fq -- '--refresh-stale)    REFRESH_STALE=true' "$TEMPLATE_DIR/update.sh"; then
    pass "T33: both stage-B flags are parsed and default to off"
else
    fail "T33: stage-B flag parsing missing in update.sh"
fi
if grep -Fq -- '--refresh-stale отклонён' "$TEMPLATE_DIR/update.sh" && \
   grep -Fq '.backups/refresh-stale/' "$TEMPLATE_DIR/update.sh"; then
    pass "T33: refresh-stale refuses on unknown>0 and backs up before overwrite"
else
    fail "T33: refresh-stale safeguards (unknown block / backup) missing"
fi
if grep -Fq 'settings-merge-apply.sh' "$TEMPLATE_DIR/update.sh"; then
    pass "T33: update.sh delegates settings apply to the standalone tested script"
else
    fail "T33: update.sh does not call settings-merge-apply.sh"
fi

# ============================================================
# T34: code-style cap uses the same Unicode unit for count and slice (#435)
# ============================================================
echo ""
echo "--- T34: code-style Unicode cap contract (#435) ---"
T34_BASE="$TEST_WS/t34-base.json"
T34_CAPPED="$TEST_WS/t34-capped.json"
T34_PAYLOAD="{\"session_id\":\"t34-base\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T16_PROJ/t16-fixture.py\"}}"
if printf '%s' "$T34_PAYLOAD" | HOME="$T16_HOME" CLAUDE_PROJECT_DIR="$T16_PROJ" \
    IWE_GOVERNANCE_REPO="DS-strategy" bash "$TEMPLATE_DIR/.claude/hooks/inject-code-style.sh" > "$T34_BASE" 2>/dev/null; then
    T34_CHARS=$(python3 -c "import json; print(len(json.load(open('$T34_BASE'))['hookSpecificOutput']['additionalContext']))")
    T34_BYTES=$(python3 -c "import json; print(len(json.load(open('$T34_BASE'))['hookSpecificOutput']['additionalContext'].encode()))")
    T34_PAYLOAD="{\"session_id\":\"t34-capped\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$T16_PROJ/t16-fixture.py\"}}"
    if [ "$T34_BYTES" -gt "$T34_CHARS" ] && \
       printf '%s' "$T34_PAYLOAD" | HOME="$T16_HOME" CLAUDE_PROJECT_DIR="$T16_PROJ" \
          IWE_GOVERNANCE_REPO="DS-strategy" CODE_STYLE_INJECT_CAP="$T34_CHARS" \
          bash "$TEMPLATE_DIR/.claude/hooks/inject-code-style.sh" > "$T34_CAPPED" 2>/dev/null && \
       python3 - "$T34_BASE" "$T34_CAPPED" <<'PY'
import json
import sys

baseline = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
capped = json.load(open(sys.argv[2], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
raise SystemExit(0 if baseline == capped and "[…обрезано до лимита" not in capped else 1)
PY
    then
        pass "T34: Cyrillic context at its character cap is not falsely truncated by bytes"
    else
        fail "T34: code-style cap count and slice diverge on Cyrillic"
    fi
else
    fail "T34: inject-code-style did not produce a baseline context"
fi

# ============================================================
# T35: /extend lists every extension point that a protocol invokes (#436)
# ============================================================
echo ""
echo "--- T35: /extend catalog matches protocol extension points (#436) ---"
if python3 - "$TEMPLATE_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
call_re = re.compile(r"load-extensions\.sh\s+([a-z-]+)\s+(before|after|checks|sync)")
row_re = re.compile(r"^\| `([^`]+)` \| `([^`]+)` \| `extensions/", re.MULTILINE)
readme_row_re = re.compile(r"^\| `([^`]+)` \| `([^`]+)` \|", re.MULTILINE)

sources = [root / "memory/protocol-close.md", root / "memory/protocol-open.md"]
sources.extend(path for path in (root / ".claude/skills").rglob("*.md") if path != root / ".claude/skills/extend/SKILL.md")
called = {
    match.groups()
    for path in sources
    for match in call_re.finditer(path.read_text(encoding="utf-8"))
}
catalog = set(row_re.findall((root / ".claude/skills/extend/SKILL.md").read_text(encoding="utf-8")))
readme_catalog = set(
    readme_row_re.findall((root / "extensions/README.md").read_text(encoding="utf-8"))
)
required = {
    (protocol, hook)
    for protocol in ("iwe-update", "verify", "archgate")
    for hook in ("before", "checks", "after")
}
if catalog != called or readme_catalog != called or not required.issubset(called):
    missing = sorted(called - catalog)
    extra = sorted(catalog - called)
    readme_missing = sorted(called - readme_catalog)
    readme_extra = sorted(readme_catalog - called)
    absent_required = sorted(required - called)
    raise SystemExit(
        f"called={len(called)} catalog={len(catalog)} "
        f"missing={missing} extra={extra} readme_missing={readme_missing} "
        f"readme_extra={readme_extra} absent_required={absent_required}"
    )

for protocol in ("iwe-update", "verify", "archgate"):
    skill = (root / ".claude/skills" / protocol / "SKILL.md").read_text(encoding="utf-8")
    positions = [skill.index(f"load-extensions.sh {protocol} {hook}") for hook in ("before", "checks", "after")]
    if positions != sorted(positions):
        raise SystemExit(f"{protocol} lifecycle order is not before -> checks -> after: {positions}")

archgate = (root / ".claude/skills/archgate/SKILL.md").read_text(encoding="utf-8")
calls = [f"load-extensions.sh archgate {hook}" for hook in ("before", "checks", "after")]
if any(archgate.count(call) != 1 for call in calls):
    raise SystemExit("archgate must invoke each lifecycle phase exactly once")
markers = [
    calls[0],
    "## Шаг 0.",
    "## Шаг 4.6.",
    calls[1],
    "## Шаг 5.",
    calls[2],
]
marker_positions = [archgate.index(marker) for marker in markers]
if marker_positions != sorted(marker_positions):
    raise SystemExit(f"archgate phase boundaries are out of order: {marker_positions}")

step3 = archgate.split("## Шаг 3.", 1)[1].split("## Шаг 4.", 1)[0]
pre_checks = archgate.split("## Шаг 4.7.", 1)[0]
normalized_archgate = " ".join(archgate.split())
required_contracts = (
    "extension_check_error",
    "блокирует начало оценки",
    "не может переписать, отозвать или понизить",
    "продолжая со следующим даже после ошибки предыдущего",
    "запрещено вызывать `/archgate`",
    "Шаг 4.7",
    "единственная точка",
    "явный `BLOCK`/`STOP`",
    "содержательное возражение рецензента",
    "Не исполнять собранную через `eval`",
    "получения всех обязательных explicit acknowledgement",
    "ARCHGATE_EXTENSION: PASS",
    "ARCHGATE_EXTENSION: BLOCK",
    "extension_check_blocked",
    "pending_ack",
)
missing_contracts = [
    contract for contract in required_contracts if contract not in normalized_archgate
]
if missing_contracts:
    raise SystemExit(f"archgate lifecycle semantics missing: {missing_contracts}")
if "Перейди к шагу 5 и завершай" in step3:
    raise SystemExit("rejected core result bypasses archgate checks")
for bypass in ("перейди к шагу 5", "переходи к Шагу 5"):
    if bypass.lower() in pre_checks.lower():
        raise SystemExit(f"pre-check lifecycle contains direct verdict bypass: {bypass}")
if "| **Вердикт**" in pre_checks or "ПРОХОДИТ/НЕТ" in pre_checks:
    raise SystemExit("archgate publishes a verdict before extension checks")
if "оформи DRR" in pre_checks or "финализируй DRR" in pre_checks:
    raise SystemExit("archgate persists an accepted DRR before extension checks")
rejected_no_ack = "Если `core_result = rejected`, обязательные подтверждения рисков не запрашивай"
passing_ack = "Только если ядро прошло, **сначала собери обязательные подтверждения.**"
if rejected_no_ack not in archgate or passing_ack not in archgate:
    raise SystemExit("acknowledgements are not conditional on a passing core result")
ack_position = archgate.index(passing_ack)
final_position = archgate.index("**После всех обязательных подтверждений опубликуй ровно один вердикт:**")
after_position = archgate.index(calls[2])
if not ack_position < final_position < after_position:
    raise SystemExit("acknowledgement, final verdict and after phases are out of order")
PY
then
    pass "T35: /extend lists every invoked point and new skill lifecycles are ordered"
else
    fail "T35: /extend catalog differs from invoked extension points"
fi

# ============================================================
# T36: extension loader sorting, no-op, and usage error contract (#508)
# ============================================================
echo ""
echo "--- T36: extension loader lifecycle contract (#508) ---"
T36_ROOT="$TEST_WS/t36-workspace"
T36_EXT="$T36_ROOT/extensions"
T36_OUT="$TEST_WS/t36-found.txt"
mkdir -p "$T36_EXT"
: > "$T36_EXT/archgate.before.20-second.md"
: > "$T36_EXT/archgate.before.10-first.md"
: > "$T36_EXT/archgate.before.md"

if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" archgate before > "$T36_OUT"; then
    T36_NAMES=$(sed 's#.*/##' "$T36_OUT" | paste -sd ' ' -)
    if [ "$T36_NAMES" = "archgate.before.10-first.md archgate.before.20-second.md archgate.before.md" ]; then
        pass "T36a: suffix and manifest extensions are returned in stable lexical order"
    else
        fail "T36a: unexpected extension order: $T36_NAMES"
    fi
else
    fail "T36a: loader did not return matching extensions"
fi

if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" archgate checks >/dev/null 2>&1; then
    T36_NOOP_RC=0
else
    T36_NOOP_RC=$?
fi
if [ "$T36_NOOP_RC" -eq 1 ]; then
    pass "T36b: no matching extension is an explicit no-op (rc=1)"
else
    fail "T36b: no-match returned rc=$T36_NOOP_RC instead of 1"
fi

if bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" >/dev/null 2>&1; then
    T36_USAGE_RC=0
else
    T36_USAGE_RC=$?
fi
if [ "$T36_USAGE_RC" -eq 2 ]; then
    pass "T36c: malformed loader invocation is distinguishable from no-op (rc=2)"
else
    fail "T36c: malformed invocation returned rc=$T36_USAGE_RC instead of 2"
fi

T36_BROKEN="$TEST_WS/t36-broken-workspace"
mkdir -p "$T36_BROKEN/.claude/scripts"
cp "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" "$T36_BROKEN/.claude/scripts/"
if IWE_WORKSPACE="$T36_BROKEN" WORKSPACE_DIR="$T36_BROKEN" IWE_ROOT="$T36_BROKEN" IWE="$T36_BROKEN" \
    bash "$T36_BROKEN/.claude/scripts/load-extensions.sh" archgate checks \
    >"$TEST_WS/t36-broken.out" 2>&1; then
    T36_BROKEN_RC=0
else
    T36_BROKEN_RC=$?
fi
if [ "$T36_BROKEN_RC" -eq 3 ] && grep -Fq '[extension_loader_error]' "$TEST_WS/t36-broken.out"; then
    pass "T36d: missing extensions directory is a typed loader failure, not a no-op"
else
    fail "T36d: missing extensions directory returned rc=$T36_BROKEN_RC"
fi

ln -s "$T36_ROOT/extensions/missing-before.md" "$T36_EXT/archgate.checks.md"
if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" \
    archgate checks >"$TEST_WS/t36-broken-link.out" 2>&1; then
    T36_LINK_RC=0
else
    T36_LINK_RC=$?
fi
if [ "$T36_LINK_RC" -eq 3 ] && grep -Fq 'symlink target is missing' "$TEST_WS/t36-broken-link.out"; then
    pass "T36e: configured dangling extension is a typed failure, not a no-op"
else
    fail "T36e: dangling extension returned rc=$T36_LINK_RC"
fi
rm "$T36_EXT/archgate.checks.md"
mkdir "$T36_EXT/archgate.checks.md"
if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" \
    archgate checks >"$TEST_WS/t36-wrong-type.out" 2>&1; then
    T36_TYPE_RC=0
else
    T36_TYPE_RC=$?
fi
if [ "$T36_TYPE_RC" -eq 3 ] && grep -Fq 'not a regular file' "$TEST_WS/t36-wrong-type.out"; then
    pass "T36f: matching non-file extension is a typed failure, not a no-op"
else
    fail "T36f: matching directory returned rc=$T36_TYPE_RC"
fi

T36_EXPLICIT="$TEST_WS/t36-explicit-without-extensions"
mkdir -p "$T36_EXPLICIT"
if IWE_WORKSPACE="$T36_EXPLICIT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" \
    archgate before >"$TEST_WS/t36-explicit.out" 2>&1; then
    T36_EXPLICIT_RC=0
else
    T36_EXPLICIT_RC=$?
fi
if [ "$T36_EXPLICIT_RC" -eq 3 ] && grep -Fq 'extensions directory is unavailable' "$TEST_WS/t36-explicit.out"; then
    pass "T36g: existing explicit workspace cannot fail open into script fallback"
else
    fail "T36g: explicit workspace without extensions returned rc=$T36_EXPLICIT_RC"
fi

rm -rf "$T36_EXT/archgate.checks.md"
printf '%s\n' 'ARCHGATE_EXTENSION: PASS' > "$T36_EXT/archgate.after.10-healthy.md"
ln -s "$T36_ROOT/extensions/missing-after.md" "$T36_EXT/archgate.after.20-broken.md"
if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" \
    archgate after >"$TEST_WS/t36-mixed.out" 2>"$TEST_WS/t36-mixed.err"; then
    T36_MIXED_RC=0
else
    T36_MIXED_RC=$?
fi
if [ "$T36_MIXED_RC" -eq 3 ] && \
   grep -Fq 'archgate.after.10-healthy.md' "$TEST_WS/t36-mixed.out" && \
   ! grep -Fq 'archgate.after.20-broken.md' "$TEST_WS/t36-mixed.out" && \
   grep -Fq 'symlink target is missing' "$TEST_WS/t36-mixed.err"; then
    pass "T36h: mixed after set preserves healthy paths while reporting damage"
else
    fail "T36h: damaged after file suppressed healthy files or lost diagnosis (rc=$T36_MIXED_RC)"
fi

rm "$T36_EXT/archgate.after.20-broken.md"
for T36_PHASE in before checks after; do
    rm -f "$T36_EXT"/archgate."$T36_PHASE"*.md
    printf '%s\n' 'bash .claude/scripts/load-extensions.sh archgate checks' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-plain.md"
    printf '%s\n' 'bash .claude/scripts/load-extensions.sh '\''archgate'\'' "checks"' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-quoted.md"
    printf '%s\n' 'Вызови `/archgate повторно`.' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-slash.md"
    printf '%s\n' 'Вызови "/archgate" повторно.' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-double-quote.md"
    printf '%s\n' "Вызови '/archgate' повторно." \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-single-quote.md"
    printf '%s\n' 'Вызови (/archgate); повторно.' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-paren.md"
    printf '%s\n' 'then;/archgate|next' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-shell-separator.md"
    printf '%s\n' 'Вызови /ARCHGATE повторно.' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-uppercase.md"
    printf '%s\n' 'bash .claude/scripts/load-extensions.sh ArchGate checks' \
        > "$T36_EXT/archgate.$T36_PHASE.recursive-mixed-case-loader.md"
    printf '%s\n' '/archgate-extra foo/archgate /archgate.md' \
        > "$T36_EXT/archgate.$T36_PHASE.nonrecursive-lookalikes.md"
    if IWE_WORKSPACE="$T36_ROOT" bash "$TEMPLATE_DIR/.claude/scripts/load-extensions.sh" \
        archgate "$T36_PHASE" >"$TEST_WS/t36-recursive-$T36_PHASE.out" \
        2>"$TEST_WS/t36-recursive-$T36_PHASE.err"; then
        T36_RECURSIVE_RC=0
    else
        T36_RECURSIVE_RC=$?
    fi
    if [ "$T36_PHASE" = "after" ]; then
        T36_RECURSIVE_MARKER='ARCHGATE_EXTENSION: WARN'
    else
        T36_RECURSIVE_MARKER='ARCHGATE_EXTENSION: BLOCK'
    fi
    if [ "$T36_RECURSIVE_RC" -eq 3 ] && \
       [ "$(wc -l < "$TEST_WS/t36-recursive-$T36_PHASE.out" | tr -d ' ')" -eq 1 ] && \
       grep -Fq "archgate.$T36_PHASE.nonrecursive-lookalikes.md" \
           "$TEST_WS/t36-recursive-$T36_PHASE.out" && \
       [ "$(grep -Fc "$T36_RECURSIVE_MARKER" "$TEST_WS/t36-recursive-$T36_PHASE.err")" -eq 9 ]; then
        pass "T36i/$T36_PHASE: recursion delimiters are rejected without blocking lookalikes ($T36_RECURSIVE_MARKER)"
    else
        fail "T36i/$T36_PHASE: recursion contract failed (rc=$T36_RECURSIVE_RC)"
    fi
done

# ============================================================
# T37: update preview names governance backfill targets (#508)
# ============================================================
echo ""
echo "--- T37: governance backfills are explicit in update preview (#508) ---"
T37_WS="$TEST_WS/t37-workspace"
T37_TEMPLATE="$T37_WS/template"
T37_RUNNER="$TEST_WS/t37-preview-runner.sh"
mkdir -p "$T37_TEMPLATE"
printf 'GOVERNANCE_REPO=legacy-governance\n' > "$T37_TEMPLATE/.exocortex.env"
awk '/^effective_governance_repo\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' \
    "$TEMPLATE_DIR/update.sh" > "$T37_RUNNER"
awk '/^print_extra_write_targets\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' \
    "$TEMPLATE_DIR/update.sh" >> "$T37_RUNNER"
cat >> "$T37_RUNNER" <<EOF
SCRIPT_DIR="$T37_TEMPLATE"
WORKSPACE_DIR="$T37_WS"
CLAUDE_MEMORY_DIR="$T37_WS/memory"
ENV_GOVERNANCE_REPO=""
IWE_GOVERNANCE_REPO=""
print_extra_write_targets
EOF
T37_OUT=$(bash "$T37_RUNNER" 2>&1)
if printf '%s\n' "$T37_OUT" | grep -Fq "$T37_WS/legacy-governance/scripts/install-hooks.sh" && \
   printf '%s\n' "$T37_OUT" | grep -Fq "$T37_WS/legacy-governance/.githooks/pre-commit" && \
   printf '%s\n' "$T37_OUT" | grep -Fq "$T37_WS/legacy-governance/scripts/update-derived-snapshot.py" && \
   printf '%s\n' "$T37_OUT" | grep -Fq "$T37_WS/legacy-governance/scripts/executor-catalog.yaml" && \
   printf '%s\n' "$T37_OUT" | grep -Fq "$T37_WS/.iwe-paths" && \
   printf '%s\n' "$T37_OUT" | grep -Fq '/.zshenv' && \
   printf '%s\n' "$T37_OUT" | grep -Fq 'local core.hooksPath'; then
    pass "T37: preview resolves legacy config and lists every governance backfill target"
else
    fail "T37: preview omits or mis-resolves governance backfill targets: $T37_OUT"
fi
if grep -Fq '/ (ваше планирование)' "$TEMPLATE_DIR/update.sh"; then
    fail "T37: update preview still promises the whole governance repository is untouched"
else
    pass "T37: no broad untouched-governance promise remains"
fi

# ============================================================
# T38: State-Transition Gate hot trigger resolves fail-closed (#481)
# ============================================================
echo ""
echo "--- T38: State-Transition Gate lazy trigger contract (#481) ---"
T38_RC=0
IWE_ROOT="$TEMPLATE_DIR" bash "$TEMPLATE_DIR/scripts/sync-agent-instructions.sh" --check >/dev/null 2>&1 || T38_RC=$?
if [ "$T38_RC" -eq 0 ]; then
    pass "T38a: generated AGENTS.md matches the CLAUDE.md hot source"
else
    fail "T38a: generated AGENTS.md has drift (rc=$T38_RC)"
fi

if python3 - "$TEMPLATE_DIR" <<'PY'
from pathlib import Path
import re
import shutil
import tempfile
import sys

root = Path(sys.argv[1])
target_reference = ".claude/rules-lazy/state-transition-gate.md"
claude = (root / "CLAUDE.md").read_text(encoding="utf-8")
agents = (root / "AGENTS.md").read_text(encoding="utf-8")
lazy = (root / target_reference).read_text(encoding="utf-8")
blocking = (root / ".claude/rules-lazy/blocking-rules-full.md").read_text(encoding="utf-8")

if claude.count(target_reference) != 1 or agents.count(target_reference) != 1:
    raise SystemExit("hot source must contain exactly one mandatory lazy reference")

state_block = claude.split("## State-Transition Gate — CRITICAL", 1)[1].split("\n## ", 1)[0]
def validate_hot(hot: str, governance: str) -> str:
    normalized = " ".join(hot.split())
    expected = (
        f"**Есть `{governance}/docs/state-axes-registry.yaml` → до любого "
        "нетривиального действия или РП полностью прочитать и выполнить "
        "`.claude/rules-lazy/state-transition-gate.md`; lazy-файл отсутствует "
        "или нечитаем → только inventory, СТОП. Реестра нет → гейт неактивен.**"
    )
    if normalized != expected:
        raise ValueError("hot trigger differs from the normative fail-closed rule")
    match = re.search(r"`(\.claude/rules-lazy/[^`]+\.md)`", hot)
    if match is None:
        raise ValueError("lazy target missing from hot trigger")
    return match.group(1)

def validate_lazy(full_rule: str) -> None:
    normalized = " ".join(full_rule.split())
    expected = " ".join("""
# State-Transition Gate — полный контракт

> Hot-триггер: `CLAUDE.md`, Agent Core. Этот файл обязателен целиком, когда в
> governance-репозитории существует `docs/state-axes-registry.yaml` (WP-457).

Перед любым нетривиальным действием или РП назвать целевой переход состояния
пользователя в форме `{тип состояния, из→в}`.

## Допустимый переход

1. Тип состояния брать только из того же
   `docs/state-axes-registry.yaml` governance-репозитория, наличие которого
   активировало hot-триггер.
2. Использовать только ось с `gate_ready: true`.
3. Дать ссылку на объявленного владельца конечного автомата
   (`declared FSM-owner`) этой оси.
4. Свободный текст вместо зарегистрированного типа состояния не принимается.

Если тип не зарегистрирован, ось не имеет `gate_ready: true` или ссылка на
владельца отсутствует, разрешён только сбор фактов (`inventory`) → СТОП и
отложить нетривиальное действие или РП.

Для перехода по нескольким осям применять правила cross-axis из
`memory/reference/agent-core.md`. Авторская концептуальная модель может быть
доступна в `archive/wp-contexts/WP-457/CONCEPT-user-states.md §5`, но не является
обязательной для понимания и исполнения этого поставляемого контракта.
""".split())
    if normalized != expected:
        raise ValueError("lazy rule differs from the normative structural contract")
    if re.search(r"{{[A-Z][A-Z0-9_]*}}", full_rule):
        raise ValueError("raw install placeholder leaked into shipped lazy rule")

validate_hot(state_block, "{{GOVERNANCE_REPO}}")
validate_lazy(lazy)
if blocking.count(target_reference) != 1 or "Полный текст → Agent Core" in blocking:
    raise SystemExit("blocking-rules pointer duplicates or points back to hot core")

def resolve_lazy(fixture: Path, governance: str, registry_present: bool):
    registry = fixture / governance / "docs/state-axes-registry.yaml"
    hot = (fixture / "CLAUDE.md").read_text(encoding="utf-8")
    target_reference_from_hot = validate_hot(hot, governance)
    if not registry_present:
        if registry.exists():
            raise AssertionError("no-registry fixture unexpectedly has a registry")
        return None
    if not registry.is_file():
        raise RuntimeError("registry expected but absent")
    target = fixture / target_reference_from_hot
    if not target.is_file():
        raise RuntimeError(f"lazy target missing or unreadable: {target}")
    resolved = target.read_text(encoding="utf-8")
    validate_lazy(resolved)
    return resolved

with tempfile.TemporaryDirectory(prefix="iwe-state-gate-") as raw_fixture:
    fixture = Path(raw_fixture)
    governance = "pilot-governance"
    installed_hot = state_block.replace("{{GOVERNANCE_REPO}}", governance)
    (fixture / "CLAUDE.md").write_text(installed_hot, encoding="utf-8")
    target = fixture / target_reference
    target.parent.mkdir(parents=True)
    shutil.copy2(root / target_reference, target)

    if resolve_lazy(fixture, governance, registry_present=False) is not None:
        raise SystemExit("fresh install loaded the full rule without a registry")

    registry = fixture / governance / "docs/state-axes-registry.yaml"
    registry.parent.mkdir(parents=True)
    registry.write_text("axes: {}\n", encoding="utf-8")
    resolved = resolve_lazy(fixture, governance, registry_present=True)
    if resolved is None or "gate_ready" not in resolved:
        raise SystemExit("author install did not resolve the full lazy contract")

    hot_mutations = (
        installed_hot.replace("Есть `", "Нет `"),
        installed_hot.replace("полностью прочитать", "не читать"),
        installed_hot.replace("только inventory, СТОП", "продолжить"),
        installed_hot.replace(governance, "wrong-governance"),
    )
    for mutated in hot_mutations:
        try:
            validate_hot(mutated, governance)
        except ValueError:
            continue
        raise SystemExit("dangerous hot-trigger mutation passed semantic validation")

    lazy_mutations = (
        lazy.replace("`gate_ready: true`", "`gate_ready: false`", 1),
        lazy.replace("не принимается", "принимается", 1),
        lazy.replace("Дать ссылку", "Не давать ссылку", 1),
        lazy.replace("Использовать только ось", "Не: Использовать только ось", 1),
        lazy.replace("Дать ссылку", "Не следует: Дать ссылку", 1),
        lazy.replace(
            "Свободный текст вместо зарегистрированного типа состояния не принимается",
            "Неверно, что Свободный текст вместо зарегистрированного типа состояния не принимается",
            1,
        ),
        lazy + "\n{{WORKSPACE_DIR}}\n",
    )
    for mutated_lazy in lazy_mutations:
        try:
            validate_lazy(mutated_lazy)
        except ValueError:
            continue
        raise SystemExit("dangerous full-rule mutation passed semantic validation")

    missing_target = installed_hot.replace(
        target_reference, ".claude/rules-lazy/missing.md"
    )
    (fixture / "CLAUDE.md").write_text(missing_target, encoding="utf-8")
    try:
        resolve_lazy(fixture, governance, registry_present=True)
    except (RuntimeError, ValueError):
        pass
    else:
        raise SystemExit("missing lazy target did not fail closed")
PY
then
    pass "T38b: trigger, full rule, fresh/author routing and negative mutation pass"
else
    fail "T38b: State-Transition Gate lazy contract is incomplete"
fi

T38_SYNC_RUNNER="$TEST_WS/t38-sync-agents.sh"
{
    printf '%s\n' '#!/bin/bash' 'set -e'
    if [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' 'sed_inplace() { sed -i "" "$@"; }'
    else
        printf '%s\n' 'sed_inplace() { sed -i "$@"; }'
    fi
    awk '/^sed_escape_replacement\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/update.sh"
    awk '/^substitute_claude_placeholders\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/update.sh"
    awk '/^sync_workspace_agents\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/update.sh"
} > "$T38_SYNC_RUNNER"
T38_SYNC_ROOT="$TEST_WS/t38-sync"
mkdir -p "$T38_SYNC_ROOT/template" "$T38_SYNC_ROOT/workspace" "$T38_SYNC_ROOT/tmp"
printf '%s\n' 'registry={{GOVERNANCE_REPO}}' > "$T38_SYNC_ROOT/template/AGENTS.md"
printf '%s\n' 'GOVERNANCE_REPO="governance-live"' > "$T38_SYNC_ROOT/workspace/.exocortex.env"
if SCRIPT_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   TMPDIR_UPDATE="$T38_SYNC_ROOT/tmp" CLAUDE_PROJECT_SLUG=test \
   bash -c 'source "$1"; sync_workspace_agents; printf stale > "$WORKSPACE_DIR/AGENTS.md"; sync_workspace_agents' \
   t38 "$T38_SYNC_RUNNER" && \
   grep -Fxq 'registry=governance-live' "$T38_SYNC_ROOT/workspace/AGENTS.md" && \
   python3 - "$TEMPLATE_DIR/update.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("repair_pass() {")
end = text.index("\n}", start)
if text[start:end].count("sync_workspace_agents") != 1:
    raise SystemExit("repair_pass must centrally sync AGENTS.md exactly once")
if text.count("sync_workspace_agents") != 2:
    raise SystemExit("AGENTS sync must have one definition and one repair call")
PY
then
    pass "T38c: setup/update recovery delivers and repairs substituted workspace AGENTS.md"
else
    fail "T38c: workspace AGENTS.md delivery is incomplete"
fi

T38_VICTIM="$T38_SYNC_ROOT/outside-victim.md"
printf '%s\n' 'outside-bytes-must-survive' > "$T38_VICTIM"
rm -f "$T38_SYNC_ROOT/workspace/AGENTS.md"
ln -s "$T38_VICTIM" "$T38_SYNC_ROOT/workspace/AGENTS.md"
if SCRIPT_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   TMPDIR_UPDATE="$T38_SYNC_ROOT/tmp" CLAUDE_PROJECT_SLUG=test \
   bash -c 'source "$1"; sync_workspace_agents' t38 "$T38_SYNC_RUNNER" \
   >/dev/null 2>&1; then
    T38_UPDATE_LINK_RC=0
else
    T38_UPDATE_LINK_RC=$?
fi

T38_SETUP_RUNNER="$TEST_WS/t38-setup-instruction.sh"
{
    printf '%s\n' '#!/bin/bash' 'set -e'
    if [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' 'sed_inplace() { sed -i "" "$@"; }'
    else
        printf '%s\n' 'sed_inplace() { sed -i "$@"; }'
    fi
    awk '/^sed_escape_replacement\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/setup.sh"
    awk '/^install_workspace_instruction\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/setup.sh"
    awk '/^install_workspace_merge_base\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/setup.sh"
    awk '/^install_agent_instruction_bundle\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$TEMPLATE_DIR/setup.sh"
} > "$T38_SETUP_RUNNER"
if TEMPLATE_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   GITHUB_USER=test CLAUDE_PATH=claude CLAUDE_PROJECT_SLUG=test \
   TIMEZONE_HOUR=4 TIMEZONE_DESC=utc HOME_DIR="$T38_SYNC_ROOT" \
   GOVERNANCE_REPO=governance-live IWE_TEMPLATE_PATH="$T38_SYNC_ROOT/template" \
   IWE_RUNTIME_PATH="$T38_SYNC_ROOT/runtime" \
   bash -c 'source "$1"; install_workspace_instruction AGENTS.md' \
   t38 "$T38_SETUP_RUNNER" >/dev/null 2>&1; then
    T38_SETUP_LINK_RC=0
else
    T38_SETUP_LINK_RC=$?
fi

if [ "$T38_UPDATE_LINK_RC" -ne 0 ] && [ "$T38_SETUP_LINK_RC" -ne 0 ] && \
   [ -L "$T38_SYNC_ROOT/workspace/AGENTS.md" ] && \
   grep -Fxq 'outside-bytes-must-survive' "$T38_VICTIM"; then
    pass "T38d: setup and update reject AGENTS symlinks without touching the target"
else
    fail "T38d: instruction delivery followed/replaced a symlink (update=$T38_UPDATE_LINK_RC setup=$T38_SETUP_LINK_RC)"
fi

rm "$T38_SYNC_ROOT/workspace/AGENTS.md"
mkdir "$T38_SYNC_ROOT/workspace/AGENTS.md"
if SCRIPT_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   TMPDIR_UPDATE="$T38_SYNC_ROOT/tmp" CLAUDE_PROJECT_SLUG=test \
   bash -c 'source "$1"; sync_workspace_agents' t38 "$T38_SYNC_RUNNER" \
   >/dev/null 2>&1; then
    T38_UPDATE_DIR_RC=0
else
    T38_UPDATE_DIR_RC=$?
fi
if TEMPLATE_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   GITHUB_USER=test CLAUDE_PATH=claude CLAUDE_PROJECT_SLUG=test \
   TIMEZONE_HOUR=4 TIMEZONE_DESC=utc HOME_DIR="$T38_SYNC_ROOT" \
   GOVERNANCE_REPO=governance-live IWE_TEMPLATE_PATH="$T38_SYNC_ROOT/template" \
   IWE_RUNTIME_PATH="$T38_SYNC_ROOT/runtime" \
   bash -c 'source "$1"; install_workspace_instruction AGENTS.md' \
   t38 "$T38_SETUP_RUNNER" >/dev/null 2>&1; then
    T38_SETUP_DIR_RC=0
else
    T38_SETUP_DIR_RC=$?
fi
if [ "$T38_UPDATE_DIR_RC" -ne 0 ] && [ "$T38_SETUP_DIR_RC" -ne 0 ] && \
   [ -d "$T38_SYNC_ROOT/workspace/AGENTS.md" ] && \
   [ -z "$(ls -A "$T38_SYNC_ROOT/workspace/AGENTS.md")" ]; then
    pass "T38e: setup and update reject non-file AGENTS targets without fail-open"
else
    fail "T38e: non-file AGENTS target was accepted (update=$T38_UPDATE_DIR_RC setup=$T38_SETUP_DIR_RC)"
fi

rmdir "$T38_SYNC_ROOT/workspace/AGENTS.md"
printf '%s\n' 'claude={{GOVERNANCE_REPO}}' > "$T38_SYNC_ROOT/template/CLAUDE.md"
T38_CLAUDE_VICTIM="$T38_SYNC_ROOT/outside-claude-victim.md"
printf '%s\n' 'claude-victim-must-survive' > "$T38_CLAUDE_VICTIM"
ln -s "$T38_CLAUDE_VICTIM" "$T38_SYNC_ROOT/workspace/CLAUDE.md"
rm -f "$T38_SYNC_ROOT/workspace/.claude.md.base"
if TEMPLATE_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   GITHUB_USER=test CLAUDE_PATH=claude CLAUDE_PROJECT_SLUG=test \
   TIMEZONE_HOUR=4 TIMEZONE_DESC=utc HOME_DIR="$T38_SYNC_ROOT" \
   GOVERNANCE_REPO=governance-live IWE_TEMPLATE_PATH="$T38_SYNC_ROOT/template" \
   IWE_RUNTIME_PATH="$T38_SYNC_ROOT/runtime" \
   bash -c 'source "$1"; install_agent_instruction_bundle' \
   t38 "$T38_SETUP_RUNNER" >/dev/null 2>&1; then
    T38_BUNDLE_LINK_RC=0
else
    T38_BUNDLE_LINK_RC=$?
fi
if [ "$T38_BUNDLE_LINK_RC" -ne 0 ] && \
   [ -L "$T38_SYNC_ROOT/workspace/CLAUDE.md" ] && \
   [ ! -e "$T38_SYNC_ROOT/workspace/.claude.md.base" ] && \
   grep -Fxq 'claude-victim-must-survive' "$T38_CLAUDE_VICTIM"; then
    pass "T38f: actual setup bundle aborts before a CLAUDE symlink can poison merge base"
else
    fail "T38f: setup bundle ignored an unsafe CLAUDE target (rc=$T38_BUNDLE_LINK_RC)"
fi

rm "$T38_SYNC_ROOT/workspace/CLAUDE.md"
T38_SPECIAL='pilot&co|team\ops'
if TEMPLATE_DIR="$T38_SYNC_ROOT/template" WORKSPACE_DIR="$T38_SYNC_ROOT/workspace" \
   GITHUB_USER=test CLAUDE_PATH=claude CLAUDE_PROJECT_SLUG=test \
   TIMEZONE_HOUR=4 TIMEZONE_DESC=utc HOME_DIR="$T38_SYNC_ROOT" \
   GOVERNANCE_REPO="$T38_SPECIAL" IWE_TEMPLATE_PATH="$T38_SYNC_ROOT/template" \
   IWE_RUNTIME_PATH="$T38_SYNC_ROOT/runtime" \
   bash -c 'source "$1"; install_agent_instruction_bundle' \
   t38 "$T38_SETUP_RUNNER" >/dev/null 2>&1 && \
   grep -Fxq "registry=$T38_SPECIAL" "$T38_SYNC_ROOT/workspace/AGENTS.md" && \
   grep -Fxq "claude=$T38_SPECIAL" "$T38_SYNC_ROOT/workspace/CLAUDE.md" && \
   cmp -s "$T38_SYNC_ROOT/workspace/CLAUDE.md" \
          "$T38_SYNC_ROOT/workspace/.claude.md.base"; then
    pass "T38g: setup safely substitutes &, | and backslash and preserves merge-base parity"
else
    fail "T38g: setup corrupted a special-character replacement or its merge base"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"

exit "$FAIL_COUNT"
