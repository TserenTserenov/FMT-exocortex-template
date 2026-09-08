#!/usr/bin/env bash
# test_generate_manifest_registers_setup_exclusions.sh — Evgenii Red Team
# review 2026-08-19 (post-merge manifest drift observation, #3).
#
# generate-manifest.sh's setup/* blanket-skip branch used to `continue`
# without ever appending to EXCLUDED_PATHS — every setup/test-*.sh file
# (and 20+ others under setup/) fell out of BOTH manifest.files and
# manifest.excluded_paths silently. check-manifest-coverage.py (which
# already existed, but was never wired into CI as its own gate) correctly
# flags this as a coverage gap: no way to distinguish "forgotten delivery"
# from "deliberately install-time-only".
#
# This test runs the REAL generate-manifest.sh + check-manifest-coverage.py
# against a scratch clone of this repo (same harness pattern as
# setup/test-update-issue-226.sh) — generate-manifest.sh has no --output
# flag, it always writes $SCRIPT_DIR/update-manifest.json, so the whole
# repo is cloned rather than pointed at the live manifest.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
SCRATCH="/tmp/iwe-manifest-setup-exclusion-test-$$"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
cleanup() { local rc=$?; rm -rf "$SCRATCH"; exit "$rc"; }
trap cleanup EXIT INT TERM

# generate-manifest.sh runs `git ls-files` internally, so the scratch copy
# needs an actual .git, not just the tracked files — `git archive` strips
# .git entirely and silently produces an empty manifest (0 files) instead
# of failing loud, which would have made every setup/ file look "uncovered"
# for the wrong reason. `git clone --local` gives a real repo at HEAD.
git clone --local --quiet "$ROOT" "$SCRATCH" \
    || { fail "git clone of $ROOT failed"; exit 1; }
# A local clone contains committed HEAD only. Overlay the generator under test
# so the check observes the current working-tree implementation before commit.
cp "$ROOT/generate-manifest.sh" "$SCRATCH/generate-manifest.sh"

echo "--- generate-manifest.sh must register EVERY setup/ file it skips ---"
( cd "$SCRATCH" && bash generate-manifest.sh >/dev/null 2>&1 ) \
    || { fail "generate-manifest.sh itself failed"; exit 1; }

echo "--- platform delivery infrastructure is the only seed/ upgrade allow-list ---"
PLATFORM_HOOK_PATHS="
seed/strategy/.githooks/pre-commit
seed/strategy/.githooks/pre-push
seed/strategy/scripts/install-hooks.sh
seed/strategy/scripts/update-derived-snapshot.py
"
PLATFORM_HOOK_FAILURES=""
for hook_path in $PLATFORM_HOOK_PATHS; do
    PRESENT=$(cd "$SCRATCH" && python3 -c "
import json
manifest = json.load(open('update-manifest.json'))
print('1' if any(entry['path'] == '$hook_path' for entry in manifest['files']) else '0')
")
    [ "$PRESENT" = "1" ] || PLATFORM_HOOK_FAILURES="$PLATFORM_HOOK_FAILURES $hook_path"
done
if [ -z "$PLATFORM_HOOK_FAILURES" ]; then
    pass "all platform delivery files are delivered through files[]"
else
    fail "platform delivery files missing from files[]:$PLATFORM_HOOK_FAILURES"
fi

UNRELATED_SEED_PRESENT=$(cd "$SCRATCH" && python3 -c "
import json
manifest = json.load(open('update-manifest.json'))
print('1' if any(entry['path'] == 'seed/strategy/CLAUDE.md' for entry in manifest['files']) else '0')
")
if [ "$UNRELATED_SEED_PRESENT" = "0" ]; then
    pass "unrelated seed user-space remains outside update delivery"
else
    fail "seed/strategy/CLAUDE.md leaked into files[] with the platform hook allow-list"
fi

# Cross-check against the REAL setup/ tree, not a fixture: any tracked file
# under setup/ that generate-manifest.sh silently drops is exactly the
# defect Evgenii found (test-delivery-route-label.sh was one instance among
# several — the fix targets the branch, not one filename).
UNCOVERED=""
while IFS= read -r f; do
    COVERED=$(cd "$SCRATCH" && python3 -c "
import json
m = json.load(open('update-manifest.json'))
in_files = any(x['path'] == '$f' for x in m['files'])
in_excluded = '$f' in m.get('excluded_paths', [])
print('1' if (in_files or in_excluded) else '0')
")
    [ "$COVERED" = "0" ] && UNCOVERED="$UNCOVERED $f"
done < <(git -C "$SCRATCH" ls-files setup/)

if [ -z "$UNCOVERED" ]; then
    pass "every tracked setup/ file is in manifest.files or manifest.excluded_paths"
else
    fail "uncovered setup/ files (in neither list):$UNCOVERED"
fi

echo "--- check-manifest-coverage.py must find zero gaps on the generated manifest ---"
if ( cd "$SCRATCH" && git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json ) >/tmp/coverage-out-$$.log 2>&1; then
    pass "check-manifest-coverage.py: zero gaps"
else
    fail "check-manifest-coverage.py found gaps:"
    sed 's/^/  /' /tmp/coverage-out-$$.log >&2
fi
rm -f /tmp/coverage-out-$$.log

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "manifest setup-exclusion contract: $FAIL check(s) failed"
    exit 1
fi
echo "manifest setup-exclusion contract: all checks passed"
