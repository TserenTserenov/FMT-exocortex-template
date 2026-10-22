#!/usr/bin/env bash
# Regression coverage for issue #850: a full git-mirror with its own CI
# enabled gets .github/workflows/validate-template.yml updated every release
# via update.sh, but the setup/test-*.sh and scripts/tests/*.sh files that
# workflow calls are in excluded_paths and never update after the initial
# clone — so a mirror's CI eventually fails on a stale test checking fresh
# code, not a real delivery regression (reported: #728 lines of canon test
# vs #488 lines on a 6-release-old mirror).
#
# windows-session-guard/integration-contract-ubuntu/integration-contract-macos
# /issue-1030-windows/upgrade-test already carry
# `if: github.repository == 'TserenTserenov/FMT-exocortex-template'` (issue
# #1223) so they simply don't run on a mirror. The `validate` job was left
# uncovered despite calling dozens of excluded_paths test files (lines
# 672-909 at the time of writing) -- that gap is the actual live source of
# the drift reported in #850, not the workflow file as a whole.
#
# This test extracts the real validate-template.yml and update-manifest.json
# from the repo (not re-typed copies) and asserts: every job whose steps
# reference a path from excluded_paths[] carries the canon-only guard at job
# level. It is deliberately generic (not just "does the `validate` job have
# it") so a future new job making the same mistake is caught too.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$ROOT/.github/workflows/validate-template.yml"
MANIFEST="$ROOT/update-manifest.json"

fail=0
pass() { echo "  PASS: $*"; }
fail_test() { echo "  FAIL: $*" >&2; fail=1; }

CHECK=$(python3 <<PYEOF
import json, sys
import yaml

with open("$MANIFEST") as f:
    manifest = json.load(f)
excluded = manifest["excluded_paths"]

with open("$WORKFLOW") as f:
    wf = yaml.safe_load(f)

GUARD = "github.repository == 'TserenTserenov/FMT-exocortex-template'"
violations = []
checked = 0

for job_name, job in wf["jobs"].items():
    run_text = "\n".join(
        step.get("run", "") for step in job.get("steps", []) if isinstance(step, dict)
    )
    if not run_text:
        continue
    referenced = [p for p in excluded if p in run_text]
    if not referenced:
        continue
    checked += 1
    job_if = job.get("if", "")
    if GUARD not in job_if:
        violations.append((job_name, referenced[:3]))

if violations:
    for job_name, sample in violations:
        print(f"VIOLATION:{job_name}:{','.join(sample)}")
print(f"CHECKED:{checked}")
PYEOF
)

echo "$CHECK"

checked_count=$(echo "$CHECK" | grep "^CHECKED:" | cut -d: -f2)
violation_lines=$(echo "$CHECK" | grep "^VIOLATION:" || true)

if [ -z "$checked_count" ] || [ "$checked_count" -lt 1 ]; then
    fail_test "T1: parser found 0 jobs referencing excluded_paths -- manifest/workflow drifted or parser broke, test can't assert anything"
else
    pass "T1: parser found $checked_count job(s) referencing excluded_paths to check"
fi

if [ -n "$violation_lines" ]; then
    fail_test "T2: job(s) without canon-only guard despite referencing excluded_paths:"
    echo "$violation_lines" >&2
else
    pass "T2: every job referencing excluded_paths carries the canon-only guard"
fi

# --- T3: prove the check actually catches the regression (not a tautology) ---
# Strip the guard from the `validate` job in a scratch copy and verify the
# same parser now reports it as a violation.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 - "$WORKFLOW" "$TMP/broken.yml" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    lines = f.readlines()
out = []
skip_next_if = False
for line in lines:
    stripped = line.strip()
    if stripped == "validate:":
        skip_next_if = True
        out.append(line)
        continue
    if skip_next_if:
        # drop the comment block + `if:` line this test's own fix added
        if stripped.startswith("#") or stripped.startswith("if: github.repository"):
            continue
        skip_next_if = False
    out.append(line)
with open(dst, "w") as f:
    f.writelines(out)
PYEOF

BROKEN_CHECK=$(python3 <<PYEOF
import json
import yaml

with open("$MANIFEST") as f:
    manifest = json.load(f)
excluded = manifest["excluded_paths"]

with open("$TMP/broken.yml") as f:
    wf = yaml.safe_load(f)

GUARD = "github.repository == 'TserenTserenov/FMT-exocortex-template'"
violations = []
for job_name, job in wf["jobs"].items():
    run_text = "\n".join(
        step.get("run", "") for step in job.get("steps", []) if isinstance(step, dict)
    )
    if not run_text:
        continue
    if any(p in run_text for p in excluded) and GUARD not in job.get("if", ""):
        violations.append(job_name)

print("validate" in violations)
PYEOF
)

if [ "$BROKEN_CHECK" = "True" ]; then
    pass "T3: stripping the guard from a scratch copy is correctly flagged (check is not a tautology)"
else
    fail_test "T3: stripping the guard from 'validate' was NOT flagged -- parser/assertion logic is broken"
fi

if [ "$fail" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "TESTS FAILED" >&2
    exit 1
fi
