#!/bin/bash
# Regression test for read-only Pack mounting in the isolated inbox-check
# sandbox (WP-5, ArchGate 03.09): inbox-check.md never writes into a Pack by
# design (only the separate, pilot-triggered apply session does) -- but
# run_claude launches Claude with --dangerously-skip-permissions and
# Write/Edit tools allowed, so "don't write here" as prompt text alone is
# not a real control (same gap class as
# inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md). This test
# verifies the mount is actually read-only at the filesystem level, and that
# the real cleanup function can still remove it afterward.
#
# Extracts the functions straight out of the real extractor.sh (instead of
# sourcing the whole file, which guards against direct execution from the
# raw FMT checkout and requires a built runtime) via awk, and calls the real
# cleanup_isolated_inbox_worktree() -- not a hand-rolled equivalent -- so a
# regression in its actual pack-removal loop would fail this test (cold
# review 03.09 found the first version of this test didn't do that).
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/extractor/scripts/extractor.sh"
extract_fn() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$SCRIPT"
}
MOUNT_FN=$(extract_fn mount_readonly_packs)
CLEANUP_FN=$(extract_fn cleanup_isolated_inbox_worktree)
if [ -z "$MOUNT_FN" ]; then
    echo "FAIL: mount_readonly_packs() not found in $SCRIPT"
    exit 1
fi
if [ -z "$CLEANUP_FN" ]; then
    echo "FAIL: cleanup_isolated_inbox_worktree() not found in $SCRIPT"
    exit 1
fi
eval "$MOUNT_FN"
eval "$CLEANUP_FN"

# Both extracted functions call log() and append to $LOG_FILE -- stub both so
# they run standalone without the rest of extractor.sh.
LOG_FILE=/dev/null
log() { :; }

FAIL=0
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

WORKSPACE="$TMP/workspace"
ISOLATED="$TMP/isolated"
mkdir -p "$WORKSPACE" "$ISOLATED"

git init -q -b main "$WORKSPACE/PACK-test"
git -C "$WORKSPACE/PACK-test" config user.email "test@example.invalid"
git -C "$WORKSPACE/PACK-test" config user.name "Pack mount regression"
echo "original content" > "$WORKSPACE/PACK-test/00-pack-manifest.md"
git -C "$WORKSPACE/PACK-test" add 00-pack-manifest.md
git -C "$WORKSPACE/PACK-test" commit -q -m init

mount_readonly_packs "$WORKSPACE" "$ISOLATED"

if [ -f "$ISOLATED/PACK-test/00-pack-manifest.md" ]; then
    echo "PASS: Pack content is readable in the isolated mount"
else
    echo "FAIL: expected $ISOLATED/PACK-test/00-pack-manifest.md to exist"
    FAIL=1
fi

if echo "tampered" > "$ISOLATED/PACK-test/00-pack-manifest.md" 2>/dev/null; then
    echo "FAIL: writing into the mounted Pack succeeded — filesystem is not actually read-only"
    FAIL=1
else
    echo "PASS: writing into the mounted Pack fails at the filesystem level"
fi

if touch "$ISOLATED/PACK-test/new-file.md" 2>/dev/null; then
    echo "FAIL: creating a new file inside the mounted Pack succeeded"
    FAIL=1
else
    echo "PASS: creating a new file inside the mounted Pack fails (directory itself is read-only)"
fi

# Live checkout must be untouched by the mount (it's a clone, not a symlink).
if [ "$(cat "$WORKSPACE/PACK-test/00-pack-manifest.md")" = "original content" ]; then
    echo "PASS: the live Pack checkout is untouched"
else
    echo "FAIL: the live Pack checkout was modified"
    FAIL=1
fi

# Exercise the REAL cleanup_isolated_inbox_worktree() end to end, with the
# same shape of arguments run_inbox_check_isolated() actually passes it --
# not a hand-rolled chmod+rm -rf standing in for it.
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GOV_REPO="$WORKSPACE/$GOVERNANCE_REPO"
git init -q -b main "$GOV_REPO"
git -C "$GOV_REPO" config user.email "test@example.invalid"
git -C "$GOV_REPO" config user.name "Pack mount regression"
git -C "$GOV_REPO" commit -q --allow-empty -m init
GOV_WORKTREE="$TMP/run_root/$GOVERNANCE_REPO"
mkdir -p "$TMP/run_root"
git -C "$GOV_REPO" worktree add -q -b extractor/inbox-check-test "$GOV_WORKTREE" main

cleanup_isolated_inbox_worktree "$GOV_REPO" "$GOV_WORKTREE" "extractor/inbox-check-test" \
    "$ISOLATED" "$GOVERNANCE_REPO" "$TMP/run_root"

if [ -d "$ISOLATED/PACK-test" ]; then
    echo "FAIL: cleanup_isolated_inbox_worktree() left the read-only Pack clone behind"
    FAIL=1
else
    echo "PASS: cleanup_isolated_inbox_worktree() removes the read-only Pack clone"
fi

if [ -d "$ISOLATED" ]; then
    echo "FAIL: cleanup_isolated_inbox_worktree() left the isolated workspace shell behind"
    FAIL=1
else
    echo "PASS: cleanup_isolated_inbox_worktree() removes the now-empty isolated workspace"
fi

exit $FAIL
