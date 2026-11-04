#!/bin/bash
# Regression test for issue #1458: two isolated extractor runs started in the
# same minute race for the canonical repo's .git/config.lock. The old
# `worktree add -b` wrote tracking config, failed on the held lock and left an
# orphan extractor/<label>-<id> branch behind.
#
# Exercises the real create_isolated_worktree() and its helpers, extracted
# from extractor.sh (same technique as test_extractor_branch_cleanup.sh).
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/roles/extractor/scripts/extractor.sh"
for fn in create_isolated_worktree drop_failed_isolation_branch set_isolation_upstream \
          maybe_cleanup_empty_worktree cleanup_isolated_inbox_worktree; do
    body=$(awk -v name="$fn" '$0 ~ "^" name "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$SCRIPT")
    if [ -z "$body" ]; then
        echo "FAIL: $fn() not found in $SCRIPT"
        exit 1
    fi
    eval "$body"
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/runs"
mkdir -p "$TMPDIR"
LOG_FILE="$TMP/extractor.log"
log() { echo "$*" >> "$LOG_FILE"; }

GIT_ID=(-c user.email=test@example.invalid -c user.name="Config lock regression")
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/canon" 2>/dev/null
CANON="$TMP/canon"
git -C "$CANON" "${GIT_ID[@]}" commit -q --allow-empty -m init
git -C "$CANON" push -q origin main
START=$(git -C "$CANON" rev-parse origin/main)
STAMP="2026110409"  # fixed run-id prefix, see fake_date below

extractor_branches() { git -C "$CANON" for-each-ref --format='%(refname:short)' 'refs/heads/extractor/*'; }
run_dirs() { find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }
# git prints the physical path (macOS: /var -> /private/var); resolve the parent,
# which exists even after the worktree itself was removed.
registered() {
    local phys
    phys="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
    git -C "$CANON" worktree list --porcelain | grep -qxF "worktree $phys"
}

# (a) Another run holds .git/config.lock for the whole attempt.
touch "$CANON/.git/config.lock"
rc=0
create_isolated_worktree "$CANON" DS-fixture main feed || rc=$?
rm -f "$CANON/.git/config.lock"
if [ "$rc" -ne 0 ]; then pass "held config lock: run refused"; else fail "held config lock: rc=0"; fi
if [ -z "$(extractor_branches)" ]; then
    pass "held config lock: no orphan extractor/* branch"
else
    fail "held config lock: orphan branch left: $(extractor_branches)"
fi
if [ "$(run_dirs)" = 0 ]; then pass "held config lock: run directory removed"; else fail "held config lock: run directory left"; fi
if registered "$ISO_WORKTREE"; then fail "held config lock: worktree still registered"; else pass "held config lock: no worktree registered"; fi
if grep -q 'could not lock config file' "$LOG_FILE"; then
    pass "held config lock: lock error logged"
else
    fail "held config lock: lock error not in the log"
fi

# (b) No lock: the worktree is created and registered, upstream is set.
rc=0
create_isolated_worktree "$CANON" DS-fixture main feed || rc=$?
if [ "$rc" -eq 0 ]; then pass "no lock: worktree created"; else fail "no lock: rc=$rc"; fi
if registered "$ISO_WORKTREE"; then pass "no lock: worktree registered"; else fail "no lock: worktree not registered"; fi
upstream=$(git -C "$ISO_WORKTREE" rev-parse --abbrev-ref "$ISO_BRANCH@{upstream}" 2>/dev/null || true)
if [ "$upstream" = origin/main ]; then pass "no lock: upstream is origin/main"; else fail "no lock: upstream '$upstream'"; fi
if [ "$(git -C "$ISO_WORKTREE" rev-parse HEAD)" = "$START" ]; then
    pass "no lock: worktree starts at origin/main"
else
    fail "no lock: wrong start commit"
fi
git -C "$CANON" worktree remove --force "$ISO_WORKTREE"
git -C "$CANON" branch -D "$ISO_BRANCH" >/dev/null
rm -rf "$ISO_RUN_ROOT"

# (c) A pre-existing branch with the generated name and the same tip survives.
date() { echo "${STAMP}0008"; }
existing="extractor/feed-${STAMP}0008-$$"
git -C "$CANON" branch "$existing" "$START"
rc=0
create_isolated_worktree "$CANON" DS-fixture main feed || rc=$?
unset -f date
if [ "$rc" -ne 0 ]; then pass "pre-existing branch: run refused"; else fail "pre-existing branch: rc=0"; fi
if [ "$(git -C "$CANON" rev-parse --verify -q "refs/heads/$existing" || true)" = "$START" ]; then
    pass "pre-existing branch: kept at its tip"
else
    fail "pre-existing branch: deleted or moved"
fi
if [ "$(run_dirs)" = 0 ]; then pass "pre-existing branch: run directory removed"; else fail "pre-existing branch: run directory left"; fi
git -C "$CANON" branch -D "$existing" >/dev/null

# drop_failed_isolation_branch() deletes only this attempt's own empty branch.
has_branch() { git -C "$CANON" show-ref --verify --quiet "refs/heads/$1"; }

own="extractor/feed-${STAMP}0009-1"
git -C "$CANON" branch "$own" "$START"
drop_failed_isolation_branch "$CANON" "$own" "$START" 0
if has_branch "$own"; then fail "own empty branch was kept"; else pass "own empty branch is deleted"; fi

ahead="extractor/feed-${STAMP}0010-1"
git -C "$CANON" "${GIT_ID[@]}" commit -q --allow-empty -m local
git -C "$CANON" branch "$ahead" HEAD
drop_failed_isolation_branch "$CANON" "$ahead" "$START" 0
if has_branch "$ahead"; then pass "branch with a commit on top is kept"; else fail "branch with a commit on top was deleted"; fi

foreign="feature/feed-${STAMP}0011-1"
git -C "$CANON" branch "$foreign" "$START"
drop_failed_isolation_branch "$CANON" "$foreign" "$START" 0
if has_branch "$foreign"; then pass "branch outside the isolation pattern is kept"; else fail "branch outside the isolation pattern was deleted"; fi

existed="extractor/feed-${STAMP}0012-1"
git -C "$CANON" branch "$existed" "$START"
drop_failed_isolation_branch "$CANON" "$existed" "$START" 1
if has_branch "$existed"; then pass "branch that existed before the attempt is kept"; else fail "branch that existed before the attempt was deleted"; fi

exit "$FAIL"
