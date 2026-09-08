#!/usr/bin/env bash
# test_issue_463_setup_reuses_resolved_python3.sh — WP-529 F6 (Evgenii Red
# Team review 2026-08-19, defect #2). Renamed from
# test_setup_reuses_resolved_python3.sh (WP-529 Red Team round 2, 19.08) to
# match run-issue-tests.sh's test_issue_*.sh glob — the original name never
# ran in CI at all.
#
# setup.sh used to run scripts/lib/find-python3.sh only for its exit code
# (stdout discarded to /dev/null) and then call bare `python3` again to
# generate executor-catalog.yaml. On a real Apple Silicon machine those can
# be two DIFFERENT interpreters: the resolver walks a fixed candidate list
# (python3, /opt/homebrew/bin/python3, /usr/local/bin/python3, /usr/bin/…)
# and returns the first one with yaml importable, while bare `python3` just
# follows PATH — if PATH's `python3` has no yaml but a later resolver
# candidate does, setup.sh finds a working interpreter and then throws it
# away before actually using it.
#
# This test does not need two real Apple-Silicon python installs: it makes
# find-python3.sh's FIRST candidate (`python3` on PATH) resolve to a stub
# with no yaml, forcing the resolver to walk to its second candidate — a
# second stub that delegates to this machine's real yaml-capable python3.
# A setup.sh that discards the resolved path and calls bare `python3` again
# will hit the no-yaml stub and fail; a setup.sh that reuses the resolved
# path succeeds. Requires the host running this test to have a working
# python3+PyYAML somewhere findable via `command -v` (true for CI and any
# dev machine that can run the rest of this repo's test suite).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TEST_ROOT="/tmp/iwe-wp529-setup-python-test-$$"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"

# --- Stub PATH: a python3 with no yaml, shadowing the real one ---
BIN_NO_YAML="$TEST_ROOT/bin-no-yaml"
mkdir -p "$BIN_NO_YAML"

# generate-executor-catalog.py does `import yaml` at module load time — ANY
# invocation of it on a yaml-less interpreter fails with the same traceback,
# regardless of the script's own args. The resolver's own `-c "import yaml"`
# probe hits the identical failure, which is what makes it walk to the next
# candidate — that legitimate probe call and a bug re-deriving bare `python3`
# for the generator both hit this SAME stub, so counting invocations cannot
# tell them apart (found running this against the pre-fix setup.sh: the old
# code never calls find-python3.sh in this section at all, so the single
# illegitimate generator call is numerically indistinguishable from the
# resolver's single legitimate probe — "count <= 1" passed on both). The
# stub logs its OWN ARGUMENTS instead of a fixed marker, so the check below
# can tell "-c import yaml" (resolver probing a candidate) apart from a
# generate-executor-catalog.py path (the actual generator call Evgenii's
# finding is about).
cat > "$BIN_NO_YAML/python3" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$IWE_TEST_PROBE"
echo "Traceback (most recent call last):" >&2
echo "ModuleNotFoundError: No module named 'yaml'" >&2
exit 1
EOF
chmod +x "$BIN_NO_YAML/python3"

# find-python3.sh's second candidate is a hardcoded absolute path
# (/opt/homebrew/bin/python3) — it is used here AS-IS, not shadowed, so the
# resolver genuinely walks past the no-yaml stub to a real interpreter (same
# as the "resolver alone" check above). What this section actually verifies
# is the DIFFERENCE between two callers sharing the SAME `python3` PATH
# entry: the resolver (which also checks /opt/homebrew directly) succeeds
# either way, while a caller that discards its result and calls bare
# `python3` only ever sees whatever PATH's `python3` is — the no-yaml stub.
# A probe log on real /opt/homebrew/bin/python3 would need modifying a real
# system binary, which this test does not do; the assertions below instead
# distinguish success (yaml-capable output) from the specific ModuleNotFoundError
# defect #2 produces, which is what actually needs distinguishing.

# --- Sandbox TEMPLATE_DIR: only the two files under test, called directly
# with the same env find-python3.sh's candidate walk relies on (PATH order
# makes candidate #1 `python3` resolve to the no-yaml stub deterministically;
# the with-yaml stub is not on this PATH at all — reachability of a SECOND
# working interpreter is exactly what a discarding setup.sh would miss).
TEMPLATE_DIR="$ROOT"
export IWE_TEST_PROBE="$TEST_ROOT/probe.log"
: > "$IWE_TEST_PROBE"

echo "--- find-python3.sh alone: falls through the no-yaml stub to a real interpreter ---"
RESOLVED=$(PATH="$BIN_NO_YAML:$PATH" "$TEMPLATE_DIR/scripts/lib/find-python3.sh" 2>/dev/null)
RESOLVE_STATUS=$?
if [ "$RESOLVE_STATUS" -eq 0 ] && [ -n "$RESOLVED" ]; then
    pass "resolver succeeds despite the no-yaml stub being PATH's first python3"
else
    fail "resolver could not find any yaml-capable interpreter (status=$RESOLVE_STATUS)"
fi
if [ -s "$IWE_TEST_PROBE" ]; then
    pass "resolver actually tried the no-yaml stub first (candidate order respected)"
else
    fail "no-yaml stub was never invoked — PATH override did not take effect"
fi

echo "--- setup.sh's executor-catalog step: must reuse the resolved path, not re-call bare python3 ---"
# Extract the full "4e" block (preflight resolve + catalog generation) by line
# range and run it in isolation — running the whole setup.sh would need a
# full governance-repo fixture unrelated to this defect. The range is pinned
# to the section's own start/end markers so it survives edits elsewhere in
# setup.sh; if the markers move, START/END below need updating together with
# the sed range (both read from the same two greps, not duplicated numbers).
SECTION_START=$(grep -n '^# === 4e\. Generate executor-catalog' "$ROOT/setup.sh" | head -1 | cut -d: -f1)
SECTION_END=$(grep -n '^# === 4f\.' "$ROOT/setup.sh" | head -1 | cut -d: -f1)
if [ -z "$SECTION_START" ] || [ -z "$SECTION_END" ]; then
    fail "could not locate the 4e/4f section markers in setup.sh — extraction range invalid"
fi
SNIPPET="$TEST_ROOT/snippet.sh"
{
    echo "#!/bin/bash"
    echo "set -u"
    echo "TEMPLATE_DIR='$TEMPLATE_DIR'"
    echo "WORKSPACE_DIR='$TEST_ROOT/home/IWE'"
    echo "GOVERNANCE_REPO='irrelevant-for-this-snippet'"
    echo "CORE_ONLY=false"
    echo "DRY_RUN=false"
    sed -n "${SECTION_START},$((SECTION_END - 1))p" "$ROOT/setup.sh"
    # Production calls this only after step 6 has created/found governance.
    echo 'mkdir -p "$WORKSPACE_DIR/$GOVERNANCE_REPO"'
    echo 'generate_executor_catalog_for_governance'
} > "$SNIPPET"
chmod +x "$SNIPPET"

# Evgenii Red Team review 2026-08-19 (defect #2 continued, cold review):
# generate-executor-catalog.py resolves both its input (~/IWE/.claude/skills)
# and its default output (~/IWE/$GOVERNANCE_REPO/scripts/executor-catalog.yaml)
# from Path.home() — the snippet sets GOVERNANCE_REPO but never HOME, so an
# unmodified run reads the real machine's skills and writes a real file
# outside $TEST_ROOT. A sandbox HOME with just enough of a skills/ fixture
# to avoid the generator's own "SKILLS_DIR not found" exit(1) keeps both
# reads and writes inside $TEST_ROOT.
FAKE_HOME="$TEST_ROOT/home"
mkdir -p "$FAKE_HOME/IWE/.claude/skills/smoke-fixture"
cat > "$FAKE_HOME/IWE/.claude/skills/smoke-fixture/SKILL.md" <<'SKILLEOF'
---
name: smoke-fixture
description: minimal fixture skill for test_issue_463_setup_reuses_resolved_python3.sh
routing:
  executor: script
  script_path: scripts/smoke-fixture.sh
  deterministic: true
---
Fixture only — not a real skill.
SKILLEOF

# PATH puts the no-yaml stub first for BOTH the resolver call inside the
# snippet and any bare `python3` the snippet might call — this is the actual
# defect #2 scenario: PATH's own python3 has no yaml, but find-python3.sh's
# second candidate (a hardcoded /opt/homebrew/bin/python3) does. A fixed
# setup.sh reuses what the resolver found; a discarding one calls bare
# `python3` again, which resolves to the SAME no-yaml stub the resolver
# already rejected.
: > "$IWE_TEST_PROBE"
OUT=$(HOME="$FAKE_HOME" PATH="$BIN_NO_YAML:$PATH" bash "$SNIPPET" 2>&1)
STATUS=$?

# Evgenii Red Team review 2026-08-19 (defect #2 continued): three iterations
# to get this check right, found by actually running each against both the
# fixed setup.sh AND the exact pre-F6 defective setup.sh (commit 6dbbf19^):
#   1. Grepping $OUT for "ModuleNotFoundError" was never the actual contract
#      — old setup.sh caught the resolver's own defect and turned the
#      traceback into a friendly warning with exit 0, so the substring never
#      reached $OUT on EITHER old or fixed code.
#   2. A presence-only probe check (`grep -q "no-yaml-stub-invoked"`) is also
#      wrong: the snippet's own internal `find-python3.sh` call (setup.sh
#      line ~700) legitimately walks PATH's stub as its rejected first
#      candidate — that write happens on a CORRECT setup.sh too.
#   3. A count-based check (`invocations <= 1`) is ALSO wrong, and only
#      surfaces on the actual pre-F6 code: that code never calls
#      find-python3.sh in this section at all, so its single illegitimate
#      bare-`python3` call for the generator is numerically indistinguishable
#      from a correct setup.sh's single legitimate resolver probe — both are
#      exactly 1 invocation.
# The only signal that is unambiguous on both old and new code: WHAT was the
# stub invoked WITH. The resolver only ever probes candidates via
# `"$resolved" -c "import yaml"` (find-python3.sh above) — it never receives
# generate-executor-catalog.py as an argument. So checking for that filename
# in the probe log (which now records the stub's own $* on each call)
# distinguishes "the resolver rejected this candidate" from "something ran
# the generator itself on the rejected interpreter" — exactly the check
# Evgenii asked for ("отклонённый Python не запускал
# generate-executor-catalog.py").
#
# Cold review 2026-08-19 (Medium): this couples the signal to
# find-python3.sh's own contract — its header documents the probe as the
# literal `-c "import yaml"`, never a filename, so a future change to THAT
# file (not owned by this test) that started passing a script path to its
# internal probe would defeat this check. Left as documented coupling rather
# than re-architected: the resolver's contract already forbids that shape of
# call, and building extra machinery here to guard against a hypothetical
# breaking change to a different file's documented contract is the kind of
# defensive complexity this repo's own style guide (P5) warns against.
if grep -q "generate-executor-catalog.py" "$IWE_TEST_PROBE" 2>/dev/null; then
    fail "the no-yaml stub was invoked to run generate-executor-catalog.py directly — the resolved interpreter was discarded and bare python3 re-derived instead (defect #2 reproduced)"
    echo "  --- probe log ---" >&2
    cat "$IWE_TEST_PROBE" | sed 's/^/  /' >&2
    echo "  --- snippet output ---" >&2
    echo "$OUT" | sed 's/^/  /' >&2
else
    pass "the no-yaml stub was never invoked with generate-executor-catalog.py — the resolved interpreter was reused, not re-derived from bare python3"
fi
if [ "$STATUS" -eq 0 ]; then
    pass "snippet completed successfully (exit 0)"
else
    fail "snippet exited $STATUS (expected 0 — see output above)"
fi

echo "--- generator defaults: actual IWE_ROOT and governance repo, not HOME/IWE literals ---"
CUSTOM_WORKSPACE="$TEST_ROOT/custom-workspace"
CUSTOM_SKILLS="$CUSTOM_WORKSPACE/.claude/skills"
CUSTOM_CATALOG="$CUSTOM_WORKSPACE/custom-governance/scripts/executor-catalog.yaml"
mkdir -p "$CUSTOM_SKILLS"
cp -R "$FAKE_HOME/IWE/.claude/skills/smoke-fixture" "$CUSTOM_SKILLS/"
mkdir -p "$CUSTOM_SKILLS/agent-mode" "$CUSTOM_SKILLS/hybrid-mode" \
    "$CUSTOM_SKILLS/skip-explicit" "$CUSTOM_SKILLS/skip-destructive" \
    "$CUSTOM_SKILLS/skip-no-frontmatter" "$CUSTOM_SKILLS/skip-no-skill"
cat > "$CUSTOM_SKILLS/agent-mode/SKILL.md" <<'EOF'
---
name: agent-mode
description: Agent executor fixture.
routing:
  executor: agent
  model: sonnet
  deterministic: false
---
EOF
cat > "$CUSTOM_SKILLS/hybrid-mode/SKILL.md" <<'EOF'
---
name: hybrid-mode
description: Script plus judgment fixture.
routing:
  executor: script+judgment
  deterministic: false
---
EOF
cat > "$CUSTOM_SKILLS/skip-explicit/SKILL.md" <<'EOF'
---
name: skip-explicit
description: Explicitly non-routable fixture.
skip_reason: requires-pilot
---
EOF
cat > "$CUSTOM_SKILLS/skip-destructive/SKILL.md" <<'EOF'
---
name: skip-destructive
description: Interactive destructive fixture.
destructive: true
interactive: true
---
EOF
printf 'Fixture without YAML frontmatter.\n' \
    > "$CUSTOM_SKILLS/skip-no-frontmatter/SKILL.md"
DIRECT_OUT=$(IWE_ROOT="$CUSTOM_WORKSPACE" IWE_GOVERNANCE_REPO=custom-governance \
    "$RESOLVED" "$ROOT/scripts/generate-executor-catalog.py" 2>&1)
DIRECT_STATUS=$?
if [ "$DIRECT_STATUS" -eq 0 ] && [ -f "$CUSTOM_CATALOG" ]; then
    pass "generator writes to the configured workspace/governance path"
else
    fail "generator ignored configured paths or failed (status=$DIRECT_STATUS): $DIRECT_OUT"
fi
if grep -Fq '${IWE_GOVERNANCE_REPO:-DS-strategy}' "$CUSTOM_CATALOG" 2>/dev/null; then
    fail "generated catalog still contains a shell-expansion literal"
else
    pass "generated catalog contains no shell-expansion path literal"
fi
if IWE_EXECUTOR_CATALOG="$CUSTOM_CATALOG" \
    bash "$ROOT/scripts/route-task.sh" --validate >/dev/null 2>&1; then
    pass "route-task validates the generator taxonomy"
else
    fail "route-task rejects the generated executor catalog"
fi
AGENT_ROUTE=$(IWE_EXECUTOR_CATALOG="$CUSTOM_CATALOG" \
    bash "$ROOT/scripts/route-task.sh" --skill agent-mode 2>&1 || true)
HYBRID_ROUTE=$(IWE_EXECUTOR_CATALOG="$CUSTOM_CATALOG" \
    bash "$ROOT/scripts/route-task.sh" --skill hybrid-mode 2>&1 || true)
if echo "$AGENT_ROUTE" | grep -q 'ROUTE_TO_AGENT skill=agent-mode model=sonnet' && \
   echo "$HYBRID_ROUTE" | grep -q 'mode=script+judgment'; then
    pass "compound executor entries are executable by route-task"
else
    fail "compound executor dispatch mismatch: agent=[$AGENT_ROUTE] hybrid=[$HYBRID_ROUTE]"
fi
if "$RESOLVED" - "$CUSTOM_CATALOG" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    catalog = yaml.safe_load(stream)

expected = {
    "skip-explicit": "requires-pilot",
    "skip-destructive": "destructive-interactive",
    "skip-no-frontmatter": "no-frontmatter",
    "skip-no-skill": "no-SKILL.md",
}
actual = {
    item["name"]: item["skip_reason"]
    for item in catalog["skipped"]
    if set(item) == {"name", "skip_reason"}
}
assert catalog["reflexes"] == []
assert actual == expected, (actual, expected)
assert catalog["skipped_no_routing"] == len(expected)
PY
then
    pass "fresh catalog contains empty reflexes and detailed skip records"
else
    fail "fresh catalog lost detailed skip records or did not initialize reflexes"
fi

DIRECT_CATALOG_COPY="$TEST_ROOT/direct-catalog-first.yaml"
cp "$CUSTOM_CATALOG" "$DIRECT_CATALOG_COPY"
sleep 1
DIRECT_SECOND_OUT=$(IWE_ROOT="$CUSTOM_WORKSPACE" IWE_GOVERNANCE_REPO=custom-governance \
    "$RESOLVED" "$ROOT/scripts/generate-executor-catalog.py" 2>&1)
DIRECT_SECOND_STATUS=$?
if [ "$DIRECT_SECOND_STATUS" -eq 0 ] && cmp -s "$DIRECT_CATALOG_COPY" "$CUSTOM_CATALOG"; then
    pass "unchanged executor input keeps catalog byte-stable across reruns"
else
    fail "unchanged direct generator rewrote catalog (status=$DIRECT_SECOND_STATUS): $DIRECT_SECOND_OUT"
fi

echo "--- generator state boundary: preserve only reflexes and fail closed on bad output ---"
"$RESOLVED" - "$CUSTOM_CATALOG" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = yaml.safe_load(stream)
catalog["reflexes"] = [{"trigger": "fixture", "action": "preserve"}]
catalog["foreign_runtime_section"] = [{"must": "drop"}]
catalog["total_entries"] = 999
catalog["entries"] = []
catalog["skipped"] = []
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(catalog, stream, allow_unicode=True, sort_keys=False)
PY
PRESERVE_OUT=$(IWE_ROOT="$CUSTOM_WORKSPACE" IWE_GOVERNANCE_REPO=custom-governance \
    "$RESOLVED" "$ROOT/scripts/generate-executor-catalog.py" 2>&1)
PRESERVE_STATUS=$?
if [ "$PRESERVE_STATUS" -eq 0 ] && "$RESOLVED" - "$CUSTOM_CATALOG" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    catalog = yaml.safe_load(stream)
assert catalog["reflexes"] == [{"trigger": "fixture", "action": "preserve"}]
assert "foreign_runtime_section" not in catalog
assert catalog["total_entries"] == 3
assert {entry["name"] for entry in catalog["entries"]} == {
    "agent-mode", "hybrid-mode", "smoke-fixture"
}
assert len(catalog["skipped"]) == 4
PY
then
    pass "regeneration preserves only reflexes and rebuilds every derived field"
else
    fail "preserved-state boundary mismatch (status=$PRESERVE_STATUS): $PRESERVE_OUT"
fi

assert_invalid_catalog_rejected() {
    local label="$1"
    local content="$2"
    local invalid_path="$TEST_ROOT/invalid-$label.yaml"
    local before_path="$TEST_ROOT/invalid-$label.before"
    local invalid_out invalid_status

    printf '%s' "$content" > "$invalid_path"
    cp "$invalid_path" "$before_path"
    invalid_out=$(IWE_ROOT="$CUSTOM_WORKSPACE" IWE_GOVERNANCE_REPO=custom-governance \
        "$RESOLVED" "$ROOT/scripts/generate-executor-catalog.py" \
        --skills-dir "$CUSTOM_SKILLS" --output "$invalid_path" 2>&1)
    invalid_status=$?
    if [ "$invalid_status" -ne 0 ] && cmp -s "$before_path" "$invalid_path"; then
        pass "invalid existing catalog ($label) is rejected without byte changes"
    else
        fail "invalid existing catalog ($label) was accepted or modified (status=$invalid_status): $invalid_out"
    fi
}

assert_invalid_catalog_rejected "yaml" $'reflexes: [\n'
assert_invalid_catalog_rejected "nonmapping" $'- item\n'
assert_invalid_catalog_rejected "missing-reflexes" $'schema_version: "1.0"\n'
assert_invalid_catalog_rejected "nonlist-reflexes" $'reflexes: {}\n'

VALIDATE_OUTPUT="$TEST_ROOT/validate-input-only.yaml"
printf 'reflexes: [\n' > "$VALIDATE_OUTPUT"
cp "$VALIDATE_OUTPUT" "$VALIDATE_OUTPUT.before"
VALIDATE_OUT=$(IWE_ROOT="$CUSTOM_WORKSPACE" IWE_GOVERNANCE_REPO=custom-governance \
    "$RESOLVED" "$ROOT/scripts/generate-executor-catalog.py" \
    --validate --skills-dir "$CUSTOM_SKILLS" --output "$VALIDATE_OUTPUT" 2>&1)
VALIDATE_STATUS=$?
if [ "$VALIDATE_STATUS" -eq 0 ] && cmp -s "$VALIDATE_OUTPUT.before" "$VALIDATE_OUTPUT"; then
    pass "--validate checks input only and leaves an invalid output path untouched"
else
    fail "--validate read or changed the output path (status=$VALIDATE_STATUS): $VALIDATE_OUT"
fi

echo "--- update.sh backfill: same resolved Python and explicit installed paths ---"
UPDATE_WORKSPACE="$TEST_ROOT/update-workspace"
UPDATE_GOVERNANCE="$UPDATE_WORKSPACE/update-governance"
mkdir -p "$UPDATE_WORKSPACE/.claude/skills" "$UPDATE_GOVERNANCE/scripts"
cp -R "$FAKE_HOME/IWE/.claude/skills/smoke-fixture" "$UPDATE_WORKSPACE/.claude/skills/"

UPDATE_FUNCTIONS="$TEST_ROOT/update-backfill-functions.sh"
awk '
  /^effective_governance_repo\(\)/ { capture=1 }
  /^record_rule_workspace_state\(\)/ { exit }
  capture { print }
' "$ROOT/update.sh" > "$UPDATE_FUNCTIONS"
if ! grep -q '^backfill_executor_catalog()' "$UPDATE_FUNCTIONS" \
    || ! grep -q '^backfill_derived_snapshot_updater()' "$UPDATE_FUNCTIONS" \
    || ! grep -q '^backfill_executor_catalog_generator()' "$UPDATE_FUNCTIONS"; then
    fail "could not extract update backfill functions"
fi

UPDATE_SNIPPET="$TEST_ROOT/update-catalog-snippet.sh"
{
    echo "#!/bin/bash"
    echo "set -u"
    echo "SCRIPT_DIR='$ROOT'"
    echo "WORKSPACE_DIR='$UPDATE_WORKSPACE'"
    echo "ENV_GOVERNANCE_REPO='update-governance'"
    echo "unset IWE_GOVERNANCE_REPO"
    cat "$UPDATE_FUNCTIONS"
    echo 'EFFECTIVE_GOVERNANCE_REPO=$(effective_governance_repo)'
    echo "backfill_derived_snapshot_updater"
    echo "backfill_executor_catalog_generator"
    echo "backfill_executor_catalog"
} > "$UPDATE_SNIPPET"
chmod +x "$UPDATE_SNIPPET"

git -C "$UPDATE_GOVERNANCE" init -q
git -C "$UPDATE_GOVERNANCE" config user.name "Issue 508 update test"
git -C "$UPDATE_GOVERNANCE" config user.email "issue-508@example.invalid"
printf '#!/usr/bin/env python3\nSNAPSHOT_PATH = "${IWE_GOVERNANCE_REPO:-DS-strategy}"\n' \
    > "$UPDATE_GOVERNANCE/scripts/update-derived-snapshot.py"
chmod +x "$UPDATE_GOVERNANCE/scripts/update-derived-snapshot.py"
git -C "$UPDATE_GOVERNANCE" add -- scripts/update-derived-snapshot.py
git -C "$UPDATE_GOVERNANCE" commit -qm "old installed snapshot updater"

: > "$IWE_TEST_PROBE"
UPDATE_OUT=$(PATH="$BIN_NO_YAML:$PATH" bash "$UPDATE_SNIPPET" 2>&1)
UPDATE_STATUS=$?
UPDATE_CATALOG="$UPDATE_GOVERNANCE/scripts/executor-catalog.yaml"
if [ "$UPDATE_STATUS" -eq 0 ] && [ -f "$UPDATE_CATALOG" ]; then
    pass "update backfills executor catalog at the installed governance path"
else
    fail "update catalog backfill failed (status=$UPDATE_STATUS): $UPDATE_OUT"
fi
if grep -q "generate-executor-catalog.py" "$IWE_TEST_PROBE" 2>/dev/null; then
    fail "update re-ran the generator with PATH's rejected no-yaml Python"
else
    pass "update reuses the resolver-selected Python for catalog generation"
fi
if cmp -s "$ROOT/seed/strategy/scripts/update-derived-snapshot.py" \
    "$UPDATE_GOVERNANCE/scripts/update-derived-snapshot.py"; then
    pass "update backfills the executed governance snapshot updater from release bytes"
else
    fail "governance snapshot updater stayed on the old literal-path implementation"
fi
if cmp -s "$ROOT/scripts/generate-executor-catalog.py" \
        "$ROOT/seed/strategy/scripts/generate-executor-catalog.py" \
    && cmp -s "$ROOT/seed/strategy/scripts/generate-executor-catalog.py" \
        "$UPDATE_GOVERNANCE/scripts/generate-executor-catalog.py"; then
    pass "setup source, seed payload, and update-backfilled generator are byte-identical"
else
    fail "executor catalog generator drifted between setup, seed, and update backfill"
fi
SETUP_CATALOG="$FAKE_HOME/IWE/irrelevant-for-this-snippet/scripts/executor-catalog.yaml"
if "$RESOLVED" - "$SETUP_CATALOG" "$UPDATE_CATALOG" <<'PY'
import sys
import yaml

catalogs = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as stream:
        catalog = yaml.safe_load(stream)
    catalog.pop("generated_at", None)
    catalogs.append(catalog)
assert catalogs[0] == catalogs[1], catalogs
PY
then
    pass "fresh setup and update backfill generate the same semantic catalog"
else
    fail "fresh setup and update backfill catalog payloads differ"
fi
if grep -Fq '"path": "seed/strategy/scripts/generate-executor-catalog.py"' \
    "$ROOT/update-manifest.json"; then
    pass "update manifest delivers the seed generator required by backfill"
else
    fail "update manifest omits the seed generator required by backfill"
fi
if [ ! -e "$UPDATE_WORKSPACE/DS-strategy" ]; then
    pass ".exocortex governance value wins without exported IWE_GOVERNANCE_REPO"
else
    fail "backfill wrote to default DS-strategy instead of configured governance"
fi

git -C "$UPDATE_GOVERNANCE" add -- \
    scripts/executor-catalog.yaml scripts/generate-executor-catalog.py \
    scripts/update-derived-snapshot.py
git -C "$UPDATE_GOVERNANCE" commit -qm "accept first update backfill"
UPDATE_CATALOG_COPY="$TEST_ROOT/update-catalog-first.yaml"
cp "$UPDATE_CATALOG" "$UPDATE_CATALOG_COPY"
sleep 1
: > "$IWE_TEST_PROBE"
UPDATE_SECOND_OUT=$(PATH="$BIN_NO_YAML:$PATH" bash "$UPDATE_SNIPPET" 2>&1)
UPDATE_SECOND_STATUS=$?
if [ "$UPDATE_SECOND_STATUS" -eq 0 ] \
    && cmp -s "$UPDATE_CATALOG_COPY" "$UPDATE_CATALOG" \
    && [ -z "$(git -C "$UPDATE_GOVERNANCE" status --porcelain)" ]; then
    pass "second update backfill is byte-stable and leaves governance clean"
else
    fail "second update backfill is not idempotent (status=$UPDATE_SECOND_STATUS): $UPDATE_SECOND_OUT"
fi

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "setup.sh python3-reuse contract: $FAIL check(s) failed"
    exit 1
fi
echo "setup.sh python3-reuse contract: all checks passed"
