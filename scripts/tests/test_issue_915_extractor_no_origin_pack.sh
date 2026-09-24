#!/usr/bin/env bash
# Regression coverage for issue #915: mount_readonly_packs() in extractor.sh
# aborted the whole inbox-check run the moment it hit a Pack with no `origin`
# remote (a Pack the user keeps local-only by policy). It only had a skip
# path for the unrelated `.pack-frozen` case. This test extracts the two
# functions under test (not the whole script -- extractor.sh's bottom `case`
# dispatches real work on $1 and is not source-safe for unit testing) and
# exercises three Pack shapes: frozen, local-only (no origin, real git repo),
# and normal (origin points at a local bare repo so `git clone` needs no
# network).
set -uo pipefail

# A bare CI runner has no global git identity configured (unlike a dev
# machine) -- every `git commit` below needs its own, or it fails with
# "Author identity unknown" (same class of gap fixed for this repo's own
# CI ancestry-hardening tests, WP-7 F167, 22.09).
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.invalid"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/roles/extractor/scripts/extractor.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

WORKDIR=$(mktemp -d)
# mount_readonly_packs chmod -R a-w's the mounted clone by design (read-only
# enforcement) -- undo that before cleanup or rm -rf fails on the clone.
trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT
LOG_FILE="$WORKDIR/extractor.log"
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

# Load only the two functions under test into this shell.
eval "$(sed -n '/^mount_readonly_packs()/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^pack_snapshot_context()/,/^}/p' "$SCRIPT")"

CANON="$WORKDIR/canon"
ISO="$WORKDIR/iso"
mkdir -p "$CANON" "$ISO"

# PACK-frozen: explicitly frozen marker, not even a git repo -- must be
# skipped without ever reaching a git command.
mkdir -p "$CANON/PACK-frozen"
touch "$CANON/PACK-frozen/.pack-frozen"

# PACK-local: a real git repo, deliberately no `origin` (the reported case).
mkdir -p "$CANON/PACK-local"
git -C "$CANON/PACK-local" init -q
git -C "$CANON/PACK-local" commit -q --allow-empty -m init

# PACK-good: origin points at a local bare repo, so the strict clone branch
# below can succeed without any network access.
#
# The bare repo's HEAD symref is pinned to `main` explicitly (`-b main`),
# not left to `init.defaultBranch` -- a bare repo whose HEAD points at a
# branch nothing was ever pushed to (e.g. the CI runner's `master` default,
# vs. `main` on this dev machine) leaves `git clone` unable to check
# anything out, and the later `git rev-parse HEAD` in mount_readonly_packs()
# fails with "ambiguous argument 'HEAD'" -- passed locally, failed in CI
# (GitHub Actions run on PR #916, 24.09) for exactly this reason.
BARE="$WORKDIR/PACK-good-bare.git"
git init -q --bare -b main "$BARE"
mkdir -p "$CANON/PACK-good"
git -C "$CANON/PACK-good" init -q
git -C "$CANON/PACK-good" commit -q --allow-empty -m init
git -C "$CANON/PACK-good" remote add origin "$BARE"
git -C "$CANON/PACK-good" push -q origin HEAD:refs/heads/main

if mount_readonly_packs "$CANON" "$ISO"; then
    pass "run did not abort with a local-only (no-origin) Pack present"
else
    fail_test "mount_readonly_packs aborted the whole run instead of skipping the no-origin Pack"
fi

if [ "${#EXTRACTOR_PACK_REFS[@]}" -eq 1 ] && [[ "${EXTRACTOR_PACK_REFS[0]}" == PACK-good=* ]]; then
    pass "the Pack with a real origin was mounted (${EXTRACTOR_PACK_REFS[0]})"
else
    fail_test "expected exactly PACK-good in EXTRACTOR_PACK_REFS, got: ${EXTRACTOR_PACK_REFS[*]:-<empty>}"
fi

if [ "${#EXTRACTOR_PACK_SKIPPED[@]}" -eq 1 ] && [ "${EXTRACTOR_PACK_SKIPPED[0]}" = "PACK-frozen" ]; then
    pass "PACK-frozen landed in the frozen-skip list, not misclassified"
else
    fail_test "expected PACK-frozen alone in EXTRACTOR_PACK_SKIPPED, got: ${EXTRACTOR_PACK_SKIPPED[*]:-<empty>}"
fi

if [ "${#EXTRACTOR_PACK_SKIPPED_NO_ORIGIN[@]}" -eq 1 ] && [ "${EXTRACTOR_PACK_SKIPPED_NO_ORIGIN[0]}" = "PACK-local" ]; then
    pass "PACK-local landed in the no-origin-skip list, not the frozen list"
else
    fail_test "expected PACK-local alone in EXTRACTOR_PACK_SKIPPED_NO_ORIGIN, got: ${EXTRACTOR_PACK_SKIPPED_NO_ORIGIN[*]:-<empty>}"
fi

context=$(pack_snapshot_context)
if grep -q 'PACK-frozen' <<<"$context" && grep -q 'frozen' <<<"$context"; then
    pass "prompt context still labels PACK-frozen as frozen"
else
    fail_test "prompt context lost the frozen label for PACK-frozen"
fi

if grep -q 'PACK-local' <<<"$context" && ! grep -q 'PACK-local.*frozen\|frozen.*PACK-local' <<<"$context"; then
    pass "prompt context mentions PACK-local without falsely calling it frozen"
else
    fail_test "prompt context either drops PACK-local or mislabels it as frozen"
fi


# --- Second scenario (cold-review finding, 24.09): a Pack dir with no .git
# of its own, nested inside a workspace that IS a git repo (the real,
# common case -- the pilot's own ~/IWE canonical checkout is one), must not
# inherit the WORKSPACE's git identity and get waved through as
# "local-only, no origin". `rev-parse --is-inside-work-tree` alone returns
# true here because git looks UP the tree for .git -- this is exactly the
# broken/incomplete-clone case the strict branch exists to hard-abort on.
WORKDIR2=$(mktemp -d)
# Replaces, not adds to, the first scenario's EXIT trap -- clean up both.
trap 'chmod -R u+w "$WORKDIR" "$WORKDIR2" 2>/dev/null; rm -rf "$WORKDIR" "$WORKDIR2"' EXIT
LOG_FILE="$WORKDIR2/extractor.log"
: > "$LOG_FILE"

CANON2="$WORKDIR2/canon"
ISO2="$WORKDIR2/iso"
mkdir -p "$CANON2" "$ISO2"
git -C "$CANON2" init -q
git -C "$CANON2" commit -q --allow-empty -m "workspace root is itself a git repo"

BARE2="$WORKDIR2/PACK-good-bare.git"
git init -q --bare "$BARE2"
mkdir -p "$CANON2/PACK-good"
git -C "$CANON2/PACK-good" init -q
git -C "$CANON2/PACK-good" commit -q --allow-empty -m init
git -C "$CANON2/PACK-good" remote add origin "$BARE2"
git -C "$CANON2/PACK-good" push -q origin HEAD:refs/heads/main

# PACK-broken: a plain directory, no .git of its own -- inherits CANON2's.
mkdir -p "$CANON2/PACK-broken"
: > "$CANON2/PACK-broken/some-file.md"

if mount_readonly_packs "$CANON2" "$ISO2"; then
    fail_test "PACK-broken (no .git of its own, nested in a git workspace) was silently skipped instead of hard-aborting the run"
else
    pass "PACK-broken (no .git of its own, nested in a git workspace) still hard-aborts the run, not misclassified as local-only-no-origin"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_915_extractor_no_origin_pack: all checks passed"
fi
exit "$fail"
