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

echo "--- Scenario D: post-backfill failure then zero-diff recovery on configured governance ---"
# Build a real installed topology. The first run reaches post-apply backfills
# but refuses a snapshot symlink; after restoring the tracked regular file, the
# next TOTAL_CHANGES=0 run must deliver every target and close the transaction.
mkdir -p \
    "$SCRIPT_DIR/seed/strategy/scripts" \
    "$SCRIPT_DIR/seed/strategy/.githooks" \
    "$SCRIPT_DIR/scripts/agent-fault" \
    "$SCRIPT_DIR/scripts" \
    "$WORKSPACE_DIR/.claude/skills/smoke-catalog" \
    "$WORKSPACE_DIR/custom-governance/scripts"
cp "$ROOT/seed/strategy/scripts/install-hooks.sh" \
    "$SCRIPT_DIR/seed/strategy/scripts/install-hooks.sh"
cp "$ROOT/seed/strategy/.githooks/pre-commit" \
    "$SCRIPT_DIR/seed/strategy/.githooks/pre-commit"
cp "$ROOT/seed/strategy/.githooks/pre-push" \
    "$SCRIPT_DIR/seed/strategy/.githooks/pre-push"
cp "$ROOT/seed/strategy/scripts/update-derived-snapshot.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/update-derived-snapshot.py"
cp "$ROOT/seed/strategy/scripts/day-open-llm-fill.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/day-open-llm-fill.py"
cp "$ROOT/seed/strategy/scripts/iwe_checklist_memory.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/iwe_checklist_memory.py"
cp "$ROOT/seed/strategy/scripts/sync_feedback_to_memory.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/sync_feedback_to_memory.py"
cp "$ROOT/seed/strategy/scripts/agent_fault_remind.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.py"
cp "$ROOT/seed/strategy/scripts/agent_fault_remind.sh" \
    "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.sh"
cp "$ROOT/seed/strategy/scripts/generate-executor-catalog.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/generate-executor-catalog.py"
cp "$ROOT/scripts/agent-fault/iwe_checklist_memory.py" \
    "$SCRIPT_DIR/scripts/agent-fault/iwe_checklist_memory.py"
cp "$ROOT/scripts/lib/find-python3.sh" "$SCRIPT_DIR/scripts/lib/find-python3.sh"
cp "$ROOT/scripts/generate-executor-catalog.py" \
    "$SCRIPT_DIR/scripts/generate-executor-catalog.py"
cp "$ROOT/scripts/route-task.sh" "$SCRIPT_DIR/scripts/route-task.sh"
cp "$ROOT/setup/install-iwe-paths.sh" "$SCRIPT_DIR/setup/install-iwe-paths.sh"
chmod +x \
    "$SCRIPT_DIR/seed/strategy/scripts/install-hooks.sh" \
    "$SCRIPT_DIR/seed/strategy/.githooks/pre-commit" \
    "$SCRIPT_DIR/seed/strategy/.githooks/pre-push" \
    "$SCRIPT_DIR/seed/strategy/scripts/update-derived-snapshot.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/day-open-llm-fill.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/iwe_checklist_memory.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/sync_feedback_to_memory.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.py" \
    "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.sh" \
    "$SCRIPT_DIR/seed/strategy/scripts/generate-executor-catalog.py" \
    "$SCRIPT_DIR/scripts/agent-fault/iwe_checklist_memory.py" \
    "$SCRIPT_DIR/scripts/lib/find-python3.sh" \
    "$SCRIPT_DIR/scripts/generate-executor-catalog.py" \
    "$SCRIPT_DIR/scripts/route-task.sh" \
    "$SCRIPT_DIR/setup/install-iwe-paths.sh"
cat > "$WORKSPACE_DIR/.claude/skills/smoke-catalog/SKILL.md" <<'EOF'
---
name: smoke-catalog
description: Deterministic recovery fixture.
routing:
  executor: sonnet
  deterministic: false
---
EOF
printf 'GOVERNANCE_REPO=custom-governance\n' > "$WORKSPACE_DIR/.exocortex.env"

GOVERNANCE="$WORKSPACE_DIR/custom-governance"
printf '#!/bin/bash\necho old installer\n' > "$GOVERNANCE/scripts/install-hooks.sh"
printf '#!/usr/bin/env python3\nprint("old snapshot")\n' \
    > "$GOVERNANCE/scripts/update-derived-snapshot.py"
cp "$ROOT/seed/strategy/REPO-TYPE.md" "$GOVERNANCE/REPO-TYPE.md"
cat > "$GOVERNANCE/scripts/day-open-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
# Simulates the pre-fix installed caller: it exports a stale workspace identity
# before launching the updater. update.sh intentionally does not replace this
# user-owned pipeline, so the updated child must self-identify.
export IWE_ROOT="${OLD_PIPELINE_IWE_ROOT:?}"
export IWE_GOVERNANCE_REPO="${OLD_PIPELINE_GOVERNANCE_REPO:?}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$SCRIPT_DIR/update-derived-snapshot.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("installed_snapshot_upgrade", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.SNAPSHOT_PATH)
PY
EOF
chmod +x "$GOVERNANCE/scripts/install-hooks.sh" \
    "$GOVERNANCE/scripts/update-derived-snapshot.py" \
    "$GOVERNANCE/scripts/day-open-pipeline.sh"
git -C "$GOVERNANCE" init -q
git -C "$GOVERNANCE" config user.email t@t
git -C "$GOVERNANCE" config user.name t
git -C "$GOVERNANCE" add -- REPO-TYPE.md scripts/day-open-pipeline.sh \
    scripts/install-hooks.sh scripts/update-derived-snapshot.py
git -C "$GOVERNANCE" commit -qm init
OLD_PIPELINE_HASH=$(shasum -a 256 "$GOVERNANCE/scripts/day-open-pipeline.sh" | cut -d' ' -f1)

OUTSIDE_SNAPSHOT="$TEST_ROOT/outside-snapshot-sentinel.py"
printf 'outside snapshot sentinel\n' > "$OUTSIDE_SNAPSHOT"
rm "$GOVERNANCE/scripts/update-derived-snapshot.py"
ln -s "$OUTSIDE_SNAPSHOT" "$GOVERNANCE/scripts/update-derived-snapshot.py"
cat > "$SCRIPT_DIR/setup/build-runtime.sh" <<'EOF'
#!/bin/bash
echo "brt-invoked-scenario-d" >> "$(cd "$(dirname "$0")/.." && pwd)/brt-probe.log"
exit 0
EOF
chmod +x "$SCRIPT_DIR/setup/build-runtime.sh"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d1.log" 2>&1
RC_D1=$?
set -e
if [ "$RC_D1" -eq 3 ] && \
   grep -q 'consumer scan refused symlinked Python file' "$TEST_ROOT/out-d1.log"; then
    pass "D1: snapshot symlink blocks before consumer scan can read through it"
else
    fail "D1: expected symlink refusal/exit 3, got rc=$RC_D1"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "D1: marker remains after post-backfill failure"
else
    fail "D1: post-backfill failure cleared the transaction marker"
fi
if [ "$(cat "$OUTSIDE_SNAPSHOT")" = "outside snapshot sentinel" ]; then
    pass "D1: external symlink target bytes remain untouched"
else
    fail "D1: snapshot backfill wrote through the symlink"
fi

rm "$GOVERNANCE/scripts/update-derived-snapshot.py"
git -C "$GOVERNANCE" restore --worktree -- scripts/update-derived-snapshot.py
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d2.log" 2>&1
RC_D2=$?
set -e
if [ "$RC_D2" -eq 0 ]; then
    pass "D2: fixed zero-diff rerun converges"
else
    fail "D2: fixed zero-diff rerun exited $RC_D2"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    fail "D2: marker remains after all post-backfills succeeded"
else
    pass "D2: marker removed only after all post-backfills succeeded"
fi
if cmp -s "$SCRIPT_DIR/seed/strategy/scripts/update-derived-snapshot.py" \
      "$GOVERNANCE/scripts/update-derived-snapshot.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/day-open-llm-fill.py" \
      "$GOVERNANCE/scripts/day-open-llm-fill.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/iwe_checklist_memory.py" \
      "$GOVERNANCE/scripts/iwe_checklist_memory.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/sync_feedback_to_memory.py" \
      "$GOVERNANCE/scripts/sync_feedback_to_memory.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.py" \
      "$GOVERNANCE/scripts/agent_fault_remind.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/agent_fault_remind.sh" \
      "$GOVERNANCE/scripts/agent_fault_remind.sh" && \
   cmp -s "$ROOT/scripts/agent-fault/iwe_checklist_memory.py" \
      "$SCRIPT_DIR/scripts/agent-fault/iwe_checklist_memory.py" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/scripts/install-hooks.sh" \
      "$GOVERNANCE/scripts/install-hooks.sh" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/.githooks/pre-commit" \
      "$GOVERNANCE/.githooks/pre-commit" && \
   cmp -s "$SCRIPT_DIR/seed/strategy/.githooks/pre-push" \
      "$GOVERNANCE/.githooks/pre-push" && \
   [ -f "$GOVERNANCE/scripts/executor-catalog.yaml" ]; then
    pass "D2: snapshot, reader, canonical CLI, shims, hooks and catalog delivered"
else
    fail "D2: one or more installed governance backfills are stale or missing"
fi
if [ ! -e "$WORKSPACE_DIR/DS-strategy" ]; then
    pass "D2: config-only governance resolution created no default DS-strategy"
else
    fail "D2: backfill escaped to default DS-strategy"
fi
OLD_PIPELINE_ACTUAL=$( \
    OLD_PIPELINE_IWE_ROOT="$TEST_ROOT/stale-foreign-workspace" \
    OLD_PIPELINE_GOVERNANCE_REPO="stale-foreign-governance" \
    bash "$GOVERNANCE/scripts/day-open-pipeline.sh"
)
GOVERNANCE_PHYSICAL=$(cd "$GOVERNANCE" && pwd -P)
OLD_PIPELINE_EXPECTED="$GOVERNANCE_PHYSICAL/inbox/WP-425/cache/derived_snapshot.json"
OLD_PIPELINE_HASH_AFTER=$(shasum -a 256 "$GOVERNANCE/scripts/day-open-pipeline.sh" | cut -d' ' -f1)
if [ "$OLD_PIPELINE_ACTUAL" = "$OLD_PIPELINE_EXPECTED" ] && \
   [ "$OLD_PIPELINE_HASH" = "$OLD_PIPELINE_HASH_AFTER" ]; then
    pass "D2: updated child self-identifies under an unchanged old installed pipeline"
else
    fail "D2: old caller routed updater to '$OLD_PIPELINE_ACTUAL' or was overwritten"
fi
if IWE_EXECUTOR_CATALOG="$GOVERNANCE/scripts/executor-catalog.yaml" \
    bash "$SCRIPT_DIR/scripts/route-task.sh" --validate \
    > "$TEST_ROOT/route-validate.log" 2>&1; then
    pass "D2: installed route-task validates the generated catalog"
else
    fail "D2: installed route-task rejects generated catalog: $(cat "$TEST_ROOT/route-validate.log")"
fi

CATALOG_HASH_BEFORE=$(shasum -a 256 "$GOVERNANCE/scripts/executor-catalog.yaml" | cut -d' ' -f1)
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d3.log" 2>&1
RC_D3=$?
set -e
CATALOG_HASH_AFTER=$(shasum -a 256 "$GOVERNANCE/scripts/executor-catalog.yaml" | cut -d' ' -f1)
if [ "$RC_D3" -eq 0 ] && [ "$CATALOG_HASH_BEFORE" = "$CATALOG_HASH_AFTER" ]; then
    pass "D3: repeated zero-diff recovery is byte-idempotent"
else
    fail "D3: repeated recovery rc=$RC_D3 or executor catalog churned"
fi

echo "--- Scenario E: governance-root symlink fails before install-path writes ---"
EXTERNAL_GOVERNANCE="$TEST_ROOT/external-governance"
mkdir -p "$EXTERNAL_GOVERNANCE/.githooks"
printf '#!/bin/bash\nexit 0\n' > "$EXTERNAL_GOVERNANCE/.githooks/pre-commit"
printf 'external sentinel\n' > "$EXTERNAL_GOVERNANCE/sentinel.txt"
git -C "$EXTERNAL_GOVERNANCE" init -q
git -C "$EXTERNAL_GOVERNANCE" config user.email external@test.invalid
git -C "$EXTERNAL_GOVERNANCE" config user.name external
git -C "$EXTERNAL_GOVERNANCE" add -- .githooks/pre-commit sentinel.txt
git -C "$EXTERNAL_GOVERNANCE" commit -qm init
EXTERNAL_CONFIG_HASH=$(shasum -a 256 "$EXTERNAL_GOVERNANCE/.git/config" | cut -d' ' -f1)
EXTERNAL_SENTINEL_HASH=$(shasum -a 256 "$EXTERNAL_GOVERNANCE/sentinel.txt" | cut -d' ' -f1)
ln -s "$EXTERNAL_GOVERNANCE" "$WORKSPACE_DIR/linked-governance"
printf 'GOVERNANCE_REPO=linked-governance\n' > "$WORKSPACE_DIR/.exocortex.env"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" IWE_UPDATE_CHANNEL=main \
    bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-e.log" 2>&1
RC_E=$?
set -e
EXTERNAL_CONFIG_HASH_AFTER=$(shasum -a 256 "$EXTERNAL_GOVERNANCE/.git/config" | cut -d' ' -f1)
EXTERNAL_SENTINEL_HASH_AFTER=$(shasum -a 256 "$EXTERNAL_GOVERNANCE/sentinel.txt" | cut -d' ' -f1)
if [ "$RC_E" -eq 3 ] && grep -q 'governance repo является symlink' "$TEST_ROOT/out-e.log"; then
    pass "E: governance-root symlink blocks post-backfill with EXIT_RUNTIME"
else
    fail "E: expected early governance symlink refusal/exit 3, got rc=$RC_E"
fi
if [ -f "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "E: transaction marker remains after early symlink refusal"
else
    fail "E: symlink refusal cleared the transaction marker"
fi
if [ "$EXTERNAL_CONFIG_HASH" = "$EXTERNAL_CONFIG_HASH_AFTER" ] && \
   [ "$EXTERNAL_SENTINEL_HASH" = "$EXTERNAL_SENTINEL_HASH_AFTER" ]; then
    pass "E: external git config and sentinel remain byte-identical"
else
    fail "E: install-path step wrote through governance-root symlink before refusal"
fi

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "build-runtime fail-closed contract: $FAIL check(s) failed"
    exit 1
fi
echo "build-runtime fail-closed contract: all checks passed"
