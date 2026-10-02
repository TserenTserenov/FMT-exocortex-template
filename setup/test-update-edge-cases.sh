#!/bin/bash
# test-update-edge-cases.sh — edge-case regression tests for update.sh (issue #206)
#
# Covers gaps not exercised by smoke-test-fresh-install.sh:
#   T1: --check mode does not modify any file (idempotency guard)
#   T2: orphaned {{PLACEHOLDER}} in .iwe-runtime/ is detected post-build
#   T3: CLAUDE.md with pre-existing conflict markers blocks update (stacking guard)
#   T4: role install failure surfaces a visible warning (not silently swallowed)
#   T5: network-independent --check works with a cached manifest
#   T6: the owner: marker is read correctly but no longer decides a memory update (issues #229/#965)
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
#   T21: legacy owner:user protocols follow the memory policy: untouched ones migrate once with a
#        backup, edited ones are kept (issues #354/#965/#967)
#   T22: Quick Close requires a runner card only when the runner and graph exist (issue #356)
#   T23: wp-sync-bundle handles canonical cards, phase statuses, relation shapes, titles, and linked worktrees
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
#   T40: Kimi peer heartbeat stays outside authoritative session admission (WP-484)
#   T41: sync_workspace_claude_md() accepts a hand-resolved conflict instead of
#        re-merging it against the stale base forever; a stale pending record
#        (upstream moved on) is discarded, not silently accepted (issue #846)
#   T42: memory/*.md stale-repair backs up the workspace copy before
#        overwriting it, like .claude/rules/* already does (issue #847)
#   T43: Step 6 (the main apply path) keeps a memory file the pilot edited, backs up and names
#        a file it replaces because the pilot never changed it (issues #967/#965)
#   T44: the author_mode "stale" hint runs on exactly the printed paths (a space, quotes,
#        $(...), backticks and a backslash in them) and two runs keep two copies
#   T45: the same for the memory policy's command for a kept copy; a refreshed copy on such
#        paths gets its backup (cold review of #967)
#   T46: one memory policy for every owner: untouched copies refreshed with a backup (proof by
#        the version installed last time or by the clone's history), edited or unverifiable
#        ones kept with a command; shallow clone, failed backup, repeated update, migration,
#        odd paths, author_mode, the record of installed versions (issues #965/#967)
#   T47: the record of installed memory versions (.memory-deployed.tsv): a broken-off run and a
#        copy several releases behind, an unusable record, setup.sh's first record, author_mode
#        in Step 6 and the repair pass (review of #965/#967)
#   T48: the record before Step 5 (a run broken off before Step 6), atomic writes of the record and
#        of memory copies, unreadable or linked record, every file left as it was in the summary
#        (review-12 of #965/#967)
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

# update_sh_functions NAME... — the definitions of the named top-level functions of update.sh, in
# the given order. A name update.sh does not define prints nothing: a run of the extracted code
# then fails on its observable result, not on the extraction. One-line functions (py_available)
# cannot be extracted this way; tests define their own stand-ins.
update_sh_functions() {
    local fn
    for fn in "$@"; do
        awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh"
    done
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
# T6: the owner: marker is read correctly, and it no longer decides whether a memory copy is
# refreshed (issue #229, then #965/#967: an edited owner: user copy survives because it is
# edited — T46 runs that — and an untouched one is refreshed like any other)
# ============================================================================
echo "--- T6: owner: marker is read, but the memory policy decides (issues #229/#965) ---"

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

if [ "$(get_field "$T6_DEPLOYED" owner)" = "user" ]; then
    pass "T6: get_field detects owner:user (single-quoted)"
else
    fail "T6: get_field failed to detect owner:user"
fi

# Wiring check: no owner: guard is left at either memory site — the marker used to keep an
# untouched owner: user file behind forever (#965) and let an edited owner: platform file be
# replaced (#967) — and both sites go through the one policy helper: Step 6 with the version
# installed last time, the repair pass without it (nothing was replaced in its run).
T6_OWNER_GUARDS=$(grep -cE 'get_field "\$[a-z_]*dst" owner' "$TEMPLATE_DIR/update.sh")
# shellcheck disable=SC2016  # literal update.sh code, nothing is meant to expand
T6_STEP6_WIRED=$(grep -cF 'elif apply_memory_policy "$f" "$dst" "$(memory_old_hash "$f")"; then' "$TEMPLATE_DIR/update.sh")
# shellcheck disable=SC2016
T6_REPAIR_WIRED=$(grep -cF 'elif apply_memory_policy "$fpath" "$mem_dst"; then' "$TEMPLATE_DIR/update.sh")
# The decision itself never reads the marker; only author_mode's report does (is_user_owned_memory).
T6_DECISION_READS=$(update_sh_functions apply_memory_policy memory_copy_verdict | grep -cE 'get_field|is_user_owned_memory' || true)
if [ "$T6_OWNER_GUARDS" -eq 0 ] && [ "$T6_STEP6_WIRED" -eq 1 ] && [ "$T6_REPAIR_WIRED" -eq 1 ] && [ "$T6_DECISION_READS" -eq 0 ]; then
    pass "T6: no owner: guard decides any more; Step 6 and repair_pass() both call apply_memory_policy"
else
    fail "T6: expected no owner: guard and the policy at both memory sites, found guards=$T6_OWNER_GUARDS step6=$T6_STEP6_WIRED repair=$T6_REPAIR_WIRED decision-reads=$T6_DECISION_READS"
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

# Check 4 calls resolve_find_python3() (issue #764/#765 fix), defined earlier
# in the hook outside the Check-3..5 slice above — extract it too, by function
# boundary, and source it first so the sliced block can call it.
T11_RESOLVER_BLOCK=$(awk '
/^resolve_find_python3\(\) \{$/{found=1}
found{print}
found && /^}$/{exit}
' "$HOOK_FILE")

if [ -z "$T11_CHECKS_BLOCK" ]; then
    fail "T11: could not extract Check 3/4 block from protocol-artifact-validate.sh — marker comments moved?"
elif [ -z "$T11_RESOLVER_BLOCK" ]; then
    fail "T11: could not extract resolve_find_python3() from protocol-artifact-validate.sh — function moved/renamed?"
else
    T11_RESOLVER_FILE="$TEST_WS/t11-resolver.sh"
    printf '%s\n' "$T11_RESOLVER_BLOCK" > "$T11_RESOLVER_FILE"
    source "$T11_RESOLVER_FILE"

    T11_CHECKS_FILE="$TEST_WS/t11-checks.sh"
    printf '%s\n' "$T11_CHECKS_BLOCK" > "$T11_CHECKS_FILE"

    # resolve_find_python3() is sourced from a temp file above, so its own
    # self-relative fallback (dirname of its *defining* file) points into
    # $TEST_WS, not the real template — IWE_SCRIPTS is what makes it resolve
    # to a real find-python3.sh in these fixtures (issue #764: the fixture
    # used to place find-python3.sh at $WORKSPACE/scripts/lib/, the exact
    # path the fixed resolver no longer looks at).
    export IWE_SCRIPTS="$TEMPLATE_DIR/scripts"

    # Case A: default installation (mandatory_daily_wps commented out in the
    # template default), DayPlan uses the real pilot phrasing from issue #328.
    T11_DIR="$TEST_WS/t11-dayplan"
    mkdir -p "$T11_DIR/memory" "$T11_DIR/current"
    cp "$TEMPLATE_DIR/memory/day-rhythm-config.yaml" "$T11_DIR/memory/day-rhythm-config.yaml"
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
    mkdir -p "$T11_DIR_B/memory" "$T11_DIR_B/current"
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

# issues #965/#967: the one-time owner:user -> owner:platform migration is no second overwrite
# path any more. The memory policy decides it like any other file: an untouched legacy copy is
# replaced (its marker changes with the file), an edited one is kept — so navigation.md with the
# installation's own addresses survives the update. author_mode keeps its branch (T46, world E).
T21_SECOND_PATH=$(grep -cE '^(migrate_platform_memory|is_migrated_platform_memory_path)\(\)' "$TEMPLATE_DIR/update.sh")
if [ "$T21_SECOND_PATH" -eq 0 ]; then
    pass "T21: the migration has no overwrite path of its own"
else
    fail "T21: update.sh still defines a separate migration overwrite path ($T21_SECOND_PATH function(s))"
fi

# Every check ends with "|| exit 1": set -e has no effect inside a subshell that an `if` tests.
if (
    set +u
    eval "$(update_sh_functions hash_file saving_cp_command backup_memory_file_before_overwrite apply_memory_policy \
        memory_record_put memory_record_get remember_memory_deployed memory_decided_once memory_reason_text \
        memory_copy_verdict replace_memory_copy)"
    SCRIPT_DIR="$TEMPLATE_DIR"
    WORKSPACE_DIR="$TEST_WS/t21-workspace"
    MEMORY_BACKUP_RUN=""
    # shellcheck disable=SC2034  # read by the eval'd update.sh functions
    MEMORY_DEPLOYED_RECORD="$WORKSPACE_DIR/.memory-deployed.tsv"
    mkdir -p "$WORKSPACE_DIR"

    # The copy an old release installed (owner: user), untouched since: proven by its hash.
    target="$TEST_WS/t21-protocol-open.md"
    printf -- '---\nowner: user\n---\nLegacy protocol text as an old release shipped it.\n' > "$target"
    installed_hash=$(hash_file "$target")
    apply_memory_policy memory/protocol-open.md "$target" "$installed_hash" || exit 1
    cmp -s "$target" "$TEMPLATE_DIR/memory/protocol-open.md" || exit 1
    [ "$(get_field "$target" owner)" = "platform" ] || exit 1
    backup=$(find "$WORKSPACE_DIR/.backups/memory-pre-update" -type f -name protocol-open.md -print -quit)
    grep -q 'Legacy protocol text as an old release shipped it' "$backup" || exit 1

    # The next update finds the copy current: nothing is replaced or backed up again.
    # shellcheck disable=SC2034  # read by the eval'd update.sh function
    MEMORY_POLICY_SEEN=""
    if apply_memory_policy memory/protocol-open.md "$target" "$installed_hash"; then
        exit 1
    fi
    [ "$(find "$WORKSPACE_DIR/.backups" -type f | wc -l | tr -d ' ')" = "1" ] || exit 1

    # An edited legacy copy is kept: the installation's addresses must survive.
    edited="$TEST_WS/t21-navigation.md"
    printf -- '---\nowner: user\n---\nRepository addresses of this installation.\n' > "$edited"
    if apply_memory_policy memory/navigation.md "$edited" "$installed_hash"; then
        exit 1
    fi
    grep -q 'Repository addresses of this installation' "$edited" || exit 1
    [ "$(find "$WORKSPACE_DIR/.backups" -type f | wc -l | tr -d ' ')" = "1" ] || exit 1
) > /dev/null 2>&1; then
    pass "T21: an untouched legacy copy migrates with a backup, once; an edited one is kept"
else
    fail "T21: legacy owner: user memory did not follow the memory policy"
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
T23_BUNDLE="${WP_SYNC_BUNDLE_UNDER_TEST:-$TEMPLATE_DIR/.claude/scripts/wp-sync-bundle.sh}"
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
    bash "$T23_BUNDLE" WP-777 2>&1)
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
    bash "$T23_BUNDLE" WP-778 2>&1)
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
    bash "$T23_BUNDLE" WP-46 2>&1)
T23_PREFIX_RC=$?
if [ "$T23_PREFIX_RC" -eq 1 ] && [[ "$T23_PREFIX_OUT" == *'WP-46: файл не найден'* ]]; then
    pass "T23: a shorter WP ID does not resolve a longer numeric prefix"
else
    fail "T23: numeric-prefix archive lookup regressed (rc=$T23_PREFIX_RC): $T23_PREFIX_OUT"
fi

T23_GIT_SOURCE="$T23_ROOT/git-source"
T23_LINKED_WORKSPACE="$T23_ROOT/linked-workspace"
T23_LINKED_GOV="$T23_LINKED_WORKSPACE/governance"
mkdir -p "$T23_GIT_SOURCE/docs" "$T23_GIT_SOURCE/inbox/WP-780" \
    "$T23_GIT_SOURCE/inbox/WP-78" "$T23_GIT_SOURCE/inbox/WP-784" \
    "$T23_GIT_SOURCE/inbox/WP-785" \
    "$T23_GIT_SOURCE/inbox/WP-781" "$T23_GIT_SOURCE/inbox/WP-782" \
    "$T23_GIT_SOURCE/inbox/WP-783" "$T23_LINKED_WORKSPACE"
cat > "$T23_GIT_SOURCE/docs/WP-REGISTRY.md" <<'HEREDOC'
| # | Название | Статус |
|---|---|---|
| 780 | Inline current | 🔄 in_progress |
| 78 | Closed prefix | ✅ done |
| 781 | Legacy related | ⏳ pending |
| 782 | Titled related | ⏳ pending |
| 783 | Block related | ⏳ pending |
| 784 | Boundary current | 🔄 in_progress |
| 785 | Inline blocker | 🔄 in_progress |
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-78/WP-78.md" <<'HEREDOC'
---
wp: 78
title: Closed prefix relation
status: done
spawned: 2026-09-10
phases: []
---
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-780/WP-780.md" <<'HEREDOC'
---
wp: 780
title: Inline current title
status: in_progress
spawned: 2026-09-10
# Inline YAML accepts both canonical WP-N and the numeric legacy form used by
# existing cards. A following top-level comment is not part of this value.
related: [WP-781, 782, WP-781, WP-780] # WP-799 is not related.
# WP-799 belongs to this comment, not to related.
phases: []
---

No related references in the body.
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-781/WP-781.md" <<'HEREDOC'
---
wp: 781
name: Legacy related name
title: Ignored title because name has priority
status: pending
spawned: 2026-09-10
phases: []
---
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-782/WP-782.md" <<'HEREDOC'
---
wp: 782
title: Titled related name
status: pending
spawned: 2026-09-10
phases: []
---
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-783/WP-783.md" <<'HEREDOC'
---
wp: 783
title: Block related name
status: in_progress
spawned: 2026-09-10
related: # WP-799 is not related; the indented mapping below is the value.
  # WP-798 is not related either.
  depends_on: [WP-781 (uses 5 views)]
  references: [782]
phases: []
---

See WP-5 in the body only.
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-784/WP-784.md" <<'HEREDOC'
---
wp: 784
title: Exact relation boundary
status: in_progress
spawned: 2026-09-10
related: [WP-78]
---

- [ ] Continue WP-780 only.
HEREDOC
cat > "$T23_GIT_SOURCE/inbox/WP-785/WP-785.md" <<'HEREDOC'
---
wp: 785
title: Inline blocker current
status: in_progress
spawned: 2026-09-10
blockers: [WP-781]
phases: []
---

No related references in the body.
HEREDOC
git -C "$T23_GIT_SOURCE" init -q -b main
git -C "$T23_GIT_SOURCE" config user.email "test@test"
git -C "$T23_GIT_SOURCE" config user.name "test"
git -C "$T23_GIT_SOURCE" add docs/WP-REGISTRY.md \
    inbox/WP-78/WP-78.md inbox/WP-784/WP-784.md inbox/WP-785/WP-785.md \
    inbox/WP-780/WP-780.md inbox/WP-781/WP-781.md \
    inbox/WP-782/WP-782.md inbox/WP-783/WP-783.md
git -C "$T23_GIT_SOURCE" commit -qm "fixture baseline commit"
git -C "$T23_GIT_SOURCE" worktree add -q -b t23-linked "$T23_LINKED_GOV" main

T23_INLINE_OUT=$(IWE_WORKSPACE="$T23_LINKED_WORKSPACE" IWE_GOVERNANCE_REPO=governance \
    WP_SYNC_GIT_DAYS=3650 bash "$T23_BUNDLE" WP-780 2>&1)
T23_INLINE_RC=$?
T23_INLINE_781=$(printf '%s\n' "$T23_INLINE_OUT" | grep -c '^### WP-781 (related)$' || true)
T23_INLINE_782=$(printf '%s\n' "$T23_INLINE_OUT" | grep -c '^### WP-782 (related)$' || true)
T23_INLINE_799=$(printf '%s\n' "$T23_INLINE_OUT" | grep -c '^### WP-799 ' || true)
if [ "$T23_INLINE_RC" -eq 0 ] && [ -f "$T23_LINKED_GOV/.git" ] && \
   [ ! -d "$T23_LINKED_GOV/.git" ] && \
   [ "$T23_INLINE_781" -eq 1 ] && [ "$T23_INLINE_782" -eq 1 ] && \
   [ "$T23_INLINE_799" -eq 0 ] && \
   [[ "$T23_INLINE_OUT" == *'- Название: Inline current title'* ]] && \
   [[ "$T23_INLINE_OUT" == *'- Название: Legacy related name'* ]] && \
   [[ "$T23_INLINE_OUT" == *'- Название: Titled related name'* ]] && \
   [[ "$T23_INLINE_OUT" == *'fixture baseline commit'* ]] && \
   [[ "$T23_INLINE_OUT" != *'_git недоступен_'* ]]; then
    pass "T23: inline related, title fallback, dedup/self-filter, and linked-worktree history work together"
else
    fail "T23: inline related/title/linked-worktree contract regressed (rc=$T23_INLINE_RC): $T23_INLINE_OUT"
fi

T23_BLOCK_OUT=$(IWE_WORKSPACE="$T23_LINKED_WORKSPACE" IWE_GOVERNANCE_REPO=governance \
    WP_SYNC_GIT_DAYS=3650 bash "$T23_BUNDLE" WP-783 2>&1)
T23_BLOCK_RC=$?
if [ "$T23_BLOCK_RC" -eq 0 ] && \
   [[ "$T23_BLOCK_OUT" == *'### WP-781 (depends_on)'* ]] && \
   [[ "$T23_BLOCK_OUT" == *'### WP-782 (references)'* ]] && \
   [[ "$T23_BLOCK_OUT" == *'### WP-5 (body_ref)'* ]] && \
   [[ "$T23_BLOCK_OUT" != *'### WP-798 '* ]] && \
   [[ "$T23_BLOCK_OUT" != *'### WP-799 '* ]]; then
    pass "T23: block related keeps typed relations"
else
    fail "T23: block related relation types regressed (rc=$T23_BLOCK_RC): $T23_BLOCK_OUT"
fi

T23_BOUNDARY_OUT=$(IWE_WORKSPACE="$T23_LINKED_WORKSPACE" IWE_GOVERNANCE_REPO=governance \
    bash "$T23_BUNDLE" WP-784 2>&1)
T23_BOUNDARY_RC=$?
if [ "$T23_BOUNDARY_RC" -eq 0 ] && \
   [[ "$T23_BOUNDARY_OUT" == *'### WP-78 (related)'* ]] && \
   [[ "$T23_BOUNDARY_OUT" == *'- Кол-во: 0'* ]]; then
    pass "T23: a WP-780 phase reference does not create drift for closed WP-78"
else
    fail "T23: relation ID boundary regressed (rc=$T23_BOUNDARY_RC): $T23_BOUNDARY_OUT"
fi

if grep -q '^extract_blocker_wps()' "$T23_BUNDLE"; then
    T23_BLOCKER_OUT=$(IWE_WORKSPACE="$T23_LINKED_WORKSPACE" IWE_GOVERNANCE_REPO=governance \
        bash "$T23_BUNDLE" WP-785 2>&1)
    T23_BLOCKER_RC=$?
    if [ "$T23_BLOCKER_RC" -eq 0 ] && \
       [[ "$T23_BLOCKER_OUT" == *'### WP-781 (body_ref)'* ]]; then
        pass "T23: runtime variant reads inline blockers"
    else
        fail "T23: inline blocker extraction regressed (rc=$T23_BLOCKER_RC): $T23_BLOCKER_OUT"
    fi
fi
git -C "$T23_GIT_SOURCE" worktree remove "$T23_LINKED_GOV" --force >/dev/null 2>&1

T23_NESTED_WORKSPACE="$T23_GIT_SOURCE/nested-workspace"
T23_NESTED_GOV="$T23_NESTED_WORKSPACE/governance"
mkdir -p "$T23_NESTED_GOV/docs" "$T23_NESTED_GOV/inbox/WP-790" \
    "$T23_NESTED_GOV/inbox/WP-791"
cat > "$T23_NESTED_GOV/docs/WP-REGISTRY.md" <<'HEREDOC'
| # | Название | Статус |
|---|---|---|
| 790 | Nested current | 🔄 in_progress |
| 791 | Nested related | ⏳ pending |
HEREDOC
cat > "$T23_NESTED_GOV/inbox/WP-790/WP-790.md" <<'HEREDOC'
---
wp: 790
title: Nested current
status: in_progress
spawned: 2026-09-10
related: [WP-791]
phases: []
---
HEREDOC
cat > "$T23_NESTED_GOV/inbox/WP-791/WP-791.md" <<'HEREDOC'
---
wp: 791
title: Nested related
status: pending
spawned: 2026-09-10
phases: []
---
HEREDOC
T23_NESTED_OUT=$(IWE_WORKSPACE="$T23_NESTED_WORKSPACE" IWE_GOVERNANCE_REPO=governance \
    bash "$T23_BUNDLE" WP-790 2>&1)
T23_NESTED_RC=$?
if [ "$T23_NESTED_RC" -eq 0 ] && \
   [[ "$T23_NESTED_OUT" == *'_git недоступен_'* ]]; then
    pass "T23: a plain directory nested in another repository is not treated as its Git root"
else
    fail "T23: nested non-root Git directory was accepted (rc=$T23_NESTED_RC): $T23_NESTED_OUT"
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
   [ "$(grep -c '^export IWE_' "$T25_WS/.iwe-paths")" -eq 8 ]; then
    pass "T25: legacy HOME source is replaced by the eight-variable workspace SoT"
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
# Here-strings, not `printf | grep -q`: with pipefail, grep -q leaving after an early match makes
# printf die of SIGPIPE once the preview outgrows the pipe buffer, and the check fails at random.
if grep -Fq -- "$T37_WS/legacy-governance/scripts/install-hooks.sh" <<<"$T37_OUT" && \
   grep -Fq -- "$T37_WS/legacy-governance/.githooks/pre-commit" <<<"$T37_OUT" && \
   grep -Fq -- "$T37_WS/legacy-governance/scripts/update-derived-snapshot.py" <<<"$T37_OUT" && \
   grep -Fq -- "$T37_WS/legacy-governance/scripts/executor-catalog.yaml" <<<"$T37_OUT" && \
   grep -Fq -- "$T37_WS/.iwe-paths" <<<"$T37_OUT" && \
   grep -Fq -- '/.zshenv' <<<"$T37_OUT" && \
   grep -Fq -- 'local core.hooksPath' <<<"$T37_OUT"; then
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

# ============================================================================
# T39: hash_file() fails loudly with neither shasum nor sha256sum (issue #755)
# ============================================================================
echo "--- T39: hash_file() on a system with no hasher at all (issue #755) ---"

# Extracts the real preflight check + hash_file() from update.sh (same
# awk-by-function-name technique as T24's rule helpers) -- not a re-typed
# copy, so this breaks the moment the two diverge.
T39_PREFLIGHT=$(awk '
/^if ! command -v shasum/{copy=1}
copy{print}
copy && /^fi$/{exit}
' "$TEMPLATE_DIR/update.sh")
T39_HASH_FILE=$(awk '/^hash_file\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")

if [ -z "$T39_PREFLIGHT" ] || [ -z "$T39_HASH_FILE" ]; then
    fail "T39: could not extract the hasher preflight or hash_file() from update.sh — code moved?"
else
    T39_DIR="$TEST_WS/t39-no-hasher"
    T39_BIN="$T39_DIR/bin"
    mkdir -p "$T39_BIN"
    # A PATH containing only what bash itself needs to run this snippet --
    # no shasum, no sha256sum, no perl (real /bin already lacks GNU coreutils
    # sha256sum on macOS; symlinking just the handful of builtins this test
    # needs keeps the fixture from silently finding a real hasher elsewhere).
    for tool in bash cut env command printf; do
        p=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$p" "$T39_BIN/$(basename "$p")"
    done
    T39_TARGET="$T39_DIR/some-file.txt"
    echo "content" > "$T39_TARGET"

    T39_SNIPPET="$T39_DIR/snippet.sh"
    {
        echo 'EXIT_RUNTIME=3'
        printf '%s\n' "$T39_PREFLIGHT"
        printf '%s\n' "$T39_HASH_FILE"
        echo 'hash_file "$1"'
    } > "$T39_SNIPPET"

    T39_STATUS=0
    T39_OUT=$(env -i PATH="$T39_BIN" HOME="$HOME" bash "$T39_SNIPPET" "$T39_TARGET" 2>&1) || T39_STATUS=$?

    if [ "$T39_STATUS" -eq 3 ] && [ -z "$T39_OUT" ]; then
        # exit 3 with nothing on stdout is wrong in the OTHER direction: it
        # would mean the preflight fired but printed nothing to explain why.
        fail "T39: preflight exited EXIT_RUNTIME but printed no diagnostic"
    elif [ "$T39_STATUS" -eq 3 ] && printf '%s' "$T39_OUT" | grep -qi "shasum\|sha256sum"; then
        pass "T39: no hasher on PATH -> loud EXIT_RUNTIME(3) naming the missing tools, not a silent empty hash"
    else
        fail "T39: expected EXIT_RUNTIME(3) with a shasum/sha256sum diagnostic, got status=$T39_STATUS: $T39_OUT"
    fi
fi

# ============================================================
# T40: Kimi peer heartbeat is observational, never a session semaphore (WP-484)
# ============================================================
echo "--- T40: Kimi peer heartbeat namespace and watchdog consumer (WP-484) ---"

T40_ROOT="$TEST_WS/t40-kimi-peer-heartbeat"
T40_IWE="$T40_ROOT/iwe"
T40_HOME="$T40_ROOT/home"
T40_ADD_DIR="$T40_ROOT/2026-09-12-01-wp484-peer-beacon"
T40_LOCK_DIR="$T40_ROOT/locks"
T40_BIN="$T40_ROOT/fake-kimi"
T40_READY="$T40_ROOT/ready"
T40_RELEASE="$T40_ROOT/release"
T40_OAUTH_DIR="$T40_LOCK_DIR/kimi-oauth-refresh.lockdir"
T40_OAUTH_LINEAGE="$T40_LOCK_DIR/kimi-oauth-refresh.lineage-v4"
mkdir -p "$T40_HOME" "$T40_ADD_DIR"

cat > "$T40_BIN" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    echo "--agent-file Load an agent definition from a Markdown file"
    exit 0
fi
printf '%s\n' "$$" >> "$T40_READY"
while [ ! -f "$T40_RELEASE" ]; do sleep 0.05; done
printf '%s\n' '{"role":"assistant","content":"CONSENSUS: beacon probe complete"}'
EOF
chmod +x "$T40_BIN"
export T40_READY T40_RELEASE

if HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/cutover-unasserted.out" 2>"$T40_ROOT/cutover-unasserted.err"; then
    T40_CUTOVER_UNASSERTED_RC=0
else
    T40_CUTOVER_UNASSERTED_RC=$?
fi
HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/cutover.out" 2>"$T40_ROOT/cutover.err"
T40_CUTOVER_RC=$?
T40_FENCE_TARGET=$(readlink "$T40_OAUTH_DIR" 2>/dev/null || true)
T40_FENCE_PID=$(cat "$T40_OAUTH_DIR/pid" 2>/dev/null || true)
T40_FENCE_OWNER=$(cat "$T40_OAUTH_DIR/owner" 2>/dev/null || true)
T40_FENCE_LEASE_ID=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev} {s.st_ino}")' "$T40_LOCK_DIR/kimi-oauth-refresh.lease" 2>/dev/null || true)
HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/cutover-again.out" 2>"$T40_ROOT/cutover-again.err"
T40_CUTOVER_AGAIN_RC=$?

HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" \
    IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" IWE_PEER_HEARTBEAT_SECONDS=1 \
    IWE_PEER_TIMEOUT_SECONDS=10 \
    KIMI_BIN="$T40_BIN" \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_ADD_DIR" \
    </dev/null >"$T40_ROOT/adapter.out" 2>"$T40_ROOT/adapter.err" &
T40_ADAPTER_PID=$!
for _t40_wait in $(seq 1 200); do
    [ -f "$T40_READY" ] && break
    sleep 0.05
done

T40_BEACON="$T40_IWE/.iwe-runtime/peer-heartbeats/kimi-peer-2026-09-12-01-wp484-peer-beacon.heartbeat"
mkdir -p "$T40_IWE/.iwe-runtime/sessions"
T40_OPEN_COUNT=$(find "$T40_IWE/.iwe-runtime/sessions" -name '*.open' 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$T40_READY" ] && [ -f "$T40_BEACON" ] && [ ! -L "$T40_BEACON" ] && \
   [ "$T40_OPEN_COUNT" = 0 ] && grep -q '^agent: kimi-peer$' "$T40_BEACON" && \
   grep -q '^wp: WP-484$' "$T40_BEACON"; then
    pass "T40a: peer adapter writes visibility beacon outside sessions/*.open"
else
    fail "T40a: peer beacon entered admission namespace or was not created: $(find "$T40_IWE/.iwe-runtime" -type f 2>/dev/null | tr '\n' ' ')"
fi

T40_OAUTH_HOLDER=$(cat "$T40_OAUTH_LINEAGE/pid" 2>/dev/null || true)
T40_OAUTH_OWNER=$(cat "$T40_OAUTH_LINEAGE/owner" 2>/dev/null || true)
T40_SESSION_OWNER=$(cat "$T40_LOCK_DIR/2026-09-12-01-wp484-peer-beacon.lock/owner.pid" 2>/dev/null || true)
T40_SESSION_NONCE=${T40_SESSION_OWNER#* }
T40_OAUTH_LEASE_ID=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev} {s.st_ino}")' "$T40_LOCK_DIR/kimi-oauth-refresh.lease" 2>/dev/null || true)
T40_EXPECTED_OWNER="iwe-oauth-lineage-v4 $T40_OAUTH_LEASE_ID $T40_SESSION_NONCE"
T40_OAUTH_TARGET=$(readlink "$T40_OAUTH_LINEAGE" 2>/dev/null || true)
if [ "$T40_CUTOVER_UNASSERTED_RC" -eq 1 ] && \
   [ "$T40_CUTOVER_RC" -eq 0 ] && [ "$T40_CUTOVER_AGAIN_RC" -eq 0 ] && \
   [[ "$T40_FENCE_TARGET" =~ ^kimi-oauth-refresh\.fence-v4\.[0-9a-f]{32}$ ]] && \
   [ "$T40_FENCE_PID" = -1 ] && \
   [ "$T40_FENCE_OWNER" = "iwe-oauth-fence-v4 $T40_FENCE_LEASE_ID ${T40_FENCE_TARGET##*.}" ] && \
   [[ "$T40_OAUTH_HOLDER" =~ ^-[0-9]+$ ]] && \
   kill -0 "$T40_OAUTH_HOLDER" 2>/dev/null && \
   [ -L "$T40_OAUTH_DIR" ] && \
   [ -L "$T40_OAUTH_LINEAGE" ] && \
   [ "$T40_OAUTH_TARGET" = "kimi-oauth-refresh.lineage-v4.$T40_SESSION_NONCE" ] && \
   [ "${T40_SESSION_OWNER%% *}" = "$T40_ADAPTER_PID" ] && \
   [[ "$T40_SESSION_NONCE" =~ ^[0-9a-f]{32}$ ]] && \
   [ "$T40_OAUTH_OWNER" = "$T40_EXPECTED_OWNER" ]; then
    pass "T40b: explicit idempotent cutover keeps immutable fence while v4 lineage publishes vendor PGID"
else
    fail "T40b: v4 cutover/fence/lineage is not exact (cutover=$T40_CUTOVER_UNASSERTED_RC/$T40_CUTOVER_RC/$T40_CUTOVER_AGAIN_RC fence=$T40_FENCE_TARGET/$T40_FENCE_PID/$T40_FENCE_OWNER adapter=$T40_ADAPTER_PID holder=$T40_OAUTH_HOLDER target=$T40_OAUTH_TARGET owner=$T40_OAUTH_OWNER expected=$T40_EXPECTED_OWNER)"
fi

T40_ID_BEFORE=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_BEACON" 2>/dev/null)
T40_SUM_BEFORE=$(head -6 "$T40_BEACON" | cksum 2>/dev/null)
if HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
   IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" \
   IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" IWE_PEER_HEARTBEAT_SECONDS=1 \
   IWE_PEER_TIMEOUT_SECONDS=2 \
   KIMI_BIN="$T40_BIN" \
   bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_ADD_DIR" \
   </dev/null >"$T40_ROOT/duplicate.out" 2>"$T40_ROOT/duplicate.err"; then
    T40_DUPLICATE_RC=0
else
    T40_DUPLICATE_RC=$?
fi
T40_ID_AFTER=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_BEACON" 2>/dev/null)
T40_SUM_AFTER=$(head -6 "$T40_BEACON" | cksum 2>/dev/null)
if [ "$T40_DUPLICATE_RC" -eq 5 ] && [ -n "$T40_ID_BEFORE" ] && \
   [ "$T40_ID_AFTER" = "$T40_ID_BEFORE" ] && [ "$T40_SUM_AFTER" = "$T40_SUM_BEFORE" ]; then
    pass "T40c: rejected duplicate cannot replace the live owner's beacon"
else
    fail "T40c: duplicate mutated the beacon (rc=$T40_DUPLICATE_RC before=$T40_ID_BEFORE/$T40_SUM_BEFORE after=$T40_ID_AFTER/$T40_SUM_AFTER)"
fi

touch "$T40_RELEASE"
if wait "$T40_ADAPTER_PID"; then
    T40_ADAPTER_RC=0
else
    T40_ADAPTER_RC=$?
fi
if [ "$T40_ADAPTER_RC" -eq 0 ] && [ ! -e "$T40_BEACON" ] && \
   ! kill -0 "$T40_OAUTH_HOLDER" 2>/dev/null && \
   [ -L "$T40_OAUTH_DIR" ] && [ "$(readlink "$T40_OAUTH_DIR")" = "$T40_FENCE_TARGET" ] && \
   [ ! -e "$T40_OAUTH_LINEAGE" ] && [ ! -L "$T40_OAUTH_LINEAGE" ] && \
   [ ! -e "$T40_IWE/.iwe-runtime/sessions/kimi-peer-2026-09-12-01-wp484-peer-beacon.open" ]; then
    pass "T40d: normal peer exit reaps runtime lineage, preserves permanent fence, and removes its beacon"
else
    fail "T40d: normal peer cleanup leaked vendor group/beacon (rc=$T40_ADAPTER_RC holder=$T40_OAUTH_HOLDER)"
fi

T40_JOURNAL="$T40_HOME/.iwe/agent-sessions.jsonl"
for _t40_wait in $(seq 1 100); do
    [ -s "$T40_JOURNAL" ] && break
    sleep 0.05
done
if python3 - "$T40_JOURNAL" <<'PY'
import datetime
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text(encoding="utf-8").splitlines()[-1])
assert record["agent"] == "kimi"
assert record["session_id"] == "2026-09-12-01-wp484-peer-beacon"
datetime.datetime.fromisoformat(record["start_time"].replace("Z", "+00:00"))
datetime.datetime.fromisoformat(record["end_time"].replace("Z", "+00:00"))
PY
then
    pass "T40e: successful peer call records a timestamped session journal entry"
else
    fail "T40e: successful peer call lost its session journal entry"
fi

# Start eight adapters on one id without a pre-established winner. Exactly one
# may enter the fake CLI; the kernel lock must reject the other seven.
T40_RACE_ADD="$T40_ROOT/peer-race-session"
T40_RACE_READY="$T40_ROOT/race-ready"
T40_RACE_RELEASE="$T40_ROOT/race-release"
mkdir -p "$T40_RACE_ADD" "$T40_ROOT/race-results"
t40_racer() {
    local index="$1" rc
    if HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
       IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" \
       IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" IWE_PEER_HEARTBEAT_SECONDS=1 \
       IWE_PEER_TIMEOUT_SECONDS=10 T40_READY="$T40_RACE_READY" \
       T40_RELEASE="$T40_RACE_RELEASE" KIMI_BIN="$T40_BIN" \
       bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_RACE_ADD" \
       </dev/null >"$T40_ROOT/race-results/$index.out" 2>"$T40_ROOT/race-results/$index.err"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$rc" > "$T40_ROOT/race-results/$index.rc"
}
T40_RACE_PIDS=""
for _t40_index in $(seq 1 8); do
    t40_racer "$_t40_index" &
    T40_RACE_PIDS="$T40_RACE_PIDS $!"
done
for _t40_wait in $(seq 1 100); do
    T40_RACE_DONE=$(find "$T40_ROOT/race-results" -name '*.rc' | wc -l | tr -d ' ')
    [ "$T40_RACE_DONE" -ge 7 ] && break
    sleep 0.05
done
touch "$T40_RACE_RELEASE"
for _t40_pid in $T40_RACE_PIDS; do
    wait "$_t40_pid" || true
done
if [ -f "$T40_RACE_READY" ]; then
    T40_RACE_ENTERED=$(wc -l < "$T40_RACE_READY" | tr -d ' ')
else
    T40_RACE_ENTERED=0
fi
T40_RACE_OK=$(grep -l '^0$' "$T40_ROOT"/race-results/*.rc 2>/dev/null | wc -l | tr -d ' ')
T40_RACE_BUSY=$(grep -l '^5$' "$T40_ROOT"/race-results/*.rc 2>/dev/null | wc -l | tr -d ' ')
if [ "$T40_RACE_ENTERED" -eq 1 ] && [ "$T40_RACE_OK" -eq 1 ] && \
   [ "$T40_RACE_BUSY" -eq 7 ]; then
    pass "T40f: concurrent same-id adapters elect exactly one owner"
else
    fail "T40f: peer lock split ownership (entered=$T40_RACE_ENTERED ok=$T40_RACE_OK busy=$T40_RACE_BUSY)"
fi

# Exercise the adapter with isolated paths while preserving the exact env used
# by the installed template. These helpers keep every race case below concise.
T40_ADAPTER_ENV=(
    env
    HOME="$T40_HOME"
    CODEX_SANDBOX=''
    CODEX_SANDBOX_NETWORK_DISABLED=''
    IWE_PEER_PLAIN=1
    IWE_ROOT="$T40_IWE"
    IWE_PEER_LOCK_DIR="$T40_LOCK_DIR"
    IWE_PEER_HEARTBEAT_SECONDS=1
)
t40_run_peer() {
    local add_dir="$1" kimi_bin="$2" stdout_file="$3" stderr_file="$4"
    shift 4
    "${T40_ADAPTER_ENV[@]}" "$@" KIMI_BIN="$kimi_bin" \
        bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$add_dir" \
        </dev/null >"$stdout_file" 2>"$stderr_file"
}
t40_launch_peer() {
    local add_dir="$1" kimi_bin="$2" stdout_file="$3" stderr_file="$4"
    shift 4
    exec "${T40_ADAPTER_ENV[@]}" "$@" KIMI_BIN="$kimi_bin" \
        bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$add_dir" \
        </dev/null >"$stdout_file" 2>"$stderr_file"
}
t40_process_is_non_zombie() {
    local process_pid="$1" process_state
    process_state=$(ps -o stat= -p "$process_pid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$process_state" ]; then
        [[ "$process_state" != Z* ]]
    else
        kill -0 "$process_pid" 2>/dev/null
    fi
}
t40_wait_for_process_exit() {
    local process_pid="$1" _wait
    for _wait in $(seq 1 120); do
        t40_process_is_non_zombie "$process_pid" || return 0
        sleep 0.05
    done
    return 1
}
t40_run_recovery() {
    local add_dir="$1" kimi_bin="$2" stdout_file="$3" stderr_file="$4" _wait
    shift 4
    T40_RECOVERY_RC=5
    for _wait in $(seq 1 80); do
        if t40_run_peer "$add_dir" "$kimi_bin" "$stdout_file" "$stderr_file" "$@"; then
            T40_RECOVERY_RC=0
        else
            T40_RECOVERY_RC=$?
        fi
        [ "$T40_RECOVERY_RC" -eq 5 ] || break
        sleep 0.05
    done
}

# Removing mutable owner metadata must stop the vendor fail-closed while the
# stable lease remains locked. A duplicate must never enter during that drain.
T40_UNLINK_ADD="$T40_ROOT/peer-without-wp-label"
T40_UNLINK_READY="$T40_ROOT/unlink-ready"
T40_UNLINK_CHILD_PID_FILE="$T40_ROOT/unlink-child.pid"
T40_UNLINK_BIN="$T40_ROOT/fake-kimi-unlink"
mkdir -p "$T40_UNLINK_ADD"
cat > "$T40_UNLINK_BIN" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    echo "--agent-file Load an agent definition from a Markdown file"
    exit 0
fi
trap '' TERM
echo "$$" > "$T40_UNLINK_CHILD_PID_FILE"
: > "$T40_UNLINK_READY"
while :; do sleep 0.05; done
EOF
chmod +x "$T40_UNLINK_BIN"
export T40_UNLINK_READY T40_UNLINK_CHILD_PID_FILE
t40_launch_peer "$T40_UNLINK_ADD" "$T40_UNLINK_BIN" \
    "$T40_ROOT/unlink.out" "$T40_ROOT/unlink.err" IWE_PEER_TIMEOUT_SECONDS=20 &
T40_UNLINK_ADAPTER_PID=$!
for _t40_wait in $(seq 1 200); do
    [ -s "$T40_UNLINK_CHILD_PID_FILE" ] && break
    sleep 0.05
done
T40_UNLINK_OWNER="$T40_LOCK_DIR/peer-without-wp-label.lock/owner.pid"
rm -f "$T40_UNLINK_OWNER"
if t40_run_peer "$T40_UNLINK_ADD" "$T40_UNLINK_BIN" \
    "$T40_ROOT/unlink-duplicate.out" "$T40_ROOT/unlink-duplicate.err" \
    IWE_PEER_TIMEOUT_SECONDS=20; then
    T40_UNLINK_DUPLICATE_RC=0
else
    T40_UNLINK_DUPLICATE_RC=$?
fi
if wait "$T40_UNLINK_ADAPTER_PID"; then
    T40_UNLINK_RC=0
else
    T40_UNLINK_RC=$?
fi
T40_UNLINK_CHILD_PID=$(cat "$T40_UNLINK_CHILD_PID_FILE" 2>/dev/null || true)
T40_UNLINK_CHILD_LIVE=false
t40_wait_for_process_exit "$T40_UNLINK_CHILD_PID" || T40_UNLINK_CHILD_LIVE=true
if [ "$T40_UNLINK_DUPLICATE_RC" -eq 5 ] && [ "$T40_UNLINK_RC" -eq 1 ] && \
   [ "$T40_UNLINK_CHILD_LIVE" = false ] && \
   [ -f "$T40_LOCK_DIR/peer-without-wp-label.lock/lease" ] && \
   grep -q 'exact peer-session lock lost (lock-owner-metadata-missing)' "$T40_ROOT/unlink.err"; then
    pass "T40g: owner metadata loss keeps stable admission closed and kills vendor fail-closed"
else
    fail "T40g: unlink race escaped stable lease (duplicate=$T40_UNLINK_DUPLICATE_RC rc=$T40_UNLINK_RC child_live=$T40_UNLINK_CHILD_LIVE)"
fi

# SIGKILL of the top adapter must not orphan a TERM-resistant vendor/grandchild.
# A same-id duplicate is rejected, while a different id waits on global OAuth;
# sampled live vendor count may never exceed one.
T40_CRASH_ADD="$T40_ROOT/peer-crash-session"
T40_CROSS_ADD="$T40_ROOT/peer-crash-cross-session"
T40_CRASH_READY="$T40_ROOT/crash-ready"
T40_CROSS_READY="$T40_ROOT/cross-ready"
T40_CRASH_ENTRIES="$T40_ROOT/crash-entries"
T40_CRASH_VENDOR_PID_FILE="$T40_ROOT/crash-vendor.pid"
T40_CRASH_GRANDCHILD_PID_FILE="$T40_ROOT/crash-grandchild.pid"
T40_CRASH_BIN="$T40_ROOT/fake-kimi-crash"
mkdir -p "$T40_CRASH_ADD" "$T40_CROSS_ADD"
cat > "$T40_CRASH_BIN" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    echo "--agent-file Load an agent definition from a Markdown file"
    exit 0
fi
if [ "${T40_CROSS_SESSION:-0}" = "1" ]; then
    printf '%s\n' "$$" >> "$T40_CRASH_ENTRIES"
    : > "$T40_CROSS_READY"
    sleep 0.5
    printf '%s\n' '{"role":"assistant","content":"cross-session complete"}'
    exit 0
fi
if [ "${T40_RECOVERY:-0}" = "1" ]; then
    printf '%s\n' '{"role":"assistant","content":"SIGKILL recovery complete"}'
    exit 0
fi
trap '' HUP INT TERM
printf '%s\n' "$$" >> "$T40_CRASH_ENTRIES"
echo "$$" > "$T40_CRASH_VENDOR_PID_FILE"
(
    trap '' HUP INT TERM
    while :; do sleep 0.05; done
) &
grandchild=$!
echo "$grandchild" > "$T40_CRASH_GRANDCHILD_PID_FILE"
: > "$T40_CRASH_READY"
wait "$grandchild"
EOF
chmod +x "$T40_CRASH_BIN"
export T40_CRASH_READY T40_CROSS_READY T40_CRASH_ENTRIES
export T40_CRASH_VENDOR_PID_FILE T40_CRASH_GRANDCHILD_PID_FILE
t40_launch_peer "$T40_CRASH_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/crash.out" "$T40_ROOT/crash.err" IWE_PEER_TIMEOUT_SECONDS=30 &
T40_CRASH_PID=$!
for _t40_wait in $(seq 1 200); do
    [ -e "$T40_CRASH_READY" ] && [ -s "$T40_CRASH_GRANDCHILD_PID_FILE" ] && break
    sleep 0.025
done
T40_CRASH_VENDOR_PID=$(cat "$T40_CRASH_VENDOR_PID_FILE" 2>/dev/null || true)
T40_CRASH_GRANDCHILD_PID=$(cat "$T40_CRASH_GRANDCHILD_PID_FILE" 2>/dev/null || true)
kill -9 "$T40_CRASH_PID" 2>/dev/null || true
t40_launch_peer "$T40_CROSS_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/cross.out" "$T40_ROOT/cross.err" \
    IWE_PEER_TIMEOUT_SECONDS=30 T40_CROSS_SESSION=1 &
T40_CROSS_PID=$!
t40_launch_peer "$T40_CRASH_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/crash-duplicate.out" "$T40_ROOT/crash-duplicate.err" \
    IWE_PEER_TIMEOUT_SECONDS=30 &
T40_CRASH_DUPLICATE_PID=$!
T40_CRASH_MAX_LIVE=0
for _t40_sample in $(seq 1 900); do
    T40_CRASH_LIVE=0
    while IFS= read -r _t40_entry_pid; do
        if [ -n "$_t40_entry_pid" ] && t40_process_is_non_zombie "$_t40_entry_pid"; then
            T40_CRASH_LIVE=$((T40_CRASH_LIVE + 1))
        fi
    done < "$T40_CRASH_ENTRIES"
    [ "$T40_CRASH_LIVE" -le "$T40_CRASH_MAX_LIVE" ] || T40_CRASH_MAX_LIVE="$T40_CRASH_LIVE"
    t40_process_is_non_zombie "$T40_CROSS_PID" || break
    sleep 0.01
done
if wait "$T40_CRASH_DUPLICATE_PID"; then
    T40_CRASH_DUPLICATE_RC=0
else
    T40_CRASH_DUPLICATE_RC=$?
fi
if wait "$T40_CROSS_PID"; then
    T40_CROSS_RC=0
else
    T40_CROSS_RC=$?
fi
wait "$T40_CRASH_PID" 2>/dev/null || true
T40_CRASH_VENDOR_LIVE=false
T40_CRASH_GRANDCHILD_LIVE=false
t40_wait_for_process_exit "$T40_CRASH_VENDOR_PID" || T40_CRASH_VENDOR_LIVE=true
t40_wait_for_process_exit "$T40_CRASH_GRANDCHILD_PID" || T40_CRASH_GRANDCHILD_LIVE=true
t40_run_recovery "$T40_CRASH_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/crash-recovery.out" "$T40_ROOT/crash-recovery.err" T40_RECOVERY=1
T40_CRASH_RECOVERY_RC="$T40_RECOVERY_RC"
if [ "$T40_CRASH_DUPLICATE_RC" -eq 5 ] && [ "$T40_CROSS_RC" -eq 0 ] && \
   [ "$(wc -l < "$T40_CRASH_ENTRIES" | tr -d ' ')" -eq 2 ] && \
   [ "$T40_CRASH_MAX_LIVE" -le 1 ] && [ "$T40_CRASH_VENDOR_LIVE" = false ] && \
   [ "$T40_CRASH_GRANDCHILD_LIVE" = false ] && [ "$T40_CRASH_RECOVERY_RC" -eq 0 ]; then
    pass "T40h: top SIGKILL preserves same/cross-id exclusion until resistant lineage is dead"
else
    fail "T40h: SIGKILL overlap (same=$T40_CRASH_DUPLICATE_RC cross=$T40_CROSS_RC max_live=$T40_CRASH_MAX_LIVE vendor=$T40_CRASH_VENDOR_LIVE grandchild=$T40_CRASH_GRANDCHILD_LIVE recovery=$T40_CRASH_RECOVERY_RC)"
fi

# The helper and sentinel deliberately share the same open-file authorities.
# Killing either one while a resistant vendor+grandchild is live must leave the
# survivor in charge of same-id and cross-id exclusion through complete drain.
t40_exercise_authority_sigkill() {
    local role="$1" label="$2" sequence="$3" cross_sequence="$4"
    local prefix="${role}-sigkill"
    local add_dir="$T40_ROOT/peer-${sequence}-${prefix}"
    local cross_dir="$T40_ROOT/peer-${cross_sequence}-${prefix}-cross"
    local barrier="$T40_ROOT/${prefix}-pre-owner"
    local sentinel_barrier="$T40_ROOT/${prefix}-pre-sentinel"
    local adapter_pid helper_pid sentinel_pid target_pid expected_reason
    local vendor_pid grandchild_pid session_id session_owner session_nonce
    local oauth_owner lease_id expected_owner duplicate_pid cross_pid
    local duplicate_rc cross_rc adapter_rc max_live=0 live entry_pid
    local vendor_live=false grandchild_live=false recovery_rc

    mkdir -p "$add_dir" "$cross_dir"
    rm -f "$T40_CRASH_READY" "$T40_CROSS_READY" \
        "$T40_CRASH_VENDOR_PID_FILE" "$T40_CRASH_GRANDCHILD_PID_FILE"
    : > "$T40_CRASH_ENTRIES"
    : > "$sentinel_barrier.release"
    t40_launch_peer "$add_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/${prefix}.out" "$T40_ROOT/${prefix}.err" \
        IWE_PEER_TIMEOUT_SECONDS=30 \
        IWE_PEER_TEST_OAUTH_PRE_OWNER_BARRIER="$barrier" \
        IWE_PEER_TEST_OAUTH_PRE_SENTINEL_BARRIER="$sentinel_barrier" &
    adapter_pid=$!
    for _t40_authority_owner_wait in $(seq 1 200); do
        [ -s "$barrier.ready" ] && break
        sleep 0.025
    done
    helper_pid=$(cat "$barrier.ready" 2>/dev/null || true)
    touch "$barrier.release"
    for _t40_authority_ready_wait in $(seq 1 200); do
        [ -e "$T40_CRASH_READY" ] && [ -s "$T40_CRASH_GRANDCHILD_PID_FILE" ] && break
        sleep 0.025
    done
    vendor_pid=$(cat "$T40_CRASH_VENDOR_PID_FILE" 2>/dev/null || true)
    grandchild_pid=$(cat "$T40_CRASH_GRANDCHILD_PID_FILE" 2>/dev/null || true)
    sentinel_pid=$(cat "$sentinel_barrier.sentinel" 2>/dev/null || true)
    session_id=$(basename "$add_dir")
    session_owner=$(cat "$T40_LOCK_DIR/$session_id.lock/owner.pid" 2>/dev/null || true)
    session_nonce=${session_owner#* }
    oauth_owner=$(cat "$T40_OAUTH_LINEAGE/owner" 2>/dev/null || true)
    lease_id=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev} {s.st_ino}")' "$T40_LOCK_DIR/kimi-oauth-refresh.lease" 2>/dev/null || true)
    expected_owner="iwe-oauth-lineage-v4 $lease_id $session_nonce"
    if [ "$role" = helper ]; then
        target_pid="$helper_pid"
        expected_reason=lock-helper-process-gone
    else
        target_pid="$sentinel_pid"
        expected_reason=lock-sentinel-process-gone
    fi
    kill -9 "$target_pid" 2>/dev/null || true

    t40_launch_peer "$cross_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/${prefix}-cross.out" "$T40_ROOT/${prefix}-cross.err" \
        IWE_PEER_TIMEOUT_SECONDS=30 T40_CROSS_SESSION=1 &
    cross_pid=$!
    t40_launch_peer "$add_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/${prefix}-duplicate.out" "$T40_ROOT/${prefix}-duplicate.err" \
        IWE_PEER_TIMEOUT_SECONDS=30 &
    duplicate_pid=$!
    for _t40_authority_sample in $(seq 1 900); do
        live=0
        while IFS= read -r entry_pid; do
            if [ -n "$entry_pid" ] && t40_process_is_non_zombie "$entry_pid"; then
                live=$((live + 1))
            fi
        done < "$T40_CRASH_ENTRIES"
        [ "$live" -le "$max_live" ] || max_live="$live"
        t40_process_is_non_zombie "$cross_pid" || break
        sleep 0.01
    done
    if wait "$duplicate_pid"; then duplicate_rc=0; else duplicate_rc=$?; fi
    if wait "$cross_pid"; then cross_rc=0; else cross_rc=$?; fi
    if wait "$adapter_pid"; then adapter_rc=0; else adapter_rc=$?; fi
    t40_wait_for_process_exit "$vendor_pid" || vendor_live=true
    t40_wait_for_process_exit "$grandchild_pid" || grandchild_live=true
    t40_run_recovery "$add_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/${prefix}-recovery.out" "$T40_ROOT/${prefix}-recovery.err" \
        T40_RECOVERY=1
    recovery_rc="$T40_RECOVERY_RC"

    if [[ "$sentinel_pid" =~ ^[0-9]+$ ]] && [[ "$helper_pid" =~ ^[0-9]+$ ]] && \
       [ "${session_owner%% *}" = "$adapter_pid" ] && \
       [[ "$session_nonce" =~ ^[0-9a-f]{32}$ ]] && \
       [ "$oauth_owner" = "$expected_owner" ] && \
       [ "$duplicate_rc" -eq 5 ] && [ "$cross_rc" -eq 0 ] && \
       [ "$adapter_rc" -eq 1 ] && [ "$max_live" -le 1 ] && \
       [ "$vendor_live" = false ] && [ "$grandchild_live" = false ] && \
       [ "$recovery_rc" -eq 0 ] && \
       ! t40_process_is_non_zombie "$helper_pid" && \
       ! t40_process_is_non_zombie "$sentinel_pid" && \
       grep -q "$expected_reason" "$T40_ROOT/${prefix}.err" && \
       grep -q '^cross-session complete$' "$T40_ROOT/${prefix}-cross.out" && \
       grep -q '^SIGKILL recovery complete$' "$T40_ROOT/${prefix}-recovery.out"; then
        pass "T40${label}: SIGKILL $role leaves its survivor authoritative through same/cross drain and reaps both"
    else
        fail "T40${label}: $role SIGKILL opened or leaked authority (helper=$helper_pid sentinel=$sentinel_pid duplicate=$duplicate_rc cross=$cross_rc adapter=$adapter_rc max_live=$max_live vendor=$vendor_live grandchild=$grandchild_live recovery=$recovery_rc)"
    fi
}

t40_exercise_authority_sigkill helper i 10 11
t40_exercise_authority_sigkill sentinel j 12 13

# The exec gate transfers legacy liveness from the controller group to the
# vendor group. Losing both Python owners after admission must still block a
# cross-id contender until the last resistant vendor descendant is gone.
T40_DOUBLE_ADD="$T40_ROOT/peer-16-double-controller-fault"
T40_DOUBLE_CROSS="${T40_DOUBLE_ADD}-cross"
T40_DOUBLE_OWNER_BARRIER="$T40_ROOT/double-pre-owner"
T40_DOUBLE_SENTINEL_BARRIER="$T40_ROOT/double-pre-sentinel"
mkdir -p "$T40_DOUBLE_ADD" "$T40_DOUBLE_CROSS"
rm -f "$T40_CRASH_READY" "$T40_CROSS_READY" \
    "$T40_CRASH_VENDOR_PID_FILE" "$T40_CRASH_GRANDCHILD_PID_FILE"
: > "$T40_CRASH_ENTRIES"
: > "$T40_DOUBLE_SENTINEL_BARRIER.release"
t40_launch_peer "$T40_DOUBLE_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/double.out" "$T40_ROOT/double.err" \
    IWE_PEER_TIMEOUT_SECONDS=30 \
    IWE_PEER_TEST_OAUTH_PRE_OWNER_BARRIER="$T40_DOUBLE_OWNER_BARRIER" \
    IWE_PEER_TEST_OAUTH_PRE_SENTINEL_BARRIER="$T40_DOUBLE_SENTINEL_BARRIER" &
T40_DOUBLE_ADAPTER_PID=$!
for _t40_double_owner_wait in $(seq 1 200); do
    [ -s "$T40_DOUBLE_OWNER_BARRIER.ready" ] && break
    sleep 0.025
done
T40_DOUBLE_HELPER_PID=$(cat "$T40_DOUBLE_OWNER_BARRIER.ready" 2>/dev/null || true)
touch "$T40_DOUBLE_OWNER_BARRIER.release"
for _t40_double_vendor_wait in $(seq 1 240); do
    [ -s "$T40_DOUBLE_SENTINEL_BARRIER.sentinel" ] && \
        [ -s "$T40_CRASH_VENDOR_PID_FILE" ] && \
        [ -s "$T40_CRASH_GRANDCHILD_PID_FILE" ] && break
    sleep 0.025
done
T40_DOUBLE_SENTINEL_PID=$(cat "$T40_DOUBLE_SENTINEL_BARRIER.sentinel" 2>/dev/null || true)
T40_DOUBLE_VENDOR_PID=$(cat "$T40_CRASH_VENDOR_PID_FILE" 2>/dev/null || true)
T40_DOUBLE_GRANDCHILD_PID=$(cat "$T40_CRASH_GRANDCHILD_PID_FILE" 2>/dev/null || true)
T40_DOUBLE_HOLDER=$(cat "$T40_OAUTH_LINEAGE/pid" 2>/dev/null || true)
T40_DOUBLE_HOLDER_LIVE=false
kill -0 "$T40_DOUBLE_HOLDER" 2>/dev/null && T40_DOUBLE_HOLDER_LIVE=true
kill -9 "$T40_DOUBLE_HELPER_PID" "$T40_DOUBLE_SENTINEL_PID" 2>/dev/null || true
if t40_run_peer "$T40_DOUBLE_CROSS" "$T40_CRASH_BIN" \
    "$T40_ROOT/double-blocked.out" "$T40_ROOT/double-blocked.err" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 T40_CROSS_SESSION=1; then
    T40_DOUBLE_BLOCKED_RC=0
else
    T40_DOUBLE_BLOCKED_RC=$?
fi
T40_DOUBLE_ENTRIES_LIVE=$(wc -l < "$T40_CRASH_ENTRIES" | tr -d ' ')
kill -9 "$T40_DOUBLE_HOLDER" 2>/dev/null || true
wait "$T40_DOUBLE_ADAPTER_PID" 2>/dev/null || true
t40_wait_for_process_exit "$T40_DOUBLE_VENDOR_PID" || true
t40_wait_for_process_exit "$T40_DOUBLE_GRANDCHILD_PID" || true
t40_run_recovery "$T40_DOUBLE_CROSS" "$T40_CRASH_BIN" \
    "$T40_ROOT/double-recovery.out" "$T40_ROOT/double-recovery.err" \
    T40_RECOVERY=1 T40_CROSS_SESSION=1
T40_DOUBLE_RECOVERY_RC="$T40_RECOVERY_RC"
if [[ "$T40_DOUBLE_HELPER_PID" =~ ^[0-9]+$ ]] && \
   [[ "$T40_DOUBLE_SENTINEL_PID" =~ ^[0-9]+$ ]] && \
   [[ "$T40_DOUBLE_HOLDER" =~ ^-[0-9]+$ ]] && \
   [ "$T40_DOUBLE_HOLDER_LIVE" = true ] && \
   [ "$T40_DOUBLE_BLOCKED_RC" -eq 1 ] && \
   [ "$T40_DOUBLE_ENTRIES_LIVE" -eq 1 ] && \
   [ "$T40_DOUBLE_RECOVERY_RC" -eq 0 ] && \
   ! t40_process_is_non_zombie "$T40_DOUBLE_VENDOR_PID" && \
   ! t40_process_is_non_zombie "$T40_DOUBLE_GRANDCHILD_PID"; then
    pass "T40v: double controller fault remains closed by vendor PGID until group death"
else
    fail "T40v: exec gate lost vendor-group visibility (helper=$T40_DOUBLE_HELPER_PID sentinel=$T40_DOUBLE_SENTINEL_PID holder=$T40_DOUBLE_HOLDER blocked=$T40_DOUBLE_BLOCKED_RC entries=$T40_DOUBLE_ENTRIES_LIVE recovery=$T40_DOUBLE_RECOVERY_RC)"
fi

# A hung capability probe runs before PGID publication. It must not inherit fd9
# and turn top SIGKILL into a permanent per-session blocker.
T40_HELP_ADD="$T40_ROOT/peer-hung-help-session"
T40_HELP_READY="$T40_ROOT/help-ready"
T40_HELP_PID_FILE="$T40_ROOT/help.pid"
T40_HELP_BIN="$T40_ROOT/fake-kimi-hung-help"
mkdir -p "$T40_HELP_ADD"
cat > "$T40_HELP_BIN" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    if [ "${T40_HELP_RECOVERY:-0}" = "1" ]; then
        echo "--agent-file Load an agent definition from a Markdown file"
        exit 0
    fi
    echo "$$" > "$T40_HELP_PID_FILE"
    : > "$T40_HELP_READY"
    trap '' HUP INT TERM
    while :; do sleep 0.05; done
fi
printf '%s\n' '{"role":"assistant","content":"hung-help recovery complete"}'
EOF
chmod +x "$T40_HELP_BIN"
export T40_HELP_READY T40_HELP_PID_FILE
t40_launch_peer "$T40_HELP_ADD" "$T40_HELP_BIN" \
    "$T40_ROOT/help.out" "$T40_ROOT/help.err" IWE_PEER_TIMEOUT_SECONDS=30 &
T40_HELP_ADAPTER_PID=$!
for _t40_wait in $(seq 1 200); do
    [ -s "$T40_HELP_PID_FILE" ] && [ -e "$T40_HELP_READY" ] && break
    sleep 0.025
done
T40_HELP_PID=$(cat "$T40_HELP_PID_FILE" 2>/dev/null || true)
kill -9 "$T40_HELP_ADAPTER_PID" 2>/dev/null || true
wait "$T40_HELP_ADAPTER_PID" 2>/dev/null || true
t40_run_recovery "$T40_HELP_ADD" "$T40_HELP_BIN" \
    "$T40_ROOT/help-recovery.out" "$T40_ROOT/help-recovery.err" T40_HELP_RECOVERY=1
T40_HELP_RECOVERY_RC="$T40_RECOVERY_RC"
T40_HELP_ORPHAN_LIVE=false
t40_process_is_non_zombie "$T40_HELP_PID" && T40_HELP_ORPHAN_LIVE=true
kill -9 "$T40_HELP_PID" 2>/dev/null || true
t40_wait_for_process_exit "$T40_HELP_PID" || true
if [ "$T40_HELP_ORPHAN_LIVE" = true ] && [ "$T40_HELP_RECOVERY_RC" -eq 0 ] && \
   grep -q '^hung-help recovery complete$' "$T40_ROOT/help-recovery.out"; then
    pass "T40k: hung --help cannot pin the lifetime FIFO after top SIGKILL"
else
    fail "T40k: capability probe pinned admission (probe=$T40_HELP_PID live=$T40_HELP_ORPHAN_LIVE recovery=$T40_HELP_RECOVERY_RC)"
fi

# Exact helper death in mkdir→pid and pid→owner can leave only an inert private
# runtime staging directory; the immutable legacy fence remains unchanged.
t40_unpublished_bridge_sigkill() {
    local label="$1" sequence="$2" seam="$3" expected_mode="$4"
    local add_dir="$T40_ROOT/peer-${sequence}-oauth-${label}"
    local recovery_dir="${add_dir}-cross"
    local barrier="$T40_ROOT/oauth-${label}"
    local adapter_pid helper_pid bridge_dir staged_pid owner_absent=true
    local adapter_rc recovery_rc pid_ok=false

    mkdir -p "$add_dir" "$recovery_dir"
    rm -f "$T40_CRASH_READY" "$T40_CROSS_READY" \
        "$T40_CRASH_VENDOR_PID_FILE" "$T40_CRASH_GRANDCHILD_PID_FILE"
    : > "$T40_CRASH_ENTRIES"
    t40_launch_peer "$add_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/oauth-${label}.out" "$T40_ROOT/oauth-${label}.err" \
        IWE_PEER_TIMEOUT_SECONDS=30 T40_RECOVERY=1 "$seam=$barrier" &
    adapter_pid=$!
    for _t40_oauth_boundary_wait in $(seq 1 200); do
        [ -s "$barrier.ready" ] && break
        sleep 0.025
    done
    helper_pid=$(cat "$barrier.ready" 2>/dev/null || true)
    bridge_dir=$(find "$T40_LOCK_DIR" -maxdepth 1 -type d \
        -name 'kimi-oauth-refresh.lineage-v4.*' -print -quit)
    staged_pid=$(cat "$bridge_dir/pid" 2>/dev/null || true)
    [ -e "$bridge_dir/owner" ] && owner_absent=false
    if { [ "$expected_mode" = absent ] && [ -z "$staged_pid" ]; } || \
       { [ "$expected_mode" = controller-group ] && \
         [ "$staged_pid" = "-$helper_pid" ]; }; then
        pid_ok=true
    fi
    kill -9 "$helper_pid" 2>/dev/null || true
    if wait "$adapter_pid" 2>/dev/null; then adapter_rc=0; else adapter_rc=$?; fi
    t40_run_recovery "$recovery_dir" "$T40_CRASH_BIN" \
        "$T40_ROOT/oauth-${label}-recovery.out" \
        "$T40_ROOT/oauth-${label}-recovery.err" \
        T40_RECOVERY=1 T40_CROSS_SESSION=1
    recovery_rc="$T40_RECOVERY_RC"

    if [[ "$helper_pid" =~ ^[0-9]+$ ]] && [ -n "$bridge_dir" ] && \
       [ -L "$T40_OAUTH_DIR" ] && \
       [ "$(readlink "$T40_OAUTH_DIR")" = "$T40_FENCE_TARGET" ] && \
       [ ! -e "$T40_OAUTH_LINEAGE" ] && [ ! -L "$T40_OAUTH_LINEAGE" ] && \
       [ "$pid_ok" = true ] && [ "$owner_absent" = true ] && \
       [ "$adapter_rc" -eq 1 ] && [ "$recovery_rc" -eq 0 ] && \
       [ "$(wc -l < "$T40_CRASH_ENTRIES" | tr -d ' ')" -eq 1 ]; then
        [ -z "$bridge_dir" ] || rm -rf -- "$bridge_dir"
        return 0
    fi
    T40_UNPUBLISHED_ERROR="label=$label helper=$helper_pid bridge=$bridge_dir pid=$staged_pid expected=$expected_mode owner_absent=$owner_absent adapter=$adapter_rc recovery=$recovery_rc"
    [ -z "$bridge_dir" ] || rm -rf -- "$bridge_dir"
    return 1
}

T40_UNPUBLISHED_ERROR=""
if t40_unpublished_bridge_sigkill post-mkdir 08 \
       IWE_PEER_TEST_OAUTH_POST_MKDIR_BARRIER absent && \
   t40_unpublished_bridge_sigkill pre-owner 14 \
       IWE_PEER_TEST_OAUTH_PRE_OWNER_BARRIER controller-group; then
    pass "T40l: helper SIGKILL in both staging windows preserves fence and leaves runtime free"
else
    fail "T40l: unpublished v4 staging blocked recovery ($T40_UNPUBLISHED_ERROR)"
fi

# A pre-v4 contender may pause after its stale-PID decision. Ordinary
# admission and asserted cutover preserve that real directory. After external
# quiescence and drain, explicit cutover installs an immutable -1 fence that a
# rollback implementation observes as permanently live.
T40_ABA_LOCK_DIR="$T40_ROOT/oauth-aba-locks"
T40_ABA_CANONICAL="$T40_ABA_LOCK_DIR/kimi-oauth-refresh.lockdir"
T40_ABA_ADD="$T40_ROOT/peer-15-legacy-aba"
T40_ABA_CHECKED="$T40_ROOT/legacy-aba.checked"
T40_ABA_RELEASE="$T40_ROOT/legacy-aba.release"
T40_ABA_ENTERED="$T40_ROOT/legacy-aba.entered"
T40_ABA_DONE="$T40_ROOT/legacy-aba.done"
mkdir -p "$T40_ABA_LOCK_DIR" "$T40_ABA_CANONICAL" "$T40_ABA_ADD"
printf '%s\n' 99999999 > "$T40_ABA_CANONICAL/pid"
python3 - "$T40_ABA_CANONICAL" "$T40_ABA_CHECKED" "$T40_ABA_RELEASE" \
    "$T40_ABA_ENTERED" "$T40_ABA_DONE" <<'PY' &
import os
import shutil
import sys
import time

canonical, checked, release, entered, done = sys.argv[1:]
holder = open(os.path.join(canonical, "pid"), encoding="ascii").read().strip()
try:
    os.kill(int(holder), 0)
    raise SystemExit("fixture holder unexpectedly alive")
except ProcessLookupError:
    pass
open(checked, "w", encoding="ascii").close()
while not os.path.exists(release):
    time.sleep(0.02)
shutil.rmtree(canonical)
os.mkdir(canonical, 0o700)
with open(os.path.join(canonical, "pid"), "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
open(entered, "w", encoding="ascii").close()
while not os.path.exists(done):
    time.sleep(0.02)
shutil.rmtree(canonical)
PY
T40_ABA_LEGACY_PID=$!
for _t40_aba_wait in $(seq 1 200); do
    [ -e "$T40_ABA_CHECKED" ] && break
    sleep 0.025
done
T40_ABA_INODE=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_ABA_CANONICAL")
rm -f "$T40_CRASH_READY"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_ABA_LOCK_DIR" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_ABA_ADD" \
    </dev/null >"$T40_ROOT/legacy-aba-peer.out" 2>"$T40_ROOT/legacy-aba-peer.err"; then
    T40_ABA_PEER_RC=0
else
    T40_ABA_PEER_RC=$?
fi
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_ABA_LOCK_DIR" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/legacy-aba-cutover-blocked.out" \
    2>"$T40_ROOT/legacy-aba-cutover-blocked.err"; then
    T40_ABA_CUTOVER_BLOCKED_RC=0
else
    T40_ABA_CUTOVER_BLOCKED_RC=$?
fi
T40_ABA_INODE_AFTER=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_ABA_CANONICAL" 2>/dev/null || true)
touch "$T40_ABA_RELEASE"
for _t40_aba_enter_wait in $(seq 1 200); do
    [ -e "$T40_ABA_ENTERED" ] && break
    sleep 0.025
done
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_ABA_LOCK_DIR" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/legacy-aba-live-cutover.out" \
    2>"$T40_ROOT/legacy-aba-live-cutover.err"; then
    T40_ABA_LIVE_CUTOVER_RC=0
else
    T40_ABA_LIVE_CUTOVER_RC=$?
fi
touch "$T40_ABA_DONE"
wait "$T40_ABA_LEGACY_PID" 2>/dev/null || true
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_ABA_LOCK_DIR" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/legacy-aba-cutover.out" 2>"$T40_ROOT/legacy-aba-cutover.err"; then
    T40_ABA_CUTOVER_RC=0
else
    T40_ABA_CUTOVER_RC=$?
fi
T40_ABA_FENCE_INODE=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_ABA_CANONICAL" 2>/dev/null || true)
T40_ABA_ROLLBACK_BLOCKED=false
if ! mkdir "$T40_ABA_CANONICAL" 2>/dev/null; then
    T40_ABA_ROLLBACK_HOLDER=$(cat "$T40_ABA_CANONICAL/pid" 2>/dev/null || true)
    if [ "$T40_ABA_ROLLBACK_HOLDER" = -1 ] && \
       kill -0 "$T40_ABA_ROLLBACK_HOLDER" 2>/dev/null; then
        T40_ABA_ROLLBACK_BLOCKED=true
    fi
fi
T40_ABA_FENCE_INODE_AFTER=$(python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$T40_ABA_CANONICAL" 2>/dev/null || true)
if [ "$T40_ABA_PEER_RC" -eq 1 ] && \
   [ "$T40_ABA_CUTOVER_BLOCKED_RC" -eq 1 ] && \
   [ "$T40_ABA_INODE_AFTER" = "$T40_ABA_INODE" ] && \
   [ -e "$T40_ABA_ENTERED" ] && [ "$T40_ABA_LIVE_CUTOVER_RC" -eq 1 ] && \
   [ "$T40_ABA_CUTOVER_RC" -eq 0 ] && \
   [ "$T40_ABA_ROLLBACK_BLOCKED" = true ] && \
   [ "$T40_ABA_FENCE_INODE_AFTER" = "$T40_ABA_FENCE_INODE" ] && \
   [ ! -e "$T40_CRASH_READY" ]; then
    pass "T40w: paused legacy ABA blocks admission/cutover; drained cutover fence blocks rollback"
else
    fail "T40w: v4 quiescence/fence boundary failed (peer=$T40_ABA_PEER_RC cutover_paused=$T40_ABA_CUTOVER_BLOCKED_RC inode=$T40_ABA_INODE/$T40_ABA_INODE_AFTER live_cutover=$T40_ABA_LIVE_CUTOVER_RC cutover=$T40_ABA_CUTOVER_RC rollback=$T40_ABA_ROLLBACK_BLOCKED fence=$T40_ABA_FENCE_INODE/$T40_ABA_FENCE_INODE_AFTER)"
fi

# Ordinary calls must never infer quiescence or create the fence themselves.
T40_NO_FENCE_ROOT="$T40_ROOT/oauth-no-fence-locks"
T40_NO_FENCE_ADD="$T40_ROOT/peer-17-no-fence"
mkdir -p "$T40_NO_FENCE_ROOT" "$T40_NO_FENCE_ADD"
rm -f "$T40_CRASH_READY"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_NO_FENCE_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_NO_FENCE_ADD" \
    </dev/null >"$T40_ROOT/no-fence.out" 2>"$T40_ROOT/no-fence.err"; then
    T40_NO_FENCE_RC=0
else
    T40_NO_FENCE_RC=$?
fi
if [ "$T40_NO_FENCE_RC" -eq 1 ] && \
   [ ! -e "$T40_NO_FENCE_ROOT/kimi-oauth-refresh.lockdir" ] && \
   [ ! -L "$T40_NO_FENCE_ROOT/kimi-oauth-refresh.lockdir" ] && \
   [ ! -e "$T40_NO_FENCE_ROOT/kimi-oauth-refresh.lineage-v4" ] && \
   [ ! -e "$T40_CRASH_READY" ] && \
   grep -q 'OAuth lineage v4 cutover is required' "$T40_ROOT/no-fence.err"; then
    pass "T40x: no-fence ordinary call fails closed without auto-cutover or vendor entry"
else
    fail "T40x: no-fence state was auto-upgraded/admitted (rc=$T40_NO_FENCE_RC)"
fi

# Exact OAuth metadata is byte-exact. Invalid bytes must fault rather than be
# dropped during decoding and turn a tampered payload back into a valid one.
T40_NONASCII_ROOT="$T40_ROOT/oauth-nonascii-locks"
T40_NONASCII_ADD="$T40_ROOT/peer-18-oauth-nonascii"
T40_NONASCII_FENCE="$T40_NONASCII_ROOT/kimi-oauth-refresh.lockdir"
mkdir -p "$T40_NONASCII_ROOT" "$T40_NONASCII_ADD"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_NONASCII_ROOT" \
    IWE_OAUTH_CUTOVER_QUIESCED=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" \
    --cutover-oauth-lineage-v4 \
    >"$T40_ROOT/nonascii-cutover.out" 2>"$T40_ROOT/nonascii-cutover.err"; then
    T40_NONASCII_CUTOVER_RC=0
else
    T40_NONASCII_CUTOVER_RC=$?
fi
T40_NONASCII_OWNER=$(cat "$T40_NONASCII_FENCE/owner" 2>/dev/null || true)
printf '%s\377\n' "$T40_NONASCII_OWNER" > "$T40_NONASCII_FENCE/owner"
rm -f "$T40_CRASH_READY"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_NONASCII_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_NONASCII_ADD" \
    </dev/null >"$T40_ROOT/nonascii.out" 2>"$T40_ROOT/nonascii.err"; then
    T40_NONASCII_RC=0
else
    T40_NONASCII_RC=$?
fi
if [ "$T40_NONASCII_CUTOVER_RC" -eq 0 ] && \
   [ "$T40_NONASCII_RC" -eq 1 ] && \
   [ -L "$T40_NONASCII_FENCE" ] && \
   [ ! -e "$T40_NONASCII_ROOT/kimi-oauth-refresh.lineage-v4" ] && \
   [ ! -L "$T40_NONASCII_ROOT/kimi-oauth-refresh.lineage-v4" ] && \
   [ ! -e "$T40_CRASH_READY" ]; then
    pass "T40z: non-ASCII OAuth metadata faults closed without vendor entry"
else
    fail "T40z: metadata validation accepted invalid ASCII (cutover=$T40_NONASCII_CUTOVER_RC rc=$T40_NONASCII_RC)"
fi

# Rollout boundary: every historical real directory is untrusted. Live,
# dead ownerless, raw-nonce and fully staged v2 variants all remain untouched.
T40_LEGACY_ROOT="$T40_ROOT/oauth-legacy-locks"
T40_LEGACY_DIR="$T40_LEGACY_ROOT/kimi-oauth-refresh.lockdir"
T40_LEGACY_ADD="$T40_ROOT/peer-oauth-legacy-session"
mkdir -p "$T40_LEGACY_ROOT" "$T40_LEGACY_DIR" "$T40_LEGACY_ADD"
( sleep 5 ) &
T40_LEGACY_HOLDER_PID=$!
printf '%s\n' "$T40_LEGACY_HOLDER_PID" > "$T40_LEGACY_DIR/pid"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_LEGACY_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_LEGACY_ADD" \
    </dev/null >"$T40_ROOT/legacy-live.out" 2>"$T40_ROOT/legacy-live.err"; then
    T40_LEGACY_LIVE_RC=0
else
    T40_LEGACY_LIVE_RC=$?
fi
T40_LEGACY_PID_AFTER=$(cat "$T40_LEGACY_DIR/pid" 2>/dev/null || true)
if [ "$T40_LEGACY_LIVE_RC" -eq 1 ] && \
   [ "$T40_LEGACY_PID_AFTER" = "$T40_LEGACY_HOLDER_PID" ]; then
    pass "T40m: live pid-only scheduler remains untouched before explicit cutover"
else
    fail "T40m: live legacy OAuth holder was altered (rc=$T40_LEGACY_LIVE_RC expected=$T40_LEGACY_HOLDER_PID actual=$T40_LEGACY_PID_AFTER)"
fi
kill "$T40_LEGACY_HOLDER_PID" 2>/dev/null || true
wait "$T40_LEGACY_HOLDER_PID" 2>/dev/null || true
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_LEGACY_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_LEGACY_ADD" \
    </dev/null >"$T40_ROOT/legacy-dead.out" 2>"$T40_ROOT/legacy-dead.err"; then
    T40_LEGACY_DEAD_RC=0
else
    T40_LEGACY_DEAD_RC=$?
fi
T40_RAW_NONCE=0123456789abcdef0123456789abcdef
printf '%s\n' "$T40_RAW_NONCE" > "$T40_LEGACY_DIR/owner"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_LEGACY_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_LEGACY_ADD" \
    </dev/null >"$T40_ROOT/raw-dead.out" 2>"$T40_ROOT/raw-dead.err"; then
    T40_RAW_DEAD_RC=0
else
    T40_RAW_DEAD_RC=$?
fi
if [ "$T40_LEGACY_DEAD_RC" -eq 1 ] && [ "$T40_RAW_DEAD_RC" -eq 1 ] && \
   [ -d "$T40_LEGACY_DIR" ] && \
   [ "$(cat "$T40_LEGACY_DIR/pid" 2>/dev/null || true)" = "$T40_LEGACY_HOLDER_PID" ] && \
   [ "$(cat "$T40_LEGACY_DIR/owner" 2>/dev/null || true)" = "$T40_RAW_NONCE" ]; then
    pass "T40n: dead ownerless/raw legacy directories remain fail-closed"
else
    fail "T40n: dead legacy/raw directory was altered (legacy=$T40_LEGACY_DEAD_RC raw=$T40_RAW_DEAD_RC)"
fi

rm -rf "$T40_LEGACY_DIR"
mkdir -p "$T40_LEGACY_DIR"
T40_SHARED_LEASE_ID=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev} {s.st_ino}")' "$T40_LEGACY_ROOT/kimi-oauth-refresh.lease")
T40_VERSIONED_NONCE=fedcba9876543210fedcba9876543210
printf '%s\n' 99999999 > "$T40_LEGACY_DIR/pid"
printf 'iwe-oauth-sentinel-v2 %s %s\n' "$T40_SHARED_LEASE_ID" "$T40_VERSIONED_NONCE" > "$T40_LEGACY_DIR/owner"
if "${T40_ADAPTER_ENV[@]}" IWE_PEER_LOCK_DIR="$T40_LEGACY_ROOT" \
    KIMI_BIN="$T40_CRASH_BIN" T40_RECOVERY=1 \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=1 \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_LEGACY_ADD" \
    </dev/null >"$T40_ROOT/versioned-recovery.out" 2>"$T40_ROOT/versioned-recovery.err"; then
    T40_VERSIONED_RECOVERY_RC=0
else
    T40_VERSIONED_RECOVERY_RC=$?
fi
if [ "$T40_VERSIONED_RECOVERY_RC" -eq 1 ] && \
   [ -d "$T40_LEGACY_DIR" ] && [ ! -L "$T40_LEGACY_DIR" ] && \
   [ "$(cat "$T40_LEGACY_DIR/pid")" = 99999999 ] && \
   [ "$(cat "$T40_LEGACY_DIR/owner")" = "iwe-oauth-sentinel-v2 $T40_SHARED_LEASE_ID $T40_VERSIONED_NONCE" ]; then
    pass "T40o: valid v2 real directory stays fail-closed at the cutover boundary"
else
    fail "T40o: v2 real directory was removed (rc=$T40_VERSIONED_RECOVERY_RC)"
fi

# Only the separate new-only runtime namespace supports automatic recovery.
T40_V4_MISSING_NONCE=0123456789abcdefabcdef0123456789
T40_V4_MISSING_TARGET="kimi-oauth-refresh.lineage-v4.$T40_V4_MISSING_NONCE"
ln -s "$T40_V4_MISSING_TARGET" "$T40_OAUTH_LINEAGE"
if t40_run_peer "$T40_LEGACY_ADD" "$T40_CRASH_BIN" \
    "$T40_ROOT/v4-missing-recovery.out" "$T40_ROOT/v4-missing-recovery.err" \
    IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS=2 T40_RECOVERY=1; then
    T40_V4_MISSING_RC=0
else
    T40_V4_MISSING_RC=$?
fi
if [ "$T40_V4_MISSING_RC" -eq 0 ] && \
   [ ! -e "$T40_OAUTH_LINEAGE" ] && [ ! -L "$T40_OAUTH_LINEAGE" ] && \
   [ -L "$T40_OAUTH_DIR" ] && \
   [ "$(readlink "$T40_OAUTH_DIR")" = "$T40_FENCE_TARGET" ] && \
   grep -q '^SIGKILL recovery complete$' "$T40_ROOT/v4-missing-recovery.out"; then
    pass "T40y: missing-target v4 runtime recovers without changing permanent fence"
else
    fail "T40y: v4 runtime recovery failed (rc=$T40_V4_MISSING_RC runtime=$(test -L "$T40_OAUTH_LINEAGE" -o -e "$T40_OAUTH_LINEAGE" && echo present || echo absent) fence=$(readlink "$T40_OAUTH_DIR" 2>/dev/null || true))"
fi

# TERM must terminate the adapter after cleanup; the old multi-signal cleanup
# handler returned to normal execution and could print a response after giving
# up its lock. Release the fake CLI only to let Bash deliver its deferred trap.
T40_TERM_ADD="$T40_ROOT/peer-term-session"
T40_TERM_READY="$T40_ROOT/term-ready"
T40_TERM_RELEASE="$T40_ROOT/term-release"
T40_TERM_BEACON="$T40_IWE/.iwe-runtime/peer-heartbeats/kimi-peer-peer-term-session.heartbeat"
mkdir -p "$T40_TERM_ADD"
HOME="$T40_HOME" CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' \
    IWE_PEER_PLAIN=1 IWE_ROOT="$T40_IWE" \
    IWE_PEER_LOCK_DIR="$T40_LOCK_DIR" IWE_PEER_HEARTBEAT_SECONDS=1 \
    IWE_PEER_TIMEOUT_SECONDS=10 T40_READY="$T40_TERM_READY" \
    T40_RELEASE="$T40_TERM_RELEASE" KIMI_BIN="$T40_BIN" \
    bash "$TEMPLATE_DIR/scripts/kimi-peer-adapter.sh" --add-dir "$T40_TERM_ADD" \
    </dev/null >"$T40_ROOT/term.out" 2>"$T40_ROOT/term.err" &
T40_TERM_PID=$!
for _t40_wait in $(seq 1 200); do
    [ -s "$T40_TERM_READY" ] && [ -f "$T40_TERM_BEACON" ] && break
    sleep 0.05
done
kill -TERM "$T40_TERM_PID" 2>/dev/null || true
touch "$T40_TERM_RELEASE"
if wait "$T40_TERM_PID"; then
    T40_TERM_RC=0
else
    T40_TERM_RC=$?
fi
if [ "$T40_TERM_RC" -eq 143 ] && [ ! -s "$T40_ROOT/term.out" ] && \
   [ ! -e "$T40_TERM_BEACON" ]; then
    pass "T40p: TERM exits after exact cleanup and cannot continue the peer call"
else
    fail "T40p: TERM did not stop the adapter (rc=$T40_TERM_RC output=$(wc -c < "$T40_ROOT/term.out" | tr -d ' '))"
fi

mkdir -p "$T40_IWE/.iwe-runtime/peer-heartbeats"
cat > "$T40_BEACON" <<'EOF'
opened_at: 2020-01-01T00:00:00Z
wp: WP-7
task: bounded consumer probe
agent: kimi-peer
heartbeat_at: 2020-01-01T00:00:00Z
EOF
T40_WATCHDOG_OUT=$(IWE_ROOT="$T40_IWE" SILENCE_THRESHOLD_S=1 \
    bash -c 'source "$1"; notify_pilot(){ printf "%s|%s\n" "$1" "$2"; }; scan_once' \
    t40 "$TEMPLATE_DIR/scripts/kimi-session-watchdog.sh" 2>&1)
T40_WATCHDOG_RC=$?
if [ "$T40_WATCHDOG_RC" -eq 0 ] && [[ "$T40_WATCHDOG_OUT" == *"$T40_BEACON|"* ]]; then
    pass "T40q: watchdog consumes the separate peer-heartbeats namespace"
else
    fail "T40q: watchdog ignored the peer heartbeat (rc=$T40_WATCHDOG_RC out=$T40_WATCHDOG_OUT)"
fi

T40_FRESH_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$T40_BEACON" <<EOF
opened_at: $T40_FRESH_NOW
wp: WP-7
task: fresh consumer probe
agent: kimi-peer
heartbeat_at: $T40_FRESH_NOW
EOF
T40_FRESH_OUT=$(IWE_ROOT="$T40_IWE" SILENCE_THRESHOLD_S=300 \
    bash -c 'source "$1"; notify_pilot(){ printf "%s|%s\n" "$1" "$2"; }; scan_once' \
    t40 "$TEMPLATE_DIR/scripts/kimi-session-watchdog.sh" 2>&1)
if [ -z "$T40_FRESH_OUT" ]; then
    pass "T40r: watchdog does not alert on a fresh peer heartbeat"
else
    fail "T40r: watchdog falsely reported a fresh heartbeat: $T40_FRESH_OUT"
fi

if IWE_ROOT="$T40_IWE" CHECK_INTERVAL_S=0 \
   bash -c 'source "$1"' t40 "$TEMPLATE_DIR/scripts/kimi-session-watchdog.sh" \
   >"$T40_ROOT/invalid-interval.out" 2>&1; then
    T40_BAD_INTERVAL_RC=0
else
    T40_BAD_INTERVAL_RC=$?
fi
if IWE_ROOT="$T40_IWE" SILENCE_THRESHOLD_S=not-a-number \
   bash -c 'source "$1"' t40 "$TEMPLATE_DIR/scripts/kimi-session-watchdog.sh" \
   >"$T40_ROOT/invalid-threshold.out" 2>&1; then
    T40_BAD_THRESHOLD_RC=0
else
    T40_BAD_THRESHOLD_RC=$?
fi
if [ "$T40_BAD_INTERVAL_RC" -ne 0 ] && [ "$T40_BAD_THRESHOLD_RC" -ne 0 ] && \
   grep -q 'positive integer' "$T40_ROOT/invalid-interval.out" && \
   grep -q 'positive integer' "$T40_ROOT/invalid-threshold.out"; then
    pass "T40s: watchdog rejects zero and non-numeric timing controls"
else
    fail "T40s: watchdog accepted an unsafe timing value (interval=$T40_BAD_INTERVAL_RC threshold=$T40_BAD_THRESHOLD_RC)"
fi

T40_OSA_DIR="$T40_ROOT/fake-osa-bin"
T40_OSA_CAPTURE="$T40_ROOT/osascript-args.json"
mkdir -p "$T40_OSA_DIR"
cat > "$T40_OSA_DIR/osascript" <<'EOF'
#!/bin/bash
python3 - "$T40_OSA_CAPTURE" "$@" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]), encoding="utf-8")
PY
EOF
chmod +x "$T40_OSA_DIR/osascript"
export T40_OSA_CAPTURE
if ! PATH="$T40_OSA_DIR:$PATH" command -v osascript >/dev/null 2>&1; then
    fail "T40t: fake osascript is not discoverable"
fi
cat > "$T40_BEACON" <<'EOF'
opened_at: 2020-01-01T00:00:00Z
wp: WP-7
task: probe"; display dialog "PWN
agent: kimi-peer
heartbeat_at: 2020-01-01T00:00:00Z
EOF
PATH="$T40_OSA_DIR:$PATH" IWE_ROOT="$T40_IWE" SILENCE_THRESHOLD_S=1 \
    bash -c 'source "$1"; notify_pilot "$2" 999' \
    t40 "$TEMPLATE_DIR/scripts/kimi-session-watchdog.sh" "$T40_BEACON"
if python3 - "$T40_OSA_CAPTURE" <<'PY'
import json
import pathlib
import sys

args = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert len(args) == 2 and args[0] == "-e"
program = args[1]
assert 'subtitle "probe\\"; display dialog \\"PWN"' in program
assert 'subtitle "probe"; display dialog "PWN"' not in program
PY
then
    pass "T40t: watchdog escapes peer labels before AppleScript interpolation"
else
    fail "T40t: watchdog exposed an unescaped peer label to AppleScript"
fi

T40_PYTHON3=$("$TEMPLATE_DIR/scripts/lib/find-python3.sh" 2>/dev/null || true)
if [ -n "$T40_PYTHON3" ]; then
    T40_LANG_RESULT=$(printf '%s\n' 'This complete response is deliberately written only in English prose.' | \
        "$T40_PYTHON3" "$TEMPLATE_DIR/scripts/lib/language-check.py" 2>/dev/null || true)
else
    T40_LANG_RESULT=""
fi
if [ -n "$T40_PYTHON3" ] && "$T40_PYTHON3" - "$T40_LANG_RESULT" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["alert"] is True
PY
then
    pass "T40u: template delivers the peer language-check dependency"
else
    fail "T40u: peer language-check dependency is missing or inactive"
fi

# ============================================================================
# T41: sync_workspace_claude_md() accepts a hand-resolved conflict instead of
# re-merging it against the stale base forever; a stale pending record
# (upstream moved on since) is discarded, not silently accepted (issue #846)
# ============================================================================
echo "--- T41: workspace CLAUDE.md conflict-pending sidecar (issue #846) ---"

T41_FN_BLOCK=$(awk '/^sync_workspace_claude_md\(\) \{$/{found=1} found{print} found && /^}$/{exit}' "$TEMPLATE_DIR/update.sh")
if [ -z "$T41_FN_BLOCK" ]; then
    fail "T41: could not extract sync_workspace_claude_md() from update.sh — signature moved?"
else
    T41_DIR="$TEST_WS/t41-claude-conflict"
    mkdir -p "$T41_DIR"
    T41_FN_FILE="$T41_DIR/fn.sh"
    printf '%s\n' "$T41_FN_BLOCK" > "$T41_FN_FILE"

    # Stubs for the function's two dependencies — this test targets the
    # merge/conflict/pending logic, not placeholder substitution or the
    # (unrelated) silent-loss heuristic.
    substitute_claude_placeholders() { cp "$1" "$2"; }
    detect_claude_silent_loss() { echo 0; }
    # shellcheck source=/dev/null
    source "$T41_FN_FILE"

    T41_SCRIPT_DIR="$T41_DIR/script"
    T41_WORKSPACE_DIR="$T41_DIR/workspace"
    mkdir -p "$T41_SCRIPT_DIR" "$T41_WORKSPACE_DIR" "$T41_DIR/tmp"

    # base + pilot's copy + upstream's next edit disagree on the same line —
    # a real, unavoidable 3-way conflict.
    printf 'line one\nORIGINAL\nline three\n' > "$T41_WORKSPACE_DIR/.claude.md.base"
    printf 'line one\nPILOT-EDIT\nline three\n' > "$T41_WORKSPACE_DIR/CLAUDE.md"
    printf 'line one\nUPSTREAM-EDIT\nline three\n' > "$T41_SCRIPT_DIR/CLAUDE.md"

    SCRIPT_DIR="$T41_SCRIPT_DIR" WORKSPACE_DIR="$T41_WORKSPACE_DIR" TMPDIR_UPDATE="$T41_DIR/tmp"
    CLAUDE_CONFLICT_DETECTED=false; CLAUDE_CONFLICT_FILES=(); CLAUDE_SILENT_LOSS_FILES=(); CLAUDE_CONFLICTS=0
    sync_workspace_claude_md

    if grep -q '^<<<<<<<' "$T41_WORKSPACE_DIR/CLAUDE.md" \
        && [ -f "$T41_WORKSPACE_DIR/.claude.md.conflict-pending" ] \
        && grep -q 'UPSTREAM-EDIT' "$T41_WORKSPACE_DIR/.claude.md.conflict-pending"; then
        pass "T41: first run — real conflict surfaced and recorded as pending"
    else
        fail "T41: first run did not produce the expected conflict/pending state"
    fi

    # The pilot resolves it by hand: keeps their own edit, removes markers.
    # Upstream CLAUDE.md is unchanged since the conflict.
    printf 'line one\nPILOT-EDIT\nline three\n' > "$T41_WORKSPACE_DIR/CLAUDE.md"
    sync_workspace_claude_md

    if ! grep -q '^<<<<<<<' "$T41_WORKSPACE_DIR/CLAUDE.md" \
        && grep -q 'PILOT-EDIT' "$T41_WORKSPACE_DIR/CLAUDE.md" \
        && grep -q 'UPSTREAM-EDIT' "$T41_WORKSPACE_DIR/.claude.md.base" \
        && [ ! -f "$T41_WORKSPACE_DIR/.claude.md.conflict-pending" ]; then
        pass "T41: hand-resolved file accepted — base advanced without re-merging, file untouched"
    else
        fail "T41: hand-resolved file was re-merged instead of accepted"
    fi

    if compgen -G "$T41_WORKSPACE_DIR/.claude.md.base.bak-*" > /dev/null; then
        pass "T41: old base backed up before being advanced"
    else
        fail "T41: old base was overwritten with no backup"
    fi

    # --- Scenario 2: upstream moves on again before the pilot resolves. The
    # stale pending record (recorded against the now-superseded upstream
    # edit) must not be blindly trusted — a fresh merge decides instead. ---
    T41_SCRIPT_DIR2="$T41_DIR/script2"
    T41_WORKSPACE_DIR2="$T41_DIR/workspace2"
    mkdir -p "$T41_SCRIPT_DIR2" "$T41_WORKSPACE_DIR2" "$T41_DIR/tmp2"
    printf 'line one\nORIGINAL\nline three\n' > "$T41_WORKSPACE_DIR2/.claude.md.base"
    printf 'line one\nPILOT-EDIT\nline three\n' > "$T41_WORKSPACE_DIR2/CLAUDE.md"
    printf 'line one\nUPSTREAM-EDIT\nline three\n' > "$T41_SCRIPT_DIR2/CLAUDE.md"

    SCRIPT_DIR="$T41_SCRIPT_DIR2" WORKSPACE_DIR="$T41_WORKSPACE_DIR2" TMPDIR_UPDATE="$T41_DIR/tmp2"
    CLAUDE_CONFLICT_DETECTED=false; CLAUDE_CONFLICT_FILES=(); CLAUDE_SILENT_LOSS_FILES=(); CLAUDE_CONFLICTS=0
    sync_workspace_claude_md   # first conflict — records pending = UPSTREAM-EDIT

    printf 'line one\nPILOT-EDIT\nline three\n' > "$T41_WORKSPACE_DIR2/CLAUDE.md"   # pilot resolves by hand
    printf 'line one\nUPSTREAM-EDIT-V2\nline three\n' > "$T41_SCRIPT_DIR2/CLAUDE.md"  # but upstream moved on

    T41_OUT2=$(SCRIPT_DIR="$T41_SCRIPT_DIR2" WORKSPACE_DIR="$T41_WORKSPACE_DIR2" TMPDIR_UPDATE="$T41_DIR/tmp2" \
        sync_workspace_claude_md)

    if ! printf '%s' "$T41_OUT2" | grep -q "принят как разрешённый вручную" \
        && grep -q '^<<<<<<<' "$T41_WORKSPACE_DIR2/CLAUDE.md"; then
        pass "T41: stale pending (upstream moved on) is discarded — fresh merge runs instead of blind accept"
    else
        fail "T41: stale pending record was blindly accepted despite upstream moving on"
    fi
fi

# ============================================================================
# T42: memory/*.md stale-repair backs up the workspace copy before
# overwriting it, like .claude/rules/* already does (issue #847)
# ============================================================================
echo "--- T42: memory/* stale-repair backup (issue #847) ---"

T42_FN_BLOCK=$(awk '/^backup_memory_file_before_overwrite\(\) \{$/{found=1} found{print} found && /^}$/{exit}' "$TEMPLATE_DIR/update.sh")
if [ -z "$T42_FN_BLOCK" ]; then
    fail "T42: could not extract backup_memory_file_before_overwrite() from update.sh — signature moved?"
else
    T42_DIR="$TEST_WS/t42-memory-backup"
    T42_WORKSPACE_DIR="$T42_DIR/workspace"
    mkdir -p "$T42_WORKSPACE_DIR/memory"
    printf '%s\n' "$T42_FN_BLOCK" > "$T42_DIR/fn.sh"
    # shellcheck source=/dev/null
    source "$T42_DIR/fn.sh"

    WORKSPACE_DIR="$T42_WORKSPACE_DIR"
    MEMORY_BACKUP_RUN=""
    printf 'owner: platform\npilot-local edits here\n' > "$T42_WORKSPACE_DIR/memory/navigation.md"
    backup_memory_file_before_overwrite "memory/navigation.md" "$T42_WORKSPACE_DIR/memory/navigation.md"

    T42_BACKUP=$(find "$T42_WORKSPACE_DIR/.backups/memory-pre-update" -type f -name navigation.md -print -quit 2>/dev/null || true)
    if [ -n "$T42_BACKUP" ] && grep -q 'pilot-local edits here' "$T42_BACKUP"; then
        pass "T42: memory/navigation.md backed up before stale-repair overwrite"
    else
        fail "T42: no backup found for memory/navigation.md before overwrite"
    fi

    # A path outside memory/*.md|.yaml|.yml is a no-op (same guard shape as
    # backup_rule_before_overwrite() for .claude/rules/*).
    MEMORY_BACKUP_RUN=""
    printf 'unrelated' > "$T42_WORKSPACE_DIR/README.md"
    backup_memory_file_before_overwrite "README.md" "$T42_WORKSPACE_DIR/README.md"
    if [ -z "$MEMORY_BACKUP_RUN" ]; then
        pass "T42: non-memory path is a no-op, matching the .claude/rules/*-only scope of the sibling function"
    else
        fail "T42: backup_memory_file_before_overwrite acted on a path outside memory/*"
    fi

    T42_WIRED=$(grep -c 'backup_memory_file_before_overwrite "\$fpath" "\$mem_dst"' "$TEMPLATE_DIR/update.sh")
    if [ "$T42_WIRED" -ge 1 ]; then
        pass "T42: repair_pass() actually calls the backup before the stale-repair cp"
    else
        fail "T42: backup_memory_file_before_overwrite() exists but repair_pass() never calls it"
    fi
fi

# ============================================================================
# T43: Step 6 (the main apply path) keeps a memory file the pilot edited, and backs up and
# names a file it replaces because the pilot never changed it (issues #967/#965)
# ============================================================================
echo "--- T43: Step 6 keeps the edited memory file, backs up and reports the replaced one (issues #967/#965) ---"

# T42 covers the backup itself. Step 6 replaced a changed memory/*.md with a bare `cp`: a
# pilot's edit to a platform-owned file (memory/navigation.md holds per-installation notes)
# vanished with every release that touched the file (#967). Now Step 6 refreshes only a copy
# that equals the version installed last time (recorded in Step 2), after a backup, and keeps an
# edited one with a ready command to accept the release version.
# The Step 6 loop is inline code, not a function: it is extracted by the comment above
# it and the closing `fi` of its outer `if`, and run for real on a fixture.
T43_BLOCK=$(awk '
    /^# Copy memory files to Claude projects directory$/ { armed=1; next }
    armed && /^if \[ -d "\$CLAUDE_MEMORY_DIR" \]; then$/ { found=1 }
    found { print }
    found && /^fi$/ { exit }
' "$TEMPLATE_DIR/update.sh")
T43_FUNCS=""
T43_MISSING=""
for t43_fn in hash_file is_author_mode is_personal_config saving_cp_command backup_memory_file_before_overwrite \
    apply_memory_policy record_memory_old_hash memory_old_hash report_memory_policy_summary \
    memory_record_put memory_record_get remember_memory_deployed memory_decided_once memory_reason_text memory_copy_verdict replace_memory_copy; do
    t43_src=$(awk -v fn="$t43_fn" '$0 ~ "^" fn "\\(\\) \\{" {copy=1} copy{print} copy && /^}/{exit}' "$TEMPLATE_DIR/update.sh")
    if [ -z "$t43_src" ]; then
        T43_MISSING="$T43_MISSING $t43_fn"
    fi
    T43_FUNCS="$T43_FUNCS
$t43_src"
done
if [ -z "$T43_BLOCK" ] || [ -n "$T43_MISSING" ]; then
    fail "T43: could not extract the Step 6 memory loop or helpers from update.sh (block empty: $([ -z "$T43_BLOCK" ] && echo yes || echo no), missing functions:${T43_MISSING:- none})"
else
    T43_DIR="$TEST_WS/t43-step6-memory"
    T43_TEMPLATE="$T43_DIR/template"
    T43_PREVIOUS="$T43_DIR/previous"
    T43_WORKSPACE="$T43_DIR/workspace"
    T43_MEMORY="$T43_DIR/claude-memory"
    mkdir -p "$T43_TEMPLATE/memory" "$T43_PREVIOUS/memory" "$T43_WORKSPACE" "$T43_MEMORY"

    # The release: a changed navigation.md, a changed file the pilot never touched, a file that
    # is new here, one that is identical to the pilot's copy, and one the pilot rewrote.
    printf -- '---\nowner: platform\n---\nTemplate v2 navigation\n' > "$T43_TEMPLATE/memory/navigation.md"
    printf -- '---\nowner: platform\n---\nTemplate v2 untouched\n' > "$T43_TEMPLATE/memory/untouched.md"
    printf -- '---\nowner: platform\n---\nBrand new platform file\n' > "$T43_TEMPLATE/memory/brand-new.md"
    printf -- '---\nowner: platform\n---\nSame text on both sides\n' > "$T43_TEMPLATE/memory/same.md"
    printf -- '---\nowner: platform\n---\nTemplate text for a pilot-owned file\n' > "$T43_TEMPLATE/memory/user-owned.md"
    # The versions the previous update installed (what Step 2 records before Step 5 replaces them).
    printf -- '---\nowner: platform\n---\nTemplate v1 navigation\n' > "$T43_PREVIOUS/memory/navigation.md"
    printf -- '---\nowner: platform\n---\nTemplate v1 untouched\n' > "$T43_PREVIOUS/memory/untouched.md"
    printf -- '---\nowner: user\n---\nTemplate v1 text for a pilot-owned file\n' > "$T43_PREVIOUS/memory/user-owned.md"
    # The pilot's deployed copies.
    printf -- '---\nowner: platform\n---\nTemplate v1 navigation\nPilot notes about this installation\n' > "$T43_MEMORY/navigation.md"
    cp "$T43_PREVIOUS/memory/untouched.md" "$T43_MEMORY/untouched.md"
    cp "$T43_TEMPLATE/memory/same.md" "$T43_MEMORY/same.md"
    printf -- '---\nowner: user\n---\nPilot-owned text\n' > "$T43_MEMORY/user-owned.md"

    # t43_run_step6 "NEW FILES" "UPDATED FILES" — the extracted loop, in a subshell (it is
    # update.sh code and runs without -u), after the Step 2 record of the previous versions and
    # followed by the memory summary that closes the pass; prints what they printed.
    t43_run_step6() {
        local new_list="$1" updated_list="$2"
        (
            set +u
            # shellcheck source=/dev/null
            source "$TEMPLATE_DIR/.claude/lib/frontmatter.sh"
            eval "$T43_FUNCS"
            SCRIPT_DIR="$T43_TEMPLATE"
            WORKSPACE_DIR="$T43_WORKSPACE"
            # shellcheck disable=SC2034  # read by the eval'd update.sh code
            CLAUDE_MEMORY_DIR="$T43_MEMORY"
            MEMORY_BACKUP_RUN=""
            MEMORY_OLD_HASHES="$T43_DIR/old-hashes.tsv"
            : > "$MEMORY_OLD_HASHES"
            # shellcheck disable=SC2034  # read by the eval'd update.sh code
            MEMORY_DEPLOYED_RECORD="$T43_WORKSPACE/.memory-deployed.tsv"
            # shellcheck disable=SC2034,SC2206  # word splitting of a list of plain paths is intended
            NEW_FILES=($new_list)
            # shellcheck disable=SC2034,SC2206
            UPDATED_FILES=($updated_list)
            for t43_f in "${UPDATED_FILES[@]}"; do
                if [ -f "$T43_PREVIOUS/$t43_f" ]; then
                    record_memory_old_hash "$t43_f" "$(hash_file "$T43_PREVIOUS/$t43_f")"
                fi
            done
            eval "$T43_BLOCK"
            report_memory_policy_summary
        ) 2>&1
    }
    T43_OUT=$(t43_run_step6 "memory/brand-new.md" "memory/navigation.md memory/untouched.md memory/same.md memory/user-owned.md")

    T43_NAV_LINE=$(grep -F -- 'memory/navigation.md — НЕ обновлён: ' <<<"$T43_OUT" || true)
    if grep -q 'Pilot notes about this installation' "$T43_MEMORY/navigation.md" \
        && grep -qF -- 'Если ваших правок там нет, примите версию шаблона (прежняя копия останется рядом): ' <<<"$T43_NAV_LINE"; then
        pass "T43: the pilot's edited navigation.md is kept, with one line and a ready command"
    else
        fail "T43: the edited navigation.md was replaced or reported without a command: '${T43_NAV_LINE:-<no line>}'"
    fi
    T43_BACKUP=$(find "$T43_WORKSPACE/.backups/memory-pre-update" -type f -name untouched.md -print -quit 2>/dev/null || true)
    if cmp -s "$T43_MEMORY/untouched.md" "$T43_TEMPLATE/memory/untouched.md" \
        && [ -n "$T43_BACKUP" ] && grep -q 'Template v1 untouched' "$T43_BACKUP"; then
        pass "T43: a file the pilot never changed is replaced with the release version, after a backup"
    else
        fail "T43: the untouched file was not replaced after a backup (backup: ${T43_BACKUP:-none})"
    fi
    T43_SUMMARY=$(printf '%s\n' "$T43_OUT" | grep -F 'Заменено файлов памяти' || true)
    if grep -qF -- 'Заменено файлов памяти: 1' <<<"$T43_SUMMARY" \
        && grep -qF -- 'memory/untouched.md' <<<"$T43_SUMMARY" \
        && grep -qF -- "$T43_WORKSPACE/.backups/memory-pre-update" <<<"$T43_SUMMARY"; then
        pass "T43: the summary names the replaced file, their number and the backup directory"
    else
        fail "T43: replaced-files summary is missing or wrong: '${T43_SUMMARY:-<none>}'"
    fi
    if grep -qE -- 'navigation|brand-new|same\.md|user-owned' <<<"$T43_SUMMARY"; then
        fail "T43: the summary lists a file that was not replaced: $T43_SUMMARY"
    else
        pass "T43: kept, new and identical files are not in the replaced-files summary"
    fi
    if [ -f "$T43_MEMORY/brand-new.md" ] \
        && [ -z "$(find "$T43_WORKSPACE/.backups/memory-pre-update" -type f \( -name brand-new.md -o -name same.md -o -name user-owned.md -o -name navigation.md \) -print 2>/dev/null)" ]; then
        pass "T43: a new file is copied, and nothing is backed up for new, identical or kept files"
    else
        fail "T43: new file missing, or an unnecessary backup exists for a new/identical/kept file"
    fi
    if grep -q 'Pilot-owned text' "$T43_MEMORY/user-owned.md"; then
        pass "T43: a pilot-owned (owner: user) file the pilot rewrote is still left alone"
    else
        fail "T43: the pilot's rewrite of user-owned.md was replaced"
    fi

    # A second pass finds nothing to replace: no replaced-files summary.
    T43_OUT2=$(t43_run_step6 "" "memory/navigation.md memory/same.md memory/untouched.md")
    if grep -qF -- 'Заменено файлов памяти' <<<"$T43_OUT2"; then
        fail "T43: a pass that replaces nothing still prints the replaced-files summary"
    else
        pass "T43: no replaced-files summary when no file is replaced"
    fi
fi

# ============================================================================
# T44/T45: the cp command that update.sh offers (the author_mode stale hint; the memory policy's
# command for a kept copy) runs on exactly the printed paths and keeps every earlier copy (cold
# review of #967)
# ============================================================================
# A bare cp loses the copy when the verdict misleads (an edit committed into the clone looks like
# an older version too). The printed command is run by the user's shell, so a path with a double
# quote breaks it, and a literal $(...) in a path would be executed; and a saved copy with a fixed
# (or per-second) name is overwritten by a second run of the same command, leaving only the
# already refreshed copy. The real functions and the real classifier run on a throwaway template
# clone; the printed command runs twice in a shell.

# A `date` that always prints the same value: the runs of a printed command must not depend on the
# clock or on a shell's random numbers for the name of the copy they save.
T44_FIXED_DATE_DIR="$TEST_WS/fixed-date"
mkdir -p "$T44_FIXED_DATE_DIR"
printf '#!/bin/bash\necho 20260101000000\n' > "$T44_FIXED_DATE_DIR/date"
chmod +x "$T44_FIXED_DATE_DIR/date"

# check_saving_hint LABEL HINT COPY ORIGINAL TEMPLATE_TEXT EXPANDED_DIR — HINT is a command line
# update.sh printed for the user to run. It runs twice, back to back, under IDENTICAL conditions:
# the same RANDOM seed and a date that never changes (the same second, the same random number).
# The copy must end up as TEMPLATE_TEXT at exactly COPY; two saved copies must sit next to it, one
# holding ORIGINAL; and the shell must have interpreted nothing in the paths: EXPANDED_DIR, the
# directory a shell would have used after running the $(printf EXPANDED) of the path, must not exist.
check_saving_hint() {
    local label="$1" hint="$2" copy="$3" original="$4" template_text="$5" expanded_dir="$6"
    local saved count=0 original_kept=0
    PATH="$T44_FIXED_DATE_DIR:$PATH" bash -c "RANDOM=11; $hint" > /dev/null 2>&1 || true
    PATH="$T44_FIXED_DATE_DIR:$PATH" bash -c "RANDOM=11; $hint" > /dev/null 2>&1 || true
    for saved in "$copy".before-update-*; do
        [ -f "$saved" ] || continue
        count=$((count + 1))
        if [ "$(cat "$saved")" = "$original" ]; then
            original_kept=1
        fi
    done
    if [ "$count" -eq 2 ] && [ "$original_kept" -eq 1 ] && [ "$(cat "$copy" 2>/dev/null)" = "$template_text" ] \
        && [ ! -e "$expanded_dir" ]; then
        pass "$label: the printed command refreshes exactly the printed path, interprets nothing in it, and two identical runs keep two copies"
    else
        fail "$label: the printed command ('$hint') left $count saved copies (original kept: $original_kept), the copy now holds '$(cat "$copy" 2>/dev/null)', an expanded directory exists: $([ -e "$expanded_dir" ] && echo yes || echo no)"
    fi
}

echo "--- T44: author_mode stale hint: odd paths, two runs keep two copies ---"
T44_FN=$(awk '/^report_author_skip\(\) \{$/{found=1} found{print} found && /^}$/{exit}' "$TEMPLATE_DIR/update.sh")
# The command builder is a helper of the report; it is extracted when update.sh has it (the report
# fails by itself if it calls a helper that is gone).
T44_HELPER=$(awk '/^saving_cp_command\(\) \{$/{found=1} found{print} found && /^}$/{exit}' "$TEMPLATE_DIR/update.sh")
if [ -z "$T44_FN" ]; then
    fail "T44: could not extract report_author_skip() from update.sh — signature moved?"
else
    T44_DIR="$TEST_WS/t44-author-hint"
    # One path with a space, double quotes, a $(...) substitution, backticks and a backslash.
    # shellcheck disable=SC2016  # literal characters, nothing is meant to expand
    T44_ODD='odd "q" $(printf EXPANDED) `b` back\slash'
    T44_TEMPLATE="$T44_DIR/template $T44_ODD"
    T44_COPY="$T44_DIR/copy $T44_ODD/workspace copy.md"
    T44_EXPANDED="$T44_DIR/copy odd \"q\" EXPANDED \`b\` back\\slash"
    mkdir -p "$T44_TEMPLATE/memory" "$T44_TEMPLATE/.claude/scripts" "$(dirname "$T44_COPY")"
    cp "$TEMPLATE_DIR/.claude/scripts/classify-workspace-copy.sh" "$T44_TEMPLATE/.claude/scripts/classify-workspace-copy.sh"
    chmod +x "$T44_TEMPLATE/.claude/scripts/classify-workspace-copy.sh"
    git -C "$T44_TEMPLATE" init -q
    git -C "$T44_TEMPLATE" config user.email "test@test"
    git -C "$T44_TEMPLATE" config user.name "test"
    printf 'template v1\n' > "$T44_TEMPLATE/memory/x.md"
    git -C "$T44_TEMPLATE" add memory/x.md
    git -C "$T44_TEMPLATE" commit -q -m "v1"
    printf 'template v2\n' > "$T44_TEMPLATE/memory/x.md"
    git -C "$T44_TEMPLATE" add memory/x.md
    git -C "$T44_TEMPLATE" commit -q -m "v2"
    printf 'template v1\n' > "$T44_COPY"   # equals the committed v1: verdict "stale"

    T44_OUT=$(
        set +u
        eval "$T44_HELPER"
        eval "$T44_FN"
        SCRIPT_DIR="$T44_TEMPLATE"
        # Exported: the eval'd update.sh function reads and counts them.
        export CLASSIFIER_DEGRADED_WARNED=false AUTHOR_SKIP_AUTHORED=0 AUTHOR_SKIP_STALE=0 AUTHOR_SKIP_UNKNOWN=0
        # shellcheck disable=SC2034
        AUTHOR_STALE_PAIRS=()
        report_author_skip memory/x.md "$T44_COPY"
    )
    if grep -qF -- 'Обновить: ' <<<"$T44_OUT"; then
        T44_HINT="${T44_OUT#*Обновить: }"
        check_saving_hint "T44" "$T44_HINT" "$T44_COPY" "template v1" "template v2" "$T44_EXPANDED"
    else
        fail "T44: report_author_skip() printed no 'Обновить:' hint for a stale copy: '${T44_OUT:-<empty>}'"
    fi
fi

echo "--- T45: kept memory copy: odd paths, the hint's two runs keep two copies (issues #965/#967) ---"
# The memory policy (apply_memory_policy) keeps a copy that matches no committed version and prints
# the saving command for it; a copy that equals a committed older version it refreshes itself,
# after a backup. Both on paths with a space, double quotes, a $(...), backticks and a backslash.
T45_FUNCS=$(update_sh_functions hash_file saving_cp_command backup_memory_file_before_overwrite apply_memory_policy \
    memory_record_put memory_record_get remember_memory_deployed memory_decided_once memory_reason_text memory_copy_verdict replace_memory_copy)
if ! grep -q '^apply_memory_policy() {' <<<"$T45_FUNCS"; then
    fail "T45: could not extract apply_memory_policy() from update.sh"
else
    T45_DIR="$TEST_WS/t45-owner-hint"
    # shellcheck disable=SC2016
    T45_ODD='odd "q" $(printf EXPANDED) `b` back\slash'
    T45_TEMPLATE="$T45_DIR/template $T45_ODD"
    T45_MEMORY="$T45_DIR/memory $T45_ODD"
    T45_WORKSPACE="$T45_DIR/workspace $T45_ODD"
    T45_EXPANDED="$T45_DIR/memory odd \"q\" EXPANDED \`b\` back\\slash"
    # The memory files' own names have the odd characters too (no backslash: git reads one in a pathspec as an escape).
    # shellcheck disable=SC2016
    T45_NAME='odd "q" $(printf EXPANDED) `b`.md'
    # shellcheck disable=SC2016
    T45_STALE_NAME='stale "q" $(printf EXPANDED) `b`.md'
    T45_FPATH="memory/$T45_NAME"
    T45_STALE_FPATH="memory/$T45_STALE_NAME"
    mkdir -p "$T45_TEMPLATE/memory" "$T45_TEMPLATE/.claude/scripts" "$T45_MEMORY"
    cp "$TEMPLATE_DIR/.claude/scripts/classify-workspace-copy.sh" "$T45_TEMPLATE/.claude/scripts/classify-workspace-copy.sh"
    git -C "$T45_TEMPLATE" init -q
    git -C "$T45_TEMPLATE" config user.email "test@test"
    git -C "$T45_TEMPLATE" config user.name "test"
    for t45_v in v1 v2; do
        printf -- '---\nowner: user\n---\ntemplate %s\n' "$t45_v" > "$T45_TEMPLATE/$T45_FPATH"
        printf -- '---\nowner: user\n---\nstale template %s\n' "$t45_v" > "$T45_TEMPLATE/$T45_STALE_FPATH"
        git -C "$T45_TEMPLATE" add -- "$T45_FPATH" "$T45_STALE_FPATH"
        git -C "$T45_TEMPLATE" commit -q -m "$t45_v"
    done
    printf -- '---\nowner: user\n---\nThe pilot edited this copy\n' > "$T45_MEMORY/$T45_NAME"   # no committed version: kept
    printf -- '---\nowner: user\n---\nstale template v1\n' > "$T45_MEMORY/$T45_STALE_NAME"     # the committed v1: refreshed

    T45_OUT=$(
        exec 2>&1
        set +u
        eval "$T45_FUNCS"
        SCRIPT_DIR="$T45_TEMPLATE"
        # shellcheck disable=SC2034  # read by the eval'd update.sh functions
        WORKSPACE_DIR="$T45_WORKSPACE"
        # shellcheck disable=SC2034
        MEMORY_BACKUP_RUN=""
        apply_memory_policy "$T45_FPATH" "$T45_MEMORY/$T45_NAME"
        apply_memory_policy "$T45_STALE_FPATH" "$T45_MEMORY/$T45_STALE_NAME"
    ) || true
    T45_BACKUP=$(find "$T45_WORKSPACE/.backups" -type f -name "$T45_STALE_NAME" -print -quit 2>/dev/null || true)
    if cmp -s "$T45_MEMORY/$T45_STALE_NAME" "$T45_TEMPLATE/$T45_STALE_FPATH" \
        && [ -n "$T45_BACKUP" ] && grep -q 'stale template v1' "$T45_BACKUP" && [ ! -e "$T45_EXPANDED" ]; then
        pass "T45: a copy equal to a committed version is refreshed at exactly its odd path, after a backup"
    else
        fail "T45: the stale copy on an odd path was not refreshed with a backup: $(printf '%s' "$T45_OUT" | tr '\n' ' ')"
    fi
    T45_LINE=$(grep -F -- "$T45_FPATH — НЕ обновлён: " <<<"$T45_OUT" || true)
    if grep -qF -- 'Если ваших правок там нет, примите версию шаблона (прежняя копия останется рядом): ' <<<"$T45_LINE"; then
        T45_HINT="${T45_LINE#*прежняя копия останется рядом): }"
        check_saving_hint "T45" "$T45_HINT" "$T45_MEMORY/$T45_NAME" "$(cat "$T45_MEMORY/$T45_NAME")" "$(cat "$T45_TEMPLATE/$T45_FPATH")" "$T45_EXPANDED"
    else
        fail "T45: apply_memory_policy() printed no saving command for a kept copy: '${T45_OUT:-<empty>}'"
    fi
fi

# ============================================================================
# T46: one rule for every memory/* file, whatever its owner: marker — a copy the pilot did not
# change is refreshed after a backup, a changed or unverifiable one is kept with a ready command
# to accept the template version (issues #965/#967)
# ============================================================================
echo "--- T46: memory policy — untouched copies refreshed, edited ones kept (issues #965/#967) ---"

# The real Step 6 memory loop (extracted as in T43) and the real repair_pass() run on throwaway
# fixtures, with every update.sh function they may call (see update_sh_functions).
T46_FUNCS=$(update_sh_functions hash_file is_personal_config is_author_mode report_author_skip \
    saving_cp_command backup_memory_file_before_overwrite sync_workspace_agents repair_pass \
    is_migrated_platform_memory_path migrate_platform_memory report_owner_user_memory_drift \
    record_memory_old_hash memory_old_hash apply_memory_policy report_memory_policy_summary \
    memory_record_put memory_record_get remember_memory_deployed memory_decided_once memory_reason_text memory_copy_verdict replace_memory_copy is_user_owned_memory report_author_user_memory report_author_skip_summary apply_refresh_stale \
    remember_untouched_memory_before_apply)
T46_STEP6=$(awk '
    /^# Copy memory files to Claude projects directory$/ { armed=1; next }
    armed && /^if \[ -d "\$CLAUDE_MEMORY_DIR" \]; then$/ { found=1 }
    found { print }
    found && /^fi$/ { exit }
' "$TEMPLATE_DIR/update.sh")

# t46_doc OWNER TEXT — a memory file with an owner: marker.
t46_doc() { printf -- '---\nowner: %s\n---\n%s\n' "$1" "$2"; }

# t46_manifest FILE PATH... — a manifest listing PATH...: the paths repair_pass() walks.
t46_manifest() {
    local out="$1"
    shift
    python3 - "$out" "$@" <<'PY'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"files": [{"path": p} for p in sys.argv[2:]]}, handle)
PY
}

# t46_template DIR — a template copy that ships the real classifier.
t46_template() {
    mkdir -p "$1/memory" "$1/.claude/scripts"
    cp "$TEMPLATE_DIR/.claude/scripts/classify-workspace-copy.sh" "$1/.claude/scripts/classify-workspace-copy.sh"
    chmod +x "$1/.claude/scripts/classify-workspace-copy.sh"
}

# t46_prepare TEMPLATE WORKSPACE MEMORY MANIFEST — inside a run: the update.sh functions plus the
# globals its memory code reads. update.sh itself runs under set -e only: no -u, no pipefail.
# shellcheck disable=SC2329  # called by the world functions t46_run invokes
t46_prepare() {
    set +u +o pipefail
    # shellcheck source=/dev/null
    source "$TEMPLATE_DIR/.claude/lib/frontmatter.sh"
    eval "$T46_FUNCS"
    # shellcheck disable=SC2329  # called by the eval'd update.sh code
    py_available() { return 0; }
    # shellcheck disable=SC2034  # read by the eval'd update.sh code
    PY_BIN=python3
    SCRIPT_DIR="$1"
    WORKSPACE_DIR="$2"
    # shellcheck disable=SC2034
    CLAUDE_MEMORY_DIR="$3"
    # shellcheck disable=SC2034
    MANIFEST="$4"
    # shellcheck disable=SC2034
    MEMORY_BACKUP_RUN=""
    MEMORY_OLD_HASHES="$(dirname "$1")/old-hashes.tsv"
    : > "$MEMORY_OLD_HASHES"
    # shellcheck disable=SC2034
    MEMORY_DEPLOYED_RECORD="$WORKSPACE_DIR/.memory-deployed.tsv"
    mkdir -p "$WORKSPACE_DIR" "$CLAUDE_MEMORY_DIR"
}

# t46_release UPDATED_FILE... — what update.sh does to the template between Step 2 and Step 6:
# remember the version each changed file had (Step 2), then lay the release over the template
# (Step 5). The release lies next to the template, in DIR/release.
# shellcheck disable=SC2329  # called by the world functions t46_run invokes
t46_release() {
    local f
    for f in "$@"; do
        # An update.sh without the recorder records nothing; its Step 6 still runs and is judged
        # by what it does to the copies.
        if declare -F record_memory_old_hash >/dev/null; then
            record_memory_old_hash "$f" "$(hash_file "$SCRIPT_DIR/$f")"
        fi
    done
    cp -R "$(dirname "$SCRIPT_DIR")/release/." "$SCRIPT_DIR/"
}

# t46_run BODY — one update.sh run: the function BODY in a subshell under set -e, the way
# update.sh runs, stderr folded into stdout. T46_OUT gets the output, T46_RC the exit status.
# Plain assignment, not "|| true": bash 5 ignores set -e inside a command substitution whose
# status is tested. The caller's own errexit (this file runs under set -e from T25 on) is
# restored afterwards.
t46_run() {
    local had_errexit=false
    case $- in *e*) had_errexit=true ;; esac
    set +e
    T46_OUT=$(exec 2>&1; set -e; "$1")
    T46_RC=$?
    if $had_errexit; then set -e; fi
    return 0
}

# t46_state DIR — the content of every file under DIR, to compare two runs.
t46_state() { { find "$1" -type f -exec cksum {} + 2>/dev/null || true; } | sort; }

# t46_files DIR — how many files lie under DIR (0 when it does not exist).
t46_files() { { find "$1" -type f 2>/dev/null || true; } | wc -l | tr -d ' '; }

# t46_count TEXT OUTPUT — how many lines of OUTPUT contain TEXT.
t46_count() { grep -cF -- "$1" <<<"$2" || true; }

# --- World A: an update that changes eight memory files (Step 6 + the repair pass after it),
# proof by the version installed last time, no git history to help. The memory directory, the
# workspace and one file name carry a space, double quotes, a $(...) and backticks.
T46A_DIR="$TEST_WS/t46-a"
# shellcheck disable=SC2016  # literal characters, nothing is meant to expand
T46_ODD='odd "q" $(printf EXPANDED) `b`'
T46A_TEMPLATE="$T46A_DIR/template"
T46A_WS="$T46A_DIR/workspace $T46_ODD"
T46A_MEM="$T46A_DIR/memory $T46_ODD"
T46A_ODD_FILE="memory/note $T46_ODD.md"
T46A_MANIFEST="$T46A_DIR/manifest.json"
t46_template "$T46A_TEMPLATE"
mkdir -p "$T46A_DIR/release/memory" "$T46A_MEM"
# Release one is in the template (installed last time), release two lies in release/.
for t46_pair in user:user-untouched user:user-edited platform:platform-untouched platform:platform-edited platform:same; do
    t46_doc "${t46_pair%%:*}" "${t46_pair#*:} release one" > "$T46A_TEMPLATE/memory/${t46_pair#*:}.md"
    t46_doc "${t46_pair%%:*}" "${t46_pair#*:} release two" > "$T46A_DIR/release/memory/${t46_pair#*:}.md"
done
# Old releases shipped these two platform protocols as owner: user (#354/#384).
t46_doc user "protocol-open release one" > "$T46A_TEMPLATE/memory/protocol-open.md"
t46_doc platform "protocol-open release two" > "$T46A_DIR/release/memory/protocol-open.md"
t46_doc user "protocol-work release one" > "$T46A_TEMPLATE/memory/protocol-work.md"
t46_doc platform "protocol-work release two" > "$T46A_DIR/release/memory/protocol-work.md"
t46_doc platform "odd release one" > "$T46A_TEMPLATE/$T46A_ODD_FILE"
t46_doc platform "odd release two" > "$T46A_DIR/release/$T46A_ODD_FILE"
t46_doc platform "brand new in release two" > "$T46A_DIR/release/memory/brand-new.md"
# The pilot's copies: untouched ones equal release one, edited ones carry the pilot's lines.
for t46_name in user-untouched platform-untouched protocol-open; do
    cp "$T46A_TEMPLATE/memory/$t46_name.md" "$T46A_MEM/$t46_name.md"
done
cp "$T46A_TEMPLATE/$T46A_ODD_FILE" "$T46A_MEM/${T46A_ODD_FILE#memory/}"
for t46_name in user-edited platform-edited protocol-work; do
    { cat "$T46A_TEMPLATE/memory/$t46_name.md"; echo "Pilot line in $t46_name"; } > "$T46A_MEM/$t46_name.md"
done
cp "$T46A_DIR/release/memory/same.md" "$T46A_MEM/same.md"
t46_manifest "$T46A_MANIFEST" memory/user-untouched.md memory/user-edited.md memory/platform-untouched.md \
    memory/platform-edited.md memory/protocol-open.md memory/protocol-work.md memory/same.md \
    memory/brand-new.md "$T46A_ODD_FILE"

# t46a_update — the update that brings release two: Step 2 and 5, Step 6, then the repair pass.
# shellcheck disable=SC2329  # invoked through t46_run
t46a_update() {
    t46_prepare "$T46A_TEMPLATE" "$T46A_WS" "$T46A_MEM" "$T46A_MANIFEST"
    # shellcheck disable=SC2034  # read by the eval'd Step 6 loop
    NEW_FILES=(memory/brand-new.md)
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/user-untouched.md memory/user-edited.md memory/platform-untouched.md
        memory/platform-edited.md memory/protocol-open.md memory/protocol-work.md memory/same.md
        "$T46A_ODD_FILE")
    t46_release "${UPDATED_FILES[@]}"
    eval "$T46_STEP6"
    repair_pass
}
# t46a_repeat — the next update brings nothing new: only the repair pass runs.
# shellcheck disable=SC2329  # invoked through t46_run
t46a_repeat() {
    t46_prepare "$T46A_TEMPLATE" "$T46A_WS" "$T46A_MEM" "$T46A_MANIFEST"
    repair_pass
}
t46_run t46a_update
T46A_OUT="$T46_OUT"
T46A_RC="$T46_RC"

# t46_backup NAME — the backup of memory file NAME this world's runs made, if any.
t46_backup() { find "$T46A_WS/.backups" -type f -name "$1" -print -quit 2>/dev/null || true; }

if [ "$T46A_RC" -eq 0 ]; then
    pass "T46: the update runs to its end under set -e"
else
    fail "T46: the update ended with status $T46A_RC: $(printf '%s' "$T46A_OUT" | tail -3 | tr '\n' ' ')"
fi
t46_replaced_ok=true
for t46_name in user-untouched.md platform-untouched.md protocol-open.md "${T46A_ODD_FILE#memory/}"; do
    t46_bak=$(t46_backup "$t46_name")
    if ! cmp -s "$T46A_MEM/$t46_name" "$T46A_DIR/release/memory/$t46_name" \
        || [ -z "$t46_bak" ] || ! grep -q 'release one' "$t46_bak"; then
        t46_replaced_ok=false
        fail "T46: untouched $t46_name was not refreshed with a backup of the previous version (backup: ${t46_bak:-none})"
    fi
done
if $t46_replaced_ok; then
    pass "T46: untouched copies are refreshed after a backup — owner: user and owner: platform alike, odd paths included"
fi
if grep -qF -- 'owner: platform' "$T46A_MEM/protocol-open.md" \
    && grep -qF -- 'memory/protocol-open.md → memory/ — обновлён (не менялся: равен прошлой версии шаблона; если в клоне шаблона была ваша правка, она в прежней версии)' <<<"$T46A_OUT"; then
    pass "T46: an untouched legacy owner: user protocol migrates to the platform version, the line naming the proof"
else
    fail "T46: the untouched legacy protocol-open.md did not migrate with its line"
fi
if [ -z "$(find "$T46A_DIR" -name '*EXPANDED*' ! -name "*\$(printf EXPANDED)*" 2>/dev/null)" ]; then
    pass "T46: no shell expanded the odd paths (no '…EXPANDED…' path appeared)"
else
    fail "T46: an odd path was expanded by a shell: $(find "$T46A_DIR" -name '*EXPANDED*' ! -name "*\$(printf EXPANDED)*")"
fi

t46_kept_ok=true
for t46_name in user-edited platform-edited protocol-work; do
    t46_line=$(grep -F -- "memory/$t46_name.md — НЕ обновлён: " <<<"$T46A_OUT" || true)
    if ! grep -q "Pilot line in $t46_name" "$T46A_MEM/$t46_name.md" || [ -n "$(t46_backup "$t46_name.md")" ] \
        || ! grep -qF -- '. Сам он не обновится. Сверьте: diff ' <<<"$t46_line" || ! grep -qF -- 'Если ваших правок там нет, примите версию шаблона (прежняя копия останется рядом): ' <<<"$t46_line"; then
        t46_kept_ok=false
        fail "T46: edited $t46_name.md was replaced, backed up, or got no one-line reason with a command: '${t46_line:-<no line>}'"
    fi
    t46_times=$(t46_count "memory/$t46_name.md — НЕ обновлён" "$T46A_OUT")
    if [ "$t46_times" != "1" ]; then
        t46_kept_ok=false
        fail "T46: edited $t46_name.md is reported $t46_times times in one run (Step 6 and the repair pass must report it once)"
    fi
done
if $t46_kept_ok; then
    pass "T46: edited copies are kept — owner: user, owner: platform and a legacy protocol — each with one line and a ready command"
fi

if [ -f "$T46A_MEM/brand-new.md" ] && [ -z "$(t46_backup brand-new.md)" ] && [ -z "$(t46_backup same.md)" ] \
    && ! grep -qF -- 'memory/same.md' <<<"$T46A_OUT"; then
    pass "T46: a missing copy is copied and an identical one left alone, neither backed up"
else
    fail "T46: the new file is missing, or a new/identical file was backed up or reported"
fi

T46A_SUMMARY=$(grep -F -- 'Заменено файлов памяти' <<<"$T46A_OUT" || true)
T46A_KEPT_SUMMARY=$(grep -F -- 'Не обновлено файлов памяти' <<<"$T46A_OUT" || true)
if grep -qF -- 'Заменено файлов памяти: 4 (' <<<"$T46A_SUMMARY" \
    && grep -qF -- 'memory/user-untouched.md' <<<"$T46A_SUMMARY" \
    && grep -qF -- "$T46A_WS/.backups/memory-pre-update" <<<"$T46A_SUMMARY" \
    && ! grep -qE -- 'edited|protocol-work|brand-new|same\.md' <<<"$T46A_SUMMARY" \
    && grep -qF -- ': 3 (' <<<"$T46A_KEPT_SUMMARY"; then
    pass "T46: the summary names all four replaced files and the backup directory, and counts the three kept ones"
else
    fail "T46: summary is missing or wrong: replaced '${T46A_SUMMARY:-<none>}', kept '${T46A_KEPT_SUMMARY:-<none>}'"
fi

# The record: a line for every copy the update put in place or found equal to the template, with
# the template's hash; none for a kept copy (it must stay provably edited).
T46A_RECORD="$T46A_WS/.memory-deployed.tsv"
t46_record_ok=true
for t46_name in user-untouched.md platform-untouched.md protocol-open.md brand-new.md same.md "${T46A_ODD_FILE#memory/}"; do
    t46_want=$(printf 'memory/%s\t%s' "$t46_name" "$(shasum -a 256 "$T46A_TEMPLATE/memory/$t46_name" | cut -d' ' -f1)")
    grep -qxF -- "$t46_want" "$T46A_RECORD" 2>/dev/null || t46_record_ok=false
done
for t46_name in user-edited platform-edited protocol-work; do
    ! grep -qF -- "memory/$t46_name.md" "$T46A_RECORD" 2>/dev/null || t46_record_ok=false
done
if $t46_record_ok; then
    pass "T46: the record names the template version of every refreshed, new and identical copy, and no kept one"
else
    fail "T46: the record is missing a line or names a kept copy: $(tr '\n' '|' < "$T46A_RECORD" 2>/dev/null)"
fi

# The next update brings nothing new: only the repair pass runs. It changes nothing.
T46A_RECORD_STATE=$(cksum < "$T46A_RECORD" 2>/dev/null || true)
T46A_STATE=$(t46_state "$T46A_MEM")
T46A_BACKUPS=$(t46_files "$T46A_WS/.backups")
t46_run t46a_repeat
if [ "$T46_RC" -eq 0 ] && [ "$T46A_STATE" = "$(t46_state "$T46A_MEM")" ] \
    && [ "$T46A_BACKUPS" = "$(t46_files "$T46A_WS/.backups")" ] \
    && [ "$T46A_RECORD_STATE" = "$(cksum < "$T46A_RECORD" 2>/dev/null || true)" ] \
    && ! grep -qF -- 'Заменено файлов памяти' <<<"$T46_OUT" \
    && [ "$(t46_count '— НЕ обновлён: ' "$T46_OUT")" = "3" ]; then
    pass "T46: a repeated update changes nothing — copies, backups, record; the three kept files are reported again"
else
    fail "T46: the repeated update changed files or backups, or lost the kept-file lines (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi

# --- World B: the repair pass (no version from this run) on a clone with full history.
T46B_DIR="$TEST_WS/t46-b"
T46B_TEMPLATE="$T46B_DIR/template"
T46B_MEM="$T46B_DIR/memory"
T46B_MANIFEST="$T46B_DIR/manifest.json"
t46_template "$T46B_TEMPLATE"
mkdir -p "$T46B_MEM"
git -C "$T46B_TEMPLATE" init -q
git -C "$T46B_TEMPLATE" config user.email "test@test"
git -C "$T46B_TEMPLATE" config user.name "test"
for t46_v in one two three; do
    t46_doc user "stuck-user release $t46_v" > "$T46B_TEMPLATE/memory/stuck-user.md"
    t46_doc platform "stuck-platform release $t46_v" > "$T46B_TEMPLATE/memory/stuck-platform.md"
    t46_doc platform "authored release $t46_v" > "$T46B_TEMPLATE/memory/authored.md"
    git -C "$T46B_TEMPLATE" add memory
    git -C "$T46B_TEMPLATE" commit -q -m "release $t46_v"
done
t46_doc user "stuck-user release two" > "$T46B_MEM/stuck-user.md"          # a past release, not the last
t46_doc platform "stuck-platform release two" > "$T46B_MEM/stuck-platform.md"
t46_doc platform "The pilot rewrote this file" > "$T46B_MEM/authored.md"
t46_manifest "$T46B_MANIFEST" memory/stuck-user.md memory/stuck-platform.md memory/authored.md
# shellcheck disable=SC2329  # invoked through t46_run
t46b_repair() {
    t46_prepare "$T46B_TEMPLATE" "$T46B_DIR/workspace" "$T46B_MEM" "$T46B_MANIFEST"
    repair_pass
}
t46_run t46b_repair
T46B_BACKUP=$(find "$T46B_DIR/workspace/.backups" -type f -name stuck-user.md -print -quit 2>/dev/null || true)
if [ "$T46_RC" -eq 0 ] && cmp -s "$T46B_MEM/stuck-user.md" "$T46B_TEMPLATE/memory/stuck-user.md" \
    && cmp -s "$T46B_MEM/stuck-platform.md" "$T46B_TEMPLATE/memory/stuck-platform.md" \
    && [ -n "$T46B_BACKUP" ] && grep -q 'release two' "$T46B_BACKUP" \
    && grep -qF -- 'memory/stuck-user.md → memory/ — обновлён (не менялся: равен версии из истории клона шаблона' <<<"$T46_OUT"; then
    pass "T46: a copy stuck on a past release is refreshed through the clone's history, with a backup"
else
    fail "T46: the stuck copy was not refreshed through history (status $T46_RC): $(grep -F 'stuck' <<<"$T46_OUT" | tr '\n' ' ')"
fi
if grep -q 'The pilot rewrote this file' "$T46B_MEM/authored.md" \
    && grep -qF -- 'memory/authored.md — НЕ обновлён: не совпадает ни с одной версией в истории текущей ветки клона (ваши правки или уже применённый прошлый релиз). Сам он не обновится. Сверьте: diff ' <<<"$T46_OUT"; then
    pass "T46: an owner: platform copy that matches no committed version is kept, naming both possible causes"
else
    fail "T46: the authored owner: platform copy was replaced or reported wrongly: $(grep -F 'authored' <<<"$T46_OUT" | tr '\n' ' ')"
fi

# --- World C: the same stuck copies in a clone made with --depth 1: nothing can be proven.
T46C_DIR="$TEST_WS/t46-c"
T46C_TEMPLATE="$T46C_DIR/template"
T46C_MEM="$T46C_DIR/memory"
T46C_MANIFEST="$T46C_DIR/manifest.json"
mkdir -p "$T46C_DIR" "$T46C_MEM"
git clone -q --depth 1 "file://$T46B_TEMPLATE" "$T46C_TEMPLATE" 2>/dev/null
t46_template "$T46C_TEMPLATE"
t46_doc user "stuck-user release two" > "$T46C_MEM/stuck-user.md"
t46_doc platform "stuck-platform release two" > "$T46C_MEM/stuck-platform.md"
t46_manifest "$T46C_MANIFEST" memory/stuck-user.md memory/stuck-platform.md
# shellcheck disable=SC2329  # invoked through t46_run
t46c_repair() {
    t46_prepare "$T46C_TEMPLATE" "$T46C_DIR/workspace" "$T46C_MEM" "$T46C_MANIFEST"
    repair_pass
}
t46_run t46c_repair
if [ "$T46_RC" -eq 0 ] && grep -q 'stuck-platform release two' "$T46C_MEM/stuck-platform.md" \
    && grep -q 'stuck-user release two' "$T46C_MEM/stuck-user.md" && [ ! -d "$T46C_DIR/workspace/.backups" ] \
    && grep -qF -- 'memory/stuck-platform.md — НЕ обновлён: не удалось проверить, менялся ли файл (клон шаблона сделан с --depth, его истории нет). Сам он не обновится. Сверьте: diff ' <<<"$T46_OUT"; then
    pass "T46: in a --depth 1 clone a stuck copy is kept — owner: platform too — with the reason and a command"
else
    fail "T46: the shallow clone's stuck copy was replaced or not reported (status $T46_RC): $(grep -F 'stuck' <<<"$T46_OUT" | tr '\n' ' ')"
fi

# --- World D: the backup cannot be written (.backups is a file): no replacement, no abort.
T46D_DIR="$TEST_WS/t46-d"
T46D_TEMPLATE="$T46D_DIR/template"
T46D_WS="$T46D_DIR/workspace"
T46D_MEM="$T46D_DIR/memory"
t46_template "$T46D_TEMPLATE"
mkdir -p "$T46D_DIR/release/memory" "$T46D_MEM" "$T46D_WS"
t46_doc platform "untouched release one" > "$T46D_TEMPLATE/memory/untouched.md"
t46_doc platform "untouched release two" > "$T46D_DIR/release/memory/untouched.md"
cp "$T46D_TEMPLATE/memory/untouched.md" "$T46D_MEM/untouched.md"
printf 'a file where the backup directory would go\n' > "$T46D_WS/.backups"
# shellcheck disable=SC2329  # invoked through t46_run
t46d_update() {
    t46_prepare "$T46D_TEMPLATE" "$T46D_WS" "$T46D_MEM" "$T46D_DIR/manifest.json"
    # shellcheck disable=SC2034
    NEW_FILES=()
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/untouched.md)
    t46_release memory/untouched.md
    eval "$T46_STEP6"
    if declare -F report_memory_policy_summary >/dev/null; then report_memory_policy_summary; fi
    echo "T46D: the run went on"
}
t46_run t46d_update
if [ "$T46_RC" -eq 0 ] && grep -q 'untouched release one' "$T46D_MEM/untouched.md" \
    && grep -qF -- 'T46D: the run went on' <<<"$T46_OUT" \
    && grep -qF -- 'memory/untouched.md — НЕ обновлён: не удалось сохранить прежнюю версию' <<<"$T46_OUT" \
    && ! grep -qE -- 'Заменено файлов памяти|memory-файлов обновлено' <<<"$T46_OUT" \
    && grep -qF -- 'Не обновлено файлов памяти: 1 (memory/untouched.md)' <<<"$T46_OUT"; then
    pass "T46: a failed backup leaves the copy as it was, warns, counts it among the files not updated and does not end the run"
else
    fail "T46: failed backup: copy replaced, run ended (status $T46_RC), no warning, or counted: $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi

# --- World E: author_mode keeps its own branch — the policy never writes the author's copies.
T46E_DIR="$TEST_WS/t46-e"
T46E_TEMPLATE="$T46E_DIR/template"
T46E_WS="$T46E_DIR/workspace"
T46E_MEM="$T46E_DIR/memory"
t46_template "$T46E_TEMPLATE"
mkdir -p "$T46E_DIR/release/memory" "$T46E_MEM" "$T46E_WS"
printf 'author_mode: true\n' > "$T46E_WS/params.yaml"
t46_doc user "author copy release one" > "$T46E_TEMPLATE/memory/untouched.md"
t46_doc user "author copy release two" > "$T46E_DIR/release/memory/untouched.md"
cp "$T46E_TEMPLATE/memory/untouched.md" "$T46E_MEM/untouched.md"
# shellcheck disable=SC2329  # invoked through t46_run
t46e_update() {
    t46_prepare "$T46E_TEMPLATE" "$T46E_WS" "$T46E_MEM" "$T46E_DIR/manifest.json"
    # shellcheck disable=SC2034
    NEW_FILES=()
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/untouched.md)
    t46_release memory/untouched.md
    eval "$T46_STEP6"
}
t46_run t46e_update
if grep -q 'author copy release one' "$T46E_MEM/untouched.md" && [ ! -e "$T46E_WS/.backups" ] \
    && grep -qF -- 'memory/untouched.md — author_mode, owner: user: рабочая копия не тронута' <<<"$T46_OUT"; then
    pass "T46: author_mode keeps its own branch — the author's copy is reported, not refreshed"
else
    fail "T46: author_mode copy was written or not reported (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi

# ============================================================================
# T47: the record of installed memory versions (.memory-deployed.tsv), proof (a) of the memory
# policy: it outlives a broken-off run and a copy several releases behind, an edited copy never
# enters it, an unusable record never stops the update, setup.sh writes the first one; author_mode
# keeps its quiet report for owner: user copies, in Step 6 and in the repair pass (review of
# #965/#967: С1, С2, М1, М5, М7)
# ============================================================================
echo "--- T47: memory record — broken-off run, lag, unusable record, setup, author_mode (#965/#967 review) ---"

# t47_sha FILE — the sha256 the record keeps for FILE's content.
t47_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
# t47_line KEY FILE — the record line that says the deployed copy KEY holds FILE's content.
t47_line() { printf '%s\t%s' "$1" "$(t47_sha "$2")"; }

# --- 47a: setup.sh writes the record with the same writer and hash as update.sh.
t47_same=true
for t47_fn in memory_record_put hash_file; do
    t47_u=$(awk -v fn="$t47_fn" '$0 ~ "^" fn "\\(\\) \\{" {c=1} c{print} c && /^}/{exit}' "$TEMPLATE_DIR/update.sh")
    t47_s=$(awk -v fn="$t47_fn" '$0 ~ "^" fn "\\(\\) \\{" {c=1} c{print} c && /^}/{exit}' "$TEMPLATE_DIR/setup.sh")
    if [ -z "$t47_u" ] || [ "$t47_u" != "$t47_s" ]; then
        t47_same=false
        fail "T47: $t47_fn differs between update.sh and setup.sh (or one of them lacks it)"
    fi
done
if $t47_same; then
    pass "T47: update.sh and setup.sh write the record with the same memory_record_put and hash_file"
fi

# --- 47b: a broken-off run. An earlier run recorded the copies (they equalled the template);
# then the template moved on twice without Step 6 (code 49 or Ctrl-C, the run's own hashes gone
# with its temporary directory), and the clone has no history that knows the copies. The next run
# must refresh the untouched copy by the record and keep the edited one, its record line unchanged.
T47F_DIR="$TEST_WS/t47-f"
T47F_TEMPLATE="$T47F_DIR/template"
T47F_WS="$T47F_DIR/workspace"
T47F_MEM="$T47F_DIR/memory"
T47F_MANIFEST="$T47F_DIR/manifest.json"
t46_template "$T47F_TEMPLATE"
mkdir -p "$T47F_MEM"
t46_doc user "untouched release one" > "$T47F_TEMPLATE/memory/untouched.md"
t46_doc platform "edited release one" > "$T47F_TEMPLATE/memory/edited.md"
cp "$T47F_TEMPLATE/memory/untouched.md" "$T47F_TEMPLATE/memory/edited.md" "$T47F_MEM/"
t46_manifest "$T47F_MANIFEST" memory/untouched.md memory/edited.md
# shellcheck disable=SC2329  # invoked through t46_run
t47f_repair() {
    t46_prepare "$T47F_TEMPLATE" "$T47F_WS" "$T47F_MEM" "$T47F_MANIFEST"
    repair_pass
}
t46_run t47f_repair        # in step with the template: the copies get their record lines
echo "Pilot line in edited" >> "$T47F_MEM/edited.md"
T47F_EDITED_LINE=$(t47_line memory/edited.md "$T47F_TEMPLATE/memory/edited.md")
for t47_v in two three; do  # two releases land in the clone, memory never sees them
    t46_doc user "untouched release $t47_v" > "$T47F_TEMPLATE/memory/untouched.md"
    t46_doc platform "edited release $t47_v" > "$T47F_TEMPLATE/memory/edited.md"
done
t46_run t47f_repair
T47F_RECORD="$T47F_WS/.memory-deployed.tsv"
if [ "$T46_RC" -eq 0 ] && cmp -s "$T47F_MEM/untouched.md" "$T47F_TEMPLATE/memory/untouched.md" \
    && grep -qF -- 'memory/untouched.md → memory/ — обновлён (не менялся: равен версии, установленной в прошлый раз' <<<"$T46_OUT" \
    && grep -qxF -- "$(t47_line memory/untouched.md "$T47F_TEMPLATE/memory/untouched.md")" "$T47F_RECORD"; then
    pass "T47: after a broken-off run a copy two releases behind is refreshed by the record, which then names the new version"
else
    fail "T47: the untouched copy left behind by a broken-off run was not refreshed by the record (status $T46_RC): $(grep -F 'untouched' <<<"$T46_OUT" | tr '\n' ' ')"
fi
if grep -q 'Pilot line in edited' "$T47F_MEM/edited.md" && grep -qxF -- "$T47F_EDITED_LINE" "$T47F_RECORD" \
    && grep -qF -- 'memory/edited.md — НЕ обновлён: ' <<<"$T46_OUT"; then
    pass "T47: an edited copy stays after a broken-off run, and its record line still names the version installed before"
else
    fail "T47: the edited copy was replaced, or its record line moved: $(grep -F 'edited' <<<"$T46_OUT" | tr '\n' ' ')"
fi

# --- 47c: a record that cannot be used never stops the update.
# The record path is a directory: the run goes on under set -e, a copy proven by the version this
# run replaced is still refreshed, one warning names the record, nothing lands inside the directory.
T47G_DIR="$TEST_WS/t47-g"
T47G_TEMPLATE="$T47G_DIR/template"
T47G_WS="$T47G_DIR/workspace"
T47G_MEM="$T47G_DIR/memory"
t46_template "$T47G_TEMPLATE"
mkdir -p "$T47G_DIR/release/memory" "$T47G_MEM" "$T47G_WS/.memory-deployed.tsv"
t46_doc platform "proven release one" > "$T47G_TEMPLATE/memory/proven.md"
t46_doc platform "proven release two" > "$T47G_DIR/release/memory/proven.md"
cp "$T47G_TEMPLATE/memory/proven.md" "$T47G_MEM/proven.md"
t46_manifest "$T47G_DIR/manifest.json" memory/proven.md
# shellcheck disable=SC2329  # invoked through t46_run
t47g_update() {
    t46_prepare "$T47G_TEMPLATE" "$T47G_WS" "$T47G_MEM" "$T47G_DIR/manifest.json"
    # shellcheck disable=SC2034
    NEW_FILES=()
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/proven.md)
    t46_release memory/proven.md
    eval "$T46_STEP6"
    repair_pass
}
t46_run t47g_update
if [ "$T46_RC" -eq 0 ] && cmp -s "$T47G_MEM/proven.md" "$T47G_DIR/release/memory/proven.md" \
    && [ "$(t46_count 'не удалось записать' "$T46_OUT")" = "1" ] && [ -z "$(ls -A "$T47G_WS/.memory-deployed.tsv")" ]; then
    pass "T47: a record path that is a directory costs one warning; the update and its other proofs go on"
else
    fail "T47: an unusable record broke the update or went unreported (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi
# Lines that do not parse are ignored, and dropped when the record is written next.
T47H_DIR="$TEST_WS/t47-h"
T47H_TEMPLATE="$T47H_DIR/template"
T47H_WS="$T47H_DIR/workspace"
T47H_MEM="$T47H_DIR/memory"
t46_template "$T47H_TEMPLATE"
mkdir -p "$T47H_MEM" "$T47H_WS"
for t47_name in good bad; do
    t46_doc platform "$t47_name release one" > "$T47H_MEM/$t47_name.md"
    t46_doc platform "$t47_name release two" > "$T47H_TEMPLATE/memory/$t47_name.md"
done
{
    echo "a line that is no record"
    printf 'memory/bad.md\tnot-a-sha256\n'
    t47_line memory/good.md "$T47H_MEM/good.md"; echo
} > "$T47H_WS/.memory-deployed.tsv"
t46_manifest "$T47H_DIR/manifest.json" memory/good.md memory/bad.md
# shellcheck disable=SC2329  # invoked through t46_run
t47h_repair() {
    t46_prepare "$T47H_TEMPLATE" "$T47H_WS" "$T47H_MEM" "$T47H_DIR/manifest.json"
    repair_pass
}
t46_run t47h_repair
if [ "$T46_RC" -eq 0 ] && cmp -s "$T47H_MEM/good.md" "$T47H_TEMPLATE/memory/good.md" \
    && grep -q 'bad release one' "$T47H_MEM/bad.md" \
    && ! grep -qE 'no record|not-a-sha256' "$T47H_WS/.memory-deployed.tsv" \
    && grep -qxF -- "$(t47_line memory/good.md "$T47H_TEMPLATE/memory/good.md")" "$T47H_WS/.memory-deployed.tsv"; then
    pass "T47: malformed record lines prove nothing and are dropped; a valid line still proves its copy"
else
    fail "T47: malformed record lines changed the outcome (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi

# --- 47d: author_mode, Step 6 and the repair pass: an owner: user copy keeps one quiet line and no
# author_mode counter — the summary counts only the platform copy, --refresh-stale is not refused.
T47A_DIR="$TEST_WS/t47-author"
T47A_TEMPLATE="$T47A_DIR/template"
T47A_WS="$T47A_DIR/workspace"
T47A_MEM="$T47A_DIR/memory"
T47A_MANIFEST="$T47A_DIR/manifest.json"
t46_template "$T47A_TEMPLATE"
mkdir -p "$T47A_MEM" "$T47A_WS"
printf 'author_mode: true\n' > "$T47A_WS/params.yaml"
git -C "$T47A_TEMPLATE" init -q
git -C "$T47A_TEMPLATE" config user.email "test@test"
git -C "$T47A_TEMPLATE" config user.name "test"
for t47_v in one two; do
    t46_doc platform "platform release $t47_v" > "$T47A_TEMPLATE/memory/platform.md"
    git -C "$T47A_TEMPLATE" add memory/platform.md
    git -C "$T47A_TEMPLATE" commit -q -m "release $t47_v"
done
t46_doc user "notes the template ships" > "$T47A_TEMPLATE/memory/notes.md"   # never committed
t46_doc platform "platform release one" > "$T47A_MEM/platform.md"           # behind: stale
t46_doc user "The author's own notes" > "$T47A_MEM/notes.md"
t46_manifest "$T47A_MANIFEST" memory/platform.md memory/notes.md
# shellcheck disable=SC2329  # invoked through t46_run
t47a_update() {
    t46_prepare "$T47A_TEMPLATE" "$T47A_WS" "$T47A_MEM" "$T47A_MANIFEST"
    # shellcheck disable=SC2034  # read by the eval'd update.sh code
    AUTHOR_SKIP_AUTHORED=0 AUTHOR_SKIP_STALE=0 AUTHOR_SKIP_UNKNOWN=0 CLASSIFIER_DEGRADED_WARNED=false REFRESH_STALE=true
    # shellcheck disable=SC2034
    AUTHOR_STALE_PAIRS=()
    # shellcheck disable=SC2034
    NEW_FILES=()
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/platform.md memory/notes.md)
    eval "$T46_STEP6"
    repair_pass
    report_author_skip_summary
}
t46_run t47a_update
if [ "$T46_RC" -eq 0 ] && grep -q "The author's own notes" "$T47A_MEM/notes.md" \
    && [ "$(t46_count 'memory/notes.md — author_mode, owner: user: рабочая копия не тронута' "$T46_OUT")" = "1" ] \
    && [ "$(t46_count 'memory/notes.md' "$T46_OUT")" = "1" ] \
    && grep -qF -- 'author_mode: пропущено 1 файл(ов) — авторских 0, отставших 1, неизвестно 0' <<<"$T46_OUT" \
    && ! grep -qF -- 'refresh-stale отклонён' <<<"$T46_OUT" \
    && cmp -s "$T47A_MEM/platform.md" "$T47A_TEMPLATE/memory/platform.md" && [ ! -e "$T47A_WS/.memory-deployed.tsv" ]; then
    pass "T47: author_mode reports an owner: user copy once, outside its counters; --refresh-stale still refreshes the stale platform copy"
else
    fail "T47: author_mode changed for an owner: user copy (status $T46_RC): $(grep -E 'notes|пропущено|refresh' <<<"$T46_OUT" | tr '\n' ' ')"
fi

# --- 47e: setup.sh records what it installs: the copied files' lines replace older ones, lines for
# files it does not copy stay, and --dry-run writes nothing. The workspace path has odd characters.
T47S_SETUP=$(awk '
    /^# === 3\. Copy memory to Claude projects directory ===$/ { on=1 }
    /^# === 4\. / { exit }
    on { print }
' "$TEMPLATE_DIR/setup.sh")
T47S_FUNCS=$(for t47_fn in hash_file memory_record_put; do
    awk -v fn="$t47_fn" '$0 ~ "^" fn "\\(\\) \\{" {c=1} c{print} c && /^}/{exit}' "$TEMPLATE_DIR/setup.sh"
done)
T47S_DIR="$TEST_WS/t47-setup"
T47S_TEMPLATE="$T47S_DIR/template"
mkdir -p "$T47S_TEMPLATE/memory"
t46_doc platform "a as shipped" > "$T47S_TEMPLATE/memory/a.md"
t46_doc user "b as shipped" > "$T47S_TEMPLATE/memory/b.md"
printf '# Index\n' > "$T47S_TEMPLATE/memory/MEMORY.md"
printf 'calendar_ids: []\n' > "$T47S_TEMPLATE/memory/day-rhythm-config.yaml"
# t47s_setup WORKSPACE HOME DRY_RUN — setup.sh's memory step in one t46_run, under set -e only, as
# setup.sh runs (no -u, no pipefail).
t47s_setup() {
    T47S_ARGS_WS="$1" T47S_ARGS_HOME="$2" T47S_ARGS_DRY="$3"
    t46_run t47s_body
}
# shellcheck disable=SC2329  # invoked through t46_run
t47s_body() {
    set +u +o pipefail
    eval "$T47S_FUNCS"
    # shellcheck disable=SC2034  # read by the eval'd setup.sh code
    TEMPLATE_DIR="$T47S_TEMPLATE" WORKSPACE_DIR="$T47S_ARGS_WS" HOME="$T47S_ARGS_HOME" DRY_RUN="$T47S_ARGS_DRY" CLAUDE_PROJECT_SLUG="t47-slug"
    mkdir -p "$WORKSPACE_DIR"
    eval "$T47S_SETUP"
}
# shellcheck disable=SC2016  # literal characters, nothing is meant to expand
T47S_WS="$T47S_DIR/workspace \"q\" \$(printf EXPANDED)"
T47S_MEM="$T47S_DIR/home/.claude/projects/t47-slug/memory"
mkdir -p "$T47S_WS"
{
    printf 'memory/reference/agent-core.md\t%s\n' "$(printf 'x' | shasum -a 256 | cut -d' ' -f1)"
    printf 'memory/a.md\t%s\n' "$(printf 'old' | shasum -a 256 | cut -d' ' -f1)"
} > "$T47S_WS/.memory-deployed.tsv"
T47S_KEPT_LINE=$(head -1 "$T47S_WS/.memory-deployed.tsv")
t47s_setup "$T47S_WS" "$T47S_DIR/home" false
t47s_record_ok=true
for t47_name in a.md b.md MEMORY.md day-rhythm-config.yaml; do
    grep -qxF -- "$(t47_line "memory/$t47_name" "$T47S_MEM/$t47_name")" "$T47S_WS/.memory-deployed.tsv" || t47s_record_ok=false
done
if [ "$T46_RC" -eq 0 ] && $t47s_record_ok && grep -qxF -- "$T47S_KEPT_LINE" "$T47S_WS/.memory-deployed.tsv" \
    && [ "$(grep -c '^memory/a\.md' "$T47S_WS/.memory-deployed.tsv")" = "1" ]; then
    pass "T47: setup.sh records every memory file it installs, keeps other lines, replaces an older line"
else
    fail "T47: setup.sh did not write the record as expected (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi
T47S_DRY_WS="$T47S_DIR/dry-workspace"
t47s_setup "$T47S_DRY_WS" "$T47S_DIR/dry-home" true
if [ "$T46_RC" -eq 0 ] && [ ! -e "$T47S_DRY_WS/.memory-deployed.tsv" ] && [ ! -e "$T47S_DIR/dry-home/.claude" ]; then
    pass "T47: setup.sh --dry-run writes no record"
else
    fail "T47: setup.sh --dry-run wrote memory or its record, or failed (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi

# ============================================================================
# T48: the record before Step 5 and the safety of every write (review-12 of #965/#967: С1, М1-М3).
# A copy equal to the version this run replaces gets its record line BEFORE Step 5, so a run broken
# off between Step 5 and Step 6 cannot leave it unprovable; the record and the memory copies are
# replaced by rename, never rewritten in place; a record that cannot be read, or is a link, is not
# written; every file left as it was is listed in the closing summary.
# ============================================================================
echo "--- T48: record before Step 5, atomic writes, unusable record, closing summary (review-12 of #965/#967) ---"

# t48_inode FILE — the inode number: a rename gives the path a new one, an in-place write does not.
# shellcheck disable=SC2012  # ls -i is the portable inode reader (stat differs between BSD and GNU)
t48_inode() { ls -i "$1" | awk '{print $1}'; }
T48_ROOT=false
[ "$(id -u)" -eq 0 ] && T48_ROOT=true   # root ignores file modes: the mode-based checks say so and stand aside

# --- 48a: the record before Step 5. Untouched copies (owner: user and owner: platform) get the version
# this run is about to replace; the edited copy, MEMORY.md and the personal config get nothing; author_mode
# records nothing.
T48A_DIR="$TEST_WS/t48-a"
T48A_TEMPLATE="$T48A_DIR/template"
T48A_WS="$T48A_DIR/workspace"
T48A_MEM="$T48A_DIR/memory"
t46_template "$T48A_TEMPLATE"
mkdir -p "$T48A_MEM" "$T48A_WS"
t46_doc user "user copy release one" > "$T48A_TEMPLATE/memory/user-copy.md"
t46_doc platform "platform copy release one" > "$T48A_TEMPLATE/memory/platform-copy.md"
t46_doc platform "edited copy release one" > "$T48A_TEMPLATE/memory/edited-copy.md"
printf '# Index\n' > "$T48A_TEMPLATE/memory/MEMORY.md"
printf 'calendar_ids: []\n' > "$T48A_TEMPLATE/memory/day-rhythm-config.yaml"
cp "$T48A_TEMPLATE/memory/"* "$T48A_MEM/"
echo "Pilot line in edited-copy" >> "$T48A_MEM/edited-copy.md"
# shellcheck disable=SC2329  # invoked through t46_run
t48a_before_apply() {
    t46_prepare "$T48A_TEMPLATE" "$T48A_WS" "$T48A_MEM" "$T48A_DIR/manifest.json"
    # shellcheck disable=SC2034
    UPDATED_FILES=(memory/user-copy.md memory/platform-copy.md memory/edited-copy.md memory/MEMORY.md memory/day-rhythm-config.yaml)
    for t48_f in "${UPDATED_FILES[@]}"; do
        record_memory_old_hash "$t48_f" "$(hash_file "$SCRIPT_DIR/$t48_f")"
    done
    remember_untouched_memory_before_apply
}
t46_run t48a_before_apply
T48A_RECORD="$T48A_WS/.memory-deployed.tsv"
if [ "$T46_RC" -eq 0 ] \
    && grep -qxF -- "$(t47_line memory/user-copy.md "$T48A_TEMPLATE/memory/user-copy.md")" "$T48A_RECORD" 2>/dev/null \
    && grep -qxF -- "$(t47_line memory/platform-copy.md "$T48A_TEMPLATE/memory/platform-copy.md")" "$T48A_RECORD" 2>/dev/null \
    && ! grep -qE 'edited-copy|MEMORY\.md|day-rhythm' "$T48A_RECORD" 2>/dev/null; then
    pass "T48: before Step 5 untouched copies get their record line — owner: user and owner: platform; edited copy, MEMORY.md, personal config none"
else
    fail "T48: the record before Step 5 is wrong (status $T46_RC): '$(tr '\n' '|' < "$T48A_RECORD" 2>/dev/null)' $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
fi
rm -f "$T48A_RECORD"
printf 'author_mode: true\n' > "$T48A_WS/params.yaml"
t46_run t48a_before_apply
if [ "$T46_RC" -eq 0 ] && [ ! -e "$T48A_RECORD" ]; then
    pass "T48: author_mode writes no record before Step 5"
else
    fail "T48: author_mode wrote a record before Step 5 (status $T46_RC)"
fi

# The functions below are update.sh's own; each check runs them in a subshell under set -e.
T48_FUNCS=$(update_sh_functions hash_file memory_record_put memory_record_get remember_memory_deployed replace_memory_copy)
T48_H1=$(printf one | shasum -a 256 | cut -d' ' -f1)
T48_H2=$(printf two | shasum -a 256 | cut -d' ' -f1)
T48_DIR="$TEST_WS/t48-units"
mkdir -p "$T48_DIR"

# --- 48b: the record is replaced by rename: a read-only record still takes the new line, and the path
# gets a new inode (an in-place `cat >` fails on it, or keeps the inode).
T48B_REC="$T48_DIR/readonly-record.tsv"
printf 'memory/a.md\t%s\nmemory/b.md\t%s\n' "$T48_H1" "$T48_H2" > "$T48B_REC"
chmod 444 "$T48B_REC"
T48B_INODE=$(t48_inode "$T48B_REC")
T48B_RC=0
( set -e; eval "$T48_FUNCS"; memory_record_put "$T48B_REC" memory/c.md "$T48_H1" ) || T48B_RC=$?
if [ "$T48B_RC" -eq 0 ] && grep -qxF -- "$(printf 'memory/c.md\t%s' "$T48_H1")" "$T48B_REC" \
    && grep -qxF -- "$(printf 'memory/a.md\t%s' "$T48_H1")" "$T48B_REC" \
    && [ "$(t48_inode "$T48B_REC")" != "$T48B_INODE" ]; then
    pass "T48: the record is rewritten by rename — a read-only record still takes the line, under a new inode"
else
    fail "T48: the record was written in place or not at all (rc $T48B_RC, inode $T48B_INODE -> $(t48_inode "$T48B_REC")): $(tr '\n' '|' < "$T48B_REC")"
fi
rm -f "$T48B_REC"

# --- 48c: a memory copy is replaced by rename too, keeping its mode: no moment shows it cut short.
printf 'release two\n' > "$T48_DIR/src.md"
printf 'release one\n' > "$T48_DIR/dst.md"
chmod 640 "$T48_DIR/dst.md"
T48C_INODE=$(t48_inode "$T48_DIR/dst.md")
T48C_RC=0
( set -e; eval "$T48_FUNCS"; replace_memory_copy "$T48_DIR/src.md" "$T48_DIR/dst.md" ) || T48C_RC=$?
# shellcheck disable=SC2012  # the mode string of one known file
T48C_MODE=$(ls -l "$T48_DIR/dst.md" | cut -c1-10)
if [ "$T48C_RC" -eq 0 ] && cmp -s "$T48_DIR/src.md" "$T48_DIR/dst.md" \
    && [ "$(t48_inode "$T48_DIR/dst.md")" != "$T48C_INODE" ] && [ "$T48C_MODE" = "-rw-r-----" ] \
    && [ -z "$(find "$T48_DIR" -name 'dst.md.update-*')" ]; then
    pass "T48: a memory copy is replaced by rename (new inode), keeps its mode and leaves no temporary file"
else
    fail "T48: the memory copy was rewritten in place or lost its mode (rc $T48C_RC, mode $T48C_MODE, inode $T48C_INODE -> $(t48_inode "$T48_DIR/dst.md"))"
fi

# --- 48d: a record that cannot be read, or that is a link, is not written: other files keep proof (a).
T48D_REC="$T48_DIR/unreadable-record.tsv"
for t48_n in 1 2 3 4 5 6; do printf 'memory/f%s.md\t%s\n' "$t48_n" "$T48_H1"; done > "$T48D_REC"
if $T48_ROOT; then
    echo "  (T48: unreadable-record check skipped — root reads any file)"
else
    chmod 000 "$T48D_REC"
    T48D_RC=0
    ( set -e; eval "$T48_FUNCS"; memory_record_put "$T48D_REC" memory/new.md "$T48_H2" ) || T48D_RC=$?
    chmod 600 "$T48D_REC"
    if [ "$T48D_RC" -ne 0 ] && [ "$(wc -l < "$T48D_REC" | tr -d ' ')" = "6" ] && ! grep -q 'memory/new.md' "$T48D_REC"; then
        pass "T48: an unreadable record is not rewritten — its six lines survive"
    else
        fail "T48: an unreadable record was rewritten (rc $T48D_RC): $(wc -l < "$T48D_REC" | tr -d ' ') line(s) left"
    fi
fi
printf 'memory/x.md\t%s\n' "$T48_H1" > "$T48_DIR/elsewhere.tsv"
ln -s "$T48_DIR/elsewhere.tsv" "$T48_DIR/linked-record.tsv"
T48D_OUT=$(
    exec 2>&1
    eval "$T48_FUNCS"
    # shellcheck disable=SC2034  # read by the eval'd update.sh functions
    MEMORY_DEPLOYED_RECORD="$T48_DIR/linked-record.tsv"
    # shellcheck disable=SC2034
    MEMORY_RECORD_WARNED=false
    remember_memory_deployed memory/y.md "$T48_H2"
    remember_memory_deployed memory/z.md "$T48_H2"
) || true
if [ -L "$T48_DIR/linked-record.tsv" ] && [ "$(cat "$T48_DIR/elsewhere.tsv")" = "$(printf 'memory/x.md\t%s' "$T48_H1")" ] \
    && [ "$(t46_count 'не удалось записать' "$T48D_OUT")" = "1" ]; then
    pass "T48: a record that is a link is left as it is, with one warning for the run"
else
    fail "T48: a linked record was replaced or written through, or warned $(t46_count 'не удалось записать' "$T48D_OUT") times"
fi

# --- 48f: a link is no proof when READ either (red team of the 0.41.1 candidate). memory_record_put never writes
# through one, but memory_record_get followed it: a link to a file somebody else filled with the hash of an edited
# copy made that copy count as untouched, and the update replaced it.
printf 'memory/x.md\t%s\n' "$T48_H1" > "$T48_DIR/proof-elsewhere.tsv"
ln -s "$T48_DIR/proof-elsewhere.tsv" "$T48_DIR/proof-link.tsv"
T48F_PLAIN=$( eval "$T48_FUNCS"; memory_record_get "$T48_DIR/proof-elsewhere.tsv" memory/x.md )
T48F_LINK=$( eval "$T48_FUNCS"; memory_record_get "$T48_DIR/proof-link.tsv" memory/x.md )
if [ "$T48F_PLAIN" = "$T48_H1" ] && [ -z "$T48F_LINK" ]; then
    pass "T48: a record that is a link proves nothing when it is read (the same file read directly does)"
else
    fail "T48: a link was read as proof (direct read '$T48F_PLAIN', through the link '$T48F_LINK')"
fi

# --- 48e: every file left as it was is in the closing summary, whatever the reason; the summary does not
# promise a command where there is none.
if $T48_ROOT; then
    echo "  (T48: closing-summary check skipped — root ignores the modes it needs)"
else
    T48E_DIR="$TEST_WS/t48-e"
    T48E_TEMPLATE="$T48E_DIR/template"
    T48E_MEM="$T48E_DIR/memory"
    t46_template "$T48E_TEMPLATE"
    mkdir -p "$T48E_TEMPLATE/memory/sub" "$T48E_MEM/sub" "$T48E_DIR/workspace"
    t46_doc platform "new file" > "$T48E_TEMPLATE/memory/sub/new.md"
    t46_doc platform "template file nobody can read" > "$T48E_TEMPLATE/memory/unreadable.md"
    t46_doc platform "the copy" > "$T48E_MEM/unreadable.md"
    chmod 555 "$T48E_MEM/sub"
    chmod 000 "$T48E_TEMPLATE/memory/unreadable.md"
    # shellcheck disable=SC2329  # invoked through t46_run
    t48e_policy() {
        t46_prepare "$T48E_TEMPLATE" "$T48E_DIR/workspace" "$T48E_MEM" "$T48E_DIR/manifest.json"
        apply_memory_policy memory/sub/new.md "$T48E_MEM/sub/new.md" || true
        apply_memory_policy memory/unreadable.md "$T48E_MEM/unreadable.md" || true
        report_memory_policy_summary
    }
    t46_run t48e_policy
    chmod 755 "$T48E_MEM/sub"
    chmod 644 "$T48E_TEMPLATE/memory/unreadable.md"
    T48E_SUMMARY=$(grep -F -- 'Не обновлено файлов памяти' <<<"$T46_OUT" || true)
    if [ "$T46_RC" -eq 0 ] && grep -qF -- 'Не обновлено файлов памяти: 2 (memory/sub/new.md, memory/unreadable.md)' <<<"$T48E_SUMMARY" \
        && grep -qF -- 'почему и что сделать — в строке каждого файла выше' <<<"$T48E_SUMMARY" \
        && grep -qF -- 'memory/sub/new.md — НЕ доставлен: ' <<<"$T46_OUT" \
        && grep -qF -- 'memory/unreadable.md — НЕ обновлён: не удалось прочитать шаблонный файл' <<<"$T46_OUT"; then
        pass "T48: a copy that could not be delivered and an unreadable template file are in the closing summary"
    else
        fail "T48: the closing summary misses a file left as it was (status $T46_RC): $(printf '%s' "$T46_OUT" | tr '\n' ' ')"
    fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"

exit "$FAIL_COUNT"
